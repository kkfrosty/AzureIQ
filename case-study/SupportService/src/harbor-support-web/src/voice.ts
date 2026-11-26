import { appBase, errorMessage } from './api';
import type { Api } from './api';
import type { CaseProposal, Citation, VoiceTicket } from './contracts';

export type VoiceState = 'idle' | 'connecting' | 'listening' | 'stopped' | 'error';

interface VoiceHandlers {
  state(value: VoiceState, detail: string): void;
  warning(detail: string): void;
  text(value: string): void;
  sources(value: Citation[]): void;
  proposal(value: CaseProposal): void;
}

interface Run {
  stopped: boolean;
  ready: boolean;
  context: AudioContext | null;
  stream: MediaStream | null;
  source: MediaStreamAudioSourceNode | null;
  capture: AudioWorkletNode | null;
  mute: GainNode | null;
  socket: WebSocket | null;
  ticket: VoiceTicket | null;
  revoked: boolean;
  timers: number[];
  playback: Set<AudioBufferSourceNode>;
  playbackAt: number;
}

export function pcmBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function voiceSocketUrl(ticket: VoiceTicket): URL {
  if (appBase.protocol !== 'https:' && !(appBase.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(appBase.hostname))) {
    throw new Error('Voice requires HTTPS (or localhost for development).');
  }
  const url = new URL(ticket.webSocketUrl, appBase);
  const expectedOrigin = new URL(appBase);
  expectedOrigin.protocol = appBase.protocol === 'https:' ? 'wss:' : 'ws:';
  if (url.protocol === 'https:') url.protocol = 'wss:';
  else if (url.protocol === 'http:') url.protocol = 'ws:';
  const parameters = [...url.searchParams];
  const uuid = /^(?:[a-f\d]{32}|[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12})$/i;
  if (url.origin !== expectedOrigin.origin || url.pathname !== `${appBase.pathname}voice` ||
      url.username || url.password || url.hash || parameters.length !== 1 ||
      parameters[0]?.[0] !== 'sessionId' || parameters[0]?.[1] !== ticket.sessionId ||
      !uuid.test(ticket.sessionId) || ticket.protocol !== 'harbor.voice.v1' ||
      !/^[A-Za-z0-9_-]{43}$/.test(ticket.ticket)) {
    throw new Error('The server returned an invalid fixed voice URL, session ID, or protocol.');
  }
  return url;
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

export function createVoiceController(api: Api, handlers: VoiceHandlers, sessionSeconds: number) {
  let current: Run | null = null;

  function stopPlayback(run: Run) {
    for (const source of run.playback) {
      source.stop();
      source.disconnect();
    }
    run.playback.clear();
    run.playbackAt = 0;
  }

  async function revoke(run: Run) {
    if (!run.ticket || run.revoked) return;
    run.revoked = true;
    try {
      await api.request(`v1/voice/sessions/${encodeURIComponent(run.ticket.sessionId)}`, 'DELETE');
    } catch (error) {
      // Socket closure can release the same lease before the revocation request arrives.
      if (error instanceof Error && 'status' in error && error.status === 404) return;
      handlers.warning(`The previous microphone stream is stopped, but lease revocation could not be verified. ${errorMessage(error)}`);
    }
  }

  function release(run: Run) {
    run.stopped = true;
    run.ready = false;
    for (const timer of run.timers) window.clearTimeout(timer);
    run.timers = [];
    run.stream?.getTracks().forEach(track => track.stop());
    run.capture?.port.close();
    run.capture?.disconnect();
    run.source?.disconnect();
    run.mute?.disconnect();
    stopPlayback(run);
    if (run.socket) {
      run.socket.onopen = null; run.socket.onmessage = null; run.socket.onerror = null; run.socket.onclose = null;
      if (run.socket.readyState === WebSocket.OPEN) {
        run.socket.send(JSON.stringify({ type: 'session.stop' }));
        run.socket.close(1000, 'client_stopped');
      } else if (run.socket.readyState === WebSocket.CONNECTING) {
        run.socket.close();
      }
    }
    if (run.context && run.context.state !== 'closed') {
      void run.context.close().catch(error => {
        handlers.warning(`The previous microphone stream is stopped, but audio cleanup failed. ${errorMessage(error)}`);
      });
    }
    if (current === run) current = null;
    void revoke(run);
  }

  function fail(run: Run, error: unknown) {
    if (run.stopped) return;
    release(run);
    handlers.state('error', errorMessage(error));
  }

  function play(run: Run, audio: string) {
    const context = run.context;
    if (!context) throw new Error('Audio playback was not initialized.');
    const binary = atob(audio);
    if (binary.length === 0 || binary.length % 2 !== 0 || binary.length > 49_152) {
      throw new Error('The voice relay returned invalid or oversized PCM16 audio.');
    }
    const buffer = context.createBuffer(1, binary.length / 2, 24_000);
    const channel = buffer.getChannelData(0);
    for (let index = 0; index < channel.length; index++) {
      const sample = binary.charCodeAt(index * 2) | (binary.charCodeAt(index * 2 + 1) << 8);
      channel[index] = (sample >= 0x8000 ? sample - 0x10000 : sample) / 0x8000;
    }
    const when = Math.max(context.currentTime, run.playbackAt);
    if (when - context.currentTime > 30) throw new Error('Voice playback exceeded its bounded queue. Start a new session.');
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    source.onended = () => { run.playback.delete(source); source.disconnect(); };
    run.playback.add(source);
    source.start(when);
    run.playbackAt = when + buffer.duration;
  }

  function receive(run: Run, data: unknown) {
    if (typeof data !== 'string' || data.length > 65_536) throw new Error('The voice relay returned an unsupported message.');
    const message: unknown = JSON.parse(data);
    if (!record(message) || typeof message.type !== 'string') throw new Error('The voice relay returned malformed JSON.');
    switch (message.type) {
      case 'session.ready':
        if (message.sampleRate !== 24_000) throw new Error('The voice relay must use 24 kHz PCM16 audio.');
        run.ready = true;
        handlers.state('listening', 'Microphone on. Listening through the backend-controlled Voice Live relay.');
        break;
      case 'speech.started':
        stopPlayback(run);
        break;
      case 'audio.delta':
        if (!run.ready || typeof message.audio !== 'string') throw new Error('Unexpected voice audio received.');
        play(run, message.audio);
        break;
      case 'assistant.text':
        if (typeof message.text !== 'string' || message.text.length > 8000) throw new Error('The voice transcript is invalid.');
        handlers.text(message.text);
        break;
      case 'knowledge.sources':
        if (!Array.isArray(message.citations)) throw new Error('The voice source references are invalid.');
        handlers.sources(message.citations as Citation[]);
        break;
      case 'case.proposal':
        if (!record(message.proposal) || typeof message.proposal.id !== 'string') throw new Error('The voice case proposal is invalid.');
        handlers.proposal(message.proposal as unknown as CaseProposal);
        break;
      case 'voice.error':
        throw new Error(typeof message.detail === 'string' ? message.detail : 'The real voice provider failed.');
      default:
        throw new Error('The voice relay returned an unknown event. Verify backend/frontend compatibility.');
    }
  }

  return {
    async start(consent: boolean) {
      if (!consent) throw new Error('Microphone and audio-processing consent is required.');
      if (current) return;
      if (!navigator.mediaDevices?.getUserMedia || typeof AudioContext === 'undefined' || typeof AudioWorkletNode === 'undefined') {
        handlers.state('error', 'Voice is unavailable in this browser. Use a secure context with microphone and AudioWorklet support, or use text support.');
        return;
      }
      const run: Run = {
        stopped: false, ready: false, context: null, stream: null, source: null, capture: null,
        mute: null, socket: null, ticket: null, revoked: false, timers: [], playback: new Set(), playbackAt: 0,
      };
      current = run;
      handlers.state('connecting', 'Requesting microphone permission, then a short-lived voice lease…');
      try {
        const context = new AudioContext({ sampleRate: 24_000 });
        run.context = context;
        await context.resume();
        if (run.stopped) return;
        const stream = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, sampleRate: { ideal: 24_000 }, echoCancellation: true, noiseSuppression: true },
          video: false,
        });
        if (run.stopped) { stream.getTracks().forEach(track => track.stop()); return; }
        run.stream = stream;
        for (const track of stream.getAudioTracks()) track.onended = () => fail(run, new Error('Microphone access ended. Start a new session when ready.'));
        await context.audioWorklet.addModule(new URL('pcm-capture.js', appBase).href);
        if (run.stopped) return;
        const ticket = await api.request<VoiceTicket>('v1/voice/sessions', 'POST', { consent: true });
        run.ticket = ticket;
        if (run.stopped) { await revoke(run); return; }
        const remaining = Math.min(Date.parse(ticket.sessionExpiresAt) - Date.now(), sessionSeconds * 1000);
        if (!Number.isFinite(remaining) || remaining <= 0 || Date.parse(ticket.ticketExpiresAt) <= Date.now()) {
          throw new Error('The voice lease expired before connection. Start a new session.');
        }
        run.timers.push(window.setTimeout(() => {
          release(run);
          handlers.state('stopped', 'The bounded voice session has ended. The microphone is off.');
        }, remaining));
        const socket = new WebSocket(voiceSocketUrl(ticket), [ticket.protocol, `harbor.ticket.${ticket.ticket}`]);
        run.socket = socket;
        run.timers.push(window.setTimeout(() => {
          if (!run.ready) fail(run, new Error('Voice connection timed out. Check APIM WebSocket routing, approved Origin, and the real provider.'));
        }, 20_000));
        socket.onopen = () => {
          if (run.stopped) return;
          try {
            if (socket.protocol !== 'harbor.voice.v1') throw new Error('The voice relay did not negotiate the approved protocol.');
            const capture = new AudioWorkletNode(context, 'harbor-pcm-capture', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
            run.capture = capture;
            run.source = context.createMediaStreamSource(stream);
            run.mute = context.createGain();
            run.mute.gain.value = 0;
            run.source.connect(capture); capture.connect(run.mute); run.mute.connect(context.destination);
            capture.port.onmessage = (event: MessageEvent<unknown>) => {
              if (run.stopped || !run.ready || socket.readyState !== WebSocket.OPEN) return;
              try {
                if (!(event.data instanceof ArrayBuffer) || event.data.byteLength === 0 || event.data.byteLength % 2 !== 0 || event.data.byteLength > 4800) {
                  throw new Error('Microphone produced an invalid PCM16 chunk.');
                }
                if (socket.bufferedAmount > 48_000) throw new Error('Voice upload cannot keep up with the microphone. Check your connection.');
                socket.send(JSON.stringify({ type: 'audio.append', audio: pcmBase64(event.data) }));
              } catch (error) {
                fail(run, error);
              }
            };
          } catch (error) {
            fail(run, error);
          }
        };
        socket.onmessage = event => {
          if (run.stopped) return;
          try { receive(run, event.data as unknown); }
          catch (error) { fail(run, error); }
        };
        socket.onerror = () => fail(run, new Error('Voice connection failed. Check APIM routing, the approved Origin, your lease, and provider availability. No direct provider fallback is used.'));
        socket.onclose = event => {
          if (run.stopped) return;
          release(run);
          handlers.state(event.code === 1000 ? 'stopped' : 'error',
            `The voice relay closed${event.reason ? ` (${event.reason})` : ''}. Microphone off.${event.code !== 1000 ? ' Check provider and gateway availability before retrying.' : ''}`);
        };
      } catch (error) {
        fail(run, error);
      }
    },
    stop() {
      if (current) release(current);
      handlers.state('stopped', 'Voice stopped. Microphone and playback are off.');
    },
    interrupt() {
      const run = current;
      if (!run || run.stopped) return;
      stopPlayback(run);
      if (run.socket?.readyState === WebSocket.OPEN) run.socket.send(JSON.stringify({ type: 'response.interrupt' }));
    },
  };
}
