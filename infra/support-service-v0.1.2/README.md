# Harbor existing-network recovery candidate

This unapproved v0.1.2 candidate preserves two existing subnet NSG attachments
when resuming a partial Harbor deployment. It retains the v0.1.1 Search
authentication and Foundry serialization repairs. Earlier approved versions
remain unchanged.

The candidate also explicitly preserves two observed mutable controls that
the old template omitted: Container Apps environment public network access
`Disabled` and Search trusted-service bypass `None`. Do not assume that omitting
these properties from a PUT preserves their current values.
The registry retains its existing stable API and authentication configuration;
its ARM-audience policy must be checked after apply rather than adding an
unsupported property or suppressing a compiler diagnostic.

## Measured reason for this version

The November 9 read-only Provider what-if for v0.1.1 predicted no resource
deletions, but did predict removal of the Container Apps and private-endpoint
subnets' existing `networkSecurityGroup` properties. Zero resource deletions
alone is therefore insufficient admission.

The recovery entrypoint requires
`containerAppsSubnetNetworkSecurityGroupId` and
`privateEndpointsSubnetNetworkSecurityGroupId`. Bind them only to the exact
current attachments read from the owned VNet. Verify each NSG exists in the
same approved subscription/resource group. This package does not create,
adopt ownership of, edit rules on, or delete those NSGs. Their creator is not
inferred from their names.

This is an existing-network recovery package, not a fresh-environment
bootstrap. Use the original package's owned-inventory and lifecycle controls.
No separate foundation replay, image rebuild, initialization replay, usage
reset, identity change or higher runtime cap is introduced.

## Validation and release gates

Run `.\Test-Package.ps1` for offline Bicep, parameter-forwarding, subnet-binding,
private/keyless Search, service-tier, current security-control and source-closure
checks.

Before any apply, obtain approval for this exact new source version and
current lab dates, then run fresh Provider validation and what-if with actual
bindings. Require zero deletes or replacements **and no removal/rebinding of
existing NSG attachments**. Review unresolved provider expressions and every
other security/RBAC change; compilation is not deployment acceptance.

Changing the configured application deadline does not reset its durable
usage ledger. A stored Budget row bound to another deadline blocks admission;
do not bypass it by deleting data, changing the window identifier or weakening
the application guard. Native API Center MCP, customer flows, telemetry,
alerts, directory app-role grants and independent acceptance remain required.
No PIM or new tenant role is authorized by this package.
