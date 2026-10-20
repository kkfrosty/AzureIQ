# Contributing To AzureIQ

Read the [AI safety disclaimer](DISCLAIMER.md) before running the project.
Use isolated development environments and sanitized examples. Do not use
production credentials or run unattended AI-directed changes to test a contribution.

## Forks, Branches, And Publishing

AzureIQ is public and licensed under [MIT](LICENSE). Others may copy, modify,
and redistribute it, subject to the license, including retaining its copyright
and permission notice. These permissions do not grant write access to this
upstream repository.

| Access | Work on code | Update upstream `main` |
| --- | --- | --- |
| Public user, without collaborator access | Clone or fork; create branches in their own fork; open a pull request | No |
| Explicitly invited write collaborator | Also create and push ordinary working branches in this repository | No; submit a pull request for the owner to merge |
| Repository owner `@kkfrosty` | Manage access, branches, and contributions | May merge pull requests or push directly using the owner/admin bypass |

The owner-only update rule targets `main`. Ordinary working branches are not
protected by that rule. Write access is not a private branch sandbox: collaborators
may be able to modify other unprotected branches. Use forks when separate control
is important. Branches and their contents in this public repository are public.

Only invite collaborators when upstream write access is actually needed. Public
contributors do not need invitations to use forks or propose changes. Do not
share owner credentials or tokens with another account. Access is based on the
GitHub account authenticated for the push, not the author name or email in a
commit. A second account used by the owner is not automatically the repository
owner or entitled to bypass `main` protections.

An active update-restriction ruleset reserves changes to `main` for the repository
admin; on this personal repository, that is its owner. Classic branch protection
also requires an up-to-date passing `Workspace contract` check, one code-owner
approval, signed commits, resolved conversations, and linear history for
non-bypassing changes. Force-pushes and deletion are disabled in that protection.
The owner/admin bypass is intentionally enabled to permit direct pushes; it
also bypasses branch checks and is not an identity-specific secret-scanning
exemption. The owner should still use pull requests and passing validation when
practical.

The owner is the code owner in [CODEOWNERS](.github/CODEOWNERS). Adding a
collaborator or another code owner does not grant permission to bypass the
owner-only update rule. Repository settings can change; live GitHub settings,
not this document alone, determine enforcement.

Other public GitHub repositories commonly use the same fork-and-pull-request
model, but each repository controls its own collaborator permissions, branch
rules, contribution process, and license. Public visibility alone does not grant
permission to modify upstream branches or reuse code without a license.

## Contribution Process

1. Fork the repository, or use a working branch if explicitly granted write access.
2. Keep the change focused and review the diff for secrets and private scope.
3. Run `./scripts/Test-Workspace.ps1` and the tests relevant to your change.
4. Open a pull request describing the change, risks, and validation performed.
5. Wait for owner review and merge. Do not assume an approved PR grants direct
   push rights to `main`.

Do not submit access tokens, private keys, connection strings, private tenant or
subscription scope, personal information, customer payloads, raw telemetry, or
local environment files. Use synthetic test fixtures. Review commit metadata
and use a GitHub `noreply` email if you do not want a personal address published.
Secret push protection is a useful layer, not proof that a contribution is safe.

Workflow changes must retain least privilege. Do not give untrusted fork code
write tokens, deployment credentials, or secret-bearing execution contexts.

By submitting a contribution, you represent that you have the necessary rights
and intend it to be distributed under this repository's MIT License. Preserve
applicable third-party notices and do not contribute employer-owned code or
confidential material without authorization. Contributions may be declined; no
review or support timeline is promised.
