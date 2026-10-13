# Azure Networking Support Domain

Umbrella routing boundary for cross-service network diagnosis and topology. It does not own every Azure networking product indefinitely.

## Product Boundaries

Start here for end-to-end path reasoning, then create focused child packs only after a demonstrated gap:

- Front Door and CDN
- Application Gateway and WAF
- Azure Firewall
- virtual networks, subnets, NSGs, routes, and NAT Gateway
- Private Link and private endpoints
- Azure DNS and Private DNS
- Load Balancer, Traffic Manager, VPN, and ExpressRoute

This pack is `draft` and contains no reusable artifacts yet. Product-specific queries and runbooks must move into focused packs when their scope becomes substantial.