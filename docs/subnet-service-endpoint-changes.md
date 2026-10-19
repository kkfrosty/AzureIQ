# Subnet service endpoint changes

Use the existing `change` workflow for explicit requests to enable APIM subnet
service endpoints. Troubleshooting remains read-only.

## Admitted operation

`network.subnet-core-service-endpoints` 0.1.0 initializes **Microsoft.Storage**,
**Microsoft.Sql**, and **Microsoft.KeyVault** on one existing classic APIM subnet.
The endpoint set must be empty. APIM's SKU and subnet membership are checked.
Event Hubs is not automatically enabled when no corresponding usage is established.

This is a constrained CLI recipe, not generated executable code. The fixed
executor accepts only `az network vnet subnet update` with target arguments
matching the plan and either the declared service list or the declared rollback.
It appends the private subscription itself. Additional flags, shell syntax,
other command families, cross-subscription targets and subnet deletion are
rejected. Existing custom endpoint/location sets require a different reviewed
additive recipe, not silent replacement.

Azure CLI's maintained read/modify/update preserves the remaining subnet
configuration. Do not replace a live subnet with a partial Bicep/ARM resource.
The executor independently checks prefix, NSG, route table, delegations, NAT,
endpoint policies, default outbound access and private-network policies before reporting a match.
No NSG, UDR, DNS, firewall, APIM policy or service access rule is changed.

Existing IP-configuration associations can reference managed NIC/scale-set or
load-balancer resources in another subscription. Recognized reference IDs are
retained as opaque read-only snapshot data, never dereferenced or used in
command arguments. Mutable foreign resource references and foreign targets
remain rejected; rollback uses only the endpoint-removal argument array.

## Planning and approval

Prefix commands with:

```powershell
dotnet run --project .\src\AzureIQ.Execution --configuration Release --no-restore --
```

Use `change validate` and `change plan` with `--artifact
network.subnet-core-service-endpoints --version 0.1.0 --parameters <private-json>`.
The binding file contains the resource group, VNet, subnet and APIM names.

The plan captures the full before-state, exact argument array, package digest,
installed CLI version/executable fingerprint, and verified SDK/CLI identity.
CLI account cloud, selected subscription, tenant and configured principal must
match private scope. The CLI token principal must match the SDK token principal.
No login, context switch, extension install, permission grant or provider
registration happens automatically.

Use AzureIQ Change Planner to review the exact **R3** manifest and obtain its
digest-bound user approval. Then use `change approve` and `change apply-approved`.
Expiry, source, account/tool-version or state drift blocks execution.
Writes are one-use and never retried automatically. A timeout may leave a
server-side operation running: inspect with read-only tools before doing more.

The scoped native update is the plan/diff primitive; this lane does not claim
ARM deployment what-if. Before mutation verify endpoint availability in the
region, ownership and effective subnet write permission. Network Contributor
scoped to the VNet or a reviewed narrower role can supply the required
`Microsoft.Network/virtualNetworks/subnets/read` and `/write` permissions.
This workflow does not grant those roles.

## Risks and rollback

Enabling endpoints changes service routes and source IP identity from public to
subnet-private addressing. Existing TCP connections can close; public-IP-only
service firewall allowlists can stop matching. Coordinate a quiet maintenance
window, recovery owner and exclusive change ownership. Endpoint creation itself
does not create a private endpoint or alter service-side firewalls.

The native CLI does not provide an atomic conditional-write guarantee here.
Before-state checks and the workspace lock do not prevent an external operator
from changing the subnet during execution.

`change rollback-plan` prepares a fresh **R3** proposal clearing only the newly
initialized endpoint set using `--remove serviceEndpoints`. It never deletes
the subnet. Separate approval is required. Non-endpoint configuration drift
blocks rollback rather than overwriting another operator.

## Independent verification and maturity

The package is candidate with offline evidence only until a controlled live run.
The verifier must:

- Confirm the exact three endpoint services and `Succeeded` provisioning.
- Compare the preserved subnet settings with the captured before-state.
- Rerun the VNet checker and inspect APIM dependency timestamps after the change;
  a recent but pre-change platform probe is not post-change connectivity proof.
- Treat any new required dependency failure as a stop condition; preserve
  evidence and prepare rollback, but do not execute rollback without approval.
- State when client/backend paths remain untested. Do not generate traffic
  merely to make a result green.

See [Azure service endpoint considerations](https://learn.microsoft.com/azure/virtual-network/virtual-network-service-endpoints-overview#considerations)
for source-IP and connection-reset behavior.
