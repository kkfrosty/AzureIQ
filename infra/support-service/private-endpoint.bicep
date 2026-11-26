targetScope = 'resourceGroup'

param name string
param location string
param subnetResourceId string
param targetResourceId string
param groupId string
param virtualNetworkResourceId string
param dnsZoneNames array
param tags object

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zoneName in dnsZoneNames: {
    name: zoneName
    location: 'global'
    tags: tags
  }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zoneName, index) in dnsZoneNames: {
    parent: zones[index]
    name: 'harbor-link'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: virtualNetworkResourceId
      }
    }
  }
]

resource group 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for (zoneName, index) in dnsZoneNames: {
        name: replace(zoneName, '.', '-')
        properties: {
          privateDnsZoneId: zones[index].id
        }
      }
    ]
  }
}

var zoneIds = [for (zoneName, index) in dnsZoneNames: zones[index].id]
var linkIds = [for (zoneName, index) in dnsZoneNames: links[index].id]
var interfaceIds = map(endpoint.properties.networkInterfaces ?? [], item => item.id)
output resourceIds array = concat([endpoint.id, group.id], zoneIds, linkIds, interfaceIds)
