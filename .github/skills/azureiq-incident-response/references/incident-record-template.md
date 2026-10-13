# Incident Record Template

Store completed, sanitized records under `incidents/YYYY/YYYY-MM-DD-short-name.md`. Do not store credentials, tokens, personal data, customer payloads, or unrestricted raw telemetry.

The record follows the same three-part diagnostic format used in the live brief: problem definition, diagnosis, then root cause analysis.

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
- Affected support-domain version:
- Data classification:

## 1. Problem Definition

- User-visible impact, duration, scope, and measurable service-level effect:
- Expected behavior:
- Observed behavior and reproducible symptom:
- Investigation window (absolute UTC):
- Affected paths:
- Explicitly unaffected paths:
- Sanitized request, operation, trace, deployment, and correlation identifiers:

## Timeline

| UTC time | Fact, decision, or action | Source/owner |
| --- | --- | --- |

## 2. Diagnosis

### Evidence

| ID | UTC window | Source/query | Sanitized result | Reliability/limitations |
| --- | --- | --- | --- | --- |

### Detector Attempts

| Detector/tool | Resource | Outcome | Usable evidence |
| --- | --- | --- | --- |

### Localization

Name the responsible hop, component, or processing stage and the evidence that isolates it.

### Hypotheses

| Hypothesis | Supporting evidence | Contradicting evidence | Disproving check | Confidence |
| --- | --- | --- | --- | --- |

### Telemetry And Permission Gaps

List evidence that was unavailable, delayed, sampled, expired, inaccessible, or not correlated.

## 3. Root Cause Analysis

- Causal chain from trigger to user-visible symptom:
- Root-cause confidence: confirmed | probable | undetermined
- Justification for that confidence label:
- Trigger:
- Root cause:
- Contributing factors:
- Intended behavior or fault, and why:
- Why detection or prevention did not catch it:

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

## Follow-Up

| Item | Owner | Due | Tracking link | Completion evidence |
| --- | --- | --- | --- | --- |

## Durable Learning

List verified support-domain, alert, query, test, baseline, or runbook changes. Do not promote an unverified hypothesis into future automation.

## Redaction

State what was removed or generalized and where authorized raw evidence is retained.
```