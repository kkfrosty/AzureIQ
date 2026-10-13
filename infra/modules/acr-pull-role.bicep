targetScope = 'resourceGroup'

metadata description = 'Assigns AcrPull to one managed identity at one container registry.'

@description('Workload name used in the role assignment description.')
param name string

@description('Azure region of the workload and registry.')
param location string = resourceGroup().location

@description('Ownership tags used to describe the managed assignment.')
param tags object = {}

@description('Name of the target container registry.')
param containerRegistryName string

@description('Object ID of the system- or user-assigned managed identity.')
param principalId string

var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var managedBy = tags.?managedBy ?? 'declarative infrastructure'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, principalId, acrPullRoleDefinitionId)
  scope: containerRegistry
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
    description: 'Allow ${name} in ${location} to pull images only from this registry; managed by ${managedBy}.'
  }
}

output resourceId string = acrPull.id
