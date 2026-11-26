import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import type { Api } from './api';
import { errorMessage } from './api';
import type { CaseDraft, CaseProposal, CommitResult, ConfirmationGrant, Service, SupportCase } from './contracts';

interface Props {
  api: Api;
  services: Service[];
  enabled: boolean;
  suggestedProposalId: string | null;
}

interface Confirmed {
  grant: ConfirmationGrant;
  idempotencyKey: string;
}

export function CasesPanel({ api, services, enabled, suggestedProposalId }: Props) {
  const [cases, setCases] = useState<SupportCase[]>([]);
  const [listError, setListError] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [proposal, setProposal] = useState<CaseProposal | null>(null);
  const [confirmed, setConfirmed] = useState<Confirmed | null>(null);
  const [expired, setExpired] = useState(false);
  const [confirmationAttempted, setConfirmationAttempted] = useState(false);
  const [receipt, setReceipt] = useState<CommitResult | null>(null);
  const [loadedVoiceId, setLoadedVoiceId] = useState<string | null>(null);

  async function refresh() {
    setLoading(true);
    setListError('');
    try {
      setCases(await api.request<SupportCase[]>('v1/cases'));
    } catch (failure) {
      setListError(errorMessage(failure));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (!enabled) return;
    let active = true;
    setLoading(true);
    void api.request<SupportCase[]>('v1/cases').then(
      result => { if (active) setCases(result); },
      failure => { if (active) setListError(errorMessage(failure)); },
    ).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [api, enabled]);

  async function reviewVoiceDraft() {
    if (!enabled || !suggestedProposalId || proposal || busy) return;
    setBusy(true);
    setError('');
    try {
      const result = await api.request<CaseProposal>(`v1/case-proposals/${encodeURIComponent(suggestedProposalId)}`);
      setProposal(result);
      setLoadedVoiceId(suggestedProposalId);
      setConfirmed(null);
      setConfirmationAttempted(false);
      setReceipt(null);
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    const remaining = proposal ? Date.parse(proposal.expiresAt) - Date.now() : 0;
    setExpired(proposal !== null && remaining <= 0);
    if (!proposal || remaining <= 0) return;
    const timer = window.setTimeout(() => setExpired(true), remaining);
    return () => window.clearTimeout(timer);
  }, [proposal]);

  async function prepare(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const impact = form.get('impact');
    if (impact !== 'low' && impact !== 'medium' && impact !== 'high') return;
    const draft: CaseDraft = {
      serviceId: String(form.get('serviceId')),
      subject: String(form.get('subject')).trim(),
      summary: String(form.get('summary')).trim(),
      impact,
    };
    setBusy(true);
    setError('');
    setReceipt(null);
    try {
      setProposal(await api.request<CaseProposal>('v1/case-proposals', 'POST', draft));
      setConfirmed(null);
      setConfirmationAttempted(false);
    } catch (failure) {
      setError(errorMessage(failure));
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    if (!proposal || expired || confirmed || confirmationAttempted) return;
    setBusy(true);
    setError('');
    setConfirmationAttempted(true);
    try {
      const grant = await api.request<ConfirmationGrant>(
        `v1/case-proposals/${encodeURIComponent(proposal.id)}/confirmation`,
        'POST', { proposalHash: proposal.proposalHash, intent: 'create_case' },
      );
      if (grant.proposalId !== proposal.id || grant.proposalHash !== proposal.proposalHash) {
        throw new Error('The confirmation does not match the reviewed proposal. Do not commit.');
      }
      setConfirmed({ grant, idempotencyKey: crypto.randomUUID() });
    } catch (failure) {
      setError(`${errorMessage(failure)} Confirmation may have been recorded, but no case was committed by this browser. Check My cases; discard this proposal and prepare a new one if needed. Do not repeat confirmation blindly.`);
    } finally {
      setBusy(false);
    }
  }

  async function commit() {
    if (!proposal || !confirmed) return;
    setBusy(true);
    setError('');
    try {
      const result = await api.request<CommitResult>(
        `v1/case-proposals/${encodeURIComponent(proposal.id)}/commit`, 'POST',
        { proposalHash: proposal.proposalHash, confirmationGrant: confirmed.grant.grant },
        { 'Idempotency-Key': confirmed.idempotencyKey },
      );
      setReceipt(result);
      setCases(current => [result.case, ...current.filter(item => item.id !== result.case.id)]);
      setProposal(null);
      setConfirmed(null);
    } catch (failure) {
      setError(`${errorMessage(failure)} The outcome is not confirmed. Retry commit uses the exact same grant and idempotency key; do not prepare a duplicate case.`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card" id="cases" aria-labelledby="cases-heading">
      <div className="section-heading">
        <div><p className="eyebrow">Track & resolve</p><h2 id="cases-heading">My support cases</h2></div>
        <span className="tag">Only your cases</span>
      </div>
      {!enabled ? <p role="status">Case storage is not configured. Creating and listing cases is unavailable.</p> : <>
        <p>Prepare a draft, review the exact details, then explicitly confirm and create. Chat and voice cannot confirm a case for you.</p>
        {suggestedProposalId && suggestedProposalId !== loadedVoiceId && <div className="notice">
          <p>A voice-prepared draft is ready. Finish or discard any current proposal before reviewing it.</p>
          <button type="button" className="secondary" disabled={busy || proposal !== null} onClick={() => void reviewVoiceDraft()}>Review voice-prepared draft</button>
        </div>}
        {error && <p className="error" role="alert">{error}</p>}
        {receipt && <p className="notice" role="status">
          {receipt.replayed ? 'Original case recovered' : 'Case created'}: <strong>{receipt.case.subject}</strong> · {receipt.case.id}
        </p>}
        {proposal ? <div className="review" aria-labelledby="review-heading">
          <h3 id="review-heading">Review case proposal</h3>
          <dl>
            <dt>Service</dt><dd>{services.find(item => item.serviceId === proposal.serviceId)?.name ?? proposal.serviceId}</dd>
            <dt>Subject</dt><dd>{proposal.subject}</dd>
            <dt>Summary</dt><dd className="preserve">{proposal.summary}</dd>
            <dt>Impact</dt><dd>{proposal.impact}</dd>
            <dt>Expires</dt><dd>{new Date(proposal.expiresAt).toLocaleString()}</dd>
          </dl>
          <details><summary>Exact proposal reference</summary><p className="mono">{proposal.id}<br />{proposal.proposalHash}</p></details>
          {expired && <p role="status">This proposal has expired. A pending commit can still be retried with its original key to recover an existing receipt.</p>}
          {confirmed ? <>
            <p className="notice" role="status">You confirmed these exact details. No case is created until you commit.</p>
            <button type="button" disabled={busy} onClick={() => void commit()}>{busy ? 'Committing…' : 'Commit confirmed case'}</button>
          </> : <button type="button" disabled={busy || expired || confirmationAttempted} onClick={() => void confirm()}>
            {busy ? 'Confirming…' : 'I confirm: create this case'}
          </button>}
          <button type="button" className="secondary" disabled={busy} onClick={() => {
            setProposal(null); setConfirmed(null); setConfirmationAttempted(false); setError('');
          }}>Discard draft</button>
        </div> : <form onSubmit={event => void prepare(event)}>
          <div className="field-pair">
            <label>Case service<select name="serviceId" required disabled={busy || services.length === 0}>
              {services.map(service => <option key={service.serviceId} value={service.serviceId}>{service.name}</option>)}
            </select></label>
            <label>Business impact<select name="impact" defaultValue="low" disabled={busy}>
              <option value="low">Low — minor disruption</option><option value="medium">Medium — work is affected</option><option value="high">High — business is blocked</option>
            </select></label>
          </div>
          <label>Subject<input name="subject" required minLength={1} maxLength={120} disabled={busy} /></label>
          <label>What happened?<textarea name="summary" required minLength={1} maxLength={2000} rows={3} disabled={busy} aria-describedby="case-privacy" /></label>
          <p className="muted small" id="case-privacy">Describe the issue and its impact. Never include passwords, tokens, payment details, or sensitive customer data.</p>
          <button disabled={busy || services.length === 0}>{busy ? 'Preparing…' : 'Prepare case for review'}</button>
        </form>}
        <div className="section-heading list-heading"><h3>Your case history</h3><button type="button" className="secondary" disabled={loading} onClick={() => void refresh()}>Refresh cases</button></div>
        {loading && <p role="status">Loading your cases…</p>}
        {listError && <p role="alert" className="error">{listError}</p>}
        {!loading && !listError && cases.length === 0 && <p className="muted">No cases returned for your signed-in account.</p>}
        <ul className="case-list">{cases.map(item => <li key={item.id}>
          <details><summary><strong>{item.subject}</strong> <span className="tag">{item.state}</span></summary>
            <p className="preserve">{item.summary}</p>
            <p className="small">{item.serviceId} · {item.impact} impact · {new Date(item.createdAt).toLocaleString()}</p>
            <p className="mono small">{item.id}{item.synthetic ? ' · Fictional support case' : ''}</p>
          </details>
        </li>)}</ul>
      </>}
    </section>
  );
}
