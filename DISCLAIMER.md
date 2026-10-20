# AI Safety And Risk Disclaimer

## Use At Your Own Risk

AzureIQ is experimental AI-assisted operations software, not a certified safety,
security, compliance, or production-management system. Use of this software,
documentation, generated code, commands, diagnoses, reports, or recommendations
is at your own risk. You are responsible for deciding whether an action is
appropriate, obtaining authorization, and independently verifying its outcome.

AI can hallucinate facts, misunderstand scope, omit important dependencies,
misidentify root causes, generate insecure or destructive commands, and report
success when a system is still unhealthy. Output can be incorrect even when it
appears confident, includes citations, or passes automated checks. Reports and
examples are not professional advice or guarantees of correctness, security,
compliance, availability, or fitness for any particular purpose.

## Development Environments, Not Production

**We strongly recommend performing all AI-proposed changes only in isolated,
disposable development or test environments, not production.** Use synthetic or
sanitized data, dedicated test identities, least-privilege access, and explicit
cost limits. Do not connect production credentials merely to try the project.

This project does not claim production readiness. Production use is discouraged.
If you nevertheless choose to use any part of it against production, that is
your decision and risk. Apply your organization's formal engineering, security,
change-management, backup, recovery, and compliance processes; obtain qualified
human review and approval of the exact target and change. Testing in development
does not establish that a change is safe in production.

An incorrect action can delete or corrupt data, interrupt services, expose
credentials or personal information, grant excessive privileges, weaken network
security, create unexpected cloud charges, or cause irreversible changes.
Some changes have no reliable rollback.

## Avoid Autopilot And Unattended Writes

**Do not treat an AI agent as an autonomous administrator. Avoid autopilot,
auto-approve, unrestricted-tool, and unattended remediation modes.** Do not
disable approval prompts or grant broad credentials to make an agent complete a
task. Such modes can chain multiple erroneous actions before anyone notices.

Repository instructions, prompts, model-generated plans, approval text, and
read-only labels are not technical authorization boundaries. Model-directed
routing and instruction compliance are best-effort. Enforce permissions and
approval gates outside the model with Azure RBAC, identity and network controls,
and independently controlled execution mechanisms. Treat retrieved content and
tool output as untrusted; they may contain prompt-injection instructions.

Before any write, independently confirm:

- the authenticated identity, tenant, subscription, resource scope, and environment;
- the exact proposed commands, parameters, permissions, and expected impact;
- a narrow plan or what-if, available backups, and a tested recovery approach;
- explicit human authorization, monitoring, cost controls, and stop conditions;
- post-change functional, security, and health checks, not just command success.

Never put secrets, credentials, customer data, or raw sensitive logs in issues,
pull requests, Git history, agent prompts, or public reports. Secret scanners do
not detect every kind of sensitive information.

## No Warranty Or Guaranteed Support

The software is provided **"AS IS", without warranty**, under the
[MIT License](LICENSE). To the extent permitted by applicable law, the authors
and copyright holders disclaim liability as stated in that license. No support,
incident response, service level, or correction timeline is promised. Applicable
law may limit warranty exclusions or liability limitations; this notice does not
override mandatory legal rights.

AzureIQ is an independent project. Use of Azure, Microsoft, or GitHub names does
not imply endorsement, certification, or support by those companies.

This notice communicates risks and recommended operating practices. It does not
add field-of-use restrictions or remove permissions granted by the MIT License.
Third-party components and services remain subject to their own licenses and
terms.
