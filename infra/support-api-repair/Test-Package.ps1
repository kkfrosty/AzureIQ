[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$output = Join-Path $root ".azureiq\tmp\api-repair-$([guid]::NewGuid().ToString('N')).json"
try {
    & (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe') build (Join-Path $PSScriptRoot 'main.bicep') --no-restore --outfile $output
    if ($LASTEXITCODE -ne 0) { throw 'API repair compilation failed.' }
    $template = Get-Content -Raw $output | ConvertFrom-Json
    $policy = @($template.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/apis/operations/policies')[0]
    if ($policy.type -ne 'Microsoft.ApiManagement/service/apis/operations/policies' -or
        $policy.name -notlike '*onHandshake*') { throw 'Voice policy must target onHandshake operation scope.' }
    $source = Get-Content -Raw (Join-Path $PSScriptRoot 'main.bicep')
    $remaining = @($template.resources | Where-Object name -eq 'harbor-remaining-apis')[0].properties.template
    $mcp = @($remaining.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis' -and $_.properties.apiType -eq 'mcp' })[0]
    if ($mcp.properties.mcpProperties.endpoints -is [array] -or
        $mcp.properties.mcpProperties.endpoints.mcp.uriTemplate -ne '/mcp') {
        throw 'Live MCP provider requires a name-keyed endpoint object.'
    }
    if (-not $source.Contains("path.key != '/v1/{unmatched}'") -or
        -not $source.Contains('shallowMerge([supportOpenApi, { paths: publishedPaths }])')) {
        throw 'Catch-all exclusion requires paths replacement, not recursive merge.'
    }
    $document = Get-Content -Raw (Join-Path $root 'case-study\SupportService\contracts\support-v1.openapi.json') | ConvertFrom-Json -AsHashtable
    $published = @{} + $document.paths
    $null = $published.Remove('/v1/{unmatched}')
    foreach ($path in $published.Keys) {
        foreach ($method in $published[$path].Keys | Where-Object { $_ -in @('get', 'post', 'put', 'patch', 'delete', 'head', 'options') }) {
            $parameters = @($published[$path].parameters) + @($published[$path][$method].parameters)
            foreach ($match in [regex]::Matches($path, '\{([^}]+)\}')) {
                if (@($parameters | Where-Object { $_.name -eq $match.Groups[1].Value -and $_.in -eq 'path' -and $_.required }).Count -ne 1) {
                    throw "Undeclared or optional path parameter: $path $method"
                }
            }
        }
    }
    if ($document.paths.ContainsKey('/v1/{unmatched}') -and $published.Count -ne $document.paths.Count - 1) {
        throw 'Only the invalid fallback may be excluded.'
    }
    [pscustomobject]@{ Status = 'Passed'; HandshakePolicy = 'Operation scope'; PathParameters = 'Declared and required'; AzureWrites = 0 }
}
finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
}
