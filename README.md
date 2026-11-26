# AzureIQ

AzureIQ is a control workspace for creating, configuring, observing, diagnosing, and safely remediating an Azure estate. The goal is a central operational nervous system and supervised subscription manager, not an unrestricted bot with subscription-wide write access.

> **AI SAFETY WARNING - USE AT YOUR OWN RISK:** AI can make mistakes, invent facts,
> generate destructive changes, and report false success. Strongly prefer isolated
> development/test environments; production use is discouraged. Avoid autopilot,
> auto-approval, and unattended AI-directed writes. Independently review and
> explicitly authorize every change using least-privilege credentials. This
> experimental software is provided "AS IS", without warranty. Read the full
> [AI safety and risk disclaimer](DISCLAIMER.md) before use.

**Current status:** supervised operations workspace with a deployed non-production
Harbor reference stack. Provisioning is not full readiness: authenticated
application, runtime lifecycle, native discovery and telemetry/alert acceptance
still have gates. See the dated [Harbor operating guide](docs/harbor-operations-guide.md)
for current evidence; private scope and effective commissioning remain local.

## Design Center

- Use live Azure APIs and telemetry as the source of current state.
- Keep desired state, operating policy, service baselines, runbooks, and sanitized lessons in version control.
- Use the installed Azure MCP and service extensions first; add CLI, REST, or browser fallbacks only for uncovered operations.
- Separate AI-assisted investigation and planning from deterministic execution.
- Require explicit approval for writes until a specific remediation has evidence, tests, rollback, and a deliberately approved automation tier.
- Run continuous detection and remediation in Azure, not in an editor session.
- Do not duplicate Azure MCP or installed Azure skills. Keep AzureIQ artifacts only when a measured comparison shows added accuracy, safety, repeatability, evidence quality, customer context, or reduced operator effort.
- In supervised management mode, complete requested Azure changes through execution and verification rather than stopping after design or code generation.

See [Current Architecture](docs/current-architecture.md) for the implemented inventory, [Architecture](docs/architecture.md) for the target system, and [Capability Boundaries](docs/capabilities.md) for what is and is not currently possible. The [Roadmap](docs/roadmap.md) sequences delivery, the [Memory Model](docs/memory-model.md) defines what AzureIQ may retain and trust, [Reusable Artifacts and Engineering Review](docs/artifact-lifecycle.md) governs reuse and human-style checks, [Coding Engine](docs/coding-engine.md) defines safe generated-code execution, and [Execution Tools](docs/execution-tools.md) governs MCP gaps and shared local operations.

## Planned Workspace Shape

| Path | Purpose |
| --- | --- |
| `.github/copilot-instructions.md` | Always-on safety and evidence contract |
| `.github/agents/` | One visible orchestrator plus hidden least-privilege specialists |
| `.github/skills/` | Automatically loaded cross-service operating workflows |
| `config/` | Non-secret scope and policy configuration |
| `capabilities/` | Machine-readable routing overlays for tool gaps, corroboration, fallback, maturity, and verification |
| `artifacts/` | Versioned reusable asset catalog with compatibility, decisions, digests, validation, and supersession |
| `docs/` | Architecture, decisions, roadmap, and memory model |
| `support-domains/` | Service-specific baselines, queries, alerts, and runbooks |
| `incidents/` | Sanitized incident records and learned outcomes |
| `infra/` | Future control-plane and observability infrastructure as code |
| `src/AzureIQ.Execution/` | Tested Azure SDK mutation adapters for gaps not covered by Azure MCP |

## How To Use AzureIQ

Describe the outcome or symptom in ordinary GitHub Copilot Agent mode. The always-on workspace instructions classify the request and invoke hidden AzureIQ specialists, relevant skills, support domains, and Azure MCP tools. Users do not need to know their names.

`AzureIQ Orchestrator` is the single optional dedicated agent mode. It provides the same automatic routing with a focused AzureIQ interaction contract. Inventory, incident, planning, verification, and skill customizations are intentionally hidden from user selection.

Routing is model-directed and therefore best-effort, not a workflow or authorization engine. If subagent invocation is unavailable, the active agent follows the same workflow directly and reports the loss of tool isolation. Azure writes remain controlled by repository policy and, later, deterministic hosted enforcement.

## First Milestone

The first commissioning milestone is read-only: establish tenant and subscription scope, inventory resources and dependencies, assess telemetry coverage, and select management paths. The first operational milestone is a non-production supervised vertical slice that creates or configures a service, enables its telemetry, validates behavior, and proves rollback and independent verification.

The [API Management support domain](support-domains/api-management/README.md) is `observed` and `value-demonstrated` for the validated Developer-tier APIM and Container Apps case study. Azure Monitor and Container Apps own the cross-service trace and backend-platform evidence it collaborates with.

## Case Study

[Waypoint Freight](case-study/WaypointFreight/README.md) is the local proving application: a .NET shipment API, integration tests, and browser client. The local milestone is validated with controlled fault scenarios; Azure App Service, API Management, observability, authentication, and VNet preparation remain gated by the deployment plan.

## Harbor IT Services reference

See the [deployed layout and operating guide](docs/harbor-operations-guide.md)
for the current Harbor diagram, existing APIM AI Gateway controls, staged AI
Gateway adoption path, user workflows, diagnostic evidence, and remaining
readiness gates. Its dated live observations distinguish provisioning from
authenticated acceptance.

The [API Center Try it investigation guide](docs/api-center-try-it-client-credentials.md)
records the client-credentials warning reproduction, portal versus credential
access, and the evidence and verification steps needed to work through the case.

The new [Harbor support application](case-study/SupportService/README.md)
implements a fictional company-scoped text/voice client, protected APIs,
confirmed cases, Search grounding, and Foundry integrations. Local test doubles
verify application boundaries; they do not prove live provider connectivity.

The [disposable infrastructure package](infra/support-service/README.md) is a
cataloged candidate for Standard v2 plus linked API Center Standard, private
dependencies, diagnostics, and repeatable removal/recreation. Native API Center
MCP activation, the billing benefit, current compiler/provider validation and
live telemetry/user-flow acceptance remain release gates. The project is not
deployed or ready merely because the application builds.

## Execution Adapters

Azure MCP remains the first management path. When it lacks a mutation, AzureIQ may provide a small tested SDK adapter instead of forcing repeated portal work or ad hoc scripts.

The first proven CLI operation remains Resource Group create-or-verify.

A bounded [observability change workflow](docs/observability-changes.md) now
supports targeted APIM logging, alerts and subscription Activity Log export.
It separates read-only diagnosis/planning from explicitly approved supervised
writes, with drift checks, readback and separately approved rollback. Its
packages have offline test evidence and remain candidate pending live validation.

Resource Group commands:

```powershell
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- resource-group ensure --name '<name>' --location '<azure-region>' --what-if
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- resource-group ensure --name '<name>' --location '<azure-region>'
```

The shared host uses ignored private scope, VS Code Azure authentication locally, managed identity when hosted, exact subscription targeting, idempotency, redacted errors, and machine-readable output. Each new operation must close a confirmed tool gap and meet the same contract. Resource names are parameters; no operation is tied to a specific customer resource.

## Validation

Run the workspace contract check locally:

```powershell
./scripts/Test-Workspace.ps1
```

The same check runs for pull requests and pushes to `main`. It validates required files, the single visible Orchestrator, hidden model-routable specialists, automatic-only skills, support-domain value metadata, JSON parsing, local documentation links, forbidden sensitive artifact types, and operating-mode consistency. Bootstrap requires denied writes; supervised management requires configured scope, principal, IaC, telemetry, approval, and no automatic risk tiers. It does not validate live Azure access, RBAC, KQL against a workspace, complete YAML semantics, model routing behavior, or service outcomes.

## License And Contributions

AzureIQ is licensed under the [MIT License](LICENSE), which permits copying,
modification, commercial use, and redistribution subject to its terms. Third-party
components retain their own licenses. The [risk disclaimer](DISCLAIMER.md)
provides safety guidance and does not add restrictions to the MIT License.

Anyone may work in a fork and propose a pull request. Invited write collaborators
may push working branches in this repository, but only the owner `@kkfrosty` may
publish to upstream `main`, including direct pushes through the admin bypass.
See [Contributing](CONTRIBUTING.md) for the access model and review process.