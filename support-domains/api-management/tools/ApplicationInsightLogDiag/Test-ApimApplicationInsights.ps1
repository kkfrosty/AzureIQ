#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$ServiceName,
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$ResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Live')][string]$ApiId,
    [Parameter(ParameterSetName = 'Live')][string]$ComponentName,
    [Parameter(ParameterSetName = 'Live')][string]$ComponentResourceGroup,
    [Parameter(ParameterSetName = 'Live')][string]$WorkspaceResourceGroup,
    [Parameter(ParameterSetName = 'Live')][switch]$QueryRequests,
    [Parameter(ParameterSetName = 'Live')][datetimeoffset]$StartTime,
    [Parameter(ParameterSetName = 'Live')][datetimeoffset]$EndTime,
    [Parameter(ParameterSetName = 'Live')][string]$RunMarker,
    [Parameter(ParameterSetName = 'Live')][string]$TraceId,
    [Parameter(ParameterSetName = 'Live')][int]$ExpectedRequests = 0,
    [Parameter(Mandatory, ParameterSetName = 'Offline')][string]$SnapshotPath,
    [Parameter(Mandatory, ParameterSetName = 'Describe')][switch]$Describe,
    [Parameter(Mandatory, ParameterSetName = 'Preflight')][switch]$Preflight,
    [switch]$NoOpen
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$mode = $PSCmdlet.ParameterSetName
$started = [datetimeoffset]::UtcNow
$runId = 'RUN-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
Import-Module (Join-Path $PSScriptRoot 'ApimInsights.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ApimInsights.Report.psm1') -Force

if ($Describe) {
    @{
        name = 'APIM Application Insights customer diagnostic'; version = '0.1.0'; status = 'candidate'
        mutatesAzure = $false; generatesTraffic = $false; changesAuthentication = $false
        commands = @('Describe', 'Preflight', 'Live', 'Offline')
        liveRequired = @('ServiceName', 'ResourceGroup', 'ApiId')
        liveOptional = @('ComponentName', 'ComponentResourceGroup', 'WorkspaceResourceGroup', 'QueryRequests',
            'StartTime', 'EndTime', 'RunMarker', 'TraceId', 'ExpectedRequests')
        scopeSource = 'Ignored config/local.azureiq.json; one exact tenant/subscription and expected CLI principal'
        queryContract = 'Opt-in customer Log Analytics aggregate query; explicit UTC interval of at most 24 hours'
        reportDirectory = '.azureiq/private-reports/api-management/application-insights/RUN-.../'
        reportOpens = 'Default; use NoOpen for automation'
        outputs = @('Report', 'HtmlReport', 'ExecutionRecord', 'Summary', 'Delivery', 'RootCause')
        exitCodes = @{ '0' = 'Requested checks passed'; '1' = 'Collection/input/setup failure'; '2' = 'Observed failed check'; '3' = 'Unknown or incomplete coverage' }
    } | ConvertTo-Json -Depth 6
    exit 0
}

function Digest {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

$inputDigest = Digest (@{ mode = $mode; service = $ServiceName; group = $ResourceGroup; api = $ApiId
    component = $ComponentName; componentGroup = $ComponentResourceGroup; workspaceGroup = $WorkspaceResourceGroup
    query = [bool]$QueryRequests; start = $StartTime; end = $EndTime; marker = $RunMarker; trace = $TraceId
    expected = $ExpectedRequests; snapshotPath = $SnapshotPath } | ConvertTo-Json -Compress)
$failure = $null
try {
    if ($Preflight) {
        Test-ApimInsightsReader -WorkspaceRoot $workspace | ConvertTo-Json
        exit 0
    }
    if ($mode -eq 'Live') {
        if ($ServiceName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,49}$' -or $ResourceGroup -notmatch '^[A-Za-z0-9_.()-]{1,90}$' -or
            $ApiId -notmatch '^[A-Za-z0-9_.-]+(?:;rev=[0-9]+)?$') { throw 'INVALID_TARGET_INPUT' }
        foreach ($name in @($ComponentName, $ComponentResourceGroup, $WorkspaceResourceGroup | Where-Object { $_ })) {
            if ($name -notmatch '^[A-Za-z0-9_.()-]{1,90}$') { throw 'INVALID_TARGET_INPUT' }
        }
        if ($ComponentResourceGroup -and -not $ComponentName) { throw 'INVALID_TARGET_INPUT' }
        if (($RunMarker -or $TraceId -or $ExpectedRequests -or $PSBoundParameters.ContainsKey('StartTime') -or $PSBoundParameters.ContainsKey('EndTime')) -and -not $QueryRequests) {
            throw 'QUERY_REQUESTS_REQUIRED'
        }
        if ($QueryRequests) {
            if (-not $PSBoundParameters.ContainsKey('StartTime') -or -not $PSBoundParameters.ContainsKey('EndTime') -or
                $StartTime.Offset -ne [timespan]::Zero -or $EndTime.Offset -ne [timespan]::Zero -or
                ($EndTime - $StartTime).TotalSeconds -le 0 -or ($EndTime - $StartTime).TotalHours -gt 24) { throw 'INVALID_QUERY_WINDOW' }
            $markerGuid = [guid]::Empty
            if ($RunMarker -and (-not [guid]::TryParse($RunMarker, [ref]$markerGuid) -or $markerGuid -eq [guid]::Empty)) { throw 'INVALID_CORRELATION_INPUT' }
            if (($ExpectedRequests -gt 0 -or $TraceId) -and -not $RunMarker -or $ExpectedRequests -lt 0 -or
                ($TraceId -and ($TraceId -notmatch '^[0-9a-fA-F]{32}$' -or $TraceId -match '^0+$'))) { throw 'INVALID_CORRELATION_INPUT' }
        }
        $snapshot = Get-ApimInsightsSnapshot -WorkspaceRoot $workspace -ServiceName $ServiceName -ResourceGroup $ResourceGroup `
            -ApiId $ApiId -ComponentName $ComponentName -ComponentResourceGroup $ComponentResourceGroup `
            -WorkspaceResourceGroup $WorkspaceResourceGroup -QueryRequests:$QueryRequests `
            -StartTime $StartTime -EndTime $EndTime -RunMarker $RunMarker -TraceId $TraceId -ExpectedRequests $ExpectedRequests
    } else {
        $snapshot = Get-Content -Raw -LiteralPath $SnapshotPath | ConvertFrom-Json -AsHashtable -Depth 100
    }
    $report = Invoke-ApimInsightsAssessment -Snapshot $snapshot -Mode $mode
} catch {
    $safe = @('PRIVATE_SCOPE_REQUIRED', 'EXACT_PRIVATE_SCOPE_REQUIRED', 'PRIVATE_SCOPE_CHANGED', 'SCOPE_MISMATCH',
        'PRINCIPAL_MISMATCH', 'EXCLUDED_SCOPE', 'UNSUPPORTED_CLOUD_OR_ACCOUNT', 'AZURE_CLI_REQUIRED',
        'ACCESS_DENIED', 'NOT_FOUND', 'THROTTLED', 'CLI_READ_FAILED', 'CLI_READ_TIMEOUT', 'INVALID_CLI_JSON',
        'CLI_ARGUMENT_NOT_ALLOWED', 'RESOURCE_PATH_NOT_ALLOWED', 'CROSS_SUBSCRIPTION_READ_DENIED',
        'UNSUPPORTED_WORKSPACE_PROFILE', 'UNSUPPORTED_PRIVATE_PROFILE', 'INVALID_SERVICE_RESPONSE',
        'LOCATION_LIMIT_EXCEEDED', 'INVALID_QUERY_RESULT', 'INVALID_SNAPSHOT', 'INVALID_TARGET_INPUT',
        'QUERY_REQUESTS_REQUIRED', 'INVALID_QUERY_WINDOW', 'INVALID_CORRELATION_INPUT')
    $failure = if ($_.Exception.Message -in $safe) { $_.Exception.Message } else { 'COLLECTION_FAILED' }
    if ($Preflight) {
        [Console]::Error.WriteLine((@{ status = 'Failed'; errorCategory = $failure; resourceReads = 0 } | ConvertTo-Json -Compress))
        exit 1
    }
    $report = @{
        toolVersion = '0.1.0'; schemaVersion = 1; assessmentMode = $(if ($mode -eq 'Live') { 'Live' } else { 'Offline' })
        capturedAt = $null; assessedAt = [datetimeoffset]::UtcNow.ToString('o')
        collection = 'Failed'; configuration = 'NotAssessed'; diagnosticSource = 'Unavailable'
        summary = @{ failed = 0; unknown = 1; passed = 0 }
        delivery = @{ state = 'NotTested'; startTime = $null; endTime = $null; observedAt = $null }
        rootCauseAnalysis = @{ confidence = 'undetermined'; behavior = 'Collection did not establish a diagnosis or service-health verdict.' }
        findings = @(@{ ruleId = 'collection-aborted'; title = 'Diagnostic collection'; status = 'Unknown'
            detail = "Collection could not complete ($failure). No raw errors or private identifiers are emitted."
            nextStep = 'Check the private profile, matching signed-in reader and required read/query permissions. No login or scope changes are performed automatically.'
            evidenceRef = 'collection'; source = 'https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights' })
    }
}

try {
    $directory = Get-InsightsOutputDirectory $workspace $runId 'reports'
    $audit = Get-InsightsOutputDirectory $workspace $runId 'audit'
    $reportPath = Join-Path $directory 'report.json'
    $htmlPath = Join-Path $directory 'report.html'
    $report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
    ConvertTo-ApimInsightsHtml $report | Set-Content -LiteralPath $htmlPath -Encoding utf8NoBOM
    $status = if ($failure) { 'failed' } elseif ($report.summary.failed) { 'partial' } elseif ($report.summary.unknown) { 'inconclusive' } else { 'succeeded' }
    $record = @{
        schemaVersion = 1; runId = $runId; changeId = $null; startedAt = $started.ToString('o'); completedAt = [datetimeoffset]::UtcNow.ToString('o')
        intent = 'Read-only customer APIM Application Insights diagnosis'
        route = @{ kind = 'azureiq-cli'; selector = 'ApplicationInsightLogDiag'; operation = $mode; version = '0.1.0' }
        artifact = $null
        authorization = @{ mode = 'read-only'; status = 'not-required'; manifestDigest = $null }
        scope = @{ reference = 'private-local'; environment = $(if ($mode -eq 'Live') { 'configured' } else { 'offline-fixture' }) }
        inputs = @{ parametersDigest = "sha256:$inputDigest"; containsSecrets = $false }
        result = @{ status = $status; summary = "$($report.summary.failed) failed and $($report.summary.unknown) unknown checks; no Azure changes."; created = 0; modified = 0; deleted = 0 }
        verification = @{ verdict = $(if ($failure) { 'not-run' } else { 'inconclusive' })
            evidenceRefs = @([IO.Path]::GetRelativePath($audit, $reportPath), [IO.Path]::GetRelativePath($audit, $htmlPath)) }
        privacy = @{ secretsStored = $false; customerIdentifiersStored = $false; rawPayloadsStored = $false }
        learning = @{ candidateArtifacts = @(); updateArtifacts = @(); incidentRecordRef = $null }
    }
    $recordPath = Join-Path $audit 'execution-record.json'
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    $openStatus = if ($NoOpen) { 'Suppressed' } else { 'Requested' }
    if (-not $NoOpen) {
        try { Invoke-Item -LiteralPath $htmlPath }
        catch { $openStatus = 'Failed'; [Console]::Error.WriteLine('REPORT_OPEN_FAILED: open the returned HtmlReport path manually.') }
    }
    @{ RunId = $runId; AssessmentMode = $mode; ToolVersion = '0.1.0'; Report = $reportPath; HtmlReport = $htmlPath
        ExecutionRecord = $recordPath; ReportOpen = $openStatus; Summary = $report.summary
        Delivery = $report.delivery.state; RootCause = $report.rootCauseAnalysis.confidence; ErrorCategory = $failure } | ConvertTo-Json -Depth 6
} catch {
    [Console]::Error.WriteLine('{"status":"Failed","errorCategory":"REPORT_OR_AUDIT_WRITE_FAILED","message":"No complete persisted report is available. Check ignored report paths, reparse points and filesystem permissions."}')
    exit 1
}
if ($failure) { exit 1 }
if ($report.summary.failed) { exit 2 }
if ($report.summary.unknown) { exit 3 }
exit 0
