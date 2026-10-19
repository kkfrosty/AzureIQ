using System.Text.Json.Nodes;

namespace AzureIQ.Execution.Tests;

public sealed class AzureCliRecipeTests
{
    private readonly Guid subscription = Guid.NewGuid();
    private string Target => $"/subscriptions/{subscription}/resourceGroups/synthetic-rg/providers/Microsoft.Network/virtualNetworks/synthetic-vnet/subnets/synthetic-subnet";
    private static JsonObject Desired => JsonNode.Parse("""
        {"properties":{"serviceEndpoints":[{"service":"Microsoft.Storage"},{"service":"Microsoft.Sql"},{"service":"Microsoft.KeyVault"}]}}
        """)!.AsObject();
    private static string[] Prefix =>
    [
        "network", "vnet", "subnet", "update", "--resource-group", "synthetic-rg",
        "--vnet-name", "synthetic-vnet", "--name", "synthetic-subnet"
    ];
    private static CliBinding Binding => new(
        [.. Prefix, "--service-endpoints", "Microsoft.Storage", "Microsoft.Sql", "Microsoft.KeyVault"],
        [.. Prefix, "--remove", "serviceEndpoints"], "2.79.0", "synthetic-context");

    [Fact]
    public void AdmittedUpdateAndEmptyRollbackAreAccepted()
    {
        AzureCliRecipeRunner.Validate(Target, Desired, Binding, subscription);
        AzureCliRecipeRunner.Validate(Target, new JsonObject { ["properties"] = new JsonObject() },
            Binding with { Arguments = Binding.RollbackArguments, IsRollback = true }, subscription);
    }

    [Fact]
    public void CrossSubscriptionAndDeleteAreRejected()
    {
        Assert.Throws<InvalidOperationException>(() => AzureCliRecipeRunner.Validate(
            Target.Replace(subscription.ToString(), Guid.NewGuid().ToString()), Desired, Binding, subscription));
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.Validate(Target, null, Binding, subscription));
    }

    [Theory]
    [InlineData("delete")]
    [InlineData("create")]
    [InlineData("show")]
    public void UnapprovedCommandFamiliesAreRejected(string action)
    {
        CliBinding binding = Binding;
        binding.Arguments[3] = action;
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.Validate(Target, Desired, binding, subscription));
    }

    [Fact]
    public void AdditionalFlagsAndDifferentTargetArgumentsAreRejected()
    {
        Assert.Throws<InvalidOperationException>(() => AzureCliRecipeRunner.Validate(Target, Desired,
            Binding with { Arguments = [.. Binding.Arguments, "--subscription", Guid.NewGuid().ToString()] }, subscription));
        CliBinding binding = Binding;
        binding.Arguments[9] = "another-subnet";
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.Validate(Target, Desired, binding, subscription));
    }

    [Fact]
    public void AdditionalSubnetPropertiesCannotBeChanged()
    {
        JsonObject body = Desired;
        body["properties"]!["addressPrefix"] = "10.1.0.0/24";
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.Validate(Target, body, Binding, subscription));
    }

    [Theory]
    [InlineData("Microsoft.ContainerRegistry")]
    [InlineData("Microsoft.Storage;evil")]
    [InlineData("Microsoft.Storage")]
    public void UnknownInjectedOrDuplicateEndpointArgumentsAreRejected(string service)
    {
        Assert.Throws<InvalidOperationException>(() => AzureCliRecipeRunner.Validate(Target, Desired,
            Binding with { Arguments = [.. Binding.Arguments, service] }, subscription));
    }

    [Theory]
    [InlineData("x&other")]
    [InlineData("x|other")]
    [InlineData("%SUBSCRIPTION%")]
    [InlineData("x\"other")]
    public void WindowsShellMetacharactersAreRejected(string value) =>
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.StartInfo(@"C:\synthetic\az.cmd", ["network", value]));

    [Fact]
    public void ActiveCliCloudSubscriptionTenantAndPrincipalMustMatch()
    {
        var configuration = new LocalConfiguration("supervised-management",
            new ScopeConfiguration(Guid.NewGuid().ToString(), [subscription.ToString()]),
            new SafetyConfiguration("supervised"));
        var account = new JsonObject
        {
            ["environmentName"] = "AzureCloud", ["tenantId"] = configuration.TenantId.ToString(),
            ["id"] = subscription.ToString(), ["user"] = new JsonObject { ["name"] = "reader@example.invalid" }
        };
        AzureCliRecipeRunner.ValidateAccount(account, configuration, "reader@example.invalid");
        account["id"] = Guid.NewGuid().ToString();
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.ValidateAccount(account, configuration, "reader@example.invalid"));
        account["id"] = subscription.ToString();
        account["user"]!["name"] = "another@example.invalid";
        Assert.Throws<InvalidOperationException>(() =>
            AzureCliRecipeRunner.ValidateAccount(account, configuration, "reader@example.invalid"));
    }

    [Fact]
    public void DefaultOutboundAccessIsPartOfSubnetPreservation()
    {
        JsonObject before = JsonNode.Parse("""{"properties":{"defaultOutboundAccess":false}}""")!.AsObject();
        JsonObject after = JsonNode.Parse("""{"properties":{"defaultOutboundAccess":true}}""")!.AsObject();
        Assert.False(AzureCliRecipeRunner.PreservesSubnet(before, after));
    }
}
