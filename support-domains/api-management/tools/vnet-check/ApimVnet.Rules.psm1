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
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$targetIp)) {
        $parts = $Selector.Split('/')
        if ([System.Net.IPAddress]::TryParse($parts[0], [ref]$selectorIp)) {
            if ($targetIp.AddressFamily -ne $selectorIp.AddressFamily) { return 'No' }
            if ($parts.Length -eq 1) {
                if ($targetIp.Equals($selectorIp)) { return 'Yes' }
                return 'No'
            }
            $prefix = 0
            $bytes = $targetIp.GetAddressBytes()
            if ($parts.Length -ne 2 -or -not [int]::TryParse($parts[1], [ref]$prefix) -or
                $prefix -lt 0 -or $prefix -gt $bytes.Length * 8) { return 'Unknown' }
            $networkBytes = $selectorIp.GetAddressBytes()
            for ($bit = 0; $bit -lt $prefix; $bit++) {
                $mask = 1 -shl (7 - ($bit % 8))
                $index = [int][Math]::Floor($bit / 8)
                if (($bytes[$index] -band $mask) -ne ($networkBytes[$index] -band $mask)) { return 'No' }
            }
            return 'Yes'
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
    param([object[]]$Selectors, [string]$Target)
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
    param($Nsg, [string]$Direction, [string]$Source, [string]$Destination, [int]$Port, [string]$Protocol)
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
            (Get-Field $p 'access') -notin @('Allow', 'Deny')) { return 'Unknown' }
        # NSGs allow the same priority in opposite directions, but not duplicate priorities within a direction.
        if ((Get-Field $p 'direction') -eq $Direction -and -not $priorities.Add($priority)) { return 'Unknown' }
    }
    $uncertainPrecedence = $false
    foreach ($rule in $rules) {
        $p = Get-Field $rule 'properties'
        if ((Get-Field $p 'direction') -ne $Direction) { continue }
        $ruleProtocol = Get-Field $p 'protocol'
        if ($null -eq $ruleProtocol) { $uncertainPrecedence = $true; continue }
        if ($ruleProtocol -ne '*' -and $ruleProtocol -ne $Protocol) { continue }
        $destinationPort = Test-PortSet @(Get-Selectors $p 'destinationPortRange' 'destinationPortRanges') $Port
        if ($destinationPort -eq 'No') { continue }
        $sourceMatch = Test-AddressSet @(Get-Selectors $p 'sourceAddressPrefix' 'sourceAddressPrefixes') $Source
        $destinationMatch = Test-AddressSet @(Get-Selectors $p 'destinationAddressPrefix' 'destinationAddressPrefixes') $Destination
        if ($sourceMatch -eq 'No' -or $destinationMatch -eq 'No') { continue }
        $sourcePorts = @(Get-Selectors $p 'sourcePortRange' 'sourcePortRanges')
        $allSourcePorts = '*' -in $sourcePorts -or '0-65535' -in $sourcePorts
        $hasAsg = @(Get-Field $p 'sourceApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0 -or
            @(Get-Field $p 'destinationApplicationSecurityGroups' | Where-Object { $null -ne $_ }).Count -gt 0
        if ($sourceMatch -eq 'Unknown' -or $destinationMatch -eq 'Unknown' -or
            $destinationPort -eq 'Unknown' -or -not $allSourcePorts -or $hasAsg) {
            $uncertainPrecedence = $true
            continue
        }
        if ($uncertainPrecedence) { return 'Unknown' }
        switch (Get-Field $p 'access') {
            'Allow' { return 'Pass' }
            'Deny' { return 'Fail' }
            default { return 'Unknown' }
        }
    }
    return 'Unknown'
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
    $capturedAt = [datetimeoffset]::MinValue
    if ($null -eq $service -or [string]::IsNullOrWhiteSpace($sku) -or
        [string]::IsNullOrWhiteSpace($mode) -or
        -not [datetimeoffset]::TryParse([string](Get-Field $Snapshot 'capturedAt'), [ref]$capturedAt)) {
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
        param([string]$Id, [int]$Region, [string]$Status, [string]$Severity, [string]$Detail, [string]$Source, [string]$EvidenceTimestamp = $null)
        $findings.Add([ordered]@{
            ruleId = $Id; regionIndex = $Region; status = $Status; severity = $Severity
            detail = $Detail; source = $Source; evidenceTimestamp = $EvidenceTimestamp
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
                Add-Finding 'collection-gap' $regionIndex 'Unknown' 'Warning' 'A required configuration read failed or was unavailable. Review collection diagnostics locally.' $source
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
                Add-Finding 'delegation' $regionIndex $status $(if ($validDelegation) { 'Info' } else { 'Error' }) "Subnet delegation was checked against the $family requirement." $source
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
                            $status = Get-NsgFlowVerdict $nsg $flow.direction $flow.source $destination $port $flow.protocol
                            $networkSource = if ($family -eq 'classic') { $rules.sources.classicNetwork } else { $rules.sources.premiumV2 }
                            $label = if ($flow.ContainsKey('regional') -and $flow.regional) { "regional-$destinationIndex" } else { $flow.destination }
                            Add-Finding "nsg-$($flow.id)-$label-$port" $regionIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) "$($flow.purpose): ordered NSG configuration evaluation, not an end-to-end traffic test." $networkSource
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
                        $status = Get-NsgFlowVerdict $nsg 'Outbound' 'VirtualNetwork' ([string]$dnsServer) 53 $protocol
                        Add-Finding "custom-dns-$protocol" $regionIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) 'Custom resolver port 53 was evaluated without retaining its address. DNS responses and routing still require verification.' $rules.sources.classicNetwork
                    }
                }
            }
            $routeTable = Get-Field $region 'routeTable'
            $defaultRoutes = @(Get-Field (Get-Field $routeTable 'properties') 'routes' |
                Where-Object { $null -ne $_ -and (Get-Field (Get-Field $_ 'properties') 'addressPrefix') -eq '0.0.0.0/0' })
            $detail = if ($defaultRoutes.Count -gt 0) {
                'A default UDR is configured. Check next-hop appliance policy, dependency routes, BGP and asymmetric return paths; a default route alone does not prove failure.'
            } else { 'No default UDR was observed. Effective routes, BGP, peering and firewall policy are not proven by this snapshot.' }
            Add-Finding 'effective-routing' $regionIndex 'Unknown' 'Warning' $detail $rules.sources.classicRouting
            if ($family -eq 'classic' -and $defaultRoutes.Count -gt 0) {
                Add-Finding 'management-return-path' $regionIndex 'Unknown' 'Warning' 'For classic forced tunneling, verify an ApiManagement-to-Internet return route and documented service-endpoint exceptions. Do not apply this classic rule to Premium v2.' $rules.sources.classicRouting
            }
            Add-Finding 'dns-resolution' $regionIndex 'Unknown' 'Warning' 'Validate gateway hostnames and backend/dependency resolution from the relevant VNet/client path. Workstation DNS is not APIM DNS evidence.' $(if ($family -eq 'premium-v2') { $rules.sources.premiumV2 } else { $rules.sources.internalDns })
            Add-Finding 'backend-and-client-path' $regionIndex 'Unknown' 'Warning' 'Client ingress, backend TCP/TLS/SNI, firewalls, peering, policies and authentication require separate scoped evidence or approved probes.' $rules.sources.classicNetwork
            Add-Finding 'conditional-dependencies' $regionIndex 'Unknown' 'Warning' 'HTTP ingress, Traffic Manager, caches, rate-limit synchronization, Event Hubs, Entra/credential-manager features, NTP and FQDN-based infrastructure dependencies are not fully evaluated in this version.' $rules.sources.classicNetwork
        }
        $native = Get-Field $Snapshot 'nativeNetworkStatus'
        if ((Get-Field $native 'available') -ne $true) {
            Add-Finding 'native-network-status' 0 'Unknown' 'Warning' 'Native APIM network status is unavailable or unsupported. Absence is not a connectivity success.' $rules.sources.networkStatus
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
                    $updated = [datetimeoffset]::MinValue
                    $fresh = [datetimeoffset]::TryParse([string](Get-Field $dependency 'lastUpdated'), [ref]$updated) -and
                        ($Now - $updated).TotalMinutes -le $MaxStatusAgeMinutes -and ($updated - $Now).TotalMinutes -le 5
                    $optional = Get-Field $dependency 'isOptional'
                    $status = 'Unknown'
                    if ($fresh -and $optional -is [bool]) {
                        if ((Get-Field $dependency 'status') -eq 'success') { $status = 'Pass' }
                        elseif ((Get-Field $dependency 'status') -eq 'failure' -and -not $optional) { $status = 'Fail' }
                    }
                    $timestamp = if ($updated -ne [datetimeoffset]::MinValue) { $updated.ToString('o') } else { $null }
                    Add-Finding "native-dependency-$dependencyIndex" $nativeIndex $status $(if ($status -eq 'Fail') { 'Error' } elseif ($status -eq 'Unknown') { 'Warning' } else { 'Info' }) 'Native dependency observation: freshness and optionality checked; hostnames and raw error text deliberately omitted. This does not identify a causal NSG or route rule.' $rules.sources.networkStatus $timestamp
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
    $failed = @($findings | Where-Object status -eq 'Fail').Count
    $unknown = @($findings | Where-Object status -eq 'Unknown').Count
    return [ordered]@{
        schemaVersion = 1; toolVersion = $rules.version; maturity = 'candidate'; valueProof = 'unproven'
        assessedAt = $Now.ToString('o'); capturedAt = $capturedAt.ToString('o')
        skuFamily = $family; networkMode = $(if ($mode -in @('Internal', 'External', 'None')) { $mode } else { 'Unknown' })
        result = $(if ($failed -gt 0) { 'ISSUES_FOUND' } else { 'INCONCLUSIVE' })
        summary = @{ failed = $failed; unknown = $unknown; passed = @($findings | Where-Object status -eq 'Pass').Count }
        problemDefinition = 'Assess VNet-injected APIM configuration and dependency observations without changing Azure or generating application traffic.'
        diagnosis = 'Rule results distinguish configuration blockers, native observations and missing evidence. Pass means only that the stated check passed.'
        rootCauseAnalysis = @{ confidence = 'undetermined'; behavior = 'Not classified without service-specific expected behavior and traffic evidence.' }
        findings = $findings.ToArray()
    }
}

Export-ModuleMember -Function Invoke-ApimVnetAssessment
