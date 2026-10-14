# Fault-injection and recovery plan

**Status:** proposed; no live faults executed by this handoff.

The earlier known-good study proved delivery, not negative-path diagnosis.
The objective now is to prove that a candidate diagnostic identifies a specific
introduced blocker, proposes the right correction and verifies recovery.

## Authorization gates

The current tracked AzureIQ policy denies writes and no private commissioning
profile was present during review. Do not execute these experiments through
AzureIQ until the operator has an authorized private lab scope, permitted
supervised mode and approved versioned change/rollback manifest.

For every experiment:

1. Re-query account, tenant, subscription, region, exact resources and principal.
   Saved lab state is a hint, not standing authorization.
2. Confirm a dedicated non-production service, synthetic API and telemetry
   destination. Exclude customer/shared resources.
3. Record privately the exact prior configuration, change digest and concurrency
   token where supported. Read credentials/secrets neither for baseline nor undo.
4. Bind approval to one change, observation budget, abort conditions, restoration,
   verification and any VM start/traffic cost.
5. Run only one fault at a time. Keep the controller and management/rollback path
   outside the affected egress path.
6. Before the write, verify a rollback method that survives a stopped editor or
   failed client. If no independent timed/operator rollback is available, do not
   proceed with a network-breaking test.
7. Detect concurrent drift. Never restore an entire stale NSG or service document
   over another operator's changes.
8. Verify both settings restoration and new accepted telemetry before deallocating
   the test client and closing the experiment.

Diagnostic readers, traffic clients and change operators need separate least
privilege. VM Run Command is remote code execution, not a read-only ARM GET.
Traffic generation and even a GET to an existing customer API can have side
effects; use an explicitly approved mock endpoint.

## First experiment: bounded APIM telemetry egress denial

Recommend this before deploying any firewall/router:

- Target only the dedicated APIM subnet NSG.
- Add one uniquely named outbound TCP deny for the applicable Azure Monitor
  ingestion flow, above the current matching allow.
- Bind the source to the actual APIM subnet and verify destination applicability
  against the actual endpoint/current service-tag evidence.
- Choose an unused legal priority: custom NSG priorities start at **100**.
  Do not hardcode a number without checking the existing winning rule.
- Preserve private client-to-gateway HTTPS, runner agent/egress, APIM management
  return traffic, identity dependencies and rollback access.
- Document collateral impact: the `AzureMonitor` service tag can cover metrics
  and other monitoring traffic, not just Application Insights.
- If a broad tag cannot safely isolate the intended experiment, use a separately
  reviewed exact-address trial with DNS/TTL evidence, or defer the test. Do not
  imply a static IP snapshot is a permanent FQDN allowlist.

An NSG cannot filter by URL, SNI or TLS cipher. A drop can demonstrate an
egress/missing-telemetry failure, but does **not** reproduce an exact proxy
connection-reset or TLS-interception failure from a different environment.

## Positive / fault / recovered sequence

### A: calibrate known-good behavior

- Start the approved private client only for the test window.
- Confirm normal TLS validation, correct private gateway resolution and the
  deterministic mock response.
- Use a new synthetic run UUID, 20 requests and known W3C trace IDs.
- Use an approved dedicated API with effective 100% sampling and no duplicate
  destination multiplexing.
- Observe all 20 matching successful rows in the intended component/workspace,
  with distinct request IDs/operations. Save observation timestamps privately.
- Calibrate the ingestion wait budget. A suggested initial ten-minute budget is
  an experiment setting, **not an Azure delivery SLA**. If the baseline cannot
  meet the selected budget, stop or recalibrate; do not run a negative trial
  against an unproven positive path.

### B: apply the approved single fault

- Recheck scope, drift and the exact change manifest.
- Read back the injected rule and its precedence/applicability.
- Run a new marker through the still-working mock API.
- Run the candidate diagnostic without giving it the fault answer. Separately
  retain the operator's ground-truth change.
- Observe correlated counts over the selected budget and collect independent
  network evidence when available.
- Require the diagnostic to identify the applicable deny, cite evidence, retain
  any unresolved effective-route/admin-rule ambiguity, and propose removal or
  correction of that specific rule.
- Zero rows alone is insufficient to confirm a sender/network cause.

### A2: restore and prove recovery

- Remove only the test-owned rule, or restore only the approved changed fields,
  after verifying there is no unexpected concurrent edit.
- Confirm original settings/allowed flow and private management/client access.
- Generate a third unique run marker and observe accepted request rows.
- Watch for delayed delivery of B's buffered events. Such delivery does not prove
  there was timely ingestion while the rule was active.
- Report cause confidence from the complete controlled evidence. A clean
  restoration readback without delivery evidence is not resolution.
- Deallocate the client after verification. Disk/network charges can remain;
  deletion needs a separate approved teardown.

## Experiment matrix

All entries below are **planned**, including those supported by offline fixtures.

| ID | Controlled change | Expected diagnostic distinction | Restoration and evidence |
| --- | --- | --- | --- |
| N1 | APIM-source monitoring/ingestion TCP 443 deny | Applicable first-match deny; missing delivery qualified by observed flow and A/B/A2 | Delete only owned rule; verify new rows and management/client health |
| N2 | Wrong DNS answer for the exact approved ingestion hostname | Ingestion-path DNS evidence, not gateway-client DNS or workstation proof | Restore/delete only owned record/zone/link; respect caches; new rows |
| N3 | Break only gateway DNS used by the test client | Traffic could not reach APIM; do not call this a logging transport failure | Restore exact gateway record; generate requests before testing ingestion |
| N4 | Default UDR to a separately approved test appliance | Forced tunnel alone is not a fault; require effective path/appliance evidence | Restore subnet association/route before stopping appliance; verify return path |
| C1 | Dedicated API diagnostic sampling set to zero for successful mock requests | Configuration explains intentional absence; not an NSG or SDK fault | Restore exact diagnostic; new successful request rows |
| C2 | Effective API override points somewhere other than the expected target | Logs may be delivered elsewhere; do not say all telemetry is lost | Offline first; live only with separately approved isolated destination |
| A1 | Remove a known publication role assignment in a dedicated auth trial | Distinguish publisher metadata from diagnostic-reader denial; allow for RBAC/token cache propagation | Restore same assignment/principal/scope through approved rollback; never disable/recreate identity |
| P1 | Public ingestion disabled without an approved private path | Network-access configuration blocker for this known public-path lab | Restore ingestion setting only; preserve query access and verify new rows |
| E1 | Collector cannot query workspace, or queries the wrong table/scope | Access/query/schema evidence gap, not APIM publishing failure | Correct only reader/query context; no APIM mutation required |
| T1 | Explicitly designed proxy/reset/TLS-interception scenario | Exact transport semantics require separate source/path evidence | Separate cost, certificates, routing and trust review; not part of N1 |

Avoid broad DNS apex changes, disabling managed identity, removing NSGs,
changing customer certificates, enabling old TLS, or creating a global sinkhole.
`AzurePlatformDNS` is a deny-only override of platform DNS behavior; do not
attempt an `Allow` rule for that tag. Blocking platform DNS would also affect
unrelated service dependencies and is not the first controlled experiment.

## Test pass criteria

For each claimed diagnosis, the report must contain:

- The actual captured configuration/evidence version and observation interval.
- The correct fault domain and the decisive evidence or explicit ambiguity.
- The narrow correction and independent postcondition.
- Successful restoration and positive A2 evidence.
- No private identifiers/secrets in shareable output.
- No false root-cause claim for stale/absent logs, sampling, reader permission,
  unknown selectors, default UDR alone or successful periodic checks.

Record detection rate and false positives across the matrix, not just one
successful lab case. A healthy static snapshot is allowed to remain inconclusive.

## Fair comparison and release gate

Run identical starting conditions with Azure MCP/installed skills alone and with
the candidate plus GHC. Keep scope, permissions, telemetry, test marker, window
and evidence availability equivalent. Measure time/tool calls to a correct
finding, unsupported root-cause claims, operator prompts, missed blockers and
recovery verification.

Do not claim reduced support-case volume without customer-use evidence. Promote
only tested rule/model combinations; explicitly list unexecuted experiments.
