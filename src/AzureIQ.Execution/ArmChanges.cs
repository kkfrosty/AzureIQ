using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

namespace AzureIQ.Execution;

internal sealed record ArmSnapshot(JsonObject Body, string? ETag);
internal sealed record ReadRequirement(
    string Target, string ApiVersion, JsonObject Expected, string[]? AllowedSkuNames,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string[]? EmptyArrays = null);
internal sealed record ChangePlan(
    string Id, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt,
    string ArtifactId, string ArtifactVersion, string ArtifactDigest, string ContextDigest,
    string Target, string ApiVersion, JsonObject? Desired, ArmSnapshot? Before,
    string Risk, string Summary, string Verification, ReadRequirement[] Requirements, string? RollbackOf,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] CliBinding? Cli = null);
internal sealed record ChangeApproval(string PlanDigest, DateTimeOffset ApprovedAt, DateTimeOffset ExpiresAt);

internal interface IArmChanges
{
    Task<ArmSnapshot?> ReadAsync(string target, string apiVersion);
    Task WriteAsync(string target, string apiVersion, JsonObject? body, string? etag, bool create, CliBinding? cli = null);
}

internal sealed class ArmChanges(HttpClient client, TokenCredential credential, AzureCliRecipeRunner? cliRunner = null) : IArmChanges
{
    public async Task<ArmSnapshot?> ReadAsync(string target, string apiVersion)
    {
        using HttpRequestMessage request = await RequestAsync(HttpMethod.Get, target, apiVersion);
        using HttpResponseMessage response = await client.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
        EnsureSuccess(response);
        JsonObject body = JsonNode.Parse(await response.Content.ReadAsStringAsync()) as JsonObject
            ?? throw new InvalidOperationException("ARM returned an invalid object.");
        string? etag = response.Headers.ETag?.ToString() ?? body["etag"]?.GetValue<string>();
        return new ArmSnapshot(Normalize(body,
            target.Contains("/providers/Microsoft.Insights/", StringComparison.OrdinalIgnoreCase)), etag);
    }

    public async Task WriteAsync(string target, string apiVersion, JsonObject? body, string? etag, bool create, CliBinding? cli = null)
    {
        if (cli is not null)
        {
            await (cliRunner ?? throw new InvalidOperationException("The controlled CLI adapter is unavailable."))
                .ExecuteAsync(target, body, cli);
            return;
        }
        if (target.Contains("/providers/Microsoft.Network/", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Network writes require an admitted CLI recipe, never a bare ARM replacement.");
        }
        using HttpRequestMessage request = await RequestAsync(
            body is null ? HttpMethod.Delete : HttpMethod.Put, target, apiVersion);
        if (etag is not null)
        {
            request.Headers.TryAddWithoutValidation("If-Match", etag);
        }
        else if (create)
        {
            request.Headers.TryAddWithoutValidation("If-None-Match", "*");
        }
        if (body is not null)
        {
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        }
        using HttpResponseMessage response = await client.SendAsync(request);
        EnsureSuccess(response);
    }

    private async Task<HttpRequestMessage> RequestAsync(HttpMethod method, string target, string apiVersion)
    {
        AccessToken token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), CancellationToken.None);
        var request = new HttpRequestMessage(method,
            $"https://management.azure.com{target}?api-version={apiVersion}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return request;
    }

    private static void EnsureSuccess(HttpResponseMessage response)
    {
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"ARM request failed (HTTP {(int)response.StatusCode}); no response body was exported.");
        }
    }

    internal static JsonObject Normalize(JsonObject body, bool removeReadOnly = true)
    {
        var result = new JsonObject();
        foreach (string name in new[] { "location", "tags", "properties", "sku" })
        {
            if (body[name] is { } value)
            {
                result[name] = value.DeepClone();
            }
        }
        if (removeReadOnly && result["properties"] is JsonObject properties)
        {
            foreach (string name in new[] { "provisioningState", "createdTime", "lastUpdatedTime", "lastModifiedTime" })
            {
                properties.Remove(name);
            }
        }
        return result;
    }
}

internal sealed class ChangeWorkflow(
    string workspace, Guid subscription, IArmChanges arm, Func<Task<string>> context, Action assertWrites,
    TimeProvider? clock = null, TimeSpan? approvalLifetime = null,
    IReadOnlyList<string>? permittedRiskTiers = null, Func<Task<CliIdentity>>? cliIdentity = null)
{
    private readonly TimeProvider time = clock ?? TimeProvider.System;
    private readonly Guid privateSubscription = subscription;
    private readonly TimeSpan lifetime = approvalLifetime ?? TimeSpan.FromMinutes(30);
    private readonly IReadOnlyList<string> permittedRisks = permittedRiskTiers ?? ["R1", "R2", "R3"];
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    internal static string Digest(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    internal static string Canonical(JsonNode? node) => node switch
    {
        JsonObject obj => "{" + string.Join(",", obj.OrderBy(item => item.Key, StringComparer.Ordinal)
            .Select(item => JsonSerializer.Serialize(item.Key) + ":" + Canonical(item.Value))) + "}",
        JsonArray array => "[" + string.Join(",", array.Select(Canonical)) + "]",
        _ => node?.ToJsonString() ?? "null"
    };

    internal static string PlanDigest(ChangePlan plan) =>
        Digest(Canonical(JsonSerializer.SerializeToNode(plan, JsonOptions)));

    internal (JsonObject Package, string Digest) LoadPackage(string id, string version)
    {
        JsonObject catalog = ReadObject(Path.Combine(workspace, "artifacts", "catalog.json"));
        JsonObject artifact = catalog["artifacts"]!.AsArray().OfType<JsonObject>().Single(item =>
            item["id"]!.GetValue<string>() == id && item["version"]!.GetValue<string>() == version);
        Require(artifact["status"]!.GetValue<string>() is "candidate" or "validated" or "approved",
            "Artifact is not executable.");
        Require(artifact["kind"]!.GetValue<string>() is "rest-workflow" or "cli-workflow",
            "Expected a cataloged REST or controlled CLI workflow.");
        string expiry = artifact["validation"]!["expiresAt"]!.GetValue<string>();
        Require(DateOnly.Parse(expiry, System.Globalization.CultureInfo.InvariantCulture) >=
            DateOnly.FromDateTime(time.GetUtcNow().UtcDateTime), "Artifact validation has expired.");
        string source = Path.GetFullPath(Path.Combine(workspace, "artifacts",
            artifact["source"]!["path"]!.GetValue<string>()));
        string[] roots = ["observability", "networking"];
        Require(roots.Any(root => source.StartsWith(
            Path.Combine(workspace, "artifacts", root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)),
            "Package source is outside its admitted root.");
        RejectReparsePoints(source);
        string text = File.ReadAllText(source).Replace("\r\n", "\n").Replace("\r", "\n");
        string digest = Digest(text);
        Require(digest == artifact["source"]!["sha256"]!.GetValue<string>(), "Artifact digest mismatch.");
        JsonObject package = JsonNode.Parse(text)!.AsObject();
        Require(package["id"]!.GetValue<string>() == id && package["version"]!.GetValue<string>() == version,
            "Package identity differs from the catalog.");
        return (package, digest);
    }

    internal (string Target, string ApiVersion, JsonObject Body, string Digest, JsonObject Package,
        ReadRequirement[] Requirements, CliBinding? Cli) Resolve(
        string id, string version, JsonObject parameters, Guid subscription)
    {
        (JsonObject package, string digest) = LoadPackage(id, version);
        JsonObject definitions = package["parameters"]!.AsObject();
        Require(parameters.All(item => definitions.ContainsKey(item.Key)), "Unknown package parameter.");
        foreach ((string name, JsonNode? definition) in definitions)
        {
            JsonNode value = parameters[name] ?? throw new InvalidOperationException($"Missing parameter: {name}.");
            string type = definition!["type"]!.GetValue<string>();
            if (type == "string")
            {
                string text = value.GetValue<string>();
                Require(text.Length <= 2048 && Regex.IsMatch(text, definition["pattern"]!.GetValue<string>(),
                    RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)), $"Invalid parameter: {name}.");
            }
            else if (type == "number")
            {
                double number = JsonSerializer.Deserialize<double>(value.ToJsonString());
                Require(double.IsFinite(number) && number >= definition["minimum"]!.GetValue<double>() &&
                    number <= definition["maximum"]!.GetValue<double>(), $"Invalid numeric parameter: {name}.");
            }
            else
            {
                throw new InvalidOperationException("Unsupported parameter type.");
            }
        }
        JsonObject values = parameters.DeepClone().AsObject();
        values["subscriptionId"] = subscription.ToString();
        JsonNode? Render(JsonNode? node)
        {
            if (node is JsonObject obj)
            {
                var result = new JsonObject();
                foreach ((string key, JsonNode? value) in obj)
                {
                    result[key] = Render(value);
                }
                return result;
            }
            if (node is JsonArray array)
            {
                return new JsonArray(array.Select(item => Render(item)).ToArray());
            }
            if (node is JsonValue scalar && scalar.TryGetValue(out string? text))
            {
                if (text.StartsWith("{{", StringComparison.Ordinal) && text.EndsWith("}}", StringComparison.Ordinal) &&
                    text.Count(character => character == '{') == 2)
                {
                    return values[text[2..^2]]?.DeepClone()
                        ?? throw new InvalidOperationException("Unknown package binding.");
                }
                return JsonValue.Create(Regex.Replace(text, @"\{\{([A-Za-z][A-Za-z0-9]*)\}\}", match =>
                {
                    JsonNode binding = values[match.Groups[1].Value]
                        ?? throw new InvalidOperationException("Unknown string binding.");
                    return binding is JsonValue value && value.TryGetValue(out string? stringValue)
                        ? stringValue : binding.ToJsonString();
                }));
            }
            return node?.DeepClone();
        }
        string target = Render(package["target"])?.GetValue<string>()
            ?? throw new InvalidOperationException("Package target is missing.");
        string apiVersion = package["apiVersion"]!.GetValue<string>();
        ValidateTarget(target, apiVersion, subscription);
        JsonObject body = Render(package["body"]) as JsonObject
            ?? throw new InvalidOperationException("Package body must be an object.");
        ValidateReferences(body, subscription);
        ReadRequirement[] requirements = package["checks"] is JsonArray checks
            ? JsonSerializer.Deserialize<ReadRequirement[]>((Render(checks)
                ?? throw new InvalidOperationException("Package checks are missing.")).ToJsonString(), JsonOptions)!
            : [];
        foreach (ReadRequirement requirement in requirements)
        {
            ValidateReadTarget(requirement, subscription);
        }
        CliBinding? cli = null;
        if (package["cli"] is JsonObject recipe)
        {
            string[] arguments = Render(recipe["arguments"])!.AsArray().Select(item => item!.GetValue<string>()).ToArray();
            string[] rollback = Render(recipe["rollbackArguments"])!.AsArray().Select(item => item!.GetValue<string>()).ToArray();
            cli = new CliBinding(arguments, rollback, "", "");
            AzureCliRecipeRunner.Validate(target, body, cli, subscription);
        }
        Require(AzureCliRecipeRunner.IsSubnet(target, subscription) == (cli is not null),
            "Subnet packages require the controlled CLI lane; other targets cannot use it.");
        return (target, apiVersion, body, digest, package, requirements, cli);
    }

    internal async Task<string> PlanAsync(string id, string version, JsonObject parameters, Guid subscription)
    {
        Require(subscription == privateSubscription, "Planning subscription differs from private scope.");
        var resolved = Resolve(id, version, parameters, subscription);
        Require(lifetime >= TimeSpan.FromMinutes(1) && lifetime <= TimeSpan.FromMinutes(30), "Invalid approval lifetime.");
        string fingerprint = await context();
        await CheckRequirementsAsync(resolved.Requirements);
        ArmSnapshot? before = await arm.ReadAsync(resolved.Target, resolved.ApiVersion);
        if (before is not null)
        {
            ValidateSnapshotReferences(before.Body, subscription, resolved.Cli is not null);
        }
        CliBinding? cli = resolved.Cli;
        if (cli is not null)
        {
            Require(before is not null && AzureCliRecipeRunner.Services(before.Body).Length == 0,
                "This initialization recipe requires an existing subnet with no service endpoints.");
            CliIdentity identity = await (cliIdentity ??
                throw new InvalidOperationException("CLI identity verification is unavailable."))();
            cli = cli with { Version = identity.Version, ContextDigest = identity.Digest };
        }
        Require(await context() == fingerprint, "Authentication or private policy changed during planning.");
        DateTimeOffset now = time.GetUtcNow();
        var plan = new ChangePlan("CHG-" + Guid.NewGuid().ToString("N").ToUpperInvariant(),
            now, now.Add(lifetime), id, version, resolved.Digest, fingerprint,
            resolved.Target, resolved.ApiVersion, resolved.Body, before, PackageRisk(resolved.Package),
            resolved.Package["summary"]!.GetValue<string>(),
            resolved.Package["verification"]!.GetValue<string>(), resolved.Requirements, null, cli);
        return SavePlan(plan);
    }

    internal ChangePlan ReadPlan(string path)
    {
        AssertPrivatePath(path);
        ChangePlan plan = JsonSerializer.Deserialize<ChangePlan>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidOperationException("Invalid change plan.");
        Require(plan.Id == Path.GetFileName(Path.GetDirectoryName(Path.GetFullPath(path))),
            "Plan ID differs from its private directory.");
        return plan;
    }

    internal async Task ApproveAsync(string path, string digest)
    {
        ChangePlan plan = ReadPlan(path);
        await CheckPlanAsync(plan);
        assertWrites();
        Require(digest == PlanDigest(plan), "Approval digest differs from the reviewed plan.");
        string approvalPath = Path.Combine(Path.GetDirectoryName(path)!, "approval.json");
        Require(!File.Exists(approvalPath), "This plan already has an approval; create a fresh plan instead.");
        WriteNew(approvalPath, new ChangeApproval(digest, time.GetUtcNow(), plan.ExpiresAt));
    }

    internal async Task ApplyAsync(string path)
    {
        ChangePlan plan = ReadPlan(path);
        using FileStream executionLock = new(Path.Combine(workspace, ".azureiq", "plans", "execution.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        await CheckPlanAsync(plan);
        assertWrites();
        string directory = Path.GetDirectoryName(path)!;
        string approvalPath = Path.Combine(directory, "approval.json");
        AssertPrivatePath(approvalPath);
        ChangeApproval approval = JsonSerializer.Deserialize<ChangeApproval>(
            File.ReadAllText(approvalPath), JsonOptions) ?? throw new InvalidOperationException("Approval is missing.");
        Require(approval.PlanDigest == PlanDigest(plan) &&
            approval.ApprovedAt >= plan.CreatedAt && approval.ApprovedAt <= time.GetUtcNow() &&
            approval.ExpiresAt <= plan.ExpiresAt && approval.ExpiresAt > time.GetUtcNow(),
            "Approval is expired or does not match the plan.");
        if (plan.Desired is null)
        {
            string rollbackPath = plan.RollbackOf
                ?? throw new InvalidOperationException("Deletion is allowed only as a separately approved rollback.");
            ChangePlan original = ReadPlan(rollbackPath);
            Require(original.Before is null && original.Target == plan.Target &&
                File.Exists(Path.Combine(Path.GetDirectoryName(rollbackPath)!, "attempt.json")) &&
                Matches(original.Desired, plan.Before?.Body, IsDiagnosticSetting(original.Target)),
                "Rollback deletion lacks matching original evidence.");
        }
        ArmSnapshot? current = await arm.ReadAsync(plan.Target, plan.ApiVersion);
        Require(SameState(current, plan.Before), "Target state changed after planning; replan.");
        Require(await context() == plan.ContextDigest, "Private policy or execution identity changed.");
        await CheckCliAsync(plan);
        assertWrites();
        string attemptPath = Path.Combine(directory, "attempt.json");
        WriteAudit(plan, "inconclusive", "not-run");
        using FileStream claim = new(attemptPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        await JsonSerializer.SerializeAsync(claim, new { status = "Attempted", at = time.GetUtcNow() }, JsonOptions);
        await claim.FlushAsync();
        try
        {
            await arm.WriteAsync(plan.Target, plan.ApiVersion, plan.Desired, current?.ETag, current is null, plan.Cli);
            bool matched = await VerifyAsync(path);
            WriteNew(Path.Combine(directory, "result.json"),
                new { status = matched ? "ConfigurationMatched" : "ReadbackPending", independentVerificationRequired = true });
            WriteAudit(plan, matched ? "succeeded" : "inconclusive", "not-run");
            Require(matched, "Write was accepted, but readback has not matched. Verify before any further change.");
        }
        catch (Exception)
        {
            WriteAudit(plan, "inconclusive", "not-run");
            throw;
        }
    }

    internal async Task<bool> VerifyAsync(string path)
    {
        ChangePlan plan = ReadPlan(path);
        await CheckPlanAsync(plan, allowExpired: true, writePreconditions: false);
        ArmSnapshot? current = await arm.ReadAsync(plan.Target, plan.ApiVersion);
        if (plan.Cli is not null)
        {
            return AzureCliRecipeRunner.MatchesState(plan, current);
        }
        return plan.Desired is null ? current is null :
            Matches(plan.Desired, current?.Body, IsDiagnosticSetting(plan.Target));
    }

    internal async Task<string> RollbackPlanAsync(string path)
    {
        ChangePlan original = ReadPlan(path);
        await CheckPlanAsync(original, allowExpired: true, writePreconditions: false);
        Require(original.RollbackOf is null, "Plan a new forward change rather than rolling back a rollback.");
        Require(File.Exists(Path.Combine(Path.GetDirectoryName(path)!, "attempt.json")),
            "No write attempt exists to roll back.");
        ArmSnapshot? current = await arm.ReadAsync(original.Target, original.ApiVersion);
        Require(original.Cli is not null ? AzureCliRecipeRunner.MatchesState(original, current) :
            Matches(original.Desired, current?.Body, IsDiagnosticSetting(original.Target)),
            "Current state does not match the forward change; investigate before rollback.");
        DateTimeOffset now = time.GetUtcNow();
        return SavePlan(original with
        {
            Id = "CHG-" + Guid.NewGuid().ToString("N").ToUpperInvariant(),
            CreatedAt = now, ExpiresAt = now.Add(lifetime),
            Before = current, Desired = original.Before?.Body, Risk = original.Before is null ? "R3" : original.Risk,
            Summary = "Restore the captured pre-change configuration; delete only if this change created the resource.",
            RollbackOf = Path.GetFullPath(path),
            Cli = original.Cli is null ? null : original.Cli with
            {
                Arguments = original.Cli.RollbackArguments,
                RollbackArguments = original.Cli.Arguments,
                IsRollback = true
            }
        });
    }

    private async Task CheckPlanAsync(ChangePlan plan, bool allowExpired = false, bool writePreconditions = true)
    {
        var package = LoadPackage(plan.ArtifactId, plan.ArtifactVersion);
        string expectedRisk = plan.RollbackOf is not null && plan.Desired is null ? "R3" : PackageRisk(package.Package);
        Require(plan.Risk == expectedRisk && permittedRisks.Contains(plan.Risk),
            "Change risk is not permitted by the effective supervised policy.");
        DateTimeOffset now = time.GetUtcNow();
        Require(plan.CreatedAt <= now && plan.ExpiresAt > plan.CreatedAt &&
            plan.ExpiresAt - plan.CreatedAt <= lifetime &&
            (allowExpired || plan.ExpiresAt > now), "Plan is invalid or expired.");
        Require(package.Digest == plan.ArtifactDigest, "Package changed after planning.");
        Require(await context() == plan.ContextDigest, "Private policy or execution identity changed; replan.");
        Require(plan.ApiVersion == package.Package["apiVersion"]!.GetValue<string>(), "Plan API version changed.");
        ValidateTarget(plan.Target, plan.ApiVersion, privateSubscription);
        if (plan.Desired is not null)
        {
            ValidateSnapshotReferences(plan.Desired, privateSubscription, plan.Cli is not null);
        }
        await CheckRequirementsAsync(plan.Requirements, writePreconditions && plan.RollbackOf is null);
        Require((package.Package["cli"] is not null) == (plan.Cli is not null), "Plan execution lane changed.");
        if (plan.Cli is not null)
        {
            Require(plan.Cli.IsRollback == (plan.RollbackOf is not null), "CLI rollback marker differs from the plan.");
            AzureCliRecipeRunner.Validate(plan.Target, plan.Desired, plan.Cli, privateSubscription);
            if (plan.RollbackOf is null)
            {
                Require(Canonical(plan.Desired) == Canonical(package.Package["body"]), "CLI desired state differs from its package.");
            }
            await CheckCliAsync(plan);
        }
    }

    private static string PackageRisk(JsonObject package)
    {
        string risk = package["risk"]?.GetValue<string>() ?? "R2";
        Require(risk is "R2" or "R3", "Package risk is unsupported.");
        return risk;
    }

    private async Task CheckCliAsync(ChangePlan plan)
    {
        if (plan.Cli is null)
        {
            return;
        }
        CliIdentity current = await (cliIdentity ??
            throw new InvalidOperationException("CLI identity verification is unavailable."))();
        Require(current.Version == plan.Cli.Version && current.Digest == plan.Cli.ContextDigest,
            "CLI version, executable, account, or identity changed; replan.");
    }

    private async Task CheckRequirementsAsync(ReadRequirement[] requirements, bool checkEmptyArrays = true)
    {
        foreach (ReadRequirement requirement in requirements)
        {
            ValidateReadTarget(requirement, privateSubscription);
            ArmSnapshot? state = await arm.ReadAsync(requirement.Target, requirement.ApiVersion);
            Require(state is not null && Matches(requirement.Expected, state.Body),
                "A required resource is absent, inaccessible, disabled, or not ready.");
            if (requirement.AllowedSkuNames is { Length: > 0 })
            {
                string? sku = state?.Body["sku"]?["name"]?.GetValue<string>();
                Require(sku is not null && requirement.AllowedSkuNames.Contains(sku, StringComparer.OrdinalIgnoreCase),
                    "The observed service SKU is unsupported by this package.");
            }
            foreach (string path in checkEmptyArrays ? requirement.EmptyArrays ?? [] : [])
            {
                JsonNode? value = state?.Body;
                foreach (string part in path.Split('.'))
                {
                    value = value?[part];
                }
                Require(value is null or JsonArray { Count: 0 }, "A required empty collection is already configured.");
            }
        }
    }

    private static void ValidateReadTarget(ReadRequirement requirement, Guid subscription)
    {
        string name = @"[A-Za-z0-9_.()-]{1,90}";
        string prefix = $"/subscriptions/{subscription}/resourceGroups/{name}/providers/";
        bool supported = (Regex.IsMatch(requirement.Target, $"^{prefix}Microsoft.ApiManagement/service/{name}$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) && requirement.ApiVersion == "2024-05-01") ||
            (Regex.IsMatch(requirement.Target, $"^{prefix}Microsoft.OperationalInsights/workspaces/{name}$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) && requirement.ApiVersion == "2022-10-01") ||
            (Regex.IsMatch(requirement.Target, $"^{prefix}Microsoft.Insights/actionGroups/{name}$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) && requirement.ApiVersion == "2023-01-01") ||
            (AzureCliRecipeRunner.IsSubnet(requirement.Target, subscription) && requirement.ApiVersion == "2024-05-01");
        Require(supported, "Preflight resource is outside the admitted read surface.");
    }

    private string SavePlan(ChangePlan plan)
    {
        string path = Path.Combine(workspace, ".azureiq", "plans", plan.Id, "plan.json");
        AssertPrivatePath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        WriteNew(path, plan);
        return path;
    }

    internal void AssertPrivatePath(string path)
    {
        string root = Path.GetFullPath(Path.Combine(workspace, ".azureiq", "plans")) + Path.DirectorySeparatorChar;
        Require(Path.GetFullPath(path).StartsWith(root, StringComparison.OrdinalIgnoreCase), "Plans must remain in ignored private storage.");
        Require(File.ReadLines(Path.Combine(workspace, ".gitignore")).Any(line => line.Trim() == ".azureiq/plans/"),
            "Private plan storage must be Git-ignored.");
        RejectReparsePoints(path);
    }

    private static void RejectReparsePoints(string path)
    {
        for (string? current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
        {
            if (Path.Exists(current))
            {
                Require((File.GetAttributes(current) & FileAttributes.ReparsePoint) == 0,
                    "Reparse-point paths are not admitted.");
            }
        }
    }

    internal static void ValidateTarget(string target, string apiVersion, Guid subscription)
    {
        string prefix = "/subscriptions/" + subscription;
        string name = @"[A-Za-z0-9_.()-]{1,90}";
        bool diagnostics = Regex.IsMatch(target,
            $"^{prefix}(?:/resourceGroups/{name}/providers/Microsoft.ApiManagement/service/[A-Za-z0-9-]{{1,50}})?/providers/Microsoft.Insights/diagnosticSettings/{name}$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        bool metric = Regex.IsMatch(target,
            $"^{prefix}/resourceGroups/{name}/providers/Microsoft.Insights/metricAlerts/{name}$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        bool query = Regex.IsMatch(target,
            $"^{prefix}/resourceGroups/{name}/providers/Microsoft.Insights/scheduledQueryRules/{name}$",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        Require((diagnostics && apiVersion == "2021-05-01-preview") ||
            (metric && apiVersion == "2018-03-01") || (query && apiVersion == "2023-12-01") ||
            (AzureCliRecipeRunner.IsSubnet(target, subscription) && apiVersion == "2024-05-01"),
            "Resource target or API version is outside the admitted change surface.");
    }

    private static void ValidateReferences(JsonNode node, Guid subscription)
    {
        if (node is JsonObject obj)
        {
            foreach ((string name, JsonNode? child) in obj)
            {
                bool empty = child is null || child is JsonObject { Count: 0 } || child is JsonArray { Count: 0 };
                Require(empty || !Regex.IsMatch(name, "password|secret|connectionString|authorization|webhook",
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), "Secret-bearing fields are not admitted.");
                if (child is not null)
                {
                    ValidateReferences(child, subscription);
                }
            }
        }
        else if (node is JsonArray array)
        {
            foreach (JsonNode child in array.OfType<JsonNode>())
            {
                ValidateReferences(child, subscription);
            }
        }
        else if (node is JsonValue value && value.TryGetValue(out string? text))
        {
            foreach (Match match in Regex.Matches(text, @"/subscriptions/([^/\s'"";]+)", RegexOptions.IgnoreCase))
            {
                Require(Guid.TryParse(match.Groups[1].Value, out Guid reference) && reference == subscription,
                    "Cross-subscription body references are not admitted.");
            }
            Require(!text.Contains("://", StringComparison.Ordinal), "External URL values are not admitted.");
        }
    }

    private static void ValidateSnapshotReferences(JsonObject body, Guid subscription, bool subnetSnapshot)
    {
        if (!subnetSnapshot)
        {
            ValidateReferences(body, subscription);
            return;
        }
        JsonObject inspection = body.DeepClone().AsObject();
        if (inspection["properties"]?["ipConfigurations"] is JsonArray associations)
        {
            foreach (JsonNode? value in associations)
            {
                Require(value is JsonObject { Count: 1 } reference &&
                    reference["id"] is JsonValue id && id.TryGetValue(out string? text) &&
                    Regex.IsMatch(text,
                        @"^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.(?:Network|Compute)/(?:[A-Za-z0-9_.()-]+/)+(?:ipConfigurations|frontendIPConfigurations)/[A-Za-z0-9_.()-]+$",
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant),
                    "Unrecognized read-only subnet IP-configuration reference.");
            }
            // These associations are opaque read-only data, never CLI arguments or a write body.
            inspection["properties"]!.AsObject().Remove("ipConfigurations");
        }
        ValidateReferences(inspection, subscription);
    }

    private static bool IsDiagnosticSetting(string target) =>
        target.Contains("/providers/Microsoft.Insights/diagnosticSettings/", StringComparison.OrdinalIgnoreCase);

    internal static bool Matches(JsonNode? expected, JsonNode? actual, bool allowDisabledExportDefaults = false)
    {
        if (expected is JsonObject obj && actual is JsonObject other)
        {
            return obj.All(item => other.ContainsKey(item.Key) && Matches(item.Value, other[item.Key],
                allowDisabledExportDefaults && item.Key is "properties" or "logs" or "metrics"));
        }
        if (expected is JsonArray array && actual is JsonArray otherArray)
        {
            var remaining = otherArray.ToList();
            foreach (JsonNode? item in array)
            {
                int match = remaining.FindIndex(candidate => Matches(item, candidate));
                if (match < 0)
                {
                    return false;
                }
                remaining.RemoveAt(match);
            }
            // ARM can expand diagnostic settings with additional disabled category defaults.
            return remaining.Count == 0 || allowDisabledExportDefaults && remaining.All(item =>
                item is JsonObject category && category["enabled"] is JsonValue enabled &&
                enabled.TryGetValue(out bool active) && !active &&
                (category["category"] is JsonValue || category["categoryGroup"] is JsonValue));
        }
        return JsonNode.DeepEquals(expected, actual);
    }

    private static bool SameState(ArmSnapshot? left, ArmSnapshot? right) =>
        left?.ETag == right?.ETag && Canonical(left?.Body) == Canonical(right?.Body);

    private void WriteAudit(ChangePlan plan, string status, string verdict)
    {
        string run = "RUN-" + Guid.NewGuid().ToString("N").ToUpperInvariant();
        string directory = Path.Combine(workspace, ".azureiq", "runs", run);
        Require(File.ReadLines(Path.Combine(workspace, ".gitignore")).Any(line => line.Trim() == ".azureiq/runs/"),
            "Run storage must be Git-ignored.");
        RejectReparsePoints(directory);
        Directory.CreateDirectory(directory);
        WriteNew(Path.Combine(directory, "execution-record.json"), new
        {
            schemaVersion = 1, runId = run, changeId = plan.Id, startedAt = plan.CreatedAt, completedAt = time.GetUtcNow(),
            intent = plan.Cli is null ? "Bounded observability configuration change" : "Bounded subnet service endpoint change",
            route = new { kind = plan.Cli is null ? "arm-rest" : "azureiq-cli", selector = "AzureIQ.Execution", operation = "change apply-approved", version = "0.1.0" },
            artifact = new { id = plan.ArtifactId, version = plan.ArtifactVersion, sha256 = plan.ArtifactDigest },
            authorization = new { mode = "supervised", status = "approved", manifestDigest = "sha256:" + PlanDigest(plan) },
            scope = new { reference = "private-local", environment = "operator-scoped" },
            inputs = new { parametersDigest = "sha256:" + PlanDigest(plan), containsSecrets = false },
            result = new
            {
                status, summary = "Write attempted; independent operational verification is required.",
                created = status == "succeeded" && plan.Before is null ? 1 : 0,
                modified = status == "succeeded" && plan.Before is not null && plan.Desired is not null ? 1 : 0,
                deleted = status == "succeeded" && plan.Desired is null ? 1 : 0
            },
            verification = new { verdict, evidenceRefs = new[] { plan.Id } },
            privacy = new { secretsStored = false, customerIdentifiersStored = false, rawPayloadsStored = false },
            learning = new { candidateArtifacts = Array.Empty<string>(), updateArtifacts = Array.Empty<string>(), incidentRecordRef = (string?)null }
        });
    }

    internal static JsonObject ReadObject(string path) => JsonNode.Parse(File.ReadAllText(path)) as JsonObject
        ?? throw new InvalidOperationException("Expected a JSON object.");

    private static void WriteNew<T>(string path, T value)
    {
        using FileStream stream = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        JsonSerializer.Serialize(stream, value, JsonOptions);
        stream.Flush(flushToDisk: true);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

internal static class ArmChangeCommand
{
    internal static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 1 || args.Length % 2 != 1)
        {
            throw new ArgumentException("Usage: change validate|plan|approve|apply-approved|verify|rollback-plan --option value");
        }
        string action = args[0];
        string[] allowed = action switch
        {
            "validate" or "plan" => ["artifact", "version", "parameters"],
            "approve" => ["plan", "digest"],
            "apply-approved" or "verify" or "rollback-plan" => ["plan"],
            _ => throw new ArgumentException("Unknown change command.")
        };
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int index = 1; index < args.Length; index += 2)
        {
            string name = args[index];
            if (!name.StartsWith("--", StringComparison.Ordinal) || !allowed.Contains(name[2..]) ||
                !options.TryAdd(name[2..], args[index + 1]))
            {
                throw new ArgumentException("Unknown or duplicate change option.");
            }
        }
        if (options.Count != allowed.Length)
        {
            throw new ArgumentException("All documented command options are required.");
        }
        string workspace = Directory.GetCurrentDirectory();
        string configurationPath = Path.Combine(workspace, "config", "local.azureiq.json");
        LocalConfiguration configuration = await LocalConfiguration.LoadAsync(configurationPath);
        configuration.ValidateForRead();
        string policyText = File.ReadAllText(configurationPath);
        string trackedPolicy = File.ReadAllText(Path.Combine(workspace, "config", "azureiq.yaml"));
        TokenCredential credential = new VisualStudioCodeCredential(new VisualStudioCodeCredentialOptions
        {
            TenantId = configuration.TenantId.ToString()
        });
        string currentPrincipal = "";
        async Task<string> Context()
        {
            if (File.ReadAllText(configurationPath) != policyText ||
                File.ReadAllText(Path.Combine(workspace, "config", "azureiq.yaml")) != trackedPolicy)
            {
                throw new InvalidOperationException("Private policy changed during this operation.");
            }
            AccessToken token = await credential.GetTokenAsync(
                new TokenRequestContext(["https://management.azure.com/.default"]), CancellationToken.None);
            var (tenant, principal) = AzureCliRecipeRunner.TokenIdentity(token);
            if (!Guid.TryParse(tenant, out Guid actualTenant) || actualTenant != configuration.TenantId ||
                !Guid.TryParse(principal, out _))
            {
                throw new InvalidOperationException("Authenticated tenant or principal is invalid for private scope.");
            }
            currentPrincipal = principal;
            return ChangeWorkflow.Digest(policyText + trackedPolicy + tenant + principal);
        }
        string expectedPrincipal = JsonNode.Parse(policyText)?["identity"]?["interactivePrincipal"]?.GetValue<string>() ?? "";
        var cli = new AzureCliRecipeRunner(configuration, expectedPrincipal);
        async Task<CliIdentity> CliContext()
        {
            string sdkContext = await Context();
            CliIdentity identity = await cli.IdentityAsync(currentPrincipal);
            return identity with { Digest = ChangeWorkflow.Digest(sdkContext + identity.Digest) };
        }
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(60) };
        var workflow = new ChangeWorkflow(workspace, configuration.SubscriptionId, new ArmChanges(client, credential, cli), Context,
            configuration.ValidateForSupervisedExecution, approvalLifetime:
                TimeSpan.FromMinutes(configuration.Safety.ApprovalExpiresAfterMinutes),
            permittedRiskTiers: configuration.Safety.PermittedSupervisedRiskTiers, cliIdentity: CliContext);
        if (action is "validate" or "plan")
        {
            JsonObject parameters = ChangeWorkflow.ReadObject(options["parameters"]);
            _ = workflow.Resolve(options["artifact"], options["version"], parameters, configuration.SubscriptionId);
            if (action == "validate")
            {
                Console.WriteLine(JsonSerializer.Serialize(new { status = "PackageValidated", mutatesAzure = false, validation = "offline-only" }));
                return 0;
            }
            string path = await workflow.PlanAsync(options["artifact"], options["version"], parameters, configuration.SubscriptionId);
            Console.WriteLine(JsonSerializer.Serialize(new { status = "PlanCreated", plan = path, digest = ChangeWorkflow.PlanDigest(workflow.ReadPlan(path)), mutatesAzure = false }));
            return 0;
        }
        string planPath = Path.GetFullPath(options["plan"]);
        ChangePlan plan = workflow.ReadPlan(planPath);
        ChangeWorkflow.ValidateTarget(plan.Target, plan.ApiVersion, configuration.SubscriptionId);
        switch (action)
        {
            case "approve":
                await workflow.ApproveAsync(planPath, options["digest"]);
                break;
            case "apply-approved":
                await workflow.ApplyAsync(planPath);
                break;
            case "verify":
                bool matched = await workflow.VerifyAsync(planPath);
                Console.WriteLine(JsonSerializer.Serialize(new { status = matched ? "ConfigurationMatched" : "ConfigurationMismatch", independentOperationalVerificationRequired = true }));
                return matched ? 0 : 3;
            case "rollback-plan":
                string rollback = await workflow.RollbackPlanAsync(planPath);
                Console.WriteLine(JsonSerializer.Serialize(new { status = "RollbackPlanCreated", plan = rollback, digest = ChangeWorkflow.PlanDigest(workflow.ReadPlan(rollback)), newApprovalRequired = true }));
                return 0;
        }
        Console.WriteLine(JsonSerializer.Serialize(new { status = "Completed", independentOperationalVerificationRequired = true }));
        return 0;
    }
}
