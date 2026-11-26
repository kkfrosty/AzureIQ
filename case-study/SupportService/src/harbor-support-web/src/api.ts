import type { RuntimeConfig } from './contracts';

export const appBase = new URL('./', document.baseURI);

export function errorMessage(error: unknown): string {
  return error instanceof Error || error instanceof DOMException ? error.message : 'An unexpected error occurred. Please try again.';
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

export interface Api {
  request<T>(path: string, method?: 'GET' | 'POST' | 'DELETE', body?: unknown, headers?: Record<string, string>): Promise<T>;
}

async function requestJson<T>(path: string, token?: string, method = 'GET', body?: unknown, headers?: Record<string, string>): Promise<T> {
  const url = new URL(path, appBase);
  if (url.origin !== appBase.origin || !url.pathname.startsWith(`${appBase.pathname}v1/`)) {
    throw new Error('The requested API path is outside the support application.');
  }
  const requestHeaders = new Headers(headers);
  requestHeaders.set('Accept', 'application/json');
  if (token) requestHeaders.set('Authorization', `Bearer ${token}`);
  if (body !== undefined) requestHeaders.set('Content-Type', 'application/json');
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: requestHeaders,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      signal: AbortSignal.timeout(30_000),
    });
  } catch (error) {
    throw new Error(`Support API could not be reached. Check the connection and APIM configuration. ${errorMessage(error)}`);
  }
  if (!response.ok) {
    let problem: unknown;
    try {
      problem = await response.json();
    } catch {
      throw new Error(`Support API returned HTTP ${response.status} without a readable error.`);
    }
    const detail = isRecord(problem) && typeof problem.detail === 'string' ? problem.detail : `Request failed (HTTP ${response.status}).`;
    const trace = isRecord(problem) && typeof problem.traceId === 'string' ? ` Reference: ${problem.traceId}.` : '';
    throw Object.assign(new Error(`${response.status === 401 ? 'Please sign in again. ' : ''}${detail}${trace}`), { status: response.status });
  }
  if (response.status === 204) return undefined as T;
  try {
    return await response.json() as T;
  } catch {
    throw new Error('Support API returned invalid JSON. Verify the runtime endpoint, not an HTML fallback.');
  }
}

export async function loadConfig(): Promise<RuntimeConfig> {
  const value = await requestJson<unknown>('v1/config');
  if (!isRecord(value) || typeof value.companyName !== 'string' || typeof value.fictionalDemo !== 'boolean' ||
      !isRecord(value.auth) || typeof value.auth.configured !== 'boolean' ||
      typeof value.auth.redirectPath !== 'string' || !isRecord(value.capabilities) ||
      !['cases', 'knowledge', 'text', 'voice'].every(key => typeof value.capabilities === 'object' &&
        value.capabilities !== null && typeof (value.capabilities as Record<string, unknown>)[key] === 'boolean') ||
      typeof value.capabilities.providerMode !== 'string' ||
      typeof value.textMaxChars !== 'number' || value.textMaxChars < 1 || value.textMaxChars > 2000 ||
      typeof value.voiceSessionSeconds !== 'number' || value.voiceSessionSeconds < 1 || value.voiceSessionSeconds > 300) {
    throw new Error('Runtime configuration is invalid. The support administrator must configure /v1/config.');
  }
  return value as unknown as RuntimeConfig;
}

export function createApi(getToken: () => Promise<string>): Api {
  return {
    async request<T>(path: string, method = 'GET', body?: unknown, headers?: Record<string, string>): Promise<T> {
      const token = await getToken();
      if (!token) throw new Error('Sign in before contacting support.');
      // Only the customer token goes to APIM. Gateway and model credentials never enter this app.
      return requestJson<T>(path, token, method, body, headers);
    },
  };
}
