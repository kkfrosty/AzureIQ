targetScope = 'resourceGroup'

metadata description = 'Harbor recovery foundation preserving verified existing subnet NSG attachments.'

param environmentName string
param location string = resourceGroup().location
param tags object
param chatModel object
param containerAppsSubnetNetworkSecurityGroupId string
param privateEndpointsSubnetNetworkSecurityGroupId string

var suffix = take(uniqueString(resourceGroup().id, environmentName), 8)
var names = {
  network: 'vnet-hi-${suffix}'
  workspace: 'log-hi-${suffix}'
  insights: 'appi-hi-${suffix}'
  registry: 'acrhi${suffix}'
  storage: 'sthi${suffix}'
  search: 'srch-hi-${suffix}'
  foundry: 'aif-hi-${suffix}'
  containerEnvironment: 'cae-hi-${suffix}'
  backendIdentity: 'id-hi-web-${suffix}'
  seedIdentity: 'id-hi-seed-${suffix}'
}

resource backendIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.backendIdentity
  location: location
  tags: tags
}

resource seedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.seedIdentity
  location: location
  tags: tags
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-hi-apim-${suffix}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-KeyVault-Dependency'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Private-Backends'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-Entra'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: names.network
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.84.0.0/16']
    }
    subnets: [
      {
        name: 'apim-outbound'
        properties: {
          addressPrefix: '10.84.0.0/24'
          networkSecurityGroup: { id: apimNsg.id }
          delegations: [
            {
              name: 'apim-standard-v2'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
      {
        name: 'container-apps'
        properties: {
          addressPrefix: '10.84.2.0/23'
          networkSecurityGroup: { id: containerAppsSubnetNetworkSecurityGroupId }
          delegations: [
            {
              name: 'container-environment'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.84.4.0/24'
          networkSecurityGroup: { id: privateEndpointsSubnetNetworkSecurityGroupId }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.workspace
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.05') }
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: names.insights
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    DisableIpMasking: false
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 30
    SamplingPercentage: 100
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: names.registry
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: names.storage
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource tables 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource cases 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tables
  name: 'HarborCases'
}

resource proposals 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tables
  name: 'HarborUsage'
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: names.search
  location: location
  tags: tags
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
    semanticSearch: 'disabled'
    networkRuleSet: { bypass: 'None' }
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2026-05-01' = {
  name: names.foundry
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: names.foundry
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny' }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = {
  parent: foundry
  name: 'harbor-support'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  // Cognitive Services serializes account-affecting child operations.
  dependsOn: [deployment]
  properties: {
    displayName: 'Harbor IT Services'
    description: 'Synthetic company support and voice learning project.'
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2026-05-01' = {
  parent: foundry
  name: chatModel.deploymentName
  sku: {
    name: chatModel.sku
    capacity: chatModel.capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModel.name
      version: chatModel.version
    }
  }
}

module tableEndpoint '../support-service/private-endpoint.bicep' = {
  name: 'private-tables'
  params: {
    name: 'pe-hi-table-${suffix}'
    location: location
    subnetResourceId: '${network.id}/subnets/private-endpoints'
    targetResourceId: storage.id
    groupId: 'table'
    virtualNetworkResourceId: network.id
    dnsZoneNames: ['privatelink.table.${environment().suffixes.storage}']
    tags: tags
  }
}

module searchEndpoint '../support-service/private-endpoint.bicep' = {
  name: 'private-search'
  params: {
    name: 'pe-hi-search-${suffix}'
    location: location
    subnetResourceId: '${network.id}/subnets/private-endpoints'
    targetResourceId: search.id
    groupId: 'searchService'
    virtualNetworkResourceId: network.id
    dnsZoneNames: ['privatelink.search.windows.net']
    tags: tags
  }
}

module foundryEndpoint '../support-service/private-endpoint.bicep' = {
  name: 'private-foundry'
  dependsOn: [project]
  params: {
    name: 'pe-hi-foundry-${suffix}'
    location: location
    subnetResourceId: '${network.id}/subnets/private-endpoints'
    targetResourceId: foundry.id
    groupId: 'account'
    virtualNetworkResourceId: network.id
    dnsZoneNames: [
      'privatelink.cognitiveservices.azure.com'
      'privatelink.openai.azure.com'
      'privatelink.services.ai.azure.com'
    ]
    tags: tags
  }
}

var pullIdentities = [backendIdentity.id, seedIdentity.id]
var pullPrincipals = [backendIdentity.properties.principalId, seedIdentity.properties.principalId]
resource registryPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (identityId, index) in pullIdentities: {
    name: guid(registry.id, identityId, 'AcrPull')
    scope: registry
    properties: {
      principalId: pullPrincipals[index]
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    }
  }
]

resource tableWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, backendIdentity.id, 'TableDataContributor')
  scope: storage
  properties: {
    principalId: backendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

resource seedTableWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, seedIdentity.id, 'TableDataContributor')
  scope: storage
  properties: {
    principalId: seedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

resource searchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, backendIdentity.id, 'SearchIndexDataReader')
  scope: search
  properties: {
    principalId: backendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
  }
}

resource searchSeedRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in ['7ca78c08-252a-4471-8644-bb5ff32d4ba0', '8ebe5a00-799e-43f5-93ac-243d3dce84a7']: {
    name: guid(search.id, seedIdentity.id, roleId)
    scope: search
    properties: {
      principalId: seedIdentity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

resource voiceRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in ['a97b65f3-24c7-4388-baec-2e87135dc908', '53ca6127-db72-4b80-b1b0-d745d6d5456d']: {
    name: guid(foundry.id, backendIdentity.id, roleId)
    scope: foundry
    properties: {
      principalId: backendIdentity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

resource insightsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, backendIdentity.id, 'MetricsPublisher')
  scope: insights
  properties: {
    principalId: backendIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

resource containerEnvironment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: names.containerEnvironment
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Disabled'
    vnetConfiguration: {
      infrastructureSubnetId: '${network.id}/subnets/container-apps'
      internal: true
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    appLogsConfiguration: { destination: 'azure-monitor' }
    zoneRedundant: false
  }
}

module appDns '../support-service/container-dns.bicep' = {
  name: 'container-dns'
  params: {
    domain: containerEnvironment.properties.defaultDomain
    address: containerEnvironment.properties.staticIp
    networkId: network.id
    tags: tags
  }
}

resource environmentDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'harbor-environment'
  scope: containerEnvironment
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'ContainerAppConsoleLogs', enabled: true }
      { category: 'ContainerAppSystemLogs', enabled: true }
    ]
  }
}

output suffix string = suffix
output networkId string = network.id
output apimSubnetId string = '${network.id}/subnets/apim-outbound'
output environmentId string = containerEnvironment.id
output environmentDomain string = containerEnvironment.properties.defaultDomain
output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output backendIdentityId string = backendIdentity.id
output backendPrincipalId string = backendIdentity.properties.principalId
output backendClientId string = backendIdentity.properties.clientId
output seedIdentityId string = seedIdentity.id
output seedClientId string = seedIdentity.properties.clientId
output storageServiceUri string = 'https://${storage.name}.table.${environment().suffixes.storage}'
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchName string = search.name
output foundryName string = foundry.name
output foundryId string = foundry.id
output foundryEndpoint string = 'https://${foundry.name}.openai.azure.com'
output voiceEndpoint string = 'https://${foundry.name}.services.ai.azure.com/voice-live/realtime'
output insightsId string = insights.id
@secure()
output insightsConnectionString string = insights.properties.ConnectionString
output workspaceId string = workspace.id
var pullRoleIds = [for (identityId, index) in pullIdentities: registryPull[index].id]
var seedRoleIds = [for (roleId, index) in ['7ca78c08-252a-4471-8644-bb5ff32d4ba0', '8ebe5a00-799e-43f5-93ac-243d3dce84a7']: searchSeedRoles[index].id]
var voiceRoleIds = [for (roleId, index) in ['a97b65f3-24c7-4388-baec-2e87135dc908', '53ca6127-db72-4b80-b1b0-d745d6d5456d']: voiceRoles[index].id]
output resourceIds array = concat([
  backendIdentity.id
  seedIdentity.id
  apimNsg.id
  network.id
  workspace.id
  insights.id
  registry.id
  storage.id
  tables.id
  cases.id
  proposals.id
  search.id
  foundry.id
  project.id
  deployment.id
  tableWriter.id
  seedTableWriter.id
  searchReader.id
  insightsPublisher.id
  containerEnvironment.id
  environmentDiagnostics.id
], pullRoleIds, seedRoleIds, voiceRoleIds, appDns.outputs.resourceIds,
  tableEndpoint.outputs.resourceIds, searchEndpoint.outputs.resourceIds, foundryEndpoint.outputs.resourceIds)
