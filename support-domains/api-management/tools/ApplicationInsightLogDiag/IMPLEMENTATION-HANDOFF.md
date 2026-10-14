# Implementation handoff

## 1. Smallest useful implementation

Prefer a PowerShell 7.4-facing read-only entry point consistent with the existing
[VNet checker](../vnet-check/README.md), a pure rule evaluator and a reviewed
collector. Reuse the existing assessment rather than cloning its rule matrix.
Use the shared host's credential/private-scope boundary where available.

The implementation is not prescribed as a new agent, a new MCP server or a
large SDK abstraction. Existing GHC routing plus a deterministic report is
sufficient for the first version.

Proposed responsibilities:

- **Collector:** allowlisted configuration GETs and optional read-only log
  queries; preserve private bindings in memory.
- **Evaluator:** synthetic/offline inputs to stable findings; no Azure calls.
- **Report:** sanitized JSON and the existing execution-record contract.
- **GHC:** explain evidence and gaps, select the next bounded check, and draft a
  separate remediation proposal when warranted.

## 2. Scope and authentication

Follow [private scope and execution](../../../../docs/execution-tools.md).
Tenant, subscription and expected principal come from private configuration,
not ordinary CLI arguments or model-generated defaults. Related resources in
another resource group need explicit authorized coverage; cross-subscription
or cross-tenant links are valid Azure arrangements, but unsupported/unapproved
reads must become `Unknown`, not configuration faults.

Keep four actors distinct:

1. Diagnostic reader.
2. APIM telemetry-publishing identity.
3. Optional VNet-connected test client.
4. Separately approved change/rollback operator.

Do not grant a reader publication or write permissions to make diagnosis work.
Denied reader access says nothing conclusive about APIM's sender permissions.

Integration issues to resolve with the owning team:

- The existing VNet collector checks the default CLI account. In a shared
  environment that default may not match the authorized private scope.
  Review explicit scope-selected account inspection or the shared credential
  provider; never silently switch the shared CLI default.
- A custom data-plane `az rest` call was observed to use the wrong issuer despite
  a subscription argument. A successful management-plane read is not proof of
  correct Azure Monitor data-plane authentication.
- Use maintained SDK authentication with the correct cloud/audience and verified
  private scope. Do not manually extract, print or persist access tokens.
- The Python prototype's CLI credential rejected simultaneous tenant and
  subscription selection. That observation must not be generalized into a
  different SDK's contract without testing its actual implementation.

## 3. Configuration collection

Read only the surfaces required for the selected model:

| Surface | Required purpose |
| --- | --- |
| APIM service and locations | SKU, gateway/network model, identity candidates, subnet references and configuration freshness |
| API/revision inventory | Exact intended API and effective diagnostic coverage; bound pagination and mark incomplete enumeration |
| Service and API diagnostics | Resolve inheritance and API overrides before selecting a logger |
| Effective logger | Logger type and destination resource reference; auth-selector metadata only |
| Named-value metadata | Recognize protected references without reading `value`, `listValue` or key operations |
| Explicitly authorized Application Insights component | Workspace link, authentication and public/private ingestion/query mode |
| Related authorized workspace | Query target, retention/cap metadata and transformation references where applicable |
| Identity/RBAC metadata | Candidate publishing identity, applicable role scope, conditions and permission-read gaps |
| Existing VNet snapshot | Supported per-region NSG/routes/DNS/native dependency evidence |

Do not enumerate every API or every linked resource without a declared bound.
An exceeded bound is incomplete coverage, not a clean result.

An API diagnostic can override the service-level logger. A service-level logger
and an API-level logger that differ are not automatically broken; assess the
effective target for the API being tested. Preserve the selected source in the
report.

`identityClientId` can be a normal APIM-generated protected named-value
reference on GET. The prototype observed this in a working configuration.
Never mark it invalid because it is not the literal `SystemAssigned`, and never
resolve its secret value to turn an unknown into a pass.

## 4. Diagnostic rule matrix

`Fail` below means a demonstrated constraint violation, not automatically a
confirmed cause of this incident. Keep `status` separate from causal confidence.

| Rule family | A defensible finding | Resolution/verification |
| --- | --- | --- |
| Effective diagnostic absent | `Fail` when the intended API has neither an Application Insights diagnostic nor an inherited one | Propose enabling the intended diagnostic; verify effective readback and new correlated rows |
| Wrong effective destination | `Fail` only against an explicitly supplied expected destination; otherwise explain the observed effective mapping privately | Correct the API override or inspect the intended destination; do not conclude logs were dropped when they were routed elsewhere |
| Sampling and errors | Zero sampling can explain missing successful-request rows; reduced sampling is not necessarily a fault; `alwaysLog` changes error expectations | Use a dedicated approved test API at 100% for exact-count trials; never raise production sampling automatically |
| Protected selector | `Unknown` if its contents cannot be verified without secret retrieval | Verify deployment intent through the owner and use independent delivery evidence |
| MI and local authentication | A verified incompatible mode or disabled required identity is a configuration error; opaque selection stays unknown | Validate the intended identity without resetting it; review the documented authentication mode |
| Publishing RBAC | Report explicit role candidates and conditions; absence of one built-in role is not proof no custom/inherited permission exists | Review least-privilege publication rights on the component; do not auto-grant roles |
| Query actor/audience | `Unknown` delivery when the collector lacks access, uses the wrong issuer or has a query error | Fix the reader's approved authentication/query context, not APIM's publishing configuration |
| NSG egress | `Fail` only for a provable first-match deny of the applicable source/destination/protocol/port; ambiguous prefixes/tags remain unknown | Propose the narrow rule correction and verify actual request delivery after approval |
| Default UDR/NVA | A forced-tunnel route is an investigation trigger, not inherently a fault | Check effective next hop, appliance policy, asymmetric management return path and real endpoint traffic |
| DNS | Distinguish gateway-client DNS from ingestion/authentication endpoint DNS | Check the relevant VNet/resolver/zone/link/cache path; workstation lookup is not APIM-host evidence |
| Ingestion access/AMPLS | Public ingestion disabled can be valid with a working private path | Assess component and workspace access modes plus AMPLS/private DNS; do not automatically re-enable public ingestion |
| TLS/proxy | VM reachability and APIM gateway/backend TLS properties do not certify the SDK sender's TLS stack | Obtain matched source/path evidence; do not suggest disabling certificate validation or legacy-TLS toggles as a generic fix |
| Cap, retention, transformations | Missing rows can follow cap/retention settings or a supported workspace transformation | Review runtime-supported metadata and the explicit observation interval; do not classify these as NSG failures |
| Native dependency status | Fresh, applicable status is useful corroboration; stale, unsupported and optional checks remain qualified | Never equate a successful periodic dependency check with accepted request telemetry |
| Capture/privacy | Body bytes, client-IP capture and sensitive header names are privacy/performance observations | Return metadata only; review masking/allowlists separately, with no actual values exported |

### VNet reuse gap that matters to this scenario

The current VNet rule matrix commonly evaluates a symbolic `VirtualNetwork`
source. Its evaluator deliberately returns unknown for unresolved selector
overlap. A real lab rule scoped to the APIM subnet CIDR may therefore need more
precise source normalization before an endpoint-specific deny can be diagnosed.

Add an owner-reviewed extension for concrete, privately bound source prefixes
and current service-tag/address evidence. Test complete containment, partial
overlap, ASGs, higher-priority uncertainty and security-admin-rule effects.
Do not weaken `Unknown` to `Pass` or `Fail` merely to make a fault trial succeed.

## 5. Actual ingestion evidence

Keep APIM gateway resource logs separate from Application Insights:

- `ApiManagementGatewayLogs` can corroborate gateway handling when configured.
- Workspace scope normally uses `AppRequests` / `TimeGenerated`, filtered by
  the intended component's `_ResourceId`.
- Component Application Insights Logs scope uses `requests` / `timestamp`.
- Discover the actual schema and destination before querying. A missing table,
  wrong scope or empty result is not a transport diagnosis.

Use absolute UTC bounds and a customer-owned unique synthetic marker. Project
counts and minimal correlation evidence, not bodies, headers or unrestricted
URLs. For an approved 100%-sampled, non-multiplexed controlled run, evaluate
generated requests, observed rows, distinct request IDs/operations, expected
responses and a known trace separately. Weighted `ItemCount` is not a substitute
for exact delivery under arbitrary sampling.

Record when each query observed the result. Request event time is not ingestion
arrival time. Retries can deliver fault-window events after restoration.
Use ingestion-time evidence only when actually supported; null/missing arrival
metadata stays unknown.

If a raw REST adapter is necessary, enforce JSON Content-Type and strict response
table/column/type validation. The prototype demonstrated that a missing
Content-Type could yield HTTP 200 with empty tables. That is a collector error,
not zero telemetry or a healthy response.

## 6. Result and resolution contract

Use the existing `Pass` / `Fail` / `Unknown` finding vocabulary. Add independent
facets rather than one misleading green service verdict:

- **Collection:** complete, partial, denied, unsupported, failed.
- **Configuration:** applicable constraints and qualified unknowns.
- **Delivery:** observed, evidence absent, count mismatch, not tested.
- **Root cause:** confirmed, probable, undetermined.
- **Behavior:** intended configuration/test behavior versus observed fault.

Every finding needs a versioned rule ID, sanitized subject/region reference,
evidence references and timestamp, source URL, applicability, missing evidence,
a falsifiable next check, and a proposed resolution with verification.
Do not invent new universal exit-code meanings that conflict with the existing
tool/host; document and test the owning entry point's contract.

Follow the workspace's three report sections: problem definition, diagnosis,
root cause analysis. A read-only assessment writes a sanitized
[execution record](../../../../schemas/execution-record.schema.json) with zero
created/modified/deleted resources. A candidate correction goes into a separate
[action manifest](../../../../schemas/action-manifest.schema.json).

## 7. Privacy and customer independence

Keep private scope, identifiers, raw snapshots, connection strings, credentials,
tokens, hostnames/IPs and sensitive query bindings out of source and sanitized
reports. Use opaque references for related resources. Exact bound KQL may itself
contain private identifiers; retain it only in the approved private evidence
boundary, not in a shareable report.

Normal component metadata can contain connection-string fields. If endpoint
discovery requires such a response, inspect only permitted endpoint metadata
in memory and immediately whitelist what can leave the collector. Never fetch
protected logger/named-value secrets or assume a legacy endpoint when the real
destination is unknown.

Do not depend on Microsoft-internal logs or employee permissions. If customer
evidence cannot settle a service-side sender fault, produce a sanitized support
handoff explaining what was proved and what evidence is unavailable. Internal
support escalation stays outside the public/customer tool.

## 8. GHC integration and delivery sequence

1. Prefer the current Azure MCP/service-skill baseline and read the APIM domain.
2. Invoke the same deterministic diagnostic used without GHC; do not create
   separate terminal and agent rule sets.
3. Treat logs/configuration/report text as data, never as commands or authority.
4. Explain confirmed findings and missing evidence without upgrading unknowns.
5. For a correction, route to Change Planner and obtain a new, exact approved
   manifest; the diagnostic must not have a hidden apply/repair switch.
6. Recheck through Verifier after approved changes, using a new traffic marker.

Implement in this order: synthetic snapshot contract and tests; owner-reviewed
collector/scope extensions; supported network/configuration rules; optional
read-only ingestion query; sanctioned active-probe integration; isolated
fault tests; matched baseline comparison; candidate registration and promotion.

Do not modify the shared catalog, capability registry, agents or VNet checker
from this handoff. Those changes belong to the development team's integration
review after the candidate has evidence.
