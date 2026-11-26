using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;
using Harbor.Support.Tests;
using Microsoft.AspNetCore.Mvc.ApiExplorer;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Harbor.Support.IntegrationTests;

public sealed class ApiTests
{
    [Fact]
    public async Task UnknownApiRouteRemains404ButIsExcludedFromOpenApi()
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        using var response = await client.GetAsync("/support/v1/not-an-endpoint", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        var descriptions = factory.Services.GetRequiredService<IApiDescriptionGroupCollectionProvider>();
        Assert.DoesNotContain(descriptions.ApiDescriptionGroups.Items.SelectMany(group => group.Items),
            description => description.RelativePath?.Contains("unmatched", StringComparison.Ordinal) == true);
    }

    [Fact]
    public async Task BootstrapIsPublicButNoCallerApiAcceptsUnauthenticatedRequests()
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        var config = await client.GetFromJsonAsync<RuntimeConfig>("/support/v1/config", TestContext.Current.CancellationToken);
        Assert.True(config!.Auth.Configured);
        Assert.Equal(TestData.Client, config.Auth.ClientId);
        Assert.Equal(TestData.Audience + "/Support.Access", config.Auth.Scope);
        using var denied = await client.GetAsync("/support/v1/customer", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        Assert.Equal("application/problem+json", denied.Content.Headers.ContentType!.MediaType);
    }

    [Theory]
    [InlineData("customer-only")]
    [InlineData("gateway-only")]
    [InlineData("wrong-role")]
    [InlineData("wrong-scope")]
    [InlineData("wrong-tenant")]
    [InlineData("wrong-audience")]
    [InlineData("wrong-signature")]
    [InlineData("expired")]
    [InlineData("delegated-gateway")]
    public async Task RealJwtValidationRequiresBothIndependentAuthorizedIdentities(string scenario)
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        if (scenario != "customer-only")
            client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token(gateway: true,
                scope: scenario == "delegated-gateway" ? "Support.Access" : null));
        else
            client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token());
        if (scenario != "gateway-only")
            client.DefaultRequestHeaders.Add(CustomerIdentity.CallerHeader, "Bearer " + factory.Token(
                role: scenario == "wrong-role" ? "Other.Customer" : null,
                scope: scenario == "wrong-scope" ? "Other.Scope" : null,
                tenant: scenario == "wrong-tenant" ? Guid.NewGuid().ToString() : null,
                audience: scenario == "wrong-audience" ? "api://other" : null,
                wrongSignature: scenario == "wrong-signature", expired: scenario == "expired"));
        using var response = await client.GetAsync("/support/v1/cases", TestContext.Current.CancellationToken);
        Assert.Contains(response.StatusCode, new[] { HttpStatusCode.Unauthorized, HttpStatusCode.Forbidden });
        Assert.Empty(await factory.Store.ListAsync(TestData.Customer(factory.Clock), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task StandardEntraRoleMapsCompanyWithoutAnyCustomClaim()
    {
        using var factory = new HarborFactory();
        using var client = factory.CustomerClient();
        var customer = await client.GetFromJsonAsync<CustomerInfo>("/support/v1/customer", TestContext.Current.CancellationToken);
        Assert.Equal(HarborOptions.CompanyId, customer!.CompanyId);
        Assert.True(customer.AuthorizationExpiresAt > DateTimeOffset.UtcNow);
        var services = await client.GetFromJsonAsync<ServiceInfo[]>("/support/v1/services", TestContext.Current.CancellationToken);
        Assert.Equal(4, services!.Length);
        var status = await client.GetFromJsonAsync<SyntheticStatus>("/support/v1/status/microsoft-365",
            TestContext.Current.CancellationToken);
        Assert.True(status!.Synthetic);
    }

    [Fact]
    public async Task SameApiApplicationIdUriAndV2GuidAudiencesAreBothAccepted()
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token(gateway: true, audience: TestData.Audience));
        client.DefaultRequestHeaders.Add(CustomerIdentity.CallerHeader, "Bearer " + factory.Token(audience: TestData.ApiClient));
        using var guidCaller = await client.GetAsync("/support/v1/customer", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, guidCaller.StatusCode);
        client.DefaultRequestHeaders.Remove(CustomerIdentity.CallerHeader);
        client.DefaultRequestHeaders.Add(CustomerIdentity.CallerHeader, "Bearer " + factory.Token(audience: TestData.Audience));
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token(gateway: true, audience: TestData.ApiClient));
        using var uriCaller = await client.GetAsync("/support/v1/customer", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, uriCaller.StatusCode);
    }

    [Fact]
    public async Task HumanConfirmationAndExactIdempotencyWriteOnlyOneOwnerBoundCase()
    {
        using var factory = new HarborFactory();
        using var client = factory.CustomerClient();
        using var prepared = await client.PostAsJsonAsync("/support/v1/case-proposals", TestData.CaseRequest,
            TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Created, prepared.StatusCode);
        var proposal = (await prepared.Content.ReadFromJsonAsync<CaseProposal>(TestContext.Current.CancellationToken))!;
        Assert.Equal("/support/v1/case-proposals/" + proposal.Id, prepared.Headers.Location!.OriginalString);
        var proposalPath = "/support/v1/case-proposals/" + proposal.Id;
        using var confirmation = await client.PostAsJsonAsync(proposalPath + "/confirmation",
            new ConfirmationRequest(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        var grant = (await confirmation.Content.ReadFromJsonAsync<ConfirmationGrant>(TestContext.Current.CancellationToken))!;
        Assert.Equal(HttpStatusCode.OK, confirmation.StatusCode);
        client.DefaultRequestHeaders.Add("Idempotency-Key", Guid.NewGuid().ToString());
        var request = new CommitCaseRequest(proposal.ProposalHash, grant.Grant);
        using var committed = await client.PostAsJsonAsync(proposalPath + "/commit", request, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Created, committed.StatusCode);
        var created = (await committed.Content.ReadFromJsonAsync<CommitCaseResult>(TestContext.Current.CancellationToken))!;
        using var replayed = await client.PostAsJsonAsync(proposalPath + "/commit", request, TestContext.Current.CancellationToken);
        var replay = (await replayed.Content.ReadFromJsonAsync<CommitCaseResult>(TestContext.Current.CancellationToken))!;
        Assert.Equal(HttpStatusCode.OK, replayed.StatusCode);
        Assert.True(replay.Replayed);
        Assert.Equal(created.Case.Id, replay.Case.Id);
        var cases = await client.GetFromJsonAsync<SupportCase[]>("/support/v1/cases", TestContext.Current.CancellationToken);
        Assert.Single(cases!);
        using var other = factory.CustomerClient("00000000-0000-0000-0000-000000000005");
        using var denied = await other.GetAsync("/support/v1/cases/" + created.Case.Id, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
        using var hiddenProposal = await other.GetAsync(proposalPath, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.NotFound, hiddenProposal.StatusCode);
        Assert.Empty((await other.GetFromJsonAsync<SupportCase[]>("/support/v1/cases", TestContext.Current.CancellationToken))!);
    }

    [Fact]
    public async Task ConfirmationExpiryAndProblemDetailsAreObservableOverHttp()
    {
        using var factory = new HarborFactory();
        using var client = factory.CustomerClient();
        using var prepared = await client.PostAsJsonAsync("/support/v1/case-proposals", TestData.CaseRequest,
            TestContext.Current.CancellationToken);
        var proposal = (await prepared.Content.ReadFromJsonAsync<CaseProposal>(TestContext.Current.CancellationToken))!;
        factory.Clock.Now = proposal.ExpiresAt;
        using var expired = await client.PostAsJsonAsync("/support/v1/case-proposals/" + proposal.Id + "/confirmation",
            new ConfirmationRequest(proposal.ProposalHash, "create_case"), TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Gone, expired.StatusCode);
        using var body = await JsonDocument.ParseAsync(await expired.Content.ReadAsStreamAsync(TestContext.Current.CancellationToken),
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("proposal_expired", body.RootElement.GetProperty("code").GetString());
        Assert.True(body.RootElement.TryGetProperty("traceId", out _));
        Assert.True(expired.Headers.CacheControl!.NoStore);
    }

    [Theory]
    [InlineData("{\"serviceId\":\"microsoft-365\",\"message\":\"Harbor support\",\"ownerKey\":\"other\"}")]
    [InlineData("{\"serviceId\":\"microsoft-365\",\"message\":\"Harbor support\",\"message\":\"override\"}")]
    [InlineData("{\"serviceId\":\"microsoft-365\",\"message\":{}}")]
    public async Task InvalidBodiesCannotSelectOwnerOrOverrideRequestShape(string json)
    {
        using var factory = new HarborFactory();
        using var client = factory.CustomerClient();
        using var body = new StringContent(json, Encoding.UTF8, "application/json");
        using var response = await client.PostAsync("/support/v1/chat/messages", body, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal(0, factory.Text.Calls);
    }

    [Fact]
    public async Task MissingKnowledgeAndProviderFailuresNeverReturnSuccessfulMockAnswers()
    {
        using var factory = new HarborFactory();
        using var client = factory.CustomerClient();
        factory.Knowledge.Documents = [];
        using var unknown = await client.PostAsJsonAsync("/support/v1/chat/messages",
            new ChatMessageRequest("microsoft-365", "Harbor Outlook guidance"), TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.UnprocessableEntity, unknown.StatusCode);
        Assert.Equal(0, factory.Text.Calls);
        factory.Knowledge.Documents = TestData.Catalog().ApprovedDocuments.Where(document => document.DocId == "hbr-microsoft-365").ToArray();
        factory.Text.Failure = new(502, "model_provider_failed", "Synthetic upstream outage.");
        using var failed = await client.PostAsJsonAsync("/support/v1/chat/messages",
            new ChatMessageRequest("microsoft-365", "Harbor Outlook guidance"), TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.BadGateway, failed.StatusCode);
    }

    [Fact]
    public async Task OpenApiHasActualSchemasRoutesAndOnlyAdmittedMcpOperations()
    {
        using var factory = new HarborFactory();
        using var client = factory.CreateClient();
        using var api = JsonDocument.Parse(await client.GetStringAsync("/support/openapi/v1.json", TestContext.Current.CancellationToken));
        Assert.StartsWith("3.0.", api.RootElement.GetProperty("openapi").GetString());
        var paths = api.RootElement.GetProperty("paths");
        var operationIds = paths.EnumerateObject().SelectMany(path => path.Value.EnumerateObject())
            .Where(method => method.Value.TryGetProperty("operationId", out _))
            .Select(method => method.Value.GetProperty("operationId").GetString()).ToArray();
        Assert.Contains("GetCustomer", operationIds);
        Assert.Contains("ConfirmCaseProposal", operationIds);
        Assert.All(ContractExporter.ToolOperations.Values, id => Assert.Contains(id, operationIds));
        Assert.DoesNotContain("ConfirmCaseProposal", ContractExporter.ToolOperations.Values);
        Assert.DoesNotContain("CommitConfirmedCase", ContractExporter.ToolOperations.Values);
        Assert.True(api.RootElement.GetProperty("components").GetProperty("schemas").TryGetProperty("CaseProposal", out _));
        Assert.True(paths.TryGetProperty("/voice/socket", out _));
    }
}
