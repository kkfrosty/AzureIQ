# AzureIQ Case-Study Roadmap

AzureIQ will be developed through one end-to-end application: a web API on App Service, API Management in front of it, and a client application that uses the API through APIM. The case study, not a speculative enterprise platform model, determines what AzureIQ keeps and generalizes.

Commissioned workspaces keep the deployment source of truth in the ignored local `.azure/deployment-plan.md` file so private scope and environment details are not published.

## Phase 0: Workspace Commissioning

Current accomplishments:

- one user-facing Orchestrator and hidden specialist workflows;
- supervised private Azure scope with no private identifiers in Git;
- MCP-first capability routing;
- initial change, approval, verification, and artifact-reuse contracts;
- one proven Resource Group mutation gap and parameterized fallback;
- an empty test Resource Group for the case study.

These are provisional inputs. The case study may simplify, replace, or retire them.

## Phase 1: Define The Application And Scenarios

Capture:

- business concept, users, and primary workflow;
- API and client technology;
- API contract and data needs;
- authentication and authorization;
- data classification and privacy;
- availability, latency, scale, recovery, and budget;
- APIM policy requirements;
- normal behavior plus the failure scenarios to inject;
- functional and operational acceptance criteria.

Exit when the deployment plan is complete and approved. Do not generate application or infrastructure code before this gate.

## Phase 2: Build The Local Product

- Build the web API and client application.
- Define correlation IDs, health endpoints, structured telemetry, and error contracts.
- Add functional, integration, and API contract tests.
- Verify the client-to-API workflow locally.

Exit when the normal workflow is testable without Azure and expected failures are observable.

## Phase 3: Prepare And Deploy The Azure Vertical Slice

- Inventory available Azure MCP, extensions, skills, modules, and existing subscription telemetry.
- Design App Service, APIM, client hosting, identities, networking, Key Vault references, and observability.
- Prefer Bicep and maintained modules where they fit; use MCP, CLI, SDK, or REST where they are the better supported primitive.
- Generate only the artifacts needed for this application.
- Run static validation, provider validation, what-if, security/reliability/cost review, and approval.
- Deploy through the approved path.
- Verify client-to-APIM-to-App-Service behavior, telemetry, alerts, identity, and rollback.

Exit when the application works end to end in the test subscription and the operational baseline is queryable.

## Phase 4: Exercise Engineering And Support Scenarios

For each user-defined scenario:

1. Record healthy baseline and expected failure signature.
2. Inject one bounded, approved fault.
3. Run raw Azure MCP/AppLens diagnosis.
4. Identify evidence gaps, wrong assumptions, tool limitations, and user effort.
5. Add the smallest AzureIQ query, decision point, runbook, guard, or execution operation only when it improves the baseline.
6. Plan and approve remediation.
7. Execute and independently verify recovery plus adjacent regressions.
8. Record sanitized results and compare measurable outcomes.

Potential scenarios include policy regressions, backend errors, authentication failures, rate limits, cache behavior, latency, deployment/revision errors, certificates, networking, telemetry gaps, and capacity. The user will supply the actual list.

Exit when AzureIQ can repeat the tested scenarios with accurate routing, evidence, questions, remediation, and verification.

## Phase 5: Harvest Reusable Assets

From case-study evidence only:

- promote useful App Service/APIM/client modules, policies, KQL, alerts, tests, and runbooks;
- record versions, compatibility conditions, decision points, validation freshness, and supersession;
- rerun a setup with one changed condition to prove adaptation rather than blind reuse;
- retire artifacts that do not outperform platform tools or reduce meaningful risk/effort;
- decide whether the shared CLI needs generic deployment operations;
- decide whether enough stable local operations exist to justify a local MCP transport.

Exit when reuse is demonstrated, not merely cataloged.

## Phase 6: Decide What To Generalize

Only after the vertical slice:

- identify workflows common across other Azure services;
- onboard a second workload to test portability;
- decide whether centralized telemetry, policy, hosted approvals, and durable incident state are justified;
- design always-on detection/remediation only for tested, bounded runbooks;
- preserve human-led review for ambiguous, destructive, privilege, public-exposure, failover, and data-risk decisions.

## Immediate Decisions

| Decision | Why it is needed now |
| --- | --- |
| Application concept and users | Defines the real API and client workflow |
| API/client technology | Starts local product development |
| Authentication and data sensitivity | Controls identity, policy, logging, and client design |
| Initial APIM scenarios | Determines telemetry and operational tests |
| Availability and budget | Constrains App Service/APIM tiers and topology |

Broader enterprise standards will be proposed as the case study exposes them, with recommendations and tradeoffs rather than a large questionnaire upfront.