# AzureIQ Capability Overlays

[registry.json](registry.json) tells GitHub Copilot how AzureIQ augments live extension and MCP tool discovery. It does not enumerate every Azure MCP tool; tool descriptions supplied by installed MCP servers remain authoritative for generic capability.

An overlay exists only when AzureIQ must record one or more of:

- a confirmed platform-tool gap and proven local fallback;
- required evidence that must corroborate a detector or diagnostic result;
- customer-specific service-pack knowledge;
- a maturity or value-proof warning;
- mandatory independent verification;
- an extension-owned tool surface whose ownership could otherwise be confused with repository code.

## GHC Routing

1. Classify the user intent.
2. Search live MCP and extension tool descriptions.
3. Check this registry for a matching overlay.
4. Use the overlay to constrain evidence, fallback, maturity, and verification.
5. Load referenced skills or service packs progressively.
6. For local CLI operations, run `operations list` and use only the registered operation and parameters.
7. Never treat registry presence as approval to mutate Azure.

If no overlay matches, use the live Azure MCP/extension capability normally. Do not add an overlay unless the default behavior needs a measured correction or guard.