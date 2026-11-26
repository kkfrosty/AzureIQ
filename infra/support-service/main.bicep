targetScope = 'subscription'

metadata description = 'Candidate disposable Harbor IT Services lab; deployment requires private scope, cost, identity and native MCP readiness approval.'

@description('Unique nonproduction run identifier. Use a fresh identifier after teardown.')
@minLength(3)
@maxLength(20)
param environmentName string

@description('Approved region; verify Standard v2, API Center, Search and Voice Live availability before applying.')
param location string

@description('Dedicated owned resource group. Never target a shared resource group.')
param resourceGroupName string

@description('APIM publisher contact; this does not authorize sending communications.')
param publisherEmail string

@description('Immutable Harbor application image, built from the validated application source.')
@minLength(20)
param applicationImage string

@description('Private Entra application configuration. Registration and consent require separate approval.')
@secure()
param entra object

@description('Principal explicitly approved for API Center discovery access.')
@secure()
param apiCenterReader object

@description('Existing approved notification destination for operational alerts.')
param actionGroupResourceId string

@description('Generated OpenAPI 3 document from the actual Harbor application build.')
param supportOpenApi object

@description('Explicit support operations selected from the generated OpenAPI, not management or inference operations.')
param supportTools array

@description('Chat model and deployment parameters after live availability/quota verification.')
param chatModel object

@description('Voice Live model after availability and private-path verification.')
param voiceModel string

@description('UTC creation time bound to the run manifest.')
param createdAt string

@description('UTC teardown deadline. A tag is not an automatic cleanup executor.')
param expiresAt string

var ownership = {
  managedBy: 'AzureIQ'
  lifecycle: 'ephemeral'
  caseStudy: 'HarborITServices'
  environmentId: environmentName
  createdAt: createdAt
  expiresAt: expiresAt
}

resource lab 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: ownership
}

module ecosystem './ecosystem.bicep' = {
  name: 'harbor-${environmentName}'
  scope: lab
  params: {
    environmentName: environmentName
    location: location
    publisherEmail: publisherEmail
    applicationImage: applicationImage
    entra: entra
    apiCenterReader: apiCenterReader
    actionGroupResourceId: actionGroupResourceId
    supportOpenApi: supportOpenApi
    supportTools: supportTools
    chatModel: chatModel
    voiceModel: voiceModel
    tags: ownership
  }
}

output APPLICATION_URL string = ecosystem.outputs.applicationUrl
output API_MANAGEMENT_NAME string = ecosystem.outputs.apiManagementName
output API_CENTER_NAME string = ecosystem.outputs.apiCenterName
output API_CENTER_MCP_ENDPOINT string = ecosystem.outputs.apiCenterMcpEndpoint
output CONTAINER_REGISTRY_NAME string = ecosystem.outputs.containerRegistryName
output SEED_JOB_NAME string = ecosystem.outputs.seedJobName
output EXPECTED_RESOURCE_IDS array = concat([lab.id], ecosystem.outputs.expectedResourceIds)
output LIVE_GATES array = [
  'Exact private subscription/tenant/principal and least-privilege rights verified'
  'Application image digest and generated OpenAPI match the approved source'
  'Entra public-client/API registration and managed-identity app role approved'
  'API Center Standard linked benefit and native portal/MCP activation verified'
  'Synthetic Search seed job separately approved and completed'
  'Model, Voice Live, network and telemetry ingestion verified independently'
  'Full cost forecast and billed-lab window within $400/month and 200 hours'
]
