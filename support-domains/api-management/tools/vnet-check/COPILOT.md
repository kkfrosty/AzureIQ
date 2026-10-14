# Copilot Invocation And Analysis

## User experience

The user can simply say:

> Check the networking for APIM `<name>` in resource group `<group>`, run all available read-only checks, and show me the HTML report with the issues explained.

Or use the optional `/apim-vnet-check` prompt in VS Code. The user does not need to select an AzureIQ specialist, know the SKU, or choose individual tests.

## Fixed workflow

1. Discover live MCP/extension capabilities, then read `apim.vnet-configuration.assess` in the capability registry and `apim.vnet-check` in the artifact catalog. This registered standalone read-only diagnostic is not a mutation subcommand in the shared execution host.
2. Resolve the requested APIM name/resource group from user context or scoped inventory. If several targets match, ask which one; never scan arbitrary subscriptions. For a symptom-driven incident, use AppLens first and retain its outcome as separate evidence, not a substitute for running the requested checker.
3. Run the command below with `-Describe` to read its current machine-readable contract. This requires no Azure authentication and creates no run records. Do not reconstruct arguments, sections or exit codes from memory.
4. Run the same command with either `-ServiceName` and `-ResourceGroup`, or `-SnapshotPath`. Every applicable section runs automatically; no extra "all" flag is needed. Pass names as literal argument values, not executable command text.
5. Treat exit 2 and 3 as completed assessments, not command crashes. Parse the JSON command output, which contains `Report`, `HtmlReport`, `OperatorReport`, `AssessmentMode`, `RunId`, counts and section summaries. Live `HtmlReport` identifies a real target in a private user-local report outside the repository. Offline HTML is explicitly not live evidence. Exit 1 means abort: inspect only the safe category/audit record. Do not retry a scope mismatch or switch accounts.
6. Read sanitized `report.json`, first its `targetOverview` to confirm the discovered SKU, capacity, injection applicability, regions and selected rules, then its `sections`, failed findings and unknown findings by `sectionId`. Preserve captured and assessed timestamps. For large reports, use bounded section/status filtering rather than dumping the entire file. Detailed target/network names belong in the private operator report, not durable chat memory or incident records.
7. Present and link `report.html` and a short section table: failed checks, unknowns, reason, and next evidence needed. Highlight NSG direction/protocol/source/destination/port and matched rule priority; distinguish missing permits from an ambiguous earlier match. Service endpoints may have valid firewall alternatives.
8. Link the finding's Microsoft documentation. Never claim all documentation requirements were tested: TLS, DNS answers, actual route/firewall behavior, optional features and active traffic paths can remain unknown. Root cause stays `undetermined` until corroborated.
9. Return any proposed mutation to change control for a separately approved manifest and independent verification. Do not automatically add NSG rules, enable endpoints, run probes, change DNS/routes, install tooling, change private scope or log in.

From the repository root:

```powershell
pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 -Describe

pwsh -NoProfile -File .\support-domains\api-management\tools\vnet-check\Test-ApimVnet.ps1 `
    -ServiceName '<apim-name>' -ResourceGroup '<resource-group>'
```

When the hidden diagnostician cannot invoke a terminal, the active agent/Orchestrator runs this fixed registered command and passes the sanitized JSON to the diagnostician. Do not broaden the specialist's permissions or tell the user to select a different agent. Copilot routing remains model-directed, not an authorization engine.

## Output contract

- `report.json`: machine-readable sections plus flat findings with `sectionId`, expected/observed configuration, next step, evidence category/timestamp and documentation.
- `report.html`: self-contained, searchable, filterable, expandable and printable human report. No CDN, telemetry or background Azure calls.
- `execution-record.json`: sanitized audit record including report references and candidate version.
- Sanitized outputs stay under ignored `.azureiq/runs/`. Live runs also write `operator-report.json` and detailed HTML to `LocalApplicationData\AzureIQ\Reports\RUN-...`, outside the repository. This is the approved user-local operator-report boundary, not a raw-payload store. Link the returned `HtmlReport`; do not publish it. Neither boundary stores tenant/subscription/principal IDs or full resource IDs.
- Present the target/SKU/network overview before interpreting findings. Distinguish configured injection from proven connectivity. For mode `None`, injection-only sections are skipped; unsupported SKUs/models remain unknown.
- Never call an offline/synthetic preview a live APIM assessment. Only a successful live collector invocation establishes live provenance; it still does not prove traffic health.
- Reports are point-in-time snapshots, not continuous monitoring. A user request to refresh means a new explicitly scoped run, not an unattended loop.

## Validation and maturity

The previous baseline returned a flat JSON file and required the agent to infer command semantics and report grouping. Version 0.2 adds one discovery command, a reusable prompt, explicit section summaries, and the same structured findings in JSON/HTML. Offline acceptance tests cover all twelve sections, service-endpoint alternatives, NSG match evidence, output encoding, documentation links and entrypoint artifacts.

The report/workflow is candidate and live/model-routing effectiveness remains unproven. Compare repeatability and operator effort against the previous workflow before promotion.
