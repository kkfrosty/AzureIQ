using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.WebUtilities;

namespace Harbor.Support.Api.Features;

public interface ICaseStore
{
    Task<IReadOnlyList<SupportCase>> ListAsync(CustomerContext customer, CancellationToken cancellationToken);
    Task<SupportCase?> GetCaseAsync(CustomerContext customer, string id, CancellationToken cancellationToken);
    Task AddProposalAsync(CustomerContext customer, CaseProposal proposal, CancellationToken cancellationToken);
    Task<StoredProposal?> GetProposalAsync(CustomerContext customer, string id, CancellationToken cancellationToken);
    Task<IdempotencyReceipt?> GetReceiptAsync(CustomerContext customer, string keyHash, CancellationToken cancellationToken);
    Task<bool> ConfirmAsync(CustomerContext customer, StoredProposal proposal, string grantHash,
        DateTimeOffset confirmedAt, CancellationToken cancellationToken);
    Task<bool> CommitAsync(CustomerContext customer, StoredProposal proposal, IdempotencyReceipt receipt,
        CancellationToken cancellationToken);
}

public sealed class CaseService(ICaseStore store, Catalog catalog, HarborOptions options, TimeProvider clock)
{
    public Task<IReadOnlyList<SupportCase>> ListAsync(CustomerContext customer, CancellationToken cancellationToken) =>
        store.ListAsync(customer, cancellationToken);

    public async Task<CaseProposal> GetProposalAsync(CustomerContext customer, string id, CancellationToken cancellationToken) =>
        (await RequireProposalAsync(customer, id, cancellationToken)).Proposal;

    public async Task<SupportCase> GetAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        RequireId(id);
        return await store.GetCaseAsync(customer, id, cancellationToken) ??
            throw new HarborException(404, "case_not_found", "No caller-owned case was found.");
    }

    public async Task<CaseProposal> PrepareAsync(CustomerContext customer, PrepareCaseRequest request, CancellationToken cancellationToken)
    {
        catalog.RequireService(request.ServiceId);
        var subject = Normalize(request.Subject, 120, "subject");
        var summary = Normalize(request.Summary, 2000, "summary");
        if (request.Impact is not ("low" or "medium" or "high"))
            throw new HarborException(400, "invalid_impact", "Impact must be low, medium, or high.");
        if (CompanyPolicy.ContainsSecret(subject) || CompanyPolicy.ContainsSecret(summary))
            throw new HarborException(400, "sensitive_content", "Do not include passwords, access tokens, or payment details.");
        var createdAt = clock.GetUtcNow();
        var expiresAt = new[] { createdAt.AddSeconds(options.Limits.ProposalSeconds), customer.AuthorizationExpiresAt }.Min();
        if (expiresAt <= createdAt)
            throw new HarborException(403, "authorization_expired", "Sign in again before preparing a case.");
        var id = Guid.NewGuid().ToString("N");
        var hash = CustomerIdentity.Hash(JsonSerializer.Serialize(
            new { id, customer.CompanyId, customer.OwnerKey, request.ServiceId, subject, summary, request.Impact, expiresAt }));
        var proposal = new CaseProposal(id, request.ServiceId, subject, summary, request.Impact, hash, createdAt, expiresAt);
        await store.AddProposalAsync(customer, proposal, cancellationToken);
        return proposal;
    }

    public async Task<ConfirmationGrant> ConfirmAsync(
        CustomerContext customer, string id, ConfirmationRequest request, CancellationToken cancellationToken)
    {
        var stored = await RequireProposalAsync(customer, id, cancellationToken);
        ValidateProposal(stored, request.ProposalHash);
        if (request.Intent != "create_case")
            throw new HarborException(400, "explicit_confirmation_required", "The exact create_case confirmation intent is required.");
        if (stored.Consumed || stored.GrantHash is not null)
            throw new HarborException(409, "proposal_already_confirmed", "This proposal has already been confirmed or consumed.");
        var grant = WebEncoders.Base64UrlEncode(RandomNumberGenerator.GetBytes(32));
        if (!await store.ConfirmAsync(customer, stored, CustomerIdentity.Hash(grant), clock.GetUtcNow(), cancellationToken))
            throw new HarborException(409, "proposal_changed", "The proposal changed; do not repeat confirmation blindly.");
        return new ConfirmationGrant(id, stored.Proposal.ProposalHash, grant, stored.Proposal.ExpiresAt);
    }

    public async Task<CommitCaseResult> CommitAsync(
        CustomerContext customer, string id, string? idempotencyKey, CommitCaseRequest request, CancellationToken cancellationToken)
    {
        RequireId(id);
        if (!Guid.TryParse(idempotencyKey, out var key))
            throw new HarborException(400, "idempotency_key_required", "Idempotency-Key must be a GUID; reuse it for exact retries.");
        if (string.IsNullOrWhiteSpace(request.ConfirmationGrant) || request.ConfirmationGrant.Length > 128 ||
            string.IsNullOrWhiteSpace(request.ProposalHash) || request.ProposalHash.Length != 64)
            throw new HarborException(400, "confirmation_grant_required", "An exact proposal hash and human confirmation grant are required.");
        var keyHash = CustomerIdentity.Hash(key.ToString("N"));
        var grantHash = CustomerIdentity.Hash(request.ConfirmationGrant);
        var receipt = await store.GetReceiptAsync(customer, keyHash, cancellationToken);
        if (receipt is not null)
            return MatchReceipt(receipt, id, request.ProposalHash, grantHash);
        var stored = await RequireProposalAsync(customer, id, cancellationToken);
        ValidateProposal(stored, request.ProposalHash);
        if (stored.Consumed)
            throw new HarborException(409, "proposal_consumed", "The proposal was already committed. Reuse the original idempotency key.");
        if (stored.GrantHash is null || stored.ConfirmedAt is null ||
            !CustomerIdentity.HashEquals(stored.GrantHash, grantHash))
            throw new HarborException(403, "explicit_confirmation_required", "A separate caller-bound human confirmation is required.");
        var supportCase = new SupportCase(Guid.NewGuid().ToString("N"), stored.Proposal.ServiceId,
            stored.Proposal.Subject, stored.Proposal.Summary, stored.Proposal.Impact, "open", clock.GetUtcNow(), true);
        var newReceipt = new IdempotencyReceipt(keyHash, id, request.ProposalHash, grantHash, supportCase);
        if (await store.CommitAsync(customer, stored, newReceipt, cancellationToken))
            return new CommitCaseResult(supportCase, false);
        receipt = await store.GetReceiptAsync(customer, keyHash, cancellationToken);
        if (receipt is not null)
            return MatchReceipt(receipt, id, request.ProposalHash, grantHash);
        throw new HarborException(409, "commit_conflict", "The proposal changed. Do not retry with a different idempotency key.");
    }

    private static CommitCaseResult MatchReceipt(IdempotencyReceipt receipt, string proposalId, string proposalHash, string grantHash)
    {
        if (receipt.ProposalId != proposalId ||
            !CustomerIdentity.HashEquals(receipt.ProposalHash, proposalHash) ||
            !CustomerIdentity.HashEquals(receipt.GrantHash, grantHash))
            throw new HarborException(409, "idempotency_conflict", "This idempotency key belongs to a different action.");
        return new CommitCaseResult(receipt.Case, true);
    }

    private async Task<StoredProposal> RequireProposalAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        RequireId(id);
        return await store.GetProposalAsync(customer, id, cancellationToken) ??
            throw new HarborException(404, "proposal_not_found", "No caller-owned proposal was found.");
    }

    private void ValidateProposal(StoredProposal stored, string? hash)
    {
        if (stored.Proposal.ExpiresAt <= clock.GetUtcNow())
            throw new HarborException(410, "proposal_expired", "The proposal expired; prepare a new proposal.");
        if (hash is null || !CustomerIdentity.HashEquals(stored.Proposal.ProposalHash, hash))
            throw new HarborException(409, "proposal_hash_mismatch", "Confirmation must match the exact immutable proposal.");
    }

    public static void RequireId(string id)
    {
        if (!Guid.TryParseExact(id, "N", out _))
            throw new HarborException(400, "invalid_id", "The identifier is invalid.");
    }

    public static string Normalize(string? value, int maxLength, string field)
    {
        var normalized = value?.Trim().Normalize(NormalizationForm.FormC);
        if (string.IsNullOrWhiteSpace(normalized) || normalized.Length > maxLength ||
            normalized.Any(character => char.IsControl(character) && character is not ('\n' or '\r' or '\t')))
            throw new HarborException(400, "invalid_request", $"{field} must contain 1 to {maxLength} characters.");
        return normalized;
    }
}
