# APIM VNet Checker

**Version:** 0.3.3

**Status:** candidate; offline regression tested and scoped classic live collection exercised; Premium v2 live comparison and controlled failure-path validation remain pending.

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

When CLI discovery returns multiple applications on Windows, the collector uses
the first resolved launcher rather than passing multiple paths to process startup.

## Run against an APIM service

### Ask GitHub Copilot

Say: **"Check the networking for APIM `<name>` in resource group `<group>`, run all available read-only checks, and explain the HTML report."**

Workspace routing and the optional `/apim-vnet-check` prompt point to [the fixed Copilot workflow](COPILOT.md). Copilot starts `-Describe` and `-Preflight` immediately, prompts for authentication or missing target details, runs every applicable section, and links the persisted private HTML promptly. Optional research must not delay the checker. Users do not need to know the SKU or select tests.

Authentication preflight checks the existing CLI account against private scope
without resource reads, login, context changes, or report/run creation:

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 -Preflight
```

Exit zero means the local reader context is ready, not that the service is healthy.

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

Private authentication scope stays in memory. Raw service responses, credentials,
certificates and native hostnames/errors are never exported. Sanitized reports
exclude all resource and authentication-scope identifiers. The private operator
report includes resource/subscription identifiers only inside validated direct
Azure Portal links, as approved for local troubleshooting; it excludes tenant
and principal identifiers. The collector does not export raw snapshots.

Live runs create private operator HTML/JSON under the standard Git-ignored
workspace folder `.azureiq/private-reports/api-management/vnet-check/RUN-.../`.
Keeping reports within the trusted workspace allows the integrated browser to
read them without changing folder trust. The writer requires the
`.azureiq/private-reports/` exclusion in the workspace's `.gitignore` and rejects
filesystem reparse points. Git ignore prevents normal Git inclusion, not an
explicit force-add or unrelated filesystem/cloud backup.

Reports contain APIM/resource-group/VNet/subnet/NSG/route-table names, address
spaces, subnet prefixes and custom DNS IPs. They are local operational metadata,
not publishable artifacts: do not force-add, commit, publish, or copy them into
durable chat memory. They inherit workspace filesystem permissions and are not
encrypted. Secrets, raw responses and authentication actor identifiers remain
excluded; resource IDs are present only in approved private portal links.

## Offline assessment

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 `
    -SnapshotPath '<private-or-synthetic-snapshot.json>'
```

Offline mode makes no Azure calls and requires no Azure credentials. A snapshot has `schemaVersion: 1`, ISO-8601 `capturedAt`, a service GET-shaped `service`, and a `regions` array. Each region contains its `location`, optional `capacity`, `subnet`, `virtualNetwork`, `networkSecurityGroup`, optional `routeTable`, and `evidenceGaps`. Optional `nativeNetworkStatus` contains `available` and the REST API's bare-array result as `locations`.

Use only synthetic fixtures in Git. Private configuration captures belong in approved external evidence storage or the ignored raw-evidence boundary, never this tools directory. Offline snapshots are untrusted data; no values are evaluated as commands.

The [test suite](tests/Test-ApimVnet.Tests.ps1) constructs synthetic classic and Premium v2 snapshots and demonstrates the input shape.

## Results

Every completed assessment writes sanitized `report.json`, a self-contained sanitized `report.html`, and a schema-conforming `execution-record.json` beneath ignored `.azureiq/runs/RUN-.../`. These files contain no target names or address literals. Audit privacy assertions describe these sanitized run artifacts; detailed operator reports are kept separately in ignored `.azureiq/private-reports/api-management/vnet-check/RUN-.../`.

For live runs, `HtmlReport` points to the private operator HTML and `OperatorReport` to its private JSON. `Report` always points to the sanitized analysis JSON; `AssessmentMode` distinguishes live collection from offline input. Offline runs do not create detailed operator reports, and their HTML prominently states **OFFLINE / SNAPSHOT - NOT LIVE AZURE EVIDENCE**. Synthetic test previews must never be presented as a real-service diagnosis.

The opening overview shows the exact discovered SKU, capacity, primary region, provisioning state, network mode, injection applicability and selected SKU-specific rules. Each collected location maps to the finding's region ordinal and includes VNet region, regional capacity, subnet evidence, prefix sizes, DNS mode, attachments and collection gaps. The live private report also identifies the APIM/resource group and network names/settings. Unreadable metadata is explicitly unavailable. A configured injection mode is not proof of connectivity; incomplete subnet references are flagged. Noninjected services skip injection-specific checks, and unsupported SKUs/models remain inconclusive.

The JSON command output includes report paths and a section summary. Findings include expected/observed configuration, next steps, ordinal region references, documentation links and safe evidence. NSG findings identify the matched rule priority/ordinal without retaining private rule names or address literals.

The HTML starts with **actual APIM and VNet configuration**, clearly separated
from recommendations. Resource names, tier, region, subnet prefixes, NSG,
route table and configured endpoints appear before the detailed inventory.
Private-only links open the service and network resources in Azure Portal.
Technical inventory is collapsed at the bottom rather than pushing context
below a long NSG table.

Each check has a human-readable title and a specific `assessment`: `Issue`,
`Optional feature issue`, `Recommendation`, `Checked`, `Needs review`,
`Unavailable evidence`, `Stale evidence`, `Not tested`, or `Not applicable`.
The existing machine `status` (Pass/Fail/Unknown/NotApplicable) is retained
separately; it is not the customer-facing label. Missing safeguards are known
recommendations, not uncertain configuration. Stale and untested paths never
become passes merely to remove uncertainty. `assessmentSummary` accounts for
every machine-record entry. The published findings, counts and filters exclude
`Not tested` placeholders. A collapsed coverage-limits note lists unimplemented
areas without presenting them as faults or assigning remediation work.

The main report is limited to collected APIM/network configuration and APIM
platform Network status observations. It does not publish standalone TLS,
infrastructure/FQDN, optional-feature-usage or client/backend-log sections when
no evidence was collected for them. DNS resolver NSG checks still appear when
actual resolver configuration was evaluated, without claiming DNS answers were
tested. Machine JSON retains the coverage inventory for technical consumers;
CLI `NotAssessedChecks` discloses omitted checks separately from the evidence
summary. Extend the published diagnostics only when collection and validation
for the new evidence source are implemented.

The management return-route recommendation explicitly proposes creating or
reusing a route table, adding destination type `Service tag`, destination
`ApiManagement`, next hop `Internet`, and associating it with the APIM subnet.
It explains preventive protection against a future default/appliance route or
peering with gateway transit/BGP that redirects management replies. Peering
alone is not a fault, the route does not protect every APIM flow, and
more-specific conflicts still need effective-route review.

Every check also states its specific requirement: region/subscription
placement, tier-specific subnet minimum, actual NSG flow, DNS answer/port
expectation or named dependency/freshness criteria. The generic "meet the
applicable requirement" fallback is removed; a missing rule definition aborts
explicitly instead of generating a vague recommendation.

Private sections repeat their actual APIM and relevant VNet/subnet targets
with validated portal links, rather than requiring users to return to the
overview. NSG and routing sections also link the applicable NSG/route table.
The endpoint section gives the exact VNet > Subnets > selected subnet >
Service endpoints navigation.

Live classic endpoint/routing sections include a "Plan this change with GHC"
handoff. The copyable request contains observed target context, capture time,
specific proposed settings and the change-control steps: refresh current
state, confirm private scope, produce an action manifest/diff/what-if, assess
RBAC and risk, provide rollback/abort/verification, ask explicit approval,
and execute only through authorized supported tools with independent
verification. Copying the request grants no write approval. The static HTML
cannot invoke Copilot or mutate Azure; paste the request into Copilot Chat.
If browser clipboard access fails, the report explicitly reports the failure
and selects the request for manual Ctrl+C. Offline and sanitized reports do
not offer scoped live-change handoffs.

Platform dependencies are named (for example, "APIM management endpoint -
inbound connectivity"), not identified primarily by a rule number.
They appear in a dedicated **APIM network connection status** table showing
every collected success and failure, required/optional classification,
observation UTC timestamp, last status change, freshness at capture and
error availability. Configuration filters and searches never hide this
table or its rows. Summary totals cover all collected evidence; filter
totals refer only to configuration checks and explain that connection
statuses remain visible separately. Portal navigation is a supplement for
current/raw errors or newer data, not a replacement for the captured statuses.
`dependencyEvidence` retains the safe resource type, Azure-reported status,
required/optional flag, original last-updated/last-status-change UTC timestamps,
freshness limit and whether an error was returned. The source is the APIM
platform Network status API, `GET /networkstatus`, API version `2024-05-01`;
the tool does not actively probe or refresh these periodic platform checks.
Use the private service link, then **Deployment + infrastructure > Network >
Network status**, select Required or Optional, and expand the named dependency
to inspect current endpoint/error details. Raw errors remain excluded here.

Reports retain problem definition, diagnosis and root cause analysis; root cause stays `undetermined` without causal traffic evidence. Reports are point-in-time snapshots: rerun to refresh, not continuous monitoring. No CDN, telemetry, external assets or background network calls are used.

Aborted assessments also attempt to write a sanitized failure execution record. Permission and unsupported-API gaps retain only allowlisted diagnostic categories, not raw Azure errors. If the audit record cannot be written, that failure is reported explicitly.

| Finding | Meaning |
| --- | --- |
| `Pass` | This specific configuration check or fresh native observation passed; not proof of connectivity |
| `Fail` | A documented constraint is violated or a fresh required native dependency reports failure |
| `Unknown` | Missing, stale, unsupported or ambiguous evidence; requires additional investigation |

| Process exit | Meaning |
| --- | --- |
| 0 | Metadata discovery with `-Describe` or ready authentication `-Preflight`; not a service-health verdict |
| 1 | Input, scope, authentication, initial read or tool failure; no success verdict |
| 2 | Assessment completed with at least one failed check; see the report |
| 3 | Assessment completed without failed checks, but connectivity remains inconclusive |

Version 0.3.3 intentionally has no healthy/exit-zero service assessment verdict. A clean static configuration does not establish correct DNS, routing, backend behavior or policy execution.

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
| Service endpoints | Explicit proactive recommendations for Storage, primary-region SQL, Key Vault and optional Event Hubs. Missing endpoints are warnings without observed forced tunneling. A default UDR to VirtualAppliance/VirtualNetworkGateway escalates absent core endpoints to required safeguard gaps (`Fail`), not confirmed outage causes; a verified maintained firewall alternative can satisfy connectivity. Event Hubs applicability remains unknown until feature use is established. Premium v2 does not inherit classic recommendations. |
| Premium v2 dependencies | Key Vault 443, without imposing classic control-plane requirements |
| DNS | Custom resolver UDP/TCP 53 NSG checks; actual resolution, forwarding and internal gateway DNS remain unknown |
| Routes | Classifies `0.0.0.0/0` next hops; Internet is not forced tunneling, and None is an explicit discard-route finding (`Fail`) without asserting all flows are affected. Checks global `ApiManagement` -> `Internet` successful UDR provisioning separately from NSG TCP 3443. Missing/wrong return safeguard is `Fail` under configured forced tunneling; regional-tag coverage, IP-route alternatives, BGP and effective behavior remain unknown. |
| Native status | Safe dependency type, observed status, required/optional and UTC freshness, including DateTime values produced by JSON parsing; no raw hostname/error retention |

Service endpoints are recommended from the start: they introduce more-specific
Azure-backbone dependency routes that protect against later default-route changes.
They do not protect every dependency, and enabling them changes routing and can
affect existing firewall designs. Propose changes for approval, never apply them
automatically. Under forced tunneling, missing endpoint findings identify an
unmet recommended safeguard, not proof that a valid firewall alternative is
absent or that APIM is down.

The private HTML/JSON includes configured custom/default NSG rules (priority,
direction, protocol, address and port selectors), endpoint provisioning, route
prefix/service tag, next-hop type/IP, and BGP propagation metadata. It is
self-contained, printable and light/dark themed. Review before sending through
an approved Microsoft support channel; sanitized reports omit this inventory.

A prominent, unfiltered "Recommended durable network safeguards" panel lists
endpoint recommendations, the `ApiManagement` service-tag Internet UDR and the
separate inbound TCP 3443 NSG permit even when the current default route is
removed or changed. These safeguards do not restore every path affected by a
discard default route and must be reviewed against intended firewall policy.

NSG evaluation uses collected APIM subnet prefixes for subnet-side address
matching, including CIDR containment and disjointness. Service tags can overlap:
possible earlier matches cause `Needs review` only when their access could
change the decision. When every possible earlier match agrees with a guaranteed
fallback rule, the allow/deny outcome is established even if the exact winning
rule is not. Partial-subnet coverage, ASGs, restricted source ports and possible
earlier opposite-access rules remain qualified; no effective-path health is
inferred from a configuration allow.

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
