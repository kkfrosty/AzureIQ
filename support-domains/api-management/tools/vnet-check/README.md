# APIM VNet Checker

**Version:** 0.2.0

**Status:** candidate; value unproven; offline tested, not live validated.

This read-only PowerShell tool discovers the APIM SKU and network mode. It selects separate rules for classic Developer/Premium injection (internal or external) and Premium v2 injection (internal). It never applies classic management-port or delegation rules to Premium v2.

It does not deploy, change NSGs/routes/DNS, register providers, fetch keys, change authentication, or generate gateway/backend traffic. It cannot certify that traffic flows based on configuration alone.

## Why a tool?

Baseline: Azure MCP exposes conversational AppLens diagnosis and resource/configuration discovery, and AzureIQ already has [gateway request evidence](../../queries/request-evidence.kql) and an [unexpected-response runbook](../../runbooks/unexpected-response.md). No compatible VNet rule evaluator exists in the artifact catalog.

Observed tooling limitation: the discovered AppLens surface exposes one conversational diagnosis command, not a versioned deterministic VNet rule matrix or offline fixture runner. This is a repeatability gap, not proof that AppLens cannot diagnose a specific incident. No live comparison has been performed for VNet-injected APIM.

Expected improvement: reproducible SKU-specific findings, ordered NSG evaluation, explicit missing evidence and privacy-preserving output. Acceptance: both SKU families, delegation/minimum-prefix differences, higher-priority denies, ambiguous address overlap, native-status freshness, scope rejection and redaction must pass offline tests. Retention remains pending a live baseline comparison.

## Requirements

- PowerShell 7.4 or later.
- Live collection additionally requires an installed Azure CLI, an already authenticated AzureCloud account and read permissions.
- Exactly one tenant/subscription in ignored `config/local.azureiq.json`; no tenant/subscription CLI parameters.
- The selected Azure CLI account must match the configured tenant, subscription and principal. The tool does not use or switch the VS Code credential.
- Put the exact expected Azure CLI `user.name` in private `identity.apimVnetReaderPrincipal`, or use an exact `identity.interactivePrincipal`. A generic `azure-extension-current-user` label does not establish a CLI principal match and will be rejected. Do not commit the actual account label.
- Reader access to APIM, its VNets/subnets, NSGs and route tables is sufficient for the configuration GETs. Native network-status read also requires `Microsoft.ApiManagement/service/networkstatus/read`. Missing permissions become explicit evidence gaps, except the initial service/authentication read, which aborts.

The CLI fallback is used because this repeatable standalone collector cannot invoke editor-only MCP tools, and no dedicated generic APIM management router was discovered. All resource operations are allowlisted ARM GETs. Azure CLI authentication context is checked immediately before every resource read. Cross-subscription network references are rejected rather than broadening scope.

Each CLI process has a 60-second timeout, and collection is limited to ten service locations. There are no retries or automatic credential installation/login steps. Resource names use a deliberately restricted ASCII character set; unsupported names fail explicitly.

## Run against an APIM service

### Ask GitHub Copilot

Say: **"Check the networking for APIM `<name>` in resource group `<group>`, run all available read-only checks, and explain the HTML report."**

Workspace routing and the optional `/apim-vnet-check` prompt point to [the fixed Copilot workflow](COPILOT.md). Copilot discovers arguments with `-Describe`, runs every applicable section, reads the JSON, and links the HTML. Users do not need to know the SKU or select tests. Unknown/manual evidence remains explicit.

### Command line

From the repository root, using placeholders replaced at runtime:

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 `
    -ServiceName '<apim-service-name>' `
    -ResourceGroup '<resource-group-name>'
```

The tool discovers every service location and reads the referenced subnet, VNet, NSG and route table. It attempts the native APIM `networkstatus` GET for both supported SKU families, treating unsupported or unavailable responses as unknown rather than assuming Premium v2 exposes classic platform dependencies.

For the machine-readable invocation contract, supported sections, output names and exit codes:

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 -Describe
```

This command makes no Azure calls and creates no assessment records.

Private authentication scope stays in memory. Tenant/subscription/principal identifiers, raw service responses, certificates, native hostnames/errors and full resource IDs are never exported. The collector does not export raw snapshots.

Live runs additionally create a private operator HTML/JSON report under the current user's local application-data folder, `AzureIQ\Reports\RUN-...`, outside the repository. This report intentionally contains APIM/resource-group/VNet/subnet/NSG/route-table names, address spaces, subnet prefixes and custom DNS IPs. This is operational metadata, not a publishable artifact: do not commit, share publicly or copy it into chat memory. It inherits the user-local folder's access permissions; it is not encrypted. The tool rejects paths inside the workspace or through filesystem reparse points instead of silently falling back to repository storage.

## Offline assessment

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 `
    -SnapshotPath '<private-or-synthetic-snapshot.json>'
```

Offline mode makes no Azure calls and requires no Azure credentials. A snapshot has `schemaVersion: 1`, ISO-8601 `capturedAt`, a service GET-shaped `service`, and a `regions` array. Each region contains its `location`, optional `capacity`, `subnet`, `virtualNetwork`, `networkSecurityGroup`, optional `routeTable`, and `evidenceGaps`. Optional `nativeNetworkStatus` contains `available` and the REST API's bare-array result as `locations`.

Use only synthetic fixtures in Git. Private configuration captures belong in approved external evidence storage or the ignored raw-evidence boundary, never this tools directory. Offline snapshots are untrusted data; no values are evaluated as commands.

The [test suite](tests/Test-ApimVnet.Tests.ps1) constructs synthetic classic and Premium v2 snapshots and demonstrates the input shape.

## Results

Every completed assessment writes sanitized `report.json`, a self-contained sanitized `report.html`, and a schema-conforming `execution-record.json` beneath ignored `.azureiq/runs/RUN-.../`. These files contain no target names or address literals. Audit privacy assertions describe these sanitized run artifacts; detailed operator reports are kept separately outside the repository.

For live runs, `HtmlReport` points to the private operator HTML and `OperatorReport` to its private JSON. `Report` always points to the sanitized analysis JSON; `AssessmentMode` distinguishes live collection from offline input. Offline runs do not create detailed operator reports, and their HTML prominently states **OFFLINE / SNAPSHOT - NOT LIVE AZURE EVIDENCE**. Synthetic test previews must never be presented as a real-service diagnosis.

The opening overview shows the exact discovered SKU, capacity, primary region, provisioning state, network mode, injection applicability and selected SKU-specific rules. Each collected location maps to the finding's region ordinal and includes VNet region, regional capacity, subnet evidence, prefix sizes, DNS mode, attachments and collection gaps. The live private report also identifies the APIM/resource group and network names/settings. Unreadable metadata is explicitly unavailable. A configured injection mode is not proof of connectivity; incomplete subnet references are flagged. Noninjected services skip injection-specific checks, and unsupported SKUs/models remain inconclusive.

The JSON command output includes report paths and a section summary. Findings include expected/observed configuration, next steps, ordinal region references, documentation links and safe evidence. NSG findings identify the matched rule priority/ordinal without retaining private rule names or address literals.

The HTML has twelve navigable sections: discovery, subnet/capacity, NSGs, service endpoints, routing, DNS, native dependency status, TLS, client/backend traffic, optional features, infrastructure egress, and evidence quality. Failed and unknown checks are shown first. Search, status filters, expandable sections, count summaries and print support make it usable without reading raw JSON. Documentation areas without automated evidence are visible unknowns, not omitted passes.

Reports retain problem definition, diagnosis and root cause analysis; root cause stays `undetermined` without causal traffic evidence. Reports are point-in-time snapshots: rerun to refresh, not continuous monitoring. No CDN, telemetry, external assets or background network calls are used.

Aborted assessments also attempt to write a sanitized failure execution record. Permission and unsupported-API gaps retain only allowlisted diagnostic categories, not raw Azure errors. If the audit record cannot be written, that failure is reported explicitly.

| Finding | Meaning |
| --- | --- |
| `Pass` | This specific configuration check or fresh native observation passed; not proof of connectivity |
| `Fail` | A documented constraint is violated or a fresh required native dependency reports failure |
| `Unknown` | Missing, stale, unsupported or ambiguous evidence; requires additional investigation |

| Process exit | Meaning |
| --- | --- |
| 0 | Metadata discovery with `-Describe`; not a service-health verdict |
| 1 | Input, scope, authentication, initial read or tool failure; no success verdict |
| 2 | Assessment completed with at least one failed check; see the report |
| 3 | Assessment completed without failed checks, but connectivity remains inconclusive |

Version 0.2.0 intentionally has no healthy/exit-zero service assessment verdict. A clean static configuration does not establish correct DNS, routing, backend behavior or policy execution. Successful metadata discovery and test-suite execution exit zero.

Native observations older than 30 minutes or more than five minutes in the future are unknown. Use `-MaxStatusAgeMinutes` to change the age threshold. Stale configuration captures are labeled; their findings describe captured configuration, not current live state.

## Evaluated checks and limits

| Area | Evaluation |
| --- | --- |
| SKU/mode | Automatic discovery; unsupported SKU/mode, integration, private endpoints and workspace gateways are unknown |
| Placement | Per-location VNet region and subscription comparison |
| Subnet | Classic minimum /29 with no delegation; Premium v2 minimum /27 with `Microsoft.Web/hostingEnvironments` delegation |
| Capacity | Classic minimum reserved/unit/load-balancer address arithmetic; actual free addresses and upgrade headroom remain unknown |
| NSG | Attachment; ordered custom/default rules, direction, protocol, singular/plural address and port selectors, port ranges |
| Classic dependencies | Management 3443, external HTTPS 443, Premium probe 6390, certificate HTTP 80, Storage 443, SQL 1433, Key Vault 443, Azure Monitor 1886/443 |
| Regional tags | Storage/SQL coverage evaluated for both local and primary regions |
| Service endpoints | Classic Storage, SQL, Event Hubs and Key Vault endpoint presence/provisioning; SQL recommendation limited to primary region. Missing endpoints are unknown because firewall routing can be a valid alternative. Premium v2 does not inherit classic recommendations. |
| Premium v2 dependencies | Key Vault 443, without imposing classic control-plane requirements |
| DNS | Custom resolver UDP/TCP 53 NSG checks; actual resolution, forwarding and internal gateway DNS remain unknown |
| Routes | Default UDR/forced-tunnel investigation and classic management return-path guidance; not effective-route proof |
| Native status | Required vs optional dependencies, success/failure and timestamp freshness; no raw hostname/error retention |

Service tags can overlap. Without resolved service-tag prefixes, IP/CIDR rules or different tags that might match cause `Unknown` when they precede an otherwise decisive rule. Application security groups and restricted source-port coverage also remain unknown. This avoids falsely certifying an allow simply because a matching allow rule exists.

No tests are run from inside APIM's managed compute. The checker does not inspect every firewall, effective BGP route, peering, Private DNS link/record, backend policy, certificate chain, SNI or client path. Optional caches, synchronization, Traffic Manager, Event Hubs, Entra/credential-manager features, NTP and FQDN-based infrastructure dependencies need additional evidence. See [the reviewed source matrix](SOURCES.md).

Do not treat absent logs or unknown findings as either health or failure. Follow the [incident workflow](../../runbooks/unexpected-response.md) when a user-visible symptom exists; remediation requires a separately approved change and independent verification.

## Validate

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\tests\Test-ApimVnet.Tests.ps1
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\tests\Test-ApimVnet.Collector.Tests.ps1
.\scripts\Test-Workspace.ps1
```

The tests are deterministic and make zero Azure calls. Live acceptance remains outstanding: compare known-good classic and Premium v2 services against AppLens/MCP under equivalent permissions, then reproduce selected misconfigurations only in a separately approved disposable environment. Do not inject faults or create resources as part of this checker.

To retain a synthetic HTML demonstration generated by the actual evaluator and renderer, run the assessment test suite with `-KeepSampleReport`. Its final output supplies `SyntheticSampleHtml`; the report is labeled offline and is not a live diagnosis.
