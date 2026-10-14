#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ReaderCli {
    param([string[]]$Arguments)
    # Azure CLI diagnostics can contain private identifiers; only fixed error categories leave this boundary.
    $command = Get-Command az -CommandType Application -ErrorAction Stop
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

function Get-ApimVnetSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]{1,50}$')][string]$ServiceName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]{1,90}$')][string]$ResourceGroup
    )
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
    function Read-Resource {
        param([string]$Id)
        if ((Get-Content -Raw -LiteralPath $configurationPath) -cne $configurationText -or
            (Get-Content -Raw -LiteralPath (Join-Path $WorkspaceRoot 'config\azureiq.yaml')) -cne $tracked) {
            throw 'PRIVATE_SCOPE_CHANGED'
        }
        $account = Invoke-ReaderCli @('account', 'show')
        Assert-ApimReaderContext $configuration $account
        $uri = Get-ApimReadUri $Id $configuration.scope.subscriptionIds[0]
        return Invoke-ReaderCli @('rest', '--method', 'get', '--url', $uri, '--subscription', $configuration.scope.subscriptionIds[0])
    }
    $account = Invoke-ReaderCli @('account', 'show')
    Assert-ApimReaderContext $configuration $account
    $id = "/subscriptions/$($configuration.scope.subscriptionIds[0])/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ServiceName"
    $service = Read-Resource $id
    if (-not $service.ContainsKey('properties') -or -not $service.ContainsKey('sku')) { throw 'INVALID_SERVICE_RESPONSE' }
    $locations = @(@{
        location = $service.location; capacity = $service.sku.capacity
        virtualNetworkConfiguration = $service.properties['virtualNetworkConfiguration']
    })
    if ($service.properties.ContainsKey('additionalLocations')) { $locations += @($service.properties.additionalLocations) }
    if ($locations.Count -gt 10) { throw 'LOCATION_LIMIT_EXCEEDED' }
    $regions = [System.Collections.Generic.List[object]]::new()
    foreach ($location in $locations) {
        $region = @{
            location = $location.location; capacity = $location['capacity']
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
        try { $region.subnet = Read-Resource $subnetId }
        catch {
            if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
            $region.evidenceGaps.Add("SUBNET_$($_.Exception.Message)")
        }
        $vnetId = $subnetId -replace '/subnets/[^/]+$', ''
        try { $region.virtualNetwork = Read-Resource $vnetId }
        catch {
            if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
            $region.evidenceGaps.Add("VNET_$($_.Exception.Message)")
        }
        if ($null -ne $region.subnet -and $region.subnet.ContainsKey('properties')) {
            foreach ($type in @('networkSecurityGroup', 'routeTable')) {
                $reference = $region.subnet.properties[$type]
                if ($null -eq $reference) { continue }
                if (-not $reference.ContainsKey('id')) { $region.evidenceGaps.Add('INVALID_NETWORK_REFERENCE'); continue }
                try { $region[$type] = Read-Resource $reference.id }
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
        $native.locations = @(Read-Resource "$id/networkstatus")
        $native.available = $true
    } catch {
        if (-not (Test-OptionalReadFailure $_.Exception.Message)) { throw }
        $native.errorCategory = $_.Exception.Message
    }
    return @{
        schemaVersion = 1; capturedAt = [datetimeoffset]::UtcNow.ToString('o')
        service = $service; regions = $regions.ToArray(); nativeNetworkStatus = $native
    }
}

Export-ModuleMember -Function Get-ApimVnetSnapshot, Assert-ApimReaderContext, Get-ApimReadUri
