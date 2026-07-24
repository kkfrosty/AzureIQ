using WaypointFreight.Api.Models;
using WaypointFreight.Api.Services;

namespace WaypointFreight.Api.Endpoints;

public static class ShipmentEndpoints
{
    public static IEndpointRouteBuilder MapShipmentEndpoints(this IEndpointRouteBuilder endpoints)
    {
        RouteGroupBuilder group = endpoints.MapGroup("/api/shipments")
            .WithTags("Shipments");

        group.MapGet("/", (IShipmentRepository repository) =>
            TypedResults.Ok(repository.GetAll()
                .OrderByDescending(shipment => shipment.LastUpdated)
                .Select(ToSummary)))
            .WithName("ListShipments");

        group.MapGet("/{trackingNumber}", (string trackingNumber, IShipmentRepository repository, HttpContext context) =>
        {
            Shipment? shipment = repository.GetByTrackingNumber(trackingNumber);
            return shipment is null
                ? Results.NotFound(NotFound(trackingNumber, context.TraceIdentifier))
                : Results.Ok(shipment);
        })
        .WithName("GetShipment");

        group.MapGet("/{trackingNumber}/events", (string trackingNumber, IShipmentRepository repository, HttpContext context) =>
        {
            Shipment? shipment = repository.GetByTrackingNumber(trackingNumber);
            return shipment is null
                ? Results.NotFound(NotFound(trackingNumber, context.TraceIdentifier))
                : Results.Ok(shipment.Events.OrderByDescending(shipmentEvent => shipmentEvent.OccurredAt));
        })
        .WithName("GetShipmentEvents");

        return endpoints;
    }

    private static ShipmentSummary ToSummary(Shipment shipment) => new(
        shipment.TrackingNumber,
        shipment.Origin,
        shipment.Destination,
        shipment.Status,
        shipment.EstimatedDelivery,
        shipment.LastUpdated);

    private static ApiError NotFound(string trackingNumber, string correlationId) => new(
        "shipment.not_found",
        $"Shipment '{trackingNumber}' was not found.",
        correlationId,
        false);
}