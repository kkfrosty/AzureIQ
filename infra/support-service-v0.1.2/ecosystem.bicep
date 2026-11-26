targetScope = 'resourceGroup'

param environmentName string
param location string = resourceGroup().location
param publisherEmail string
param applicationImage string
@secure()
param entra object
@secure()
param apiCenterReader object
param actionGroupResourceId string
param supportOpenApi object
param supportTools array
param chatModel object
param voiceModel string
param tags object
param containerAppsSubnetNetworkSecurityGroupId string
param privateEndpointsSubnetNetworkSecurityGroupId string

module foundation './foundation.bicep' = {
  name: 'harbor-foundation'
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    chatModel: chatModel
    containerAppsSubnetNetworkSecurityGroupId: containerAppsSubnetNetworkSecurityGroupId
    privateEndpointsSubnetNetworkSecurityGroupId: privateEndpointsSubnetNetworkSecurityGroupId
  }
}

var suffix = take(uniqueString(resourceGroup().id, environmentName), 8)
var appName = 'ca-hi-${suffix}'
var gatewayName = 'apim-hi-${suffix}'
var centerName = 'apic-hi-${suffix}'
var backendHost = '${appName}.${foundation.outputs.environmentDomain}'
var backendIdentity = {
  '${resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-hi-web-${suffix}')}': {}
}
var seedIdentity = {
  '${resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-hi-seed-${suffix}')}': {}
}
var commonEnvironment = [
  { name: 'ASPNETCORE_HTTP_PORTS', value: '8080' }
  { name: 'Harbor__Storage__ServiceUri', value: foundation.outputs.storageServiceUri }
  { name: 'Harbor__Storage__CasesTableName', value: 'HarborCases' }
  { name: 'Harbor__Storage__UsageTableName', value: 'HarborUsage' }
  { name: 'Harbor__Search__Endpoint', value: foundation.outputs.searchEndpoint }
  { name: 'Harbor__Search__IndexName', value: 'harbor-knowledge' }
]

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: backendIdentity
  }
  properties: {
    managedEnvironmentId: foundation.outputs.environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      ingress: {
        // Environment-external ingress is private because the environment uses an internal load balancer.
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: foundation.outputs.registryServer
          identity: foundation.outputs.backendIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'harbor'
          image: applicationImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: concat(commonEnvironment, [
            { name: 'AZURE_CLIENT_ID', value: foundation.outputs.backendClientId }
            { name: 'Harbor__Entra__TenantId', value: entra.tenantId }
            { name: 'Harbor__Entra__ClientId', value: entra.clientId }
            { name: 'Harbor__Entra__ApiAudience', value: 'api://${entra.clientId}' }
            { name: 'Harbor__Entra__Scope', value: entra.scope }
            { name: 'Harbor__Entra__GatewayRole', value: 'Support.Gateway' }
            { name: 'Harbor__Entra__CustomerRole', value: 'Support.Customer' }
            { name: 'Harbor__Ai__ChatEndpoint', value: 'https://${gatewayName}.azure-api.net/ai/chat' }
            { name: 'Harbor__Ai__TokenScope', value: 'api://${entra.clientId}/.default' }
            { name: 'Harbor__Ai__Deployment', value: chatModel.deploymentName }
            { name: 'Harbor__Ai__ApiVersion', value: '2024-10-21' }
            { name: 'Harbor__Voice__Endpoint', value: foundation.outputs.voiceEndpoint }
            { name: 'Harbor__Voice__Model', value: voiceModel }
            { name: 'Harbor__Voice__ApiVersion', value: '2026-07-15' }
            { name: 'Harbor__PathBase', value: '/support' }
            { name: 'Harbor__Voice__AllowedOrigins__0', value: 'https://${gatewayName}.azure-api.net' }
            { name: 'Harbor__Limits__VoiceSessionSeconds', value: '180' }
            { name: 'Harbor__Limits__VoiceConcurrency', value: '2' }
            { name: 'Harbor__Limits__TextMaxOutputTokens', value: '512' }
            { name: 'Harbor__Limits__LabWindowId', value: environmentName }
            { name: 'Harbor__Limits__LabWindowEndsAt', value: tags.expiresAt }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: foundation.outputs.insightsConnectionString }
          ])
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health/live', port: 8080 }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource seedJob 'Microsoft.App/jobs@2025-07-01' = {
  name: 'job-hi-seed-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: seedIdentity
  }
  properties: {
    environmentId: foundation.outputs.environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 300
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [
        {
          server: foundation.outputs.registryServer
          identity: foundation.outputs.seedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'seed'
          image: applicationImage
          command: ['dotnet', 'Harbor.Support.Api.dll']
          args: ['seed', '--execute-approved-initialization']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: concat(commonEnvironment, [
            { name: 'AZURE_CLIENT_ID', value: foundation.outputs.seedClientId }
          ])
        }
      ]
    }
  }
}

resource gateway 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  sku: { name: 'StandardV2', capacity: 1 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: 'Harbor IT Services'
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: foundation.outputs.apimSubnetId
    }
  }
}

resource modelRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingFoundry.id, gateway.id, 'OpenAIUser')
  scope: existingFoundry
  properties: {
    principalId: gateway.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  }
}

resource existingFoundry 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: 'aif-hi-${suffix}'
}

resource existingInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: 'appi-hi-${suffix}'
}

resource gatewayMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(existingInsights.id, gateway.id, 'MetricsPublisher')
  scope: existingInsights
  properties: {
    principalId: gateway.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

resource gatewayLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'harbor-gateway'
  scope: gateway
  properties: {
    workspaceId: foundation.outputs.workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ category: 'GatewayLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: gateway
  name: 'applicationinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: foundation.outputs.insightsId
    credentials: {
      connectionString: foundation.outputs.insightsConnectionString
      identityClientId: 'SystemAssigned'
    }
    isBuffered: true
  }
  dependsOn: [gatewayMetrics]
}

resource gatewayInsights 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: gateway
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    httpCorrelationProtocol: 'W3C'
    logClientIp: false
    alwaysLog: 'allErrors'
    sampling: { samplingType: 'fixed', percentage: 100 }
    frontend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [], body: { bytes: 0 } }
      response: { headers: [], body: { bytes: 0 } }
    }
  }
}

module api '../support-service/gateway-apis.bicep' = {
  name: 'harbor-apis'
  params: {
    gatewayName: gateway.name
    backendHost: backendHost
    foundryEndpoint: foundation.outputs.foundryEndpoint
    modelDeployment: chatModel.deploymentName
    tenantId: entra.tenantId
    audience: 'api://${entra.clientId}'
    customerScope: last(split(entra.scope, '/'))
    backendPrincipalId: foundation.outputs.backendPrincipalId
    supportOpenApi: supportOpenApi
    supportTools: supportTools
  }
  dependsOn: [modelRole, gatewayInsights]
}

module catalog '../support-service/api-center.bicep' = {
  name: 'harbor-catalog'
  params: {
    name: centerName
    location: location
    gatewayName: gateway.name
    reader: apiCenterReader
    tags: tags
  }
  dependsOn: [api]
}

resource failureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-hi-gateway-errors-${suffix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Candidate low-volume Harbor gateway failure signal; validate expected counts and alert delivery.'
    severity: 2
    enabled: true
    scopes: [gateway.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'server-errors'
          metricNamespace: 'Microsoft.ApiManagement/service'
          metricName: 'Requests'
          dimensions: [{ name: 'GatewayResponseCodeCategory', operator: 'Include', values: ['5xx'] }]
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 5
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [{ actionGroupId: actionGroupResourceId }]
  }
}

output applicationUrl string = 'https://${gateway.name}.azure-api.net/support/'
output apiManagementName string = gateway.name
output apiCenterName string = centerName
output apiCenterMcpEndpoint string = catalog.outputs.mcpEndpoint
output containerRegistryName string = foundation.outputs.registryName
output seedJobName string = seedJob.name
output expectedResourceIds array = concat(foundation.outputs.resourceIds, [
  app.id
  seedJob.id
  gateway.id
  modelRole.id
  gatewayMetrics.id
  gatewayLogs.id
  logger.id
  gatewayInsights.id
  failureAlert.id
], api.outputs.resourceIds, catalog.outputs.resourceIds)
