targetScope = 'subscription'

metadata description = 'Disposable Waypoint Freight App Service, API Management, and observability baseline.'

@description('Short AZD environment name used for ownership and lifecycle tags.')
@minLength(3)
@maxLength(40)
param environmentName string

@description('Azure region for the resource group and all contained resources.')
param location string

@description('Dedicated disposable resource group name.')
param resourceGroupName string

@description('API Management publisher email. Supplied from the private AZD environment.')
param publisherEmail string

@description('UTC creation time recorded in lifecycle tags.')
param createdAt string

@description('UTC expiry time recorded in lifecycle tags.')
param expiresAt string

var ownershipTags = {
  'azd-env-name': environmentName
  managedBy: 'AzureIQ'
  lifecycle: 'ephemeral'
  caseStudy: 'WaypointFreight'
  environmentId: environmentName
  createdAt: createdAt
  expiresAt: expiresAt
}

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: ownershipTags
}

module waypointFreight './modules/waypoint-freight.bicep' = {
  name: 'waypoint-freight-${take(uniqueString(environmentName, location), 8)}'
  scope: environmentResourceGroup
  params: {
    name: environmentName
    location: location
    publisherEmail: publisherEmail
    tags: ownershipTags
  }
}

resource activityLogDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-wf-activity-${take(uniqueString(subscription().id, environmentName), 8)}'
  properties: {
    workspaceId: waypointFreight.outputs.logAnalyticsResourceId
    logs: [
      {
        category: 'Administrative'
        enabled: true
      }
      {
        category: 'Security'
        enabled: true
      }
      {
        category: 'ServiceHealth'
        enabled: true
      }
      {
        category: 'Alert'
        enabled: true
      }
      {
        category: 'Recommendation'
        enabled: true
      }
      {
        category: 'Policy'
        enabled: true
      }
      {
        category: 'Autoscale'
        enabled: true
      }
      {
        category: 'ResourceHealth'
        enabled: true
      }
    ]
  }
}

output AZURE_RESOURCE_GROUP string = environmentResourceGroup.name
output AZURE_LOCATION string = location
output SERVICE_API_NAME string = waypointFreight.outputs.appServiceName
output API_URL string = waypointFreight.outputs.gatewayApiUrl
output APIM_GATEWAY_URL string = waypointFreight.outputs.gatewayApiUrl
output APP_SERVICE_URL string = waypointFreight.outputs.appServiceUrl
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = waypointFreight.outputs.logAnalyticsResourceId
output APPLICATION_INSIGHTS_NAME string = waypointFreight.outputs.applicationInsightsName
output API_MANAGEMENT_NAME string = waypointFreight.outputs.apiManagementName
output EXPECTED_RESOURCE_IDS array = concat(waypointFreight.outputs.expectedResourceIds, [
  activityLogDiagnostics.id
])