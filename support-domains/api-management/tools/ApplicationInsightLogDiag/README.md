# ApplicationInsightLogDiag

**Status:** design handoff; no executable AzureIQ tool in this folder.

**Reviewed:** 2026-10-14.

**Value proof:** proposed and unproven for AzureIQ integration and fault diagnosis.

## Recommendation

Build a customer-run, read-only diagnostic that combines effective APIM logging
configuration, the existing VNet assessment and correlated ingestion evidence.
Keep traffic generation, fault injection and remediation in separately approved
execution paths. GitHub Copilot should interpret the deterministic evidence,
not invent a diagnosis or change customer settings to make a test pass.

This can identify many customer-correctable configuration blockers without
service-side engineering logs. It cannot promise to identify every SDK,
platform, TLS-interception or transient transport failure.

## Handoff contents

- [Implementation handoff](IMPLEMENTATION-HANDOFF.md): architecture, rules,
  privacy, authentication, result semantics and GHC integration.
- [Fault-injection plan](FAULT-INJECTION-PLAN.md): controlled experiments,
  causal evidence, restoration and acceptance gates.
- [Sources and validation](SOURCES-AND-VALIDATION.md): public references,
  demonstrated evidence and remaining validation.

## What already exists

| Asset | Reuse | Boundary |
| --- | --- | --- |
| [VNet checker](../vnet-check/README.md) | SKU discovery, per-location snapshots, ordered NSG checks and explicit unknowns | Candidate; offline tested, not live validated. It does not cover effective Application Insights logger/authentication or prove ingestion. |
| [Azure Monitor collaboration](../../../azure-monitor/README.md) | Customer-owned log scope, schema and correlation | Select the actual component/workspace; do not assume gateway resource logs and Application Insights share a destination. |
| [Execution tools](../../../../docs/execution-tools.md) | Private scope, credential handling and shared execution boundary | Do not introduce a second credentialed mutation executable. |
| [Artifact lifecycle](../../../../docs/artifact-lifecycle.md) | Compatibility, digests, maturity and value comparison | External proof-of-concept success does not approve an AzureIQ implementation. |

An earlier isolated non-production study established a known-good classic
Developer/internal-VNet configuration: 20 generated synthetic requests produced
20 successful Application Insights request rows, distinct request IDs and
operations, with W3C correlation. A standalone read-only prototype and an
internal probe both reproduced the evidence; 17 prototype regression tests
passed. These are historical positive-path observations, not proof of current
customer state or of detecting deliberately broken networking.

The prototype is not copied here. Its command-line scope inputs, private-ID
output and execution ledger differ from AzureIQ's contracts. Port the useful
logic and tests through the owning team's review, not the entry point verbatim.

## Initial customer experience

1. Establish the customer's private, explicitly authorized scope and reader.
2. Discover APIM SKU, gateway model, locations and requested API/revision.
3. Assess effective logging configuration and related-resource evidence.
4. Reuse the VNet checker for supported models.
5. Query customer-authorized, schema-verified request evidence when available.
6. Return separate configuration, delivery and root-cause findings.
7. Recommend the narrowest verified correction and an independent recheck.
   Do not execute that correction from the read-only diagnostic.

Start with the managed classic Developer/internal-VNet scenario demonstrated by
the study. Other SKUs, gateway types, workspaces and clouds require explicit
compatibility work. Discovery can still explain an unsupported model without
pretending it was checked.

## Current authorization boundary

The tracked [AzureIQ policy](../../../../config/azureiq.yaml) is
`bootstrap-read-only` with `azureWrites: deny`. No ignored commissioning profile
was present during this review. This handoff does not change that policy,
commission a subscription or authorize a fault experiment.

An existing lab in another workspace is not automatically an AzureIQ scope.
The operator must bind an approved private lab profile, permitted execution
mode and exact change manifest before any live fault, VM start or remediation.

No live Azure configuration was changed during this evaluation. Existing
offline VNet rule and mocked collector tests passed with zero Azure calls.
The new diagnostic and negative experiments remain design-only.

## Development-team ownership

Only this directory was added. The other team's VNet modules, agents, skills,
support-domain manifest, capability registry, artifact catalog and execution
host were not modified.

The owning team should implement the candidate, add catalog/routing entries
under review, and compare it with Azure MCP and existing skills before promotion.
Do not register these documents as a runnable or approved diagnostic.
