# Support Domain Contract

A support domain gives AzureIQ service-specific operating knowledge without expanding the global instructions or a general agent indefinitely.

Reusable files within a support domain must also be registered in `artifacts/catalog.json` before they drive a mutation or are selected as trusted knowledge. The support-domain manifest owns domain grouping; the artifact catalog owns exact version, digest, compatibility, decision points, validation freshness, and supersession.

## Admission Gate

Do not create a support domain merely because AzureIQ might manage the service later. First run a representative inventory, diagnosis, change-planning, or verification scenario with Azure MCP and the installed Azure skill set alone.

Admit an artifact only when the pack records:

- the baseline provider, tool/skill versions, permissions, Azure scope, telemetry, inputs, and result;
- a reproducible observed limitation, not a speculative possibility;
- the smallest AzureIQ artifact intended to close that limitation;
- acceptance criteria and a fair comparison using equivalent starting conditions;
- measured results for scope accuracy, schema/factual correctness, evidence completeness, unsupported claims, sensitive-data handling, safety, repeatability, operator prompts/tool calls, and verification quality;
- a `keep`, `revise`, or `retire` decision with evidence and owner.

An artifact may be drafted before the baseline run only when clearly labeled `unproven`. It cannot advance to `observed` until its query or procedure is tested against a scoped live resource, and it cannot claim AzureIQ value until the baseline comparison succeeds.

## Layout

```text
support-domains/<service-name>/
|-- manifest.yaml
|-- README.md
|-- baselines/
|-- queries/
|-- alerts/
|-- dashboards/
|-- runbooks/
|-- tests/
`-- references/
```

Only create directories the service needs. Keep scripts and queries executable or machine-readable where practical.

## Manifest Fields

`manifest.yaml` should contain:

- schema version, support-domain version, status, owners, and review date;
- value proof status, baseline provider/status, gap IDs, artifact references, acceptance criteria, result references, and retention decision;
- Azure resource type strings and supported deployment/API versions;
- environments, criticality, data classification, and compliance scope;
- control-plane and data-plane dependencies;
- minimum read, change, and verification roles and scopes;
- required resource providers and feature registrations;
- identity, network, DNS, encryption, backup, restore, scaling, and fault-tolerance expectations;
- required diagnostic categories discovered from the target API, destinations, retention, sampling, and correlation fields;
- service-level indicators, objectives, alerts, suppression, escalation, and action groups;
- runbook IDs with risk tier, automation eligibility, rollback support, and verification IDs;
- authoritative documentation links and the date they were last reviewed;
- tested limitations and unsupported scenarios.

Do not place secrets, resource access keys, connection strings, tokens, private endpoints containing credentials, customer payloads, or unrestricted log output in the manifest.

## Baselines

Separate baseline types so drift has a clear meaning:

- **required:** absence is a defect;
- **recommended:** deviation requires a reason;
- **environment-specific:** dev/test/prod values differ intentionally;
- **observed:** a timestamped discovery result, never desired state by itself;
- **exception:** approved deviation with owner, justification, compensating control, and expiry.

## Runbook Contract

Every executable runbook defines:

- ID, purpose, owner, version, and supported resource/API versions;
- symptom or trigger and required evidence;
- exact target selector and exclusion rules;
- preconditions, lock/concurrency behavior, rate limits, and idempotency;
- required identity and least-privilege permissions;
- exact operations and sanitized parameters;
- risk tier and whether automatic execution is prohibited, supervised, or policy-eligible;
- timeout, abort, partial-failure, rollback, and compensating behavior;
- independent success checks and observation window;
- tests, known failure modes, and last game-day date.

Free-form model output must not be passed directly to a runbook executor. Validate an action manifest against a schema and allowlisted operation before execution.

## Maturity

| Status | Meaning |
| --- | --- |
| `draft` | Knowledge exists but has not been validated against a real scoped resource |
| `observed` | Discovery and telemetry queries were verified read-only |
| `supervised` | Changes/runbooks succeeded with explicit approval and independent verification |
| `policy-eligible` | A bounded runbook has tests, idempotency, rollback, rate limits, and repeated supervised success |
| `retired` | Pack is unsupported and must not drive new actions |

No runbook starts as `policy-eligible`.

Maturity and value are separate. A runbook can be technically `observed` yet add no value over Azure MCP; in that case retire the redundant artifact.