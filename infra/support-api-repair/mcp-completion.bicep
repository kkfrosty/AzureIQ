targetScope = 'resourceGroup'

param gatewayName string
param supportTools array
@secure()
param tenantId string
@secure()
param audience string
param customerScope string
param catalogName string
param location string
@secure()
param reader object
param tags object

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}
resource support 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' existing = {
  parent: gateway
  name: 'harbor-support'
}

// sourceApiId clones the REST API; REST-backed MCP instead binds each tool.
resource mcp 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: gateway
  name: 'harbor-support-mcp'
  properties: {
    displayName: 'Harbor authorized support tools'
    description: 'Seven selected Harbor support operations with independent caller authorization.'
    type: 'mcp'
    path: 'support-mcp'
    protocols: ['https']
    subscriptionRequired: false
  }
}
resource tools 'Microsoft.ApiManagement/service/apis/tools@2025-09-01-preview' = [
  for tool in supportTools: {
    parent: mcp
    name: tool.name
    properties: {
      displayName: tool.name
      description: tool.description
      operationId: '${support.id}/operations/${tool.operationId}'
    }
  }
]
resource policy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = {
  parent: mcp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(
      replace(
        replace(loadTextContent('../support-service/policies/mcp.xml'), '__TENANT__', tenantId),
        '__AUDIENCE__', audience),
      '__SCOPE__', customerScope), '__CLIENT_ID__', replace(audience, 'api://', ''))
  }
}
module catalog '../support-service/api-center.bicep' = {
  name: 'harbor-catalog-final'
  params: {
    name: catalogName
    location: location
    gatewayName: gatewayName
    reader: reader
    tags: tags
  }
  dependsOn: [tools, policy]
}
output mcpApiId string = mcp.id
output catalogId string = resourceId('Microsoft.ApiCenter/services', catalogName)
