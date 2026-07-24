# AzureIQ Service Packs

Service packs isolate Azure-service-specific knowledge, queries, baselines, alerts, tests, and runbooks from the global agent context. A pack does not grant permissions or standing approval.

## Lifecycle

1. `draft`: designed but not verified against a scoped resource.
2. `observed`: discovery and telemetry queries verified read-only.
3. `supervised`: changes or runbooks executed with explicit approval and independent verification.
4. `policy-eligible`: a specific bounded runbook meets the automation contract.
5. `retired`: unsupported and ineligible for action.

No pack or runbook skips directly to `policy-eligible`.

Maturity does not prove value. Every pack also carries a comparison status: `unproven`, `baseline-recorded`, `value-demonstrated`, or `no-value`. A technically correct artifact is retired when Azure MCP or an installed skill already produces an equivalent result without sacrificing safety or repeatability.

## Requirements

- Follow the [service-pack contract](../.github/skills/azureiq-service-onboarding/references/service-pack-contract.md).
- Discover current diagnostic categories and API support from the target resource; do not assume static lists.
- Link authoritative Microsoft documentation and record the review date.
- Keep secrets, tokens, keys, customer payloads, and raw telemetry outside Git.
- Validate queries against the actual table plan and schema.
- Route all writes through the AzureIQ change-control workflow.
- Require independent verification before learning from an outcome.
- Record the baseline Azure MCP behavior, observed gap, smallest targeted artifact, acceptance criteria, comparison result, and `keep`, `revise`, or `retire` decision.

## Packs

| Pack | Status | Value proof | Purpose |
| --- | --- | --- |
| [API Management](api-management/README.md) | `draft` | `unproven` | First end-to-end gateway, policy, backend, identity, telemetry, and unexpected-response exemplar |