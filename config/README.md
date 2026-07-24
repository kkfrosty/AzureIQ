# AzureIQ Configuration

[azureiq.yaml](azureiq.yaml) is the non-secret operating profile. It records scope and safety intent; it is not a credential file and, until the hosted policy gate exists, it is not a hard technical authorization boundary.

Private tenant, subscription, and account scope belongs in the ignored `config/local.azureiq.json`. AzureIQ merges that file over the tracked defaults on this machine. JSON is used so local executors can parse it with standard libraries and no third-party YAML dependency. Never commit or copy its identifiers into durable chat/repository memory.

AzureIQ is intended to operate in `supervised-management` after commissioning. The current read-only state prevents an unscoped new repository from changing an arbitrary subscription; it is not the product's destination.

## Operating Modes

| Mode | Azure writes | Intended behavior |
| --- | --- | --- |
| `bootstrap-read-only` | `deny` | Discover authenticated scope, inventory resources, select tools and identities, and prepare executable plans without changing Azure |
| `supervised-management` | `supervised` | Create, configure, update, deploy, remediate, and verify within exact configured scope after validation and explicit approval of each action manifest |
| Future hosted automation | Per-runbook policy | Execute only versioned, allowlisted runbooks that have separate automation approval, limits, rollback, and independent verification |

Supervised management is not autonomous subscription-wide write access. It is an interactive operating mode in which the user asks for an outcome, reviews the exact plan once, approves it, and AzureIQ executes and verifies it.

## Current State

- `mode: bootstrap-read-only`
- `targetMode: supervised-management`;
- no tenant, management group, subscription, environment, or region selected;
- `safety.azureWrites: deny`;
- no IaC, approval, incident, evidence, telemetry, or hosted-runtime system selected;
- no risk tier eligible for automatic execution.

## Activation Sequence

1. Add the intended tenant and subscription IDs after confirming the desired blast radius.
2. Record exclusions before broad inventory.
3. Verify the signed-in principal and read-only RBAC without storing tokens.
4. Run the read-only inventory milestone and document permission blind spots.
5. Decide IaC, telemetry topology, approval system, incident system, evidence retention, and execution identities.
6. Install or verify the management paths required for the first vertical slice, such as Azure CLI/Bicep or a supported Azure MCP operation.
7. Keep `azureWrites: deny` until exact scope, principal, validation, approval, rollback, and verification are ready.
8. Change `mode` to `supervised-management` and `azureWrites` to `supervised` through a reviewed Git change. A chat message cannot commission an otherwise unscoped workspace.
9. Perform a non-production create/configure/verify exercise before managing production.
10. Add policy-eligible runbook IDs individually after repeated supervised proof; never enable a risk tier globally.

Before `supervised-management` is accepted, the effective tracked-plus-local profile must identify at least one subscription, the interactive principal, the approval mechanism, the primary IaC choice for repeatable provisioning, and the intended telemetry topology. Automatic risk tiers remain empty during initial supervised operation.

A private commissioned override has this shape. The file is ignored by Git and contains no credentials or tokens:

```json
{
	"schemaVersion": 1,
	"mode": "supervised-management",
	"scope": {
		"tenantId": "00000000-0000-0000-0000-000000000000",
		"subscriptionIds": ["00000000-0000-0000-0000-000000000000"]
	},
	"identity": {
		"interactivePrincipal": "azure-extension-current-user"
	},
	"safety": {
		"azureWrites": "supervised",
		"requireExactScope": true,
		"requireActionManifest": true,
		"requireExplicitApproval": true,
		"automaticRiskTiers": []
	},
	"observability": {
		"topology": "central"
	},
	"operations": {
		"primaryIac": "bicep",
		"approvalSystem": "vscode-explicit-confirmation"
	}
}
```

The validator checks these commissioning fields but cannot verify their truth or the principal's RBAC. AzureIQ must query and compare the authenticated context immediately before each operation. CI validates only the public bootstrap profile because the private override is absent there.

## Secret Boundary

Do not add client secrets, tokens, keys, connection strings, private certificates, subscription keys, named-value secrets, raw payloads, or debug credentials. Store secret material in Key Vault or the approved local/cloud credential mechanism and reference it by non-secret identifier.

Subscription and tenant IDs are identifiers rather than authentication secrets, but they can still be sensitive operational metadata. Share and retain them according to organizational policy.