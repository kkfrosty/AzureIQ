# ApplicationInsightLogDiag

**Version:** 0.1.0 customer-run candidate. Offline evaluator, mocked collector and
HTML contracts tested; live customer-subscription validation is pending.

This is a standalone, read-only PowerShell 7.4 diagnostic. It assesses effective
APIM Application Insights configuration, reuses the existing VNet checker, and
optionally queries customer-owned Request evidence. It generates self-contained
HTML and sanitized JSON, opens the HTML by default, and creates a sanitized
execution record. No Microsoft-internal tools or employee-only logs are used.

It never starts a VM, generates application traffic, retrieves logger/named-value
secrets, installs an extension, signs in, switches subscriptions, grants roles or
changes Azure configuration. Remediation and fault experiments remain separate.

## Run from GitHub Copilot or PowerShell

From the AzureIQ repository root:

```powershell
$tool = '.\support-domains\api-management\tools\ApplicationInsightLogDiag\Test-ApimApplicationInsights.ps1'
& $tool -Describe
& $tool -Preflight
& $tool -ServiceName '<apim-name>' -ResourceGroup '<resource-group>' -ApiId '<api-id>'
```

`-ApiId` identifies one exact API, including `;rev=2` when applicable. This tool
does not enumerate all APIs. Add `-ComponentName '<expected-component>'` to test
the destination against an explicit expectation; without it an observed target
is not declared wrong.

For another component/workspace resource group within the authorized subscription,
explicitly supply `-ComponentResourceGroup` and/or `-WorkspaceResourceGroup`.
Cross-subscription links are valid Azure arrangements but are not read by this
candidate: they remain a coverage gap, not a configuration fault.

To enable the optional workspace query:

```powershell
& $tool -ServiceName '<apim-name>' -ResourceGroup '<resource-group>' -ApiId '<api-id>' `
  -QueryRequests -StartTime '2026-01-01T00:00:00Z' -EndTime '2026-01-01T01:00:00Z'
```

Replace the example dates with the actual absolute UTC incident window, at most
24 hours. Querying first verifies the actual `AppRequests` column names, then
retrieves only aggregate counts scoped to the selected component. No URLs,
bodies, headers or unrestricted log rows leave the collector.

For an already authorized known synthetic run, optionally add:

```powershell
  -RunMarker '<synthetic-run-uuid>' -ExpectedRequests 20 -TraceId '<32-hex-trace-id>'
```

These arguments do not create requests. Counts/trace expectations require a run
marker. Exact-count comparisons are only meaningful for an appropriately
controlled, 100-percent-sampled run. Reduced sampling, lag, retention, querying
the wrong window and reader access must not be labeled network failures.

### Authentication and private scope

Signing in to Azure alone is not sufficient: the existing AzureIQ private profile
must authorize the same tenant, one selected subscription and expected principal.
This tool reuses the VNet reader's `config/local.azureiq.json` contract, including
`identity.interactivePrincipal` (or the existing `apimVnetReaderPrincipal` override).
Follow [the existing private-scope documentation](../../../../docs/execution-tools.md).

The profile stays Git-ignored. Never put real tenant/subscription/account values
in this README, ordinary command arguments, tracked examples or shareable reports.
`-Preflight` checks the reader without Azure resource reads. A missing/mismatched
profile produces a setup blocker; the tool does not repair authentication.

ARM configuration/role-reader rights and Log Analytics query rights are separate.
The optional query uses the maintained Azure CLI `monitor log-analytics query`
command with explicit subscription selection, not a manually extracted token or
a raw data-plane `az rest` call. If its CLI extension is unavailable, arrange its
installation explicitly in the testing window; automatic installation is disabled.

## Outputs and interpretation

Default report location:

```text
.azureiq/private-reports/api-management/application-insights/RUN-.../
  report.html
  report.json
```

The returned `HtmlReport` path is the report to open. Use `-NoOpen` only for
automation or when report opening is unwanted. Report-write/open failures are
explicitly reported. Files are ignored, reparse-point paths are rejected, and
audit records stay separately under `.azureiq/runs/RUN-.../execution-record.json`.

HTML has light/dark styling, searchable/filterable checks, print support and
green/red/yellow row indicators with `Pass`/`Fail`/`Unknown` text. Its three
sections are problem definition, diagnosis and root cause analysis. Collection,
configuration, delivery and causal confidence are independent facets.

Reports omit private identifiers, exact bound queries, connection strings,
tokens, captured payloads and raw native errors. Review reports before sharing.
The collector keeps raw read responses in memory only; it never saves a raw
snapshot. Git ignore is not encryption or a backup/sync exclusion.

| Exit | Meaning |
| --- | --- |
| 0 | Requested narrow checks passed; not a universal health verdict |
| 1 | Setup, input, collection or persistence failed |
| 2 | At least one demonstrated failed check |
| 3 | Unknown or incomplete evidence remains |

Exit 3 is expected when a protected identity selector or untested transport path
remains unknown. The tool never retrieves a secret to make a report green.

## Offline preview and tests

No Azure credentials or calls are used:

```powershell
& $tool -SnapshotPath '.\support-domains\api-management\tools\ApplicationInsightLogDiag\tests\example.snapshot.json'
& '.\support-domains\api-management\tools\ApplicationInsightLogDiag\tests\Test-ApimInsights.Tests.ps1'
& '.\support-domains\api-management\tools\ApplicationInsightLogDiag\tests\Test-ApimInsights.Collector.Tests.ps1'
```

The committed snapshot is synthetic, not customer evidence. Offline HTML is
prominently marked as offline. Live testing is deliberately left to the separately
authenticated window requested by the user.

## Coverage and release boundary

Managed classic APIM configuration is the initial scope. Other gateway/SKU models
remain explicitly unverified. Network evaluation uses the existing versioned
[VNet checker](../vnet-check/README.md), preserving its scope/freshness/unknown
boundaries rather than cloning or weakening its rules.

The diagnostic does not certify effective RBAC/deny assignments, AMPLS/private-DNS
transport, proxy/TLS interception, SDK buffering, quotas or transformations. A
forced-tunnel route or missing Request row does not alone establish root cause.
Root cause remains undetermined without independent causal evidence.

Network findings currently include the broad VNet assessment, not only the
logging path. Named platform observations retain dependency type, reported state,
optionality and freshness, including Application Insights ingestion when that
check is returned. A failed optional logging check can matter for this feature
without proving a core APIM outage. Not-applicable VNet results stay skipped
(gray), not passed. General network findings must not automatically be treated
as causes of missing Application Insights records.

No shared host, capability registry, catalog, agents or VNet source were modified.
Integration/promotion remains the owning team's review after live comparison.

- [Implementation contract](IMPLEMENTATION-HANDOFF.md)
- [Sources and validation status](SOURCES-AND-VALIDATION.md)
- [Separately approved fault/recovery experiments](FAULT-INJECTION-PLAN.md)
