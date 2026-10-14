#Requires -Version 7.4
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'ApimVnet.Rules.psm1') -Force
Import-Module (Join-Path $toolRoot 'ApimVnet.Collector.psm1') -Force
$now = [datetimeoffset]'2026-10-14T12:00:00Z'
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -like "*$Expected*") "Expected error category: $Expected"
}

function New-Rule {
    param([string]$Direction = 'Outbound', [string]$Access = 'Allow', [int]$Priority = 100, [string]$Destination = '*', [string]$Port = '*')
    return @{ properties = @{
        priority = $Priority; direction = $Direction; access = $Access; protocol = '*'
        sourceAddressPrefix = '*'; destinationAddressPrefix = $Destination
        sourcePortRange = '*'; destinationPortRange = $Port
    } }
}

function New-Snapshot {
    param([string]$Sku = 'Premium', [string]$Mode = 'Internal', [string]$Prefix = '10.0.0.0/24')
    $subscription = '00000000-0000-0000-0000-000000000001'
    $subnet = "/subscriptions/$subscription/resourceGroups/example/providers/Microsoft.Network/virtualNetworks/example/subnets/apim"
    $delegations = if ($Sku -eq 'PremiumV2') { @(@{ properties = @{ serviceName = 'Microsoft.Web/hostingEnvironments' } }) } else { @() }
    return @{
        schemaVersion = 1; capturedAt = $now.ToString('o')
        service = @{
            id = "/subscriptions/$subscription/resourceGroups/example/providers/Microsoft.ApiManagement/service/example"
            location = 'eastus'; sku = @{ name = $Sku; capacity = 1 }
            properties = @{ virtualNetworkType = $Mode; additionalLocations = @(); virtualNetworkConfiguration = @{ subnetResourceId = $subnet } }
        }
        regions = @(@{
            location = 'eastus'; capacity = 1; evidenceGaps = @()
            virtualNetwork = @{ location = 'eastus'; properties = @{ dhcpOptions = @{ dnsServers = @() } } }
            subnet = @{ id = $subnet; properties = @{ addressPrefix = $Prefix; delegations = $delegations; networkSecurityGroup = @{ id = "/subscriptions/$subscription/resourceGroups/example/providers/Microsoft.Network/networkSecurityGroups/example" } } }
            networkSecurityGroup = @{ properties = @{ securityRules = @((New-Rule), (New-Rule -Direction Inbound)); defaultSecurityRules = @() } }
            routeTable = $null
        })
        nativeNetworkStatus = @{ available = $true; locations = @(@{ location = 'eastus'; networkStatus = @{
            connectivityStatus = @(@{ status = 'success'; isOptional = $false; lastUpdated = $now.ToString('o'); name = 'private-hostname.example.invalid'; error = 'private raw detail' })
        } }) }
    }
}

function Assess { param($Snapshot) return Invoke-ApimVnetAssessment $Snapshot -Now $now }
function Finding { param($Report, [string]$Id) return ,@($Report.findings | Where-Object ruleId -eq $Id) }

$classic = Assess (New-Snapshot)
Assert-True ($classic.skuFamily -eq 'classic') 'Classic SKU discovery'
Assert-True ((Finding $classic 'delegation')[0].status -eq 'Pass') 'Classic empty delegation is valid'
Assert-True ($classic.summary.failed -eq 0 -and $classic.result -eq 'INCONCLUSIVE') 'Configuration pass never claims traffic healthy'
$v2 = Assess (New-Snapshot -Sku PremiumV2)
Assert-True ($v2.skuFamily -eq 'premium-v2' -and (Finding $v2 'delegation')[0].status -eq 'Pass') 'Premium v2 discovery and delegation'
Assert-True (@($v2.findings | Where-Object ruleId -like 'nsg-management*').Count -eq 0) 'Do not impose classic management port on Premium v2'
Assert-True ((Finding $v2 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Pass') 'Premium v2 Key Vault rule'
$snapshot = New-Snapshot -Sku Developer
$developer = Assess $snapshot
Assert-True (@($developer.findings | Where-Object ruleId -like 'nsg-load-balancer*').Count -eq 0) 'Developer load-balancer exception'
$snapshot.regions[0].subnet.properties.delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/hostingEnvironments' } })
Assert-True ((Finding (Assess $snapshot) 'delegation')[0].status -eq 'Fail') 'Classic rejects delegation'
$snapshot = New-Snapshot -Sku PremiumV2
$snapshot.regions[0].subnet.properties.delegations = @()
Assert-True ((Finding (Assess $snapshot) 'delegation')[0].status -eq 'Fail') 'Premium v2 requires delegation'
Assert-True ((Finding (Assess (New-Snapshot -Prefix '10.0.0.0/29')) 'subnet-size')[0].status -eq 'Pass') 'Classic /29 supported'
Assert-True ((Finding (Assess (New-Snapshot -Sku PremiumV2 -Prefix '10.0.0.0/28')) 'subnet-size')[0].status -eq 'Fail') 'Premium v2 /28 rejected'
Assert-True ((Finding (Assess (New-Snapshot -Prefix '10.0.0.0/30')) 'subnet-size')[0].status -eq 'Fail') 'Classic /30 rejected'
$snapshot = New-Snapshot -Prefix '10.0.0.0/29'
$snapshot.service.sku.capacity = 2
$snapshot.regions[0].capacity = 2
Assert-True ((Finding (Assess $snapshot) 'subnet-capacity')[0].status -eq 'Fail') 'Configured units must fit prefix'
$snapshot = New-Snapshot
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @(
    (New-Rule -Access Deny -Priority 100 -Port '443'), (New-Rule -Priority 200), (New-Rule -Direction Inbound))
$report = Assess $snapshot
Assert-True ((Finding $report 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Fail') 'Higher-priority deny overrides allow'
Assert-True ((Finding $report 'nsg-sql-regional-1-1433')[0].status -eq 'Pass') 'Unrelated denied port does not block SQL'
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @((New-Rule -Port '440-445'), (New-Rule -Direction Inbound))
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Pass') 'Destination port range'
$snapshot.regions[0].networkSecurityGroup.properties.securityRules[0].properties.sourcePortRange = '50000-50001'
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Unknown') 'Restricted source-port coverage is unknown'
$snapshot = New-Snapshot
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @(
    (New-Rule -Access Deny -Destination '10.10.0.0/16'), (New-Rule -Priority 200), (New-Rule -Direction Inbound))
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Unknown') 'Earlier unresolved address overlap prevents false pass'
$snapshot = New-Snapshot
$snapshot.regions[0].networkSecurityGroup.properties.Remove('defaultSecurityRules')
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Unknown') 'Missing default-rule evidence is unknown'
$snapshot = New-Snapshot
$snapshot.regions[0].subnet.properties.Remove('networkSecurityGroup')
Assert-True ((Finding (Assess $snapshot) 'nsg-attachment')[0].status -eq 'Fail') 'No attached NSG fails'
$snapshot = New-Snapshot
$snapshot.regions[0].networkSecurityGroup = $null
Assert-True ((Finding (Assess $snapshot) 'nsg-attachment')[0].status -eq 'Unknown') 'Unreadable attached NSG is not absent'
$snapshot = New-Snapshot
$snapshot.regions[0].subnet = $null
Assert-True ((Finding (Assess $snapshot) 'subnet-evidence')[0].status -eq 'Unknown') 'Missing subnet is explicit evidence gap'
$snapshot = New-Snapshot
$snapshot.regions[0].virtualNetwork.location = 'westus'
Assert-True ((Finding (Assess $snapshot) 'region-placement')[0].status -eq 'Fail') 'Region mismatch'
$snapshot = New-Snapshot
$snapshot.regions[0].subnet.id = $snapshot.regions[0].subnet.id.Replace('000000000001', '000000000002')
Assert-True ((Finding (Assess $snapshot) 'subscription-placement')[0].status -eq 'Fail') 'Subscription placement mismatch'
$snapshot = New-Snapshot
$snapshot.service.properties.additionalLocations = @(@{ location = 'westus' })
Assert-True ((Finding (Assess $snapshot) 'region-coverage')[0].status -eq 'Unknown') 'Incomplete multi-region evidence'
$snapshot = New-Snapshot
$snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].status = 'failure'
Assert-True ((Finding (Assess $snapshot) 'native-dependency-1')[0].status -eq 'Fail') 'Fresh required native failure'
$snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].isOptional = $true
Assert-True ((Finding (Assess $snapshot) 'native-dependency-1')[0].status -eq 'Unknown') 'Optional native failure is not global service failure'
$snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].isOptional = $false
$snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].lastUpdated = $now.AddMinutes(-31).ToString('o')
Assert-True ((Finding (Assess $snapshot) 'native-dependency-1')[0].status -eq 'Unknown') 'Stale native failure is not current failure'
$snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].status = 'success'
Assert-True ((Finding (Assess $snapshot) 'native-dependency-1')[0].status -eq 'Unknown') 'Stale native success is not current success'
$snapshot = New-Snapshot
$snapshot.nativeNetworkStatus.available = $false
Assert-True ((Finding (Assess $snapshot) 'native-network-status')[0].status -eq 'Unknown') 'Unavailable native API is not success'
$snapshot = New-Snapshot -Sku StandardV2 -Mode External
Assert-True ((Finding (Assess $snapshot) 'network-model')[0].status -eq 'Unknown') 'Integration or unsupported SKU is not treated as classic injection'
$snapshot = New-Snapshot
$snapshot.capturedAt = $now.AddMinutes(-31).ToString('o')
Assert-True ((Finding (Assess $snapshot) 'snapshot-freshness')[0].status -eq 'Unknown') 'Stale snapshot reported'
$snapshot = New-Snapshot
$snapshot.regions[0].virtualNetwork.properties.dhcpOptions.dnsServers = @('10.0.1.4')
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @(
    (New-Rule -Access Deny -Destination '10.0.1.0/24' -Port '53'), (New-Rule -Priority 200), (New-Rule -Direction Inbound))
Assert-True ((Finding (Assess $snapshot) 'custom-dns-Udp')[0].status -eq 'Fail') 'CIDR rule can definitively block custom resolver'
$snapshot.regions[0].routeTable = @{ properties = @{ routes = @(@{ properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'VirtualAppliance' } }) } }
Assert-True ((Finding (Assess $snapshot) 'management-return-path')[0].status -eq 'Unknown') 'Forced tunnel is investigation trigger, not false failure'
$json = $classic | ConvertTo-Json -Depth 30
Assert-True ($json -notmatch 'private-hostname|private raw detail|00000000-|10\.0\.0') 'Report excludes raw hostnames, IDs, IPs and errors'
Assert-Throws { Invoke-ApimVnetAssessment @{ schemaVersion = 2 } } 'Unsupported snapshot'

$config = @{
    scope = @{ tenantId = '00000000-0000-0000-0000-000000000002'; subscriptionIds = @('00000000-0000-0000-0000-000000000001') }
    identity = @{ apimVnetReaderPrincipal = 'example-reader' }
}
$account = @{ tenantId = $config.scope.tenantId; id = $config.scope.subscriptionIds[0]; environmentName = 'AzureCloud'; state = 'Enabled'; user = @{ name = 'example-reader' } }
Assert-ApimReaderContext $config $account
$script:checks++
$account.id = '00000000-0000-0000-0000-000000000003'
Assert-Throws { Assert-ApimReaderContext $config $account } 'SCOPE_MISMATCH'
$account.id = $config.scope.subscriptionIds[0]
$account.user.name = 'different-reader'
Assert-Throws { Assert-ApimReaderContext $config $account } 'PRINCIPAL_MISMATCH'
$account.user.name = 'example-reader'
$account.environmentName = 'AzureUSGovernment'
Assert-Throws { Assert-ApimReaderContext $config $account } 'UNSUPPORTED_CLOUD'
$config.scope.subscriptionIds += '00000000-0000-0000-0000-000000000003'
Assert-Throws { Assert-ApimReaderContext $config $account } 'EXACT_PRIVATE_SCOPE'
$subscription = '00000000-0000-0000-0000-000000000001'
$id = "/subscriptions/$subscription/resourceGroups/example/providers/Microsoft.ApiManagement/service/example/networkstatus"
Assert-True ((Get-ApimReadUri $id $subscription) -match '/networkstatus\?api-version=2024-05-01$') 'Native API URI is GET allowlisted'
Assert-Throws { Get-ApimReadUri ($id -replace '/networkstatus$', '/listSecrets') $subscription } 'RESOURCE_PATH_NOT_ALLOWED'
Assert-Throws { Get-ApimReadUri ($id.Replace('000000000001', '000000000002')) $subscription } 'CROSS_SUBSCRIPTION_READ_DENIED'
Assert-Throws { Get-ApimReadUri 'https://attacker.example.invalid/' $subscription } 'RESOURCE_PATH_NOT_ALLOWED'

$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $toolRoot '..\..\..\..'))
$testDirectory = Join-Path $workspaceRoot ('.azureiq\tmp\apim-vnet-tests-' + [guid]::NewGuid().ToString('N'))
$fixturePath = Join-Path $testDirectory 'snapshot.json'
$inputPath = Join-Path $testDirectory 'invalid.json'
$null = New-Item -ItemType Directory -Path $testDirectory -Force
$createdRuns = [System.Collections.Generic.List[string]]::new()
try {
    $snapshot = New-Snapshot
    $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
    $output = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -SnapshotPath $fixturePath
    Assert-True ($LASTEXITCODE -eq 3) 'Offline entrypoint returns inconclusive, not healthy'
    $result = ($output -join "`n") | ConvertFrom-Json
    $runDirectory = Split-Path -Parent $result.Report
    $createdRuns.Add($runDirectory)
    Assert-True ($runDirectory.StartsWith((Join-Path $workspaceRoot '.azureiq\runs'), [StringComparison]::OrdinalIgnoreCase)) 'Reports remain in ignored repository run boundary'
    $recordPath = Join-Path $runDirectory 'execution-record.json'
    $record = Get-Content -Raw -LiteralPath $recordPath
    Assert-True ($record | Test-Json -SchemaFile (Join-Path $workspaceRoot 'schemas\execution-record.schema.json')) 'Execution record conforms to repository schema'
    $snapshot.regions[0].subnet.properties.delegations = @(@{ properties = @{ serviceName = 'incorrect' } })
    $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
    $output = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -SnapshotPath $fixturePath
    Assert-True ($LASTEXITCODE -eq 2) 'Offline entrypoint returns issues-found'
    $result = ($output -join "`n") | ConvertFrom-Json
    $createdRuns.Add((Split-Path -Parent $result.Report))
    '{"schemaVersion":2}' | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
    $output = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -SnapshotPath $inputPath 2>&1
    Assert-True ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match 'ASSESSMENT_FAILED') 'Invalid input is explicit, redacted failure'
} finally {
    foreach ($run in $createdRuns) {
        Remove-Item -LiteralPath (Join-Path $run 'report.json'), (Join-Path $run 'execution-record.json') -ErrorAction Stop
        Remove-Item -LiteralPath $run -ErrorAction Stop
    }
    foreach ($file in @($fixturePath, $inputPath)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $testDirectory
}
[pscustomobject]@{ Status = 'PASS'; Assertions = $script:checks; AzureCalls = 0 }
