using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Tests;
using Xunit;

namespace Harbor.Support.UnitTests;

public sealed class CaseTests
{
    private readonly TestClock clock = new();
    private readonly MemoryCaseStore store = new();
    private CaseService Service => new(store, TestData.Catalog(), TestData.Options(clock), clock);
    private CustomerContext Customer => TestData.Customer(clock);

    [Fact]
    public async Task PreparingDoesNotCreateACaseAndBindsExactContent()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        Assert.Empty(await Service.ListAsync(Customer, TestContext.Current.CancellationToken));
        Assert.Equal(TestData.CaseRequest.Subject, proposal.Subject);
        Assert.Equal(64, proposal.ProposalHash.Length);
        Assert.Equal(clock.Now.AddMinutes(10), proposal.ExpiresAt);
        Assert.Equal(proposal, await Service.GetProposalAsync(Customer, proposal.Id, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task UnconfirmedCommitIsDenied()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.CommitAsync(Customer, proposal.Id,
            Guid.NewGuid().ToString(), new(proposal.ProposalHash, "unconfirmed"), TestContext.Current.CancellationToken));
        Assert.Equal("explicit_confirmation_required", failure.Code);
        Assert.Empty(await Service.ListAsync(Customer, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("different-hash", "create_case", "proposal_hash_mismatch")]
    [InlineData(null, "create_case", "proposal_hash_mismatch")]
    [InlineData("exact", "yes", "explicit_confirmation_required")]
    public async Task ConfirmationRequiresExactHashAndIntent(string? hash, string intent, string code)
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.ConfirmAsync(Customer, proposal.Id,
            new(hash == "exact" ? proposal.ProposalHash : hash!, intent), TestContext.Current.CancellationToken));
        Assert.Equal(code, failure.Code);
    }

    [Fact]
    public async Task ConfirmationCannotBeIssuedTwice()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var request = new ConfirmationRequest(proposal.ProposalHash, "create_case");
        await Service.ConfirmAsync(Customer, proposal.Id, request, TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<HarborException>(() =>
            Service.ConfirmAsync(Customer, proposal.Id, request, TestContext.Current.CancellationToken));
        Assert.Equal("proposal_already_confirmed", failure.Code);
    }

    [Fact]
    public async Task ExactCommitRetriesReturnOneCaseEvenAfterProposalExpiry()
    {
        var customer = Customer;
        var proposal = await Service.PrepareAsync(customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var grant = await Service.ConfirmAsync(customer, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        var key = Guid.NewGuid().ToString();
        var request = new CommitCaseRequest(proposal.ProposalHash, grant.Grant);
        var created = await Service.CommitAsync(customer, proposal.Id, key, request, TestContext.Current.CancellationToken);
        clock.Now = proposal.ExpiresAt.AddSeconds(1);
        var replay = await Service.CommitAsync(customer, proposal.Id, key, request, TestContext.Current.CancellationToken);
        Assert.False(created.Replayed);
        Assert.True(replay.Replayed);
        Assert.Equal(created.Case, replay.Case);
        Assert.Single(await Service.ListAsync(customer, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ExpiryIsInclusiveAndBoundedByCustomerAuthorization()
    {
        var customer = Customer with { AuthorizationExpiresAt = clock.Now.AddSeconds(20) };
        var proposal = await Service.PrepareAsync(customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        Assert.Equal(customer.AuthorizationExpiresAt, proposal.ExpiresAt);
        clock.Now = proposal.ExpiresAt;
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.ConfirmAsync(customer, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken));
        Assert.Equal(410, failure.Status);
    }

    [Fact]
    public async Task ExpiredConfirmedProposalCannotFirstCommit()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var grant = await Service.ConfirmAsync(Customer, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        clock.Now = proposal.ExpiresAt;
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.CommitAsync(Customer, proposal.Id,
            Guid.NewGuid().ToString(), new(proposal.ProposalHash, grant.Grant), TestContext.Current.CancellationToken));
        Assert.Equal("proposal_expired", failure.Code);
    }

    [Fact]
    public async Task IdempotencyKeyCannotBeReboundToAnotherActionOrGrant()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var grant = await Service.ConfirmAsync(Customer, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        var key = Guid.NewGuid().ToString();
        await Service.CommitAsync(Customer, proposal.Id, key,
            new(proposal.ProposalHash, grant.Grant), TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.CommitAsync(Customer, proposal.Id,
            key, new(proposal.ProposalHash, "other-grant"), TestContext.Current.CancellationToken));
        Assert.Equal("idempotency_conflict", failure.Code);
    }

    [Fact]
    public async Task ConsumedProposalCannotCreateAnotherCaseWithNewKey()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var grant = await Service.ConfirmAsync(Customer, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        var request = new CommitCaseRequest(proposal.ProposalHash, grant.Grant);
        await Service.CommitAsync(Customer, proposal.Id, Guid.NewGuid().ToString(), request, TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.CommitAsync(Customer, proposal.Id,
            Guid.NewGuid().ToString(), request, TestContext.Current.CancellationToken));
        Assert.Equal("proposal_consumed", failure.Code);
    }

    [Fact]
    public async Task AnotherOwnerCannotReadOrConfirmProposalOrReadCase()
    {
        var proposal = await Service.PrepareAsync(Customer, TestData.CaseRequest, TestContext.Current.CancellationToken);
        var other = TestData.Customer(clock, "another-owner");
        var denied = await Assert.ThrowsAsync<HarborException>(() => Service.ConfirmAsync(other, proposal.Id,
            new(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken));
        Assert.Equal(404, denied.Status);
        Assert.Empty(await Service.ListAsync(other, TestContext.Current.CancellationToken));
        Assert.Equal(404, (await Assert.ThrowsAsync<HarborException>(() => Service.GetAsync(other,
            Guid.NewGuid().ToString("N"), TestContext.Current.CancellationToken))).Status);
    }

    [Fact]
    public async Task AnotherCompanyCannotUseStore()
    {
        var customer = Customer with { CompanyId = "another-company" };
        var failure = await Assert.ThrowsAsync<HarborException>(() =>
            Service.PrepareAsync(customer, TestData.CaseRequest, TestContext.Current.CancellationToken));
        Assert.Equal(403, failure.Status);
    }

    [Fact]
    public async Task CancellationPreventsProposalPersistence()
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            Service.PrepareAsync(Customer, TestData.CaseRequest, cancellation.Token));
        Assert.Empty(await Service.ListAsync(Customer, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("password=do-not-store", "medium", "sensitive_content")]
    [InlineData("Synthetic issue", "critical", "invalid_impact")]
    [InlineData("", "medium", "invalid_request")]
    public async Task InvalidOrSensitiveCasesAreRejected(string subject, string impact, string code)
    {
        var failure = await Assert.ThrowsAsync<HarborException>(() => Service.PrepareAsync(Customer,
            TestData.CaseRequest with { Subject = subject, Impact = impact }, TestContext.Current.CancellationToken));
        Assert.Equal(code, failure.Code);
    }
}
