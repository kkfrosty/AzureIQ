# Azure API Management Support Domain

**Status:** `observed`

**Value proof:** `value-demonstrated`

**Documentation reviewed:** 2026-07-24

**Cloud resources validated:** one Developer-tier APIM service with a Container Apps backend, read-only

This pack is the first AzureIQ vertical slice. It is not yet authority to create or modify an API Management instance. Its unexpected-response path has now been exercised read-only against a live service.

## Value Hypotheses

The [manifest](manifest.yaml) records two hypotheses: schema-verified gateway evidence may correct generic log-query mistakes, and bounded planning plus independent verification may make APIM policy remediation safer.

The first hypothesis is now `value-demonstrated`. In the live comparison the registered platform baseline produced nothing usable: AppLens failed twice for the APIM resource and does not support Container Apps backends, and a natural-language Resource Graph request was mistranslated into an unrelated query that returned zero rows. The gateway `ResponseCode` versus `BackendResponseCode` comparison localized both failures on the first scoped query. Azure MCP monitoring alone can reach the same result, but only after selecting the correct workspace, tables, and join key, which this pack now records.

The second hypothesis remains `unproven` because no remediation has been planned or executed.

## Diagnosis Order

1. Attempt AppLens for supported resource types and record the outcome, including failures.
2. Retrieve gateway evidence with [request-evidence.kql](queries/request-evidence.kql) using absolute UTC bounds.
3. Localize with `BackendResponseCode`: empty means APIM answered before the backend, populated and equal means APIM relayed the backend outcome.
4. Correlate instrumented hops with Azure Monitor [distributed-trace-correlation.kql](../azure-monitor/queries/distributed-trace-correlation.kql) by Application Insights `OperationId`.
5. Explain backend latency or restarts with the backend support domain's evidence, such as Container Apps [platform-evidence.kql](../container-apps/queries/platform-evidence.kql).
6. Separate deliberate application behavior, including synthetic and fault-injection endpoints, from infrastructure faults before declaring an incident.

Before adding more APIM guidance, run the same scenarios first with Azure MCP and installed Azure skills alone, then with this pack under equivalent scope, permissions, telemetry, and starting context. Keep only artifacts that materially improve the declared acceptance criteria. Mark an equivalent result `no-value` and retire the redundant artifact.

## Intended Coverage

- service provisioning, SKU/capacity, zones, regions, gateways, workspaces, and upgrade constraints;
- networking, DNS, private connectivity, ingress/egress, certificates, custom domains, and dependencies;
- managed identities, RBAC, Key Vault, subscriptions, OAuth/OIDC, client certificates, and backend authentication;
- APIs, versions, revisions, operations, products, groups, backends, named values, policy fragments, and effective policy;
- inbound, backend, outbound, and on-error policy behavior;
- deployment, promotion, rollback, backup/restore support where the selected tier supports it, and disaster recovery;
- gateway metrics and resource logs, Activity Log, Application Insights, secure tracing, alerts, dashboards, and evidence retention;
- user-visible correctness, latency, availability, capacity, authentication, backend, policy, certificate, and network incidents.

Every capability is SKU, gateway, workspace, API-version, network, and region dependent. The onboarding workflow must resolve those conditions from current Microsoft documentation and the target resource before producing a change plan.

## Current Tool Boundary

The current VS Code environment has the official API Management extension, REST Client, XML support, Azure MCP diagnostics, monitoring, documentation, Resource Graph, Activity Log, and related Azure surfaces. No dedicated generic API Management MCP management router was observed, and the local Azure CLI is absent.

AppLens is the registered first-choice detector surface, but its coverage is narrow and unreliable here. Verified on 2026-07-24: it exposes a single conversational diagnose command rather than an enumerable detector list; it supports only `microsoft.web/sites`, `microsoft.containerservice/managedclusters`, and `microsoft.apimanagement/service`; it failed twice for the validated Developer-tier APIM service with `BadRequest`; and Container Apps backends support neither AppLens nor Resource Health, which returned `422`. Attempt the detector first, record the outcome, and continue to telemetry without waiting for it.

Until that changes:

1. use Azure MCP and existing Azure AI Gateway guidance where applicable;
2. use the APIM extension for interactive policy authoring, API management, and supported testing/debugging workflows;
3. use the API Management ARM REST API for supported generic operations when explicitly approved;
4. install and validate Azure CLI before relying on `az apim` workflows;
5. use the portal/browser only for a supported operation that lacks a suitable API/tool path;
6. capture the exact fallback and audit evidence.

The VS Code policy step debugger is limited by current Microsoft guidance to the APIM Developer tier and requires service-owner access plus the built-in all-access subscription. Use it only in an appropriate isolated development service. Production diagnosis should rely on gateway logs, Application Insights, effective policy, revisions, safe request tracing, and controlled test traffic.

## Minimum Observability Baseline

- Export subscription Activity Log to the chosen operational workspace/archive.
- Enable API Management resource logs through diagnostic settings and prefer the resource-specific `ApiManagementGatewayLogs` table.
- Discover and select current categories for gateway, WebSocket, developer portal, generative AI gateway, or MCP traffic only when those surfaces are used.
- Integrate Application Insights when request/dependency/exception correlation is needed. Prefer a connection string with API Management managed identity credentials and scope `Monitoring Metrics Publisher` to the Application Insights resource, subject to current support.
- Configure API diagnostics deliberately. Default request/response body logging remains off; sampling, error capture, header allowlists, and payload limits require a data and performance review.
- Monitor telemetry ingestion itself. New Log Analytics workspaces can take substantially longer to receive initial data than established workspaces.
- Use tail-latency and error/success-rate signals per important method rather than relying only on averages or raw failure counts.

API Management logging is asynchronous except for request tracing. Azure Monitor log records have size limits and can drop body/trace content when entries are too large. Missing body content is therefore not proof that no transformation occurred.

Gateway logs, Application Insights, and backend platform logs are often split across more than one workspace. Resolve the workspace that owns each table before concluding that a request is missing, and never read an empty result as proof that traffic or a change did not occur.

## Request Tracing Boundary

- `Ocp-Apim-Trace` subscription tracing is no longer supported.
- For an external client, obtain a time-limited, API-specific debug credential through the API Management REST API, send it in `Apim-Debug-Authorization`, capture `Apim-Trace-Id`, then retrieve the trace.
- The debug credential requires elevated API Management rights, expires in at most one hour under current guidance, and is secret material. Never store it in Git, chat, incident memory, or command output.
- Traces can expose sensitive inbound, backend, outbound, and on-error data. Minimize the request and sanitize retained evidence.
- Current Microsoft guidance says this tracing feature is unavailable in API Management workspaces. Recheck before each implementation because this is version-sensitive.

## Authoritative References

- [Monitor API Management](https://learn.microsoft.com/azure/api-management/monitor-api-management)
- [API Management monitoring data reference](https://learn.microsoft.com/azure/api-management/monitor-api-management-reference)
- [ApiManagementGatewayLogs table](https://learn.microsoft.com/azure/azure-monitor/reference/tables/apimanagementgatewaylogs)
- [API Management request tracing](https://learn.microsoft.com/azure/api-management/api-management-howto-api-inspector)
- [Application Insights integration](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights)
- [API Management policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies)

The review date in [manifest.yaml](manifest.yaml) must be advanced only after these and the selected tier/API documentation are rechecked.