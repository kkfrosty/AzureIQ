[CmdletBinding()]
param(
    [string]$BicepPath = (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temporary = Join-Path $root ".azureiq\tmp\harbor-recovery-$([guid]::NewGuid().ToString('N')).json"

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-TemplateResources($Template) {
    $resources = if ($Template.resources -is [array]) {
        $Template.resources
    } else {
        $Template.resources.PSObject.Properties | ForEach-Object Value
    }
    foreach ($resource in $resources) {
        if ($resource.existing) { continue }
        $resource
        if ($resource.type -eq 'Microsoft.Resources/deployments') {
            Get-TemplateResources $resource.properties.template
        }
    }
}

try {
    & $BicepPath build (Join-Path $PSScriptRoot 'main.bicep') --no-restore --outfile $temporary
    Assert-Contract ($LASTEXITCODE -eq 0) 'Recovery Bicep compilation failed.'
    $template = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
    $resources = @(Get-TemplateResources $template)
    foreach ($name in @('containerAppsSubnetNetworkSecurityGroupId', 'privateEndpointsSubnetNetworkSecurityGroupId')) {
        Assert-Contract ($template.parameters.$name.type -eq 'string') "Required NSG binding is missing: $name"
        Assert-Contract (-not $template.parameters.$name.PSObject.Properties['defaultValue']) "NSG binding must not silently default: $name"
        $ecosystem = @($template.resources.PSObject.Properties.Value | Where-Object type -eq 'Microsoft.Resources/deployments')[0]
        Assert-Contract ($ecosystem.properties.parameters.$name.value -eq "[parameters('$name')]") "Root NSG binding is not forwarded: $name"
        $foundation = @($ecosystem.properties.template.resources.PSObject.Properties.Value | Where-Object type -eq 'Microsoft.Resources/deployments')[0]
        Assert-Contract ($foundation.properties.parameters.$name.value -eq "[parameters('$name')]") "Foundation NSG binding is not forwarded: $name"
    }
    $network = @($resources | Where-Object type -eq 'Microsoft.Network/virtualNetworks')
    Assert-Contract ($network.Count -eq 1) 'Exactly one owned virtual network is required.'
    foreach ($binding in @(
        @{ Subnet = 'container-apps'; Parameter = 'containerAppsSubnetNetworkSecurityGroupId' },
        @{ Subnet = 'private-endpoints'; Parameter = 'privateEndpointsSubnetNetworkSecurityGroupId' }
    )) {
        $subnet = @($network[0].properties.subnets | Where-Object name -eq $binding.Subnet)
        Assert-Contract ($subnet.Count -eq 1) "Required subnet is missing: $($binding.Subnet)"
        Assert-Contract ($subnet[0].properties.networkSecurityGroup.id -eq "[parameters('$($binding.Parameter)')]") "Existing subnet NSG would not be preserved: $($binding.Subnet)"
    }
    $search = @($resources | Where-Object type -eq 'Microsoft.Search/searchServices')
    Assert-Contract ($search.Count -eq 1 -and $search[0].properties.disableLocalAuth) 'Search must remain keyless.'
    Assert-Contract ($search[0].properties.publicNetworkAccess -eq 'disabled') 'Search data plane must remain private.'
    Assert-Contract (-not $search[0].properties.PSObject.Properties['authOptions']) 'Search dual-auth provider incompatibility must not return.'
    Assert-Contract ($search[0].properties.networkRuleSet.bypass -eq 'None') 'Search trusted-service bypass must remain disabled.'
    $environment = @($resources | Where-Object type -eq 'Microsoft.App/managedEnvironments')
    Assert-Contract ($environment.Count -eq 1 -and $environment[0].properties.vnetConfiguration.internal) 'Container Apps environment must remain internal.'
    Assert-Contract ($environment[0].properties.publicNetworkAccess -eq 'Disabled') 'Container Apps public-network denial must remain explicit.'
    $registry = @($resources | Where-Object type -eq 'Microsoft.ContainerRegistry/registries')
    Assert-Contract ($registry.Count -eq 1 -and -not $registry[0].properties.adminUserEnabled) 'Registry admin credentials must remain disabled.'
    $gateway = @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service')
    Assert-Contract ($gateway.Count -eq 1 -and $gateway[0].sku.name -eq 'StandardV2') 'Gateway tier must remain Standard v2.'
    $center = @($resources | Where-Object type -eq 'Microsoft.ApiCenter/services')
    Assert-Contract ($center.Count -eq 1 -and $center[0].sku.name -eq 'Standard') 'Catalog tier must remain Standard.'
    $manifestPath = Join-Path $PSScriptRoot 'artifact-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($file in $manifest.files) {
            $text = (Get-Content -LiteralPath (Join-Path $root $file.path) -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
            $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
            Assert-Contract ($digest -eq $file.sha256) "Candidate source digest differs: $($file.path)"
        }
    } else {
        throw 'Candidate source manifest is required.'
    }
    [pscustomobject]@{
        Status = 'Passed'
        TemplatesCompiled = 1
        ExistingSubnetNsgBindings = 'Preserved'
        PrivateKeylessSearch = 'Preserved'
        ServiceTiers = 'Unchanged'
        AzureCallsMade = $false
        LiveReadiness = 'Not verified'
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
