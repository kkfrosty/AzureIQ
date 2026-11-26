using System.Net;
using System.Text;
using System.Text.Json;
using Harbor.Support.Api;
using Harbor.Support.Api.Features;
using Harbor.Support.Api.Infrastructure;
using Harbor.Support.Tests;
using Xunit;

namespace Harbor.Support.UnitTests;

public sealed class ProviderTests
{
    [Fact]
    public async Task TextProviderUsesManagedIdentityApimAudienceAndFixedModelEnvelope()
    {
        var clock = new TestClock();
        var credential = new TestCredential();
        var options = TestData.Options(clock);
        using var handler = new RecordingHandler(HttpStatusCode.OK,
            """{"choices":[{"message":{"content":"Approved guidance [hbr-microsoft-365@1.0]"}}],"usage":{"prompt_tokens":12,"completion_tokens":9}}""");
        using var http = new HttpClient(handler);
        var client = new FoundryTextClient(http, options, credential);
        var catalog = TestData.Catalog();
        var document = catalog.ApprovedDocuments.Single(item => item.DocId == "hbr-microsoft-365");
        var result = await client.CompleteAsync("Harbor Outlook guidance",
            new(HarborOptions.CompanyId, [document], [Catalog.Cite(document)]), catalog.GetStatus("microsoft-365"),
            TestContext.Current.CancellationToken);
        Assert.Equal(9, result.OutputTokens);
        Assert.Equal(options.Ai.TokenScope, Assert.Single(credential.Scopes));
        Assert.Equal(options.Ai.ChatEndpoint + "?api-version=2024-10-21", handler.Uri!.AbsoluteUri);
        Assert.Equal("Bearer", handler.AuthScheme);
        using var envelope = JsonDocument.Parse(handler.Body!);
        Assert.False(envelope.RootElement.GetProperty("stream").GetBoolean());
        Assert.Equal(600, envelope.RootElement.GetProperty("max_tokens").GetInt32());
        var messages = envelope.RootElement.GetProperty("messages");
        Assert.Equal(AssistantInstructions.CompanyOnly, messages[0].GetProperty("content").GetString());
        Assert.Contains("Harbor Outlook guidance", messages[1].GetProperty("content").GetString());
        Assert.False(envelope.RootElement.TryGetProperty("tools", out _));
    }

    [Theory]
    [InlineData(429, "model_provider_failed")]
    [InlineData(403, "model_provider_failed")]
    [InlineData(500, "model_provider_failed")]
    public async Task ProviderHttpFailuresAreExplicit(int status, string code)
    {
        var clock = new TestClock();
        using var handler = new RecordingHandler((HttpStatusCode)status, "{\"error\":\"upstream-sensitive-details\"}");
        using var http = new HttpClient(handler);
        var client = new FoundryTextClient(http, TestData.Options(clock), new TestCredential());
        var failure = await Assert.ThrowsAsync<HarborException>(() => client.CompleteAsync("Harbor",
            new(HarborOptions.CompanyId, [], []), TestData.Catalog().GetStatus("microsoft-365"), TestContext.Current.CancellationToken));
        Assert.Equal(code, failure.Code);
        Assert.DoesNotContain("sensitive", failure.Message);
        Assert.Equal(status == 429 ? 429 : 502, failure.Status);
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"choices\":[null]}")]
    [InlineData("{\"choices\":[{\"message\":[]}]}")]
    [InlineData("{\"choices\":[{\"message\":{\"content\":null}}]}")]
    [InlineData("invalid-json")]
    public async Task MalformedProviderEnvelopeFailsSafely(string body)
    {
        var clock = new TestClock();
        using var handler = new RecordingHandler(HttpStatusCode.OK, body);
        using var http = new HttpClient(handler);
        var client = new FoundryTextClient(http, TestData.Options(clock), new TestCredential());
        var failure = await Assert.ThrowsAsync<HarborException>(() => client.CompleteAsync("Harbor",
            new(HarborOptions.CompanyId, [], []), TestData.Catalog().GetStatus("microsoft-365"), TestContext.Current.CancellationToken));
        Assert.Equal("invalid_model_response", failure.Code);
    }

    [Fact]
    public async Task OversizedProviderResponseIsRejectedBeforeParsing()
    {
        var clock = new TestClock();
        using var handler = new RecordingHandler(HttpStatusCode.OK, new string('x', 65537));
        using var http = new HttpClient(handler);
        var client = new FoundryTextClient(http, TestData.Options(clock), new TestCredential());
        var failure = await Assert.ThrowsAsync<HarborException>(() => client.CompleteAsync("Harbor",
            new(HarborOptions.CompanyId, [], []), TestData.Catalog().GetStatus("microsoft-365"), TestContext.Current.CancellationToken));
        Assert.Equal("provider_message_limit", failure.Code);
    }

    [Fact]
    public async Task ProviderCancellationIsPropagatedAndNoRequestIsSent()
    {
        var clock = new TestClock();
        using var handler = new RecordingHandler(HttpStatusCode.OK, "{}");
        using var http = new HttpClient(handler);
        var client = new FoundryTextClient(http, TestData.Options(clock), new TestCredential());
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.CompleteAsync("Harbor",
            new(HarborOptions.CompanyId, [], []), TestData.Catalog().GetStatus("microsoft-365"), cancellation.Token));
        Assert.Null(handler.Uri);
    }
}

public sealed class RecordingHandler(HttpStatusCode status, string response) : HttpMessageHandler
{
    public Uri? Uri { get; private set; }
    public string? Body { get; private set; }
    public string? AuthScheme { get; private set; }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Uri = request.RequestUri;
        Body = await request.Content!.ReadAsStringAsync(cancellationToken);
        AuthScheme = request.Headers.Authorization?.Scheme;
        return new(status) { Content = new StringContent(response, Encoding.UTF8, "application/json") };
    }
}
