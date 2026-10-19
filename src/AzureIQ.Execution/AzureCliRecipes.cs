using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

namespace AzureIQ.Execution;

internal sealed record CliBinding(
    string[] Arguments, string[] RollbackArguments, string Version, string ContextDigest, bool IsRollback = false);
internal sealed record CliIdentity(string Version, string Digest);

internal sealed class AzureCliRecipeRunner(LocalConfiguration configuration, string expectedPrincipal)
{
    internal static (string Tenant, string Principal) TokenIdentity(AccessToken token)
    {
        string[] parts = token.Token.Split('.');
        if (parts.Length != 3)
        {
            throw new InvalidOperationException("ARM credential returned an unsupported token format.");
        }
        string payload = parts[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
        using JsonDocument claims = JsonDocument.Parse(Convert.FromBase64String(payload));
        string tenant = claims.RootElement.GetProperty("tid").GetString()!;
        string principal = claims.RootElement.GetProperty("oid").GetString()!;
        if (!Guid.TryParse(tenant, out _) || !Guid.TryParse(principal, out _))
        {
            throw new InvalidOperationException("ARM credential has no valid tenant/principal identity.");
        }
        return (tenant, principal);
    }

    internal async Task<CliIdentity> IdentityAsync(string sdkPrincipal)
    {
        string executable = FindExecutable();
        JsonObject account = JsonNode.Parse(await RunAsync(executable, ["account", "show"]))!.AsObject();
        ValidateAccount(account, configuration, expectedPrincipal);
        var credential = new AzureCliCredential(new AzureCliCredentialOptions
        {
            TenantId = configuration.TenantId.ToString(),
            ProcessTimeout = TimeSpan.FromSeconds(30)
        });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        AccessToken token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), timeout.Token);
        var actor = TokenIdentity(token);
        if (Guid.Parse(actor.Tenant) != configuration.TenantId ||
            !string.Equals(actor.Principal, sdkPrincipal, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Azure CLI and SDK execution identities do not match.");
        }
        JsonObject versions = JsonNode.Parse(await RunAsync(executable, ["version"]))!.AsObject();
        string version = versions["azure-cli"]!.GetValue<string>();
        string fileDigest = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(executable)));
        return new CliIdentity(version, ChangeWorkflow.Digest(
            executable + version + fileDigest + actor.Tenant + actor.Principal +
            configuration.SubscriptionId + expectedPrincipal));
    }

    internal static void ValidateAccount(JsonObject account, LocalConfiguration configuration, string principal)
    {
        if (string.IsNullOrWhiteSpace(principal) ||
            account["environmentName"]?.GetValue<string>() != "AzureCloud" ||
            !Guid.TryParse(account["tenantId"]?.GetValue<string>(), out Guid tenant) || tenant != configuration.TenantId ||
            !Guid.TryParse(account["id"]?.GetValue<string>(), out Guid subscription) || subscription != configuration.SubscriptionId ||
            !string.Equals(account["user"]?["name"]?.GetValue<string>(), principal, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Azure CLI cloud, selected scope, or principal does not match the private profile.");
        }
    }

    internal static bool IsSubnet(string target, Guid subscription) =>
        Regex.IsMatch(target, $"^/subscriptions/{subscription}/resourceGroups/[A-Za-z0-9_.()-]{{1,90}}/providers/Microsoft\\.Network/virtualNetworks/[A-Za-z0-9_.()-]{{1,80}}/subnets/[A-Za-z0-9_.()-]{{1,80}}$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    internal static void Validate(string target, JsonObject? desired, CliBinding binding, Guid subscription)
    {
        if (!IsSubnet(target, subscription) || desired is null)
        {
            throw new InvalidOperationException("CLI recipes may update only an existing in-scope subnet, never delete it.");
        }
        string[] pieces = target.Split('/');
        string[] prefix =
        [
            "network", "vnet", "subnet", "update",
            "--resource-group", pieces[4], "--vnet-name", pieces[8], "--name", pieces[10]
        ];
        string[] args = binding.Arguments;
        if (args.Length < 12 || !args.Take(10).SequenceEqual(prefix, StringComparer.Ordinal))
        {
            throw new InvalidOperationException("CLI command family or target arguments differ from the approved target.");
        }
        if (binding.IsRollback)
        {
            if (args.Length != 12 || args[10] != "--remove" || args[11] != "serviceEndpoints" ||
                Services(desired).Length != 0)
            {
                throw new InvalidOperationException("Subnet rollback may restore only an originally empty endpoint set.");
            }
        }
        else
        {
            string[] services = args[11..];
            string[] allowed = ["Microsoft.Storage", "Microsoft.Sql", "Microsoft.KeyVault", "Microsoft.EventHub"];
            if (args[10] != "--service-endpoints" || services.Length == 0 ||
                services.Distinct(StringComparer.Ordinal).Count() != services.Length ||
                services.Any(service => !allowed.Contains(service, StringComparer.Ordinal)) ||
                desired.Count != 1 || desired["properties"] is not JsonObject { Count: 1 } ||
                !services.Order(StringComparer.Ordinal).SequenceEqual(Services(desired).Order(StringComparer.Ordinal)))
            {
                throw new InvalidOperationException("CLI endpoint arguments or desired properties are outside the admitted scope.");
            }
        }
    }

    internal async Task ExecuteAsync(string target, JsonObject? body, CliBinding binding)
    {
        Validate(target, body, binding, configuration.SubscriptionId);
        string[] arguments = [.. binding.Arguments, "--subscription", configuration.SubscriptionId.ToString()];
        _ = await RunAsync(FindExecutable(), arguments, TimeSpan.FromMinutes(5));
    }

    internal static bool MatchesState(ChangePlan plan, ArmSnapshot? current)
    {
        return current is not null && plan.Desired is not null && plan.Before is not null &&
            PreservesSubnet(plan.Before.Body, current.Body) &&
            Services(plan.Desired).Order(StringComparer.OrdinalIgnoreCase)
                .SequenceEqual(Services(current.Body).Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase);
    }

    internal static bool PreservesSubnet(JsonObject before, JsonObject after)
    {
        string[] fields =
        [
            "addressPrefix", "addressPrefixes", "networkSecurityGroup", "routeTable", "delegations",
            "natGateway", "serviceEndpointPolicies", "privateEndpointNetworkPolicies", "privateLinkServiceNetworkPolicies"
            , "defaultOutboundAccess"
        ];
        return fields.All(field => JsonNode.DeepEquals(before["properties"]?[field], after["properties"]?[field]));
    }

    internal static string[] Services(JsonObject body) => body["properties"]?["serviceEndpoints"] switch
    {
        null => [],
        JsonArray values => values.Select(value => value?["service"]?.GetValue<string>()
            ?? throw new InvalidOperationException("Invalid service endpoint response.")).ToArray(),
        _ => throw new InvalidOperationException("Invalid service endpoint collection.")
    };

    private static string FindExecutable()
    {
        foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            foreach (string name in new[] { "az.cmd", "az.exe" })
            {
                string path = Path.GetFullPath(Path.Combine(directory, name));
                if (File.Exists(path))
                {
                    return path;
                }
            }
        }
        throw new InvalidOperationException("An existing Azure CLI installation is required; none is installed automatically.");
    }

    internal static ProcessStartInfo StartInfo(string executable, string[] arguments)
    {
        string[] all = [.. arguments, "--only-show-errors", "--output", "json"];
        if (new[] { executable }.Concat(all).Any(value => Regex.IsMatch(value, "[\"%!\\r\\n&|<>^]")))
        {
            throw new InvalidOperationException("Unsafe CLI argument or executable path.");
        }
        var start = new ProcessStartInfo
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
            CreateNoWindow = true
        };
        start.Environment["AZURE_EXTENSION_USE_DYNAMIC_INSTALL"] = "no";
        if (Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            start.FileName = Environment.GetEnvironmentVariable("ComSpec")
                ?? throw new InvalidOperationException("Windows command launcher is unavailable.");
            start.Arguments = "/d /s /c \"\"" + executable + "\" " +
                string.Join(" ", all.Select(value => "\"" + value + "\"")) + "\"";
        }
        else
        {
            start.FileName = executable;
            foreach (string argument in all)
            {
                start.ArgumentList.Add(argument);
            }
        }
        return start;
    }

    private static async Task<string> RunAsync(string executable, string[] arguments, TimeSpan? budget = null)
    {
        using var process = new Process { StartInfo = StartInfo(executable, arguments) };
        process.Start();
        Task<string> output = process.StandardOutput.ReadToEndAsync();
        Task<string> error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(budget ?? TimeSpan.FromSeconds(30));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new TimeoutException("Azure CLI timed out. A submitted Azure operation may still be running; do not retry a write.");
        }
        string text = await output;
        _ = await error;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"Azure CLI failed (exit {process.ExitCode}); no raw output or errors were exported.");
        }
        return text;
    }
}
