# Reviewed APIM Networking Sources

Reviewed 2026-10-14 using current Microsoft documentation. These are versioned rules, not a promise that every documentation requirement is automatically checked. Review again when the networking model, API version or Microsoft requirements change.

| Source | Applicability | Implemented or deliberately unresolved |
| --- | --- | --- |
| [Injection network resources](https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources) | Classic Developer/Premium | Same region/subscription, /29 minimum, no delegation, attached NSG, per-location evaluation. Classic unit address arithmetic checked; actual free capacity unknown. |
| [Classic VNet configuration reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference) | Classic only | Required dependency NSG ports and regional Storage/SQL tags. Developer load-balancer exception takes precedence over applying the Premium probe requirement blindly. |
| [External VNet routing](https://learn.microsoft.com/azure/api-management/api-management-using-with-vnet#routing) | Classic external/internal routing guidance | Default UDR investigation, ApiManagement-to-Internet management return path and service endpoint recommendations. Firewall/BGP/effective routes are not proven. |
| [Internal VNet DNS](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet#dns-configuration) | Classic internal | Custom/private DNS is necessary; configuration does not prove resolution. No workstation DNS result is presented as APIM evidence. |
| [Premium v2 injection](https://learn.microsoft.com/azure/api-management/inject-vnet-v2) | Premium v2 only | Dedicated subnet, /27 minimum, /24 recommendation, hostingEnvironments delegation, NSG and Key Vault 443, private inbound DNS. Dedicated occupancy and actual DNS resolution remain unknown. |
| [Network status REST API](https://learn.microsoft.com/rest/api/apimanagement/network-status/list-by-service?view=rest-apimanagement-2024-05-01) | Availability discovered at runtime | GET returns a bare array of locations, each with `networkStatus.connectivityStatus`; freshness and `isOptional` matter. Missing/unsupported API is unknown, especially for v2, not a fallback to classic assumptions. |

## Documentation interpretation

- The classic required-port table lists the load-balancer probe, but the same document explicitly exempts Developer because it has one compute unit. The checker requires 6390 only for Premium.
- Classic regional dependency tags must include both the deployment region and the primary region. This checker evaluates those separately instead of treating a regional tag as global.
- Premium v2 subnet-sizing examples mix total usable-address and allocation figures. This version uses the explicit /27 minimum and /24 recommendation, not the example table to assert available scale headroom. It does not reuse classic address arithmetic for Premium v2.
- HTTP ingress on 80 depends on intended client access; this version checks external HTTPS 443 and does not require HTTP as a universal healthy-service condition.
- Absence of service endpoints does not alone establish a fault: the routing guidance describes firewall-based alternatives. Effective reachability is unknown until corroborated.
- Native dependency failures are evidence of a failing dependency path, not proof of which NSG, route, DNS server or firewall caused it.

## Coverage still requiring evidence

Private DNS zone/record/link discovery, effective route/BGP and peering analysis, firewall policy/flow logs, TLS/SNI and custom certificates, backend policies and authentication, optional feature dependencies and safe client/backend probes are separate follow-on capabilities. Required NTP and FQDN-based infrastructure egress are explicitly unevaluated; the initial NSG matrix is not exhaustive.
