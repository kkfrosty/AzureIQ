# Harbor disposable infrastructure

This is the **candidate Standard v2 profile**, not an already deployed service.
It preserves the native API Center Standard discovery MCP requirement and uses
an explicit APIM source link. Never assume that the linked billing benefit is
active from template compilation or source registration alone.

The private readiness handoff is `.azure/harbor-deployment-plan.md`. It is kept
separate from the older Waypoint deployment entry point and is not an
authorization manifest or a claim that rollout is ready.

## Local validation

From the repository root:

```powershell
.\infra\support-service\Update-PackageManifest.ps1
.\infra\support-service\Test-Package.ps1
```

Manifest generation records source digests only and never promotes maturity or
claims test success. If candidate source changes, regenerate its manifest and
update the catalog digest before review. Approved versions are immutable.

The check compiles both entry points without Azure credentials, parses policies,
checks private/keyless storage, Search and Foundry boundaries, and validates the
expected inventory schema. It does not validate provider acceptance, regional
quota, Entra assignments, actual traffic, native MCP activation or billing.

## Deployment stages

Use the existing supported Azure MCP operations or maintained Azure CLI/IaC
tools. No new AzureIQ executor or generic deletion script is supplied.

1. Confirm the authenticated tenant, principal and selected subscription match
   the intended private profile. The Harbor profile must be separately
   commissioned for the exact approved operations; do not inherit another
   subscription's write authority.
2. Resolve region, remaining quotas, exact model/version/capacity, approved alert
   action group, Entra public-client/API registrations and roles, and native
   API Center portal/authentication configuration. Keep actual bindings private.
3. Generate an exact change manifest, complete cost forecast and expected
   resource inventory. Validate/what-if and obtain approval before applying.
4. Apply `foundation-main.bicep` to create the owned registry and private
   foundation. Both entry points must receive identical environment, model,
   resource-group, creation and expiry bindings.
5. Build the actual application image using the application Dockerfile and a
   supported registry build/push operation. Pin its digest. The image must exist
   before `main.bicep` applies; there is no quickstart-image fallback.
6. Bind the real generated OpenAPI and selected MCP tool operations from the
   application build. Apply `main.bicep` with the immutable image.
   The generated support MCP contract is an object: bind its `tools` array to
   the Bicep `supportTools` parameter, not the entire document. Verify its
   `openApiSha256` against the generated OpenAPI before requesting approval.
7. Grant the separately approved Entra application roles and delegated customer
   access. Azure resource RBAC does not substitute for API app-role assignment.
8. Explicitly approve and run the bounded synthetic-data seed job. Do not
   upload documents or create cases as an implicit web-startup action.
9. Complete the supported API Center portal/authenticated native MCP activation
   workflow. The currently published management schema does not establish a
   documented native endpoint toggle here; this is a real readiness gate, not a
   reason to invent a property or substitute a custom MCP server.
10. Verify the Standard plan and eligible linked benefit, source synchronization
    of API definitions, `mcp_registry_search`/`mcp_registry_fetch`, and separately
    authorized executable support MCP calls. Synchronization may be delayed;
    missing evidence is inconclusive, not success.
11. Independently verify real text/voice flows, forbidden direct paths, caller
    isolation/confirmation, ingestion/correlation, alert delivery and usage
    limits. No readiness claim is based solely on configuration readback.

Actual identifiers, principals, contact addresses, endpoints, tokens and plan
outputs belong in the approved ignored private configuration/evidence stores.
The `applicationImage` input must identify an immutable digest at approval.
API Management MCP resources use a pinned preview API; approve that dependency.

The registry is publicly reachable but rejects admin credentials; pulls use
managed identity. Azure Monitor ingestion/query remain public and authenticated.
Application/model/Search/Table data paths are private. This is not a blanket
claim that every service uses Private Link or that public egress is filtered by
Azure Firewall. Front Door/WAF and Firewall remain separately priced exercises.

## Budget admission

Total incremental project allowance is **USD 400/month**, one lab at a time,
with **at most 200 aggregate billed lab-window hours/month**. Provisioning,
failures, idle time and teardown count. Public retail reference rates previously
checked in East US: Standard v2 primary unit USD 0.9589/hour; API Center Standard
USD 0.9575/hour if the benefit is absent; Search Basic USD 0.101/hour.

At 200 hours, gateway plus Search is **USD 211.98** with the verified catalog
benefit; without it those three services are **USD 403.48**, before anything
else. Therefore, 200 hours cannot be admitted without benefit verification or a
shorter conservatively priced run. These figures are partial, not a full quote.

Price hosting, registry, private endpoints/DNS, model/audio usage, Table storage,
telemetry, alerts, identity, retained evidence, and delayed-billing margin.
Reprice against the chosen region/agreement and current meters. Budgets/tags do
not automatically shut down resources. Inference limits reduce usage but do not
stop fixed Azure charges. Reject a run whose conservative total exceeds the
remaining allowance; include unreported charges and reserved teardown margin.

[cost-envelope.json](cost-envelope.json) records the two verified fixed meters
and explicit, unverified reservations. It proposes a shorter first eight-hour
run; it does not claim that every model/audio/network meter is priced or that
the whole 200-hour allowance is affordable. Admission remains blocked until
the full forecast and linked benefit are verified.

## Removal and recreation

Teardown is a separately approved destructive change, not automatic permission
from an expiry tag:

1. Compare actual resources and child resources with expanded
   `EXPECTED_RESOURCE_IDS`, ownership/environment tags and
   [expected-inventory.json](expected-inventory.json). Investigate provider-owned
   Container Apps infrastructure resources; never blindly delete an unfamiliar
   resource group. Stop on locks, shared resources or unexplained drift.
   Private-endpoint NICs are provider-created resources: validate their exact
   private-endpoint references from the expanded inventory rather than assuming
   missing user tags imply unrelated ownership. Delete through their owning
   private endpoint, never as an independent wildcard NIC cleanup.
2. Preserve only approved sanitized evidence. Source, image digest, synthetic
   corpus, registration definitions and private binding references are rebuild
   inputs; credentials and raw conversations/audio are not.
3. Delete the disposable API Center and verify absence **before** deleting its
   eligible linked APIM. Leaving Standard API Center after losing the link can
   create paid orphan charges. Do not assume disabling MCP or a stop/downgrade
   operation stops billing.
4. Remove remaining owned resources in the supported dependency order, then
   reconcile active inventory, provider-owned infrastructure and retained costs.
   Never delete the shared alert destination or external Entra registrations as
   part of a resource-group deletion.
5. Confirm the selected services' soft-delete/name-reservation behavior. APIM's
   documented retention can reserve a name for 48 hours; use fresh run names or
   an explicitly approved recovery/purge decision. Never auto-purge.
6. Recreate using the same reviewed artifact versions and new private bindings.
   Resolve new managed-identity principals/app roles, refresh client endpoints,
   reseed approved synthetic data, reactivate native MCP, and repeat verification.
7. Prove a second full create/use/remove cycle before calling the composition
   reusable. Reconcile delayed costs separately from active-resource absence.

VS Code cannot enforce teardown while closed. Until separately approved hosted
controls exist, an available operator must carry out the approved teardown
within the planned window. This package does not claim that generic AzureIQ
`environment teardown-*` commands are already implemented.
