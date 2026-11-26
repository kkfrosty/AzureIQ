[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$manifestPath = Join-Path $PSScriptRoot 'artifact-manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($previous.status -ne 'candidate') {
        throw 'Only an unapproved candidate manifest can be regenerated in place.'
    }
}
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
    Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        $text = (Get-Content -LiteralPath $_.FullName -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
        $digest = [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
        ).ToLowerInvariant()
        [ordered]@{
            path = [System.IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
            sha256 = $digest
        }
    })
$manifest = [ordered]@{
    schemaVersion = 1
    id = 'harbor.support-ecosystem'
    version = '0.1.0'
    status = 'candidate'
    entryPoint = 'infra/support-service/main.bicep'
    foundationEntryPoint = 'infra/support-service/foundation-main.bicep'
    files = $files
    validation = [ordered]@{
        finalCompilation = 'pending'
        providerValidation = 'not-run'
        liveVerification = 'not-run'
        nativeApiCenterMcp = 'not-run'
        linkedStandardBenefit = 'not-verified'
        recreateCycle = 'not-run'
    }
}
if ($PSCmdlet.ShouldProcess($manifestPath, 'Regenerate unapproved candidate source digests')) {
    $json = ($manifest | ConvertTo-Json -Depth 20) + "`n"
    [System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Status = 'CandidateGenerated'; Files = $files.Count; ValidationClaimed = $false }
}
