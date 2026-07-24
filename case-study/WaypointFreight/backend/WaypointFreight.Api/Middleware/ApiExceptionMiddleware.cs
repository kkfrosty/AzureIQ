using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Middleware;

public sealed class ApiExceptionMiddleware(RequestDelegate next, ILogger<ApiExceptionMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await next(context);
        }
        catch (Exception exception)
        {
            logger.LogError(
                exception,
                "Unhandled API exception for {Method} {Path} with correlation {CorrelationId}",
                context.Request.Method,
                context.Request.Path,
                context.TraceIdentifier);

            if (context.Response.HasStarted)
            {
                throw;
            }

            context.Response.Clear();
            context.Response.StatusCode = StatusCodes.Status500InternalServerError;
            await context.Response.WriteAsJsonAsync(
                new ApiError(
                    "api.unhandled_exception",
                    "The backend encountered an unexpected error.",
                    context.TraceIdentifier,
                    false),
                context.RequestAborted);
        }
    }
}