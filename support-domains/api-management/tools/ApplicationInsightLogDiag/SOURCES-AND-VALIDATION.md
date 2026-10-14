# Sources and validation status

Reviewed 2026-10-14. Public documentation defines supported constraints;
captured evidence determines whether they apply to a particular service.

## Public source map

| Source | Use | Important limit |
| --- | --- | --- |
| [APIM Application Insights integration](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights) | Logger, identity, publication role, diagnostics and API override | Workspaces/self-hosted gateways have different support boundaries; sampling is not delivery proof |
| [APIM VNet configuration](https://learn.microsoft.com/azure/api-management/virtual-network-reference) | Classic dependencies, monitoring ports and conditional requirements | Not an exhaustive executable test of all features or v2 networking |
| [Internal VNet DNS and routing](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet) | Private gateway resolution and forced-tunnel investigation | Do not create an authoritative `azure-api.net` apex zone or assume UDRs prove failure |
| [Application Insights Entra authentication](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication) | Auth mode and publication permissions | Reader permissions, sender permissions and SDK support are separate |
| [AppRequests table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/apprequests) | Workspace schema and correlation fields | Runtime schema must still be verified; supported transformations can affect retained rows |
| [Azure Monitor query API](https://learn.microsoft.com/azure/azure-monitor/logs/api/access-api) | API endpoint/authentication and JSON query transport | Successful ARM access does not certify the query audience; parse result shape strictly |
| [Azure platform DNS/agent behavior](https://learn.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16) | DNS and agent exemptions, deny-only platform override | Do not model these as ordinary required `Allow` service-tag rules |
| [VNet checker's reviewed sources](../vnet-check/SOURCES.md) | Versioned existing networking interpretation | Candidate's missing effective-route, firewall, DNS and TLS evidence remains missing |

AMPLS/perimeter, newer gateway models, sovereign clouds and SDK-specific transport
must receive their own current public documentation review before implementation
or compatibility claims. This handoff does not assert those branches are tested.

## Evidence already demonstrated

| Evidence | Status | What it does not prove |
| --- | --- | --- |
| Historical isolated classic Developer/internal-VNet study: 20 synthetic requests and 20 successful correlated request rows | Observed outside AzureIQ on 2026-10-13 | Current state, customer ingestion, negative network diagnosis, Premium/v2/workspace/self-hosted coverage |
| Standalone read-only prototype and internal probe reproduce that historical request evidence | Observed outside AzureIQ | A directly portable AzureIQ entry point, complete effective RBAC or protected secret contents |
| Prototype input/auth/override/redaction/result-shape regressions | 17 tests passed in its owning workspace | New AzureIQ implementation correctness |
| Existing AzureIQ VNet rule suite | 50 assertions passed on 2026-10-14; zero Azure calls | Live networking or end-to-end ingestion |
| Existing AzureIQ mocked collector suite | 11 assertions passed on 2026-10-14; zero Azure calls | Live principal selection or telemetry-query authorization |
| New ApplicationInsightLogDiag implementation | Not implemented in this folder | Any executable diagnosis or remediation |
| Negative/fault experiments and matched MCP/GHC comparison | Not executed | Detection rate, resolution accuracy or value-demonstrated status |

Do not merge these maturity labels. Existing support-domain validation for a
different case does not confer validation on the VNet checker or this proposal.

## AzureIQ validation limits observed during review

The repository-wide workspace contract check failed **before this handoff**
because the required `.azure/deployment-plan.md` was absent. That is an existing
workspace/documentation prerequisite, not a failure of the diagnostic proposal.
It was not fabricated or repaired in this directory-only change.

Use bounded local-link/privacy checks on these documents, and rerun the full
workspace check once its owning team supplies the valid deployment plan.
Do not declare the whole repository validated from these document checks.

## Required regression coverage for the implementation

1. Wrong/changed private scope, principal or cloud: stop before resource reads.
2. API/revision override, inheritance, absent diagnostic and bounded enumeration.
3. Normal opaque protected selector: unknown, never invalid; no secret APIs.
4. Reader access denied versus publishing authorization evidence.
5. Conditional/custom/inherited roles and incomplete role-read coverage.
6. Ordered denies, concrete source prefixes, partial overlap, service tags, ASGs
   and security-admin/effective-route uncertainty.
7. Classic versus Premium v2 versus integration/workspace/self-hosted gating.
8. DNS client-path versus sender-path distinction and cache/freshness handling.
9. Wrong component/workspace/table, schema errors, malformed/partial/empty results,
   asynchronous delivery, sampling and delayed fault-window retries.
10. Sanitized stdout/stderr/reports/records, including malformed input and
    prompt-injection strings carried by resource descriptions or log content.
11. No implicit traffic, credential installation, login/default switching,
    provider/feature registration, grants or resource writes.
12. Exact positive/fault/recovery assertions and rollback/concurrency failures.

The release evidence must include real candidate outputs for every claimed
fault, not only a script exit code or a plausible recommendation.

## Publication boundary

This folder is suitable for public/customer collaboration: original design,
public references and sanitized aggregate observations only. Do not copy
customer case material, private scope/runtime records, employee-only source code,
internal knowledge-list contents or service-side log account/stream details.
Retain internal access/escalation notes in the owning support workspace.
