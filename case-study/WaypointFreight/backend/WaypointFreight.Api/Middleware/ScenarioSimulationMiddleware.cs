using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Middleware;

public sealed class ScenarioSimulationMiddleware(
    RequestDelegate next,
    IConfiguration configuration,
    IWebHostEnvironment environment,
    ILogger<ScenarioSimulationMiddleware> logger)
{
    public const string HeaderName = "X-Waypoint-Scenario";

    public async Task InvokeAsync(HttpContext context)
    {
        if (!environment.IsDevelopment() || !context.Request.Path.StartsWithSegments("/api/shipments"))
        {
            await next(context);
            return;
        }

        string scenario = context.Request.Headers[HeaderName].FirstOrDefault()?.Trim().ToLowerInvariant() ?? "none";
        switch (scenario)
        {
            case "":
            case "none":
                await next(context);
                return;
            case "delay":
                int delayMilliseconds = Math.Clamp(
                    configuration.GetValue("FaultSimulation:DelayMilliseconds", 1200),
                    1,
                    10_000);
                logger.LogWarning("Applying development scenario {Scenario} for {DelayMilliseconds} ms", scenario, delayMilliseconds);
                await Task.Delay(delayMilliseconds, context.RequestAborted);
                await next(context);
                return;
            case "server-error":
                await WriteErrorAsync(context, StatusCodes.Status500InternalServerError, "shipment.simulated_error", "A simulated server error occurred.", false);
                return;
            case "unavailable":
                context.Response.Headers.RetryAfter = "5";
                await WriteErrorAsync(context, StatusCodes.Status503ServiceUnavailable, "shipment.simulated_unavailable", "The shipment service is temporarily unavailable.", true);
                return;
            case "malformed":
                context.Response.StatusCode = StatusCodes.Status200OK;
                context.Response.ContentType = "application/json";
                await context.Response.WriteAsync("{\"unexpectedContract\":true}", context.RequestAborted);
                return;
            case "not-found":
                await WriteErrorAsync(context, StatusCodes.Status404NotFound, "shipment.simulated_not_found", "The simulated shipment was not found.", false);
                return;
            default:
                await WriteErrorAsync(context, StatusCodes.Status400BadRequest, "scenario.invalid", "The requested development scenario is not supported.", false);
                return;
        }
    }

    private static Task WriteErrorAsync(
        HttpContext context,
        int statusCode,
        string code,
        string message,
        bool retryable)
    {
        context.Response.StatusCode = statusCode;
        return context.Response.WriteAsJsonAsync(
            new ApiError(code, message, context.TraceIdentifier, retryable),
            context.RequestAborted);
    }
}