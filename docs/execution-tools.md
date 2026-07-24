# AzureIQ Execution Tools

AzureIQ uses the smallest supported execution surface for each operation. Local tooling is a value-add fallback, not a replacement for Azure MCP.

## Selection Order

1. Use an installed Azure MCP tool when it exposes the required read or mutation with suitable parameters.
2. Use an installed Azure service skill or extension when it provides a supported, repeatable operation.
3. Use declarative Bicep or Terraform for repeatable service topologies and configuration.
4. For a proven gap, have GHC generate a bounded candidate operation package for the AzureIQ coding engine. Prefer generic declarative deployment over handwritten resource-specific SDK code.
5. Use direct ARM REST or supervised browser interaction only when no maintained path exists.

Do not duplicate a working MCP operation locally merely to standardize syntax. AzureIQ-specific value should be customer scope, missing mutation coverage, safety checks, idempotency, validation, evidence, or verification.

## Shared CLI

`src/AzureIQ.Execution` builds the `azureiq` command. It is the only local mutation executable. Operations are subcommands, not separate resource-specific scripts.

The current Resource Group operation is a proof of the shared authentication and safety boundary. It is not a pattern to copy across Azure resource types. [The coding-engine architecture](coding-engine.md) defines the generic generated-package target and its fixed execution adapters.

Discover operations and parameter contracts:

```powershell
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- operations list
```

Current operation:

```powershell
dotnet run --project ./src/AzureIQ.Execution --configuration Release --no-restore -- resource-group ensure --name '<name>' --location '<region>' --what-if
```

GitHub Copilot discovers this command through the always-on instructions and change-control skill, then passes explicit parameters through the terminal tool. The output is JSON so the agent can validate it without parsing prose.

## Authentication And Private Scope

- Local execution uses the existing VS Code Azure credential and broker integration.
- Hosted execution uses system-assigned or user-assigned managed identity.
- Tenant and subscription scope come only from ignored `config/local.azureiq.json`.
- The CLI must not accept subscription or tenant IDs as normal command arguments. This prevents a prompt or generated command from silently broadening scope.
- Errors and output must redact private scope values and never include tokens or credentials.
- Every mutation requires effective supervised mode and explicit approval outside the CLI. The CLI is an executor, not an approval authority.

## Operation Admission

Before adding engine code or an operation, record:

- the Azure MCP/extension/skill capability checked and its version;
- the exact missing or incorrect behavior;
- why IaC is not the better reusable abstraction;
- required RBAC and data-plane permissions;
- risk tier, idempotency, dry-run behavior, rollback, and verification;
- test evidence against a non-production scope;
- whether output and errors remain free of private identifiers and secrets.

Reject one-customer or one-resource implementations. Names, locations, SKUs, and supported settings are parameters. Shared authentication, scope validation, redaction, and JSON output stay in the common host.

## When To Expose A Local MCP Server

The CLI already gives GitHub Copilot a parameterized, testable tool through terminal execution. A local MCP server would improve first-class schema discovery and remove shell command construction, but it also adds a long-running process, protocol surface, configuration, versioning, and another security boundary.

Promote the shared operation layer to a local MCP server when at least several stable operations exist or comparison testing shows terminal invocation is causing material routing, parameter, or reliability failures. The MCP server must call the same operation implementations; it must not create a second execution codebase.

## PostgreSQL

The Microsoft PostgreSQL VS Code extension (`ms-ossdata.vscode-pgsql`) contributes a local-process MCP server. That server is extension-owned, starts a loopback HTTP endpoint on an ephemeral port, and currently advertises 23 PostgreSQL tools for connection profiles, schema context, read-only queries, confirmed database modifications, migration, and dashboard analysis. It is local tooling, but it is not AzureIQ-owned code and does not live in this repository.

The extension also contributes fallback language-model tools when its MCP server is unavailable. AzureIQ must use the extension's MCP/tool surface before considering any PostgreSQL implementation.

There is no AzureIQ PostgreSQL executor, script, or service pack. Add a PostgreSQL operation to the shared AzureIQ host only after a specific unsupported action is reproduced against the extension-contributed tools and the shared-tool admission checks pass.

A startup `ECONNREFUSED` against `127.0.0.1:<ephemeral-port>` can occur if VS Code probes before the extension service is ready. Treat it as transient when a subsequent start reaches `Discovered <n> tools`. Treat it as a fault only when retries do not reach tool discovery or PostgreSQL tools fail when invoked. Never hardcode or monitor a historical loopback port.