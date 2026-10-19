#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:vnetRoot = Join-Path $PSScriptRoot '..\vnet-check'
Import-Module (Join-Path $script:vnetRoot 'ApimVnet.Collector.psm1')
Import-Module (Join-Path $script:vnetRoot 'ApimVnet.Rules.psm1')
$script:reader = Get-Module ApimVnet.Collector
$script:source = 'https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights'

function Get-InsightField {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    return $null
}

function Get-InsightTimestamp {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $time = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Value, [ref]$time)) { throw 'INVALID_SNAPSHOT' }
    return $time.ToUniversalTime().ToString('o')
}

function Invoke-InsightsCli {
    param([string[]]$Arguments)
    $previous = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
    try {
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'
        return & $script:reader { param($ArgsList) Invoke-ReaderCli -Arguments $ArgsList } $Arguments
    } finally { $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $previous }
}

function Get-InsightsProfile {
    param([string]$WorkspaceRoot)
    return & $script:reader { param($Root) Get-ApimReaderProfile -WorkspaceRoot $Root } $WorkspaceRoot
}

function Test-ApimInsightsReader {
    param([string]$WorkspaceRoot)
    return Test-ApimVnetReader -WorkspaceRoot $WorkspaceRoot
}

function Assert-InsightsContext {
    param($Profile, [string]$WorkspaceRoot)
    if ((Get-Content -Raw -LiteralPath $Profile.configurationPath) -cne $Profile.configurationText -or
        (Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot 'config\azureiq.yaml')) -cne $Profile.tracked) {
        throw 'PRIVATE_SCOPE_CHANGED'
    }
    Assert-ApimReaderContext -Configuration $Profile.configuration -Account (Invoke-InsightsCli @('account', 'show'))
}

function Get-InsightsReadUri {
    param([string]$ResourceId, [string]$SubscriptionId, [string[]]$ResourceGroups, [string]$ServiceId)
    $prefix = '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/]+)/providers/'
    if ($ResourceId -notmatch $prefix) { throw 'RESOURCE_PATH_NOT_ALLOWED' }
    if ($Matches[1] -ne $SubscriptionId) { throw 'CROSS_SUBSCRIPTION_READ_DENIED' }
    if ($Matches[2] -notin $ResourceGroups) { throw 'RELATED_RESOURCE_GROUP_NOT_AUTHORIZED' }
    if ($ResourceId -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]+/(?:apis/[A-Za-z0-9_.-]+(?:;rev=[0-9]+)?(?:/diagnostics/applicationinsights)?|diagnostics/applicationinsights|loggers/[A-Za-z0-9_.-]+)$') {
        if (-not $ResourceId.StartsWith("$ServiceId/", [StringComparison]::OrdinalIgnoreCase)) { throw 'RESOURCE_PATH_NOT_ALLOWED' }
        $version = '2024-05-01'
    } elseif ($ResourceId -match '/providers/Microsoft\.Insights/components/[A-Za-z0-9_.()-]+(?:/providers/Microsoft\.Authorization/roleAssignments)?$') {
        $version = if ($ResourceId -match '/roleAssignments$') { '2022-04-01' } else { '2020-02-02' }
    } elseif ($ResourceId -match '/providers/Microsoft\.OperationalInsights/workspaces/[A-Za-z0-9-]+$') {
        $version = '2022-10-01'
    } else { throw 'RESOURCE_PATH_NOT_ALLOWED' }
    return "https://management.azure.com${ResourceId}?api-version=$version"
}

function Test-InsightsOptionalFailure {
    param([string]$Code)
    return $Code -in @('ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED', 'UNSUPPORTED_OR_BAD_REQUEST',
        'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'INVALID_CLI_JSON', 'CROSS_SUBSCRIPTION_READ_DENIED',
        'RELATED_RESOURCE_GROUP_NOT_AUTHORIZED')
}

function Get-InsightsRequestQuery {
    param([string]$ComponentId, [datetimeoffset]$StartTime, [datetimeoffset]$EndTime,
        [string]$RunMarker, [string]$TraceId)
    if ($StartTime.Offset -ne [timespan]::Zero -or $EndTime.Offset -ne [timespan]::Zero -or
        ($EndTime - $StartTime).TotalSeconds -le 0 -or ($EndTime - $StartTime).TotalHours -gt 24) {
        throw 'INVALID_QUERY_WINDOW'
    }
    if ($ComponentId -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.Insights/components/[A-Za-z0-9_.()-]+$') {
        throw 'RESOURCE_PATH_NOT_ALLOWED'
    }
    if ($RunMarker -and $RunMarker -notmatch '^[0-9a-fA-F-]{36}$') { throw 'INVALID_CORRELATION_INPUT' }
    if ($TraceId -and ($TraceId -notmatch '^[0-9a-fA-F]{32}$' -or $TraceId -match '^0+$')) { throw 'INVALID_CORRELATION_INPUT' }
    $start = $StartTime.ToString('o'); $end = $EndTime.ToString('o')
    $query = "AppRequests | where TimeGenerated between (datetime('$start') .. datetime('$end')) | where _ResourceId =~ '$ComponentId'"
    if ($RunMarker) { $query += " | where Url contains '$RunMarker'" }
    $query += " | summarize Rows=count(), SuccessRows=countif(Success == true), Http200Rows=countif(ResultCode == '200'), UniqueRequests=count_distinct(Id), UniqueOperations=count_distinct(OperationId), ItemCountSum=sum(ItemCount)"
    if ($TraceId) { $query += ", KnownTraceRows=countif(OperationId == '$($TraceId.ToLowerInvariant())')" }
    return $query
}

function Get-ApimInsightsSnapshot {
    [CmdletBinding()]
    param([string]$WorkspaceRoot, [string]$ServiceName, [string]$ResourceGroup, [string]$ApiId,
        [string]$ComponentName, [string]$ComponentResourceGroup, [string]$WorkspaceResourceGroup,
        [switch]$QueryRequests, [datetimeoffset]$StartTime, [datetimeoffset]$EndTime,
        [string]$RunMarker, [string]$TraceId, [int]$ExpectedRequests = 0)
    $profile = Get-InsightsProfile $WorkspaceRoot
    $subscription = [string]$profile.configuration.scope.subscriptionIds[0]
    $serviceId = "/subscriptions/$subscription/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ServiceName"
    $groups = @($ResourceGroup, $ComponentResourceGroup, $WorkspaceResourceGroup | Where-Object { $_ } | Sort-Object -Unique)
    $snapshot = @{
        schemaVersion = 1; capturedAt = [datetimeoffset]::UtcNow.ToString('o')
        collectionErrors = @{}; serviceDiagnostic = $null; apiDiagnostic = $null; logger = $null
        component = $null; workspace = $null; roles = $null; expectedComponentId = $null
        requestEvidence = @{ state = 'NotTested' }; apiAvailable = $false
    }
    function Read-InsightResource {
        param([string]$Id)
        Assert-InsightsContext $profile $WorkspaceRoot
        $uri = Get-InsightsReadUri $Id $subscription $groups $serviceId
        return Invoke-InsightsCli @('rest', '--method', 'get', '--url', $uri, '--subscription', $subscription)
    }
    function Read-Optional {
        param([string]$Id, [string]$Surface)
        try { return Read-InsightResource $Id }
        catch {
            if (-not (Test-InsightsOptionalFailure $_.Exception.Message)) { throw }
            $snapshot.collectionErrors[$Surface] = $_.Exception.Message
            return $null
        }
    }
    # Reuse the reviewed network collector and evaluator; do not clone its rule matrix.
    $network = Get-ApimVnetSnapshot -WorkspaceRoot $WorkspaceRoot -ServiceName $ServiceName -ResourceGroup $ResourceGroup
    $snapshot.service = $network.service
    $snapshot.networkSnapshot = $network
    $snapshot.apiAvailable = $null -ne (Read-Optional "$serviceId/apis/$ApiId" 'api')
    $snapshot.serviceDiagnostic = Read-Optional "$serviceId/diagnostics/applicationinsights" 'serviceDiagnostic'
    $snapshot.apiDiagnostic = Read-Optional "$serviceId/apis/$ApiId/diagnostics/applicationinsights" 'apiDiagnostic'
    $effective = if ($snapshot.apiDiagnostic) { $snapshot.apiDiagnostic } else { $snapshot.serviceDiagnostic }
    $loggerId = [string](Get-InsightField (Get-InsightField $effective 'properties') 'loggerId')
    if ($loggerId) { $snapshot.logger = Read-Optional $loggerId 'logger' }
    $destination = [string](Get-InsightField (Get-InsightField $snapshot.logger 'properties') 'resourceId')
    if ($ComponentName) {
        $componentGroup = if ($ComponentResourceGroup) { $ComponentResourceGroup } else { $ResourceGroup }
        $snapshot.expectedComponentId = "/subscriptions/$subscription/resourceGroups/$componentGroup/providers/Microsoft.Insights/components/$ComponentName"
    }
    if ($destination) { $snapshot.component = Read-Optional $destination 'component' }
    $componentProperties = Get-InsightField $snapshot.component 'properties'
    $workspaceId = [string](Get-InsightField $componentProperties 'WorkspaceResourceId')
    if ($workspaceId) { $snapshot.workspace = Read-Optional $workspaceId 'workspace' }
    if ($snapshot.component) {
        $snapshot.roles = Read-Optional "$destination/providers/Microsoft.Authorization/roleAssignments" 'roles'
        if (Get-InsightField $snapshot.roles 'nextLink') { $snapshot.collectionErrors.roles = 'ROLE_PAGINATION_NOT_COLLECTED' }
    }
    if ($QueryRequests) {
        $snapshot.requestEvidence = @{
            state = 'Unavailable'; category = 'WORKSPACE_UNAVAILABLE'; observedAt = [datetimeoffset]::UtcNow.ToString('o')
            expectedRequests = $ExpectedRequests; markerSupplied = [bool]$RunMarker; traceSupplied = [bool]$TraceId
            startTime = $StartTime.ToString('o'); endTime = $EndTime.ToString('o')
        }
        $workspaceGuid = Get-InsightField (Get-InsightField $snapshot.workspace 'properties') 'customerId'
        $guid = [guid]::Empty
        if ($snapshot.workspace -and [guid]::TryParse([string]$workspaceGuid, [ref]$guid) -and $guid -ne [guid]::Empty) {
            try {
                Assert-InsightsContext $profile $WorkspaceRoot
                $schema = @(Invoke-InsightsCli @('monitor', 'log-analytics', 'query', '--workspace', [string]$guid,
                    '--analytics-query', 'AppRequests | getschema | project ColumnName', '--subscription', $subscription))
                $columns = @($schema | ForEach-Object { Get-InsightField $_ 'ColumnName' })
                $required = @('TimeGenerated', '_ResourceId', 'Success', 'ResultCode', 'Id', 'OperationId', 'ItemCount')
                if ($RunMarker) { $required += 'Url' }
                if (@($required | Where-Object { $_ -notin $columns }).Count) { throw 'REQUEST_SCHEMA_UNAVAILABLE' }
                $query = Get-InsightsRequestQuery $destination $StartTime $EndTime $RunMarker $TraceId
                Assert-InsightsContext $profile $WorkspaceRoot
                $rows = @(Invoke-InsightsCli @('monitor', 'log-analytics', 'query', '--workspace', [string]$guid,
                    '--analytics-query', $query, '--subscription', $subscription))
                if ($rows.Count -ne 1 -or $rows[0] -isnot [System.Collections.IDictionary]) { throw 'INVALID_QUERY_RESULT' }
                $names = @('Rows', 'SuccessRows', 'Http200Rows', 'UniqueRequests', 'UniqueOperations', 'ItemCountSum')
                if ($TraceId) { $names += 'KnownTraceRows' }
                $counts = @{}
                foreach ($name in $names) {
                    $number = Get-InsightField $rows[0] $name
                    if ($null -eq $number -and $name -eq 'ItemCountSum' -and (Get-InsightField $rows[0] 'Rows') -eq 0) { $number = 0 }
                    if ($number -isnot [long] -and $number -isnot [int] -or $number -lt 0) { throw 'INVALID_QUERY_RESULT' }
                    $counts[$name] = $number
                }
                $snapshot.requestEvidence.state = 'Collected'
                $snapshot.requestEvidence.category = $null
                $snapshot.requestEvidence.counts = $counts
                $snapshot.requestEvidence.observedAt = [datetimeoffset]::UtcNow.ToString('o')
            } catch {
                if (-not (Test-InsightsOptionalFailure $_.Exception.Message) -and
                    $_.Exception.Message -notin @('REQUEST_SCHEMA_UNAVAILABLE', 'INVALID_QUERY_RESULT')) { throw }
                $snapshot.requestEvidence.category = $_.Exception.Message
            }
        }
    }
    $snapshot.capturedAt = [datetimeoffset]::UtcNow.ToString('o')
    return $snapshot
}

function Invoke-ApimInsightsAssessment {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [ValidateSet('Live', 'Offline')][string]$Mode = 'Offline')
    if ((Get-InsightField $Snapshot 'schemaVersion') -ne 1) { throw 'INVALID_SNAPSHOT' }
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = Get-InsightField $Snapshot 'collectionErrors'
    if ($null -eq $errors) { $errors = @{} }
    function Add {
        param([string]$Id, [string]$Title, [ValidateSet('Pass', 'Fail', 'Unknown')][string]$Status,
            [string]$Detail, [string]$NextStep, [string]$Evidence = 'configuration', [string]$Source = $script:source)
        $findings.Add(@{ ruleId = $Id; title = $Title; status = $Status; detail = $Detail
            nextStep = $NextStep; evidenceRef = $Evidence; source = $Source })
    }
    foreach ($surface in @('api', 'serviceDiagnostic', 'apiDiagnostic', 'logger', 'component', 'workspace', 'roles')) {
        if ($errors.Contains($surface) -and -not ($surface -in @('serviceDiagnostic', 'apiDiagnostic') -and $errors[$surface] -eq 'NOT_FOUND')) {
            $code = if (Test-InsightsOptionalFailure $errors[$surface]) { $errors[$surface] } else { 'READ_UNAVAILABLE' }
            Add "collection-$surface" "$surface evidence" 'Unknown' "Read unavailable ($code)." 'Verify the diagnostic reader scope/access; do not change sender permissions to fix reader access.' 'collection'
        }
    }
    $service = Get-InsightField $Snapshot 'service'
    $sku = [string](Get-InsightField (Get-InsightField $service 'sku') 'name')
    $supported = $sku -in @('Developer', 'Premium', 'Basic', 'Standard')
    Add 'gateway-model' 'Gateway compatibility' $(if ($supported) { 'Pass' } else { 'Unknown' }) `
        $(if ($supported) { 'Classic managed APIM configuration rules apply.' } else { 'This candidate does not certify v2, Consumption, workspace or self-hosted gateway behavior.' }) `
        'Use a separately verified model-specific assessment when outside the supported managed classic scope.'
    $api = Get-InsightField $Snapshot 'apiDiagnostic'
    $inherited = Get-InsightField $Snapshot 'serviceDiagnostic'
    $apiUnknown = $errors.Contains('apiDiagnostic') -and $errors['apiDiagnostic'] -ne 'NOT_FOUND'
    $serviceUnknown = $errors.Contains('serviceDiagnostic') -and $errors['serviceDiagnostic'] -ne 'NOT_FOUND'
    $effective = if ($api) { $api } elseif (-not $apiUnknown) { $inherited } else { $null }
    $diagnosticSource = if ($api) { 'API override' } elseif ($effective) { 'Service inherited' } else { 'Unavailable' }
    if (-not $supported -or $apiUnknown -or (-not $api -and $serviceUnknown) -or -not (Get-InsightField $Snapshot 'apiAvailable')) {
        Add 'effective-diagnostic' 'Effective API diagnostic' 'Unknown' 'The intended API diagnostic could not be established reliably.' 'Resolve API/revision access and model coverage before judging logger configuration.'
    } elseif (-not $effective) {
        Add 'effective-diagnostic' 'Effective API diagnostic' 'Fail' 'Neither an API Application Insights diagnostic nor an inherited service diagnostic was found.' 'Plan enabling the intended diagnostic separately; verify its effective readback and new request evidence.'
    } else {
        Add 'effective-diagnostic' 'Effective API diagnostic' 'Pass' "Resolved from $diagnosticSource." 'Keep API overrides distinct from service defaults.'
    }
    $properties = Get-InsightField $effective 'properties'
    $logger = Get-InsightField (Get-InsightField $Snapshot 'logger') 'properties'
    if ($logger) {
        $isApplicationInsights = (Get-InsightField $logger 'loggerType') -eq 'applicationInsights'
        Add 'logger-type' 'Logger type' $(if ($isApplicationInsights) { 'Pass' } else { 'Fail' }) `
            $(if ($isApplicationInsights) { 'Application Insights logger found.' } else { 'The effective logger is not an Application Insights logger.' }) 'Review the selected logger without exporting credentials.'
        $destination = [string](Get-InsightField $logger 'resourceId')
        $expected = [string](Get-InsightField $Snapshot 'expectedComponentId')
        Add 'logger-destination' 'Expected destination' $(if (-not $destination -or -not $expected) { 'Unknown' } elseif ($destination -eq $expected) { 'Pass' } else { 'Fail' }) `
            $(if (-not $expected) { 'No expected destination was supplied; the observed target is not automatically wrong.' } elseif ($destination -eq $expected) { 'The effective logger matches the explicitly expected component.' } else { 'The destination is missing or differs from the explicitly expected component.' }) 'Confirm the intended component; telemetry may be routed elsewhere rather than lost.'
        $selector = [string](Get-InsightField (Get-InsightField $logger 'credentials') 'identityClientId')
        Add 'identity-selector' 'Publishing identity selection' $(if ($selector -eq 'SystemAssigned') { 'Pass' } else { 'Unknown' }) `
            $(if ($selector -eq 'SystemAssigned') { 'Literal system-assigned identity selector observed.' } else { 'Protected or non-system identity selection is not resolved by secret retrieval.' }) 'Corroborate the intended identity through deployment intent and delivery evidence; never retrieve its secret value.'
    } else {
        Add 'logger-evidence' 'Effective logger' 'Unknown' 'Logger metadata is unavailable.' 'Resolve the effective diagnostic reference and read access before judging its destination.'
    }
    if ($properties) {
        $sampling = Get-InsightField (Get-InsightField $properties 'sampling') 'percentage'
        $numeric = $sampling -is [int] -or $sampling -is [long] -or $sampling -is [double] -or $sampling -is [decimal]
        Add 'sampling' 'Successful-request sampling' $(if (-not $numeric -or $sampling -lt 0 -or $sampling -gt 100) { 'Unknown' } elseif ($sampling -eq 0) { 'Fail' } elseif ($sampling -eq 100) { 'Pass' } else { 'Unknown' }) `
            $(if (-not $numeric) { 'Sampling metadata unavailable.' } elseif ($sampling -eq 0) { 'Zero sampling intentionally omits successful requests; this is not evidence of a network fault.' } elseif ($sampling -eq 100) { '100 percent sampling configured; this does not guarantee lossless delivery.' } else { 'Reduced or unsupported sampling prevents a general exact-delivery conclusion.' }) 'For exact-count checks use only an independently approved controlled 100-percent-sampled API.'
        Add 'correlation' 'W3C correlation' $(if ((Get-InsightField $properties 'httpCorrelationProtocol') -eq 'W3C') { 'Pass' } else { 'Unknown' }) `
            $(if ((Get-InsightField $properties 'httpCorrelationProtocol') -eq 'W3C') { 'W3C correlation configured.' } else { 'W3C correlation is not established; this is not itself proof of logging failure.' }) 'Match the actual correlation mode before interpreting trace expectations.'
        $capture = @(); $headers = @()
        foreach ($side in @('frontend', 'backend')) {
            foreach ($direction in @('request', 'response')) {
                $packet = Get-InsightField (Get-InsightField $properties $side) $direction
                $bytes = Get-InsightField (Get-InsightField $packet 'body') 'bytes'
                if ($null -ne $bytes) { $capture += $bytes }
                $headers += @(Get-InsightField $packet 'headers' | Where-Object { $_ })
            }
        }
        $sensitive = @($headers | Where-Object { $_ -in @('Authorization', 'Proxy-Authorization', 'Cookie', 'Set-Cookie', 'Ocp-Apim-Subscription-Key') }).Count -gt 0
        Add 'capture-privacy' 'Payload and sensitive-header capture' $(if ($capture.Count -eq 4 -and @($capture | Where-Object { $_ -ne 0 }).Count -eq 0 -and -not $sensitive) { 'Pass' } else { 'Unknown' }) `
            $(if ($sensitive -or @($capture | Where-Object { $_ -gt 0 }).Count) { 'Capture settings require a privacy review; no captured content was read.' } else { 'Only complete zero-byte capture metadata can establish this narrow check.' }) 'Review capture/masking requirements separately; never include payloads or header values in this report.'
    }
    $component = Get-InsightField (Get-InsightField $Snapshot 'component') 'properties'
    $workspace = Get-InsightField (Get-InsightField $Snapshot 'workspace') 'properties'
    $localAuth = Get-InsightField $component 'DisableLocalAuth'
    Add 'ingestion-authentication' 'Ingestion authentication mode' $(if ($localAuth -eq $true) { 'Pass' } else { 'Unknown' }) `
        $(if ($localAuth -eq $true) { 'Component requires Entra-authenticated ingestion; actual publishing identity still needs separate evidence.' } else { 'Local authentication is enabled or unknown; this alone is not a delivery fault or proof of the selected sender mode.' }) `
        'Match the intended logger identity/key mode to the component policy; do not change authentication settings automatically.'
    Add 'workspace' 'Linked workspace access' $(if ($workspace) { 'Pass' } else { 'Unknown' }) `
        $(if ($workspace) { 'The related workspace was read within the approved resource scope.' } else { 'The linked workspace is unavailable, absent, or outside explicitly authorized related-resource coverage.' }) 'Check workspace linkage and authorize related scope separately where necessary.'
    foreach ($item in @(@{ label = 'component'; node = $component }, @{ label = 'workspace'; node = $workspace })) {
        $public = Get-InsightField $item.node 'publicNetworkAccessForIngestion'
        Add "ingestion-access-$($item.label)" "$($item.label) ingestion access" $(if ($public -eq 'Enabled') { 'Pass' } else { 'Unknown' }) `
            $(if ($public -eq 'Enabled') { 'Public ingestion enabled in configuration; reachability is not tested.' } else { 'Public ingestion is not established; a valid private path may be intended.' }) 'Verify the intended public or AMPLS/private-DNS path; do not automatically enable public access.'
    }
    $identity = Get-InsightField $service 'identity'
    $principals = @([string](Get-InsightField $identity 'principalId') | Where-Object { $_ })
    $assigned = Get-InsightField $identity 'userAssignedIdentities'
    if ($assigned -is [System.Collections.IDictionary]) {
        foreach ($entry in $assigned.Values) { $principals += @(Get-InsightField $entry 'principalId' | Where-Object { $_ }) }
    }
    $roles = @(Get-InsightField (Get-InsightField $Snapshot 'roles') 'value' | Where-Object { $_ })
    $publisher = @($roles | Where-Object {
        $role = Get-InsightField $_ 'properties'
        $destinationId = [string](Get-InsightField (Get-InsightField $Snapshot 'component') 'id')
        $roleScope = [string](Get-InsightField $role 'scope')
        $scopeCovers = $roleScope -and ($destinationId -eq $roleScope -or $destinationId.StartsWith("$roleScope/", [StringComparison]::OrdinalIgnoreCase))
        $scopeCovers -and (Get-InsightField $role 'principalId') -in $principals -and
        [string](Get-InsightField $role 'roleDefinitionId') -match '/3913510d-42f4-4e42-8a64-420c390055eb$' -and
        -not (Get-InsightField $role 'condition')
    }).Count -gt 0
    Add 'publisher-role' 'Publishing role candidate' $(if ($publisher) { 'Pass' } else { 'Unknown' }) `
        $(if ($publisher) { 'An unconditional built-in publisher-role candidate matches an APIM identity at the component scope.' } else { 'No matching candidate was established; custom, conditional, inherited rights and deny assignments are not fully evaluated.' }) 'Review sender rights separately from reader permissions; do not grant roles from this diagnostic.'
    $networkSnapshot = Get-InsightField $Snapshot 'networkSnapshot'
    $network = if ($networkSnapshot) { Invoke-ApimVnetAssessment -Snapshot $networkSnapshot } else { $null }
    if ($network) {
        foreach ($finding in @(Get-InsightField $network 'findings')) {
            if ($finding.status -notin @('Pass', 'Fail', 'Unknown', 'NotApplicable')) { throw 'INVALID_SNAPSHOT' }
            # The existing evaluator returns sanitized, fixed finding text, not raw native errors.
            $label = if ($finding.title) { $finding.title } else { $finding.ruleId }
            $findings.Add(@{ ruleId = "vnet:$($finding.ruleId)"; title = "Network / $label"
                status = $finding.status; detail = $finding.detail; nextStep = $finding.nextStep
                evidenceRef = "network-region-$($finding.regionIndex)"; source = $finding.source
                evidenceTimestamp = $finding.evidenceTimestamp; dependencyEvidence = $finding.dependencyEvidence })
        }
    } else {
        Add 'network-evidence' 'VNet assessment' 'Unknown' 'No reviewed network assessment was supplied.' 'Run the existing read-only VNet assessment; workstation connectivity is not APIM-host evidence.' 'network'
    }
    $evidence = Get-InsightField $Snapshot 'requestEvidence'
    $state = Get-InsightField $evidence 'state'
    $delivery = 'NotTested'
    if ($state -eq 'Collected') {
        $counts = Get-InsightField $evidence 'counts'
        foreach ($key in @('Rows', 'SuccessRows', 'Http200Rows', 'UniqueRequests', 'UniqueOperations', 'ItemCountSum')) {
            $number = Get-InsightField $counts $key
            if (($number -isnot [long] -and $number -isnot [int]) -or $number -lt 0) { throw 'INVALID_QUERY_RESULT' }
        }
        $expected = Get-InsightField $evidence 'expectedRequests'
        $exact = $expected -gt 0 -and @('Rows', 'SuccessRows', 'Http200Rows', 'UniqueRequests', 'UniqueOperations', 'ItemCountSum' | Where-Object { $counts[$_] -ne $expected }).Count -eq 0
        $traceOkay = -not (Get-InsightField $evidence 'traceSupplied') -or (Get-InsightField $counts 'KnownTraceRows') -eq 1
        $delivery = if ($counts.Rows -eq 0) { 'EvidenceAbsent' } elseif ($expected -gt 0 -and (-not $exact -or -not $traceOkay)) { 'CountMismatch' } else { 'Observed' }
        Add 'request-evidence' 'Observed Request ingestion' $(if ($delivery -eq 'Observed') { 'Pass' } else { 'Unknown' }) `
            $(if ($delivery -eq 'Observed') { 'Request records were observed in the selected component and UTC window; this does not certify present transport or timely delivery.' } else { 'Absent or mismatched rows do not independently establish an APIM sender or network cause.' }) 'Account for actual sampling, observation time, retention and delayed delivery before a new authorized verification.' 'requests'
    } else {
        Add 'request-evidence' 'Observed Request ingestion' 'Unknown' `
            $(if ($state -eq 'Unavailable') { 'The optional request query could not return validated evidence.' } else { 'Request querying was not requested; no traffic was generated.' }) 'Use an authorized workspace/window and optional known run; collection access failure is not publishing failure.' 'requests'
    }
    $configurationChecks = @($findings | Where-Object { $_.evidenceRef -notin @('requests', 'collection') })
    $configurationFailed = @($configurationChecks | Where-Object status -eq 'Fail').Count
    $configurationUnknown = @($configurationChecks | Where-Object status -eq 'Unknown').Count
    $failed = @($findings | Where-Object status -eq 'Fail').Count
    $unknown = @($findings | Where-Object status -eq 'Unknown').Count
    $requestSummary = @{ state = $delivery; observedAt = Get-InsightTimestamp (Get-InsightField $evidence 'observedAt')
        startTime = Get-InsightTimestamp (Get-InsightField $evidence 'startTime')
        endTime = Get-InsightTimestamp (Get-InsightField $evidence 'endTime') }
    if ($state -eq 'Collected') {
        $safeCounts = @{}
        foreach ($name in @('Rows', 'SuccessRows', 'Http200Rows', 'UniqueRequests', 'UniqueOperations', 'ItemCountSum', 'KnownTraceRows')) {
            $number = Get-InsightField $counts $name
            if ($null -eq $number) { continue }
            if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt 0) { throw 'INVALID_QUERY_RESULT' }
            $safeCounts[$name] = $number
        }
        $requestSummary.counts = $safeCounts
    }
    return @{
        schemaVersion = 1; toolVersion = '0.1.0'; assessmentMode = $Mode
        capturedAt = Get-InsightTimestamp (Get-InsightField $Snapshot 'capturedAt'); assessedAt = [datetimeoffset]::UtcNow.ToString('o')
        summary = @{ failed = $failed; unknown = $unknown; passed = @($findings | Where-Object status -eq 'Pass').Count
            notApplicable = @($findings | Where-Object status -eq 'NotApplicable').Count }
        configuration = $(if ($configurationFailed) { 'IssuesObserved' } elseif ($configurationUnknown) { 'PartialEvidence' } else { 'Checked' })
        collection = $(if ($errors.Count -or $state -eq 'Unavailable') { 'Partial' } else { 'CompleteWithinRequestedScope' })
        diagnosticSource = $diagnosticSource; delivery = $requestSummary
        rootCauseAnalysis = @{ confidence = 'undetermined'; behavior = 'Configuration findings and request records do not alone prove a transport root cause. No remediation or active traffic was executed.' }
        findings = $findings.ToArray()
    }
}

Export-ModuleMember -Function Get-ApimInsightsSnapshot, Invoke-ApimInsightsAssessment, Get-InsightsReadUri, Get-InsightsRequestQuery, Test-ApimInsightsReader
