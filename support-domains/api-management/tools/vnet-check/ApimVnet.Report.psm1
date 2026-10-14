#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ApimVnetHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Report)
    function Encode { param($Value) return [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    function Format-Utc {
        param($Value)
        $date = [datetimeoffset]::MinValue
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'") }
        if ([datetimeoffset]::TryParse([string]$Value, [ref]$date)) { return $date.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'") }
        return 'Timestamp unavailable'
    }
    function Status-Class {
        param([string]$Value)
        if ($Value -notin @('Fail', 'Unknown', 'Pass', 'NotApplicable')) { throw 'Unsupported report status.' }
        return $Value.ToLowerInvariant()
    }
    function Badge {
        param([string]$Value)
        $class = Status-Class $Value
        $label = if ($Value -eq 'NotApplicable') { 'Not applicable' } else { $Value }
        return "<span class=`"badge $class`">$(Encode $label)</span>"
    }
    function Display {
        param($Value)
        $values = @($Value | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
        if ($values.Count -eq 0) { return 'Unavailable / not collected' }
        return Encode ($values -join ', ')
    }
    $overview = $Report.targetOverview
    $live = $Report.assessmentMode -eq 'Live'
    $provenance = if ($live) { 'LIVE COLLECTION - real Azure configuration reads' } else { 'OFFLINE / SNAPSHOT - NOT LIVE AZURE EVIDENCE; may contain synthetic test data' }
    $privacy = if ($overview.privateDetails) { 'Private operator report: contains target names and network metadata. Do not commit or publish.' } else { 'Sanitized report: target names and address literals omitted.' }
    $style = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'report.css')
    $script = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'report.js')).Replace("`r`n", "`n").Replace("`r", "`n")
    $scriptHash = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($script)))
    $html = [System.Text.StringBuilder]::new()
    $null = $html.AppendLine(@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-$scriptHash'; base-uri 'none'; form-action 'none'">
<title>APIM VNet diagnostic report</title><style>$style</style></head><body>
<a class="skip" href="#main">Skip to report</a>
<header><p class="eyebrow">AzureIQ / API Management</p><h1>VNet diagnostic report</h1>
<p class="provenance"><strong>$(Encode $provenance)</strong></p>
<p>$(Encode $Report.result) &mdash; candidate tooling, not an end-to-end connectivity certificate.</p>
<div class="metadata"><span>Version $(Encode $Report.toolVersion)</span><span>$(Encode $Report.skuFamily) / $(Encode $Report.networkMode)</span><span>Mode: $(Encode $Report.assessmentMode)</span></div>
<div class="metadata"><span>Captured: $(Encode (Format-Utc $Report.capturedAt))</span><span>Assessed: $(Encode (Format-Utc $Report.assessedAt))</span></div>
</header><div class="layout"><aside><nav aria-label="Report sections">
"@)
    foreach ($section in $Report.sections) {
        if ($section.id -notmatch '^[a-z][a-z0-9-]*$') { throw 'Invalid report section identifier.' }
        $null = $html.AppendLine("<a href=`"#$(Encode $section.id)`"><span>$(Encode $section.title)</span>$(Badge $section.status)</a>")
    }
    $null = $html.AppendLine(@"
</nav><p class="subtle">Snapshot report. Rerun the tool to refresh. No background monitoring or automatic changes.</p></aside>
<main id="main">
<section class="panel target-overview" id="target-overview"><h2>Assessment target and network overview</h2>
<p><strong>$(Encode $privacy)</strong></p><dl class="target-grid">
"@)
    if ($overview.privateDetails) {
        $null = $html.AppendLine("<div><dt>APIM service</dt><dd>$(Display $overview.serviceName)</dd></div><div><dt>Resource group</dt><dd>$(Display $overview.resourceGroup)</dd></div>")
    }
    foreach ($field in @(
        @('SKU', $overview.skuName), @('Primary capacity / units', $overview.capacity),
        @('Primary region', $overview.primaryRegion), @('Provisioning state', $overview.provisioningState),
        @('Network mode', $overview.networkMode), @('Injection applicability', $overview.injection),
        @('Selected SKU-specific rules', $overview.selectedRules)
    )) {
        $null = $html.AppendLine("<div><dt>$(Encode $field[0])</dt><dd>$(Display $field[1])</dd></div>")
    }
    $null = $html.AppendLine('</dl>')
    $regionIndex = 0
    foreach ($region in $overview.regions) {
        $regionIndex++
        $null = $html.AppendLine("<h3>Region #$regionIndex &mdash; $(Display $region.location)</h3><dl class=`"target-grid`">")
        $fields = @(
            @('Regional capacity / units', $region.capacity), @('VNet region', $region.vnetRegion),
            @('Subnet evidence', $region.subnetEvidence), @('Subnet prefix sizes', $region.prefixSizes),
            @('NSG attachment', $region.nsgAttachment), @('Route table attachment', $region.routeTableAttachment),
            @('DNS configuration', $region.dnsMode),
            @('Collection gaps', $(if ($region.evidenceGaps.Count -eq 0) { 'None recorded; does not certify completeness or health' } else { $region.evidenceGaps }))
        )
        if ($overview.privateDetails) {
            $fields += @(
                @('VNet', $region.vnetName), @('Subnet', $region.subnetName),
                @('VNet address spaces', $region.vnetAddressSpaces), @('Subnet address prefixes', $region.subnetPrefixes),
                @('NSG', $region.nsgName), @('Route table', $region.routeTableName),
                @('Custom DNS servers', $(if ($region.dnsServers.Count -eq 0) { 'None returned / unavailable; see DNS findings' } else { $region.dnsServers }))
            )
        }
        foreach ($field in $fields) {
            $null = $html.AppendLine("<div><dt>$(Encode $field[0])</dt><dd>$(Display $field[1])</dd></div>")
        }
        $null = $html.AppendLine('</dl>')
    }
    if ($regionIndex -eq 0) { $null = $html.AppendLine('<p>No regional network evidence was collected.</p>') }
    $null = $html.AppendLine(@"
</section>
<section class="panel notice"><p><strong>Coverage is explicit.</strong> Unknown means missing, ambiguous, stale or untested evidence, not a passed check.
Offline reports are not live Azure validation. NSG allows do not prove DNS, routing, TLS or backend health.</p></section>
<section class="panel"><h2>1. Problem Definition</h2><p>$(Encode $Report.problemDefinition)</p></section>
<section class="panel"><h2>2. Diagnosis</h2><p>$(Encode $Report.diagnosis)</p>
<div class="stats"><div class="stat"><strong>$(Encode $Report.summary.failed)</strong><span>Failed checks</span></div>
<div class="stat"><strong>$(Encode $Report.summary.unknown)</strong><span>Unknown / untested</span></div>
<div class="stat"><strong>$(Encode $Report.summary.passed)</strong><span>Passed checks only</span></div>
<div class="stat"><strong>$(Encode $Report.summary.notApplicable)</strong><span>Not applicable</span></div></div>
<div class="controls"><label>Show checks<select id="status-filter"><option value="attention">Needs attention</option><option value="all">All checks</option><option value="Fail">Failed</option><option value="Unknown">Unknown</option><option value="Pass">Passed</option><option value="NotApplicable">Not applicable</option></select></label>
<label>Search report<input id="search-filter" type="search" placeholder="Rule, port, service or explanation"></label>
<button id="expand-all" type="button">Expand all</button><button id="collapse-all" type="button">Collapse all</button><button id="print-report" type="button">Print</button></div>
<p id="filter-summary" class="subtle" role="status">All findings are available below; filtering requires JavaScript.</p></section>
"@)
    foreach ($section in $Report.sections) {
        $counts = $section.counts
        $null = $html.AppendLine(@"
<details class="check-section" id="$(Encode $section.id)" open><summary><span class="section-heading"><strong>$(Encode $section.title)</strong>$(Badge $section.status)</span></summary>
<p class="coverage">$(Encode $section.coverage)</p>
<div class="section-counts">$(Encode $counts.failed) failed &middot; $(Encode $counts.unknown) unknown &middot; $(Encode $counts.passed) passed &middot; $(Encode $counts.notApplicable) not applicable &middot; <span class="visible-count">all visible</span></div>
<div class="table-wrap"><table><thead><tr><th scope="col">Check</th><th scope="col">Expected and observed</th><th scope="col">Next step</th><th scope="col">Evidence</th></tr></thead><tbody>
"@)
        $items = @($Report.findings | Where-Object sectionId -eq $section.id | Sort-Object {
            switch ($_.status) { 'Fail' { 0 } 'Unknown' { 1 } 'Pass' { 2 } default { 3 } }
        })
        foreach ($finding in $items) {
            $null = Status-Class $finding.status
            $uri = $null
            $validSource = [uri]::TryCreate([string]$finding.source, [UriKind]::Absolute, [ref]$uri) -and
                $uri.Scheme -eq 'https' -and $uri.Host -eq 'learn.microsoft.com' -and -not $uri.UserInfo
            $sourceLink = if ($validSource) { "<a href=`"$(Encode $uri.AbsoluteUri)`" target=`"_blank`" rel=`"noopener noreferrer`">Microsoft Learn</a>" } else { 'No approved documentation link' }
            $location = if ($finding.regionIndex -gt 0) { "Region #$($finding.regionIndex)" } else { 'Service / coverage' }
            $timestamp = if ($finding.evidenceTimestamp) { "<p>$(Encode (Format-Utc $finding.evidenceTimestamp))</p>" } else { '' }
            $category = if ($finding.evidenceCategory) { "<p><code>$(Encode $finding.evidenceCategory)</code></p>" } else { '' }
            $null = $html.AppendLine(@"
<tr data-status="$(Encode $finding.status)"><td>$(Badge $finding.status)<p><code>$(Encode $finding.ruleId)</code></p><p class="subtle">$(Encode $location)</p></td>
<td><span class="field-label">Expected</span><p>$(Encode $finding.expected)</p><span class="field-label">Observed</span><p>$(Encode $finding.observed)</p></td>
<td>$(Encode $finding.nextStep)</td><td>$sourceLink$timestamp$category</td></tr>
"@)
        }
        $null = $html.AppendLine('</tbody></table></div></details>')
    }
    $null = $html.AppendLine(@"
<section class="panel" id="root-cause"><h2>3. Root Cause Analysis</h2>
<p><strong>Confidence: $(Encode $Report.rootCauseAnalysis.confidence)</strong></p><p>$(Encode $Report.rootCauseAnalysis.behavior)</p>
<p>Suggested next steps are proposals, not approved remediation. Configuration changes and active traffic probes require separate authorization.</p></section>
</main></div><footer>Read-only assessment &middot; $(Encode $privacy) &middot; no raw payloads or raw errors retained</footer>
<script>$script</script></body></html>
"@)
    return $html.ToString()
}

function Write-ApimVnetOperatorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][ValidatePattern('^RUN-[A-F0-9]{32}$')][string]$RunId,
        [Parameter(Mandatory)][string]$WorkspaceRoot)
    $localRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localRoot)) { throw 'PRIVATE_REPORT_LOCATION_UNAVAILABLE' }
    $directory = [System.IO.Path]::GetFullPath((Join-Path $localRoot "AzureIQ\Reports\$RunId"))
    $workspace = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($directory.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'PRIVATE_REPORT_INSIDE_WORKSPACE' }
    $ancestor = $directory
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and
            ((Get-Item -Force -LiteralPath $ancestor).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'PRIVATE_REPORT_REPARSE_POINT'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    $privateReport = [ordered]@{}
    foreach ($key in $Report.Keys) { $privateReport[$key] = $Report[$key] }
    $privateReport.targetOverview = Get-ApimVnetTargetOverview -Snapshot $Snapshot -Report $Report -IncludePrivateDetails
    $null = New-Item -ItemType Directory -Path $directory -Force
    $jsonPath = Join-Path $directory 'operator-report.json'
    $htmlPath = Join-Path $directory 'report.html'
    $privateReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    ConvertTo-ApimVnetHtml -Report $privateReport | Set-Content -LiteralPath $htmlPath -Encoding utf8NoBOM
    return @{ Report = $jsonPath; HtmlReport = $htmlPath }
}

Export-ModuleMember -Function ConvertTo-ApimVnetHtml, Write-ApimVnetOperatorReport
