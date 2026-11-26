# Case preparation, confirmation, and escalation

Choose an approved Harbor service and describe the symptom, non-sensitive supporting detail, and impact: low, medium, or high. Preparation stores an immutable proposal with a versioned hash and a maximum ten-minute expiry. It creates no case.

The separate human confirmation screen displays the service, subject, summary, and impact exactly. Confirming that exact proposal issues a caller-bound single-use grant. Changing any field requires a new proposal. Chat, voice, model tools, and spoken agreement cannot issue this grant.

Commit requires the proposal hash, confirmation grant, and a caller-scoped idempotency key. Exact retries reuse that key and return the same case. Never retry an uncertain result with a new key. Expired, altered, replayed, or another customer's proposals must not create a case.

Created cases remain open synthetic support requests. Harbor does not promise a real escalation channel, notify anyone, close a case, or repair an issue. Use your organization's separately approved support process for real urgent needs.
