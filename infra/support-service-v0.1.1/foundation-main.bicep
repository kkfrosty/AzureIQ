targetScope = 'subscription'

metadata description = 'Candidate stage-one Harbor foundation, including an owned registry before building the immutable application image.'

@minLength(3)
@maxLength(20)
param environmentName string
param resourceGroupName string
param location string
param createdAt string
param expiresAt string
param chatModel object

var tags = {
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
  tags: tags
}

module foundation './foundation.bicep' = {
  name: 'harbor-foundation'
  scope: lab
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    chatModel: chatModel
  }
}

output CONTAINER_REGISTRY_NAME string = foundation.outputs.registryName
output BACKEND_PRINCIPAL_ID string = foundation.outputs.backendPrincipalId
output EXPECTED_RESOURCE_IDS array = concat([lab.id], foundation.outputs.resourceIds)
