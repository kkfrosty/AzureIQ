# REST-backed MCP completion

The original API repair's next live attempt demonstrated that `sourceApiId`
cloned the backing HTTP API and did not retain an actual MCP API type. Azure
then rejected every tool with `API type must be MCP`. Endpoint dictionary
syntax alone did not fix that distinct problem.

The separate `harbor.support-mcp-completion@0.1.0` candidate uses
`mcp-completion.bicep`. It follows Microsoft's
[REST-backed MCP creation workflow](https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api):
declare `properties.type: mcp`, do not set REST cloning or passthrough
properties, then bind the selected tools using absolute backing operation IDs.
Existing caller authorization policy and the original catalog module remain.
Earlier applied source files/manifests are preserved.

Run `Test-McpCompletion.ps1` to guard the actual API type, absence of cloning
and passthrough settings, absolute operation IDs, and bounded module scope.
The November 9 deployment of this entrypoint succeeded; actual type `mcp`,
all seven tool bindings, API Center Standard and exact source-reader assignment
were read back. Public configuration returned200 and unauthenticated customer
and executable MCP requests returned401. Catalog source convergence, native
portal/MCP, sign-in, runtime lifecycle and telemetry remain acceptance gates.

There is no deployment-submission cutoff in this completion. A bounded
write-approval lifetime is separate from application runtime lifecycle.
No inference-window binding, usage data, cap, image, identity, network or
foundation configuration is changed. No PIM or new tenant role is included.
