# Harbor APIM validation repair

Candidate `harbor.support-api-repair@0.1.0` repairs the two live APIM child
validation failures without rebuilding the pinned application image.

- Attach the unchanged voice policy to the existing WebSocket `onHandshake`
  operation, not API scope. Do not recreate the immutable handshake operation.
- Exclude only the runtime 404 catch-all `/v1/{unmatched}` from the imported
  OpenAPI. Preserve all remaining operations and schemas. Future application
  exports also exclude that endpoint from API description.
- Finish the original support policy/assets/tool bindings, then use the
  unchanged API Center module after the repaired APIs succeed.
- MCP endpoint definitions use the provider's name-keyed object shape, not
  an array; the endpoint URI and selected tool set are unchanged.

No foundation, network, application, image, model, cap, usage-window or identity
configuration is changed. Existing Entra authority remains necessary for SPA
redirect configuration and the backend/gateway app-role assignments. No PIM,
new tenant role, secret, usage reset, deletion or lab extension is authorized.

Compile and run `Test-Package.ps1`, then fresh Provider validation/what-if with
actual private bindings. A passing plan is not API import success: verify
actual child provisioning, imported operations, handshake policy and catalog
source sync. Native portal/MCP enablement and real authenticated behavior
remain independent acceptance gates. Capture policy/import preimages before
apply; reversal requires its own approved reviewed change.
