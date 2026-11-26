import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import { createApi, errorMessage, loadConfig } from './api';
import type { Api } from './api';
import { createIdentity } from './auth';
import type { Identity } from './auth';
import { CasesPanel } from './CasesPanel';
import { Citations } from './Citations';
import type { ChatAnswer, Company, RuntimeConfig, Service, ServiceStatus } from './contracts';
import { VoicePanel } from './VoicePanel';

interface Session {
  config: RuntimeConfig;
  identity: Identity;
  api: Api;
}

export function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [config, setConfig] = useState<RuntimeConfig | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(true);
  const [signedIn, setSignedIn] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let active = true;
    async function initialize() {
      setBusy(true);
      setError('');
      try {
        const runtime = await loadConfig();
        if (!active) return;
        setConfig(runtime);
        const identity = await createIdentity(runtime.auth);
        if (!active) return;
        setSession({ config: runtime, identity, api: createApi(() => identity.token()) });
        setSignedIn(identity.accountName() !== null);
      } catch (failure) {
        if (active) setError(errorMessage(failure));
      } finally {
        if (active) setBusy(false);
      }
    }
    void initialize();
    return () => { active = false; };
  }, [attempt]);

  async function login() {
    if (!session) return;
    setBusy(true); setError('');
    try {
      await session.identity.login();
      setSignedIn(true);
    } catch (failure) {
      setError(`Sign-in failed. ${errorMessage(failure)}`);
    } finally {
      setBusy(false);
    }
  }

  async function logout() {
    if (!session) return;
    setSignedIn(false);
    setBusy(true); setError('');
    try {
      await session.identity.logout();
    } catch (failure) {
      setError(`Sign-out could not complete. ${errorMessage(failure)} Close this tab on a shared device.`);
    } finally {
      setBusy(false);
    }
  }

  return <>
    <a className="skip-link" href="#main">Skip to support</a>
    <header className="site-header">
      <a className="brand" href="./" aria-label="Harbor IT Services home"><span className="brand-mark" aria-hidden="true">H</span><span>HARBOR<span className="brand-sub">IT SERVICES</span></span></a>
      <nav aria-label="Support navigation"><a href="#services">Services & status</a><a href="#assistant">Get support</a><a href="#cases">My cases</a></nav>
      {signedIn && session ? <button className="secondary" disabled={busy} onClick={() => void logout()}>Sign out</button> :
        <button disabled={busy || !session} onClick={() => void login()}>{busy ? 'Loading…' : 'Sign in with Microsoft'}</button>}
    </header>
    <main id="main">
      <div className="hero">
        <div><p className="eyebrow">Small business. Personal support.</p>
          <h1>Your IT, in good hands.</h1>
          <p className="hero-copy">Practical help for the technology your business depends on. Find trusted answers, talk it through, or open a support case with Harbor.</p>
        </div>
        <aside className="demo-notice"><span className="tag">Fictional company demo</span><p>Harbor IT Services is fictional. Service status and cases are synthetic; configured AI providers process real requests. Do not enter real secrets or sensitive business data.</p></aside>
      </div>
      {busy && !session && <p role="status">Loading secure support configuration…</p>}
      {error && <div className="error" role="alert"><p>{error}</p>{!session && <button className="secondary" onClick={() => setAttempt(current => current + 1)} disabled={busy}>Retry configuration</button>}</div>}
      {session && signedIn ? <Workspace key={session.identity.accountName()} session={session} /> :
        <section className="card welcome" aria-labelledby="welcome-heading">
          <p className="eyebrow">Customer support portal</p><h2 id="welcome-heading">Welcome to Harbor</h2>
          <p>Sign in with your authorized company account to see services, consult company knowledge, and manage cases owned by you.</p>
          <ul className="welcome-list"><li>Grounded answers with source references</li><li>Optional voice with explicit microphone consent</li><li>Review and confirm before a case is created</li></ul>
          <p className="muted small">Microsoft Entra handles sign-in using authorization code + PKCE. No passwords or model credentials are collected by this page.</p>
          {config && !config.auth.configured && <p role="status">Sign-in is unavailable until the administrator configures the runtime Entra settings.</p>}
        </section>}
    </main>
    <footer><strong>Harbor IT Services</strong><span>Support for the way small businesses work.</span><span>Fictional demonstration · No emergency or production support</span></footer>
  </>;
}

function Workspace({ session: { config, identity, api } }: { session: Session }) {
  const [company, setCompany] = useState<Company | null>(null);
  const [services, setServices] = useState<Service[]>([]);
  const [selected, setSelected] = useState('');
  const [customerExpires, setCustomerExpires] = useState('');
  const [loadError, setLoadError] = useState('');
  const [loading, setLoading] = useState(true);
  const [reload, setReload] = useState(0);
  const [status, setStatus] = useState<ServiceStatus | null>(null);
  const [statusError, setStatusError] = useState('');
  const [message, setMessage] = useState('');
  const [chatBusy, setChatBusy] = useState(false);
  const [chatError, setChatError] = useState('');
  const [turns, setTurns] = useState<{ id: string; question: string; service: string; answer: ChatAnswer }[]>([]);
  const [suggestedProposalId, setSuggestedProposalId] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    setLoading(true); setLoadError('');
    async function load() {
      try {
        const [profile, catalog, customer] = await Promise.all([
          api.request<Company>('v1/company'), api.request<Service[]>('v1/services'),
          api.request<{ companyId: string; authorizationExpiresAt: string }>('v1/customer'),
        ]);
        if (!active) return;
        setCompany(profile); setServices(catalog); setSelected(catalog[0]?.serviceId ?? '');
        setCustomerExpires(customer.authorizationExpiresAt);
      } catch (failure) {
        if (active) setLoadError(errorMessage(failure));
      } finally {
        if (active) setLoading(false);
      }
    }
    void load();
    return () => { active = false; };
  }, [api, reload]);

  useEffect(() => {
    if (!selected) return;
    let active = true;
    setStatus(null); setStatusError('');
    void api.request<ServiceStatus>(`v1/status/${encodeURIComponent(selected)}`).then(
      result => { if (active) setStatus(result); },
      failure => { if (active) setStatusError(errorMessage(failure)); },
    );
    return () => { active = false; };
  }, [api, selected, reload]);

  async function send(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const question = message.trim();
    if (!question || !selected || chatBusy) return;
    setChatBusy(true); setChatError('');
    const service = services.find(item => item.serviceId === selected)?.name ?? selected;
    try {
      const answer = await api.request<ChatAnswer>('v1/chat/messages', 'POST', { serviceId: selected, message: question });
      setTurns(current => [...current.slice(-19), { id: crypto.randomUUID(), question, service, answer }]);
      setMessage('');
    } catch (failure) {
      setChatError(errorMessage(failure));
    } finally {
      setChatBusy(false);
    }
  }

  return <>
    <div className="account-strip"><span>Signed in as <strong>{identity.accountName()}</strong></span>
      {customerExpires && <span className="small">Current authorization expires {new Date(customerExpires).toLocaleTimeString()}</span>}</div>
    {loading && <p role="status">Loading your company services…</p>}
    {loadError && <div role="alert" className="error"><p>{loadError}</p><button className="secondary" onClick={() => setReload(value => value + 1)}>Retry services</button></div>}
    <section className="card" id="services" aria-labelledby="services-heading">
      <div className="section-heading"><div><p className="eyebrow">Your business technology</p><h2 id="services-heading">Services & status</h2></div><span className="tag">Synthetic status</span></div>
      {company && <><p>{company.description}</p><p className="small muted">{company.privacyNotice}</p></>}
      <div className="services-grid">{services.map(service => <button key={service.serviceId} className="service-option" aria-pressed={selected === service.serviceId} onClick={() => setSelected(service.serviceId)}>
        <strong>{service.name}</strong><span>{service.description}</span><span className="small muted">{service.topics.join(' · ')}</span>
      </button>)}</div>
      {statusError && <p role="alert" className="error">{statusError}</p>}
      {selected && !status && !statusError && <p role="status">Loading selected service status…</p>}
      {status && <div className="status-block" role="status"><strong>{status.state}</strong><p>{status.description}</p><p className="small muted">Fictional status, not live monitoring · Updated {new Date(status.updatedAt).toLocaleString()}</p></div>}
    </section>
    <div className="support-grid">
      <section className="card" id="assistant" aria-labelledby="assistant-heading">
        <p className="eyebrow">Answers from Harbor knowledge</p><h2 id="assistant-heading">Let’s work through it</h2>
        <p>Ask about the selected service. Responses include company source references when available. Each question is independent; do not assume earlier messages are sent to the model.</p>
        {!config.capabilities.text || !config.capabilities.knowledge ? <p role="status">Grounded text support is unavailable: the real text provider or company knowledge search is not configured.</p> : <>
          <div className="chat-log" role="log" aria-label="Support conversation" aria-live="polite" aria-relevant="additions">
            {turns.length === 0 && <p className="chat-empty">What can we help with today?<span>Choose a service above, then describe your issue.</span></p>}
            {turns.map(turn => <article className="chat-turn" key={turn.id}><p className="question"><strong>You · {turn.service}</strong><span>{turn.question}</span></p>
              <div className="answer"><strong>Harbor assistant</strong><p className="preserve">{turn.answer.message}</p><Citations citations={turn.answer.citations} /><p className="small muted">Provider: {turn.answer.provider} · Company information is fictional</p></div>
            </article>)}
          </div>
          <form onSubmit={event => void send(event)}>
            <label>Your question<textarea rows={3} required maxLength={config.textMaxChars} value={message} onChange={event => setMessage(event.target.value)} disabled={chatBusy} aria-describedby="chat-help" /></label>
            <div className="section-heading"><p className="small muted" id="chat-help">No passwords or sensitive data. {message.length}/{config.textMaxChars}</p><button disabled={chatBusy || !selected || !message.trim()}>{chatBusy ? 'Finding grounded help…' : 'Send question'}</button></div>
          </form>
          {chatBusy && <p role="status">Consulting company sources and the configured provider…</p>}
          {chatError && <p role="alert" className="error">{chatError}</p>}
        </>}
      </section>
      <VoicePanel api={api} enabled={config.capabilities.voice} sessionSeconds={config.voiceSessionSeconds} onProposal={setSuggestedProposalId} />
    </div>
    {suggestedProposalId && <p className="notice" role="status">Voice prepared a case proposal. <a href="#cases">Review it in My support cases</a>; nothing has been confirmed or committed.</p>}
    <CasesPanel api={api} services={services} enabled={config.capabilities.cases} suggestedProposalId={suggestedProposalId} />
  </>;
}
