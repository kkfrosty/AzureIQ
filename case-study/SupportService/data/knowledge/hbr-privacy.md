# Privacy and information minimization

This fictional learning application minimizes customer information. Do not enter passwords, MFA codes, bearer tokens, payment details, real personal documents, or private account identifiers.

The application does not record raw audio or log raw prompts, request bodies, transcripts, retrieved passages, confirmation grants, or connection tickets. Active microphone audio is relayed to the configured Voice Live provider for that session. Provider-side processing and retention need separate parent validation; the app cannot promise a provider has no retention.

Voice requires deliberate microphone consent and offers mute, interruption, stop, and disconnect. A microphone denial is a visible error. Stopping closes local capture and playback and revokes the backend lease.

Case fields are durable only after explicit confirmation; proposals also use durable storage. Review the exact summary and avoid sensitive data. No automatic case deletion or external communication is performed by this application.
