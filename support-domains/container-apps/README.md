# Azure Container Apps Support Domain

Owns Container Apps-specific inventory, revision, replica, scaling, ingress, image-pull, managed-environment, and platform-log evidence.

## Current Scope

- `Microsoft.App/containerApps`
- `Microsoft.App/managedEnvironments`
- managed-environment system logs and revision/platform health
- collaboration with API Management, Azure Monitor, Container Registry, identity, and networking packs

Application request spans and distributed-trace joins remain owned by the [Azure Monitor pack](../azure-monitor/README.md). Gateway policy and response localization remain owned by the [API Management pack](../api-management/README.md).