using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Endpoints;

public static class TestScenarioEndpoints
{
    private static readonly TestScenario[] Scenarios =
    [
        new("exception", "Unhandled exception", "Throws an exception and returns a correlation-aware 500 response."),
        new("dependency-unavailable", "Dependency unavailable", "Simulates a failed backend dependency with HTTP 503 and Retry-After."),
        new("dependency-timeout", "Dependency timeout", "Simulates a timed-out backend dependency with HTTP 504."),
        new("throttled", "Dependency throttled", "Simulates dependency throttling with HTTP 429 and Retry-After."),
        new("slow", "Slow dependency", "Returns successfully after a configurable delay."),
        new("malformed", "Malformed contract", "Returns HTTP 200 with an unexpected response shape."),
        new("conflict", "State conflict", "Simulates a backend state conflict with HTTP 409."),
        new("not-found", "Not found", "Simulates a missing backend record with HTTP 404.")
    ];

    public static IEndpointRouteBuilder MapTestScenarioEndpoints(this IEndpointRouteBuilder endpoints)
    {
        RouteGroupBuilder group = endpoints.MapGroup("/api/test-scenarios")
            .WithTags("Test scenarios");

        group.MapGet("/", (IConfiguration configuration) =>
            IsEnabled(configuration) ? Results.Ok(Scenarios) : Results.NotFound())
            .WithName("ListTestScenarios");

        group.MapGet("/{scenario}", RunScenarioAsync)
            .WithName("RunTestScenario");

        return endpoints;
    }

    private static async Task<IResult> RunScenarioAsync(
        string scenario,
        HttpContext context,
        IConfiguration configuration,
        ILoggerFactory loggerFactory)
    {
        if (!IsEnabled(configuration))
        {
            return Results.NotFound();
        }

        ILogger logger = loggerFactory.CreateLogger("WaypointFreight.TestScenarios");
        string normalizedScenario = scenario.Trim().ToLowerInvariant();
        logger.LogWarning(
            "Executing diagnostic scenario {Scenario} with correlation {CorrelationId}",
            normalizedScenario,
            context.TraceIdentifier);

        switch (normalizedScenario)
        {
            case "exception":
                throw new InvalidOperationException("Synthetic backend exception for AzureIQ diagnostics.");
            case "dependency-unavailable":
                context.Response.Headers.RetryAfter = "15";
                return Error(context, 503, "dependency.unavailable", "The synthetic backend dependency is unavailable.", true);
            case "dependency-timeout":
                await Task.Delay(
                    Math.Clamp(configuration.GetValue("TestScenarios:TimeoutDelayMilliseconds", 1500), 1, 10_000),
                    context.RequestAborted);
                return Error(context, 504, "dependency.timeout", "The synthetic backend dependency timed out.", true);
            case "throttled":
                context.Response.Headers.RetryAfter = "30";
                return Error(context, 429, "dependency.throttled", "The synthetic backend dependency is throttling requests.", true);
            case "slow":
                int delayMilliseconds = Math.Clamp(
                    configuration.GetValue("TestScenarios:SlowDelayMilliseconds", 2500),
                    1,
                    10_000);
                await Task.Delay(delayMilliseconds, context.RequestAborted);
                return Results.Ok(new TestScenarioResult(normalizedScenario, "completed", context.TraceIdentifier, delayMilliseconds));
            case "malformed":
                return Results.Ok(new { unexpectedContract = true, correlationId = context.TraceIdentifier });
            case "conflict":
                return Error(context, 409, "dependency.conflict", "The synthetic backend dependency reported a state conflict.", false);
            case "not-found":
                return Error(context, 404, "dependency.not_found", "The synthetic backend record was not found.", false);
            default:
                return Error(context, 400, "scenario.invalid", $"Unknown diagnostic scenario '{scenario}'.", false);
        }
    }

    private static IResult Error(HttpContext context, int statusCode, string code, string message, bool retryable) =>
        Results.Json(new ApiError(code, message, context.TraceIdentifier, retryable), statusCode: statusCode);

    private static bool IsEnabled(IConfiguration configuration) =>
        configuration.GetValue<bool>("TestScenarios:Enabled");

    private sealed record TestScenario(string Id, string Name, string Description);

    private sealed record TestScenarioResult(
        string Scenario,
        string Status,
        string CorrelationId,
        int DelayMilliseconds);
}