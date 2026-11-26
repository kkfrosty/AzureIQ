import { expect, test } from '@playwright/test';

const unconfigured = {
  companyName: 'Harbor IT Services', fictionalDemo: true,
  auth: { configured: false, authority: null, clientId: null, scope: null, redirectPath: './' },
  capabilities: { cases: false, knowledge: false, text: false, voice: false, providerMode: 'real-providers' },
  textMaxChars: 2000, voiceSessionSeconds: 300,
};

test('real browser loads under /support/, detects theme before React, and exposes missing runtime auth', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/support/v1/config', route => route.fulfill({ json: unconfigured }));
  await page.goto('/support/?scoutTheme=dark');
  await expect(page.getByRole('heading', { name: 'Your IT, in good hands.' })).toBeVisible();
  await expect(page.getByRole('alert')).toContainText('Microsoft Entra sign-in is not configured');
  await expect(page.getByRole('button', { name: 'Sign in with Microsoft' })).toBeDisabled();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  expect(await page.locator('body').evaluate(element => getComputedStyle(element).fontFamily)).toContain('Segoe UI');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Skip to support' })).toBeFocused();
  expect(errors).toEqual([]);
});

test('mobile layout keeps actionable API errors visible without overflowing the viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.route('**/support/v1/config', route => route.fulfill({
    status: 503, json: { detail: 'Runtime configuration is unavailable.', traceId: 'browser-test' },
  }));
  await page.goto('/support/');
  await expect(page.getByRole('alert')).toContainText('Runtime configuration is unavailable. Reference: browser-test.');
  await expect(page.getByRole('button', { name: 'Retry configuration' })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  const overflowing = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
  expect(overflowing).toBe(false);
});
