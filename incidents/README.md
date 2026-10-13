# Incident Records

This directory holds sanitized operational records that are safe to review and version. Authorized raw evidence remains in the designated Azure evidence/log store.

Use the [incident record template](../.github/skills/azureiq-incident-response/references/incident-record-template.md). Store records as `YYYY/YYYY-MM-DD-short-name.md` and include the incident ID in the document.

Do not commit credentials, tokens, personal data, authorization headers, cookies, customer payloads, unrestricted logs, debug traces, connection strings, private keys, or secret values. Reference authorized evidence by incident-safe ID, query, UTC window, hash, and controlled location.

Only verified causes and outcomes may update support domains or future automation. A plausible hypothesis is not durable learning.