namespace Harbor.Support.Api;

public sealed record CompanyInfo(string CompanyId, string Name, string Description, bool Synthetic, string PrivacyNotice);
public sealed record ServiceInfo(string ServiceId, string Name, string Description, IReadOnlyList<string> Topics);
public sealed record SyntheticStatus(string ServiceId, string State, string Description, DateTimeOffset UpdatedAt, bool Synthetic);
public sealed record KnowledgeDocument(
    string DocId, string CompanyId, string ServiceId, string Title, string Content,
    string SourceRef, string DocVersion, string ContentHash, DateTimeOffset UpdatedAt);
public sealed record Citation(
    string DocId, string Title, string SourceRef, string DocVersion, string ContentHash, DateTimeOffset UpdatedAt);
public sealed record KnowledgeResult(string CompanyId, IReadOnlyList<KnowledgeDocument> Documents, IReadOnlyList<Citation> Citations);
public sealed record CustomerContext(string CompanyId, string OwnerKey, DateTimeOffset AuthorizationExpiresAt);
public sealed record PrepareCaseRequest(string ServiceId, string Subject, string Summary, string Impact);
public sealed record CaseProposal(
    string Id, string ServiceId, string Subject, string Summary, string Impact,
    string ProposalHash, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt);
public sealed record StoredProposal(
    CaseProposal Proposal, string? GrantHash, DateTimeOffset? ConfirmedAt, bool Consumed, string Version);
public sealed record ConfirmationRequest(string ProposalHash, string Intent);
public sealed record ConfirmationGrant(string ProposalId, string ProposalHash, string Grant, DateTimeOffset ExpiresAt);
public sealed record CommitCaseRequest(string ProposalHash, string ConfirmationGrant);
public sealed record SupportCase(
    string Id, string ServiceId, string Subject, string Summary, string Impact,
    string State, DateTimeOffset CreatedAt, bool Synthetic);
public sealed record IdempotencyReceipt(
    string KeyHash, string ProposalId, string ProposalHash, string GrantHash, SupportCase Case);
public sealed record CommitCaseResult(SupportCase Case, bool Replayed);
public sealed record ChatMessageRequest(string ServiceId, string Message);
public sealed record ChatAnswer(string Message, IReadOnlyList<Citation> Citations, string Provider, bool SyntheticCompany);
public sealed record TextCompletion(string Content, int? InputTokens, int? OutputTokens);
public sealed record VoiceSessionRequest(bool Consent);
public sealed record VoiceSessionTicket(
    string SessionId, string Ticket, DateTimeOffset TicketExpiresAt,
    DateTimeOffset SessionExpiresAt, string WebSocketUrl, string Protocol, string Provider);
public sealed record RuntimeAuthConfig(bool Configured, string? Authority, string? ClientId, string? Scope, string RedirectPath);
public sealed record RuntimeCapabilities(bool Cases, bool Knowledge, bool Text, bool Voice, string ProviderMode);
public sealed record RuntimeConfig(
    string CompanyName, bool FictionalDemo, RuntimeAuthConfig Auth,
    RuntimeCapabilities Capabilities, int TextMaxChars, int VoiceSessionSeconds);
public sealed record CustomerInfo(string CompanyId, DateTimeOffset AuthorizationExpiresAt);
