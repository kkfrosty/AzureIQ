#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'ApimInsights.psm1') -Force
$module = Get-Module ApimInsights
$workspace = [IO.Path]::GetFullPath((Join-Path $root '..\..\..\..'))
$temp = Join-Path $workspace ('.azureiq\tmp\insights-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $temp 'config') -Force
$profilePath = Join-Path $temp 'config\local.azureiq.json'
$tracked = "schemaVersion: 1`nsafety:`n  requireExactScope: true`n"
$configuration = @{
    schemaVersion = 1
    scope = @{ tenantId = '00000000-0000-0000-0000-000000000002'; subscriptionIds = @('00000000-0000-0000-0000-000000000001') }
    identity = @{ interactivePrincipal = 'test-reader' }
}
$text = $configuration | ConvertTo-Json -Depth 10
$text | Set-Content -LiteralPath $profilePath -NoNewline
$tracked | Set-Content -LiteralPath (Join-Path $temp 'config\azureiq.yaml') -NoNewline
$service = "/subscriptions/$($configuration.scope.subscriptionIds[0])/resourceGroups/example/providers/Microsoft.ApiManagement/service/example"
$component = "/subscriptions/$($configuration.scope.subscriptionIds[0])/resourceGroups/example/providers/Microsoft.Insights/components/example"
$log = "/subscriptions/$($configuration.scope.subscriptionIds[0])/resourceGroups/example/providers/Microsoft.OperationalInsights/workspaces/example"
$diagnostic = @{ properties = @{ loggerId = "$service/loggers/example"; sampling = @{ percentage = 100 } } }
$responses = @{
    "$service/apis/mock" = @{ properties = @{} }
    "$service/diagnostics/applicationinsights" = $diagnostic
    "$service/apis/mock/diagnostics/applicationinsights" = $diagnostic
    "$service/loggers/example" = @{ properties = @{ resourceId = $component } }
    $component = @{ id = $component; properties = @{ WorkspaceResourceId = $log } }
    $log = @{ properties = @{ customerId = '00000000-0000-0000-0000-000000000005' } }
    "$component/providers/Microsoft.Authorization/roleAssignments" = @{ value = @() }
}
$state = @{
    profile = @{ configuration = $configuration; configurationText = $text; configurationPath = $profilePath; tracked = $tracked }
    responses = $responses; accountChecks = 0; reads = 0; queries = 0; last = ''; mismatch = $false
    deniedApi = $false; invalidAggregate = $false; missingSchema = $false; changeProfile = $false
}
$script:assertions = 0
function Check {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw "FAILED: $Message" }
    $script:assertions++
}
try {
    & $module {
        param($State)
        $script:testState = $State
        function script:Get-InsightsProfile {
            param([string]$WorkspaceRoot)
            $script:testState.profile
        }
        function script:Get-ApimVnetSnapshot {
            param($WorkspaceRoot, $ServiceName, $ResourceGroup)
            if ($script:testState.changeProfile) {
                'changed' | Set-Content -LiteralPath $script:testState.profile.configurationPath
            }
            @{ service = @{ sku = @{ name = 'Developer' }; properties = @{} } }
        }
        function script:Invoke-InsightsCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'account') {
                $script:testState.accountChecks++
                $script:testState.last = 'account'
                $config = $script:testState.profile.configuration
                return @{ tenantId = $config.scope.tenantId
                    id = $(if ($script:testState.mismatch) { '00000000-0000-0000-0000-000000000099' } else { $config.scope.subscriptionIds[0] })
                    environmentName = 'AzureCloud'; state = 'Enabled'; user = @{ name = 'test-reader' } }
            }
            if ($script:testState.last -ne 'account') { throw 'MISSING_ACCOUNT_RECHECK' }
            $script:testState.last = 'read'
            $script:testState.reads++
            if ($Arguments[0] -eq 'rest') {
                if ($Arguments[2] -ne 'get') { throw 'WRITE_NOT_ALLOWED' }
                $id = ([uri]$Arguments[4]).AbsolutePath
                if ($script:testState.deniedApi -and $id -match '/apis/mock/diagnostics/') { throw 'ACCESS_DENIED' }
                if (-not $script:testState.responses.ContainsKey($id)) { throw 'UNEXPECTED_READ' }
                return $script:testState.responses[$id]
            }
            if ($Arguments[0] -eq 'monitor') {
                $script:testState.queries++
                if ($Arguments[-1] -ne $script:testState.profile.configuration.scope.subscriptionIds[0]) { throw 'WRONG_QUERY_SUBSCRIPTION' }
                if ($Arguments[6] -match 'getschema') {
                    $names = @('TimeGenerated', '_ResourceId', 'Success', 'ResultCode', 'Id', 'OperationId', 'ItemCount', 'Url')
                    if ($script:testState.missingSchema) { $names = @('TimeGenerated') }
                    return @($names | ForEach-Object { @{ ColumnName = $_ } })
                }
                if ($script:testState.invalidAggregate) { return @() }
                return @(@{ Rows = 20; SuccessRows = 20; Http200Rows = 20; UniqueRequests = 20; UniqueOperations = 20; ItemCountSum = 20; KnownTraceRows = 1 })
            }
            throw 'UNEXPECTED_COMMAND'
        }
    } $state
    $args = @{ WorkspaceRoot = $temp; ServiceName = 'example'; ResourceGroup = 'example'; ApiId = 'mock' }
    $snapshot = Get-ApimInsightsSnapshot @args
    Check ($state.reads -eq 7 -and $state.accountChecks -eq 7) 'Every additional metadata read rechecks scope'
    Check ($state.queries -eq 0 -and $snapshot.requestEvidence.state -eq 'NotTested') 'Log query is opt-in'
    $args.QueryRequests = $true
    $args.StartTime = [datetimeoffset]'2026-01-01T00:00:00Z'
    $args.EndTime = [datetimeoffset]'2026-01-01T00:10:00Z'
    $args.RunMarker = '00000000-0000-0000-0000-000000000004'
    $args.TraceId = '5' * 32
    $args.ExpectedRequests = 20
    $snapshot = Get-ApimInsightsSnapshot @args
    Check ($snapshot.requestEvidence.state -eq 'Collected' -and $snapshot.requestEvidence.counts.Rows -eq 20) 'Schema-verified aggregate collection works'
    Check ($state.queries -eq 2) 'Actual schema discovery precedes aggregate query'
    $state.invalidAggregate = $true
    $snapshot = Get-ApimInsightsSnapshot @args
    Check ($snapshot.requestEvidence.category -eq 'INVALID_QUERY_RESULT' -and $snapshot.requestEvidence.state -eq 'Unavailable') 'Malformed result is not zero-row evidence'
    $state.invalidAggregate = $false
    $state.missingSchema = $true
    $snapshot = Get-ApimInsightsSnapshot @args
    Check ($snapshot.requestEvidence.category -eq 'REQUEST_SCHEMA_UNAVAILABLE') 'Missing required table columns block querying'
    $state.missingSchema = $false
    $state.deniedApi = $true
    $snapshot = Get-ApimInsightsSnapshot @args
    Check ($snapshot.collectionErrors.apiDiagnostic -eq 'ACCESS_DENIED') 'Denied API evidence is retained distinctly'
    $state.deniedApi = $false
    $state.mismatch = $true
    $before = $state.reads; $thrown = $false
    try { $null = Get-ApimInsightsSnapshot @args } catch { $thrown = $_.Exception.Message -eq 'SCOPE_MISMATCH' }
    Check ($thrown -and $state.reads -eq $before) 'Changed account stops before extra resource reads'
    $state.mismatch = $false
    $state.changeProfile = $true
    $thrown = $false
    try { $null = Get-ApimInsightsSnapshot @args } catch { $thrown = $_.Exception.Message -eq 'PRIVATE_SCOPE_CHANGED' }
    Check $thrown 'Private-profile drift stops collection'
} finally {
    foreach ($path in @($profilePath, (Join-Path $temp 'config\azureiq.yaml'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath (Join-Path $temp 'config') -Force
    Remove-Item -LiteralPath $temp -Force
    Remove-Module ApimInsights -Force
}
[pscustomobject]@{ status = 'Passed'; assertions = $script:assertions; azureCalls = 0 } | ConvertTo-Json
