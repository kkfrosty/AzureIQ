# Azure API Management Service Pack

**Status:** `draft`  
**Value proof:** `unproven`  
**Documentation reviewed:** 2026-07-19  
**Cloud resources validated:** none

This pack is the first AzureIQ vertical slice. It is not yet authority to create or modify an API Management instance, and it has not yet demonstrated an advantage over Azure MCP alone.

## Value Hypotheses

The [manifest](manifest.yaml) records two hypotheses: schema-verified gateway evidence may correct generic log-query mistakes, and bounded planning plus independent verification may make APIM policy remediation safer. Neither gap has been observed in a controlled comparison yet.

Before adding more APIM guidance, run the same unexpected-response and policy-remediation scenarios first with Azure MCP and installed Azure skills alone, then with this pack under equivalent scope, permissions, telemetry, and starting context. Keep only artifacts that materially improve the declared acceptance criteria. Mark an equivalent result `no-value` and retire the redundant artifact.

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