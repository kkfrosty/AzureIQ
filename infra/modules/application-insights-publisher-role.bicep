targetScope = 'resourceGroup'

metadata description = 'Assigns Monitoring Metrics Publisher to one managed identity at one Application Insights component.'

@description('Workload name used in the role assignment description.')
param name string

@description('Azure region of the workload and component.')
param location string = resourceGroup().location

@description('Ownership tags used to describe the managed assignment.')
param tags object = {}

@description('Name of the target Application Insights component.')
param applicationInsightsName string

@description('Object ID of the system- or user-assigned managed identity.')
param principalId string

var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
var managedBy = tags.?managedBy ?? 'declarative infrastructure'

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationInsights.id, principalId, monitoringMetricsPublisherRoleDefinitionId)
  scope: applicationInsights
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    description: 'Allow ${name} in ${location} to publish telemetry only to this component; managed by ${managedBy}.'
  }
}

output resourceId string = telemetryPublisher.id
