using System.Text.Json.Serialization;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using WaypointFreight.Api.Endpoints;
using WaypointFreight.Api.Middleware;
using WaypointFreight.Api.Models;
using WaypointFreight.Api.Services;

var builder = WebApplication.CreateBuilder(args);

if (!string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    builder.Services.AddOpenTelemetry()
        .UseAzureMonitor(options => options.Credential = new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned));
}

builder.Services.AddOpenApi(options => options.AddDocumentTransformer((document, _, _) =>
{
    document.Info.Title = "Waypoint Freight Shipment API";
    document.Info.Version = "1.0.0";
    document.Info.Description = "Synthetic shipment tracking API for the AzureIQ App Service and API Management case study.";
    return Task.CompletedTask;
}).OpenApiVersion = Microsoft.OpenApi.OpenApiSpecVersion.OpenApi3_0);
builder.Services.AddHealthChecks();
builder.Services.AddSingleton<IShipmentRepository, InMemoryShipmentRepository>();
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

string[] allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options => options.AddPolicy("LocalClient", policy =>
{
    if (allowedOrigins.Length > 0)
    {
        policy.WithOrigins(allowedOrigins)
            .AllowAnyMethod()
            .AllowAnyHeader()
            .WithExposedHeaders(CorrelationIdMiddleware.HeaderName);
    }
}));

var app = builder.Build();

app.UseMiddleware<CorrelationIdMiddleware>();
app.UseMiddleware<ApiExceptionMiddleware>();
app.UseCors("LocalClient");

if (app.Environment.IsDevelopment())
{
    app.UseMiddleware<ScenarioSimulationMiddleware>();
    app.MapOpenApi();
}

app.MapGet("/", () => TypedResults.Ok(new ServiceInfo(
    "Waypoint Freight API",
    "1.0.0",
    "Shipment tracking and event history")))
    .WithName("GetServiceInfo")
    .WithTags("Service");

app.MapHealthChecks("/health/live", new HealthCheckOptions
{
    Predicate = _ => false
});
app.MapHealthChecks("/health/ready");
app.MapShipmentEndpoints();
app.MapTestScenarioEndpoints();

app.Run();

public partial class Program;
