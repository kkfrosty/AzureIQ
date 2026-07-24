# AzureIQ Change Risk Tiers

These are default minimums. Organizational policy, regulation, environment, resource criticality, data classification, or current incident conditions may only increase the tier.

## R0: Read-Only

Examples: list/get/query operations, Resource Graph, metrics, logs, health, effective configuration, documentation, and dry-run operations guaranteed not to mutate state.

- No Azure write approval is needed.
- Scope, identity, sensitive-data handling, query cost, and audit rules still apply.
- A routed tool must be used only through a verified read-only subcommand.

## R1: Low, Narrow, Reversible

Examples: applying a previously reviewed tag to one non-production resource, updating a non-sensitive dashboard, or enabling an already-approved diagnostic setting on one low-criticality resource.

- Explicit single approval for the exact action manifest.
- Validated target, precondition, rollback, and postcondition required.
- Potential future policy eligibility after tests and repeated supervised success.

## R2: Material Service Change

Examples: production configuration or policy change, scale change, deployment, alert/action-group change, secret rotation with tested overlap, network rule adjustment, backup-policy change, or bounded restart.

- Explicit approval immediately before execution.
- Maintenance/communication plan, plan or what-if, rollback, abort criteria, independent verification, and observation window required.
- Automatic execution is off by default and requires a narrowly approved runbook policy.

## R3: High Impact Or Privilege

Examples: failover, restore, production data-plane write, public-network exposure, firewall or private-DNS change with broad reach, policy exemption, lock removal, role assignment, identity federation change, destructive replacement, regional traffic shift, or broad restart.

- Explicit high-risk approval immediately before execution; use two-person approval where available.
- Confirm break-glass path, backups or recovery point, stakeholder communication, blast-radius containment, and real-time verification.
- Never infer approval from urgency or a prior general instruction.
- Not eligible for model-initiated automatic execution.

## R4: Prohibited From Autonomous Execution

Examples: irreversible deletion of production data, tenant-wide security disablement, uncontrolled subscription-wide role grants, disabling audit collection, deleting recovery material, unbounded arbitrary command execution, or an action whose target or blast radius cannot be proven.

- AzureIQ may gather evidence and prepare a plan but must not execute autonomously.
- A human-led, separately governed break-glass or formal change process is required.
- Some actions remain prohibited even with a chat approval, depending on organizational policy.

## Classification Escalators

Raise the risk tier for production, shared dependencies, regulated or sensitive data, unknown ownership, incomplete inventory, weak telemetry, stale backups, no rollback, broad wildcard scope, cross-tenant impact, current platform instability, irreversible API behavior, or permissions broader than the target action.

## Automation Eligibility

Risk tier alone does not grant automation. An action is policy-eligible only when the exact versioned runbook has bounded selectors, allowlisted operations, schema validation, idempotency, concurrency protection, rate limits, tests, fault injection or game-day evidence, rollback, independent verification, an owner, and an expiring approval policy.