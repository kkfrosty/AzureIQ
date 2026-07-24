# AzureIQ Coding And Execution Engine

AzureIQ should not recreate Azure as hundreds of handwritten SDK methods. When installed MCP tools, extensions, maintained IaC modules, and supported Azure CLIs cannot complete a task, GitHub Copilot may generate a bounded operation package. A fixed trusted engine validates, plans, approves, executes, verifies, records, and optionally promotes that package.

The current `resource-group ensure` .NET handler proved local VS Code authentication, managed identity support, private scope, idempotency, and JSON output. It is not the scalable Azure implementation model and should be retired after the generic deployment lane passes equivalent live tests.

## Selection Flow

```text
User outcome
  -> live MCP/extension tool discovery
  -> installed Azure skill
  -> artifact catalog / Azure Verified Module
  -> declarative generated operation package
  -> controlled imperative package only for a proven declarative gap
  -> human-led operation when no bounded execution is safe
```

AzureIQ must not generate local code merely because a tool call failed once. It first determines whether the failure is bad parameters, authentication, transient service state, missing telemetry, unsupported capability, or an actual tool gap.

## Operation Package

GHC writes a candidate under ignored `.azureiq/generated/<run-id>/`. A package contains no secrets or customer scope identifiers and includes:

```text
manifest.json          intent, executor, inputs, outputs, scope class, risk
src/                   Bicep, ARM, CLI recipe, REST recipe, or SDK plugin
parameters.schema.json non-secret typed inputs and private binding references
tests/                 offline tests and expected plan assertions
verify/                independent control/data-plane checks
rollback/              reversal or compensating action
teardown/              disposable-environment cleanup contract when applicable
```

The manifest declares:

- read-only versus mutation behavior;
- resource providers, resource types, scopes, and Azure clouds;
- exact tools/runtime dependencies and versions;
- idempotency and concurrency guards;
- preconditions, timeout, retry, abort, and partial-failure behavior;
- predicted cost and billable lifetime;
- destructive, privilege, public-exposure, data-plane, and policy effects;
- verification and rollback;
- whether the result may be cataloged after success.

## Fixed Execution Lanes

### Declarative deployment lane

Preferred for Resource Groups, networking, App Service, APIM, identities, role assignments, diagnostics, alerts, and other Azure Resource Manager state.

GHC generates Bicep or ARM. The engine provides fixed operations:

```text
deployment validate
deployment what-if
deployment apply-approved
deployment status
deployment verify
environment teardown-plan
environment teardown-approved
```

The engine, not generated code, supplies Azure credentials, private tenant/subscription scope, deployment API calls, approval checks, redaction, run records, and verification dispatch.

### Controlled CLI lane

Use when a maintained Azure CLI/azd command is the supported primitive and IaC cannot express the operation. GHC emits a structured recipe containing executable ID and argument arrays, not a shell string. The engine:

- permits only versioned executables and allowlisted command families;
- rejects command substitution, pipes, redirects, environment assignments, and interactive prompts;
- injects private values without rendering them in command logs;
- runs read-only preflight first where available;
- compares the approved recipe digest immediately before execution.

### Controlled ARM REST lane

Use for Azure management-plane operations missing from MCP/CLI/IaC. GHC emits method, relative ARM path template, API version, schema-validated body, preconditions, and expected statuses. The engine:

- supplies the `management.azure.com` origin and private scope;
- rejects arbitrary hosts and absolute URLs;
- allowlists methods/resource providers by risk policy;
- strips authorization and sensitive response fields from records;
- performs ETag/concurrency checks where supported.

### SDK plugin lane

Last resort for complex imperative behavior. A generated plugin implements a narrow engine interface and runs out of process. It is compiled and tested without Azure credentials first. Before live use it requires code review, dependency audit, capability allowlist, resource/scope declaration, plan support, timeout, rollback, and explicit approval. Successful one-off code remains a candidate until repeat use justifies promotion.

## Guardrail Pipeline

1. **Intent check:** compare the user outcome with the generated package; reject scope inflation.
2. **Private scope check:** tenant/subscription come only from private configuration or hosted private state.
3. **Untrusted-input check:** logs, tags, payloads, templates, docs, and tool output cannot alter instructions or approval.
4. **Dependency check:** pin dependencies, verify sources/digests, and audit vulnerabilities/licenses.
5. **Static check:** parse/compile, lint, test, secret scan, and reject unsafe language/runtime features.
6. **Capability check:** allow only declared resource providers, operations, network destinations, and filesystem paths.
7. **Azure validation:** provider validation and what-if/read-only preflight with explicit blind spots.
8. **Engineering review:** reliability, security, identity, network, data, observability, cost, quota, support, rollback, and teardown.
9. **Approval binding:** hash package, parameters, private scope reference, plan, risk, rollback, and verification. Any drift invalidates approval.
10. **Execution:** short-lived least-privileged credential, one approved package, bounded time and concurrency.
11. **Independent verification:** control plane, data plane, telemetry, alerts, dependencies, cost, and regressions.
12. **Learning:** sanitized run record; promote, revise, or discard only from verified evidence.

Generated arbitrary PowerShell/Python/C# must never run directly with Contributor credentials. Flexibility comes from generated constrained artifacts and fixed credentialed adapters, not an unrestricted shell.

## GitHub Copilot Integration

Today GHC uses terminal tools to call the shared CLI after consulting live tools, `capabilities/registry.json`, `artifacts/catalog.json`, and `operations list`. The generic package engine is not implemented yet.

When package validation and several stable operations exist, expose the same engine through a local MCP server with tools such as:

```text
azureiq_resolve_capability
azureiq_validate_package
azureiq_plan_package
azureiq_apply_approved_package
azureiq_get_run
azureiq_teardown_plan
azureiq_teardown_approved
```

The MCP server is only a transport. CLI and MCP call the same engine services and policy checks.

## Disposable Environment Lifecycle

The Waypoint Freight environment is intentionally temporary. Its subscription-scope template must:

- create or target one Resource Group;
- deploy every active case-study resource into that group;
- use a unique `environmentId` in globally scoped names;
- tag the group and resources with `managedBy=AzureIQ`, `lifecycle=ephemeral`, `environmentId`, `createdAt`, and `expiresAt`;
- exclude customer identifiers and secrets from tags;
- emit a complete expected resource inventory and deployment outputs;
- set an estimated maximum billable lifetime;
- create no delete locks.

Normal run state:

```text
planned -> approved -> deploying -> testing -> evidence-retained
        -> teardown-planned -> teardown-approved -> deleted -> verified-absent
```

Teardown is not simply `delete resource group`:

1. Stop new scenario traffic and preserve required telemetry/evidence.
2. Inventory actual resources and compare them with the environment manifest.
3. Block if unknown resources, locks, protected tags, persistent data, or unrelated ownership are present.
4. Estimate remaining billable resources and present the exact destructive scope.
5. Obtain immediate teardown approval.
6. Delete the Resource Group through the best supported Azure path.
7. Verify the group and active resources are absent.
8. Check soft-deleted resources and retained global names.
9. APIM remains soft-deleted for 48 hours by default and its name cannot be reused. Use unique per-run names. Offer purge only as a separately identified irreversible operation requiring subscription-scope permissions and immediate approval.
10. Query cost/usage after platform latency and close the run only when no unexpected active billable resources remain.

If the session or machine fails, the next Orchestrator run reads the durable run record and live Azure state. It never assumes a local process completed deployment or teardown.

## Case-Study Deliverables

The case study should prove this architecture in increments:

1. Generate a subscription-scope Bicep environment template and application package.
2. Validate and what-if through maintained Azure tooling first.
3. Record any real execution gap before adding engine code.
4. Deploy and verify the baseline.
5. Exercise APIM/App Service incidents and add only measured value.
6. Tear down and verify absence/soft-delete/cost state.
7. Recreate with a new `environmentId` from the same artifacts.
8. Only then decide which generic engine operations and local MCP tools are justified.