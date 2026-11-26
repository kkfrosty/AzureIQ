[CmdletBinding()]
param(
    [string]$BicepPath = (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temporary = Join-Path $root ".azureiq\tmp\harbor-package-$([guid]::NewGuid().ToString('N')).json"
$env:BICEP_CACHE_ROOT = Join-Path $root '.azureiq\cache\bicep'

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
    $foundationSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'foundation.bicep') -Raw
    Assert-Contract ($foundationSource.Contains('53ca6127-db72-4b80-b1b0-d745d6d5456d')) 'Foundry User built-in role must match the verified role definition.'
    Assert-Contract (-not $foundationSource.Contains('53ca6127-db72-4b80-b1b0-d745d6d54553')) 'Invalid Foundry User role ID regression.'
    $applicationSource = Get-Content -LiteralPath (Join-Path $root 'case-study\SupportService\src\Harbor.Support.Api\Program.cs') -Raw
    Assert-Contract ($applicationSource.Contains('monitor.Credential = CreateManagedIdentityCredential(builder.Configuration["AZURE_CLIENT_ID"]);')) 'Keyless Application Insights requires an explicit managed-identity exporter credential.'
    foreach ($entry in @('foundation-main.bicep', 'main.bicep')) {
        & $BicepPath build (Join-Path $PSScriptRoot $entry) --no-restore --outfile $temporary
        Assert-Contract ($LASTEXITCODE -eq 0) "Bicep compilation failed: $entry"
        $template = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
        $resources = @(Get-TemplateResources $template)
        $search = @($resources | Where-Object type -eq 'Microsoft.Search/searchServices')
        Assert-Contract ($search.Count -eq 1) 'Exactly one owned Search service is required.'
        Assert-Contract ($search[0].sku.name -eq 'basic' -and $search[0].properties.disableLocalAuth) 'Search must use Basic and keyless authentication.'
        Assert-Contract ($search[0].properties.publicNetworkAccess -eq 'disabled') 'Search must not allow public data-plane access.'
        $storage = @($resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
        Assert-Contract ($storage.Count -eq 1 -and -not $storage[0].properties.allowSharedKeyAccess) 'Case storage must reject Shared Key authentication.'
        Assert-Contract ($storage[0].properties.publicNetworkAccess -eq 'Disabled') 'Case storage must be private.'
        $foundry = @($resources | Where-Object type -eq 'Microsoft.CognitiveServices/accounts')
        Assert-Contract ($foundry.Count -eq 1 -and $foundry[0].properties.disableLocalAuth) 'Foundry must use keyless authentication.'
        Assert-Contract ($foundry[0].properties.publicNetworkAccess -eq 'Disabled') 'Foundry must be private.'
        $registry = @($resources | Where-Object type -eq 'Microsoft.ContainerRegistry/registries')
        Assert-Contract ($registry.Count -eq 1 -and -not $registry[0].properties.adminUserEnabled) 'Registry admin credentials must stay disabled.'
        if ($entry -eq 'main.bicep') {
            $gateway = @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service')
            Assert-Contract ($gateway.Count -eq 1 -and $gateway[0].sku.name -eq 'StandardV2') 'The primary lab profile must use Standard v2.'
            $center = @($resources | Where-Object type -eq 'Microsoft.ApiCenter/services')
            Assert-Contract ($center.Count -eq 1 -and $center[0].sku.name -eq 'Standard') 'Native catalog MCP requires API Center Standard.'
            Assert-Contract (@($resources | Where-Object type -eq 'Microsoft.ApiCenter/services/workspaces/apiSources').Count -eq 1) 'API Center needs an explicit APIM source link.'
            Assert-Contract (@($resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis' -and $_.properties.apiType -eq 'mcp' }).Count -eq 1) 'Support execution MCP must be distinct from API Center discovery.'
            $seed = @($resources | Where-Object type -eq 'Microsoft.App/jobs')
            Assert-Contract ($seed.Count -eq 1 -and $seed[0].properties.configuration.triggerType -eq 'Manual') 'Knowledge initialization must be an explicitly started manual job.'
            Assert-Contract (($seed[0].properties.template.containers[0].args -join ' ') -eq 'seed --execute-approved-initialization') 'The manual job must invoke the actual bounded initialization command.'
        }
    }
    foreach ($policy in Get-ChildItem (Join-Path $PSScriptRoot 'policies') -Filter '*.xml' -File) {
        $xml = [xml](Get-Content -LiteralPath $policy.FullName -Raw)
        Assert-Contract ($xml.DocumentElement.Name -eq 'policies') "Invalid policy document: $($policy.Name)"
    }
    $inventory = Get-Content (Join-Path $PSScriptRoot 'expected-inventory.json') -Raw
    Assert-Contract (Test-Json -Json $inventory -SchemaFile (Join-Path $root 'schemas\expected-inventory.schema.json')) 'Expected inventory failed schema validation.'
    $manifestPath = Join-Path $PSScriptRoot 'artifact-manifest.json'
    Assert-Contract (Test-Path -LiteralPath $manifestPath) 'Generate the candidate source manifest before validation.'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        $text = (Get-Content -LiteralPath (Join-Path $root $file.path) -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
        $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
        Assert-Contract ($digest -eq $file.sha256) "Candidate source digest differs: $($file.path)"
    }
    [pscustomobject]@{
        Status = 'Passed'
        TemplatesCompiled = 2
        PrivacyAndBoundaryChecks = 'Passed'
        InventorySchema = 'Passed'
        AzureCallsMade = $false
        LiveReadiness = 'Not verified'
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
