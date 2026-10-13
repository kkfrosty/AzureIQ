targetScope = 'resourceGroup'

metadata description = 'Assigns Cognitive Services OpenAI User to one managed identity at one AI Foundry account.'

@description('Workload name used in the role assignment description.')
param name string

@description('Azure region of the workload and account.')
param location string = resourceGroup().location

@description('Ownership tags used to describe the managed assignment.')
param tags object = {}

@description('Name of the target AI Foundry (Cognitive Services) account.')
param aiFoundryAccountName string

@description('Object ID of the system- or user-assigned managed identity.')
param principalId string

var openAiUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
var managedBy = tags.?managedBy ?? 'declarative infrastructure'

resource aiFoundryAccount 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: aiFoundryAccountName
}

resource openAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiFoundryAccount.id, principalId, openAiUserRoleDefinitionId)
  scope: aiFoundryAccount
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: openAiUserRoleDefinitionId
    description: 'Allow ${name} in ${location} to call model inference only on this account; managed by ${managedBy}.'
  }
}

output resourceId string = openAiUser.id
