# Operational tooling and latency review

Reviewed: 2026-10-16. Scope: the service-endpoint rollout and the surrounding
orchestration workflow. This is a tooling evaluation, not authorization for
additional Azure changes.

## 1. Problem definition

A request to enable three service endpoints became a development task before
it became an Azure operation. The intended model is the opposite: GitHub Copilot
orchestrates existing tools with explicit parameters, obtains the required
approval, executes the bounded operation and verifies the outcome.

The endpoint update succeeded. The lengthy preparation does not demonstrate
that Azure needs that time to configure endpoints, nor that custom tooling is
inherently necessary for ordinary VNet/subnet management.

## 2. Diagnosis: measured evidence

### Endpoint operation

| Measurement | Observed duration |
| --- | ---: |
| Request to first valid live plan | 37 min 51 sec |
| Request to configured SDK readback | 57 min 03 sec |
| Approval recording/preflight command | 9.12 sec |
| Apply command, including its client checks/readback | 34.03 sec |
| Separate read-only configuration verification | 8.32 sec |
| Combined approve/apply/readback commands | 51.47 sec |
| Azure Activity Log write Started to Succeeded | 6.56 sec |

Azure Activity Log recorded the subnet write starting at
`2026-10-16T20:52:24.51218Z` and succeeding at `20:52:31.0673558Z`.
The apply-command duration includes more than server execution: authentication,
scope/tool checks, client startup, polling and readback. It is not a pure Azure
service-latency measurement.

### Conversation/tool trace

The session event trace was streamed over the bounded UTC interval
`2026-10-16T19:55:46Z` through `20:55:47Z`; prompts, hidden reasoning, credentials
and unrestricted tool results were not exported into this report.

| Trace measurement | Observed |
| --- | ---: |
| Logged tool starts/completions in the interval | 89 / 89 |
| Completed assistant-turn spans | 38 |
| Wall-clock union with a logged tool active | 10 min 27 sec |
| Human approval tool wait, included above | 4 min 32 sec |
| Planner-agent call | 1 min 47 sec |
| ARM MCP discovery/authentication failure | 8.38 sec |
| File-editing tool calls | 9 |
| Build/test calls | 3 |
| Combined build-and-plan attempts | 3 |

Parallel and nested durations overlap; category sums must not be added as if
they were sequential. Assistant spans also overlap and include waits, so their
sum is not a model-compute measurement.

Approximately 49 min 34 sec of this one-hour trace window was outside logged
tool-execution intervals. That includes generation/orchestration gaps and
potential uninstrumented work. The trace does not justify labeling all of it
"thinking", network latency or Azure execution. It does establish that the
delay was not dominated by the successful Azure subnet write.

### Concrete friction observed

1. **The existing mutation coverage was narrower than the requested work.**
   The fixed change lane initially supported observability resources, not
   subnet updates. The installed maintained Azure CLI already exposed the
   required subnet-update command, but no corresponding admitted execution
   path had been prepared.
2. **Tool development was placed on the operation's critical path.**
   A CLI adapter, recipe, tests, catalog/routing metadata and documentation
   were added while the user was waiting for the service update.
3. **MCP availability was confused with capability readiness.**
   ARM MCP client creation failed in its authentication chain. That proves
   the path was unavailable in this session, not that Azure MCP has no suitable
   operation. SDK/CLI authentication subsequently worked.
4. **Snapshot validation reused write-body assumptions.**
   Existing read-only subnet IP-configuration references pointed to resources
   in another subscription. They were initially rejected as if they were
   requested writes. The response also contained both scale-set/NIC and
   load-balancer frontend references, including mixed-case ARM paths.
5. **An ad hoc preflight reinterpreted an API schema.**
   A raw dependency-status check failed to classify required observations.
   Reusing the existing VNet checker's validated classification resolved this
   without an Azure change.
6. **The execution path repeats readiness work.**
   Separate command launches and repeated SDK/CLI identity/version checks add
   overhead. Some checks are essential immediately before a write; others can
   be scoped to one short-lived operation context without being omitted.
7. **Specialist names exceed their actual tool access.**
   The verifier could read files and assess evidence but could not itself
   query Azure. Its conclusion correctly distinguished parent-executed
   independent-tool evidence from its own observations. That limitation must
   not be hidden behind the word "independent".
8. **Broad schemas and long manifests create unnecessary handling.**
   Repeated discovery, lengthy model-generated manifests and large outputs
   increase model turns and manual inspection without necessarily improving
   the bounded change.

## 3. Root cause analysis

**Confirmed process failure:** operational orchestration expanded into tool
development. The evidence is the sequence of source edits/builds/failed
validation attempts before the first valid plan, versus the later measured
51-second execution sequence and 6.56-second Azure write interval.

**Contributors:** an unavailable MCP authentication path, missing pre-admitted
network mutation coverage, overly broad metadata validation, repeated
readiness checks, and a high number of model/tool transitions.

**Undetermined:** the underlying ARM MCP credential-chain failure. The evidence
does not isolate its authority/broker/configuration/timeout cause. The current
tool surface did not expose the requested VS Code diagnostic-command runner;
no credential or tenant changes were attempted to manufacture a fix.

Safeguards and approval are necessary. They should be implemented once in
parameterized tools and reused, not reconstructed in long reasoning/code loops
for every ordinary operation.

## Changes already made

- Persisted MCP-first operational instructions in the workspace and
  Orchestrator.
- Made the network and observability registry entries prefer live
  MCP/extension discovery, with the existing custom executors as fallbacks.
- Stated explicitly that authentication, scope, parameter and transient
  failures are not proof of an absent feature.
- Separated routine operations from tool development. New adapters,
  compilation and executor changes require a separate development request.
  Parameterizing existing templates/recipes remains normal operational work.
- Preserved read-only diagnostics, exact scope, explicit write approvals,
  rollback controls and independent verification requirements.
- Added endpoint-specific safety coverage; the final local suite has 65
  passing tests. That does not constitute full live rollback/traffic acceptance.

Existing custom tools were not deleted or promoted. The read-only VNet report
remains useful when requested, and the new initialization fallback remains
candidate. It is **not** a general subnet editor: it refuses nonempty existing
endpoint sets rather than overwriting custom endpoint/location settings.

## Prioritized fixes

| Priority | Fix | Acceptance criteria |
| --- | --- | --- |
| P0 | Repair and validate the existing Azure MCP authentication path | Correct configured tenant/subscription/principal is demonstrated by a harmless read through the actual intended server/subcommand. No sign-out, scope switch or credential change without authorization. |
| P0 | Establish a small, verified capability matrix | For VNet/subnet get/list and endpoint update/verify, record the actual callable MCP subcommand and parameter schema, or explicitly identify an existing supported fallback. Do not infer coverage from tool names or an authentication failure. |
| P0 | Keep operations out of development mode | A routine supported change performs zero source edits, builds or dependency installations. A real gap is surfaced early with a separate development proposal. |
| P0 | Make read-only/write separation deterministic | Read-only tool contracts and least-privilege access prevent writes; mutation tools require exact approval/context rather than relying only on agent prose. Preserve existing safety controls while improving speed. |
| P1 | Use reusable parameterized tool contracts | Resolve target, validate input, produce a concise diff, apply an approved change and return structured verification/timings. Bind these contracts to working MCP tools first; do not build duplicate resource-specific SDK handlers. |
| P1 | Improve authentication/preflight lifetime | Reuse one verified short-lived context within an operation; recheck scope, principal and state at the actual write boundary. Avoid repeatedly launching account/version/token checks for every harmless read. |
| P1 | Separate stable change intent from freshness leases | Propose a reviewed protocol where user approval binds immutable scope/parameters/identity/risk, and current-state freshness is checked immediately before execution. Do not change current expiry behavior without separate review; any material drift must still require reapproval. |
| P1 | Give verification the actual read-only Azure surface it needs | The verifier can query approved resources with read-only tools/identity, or clearly reports that it only assessed supplied evidence. Never grant broad terminal/write access just to make a verifier work. |
| P1 | Expand provider-schema fixtures | Cover NIC, scale-set and LB references, mixed-case ARM IDs, disabled defaults, missing versus empty collections and asynchronous provisioning. Keep write-target validation strict while treating inert read-only references as data. |
| P1 | Reuse existing diagnostic classifiers | Consume the VNet tool's structured result instead of generating one-off status parsers during a rollout. |
| P2 | Add stage-level latency telemetry | Persist discovery, auth, reads, plan, approval wait, Azure operation and verification durations separately, with correlation IDs and partial-result status. Avoid private identifiers/secrets in sanitized records. |
| P2 | Reduce model hops and output volume | Render routine approvals from the structured plan; reserve expansive specialist analysis for actual ambiguity/high-risk design. Keep required independent checks, but pass concise typed evidence. |
| P2 | Make progress state explicit | Show waiting-for-user, authentication, submitting, provisioning, configured, and observation-pending separately. A bounded read-only follow-up should not look like a stuck write. |

## Target operating flow

1. Interpret user intent and resolve the exact resource.
2. Discover/use the suitable existing MCP tool with explicit parameters.
3. Validate scope, current state, preservation and supported settings.
4. Return one concise proposal and obtain required approval.
5. Execute once; expose the Azure operation ID and measured stage timing.
6. Verify configuration independently.
7. Track any longer health observation separately, without blocking routine
   orchestration or inventing traffic.

These are capability contracts, not claims that particular new MCP tool names
already exist. If an existing Microsoft tool implements the operation, use it.
Only a demonstrated, repeatable gap justifies a separately reviewed fallback.

## Performance acceptance targets

For a warm, supported, single-resource operation:

- First useful scoped read/preview within 30 seconds.
- Normal interactive orchestration within two minutes, excluding human
  approval wait, Azure long-running operations and an explicitly declared
  observation period.
- Zero runtime tool development or installation.
- One approval for an unchanged bounded change; reapproval for material drift.
- One mutation attempt, no hidden retry, and an explicit verification outcome.

These are proposed targets, not measured p95 guarantees. Benchmark them with
repeatable success, denied-permission, expired-approval and drift cases before
calling the workflow production-ready.

## Scope boundaries

The current service update enabled only the approved three endpoints. This
review does not authorize further networking, identity, logging, firewall,
MCP authentication or approval-policy changes. Those require their own
bounded requests and approvals. No service outage or end-to-end recovery is
claimed from configuration success alone.

## Implementation references

- [MCP-first workspace instructions](../.github/copilot-instructions.md)
- [Orchestrator capability selection](../.github/agents/azureiq-orchestrator.agent.md)
- [Capability registry and fallback routing](../capabilities/registry.json)
- [Execution-tool selection](execution-tools.md)
- [Existing subnet endpoint fallback](subnet-service-endpoint-changes.md)
- [Controlled CLI implementation](../src/AzureIQ.Execution/AzureCliRecipes.cs)
- [Change/approval controller](../src/AzureIQ.Execution/ArmChanges.cs)
- [CLI safety tests](../src/AzureIQ.Execution.Tests/AzureCliRecipeTests.cs)
