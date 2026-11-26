import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { App } from './App';
import type { RuntimeConfig } from './contracts';

const auth = vi.hoisted(() => ({
  name: null as string | null,
  login: vi.fn<() => Promise<void>>(),
  logout: vi.fn<() => Promise<void>>(),
  token: vi.fn<() => Promise<string>>(),
}));

vi.mock('./auth', () => ({
  createIdentity: vi.fn(async (config: RuntimeConfig['auth']) => {
    if (!config.configured) throw new Error('Microsoft Entra sign-in is not configured.');
    return { accountName: () => auth.name, login: auth.login, logout: auth.logout, token: auth.token };
  }),
}));

const config: RuntimeConfig = {
  companyName: 'Harbor IT Services', fictionalDemo: true,
  auth: { configured: true, authority: 'https://login.microsoftonline.com/test/v2.0', clientId: 'test-client', scope: 'api://support/Support.Access', redirectPath: './' },
  capabilities: { cases: true, knowledge: true, text: true, voice: true, providerMode: 'real-providers' },
  textMaxChars: 2000, voiceSessionSeconds: 300,
};

function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}

function backend(runtime: RuntimeConfig = config) {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const path = new URL(String(input)).pathname;
    if (path === '/v1/config') {
      expect(new Headers(init?.headers).has('Authorization')).toBe(false);
      return json(runtime);
    }
    expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer customer-test-token');
    expect(new Headers(init?.headers).has('X-Harbor-Caller-Authorization')).toBe(false);
    switch (path) {
      case '/v1/customer': return json({ companyId: 'harbor-it-services', authorizationExpiresAt: new Date(Date.now() + 3600000).toISOString() });
      case '/v1/company': return json({ companyId: 'harbor-it-services', name: 'Harbor IT Services', description: 'Small business IT support.', synthetic: true, privacyNotice: 'Do not share secrets.' });
      case '/v1/services': return json([{ serviceId: 'email', name: 'Email & productivity', description: 'Work securely.', topics: ['Outlook', 'Teams'] }]);
      case '/v1/status/email': return json({ serviceId: 'email', state: 'operational', description: 'Synthetic email status.', updatedAt: new Date().toISOString(), synthetic: true });
      case '/v1/cases': return json([]);
      case '/v1/chat/messages': return json({
        message: 'Use the company email setup guide.', provider: 'real-provider-test-double', syntheticCompany: true,
        citations: [{ docId: 'email-guide', title: 'Email setup', sourceRef: 'harbor://knowledge/email', docVersion: '1', contentHash: 'abc', updatedAt: new Date().toISOString() }],
      });
      default: throw new Error(`Unexpected test route ${path}`);
    }
  });
}

beforeEach(() => {
  auth.name = null;
  auth.login.mockReset().mockImplementation(async () => { auth.name = 'Alex at Harbor'; });
  auth.logout.mockReset().mockImplementation(async () => { auth.name = null; });
  auth.token.mockReset().mockResolvedValue('customer-test-token');
});

describe('secure support application', () => {
  it('reports an invalid runtime configuration and allows an explicit retry', async () => {
    const fetch = vi.fn().mockResolvedValueOnce(json({})).mockImplementation(backend());
    vi.stubGlobal('fetch', fetch);
    const user = userEvent.setup();
    render(<App />);
    expect(await screen.findByRole('alert')).toHaveTextContent('Runtime configuration is invalid');
    expect(screen.getByRole('button', { name: 'Sign in with Microsoft' })).toBeDisabled();
    await user.click(screen.getByRole('button', { name: 'Retry configuration' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Sign in with Microsoft' })).toBeEnabled());
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('does not contact customer APIs until sign-in succeeds and surfaces popup failures', async () => {
    const fetch = backend();
    vi.stubGlobal('fetch', fetch);
    auth.login.mockRejectedValueOnce(new Error('The sign-in popup was blocked.'));
    const user = userEvent.setup();
    render(<App />);
    const login = await screen.findByRole('button', { name: 'Sign in with Microsoft' });
    await waitFor(() => expect(login).toBeEnabled());
    expect(fetch).toHaveBeenCalledTimes(1);
    await user.click(login);
    expect(await screen.findByRole('alert')).toHaveTextContent('popup was blocked');
    expect(fetch).toHaveBeenCalledTimes(1);
    await user.click(login);
    expect(await screen.findByText('Alex at Harbor')).toBeInTheDocument();
    expect(await screen.findByText('Synthetic email status.')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Sign out' }));
    expect(await screen.findByRole('heading', { name: 'Welcome to Harbor' })).toBeInTheDocument();
  });

  it('shows grounded text citations and sends the selected service through the caller-only API', async () => {
    const fetch = backend();
    vi.stubGlobal('fetch', fetch);
    auth.name = 'Alex at Harbor';
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText('Synthetic email status.');
    await user.type(screen.getByRole('textbox', { name: 'Your question' }), 'How do I set up email?');
    await user.click(screen.getByRole('button', { name: 'Send question' }));
    expect(await screen.findByText('Use the company email setup guide.')).toBeInTheDocument();
    expect(screen.getByText('Email setup')).toBeInTheDocument();
    expect(screen.getByText(/harbor:\/\/knowledge\/email/)).toBeInTheDocument();
    const call = fetch.mock.calls.find(([input]) => new URL(String(input)).pathname.endsWith('/chat/messages'));
    expect(call?.[1]?.body).toBe(JSON.stringify({ serviceId: 'email', message: 'How do I set up email?' }));
  });

  it('makes missing providers explicit without presenting a fake response or voice success', async () => {
    vi.stubGlobal('fetch', backend({ ...config, capabilities: { ...config.capabilities, text: false, voice: false } }));
    auth.name = 'Alex at Harbor';
    render(<App />);
    expect(await screen.findByText(/Grounded text support is unavailable/)).toBeInTheDocument();
    expect(screen.getByText(/Voice support is unavailable/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Send question' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Start voice session' })).not.toBeInTheDocument();
  });

  it('shows backend provider and trace errors and retains the unsent question', async () => {
    const routes = backend();
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) =>
      new URL(String(input)).pathname.endsWith('/chat/messages') ?
        json({ detail: 'The real provider is unavailable.', traceId: 'trace-test' }, 503) : routes(input, init)));
    auth.name = 'Alex at Harbor';
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText('Synthetic email status.');
    const input = screen.getByRole('textbox', { name: 'Your question' });
    await user.type(input, 'Email is not connecting.');
    await user.click(screen.getByRole('button', { name: 'Send question' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('The real provider is unavailable. Reference: trace-test.');
    expect(input).toHaveValue('Email is not connecting.');
    expect(screen.queryByText('Harbor assistant')).not.toBeInTheDocument();
  });

  it('requires microphone consent before enabling voice and reports browser permission denial', async () => {
    vi.stubGlobal('fetch', backend());
    auth.name = 'Alex at Harbor';
    vi.stubGlobal('AudioContext', class {
      state = 'running';
      resume = vi.fn(async () => {});
      close = vi.fn(async () => {});
    });
    vi.stubGlobal('AudioWorkletNode', class {});
    const getUserMedia = vi.fn().mockRejectedValue(new DOMException('Permission denied', 'NotAllowedError'));
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } });
    const user = userEvent.setup();
    render(<App />);
    const start = await screen.findByRole('button', { name: 'Start voice session' });
    expect(start).toBeDisabled();
    expect(getUserMedia).not.toHaveBeenCalled();
    await user.click(screen.getByRole('checkbox', { name: /I consent to microphone/ }));
    await user.click(start);
    expect(await screen.findByRole('alert')).toHaveTextContent('Permission denied');
    expect(screen.getByRole('button', { name: 'Stop voice' })).toBeDisabled();
    expect(getUserMedia).toHaveBeenCalledTimes(1);
  });
});
