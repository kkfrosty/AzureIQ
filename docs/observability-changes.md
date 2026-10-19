# Reliable observability changes

Troubleshooting is read-only. An explicit request to implement a change enters
planning, approval, execution, and independent verification. It is not another
diagnostic request, and it is not unrestricted approval for arbitrary writes.

## Implemented boundary

The shared [execution host](../src/AzureIQ.Execution/README.md) now has a bounded
ARM REST lane for existing-service observability. It accepts only cataloged,
digest-checked packages under [observability](../artifacts/observability):

| Package ID | Change |
| --- | --- |
| `observability.apim-gateway-logs` | APIM GatewayLogs and AllMetrics export to an existing workspace |
| `observability.activity-log-export` | Subscription Activity Log export to an existing workspace |
| `observability.apim-capacity-alert` | Classic Developer/Premium capacity alert |
| `observability.apim-failure-alert` | HTTP 5xx percentage alert with minimum traffic |
| `observability.apim-latency-alert` | p95 total-time alert with minimum traffic |
| `observability.apim-telemetry-health-alert` | Metrics show requests but gateway logs are absent |

No default SLO, threshold, notification recipient, workspace, or action group is
guessed. Package parameter definitions are authoritative. The operator must
confirm the target SKU, log categories, workspace schema, metric availability,
units, costs, ownership, and notification destination before requesting approval.
Existing workspace/action-group dependencies are read before planning and again
before changes; missing or disabled dependencies stop execution.

The lane does not create services, workspaces, action groups, identities, RBAC,
network rules, credentials, or test traffic. It is not the full generic package
engine. It does not run generated code or allow arbitrary HTTP origins,
subscriptions, ARM resource types, or API versions.

## Operator workflow

Use AzureIQ Change Planner for the human action manifest, impact/cost/RBAC review,
current evidence, and success criteria. Use installed tools or IaC first when
they provide a suitable maintained operation. This fixed lane is the fallback
for the verified observability execution gap.

From the workspace root, prefix each command with:

```powershell
dotnet run --project .\src\AzureIQ.Execution --configuration Release --no-restore --
```

1. Put exact non-secret bindings in an ignored private JSON file. Never put real
   scope or bindings in a tracked example. Tenant/subscription are supplied only
   by `config/local.azureiq.json`, not by ordinary arguments.
2. Run `change validate --artifact <id> --version 0.1.0 --parameters <private-file>`.
   This performs offline catalog, input, resource-path, API-version, and
   cross-subscription checks; **it is not Azure provider validation**.
3. Run `change plan` with those same arguments. Existing VS Code authentication
   is used without a sign-in wizard or CLI context switch. The tool checks the
   token tenant/principal, dependencies, and existing target. It stores a
   30-minute private plan and before-state under `.azureiq/plans/CHG-.../`.
4. Review the private plan's exact target, API version, desired body, before-state,
   risk, source version/digest, dependency assertions, rollback, and verification
   guidance. Bind the returned digest to the human action manifest and present
   the exact diff, cost, minimum permissions, scope, and abort criteria to the user.
5. Obtain explicit user approval of that exact manifest/digest. Only then run
   `change approve --plan <plan-path> --digest <approved-digest>`.
   **This command records consent obtained outside the CLI; it cannot establish
   human consent, approve its own proposal, or change workspace write policy.**
6. Run `change apply-approved --plan <plan-path>`. Approval, expiry, current
   principal/policy, source digest, dependencies, and target before-state are
   rechecked. One workspace-wide lock permits only one change at a time.
   The attempt is recorded before the request; a failed/ambiguous write is never
   automatically retried or replayed.
7. Run `change verify --plan <plan-path>` for configuration readback. Exit 3
   means mismatch. An accepted or asynchronous write without matching readback
   is explicitly inconclusive; inspect and verify rather than rerunning apply.
8. Hand the approved manifest and results to AzureIQ Verifier. It independently
   checks new gateway/activity/metric ingestion, alert semantics, and authorized
   action delivery. Configuration matching is **not** service recovery or
   end-to-end telemetry verification.

Plans contain private resource identifiers and configuration, not secrets.
They inherit filesystem permissions and are not encrypted or signed. Protect
them from other local actors and backups; never commit or force-add them.
The local approval ledger is not a tamper-resistant enterprise approval service.
Sanitized execution records stay separately under `.azureiq/runs/`.

## Authorization and commissioning

Planning and verification can run in `bootstrap-read-only`. Apply and approval
recording require effective private `mode: supervised-management`,
`safety.azureWrites: supervised`, exact scope, explicit approval, and no automatic
risk tiers. The current private profile is **not changed by these commands**.

If writes are denied, explain the specific commissioning blocker and obtain a
separate explicit decision to update the local profile and verify write RBAC.
Do not mistake the diagnostician's read-only role for a permanent ban on approved
changes, and do not mistake change intent for permission to override an explicit
workspace deny. No generic "Contributor" grant or provider registration occurs.

Minimum permissions depend on the operation: relevant
`Microsoft.Insights/diagnosticSettings`, `metricAlerts`, or `scheduledQueryRules`
read/write rights at the exact target, plus dependency reads and the required
workspace query rights for verification. Rollback of a newly created setting
also needs delete permission at that setting. Check effective permissions/PIM
instead of automatically granting roles.

## Rollback and concurrency limits

`change rollback-plan --plan <forward-plan>` compares current state with the
forward desired state and prepares a new plan restoring the captured before-state.
If the forward change created the resource, rollback proposes deletion of that
one resource and is R3. Review and approve the rollback digest separately.
Unrelated state drift blocks rollback instead of overwriting another operator.

ETags are sent with `If-Match` when available; creation uses `If-None-Match: *`.
Providers do not uniformly expose or honor conditional writes. The client also
rereads before mutation, but **this does not guarantee atomic protection against
external writers when the provider lacks concurrency support**. Stop and
coordinate ownership when simultaneous external changes are possible. Local
locking protects only this workspace's change lane.

Rollback snapshots retain writable configuration fields and omit known
read-only state fields. Provider-specific restoration behavior still requires
disposable live validation. A failed write may have changed Azure: inspect its
state, preserve the attempt record, and do not assume failure means no change.

## Alert verification and release maturity

ARM can return additional disabled log/metric category defaults in a diagnostic
setting GET. Readback accepts those inactive defaults, but not additional
enabled exports or untyped enablement values. Explicitly requested entries are
still compared, and full before-state snapshots are preserved for drift checks
and rollback. Regression tests cover both the provider response shape and
rollback preparation.

All six packages remain **candidate**. The gateway-log package has one approved
live create and configuration-readback observation; new ingestion was not
established in its initial observation window. The other packages retain
offline/static evidence only. No full create/update/rollback acceptance cycle,
notification test, or fault experiment is claimed. The human manifest must
record these limitations. Before promoting a package:

- Validate exact categories/metric/schema on the target SKU.
- Prove create and in-place update, repeat readback, expiry/drift rejection,
  authorized notification delivery, restore/delete rollback, and audit privacy.
- Confirm failure/latency queries against known counts, percentages and p95 units,
  including threshold boundaries, idle periods, and minimum-volume behavior.
- The telemetry-health query compares a completed 30-to-10-minute-old interval.
  No traffic produces no incident; loss of both streams is a blind spot. It
  checks gateway-log export, **not** Application Insights request delivery.
- Separately approve a bounded benign request from an authorized VNet client
  for present Application Insights delivery verification. Never generate traffic
  simply to make a detector green.

Offline safety tests:

```powershell
dotnet test .\src\AzureIQ.Execution.Tests\AzureIQ.Execution.Tests.csproj --configuration Release
```
