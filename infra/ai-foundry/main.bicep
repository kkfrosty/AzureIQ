targetScope = 'subscription'

metadata description = 'Reusable AI Foundry and API Management AI gateway environment. Deploy multiple instances by changing environmentName and resourceGroupName.'

@description('Short environment name used for ownership tags and stable resource naming.')
@minLength(3)
@maxLength(40)
param environmentName string

@description('Azure region for the resource group and all contained resources.')
param location string

@description('Resource group that owns this AI gateway instance.')
param resourceGroupName string

@description('API Management publisher email. Supplied from the private environment configuration.')
param publisherEmail string

@description('API Management SKU used for the gateway.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
])
param apiManagementSku string = 'Developer'

@description('Model deployments created on the AI Foundry account.')
param modelDeployments array = [
  {
    name: 'gpt-5.4-mini'
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-mini'
      version: '2026-03-17'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 50
    }
  }
  {
    name: 'gpt-5.4-nano'
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-nano'
      version: '2026-03-17'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 50
    }
  }
]

@description('UTC creation time recorded in lifecycle tags.')
param createdAt string = utcNow()

@description('UTC expiry time recorded in lifecycle tags.')
param expiresAt string = dateTimeAdd(utcNow(), 'P1D')

@description('Lifecycle classification recorded in ownership tags.')
@allowed([
  'ephemeral'
  'persistent'
])
param lifecycle string = 'ephemeral'

var ownershipTags = {
  managedBy: 'AzureIQ'
  lifecycle: lifecycle
  caseStudy: 'AIFoundryGateway'
  environmentId: environmentName
  createdAt: createdAt
  expiresAt: expiresAt
}

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: ownershipTags
}

module aiFoundryGateway './modules/ai-foundry-gateway.bicep' = {
  name: 'ai-foundry-gateway-${take(uniqueString(environmentName, location), 8)}'
  scope: environmentResourceGroup
  params: {
    name: environmentName
    location: location
    publisherEmail: publisherEmail
    apiManagementSku: apiManagementSku
    modelDeployments: modelDeployments
    tags: ownershipTags
  }
}

output AZURE_RESOURCE_GROUP string = environmentResourceGroup.name
output AZURE_LOCATION string = location
output AI_FOUNDRY_NAME string = aiFoundryGateway.outputs.aiFoundryName
output AI_FOUNDRY_PROJECT_NAME string = aiFoundryGateway.outputs.aiFoundryProjectName
output AI_FOUNDRY_ENDPOINT string = aiFoundryGateway.outputs.aiFoundryEndpoint
output API_MANAGEMENT_NAME string = aiFoundryGateway.outputs.apiManagementName
output CHAT_GATEWAY_URL string = aiFoundryGateway.outputs.chatGatewayUrl
output MODEL_DEPLOYMENT_NAMES array = aiFoundryGateway.outputs.modelDeploymentNames
output APPLICATION_INSIGHTS_NAME string = aiFoundryGateway.outputs.applicationInsightsName
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = aiFoundryGateway.outputs.logAnalyticsResourceId
output EXPECTED_RESOURCE_IDS array = aiFoundryGateway.outputs.expectedResourceIds
