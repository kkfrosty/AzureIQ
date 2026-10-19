using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Azure.Core;

namespace AzureIQ.Execution.Tests;

public sealed class ChangeWorkflowTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "AzureIQ-Changes-" + Guid.NewGuid().ToString("N"));
    private readonly Guid subscription = Guid.NewGuid();
    private readonly FakeArm arm = new();
    private readonly TestClock clock = new();
    private string fingerprint = "private-policy-and-principal";
    private bool writesAllowed = true;
    private string cliFingerprint = "pinned-cli-identity";
    private ChangeWorkflow Workflow => new(directory, subscription, arm, () => Task.FromResult(fingerprint),
        () =>
        {
            if (!writesAllowed)
            {
                throw new InvalidOperationException("Writes denied.");
            }
        }, clock);
    private ChangeWorkflow CliWorkflow => new(directory, subscription, arm, () => Task.FromResult(fingerprint),
        () =>
        {
            if (!writesAllowed)
            {
                throw new InvalidOperationException("Writes denied.");
            }
        }, clock, cliIdentity: () => Task.FromResult(new CliIdentity("2.79.0", cliFingerprint)));

    public ChangeWorkflowTests()
    {
        Directory.CreateDirectory(Path.Combine(directory, "artifacts", "observability"));
        File.WriteAllText(Path.Combine(directory, ".gitignore"), ".azureiq/plans/\n.azureiq/runs/\n");
        JsonObject package = JsonNode.Parse("""
            {
              "id": "test.observability", "version": "0.1.0",
              "summary": "Bounded synthetic change", "verification": "Independent telemetry checks",
              "parameters": { "name": { "type": "string", "pattern": "^[A-Za-z0-9-]{1,30}$" } },
              "target": "/subscriptions/{{subscriptionId}}/providers/Microsoft.Insights/diagnosticSettings/{{name}}",
              "apiVersion": "2021-05-01-preview",
              "body": { "properties": { "logs": [ { "category": "Administrative", "enabled": true } ] } }
            }
            """)!.AsObject();
        string source = package.ToJsonString();
        File.WriteAllText(PackagePath, source);
        var catalog = new
        {
            artifacts = new[]
            {
                new
                {
                    id = "test.observability", version = "0.1.0", status = "candidate", kind = "rest-workflow",
                    source = new { path = "../artifacts/observability/test.json", sha256 = ChangeWorkflow.Digest(source) },
                    validation = new { expiresAt = "2026-12-31" }
                }
            }
        };
        File.WriteAllText(Path.Combine(directory, "artifacts", "catalog.json"), JsonSerializer.Serialize(catalog));
    }

    private string PackagePath => Path.Combine(directory, "artifacts", "observability", "test.json");
    private Task<string> PlanAsync() => Workflow.PlanAsync(
        "test.observability", "0.1.0", new JsonObject { ["name"] = "audit" }, subscription);
    private async Task<string> ApprovedPlanAsync()
    {
        string path = await PlanAsync();
        await Workflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(path)));
        return path;
    }

    [Fact]
    public async Task PlanningWorksWhileWritesAreDenied()
    {
        writesAllowed = false;
        string path = await PlanAsync();
        Assert.True(File.Exists(path));
        Assert.Equal(0, arm.Writes);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Workflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(path))));
    }

    [Fact]
    public async Task ApprovedChangeHasReadbackAndCannotBeReplayed()
    {
        string path = await ApprovedPlanAsync();
        await Workflow.ApplyAsync(path);
        Assert.Equal(1, arm.Writes);
        Assert.True(await Workflow.VerifyAsync(path));
        await Assert.ThrowsAnyAsync<Exception>(() => Workflow.ApplyAsync(path));
        Assert.Equal(1, arm.Writes);
        string[] audits = Directory.GetFiles(Path.Combine(directory, ".azureiq", "runs"),
            "execution-record.json", SearchOption.AllDirectories);
        Assert.Equal(2, audits.Length);
        Assert.All(audits, audit =>
        {
            string text = File.ReadAllText(audit);
            Assert.DoesNotContain(subscription.ToString(), text);
            Assert.DoesNotContain("/subscriptions/", text);
        });
    }

    [Fact]
    public async Task WritesDeniedAfterApprovalAreBlocked()
    {
        string path = await ApprovedPlanAsync();
        writesAllowed = false;
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task MissingApprovalIsNotAChangeAuthorization()
    {
        string path = await PlanAsync();
        await Assert.ThrowsAsync<FileNotFoundException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ApprovalBindsTheEntirePlan()
    {
        string path = await ApprovedPlanAsync();
        JsonObject json = ChangeWorkflow.ReadObject(path);
        json["desired"]!["properties"]!["logs"]![0]!["enabled"] = false;
        File.WriteAllText(path, json.ToJsonString());
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ApprovalExpiresAtExactBoundary()
    {
        string path = await ApprovedPlanAsync();
        clock.Now = clock.Now.AddMinutes(30);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ChangedPolicyOrPrincipalRequiresReplanning()
    {
        string path = await ApprovedPlanAsync();
        fingerprint = "different-principal";
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ArtifactDriftInvalidatesApproval()
    {
        string path = await ApprovedPlanAsync();
        File.AppendAllText(PackagePath, "\n ");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task StateDriftInvalidatesApproval()
    {
        string path = await ApprovedPlanAsync();
        arm.State = new ArmSnapshot(new JsonObject { ["properties"] = new JsonObject { ["unexpected"] = true } }, "changed");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ExistingStateIsCapturedAndRestoredBySeparatelyApprovedRollback()
    {
        JsonObject original = JsonNode.Parse("""{"properties":{"logs":[]}}""")!.AsObject();
        arm.State = new ArmSnapshot(original, "initial-etag");
        string path = await ApprovedPlanAsync();
        await Workflow.ApplyAsync(path);
        Assert.Equal("initial-etag", arm.LastETag);
        string rollback = await Workflow.RollbackPlanAsync(path);
        await Assert.ThrowsAsync<FileNotFoundException>(() => Workflow.ApplyAsync(rollback));
        await Workflow.ApproveAsync(rollback, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(rollback)));
        await Workflow.ApplyAsync(rollback);
        Assert.True(JsonNode.DeepEquals(original, arm.State?.Body));
    }

    [Fact]
    public async Task CreatedResourceIsDeletedOnlyThroughApprovedRollback()
    {
        string path = await ApprovedPlanAsync();
        await Workflow.ApplyAsync(path);
        string rollback = await Workflow.RollbackPlanAsync(path);
        Assert.Equal("R3", Workflow.ReadPlan(rollback).Risk);
        await Workflow.ApproveAsync(rollback, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(rollback)));
        await Workflow.ApplyAsync(rollback);
        Assert.Null(arm.State);
        Assert.Equal(2, arm.Writes);
    }

    [Fact]
    public async Task FailedWriteIsNotAutomaticallyRetried()
    {
        string path = await ApprovedPlanAsync();
        arm.FailWrite = true;
        await Assert.ThrowsAsync<HttpRequestException>(() => Workflow.ApplyAsync(path));
        await Assert.ThrowsAsync<IOException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(1, arm.Writes);
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(path)!, "attempt.json")));
    }

    [Fact]
    public async Task ReadbackMismatchIsExplicitNotSuccess()
    {
        string path = await ApprovedPlanAsync();
        arm.IgnoreWrite = true;
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.False(await Workflow.VerifyAsync(path));
        Assert.Equal(1, arm.Writes);
    }

    [Fact]
    public async Task CrossSubscriptionPlanIsRejectedEvenWithMatchingContext()
    {
        string path = await PlanAsync();
        JsonObject plan = ChangeWorkflow.ReadObject(path);
        plan["target"] = plan["target"]!.GetValue<string>().Replace(subscription.ToString(), Guid.NewGuid().ToString());
        File.WriteAllText(path, plan.ToJsonString());
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Workflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(path))));
    }

    [Theory]
    [InlineData("https://evil.example/path")]
    [InlineData("/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleAssignments/a")]
    [InlineData("/subscriptions/00000000-0000-0000-0000-000000000000/../providers/Microsoft.Insights/diagnosticSettings/a")]
    public void TargetsCannotEscapeAdmittedResources(string target) =>
        Assert.Throws<InvalidOperationException>(() =>
            ChangeWorkflow.ValidateTarget(target, "2021-05-01-preview", subscription));

    [Fact]
    public void ParameterInjectionAndUnknownBindingsAreRejected()
    {
        Assert.Throws<InvalidOperationException>(() => Workflow.Resolve("test.observability", "0.1.0",
            new JsonObject { ["name"] = "name/../../other" }, subscription));
        Assert.Throws<InvalidOperationException>(() => Workflow.Resolve("test.observability", "0.1.0",
            new JsonObject { ["name"] = "audit", ["subscriptionId"] = Guid.NewGuid().ToString() }, subscription));
    }

    [Fact]
    public void ReadbackIgnoresObjectDefaultsButNotExtraArrayEntries()
    {
        Assert.True(ChangeWorkflow.Matches(JsonNode.Parse("""{"enabled":true}"""),
            JsonNode.Parse("""{"enabled":true,"serverDefault":1}""")));
        Assert.False(ChangeWorkflow.Matches(JsonNode.Parse("""[{"enabled":true}]"""),
            JsonNode.Parse("""[{"enabled":true},{"enabled":false}]""")));
        Assert.True(ChangeWorkflow.Matches(JsonNode.Parse("""[1,2]"""), JsonNode.Parse("""[2,1]""")));
    }

    [Fact]
    public void DiagnosticReadbackAcceptsDisabledProviderDefaultsButRejectsAdditionalEnabledExports()
    {
        JsonNode expected = JsonNode.Parse("""
            {"properties":{"logs":[{"category":"GatewayLogs","enabled":true}],
            "metrics":[{"category":"AllMetrics","enabled":true}]}}
            """)!;
        JsonNode actual = JsonNode.Parse("""
            {"properties":{"logs":[
              {"category":"GatewayLogs","enabled":true,"retentionPolicy":{"enabled":false,"days":0}},
              {"category":"WebSocketConnectionLogs","enabled":false},
              {"category":"DeveloperPortalAuditLogs","enabled":false},
              {"category":"GatewayLlmLogs","enabled":false},
              {"category":"GatewayMCPLogs","enabled":false}],
            "metrics":[{"category":"AllMetrics","enabled":true,"retentionPolicy":{"enabled":false,"days":0}}]}}
            """)!;
        Assert.False(ChangeWorkflow.Matches(expected, actual));
        Assert.True(ChangeWorkflow.Matches(expected, actual, allowDisabledExportDefaults: true));
        actual["properties"]!["logs"]![1]!["enabled"] = true;
        Assert.False(ChangeWorkflow.Matches(expected, actual, allowDisabledExportDefaults: true));
        actual["properties"]!["logs"]![1]!["enabled"] = false;
        actual["properties"]!["logs"]![0]!["enabled"] = false;
        Assert.False(ChangeWorkflow.Matches(expected, actual, allowDisabledExportDefaults: true));
    }

    [Fact]
    public void DiagnosticDefaultHandlingDoesNotWeakenUnrelatedArraysOrAcceptUntypedEntries()
    {
        Assert.False(ChangeWorkflow.Matches(
            JsonNode.Parse("""{"properties":{"other":[1]}}"""),
            JsonNode.Parse("""{"properties":{"other":[1,{"category":"x","enabled":false}]}}"""), true));
        Assert.False(ChangeWorkflow.Matches(
            JsonNode.Parse("""{"properties":{"logs":[]}}"""),
            JsonNode.Parse("""{"properties":{"logs":[{"category":"x","enabled":"false"}]}}"""), true));
    }

    [Fact]
    public async Task ProviderDefaultsAllowReadbackAndRollbackWhilePreservingTheFullBeforeSnapshot()
    {
        JsonObject original = JsonNode.Parse("""
            {"properties":{"logs":[{"category":"Administrative","enabled":false},{"category":"Policy","enabled":false}]}}
            """)!.AsObject();
        arm.State = new ArmSnapshot(original, "\"before\"");
        arm.IncludeDisabledCategoryDefault = true;
        string path = await ApprovedPlanAsync();
        Assert.True(JsonNode.DeepEquals(original, Workflow.ReadPlan(path).Before!.Body));
        await Workflow.ApplyAsync(path);
        Assert.True(await Workflow.VerifyAsync(path));
        string rollback = await Workflow.RollbackPlanAsync(path);
        await Workflow.ApproveAsync(rollback, ChangeWorkflow.PlanDigest(Workflow.ReadPlan(rollback)));
        await Workflow.ApplyAsync(rollback);
        Assert.True(JsonNode.DeepEquals(original, arm.State?.Body));
        Assert.Equal(2, arm.Writes);
    }

    [Fact]
    public async Task PlanningWithRealClockDoesNotExceedApprovalLifetime()
    {
        var workflow = new ChangeWorkflow(directory, subscription, arm, () => Task.FromResult(fingerprint), () => { },
            approvalLifetime: TimeSpan.FromMinutes(5));
        string path = await workflow.PlanAsync("test.observability", "0.1.0", new JsonObject { ["name"] = "audit" }, subscription);
        ChangePlan plan = workflow.ReadPlan(path);
        Assert.Equal(TimeSpan.FromMinutes(5), plan.ExpiresAt - plan.CreatedAt);
        await workflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(plan));
    }

    [Fact]
    public void PrivatePathsCannotEscapeIgnoredStorage() =>
        Assert.Throws<InvalidOperationException>(() => Workflow.ReadPlan(Path.Combine(directory, "outside.json")));

    [Fact]
    public void ExpiredArtifactIsNotReused()
    {
        clock.Now = new DateTimeOffset(2027, 1, 1, 0, 0, 0, TimeSpan.Zero);
        Assert.Throws<InvalidOperationException>(() => Workflow.Resolve("test.observability", "0.1.0",
            new JsonObject { ["name"] = "audit" }, subscription));
    }

    [Theory]
    [InlineData("apim-gateway-logs")]
    [InlineData("activity-log-export")]
    [InlineData("apim-capacity-alert")]
    [InlineData("apim-failure-alert")]
    [InlineData("apim-latency-alert")]
    [InlineData("apim-telemetry-health-alert")]
    public void ActualCatalogPackagesResolveWithoutUnboundParameters(string name)
    {
        ChangeWorkflow workflow = RepositoryWorkflow();
        JsonObject parameters = PackageParameters(name);
        var resolved = workflow.Resolve("observability." + name, "0.1.0", parameters, subscription);
        Assert.DoesNotContain("{{", resolved.Body.ToJsonString());
        Assert.DoesNotContain("{{", resolved.Target);
        Assert.StartsWith("/subscriptions/" + subscription, resolved.Target);
        Assert.NotEmpty(resolved.Requirements);
        if (name == "apim-capacity-alert")
        {
            Assert.Equal(75, JsonSerializer.Deserialize<double>(
                resolved.Body["properties"]!["criteria"]!["allOf"]![0]!["threshold"]!.ToJsonString()));
            Assert.Contains("Premium", resolved.Requirements[0].AllowedSkuNames!);
        }
        else if (name.EndsWith("-alert", StringComparison.Ordinal))
        {
            string query = resolved.Body["properties"]!["criteria"]!["allOf"]![0]!["query"]!.GetValue<string>();
            Assert.Contains("ApiManagementGatewayLogs", query);
            if (name == "apim-telemetry-health-alert")
            {
                Assert.Contains("Requests > 0 and Logged == 0", query);
                Assert.Contains("ago(10m)", query);
            }
            else
            {
                Assert.Contains("Requests >= 100", query);
            }
        }
        if (parameters.ContainsKey("workspaceResourceId"))
        {
            parameters["workspaceResourceId"] = parameters["workspaceResourceId"]!.GetValue<string>()
                .Replace(subscription.ToString(), Guid.NewGuid().ToString());
            Assert.Throws<InvalidOperationException>(() =>
                workflow.Resolve("observability." + name, "0.1.0", parameters, subscription));
        }
    }

    [Fact]
    public async Task MissingWorkspaceStopsActualGatewayPackageBeforeAnyWrite()
    {
        arm.Reader = target => target.Contains("Microsoft.ApiManagement/service", StringComparison.Ordinal)
            ? new ArmSnapshot(JsonNode.Parse("""{"properties":{"provisioningState":"Succeeded"}}""")!.AsObject(), null)
            : null;
        await Assert.ThrowsAsync<InvalidOperationException>(() => RepositoryWorkflow().PlanAsync(
            "observability.apim-gateway-logs", "0.1.0", PackageParameters("apim-gateway-logs"), subscription));
        Assert.Equal(0, arm.Writes);
        Assert.Equal(2, arm.ReadTargets.Count);
        Assert.Contains("Microsoft.OperationalInsights/workspaces", arm.ReadTargets[^1]);
    }

    [Fact]
    public async Task MissingAuditStorageBlocksTheWrite()
    {
        string path = await ApprovedPlanAsync();
        File.WriteAllText(Path.Combine(directory, ".gitignore"), ".azureiq/plans/\n");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ConcurrentWorkspaceWriterIsBlocked()
    {
        string path = await ApprovedPlanAsync();
        using FileStream otherWriter = new(Path.Combine(directory, ".azureiq", "plans", "execution.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        await Assert.ThrowsAsync<IOException>(() => Workflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task ExplicitRiskPolicyBlocksUnsupportedChanges()
    {
        string path = await PlanAsync();
        var restricted = new ChangeWorkflow(directory, subscription, arm, () => Task.FromResult(fingerprint),
            () => { }, clock, permittedRiskTiers: ["R1"]);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            restricted.ApproveAsync(path, ChangeWorkflow.PlanDigest(restricted.ReadPlan(path))));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task SensitiveExistingConfigurationIsNotPersistedIntoAPlan()
    {
        arm.State = new ArmSnapshot(JsonNode.Parse("""{"properties":{"webhookProperties":{"token":"synthetic"}}}""")!.AsObject(), null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => PlanAsync());
        Assert.False(Directory.Exists(Path.Combine(directory, ".azureiq", "plans")));
    }

    [Fact]
    public async Task CliEndpointChangePreservesSubnetAndHasSeparatelyApprovedNonDeletingRollback()
    {
        JsonObject parameters = ConfigureCliPackage();
        JsonObject original = arm.State!.Body.DeepClone().AsObject();
        string path = await CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription);
        ChangePlan plan = CliWorkflow.ReadPlan(path);
        Assert.Equal("R3", plan.Risk);
        Assert.Equal("2.79.0", plan.Cli!.Version);
        await CliWorkflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(plan));
        await CliWorkflow.ApplyAsync(path);
        Assert.True(await CliWorkflow.VerifyAsync(path));
        Assert.True(AzureCliRecipeRunner.PreservesSubnet(original, arm.State!.Body));
        string rollback = await CliWorkflow.RollbackPlanAsync(path);
        ChangePlan reverse = CliWorkflow.ReadPlan(rollback);
        Assert.Equal("R3", reverse.Risk);
        Assert.NotNull(reverse.Desired);
        Assert.True(reverse.Cli!.IsRollback);
        await Assert.ThrowsAsync<FileNotFoundException>(() => CliWorkflow.ApplyAsync(rollback));
        await CliWorkflow.ApproveAsync(rollback, ChangeWorkflow.PlanDigest(reverse));
        await CliWorkflow.ApplyAsync(rollback);
        Assert.Empty(AzureCliRecipeRunner.Services(arm.State!.Body));
        Assert.True(AzureCliRecipeRunner.PreservesSubnet(original, arm.State.Body));
        Assert.Equal(2, arm.Writes);
    }

    [Fact]
    public async Task ExistingEndpointsAreNotOverwrittenByInitializationRecipe()
    {
        JsonObject parameters = ConfigureCliPackage();
        arm.State!.Body["properties"]!["serviceEndpoints"]!.AsArray()
            .Add(JsonNode.Parse("""{"service":"Microsoft.EventHub"}"""));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task CliIdentityOrVersionDriftStopsApprovedWrite()
    {
        JsonObject parameters = ConfigureCliPackage();
        string path = await CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription);
        await CliWorkflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(CliWorkflow.ReadPlan(path)));
        cliFingerprint = "changed-cli-or-principal";
        await Assert.ThrowsAsync<InvalidOperationException>(() => CliWorkflow.ApplyAsync(path));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public async Task SubnetDriftBlocksRollbackAndIsNotOverwritten()
    {
        JsonObject parameters = ConfigureCliPackage();
        string path = await CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription);
        await CliWorkflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(CliWorkflow.ReadPlan(path)));
        await CliWorkflow.ApplyAsync(path);
        arm.State!.Body["properties"]!["networkSecurityGroup"]!["id"] = "changed-by-another-operator";
        Assert.False(await CliWorkflow.VerifyAsync(path));
        await Assert.ThrowsAsync<InvalidOperationException>(() => CliWorkflow.RollbackPlanAsync(path));
        Assert.Equal(1, arm.Writes);
    }

    [Fact]
    public async Task ForeignReadOnlyNicReferencesAreRetainedWithoutBeingReadOrUsedAsWriteTargets()
    {
        JsonObject parameters = ConfigureCliPackage();
        string association = $"/subscriptions/{Guid.NewGuid()}/resourceGroups/managed/providers/Microsoft.Compute/virtualMachineScaleSets/managed/virtualMachines/0/networkInterfaces/nic/ipConfigurations/ipconfig1";
        string frontend = $"/subscriptions/{Guid.NewGuid()}/resourceGroups/managed/PROVIDERS/MICROSOFT.NETWORK/loadBalancers/managed/frontendIPConfigurations/frontend";
        arm.State!.Body["properties"]!["ipConfigurations"] = new JsonArray(
            new JsonObject { ["id"] = association }, new JsonObject { ["id"] = frontend });
        string path = await CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription);
        ChangePlan plan = CliWorkflow.ReadPlan(path);
        Assert.Contains(association, plan.Before!.Body.ToJsonString());
        Assert.Contains(frontend, plan.Before.Body.ToJsonString());
        Assert.DoesNotContain(association, string.Join(" ", plan.Cli!.Arguments));
        Assert.All(arm.ReadTargets, target => Assert.StartsWith("/subscriptions/" + subscription, target));
        await CliWorkflow.ApproveAsync(path, ChangeWorkflow.PlanDigest(plan));
        await CliWorkflow.ApplyAsync(path);
        string rollback = await CliWorkflow.RollbackPlanAsync(path);
        await CliWorkflow.ApproveAsync(rollback, ChangeWorkflow.PlanDigest(CliWorkflow.ReadPlan(rollback)));
        await CliWorkflow.ApplyAsync(rollback);
        Assert.Equal(association, arm.State.Body["properties"]!["ipConfigurations"]![0]!["id"]!.GetValue<string>());
    }

    [Fact]
    public async Task OpaqueAssociationExceptionDoesNotAllowForeignNsgReferences()
    {
        JsonObject parameters = ConfigureCliPackage();
        arm.State!.Body["properties"]!["networkSecurityGroup"]!["id"] =
            $"/subscriptions/{Guid.NewGuid()}/resourceGroups/foreign/providers/Microsoft.Network/networkSecurityGroups/foreign";
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            CliWorkflow.PlanAsync("test.observability", "0.1.0", parameters, subscription));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public void OptionalCliFieldsDoNotChangeExistingArmPlanHashShape()
    {
        var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        string requirement = JsonSerializer.Serialize(new ReadRequirement(
            "/synthetic", "version", new JsonObject(), null), json);
        Assert.DoesNotContain("emptyArrays", requirement);
        Assert.DoesNotContain("cli", JsonSerializer.Serialize(new ChangePlan(
            "CHG-SYNTHETIC", clock.Now, clock.Now.AddMinutes(30),
            "synthetic", "0.1.0", "digest", "context", "/synthetic", "version", new JsonObject(), null,
            "R2", "summary", "verification", [], null), json));
    }

    [Fact]
    public void ActualNetworkPackageBindsOnlyTheThreeCoreEndpoints()
    {
        var resolved = RepositoryWorkflow().Resolve("network.subnet-core-service-endpoints", "0.1.0",
            NetworkParameters(), subscription);
        Assert.Equal(["Microsoft.Storage", "Microsoft.Sql", "Microsoft.KeyVault"],
            AzureCliRecipeRunner.Services(resolved.Body));
        Assert.NotNull(resolved.Cli);
        Assert.Equal("R3", resolved.Package["risk"]!.GetValue<string>());
        Assert.DoesNotContain(subscription.ToString(), string.Join(" ", resolved.Cli.Arguments));
        Assert.Contains(resolved.Requirements, requirement => requirement.EmptyArrays?.Length == 1);
        AzureCliRecipeRunner.Validate(resolved.Target, resolved.Body, resolved.Cli, subscription);
    }

    private JsonObject NetworkParameters() => new()
    {
        ["resourceGroup"] = "synthetic-rg", ["vnetName"] = "synthetic-vnet",
        ["subnetName"] = "synthetic-subnet", ["apimServiceName"] = "synthetic-apim"
    };

    private JsonObject ConfigureCliPackage()
    {
        JsonObject package = ChangeWorkflow.ReadObject(Path.Combine(RepositoryRoot(), "artifacts", "networking",
            "subnet-core-service-endpoints.json"));
        package["id"] = "test.observability";
        string text = package.ToJsonString();
        Directory.CreateDirectory(Path.Combine(directory, "artifacts", "networking"));
        File.WriteAllText(Path.Combine(directory, "artifacts", "networking", "test.json"), text);
        JsonObject catalog = ChangeWorkflow.ReadObject(Path.Combine(directory, "artifacts", "catalog.json"));
        JsonNode artifact = catalog["artifacts"]![0]!;
        artifact["kind"] = "cli-workflow";
        artifact["source"]!["path"] = "../artifacts/networking/test.json";
        artifact["source"]!["sha256"] = ChangeWorkflow.Digest(text);
        File.WriteAllText(Path.Combine(directory, "artifacts", "catalog.json"), catalog.ToJsonString());
        JsonObject parameters = NetworkParameters();
        string target = CliWorkflow.Resolve("test.observability", "0.1.0", parameters, subscription).Target;
        arm.State = new ArmSnapshot(JsonNode.Parse("""
            {"properties":{"addressPrefix":"10.0.0.0/26","networkSecurityGroup":{"id":"synthetic-nsg"},
              "routeTable":null,"delegations":[],"privateEndpointNetworkPolicies":"Disabled",
              "privateLinkServiceNetworkPolicies":"Enabled","serviceEndpoints":[],"provisioningState":"Succeeded"}}
            """)!.AsObject(), "\"initial-subnet\"");
        arm.Reader = id => id.Contains("Microsoft.ApiManagement/service", StringComparison.Ordinal)
            ? new ArmSnapshot(new JsonObject
            {
                ["sku"] = new JsonObject { ["name"] = "Developer" },
                ["properties"] = new JsonObject
                {
                    ["provisioningState"] = "Succeeded",
                    ["virtualNetworkConfiguration"] = new JsonObject { ["subnetResourceId"] = target }
                }
            }, null)
            : arm.State;
        return parameters;
    }

    [Fact]
    public async Task UnsupportedSkuStopsCapacityPackageBeforeAnyWrite()
    {
        arm.State = new ArmSnapshot(JsonNode.Parse("""{"sku":{"name":"PremiumV2"}}""")!.AsObject(), null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => RepositoryWorkflow().PlanAsync(
            "observability.apim-capacity-alert", "0.1.0", PackageParameters("apim-capacity-alert"), subscription));
        Assert.Equal(0, arm.Writes);
    }

    [Fact]
    public void PreflightPreservesServiceProvisioningState()
    {
        JsonObject state = JsonNode.Parse("""{"properties":{"provisioningState":"Succeeded"}}""")!.AsObject();
        Assert.Equal("Succeeded", ArmChanges.Normalize(state, removeReadOnly: false)["properties"]!["provisioningState"]!.GetValue<string>());
        Assert.Null(ArmChanges.Normalize(state)["properties"]!["provisioningState"]);
    }

    private ChangeWorkflow RepositoryWorkflow() => new(RepositoryRoot(), subscription, arm,
        () => Task.FromResult(fingerprint), () => { }, clock);

    private JsonObject PackageParameters(string name)
    {
        string root = "/subscriptions/" + subscription + "/resourceGroups/synthetic-rg/providers/";
        var values = new JsonObject
        {
            ["resourceGroup"] = "synthetic-rg", ["serviceName"] = "synthetic-apim",
            ["settingName"] = "synthetic-setting", ["alertName"] = "synthetic-alert",
            ["location"] = "eastus", ["threshold"] = 75, ["thresholdPercent"] = 5,
            ["minimumRequests"] = 100, ["thresholdMilliseconds"] = 500,
            ["workspaceResourceId"] = root + "Microsoft.OperationalInsights/workspaces/synthetic-workspace",
            ["actionGroupResourceId"] = root + "Microsoft.Insights/actionGroups/synthetic-notifications"
        };
        JsonObject definitions = ChangeWorkflow.ReadObject(Path.Combine(RepositoryRoot(),
            "artifacts", "observability", name + ".json"))["parameters"]!.AsObject();
        var parameters = new JsonObject();
        foreach (string key in definitions.Select(item => item.Key))
        {
            parameters[key] = values[key]!.DeepClone();
        }
        return parameters;
    }

    private static string RepositoryRoot()
    {
        for (DirectoryInfo? current = new(AppContext.BaseDirectory); current is not null; current = current.Parent)
        {
            if (File.Exists(Path.Combine(current.FullName, "config", "azureiq.yaml")))
            {
                return current.FullName;
            }
        }
        throw new InvalidOperationException("Repository root was not found for package contract tests.");
    }

    [Fact]
    public void BootstrapScopeCanReadButCannotWrite()
    {
        var configuration = new LocalConfiguration("bootstrap-read-only",
            new ScopeConfiguration(Guid.NewGuid().ToString(), [subscription.ToString()]),
            new SafetyConfiguration("deny", true, true, null));
        configuration.ValidateForRead();
        Assert.Throws<InvalidOperationException>(configuration.ValidateForSupervisedExecution);
        LocalConfiguration commissioned = configuration with
        {
            Mode = "supervised-management",
            Safety = configuration.Safety with { AzureWrites = "supervised" }
        };
        commissioned.ValidateForSupervisedExecution();
        Assert.Throws<InvalidOperationException>(() =>
            (configuration with { Scope = configuration.Scope with { ExcludedSubscriptionIds = [subscription.ToString()] } })
                .ValidateForRead());
    }

    [Fact]
    public void MinimalPrivateProfileKeepsMandatoryApprovalDefaultsButNeverOverridesExplicitFalse()
    {
        const string json = """
            {"mode":"bootstrap-read-only","scope":{"tenantId":"11111111-1111-1111-1111-111111111111","subscriptionIds":["22222222-2222-2222-2222-222222222222"]},"safety":{"azureWrites":"deny","requireExactScope":true}}
            """;
        LocalConfiguration configuration = JsonSerializer.Deserialize<LocalConfiguration>(json,
            new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        configuration.ValidateForRead();
        Assert.True(configuration.Safety.RequireExplicitApproval);
        Assert.Throws<InvalidOperationException>(() =>
            (configuration with { Safety = configuration.Safety with { RequireExplicitApproval = false } }).ValidateForRead());
        Assert.Throws<InvalidOperationException>(configuration.ValidateForSupervisedExecution);
    }

    [Fact]
    public async Task ArmTransportUsesConditionalHeadersAndDoesNotLeakErrorBodies()
    {
        using var handler = new CaptureHandler();
        using var client = new HttpClient(handler);
        var transport = new ArmChanges(client, new TestCredential());
        string target = $"/subscriptions/{subscription}/providers/Microsoft.Insights/diagnosticSettings/audit";
        await transport.WriteAsync(target, "2021-05-01-preview", new JsonObject(), null, true);
        Assert.Equal("*", handler.LastIfNoneMatch);
        await transport.WriteAsync(target, "2021-05-01-preview", new JsonObject(), "\"version1\"", false);
        Assert.Equal("\"version1\"", handler.LastIfMatch);
        handler.Status = HttpStatusCode.Forbidden;
        InvalidOperationException error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            transport.ReadAsync(target, "2021-05-01-preview"));
        Assert.DoesNotContain("sensitive-server-response", error.Message);
    }

    public void Dispose()
    {
        Directory.Delete(directory, recursive: true);
        GC.SuppressFinalize(this);
    }

    private sealed class TestClock : TimeProvider
    {
        internal DateTimeOffset Now { get; set; } = new(2026, 10, 15, 16, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class FakeArm : IArmChanges
    {
        internal ArmSnapshot? State { get; set; }
        internal int Writes { get; private set; }
        internal string? LastETag { get; private set; }
        internal bool FailWrite { get; set; }
        internal bool IgnoreWrite { get; set; }
        internal bool IncludeDisabledCategoryDefault { get; set; }
        internal Func<string, ArmSnapshot?>? Reader { get; set; }
        internal List<string> ReadTargets { get; } = [];
        public Task<ArmSnapshot?> ReadAsync(string target, string apiVersion)
        {
            ReadTargets.Add(target);
            return Task.FromResult(Reader is null ? State : Reader(target));
        }
        public Task WriteAsync(string target, string apiVersion, JsonObject? body, string? etag, bool create, CliBinding? cli = null)
        {
            Writes++;
            LastETag = etag;
            if (FailWrite)
            {
                throw new HttpRequestException("Synthetic transport failure.");
            }
            if (!IgnoreWrite)
            {
                JsonObject? updated = body?.DeepClone().AsObject();
                if (cli is not null)
                {
                    updated = State!.Body.DeepClone().AsObject();
                    updated["properties"]!["serviceEndpoints"] =
                        body?["properties"]?["serviceEndpoints"]?.DeepClone() ?? new JsonArray();
                }
                if (IncludeDisabledCategoryDefault && updated?["properties"]?["logs"] is JsonArray logs &&
                    !logs.OfType<JsonObject>().Any(item => item["category"]?.GetValue<string>() == "Policy"))
                {
                    logs.Add(JsonNode.Parse("""{"category":"Policy","enabled":false}"""));
                }
                State = updated is null ? null : new ArmSnapshot(updated, "\"written\"");
            }
            return Task.CompletedTask;
        }
    }

    private sealed class TestCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(new AccessToken("synthetic-token", DateTimeOffset.UtcNow.AddHours(1)));
    }

    private sealed class CaptureHandler : HttpMessageHandler
    {
        internal string? LastIfMatch { get; private set; }
        internal string? LastIfNoneMatch { get; private set; }
        internal HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastIfMatch = request.Headers.TryGetValues("If-Match", out IEnumerable<string>? match) ? match.Single() : null;
            LastIfNoneMatch = request.Headers.TryGetValues("If-None-Match", out IEnumerable<string>? none) ? none.Single() : null;
            return Task.FromResult(new HttpResponseMessage(Status)
            {
                Content = new StringContent("sensitive-server-response", Encoding.UTF8)
            });
        }
    }
}
