targetScope = 'resourceGroup'

param gatewayName string
param backendHost string
param foundryEndpoint string
param modelDeployment string
@secure()
param tenantId string
@secure()
param audience string
param customerScope string
@secure()
param backendPrincipalId string
param supportOpenApi object
param supportTools array

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource support 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: gateway
  name: 'harbor-support'
  properties: {
    displayName: 'Harbor IT Services support'
    description: 'Fictional company APIs; customer authorization is also enforced by the private backend.'
    apiType: 'http'
    type: 'http'
    apiRevision: '1'
    path: 'support'
    protocols: ['https']
    serviceUrl: 'https://${backendHost}'
    subscriptionRequired: false
    format: 'openapi+json'
    value: string(supportOpenApi)
  }
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
        replace(loadTextContent('./policies/support.xml'), '__TENANT__', tenantId),
        '__AUDIENCE__', audience),
      '__SCOPE__', customerScope), '__CLIENT_ID__', replace(audience, 'api://', ''))
  }
}

resource chat 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: gateway
  name: 'harbor-ai'
  properties: {
    displayName: 'Harbor backend-only model gateway'
    apiType: 'http'
    type: 'http'
    path: 'ai'
    protocols: ['https']
    serviceUrl: foundryEndpoint
    subscriptionRequired: false
  }
}

resource chatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: chat
  name: 'ChatCompletion'
  properties: {
    displayName: 'Bounded chat completion for Harbor backend'
    method: 'POST'
    urlTemplate: '/chat'
    templateParameters: []
  }
}

var chatPolicyText = replace(replace(
  replace(
    replace(
      replace(loadTextContent('./policies/chat.xml'), '__TENANT__', tenantId),
      '__AUDIENCE__', audience),
    '__BACKEND_OBJECT_ID__', backendPrincipalId),
  '__DEPLOYMENT__', modelDeployment), '__CLIENT_ID__', replace(audience, 'api://', ''))

resource chatPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: chat
  name: 'policy'
  properties: { format: 'rawxml', value: chatPolicyText }
}

resource voice 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: gateway
  name: 'harbor-voice'
  properties: {
    displayName: 'Harbor controlled voice connection'
    apiType: 'websocket'
    type: 'websocket'
    path: 'support/voice'
    protocols: ['wss']
    serviceUrl: 'wss://${backendHost}/voice/socket'
    subscriptionRequired: false
  }
}

resource voicePolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: voice
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('./policies/voice.xml'), '__AUDIENCE__', audience)
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
      endpoints: [{ name: 'mcp', uriTemplate: '/mcp' }]
    }
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

resource mcpPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = {
  parent: mcp
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(replace(
      replace(
        replace(loadTextContent('./policies/mcp.xml'), '__TENANT__', tenantId),
        '__AUDIENCE__', audience),
      '__SCOPE__', customerScope), '__CLIENT_ID__', replace(audience, 'api://', ''))
  }
}

var toolIds = [for (tool, index) in supportTools: tools[index].id]
output resourceIds array = concat([
  support.id
  assets.id
  supportPolicy.id
  chat.id
  chatOperation.id
  chatPolicy.id
  voice.id
  voicePolicy.id
  mcp.id
  mcpPolicy.id
], toolIds)
output supportMcpUrl string = 'https://${gatewayName}.azure-api.net/support-mcp/mcp'
