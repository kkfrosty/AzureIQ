targetScope = 'resourceGroup'

param gatewayName string
param backendHost string
@secure()
param audience string
param supportOpenApi object
param catalogName string
param location string
@secure()
param reader object
param tags object

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: gatewayName
}

resource voice 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: gateway
  name: 'harbor-voice'
}

resource handshake 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' existing = {
  parent: voice
  name: 'onHandshake'
}

resource voicePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: handshake
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('../support-service/policies/voice.xml'), '__AUDIENCE__', audience)
  }
}

// The pinned image's catch-all is a runtime 404, not a public API operation.
var publishedPaths = toObject(
  filter(items(supportOpenApi.paths), path => path.key != '/v1/{unmatched}'),
  path => path.key,
  path => path.value)
var publishedDocument = shallowMerge([supportOpenApi, { paths: publishedPaths }])

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
    value: string(publishedDocument)
  }
}

module remainingApis './remaining-apis.bicep' = {
  name: 'harbor-remaining-apis'
  params: {
    gatewayName: gatewayName
    supportTools: supportTools
    tenantId: tenantId
    audience: audience
    customerScope: customerScope
  }
  dependsOn: [support]
}

param supportTools array
@secure()
param tenantId string
param customerScope string

module catalog '../support-service/api-center.bicep' = {
  name: 'harbor-catalog-repair'
  params: {
    name: catalogName
    location: location
    gatewayName: gatewayName
    reader: reader
    tags: tags
  }
  dependsOn: [voicePolicy, remainingApis]
}

output catalogId string = resourceId('Microsoft.ApiCenter/services', catalogName)
output applicationUrl string = 'https://${gatewayName}.azure-api.net/support/'
