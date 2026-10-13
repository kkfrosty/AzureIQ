# Capability Boundaries

This ledger is intentionally candid. It describes the environment observed on 2026-07-19 and should be refreshed as tools and permissions change.

## Available Now

| Capability | Current evidence | Practical use |
| --- | --- | --- |
| Azure MCP | `ms-azuretools.vscode-azure-mcp-server@2.0.46` is installed and Azure MCP tools are exposed in this session | Resource discovery, best practices, diagnostics, monitoring, deployment support, and many service operations |
| Azure Copilot integration | `ms-azuretools.vscode-azure-github-copilot@1.0.209` is installed | Interactive Azure-aware assistance in VS Code |
| Azure resource extensions | Resource Groups, App Service, Functions, Storage, VMs, Container Apps, Cosmos DB, and related extensions are installed | Interactive resource inspection and selected management actions |
| API Management authoring tools | `ms-azuretools.vscode-apimanagement@1.3.0`, `humao.rest-client@0.25.1`, and XML support are installed | APIM policy authoring/explanation, API testing, and Developer-tier policy debugging after VS Code reload and Azure authentication |
| PostgreSQL extension MCP | `ms-ossdata.vscode-pgsql@1.26.0` contributes an extension-hosted local MCP server and discovered 23 tools after startup | Use its database query, modification, schema, migration, and dashboard tools before adding any AzureIQ PostgreSQL operation |
| Diagnostic tool surfaces | Resource Graph, Activity Log, Azure Monitor, Application Insights, AppLens, Resource Health, Azure Policy, and related MCP surfaces are available in this session | Read-only inventory and incident evidence gathering, subject to authentication and RBAC |
| Existing Azure skills | Skills are available for diagnostics, observability, cost, compliance, reliability, deployment, validation, RBAC, storage, messaging, AKS, PostgreSQL, Foundry, and other domains | Reuse supported procedures instead of duplicating them in AzureIQ |
| Browser automation | Browser and Playwright tool surfaces are available in this session | Last-mile portal workflows and visual verification when no supported API/tool path exists |
| Containers and Kubernetes | Docker and `kubectl` are installed | Local packaging and Kubernetes interaction after context and authorization checks |
| PowerShell and Git | PowerShell 7 and Git are installed | Local scripting, validation, and version control tooling |
| Git repository | AzureIQ is initialized on `main`; no commit existed at the latest assessment | Local history and review can begin once the bootstrap is committed and a remote/review policy is configured |
| AzureIQ execution CLI | The .NET Azure SDK host has completed Resource Group dry-run, create, independent Resource Graph verification, and idempotency checks | Parameterized local operations for proven MCP gaps, using VS Code credentials locally and managed identity when hosted, with private scope outside Git |

## Missing or Unproven

| Capability | Current state | Consequence |
| --- | --- | --- |
| Azure CLI | `az` was not found on `PATH` | Generic management fallback, including broad API Management coverage, is not locally available yet |
| Azure Developer CLI | `azd` was not found on `PATH` | Standardized application provisioning and deployment workflows cannot run locally yet |
| Bicep CLI | `bicep` was not found on `PATH` | Standalone Bicep build/lint is unavailable; an installed `az` can later manage a compatible Bicep binary |
| Terraform CLI | `terraform` was not found on `PATH` | Terraform plan/apply/validate workflows are unavailable locally |
| Azure scope and identity | No tenant, subscription, resource group, principal, or role assignment has been selected or verified by this repository | AzureIQ remains in commissioning mode until exact scope and identity are configured, then transitions to supervised management |
| Telemetry coverage | No diagnostic settings, Log Analytics workspace, Application Insights resources, retention, alerts, or archives have been inventoried | Reliable diagnosis cannot yet be assumed |
| Always-on runtime | No event pipeline, durable workflow host, managed identity, approval service, or incident store exists | VS Code cannot proactively monitor or remediate while closed |
| APIM full lifecycle tool | The APIM VS Code extension is installed, but no dedicated generic API Management MCP router was observed and Azure CLI remains absent | The extension covers interactive APIM workflows; repeatable generic APIM configuration still needs verified IaC, ARM REST, Azure CLI, SDK, or portal paths |
| Deterministic policy gate | No signed action manifest, policy engine, hook, or hosted authorization gate exists | Natural-language approval rules are guidance, not a hard security boundary |

## What We Can Build Without a Custom VS Code Extension

- Workspace instructions, custom agents, skills, prompts, and hooks using supported Copilot customization files.
- Read-only discovery and evidence gathering through Azure MCP and existing extensions.
- Versioned support domains, KQL queries, policy templates, IaC, runbooks, action schemas, tests, and incident templates.
- Supervised deployments and remediations through supported MCP operations or installed CLIs after explicit approval.
- Portal fallback through interactive browser tools for gaps that cannot be closed through a supported API.
- A hosted Azure operations runtime using standard Azure services and APIs.

A custom VS Code extension should be considered only if supported customization primitives cannot provide a necessary user experience, credential boundary, tool protocol, or deterministic approval interaction. It is not needed for the initial architecture.

## What We Cannot Honestly Promise

- Complete management coverage for every Azure service and API version from the current extension set alone.
- Safe subscription-wide autonomous write access based only on agent instructions.
- Continuous monitoring from a VS Code session.
- Diagnosis of evidence that was never collected or retained.
- Guaranteed prevention of false positives, model errors, Azure outages, or damaging operator approval.
- Bypassing Entra authentication, MFA, Conditional Access, PIM, Azure Policy, locks, provider registration, quota, or regional capacity.
- Automatic remediation of irreversible data loss, unknown blast radius, broad identity changes, or ambiguous incidents at an acceptable risk level.

## Tool Selection Order

1. Existing service-specific Azure skill and Azure MCP operation.
2. Azure Resource Graph, Monitor, AppLens, Application Insights, Activity Log, or Resource Health for evidence.
3. Declarative IaC and its validation/what-if path for repeatable changes.
4. Supported Azure CLI, PowerShell, SDK, or ARM REST operation.
5. Interactive portal/browser operation when it is the only supported path.

Each fallback must preserve target verification, least privilege, approval, redaction, audit, rollback, and post-change verification.