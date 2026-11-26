import { InteractionRequiredAuthError, PublicClientApplication } from '@azure/msal-browser';
import type { AccountInfo } from '@azure/msal-browser';
import { appBase } from './api';
import type { RuntimeConfig } from './contracts';

export interface Identity {
  accountName(): string | null;
  login(): Promise<void>;
  logout(): Promise<void>;
  token(): Promise<string>;
}

export async function createIdentity(config: RuntimeConfig['auth']): Promise<Identity> {
  if (!config.configured || !config.authority || !config.clientId || !config.scope) {
    throw new Error('Microsoft Entra sign-in is not configured. Contact the support administrator.');
  }
  const authority = new URL(config.authority);
  const redirect = new URL(config.redirectPath, appBase);
  if (authority.protocol !== 'https:' || authority.hostname !== 'login.microsoftonline.com' ||
      redirect.origin !== appBase.origin || redirect.pathname !== appBase.pathname) {
    throw new Error('The runtime Entra authority or redirect path is not approved for this support application.');
  }
  const scopes = [config.scope];
  const msal = new PublicClientApplication({
    auth: { clientId: config.clientId, authority: config.authority, redirectUri: redirect.href },
    cache: { cacheLocation: 'sessionStorage' },
    system: { loggerOptions: { piiLoggingEnabled: false } },
  });
  await msal.initialize();
  const redirected = await msal.handleRedirectPromise();
  let account: AccountInfo | null = redirected?.account ?? msal.getActiveAccount();
  const accounts = msal.getAllAccounts();
  if (!account && accounts.length === 1) account = accounts[0] ?? null;
  if (account) msal.setActiveAccount(account);
  return {
    accountName: () => account?.name ?? account?.username ?? null,
    async login() {
      const result = await msal.loginPopup({ scopes, prompt: 'select_account' });
      if (!result.account) throw new Error('Sign-in did not return an account.');
      account = result.account;
      msal.setActiveAccount(account);
    },
    async logout() {
      if (account) await msal.logoutPopup({ account, postLogoutRedirectUri: redirect.href, mainWindowRedirectUri: redirect.href });
      account = null;
    },
    async token() {
      if (!account) throw new Error('Sign in to your Harbor customer account first.');
      try {
        const result = await msal.acquireTokenSilent({ account, scopes });
        return result.accessToken;
      } catch (error) {
        if (error instanceof InteractionRequiredAuthError) throw new Error('Your sign-in needs attention. Sign out and sign in again.');
        throw error;
      }
    },
  };
}
