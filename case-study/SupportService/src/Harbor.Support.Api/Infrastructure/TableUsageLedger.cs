using Azure;
using Azure.Core;
using Azure.Data.Tables;
using Harbor.Support.Api.Features;

namespace Harbor.Support.Api.Infrastructure;

public interface IUsageLedger
{
    Task ReserveTextAsync(CustomerContext customer, CancellationToken cancellationToken);
    Task ReserveVoiceAsync(CustomerContext customer, int seconds, CancellationToken cancellationToken);
}

public sealed class TableUsageLedger(
    HarborOptions options, TokenCredential credential, TimeProvider clock) : IUsageLedger
{
    public Task ReserveTextAsync(CustomerContext customer, CancellationToken cancellationToken) =>
        ReserveAsync(customer, 0, true, cancellationToken);

    public Task ReserveVoiceAsync(CustomerContext customer, int seconds, CancellationToken cancellationToken) =>
        ReserveAsync(customer, seconds, false, cancellationToken);

    private async Task ReserveAsync(CustomerContext customer, int voiceSeconds, bool text, CancellationToken cancellationToken)
    {
        TableCaseStore.RequireCompany(customer);
        options.Limits.RequireActiveWindow(clock);
        if (!options.Storage.IsConfigured)
            throw new HarborException(503, "usage_storage_not_configured", "Durable inference admission is not configured.");
        var client = new TableClient(new Uri(options.Storage.ServiceUri), options.Storage.UsageTableName, credential,
            new TableClientOptions { Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(options.Limits.ProviderTimeoutSeconds) } });
        var partition = $"w_{CustomerIdentity.Hash(options.Limits.LabWindowId)}";
        var minute = clock.GetUtcNow().ToUnixTimeSeconds() / 60;
        var callerRow = $"Text:{customer.OwnerKey}:{minute}";
        using var span = HarborTelemetry.Source.StartActivity(text ? "usage.reserve_text" : "usage.reserve_voice");
        for (var attempt = 0; attempt < 5; attempt++)
        {
            options.Limits.RequireActiveWindow(clock);
            try
            {
                var globalResponse = await client.GetEntityIfExistsAsync<TableEntity>(partition, "Budget",
                    cancellationToken: cancellationToken);
                var global = globalResponse.HasValue ? globalResponse.Value! : new TableEntity(partition, "Budget")
                {
                    ["TextCount"] = 0L,
                    ["VoiceSeconds"] = 0L,
                    ["WindowEndsAt"] = options.Limits.LabWindowEndsAt
                };
                if (global.GetDateTimeOffset("WindowEndsAt") != options.Limits.LabWindowEndsAt)
                    throw new HarborException(409, "lab_window_binding_changed", "A durable lab window cannot be extended or rebound by restarting the application.");
                var textCount = global.GetInt64("TextCount") ?? 0;
                var reservedVoice = global.GetInt64("VoiceSeconds") ?? 0;
                if (text && textCount >= options.Limits.TextRequestsPerWindow ||
                    !text && (voiceSeconds < 1 || voiceSeconds > options.Limits.VoiceSessionSeconds ||
                        reservedVoice + voiceSeconds > options.Limits.VoiceSecondsPerWindow))
                    throw new HarborException(429, "lab_usage_exhausted", "The conservative lab-window inference allowance is exhausted.");
                global["TextCount"] = textCount + (text ? 1 : 0);
                global["VoiceSeconds"] = reservedVoice + voiceSeconds;
                var actions = new List<TableTransactionAction>(2)
                {
                    new(globalResponse.HasValue ? TableTransactionActionType.UpdateReplace : TableTransactionActionType.Add,
                        global, globalResponse.HasValue ? global.ETag : default)
                };
                if (text)
                {
                    var callerResponse = await client.GetEntityIfExistsAsync<TableEntity>(partition, callerRow,
                        cancellationToken: cancellationToken);
                    var caller = callerResponse.HasValue ? callerResponse.Value! : new TableEntity(partition, callerRow) { ["Count"] = 0L };
                    var count = caller.GetInt64("Count") ?? 0;
                    if (count >= options.Limits.TextRequestsPerMinute)
                        throw new HarborException(429, "text_rate_limited", "The caller's text rate limit has been reached.");
                    caller["Count"] = count + 1;
                    actions.Add(new TableTransactionAction(
                        callerResponse.HasValue ? TableTransactionActionType.UpdateReplace : TableTransactionActionType.Add,
                        caller, callerResponse.HasValue ? caller.ETag : default));
                }
                await client.SubmitTransactionAsync(actions, cancellationToken);
                return;
            }
            catch (RequestFailedException failure) when (failure.Status is 409 or 412)
            {
                if (attempt == 4)
                    throw new HarborException(429, "usage_admission_busy", "Usage admission is busy; no provider call was started.");
                await Task.Delay(TimeSpan.FromMilliseconds(20 * (attempt + 1)), clock, cancellationToken);
            }
            catch (RequestFailedException)
            {
                throw new HarborException(503, "usage_ledger_unavailable", "Durable usage admission failed; no provider call was started.");
            }
            catch (Azure.Identity.AuthenticationFailedException)
            {
                throw new HarborException(503, "usage_identity_unavailable", "The usage-ledger managed identity could not authenticate.");
            }
        }
    }
}
