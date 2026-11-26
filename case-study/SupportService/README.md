# Harbor IT Services Support

A fictional, single-company support application: .NET 10 minimal API, React browser, caller-owned Azure Table cases, eight curated synthetic knowledge documents in AI Search, managed-identity Foundry text through APIM, and a controlled Voice Live WebSocket relay. No real cases are seeded, no Azure management tools are exposed, and no provider failure is replaced by a mock answer.

This package is **local construction**, not evidence of cloud deployment or production readiness. Live identities, networking, DNS, roles, APIM forwarding, model availability, Voice Live API/version/voice compatibility, quota and total cost remain deployment gates. Provider fakes exist only in the test projects.

## Local verification checkpoint — 2026-11-04

- Locked restore and serial Release solution build succeeded with **zero warnings/errors**.
- Native standalone MTP executed **80 unit and 25 integration tests: 105 passed, none skipped**. This includes signed-JWT dual-identity/audience checks, ownership, exact confirmation/expiry/idempotency, grounding/tool boundaries, provider failures and controlled in-process WebSocket relay flows.
- Release publish succeeded; browser `dist` was assembled into published `wwwroot` and the entry-page hashes matched. Docker pull/build/push was not executed.
- The compiled API exported OpenAPI **3.0.4**, the fixed private handshake `/voice/socket`, `sessionId` query and `webSocketUrl` ticket schema, plus seven admitted MCP operations with an OpenAPI digest.
- Published-image command `seed --dry-run` succeeded with `providerCalls: false`, `deletes: false`, and `caseFixtureUpload: false`. No Azure authentication, query, deployment, initialization write, real data seed or live provider inference was performed.

## Build and verification

The runtime `/v1/{**unmatched}` 404 fallback is excluded from OpenAPI description.
It is not a public operation or MCP tool. The targeted APIM repair can omit
that invalid generated path from the existing pinned image's import without
changing runtime behavior or rebuilding the image.

Run from this directory. The SDK is pinned to `10.0.403`; use Node `26.13.0` for the browser.

```powershell
dotnet restore SupportService.slnx --configfile NuGet.config --locked-mode
dotnet build SupportService.slnx --no-restore --configuration Release -m:1
dotnet test --solution SupportService.slnx --no-restore --configuration Release
```

Tests use **xUnit v3 3.2.2, Microsoft.Testing.Platform v2**, explicitly selected in `global.json`. Unlike VSTest, SDK 10 MTP uses `--project`/`--solution` and no `--` separator for `dotnet test`. Native standalone execution is also supported:

```powershell
dotnet run --project tests\Harbor.Support.UnitTests --configuration Release --no-build -- --no-progress --report-xunit --report-xunit-filename unit-tests.xml
dotnet run --project tests\Harbor.Support.IntegrationTests --configuration Release --no-build -- --no-progress --report-xunit --report-xunit-filename integration-tests.xml
```

The local validation environment denies VSTest loopback IPC and SDK MTP named-pipe IPC. Standalone MTP runs the actual tests in-process without either IPC mechanism. It does not change application authentication. If Git metadata reads are restricted, append `-p:EnableSourceControlManagerQueries=false` to build/publish commands; do not read or modify the denied global Git configuration. `--disable-build-servers -m:1` avoids compiler/MSBuild IPC when necessary.

The scoped `NuGet.config` uses only the configured internal `azure-default` NuGet proxy at `https://packagefeedproxy.microsoft.io/nuget/v3/index.json`; public nuget.org and public mirrors are not fallback sources. Use the organization's approved network and authentication setup without committing credentials or disabling certificate validation. The API and test dependency closures are locked. This source-configuration correction applies to future restores/builds; it does not change or rebuild the previously pinned Harbor image. For workspace-local caches:

```powershell
$cache = Join-Path (Resolve-Path ..\..).Path '.azureiq\cache'
$env:DOTNET_CLI_HOME = Join-Path $cache 'dotnet'
$env:NUGET_PACKAGES = Join-Path $cache 'nuget'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $cache 'nuget-http'
$env:NUGET_SCRATCH = Join-Path $cache 'nuget-scratch'
$env:TESTINGPLATFORM_TELEMETRY_OPTOUT = '1'
```

## Runtime configuration

Use environment variables or an untracked local settings source. `__` replaces `:` in environment-variable names. No tenant, account, endpoint, credential, or lab approval is baked into the image. Blank bindings fail closed; `/health/live` is not proof of provider health. `/health/ready` checks required binding shapes, **not** live dependencies or authorization.

| Key (`Harbor:` prefix unless noted) | Meaning / default |
| --- | --- |
| `PathBase` | Empty locally; `/support` behind the reference APIM. APIM must preserve this prefix when forwarding. No trailing slash. |
| `Entra:TenantId` | Approved Entra tenant GUID; also fixes the issuer authority. |
| `Entra:ClientId` | Public SPA application/client ID, not the backend audience or a secret. |
| `Entra:ApiAudience` | API application client GUID or its standard `api://<same-GUID>` URI. The backend accepts exactly those two representations of that same API, including the GUID audience normally emitted in v2 access tokens; arbitrary audience URIs/lists are rejected. Set API registration `api.requestedAccessTokenVersion` to `2`. |
| `Entra:Scope` | Full exposed delegated scope requested by MSAL, ending in `/Support.Access`. |
| `Entra:DelegatedScope` | `Support.Access`. |
| `Entra:CustomerRole` | `Support.Customer`; user/group app-role assignment to the API service principal. |
| `Entra:GatewayRole` | `Support.Gateway`; application role assigned only to the APIM managed identity. |
| `Storage:ServiceUri` | HTTPS Table service URI (not blob service and not a connection string). |
| `Storage:CasesTableName` / `Storage:UsageTableName` | `HarborCases` / `HarborUsage`; distinct tables. |
| `Search:Endpoint` / `Search:IndexName` | HTTPS AI Search endpoint / `harbor-knowledge-v1`. |
| `Ai:ChatEndpoint` | Exact approved HTTPS APIM inference route ending `/ai/chat`, e.g. public path `/support/ai/chat`; never a direct Foundry endpoint. |
| `Ai:TokenScope` | APIM model API audience plus `/.default`, not a cognitive-services audience. Backend MI needs the separate `Model.Invoke` application role there. |
| `Ai:Deployment` / `Ai:ApiVersion` | Approved Foundry model deployment / `2024-10-21`. APIM maps the envelope to its configured deployment route. |
| `Voice:Endpoint` | HTTPS endpoint ending exactly `/voice-live/realtime`. The backend constructs WSS internally. |
| `Voice:TokenScope` | `https://ai.azure.com/.default`. |
| `Voice:Model` / `Voice:ApiVersion` | Approved real model/deployment / `2026-07-15`. Actual regional support is unverified. |
| `Voice:VoiceName` | `en-US-AvaNeural`; actual provider availability is unverified. |
| `Voice:AllowedOrigins:0` (and numbered entries) | Exact HTTPS browser origin without trailing slash; loopback HTTP is allowed for development. No wildcard. |
| `Limits:LabWindowId` / `Limits:LabWindowEndsAt` | Required immutable bounded lab ID and UTC ISO-8601 end time. Closed/unconfigured windows deny inference. Reusing an ID with a different end time is rejected by the durable ledger. |
| **`AZURE_CLIENT_ID`** (no prefix) | Approved user-assigned managed identity client GUID. When absent, the SDK explicitly selects system-assigned MI. No CLI, developer credential, key or connection-string fallback. The initialization job uses its own MI binding. |
| **`APPLICATIONINSIGHTS_CONNECTION_STRING`** | Optional platform telemetry binding. The exporter explicitly authenticates with the managed identity selected by `AZURE_CLIENT_ID`, not the instrumentation key. No prompts, case bodies, audio, bearer tokens or upstream payloads are intentionally recorded. |

`Limits` defaults are hard ceilings and can only be lowered:

| Keys | Defaults |
| --- | --- |
| `TextRequestsPerMinute`, `TextRequestsPerWindow`, `TextMaxChars`, `TextMaxOutputTokens` | `10`, `100`, `2000`, `600` |
| `ModelConcurrency`, `ProviderTimeoutSeconds`, `ProposalSeconds` | `2`, `20` (maximum `60`), `600` |
| `VoiceSessionsPerCaller`, `VoiceConcurrency`, `VoiceSessionSeconds`, `VoiceIdleSeconds` | `1`, `2`, `300`, `60` |
| `VoiceSecondsPerWindow`, `VoiceTicketSeconds` | `1200`, `30` |
| `VoiceClientMessageBytes`, `VoiceServerMessageBytes`, `VoiceAudioChunkBytes` | `16384`, `65536`, `4800` |
| `VoiceAudioBytesPerSecond`, `VoiceEventsPerSecond`, `VoiceToolCallsPerSession` | `57600`, `40`, `8` |

Text/voice admission is an ETag-conditional Table transaction in one window partition, including global counts and per-caller text-minute rows. Voice reserves the full bounded session duration **before** issuing its connection ticket; unused time is deliberately not refunded. Per-process concurrency and opaque lease state require the reference deployment's **one replica**. Restart loses voice tickets but not durable admission counts.

## Identity and public browser bootstrap

`GET /support/v1/config` and static files are public. The response exposes only public MSAL `authority`, SPA `clientId`, delegated `scope`, redirect path `./`, capability configuration flags, and limits. It contains no token, provider URL, identity ID or secret. The browser uses authorization code + PKCE, never a gateway or provider credential.

Protected HTTP routes require **two independently validated, signed, unexpired tokens**:

1. Browser sends its delegated customer bearer token to APIM. APIM validates approved tenant/issuer/audience, scope `Support.Access`, role `Support.Customer`, and a user object ID.
2. APIM discards any inbound `X-Harbor-Caller-Authorization`, copies the validated original bearer token there, and replaces `Authorization` with its app-only managed-identity token carrying `Support.Gateway` for the backend API audience.
3. Backend validates both tokens and both identities; a direct browser/customer token is not sufficient. Gateway tokens with delegated scopes are rejected. The backend maps the approved customer role to fixed company `harbor-it-services`; **there is no custom `harbor_company` claim precondition**, company selector or caller-provided owner ID.

Owner partitions are hashes of fixed company + validated tenant + user object ID. Callers cannot select another partition. Case proposal hashes include owner, company, exact normalized contents and expiry. Confirmation requires a separate deliberate UI action with exact `proposalHash` and `intent: "create_case"`; the resulting opaque grant is stored only as a hash. Commit consumes proposal + writes case + idempotency receipt atomically. Exact retries with the original GUID `Idempotency-Key`, proposal/hash/grant return the original case, including after proposal expiry; mismatched reuse and second writes are rejected.

Required runtime grants: backend MI **Storage Table Data Contributor**, **Search Index Data Reader**, **Model.Invoke** on the APIM model API, and the approved Voice Live inference role (typically **Cognitive Services User**, verify for the selected resource/API). APIM MI separately needs **Support.Gateway** for the backend API and its approved Foundry text inference role. The initialization-job MI needs **Search Service Contributor**, **Search Index Data Contributor**, and **Storage Table Data Contributor**. Grant creation and cloud verification require separate approval.

## Routes and executable MCP selection

Paths below are relative to `Harbor:PathBase`.

| Method / path | Operation ID |
| --- | --- |
| GET `/health/live`, `/health/ready` | `GetLiveness`, `GetReadiness` |
| GET `/v1/config`, `/v1/customer` | `GetRuntimeConfig` (public), `GetCustomer` (protected) |
| GET `/v1/company`, `/v1/services` | `GetCompany`, `ListServices` |
| GET `/v1/status/{serviceId}` | `GetSyntheticServiceStatus` |
| GET `/v1/knowledge/search?serviceId=...&q=...` | `SearchCompanyKnowledge` |
| GET `/v1/cases`, `/v1/cases/{id}` | `ListMyCases`, `GetMyCase` |
| POST `/v1/case-proposals`, GET `/v1/case-proposals/{id}` | `PrepareCase`, `GetMyCaseProposal` |
| POST `/v1/case-proposals/{id}/confirmation` | `ConfirmCaseProposal` — deliberate human only |
| POST `/v1/case-proposals/{id}/commit` | `CommitConfirmedCase` — requires human grant and idempotency header |
| POST `/v1/chat/messages` | `SendChatMessage` |
| POST `/v1/voice/sessions`, DELETE `/v1/voice/sessions/{id}` | `CreateVoiceSession`, `RevokeMyVoiceSession` |
| GET `/voice/socket?sessionId=...` (private WSS upgrade) | `ConnectVoiceRelay`; public APIM handshake is `/support/voice?sessionId=...` |

`contracts/support-v1.openapi.json` is actual OpenAPI 3.0 from the compiled endpoint/schema generator, not a hand-authored placeholder. Regenerate both exports from the same binary:

```powershell
dotnet run --project src\Harbor.Support.Api --configuration Release --no-build -- export-contracts contracts
```

This command briefly starts an ephemeral loopback listener to finalize endpoint metadata, generates via `IOpenApiDocumentProvider` **without HTTP/provider requests**, exports, and stops. Development hosts also serve `/openapi/v1.json`; production does not expose it.

`contracts/support-mcp-tools.json` binds the OpenAPI file's SHA-256 and exact selected operations:

- `company_info` → `GetCompany`
- `service_catalog` → `ListServices`
- `service_status` → `GetSyntheticServiceStatus`
- `search_knowledge` → `SearchCompanyKnowledge` (`query` tool argument maps to REST query parameter `q`)
- `list_my_cases` → `ListMyCases`
- `get_my_case` → `GetMyCase`
- `prepare_case` → `PrepareCase`

These are APIM's executable MCP operations, not a new MCP server implementation. **Never** expose confirmation issuance, commit, voice lease issuance or raw voice relay as MCP/model tools. Every operation still uses the same dual-identity authorization. API Center discovery is separate from execution.

## Real Voice Live relay

After deliberate microphone/processing consent, POST `{ "consent": true }` to `/v1/voice/sessions`. Use the returned same-origin `webSocketUrl` (`/support/voice?sessionId=<opaque-id>`) without constructing another route, and exactly these two browser subprotocols:

```text
harbor.voice.v1
harbor.ticket.<43-character-opaque-ticket>
```

The only query parameter is the non-secret opaque `sessionId`; no ticket, upstream key, model identity or browser JWT is put into the URL. APIM's WebSocket API uses the fixed API path `support/voice`, immutable `onHandshake` operation, and fixed backend service URL `wss://<private-backend>/voice/socket`, preserving the sessionId query. This is separate from the REST API's `/support` prefix forwarding; no dynamic APIM handshake path templating is assumed. APIM validates/forwards the approved browser Origin and socket subprotocols and supplies **only the app-only gateway token** to the backend WSS route; the consumed one-time lease binds the caller, company and original authorization expiry. It must not demand a browser Authorization header on the socket. APIM must not log ticket-bearing subprotocols. The server selects only `harbor.voice.v1` in its upgrade response.

Browser event allowlist: `audio.append` (base64 mono PCM16, 24 kHz), `audio.clear`, `response.interrupt`, `session.stop`. No session/model/tool/instruction settings are accepted. Server events: `session.ready`, `speech.started`, `knowledge.sources`, `case.proposal`, `audio.delta`, `assistant.text`, `voice.error` (`code`, `detail`). No recording is stored. The backend controls VAD, voice, token budget, tool definitions and response stages; audio is rejected before a server read-tool result. Voice can prepare a UI proposal but cannot confirm or commit it. Duration, idle, event/audio budgets, tool counts, Origin, ticket reuse, authorization expiry, disconnect and owner cancellation terminate sessions. Real regional Voice Live behavior still requires a separately approved cloud contract test.

## Initialization using the same immutable image

```powershell
dotnet src\Harbor.Support.Api\bin\Release\net10.0\publish\Harbor.Support.Api.dll seed --dry-run
# Cloud mutation: separate exact initialization approval and seed-job MI required:
# <same-image> seed --execute-approved-initialization
```

Only these two argument forms are accepted. Dry-run makes no provider/token requests. The execute form creates the exact lexical-only Search index if missing, rejects incompatible existing schemas without replacement, uploads the eight hash/version-bound synthetic documents, and creates the distinct cases/usage tables if missing. It never uploads `cases.synthetic.json`, deletes resources/rows or modifies a mismatching index. The usage ledger rows are created transactionally on admission, not seeded. Partial initialization is possible; reconcile before retrying. Do not run execution merely because dry-run succeeds.

## One-image browser + API package

Build context is this directory, not the workspace root:

```powershell
docker build --file Dockerfile --tag harbor-support:local .
# No push or cloud deployment is part of local verification.
```

The multistage recipe uses locked npm/NuGet dependencies, builds the browser, publishes `Harbor.Support.Api.dll`, embeds the curated data, copies browser `dist` into `/app/wwwroot`, and runs as the non-root `app` user on port `8080`. Runtime MSAL config is fetched from the API, so no tenant/client binding is compiled into JavaScript. Versioned base-image tags are specified; deployment should bind the separately approved resolved image digests. The same image's entrypoint accepts the initialization command. Docker image pulls/builds and provider/network behavior are not implied by a successful local `dotnet publish`.

Equivalent local assembly after the independently owned browser build:

```powershell
dotnet publish src\Harbor.Support.Api --configuration Release --no-restore --no-self-contained -p:UseAppHost=false
$publish = 'src\Harbor.Support.Api\bin\Release\net10.0\publish'
New-Item -ItemType Directory -Force "$publish\wwwroot" | Out-Null
Copy-Item src\harbor-support-web\dist\* "$publish\wwwroot" -Recurse -Force
dotnet "$publish\Harbor.Support.Api.dll" seed --dry-run
```

`src/Harbor.Support.Api/Harbor.Support.Api.http` documents all HTTP routes. It deliberately does not automate obtaining tokens, issuing human confirmation, deploying infrastructure or writing real data.
