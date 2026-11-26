targetScope = 'resourceGroup'

param gatewayName string
param supportTools array
@secure()
param tenantId string
@secure()
param audience string
param customerScope string

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}
resource support 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' existing = {
  parent: gateway
  name: 'harbor-support'
}
resource assets 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: support
  name: 'FrontendAssets'
  properties: {
    displayName: 'Public fictional-demo client assets'
    method: 'GET'
    urlTemplate: '/*'
    templateParameters: []
  }
}
resource supportPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: support
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(
      replace(
        replace(loadTextContent('../support-service/policies/support.xml'), '__TENANT__', tenantId),
        '__AUDIENCE__', audience),
      '__SCOPE__', customerScope), '__CLIENT_ID__', replace(audience, 'api://', ''))
  }
}
resource mcp 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: gateway
  name: 'harbor-support-mcp'
  properties: {
    displayName: 'Harbor authorized support tools'
    apiType: 'mcp'
    type: 'mcp'
    path: 'support-mcp'
    protocols: ['https']
    sourceApiId: '/apis/${support.name}'
    subscriptionRequired: false
    mcpProperties: {
      transportType: 'streamable'
      // The live provider rejects arrays; its preview Bicep type still declares one.
      #disable-next-line BCP036
      endpoints: {
        mcp: { uriTemplate: '/mcp' }
      }
    }
  }
}
resource mcpPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = {
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
resource tools 'Microsoft.ApiManagement/service/apis/tools@2025-09-01-preview' = [
  for tool in supportTools: {
    parent: mcp
    name: tool.name
    properties: {
      displayName: tool.name
      description: tool.description
      operationId: '/apis/${support.name}/operations/${tool.operationId}'
    }
  }
]
