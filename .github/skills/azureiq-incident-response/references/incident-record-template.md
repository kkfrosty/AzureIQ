# Incident Record Template

Store completed, sanitized records under `incidents/YYYY/YYYY-MM-DD-short-name.md`. Do not store credentials, tokens, personal data, customer payloads, or unrestricted raw telemetry.

```markdown
# INC-YYYYMMDD-NNN: Short title

## Record

- Status: active | monitoring | resolved | closed
- Severity:
- Started (UTC):
- Detected (UTC):
- Mitigated (UTC):
- Resolved (UTC):
- Incident commander:
- Technical owner:
- Affected environments/regions:
- Affected service-pack version:
- Data classification:

## Impact

Describe user-visible impact, duration, scope, and measurable service-level effect.

## Expected And Observed Behavior

State the expected behavior and the reproducible symptom. Include sanitized request, operation, trace, deployment, and correlation identifiers.

## Timeline

| UTC time | Fact, decision, or action | Source/owner |
| --- | --- | --- |

## Evidence

| ID | UTC window | Source/query | Sanitized result | Reliability/limitations |
| --- | --- | --- | --- | --- |

## Hypotheses

| Hypothesis | Supporting evidence | Contradicting evidence | Disproving check | Confidence |
| --- | --- | --- | --- | --- |

## Changes And Approvals

| Change ID | Target/action | Risk | Approver/time | Result | Rollback state |
| --- | --- | --- | --- | --- | --- |

## Verification

- Verdict: VERIFIED | FAILED | INCONCLUSIVE | SCOPE_MISMATCH
- Observation window:
- User-visible check:
- Metrics/logs/traces:
- Dependency/regression checks:
- Residual risk:

## Cause

- Trigger:
- Root cause:
- Contributing factors:
- Why detection or prevention did not catch it:

## Telemetry And Permission Gaps

List evidence that was unavailable, delayed, sampled, expired, inaccessible, or not correlated.

## Follow-Up

| Item | Owner | Due | Tracking link | Completion evidence |
| --- | --- | --- | --- | --- |

## Durable Learning

List verified service-pack, alert, query, test, baseline, or runbook changes. Do not promote an unverified hypothesis into future automation.

## Redaction

State what was removed or generalized and where authorized raw evidence is retained.
```