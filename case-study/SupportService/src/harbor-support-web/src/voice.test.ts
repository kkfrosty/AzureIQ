import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import { createVoiceController, pcmBase64, voiceSocketUrl } from './voice';
import { createApi } from './api';
import type { VoiceTicket } from './contracts';
import type { VoiceState } from './voice';

const sockets: FakeSocket[] = [];
const captures: FakeCapture[] = [];
const playback = { connect: vi.fn(), disconnect: vi.fn(), start: vi.fn(), stop: vi.fn(), buffer: null as unknown, onended: null as (() => void) | null };
const track = { stop: vi.fn(), onended: null as (() => void) | null };
const stream = { getTracks: () => [track], getAudioTracks: () => [track] };
const close = vi.fn(async () => {});
const sessionId = '39d55f1b3c074fe2a678771f0454bf1b';

class FakeContext {
  state = 'running';
  currentTime = 0;
  destination = {};
  audioWorklet = { addModule: vi.fn(async () => {}) };
  resume = vi.fn(async () => {});
  close = close;
  createMediaStreamSource = vi.fn(() => ({ connect: vi.fn(), disconnect: vi.fn() }));
  createGain = vi.fn(() => ({ gain: { value: 1 }, connect: vi.fn(), disconnect: vi.fn() }));
  createBuffer = vi.fn((_channels: number, length: number, rate: number) => ({
    duration: length / rate, getChannelData: () => new Float32Array(length),
  }));
  createBufferSource = vi.fn(() => playback);
}

class FakeCapture {
  port = { onmessage: null as ((event: MessageEvent<unknown>) => void) | null, close: vi.fn() };
  connect = vi.fn();
  disconnect = vi.fn();
  constructor() { captures.push(this); }
}

class FakeSocket {
  static OPEN = 1;
  static CONNECTING = 0;
  readyState = 0;
  bufferedAmount = 0;
  protocol = 'harbor.voice.v1';
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  send = vi.fn();
  close = vi.fn(() => { this.readyState = 3; });
  constructor(readonly url: URL, readonly protocols: string[]) { sockets.push(this); }
  open() { this.readyState = 1; this.onopen?.(new Event('open')); }
  receive(value: unknown) { this.onmessage?.(new MessageEvent('message', { data: JSON.stringify(value) })); }
}

function ticket(): VoiceTicket {
  return {
    sessionId, ticket: 'a'.repeat(43), ticketExpiresAt: new Date(Date.now() + 30000).toISOString(),
    sessionExpiresAt: new Date(Date.now() + 300000).toISOString(), webSocketUrl: `/voice?sessionId=${sessionId}`, protocol: 'harbor.voice.v1', provider: 'test-double',
  };
}

function harness(sessionSeconds = 300) {
  const lease = ticket();
  const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer caller-test-token');
    if (init?.method === 'DELETE') return new Response(null, { status: 204 });
    expect(new URL(String(input)).pathname).toBe('/v1/voice/sessions');
    expect(init?.body).toBe(JSON.stringify({ consent: true }));
    return new Response(JSON.stringify(lease), { status: 200 });
  });
  vi.stubGlobal('fetch', fetch);
  const handlers = {
    state: vi.fn<(state: VoiceState, detail: string) => void>(),
    warning: vi.fn(), text: vi.fn(), sources: vi.fn(), proposal: vi.fn(),
  };
  return { controller: createVoiceController(createApi(async () => 'caller-test-token'), handlers, sessionSeconds), handlers, fetch, lease };
}

beforeEach(() => {
  sockets.length = 0; captures.length = 0;
  track.stop.mockClear(); close.mockClear();
  playback.start.mockClear(); playback.stop.mockClear();
  vi.stubGlobal('AudioContext', FakeContext);
  vi.stubGlobal('AudioWorkletNode', FakeCapture);
  vi.stubGlobal('WebSocket', FakeSocket);
  Object.defineProperty(navigator, 'mediaDevices', {
    configurable: true, value: { getUserMedia: vi.fn(async () => stream) },
  });
});

afterEach(() => { vi.useRealTimers(); });

describe('backend-controlled microphone and voice lease', () => {
  it('refuses to capture or reserve a lease without consent', async () => {
    const { controller, fetch } = harness();
    await expect(controller.start(false)).rejects.toThrow('consent is required');
    expect(navigator.mediaDevices.getUserMedia).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
  });

  it('uses the single-use ticket only in approved subprotocols; captures PCM only after readiness; interrupts and stops', async () => {
    const { controller, handlers, fetch } = harness();
    await controller.start(true);
    const socket = sockets[0];
    expect(socket).toBeDefined();
    if (!socket) throw new Error('Expected socket');
    expect(socket.url.href).toBe(`ws://localhost:3000/voice?sessionId=${sessionId}`);
    expect([...socket.url.searchParams]).toEqual([['sessionId', sessionId]]);
    expect(socket.url.href).not.toContain('harbor.ticket');
    expect(socket.protocols).toEqual(['harbor.voice.v1', `harbor.ticket.${'a'.repeat(43)}`]);
    socket.open();
    const capture = captures[0];
    if (!capture) throw new Error('Expected capture worklet');
    const audio = new Int16Array([0, 1000, -1000]).buffer;
    capture.port.onmessage?.(new MessageEvent('message', { data: audio }));
    expect(socket.send).not.toHaveBeenCalled();
    socket.receive({ type: 'session.ready', provider: 'test-double', sampleRate: 24000 });
    capture.port.onmessage?.(new MessageEvent('message', { data: audio }));
    expect(JSON.parse(String(socket.send.mock.calls[0]?.[0]))).toEqual({ type: 'audio.append', audio: pcmBase64(audio) });
    socket.receive({ type: 'assistant.text', text: 'Grounded voice answer.' });
    expect(handlers.text).toHaveBeenCalledWith('Grounded voice answer.');
    socket.receive({ type: 'knowledge.sources', citations: [] });
    expect(handlers.sources).toHaveBeenCalledWith([]);
    socket.receive({ type: 'audio.delta', audio: pcmBase64(audio) });
    expect(playback.start).toHaveBeenCalled();
    controller.interrupt();
    expect(playback.stop).toHaveBeenCalled();
    expect(socket.send).toHaveBeenCalledWith(JSON.stringify({ type: 'response.interrupt' }));
    controller.stop();
    await Promise.resolve(); await Promise.resolve();
    expect(track.stop).toHaveBeenCalledOnce();
    expect(close).toHaveBeenCalledOnce();
    expect(socket.close).toHaveBeenCalled();
    expect(fetch.mock.calls.some(([, init]) => init?.method === 'DELETE')).toBe(true);
    expect(handlers.state).toHaveBeenLastCalledWith('stopped', expect.stringContaining('Microphone and playback are off'));
  });

  it('stops microphone and playback immediately on a provider error', async () => {
    const { controller, handlers } = harness();
    await controller.start(true);
    const socket = sockets[0];
    if (!socket) throw new Error('Expected socket');
    socket.open();
    socket.receive({ type: 'voice.error', code: 'voice_provider_failed', detail: 'The real voice provider failed.' });
    expect(handlers.state).toHaveBeenLastCalledWith('error', 'The real voice provider failed.');
    expect(track.stop).toHaveBeenCalledOnce();
    expect(socket.close).toHaveBeenCalled();
  });

  it('enforces the local session duration even if the relay never closes', async () => {
    vi.useFakeTimers();
    const { controller, handlers } = harness(2);
    await controller.start(true);
    sockets[0]?.open();
    sockets[0]?.receive({ type: 'session.ready', sampleRate: 24000 });
    await vi.advanceTimersByTimeAsync(2000);
    expect(track.stop).toHaveBeenCalledOnce();
    expect(handlers.state).toHaveBeenLastCalledWith('stopped', expect.stringContaining('bounded voice session has ended'));
  });

  it('stops a late microphone grant after cancellation without reserving or connecting', async () => {
    let permit: ((value: typeof stream) => void) | undefined;
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true, value: { getUserMedia: vi.fn(() => new Promise<typeof stream>(resolve => { permit = resolve; })) },
    });
    const { controller, fetch } = harness();
    const starting = controller.start(true);
    await Promise.resolve();
    controller.stop();
    permit?.(stream);
    await starting;
    expect(track.stop).toHaveBeenCalledOnce();
    expect(fetch).not.toHaveBeenCalled();
    expect(sockets).toHaveLength(0);
  });

  it('consumes the returned fixed socket URL with only a non-secret UUID query', () => {
    const lease = ticket();
    expect(voiceSocketUrl(lease).href).toBe(`ws://localhost:3000/voice?sessionId=${sessionId}`);
    expect(voiceSocketUrl({ ...lease, webSocketUrl: `ws://localhost:3000/voice?sessionId=${sessionId}` }).href)
      .toBe(`ws://localhost:3000/voice?sessionId=${sessionId}`);
  });

  it('accepts the returned APIM /support/ URL without constructing a session-specific path', async () => {
    const base = document.createElement('base');
    base.href = 'http://localhost:3000/support/';
    document.head.prepend(base);
    vi.resetModules();
    try {
      const { voiceSocketUrl: resolveSocket } = await import('./voice');
      const lease = { ...ticket(), webSocketUrl: `/support/voice?sessionId=${sessionId}` };
      expect(resolveSocket(lease).href).toBe(`ws://localhost:3000/support/voice?sessionId=${sessionId}`);
      expect(() => resolveSocket({ ...lease, webSocketUrl: `/voice/socket?sessionId=${sessionId}` }))
        .toThrow('invalid fixed voice URL');
    } finally {
      base.remove();
      vi.resetModules();
    }
  });

  it.each([
    `https://other.invalid/voice?sessionId=${sessionId}`,
    `/voice?sessionId=${sessionId}&ticket=forbidden`,
    `/voice?sessionId=${sessionId}&token=forbidden`,
    `/voice?sessionId=${sessionId}&sessionId=${sessionId}`,
    '/voice',
    '/voice?sessionId=not-a-uuid',
    '/voice?sessionId=00000000000000000000000000000000',
    `/voice/${sessionId}`,
    `/voice/socket?sessionId=${sessionId}`,
    `/support/voice?sessionId=${sessionId}`,
  ])('rejects unsafe or mismatched returned socket URL: %s', webSocketUrl => {
    expect(() => voiceSocketUrl({ ...ticket(), webSocketUrl })).toThrow('invalid fixed voice URL');
  });
});
