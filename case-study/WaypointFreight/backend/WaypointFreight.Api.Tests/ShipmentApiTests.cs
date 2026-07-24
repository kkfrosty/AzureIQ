using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Tests;

public sealed class ShipmentApiTests : IClassFixture<WebApplicationFactory<Program>>
{
    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();
    private readonly WebApplicationFactory<Program> factory;

    public ShipmentApiTests(WebApplicationFactory<Program> factory)
    {
        this.factory = factory.WithWebHostBuilder(builder => builder.UseEnvironment("Development"));
    }

    [Fact]
    public async Task ListShipmentsReturnsSyntheticData()
    {
        using HttpClient client = factory.CreateClient();

        ShipmentSummary[]? shipments = await client.GetFromJsonAsync<ShipmentSummary[]>("/api/shipments", JsonOptions);

        Assert.NotNull(shipments);
        Assert.Equal(4, shipments.Length);
        Assert.Contains(shipments, shipment => shipment.TrackingNumber == "WF-1042");
    }

    [Fact]
    public async Task GetShipmentReturnsEvents()
    {
        using HttpClient client = factory.CreateClient();

        Shipment? shipment = await client.GetFromJsonAsync<Shipment>("/api/shipments/WF-1042", JsonOptions);

        Assert.NotNull(shipment);
        Assert.Equal(ShipmentStatus.InTransit, shipment.Status);
        Assert.NotEmpty(shipment.Events);
    }

    [Fact]
    public async Task UnknownShipmentReturnsStableErrorAndCorrelationId()
    {
        using HttpClient client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/shipments/WF-UNKNOWN");
        request.Headers.Add("X-Correlation-Id", "test-correlation-404");

        using HttpResponseMessage response = await client.SendAsync(request);
        ApiError? error = await response.Content.ReadFromJsonAsync<ApiError>(JsonOptions);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal("test-correlation-404", response.Headers.GetValues("X-Correlation-Id").Single());
        Assert.NotNull(error);
        Assert.Equal("shipment.not_found", error.Code);
        Assert.Equal("test-correlation-404", error.CorrelationId);
    }

    [Fact]
    public async Task UnavailableScenarioReturnsRetryableError()
    {
        using HttpClient client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/shipments");
        request.Headers.Add("X-Waypoint-Scenario", "unavailable");

        using HttpResponseMessage response = await client.SendAsync(request);
        ApiError? error = await response.Content.ReadFromJsonAsync<ApiError>(JsonOptions);

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("5", response.Headers.RetryAfter?.Delta?.TotalSeconds.ToString("0") ?? response.Headers.GetValues("Retry-After").Single());
        Assert.NotNull(error);
        Assert.True(error.Retryable);
    }

    [Fact]
    public async Task MalformedScenarioReturnsUnexpectedContractShape()
    {
        using HttpClient client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/shipments");
        request.Headers.Add("X-Waypoint-Scenario", "malformed");

        using HttpResponseMessage response = await client.SendAsync(request);
        using JsonDocument document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(JsonValueKind.Object, document.RootElement.ValueKind);
        Assert.True(document.RootElement.GetProperty("unexpectedContract").GetBoolean());
    }

    [Fact]
    public async Task SimulatedErrorIncludesLocalClientCorsHeader()
    {
        using HttpClient client = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/shipments");
        request.Headers.Add("Origin", "http://127.0.0.1:5265");
        request.Headers.Add("X-Waypoint-Scenario", "unavailable");

        using HttpResponseMessage response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal(
            "http://127.0.0.1:5265",
            response.Headers.GetValues("Access-Control-Allow-Origin").Single());
    }

    [Fact]
    public async Task FaultScenarioHeaderIsIgnoredOutsideDevelopment()
    {
        using WebApplicationFactory<Program> productionFactory = factory.WithWebHostBuilder(
            builder => builder.UseEnvironment("Production"));
        using HttpClient client = productionFactory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/shipments");
        request.Headers.Add("X-Waypoint-Scenario", "unavailable");

        using HttpResponseMessage response = await client.SendAsync(request);
        ShipmentSummary[]? shipments = await response.Content.ReadFromJsonAsync<ShipmentSummary[]>(JsonOptions);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.NotNull(shipments);
        Assert.Equal(4, shipments.Length);
    }

    [Fact]
    public async Task DiagnosticExceptionReturnsStructuredCorrelatedError()
    {
        using HttpClient client = CreateDiagnosticClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/test-scenarios/exception");
        request.Headers.Add("X-Correlation-Id", "diagnostic-exception-500");

        using HttpResponseMessage response = await client.SendAsync(request);
        ApiError? error = await response.Content.ReadFromJsonAsync<ApiError>(JsonOptions);

        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        Assert.Equal("diagnostic-exception-500", response.Headers.GetValues("X-Correlation-Id").Single());
        Assert.NotNull(error);
        Assert.Equal("api.unhandled_exception", error.Code);
        Assert.Equal("diagnostic-exception-500", error.CorrelationId);
        Assert.DoesNotContain("InvalidOperationException", await response.Content.ReadAsStringAsync());
    }

    [Theory]
    [InlineData("dependency-unavailable", HttpStatusCode.ServiceUnavailable, "dependency.unavailable", true)]
    [InlineData("dependency-timeout", HttpStatusCode.GatewayTimeout, "dependency.timeout", true)]
    [InlineData("throttled", HttpStatusCode.TooManyRequests, "dependency.throttled", true)]
    [InlineData("conflict", HttpStatusCode.Conflict, "dependency.conflict", false)]
    [InlineData("not-found", HttpStatusCode.NotFound, "dependency.not_found", false)]
    public async Task DiagnosticFailuresReturnStableErrors(
        string scenario,
        HttpStatusCode expectedStatus,
        string expectedCode,
        bool expectedRetryable)
    {
        using HttpClient client = CreateDiagnosticClient();

        using HttpResponseMessage response = await client.GetAsync($"/api/test-scenarios/{scenario}");
        ApiError? error = await response.Content.ReadFromJsonAsync<ApiError>(JsonOptions);

        Assert.Equal(expectedStatus, response.StatusCode);
        Assert.NotNull(error);
        Assert.Equal(expectedCode, error.Code);
        Assert.Equal(expectedRetryable, error.Retryable);
        Assert.False(string.IsNullOrWhiteSpace(error.CorrelationId));
    }

    [Fact]
    public async Task DiagnosticEndpointsAreDisabledUnlessConfigured()
    {
        using WebApplicationFactory<Program> productionFactory = factory.WithWebHostBuilder(
            builder => builder.UseEnvironment("Production"));
        using HttpClient client = productionFactory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync("/api/test-scenarios/exception");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task OpenApiDocumentIsAvailableInDevelopment()
    {
        using HttpClient client = factory.CreateClient();

        using HttpResponseMessage response = await client.GetAsync("/openapi/v1.json");
        using JsonDocument document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Waypoint Freight Shipment API", document.RootElement.GetProperty("info").GetProperty("title").GetString());
        Assert.Equal("1.0.0", document.RootElement.GetProperty("info").GetProperty("version").GetString());
        Assert.True(document.RootElement.GetProperty("paths").TryGetProperty("/api/shipments", out _));
    }

    private static JsonSerializerOptions CreateJsonOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }

    private HttpClient CreateDiagnosticClient()
    {
        WebApplicationFactory<Program> diagnosticFactory = factory.WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Production");
            builder.UseSetting("TestScenarios:Enabled", "true");
            builder.UseSetting("TestScenarios:TimeoutDelayMilliseconds", "1");
            builder.UseSetting("TestScenarios:SlowDelayMilliseconds", "1");
        });
        return diagnosticFactory.CreateClient();
    }
}