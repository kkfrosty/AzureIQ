#Requires -Version 7.4
[CmdletBinding()]
param([switch]$KeepSampleReport)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'ApimVnet.Rules.psm1') -Force
Import-Module (Join-Path $toolRoot 'ApimVnet.Collector.psm1') -Force
Import-Module (Join-Path $toolRoot 'ApimVnet.Report.psm1') -Force
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
Assert-True ($classic.targetOverview.skuName -eq 'Premium' -and $classic.targetOverview.capacity -eq 1 -and $classic.targetOverview.primaryRegion -eq 'eastus') 'Overview retains exact SKU, capacity and primary region'
Assert-True ($classic.targetOverview.selectedRules -eq 'classic' -and $classic.targetOverview.injection -match 'subnet references for every') 'Overview explains injection applicability and selected rules'
Assert-True ($classic.targetOverview.regions[0].prefixSizes[0] -eq '/24' -and -not $classic.targetOverview.privateDetails) 'Sanitized overview retains prefix sizes, not address literals'
$uninjected = Assess (New-Snapshot -Mode None)
Assert-True ($uninjected.targetOverview.selectedRules -match '^None:' -and $uninjected.targetOverview.injection -match 'Not VNet-injected') 'Noninjected service is clearly identified'
Assert-True (@($uninjected.findings | Where-Object ruleId -like 'nsg-*').Count -eq 0 -and $uninjected.sections.Where({ $_.id -eq 'nsg' })[0].status -eq 'NotApplicable') 'Noninjected service skips NSG injection checks'
$unsupported = Assess (New-Snapshot -Sku StandardV2)
Assert-True ($unsupported.targetOverview.selectedRules -match '^None:' -and $unsupported.summary.unknown -gt 0) 'Unsupported SKU remains inconclusive, not healthy'
$incomplete = New-Snapshot
$incomplete.service.properties.virtualNetworkConfiguration = $null
Assert-True ((Assess $incomplete).targetOverview.injection -match 'references incomplete') 'Configured mode alone is not complete injection evidence'
Assert-True ($classic.skuFamily -eq 'classic') 'Classic SKU discovery'
Assert-True ((Finding $classic 'delegation')[0].status -eq 'Pass') 'Classic empty delegation is valid'
Assert-True ($classic.summary.failed -eq 0 -and $classic.result -eq 'INCONCLUSIVE') 'Configuration pass never claims traffic healthy'
$v2 = Assess (New-Snapshot -Sku PremiumV2)
Assert-True ($v2.targetOverview.skuName -eq 'PremiumV2' -and $v2.targetOverview.selectedRules -eq 'premium-v2') 'Premium v2 overview identifies the exact SKU and separate rules'
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
$snapshot.regions[0].networkSecurityGroup.properties.defaultSecurityRules = $snapshot.regions[0].networkSecurityGroup.properties.securityRules
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @()
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Pass') 'Empty custom-rule array still evaluates defaults'
$snapshot.regions[0].networkSecurityGroup.properties.defaultSecurityRules[0].properties.Remove('priority')
Assert-True ((Finding (Assess $snapshot) 'nsg-key-vault-AzureKeyVault-443')[0].status -eq 'Unknown') 'Malformed priority cannot produce a false verdict'
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
$secondRegion = ($snapshot.regions[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
$secondRegion.location = 'westus'
$secondRegion.virtualNetwork.location = 'westus'
$snapshot.regions += $secondRegion
$snapshot.service.properties.additionalLocations = @(@{ location = 'westus' })
$report = Assess $snapshot
Assert-True (@($report.findings | Where-Object { $_.regionIndex -eq 2 -and $_.ruleId -like 'nsg-storage-regional-*' }).Count -eq 2) 'Secondary region checks both regional and primary dependency tags'
Assert-True ((Finding $report 'native-location-coverage')[0].status -eq 'Unknown') 'Native evidence missing a region is explicit'
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
$snapshot = New-Snapshot
$snapshot.regions[0].evidenceGaps = @('NETWORK_RULE_ACCESS_DENIED', 'PRIVATE_UNTRUSTED_LABEL')
$report = Assess $snapshot
Assert-True ((Finding $report 'collection-gap')[0].evidenceCategory -eq 'NETWORK_RULE_ACCESS_DENIED') 'Permission failures retain safe diagnostic category'
Assert-True ((Finding $report 'collection-gap')[1].evidenceCategory -eq 'UNCLASSIFIED_READ_GAP') 'Unknown raw gap text is not echoed'
Assert-True ($classic.sections.Count -eq 12) 'Every documentation area has a visible section'
Assert-True (@($classic.findings | Where-Object { -not $_.sectionId -or -not $_.expected -or -not $_.observed -or -not $_.nextStep }).Count -eq 0) 'All checks have section, expected, observed and next step'
Assert-True ((Finding $classic 'coverage-tls')[0].status -eq 'Unknown') 'Untested TLS is visible rather than omitted or passed'
Assert-True ((Finding $classic 'coverage-infrastructure-egress')[0].status -eq 'Unknown') 'Untested platform egress is explicit'
$counted = 0
foreach ($section in $classic.sections) {
    $counted += $section.counts.failed + $section.counts.unknown + $section.counts.passed + $section.counts.notApplicable
}
Assert-True ($counted -eq $classic.findings.Count) 'Section totals account for every finding exactly once'
$snapshot = New-Snapshot
$snapshot.regions[0].networkSecurityGroup.properties.securityRules = @(
    (New-Rule -Access Deny -Priority 100 -Port '443'), (New-Rule -Priority 200), (New-Rule -Direction Inbound))
$report = Assess $snapshot
$blocked = (Finding $report 'nsg-key-vault-AzureKeyVault-443')[0]
Assert-True ($blocked.nsgEvidence.priority -eq 100 -and $blocked.nsgEvidence.reason -eq 'DeniedByRule') 'NSG finding identifies the decisive blocking priority'
Assert-True ($blocked.expected -match 'Outbound.*443' -and $blocked.observed -match 'priority 100') 'Required flow and observed blocker are readable'
Assert-True (@($report.sections | Where-Object { $_.id -eq 'nsg' -and $_.status -eq 'Fail' }).Count -eq 1) 'NSG section shows failed aggregate status'
$snapshot.regions[0].subnet.properties.serviceEndpoints = @(
    @{ service = 'Microsoft.Storage'; provisioningState = 'Succeeded' },
    @{ service = 'Microsoft.Sql'; provisioningState = 'Failed' })
$report = Assess $snapshot
Assert-True ((Finding $report 'service-endpoint-Microsoft.Storage')[0].status -eq 'Pass') 'Configured successful service endpoint is checked'
Assert-True ((Finding $report 'service-endpoint-Microsoft.Sql')[0].status -eq 'Fail') 'Failed endpoint provisioning is reported'
Assert-True ((Finding $report 'service-endpoint-Microsoft.KeyVault')[0].status -eq 'Unknown') 'Missing endpoint is not a false fault'
Assert-True ((Finding $report 'service-endpoint-Microsoft.EventHub')[0].nextStep -match 'whether Event Hubs is used') 'Optional feature usage is established before requiring endpoints'
Assert-True ((Finding $v2 'service-endpoint-classic-guidance')[0].status -eq 'NotApplicable') 'Premium v2 does not inherit classic endpoint requirements'
$secondRegion = ($snapshot.regions[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
$secondRegion.location = 'westus'
$secondRegion.virtualNetwork.location = 'westus'
$snapshot.regions += $secondRegion
$snapshot.service.properties.additionalLocations = @(@{ location = 'westus' })
$report = Assess $snapshot
Assert-True (@(Finding $report 'service-endpoint-Microsoft.Sql' | ForEach-Object { $_ } | Where-Object { $_.regionIndex -eq 2 -and $_.status -eq 'NotApplicable' }).Count -eq 1) 'Secondary region SQL endpoint requirement is not imposed'
$html = ConvertTo-ApimVnetHtml $report
Assert-True ($html.IndexOf('Assessment target and network overview') -lt $html.IndexOf('1. Problem Definition') -and $html -match 'Primary capacity / units') 'Target and SKU context precedes diagnostic findings'
Assert-True ($html -match 'OFFLINE / SNAPSHOT - NOT LIVE AZURE EVIDENCE') 'Snapshot preview is prominently distinguished from live evidence'
$privateSnapshot = New-Snapshot
$privateSnapshot.service.name = 'private-apim-example'
$privateSnapshot.service.id = $privateSnapshot.service.id.Replace('/example/providers', '/private-group/providers').Replace('/service/example', '/service/private-apim-example')
$privateSnapshot.regions[0].virtualNetwork.id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/private-group/providers/Microsoft.Network/virtualNetworks/private-vnet"
$privateSnapshot.regions[0].virtualNetwork.properties.addressSpace = @{ addressPrefixes = @('10.42.0.0/16') }
$privateSnapshot.regions[0].virtualNetwork.properties.dhcpOptions.dnsServers = @('10.42.0.4')
$privateAssessment = Assess $privateSnapshot
$overview = Get-ApimVnetTargetOverview -Snapshot $privateSnapshot -Report $privateAssessment -IncludePrivateDetails
Assert-True ($overview.serviceName -eq 'private-apim-example' -and $overview.resourceGroup -eq 'private-group' -and $overview.regions[0].vnetName -eq 'private-vnet' -and $overview.regions[0].subnetName -eq 'apim') 'Private overview projects target and network names without full resource IDs'
Assert-True ($overview.regions[0].vnetAddressSpaces[0] -eq '10.42.0.0/16' -and $overview.regions[0].dnsServers[0] -eq '10.42.0.4') 'Private overview retains approved network settings'
Assert-True (($overview | ConvertTo-Json -Depth 30) -notmatch '00000000-|/subscriptions/|private-hostname|private raw detail') 'Private overview omits scope identifiers, native hostnames and raw errors'
Assert-True (($privateAssessment | ConvertTo-Json -Depth 30) -notmatch 'private-apim-example|private-group|private-vnet|10\.42\.|10\.0\.0\.0|/subscriptions/') 'Sanitized report is unchanged by private projection and does not retain target/address details'
$missingSnapshot = New-Snapshot
$missingSnapshot.regions[0].virtualNetwork = $null
$missingSnapshot.regions[0].subnet = $null
$missingOverview = Get-ApimVnetTargetOverview -Snapshot $missingSnapshot -Report (Assess $missingSnapshot) -IncludePrivateDetails
Assert-True ($null -eq $missingOverview.regions[0].vnetName -and $missingOverview.regions[0].nsgAttachment -eq 'Unknown') 'Unreadable network metadata remains unavailable, not fabricated'
Assert-True ($html -match 'NSG rules' -and $html -match 'Service endpoints' -and $html -match 'priority 100') 'HTML has sectioned actionable evidence'
Assert-True ($html -match 'Content-Security-Policy' -and $html -match "script-src 'sha256-") 'HTML includes a direct script-hash CSP'
$scriptBody = [regex]::Match($html, '(?s)<script>(.*?)</script>').Groups[1].Value.Replace("`r`n", "`n").Replace("`r", "`n")
$scriptHash = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($scriptBody)))
Assert-True ($html.Contains("script-src 'sha256-$scriptHash'")) 'CSP hash matches browser-normalized script text on Windows and Unix'
Assert-True ($html -match '2026-10-14 12:00:00 UTC') 'HTML preserves source timestamps explicitly in UTC'
Assert-True ($html -match 'https://learn.microsoft.com/' -and $html -notmatch 'private-hostname|private raw detail|00000000-') 'HTML retains documentation without private inputs'
$hostileReport = ($report | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
$hostileReport.findings[0].observed = '<img src=x onerror="alert(1)">'
$hostileReport.findings[0].source = 'javascript:alert(1)'
$hostile = ConvertTo-ApimVnetHtml $hostileReport
Assert-True ($hostile -notmatch '<img src=x' -and $hostile -match '&lt;img' -and $hostile -notmatch 'href="javascript:') 'Report text is encoded and unsafe links rejected'
$contract = Get-ApimVnetToolContract
Assert-True ($contract.sections.Count -eq 12 -and 'report.html' -in $contract.outputs -and -not $contract.mutatesAzure) 'Copilot contract describes all sections and read-only outputs'
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
$privateRunDirectory = $null
try {
    $privateRunId = 'RUN-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
    $privateOutput = Write-ApimVnetOperatorReport -Snapshot $privateSnapshot -Report $privateAssessment -RunId $privateRunId -WorkspaceRoot $workspaceRoot
    $privateRunDirectory = Split-Path -Parent $privateOutput.Report
    Assert-True (-not $privateRunDirectory.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) 'Detailed operator reports are persisted outside the repository'
    $operatorJson = Get-Content -Raw -LiteralPath $privateOutput.Report | ConvertFrom-Json -AsHashtable
    $operatorHtml = Get-Content -Raw -LiteralPath $privateOutput.HtmlReport
    Assert-True ($operatorJson.targetOverview.privateDetails -and $operatorHtml -match 'private-apim-example' -and $operatorHtml -match 'private-vnet' -and $operatorHtml -match '10.42.0.0/16') 'Persisted operator report identifies its target and network'
    Assert-True ($operatorHtml -match 'Do not commit or publish' -and $operatorHtml -match 'NOT LIVE AZURE EVIDENCE' -and $operatorHtml -notmatch '00000000-|/subscriptions/') 'Private report retains provenance and scope privacy boundaries'
    Assert-Throws { Write-ApimVnetOperatorReport -Snapshot $privateSnapshot -Report $privateAssessment -RunId $privateRunId -WorkspaceRoot (Split-Path -Parent $privateRunDirectory) } 'PRIVATE_REPORT_INSIDE_WORKSPACE'
    $operatorJson.targetOverview.serviceName = '<img src=x onerror="alert(1)">'
    $operatorJson.assessmentMode = 'Live'
    $operatorHtml = ConvertTo-ApimVnetHtml $operatorJson
    Assert-True ($operatorHtml -match '&lt;img' -and $operatorHtml -notmatch '<img src=x' -and $operatorHtml -match 'LIVE COLLECTION - real Azure configuration reads' -and $operatorHtml -notmatch 'OFFLINE / SNAPSHOT') 'Private target text is escaped and live provenance is distinct'
    $snapshot = New-Snapshot
    $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
    $output = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -SnapshotPath $fixturePath
    Assert-True ($LASTEXITCODE -eq 3) 'Offline entrypoint returns inconclusive, not healthy'
    $result = ($output -join "`n") | ConvertFrom-Json
    $runDirectory = Split-Path -Parent $result.Report
    $createdRuns.Add($runDirectory)
    Assert-True ((Test-Path -LiteralPath $result.HtmlReport) -and $result.Sections.Count -eq 12) 'Entrypoint returns generated HTML and section summaries'
    Assert-True ($runDirectory.StartsWith((Join-Path $workspaceRoot '.azureiq\runs'), [StringComparison]::OrdinalIgnoreCase)) 'Reports remain in ignored repository run boundary'
    $recordPath = Join-Path $runDirectory 'execution-record.json'
    $record = Get-Content -Raw -LiteralPath $recordPath
    Assert-True ($record -notmatch 'private-apim|private-vnet|00000000-' -and ($record | ConvertFrom-Json).privacy.customerIdentifiersStored -eq $false) 'Audit records retain their sanitized privacy contract'
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
    $failure = ($output -join "`n") | ConvertFrom-Json
    $failedRun = Join-Path $workspaceRoot ".azureiq\runs\$($failure.runId)"
    $createdRuns.Add($failedRun)
    $failedRecord = Get-Content -Raw -LiteralPath (Join-Path $failedRun 'execution-record.json')
    Assert-True ($failedRecord | Test-Json -SchemaFile (Join-Path $workspaceRoot 'schemas\execution-record.schema.json')) 'Failure audit record conforms to schema'
    $description = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -Describe
    Assert-True ($LASTEXITCODE -eq 0 -and (($description -join "`n" | ConvertFrom-Json).sections.Count -eq 12)) 'Metadata discovery works without Azure calls'
    $sampleReport = $null
    if ($KeepSampleReport) {
        $snapshot = New-Snapshot
        $snapshot.capturedAt = [datetimeoffset]::UtcNow.ToString('o')
        $snapshot.nativeNetworkStatus.locations[0].networkStatus.connectivityStatus[0].lastUpdated = $snapshot.capturedAt
        $snapshot.regions[0].networkSecurityGroup.properties.securityRules = @(
            (New-Rule -Access Deny -Priority 100 -Port '443'), (New-Rule -Priority 200), (New-Rule -Direction Inbound))
        $snapshot.regions[0].subnet.properties.serviceEndpoints = @(
            @{ service = 'Microsoft.Storage'; provisioningState = 'Succeeded' },
            @{ service = 'Microsoft.Sql'; provisioningState = 'Failed' })
        $snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
        $sample = & pwsh -NoProfile -File (Join-Path $toolRoot 'Test-ApimVnet.ps1') -SnapshotPath $fixturePath
        Assert-True ($LASTEXITCODE -eq 2) 'Synthetic demonstration shows real rule-engine failures, not hand-authored HTML'
        $sampleReport = (($sample -join "`n") | ConvertFrom-Json).HtmlReport
    }
} finally {
    if ($privateRunDirectory) {
        Remove-Item -LiteralPath (Join-Path $privateRunDirectory 'operator-report.json') -ErrorAction Stop
        Remove-Item -LiteralPath (Join-Path $privateRunDirectory 'report.html') -ErrorAction Stop
        Remove-Item -LiteralPath $privateRunDirectory -ErrorAction Stop
    }
    foreach ($run in $createdRuns) {
        $reportPath = Join-Path $run 'report.json'
        if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath }
        $htmlPath = Join-Path $run 'report.html'
        if (Test-Path -LiteralPath $htmlPath) { Remove-Item -LiteralPath $htmlPath }
        Remove-Item -LiteralPath (Join-Path $run 'execution-record.json') -ErrorAction Stop
        Remove-Item -LiteralPath $run -ErrorAction Stop
    }
    foreach ($file in @($fixturePath, $inputPath)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $testDirectory
}
[pscustomobject]@{ Status = 'PASS'; Assertions = $script:checks; AzureCalls = 0; SyntheticSampleHtml = $sampleReport }
