# AzureIQ Support Domains

Support domains isolate Azure-service-specific knowledge, queries, baselines, alerts, tests, and runbooks from the global agent context. A domain does not grant permissions or standing approval.

## Lifecycle

1. `draft`: designed but not verified against a scoped resource.
2. `observed`: discovery and telemetry queries verified read-only.
3. `supervised`: changes or runbooks executed with explicit approval and independent verification.
4. `policy-eligible`: a specific bounded runbook meets the automation contract.
5. `retired`: unsupported and ineligible for action.

No pack or runbook skips directly to `policy-eligible`.

Maturity does not prove value. Every pack also carries a comparison status: `unproven`, `baseline-recorded`, `value-demonstrated`, or `no-value`. A technically correct artifact is retired when Azure MCP or an installed skill already produces an equivalent result without sacrificing safety or repeatability.

## Requirements

- Follow the [support-domain contract](../.github/skills/azureiq-service-onboarding/references/support-domain-contract.md).
- Discover current diagnostic categories and API support from the target resource; do not assume static lists.
- Link authoritative Microsoft documentation and record the review date.
- Keep secrets, tokens, keys, customer payloads, and raw telemetry outside Git.
- Validate queries against the actual table plan and schema.
- Route all writes through the AzureIQ change-control workflow.
- Require independent verification before learning from an outcome.
- Record the baseline Azure MCP behavior, observed gap, smallest targeted artifact, acceptance criteria, comparison result, and `keep`, `revise`, or `retire` decision.

## Ownership And Collaboration

- Place each artifact in the pack for the Azure resource provider or telemetry plane that produces the evidence, not the service that consumes it.
- Keep symptom-oriented runbooks in the pack where diagnosis begins, and reference collaborating packs instead of copying their queries or baselines.
- Azure Monitor owns cross-service telemetry schemas and distributed-trace joins. Support domains own their resource-specific logs, configuration, health, and platform behavior.
- A collaboration states the owning pack, referenced artifact, purpose, correlation key, workspace or destination assumptions, and behavior when evidence is unavailable.
- Networking is an umbrella routing boundary. Split focused packs such as Front Door, Application Gateway/WAF, Firewall, DNS, or Private Link when their artifacts become substantial or independently validated.

## Packs

| Pack | Status | Value proof | Purpose |
| --- | --- | --- | --- |
| [API Management](api-management/README.md) | `observed` | `value-demonstrated` | First end-to-end gateway, policy, backend, identity, telemetry, and unexpected-response exemplar |
| [Azure Monitor](azure-monitor/README.md) | `observed` | `value-demonstrated` | Shared Application Insights and Log Analytics correlation across instrumented services |
| [Container Apps](container-apps/README.md) | `observed` | `value-demonstrated` | Revision, replica, scaling, ingress, image, and managed-environment platform evidence |
| [App Service](app-service/README.md) | `draft` | `unproven` | Routing boundary for App Service-specific diagnostics and operations |
| [Networking](networking/README.md) | `draft` | `unproven` | Umbrella routing boundary for Azure network paths and future product-specific packs |