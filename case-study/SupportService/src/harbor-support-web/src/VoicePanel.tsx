import { useEffect, useRef, useState } from 'react';
import type { Api } from './api';
import { errorMessage } from './api';
import type { Citation } from './contracts';
import { Citations } from './Citations';
import { createVoiceController } from './voice';
import type { VoiceState } from './voice';

interface Props {
  api: Api;
  enabled: boolean;
  sessionSeconds: number;
  onProposal(id: string): void;
}

export function VoicePanel({ api, enabled, sessionSeconds, onProposal }: Props) {
  const [consent, setConsent] = useState(false);
  const [state, setState] = useState<VoiceState>('idle');
  const [detail, setDetail] = useState('Microphone off. Voice only starts when you choose to connect.');
  const [transcripts, setTranscripts] = useState<string[]>([]);
  const [sources, setSources] = useState<Citation[]>([]);
  const [warning, setWarning] = useState('');
  const controller = useRef<ReturnType<typeof createVoiceController> | null>(null);

  useEffect(() => {
    let active = true;
    const voice = createVoiceController(api, {
      state(value, message) { if (active) { setState(value); setDetail(message); } },
      warning(message) { if (active) setWarning(message); },
      text(value) { if (active) setTranscripts(current => [...current.slice(-9), value]); },
      sources(value) { if (active) setSources(value); },
      proposal(value) { if (active) onProposal(value.id); },
    }, sessionSeconds);
    controller.current = voice;
    const stopWhenHidden = () => { if (document.visibilityState === 'hidden') voice.stop(); };
    const stopOnPageExit = () => voice.stop();
    document.addEventListener('visibilitychange', stopWhenHidden);
    window.addEventListener('pagehide', stopOnPageExit);
    return () => {
      active = false;
      voice.stop();
      controller.current = null;
      document.removeEventListener('visibilitychange', stopWhenHidden);
      window.removeEventListener('pagehide', stopOnPageExit);
    };
  }, [api, sessionSeconds, onProposal]);

  const running = state === 'connecting' || state === 'listening';

  async function start() {
    setTranscripts([]); setSources([]); setWarning('');
    try {
      await controller.current?.start(consent);
    } catch (error) {
      setState('error'); setDetail(errorMessage(error));
    }
  }

  return <section className="card voice-panel" aria-labelledby="voice-heading">
    <p className="eyebrow">Prefer to talk?</p><h2 id="voice-heading">Voice support</h2>
    <p>Talk to the same company-grounded support assistant. Your microphone is relayed by our backend to the configured real Voice Live provider; no model credentials are sent to your browser.</p>
    {!enabled ? <p role="status">Voice support is unavailable. The real Voice Live provider or approved browser Origin is not configured.</p> : <>
      <label className="check-label"><input type="checkbox" checked={consent} onChange={event => {
        setConsent(event.target.checked);
        if (!event.target.checked) controller.current?.stop();
      }} />I consent to microphone capture and audio processing by the configured voice provider for this session.</label>
      <p className="small muted">Up to {sessionSeconds} seconds per session; backend idle and usage limits also apply. Switching tabs stops voice. Do not speak secrets or sensitive data.</p>
      <div className="voice-state" role={state === 'error' ? 'alert' : 'status'}><span className={`voice-indicator ${state === 'listening' ? 'live' : ''}`} aria-hidden="true" /><p>{detail}</p></div>
      {warning && <p className="error" role="alert">{warning}</p>}
      <div className="button-row">
        <button type="button" disabled={!consent || running} onClick={() => void start()}>Start voice session</button>
        <button type="button" className="secondary" disabled={!running} onClick={() => controller.current?.interrupt()}>Interrupt reply</button>
        <button type="button" className="secondary" disabled={!running} onClick={() => controller.current?.stop()}>Stop voice</button>
      </div>
      <div role="log" aria-label="Voice response transcript" aria-live="polite">
        {transcripts.map((text, index) => <p className="preserve voice-transcript" key={`${index}-${text.slice(0, 20)}`}>{text}</p>)}
      </div>
      {sources.length > 0 && <Citations citations={sources} />}
      <p className="small muted">Voice may prepare a proposal, never authorize it. Review, confirm, and commit cases using the case form.</p>
    </>}
  </section>;
}
