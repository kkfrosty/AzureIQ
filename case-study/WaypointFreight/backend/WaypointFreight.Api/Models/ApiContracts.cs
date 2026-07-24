namespace WaypointFreight.Api.Models;

public sealed record ApiError(
    string Code,
    string Message,
    string CorrelationId,
    bool Retryable);

public sealed record ServiceInfo(
    string Name,
    string Version,
    string Description);