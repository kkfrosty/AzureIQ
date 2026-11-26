[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temporary = Join-Path $root ".azureiq\tmp\mcp-completion-$([guid]::NewGuid().ToString('N')).json"
try {
    & (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe') build (Join-Path $PSScriptRoot 'mcp-completion.bicep') --no-restore --outfile $temporary
    if ($LASTEXITCODE -ne 0) { throw 'REST-backed MCP compilation failed.' }
    $template = Get-Content -Raw $temporary | ConvertFrom-Json
    $apis = @($template.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis')
    if ($apis.Count -ne 1 -or $apis[0].properties.type -ne 'mcp') {
        throw 'Exactly one REST-backed API with properties.type mcp is required.'
    }
    foreach ($excluded in @('sourceApiId', 'apiType', 'mcpProperties', 'serviceUrl')) {
        if ($apis[0].properties.PSObject.Properties[$excluded]) {
            throw "REST clone or passthrough property is not allowed: $excluded"
        }
    }
    $tools = @($template.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis/tools')
    if ($tools.Count -ne 1 -or -not $tools[0].copy -or
        $tools[0].properties.operationId -notmatch 'resourceId.*Microsoft.ApiManagement/service/apis.*harbor-support' -or
        $tools[0].properties.operationId -notmatch '/operations/') {
        throw 'Selected tools must reference absolute existing support operation IDs.'
    }
    $unexpected = @($template.resources | Where-Object {
        $_.type -notlike 'Microsoft.ApiManagement/service/apis*' -and $_.type -ne 'Microsoft.Resources/deployments'
    })
    if ($unexpected.Count) { throw 'MCP completion must not write unrelated root resources.' }
    $catalog = @($template.resources | Where-Object type -eq 'Microsoft.Resources/deployments')
    if ($catalog.Count -ne 1 -or $catalog[0].name -ne 'harbor-catalog-final') {
        throw 'Only the original catalog module may follow MCP completion.'
    }
    [pscustomobject]@{
        Status = 'Passed'
        ApiType = 'mcp'
        RestCloning = 'Excluded'
        OperationReferences = 'Absolute'
        UnrelatedWrites = 'Excluded'
        AzureWrites = 0
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
