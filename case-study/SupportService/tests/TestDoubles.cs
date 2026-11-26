using System.Text.Json;
using System.Threading.Channels;
using Azure.Core;
using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;

namespace Harbor.Support.Tests;

public sealed class TestClock : TimeProvider
{
    public DateTimeOffset Now { get; set; } = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() => Now;
}

public static class TestData
{
    public const string Tenant = "00000000-0000-0000-0000-000000000001";
    public const string Client = "00000000-0000-0000-0000-000000000002";
    public const string ApiClient = "00000000-0000-0000-0000-000000000006";
    public const string Audience = "api://" + ApiClient;
    public const string Origin = "https://harbor.example.test";
    public static Catalog Catalog() => new(Path.Combine(AppContext.BaseDirectory, "data"));
    public static CustomerContext Customer(TestClock clock, string owner = "owner") =>
        new(HarborOptions.CompanyId, "h_" + CustomerIdentity.Hash(owner), clock.Now.AddHours(1));
    public static HarborOptions Options(TestClock clock) => new()
    {
        PathBase = "/support",
        Entra = new EntraOptions
        {
            TenantId = Tenant, ClientId = Client, ApiAudience = Audience,
            Scope = Audience + "/Support.Access"
        },
        Storage = new StorageOptions { ServiceUri = "https://table.example.test" },
        Search = new SearchOptions { Endpoint = "https://search.example.test" },
        Ai = new AiOptions
        {
            ChatEndpoint = "https://harbor.example.test/support/ai/chat",
            TokenScope = "api://harbor-model-gateway/.default", Deployment = "harbor-text"
        },
        Voice = new VoiceOptions
        {
            Endpoint = "https://voice.example.test/voice-live/realtime",
            Model = "harbor-text", AllowedOrigins = [Origin]
        },
        Limits = new LimitOptions { LabWindowId = "synthetic-unit-window", LabWindowEndsAt = clock.Now.AddMinutes(20) }
    };
    public static PrepareCaseRequest CaseRequest => new("microsoft-365", "Outlook sign-in issue",
        "Synthetic Outlook sign-in error; no customer data.", "medium");
    public static JsonElement Json(string value) => JsonSerializer.Deserialize<JsonElement>(value);
}

public sealed class MemoryCaseStore : ICaseStore
{
    private readonly Lock gate = new();
    private readonly Dictionary<(string Owner, string Id), StoredProposal> proposals = [];
    private readonly Dictionary<(string Owner, string Id), SupportCase> cases = [];
    private readonly Dictionary<(string Owner, string Key), IdempotencyReceipt> receipts = [];
    private int version;

    public Task<IReadOnlyList<SupportCase>> ListAsync(CustomerContext customer, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
            return Task.FromResult<IReadOnlyList<SupportCase>>(cases.Where(row => row.Key.Owner == customer.OwnerKey)
                .Select(row => row.Value).ToArray());
    }

    public Task<SupportCase?> GetCaseAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
            return Task.FromResult(cases.GetValueOrDefault((customer.OwnerKey, id)));
    }

    public Task AddProposalAsync(CustomerContext customer, CaseProposal proposal, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
            proposals.Add((customer.OwnerKey, proposal.Id), new(proposal, null, null, false, (++version).ToString()));
        return Task.CompletedTask;
    }

    public Task<StoredProposal?> GetProposalAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
            return Task.FromResult(proposals.GetValueOrDefault((customer.OwnerKey, id)));
    }

    public Task<IdempotencyReceipt?> GetReceiptAsync(CustomerContext customer, string keyHash, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
            return Task.FromResult(receipts.GetValueOrDefault((customer.OwnerKey, keyHash)));
    }

    public Task<bool> ConfirmAsync(CustomerContext customer, StoredProposal proposal, string grantHash,
        DateTimeOffset confirmedAt, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            var key = (customer.OwnerKey, proposal.Proposal.Id);
            if (!proposals.TryGetValue(key, out var current) || current.Version != proposal.Version)
                return Task.FromResult(false);
            proposals[key] = current with { GrantHash = grantHash, ConfirmedAt = confirmedAt, Version = (++version).ToString() };
            return Task.FromResult(true);
        }
    }

    public Task<bool> CommitAsync(CustomerContext customer, StoredProposal proposal, IdempotencyReceipt receipt,
        CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            var key = (customer.OwnerKey, proposal.Proposal.Id);
            if (!proposals.TryGetValue(key, out var current) || current.Version != proposal.Version ||
                receipts.ContainsKey((customer.OwnerKey, receipt.KeyHash)))
                return Task.FromResult(false);
            proposals[key] = current with { Consumed = true, Version = (++version).ToString() };
            cases.Add((customer.OwnerKey, receipt.Case.Id), receipt.Case);
            receipts.Add((customer.OwnerKey, receipt.KeyHash), receipt);
            return Task.FromResult(true);
        }
    }
}

public sealed class TestKnowledgeStore : IKnowledgeStore
{
    public bool IsConfigured { get; set; } = true;
    public IReadOnlyList<KnowledgeDocument> Documents { get; set; } =
        TestData.Catalog().ApprovedDocuments.Where(document => document.DocId == "hbr-microsoft-365").ToArray();
    public string? LastQuery { get; private set; }
    public Task<IReadOnlyList<KnowledgeDocument>> SearchAsync(string serviceId, string query, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        LastQuery = query;
        return Task.FromResult(Documents);
    }
}

public sealed class TestUsageLedger : IUsageLedger
{
    public int TextReservations { get; private set; }
    public int VoiceSeconds { get; private set; }
    public HarborException? Failure { get; set; }
    public Task ReserveTextAsync(CustomerContext customer, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Failure is not null)
            throw Failure;
        TextReservations++;
        return Task.CompletedTask;
    }
    public Task ReserveVoiceAsync(CustomerContext customer, int seconds, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Failure is not null)
            throw Failure;
        VoiceSeconds += seconds;
        return Task.CompletedTask;
    }
}

public sealed class TestTextClient : ITextClient
{
    public bool IsConfigured { get; set; } = true;
    public string Provider => "test-only-provider";
    public string Content { get; set; } = "Harbor Outlook guidance; status is synthetic. [hbr-microsoft-365@1.0]";
    public HarborException? Failure { get; set; }
    public int Calls { get; private set; }
    public Task<TextCompletion> CompleteAsync(string message, KnowledgeResult knowledge, SyntheticStatus status,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Calls++;
        if (Failure is not null)
            throw Failure;
        return Task.FromResult(new TextCompletion(Content, 10, 20));
    }
}

public sealed class TestCredential : TokenCredential
{
    public List<string> Scopes { get; } = [];
    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
        throw new NotSupportedException("Async token acquisition is required.");
    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Scopes.AddRange(requestContext.Scopes);
        return ValueTask.FromResult(new AccessToken("synthetic-test-token", DateTimeOffset.UtcNow.AddMinutes(10)));
    }
}

public sealed class TestVoiceFactory : IVoiceUpstreamFactory
{
    public bool IsConfigured { get; set; } = true;
    public string Provider => "test-only-voice";
    public TestVoiceConnection Connection { get; } = new();
    public Task<IVoiceConnection> ConnectAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult<IVoiceConnection>(Connection);
    }
}

public sealed class TestVoiceConnection : IVoiceConnection
{
    public Channel<JsonElement> Incoming { get; } = Channel.CreateUnbounded<JsonElement>();
    public Channel<JsonElement> Sent { get; } = Channel.CreateUnbounded<JsonElement>();
    public bool Disposed { get; private set; }
    public Task SendAsync(JsonElement message, CancellationToken cancellationToken) =>
        Sent.Writer.WriteAsync(message.Clone(), cancellationToken).AsTask();
    public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellationToken) =>
        await Incoming.Reader.ReadAsync(cancellationToken);
    public ValueTask DisposeAsync()
    {
        Disposed = true;
        return ValueTask.CompletedTask;
    }
}
