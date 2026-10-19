#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ReaderCli {
    param([string[]]$Arguments)
    # Azure CLI diagnostics can contain private identifiers; only fixed error categories leave this boundary.
    $command = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $allArguments = @($Arguments) + @('--only-show-errors', '--output', 'json')
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ([System.IO.Path]::GetExtension($command.Source) -eq '.cmd') {
        foreach ($argument in @($command.Source) + $allArguments) {
            if ($argument -match '["%!\r\n&|<>^]') { throw 'CLI_ARGUMENT_NOT_ALLOWED' }
        }
        $start.FileName = $env:ComSpec
        $quotedArguments = @($allArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $start.Arguments = '/d /s /c ""' + $command.Source + '" ' + $quotedArguments + '"'
    } else {
        $start.FileName = $command.Source
        foreach ($argument in $allArguments) { $start.ArgumentList.Add($argument) }
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'CLI_READ_TIMEOUT'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        $code = $process.ExitCode
    } finally { $process.Dispose() }
    if ($code -ne 0) {
        $text = $errorOutput
        $category = if ($text -match 'AuthorizationFailed|Forbidden|403') { 'ACCESS_DENIED' }
            elseif ($text -match 'ResourceNotFound|NotFound|404') { 'NOT_FOUND' }
            elseif ($text -match 'TooManyRequests|429') { 'THROTTLED' }
            elseif ($text -match 'BadRequest|NotSupported|400') { 'UNSUPPORTED_OR_BAD_REQUEST' }
            else { 'CLI_READ_FAILED' }
        throw [System.InvalidOperationException]::new($category)
    }
    try { return ($output | ConvertFrom-Json -AsHashtable -Depth 100) }
    catch { throw [System.InvalidOperationException]::new('INVALID_CLI_JSON') }
}

function Test-OptionalReadFailure {
    param([string]$Message)
    return $Message -in @('ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED', 'UNSUPPORTED_OR_BAD_REQUEST',
        'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'INVALID_CLI_JSON')
}

function Assert-ApimReaderContext {
    param([Parameter(Mandatory)]$Configuration, [Parameter(Mandatory)]$Account)
    if (-not $Configuration.ContainsKey('scope') -or -not $Configuration.ContainsKey('identity')) {
        throw 'PRIVATE_SCOPE_REQUIRED'
    }
    $scope = $Configuration.scope
    $tenant = [guid]::Empty
    $subscription = [guid]::Empty
    if (-not $scope.ContainsKey('tenantId') -or -not $scope.ContainsKey('subscriptionIds') -or
        @($scope.subscriptionIds).Count -ne 1 -or
        -not [guid]::TryParse([string]$scope.tenantId, [ref]$tenant) -or $tenant -eq [guid]::Empty -or
        -not [guid]::TryParse([string]$scope.subscriptionIds[0], [ref]$subscription) -or $subscription -eq [guid]::Empty) {
        throw 'EXACT_PRIVATE_SCOPE_REQUIRED'
    }
    if ($scope.ContainsKey('excludedSubscriptionIds') -and [string]$subscription -in $scope.excludedSubscriptionIds) {
        throw 'EXCLUDED_SCOPE'
    }
    if (-not $Account.ContainsKey('tenantId') -or -not $Account.ContainsKey('id') -or
        -not $Account.ContainsKey('environmentName') -or -not $Account.ContainsKey('state') -or
        $Account.tenantId -ne [string]$tenant -or $Account.id -ne [string]$subscription) { throw 'SCOPE_MISMATCH' }
    if ($Account.environmentName -ne 'AzureCloud' -or $Account.state -ne 'Enabled') { throw 'UNSUPPORTED_CLOUD_OR_ACCOUNT' }
    $identity = $Configuration.identity
    $principal = if ($identity.ContainsKey('apimVnetReaderPrincipal')) { $identity.apimVnetReaderPrincipal }
        elseif ($identity.ContainsKey('interactivePrincipal')) { $identity.interactivePrincipal } else { $null }
    if (-not $Account.ContainsKey('user') -or -not $Account.user.ContainsKey('name') -or
        [string]::IsNullOrWhiteSpace($principal) -or $principal -ne $Account.user.name) {
        throw 'PRINCIPAL_MISMATCH'
    }
}

function Get-ApimReadUri {
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string]$SubscriptionId)
    $apimPattern = '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]+(?:/networkstatus)?$'
    $networkPattern = '^/subscriptions/([0-9a-f-]{36})/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.Network/(?:virtualNetworks/[A-Za-z0-9_.-]+(?:/subnets/[A-Za-z0-9_.-]+)?|networkSecurityGroups/[A-Za-z0-9_.-]+|routeTables/[A-Za-z0-9_.-]+)$'
    if ($ResourceId -match $apimPattern) { $version = '2024-05-01' }
    elseif ($ResourceId -match $networkPattern) { $version = '2024-05-01' }
    else { throw 'RESOURCE_PATH_NOT_ALLOWED' }
    if ($Matches[1] -ne $SubscriptionId) { throw 'CROSS_SUBSCRIPTION_READ_DENIED' }
    return "https://management.azure.com${ResourceId}?api-version=$version"
}

function Get-ApimReaderProfile {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'AZURE_CLI_REQUIRED' }
    $tracked = Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot 'config\azureiq.yaml')
    if ($tracked -notmatch '(?m)^schemaVersion:\s*1\s*$' -or $tracked -notmatch 'requireExactScope:\s*true') {
        throw 'UNSUPPORTED_WORKSPACE_PROFILE'
    }
    $configurationPath = Join-Path $WorkspaceRoot 'config\local.azureiq.json'
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw 'PRIVATE_SCOPE_REQUIRED' }
    $configurationText = Get-Content -Raw -LiteralPath $configurationPath
    $configuration = $configurationText | ConvertFrom-Json -AsHashtable -Depth 50
    if (-not $configuration.ContainsKey('schemaVersion') -or $configuration.schemaVersion -ne 1) {
        throw 'UNSUPPORTED_PRIVATE_PROFILE'
    }
    $account = Invoke-ReaderCli @('account', 'show')
    Assert-ApimReaderContext $configuration $account
    return @{ configuration = $configuration; configurationText = $configurationText; configurationPath = $configurationPath; tracked = $tracked }
}

function Test-ApimVnetReader {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)
    $null = Get-ApimReaderProfile -WorkspaceRoot $WorkspaceRoot
    return @{ status = 'Ready'; resourceReads = 0; mutatesAzure = $false; changesAuthentication = $false }
}

function Get-ApimVnetSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,50}$')][string]$ServiceName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]{1,90}$')][string]$ResourceGroup
    )
    $profile = Get-ApimReaderProfile -WorkspaceRoot $WorkspaceRoot
    $configuration = $profile.configuration
    $configurationText = $profile.configurationText
    $configurationPath = $profile.configurationPath
    $tracked = $profile.tracked
    $collectionStartedAt = [datetimeoffset]::UtcNow
    $reads = [System.Collections.Generic.List[object]]::new()
    function Read-Resource {
        param([string]$Id, [string]$Kind)
        if ((Get-Content -Raw -LiteralPath $configurationPath) -cne $configurationText -or
            (Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot 'config\azureiq.yaml')) -cne $tracked) {
            throw 'PRIVATE_SCOPE_CHANGED'
        }
        $account = Invoke-ReaderCli @('account', 'show')
        Assert-ApimReaderContext $configuration $account
        $uri = Get-ApimReadUri $Id $configuration.scope.subscriptionIds[0]
        $readStartedAt = [datetimeoffset]::UtcNow
        $status = 'Succeeded'
        $etagDigest = $null
        try {
            $response = Invoke-ReaderCli @('rest', '--method', 'get', '--url', $uri, '--subscription', $configuration.scope.subscriptionIds[0])
            if ($response -is [System.Collections.IDictionary] -and $response.Contains('etag') -and $response.etag) {
                $etagDigest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                    [System.Text.Encoding]::UTF8.GetBytes([string]$response.etag))).ToLowerInvariant()
            }
            return $response
        } catch {
            $status = if (Test-OptionalReadFailure $_.Exception.Message) { $_.Exception.Message } else { 'READ_ABORTED' }
            throw
        } finally {
            $reads.Add(@{
                ordinal = $reads.Count + 1; resourceKind = $Kind; apiVersion = '2024-05-01'
                startedAt = $readStartedAt.ToString('o'); completedAt = [datetimeoffset]::UtcNow.ToString('o')
                status = $status; etagDigest = $etagDigest
            })
        }
    }
    $id = "/subscriptions/$($configuration.scope.subscriptionIds[0])/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ServiceName"
    $service = Read-Resource $id 'apim-service'
    if (-not $service.ContainsKey('properties') -or -not $service.ContainsKey('sku')) { throw 'INVALID_SERVICE_RESPONSE' }
    $locations = @(@{
        location = $service.location; capacity = $service.sku.capacity
        virtualNetworkConfiguration = $service.properties['virtualNetworkConfiguration']
    })
    if ($null -ne $service.properties['additionalLocations']) { $locations += @($service.properties.additionalLocations) }
    if ($locations.Count -gt 10) { throw 'LOCATION_LIMIT_EXCEEDED' }
    $regions = [System.Collections.Generic.List[object]]::new()
    foreach ($location in $locations) {
        $region = @{
            location = $location.location
            capacity = $(if ($null -ne $location['sku']) { $location.sku['capacity'] } else { $location['capacity'] })
            subnet = $null; virtualNetwork = $null; networkSecurityGroup = $null; routeTable = $null
            evidenceGaps = [System.Collections.Generic.List[string]]::new()
        }
        $networkConfiguration = $location['virtualNetworkConfiguration']
        if ($null -eq $networkConfiguration -or -not $networkConfiguration.ContainsKey('subnetResourceId') -or
            [string]::IsNullOrWhiteSpace($networkConfiguration.subnetResourceId)) {
            $region.evidenceGaps.Add('SUBNET_REFERENCE_UNAVAILABLE')
            $regions.Add($region)
            continue
        }
        $subnetId = $networkConfiguration.subnetResourceId
        try { $region.subnet = Read-Resource $subnetId 'subnet' }
        catch {
            if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
            $region.evidenceGaps.Add("SUBNET_$($_.Exception.Message)")
        }
        $vnetId = $subnetId -replace '/subnets/[^/]+$', ''
        try { $region.virtualNetwork = Read-Resource $vnetId 'virtual-network' }
        catch {
            if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
            $region.evidenceGaps.Add("VNET_$($_.Exception.Message)")
        }
        if ($null -ne $region.subnet -and $region.subnet.ContainsKey('properties')) {
            foreach ($type in @('networkSecurityGroup', 'routeTable')) {
                $reference = $region.subnet.properties[$type]
                if ($null -eq $reference) { continue }
                if (-not $reference.ContainsKey('id')) { $region.evidenceGaps.Add('INVALID_NETWORK_REFERENCE'); continue }
                try { $region[$type] = Read-Resource $reference.id $type }
                catch {
                    if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
                    $region.evidenceGaps.Add("NETWORK_RULE_$($_.Exception.Message)")
                }
            }
        }
        $regions.Add($region)
    }
    $native = @{ available = $false; locations = @(); errorCategory = $null }
    try {
        $native.locations = @(Read-Resource "$id/networkstatus" 'apim-network-status')
        $native.available = $true
    } catch {
        if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
        $native.errorCategory = $_.Exception.Message
    }
    return @{
        schemaVersion = 1; capturedAt = [datetimeoffset]::UtcNow.ToString('o')
        service = $service; regions = $regions.ToArray(); nativeNetworkStatus = $native
        collectionEvidence = @{
            transport = 'azure-cli-arm-get'; startedAt = $collectionStartedAt.ToString('o')
            completedAt = [datetimeoffset]::UtcNow.ToString('o'); reads = $reads.ToArray()
            consistency = 'Sequential configuration GETs, not an atomic snapshot; ETag digests identify returned resource versions when available. No cross-resource consistency or mid-run Azure configuration drift detection is claimed.'
        }
    }
}

Export-ModuleMember -Function Get-ApimVnetSnapshot, Test-ApimVnetReader, Assert-ApimReaderContext, Get-ApimReadUri
