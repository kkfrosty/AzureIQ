#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Offline')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Offline')][string]$SnapshotPath,
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidatePattern('^[A-Za-z0-9-]{1,50}$')][string]$ServiceName,
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidatePattern('^[A-Za-z0-9_.()-]{1,90}$')][string]$ResourceGroup,
    [ValidateRange(1, 1440)][int]$MaxStatusAgeMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$startedAt = [datetimeoffset]::UtcNow
$runId = 'RUN-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
$runDirectory = Join-Path $workspaceRoot ".azureiq\runs\$runId"
Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Rules.psm1') -Force

try {
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Collector.psm1') -Force
        $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $workspaceRoot -ServiceName $ServiceName -ResourceGroup $ResourceGroup
    } else {
        $snapshot = Get-Content -Raw -LiteralPath $SnapshotPath | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $report = Invoke-ApimVnetAssessment -Snapshot $snapshot -MaxStatusAgeMinutes $MaxStatusAgeMinutes
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    $reportPath = Join-Path $runDirectory 'report.json'
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
    $source = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'rules.json')).Replace("`r`n", "`n").Replace("`r", "`n")
    $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $inputDigest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 100 -Compress))
    )).ToLowerInvariant()
    $record = @{
        schemaVersion = 1; runId = $runId; changeId = $null
        startedAt = $startedAt.ToString('o'); completedAt = [datetimeoffset]::UtcNow.ToString('o')
        intent = 'Read-only APIM VNet configuration assessment'
        route = @{ kind = 'arm-rest'; selector = 'apim-vnet-check'; operation = $PSCmdlet.ParameterSetName; version = '0.1.0' }
        artifact = @{ id = 'apim.vnet-check'; version = '0.1.0'; sha256 = $digest }
        authorization = @{ mode = 'read-only'; status = 'not-required'; manifestDigest = $null }
        scope = @{ reference = 'private-local'; environment = $(if ($PSCmdlet.ParameterSetName -eq 'Live') { 'configured' } else { 'offline-fixture' }) }
        inputs = @{ parametersDigest = "sha256:$inputDigest"; containsSecrets = $false }
        result = @{ status = 'inconclusive'; summary = "$($report.result): $($report.summary.failed) failed checks, $($report.summary.unknown) unknown checks. No end-to-end verification."; created = 0; modified = 0; deleted = 0 }
        verification = @{ verdict = 'inconclusive'; evidenceRefs = @('report.json') }
        privacy = @{ secretsStored = $false; customerIdentifiersStored = $false; rawPayloadsStored = $false }
        learning = @{ candidateArtifacts = @('apim.vnet-check@0.1.0'); updateArtifacts = @(); incidentRecordRef = $null }
    }
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'execution-record.json') -Encoding utf8NoBOM
    [pscustomobject]@{
        Result = $report.result; FailedChecks = $report.summary.failed; UnknownChecks = $report.summary.unknown
        Report = $reportPath; RunId = $runId
    } | ConvertTo-Json
    if ($report.summary.failed -gt 0) { exit 2 }
    exit 3
} catch {
    # Never render an exception that could contain Azure IDs, raw CLI errors or snapshot contents.
    $safeCodes = @('PRIVATE_SCOPE_REQUIRED', 'EXACT_PRIVATE_SCOPE_REQUIRED', 'PRIVATE_SCOPE_CHANGED', 'SCOPE_MISMATCH',
        'PRINCIPAL_MISMATCH', 'EXCLUDED_SCOPE', 'CROSS_SUBSCRIPTION_READ_DENIED', 'RESOURCE_PATH_NOT_ALLOWED',
        'UNSUPPORTED_CLOUD_OR_ACCOUNT', 'AZURE_CLI_REQUIRED', 'ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED',
        'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'CLI_ARGUMENT_NOT_ALLOWED', 'INVALID_CLI_JSON', 'UNSUPPORTED_OR_BAD_REQUEST', 'LOCATION_LIMIT_EXCEEDED',
        'UNSUPPORTED_WORKSPACE_PROFILE', 'UNSUPPORTED_PRIVATE_PROFILE', 'INVALID_SERVICE_RESPONSE')
    $category = if ($_.Exception.Message -in $safeCodes) { $_.Exception.Message } else { 'ASSESSMENT_FAILED' }
    [Console]::Error.WriteLine((@{ status = 'Failed'; errorCategory = $category; message = 'No success verdict is available. Check input structure, private scope, reader principal and read permissions; raw errors are deliberately not printed.' } | ConvertTo-Json -Compress))
    exit 1
}
