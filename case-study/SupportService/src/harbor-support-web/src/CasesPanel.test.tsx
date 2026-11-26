import { describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { CasesPanel } from './CasesPanel';
import { createApi } from './api';
import type { CaseProposal, SupportCase } from './contracts';

const services = [{ serviceId: 'email', name: 'Email support', description: 'Email', topics: ['Email'] }];
const proposal: CaseProposal = {
  id: 'proposal1', serviceId: 'email', subject: 'Mailbox unavailable', summary: 'Cannot send business email.',
  impact: 'high', proposalHash: 'a'.repeat(64), createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 600000).toISOString(),
};
const supportCase: SupportCase = {
  id: 'case1', serviceId: 'email', subject: proposal.subject, summary: proposal.summary, impact: 'high', state: 'open', createdAt: new Date().toISOString(), synthetic: true,
};

function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}

async function prepare(user: ReturnType<typeof userEvent.setup>) {
  await user.type(screen.getByRole('textbox', { name: 'Subject' }), proposal.subject);
  await user.type(screen.getByRole('textbox', { name: 'What happened?' }), proposal.summary);
  await user.selectOptions(screen.getByRole('combobox', { name: 'Business impact' }), 'high');
  await user.click(screen.getByRole('button', { name: 'Prepare case for review' }));
  await screen.findByRole('heading', { name: 'Review case proposal' });
}

describe('caller-owned case confirmation', () => {
  it('requires prepare, a separate explicit confirmation, then commit; retries the exact same GUID and grant', async () => {
    let commits = 0;
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === '/v1/cases') return json([]);
      if (path === '/v1/case-proposals') return json(proposal, 201);
      if (path.endsWith('/confirmation')) return json({ proposalId: proposal.id, proposalHash: proposal.proposalHash, grant: 'test-grant', expiresAt: proposal.expiresAt });
      if (path.endsWith('/commit')) {
        expect(init?.method).toBe('POST');
        return ++commits === 1 ? json({ detail: 'Transient commit error.' }, 503) : json({ case: supportCase, replayed: true });
      }
      throw new Error(`Unexpected test path ${path}`);
    });
    vi.stubGlobal('fetch', fetch);
    const user = userEvent.setup();
    render(<CasesPanel api={createApi(async () => 'customer')} services={services} enabled suggestedProposalId={null} />);
    await prepare(user);
    expect(fetch.mock.calls.filter(([input]) => String(input).includes('/confirmation'))).toHaveLength(0);
    expect(fetch.mock.calls.filter(([input]) => String(input).includes('/commit'))).toHaveLength(0);
    expect(screen.getByText(proposal.summary)).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'I confirm: create this case' }));
    const commit = await screen.findByRole('button', { name: 'Commit confirmed case' });
    expect(commits).toBe(0);
    const confirmation = fetch.mock.calls.find(([input]) => String(input).endsWith('/confirmation'));
    expect(JSON.parse(String(confirmation?.[1]?.body))).toEqual({ proposalHash: proposal.proposalHash, intent: 'create_case' });
    await user.click(commit);
    expect(await screen.findByRole('alert')).toHaveTextContent('The outcome is not confirmed');
    await user.click(commit);
    expect(await screen.findByText(/Original case recovered/)).toBeInTheDocument();
    const commitCalls = fetch.mock.calls.filter(([input]) => String(input).endsWith('/commit'));
    expect(commitCalls).toHaveLength(2);
    const first = commitCalls[0]?.[1];
    const second = commitCalls[1]?.[1];
    const key = new Headers(first?.headers).get('Idempotency-Key');
    expect(key).toMatch(/^[a-f0-9-]{36}$/);
    expect(new Headers(second?.headers).get('Idempotency-Key')).toBe(key);
    expect(second?.body).toBe(first?.body);
    expect(JSON.parse(String(first?.body))).toEqual({ proposalHash: proposal.proposalHash, confirmationGrant: 'test-grant' });
  });

  it('does not blindly repeat confirmation when its response is lost', async () => {
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === '/v1/cases') return json([]);
      if (path === '/v1/case-proposals') return json(proposal, 201);
      if (path.endsWith('/confirmation')) throw new TypeError('Connection lost');
      throw new Error(`Unexpected request ${path}`);
    });
    vi.stubGlobal('fetch', fetch);
    const user = userEvent.setup();
    render(<CasesPanel api={createApi(async () => 'customer')} services={services} enabled suggestedProposalId={null} />);
    await prepare(user);
    await user.click(screen.getByRole('button', { name: 'I confirm: create this case' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('Do not repeat confirmation blindly');
    expect(screen.getByRole('button', { name: 'I confirm: create this case' })).toBeDisabled();
    expect(screen.queryByRole('button', { name: 'Commit confirmed case' })).not.toBeInTheDocument();
    expect(fetch.mock.calls.filter(([input]) => String(input).endsWith('/commit'))).toHaveLength(0);
  });

  it('loads a voice proposal for review without granting confirmation and disables expired proposals', async () => {
    const fetch = vi.fn(async (input: RequestInfo | URL) =>
      String(input).endsWith('/v1/cases') ? json([]) : json({ ...proposal, expiresAt: '2020-01-01T00:00:00Z' }));
    vi.stubGlobal('fetch', fetch);
    const user = userEvent.setup();
    render(<CasesPanel api={createApi(async () => 'customer')} services={services} enabled suggestedProposalId="proposal1" />);
    await user.click(screen.getByRole('button', { name: 'Review voice-prepared draft' }));
    await screen.findByRole('heading', { name: 'Review case proposal' });
    await waitFor(() => expect(screen.getByRole('button', { name: 'I confirm: create this case' })).toBeDisabled());
    expect(fetch.mock.calls.every(([input]) => !String(input).endsWith('/confirmation'))).toBe(true);
    expect(screen.getByText(/This proposal has expired/)).toBeInTheDocument();
  });
});
