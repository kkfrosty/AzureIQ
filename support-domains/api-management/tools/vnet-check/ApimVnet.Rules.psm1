#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Field {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return $Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-Field {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Contains($Name) }
    return $null -ne $Value.PSObject.Properties[$Name]
}

function ConvertTo-EvidenceTime {
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) { return [datetimeoffset]$Value.ToUniversalTime() }
    $date = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [ref]$date)) { return $date.ToUniversalTime() }
    return [datetimeoffset]::MinValue
}

function Get-SafeEvidenceCategory {
    param([string]$Category)
    $codes = @('ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED', 'UNSUPPORTED_OR_BAD_REQUEST',
        'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'INVALID_CLI_JSON')
    if ($Category -in $codes -or $Category -in @('SUBNET_REFERENCE_UNAVAILABLE', 'INVALID_NETWORK_REFERENCE')) { return $Category }
    foreach ($prefix in @('SUBNET_', 'VNET_', 'NETWORK_RULE_')) {
        foreach ($code in $codes) {
            if ($Category -eq "$prefix$code") { return $Category }
        }
    }
    return 'UNCLASSIFIED_READ_GAP'
}

function Get-Selectors {
    param($Rule, [string]$Single, [string]$Multiple)
    $plural = @(Get-Field $Rule $Multiple)
    if ($plural.Count -gt 0 -and $null -ne $plural[0]) { return $plural }
    return @(Get-Field $Rule $Single)
}

function Test-AddressSelector {
    param([string]$Selector, [string]$Target)
    if ([string]::IsNullOrWhiteSpace($Selector)) { return 'Unknown' }
    if ($Selector -eq '*' -or $Selector -eq $Target) { return 'Yes' }
    if ($Target -match '^([^.]+)\.' -and $Selector -eq $Matches[1]) { return 'Yes' }
    $targetIp = $null
    $selectorIp = $null
    $targetParts = $Target.Split('/')
    if ([System.Net.IPAddress]::TryParse($targetParts[0], [ref]$targetIp)) {
        $targetPrefix = $targetIp.GetAddressBytes().Length * 8
        if ($targetParts.Length -gt 1 -and ($targetParts.Length -ne 2 -or
            -not [int]::TryParse($targetParts[1], [ref]$targetPrefix) -or
            $targetPrefix -lt 0 -or $targetPrefix -gt $targetIp.GetAddressBytes().Length * 8)) { return 'Unknown' }
        $parts = $Selector.Split('/')
        if ([System.Net.IPAddress]::TryParse($parts[0], [ref]$selectorIp)) {
            if ($targetIp.AddressFamily -ne $selectorIp.AddressFamily) { return 'No' }
            if ($parts.Length -eq 1) {
                $parts = @($parts[0], [string]($selectorIp.GetAddressBytes().Length * 8))
            }
            $prefix = 0
            $bytes = $targetIp.GetAddressBytes()
            if ($parts.Length -ne 2 -or -not [int]::TryParse($parts[1], [ref]$prefix) -or
                $prefix -lt 0 -or $prefix -gt $bytes.Length * 8) { return 'Unknown' }
            $networkBytes = $selectorIp.GetAddressBytes()
            for ($bit = 0; $bit -lt [Math]::Min($prefix, $targetPrefix); $bit++) {
                $mask = 1 -shl (7 - ($bit % 8))
                $index = [int][Math]::Floor($bit / 8)
                if (($bytes[$index] -band $mask) -ne ($networkBytes[$index] -band $mask)) { return 'No' }
            }
            if ($prefix -le $targetPrefix) { return 'Yes' }
            return 'Unknown'
        }
        return 'Unknown'
    }
    if ($Selector -eq 'VirtualNetwork' -and $Target -ne 'VirtualNetwork') { return 'Unknown' }
    if ($Selector -eq 'Internet' -and $Target -ne 'Internet') { return 'Unknown' }
    if ($Selector -match '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)?$' -and
        $Target -match '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)?$') {
        # Distinct service tags can overlap. Without resolved prefixes, neither disjointness nor coverage is proven.
        return 'Unknown'
    }
    return 'Unknown'
}

function Test-AddressSet {
    param([object[]]$Selectors, [string]$Target, [object[]]$SubnetPrefixes = @())
    if ($Target -eq 'VirtualNetwork' -and $SubnetPrefixes.Count -gt 0) {
        if ('VirtualNetwork' -in $Selectors -or '*' -in $Selectors) { return 'Yes' }
        $matches = @($SubnetPrefixes | ForEach-Object { Test-AddressSet $Selectors ([string]$_) })
        if (@($matches | Where-Object { $_ -ne 'Yes' }).Count -eq 0) { return 'Yes' }
        if (@($matches | Where-Object { $_ -ne 'No' }).Count -eq 0) { return 'No' }
        return 'Unknown'
    }
    $unknown = $false
    foreach ($selector in $Selectors) {
        $match = Test-AddressSelector ([string]$selector) $Target
        if ($match -eq 'Yes') { return 'Yes' }
        if ($match -eq 'Unknown') { $unknown = $true }
    }
    if ($unknown -or $Selectors.Count -eq 0) { return 'Unknown' }
    return 'No'
}

function Test-PortSet {
    param([object[]]$Selectors, [int]$Port)
    $unknown = $false
    foreach ($selector in $Selectors) {
        if ($selector -eq '*') { return 'Yes' }
        $text = [string]$selector
        if ($text -match '^\d+$') {
            if ([int]$text -eq $Port) { return 'Yes' }
        } elseif ($text -match '^(\d+)-(\d+)$') {
            if ([int]$Matches[1] -gt [int]$Matches[2]) { $unknown = $true }
            elseif ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return 'Yes' }
        } else { $unknown = $true }
    }
    if ($unknown -or $Selectors.Count -eq 0) { return 'Unknown' }
    return 'No'
}

function Get-NsgFlowVerdict {
    param($Nsg, [string]$Direction, [string]$Source, [string]$Destination, [int]$Port, [string]$Protocol, [ref]$Evidence, [object[]]$SubnetPrefixes = @())
    $evaluation = @{ reason = 'MissingRuleEvidence'; priority = $null; ruleOrdinal = $null; access = $null }
    if ($null -ne $Evidence) { $Evidence.Value = $evaluation }
    $properties = Get-Field $Nsg 'properties'
    if ($null -eq $properties) { return 'Unknown' }
    $custom = Get-Field $properties 'securityRules'
    $defaults = Get-Field $properties 'defaultSecurityRules'
    if (-not (Test-Field $properties 'securityRules') -or -not (Test-Field $properties 'defaultSecurityRules')) { return 'Unknown' }
    $rules = @(@($custom) + @($defaults) | Where-Object { $null -ne $_ } |
        Sort-Object { Get-Field (Get-Field $_ 'properties') 'priority' })
    $priorities = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($rule in $rules) {
        $p = Get-Field $rule 'properties'
        $priority = 0
        if (-not [int]::TryParse([string](Get-Field $p 'priority'), [ref]$priority) -or
            $priority -lt 100 -or $priority -gt 65500 -or
            (Get-Field $p 'direction') -notin @('Inbound', 'Outbound') -or
            (Get-Field $p 'access') -notin @('Allow', 'Deny')) { $evaluation.reason = 'MalformedRule'; return 'Unknown' }
        # NSGs allow the same priority in opposite directions, but not duplicate priorities within a direction.
        if ((Get-Field $p 'direction') -eq $Direction -and -not $priorities.Add($priority)) { $evaluation.reason = 'DuplicatePriority'; return 'Unknown' }
    }
    $uncertainPrecedence = $false
    $uncertainAccess = $null
    $ordinal = 0
    foreach ($rule in $rules) {
        $ordinal++
        $p = Get-Field $rule 'properties'
        if ((Get-Field $p 'direction') -ne $Direction) { continue }
        $ruleProtocol = Get-Field $p 'protocol'
        if ($null -eq $ruleProtocol) { $evaluation.reason = 'MalformedRule'; return 'Unknown' }
        if ($ruleProtocol -ne '*' -and $ruleProtocol -ne $Protocol) { continue }
        $destinationPort = Test-PortSet @(Get-Selectors $p 'destinationPortRange' 'destinationPortRanges') $Port
        if ($destinationPort -eq 'No') { continue }
        $sourceMatch = Test-AddressSet @(Get-Selectors $p 'sourceAddressPrefix' 'sourceAddressPrefixes') $Source $SubnetPrefixes
        $destinationMatch = Test-AddressSet @(Get-Selectors $p 'destinationAddressPrefix' 'destinationAddressPrefixes') $Destination $SubnetPrefixes
        if ($sourceMatch -eq 'No' -or $destinationMatch -eq 'No') { continue }
        $sourcePorts = @(Get-Selectors $p 'sourcePortRange' 'sourcePortRanges')
        $allSourcePorts = '*' -in $sourcePorts -or '0-65535' -in $sourcePorts
        $hasAsg = @(Get-Field $p 'sourceApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0 -or
            @(Get-Field $p 'destinationApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0
        if ($sourceMatch -eq 'Unknown' -or $destinationMatch -eq 'Unknown' -or
            $destinationPort -eq 'Unknown' -or -not $allSourcePorts -or $hasAsg) {
            if (-not $uncertainPrecedence) {
                $evaluation.reason = 'AmbiguousEarlierMatch'
                $evaluation.priority = [int](Get-Field $p 'priority')
                $evaluation.ruleOrdinal = $ordinal
            }
            $access = Get-Field $p 'access'
            $uncertainAccess = if ($null -eq $uncertainAccess) { $access } elseif ($uncertainAccess -eq $access) { $access } else { 'Mixed' }
            $uncertainPrecedence = $true
            continue
        }
        if ($uncertainPrecedence -and $uncertainAccess -ne (Get-Field $p 'access')) { return 'Unknown' }
        $evaluation.priority = [int](Get-Field $p 'priority')
        $evaluation.ruleOrdinal = $ordinal
        $evaluation.access = Get-Field $p 'access'
        switch (Get-Field $p 'access') {
            'Allow' { $evaluation.reason = $(if ($uncertainPrecedence) { 'AllowedByConsistentRules' } else { 'AllowedByRule' }); return 'Pass' }
            'Deny' { $evaluation.reason = $(if ($uncertainPrecedence) { 'DeniedByConsistentRules' } else { 'DeniedByRule' }); return 'Fail' }
            default { return 'Unknown' }
        }
    }
    if (-not $uncertainPrecedence) { $evaluation.reason = 'NoDecisiveRule' }
    return 'Unknown'
}

function Get-ApimVnetTargetOverview {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Report, [switch]$IncludePrivateDetails)
    function Resource-Name {
        param($Resource, [string]$Type)
        $id = [string](Get-Field $Resource 'id')
        if ($id -match "/$Type/([^/]+)$") { return $Matches[1] }
        return Get-Field $Resource 'name'
    }
    function Portal-Link {
        param($Resource)
        $id = [string](Get-Field $Resource 'id')
        if ($id -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.(ApiManagement/service/[A-Za-z0-9-]+|Network/(virtualNetworks/[A-Za-z0-9_.-]+(?:/subnets/[A-Za-z0-9_.-]+)?|networkSecurityGroups/[A-Za-z0-9_.-]+|routeTables/[A-Za-z0-9_.-]+))$') { return $null }
        return "https://portal.azure.com/#resource$id/overview"
    }
    $service = Get-Field $Snapshot 'service'
    $sku = Get-Field $service 'sku'
    $properties = Get-Field $service 'properties'
    $locations = @(@{ virtualNetworkConfiguration = Get-Field $properties 'virtualNetworkConfiguration' })
    $locations += @(Get-Field $properties 'additionalLocations' | Where-Object { $null -ne $_ })
    $references = @($locations | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-Field (Get-Field $_ 'virtualNetworkConfiguration') 'subnetResourceId'))
    })
    $supported = ($Report.skuFamily -eq 'classic' -and $Report.networkMode -in @('Internal', 'External')) -or
        ($Report.skuFamily -eq 'premium-v2' -and $Report.networkMode -eq 'Internal')
    $injection = if ($Report.networkMode -eq 'None') { 'Not VNet-injected; injection-specific checks skipped' }
        elseif (-not $supported) { 'Unsupported SKU or network model; injection-specific checks skipped' }
        elseif ($references.Count -ne $locations.Count) { 'Injection configured; subnet references incomplete' }
        else { 'Injection configured with subnet references for every service location; connectivity not verified' }
    $overview = [ordered]@{
        privateDetails = [bool]$IncludePrivateDetails
        skuName = Get-Field $sku 'name'; capacity = Get-Field $sku 'capacity'
        primaryRegion = Get-Field $service 'location'; provisioningState = Get-Field $properties 'provisioningState'
        networkMode = $Report.networkMode; injection = $injection
        selectedRules = $(if ($supported) { $Report.skuFamily } else { 'None: supported injection not detected' })
        regions = @(
            foreach ($region in @(Get-Field $Snapshot 'regions' | Where-Object { $null -ne $_ })) {
                $subnet = Get-Field $region 'subnet'
                $subnetProperties = Get-Field $subnet 'properties'
                $vnet = Get-Field $region 'virtualNetwork'
                $vnetProperties = Get-Field $vnet 'properties'
                $prefixes = @(Get-Selectors $subnetProperties 'addressPrefix' 'addressPrefixes' | Where-Object { $null -ne $_ })
                $nsg = Get-Field $subnetProperties 'networkSecurityGroup'
                $route = Get-Field $subnetProperties 'routeTable'
                $dhcp = Get-Field $vnetProperties 'dhcpOptions'
                $dnsServers = @(Get-Field $dhcp 'dnsServers' | Where-Object { $null -ne $_ })
                $item = [ordered]@{
                    location = Get-Field $region 'location'; capacity = Get-Field $region 'capacity'
                    vnetRegion = Get-Field $vnet 'location'
                    subnetEvidence = $(if ($null -eq $subnetProperties) { 'Unavailable' } else { 'Collected' })
                    nsgAttachment = $(if ($null -eq $subnetProperties) { 'Unknown' } elseif ($null -eq $nsg) { 'None' } else { 'Attached' })
                    routeTableAttachment = $(if ($null -eq $subnetProperties) { 'Unknown' } elseif ($null -eq $route) { 'None' } else { 'Attached' })
                    dnsMode = $(if ($null -eq $vnetProperties) { 'Unknown: VNet configuration not collected' } elseif ($dnsServers.Count -gt 0) { 'Custom DNS servers configured' } else { 'No custom DNS servers returned; Azure-provided DNS default. Actual resolution untested' })
                    prefixSizes = @($prefixes | ForEach-Object { if ([string]$_ -match '/(\d{1,3})$') { "/$($Matches[1])" } })
                    evidenceGaps = @(Get-Field $region 'evidenceGaps' | Where-Object { $null -ne $_ } | ForEach-Object { Get-SafeEvidenceCategory ([string]$_) })
                }
                if ($IncludePrivateDetails) {
                    $item.portalLinks = @{
                        vnet = Portal-Link $vnet; subnet = Portal-Link $subnet
                        nsg = Portal-Link (Get-Field $region 'networkSecurityGroup')
                        routeTable = Portal-Link (Get-Field $region 'routeTable')
                    }
                    $item.vnetName = Resource-Name $vnet 'virtualNetworks'
                    $item.subnetName = Resource-Name $subnet 'subnets'
                    $item.nsgName = Resource-Name $nsg 'networkSecurityGroups'
                    $item.routeTableName = Resource-Name $route 'routeTables'
                    $item.vnetAddressSpaces = @(Get-Field (Get-Field $vnetProperties 'addressSpace') 'addressPrefixes' | Where-Object { $null -ne $_ })
                    $item.subnetPrefixes = $prefixes
                    $item.dnsServers = $dnsServers
                    $item.serviceEndpoints = @(
                        foreach ($endpoint in @(Get-Field $subnetProperties 'serviceEndpoints' | Where-Object { $null -ne $_ })) {
                            @{ service = Get-Field $endpoint 'service'; provisioningState = Get-Field $endpoint 'provisioningState'; locations = @(Get-Field $endpoint 'locations') }
                        }
                    )
                    $item.routes = @(
                        foreach ($entry in @(Get-Field (Get-Field (Get-Field $region 'routeTable') 'properties') 'routes' | Where-Object { $null -ne $_ })) {
                            $p = Get-Field $entry 'properties'
                            @{ name = Get-Field $entry 'name'; addressPrefix = Get-Field $p 'addressPrefix'; nextHopType = Get-Field $p 'nextHopType'; nextHopIpAddress = Get-Field $p 'nextHopIpAddress'; provisioningState = Get-Field $p 'provisioningState' }
                        }
                    )
                    $item.bgpRoutePropagationDisabled = Get-Field (Get-Field (Get-Field $region 'routeTable') 'properties') 'disableBgpRoutePropagation'
                    $item.nsgRules = @(
                        $ruleSets = @(
                            @{ type = 'Custom'; entries = Get-Field (Get-Field (Get-Field $region 'networkSecurityGroup') 'properties') 'securityRules' },
                            @{ type = 'Default'; entries = Get-Field (Get-Field (Get-Field $region 'networkSecurityGroup') 'properties') 'defaultSecurityRules' }
                        )
                        foreach ($set in $ruleSets) {
                            foreach ($entry in @($set.entries | Where-Object { $null -ne $_ })) {
                                $p = Get-Field $entry 'properties'
                                @{
                                    name = Get-Field $entry 'name'; ruleSet = $set.type; priority = Get-Field $p 'priority'
                                    direction = Get-Field $p 'direction'; access = Get-Field $p 'access'; protocol = Get-Field $p 'protocol'
                                    sourceAddresses = @(Get-Selectors $p 'sourceAddressPrefix' 'sourceAddressPrefixes')
                                    destinationAddresses = @(Get-Selectors $p 'destinationAddressPrefix' 'destinationAddressPrefixes')
                                    sourcePorts = @(Get-Selectors $p 'sourcePortRange' 'sourcePortRanges')
                                    destinationPorts = @(Get-Selectors $p 'destinationPortRange' 'destinationPortRanges')
                                    applicationSecurityGroupsPresent = @(Get-Field $p 'sourceApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0 -or @(Get-Field $p 'destinationApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0
                                }
                            }
                        }
                    )
                }
                $item
            }
        )
    }
    if ($IncludePrivateDetails) {
        $overview.portalLink = Portal-Link $service
        $overview.privateIpAddresses = @(Get-Field $properties 'privateIPAddresses' | Where-Object { $null -ne $_ })
        $overview.publicNetworkAccess = Get-Field $properties 'publicNetworkAccess'
        $overview.serviceName = Resource-Name $service 'service'
        $id = [string](Get-Field $service 'id')
        $overview.resourceGroup = if ($id -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { $null }
    }
    return $overview
}

function Get-ApimVnetToolContract {
    $rules = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'rules.json') | ConvertFrom-Json -AsHashtable
    return [ordered]@{
        tool = 'apim.vnet-check'; version = $rules.version; maturity = $rules.status
        mutatesAzure = $false; generatesApplicationTraffic = $false; checks = 'Implemented configuration rules and available APIM platform observations only; untested coverage is not published as findings'
        entryPoint = 'support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1'
        preflightArguments = @('-Preflight')
        liveArguments = @('-ServiceName <name>', '-ResourceGroup <name>')
        offlineArguments = @('-SnapshotPath <path>')
        scope = 'Ignored private configuration; exact active CLI tenant, selected subscription and principal required'
        outputs = @('report.json', 'report.html', 'execution-record.json')
        outputStorage = @{
            sanitized = 'Ignored .azureiq\runs\RUN-...; no target names or address literals'
            liveOperator = 'Git-ignored workspace .azureiq\private-reports\api-management\vnet-check\RUN-...; target/network metadata, no tenant/subscription/principal IDs or raw payloads'
        }
        exitCodes = @{ '0' = 'Describe or ready preflight only; not service health'; '1' = 'Aborted: inspect safe error and audit record when created'; '2' = 'Assessment completed: issues found'; '3' = 'Assessment completed: inconclusive' }
        sections = @($rules.sections | ForEach-Object { @{ id = $_.id; title = $_.title; coverage = $_.coverage } })
    }
}

function Invoke-ApimVnetAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
        [ValidateRange(1, 1440)][int]$MaxStatusAgeMinutes = 30
    )
    $rules = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'rules.json') | ConvertFrom-Json -AsHashtable
    if ((Get-Field $Snapshot 'schemaVersion') -ne 1) { throw 'Unsupported snapshot schema version.' }
    $service = Get-Field $Snapshot 'service'
    $sku = Get-Field (Get-Field $service 'sku') 'name'
    $serviceProperties = Get-Field $service 'properties'
    $mode = Get-Field $serviceProperties 'virtualNetworkType'
    $capturedAt = ConvertTo-EvidenceTime (Get-Field $Snapshot 'capturedAt')
    if ($null -eq $service -or [string]::IsNullOrWhiteSpace($sku) -or
        [string]::IsNullOrWhiteSpace($mode) -or
        $capturedAt -eq [datetimeoffset]::MinValue) {
        throw 'Snapshot requires service SKU, network mode, and a valid capturedAt timestamp.'
    }
    $family = switch ($sku) {
        'Developer' { 'classic' }
        'Premium' { 'classic' }
        'PremiumV2' { 'premium-v2' }
        default { 'unsupported' }
    }
    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding {
        param([string]$Id, [int]$Region, [string]$Status, [string]$Severity, [string]$Detail, [string]$Source,
            [string]$EvidenceTimestamp = $null, [string]$EvidenceCategory = $null,
            [string]$Expected = $null, [string]$Observed = $null, [string]$NextStep = $null, $NsgEvidence = $null,
            [string]$Title = $null, [string]$Assessment = $null, $DependencyEvidence = $null)
        $findings.Add([ordered]@{
            ruleId = $Id; regionIndex = $Region; status = $Status; severity = $Severity
            detail = $Detail; source = $Source; evidenceTimestamp = $EvidenceTimestamp; evidenceCategory = $EvidenceCategory
            expected = $Expected; observed = $Observed; nextStep = $NextStep; nsgEvidence = $NsgEvidence
            title = $Title; assessment = $Assessment; dependencyEvidence = $DependencyEvidence
        })
    }
    $injected = ($family -eq 'classic' -and $mode -in @('Internal', 'External')) -or
        ($family -eq 'premium-v2' -and $mode -eq 'Internal')
    if (-not $injected) {
        Add-Finding 'network-model' 0 'Unknown' 'Warning' 'This SKU or network mode is not supported injection. Integration, private endpoints, and workspace gateways require separate rules.' $rules.sources.premiumV2
    } else {
        Add-Finding 'network-model' 0 'Pass' 'Info' "Discovered $family injection in $mode mode." $rules.sources.premiumV2
        $regions = @(Get-Field $Snapshot 'regions' | Where-Object { $null -ne $_ })
        if ($regions.Count -eq 0) {
            Add-Finding 'region-evidence' 0 'Unknown' 'Warning' 'No subnet evidence was collected.' $rules.sources.classicSubnet
        }
        $expectedRegions = 1 + @(Get-Field $serviceProperties 'additionalLocations' | Where-Object { $null -ne $_ }).Count
        if ($regions.Count -ne $expectedRegions) {
            Add-Finding 'region-coverage' 0 'Unknown' 'Warning' 'Evidence does not cover every service location.' $rules.sources.classicSubnet
        }
        $regionIndex = 0
        foreach ($region in $regions) {
            $regionIndex++
            $source = if ($family -eq 'classic') { $rules.sources.classicSubnet } else { $rules.sources.premiumV2 }
            foreach ($gap in @(Get-Field $region 'evidenceGaps' | Where-Object { $null -ne $_ })) {
                Add-Finding 'collection-gap' $regionIndex 'Unknown' 'Warning' 'A required configuration read failed or was unavailable; the safe category identifies the evidence gap.' $source -EvidenceCategory (Get-SafeEvidenceCategory ([string]$gap))
            }
            $subnet = Get-Field $region 'subnet'
            $subnetProperties = Get-Field $subnet 'properties'
            $vnet = Get-Field $region 'virtualNetwork'
            if ($null -eq $subnetProperties) {
                Add-Finding 'subnet-evidence' $regionIndex 'Unknown' 'Warning' 'Subnet configuration is unavailable.' $source
                continue
            }
            $vnetRegion = ([string](Get-Field $vnet 'location') -replace '\s', '').ToLowerInvariant()
            $serviceRegion = ([string](Get-Field $region 'location') -replace '\s', '').ToLowerInvariant()
            if (-not $vnetRegion -or -not $serviceRegion) {
                Add-Finding 'region-placement' $regionIndex 'Unknown' 'Warning' 'VNet or service region is unavailable.' $source
            } elseif ($vnetRegion -ne $serviceRegion) {
                Add-Finding 'region-placement' $regionIndex 'Fail' 'Error' 'VNet and service location differ.' $source
            } else {
                Add-Finding 'region-placement' $regionIndex 'Pass' 'Info' 'VNet and service location agree.' $source
            }
            $serviceId = [string](Get-Field $service 'id')
            $subnetId = [string](Get-Field $subnet 'id')
            $serviceSubscription = if ($serviceId -match '^/subscriptions/([^/]+)/') { $Matches[1] } else { $null }
            $subnetSubscription = if ($subnetId -match '^/subscriptions/([^/]+)/') { $Matches[1] } else { $null }
            if (-not $serviceSubscription -or -not $subnetSubscription) {
                Add-Finding 'subscription-placement' $regionIndex 'Unknown' 'Warning' 'Subscription placement cannot be compared.' $source
            } elseif ($serviceSubscription -ne $subnetSubscription) {
                Add-Finding 'subscription-placement' $regionIndex 'Fail' 'Error' 'APIM and subnet subscriptions differ.' $source
            } else {
                Add-Finding 'subscription-placement' $regionIndex 'Pass' 'Info' 'APIM and subnet subscriptions agree.' $source
            }
            $delegations = @(Get-Field $subnetProperties 'delegations' | Where-Object { $null -ne $_ })
            if (-not (Test-Field $subnetProperties 'delegations')) {
                Add-Finding 'delegation' $regionIndex 'Unknown' 'Warning' 'Subnet delegation evidence is unavailable.' $source
            } else {
                $validDelegation = if ($family -eq 'classic') { $delegations.Count -eq 0 } else {
                    $delegations.Count -eq 1 -and
                    (Get-Field (Get-Field $delegations[0] 'properties') 'serviceName') -eq 'Microsoft.Web/hostingEnvironments'
                }
                $status = if ($validDelegation) { 'Pass' } else { 'Fail' }
                Add-Finding 'delegation' $regionIndex $status $(if ($validDelegation) { 'Info' } else { 'Error' }) "Subnet delegation was checked against the $family requirement." $source -Expected $(if ($family -eq 'classic') { 'No subnet delegation' } else { 'Exactly Microsoft.Web/hostingEnvironments delegation' }) -Observed "$($delegations.Count) delegation entries; requirement $status."
            }
            $prefixes = @(Get-Selectors $subnetProperties 'addressPrefix' 'addressPrefixes' | Where-Object { $null -ne $_ })
            $ipv4Prefixes = @($prefixes | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
            if ($ipv4Prefixes.Count -ne 1) {
                Add-Finding 'subnet-size' $regionIndex 'Unknown' 'Warning' 'Exactly one IPv4 subnet prefix is needed for this capacity calculation.' $source
            } else {
                $prefix = [int]($ipv4Prefixes[0].Split('/')[1])
                $maxPrefix = if ($family -eq 'classic') { 29 } else { 27 }
                $ip = $null
                if ($prefix -gt 32 -or -not [System.Net.IPAddress]::TryParse($ipv4Prefixes[0].Split('/')[0], [ref]$ip)) {
                    Add-Finding 'subnet-size' $regionIndex 'Unknown' 'Warning' 'Subnet prefix is malformed.' $source
                } elseif ($prefix -gt $maxPrefix) {
                    Add-Finding 'subnet-size' $regionIndex 'Fail' 'Error' "Subnet is smaller than the documented /$maxPrefix minimum." $source
                } else {
                    Add-Finding 'subnet-size' $regionIndex 'Pass' 'Info' 'Subnet meets the documented minimum prefix size.' $source
                    if ($family -eq 'premium-v2' -and $prefix -gt 24) {
                        Add-Finding 'subnet-growth' $regionIndex 'Unknown' 'Warning' 'Premium v2 recommends /24 for growth; a smaller supported subnet is not itself a fault.' $source
                    }
                    $units = Get-Field $region 'capacity'
                    if ($null -eq $units) { $units = Get-Field (Get-Field $service 'sku') 'capacity' }
                    if ($null -ne $units -and $units -gt 0 -and $family -eq 'classic') {
                        $needed = 5 + $(if ($sku -eq 'Developer') { 1 } else { 2 * [int]$units }) +
                            $(if ($mode -eq 'Internal') { 1 } else { 0 })
                        if ([Math]::Pow(2, 32 - $prefix) -lt $needed) {
                            Add-Finding 'subnet-capacity' $regionIndex 'Fail' 'Error' 'Subnet cannot accommodate Azure reservations and configured APIM units.' $source
                        }
                    }
                    Add-Finding 'free-address-capacity' $regionIndex 'Unknown' 'Warning' 'Prefix size alone does not establish free addresses, dedicated occupancy, or upgrade and scale headroom.' $source
                }
            }
            $nsgReference = Get-Field $subnetProperties 'networkSecurityGroup'
            $nsg = Get-Field $region 'networkSecurityGroup'
            if ($null -eq $nsgReference) {
                Add-Finding 'nsg-attachment' $regionIndex 'Fail' 'Error' 'No NSG is attached to the APIM subnet.' $source
            } elseif ($null -eq $nsg) {
                Add-Finding 'nsg-attachment' $regionIndex 'Unknown' 'Warning' 'An NSG is attached but its rules could not be read.' $source
            } else {
                Add-Finding 'nsg-attachment' $regionIndex 'Pass' 'Info' 'Subnet has a readable NSG.' $source
                foreach ($flow in $rules.flows) {
                    if ($flow.family -ne $family -or
                        ($flow.ContainsKey('mode') -and $flow.mode -ne $mode) -or
                        ($flow.ContainsKey('sku') -and $flow.sku -ne $sku)) { continue }
                    $destinations = @($flow.destination)
                    if ($flow.ContainsKey('regional') -and $flow.regional) {
                        $primaryRegion = ([string](Get-Field $service 'location') -replace '\s', '').ToLowerInvariant()
                        $destinations = @("$($flow.destination).$serviceRegion", "$($flow.destination).$primaryRegion" | Sort-Object -Unique)
                    }
                    $destinationIndex = 0
                    foreach ($destination in $destinations) {
                        $destinationIndex++
                        foreach ($port in $flow.ports) {
                            $nsgEvidence = $null
                            $status = Get-NsgFlowVerdict $nsg $flow.direction $flow.source $destination $port $flow.protocol -Evidence ([ref]$nsgEvidence) -SubnetPrefixes $prefixes
                            $networkSource = if ($family -eq 'classic') { $rules.sources.classicNetwork } else { $rules.sources.premiumV2 }
                            $label = if ($flow.ContainsKey('regional') -and $flow.regional) { "regional-$destinationIndex" } else { $flow.destination }
                            $expectedFlow = "$($flow.direction) $($flow.protocol): $($flow.source) -> $($flow.destination), destination port $port, any source port."
                            $explanation = switch ($nsgEvidence.reason) {
                                'DeniedByRule' { 'Blocked by an NSG deny' }
                                'AllowedByRule' { 'Allowed by an NSG rule' }
                                'AllowedByConsistentRules' { 'All possible earlier matches agree with the guaranteed fallback allow' }
                                'DeniedByConsistentRules' { 'All possible earlier matches agree with the guaranteed fallback deny' }
                                'AmbiguousEarlierMatch' { 'A possible earlier rule match prevents a definitive result' }
                                default { 'Rule evaluation is incomplete or ambiguous' }
                            }
                            $observedFlow = if ($null -ne $nsgEvidence.priority) {
                                "$explanation at priority $($nsgEvidence.priority), ordered rule #$($nsgEvidence.ruleOrdinal). Names and address literals are omitted."
                            } else { "$explanation; no definitive permit or blocking rule could be identified." }
                            Add-Finding "nsg-$($flow.id)-$label-$port" $regionIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) "$($flow.purpose): ordered NSG configuration evaluation, not an end-to-end traffic test." $networkSource -Expected $expectedFlow -Observed $observedFlow -NsgEvidence $nsgEvidence -Title "$($flow.purpose) - $($flow.direction) $($flow.protocol) $port"
                        }
                    }
                }
                $dnsServers = @(Get-Field (Get-Field (Get-Field $vnet 'properties') 'dhcpOptions') 'dnsServers' |
                    Where-Object { $null -ne $_ })
                foreach ($dnsServer in $dnsServers) {
                    $parsedDns = $null
                    if (-not [System.Net.IPAddress]::TryParse([string]$dnsServer, [ref]$parsedDns)) {
                        Add-Finding 'dns-server-format' $regionIndex 'Unknown' 'Warning' 'DNS server address could not be evaluated.' $rules.sources.classicNetwork
                        continue
                    }
                    foreach ($protocol in @('Udp', 'Tcp')) {
                        $status = Get-NsgFlowVerdict $nsg 'Outbound' 'VirtualNetwork' ([string]$dnsServer) 53 $protocol -SubnetPrefixes $prefixes
                        Add-Finding "custom-dns-$protocol" $regionIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) 'Custom resolver port 53 was evaluated without retaining its address. DNS responses and routing still require verification.' $rules.sources.classicNetwork
                    }
                }
            }
            $routeTable = Get-Field $region 'routeTable'
            $routeProperties = Get-Field $routeTable 'properties'
            $routes = @(Get-Field $routeProperties 'routes' | Where-Object { $null -ne $_ })
            $defaultRoutes = @($routes |
                Where-Object { $null -ne $_ -and (Get-Field (Get-Field $_ 'properties') 'addressPrefix') -eq '0.0.0.0/0' })
            $forcedRoutes = @($defaultRoutes | Where-Object {
                (Get-Field (Get-Field $_ 'properties') 'nextHopType') -in @('VirtualAppliance', 'VirtualNetworkGateway')
            })
            $forcedTunnel = $forcedRoutes.Count -gt 0
            $discardDefault = @($defaultRoutes | Where-Object {
                (Get-Field (Get-Field $_ 'properties') 'nextHopType') -eq 'None'
            }).Count -gt 0
            if ($family -eq 'classic') {
                foreach ($endpoint in @('Microsoft.Storage', 'Microsoft.Sql', 'Microsoft.EventHub', 'Microsoft.KeyVault')) {
                    $purpose = switch ($endpoint) {
                        'Microsoft.Storage' { 'core configuration, package and storage dependencies' }
                        'Microsoft.Sql' { 'core configuration database access in the primary region' }
                        'Microsoft.KeyVault' { 'Key Vault service dependencies and certificate/secret access where applicable' }
                        'Microsoft.EventHub' { 'Event Hubs logging when that optional feature is used' }
                    }
                    $expectedEndpoint = "Recommend enabling $endpoint from the start for $purpose. Service-endpoint routes keep this dependency on the Azure backbone and protect it from later default-route/forced-tunnel changes. With forced tunneling, a service endpoint or a verified maintained firewall alternative is required for applicable dependency connectivity."
                    if ($endpoint -eq 'Microsoft.Sql' -and $regionIndex -gt 1) {
                        Add-Finding "service-endpoint-$endpoint" $regionIndex 'NotApplicable' 'Info' 'The classic routing guidance requires the SQL service endpoint recommendation only in the primary region.' $rules.sources.classicRouting -Expected $expectedEndpoint -Observed 'Secondary service location.'
                        continue
                    }
                    $configured = @(Get-Field $subnetProperties 'serviceEndpoints' | Where-Object {
                        $null -ne $_ -and (Get-Field $_ 'service') -eq $endpoint
                    })
                    $endpointStatus = 'Unknown'
                    $endpointObserved = "$endpoint is NOT CONFIGURED. Recommended preventive safeguard is missing; this alone is not proof of an outage."
                    if ($forcedTunnel -and $endpoint -ne 'Microsoft.EventHub') {
                        $endpointStatus = 'Fail'
                        $endpointObserved = "$endpoint is NOT CONFIGURED with a default route to an appliance or virtual network gateway. Required forced-tunnel endpoint safeguard is missing; a verified firewall alternative has not been established by this collector. This configuration gap is not a confirmed outage cause."
                    }
                    if ($configured.Count -gt 0) {
                        $states = @($configured | ForEach-Object { Get-Field $_ 'provisioningState' })
                        if ($states.Count -gt 0 -and @($states | Where-Object { $_ -ne 'Succeeded' }).Count -eq 0) {
                            $endpointStatus = 'Pass'
                            $endpointObserved = 'Matching service endpoint configuration reports Succeeded; destination reachability is not established.'
                        } elseif ('Failed' -in $states) {
                            $endpointStatus = 'Fail'
                            $endpointObserved = 'Matching service endpoint configuration reports provisioning Failed.'
                        } else { $endpointObserved = 'Matching endpoint exists, but successful provisioning is not established.' }
                    }
                    $nextEndpoint = if ($endpoint -eq 'Microsoft.EventHub') {
                        'First establish whether Event Hubs is used; then verify endpoint or firewall routing. Do not require an unused optional feature.'
                    } elseif ($forcedTunnel) {
                        'Propose enabling this endpoint, or document a verified firewall alternative covering the complete dependency IP ranges and future updates. Verify remaining forced-tunneled dependencies separately. Changes require approval.'
                    } else {
                        'Recommend enabling this endpoint proactively before future VNet changes. No forced-tunnel default UDR was observed; BGP/effective routes remain unverified. Changes require approval.'
                    }
                    Add-Finding "service-endpoint-$endpoint" $regionIndex $endpointStatus $(if ($endpointStatus -eq 'Fail') { 'Error' } elseif ($endpointStatus -eq 'Unknown') { 'Warning' } else { 'Info' }) 'Service-endpoint configuration is assessed separately from the NSG and effective network path.' $rules.sources.classicRouting -Expected $expectedEndpoint -Observed $endpointObserved -NextStep $nextEndpoint
                }
            } else {
                Add-Finding 'service-endpoint-classic-guidance' $regionIndex 'NotApplicable' 'Info' 'Do not impose classic forced-tunneling endpoint recommendations on Premium v2 injection.' $rules.sources.premiumV2 -Expected 'Use Premium v2 requirements, including Key Vault egress.' -Observed 'Premium v2 injection was discovered.'
            }
            $detail = if ($discardDefault) {
                'A 0.0.0.0/0 UDR with next hop None is configured. It discards all traffic without a more-specific effective route. Review whether this restriction is intentional; verify dependency service endpoints and ApiManagement Internet return-route safeguards even if this default route is changed or removed. Actual affected flows and BGP exceptions remain unverified.'
            } elseif ($forcedTunnel) {
                'FORCED TUNNEL CONFIGURED: a 0.0.0.0/0 UDR uses VirtualAppliance or VirtualNetworkGateway. Dependency endpoint/firewall safeguards and symmetric control-plane return routing must be verified. This is not proof of an outage.'
            } elseif ($defaultRoutes.Count -gt 0) {
                "A 0.0.0.0/0 UDR is configured with next hop: $(@($defaultRoutes | ForEach-Object { Get-Field (Get-Field $_ 'properties') 'nextHopType' }) -join ', '). An Internet next hop is not forced tunneling; None drops matching traffic. Effective routes remain unverified."
            } elseif ($null -ne (Get-Field $subnetProperties 'routeTable') -and $null -eq $routeProperties) {
                'Route table is attached but unreadable; default routes and forced tunneling cannot be assessed.'
            } else { 'No 0.0.0.0/0 UDR was observed. BGP can still introduce forced tunneling; effective routes, peering and firewall policy remain unverified.' }
            Add-Finding 'effective-routing' $regionIndex $(if ($discardDefault) { 'Fail' } else { 'Unknown' }) $(if ($discardDefault) { 'Error' } else { 'Warning' }) $detail $rules.sources.classicRouting
            if ($family -eq 'classic') {
                $managementRoutes = @($routes | Where-Object { (Get-Field (Get-Field $_ 'properties') 'addressPrefix') -eq 'ApiManagement' })
                $regionalManagementRoutes = @($routes | Where-Object { (Get-Field (Get-Field $_ 'properties') 'addressPrefix') -like 'ApiManagement.*' })
                $returnStatus = 'Unknown'
                $returnObserved = if ($null -eq (Get-Field $subnetProperties 'routeTable')) {
                    'No route table is attached to the APIM subnet, so a dedicated management return route is not configured. This is a preventive recommendation, not proof of a current outage.'
                } else {
                    'The attached route table has no global ApiManagement service-tag route with next hop Internet. This is a preventive recommendation unless the actual default/effective route redirects management replies.'
                }
                if ($managementRoutes.Count -eq 1) {
                    $hop = Get-Field (Get-Field $managementRoutes[0] 'properties') 'nextHopType'
                    $state = Get-Field (Get-Field $managementRoutes[0] 'properties') 'provisioningState'
                    if ($hop -eq 'Internet' -and $state -eq 'Succeeded') {
                        $returnStatus = 'Pass'
                        $returnObserved = 'ApiManagement service-tag UDR -> Internet is configured and provisioned. This protects the classic control-plane return path from a broader default route; effective behavior is still untested.'
                    } elseif ($forcedTunnel -and $hop -ne 'Internet') {
                        $returnStatus = 'Fail'
                        $returnObserved = 'Forced tunneling is configured, but the ApiManagement service-tag UDR does not use Internet as its next hop.'
                    } else { $returnObserved = 'ApiManagement service-tag UDR exists but its Internet next hop and successful provisioning are not both established.' }
                } elseif ($managementRoutes.Count -gt 1) {
                    $returnObserved = 'Multiple ApiManagement service-tag routes were returned; precedence/provisioning requires investigation.'
                } elseif ($regionalManagementRoutes.Count -gt 0) {
                    $returnObserved = 'Regional ApiManagement service-tag routes exist; full control-plane source-region coverage is unverified. Use the global tag or establish complete required coverage.'
                } elseif ($forcedTunnel) {
                    $returnStatus = 'Fail'
                    $returnObserved = 'FORCED TUNNEL CONFIGURED but no ApiManagement service-tag UDR -> Internet exists. The documented symmetric control-plane return-path safeguard is missing; more-specific IP routes and actual connectivity remain unverified.'
                } elseif ($null -ne (Get-Field $subnetProperties 'routeTable') -and $null -eq $routeProperties) {
                    $returnObserved = 'Attached route table could not be read; control-plane return-path safeguard is unknown.'
                }
                Add-Finding 'management-return-path' $regionIndex $returnStatus $(if ($returnStatus -eq 'Fail') { 'Error' } elseif ($returnStatus -eq 'Unknown') { 'Warning' } else { 'Info' }) 'Classic APIM subnet route-table safeguard for management replies; separate from the inbound NSG permit.' $rules.sources.classicRouting -Expected 'Create a route table if none exists, or reuse the attached table; add a user-defined route with destination type Service tag, destination ApiManagement, and next hop Internet. Associate the table with the APIM subnet and preserve existing routes. This keeps replies to classic APIM inbound TCP 3443 management traffic on the Azure return path if future peering with gateway transit/BGP, an appliance or a broader default route would otherwise redirect them. Peering alone does not break management connectivity, and more-specific conflicting routes still need review. This protects management replies, not every client/backend flow; do not apply the classic requirement to Premium v2.' -Observed $returnObserved -NextStep 'Use the linked APIM subnet and route table. Plan adding ApiManagement -> Internet and, if needed, table creation/subnet association as explicit approved operations. Check effective routes and symmetric management replies before and after; do not assume all peering or future route changes are covered.'
            }
            Add-Finding 'dns-resolution' $regionIndex 'Unknown' 'Warning' 'Validate gateway hostnames and backend/dependency resolution from the relevant VNet/client path. Workstation DNS is not APIM DNS evidence.' $(if ($family -eq 'premium-v2') { $rules.sources.premiumV2 } else { $rules.sources.internalDns })
            Add-Finding 'backend-and-client-path' $regionIndex 'Unknown' 'Warning' 'Client ingress, backend TCP/TLS/SNI, firewalls, peering, policies and authentication require separate scoped evidence or approved probes.' $rules.sources.classicNetwork
            Add-Finding 'conditional-dependencies' $regionIndex 'Unknown' 'Warning' 'HTTP ingress, Traffic Manager, caches, rate-limit synchronization, Event Hubs, Entra/credential-manager features, NTP and FQDN-based infrastructure dependencies are not fully evaluated in this version.' $rules.sources.classicNetwork
        }
        $native = Get-Field $Snapshot 'nativeNetworkStatus'
        if ((Get-Field $native 'available') -ne $true) {
            Add-Finding 'native-network-status' 0 'Unknown' 'Warning' 'Native APIM network status is unavailable or unsupported. Absence is not a connectivity success.' $rules.sources.networkStatus -EvidenceCategory (Get-SafeEvidenceCategory ([string](Get-Field $native 'errorCategory')))
        } else {
            $nativeLocations = @(Get-Field $native 'locations' | Where-Object { $null -ne $_ })
            if ($nativeLocations.Count -eq 0) {
                Add-Finding 'native-network-status' 0 'Unknown' 'Warning' 'Native APIM network status returned no locations.' $rules.sources.networkStatus
            }
            $coveredLocations = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($location in $nativeLocations) {
                $nativeLocation = ([string](Get-Field $location 'location') -replace '\s', '').ToLowerInvariant()
                $nativeIndex = 0
                for ($index = 0; $index -lt $regions.Count; $index++) {
                    if (([string](Get-Field $regions[$index] 'location') -replace '\s', '').ToLowerInvariant() -eq $nativeLocation) {
                        $nativeIndex = $index + 1
                        break
                    }
                }
                if ($nativeIndex -eq 0) {
                    Add-Finding 'native-location-coverage' 0 'Unknown' 'Warning' 'Native status cannot be mapped to a captured service location.' $rules.sources.networkStatus
                    continue
                }
                $null = $coveredLocations.Add($nativeIndex)
                $dependencies = @(Get-Field (Get-Field $location 'networkStatus') 'connectivityStatus' |
                    Where-Object { $null -ne $_ })
                if ($dependencies.Count -eq 0) {
                    Add-Finding 'native-network-status' $nativeIndex 'Unknown' 'Warning' 'Native status has no dependency evidence for this location.' $rules.sources.networkStatus
                }
                $dependencyIndex = 0
                foreach ($dependency in $dependencies) {
                    $dependencyIndex++
                    $updated = ConvertTo-EvidenceTime (Get-Field $dependency 'lastUpdated')
                    $fresh = $updated -ne [datetimeoffset]::MinValue -and
                        ($Now - $updated).TotalMinutes -le $MaxStatusAgeMinutes -and ($updated - $Now).TotalMinutes -le 5
                    $optional = Get-Field $dependency 'isOptional'
                    $status = 'Unknown'
                    if ($fresh -and $optional -is [bool]) {
                        if ((Get-Field $dependency 'status') -eq 'success') { $status = 'Pass' }
                        elseif ((Get-Field $dependency 'status') -eq 'failure' -and -not $optional) { $status = 'Fail' }
                    }
                    $timestamp = if ($updated -ne [datetimeoffset]::MinValue) { $updated.ToString('o') } else { $null }
                    $type = Get-Field $dependency 'resourceType'
                    if ($type -notin @('PackageStorage', 'SmtpQueue', 'BlobStorage', 'FileStorage', 'Queue', 'TableStorage', 'SQLDatabase', 'ApplicationInsightsIngestionEndpoint', 'Monitoring', 'AzureKeyVault', 'ApiManagement Control Plane - inbound', 'RegionalAzureActiveDirectory', 'AzureActiveDirectory', 'CaptchaEndpoint', 'Metrics', 'InternalCache', 'SourceControl')) { $type = 'Unclassified dependency' }
                    $nativeStatus = Get-Field $dependency 'status'
                    if ($nativeStatus -notin @('success', 'failure')) { $nativeStatus = 'unrecognized' }
                    $dependencyNames = @{
                        PackageStorage = 'Deployment package storage'; SmtpQueue = 'Email delivery queue'
                        BlobStorage = 'Azure Blob Storage'; FileStorage = 'Azure Files'; Queue = 'Azure Queue Storage'
                        TableStorage = 'Azure Table Storage'; SQLDatabase = 'Azure SQL configuration database'
                        ApplicationInsightsIngestionEndpoint = 'Application Insights ingestion'
                        Monitoring = 'Azure monitoring'; AzureKeyVault = 'Azure Key Vault'
                        'ApiManagement Control Plane - inbound' = 'APIM management endpoint - inbound connectivity'
                        RegionalAzureActiveDirectory = 'Regional Microsoft Entra ID'; AzureActiveDirectory = 'Microsoft Entra ID'
                        CaptchaEndpoint = 'Developer portal CAPTCHA'; Metrics = 'Metrics publishing'
                        InternalCache = 'Internal cache'; SourceControl = 'Built-in source control (optional)'
                    }
                    $dependencyTitle = if ($dependencyNames.ContainsKey($type)) { $dependencyNames[$type] } else { 'Other platform dependency' }
                    $dependencyAssessment = if (-not $fresh -and $updated -ne [datetimeoffset]::MinValue) { 'Stale evidence' }
                        elseif ($status -eq 'Pass') { 'Checked' } elseif ($status -eq 'Fail') { 'Issue' }
                        elseif ($fresh -and $optional -eq $true -and $nativeStatus -eq 'failure') { 'Optional feature issue' }
                        else { 'Needs review' }
                    $dependencyEvidence = @{
                        source = 'APIM platform Network status API (GET /networkstatus, API version 2024-05-01)'
                        resourceType = $type; observedStatus = $nativeStatus; optional = $(if ($optional -is [bool]) { $optional } else { $null })
                        lastUpdated = $timestamp; lastStatusChange = $( $changed = ConvertTo-EvidenceTime (Get-Field $dependency 'lastStatusChange'); if ($changed -ne [datetimeoffset]::MinValue) { $changed.ToString('o') } else { $null } )
                        fresh = $fresh; maximumAgeMinutes = $MaxStatusAgeMinutes
                        errorAvailable = -not [string]::IsNullOrWhiteSpace([string](Get-Field $dependency 'error'))
                    }
                    $nativeObserved = "APIM's platform check reports $nativeStatus. Requirement: $(if ($optional -eq $true) { 'optional feature' } elseif ($optional -eq $false) { 'required dependency' } else { 'requirement not returned' }). Evidence: $(if ($fresh) { 'within the configured age limit' } else { 'not current; do not use this as a current health verdict' })."
                    $nativeExpected = if ($optional -eq $true) { "$dependencyTitle must be reachable when this optional feature is used; failure affects that feature rather than proving a core-service outage." }
                        elseif ($optional -eq $false) { "APIM must report successful connectivity to $dependencyTitle for this required platform dependency." }
                        else { "Establish whether $dependencyTitle is required or optional before interpreting its connectivity result." }
                    $nativeExpected += " Use an observation within $MaxStatusAgeMinutes minutes and no more than five minutes in the future; older status is historical, not current health."
                    $nativeNext = if ($fresh -and $nativeStatus -eq 'success') {
                        'The captured APIM platform check reported success at the stated time; no dependency-specific corrective action is indicated by this observation. It does not certify end-to-end traffic or telemetry delivery.'
                    } else {
                        'Use the collected connection result and timestamp in this report first. If current error details or newer observations are needed, open APIM in Azure Portal > Deployment + infrastructure > Network > Network status and expand the matching dependency. The portal is supplementary; this static report does not trigger a platform recheck.'
                    }
                    Add-Finding "native-dependency-$dependencyIndex" $nativeIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) $nativeObserved $rules.sources.networkStatus $timestamp -Title $dependencyTitle -Assessment $dependencyAssessment -DependencyEvidence $dependencyEvidence -Expected $nativeExpected -NextStep $nativeNext
                }
            }
            if ($coveredLocations.Count -lt $regions.Count) {
                Add-Finding 'native-location-coverage' 0 'Unknown' 'Warning' 'Native status does not cover every captured service location.' $rules.sources.networkStatus
            }
        }
    }
    if (($Now - $capturedAt).TotalMinutes -gt $MaxStatusAgeMinutes -or ($capturedAt - $Now).TotalMinutes -gt 5) {
        Add-Finding 'snapshot-freshness' 0 'Unknown' 'Warning' 'Configuration snapshot is stale or future-dated; findings describe that capture, not current Azure state.' $rules.sources.networkStatus
    }
    $requirements = @{
        'network-model' = 'This checker supports classic Developer/Premium Internal or External VNet injection and Premium v2 Internal injection. Integration, private endpoints and workspace gateways need their own assessment; unsupported here does not mean invalid in Azure.'
        'region-placement' = 'The APIM location and its injected VNet must be in the same Azure region.'
        'subscription-placement' = 'The injected APIM service and subnet must be in the same subscription for this supported injection model.'
        'region-evidence' = 'Collect the injected subnet, VNet, NSG and route-table configuration for the primary APIM location before evaluating its networking.'
        'region-coverage' = 'Collect networking evidence for the primary location and every configured additional APIM location; a partial regional snapshot cannot establish estate-wide results.'
        'collection-gap' = 'Required configuration GETs must complete within the approved reader scope. Resolve the named permission, missing-resource or API read gap before interpreting affected checks.'
        'subnet-evidence' = 'Read the exact subnet referenced by this APIM location, including address prefix, delegation, NSG, route table and service-endpoint configuration.'
        'delegation' = $(if ($family -eq 'classic') { 'The classic APIM subnet must have no delegation.' } else { 'The Premium v2 APIM subnet must have exactly Microsoft.Web/hostingEnvironments delegation.' })
        'subnet-size' = $(if ($family -eq 'classic') { 'Classic Developer/Premium injection needs an IPv4 subnet of /29 or larger; actual free addresses must also support capacity and updates.' } else { 'Premium v2 injection needs an IPv4 subnet of /27 or larger; /24 is recommended for growth.' })
        'subnet-growth' = 'A /24 subnet is recommended for Premium v2 growth; /27 is the supported minimum. A smaller supported subnet is not itself a service failure.'
        'subnet-capacity' = 'The IPv4 subnet must accommodate five Azure-reserved addresses, one Developer address or two addresses per Premium unit, and an additional load-balancer address in Internal mode.'
        'free-address-capacity' = 'Verify actual unallocated IP addresses against configured APIM units, Azure reservations, Internal-mode load-balancer allocation and additional upgrade/scale headroom. Prefix size alone does not prove free capacity.'
        'nsg-attachment' = 'Attach a readable NSG to the injected APIM subnet and permit the specific SKU-required platform flows; attachment alone does not establish that its rules permit them.'
        'dns-server-format' = 'Each configured custom DNS resolver must be a valid IP address reachable from the APIM subnet over both UDP and TCP 53.'
        'effective-routing' = 'Preserve required dependency and management return paths in effective routes. A 0.0.0.0/0 route to None discards traffic lacking a more-specific route; appliance/gateway default routes need verified dependency exceptions and firewall policy. Inspect BGP/system routes as well as UDRs.'
        'dns-resolution' = $(if ($mode -eq 'Internal') { 'Clients must resolve the APIM gateway hostname to the private gateway IP; APIM must resolve backend and Azure dependency names through the configured resolver. Validate answers from the relevant VNet/client path.' } else { 'Clients must resolve the configured gateway hostname to its intended reachable endpoint; APIM must resolve backend and Azure dependency names through the configured resolver. Validate answers from the relevant network path.' })
        'backend-and-client-path' = 'Authorized clients must reach the gateway, and the gateway must reach each intended backend using the configured port, TLS hostname/SNI, certificate trust, authentication and policy. NSG configuration is not an end-to-end test.'
        'conditional-dependencies' = 'First identify enabled optional features, then permit their documented destinations and ports: Event Hubs logging, Traffic Manager, caches, rate-limit synchronization, Entra and credential-manager features. Do not require unused optional features.'
        'native-network-status' = "Read APIM Network status for each applicable service location and preserve dependency requirement, status and original timestamp. Only evidence within $MaxStatusAgeMinutes minutes supports a current dependency verdict; unsupported API responses are evidence gaps."
        'native-location-coverage' = 'Map each Network status result to the corresponding captured APIM location and obtain observations for every injected region before claiming complete dependency coverage.'
        'snapshot-freshness' = "Use a configuration capture no older than $MaxStatusAgeMinutes minutes and no more than five minutes in the future. Historical snapshots describe their capture, not current Azure state."
    }
    foreach ($finding in $findings) {
        $section = @($rules.sections | Where-Object { $finding.ruleId -match $_.pattern })[0]
        $finding.sectionId = $section.id
        if (-not $finding.expected) {
            if ($requirements.ContainsKey($finding.ruleId)) { $finding.expected = $requirements[$finding.ruleId] }
            elseif ($finding.ruleId -like 'custom-dns-*') { $finding.expected = 'Allow APIM-subnet outbound traffic to each configured custom resolver on UDP and TCP destination port 53, with any source port; verify effective routing and DNS replies separately.' }
            else { throw 'RULE_REQUIREMENT_MISSING' }
        }
        if (-not $finding.observed) { $finding.observed = $finding.detail }
        if (-not $finding.nextStep) { $finding.nextStep = $section.nextStep }
    }
    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $rules.sections) {
        $items = @($findings | Where-Object sectionId -eq $definition.id)
        if ($items.Count -eq 0) {
            $reference = if ($family -eq 'premium-v2' -and $definition.id -notin @('native-status', 'evidence')) { $rules.sources.premiumV2 } else { $rules.sources[$definition.source] }
            $coverageStatus = if (-not $injected -and $mode -eq 'None' -and $definition.id -ne 'evidence') { 'NotApplicable' } else { 'Unknown' }
            $coverageDetail = if ($coverageStatus -eq 'NotApplicable') { 'Injection-specific checks skipped because the service network mode is None.' } else { 'This documentation area was not evaluated from the available evidence. It is not a passed test.' }
            $coverageExpected = switch ($definition.id) {
                'discovery' { $requirements['network-model'] }
                'subnet' { "$($requirements['subnet-size']) $($requirements['delegation']) $($requirements['free-address-capacity'])" }
                'nsg' {
                    if ($family -eq 'premium-v2') { 'Attach an NSG and allow Premium v2 Key Vault outbound TCP 443. Do not impose the classic TCP 3443 control-plane rule on Premium v2; assess intended ingress separately.' }
                    else { 'Attach an NSG and evaluate ordered applicable flows: ApiManagement inbound TCP 3443, external HTTPS TCP 443, Premium health probes TCP 6390, and outbound certificate TCP 80, Storage/Key Vault TCP 443, SQL TCP 1433 and Azure Monitor TCP 1886/443. Earlier denies must not block the required flow.' }
                }
                'service-endpoints' { 'For classic injection, recommend Microsoft.Storage, primary-region Microsoft.Sql, Microsoft.KeyVault and Microsoft.EventHub when used. Verify successful endpoint provisioning or an applicable maintained firewall alternative; do not apply classic endpoint requirements to Premium v2.' }
                'routing' { $requirements['effective-routing'] }
                'dns' { $requirements['dns-resolution'] }
                'native-status' { $requirements['native-network-status'] }
                'tls' { 'The configured gateway/backend hostname must match SNI and certificate names; certificates must be unexpired, trusted through their full chain, and able to reach required CRL/OCSP endpoints.' }
                'backends' { $requirements['backend-and-client-path'] }
                'optional-features' { $requirements['conditional-dependencies'] }
                'infrastructure-egress' { 'Allow the SKU-specific NTP, certificate/PKI, diagnostics and other platform FQDN dependencies through the actual egress path. Obtain firewall or platform evidence for paths this tool does not probe.' }
                'evidence' { "Preserve capture time and approved scope, record read gaps, and cover every service region. Do not use observations older than $MaxStatusAgeMinutes minutes as current health evidence." }
                default { throw 'RULE_REQUIREMENT_MISSING' }
            }
            if ($coverageStatus -eq 'NotApplicable') { $coverageExpected = "APIM network mode None is not VNet injection; $($definition.title) injection checks do not apply to this service." }
            Add-Finding "coverage-$($definition.id)" 0 $coverageStatus $(if ($coverageStatus -eq 'NotApplicable') { 'Info' } else { 'Warning' }) $coverageDetail $reference -Expected $coverageExpected -Observed $coverageDetail -NextStep $definition.nextStep
            $findings[$findings.Count - 1].sectionId = $definition.id
            $items = @($findings[$findings.Count - 1])
        }
        $counts = @{
            failed = @($items | Where-Object status -eq 'Fail').Count
            unknown = @($items | Where-Object status -eq 'Unknown').Count
            passed = @($items | Where-Object status -eq 'Pass').Count
            notApplicable = @($items | Where-Object status -eq 'NotApplicable').Count
        }
        $sections.Add(@{
            id = $definition.id; title = $definition.title; coverage = $definition.coverage; counts = $counts
            status = $(if ($counts.failed -gt 0) { 'Fail' } elseif ($counts.unknown -gt 0) { 'Unknown' } elseif ($counts.passed -gt 0) { 'Pass' } else { 'NotApplicable' })
        })
    }
    $titles = @{
        'network-model' = 'APIM tier and VNet connectivity mode'; 'region-placement' = 'APIM and VNet region placement'
        'subscription-placement' = 'APIM and subnet subscription placement'; 'delegation' = 'Subnet delegation'
        'subnet-size' = 'Subnet address range size'; 'subnet-capacity' = 'Subnet capacity for configured units'
        'free-address-capacity' = 'Free IP addresses and upgrade headroom'; 'subnet-evidence' = 'Subnet configuration access'
        'subnet-address-format' = 'Subnet address format'; 'nsg-attachment' = 'Subnet network security group attachment'
        'effective-routing' = 'Default route and effective routing'; 'management-return-path' = 'APIM management return route'
        'dns-resolution' = 'Gateway and dependency DNS resolution'; 'backend-and-client-path' = 'Client and backend connectivity'
        'conditional-dependencies' = 'Optional feature network requirements'; 'snapshot-freshness' = 'Configuration capture freshness'
        'collection-gap' = 'Configuration read unavailable'; 'region-evidence' = 'Regional subnet evidence'
        'region-coverage' = 'Service-region configuration coverage'; 'native-network-status' = 'APIM platform connectivity evidence'
        'native-location-coverage' = 'Platform connectivity coverage by region'; 'dns-server-format' = 'DNS server address format'
    }
    foreach ($finding in $findings) {
        if (-not $finding.title) {
            $finding.title = if ($titles.ContainsKey($finding.ruleId)) { $titles[$finding.ruleId] }
                elseif ($finding.ruleId -like 'service-endpoint-*') { ($finding.ruleId -replace '^service-endpoint-', '') + ' service endpoint' }
                elseif ($finding.ruleId -like 'custom-dns-*') { 'Custom DNS resolver - ' + ($finding.ruleId -replace '^custom-dns-', '') + ' 53' }
                elseif ($finding.ruleId -like 'coverage-*') { (@($rules.sections | Where-Object id -eq $finding.sectionId)[0]).title }
                else { ($finding.ruleId -replace '-', ' ') }
        }
        if (-not $finding.assessment) {
            $finding.assessment = switch ($finding.status) {
                'Fail' { 'Issue' } 'Pass' { 'Checked' } 'NotApplicable' { 'Not applicable' }
                default {
                    if ($finding.ruleId -like 'service-endpoint-*' -and $finding.observed -match 'NOT CONFIGURED') { 'Recommendation' }
                    elseif ($finding.ruleId -eq 'management-return-path' -and $finding.observed -match '^(No route table|The attached route table has no)') { 'Recommendation' }
                    elseif ($finding.ruleId -match '^(coverage-|free-address-capacity|dns-resolution|backend-and-client-path|conditional-dependencies)') { 'Not tested' }
                    elseif ($finding.ruleId -match '^(snapshot-freshness)$') { 'Stale evidence' }
                    elseif ($finding.ruleId -eq 'collection-gap' -or $finding.ruleId -eq 'subnet-evidence') { 'Unavailable evidence' }
                    else { 'Needs review' }
                }
            }
        }
    }
    foreach ($section in $sections) {
        $collected = @($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -ne 'Not tested' })
        if ($collected.Count -eq 0) {
            $section.assessment = 'Not tested'
            continue
        }
        $section.assessment = if ($section.counts.failed -gt 0) { 'Issue' }
            elseif (@($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -eq 'Needs review' }).Count -gt 0) { 'Needs review' }
            elseif (@($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -eq 'Unavailable evidence' }).Count -gt 0) { 'Unavailable evidence' }
            elseif (@($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -eq 'Stale evidence' }).Count -gt 0) { 'Stale evidence' }
            elseif (@($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -eq 'Optional feature issue' }).Count -gt 0) { 'Optional feature issue' }
            elseif (@($findings | Where-Object { $_.sectionId -eq $section.id -and $_.assessment -eq 'Recommendation' }).Count -gt 0) { 'Recommendation' }
            elseif ($section.counts.passed -gt 0) { 'Checked' } else { 'Not applicable' }
    }
    $failed = @($findings | Where-Object status -eq 'Fail').Count
    $unknown = @($findings | Where-Object status -eq 'Unknown').Count
    $report = [ordered]@{
        schemaVersion = 1; toolVersion = $rules.version; maturity = 'candidate'; valueProof = 'unproven'
        assessedAt = $Now.ToString('o'); capturedAt = $capturedAt.ToString('o'); assessmentMode = 'Snapshot'
        skuFamily = $family; networkMode = $(if ($mode -in @('Internal', 'External', 'None')) { $mode } else { 'Unknown' })
        result = $(if ($failed -gt 0) { 'ISSUES_FOUND' } else { 'INCONCLUSIVE' })
        summary = @{ failed = $failed; unknown = $unknown; passed = @($findings | Where-Object status -eq 'Pass').Count; notApplicable = @($findings | Where-Object status -eq 'NotApplicable').Count }
        assessmentSummary = @($findings | Group-Object { $_.assessment } | ForEach-Object { @{ label = $_.Name; count = $_.Count } })
        problemDefinition = 'Assess VNet-injected APIM configuration and dependency observations without changing Azure or generating application traffic.'
        diagnosis = 'Rule results distinguish configuration blockers, native observations and missing evidence. Pass means only that the stated check passed.'
        rootCauseAnalysis = @{ confidence = 'undetermined'; behavior = 'Not classified without service-specific expected behavior and traffic evidence.' }
        findings = $findings.ToArray()
        sections = $sections.ToArray()
    }
    $report.targetOverview = Get-ApimVnetTargetOverview -Snapshot $Snapshot -Report $report
    return $report
}

Export-ModuleMember -Function Invoke-ApimVnetAssessment, Get-ApimVnetToolContract, Get-ApimVnetTargetOverview
