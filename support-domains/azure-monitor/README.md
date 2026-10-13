# Azure Monitor Support Domain

Owns cross-service telemetry schemas and correlation logic for Azure Monitor, Log Analytics, and workspace-based Application Insights.

## Current Scope

- `Microsoft.Insights/components`
- `Microsoft.OperationalInsights/workspaces`
- `AppRequests`, `AppDependencies`, `AppExceptions`, and `AppTraces`
- distributed-trace correlation across instrumented Azure services

Resource-specific platform and gateway queries stay in their owning support domains. This domain supplies shared telemetry joins to collaborating runbooks.