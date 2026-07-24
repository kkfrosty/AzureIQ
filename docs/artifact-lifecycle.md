# Reusable Artifacts And Engineering Review

AzureIQ should generate an Azure artifact once, learn whether it works, and reuse the exact validated version when conditions match. It must not repeatedly reinvent common service configurations, nor reuse an old artifact without checking compatibility and current Azure state.

This contract is being proven through the App Service + APIM + client case study. Do not populate the catalog speculatively. Register only an artifact used by the case study or an already demonstrated platform-tool gap.

## Storage Model

| Material | Storage | Reason |
| --- | --- | --- |
| Artifact source, metadata, tests, and non-secret defaults | Git plus [the artifact catalog](../artifacts/catalog.json) | Review, versioning, digest integrity, and team reuse |
| Approved Bicep modules | Git initially; private ACR-backed Bicep registry when shared across teams | Versioned reusable modules with RBAC-controlled distribution |
| Approved full deployment patterns | Git, private template specs, or deployment stacks where lifecycle ownership is intentional | Canonical deployment and lifecycle management |
| Customer scope and non-public bindings | Ignored local configuration or a private hosted configuration store | Prevent tenant, subscription, and customer identifiers from entering reusable source |
| Secrets and certificates | Key Vault through references | Never place secret values in artifacts, parameters, prompts, or run records |
| Generated candidates and plans | `.azureiq/generated/` and `.azureiq/plans/` locally; protected workflow storage when hosted | Ephemeral review material, not trusted knowledge |
| Execution records | `.azureiq/runs/` locally; durable access-controlled audit store when hosted | Track exact artifact/tool versions, outcomes, and verification without polluting Git |
| Raw evidence | Approved Azure evidence store | Access control, retention, volume, and privacy |
| Current Azure state | Azure APIs and telemetry | Live state remains authoritative |

Deployment stacks can delete or detach resources when an artifact changes. Use them only after lifecycle boundaries and `actionOnUnmanage` behavior are explicitly approved. Template specs and private Bicep modules should contain reviewed versions, not every generated candidate.

## Artifact Lifecycle

```text
generated candidate
    -> draft
    -> validated
    -> approved
    -> deprecated
    -> retired
```

- **candidate:** generated for a specific need; not reusable or executable until cataloged and validated.
- **draft:** structurally reviewed but not proven in the required environment.
- **validated:** passed declared static/live checks for recorded compatibility conditions.
- **approved:** organizationally accepted for reuse within its compatibility and risk policy.
- **deprecated:** still readable for existing deployments but not selected for new work.
- **retired:** cannot drive execution.

Value proof is separate. A validated artifact that offers no benefit over Azure MCP, an Azure Verified Module, or another maintained baseline should be retired rather than preserved.

## Selection Before Generation

For every material design, query, policy, deployment, or runbook:

1. Search live MCP/extension capabilities.
2. Check `capabilities/registry.json` for constraints or proven gaps.
3. Search `artifacts/catalog.json` by intent.
4. Exclude deprecated/retired, expired, incompatible, or `no-value` artifacts.
5. Compare resource type, cloud, environment, SKU/tier, topology, network, identity, API version, telemetry, and declared conditions against live state and requested outcome.
6. Select the newest compatible validated/approved version. Prefer exact parameterization over adaptation.
7. Resolve each artifact decision point. Infer only when a current organizational standard or authoritative live state gives one unambiguous answer; otherwise ask the user.
8. If conditions differ materially, create a new candidate version. Never silently modify an approved version in place.
9. If no artifact fits, generate the smallest composable candidate and add it to the catalog before mutation.

## Updating Reused Artifacts

Revalidation is required when catalog conditions say so, and whenever:

- an Azure API version, SKU, region, feature state, or platform limit changes;
- an extension, MCP, SDK, module, policy, or authentication behavior changes;
- network, identity, data classification, SLO, RTO/RPO, or compliance requirements differ;
- the source digest differs from the catalog;
- validation has expired;
- live what-if, telemetry, tests, or incident evidence contradict prior assumptions.

Patch versions preserve the contract while fixing implementation. Minor versions add backward-compatible options. Major versions change behavior, scope, risk, lifecycle, or required inputs. Existing deployments remain pinned until an approved upgrade plan succeeds.

## APIM Example

The first APIM setup should generate a candidate composition rather than one giant bespoke file:

- APIM topology and identity Bicep module;
- network/private endpoint module when required;
- diagnostic settings and Application Insights configuration;
- alert and dashboard bundle;
- versioned APIs, backends, named values, and policy artifacts;
- deployment/revision strategy;
- data-plane verification tests;
- rollback procedure.

After validation, those assets receive versions and compatibility conditions. On the next APIM request, GHC retrieves them and checks tier, workspaces, gateways, regions, network exposure, backend authentication, certificate ownership, SLOs, and telemetry destinations. It asks only about unresolved material differences. A changed condition produces a new candidate version and what-if, not an invisible mutation of the prior pattern.

## Engineering Review Gates

AzureIQ should behave like a senior engineering and support team by challenging ambiguity and stopping at material risk, not by presenting a fixed questionnaire for every task.

### 1. Intake and triage

- Confirm outcome, environment, criticality, owner, affected users, UTC window, and expected behavior.
- Identify unknown scope, incomplete permissions, missing telemetry, conflicting requirements, and unsupported assumptions.
- For incidents, separate facts, hypotheses, containment, remediation, and prevention.

### 2. Design review

Evaluate availability, security, identity, networking, data protection, backup/restore, observability, operability, performance, quota/capacity, cost, regional support, dependencies, deployment, rollback, and decommissioning.

Ask for a decision when no standard safely resolves a material choice, including:

- production versus non-production and data classification;
- public versus private exposure;
- authentication/authorization and identity ownership;
- region, zone, multi-region, RTO/RPO, backup, and failover;
- SKU/capacity and material cost;
- retention, sampling, payload logging, and evidence access;
- ownership, maintenance window, and support escalation.

State a recommendation and tradeoff before asking; do not ask users to choose between unexplained options.

### 3. Change review

- Compare current and desired state.
- Resolve exact scope, identity, RBAC/PIM, policy, locks, quotas, and concurrent changes.
- Compile/lint and run provider validation plus what-if where supported.
- Highlight deletes, replacements, public exposure, privilege, data writes, policy exemptions, downtime, irreversible steps, and cost changes.
- Define rollback, abort criteria, observation window, and independent checks.
- Bind approval to exact artifact versions/digests, parameters, scope, and plan.

### 4. Execution

Stop on scope mismatch, stale plan, changed artifact digest, unexpected prompt, unapproved operation, permission escalation, concurrent drift, partial failure, or output inconsistent with the plan.

### 5. Verification

Check control-plane state, user-visible/data-plane behavior, telemetry ingestion, alerts, dependencies, security posture, cost signals, and adjacent regressions. Command success alone is insufficient.

### 6. Learning

Write a sanitized execution record conforming to [the execution-record schema](../schemas/execution-record.schema.json). Promote, update, or retire artifacts only from verified outcomes. A coincidental recovery or unverified hypothesis does not become reusable knowledge.

## Questions And Confirmation

- **Advisory:** infer from standards when safe and report the assumption.
- **Approval:** recommend an option, explain tradeoffs, and obtain confirmation before planning is finalized.
- **Blocker:** stop until explicitly resolved.
- **R1/R2 mutation:** one approval bound to the final plan at the mutation boundary.
- **R3:** immediate high-risk approval and two-person/formal review where available.
- **R4:** no autonomous execution.

If new evidence changes scope, risk, artifact digest, parameters, rollback, or predicted effects, invalidate the prior approval and ask again.