---
name: azureiq-change-control
description: 'Govern Azure changes and remediation. Use before deploy, update, policy edit, APIM policy change, restart, scale, failover, role assignment, network change, secret rotation, data-plane write, or any Azure mutation requiring approval, rollback, audit, and verification.'
argument-hint: 'Provide the desired outcome, target scope, evidence, environment, risk constraints, and maintenance window.'
user-invocable: false
---

# AzureIQ Change Control

Use this workflow for every Azure mutation, whether performed through MCP, IaC, CLI, SDK, REST, or browser.

## Execution Adapters

First use an existing working Azure MCP/extension subcommand supporting the
approved operation and scope. Custom adapters below are fallbacks, not the
default merely because they exist. Diagnose authentication/argument failures
separately from capability gaps. Do not build or extend an executor during a
routine Azure change without separate explicit tool-development authorization.

When a supported MCP path is unavailable, the existing fallback for classic APIM subnet service endpoints is the
[controlled CLI workflow](../../../docs/subnet-service-endpoint-changes.md).
It admits only a cataloged argument-array recipe for the maintained subnet
update command, pins CLI version/executable and same SDK/CLI identity, and
requires an empty initial endpoint set plus immediate R3 approval. Do not use
the observability REST lane to replace a subnet or execute a free-form shell
command. Event Hubs is not implied when only the core endpoints are applicable.

For APIM logging, alerts, and subscription Activity Log export, a fixed
catalog-bound ARM lane is available. Follow
[the observability change workflow](../../../docs/observability-changes.md).
`change validate`, `plan`, `verify`, and `rollback-plan` do not mutate Azure.
`change approve` records an exact user decision obtained outside the CLI;
it must never be used to self-approve. `change apply-approved` checks supervised
policy, scope/principal/source/state drift, expiry and one-use execution.
Rollback is a fresh, separately approved plan. All packages remain candidate
until live verification; configuration readback does not replace the verifier.

Use an existing, tested AzureIQ CLI operation when Azure MCP does not expose the required mutation. For Resource Group create-or-verify operations, invoke the shared execution host:

```powershell
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- resource-group ensure --name '<name>' --location '<region>' --what-if
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- resource-group ensure --name '<name>' --location '<region>'
```

The host reads exact tenant/subscription scope only from ignored `config/local.azureiq.json`, uses the existing VS Code Azure credential locally or managed identity when hosted, performs idempotent Azure SDK operations, and redacts private scope from errors.

Do not fall back to interactive portal automation or ask for another login when a tested CLI operation supports the approved action. Add an operation to the shared host only after confirming the MCP/extension gap. Do not create a resource-specific script or executable. Keep authentication, scope validation, idempotency, sanitized output, dry run, and independent verification in the shared host.

When no safe existing operation exists, report the concrete blocker and propose separate tool work. Only with tool-development authorization, follow [the coding-engine contract](../../../docs/coding-engine.md) to create a candidate package. Ordinary parameterization of existing approved templates/recipes does not require developing a new tool. Generated arbitrary shell or SDK code must not execute with Azure credentials.

## Approval Semantics

- Initial policy is explicit approval for every write.
- Approval must identify the action manifest, exact scope, operations, risk, and expiry. General intent such as "fix it" is not standing approval for an unspecified mutation.
- Re-approval is required when target, command, parameters, identity, blast radius, risk, rollback, or evidence changes materially.
- Future automatic execution requires a separately approved policy that names the runbook, scope, limits, preconditions, rate limits, rollback, and verification. Agent instructions alone do not create that authority.

## Workflow

1. Ask `AzureIQ Change Planner` to produce the manifest.
2. Confirm authenticated tenant, subscription, principal, minimum role, target resource IDs, environment, and concurrency state.
3. Classify the action using [risk tiers](./references/risk-tiers.md).
4. Validate current-state assertions and dependencies immediately before execution.
5. Prefer declarative IaC. Run lint, validate, plan, or what-if and inspect destructive replacements or permission changes.
6. Verify every reused/generated artifact against `artifacts/catalog.json`; bind its ID, semantic version, and source digest to the action manifest. Reject unregistered generated mutations, stale validation, or digest drift.
7. Present the exact operations, sanitized diff, unresolved decisions, blast radius, cost/downtime/data/security impact, rollback, abort criteria, and success checks.
8. Obtain the required approval immediately before the write.
9. Execute the smallest change. Stop on scope drift, unexpected prompts, partial failure, permission escalation, stale preconditions, artifact drift, or output inconsistent with the plan.
10. Preserve redacted action and Activity Log identifiers.
11. Hand the manifest and result to `AzureIQ Verifier`. Do not self-certify success.
12. Write a sanitized execution record under ignored `.azureiq/runs/` locally or the approved hosted audit store. Do not promote an artifact until independent verification succeeds.

For an ephemeral environment, treat create, test, evidence retention, and teardown as one declared lifecycle. Teardown must compare actual resources with the expected inventory, block on unknown ownership/data/locks, obtain immediate destructive approval, verify active resources are absent, and handle soft-deleted global services such as APIM explicitly.

## Required Action Manifest

Include:

- unique change ID and initiating incident/request;
- UTC creation and approval expiry;
- tenant, subscription, environment, resource group, resource IDs, and region;
- principal and minimum RBAC/data-plane permissions;
- evidence and desired postcondition;
- exact tool, operation, parameters, order, and idempotency key or guard;
- preconditions and concurrency assertion;
- risk tier, blast radius, downtime, cost, security, and data impact;
- plan/what-if result and sanitized diff;
- rollback or compensating action;
- timeout, abort, and partial-failure handling;
- verification queries, synthetic checks, observation window, and owner;
- approver, approval scope, and decision record.

## No-Go Conditions

Return `NO-GO` instead of executing when scope or identity is ambiguous, evidence is insufficient, the operation differs from approval, secrets would be exposed, required validation failed, rollback is missing for a reversible action, verification is not discriminating, or the action exceeds the approved risk policy.