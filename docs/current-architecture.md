# AzureIQ Current Architecture

**Inventory date:** 2026-07-23

This document describes what exists now. [architecture.md](architecture.md) describes the larger target system, including hosted detection and remediation that has not been built.

## Current Layers

| Layer | Current implementation | How GitHub Copilot uses it | Maturity |
| --- | --- | --- | --- |
| User entry | Ordinary GitHub Copilot Agent mode or the single visible `AzureIQ Orchestrator` | User states an Azure outcome or symptom; internal component names are unnecessary | Available, model-directed |
| Always-on routing | `.github/copilot-instructions.md` | Automatically included in workspace chat; requires MCP-first selection and capability-overlay lookup | Available |
| Role isolation | Four hidden agents for inventory, diagnosis, change planning, and verification | Orchestrator invokes them as subagents when available; otherwise follows the same workflow in the parent context | Available, subagent routing is best-effort |
| Workflow knowledge | Three hidden skills for onboarding, incident response, and change control | Loaded automatically by semantic relevance | Available |
| Platform tools | Azure MCP, AppLens, Monitor, Application Insights, Resource Health, Resource Graph, service extensions, PostgreSQL extension MCP, and other installed tools | GHC receives first-class tool names, descriptions, and JSON schemas directly from MCP servers/extensions | Dynamic platform baseline |
| Capability overlays | `capabilities/registry.json` | GHC matches intent after live tool discovery and applies known limits, evidence requirements, fallbacks, maturity, and verification | Initial registry available |
| Reusable artifact memory | `artifacts/catalog.json` plus versioned source | GHC searches before generation, checks compatibility/decision points/digests, and selects or versions existing assets | Initial catalog with three assets |
| Service knowledge | API Management support domain with KQL and unexpected-response runbook | Loaded only for relevant APIM work; augments platform evidence | Draft and value-unproven |
| Local mutations | `src/AzureIQ.Execution`, a shared .NET Azure SDK CLI | GHC invokes registered subcommands through the terminal tool with explicit parameters and JSON output | Resource Group ensure operation proven |
| Local scripts | `scripts/Test-Workspace.ps1` only | CI and local structural/privacy validation; it is not an Azure mutation tool | Available |
| Private scope | Ignored `config/local.azureiq.json` | Shared CLI and instructions use it to constrain tenant/subscription without exposing identifiers in Git | Available on this machine |
| Change governance | Risk tiers, action-manifest schema, exact approval, rollback, and independent verification | Applied before and after every Azure mutation | Guidance plus validated schemas; no hosted policy engine |
| Execution history | `schemas/execution-record.schema.json`; ignored `.azureiq/runs/` location | Defines sanitized records of exact routes/artifacts, authorization, outcomes, verification, and learning | Contract available; automatic recorder not built |
| Continuous operations | None | VS Code cannot monitor while closed | Not built |
| Case-study product | `case-study/WaypointFreight`: .NET shipment API, integration tests, and static browser client | Establishes the App Service/APIM/client behavior and controlled failures that drive subsequent AzureIQ learning | Local milestone validated; no Azure deployment |

## How GHC Selects A Capability

1. Workspace instructions classify the request as inventory, incident, change, or verification.
2. GHC searches the live tool schemas supplied by installed Azure MCP servers and extensions. This is the broad catalog and changes as extensions evolve.
3. GHC checks [the overlay registry](../capabilities/registry.json) for the matching intent.
4. If an overlay exists, GHC applies its limitations, required evidence, fallback, maturity, and verification rules.
5. GHC searches [the artifact catalog](../artifacts/catalog.json), checks compatibility, validation freshness, source digest, and decision points, then reuses or versions an existing asset before generating another.
6. The Orchestrator invokes dynamic service-specific tools itself when a restricted hidden specialist does not have that tool, then delegates minimized structured evidence for analysis.
7. Relevant skills and support domains load progressively.
8. For an approved mutation, GHC binds exact artifact versions/digests and uses the preferred MCP operation, IaC, or a registered shared-CLI operation.
9. The verifier checks control-plane and data-plane outcomes independently and requires a sanitized run record.

The registry intentionally does not enumerate every Azure MCP command. Duplicating the platform catalog would become stale and could hide newly added tools. It records only decisions AzureIQ must add to the live catalog.

## AppLens And Detector Quality

AppLens is the preferred first diagnostic for supported services because Microsoft detector teams encode service-specific platform knowledge. AzureIQ does not assume every detector covers every failure mode or that every recommendation is correct.

For incident diagnosis, AzureIQ therefore treats detector output as a candidate hypothesis and requires corroboration from relevant sources:

- Resource Health and Service Health evidence;
- Activity Log, deployments, and configuration changes;
- Azure Monitor metrics and service-specific logs;
- Application Insights requests, dependencies, exceptions, and traces;
- effective identity, policy, quota, network, DNS, and dependency state;
- a known-good comparison and a check capable of disproving the leading cause.

A support domain adds value when repeated incidents expose a detector or generic-query gap and the domain supplies a tested query, decision point, or verification that measurably improves the baseline. It should be retired when it does not.

## How Local Code Becomes Usable By GHC

Arbitrary .NET methods are not automatically tools. Today, AzureIQ local operations are usable because:

1. the shared CLI publishes machine-readable discovery through `operations list`;
2. the capability registry maps user intents to exact CLI operations and parameter contracts;
3. always-on instructions and the change-control skill require GHC to consult those sources;
4. GHC invokes the operation through its terminal tool;
5. the CLI validates private scope, authentication mode, idempotency, and output redaction.

This is usable but not equivalent to a first-class MCP tool. Tool selection and shell construction remain model-directed.

## Local MCP Promotion Boundary

A local AzureIQ MCP server should be added when either condition is met:

- several stable shared-host operations exist and first-class schemas materially reduce routing complexity; or
- comparison tests show terminal invocation causes incorrect operation selection, parameter construction, approval handling, or reliability failures.

The MCP server should be a thin transport over the same operation implementations. It would give GHC native tool schemas and calls while preserving one codebase for credentials, private scope, policy checks, execution, and output. Building it before that evidence would add maintenance without demonstrated value.

## Known Gaps

- Capability routing is instructed and validated structurally but remains model-directed.
- The registry has only four initial overlays and no automated synchronization with installed extension versions.
- Hidden specialists intentionally do not receive every Azure MCP router; the Orchestrator must collect evidence from dynamic tools they lack.
- Only Resource Group ensure has a proven local mutation path.
- The generic generated-package coding engine and declarative validate/what-if/apply/teardown adapters are designed but not implemented. The Resource Group handler remains a proof to retire, not a pattern to multiply.
- APIM support-domain value remains unproven against a live baseline comparison.
- No hosted event pipeline, durable incident state, policy engine, approval service, or always-on managed identity exists.
- The current action-manifest schema is not yet bound cryptographically to execution.
- Execution-record writing is instructed but not yet enforced automatically by the execution host or hosted runtime.

## Next Architecture Proof

Build the case study defined in the ignored local `.azure/deployment-plan.md`: web API on App Service, APIM gateway, and client application. Then use its approved failure scenarios to compare:

1. raw Azure MCP/AppLens behavior;
2. registry-directed corroboration;
3. support-domain augmentation where applicable;
4. independent verification quality.

Keep only overlays and artifacts that improve factual accuracy, scope safety, evidence completeness, repeatability, or operator effort.

Do not expand the capability registry, artifact catalog, support domains, local CLI, or hosted architecture ahead of a case-study need. Existing contracts are provisional and may be simplified when the vertical slice provides evidence.