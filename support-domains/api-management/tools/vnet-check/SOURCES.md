# Reviewed APIM Networking Sources

Reviewed 2026-10-14 using current Microsoft documentation. These are versioned rules, not a promise that every documentation requirement is automatically checked. Review again when the networking model, API version or Microsoft requirements change.

| Source | Applicability | Implemented or deliberately unresolved |
| --- | --- | --- |
| [Injection network resources](https://learn.microsoft.com/azure/api-management/virtual-network-injection-resources) | Classic Developer/Premium | Same region/subscription, /29 minimum, no delegation, attached NSG, per-location evaluation. Classic unit address arithmetic checked; actual free capacity unknown. |
| [Classic VNet configuration reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference) | Classic only | Required dependency NSG ports and regional Storage/SQL tags. Developer load-balancer exception takes precedence over applying the Premium probe requirement blindly. |
| [External VNet routing](https://learn.microsoft.com/azure/api-management/api-management-using-with-vnet#routing) | Classic external/internal routing guidance | Strong proactive endpoint recommendation; VirtualAppliance/VirtualNetworkGateway default UDR classification; global ApiManagement service-tag Internet return-route evaluation. Missing applicable endpoint/return-route safeguards under configured forced tunneling are requirement gaps, not confirmed outage causes. SQL applies to the primary region; Event Hubs depends on use; maintained firewall alternatives remain valid. |
| [Internal VNet DNS](https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet#dns-configuration) | Classic internal | Custom/private DNS is necessary; configuration does not prove resolution. No workstation DNS result is presented as APIM evidence. |
| [Premium v2 injection](https://learn.microsoft.com/azure/api-management/inject-vnet-v2) | Premium v2 only | Dedicated subnet, /27 minimum, /24 recommendation, hostingEnvironments delegation, NSG and Key Vault 443, private inbound DNS. Dedicated occupancy and actual DNS resolution remain unknown. |
| [Network status REST API](https://learn.microsoft.com/rest/api/apimanagement/network-status/list-by-service?view=rest-apimanagement-2024-05-01) | Availability discovered at runtime | GET returns a bare array of locations, each with `networkStatus.connectivityStatus`; freshness and `isOptional` matter. Missing/unsupported API is unknown, especially for v2, not a fallback to classic assumptions. |

## Documentation interpretation

- The classic required-port table lists the load-balancer probe, but the same document explicitly exempts Developer because it has one compute unit. The checker requires 6390 only for Premium.
- Classic regional dependency tags must include both the deployment region and the primary region. This checker evaluates those separately instead of treating a regional tag as global.
- Premium v2 subnet-sizing examples mix total usable-address and allocation figures. This version uses the explicit /27 minimum and /24 recommendation, not the example table to assert available scale headroom. It does not reuse classic address arithmetic for Premium v2.
- HTTP ingress on 80 depends on intended client access; this version checks external HTTPS 443 and does not require HTTP as a universal healthy-service condition.
- Recommend applicable service endpoints before future VNet changes, even without current forced tunneling. Under forced tunneling, their absence is a required safeguard gap unless a maintained firewall alternative is independently verified. Do not call that gap a proven outage or claim endpoints are the only supported solution.
- The classic ApiManagement service-tag Internet UDR preserves symmetric replies to inbound management traffic. It is distinct from the NSG inbound TCP 3443 permit. Regional tags or more-specific IP routes need complete coverage/effective-route evidence; Premium v2 does not inherit the classic requirement.
- Native dependency failures are evidence of a failing dependency path, not proof of which NSG, route, DNS server or firewall caused it.
- Current classic internal DNS guidance warns against an authoritative zone for the apex `azure-api.net`; scope records/zones to the instance's exact endpoint hostnames. This version does not discover DNS zone ownership and reports DNS resolution as unknown.

## Coverage still requiring evidence

Private DNS zone/record/link discovery, effective route/BGP and peering analysis, firewall policy/flow logs, TLS/SNI and custom certificates, backend policies and authentication, optional feature dependencies and safe client/backend probes are separate follow-on capabilities. Required NTP and FQDN-based infrastructure egress are explicitly unevaluated; the initial NSG matrix is not exhaustive.

Version 0.2 exposes every area as an HTML/JSON section with coverage notes, expected/observed findings, next evidence needed and documentation links. This coverage inventory is not a claim that all documentation requirements are automatically tested.

Version 0.2.1 preserves native UTC instants through PowerShell JSON DateTime
conversion, includes safe dependency labels, and projects reviewed NSG/UDR/endpoint
metadata into the private operator report for support review.

## Rule provenance

Digests use UTF-8 rule text with LF-normalized line endings.

| Version | SHA-256 |
| --- | --- |
| 0.2.0 | `6532256b44eb408304e7211f4ffd385b91e46ad7893ea781c2459f9cc60f127c` |
| 0.2.1 | `755d78f6a6fc05d53c70d6bce4d6a0ac7d0250c43f853e33549314e6048b9aea` |
| 0.2.2 | `9edd8c90190c9f8c523dd235de4c528191546a746811e115bfad9ed174645cf8` |
| 0.3.0 | `c5339fe2e18e64023a93cca5a292bec98a89965edc686b3282e39bda03428d38` |
| 0.3.1 | `dadd0a5da8c520eb85a7521674c3a85b622f3a4658a44af6ace51bbf7d022b46` |
| 0.3.2 | `2e7033ae04eda1b6e8eed3866c1e0b7939555f1cb9c25d76d9588b4f08c23908` |
| 0.3.3 | `e4bb846ac6e3a359d4b864fa399faee732e665259e9493aef6741f1a85f31f9a` |

Version 0.2.2 treats a configured discard default UDR as a configuration issue,
without claiming every flow is affected. Endpoint and management return-route
recommendations remain visible regardless of changing/removing the default
route. Private reports use the Git-ignored trusted-workspace report taxonomy.

Version 0.3.0 separates customer evidence states from raw machine statuses.
APIM Network status results retain API provenance, safe names, original
timestamps, reported status and error availability. Validated resource-specific
portal links are confined to private operator reports. NSG decisions use the
collected subnet prefix set and treat ambiguous earlier rules as decisive
uncertainty only when their access can change the guaranteed fallback result.

Version 0.3.1 replaces generic requirement text with check-specific criteria
and adds private section-local resource links and scoped GHC planning requests.
The request is not an approved action manifest or an execution capability.

Version 0.3.2 publishes collected configuration/platform findings only;
unimplemented checks remain coverage disclosures, not inferred problems.
Management-route guidance spells out route-table creation/reuse, the service
tag/next-hop settings and APIM-subnet association, with qualified future
peering/gateway-transit/BGP and more-specific-route limitations.

Version 0.3.3 shows every collected Network status observation directly in an
unfiltered connection table. Reported connectivity and freshness stay distinct;
Azure Portal is supplementary for raw errors and newer observations.
