using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Data.Tables;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public sealed class TableCaseStore(HarborOptions options, TokenCredential credential) : ICaseStore
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private TableClient Client()
    {
        if (!options.Storage.IsConfigured)
            throw new HarborException(503, "storage_not_configured", "Durable case storage is not configured.");
        return new TableClient(new Uri(options.Storage.ServiceUri), options.Storage.CasesTableName, credential,
            new TableClientOptions { Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(options.Limits.ProviderTimeoutSeconds) } });
    }

    public async Task<IReadOnlyList<SupportCase>> ListAsync(CustomerContext customer, CancellationToken cancellationToken)
    {
        RequireCompany(customer);
        using var span = HarborTelemetry.Source.StartActivity("cases.list");
        var cases = new List<SupportCase>(50);
        try
        {
            var filter = TableClient.CreateQueryFilter(
                $"PartitionKey eq {customer.OwnerKey} and RowKey ge {"Case:"} and RowKey lt {"Case;"}");
            await foreach (var row in Client().QueryAsync<TableEntity>(filter, 50, cancellationToken: cancellationToken))
            {
                cases.Add(Deserialize<SupportCase>(row));
                if (cases.Count == 50)
                    break;
            }
            return cases.OrderByDescending(supportCase => supportCase.CreatedAt).ToArray();
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "storage_unavailable", "Durable case storage could not be reached.");
        }
    }

    public async Task<SupportCase?> GetCaseAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        var row = await ReadAsync(customer, $"Case:{id}", cancellationToken);
        return row is null ? null : Deserialize<SupportCase>(row);
    }

    public async Task AddProposalAsync(CustomerContext customer, CaseProposal proposal, CancellationToken cancellationToken)
    {
        RequireCompany(customer);
        using var span = HarborTelemetry.Source.StartActivity("cases.prepare");
        try
        {
            await Client().AddEntityAsync(Entity(customer.OwnerKey, $"Proposal:{proposal.Id}",
                new StoredProposal(proposal, null, null, false, "")), cancellationToken);
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "storage_unavailable", "The proposal could not be stored; no case was created.");
        }
    }

    public async Task<StoredProposal?> GetProposalAsync(CustomerContext customer, string id, CancellationToken cancellationToken)
    {
        var row = await ReadAsync(customer, $"Proposal:{id}", cancellationToken);
        return row is null ? null : Deserialize<StoredProposal>(row) with { Version = row.ETag.ToString() };
    }

    public async Task<IdempotencyReceipt?> GetReceiptAsync(CustomerContext customer, string keyHash, CancellationToken cancellationToken)
    {
        var row = await ReadAsync(customer, $"Receipt:{keyHash}", cancellationToken);
        return row is null ? null : Deserialize<IdempotencyReceipt>(row);
    }

    public async Task<bool> ConfirmAsync(CustomerContext customer, StoredProposal proposal,
        string grantHash, DateTimeOffset confirmedAt, CancellationToken cancellationToken)
    {
        RequireCompany(customer);
        using var span = HarborTelemetry.Source.StartActivity("cases.confirm");
        var row = Entity(customer.OwnerKey, $"Proposal:{proposal.Proposal.Id}",
            proposal with { GrantHash = grantHash, ConfirmedAt = confirmedAt, Version = "" });
        try
        {
            await Client().UpdateEntityAsync(row, new ETag(proposal.Version), TableUpdateMode.Replace, cancellationToken);
            return true;
        }
        catch (RequestFailedException failure) when (failure.Status is 409 or 412)
        {
            return false;
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "storage_unavailable", "Confirmation could not be stored; prepare anew if its result is uncertain.");
        }
    }

    public async Task<bool> CommitAsync(CustomerContext customer, StoredProposal proposal,
        IdempotencyReceipt receipt, CancellationToken cancellationToken)
    {
        RequireCompany(customer);
        using var span = HarborTelemetry.Source.StartActivity("cases.commit");
        TableTransactionAction[] actions =
        [
            new(TableTransactionActionType.Add, Entity(customer.OwnerKey, $"Case:{receipt.Case.Id}", receipt.Case)),
            new(TableTransactionActionType.Add, Entity(customer.OwnerKey, $"Receipt:{receipt.KeyHash}", receipt)),
            new(TableTransactionActionType.UpdateReplace,
                Entity(customer.OwnerKey, $"Proposal:{proposal.Proposal.Id}", proposal with { Consumed = true, Version = "" }),
                new ETag(proposal.Version))
        ];
        try
        {
            await Client().SubmitTransactionAsync(actions, cancellationToken);
            HarborTelemetry.Commits.Add(1);
            return true;
        }
        catch (RequestFailedException failure) when (failure.Status is 409 or 412)
        {
            return false;
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "commit_uncertain", "Storage did not acknowledge the commit. Retry only the exact original idempotency key and grant.");
        }
    }

    private async Task<TableEntity?> ReadAsync(CustomerContext customer, string rowKey, CancellationToken cancellationToken)
    {
        RequireCompany(customer);
        try
        {
            var response = await Client().GetEntityIfExistsAsync<TableEntity>(customer.OwnerKey, rowKey,
                cancellationToken: cancellationToken);
            return response.HasValue ? response.Value : null;
        }
        catch (RequestFailedException)
        {
            throw new HarborException(503, "storage_unavailable", "Durable case storage could not be reached.");
        }
    }

    private static TableEntity Entity<T>(string partition, string row, T data) =>
        new(partition, row) { ["Data"] = JsonSerializer.Serialize(data, Json) };

    private static T Deserialize<T>(TableEntity entity) =>
        JsonSerializer.Deserialize<T>(entity.GetString("Data"), Json) ??
        throw new HarborException(502, "invalid_storage_record", "Storage returned an invalid case record.");

    public static void RequireCompany(CustomerContext customer)
    {
        if (customer.CompanyId != HarborOptions.CompanyId || !customer.OwnerKey.StartsWith("h_", StringComparison.Ordinal))
            throw new HarborException(403, "access_denied", "Harbor company ownership is required.");
    }
}
