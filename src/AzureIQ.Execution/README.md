# AzureIQ Execution Host

This .NET project is currently a proof-of-concept shared CLI, not the final AzureIQ coding engine.

Implemented:

- local VS Code Azure credential reuse;
- hosted managed identity credential support;
- private tenant/subscription scope;
- JSON operation discovery and output;
- one parameterized, idempotent `resource-group ensure` operation.

Target:

- generic generated-operation package validation;
- generic Bicep/ARM validate, what-if, approved apply, status, and verification;
- constrained CLI and ARM REST adapters;
- disposable-environment teardown planning/execution;
- approval-digest enforcement and sanitized run records;
- optional local MCP transport over the same engine.

The handwritten Resource Group handler should be retired after a subscription-scope generated Bicep deployment proves the generic lane provides equivalent scope validation, dry run, apply, independent verification, idempotency, and privacy.

See [the coding-engine architecture](../../docs/coding-engine.md).