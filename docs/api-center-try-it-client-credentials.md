# API Center Try it: client-credentials investigation

**Status:** active investigation; workflow is draft, not a validated remediation.
**Recorded evidence:** November 12, 2026, 19:26-19:48 UTC.
**Last documentation review:** November 12, 2026.

This guide documents the configured lab, the reproduced warning, and the work
required to establish the customer's cause and a supported resolution. It does
not declare client-credentials authentication working. No fresh Azure queries
or changes were performed while writing this document.

## 1. Problem Definition

The customer is following Microsoft's
[Configure API access in Azure API Center](https://learn.microsoft.com/en-us/azure/api-center/authorize-api-access?tabs=portal)
guide. Their managed developer portal displays:

> Credentials are unavailable for the current user. The request will be sent without authentication.

Expected behavior: a user authorized to use an API version's OAuth configuration
can authenticate through client credentials and obtain a token for the intended
API. Observed behavior: the authorization selector and **Authenticate** control
appear, but the warning persists.

This is **Azure API Center**, not the API Management developer portal. The lab
uses Petstore 1.0.0 and GET `/pets`; the customer screenshot uses POST `/pets`.
Matching warning text alone does not establish identical causes.

The impact demonstrated so far is blocked authenticated testing. Customer
production impact, severity, incident window, affected users, and correlation
IDs have not been established. Existing portal catalog access works for the
lab user; backend API authentication has not been tested.

### Why this workflow exists

- **Baseline:** follow the Microsoft configuration guide.
- **Observed limitation:** the warning can occur even when API Center returns a
  usable credential; the text does not identify the failing hop.
- **Expected improvement:** distinguish user access, secret retrieval, portal
  validation, token issuance, and backend authorization before making changes.
- **Acceptance check:** identify the failing hop with sanitized evidence and
  compare the same user/version/configuration before and after an approved fix.

## 2. Diagnosis

### Recorded lab setup

| Component | Recorded state | Verification boundary |
| --- | --- | --- |
| API Center | Dedicated lab API Center, managed portal, East US | Exact resource name remains in ignored private bindings |
| Portal sign-in | Existing single-tenant Entra SPA with the portal redirect URI | Lab user can browse the catalog |
| Portal user access | Azure API Center Data Reader at API Center scope | Does not grant access to API credentials |
| OAuth client | Isolated `apic-petstore-tryit-client-20261112` | One credential, no configured API permissions; separate resource app remains deleted |
| Secret | `petstore-oauth-client-secret` in the dedicated lab RBAC vault | Exact vault name remains in ignored private bindings; secret value is excluded |
| Secret lifetime | Expires November 13, 2026, at 19:30:16 UTC | An expired credential invalidates a later comparison |
| Vault networking | `SecuredByPerimeter`, enforced association, one lab-subscription inbound rule | Required by inherited lab governance; not necessarily the customer's topology |
| Secret reader | API Center system-assigned identity with Key Vault Secrets User at this vault | Runtime credential retrieval returned HTTP 200 and a nonempty secret |
| API authorization | `petstore-client-credentials`, OAuth2, Client Credentials only | Client ID, authorization/token endpoints, qualified audience scope and secret reference configured |
| API association | Petstore version `1-0-0`, display version 1.0.0 | Authentication attached to this exact version |
| Credential user access | Azure API Center Credential Access Reader at this authentication requirement | Granted only to the lab user |
| Deployment metadata | `tryit-lab` environment and `petstore-token-only` deployment | Enables the portal test surface; does not deploy or secure Petstore |

The token audience is the existing lab API audience with `/.default`, not an
assertion that public Petstore accepts Entra tokens. No Petstore or Harbor API
request was sent, and no bearer token was sent to either endpoint.

The refresh URL is unset: client credentials obtains new tokens rather than
using refresh tokens. This is distinct from the guide's refresh URL field for
flows that use it.

### Two different access-management surfaces

**To let a user enter the developer portal and browse APIs:**

1. Open API Center **Access control (IAM)**.
2. Select **Add > Add role assignment**.
3. Select **Azure API Center Data Reader**.
4. Select the approved Entra users or existing security group.
5. Review and assign at this API Center's scope, not the subscription.

**To let that user use configured credentials in Try it:**

1. Open **Inventory > Assets > Swagger Petstore > Versions**.
2. Open the version's menu and select **Manage Access**.
3. Confirm the intended authentication configuration is attached.
4. Open that configuration's menu and select **Edit access policies**.
5. Select **Add > Users** or **Add > Groups** and select approved members.
6. Verify **Azure API Center Credential Access Reader** at the specific
   version/authentication scope.

The documentation calls the latter role "API Center Credential Access Reader";
the live built-in role name includes the "Azure" prefix. Portal-user access
does not require giving users direct Key Vault access. Creating an OAuth client
is not a substitute for either user-access assignment.

### Evidence and limitations

| UTC/source | Sanitized observation | What it establishes |
| --- | --- | --- |
| November 12, 19:26-19:48; configuration readback | OAuth configuration, version association, deployment metadata and scoped grants exist | Configuration, not successful authentication |
| November 12, 19:46:18; API Center credential endpoint | HTTP 200 and nonempty OAuth client secret for the lab user | API Center can retrieve the secret through the perimeter |
| Same observation; managed portal | Selector and Authenticate control present; warning persists | Credential retrieval success does not clear the UI warning |
| Same observation; deployed JavaScript | Client credentials excluded from flow validation and absent from authentication dispatch | A causal mechanism for this lab warning |
| Separate direct browser token probe | Entra response blocked by CORS | A separate token-transport obstacle, not the original warning's cause |
| Alternative integrated-browser transport | `Storage.getCookies` unsupported; request failed before sending | Tool limitation, not proof of an Azure token-service failure |
| Independent verifier | End-to-end acceptance FAILED; evidence reviewed without independent live collection | No verified recovery or successful token exchange |

The recorded bundle is `/assets/index-PpfRojv7.js`, SHA256
`d7f289637a39ae742a5629a970e8dda3f094c76781daa5ec23d24599a187e938`.
Minified identifiers are build-specific; do not assume they survive an update.

Local sanitized evidence is in ignored `.azureiq\runs\`:

- `APIC-TRYIT-20261112-PORTAL-EVIDENCE.json`
- `RUN-20261112-APIC-PERIMETER-OAUTH.json`
- The corresponding `APIC-TRYIT-20261112-PERIMETER-OAUTH` plan and approval records

These records are machine-local, not committed attachments or current Azure
state. Keep tenant, subscription, principal and client IDs in approved private
bindings rather than adding them to this document.

### Competing hypotheses

| Hypothesis | Recorded lab evidence | Cheapest discriminating check |
| --- | --- | --- |
| Missing portal catalog access | Catalog works for the lab user | Check Data Reader and sign-in on the actual customer's path |
| Missing version-specific credential access | Exact scoped grant exists; credential endpoint returns a secret | Confirm the same signed-in user and authentication requirement |
| API Center cannot read Key Vault | Runtime retrieval succeeds in the lab | Inspect secret metadata, identity, role and network evidence without retrieving values into logs |
| Portal rejects the configured grant | Deployed validator and dispatcher exclude client credentials | Compare the customer's exact bundle and sanitized credential response |
| Token endpoint or application authorization fails | No successful token exchange demonstrated | Observe an approved token-only request after confirming portal dispatch |
| Backend rejects a token | No API request was sent | Separate test against an approved, lab-owned token-validating endpoint |

## 3. Root Cause Analysis

**Recorded lab warning cause: confirmed by the active investigation's evidence.**
The independent verifier reviewed supplied evidence but could not repeat live
collection; that isolation limitation remains.

The causal chain in the inspected build is:

1. The configuration returns the `clientCredentials` flow and a usable secret.
2. The flow normalizer (`S8t`) maps the configured name to `client_credentials`.
3. Its allowlist (`E8t`) contains implicit and authorization-code/PKCE flows only.
4. No allowed flow remains, so the OAuth validator (`zMe`) rejects the response.
5. The response/warning mapping (`T8t`, `w8t`) produces the unavailable-credentials
   message. The dispatcher (`BMe.authenticate`) also lacks a client-credentials
   branch.

### Fresh Authenticate trace and official source corroboration

A sanitized application HAR captured on November 12 at 20:38:26-20:38:35 UTC
contains eleven actual fetch/XHR calls. Credential retrieval returned HTTP 200
in 343.5 ms with a nonempty secret. The warning was present before and after
the Authenticate click, the selection stayed unchanged, and no application,
token-endpoint or token-proxy request followed the click in that window.
This is an application-level capture, not a full native DevTools export;
request/response bodies, cookies and sensitive headers were omitted.

At 20:40:55 UTC, isolated execution of the current deployed pure validator
rejected client credentials and accepted an authorization-code/PKCE control.
This test did not configure or execute PKCE authentication.

The official [portal reference implementation](https://github.com/Azure/APICenter-Portal-Starter)
corroborates the flow restriction in its
[validator](https://github.com/Azure/APICenter-Portal-Starter/blob/main/src/utils/apiAuth.ts),
[rejection test](https://github.com/Azure/APICenter-Portal-Starter/blob/main/src/utils/apiAuth.test.ts)
and [dispatcher](https://github.com/Azure/APICenter-Portal-Starter/blob/main/src/services/OAuthService.ts).
[Azure/APICenter-Portal-Starter#150](https://github.com/Azure/APICenter-Portal-Starter/pull/150) fixed a
separate wire-name normalization defect that produced the same warning.
Its test still excludes client credentials; applying that normalization fix
is not a remedy for a client-credentials-only configuration.
The reference source does not establish the managed portal's deployed commit.

This is explicit behavior in the deployed code. Whether it is an intentional
security restriction, a regression, or a documentation mismatch requires API
Center product confirmation. Do not generalize it into "API Center never
supports client credentials."

**Customer cause: undetermined.** We have a matching symptom, not the customer's
build, effective access, secret response, token trace or product confirmation.

Configuration/provisioning checks did not detect this incompatibility because
they do not exercise the portal's flow validator and authentication dispatcher.
Successful secret retrieval is necessary but not sufficient for Try it.

## 4. Work through the case

### Step 1: establish a fresh, safe baseline

- Record UTC time, managed versus self-hosted portal, API/version, selected
  deployment, operation and authorization configuration.
- Verify active authentication and target scope against the private local
  configuration before each Azure read. Do not treat an old record as live state.
- Recheck credential expiry before retesting. Rotation/restoration is a new
  approved change; do not quietly recreate or extend a credential.
- Confirm the exact user has portal access and record whether other users or
  authorization methods are unaffected.
- Use read-only existing tools first. Do not build execution tools to unblock
  routine service work.

### Step 2: compare the guide with the actual customer configuration

Check these without changing multiple variables:

1. Entra portal sign-in application and published redirect configuration.
2. Data Reader assignment for the signed-in portal user or effective group.
3. Exact API version and attached OAuth authentication configuration.
4. Enabled flow, client ID, tenant-specific endpoints and intended scope.
5. Key Vault reference, enabled/expiry/version metadata, API Center managed
   identity, secret-read role and permitted network path.
6. Credential Access Reader at the relevant authentication requirement.

For Entra client credentials, verify the actual token request uses the intended
resource-qualified `/.default` scope. Bare `.default` in a guide or form does
not prove the correct audience is requested. Check application roles/consent
or the API's documented authorization model; delegated scopes alone do not
authorize an app-only request.

**Completion evidence:** a sanitized configuration comparison with each item
marked confirmed, missing, different or unverified.

### Step 3: localize credential availability

Observe the existing API Center data-plane operation:

`/workspaces/<workspace>/apis/<api>/versions/<version>/securityRequirements/<requirement>:getCredentials`

It is secret-bearing. Use the existing approved session/tool and keep the
response in memory. Record only UTC time, HTTP status, safe error/correlation
codes and whether the expected credential is nonempty.

| Result | Next action |
| --- | --- |
| 401/403 | Check identity, token audience and effective credential access; do not immediately broaden grants |
| Secret retrieval error or missing credential | Check the exact identity/reference, expiry, RBAC and network path |
| HTTP 200 with a nonempty secret, warning remains | Investigate portal response normalization and grant support |
| Credential accepted, token request fails | Move to token endpoint/transport diagnosis |

Do not export raw HARs, response bodies, tokens, cookies, client secrets or
authorization headers. Do not paste credentials into tickets, chat, screenshots
or public token-decoding sites.

**Completion evidence:** identify whether failure is before or after runtime
credential retrieval. An HTTP 200 without a usable credential is not sufficient.

### Step 4: compare the actual deployed portal implementation

- Record the customer's bundle asset name/hash and observation time without
  committing their portal URL or identifiers.
- Check whether its validator accepts the configured flow and whether its
  dispatcher implements that flow.
- Compare behavior and bundle evidence with the recorded lab build. A different
  hash alone neither confirms nor disproves the same mechanism.
- Retest the same user/version/configuration after any approved change.

Do not patch hosted JavaScript, intercept responses to fabricate credentials,
add PKCE just to hide the warning, or weaken access policies. Those changes
would invalidate the client-credentials reproduction.

**Completion evidence:** a customer-specific causal trace, or an explicit
remaining evidence gap. Promote the customer hypothesis to confirmed only
after independent corroboration.

### Step 5: verify token issuance separately

Only after the portal accepts the flow:

- Use the supported token transport with an approved token-only test.
- Check request grant, client, tenant endpoint, intended audience and relevant
  application authorization without logging secret or token values.
- Record HTTP status, OAuth error code, UTC time and safe correlation ID.
- If no request is dispatched, do not label it a token-server rejection.
- If CORS blocks a browser probe, distinguish that probe from the portal's
  supported transport. Do not assume disabling CORS or adding a redirect fixes
  client credentials.

**Completion evidence:** successful token issuance for the approved audience,
or a falsifiable failure localized to the token endpoint/transport.
Token issuance alone does not establish backend authorization.

### Step 6: seek product confirmation and choose a supported resolution

Escalate with a sanitized package containing:

- The linked Microsoft guide and expected behavior.
- Reproduction steps, UTC window and managed/self-hosted distinction.
- API/version/operation and authorization association, with private IDs removed.
- Access and Key Vault retrieval results, including secret-present boolean.
- Portal bundle hash and the observed validator/dispatcher behavior.
- Whether Authenticate dispatched a token request; separate CORS/tool failures.
- Clear questions: is exclusion intentional, is this a regression, and what
  supported release/path resolves the guide-to-runtime discrepancy?

The case owner coordinates with the API Center product/support owner. Keep
resolution open until the behavior is explained and a supported path is tested.
No product issue or support escalation has been filed by this workflow.

A product fix, a switch to authorization code with PKCE, or a self-hosted portal
is a separate decision with its own scope, security implications and approval.
PKCE may be an alternative user-authentication design; it is not successful
client-credentials testing.

### Step 7: verify recovery and close

Ask the independent verifier to repeat the same user/version path and return
VERIFIED, FAILED, INCONCLUSIVE or SCOPE_MISMATCH. Use a bounded 15-minute
propagation/observation window; record actual timestamps rather than assuming
it elapsed.

For a claimed client-credentials fix, require:

- The original warning is absent for the authorized test user.
- Credentials are retrieved using the intended API Center identity.
- The intended client-credentials request is dispatched and obtains a token.
- Unauthorized users still cannot retrieve those credentials.
- Existing catalog access and unrelated API configurations remain unchanged.

If backend authorization is in scope, obtain separate approval and use a
lab-owned validating endpoint: reject absent, malformed and wrong-audience
tokens, and accept the approved token. Do not send the lab bearer token to
public Swagger Petstore or use its HTTP 200 as authentication proof.

## 5. Lifecycle, approval and cleanup

The original approval records are consumed; they are not standing authority
for future changes. Follow [AzureIQ change control](../.github/skills/azureiq-change-control/SKILL.md)
for new grants, rotations, networking changes, alternatives and rollback.

The dedicated lab credential expires November 13 at 19:30:16 UTC. Expiry does
not remove its metadata, secret, role assignments or perimeter resources, and
issued tokens may remain valid until their own expiry. Cleanup is not automatic.

Before approving cleanup, compare actual inventory with the expected lab
objects and check ownership, dependencies and locks. Remove only newly created
test credentials/access policies, OAuth association/configuration, environment/
deployment metadata, vault role, dedicated secret and perimeter objects that
are explicitly included in the approved change. Redelleting the isolated client
or deleting the dedicated vault requires immediate destructive approval.
Preserve the original portal sign-in app and existing Harbor API app.

Do not bypass inherited policy with exception tags or unapproved exemptions.
The lab perimeter resolved its earlier network prerequisite; reproducing that
topology in the customer environment is not an assumed remediation.

Preserve a sanitized execution record and verifier result after changes. Never
mark the case resolved solely because a command succeeded.

## References

- [Configure API access in API Center](https://learn.microsoft.com/en-us/azure/api-center/authorize-api-access?tabs=portal)
- [Set up the API Center portal: user and group access](https://learn.microsoft.com/en-us/azure/api-center/set-up-api-center-portal#enable-sign-in-to-portal-by-microsoft-entra-users-and-groups)
- [Entra client-credentials grant](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)
- [Key Vault network security](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [Network Security Perimeter concepts](https://learn.microsoft.com/en-us/azure/private-link/network-security-perimeter-concepts)
- [AzureIQ incident response](../.github/skills/azureiq-incident-response/SKILL.md)
- [Harbor operating guide](harbor-operations-guide.md)
