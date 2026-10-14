# Copilot Invocation And Analysis

## User experience

The user can simply say:

> Check the networking for APIM `<name>` in resource group `<group>`, run all available read-only checks, and show me the HTML report with the issues explained.

Or use the optional `/apim-vnet-check` prompt in VS Code. The user does not need to select an AzureIQ specialist, know the SKU, or choose individual tests.

## Fixed workflow

1. Immediately run `-Describe` and, for live requests, `-Preflight` as the first operational batch. Read the matching registry/catalog entries in parallel. These registered commands do not require broad MCP discovery first; do not delay them for knowledge searches, AppLens, subagents or unrelated documentation. Describe makes no Azure calls; preflight checks only the existing CLI account against private scope and creates no report/run records.
2. If preflight fails, immediately prompt for the missing authentication/private-scope setup using the safe category. Explain that VS Code and Azure CLI have separate credentials. Ask approval before changing local context/profile or opening a sign-in wizard; never switch silently, broaden scope, retry a mismatch or install tooling. If the requested subscription differs from private scope, stop and request explicit alignment.
3. Resolve the APIM name/resource group from supplied or already verified session information. Only if the group is missing, perform one exact-name lookup in the authorized subscription using a discovered inventory tool, or prompt for the resource group. If several targets match, ask which one. Never scan arbitrary subscriptions.
4. Start `-ServiceName` / `-ResourceGroup` immediately after preflight and target resolution, or use `-SnapshotPath` directly for offline requests. Every applicable section runs automatically. Do not generate replacement collection scripts or recollect the same network solely to explain the report. AppLens and known-issue/source investigations, when needed for an actual symptom, are separate corroboration after the requested report has started; they must not block report generation.
5. Treat exit 2 and 3 as completed assessments, not command crashes. Parse the JSON command output, which contains `Report`, `HtmlReport`, `OperatorReport`, `AssessmentMode`, `RunId`, counts and section summaries. Live `HtmlReport` identifies a real target in the Git-ignored workspace private-report folder. Offline HTML is explicitly not live evidence. Exit 1 means abort: inspect only the safe category/audit record. Do not retry a scope mismatch or switch accounts.
6. Read sanitized `report.json`, first its `targetOverview` to confirm the discovered SKU, capacity, injection applicability, regions and selected rules, then its `sections`, failed findings and unknown findings by `sectionId`. Preserve captured and assessed timestamps. For large reports, use bounded section/status filtering rather than dumping the entire file. Detailed target/network names belong in the private operator report, not durable chat memory or incident records.
7. Present and link the returned live `HtmlReport` promptly, even if optional corroboration fails. Confirm version, persistence and browser readability. Summarize only collected configuration/platform findings, recommendations and unresolved collected evidence. Untested coverage entries are not findings or an action list; disclose them briefly without assigning manual TLS/FQDN/feature work by default. Name every missing endpoint and explain its preventive value. Explain the classic return-route recommendation as route-table creation/reuse, ApiManagement service-tag Internet UDR and APIM-subnet association; qualify future peering/gateway-transit/BGP protection and distinguish it from the inbound NSG TCP 3443 permit.
8. Link the finding's Microsoft documentation. Never claim all documentation requirements were tested: TLS, DNS answers, actual route/firewall behavior, optional features and active traffic paths can remain unknown. Root cause stays `undetermined` until corroborated.
9. Return any proposed mutation to change control for a separately approved manifest and independent verification. Do not automatically add NSG rules, enable endpoints, run probes, change DNS/routes, install tooling, change private scope or log in.

From the repository root:

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 -Describe
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 -Preflight

pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 `
    -ServiceName '<apim-name>' -ResourceGroup '<resource-group>'
```

When the hidden diagnostician cannot invoke a terminal, the active agent/Orchestrator runs this fixed registered command and passes the sanitized JSON to the diagnostician. Do not broaden the specialist's permissions or tell the user to select a different agent. Copilot routing remains model-directed, not an authorization engine.

## Output contract

- `report.json`: machine-readable sections plus flat findings with human-readable `title`, specific `assessment`, raw `status`, expected/observed configuration, next step, `dependencyEvidence` source/freshness metadata and documentation. Explain the specific evidence state instead of repeating the raw Unknown label.
- `report.html`: self-contained, searchable, filterable, expandable and printable human report. No CDN, telemetry or background Azure calls.
- `execution-record.json`: sanitized audit record including report references and candidate version.
- Sanitized outputs stay under ignored `.azureiq/runs/`. Live runs write `operator-report.json` and detailed HTML to Git-ignored `.azureiq/private-reports/api-management/vnet-check/RUN-.../` in the trusted workspace. The writer verifies the ignore rule and rejects reparse points. Private reports include direct portal links containing resource/subscription identifiers as approved for customer troubleshooting; sanitized outputs never include these links or identifiers. Tenant/principal IDs, credentials and raw errors remain excluded. Never force-add or publish private reports.
- Present actual APIM service, SKU, region, VNet/subnet, NSG and route table before findings and recommendations. Detailed inventory stays collapsed below the findings. Distinguish configured injection from proven connectivity; unsupported models remain Needs review rather than pretending they were tested.
- Never call an offline/synthetic preview a live APIM assessment. Only a successful live collector invocation establishes live provenance; it still does not prove traffic health.
- Reports are point-in-time snapshots, not continuous monitoring. A user request to refresh means a new explicitly scoped run, not an unattended loop.
- Platform dependency findings have readable names and identify their source: APIM GET /networkstatus (2024-05-01), not a tool-generated traffic probe. Show reported status, required/optional, original timestamps and freshness. The private service link and navigation to Deployment + infrastructure > Network > Network status let customers inspect current errors. Never treat stale successful checks as current passes.
- Display all captured APIM network connection statuses directly in their unfiltered table, including successes. Configuration filters must not hide those rows or the section. Do not ask users to recheck statuses already collected; portal instructions are supplementary for raw/current errors or newer observations.
- Each check must show its concrete requirement, not a generic instruction to read documentation. Private sections identify and link affected resources locally. Live classic endpoint/routing sections offer a copyable GHC change-plan request; explain that copying/pasting is not write approval and the static report cannot execute changes. GHC must refresh state, plan, obtain exact approval, respect effective safety mode and use a supported execution/verification path.

## Validation and maturity

The previous baseline returned a flat JSON file and required the agent to infer command semantics and report grouping. Version 0.2 adds one discovery command, a reusable prompt, explicit section summaries, and the same structured findings in JSON/HTML. Offline acceptance tests cover all twelve sections, service-endpoint alternatives, NSG match evidence, output encoding, documentation links and entrypoint artifacts.

Version 0.2.2 moves private reports into the Git-ignored trusted workspace folder, adds unfiltered durable safeguard recommendations, and flags discard default UDRs explicitly. Version 0.2.1 added immediate authentication preflight, preventive endpoint/return-route guidance, forced-tunnel safeguard evaluation, support inventory and corrected native UTC handling. The workflow remains candidate pending Premium v2 and controlled failure-path comparisons. Authentication interaction time and optional research must be measured separately from collector runtime.

Version 0.3.0 adds actual-configuration-first layout, specific customer evidence
states, named platform checks with provenance and private portal navigation.
It improves subnet-aware NSG certainty without suppressing unresolved denies.

Version 0.3.1 adds explicit criteria for each check, in-section target links and
an approval-gated, copyable GHC change-plan handoff for live classic endpoint
and routing findings.

Version 0.3.2 keeps hypothetical/untested areas out of the published finding
tables and summarizes them only as coverage limits. Route recommendations
state the concrete table, route and association operations and why they are
preventive rather than a blanket guarantee about future peering.

Version 0.3.3 puts all collected network connection statuses in an independent
always-visible table rather than hiding successes behind the attention filter.
