#Requires -Version 7.4
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'ApimVnet.Collector.psm1') -Force
Import-Module (Join-Path $toolRoot 'ApimVnet.Rules.psm1') -Force
$module = Get-Module 'ApimVnet.Collector'
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $toolRoot '..\..\..\..'))
$fixtureRoot = Join-Path $workspaceRoot ('.azureiq\tmp\apim-collector-tests-' + [guid]::NewGuid().ToString('N'))
$configDirectory = Join-Path $fixtureRoot 'config'
$null = New-Item -ItemType Directory -Path $configDirectory -Force
$profilePath = Join-Path $configDirectory 'azureiq.yaml'
$configPath = Join-Path $configDirectory 'local.azureiq.json'
$fakeCliPath = Join-Path $fixtureRoot 'fake az.cmd'
$script:assertions = 0
function Check {
    param([bool]$Value, [string]$Description)
    if (-not $Value) { throw "FAILED: $Description" }
    $script:assertions++
}

$subscription = '00000000-0000-0000-0000-000000000001'
$configuration = @{
    schemaVersion = 1
    scope = @{ tenantId = '00000000-0000-0000-0000-000000000002'; subscriptionIds = @($subscription) }
    identity = @{ apimVnetReaderPrincipal = 'example-reader' }
}
$account = @{ tenantId = $configuration.scope.tenantId; id = $subscription; environmentName = 'AzureCloud'; state = 'Enabled'; user = @{ name = 'example-reader' } }
$baseId = "/subscriptions/$subscription/resourceGroups/example/providers"
$serviceId = "$baseId/Microsoft.ApiManagement/service/example"
$vnetId = "$baseId/Microsoft.Network/virtualNetworks/example"
$subnetId = "$vnetId/subnets/apim"
$nsgId = "$baseId/Microsoft.Network/networkSecurityGroups/example"
$routesId = "$baseId/Microsoft.Network/routeTables/example"
$responses = @{
    (Get-ApimReadUri $serviceId $subscription) = @{
        id = $serviceId; location = 'eastus'; sku = @{ name = 'Premium'; capacity = 1 }
        properties = @{ virtualNetworkType = 'Internal'; virtualNetworkConfiguration = @{ subnetResourceId = $subnetId }; additionalLocations = @() }
    }
    (Get-ApimReadUri $subnetId $subscription) = @{
        id = $subnetId; properties = @{
            addressPrefix = '10.0.0.0/24'; delegations = @()
            networkSecurityGroup = @{ id = $nsgId }; routeTable = @{ id = $routesId }
        }
    }
    (Get-ApimReadUri $vnetId $subscription) = @{ id = $vnetId; location = 'eastus'; properties = @{ dhcpOptions = @{ dnsServers = @() } } }
    (Get-ApimReadUri $nsgId $subscription) = @{ id = $nsgId; properties = @{ securityRules = @(); defaultSecurityRules = @() } }
    (Get-ApimReadUri $routesId $subscription) = @{ id = $routesId; properties = @{ routes = @() } }
    (Get-ApimReadUri "$serviceId/networkstatus" $subscription) = @(
        @{ location = 'eastus'; networkStatus = @{ connectivityStatus = @() } },
        @{ location = 'westus'; networkStatus = @{ connectivityStatus = @() } }
    )
}
$state = @{
    Account = $account; Responses = $responses; AccountChecks = 0; ResourceReads = 0
    PreviousCommand = ''; MismatchAt = 0; FailedUri = $null; Failure = $null; Writes = 0
}

try {
    "schemaVersion: 1`nsafety:`n  requireExactScope: true`n" | Set-Content -LiteralPath $profilePath -Encoding utf8NoBOM
    $configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    & $module {
        param($State)
        $script:mockState = $State
        function script:Get-Command {
            [CmdletBinding()]
            param([string]$Name)
            return @{ Name = $Name }
        }
        function script:Invoke-ReaderCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show') {
                $script:mockState.AccountChecks++
                $script:mockState.PreviousCommand = 'account'
                $account = $script:mockState.Account.Clone()
                if ($script:mockState.MismatchAt -eq $script:mockState.AccountChecks) {
                    $account.id = '00000000-0000-0000-0000-000000000003'
                }
                return $account
            }
            if ($Arguments[0] -ne 'rest' -or $Arguments[2] -ne 'get' -or
                $Arguments[6] -ne $script:mockState.Account.id) {
                $script:mockState.Writes++
                throw 'UNEXPECTED_COMMAND'
            }
            if ($script:mockState.PreviousCommand -ne 'account') { throw 'MISSING_SCOPE_RECHECK' }
            $script:mockState.PreviousCommand = 'rest'
            $script:mockState.ResourceReads++
            $uri = $Arguments[4]
            if ($uri -eq $script:mockState.FailedUri) { throw $script:mockState.Failure }
            if (-not $script:mockState.Responses.ContainsKey($uri)) { throw 'UNEXPECTED_URI' }
            return $script:mockState.Responses[$uri]
        }
    } $state
    $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $fixtureRoot -ServiceName example -ResourceGroup example
    Check ($state.ResourceReads -eq 6 -and $state.AccountChecks -eq 7) 'Every resource read is preceded by an exact context check'
    Check ($state.Writes -eq 0) 'Only account show and ARM GET commands are issued'
    Check ($snapshot.regions.Count -eq 1 -and $null -ne $snapshot.regions[0].routeTable) 'Subnet references are followed for route evidence'
    Check ($snapshot.nativeNetworkStatus.locations.Count -eq 2) 'Native status bare-array response is preserved'
    $state.FailedUri = Get-ApimReadUri "$serviceId/networkstatus" $subscription
    $state.Failure = 'UNSUPPORTED_OR_BAD_REQUEST'
    $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $fixtureRoot -ServiceName example -ResourceGroup example
    Check (-not $snapshot.nativeNetworkStatus.available -and $snapshot.nativeNetworkStatus.errorCategory -eq $state.Failure) 'Unsupported native API is an explicit gap'
    $state.FailedUri = Get-ApimReadUri $nsgId $subscription
    $state.Failure = 'ACCESS_DENIED'
    $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $fixtureRoot -ServiceName example -ResourceGroup example
    Check ($null -eq $snapshot.regions[0].networkSecurityGroup -and 'NETWORK_RULE_ACCESS_DENIED' -in $snapshot.regions[0].evidenceGaps) 'Denied NSG read preserves attached reference and gap category'
    $service = $responses[(Get-ApimReadUri $serviceId $subscription)]
    $service.sku.name = 'PremiumV2'
    $responses[(Get-ApimReadUri $subnetId $subscription)].properties.delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/hostingEnvironments' } })
    $state.FailedUri = $null
    $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $fixtureRoot -ServiceName example -ResourceGroup example
    $report = Invoke-ApimVnetAssessment $snapshot
    Check ($report.skuFamily -eq 'premium-v2') 'Collected SKU selects Premium v2 rules without user selection'
    $state.AccountChecks = 0
    $state.ResourceReads = 0
    $state.MismatchAt = 3
    $errorCategory = $null
    try { Get-ApimVnetSnapshot -WorkspaceRoot $fixtureRoot -ServiceName example -ResourceGroup example | Out-Null }
    catch { $errorCategory = $_.Exception.Message }
    Check ($errorCategory -eq 'SCOPE_MISMATCH' -and $state.ResourceReads -eq 1) 'Mid-run scope drift stops before the next resource read'
    if ($IsWindows) {
        Import-Module (Join-Path $toolRoot 'ApimVnet.Collector.psm1') -Force
        $module = Get-Module 'ApimVnet.Collector'
        & $module {
            param($Path)
            $script:fakeCliPath = $Path
            function script:Get-Command {
                [CmdletBinding()]
                param([string]$Name, [string]$CommandType)
                return @{ Source = $script:fakeCliPath }
            }
        } $fakeCliPath
        "@echo off`necho {`"ok`":true}`n" | Set-Content -LiteralPath $fakeCliPath -Encoding ascii
        $response = & $module { Invoke-ReaderCli @('account', 'show') }
        Check ($response.ok -eq $true) 'Windows cmd wrapper executes a spaced-path CLI without Azure access'
        "@echo off`necho AuthorizationFailed private-detail 1>&2`nexit /b 1`n" | Set-Content -LiteralPath $fakeCliPath -Encoding ascii
        $errorCategory = $null
        try { & $module { Invoke-ReaderCli @('account', 'show') } | Out-Null } catch { $errorCategory = $_.Exception.Message }
        Check ($errorCategory -eq 'ACCESS_DENIED') 'Native stderr is categorized without exposing private detail'
        $errorCategory = $null
        try { & $module { Invoke-ReaderCli @('account', 'show', '%PATH%') } | Out-Null } catch { $errorCategory = $_.Exception.Message }
        Check ($errorCategory -eq 'CLI_ARGUMENT_NOT_ALLOWED') 'Windows shell expansion is rejected before process execution'
    }
} finally {
    Import-Module (Join-Path $toolRoot 'ApimVnet.Collector.psm1') -Force
    Remove-Item -LiteralPath $profilePath, $configPath
    Remove-Item -LiteralPath $configDirectory
    if (Test-Path -LiteralPath $fakeCliPath) { Remove-Item -LiteralPath $fakeCliPath }
    Remove-Item -LiteralPath $fixtureRoot
}
[pscustomobject]@{ Status = 'PASS'; Assertions = $script:assertions; AzureCalls = 0; Collector = 'mocked' }
