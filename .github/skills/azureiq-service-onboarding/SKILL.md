---
name: azureiq-service-onboarding
description: 'Onboard an Azure service into AzureIQ. Use for API Management, App Service, Functions, databases, storage, messaging, AKS, networking, or other services that need desired state, identity, telemetry, alerts, diagnostics, runbooks, fault tolerance, and ownership.'
argument-hint: 'Provide the service/resource type, Azure scope, environment, criticality, owners, data sensitivity, and desired outcome.'
user-invocable: false
---

# AzureIQ Service Onboarding

Use this workflow to create or assess an operable service, not merely a provisioned resource. Reuse the installed service-specific Azure skill for implementation details and this skill for the cross-service operations contract.

When the user asks to set up or configure a service, the intended result in `supervised-management` mode is a deployed and verified service with its operational baseline, not only a design report or generated IaC. Use discovery and planning to make the change safe, then route the exact mutation through `azureiq-change-control`, execute after approval, and independently verify it.

## Preconditions

- Confirm tenant, subscription, environment, resource scope, owners, criticality, and data classification.
- Identify whether the task concerns a new service, an existing service, or an inherited service with unknown configuration.
- Keep discovery read-only. Route every write through the `azureiq-change-control` skill.
- Consult current Microsoft documentation for service limits and diagnostic categories; do not rely on hardcoded category lists.

## Workflow

### 1. Discover

1. Select the most specific installed Azure skill and MCP surface for the service.
2. Inventory resources, dependencies, identities, networking, DNS, private endpoints, regions, deployment history, policy, locks, tags, and current telemetry.
3. Identify permission blind spots and distinguish absent resources from inaccessible resources.
4. Capture a sanitized current-state summary with query time and scope.

### 2. Define the service contract

Document:

- purpose, owners, users, environments, and support tier;
- resource types, API versions, dependencies, and data flows;
- availability, latency, throughput, recovery, security, compliance, and cost objectives;
- expected requests, jobs, messages, or transactions and their correlation identifiers;
- maintenance, deployment, backup, restore, failover, and decommission expectations.

### 3. Design desired state

1. Search `artifacts/catalog.json` before generating. Compose compatible validated/approved artifacts and preserve their exact versions/digests.
2. Resolve artifact decision points against current standards and live state. Ask only unresolved material questions and include a recommendation with tradeoffs.
3. Apply current Azure Well-Architected and service guidance.
4. Define fault domains, zone/region strategy, scaling, capacity, quotas, backup, restore, and dependency behavior.
5. Define managed identities, least-privilege RBAC, PIM needs, Key Vault use, network exposure, TLS, authentication, authorization, and policy controls.
6. Prefer versioned infrastructure as code and versioned service configuration. When no artifact fits, create and catalog a candidate version before mutation.
7. Record unavoidable portal-only or imperative steps and how they will be audited.

### 4. Establish observability

Define and verify:

- Activity Log export and resource diagnostic settings;
- destination workspaces, Application Insights, storage archive, or event stream;
- service metrics, request/dependency traces, audit events, platform logs, and health signals;
- correlation across gateway, application, data, messaging, identity, and network layers;
- retention, sampling, ingestion transformation, access control, private connectivity, and cost limits;
- user-facing health probes and synthetic transactions that avoid production data mutation;
- service-level indicators, objectives, alert thresholds, suppression, ownership, and escalation.

Missing telemetry is an onboarding failure unless an explicit risk exception is recorded.

### 5. Build operations knowledge

Create or update the service pack defined in [service pack contract](./references/service-pack-contract.md). Include discovery queries, known-good baselines, dashboards, alerts, failure signatures, diagnostic trees, bounded runbooks, rollback, and verification.

### 6. Validate

1. Validate IaC and run the narrowest plan or what-if.
2. Test identity, network paths, diagnostics ingestion, correlation, alerts, escalation, backup/restore, and failure behavior appropriate to the criticality.
3. Confirm that responders can retrieve evidence with read-only access.
4. Run a game-day scenario before allowing any remediation to become autonomous.

### 7. Execute and verify when requested

1. If the request is advisory or bootstrap mode denies writes, return the executable plan and identify the commissioning blocker.
2. If the user requested implementation and supervised management is enabled, present one bounded action manifest covering provisioning, service configuration, identity, networking, telemetry, alerts, and validation.
3. After explicit approval, execute through Azure MCP when supported; otherwise use the selected IaC, CLI, SDK, ARM REST, or supervised portal path.
4. Verify control-plane state, data-plane behavior, diagnostic ingestion, alert routing, health probes, identity, dependency access, and rollback readiness.
5. Return `READY` only after verification. A successful deployment command without working telemetry and behavior is `CONDITIONALLY_READY` or `NOT_READY`.
6. Write a sanitized execution record and update artifact maturity only from the verifier's result.

## Output

Return an onboarding report with `READY`, `CONDITIONALLY_READY`, or `NOT_READY`, plus:

- current and desired state;
- telemetry and operability coverage;
- risks and permission gaps;
- proposed service-pack files;
- exact changes requiring approval;
- validation evidence and remaining tests;
- candidates for future bounded automation.

For implementation requests, also include the approved change ID, actual operations performed, deployment evidence, verification verdict, and any rollback or residual-risk status.

See [AzureIQ architecture](../../../docs/architecture.md) and [capability boundaries](../../../docs/capabilities.md).