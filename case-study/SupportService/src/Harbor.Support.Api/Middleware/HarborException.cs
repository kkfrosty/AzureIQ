using System.Diagnostics;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace Harbor.Support.Api;

public sealed class HarborException(int status, string code, string safeMessage) : Exception(safeMessage)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}

public sealed class HarborExceptionHandler(
    IProblemDetailsService problems, ILogger<HarborExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext context, Exception exception, CancellationToken cancellationToken)
    {
        if (exception is OperationCanceledException && context.RequestAborted.IsCancellationRequested)
            return false;
        var (status, code, detail) = exception switch
        {
            HarborException failure => (failure.Status, failure.Code, failure.Message),
            BadHttpRequestException => (400, "invalid_request", "The request body or parameters are invalid."),
            System.Text.Json.JsonException => (400, "invalid_request", "The request JSON is invalid."),
            _ => (500, "internal_error", "The request could not be completed.")
        };
        if (status >= 500)
            logger.LogError("Request failed with {Code}; exception type {ExceptionType}; trace {TraceId}",
                code, exception.GetType().Name, Activity.Current?.TraceId.ToString());
        context.Response.StatusCode = status;
        await problems.WriteAsync(new ProblemDetailsContext
        {
            HttpContext = context,
            ProblemDetails = new ProblemDetails
            {
                Status = status,
                Title = code,
                Detail = detail,
                Type = $"urn:harbor:problem:{code}",
                Extensions = { ["code"] = code, ["traceId"] = Activity.Current?.TraceId.ToString() ?? context.TraceIdentifier }
            }
        });
        return true;
    }
}
