using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Services;

public sealed class InMemoryShipmentRepository : IShipmentRepository
{
    private static readonly IReadOnlyList<Shipment> Shipments =
    [
        new(
            "WF-1042",
            "Seattle, WA",
            "Denver, CO",
            ShipmentStatus.InTransit,
            new DateOnly(2026, 7, 25),
            new DateTimeOffset(2026, 7, 23, 14, 18, 0, TimeSpan.Zero),
            [
                new(new DateTimeOffset(2026, 7, 22, 8, 10, 0, TimeSpan.Zero), "Seattle, WA", "PICKED_UP", "Shipment collected from sender"),
                new(new DateTimeOffset(2026, 7, 22, 18, 45, 0, TimeSpan.Zero), "Spokane, WA", "IN_TRANSIT", "Departed regional facility"),
                new(new DateTimeOffset(2026, 7, 23, 14, 18, 0, TimeSpan.Zero), "Boise, ID", "IN_TRANSIT", "Arrived at sorting facility")
            ]),
        new(
            "WF-2088",
            "Austin, TX",
            "Atlanta, GA",
            ShipmentStatus.OutForDelivery,
            new DateOnly(2026, 7, 23),
            new DateTimeOffset(2026, 7, 23, 12, 5, 0, TimeSpan.Zero),
            [
                new(new DateTimeOffset(2026, 7, 21, 16, 20, 0, TimeSpan.Zero), "Austin, TX", "PICKED_UP", "Shipment collected from sender"),
                new(new DateTimeOffset(2026, 7, 22, 22, 12, 0, TimeSpan.Zero), "Atlanta, GA", "AT_DESTINATION", "Arrived at destination facility"),
                new(new DateTimeOffset(2026, 7, 23, 12, 5, 0, TimeSpan.Zero), "Atlanta, GA", "OUT_FOR_DELIVERY", "Courier is completing delivery")
            ]),
        new(
            "WF-3301",
            "Boston, MA",
            "Portland, ME",
            ShipmentStatus.Delivered,
            new DateOnly(2026, 7, 22),
            new DateTimeOffset(2026, 7, 22, 19, 42, 0, TimeSpan.Zero),
            [
                new(new DateTimeOffset(2026, 7, 22, 8, 0, 0, TimeSpan.Zero), "Boston, MA", "PICKED_UP", "Shipment collected from sender"),
                new(new DateTimeOffset(2026, 7, 22, 15, 30, 0, TimeSpan.Zero), "Portland, ME", "OUT_FOR_DELIVERY", "Courier is completing delivery"),
                new(new DateTimeOffset(2026, 7, 22, 19, 42, 0, TimeSpan.Zero), "Portland, ME", "DELIVERED", "Delivered at receiving desk")
            ]),
        new(
            "WF-7719",
            "Phoenix, AZ",
            "San Diego, CA",
            ShipmentStatus.Delayed,
            new DateOnly(2026, 7, 26),
            new DateTimeOffset(2026, 7, 23, 9, 35, 0, TimeSpan.Zero),
            [
                new(new DateTimeOffset(2026, 7, 22, 11, 50, 0, TimeSpan.Zero), "Phoenix, AZ", "PICKED_UP", "Shipment collected from sender"),
                new(new DateTimeOffset(2026, 7, 23, 9, 35, 0, TimeSpan.Zero), "Yuma, AZ", "WEATHER_DELAY", "Route delayed by severe weather")
            ])
    ];

    public IReadOnlyList<Shipment> GetAll() => Shipments;

    public Shipment? GetByTrackingNumber(string trackingNumber) =>
        Shipments.FirstOrDefault(shipment =>
            string.Equals(shipment.TrackingNumber, trackingNumber, StringComparison.OrdinalIgnoreCase));
}