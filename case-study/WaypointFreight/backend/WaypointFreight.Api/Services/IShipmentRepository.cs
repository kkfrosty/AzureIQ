using WaypointFreight.Api.Models;

namespace WaypointFreight.Api.Services;

public interface IShipmentRepository
{
    IReadOnlyList<Shipment> GetAll();

    Shipment? GetByTrackingNumber(string trackingNumber);
}