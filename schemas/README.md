# AzureIQ Schemas

Schemas define data shape. They are necessary for deterministic tooling but are not authorization, policy evaluation, or proof that a value is truthful.

## Action Manifest

[action-manifest.schema.json](action-manifest.schema.json) describes a bounded Azure write proposal. An executor must additionally:

1. reject unknown or non-allowlisted tools and operations;
2. scan parameters and evidence for secrets and untrusted executable content;
3. resolve and compare every target against the approved scope;
4. verify tenant, subscription, principal, RBAC/PIM state, locks, and current-state preconditions;
5. canonicalize the manifest and verify an approval-bound digest and expiry;
6. enforce risk policy, rate limits, concurrency, idempotency, and maintenance windows;
7. prevent `R4` and non-policy-eligible automatic execution;
8. preserve immutable, redacted audit evidence;
9. run rollback/abort behavior on partial failure;
10. invoke independent verification rather than accepting executor output.

The schema intentionally disallows secrets in an operation manifest, but the `containsSecrets: false` field is only a declaration. A separate scanner and allowlist must enforce it.

Each operation explicitly records either the catalog artifact ID/version/digest used or `null` for a direct platform operation. Approval must be invalidated when an artifact digest or material decision changes.

## Artifact Catalog

[artifact-catalog.schema.json](artifact-catalog.schema.json) governs reusable assets, compatibility, decision points, validation freshness, and version/supersession policy. Catalog presence does not make a candidate safe; status, compatibility, live state, validation, and approval still apply.

## Execution Record

[execution-record.schema.json](execution-record.schema.json) governs sanitized runtime history. Records contain route and artifact versions, authorization digest, parameter digest, outcome, verification, and learning references. They intentionally prohibit secrets, customer identifiers, and raw payloads.