namespace WaypointFreight.Api.Models;

public enum ShipmentStatus
{
    LabelCreated,
    InTransit,
    Delayed,
    OutForDelivery,
    Delivered
}

public sealed record ShipmentEvent(
    DateTimeOffset OccurredAt,
    string Location,
    string Code,
    string Description);

public sealed record Shipment(
    string TrackingNumber,
    string Origin,
    string Destination,
    ShipmentStatus Status,
    DateOnly EstimatedDelivery,
    DateTimeOffset LastUpdated,
    IReadOnlyList<ShipmentEvent> Events);

public sealed record ShipmentSummary(
    string TrackingNumber,
    string Origin,
    string Destination,
    ShipmentStatus Status,
    DateOnly EstimatedDelivery,
    DateTimeOffset LastUpdated);