# AzureIQ Reusable Artifacts

[catalog.json](catalog.json) is the tracked inventory of reusable, non-secret AzureIQ assets. It includes only artifacts that physically exist and records exact version, source digest, compatibility, parameters, decision points, validation freshness, and reuse policy.

The catalog complements rather than replaces:

- live MCP/extension tool descriptions for current platform capabilities;
- `capabilities/registry.json` for routing constraints and proven gaps;
- service packs for service-specific operating knowledge;
- Azure as the source of current resource state;
- the runtime execution ledger for what actually ran.

Generated content begins as `candidate`. GHC must search this catalog before generating a new asset. It may reuse a compatible `validated` or `approved` version, adapt a draft with explicit revalidation, or create a new candidate version when conditions differ. It must never silently edit an approved version in place.

Customer identifiers, environment bindings, secrets, deployment parameters, and raw evidence do not belong here. Store private bindings in ignored local configuration or approved Azure services such as Key Vault.