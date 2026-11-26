export interface RuntimeConfig {
  companyName: string;
  fictionalDemo: boolean;
  auth: {
    configured: boolean;
    authority: string | null;
    clientId: string | null;
    scope: string | null;
    redirectPath: string;
  };
  capabilities: { cases: boolean; knowledge: boolean; text: boolean; voice: boolean; providerMode: string };
  textMaxChars: number;
  voiceSessionSeconds: number;
}

export interface Company {
  companyId: string;
  name: string;
  description: string;
  synthetic: boolean;
  privacyNotice: string;
}

export interface Service {
  serviceId: string;
  name: string;
  description: string;
  topics: string[];
}

export interface ServiceStatus {
  serviceId: string;
  state: string;
  description: string;
  updatedAt: string;
  synthetic: boolean;
}

export interface Citation {
  docId: string;
  title: string;
  sourceRef: string;
  docVersion: string;
  contentHash: string;
  updatedAt: string;
}

export interface ChatAnswer {
  message: string;
  citations: Citation[];
  provider: string;
  syntheticCompany: boolean;
}

export interface CaseDraft {
  serviceId: string;
  subject: string;
  summary: string;
  impact: 'low' | 'medium' | 'high';
}

export interface CaseProposal {
  id: string;
  serviceId: string;
  subject: string;
  summary: string;
  impact: string;
  proposalHash: string;
  createdAt: string;
  expiresAt: string;
}

export interface ConfirmationGrant {
  proposalId: string;
  proposalHash: string;
  grant: string;
  expiresAt: string;
}

export interface SupportCase {
  id: string;
  serviceId: string;
  subject: string;
  summary: string;
  impact: string;
  state: string;
  createdAt: string;
  synthetic: boolean;
}

export interface CommitResult {
  case: SupportCase;
  replayed: boolean;
}

export interface VoiceTicket {
  sessionId: string;
  ticket: string;
  ticketExpiresAt: string;
  sessionExpiresAt: string;
  webSocketUrl: string;
  protocol: string;
  provider: string;
}
