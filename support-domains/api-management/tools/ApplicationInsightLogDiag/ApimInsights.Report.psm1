#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ApimInsightsHtml {
    param([Parameter(Mandatory)]$Report)
    function Encode { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    $css = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\vnet-check\report.css')
    $css += @'
main { max-width: 1200px; margin: auto; padding: 24px; }
.check { padding: 16px; margin: 12px 0; border: 1px solid var(--cp-border); border-radius: 10px; background: var(--cp-surface); }
.check h3 { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
.status-dot { display: inline-block; width: 12px; height: 12px; border-radius: 50%; background: var(--cp-warning); }
.pass .status-dot { background: var(--cp-success); }
.fail .status-dot { background: var(--cp-danger); }
.unknown .status-dot { background: var(--cp-warning); }
.notapplicable .status-dot { background: var(--cp-text-muted); }
.check p { overflow-wrap: anywhere; }
.actions { display: flex; flex-wrap: wrap; gap: 12px; padding: 16px 0; }
.summary-grid { display: grid; grid-template-columns: repeat(auto-fit,minmax(180px,1fr)); gap: 12px; }
.summary-grid p { padding: 12px; border: 1px solid var(--cp-border); border-radius: 10px; }
[hidden] { display: none !important; }
@media print { .actions { display: none; } .check { break-inside: avoid; } body { background: var(--cp-surface); } }
'@
    $script = @'
(() => {
  const param = new URLSearchParams(window.location.search).get("scoutTheme");
  const theme =
    param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  document.documentElement.setAttribute("data-theme", theme);
})();
(() => {
  const filter = document.getElementById("status");
  const search = document.getElementById("search");
  const apply = () => {
    let visible = 0;
    for (const check of document.querySelectorAll(".check")) {
      check.hidden = (filter.value !== "all" && check.dataset.status !== filter.value) ||
        !check.textContent.toLowerCase().includes(search.value.toLowerCase());
      if (!check.hidden) visible++;
    }
    document.getElementById("visible").textContent = `${visible} checks shown`;
  };
  filter.addEventListener("change", apply);
  search.addEventListener("input", apply);
  document.getElementById("print").addEventListener("click", () => window.print());
  apply();
})();
'@
    $script = $script.Replace("`r`n", "`n").Replace("`r", "`n")
    $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script)))
    $provenance = if ($Report.assessmentMode -eq 'Live') { 'LIVE read-only Azure collection' } else { 'OFFLINE snapshot / fixture - not live Azure evidence' }
    $html = [Text.StringBuilder]::new()
    $null = $html.AppendLine(@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-$hash'; base-uri 'none'; form-action 'none'">
<title>APIM Application Insights diagnosis</title><style>$css</style></head><body>
<header><p class="eyebrow">AzureIQ / Customer diagnostic</p><h1>APIM Application Insights diagnosis</h1>
<p class="provenance">$(Encode $provenance)</p>
<p>Version $(Encode $Report.toolVersion) &middot; Captured $(Encode $Report.capturedAt) &middot; Assessed $(Encode $Report.assessedAt)</p></header>
<main><section class="panel"><h2>1. Problem definition</h2>
<p>Assess effective API logging configuration, customer-accessible network evidence and optional observed Request ingestion. No configuration changes, application traffic or Microsoft-internal tools.</p>
<p>This report omits private resource/account identifiers, exact bound queries, credentials, payloads and raw native error text.</p></section>
<section class="panel"><h2>2. Diagnosis</h2><div class="summary-grid">
<p>Collection<br><strong>$(Encode $Report.collection)</strong></p>
<p>Configuration<br><strong>$(Encode $Report.configuration)</strong></p>
<p>Delivery<br><strong>$(Encode $Report.delivery.state)</strong></p>
<p>Diagnostic source<br><strong>$(Encode $Report.diagnosticSource)</strong></p></div>
<p>$(Encode $Report.summary.passed) passed &middot; $(Encode $Report.summary.failed) failed &middot; $(Encode $Report.summary.unknown) unknown / review needed.</p>
<p>Not applicable: $(if ($Report.summary.Contains('notApplicable')) { Encode $Report.summary.notApplicable } else { '0' }). These are skipped, not passed.</p>
<p>Green = verified narrow check; red = demonstrated constraint failure; yellow = warning or unverified evidence; gray = not applicable. A completed collection is not a service-health certificate.</p>
<div class="actions"><label>Show<select id="status"><option value="all">All checks</option><option value="Pass">Pass</option><option value="Fail">Fail</option><option value="Unknown">Unknown / review</option><option value="NotApplicable">Not applicable</option></select></label>
<label>Search<input id="search" type="search"></label><button id="print" type="button">Print report</button><span id="visible" role="status"></span></div>
"@)
    foreach ($finding in $Report.findings) {
        if ($finding.status -notin @('Pass', 'Fail', 'Unknown', 'NotApplicable')) { throw 'INVALID_REPORT_STATUS' }
        $class = $finding.status.ToLowerInvariant()
        $null = $html.AppendLine("<article class=`"check $class`" data-status=`"$($finding.status)`"><h3><span class=`"status-dot`" aria-hidden=`"true`"></span>$(Encode $finding.title) <span>$(Encode $finding.status)</span></h3><p>$(Encode $finding.detail)</p><p><strong>Next check:</strong> $(Encode $finding.nextStep)</p><p class=`"subtle`">Rule $(Encode $finding.ruleId) &middot; Evidence $(Encode $finding.evidenceRef)</p>")
        if ($finding.Contains('dependencyEvidence') -and $finding.dependencyEvidence) {
            $dependency = $finding.dependencyEvidence
            $null = $html.AppendLine("<p><strong>Platform observation:</strong> $(Encode $dependency.resourceType) &middot; reported $(Encode $dependency.observedStatus) &middot; optional $(Encode $dependency.optional) &middot; fresh $(Encode $dependency.fresh)</p><p class=`"subtle`">Source: $(Encode $dependency.source). Last checked $(Encode $dependency.lastUpdated); maximum age $(Encode $dependency.maximumAgeMinutes) minutes.</p>")
        }
        $uri = $null
        if ([uri]::TryCreate([string]$finding.source, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -eq 'learn.microsoft.com' -and -not $uri.UserInfo) {
            $null = $html.AppendLine("<p><a href=`"$(Encode $uri.AbsoluteUri)`" target=`"_blank`" rel=`"noopener noreferrer`">Microsoft Learn reference</a></p>")
        }
        $null = $html.AppendLine('</article>')
    }
    $null = $html.AppendLine("<h3>Request observation scope</h3><p>Event window: $(Encode $Report.delivery.startTime) through $(Encode $Report.delivery.endTime). Query observed at: $(Encode $Report.delivery.observedAt).</p>")
    if ($Report.delivery.Contains('counts')) {
        $null = $html.AppendLine('<table><thead><tr><th>Measure</th><th>Observed count</th></tr></thead><tbody>')
        foreach ($name in @('Rows', 'SuccessRows', 'Http200Rows', 'UniqueRequests', 'UniqueOperations', 'ItemCountSum', 'KnownTraceRows')) {
            if ($Report.delivery.counts.Contains($name)) {
                $null = $html.AppendLine("<tr><td>$(Encode $name)</td><td>$(Encode $Report.delivery.counts[$name])</td></tr>")
            }
        }
        $null = $html.AppendLine('</tbody></table>')
    }
    $null = $html.AppendLine(@"
</section><section class="panel"><h2>3. Root cause analysis</h2><p><strong>Confidence: $(Encode $Report.rootCauseAnalysis.confidence)</strong></p>
<p>$(Encode $Report.rootCauseAnalysis.behavior)</p><p>Historical events do not certify current transport. No automatic fixes, role grants, traffic or fault injection are available in this tool.</p></section>
<footer>Review this sanitized point-in-time evidence before sharing. Remaining service-side gaps may need a separate support investigation.</footer></main>
<script>$script</script></body></html>
"@)
    return $html.ToString()
}

function Get-InsightsOutputDirectory {
    param([string]$WorkspaceRoot, [string]$RunId, [ValidateSet('reports', 'audit')][string]$Kind)
    if ($RunId -notmatch '^RUN-[A-F0-9]{32}$') { throw 'INVALID_RUN_ID' }
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
    $relative = if ($Kind -eq 'reports') { ".azureiq\private-reports\api-management\application-insights\$RunId" } else { ".azureiq\runs\$RunId" }
    $path = Join-Path $workspace $relative
    $ancestor = $path
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'PRIVATE_REPORT_REPARSE_POINT'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    $null = & git -C $workspace check-ignore -q -- "$relative\report.json"
    if ($LASTEXITCODE -ne 0) { throw 'PRIVATE_REPORT_NOT_IGNORED' }
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

Export-ModuleMember -Function ConvertTo-ApimInsightsHtml, Get-InsightsOutputDirectory
