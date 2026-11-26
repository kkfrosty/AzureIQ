targetScope = 'subscription'

metadata description = 'Candidate Harbor recovery preserving existing subnet NSG attachments. Not approved for deployment.'

@minLength(3)
@maxLength(20)
param environmentName string
param location string
param resourceGroupName string
param publisherEmail string
@minLength(20)
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
param createdAt string
param expiresAt string

@description('Exact existing NSG currently attached to the owned Container Apps subnet; verify the binding before deployment.')
@minLength(20)
param containerAppsSubnetNetworkSecurityGroupId string

@description('Exact existing NSG currently attached to the owned private-endpoint subnet; verify the binding before deployment.')
@minLength(20)
param privateEndpointsSubnetNetworkSecurityGroupId string

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
    containerAppsSubnetNetworkSecurityGroupId: containerAppsSubnetNetworkSecurityGroupId
    privateEndpointsSubnetNetworkSecurityGroupId: privateEndpointsSubnetNetworkSecurityGroupId
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
