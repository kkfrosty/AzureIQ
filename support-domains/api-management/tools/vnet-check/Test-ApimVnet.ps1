#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Offline')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Offline')][string]$SnapshotPath,
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidatePattern('^[A-Za-z0-9-]{1,50}$')][string]$ServiceName,
    [Parameter(Mandatory, ParameterSetName = 'Live')][ValidatePattern('^[A-Za-z0-9_.()-]{1,90}$')][string]$ResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Describe')][switch]$Describe,
    [Parameter(Mandatory, ParameterSetName = 'Preflight')][switch]$Preflight,
    [ValidateRange(1, 1440)][int]$MaxStatusAgeMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$startedAt = [datetimeoffset]::UtcNow
$runId = 'RUN-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
$runDirectory = Join-Path $workspaceRoot ".azureiq\runs\$runId"
$executionMode = $PSCmdlet.ParameterSetName
Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Rules.psm1') -Force
$contract = Get-ApimVnetToolContract
if ($Describe) {
    $contract | ConvertTo-Json -Depth 15
    exit 0
}

function Get-StringDigest {
    param([string]$Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($Text)
    )).ToLowerInvariant()
}

function Write-ApimExecutionRecord {
    param([string]$Status, [string]$Summary, [string]$InputDigest, [string[]]$EvidenceRefs)
    $source = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'rules.json')).Replace("`r`n", "`n").Replace("`r", "`n")
    $record = @{
        schemaVersion = 1; runId = $runId; changeId = $null
        startedAt = $startedAt.ToString('o'); completedAt = [datetimeoffset]::UtcNow.ToString('o')
        intent = 'Read-only APIM VNet configuration assessment'
        route = @{ kind = $(if ($executionMode -eq 'Live') { 'arm-rest' } else { 'azureiq-cli' }); selector = 'apim-vnet-check'; operation = $executionMode; version = $contract.version }
        artifact = @{ id = 'apim.vnet-check'; version = $contract.version; sha256 = (Get-StringDigest $source) }
        authorization = @{ mode = 'read-only'; status = 'not-required'; manifestDigest = $null }
        scope = @{ reference = 'private-local'; environment = $(if ($executionMode -eq 'Live') { 'configured' } else { 'offline-fixture' }) }
        inputs = @{ parametersDigest = "sha256:$InputDigest"; containsSecrets = $false }
        result = @{ status = $Status; summary = $Summary; created = 0; modified = 0; deleted = 0 }
        verification = @{ verdict = $(if ($Status -eq 'failed') { 'not-run' } else { 'inconclusive' }); evidenceRefs = @($EvidenceRefs) }
        privacy = @{ secretsStored = $false; customerIdentifiersStored = $false; rawPayloadsStored = $false }
        learning = @{ candidateArtifacts = @("apim.vnet-check@$($contract.version)"); updateArtifacts = @(); incidentRecordRef = $null }
    }
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'execution-record.json') -Encoding utf8NoBOM
}

$inputDigest = Get-StringDigest (@{
    mode = $executionMode; service = $ServiceName; resourceGroup = $ResourceGroup
    snapshotPath = $SnapshotPath; maxStatusAgeMinutes = $MaxStatusAgeMinutes
} | ConvertTo-Json -Compress)

try {
    if ($Preflight) {
        Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Collector.psm1') -Force
        Test-ApimVnetReader -WorkspaceRoot $workspaceRoot | ConvertTo-Json
        exit 0
    }
    Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Report.psm1') -Force
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        Import-Module (Join-Path $PSScriptRoot 'ApimVnet.Collector.psm1') -Force
        $snapshot = Get-ApimVnetSnapshot -WorkspaceRoot $workspaceRoot -ServiceName $ServiceName -ResourceGroup $ResourceGroup
    } else {
        $snapshot = Get-Content -Raw -LiteralPath $SnapshotPath | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $report = Invoke-ApimVnetAssessment -Snapshot $snapshot -MaxStatusAgeMinutes $MaxStatusAgeMinutes
    $report.assessmentMode = $executionMode
    $null = New-Item -ItemType Directory -Path $runDirectory -Force
    $reportPath = Join-Path $runDirectory 'report.json'
    $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
    $htmlPath = Join-Path $runDirectory 'report.html'
    ConvertTo-ApimVnetHtml -Report $report | Set-Content -LiteralPath $htmlPath -Encoding utf8NoBOM
    $operatorReportPath = $null
    if ($executionMode -eq 'Live') {
        $operatorReport = Write-ApimVnetOperatorReport -Snapshot $snapshot -Report $report -RunId $runId -WorkspaceRoot $workspaceRoot
        $operatorReportPath = $operatorReport.Report
        $htmlPath = $operatorReport.HtmlReport
    }
    Write-ApimExecutionRecord 'inconclusive' "$($report.result): $($report.summary.failed) failed checks, $($report.summary.unknown) unknown checks. No end-to-end verification." $inputDigest @('report.json', 'report.html')
    [pscustomobject]@{
        Result = $report.result; FailedChecks = $report.summary.failed; UnknownChecks = $report.summary.unknown
        Report = $reportPath; HtmlReport = $htmlPath; OperatorReport = $operatorReportPath; RunId = $runId
        AssessmentMode = $executionMode
        ToolVersion = $report.toolVersion
        EvidenceSummary = @($report.assessmentSummary | Where-Object label -ne 'Not tested')
        NotAssessedChecks = @($report.findings | Where-Object assessment -eq 'Not tested').Count
        Sections = @($report.sections | ForEach-Object { @{ Id = $_.id; Status = $_.status; Assessment = $_.assessment; Counts = $_.counts } })
    } | ConvertTo-Json -Depth 8
    if ($report.summary.failed -gt 0) { exit 2 }
    exit 3
} catch {
    # Never render an exception that could contain Azure IDs, raw CLI errors or snapshot contents.
    $safeCodes = @('PRIVATE_SCOPE_REQUIRED', 'EXACT_PRIVATE_SCOPE_REQUIRED', 'PRIVATE_SCOPE_CHANGED', 'SCOPE_MISMATCH',
        'PRINCIPAL_MISMATCH', 'EXCLUDED_SCOPE', 'CROSS_SUBSCRIPTION_READ_DENIED', 'RESOURCE_PATH_NOT_ALLOWED',
        'UNSUPPORTED_CLOUD_OR_ACCOUNT', 'AZURE_CLI_REQUIRED', 'ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED',
        'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'CLI_ARGUMENT_NOT_ALLOWED', 'INVALID_CLI_JSON', 'UNSUPPORTED_OR_BAD_REQUEST', 'LOCATION_LIMIT_EXCEEDED',
        'UNSUPPORTED_WORKSPACE_PROFILE', 'UNSUPPORTED_PRIVATE_PROFILE', 'INVALID_SERVICE_RESPONSE',
        'PRIVATE_REPORT_NOT_IGNORED', 'PRIVATE_REPORT_REPARSE_POINT', 'RULE_REQUIREMENT_MISSING')
    $category = if ($_.Exception.Message -in $safeCodes) { $_.Exception.Message } else { 'ASSESSMENT_FAILED' }
    try { if (-not $Preflight) { Write-ApimExecutionRecord 'failed' "Assessment aborted: $category. No Azure mutations or success verdict." $inputDigest @() } }
    catch { [Console]::Error.WriteLine('{"status":"Failed","errorCategory":"AUDIT_RECORD_WRITE_FAILED"}') }
    [Console]::Error.WriteLine((@{ status = 'Failed'; runId = $runId; errorCategory = $category; message = 'No success verdict is available. Check input structure, private scope, reader principal and read permissions; raw errors are deliberately not printed.' } | ConvertTo-Json -Compress))
    exit 1
}
