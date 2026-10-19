using System.Runtime.InteropServices;
using System.Reflection;
using System.Text.Json;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Identity.Broker;
using Azure.ResourceManager;
using Azure.ResourceManager.Resources;
using AzureIQ.Execution;

return await ProgramEntry.RunAsync(args);

internal static class ProgramEntry
{
    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public static async Task<int> RunAsync(string[] args)
    {
        try
        {
            if (args.Length == 2 &&
                string.Equals(args[0], "operations", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(args[1], "list", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine(OperationCatalog.ReadJson());
                return 0;
            }

            if (args.FirstOrDefault() == "change")
            {
                return await ArmChangeCommand.RunAsync(args[1..]);
            }

            CommandOptions options = CommandOptions.Parse(args);
            LocalConfiguration configuration = await LocalConfiguration.LoadAsync(options.ConfigPath);
            configuration.ValidateForSupervisedExecution();

            TokenCredential credential = CreateCredential(options, configuration);
            ArmClient armClient = new(credential, configuration.SubscriptionId.ToString());
            SubscriptionResource subscription = armClient.GetSubscriptionResource(
                SubscriptionResource.CreateResourceIdentifier(configuration.SubscriptionId.ToString()));

            ResourceGroupCollection resourceGroups = subscription.GetResourceGroups();
            NullableResponse<ResourceGroupResource> existing = await resourceGroups.GetIfExistsAsync(options.Name);
            if (existing.HasValue)
            {
                ResourceGroupResource resourceGroup = existing.Value!;
                if (!string.Equals(resourceGroup.Data.Location.Name, options.Location, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        $"Resource Group '{options.Name}' already exists in a different location.");
                }

                WriteResult(new ExecutionResult(options.Name, resourceGroup.Data.Location.Name, false, "Succeeded"));
                return 0;
            }

            if (options.WhatIf)
            {
                WriteResult(new ExecutionResult(options.Name, options.Location, false, "WhatIf"));
                return 0;
            }

            ArmOperation<ResourceGroupResource> operation = await resourceGroups.CreateOrUpdateAsync(
                WaitUntil.Completed,
                options.Name,
                new ResourceGroupData(options.Location));

            ResourceGroupResource created = operation.Value;
            WriteResult(new ExecutionResult(
                created.Data.Name,
                created.Data.Location.Name,
                true,
                "Succeeded"));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(JsonSerializer.Serialize(new
            {
                status = "Failed",
                error = SanitizeError(exception.Message)
            }, JsonOptions));
            return 1;
        }
    }

    private static TokenCredential CreateCredential(CommandOptions options, LocalConfiguration configuration)
    {
        if (options.Authentication == AuthenticationMode.ManagedIdentity)
        {
            return string.IsNullOrWhiteSpace(options.ManagedIdentityClientId)
                ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
                : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(options.ManagedIdentityClientId));
        }

        string authRecordPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".azure",
            "ms-azuretools.vscode-azureresourcegroups",
            "authRecord.json");

        if (File.Exists(authRecordPath))
        {
            return new VisualStudioCodeCredential(new VisualStudioCodeCredentialOptions
            {
                TenantId = configuration.TenantId.ToString()
            });
        }

        return new InteractiveBrowserCredential(new InteractiveBrowserCredentialBrokerOptions(GetConsoleWindow())
        {
            TenantId = configuration.TenantId.ToString(),
            UseDefaultBrokerAccount = true
        });
    }

    private static void WriteResult(ExecutionResult result) =>
        Console.WriteLine(JsonSerializer.Serialize(result, JsonOptions));

    private static string SanitizeError(string message)
    {
        string sanitized = message;
        foreach (string value in LocalConfiguration.PrivateValues)
        {
            sanitized = sanitized.Replace(value, "[private-scope]", StringComparison.OrdinalIgnoreCase);
        }
        return sanitized;
    }

    [DllImport("kernel32.dll")]
    private static extern nint GetConsoleWindow();
}

internal static class OperationCatalog
{
    public static string ReadJson()
    {
        using Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(
            "AzureIQ.Execution.operations.json") ?? throw new InvalidOperationException(
                "The embedded AzureIQ operation catalog is unavailable.");
        using StreamReader reader = new(stream);
        return reader.ReadToEnd();
    }
}

internal sealed record ExecutionResult(string Name, string Location, bool Created, string ProvisioningState);

internal enum AuthenticationMode
{
    VisualStudioCode,
    ManagedIdentity
}

internal sealed record CommandOptions(
    string Name,
    string Location,
    string ConfigPath,
    AuthenticationMode Authentication,
    string? ManagedIdentityClientId,
    bool WhatIf)
{
    public static CommandOptions Parse(string[] args)
    {
        if (args.Length < 2 ||
            !string.Equals(args[0], "resource-group", StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(args[1], "ensure", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "Usage: azureiq operations list | azureiq resource-group ensure --name <name> --location <region> [--what-if] " +
                "[--authentication VisualStudioCode|ManagedIdentity] [--managed-identity-client-id <client-id>] " +
                "[--config <private-config-path>]");
        }

        Dictionary<string, string?> values = new(StringComparer.OrdinalIgnoreCase);
        for (int index = 2; index < args.Length; index++)
        {
            string argument = args[index];
            if (!argument.StartsWith("--", StringComparison.Ordinal))
            {
                throw new ArgumentException($"Unexpected argument '{argument}'.");
            }

            string key = argument[2..];
            if (string.Equals(key, "what-if", StringComparison.OrdinalIgnoreCase))
            {
                values[key] = "true";
                continue;
            }

            if (++index >= args.Length)
            {
                throw new ArgumentException($"Missing value for '--{key}'.");
            }
            values[key] = args[index];
        }

        string name = Required(values, "name");
        if (name.Length > 90 || name.Any(character => !(char.IsLetterOrDigit(character) || ".-_()".Contains(character))))
        {
            throw new ArgumentException("Resource Group name contains unsupported characters or exceeds 90 characters.");
        }

        string location = Required(values, "location");
        string configPath = values.GetValueOrDefault("config") ?? Path.Combine(
            Directory.GetCurrentDirectory(), "config", "local.azureiq.json");
        AuthenticationMode authentication = Enum.Parse<AuthenticationMode>(
            values.GetValueOrDefault("authentication") ?? nameof(AuthenticationMode.VisualStudioCode),
            ignoreCase: true);

        return new CommandOptions(
            name,
            location,
            configPath,
            authentication,
            values.GetValueOrDefault("managed-identity-client-id"),
            values.ContainsKey("what-if"));
    }

    private static string Required(IReadOnlyDictionary<string, string?> values, string key) =>
        values.TryGetValue(key, out string? value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required '--{key}' argument.");
}

internal sealed record LocalConfiguration(string Mode, ScopeConfiguration Scope, SafetyConfiguration Safety)
{
    public static HashSet<string> PrivateValues { get; } = new(StringComparer.OrdinalIgnoreCase);

    public Guid TenantId => Guid.Parse(Scope.TenantId);
    public Guid SubscriptionId => Guid.Parse(Scope.SubscriptionIds.Single());

    public static async Task<LocalConfiguration> LoadAsync(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Private AzureIQ configuration was not found.");
        }

        await using FileStream stream = File.OpenRead(path);
        LocalConfiguration configuration = await JsonSerializer.DeserializeAsync<LocalConfiguration>(
            stream,
            ProgramEntry.JsonOptions) ?? throw new InvalidOperationException("Private AzureIQ configuration is invalid.");

        configuration.ValidateForRead();
        PrivateValues.Add(configuration.Scope.TenantId);
        foreach (string subscriptionId in configuration.Scope.SubscriptionIds)
        {
            PrivateValues.Add(subscriptionId);
        }
        return configuration;
    }

    public void ValidateForSupervisedExecution()
    {
        ValidateForRead();
        if (!string.Equals(Mode, "supervised-management", StringComparison.Ordinal) ||
            !string.Equals(Safety.AzureWrites, "supervised", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Resource Group creation requires supervised-management mode.");
        }
        if (!Safety.RequireExactScope || !Safety.RequireExplicitApproval)
        {
            throw new InvalidOperationException("Exact-scope and explicit-approval controls are required.");
        }
        if (Safety.AutomaticRiskTiers is { Count: > 0 })
        {
            throw new InvalidOperationException("Automatic execution is not permitted during initial supervised management.");
        }
    }

    public void ValidateForRead()
    {
        if (Mode is not ("bootstrap-read-only" or "supervised-management") ||
            Scope is null || Safety is null ||
            Scope.SubscriptionIds is not { Count: 1 } ||
            !Guid.TryParse(Scope.TenantId, out Guid tenant) || tenant == Guid.Empty ||
            !Guid.TryParse(Scope.SubscriptionIds[0], out Guid subscription) || subscription == Guid.Empty ||
            Scope.ExcludedSubscriptionIds?.Contains(Scope.SubscriptionIds[0], StringComparer.OrdinalIgnoreCase) == true)
        {
            throw new InvalidOperationException("One valid, non-excluded private tenant/subscription scope is required.");
        }
        if (!Safety.RequireExactScope || !Safety.RequireExplicitApproval)
        {
            throw new InvalidOperationException("Exact-scope and explicit-approval controls are required.");
        }
        if (Safety.ApprovalExpiresAfterMinutes is < 1 or > 30)
        {
            throw new InvalidOperationException("Approval lifetime must be between one and thirty minutes.");
        }
    }
}

internal sealed record ScopeConfiguration(
    string TenantId, IReadOnlyList<string> SubscriptionIds, IReadOnlyList<string>? ExcludedSubscriptionIds = null);

internal sealed record SafetyConfiguration(
    string AzureWrites,
    bool RequireExactScope = true,
    bool RequireExplicitApproval = true,
    IReadOnlyList<string>? AutomaticRiskTiers = null,
    int ApprovalExpiresAfterMinutes = 30,
    IReadOnlyList<string>? PermittedSupervisedRiskTiers = null);