# Harbor support frontend

React 19, strict TypeScript, Vite, and MSAL Browser. Harbor IT Services is a fictional small-business IT company. Company status and support cases are synthetic; inference uses only the backend's configured real providers. There is no demo login, generated answer, direct model connection, or silent provider fallback.

## Build and validate

From this directory, using the existing installed dependencies:

```powershell
npm run typecheck
npm run build
npm test
npm run test:e2e
```

`dist` contains the production SPA, relative assets, and `pcm-capture.js`. Serve **all** of it from the backend's static web root, through the same APIM origin at `/support/`. Set backend `Harbor:PathBase` to `/support` (no trailing slash). Preserve the trailing slash on the browser application URL. Vite uses `base: './'`; there are no hardcoded tenant, hostname, subscription, or deployment values in the bundle.

`npm run dev -- --base /support/` runs the Vite frontend only. It does not create an API, bypass authentication, or supply fake runtime configuration. Requests need a same-origin route to the actual backend; otherwise the UI deliberately reports the configuration error.

Unit/component tests mock the backend, identity boundary, and browser media APIs **only in test files**. AudioWorklet tests verify mono PCM16 resampling from 24, 44.1, and 48 kHz. Browser smoke tests use the machine's existing Microsoft Edge, a runner-managed local Vite server, and test-only API responses. They do not authenticate to Entra or invoke real providers; the server is bounded to the test run. No browser download is required. The initial local Node 26.13 browser-run attempt hit a Playwright/proxied local-URL `options.path` authority error before executing tests; that is not evidence of a passing browser run. Typecheck, production build, and Vitest can run independently.

## Required runtime configuration

The public, uncached `GET ./v1/config` must return the actual backend `RuntimeConfig`:

- `companyName`, `fictionalDemo`;
- `auth.configured`, `auth.authority`, `auth.clientId`, `auth.scope`, `auth.redirectPath`;
- `capabilities.cases`, `knowledge`, `text`, `voice`, `providerMode`;
- `textMaxChars` (1–2000) and `voiceSessionSeconds` (1–300).

For Entra, configure the backend's `Harbor:Entra:TenantId`, `ClientId`, `ApiAudience`, and delegated `Scope`. The client ID is the public SPA registration; register the exact application URL, e.g. `https://<gateway>/support/`, as a **SPA** redirect URI. The returned redirect path is `./`. MSAL performs authorization code + PKCE, uses session-scoped caching, and requests the configured `Support.Access` scope. The customer needs the `Support.Customer` app role. The current single-company backend derives the company from that authorized role; no custom company claim is required. Popup denial, missing consent, expired authorization, and token acquisition failures remain visible to the user.

Only the customer access token is sent in browser HTTP `Authorization`. APIM must validate it, forward it in `X-Harbor-Caller-Authorization`, and replace upstream `Authorization` with its app-only managed-identity token carrying `Support.Gateway`. Neither that gateway token nor the backend's `Model.Invoke` identity/provider credential is a browser credential. Public static assets and `/v1/config` must work before sign-in. Do not expose the private backend as an alternate browser API.

Backend storage, Search, text, Voice Live, an active bounded lab window, approved WebSocket Origins, and their managed-identity permissions must be configured by the service operator. A runtime capability being enabled does not guarantee provider health: actual failed calls display backend problem details and trace references, never fabricated success.

## HTTP contract

All paths below are relative to the application base (`/support/` externally):

| Method and path | Use |
| --- | --- |
| `GET v1/config` | Public runtime configuration |
| `GET v1/customer` | Authorized company ID and authorization expiry, no owner identifiers |
| `GET v1/company`, `GET v1/services` | Company catalog |
| `GET v1/status/{serviceId}` | Explicitly synthetic status |
| `POST v1/chat/messages` | `{serviceId,message}` → grounded answer with versioned citations |
| `GET v1/cases` | Caller-owned case history |
| `POST v1/case-proposals` | `{serviceId,subject,summary,impact}` → immutable expiring proposal |
| `GET v1/case-proposals/{id}` | Fetch a voice-prepared proposal for human review |
| `POST v1/case-proposals/{id}/confirmation` | `{proposalHash,intent:"create_case"}` → caller-bound grant |
| `POST v1/case-proposals/{id}/commit` | `{proposalHash,confirmationGrant}` plus GUID `Idempotency-Key` |
| `POST v1/voice/sessions` | `{consent:true}` → bounded one-use socket lease |
| `DELETE v1/voice/sessions/{id}` | Revoke that caller-owned lease |

Company citations are displayed as escaped text, not untrusted executable links or HTML. Text questions are independent backend requests; the visible conversation is not automatically forwarded as model history. The UI retains at most 20 text responses and 10 voice transcripts.

Case creation is three deliberate steps: **prepare → review and explicitly confirm → commit**. No model or voice event issues confirmation. Voice drafts must be selected for review and cannot replace an already reviewed draft. The exact proposal hash, grant, and GUID are retained in tab memory for commit retries; failed commits report an **unknown outcome**, not failure or success. Retry the existing commit before preparing a duplicate. Do not reload or sign out during an uncertain commit; doing so clears the in-memory grant/key. After reopening, inspect owned case history. A lost confirmation response is not blindly repeated.

## Voice protocol and microphone lifecycle

- HTTPS is required, except loopback development. Consent and browser microphone permission are separate gates.
- A mono AudioWorklet resamples the actual device rate to 24 kHz PCM16. Each chunk is 1200 samples / 2400 bytes / 50 ms; audio uploads begin only after `session.ready`.
- Consume the server's returned `webSocketUrl`, not a constructed dynamic socket path. Its path must exactly match the fixed application base plus `voice` (`/support/voice` externally), with exactly one non-secret query parameter: `?sessionId=<UUID>` matching the lease's `sessionId`. Both compact and hyphenated UUID formats are accepted. Any additional query parameters, mismatched session IDs, dynamic paths, credentials, or fragments are rejected. The secret ticket is **never** in the URL.
- APIM exposes one WebSocket handshake at `/support/voice`, forwarding to backend `/voice/socket` while preserving the `sessionId` query. There is no assumption that APIM can template an immutable handshake route with a session-specific path. Relative HTTP(S) or same-origin WS(S) URLs returned by the backend are resolved to the page's matching WebSocket transport; HTTPS remains required outside loopback development.
- WebSocket subprotocols are exactly `harbor.voice.v1` and `harbor.ticket.<opaque-ticket>`. APIM supplies the gateway identity on the upgrade; the browser cannot set a WebSocket Authorization header. The single-use lease already binds the customer and authorization expiry.
- Outbound events are only `audio.append`, `response.interrupt`, and `session.stop`. The backend owns session instructions, provider credentials, grounding, tools, turn detection, and limits.
- Incoming events are `session.ready`, `speech.started`, `knowledge.sources`, `case.proposal`, `audio.delta`, `assistant.text`, and `voice.error`. PCM playback is 24 kHz, with a bounded 30-second queue; uploads have a bounded network backlog.
- Interrupt stops queued playback and cancels the backend response. Stop, consent withdrawal, hidden tab, page exit, unmount/sign-out, expiry, provider/transport errors, and permission loss release microphone tracks, disconnect capture, stop playback, close the socket/audio context, and revoke the lease. A lease already released by socket closure may legitimately return 404 on revocation.
- Connection readiness is bounded to 20 seconds. The client also enforces the smaller of backend session expiry and the configured maximum; backend idle/concurrency/usage limits remain authoritative.

## Accessibility and theme

Semantic landmarks, a keyboard skip link, visible focus, native labeled controls, status/error live regions, reduced-motion support, responsive layouts, and non-color-only voice state indicators are included. The exact pre-module Clawpilot theme detection and `--cp-*` palette live in `index.html`; component styles use only those color variables and Segoe UI typography.
