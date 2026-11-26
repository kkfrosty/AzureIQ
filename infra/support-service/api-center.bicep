targetScope = 'resourceGroup'

param name string
param location string
param gatewayName string
@secure()
param reader object
param tags object

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource center 'Microsoft.ApiCenter/services@2024-03-01' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  // The published AVM also supplies SKU despite the provider type-schema omission.
  #disable-next-line BCP187
  sku: { name: 'Standard' }
}

resource workspace 'Microsoft.ApiCenter/services/workspaces@2024-03-01' = {
  parent: center
  name: 'default'
  properties: {
    title: 'Harbor IT Services'
    description: 'Synthetic support API and MCP discovery registry.'
  }
}

resource environment 'Microsoft.ApiCenter/services/workspaces/environments@2024-03-01' = {
  parent: workspace
  name: 'harbor-lab'
  properties: {
    title: 'Harbor learning lab'
    kind: 'testing'
    description: 'On-demand, owned, nonproduction environment.'
    server: { type: 'Azure API Management' }
  }
}

resource sourceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(gateway.id, center.id, 'ApiManagementServiceReader')
  scope: gateway
  properties: {
    principalId: center.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '71522526-b88f-4d52-b57f-d31fc3546d0d')
  }
}

resource source 'Microsoft.ApiCenter/services/workspaces/apiSources@2024-06-01-preview' = {
  parent: workspace
  name: 'harbor-apim'
  properties: {
    azureApiManagementSource: { resourceId: gateway.id }
    importSpecification: 'always'
    targetEnvironmentId: '/workspaces/default/environments/${environment.name}'
    targetLifecycleStage: 'testing'
  }
  dependsOn: [sourceReader]
}

resource discoveryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(center.id, reader.principalId, 'ApiCenterDataReader')
  scope: center
  properties: {
    principalId: reader.principalId
    principalType: reader.principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c7244dfb-f447-457d-b2ba-3999044d1706')
  }
}

output mcpEndpoint string = 'https://${center.name}.data.${location}.azure-apicenter.ms/mcp'
output resourceIds array = [
  center.id, workspace.id, environment.id, sourceReader.id, source.id, discoveryReader.id
]
output readinessGates array = [
  'Verify Standard plan and eligible linked APIM benefit'
  'Enable the authenticated API Center portal through the supported live configuration workflow'
  'Enable the native Data API MCP endpoint; this template does not invent an undocumented toggle'
  'Execute mcp_registry_search and mcp_registry_fetch using an authorized client'
]
