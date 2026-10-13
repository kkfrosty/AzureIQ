targetScope = 'resourceGroup'

metadata description = 'AI Foundry account, model deployments, and an API Management AI gateway with managed-identity authentication.'

@description('Environment name used to derive stable globally unique resource names.')
param name string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('API Management publisher email.')
param publisherEmail string

@description('API Management publisher display name.')
param publisherName string = 'AzureIQ AI Platform'

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

@description('Ownership and lifecycle tags inherited from the environment boundary.')
param tags object = {}

var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, name, location), 8)
var aiFoundryName = 'aif-${resourceSuffix}'
var aiFoundryProjectName = 'proj-${resourceSuffix}'
var apiManagementName = 'apim-ai-${resourceSuffix}'
var logAnalyticsName = 'log-ai-${resourceSuffix}'
var applicationInsightsName = 'appi-ai-${resourceSuffix}'
var apiManagementLoggerName = 'applicationinsights'
var apiName = 'ai-chat'
var productName = 'ai-chat-console'
var chatOpenApiDocument = loadJsonContent('../api/ai-chat-openapi.json')
var chatApiPolicy = loadTextContent('../api/ai-gateway-policy.xml')
var aiFoundryDataPlaneUrl = 'https://${aiFoundryName}.openai.azure.com/openai'

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.0' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    dataRetention: 30
    dailyQuotaGb: '1'
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
      immediatePurgeDataOn30Days: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    skuName: 'PerGB2018'
    tags: tags
  }
}

module applicationInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'application-insights'
  params: {
    name: applicationInsightsName
    workspaceResourceId: logAnalytics.outputs.resourceId
    applicationType: 'web'
    disableIpMasking: false
    disableLocalAuth: true
    immediatePurgeDataOn30Days: true
    location: location
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
    samplingPercentage: 100
    tags: tags
  }
}

module aiFoundry 'br/public:avm/res/cognitive-services/account:0.16.0' = {
  name: 'ai-foundry-account'
  params: {
    name: aiFoundryName
    location: location
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: aiFoundryName
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      systemAssigned: true
    }
    deployments: modelDeployments
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalytics.outputs.resourceId
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
      }
    ]
    tags: tags
  }
}

resource deployedAiFoundry 'Microsoft.CognitiveServices/accounts@2026-05-01' existing = {
  name: aiFoundryName
}

resource aiFoundryProject 'Microsoft.CognitiveServices/accounts/projects@2026-05-01' = {
  parent: deployedAiFoundry
  name: aiFoundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'AzureIQ AI Chat'
    description: 'Disposable Foundry project for the AzureIQ AI gateway case study.'
  }
  dependsOn: [
    aiFoundry
  ]
}

module apiManagement 'br/public:avm/res/api-management/service:0.14.4' = {
  name: 'api-management'
  params: {
    name: apiManagementName
    publisherEmail: publisherEmail
    publisherName: publisherName
    location: location
    sku: apiManagementSku
    enableDeveloperPortal: false
    managedIdentities: {
      systemAssigned: true
    }
    publicNetworkAccess: 'Enabled'
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalytics.outputs.resourceId
        logAnalyticsDestinationType: 'Dedicated'
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
      }
    ]
    loggers: [
      {
        name: apiManagementLoggerName
        type: 'applicationInsights'
        credentials: {
          connectionString: applicationInsights.outputs.connectionString
          identityClientId: 'systemAssigned'
        }
        description: 'Workspace-based Application Insights logger using APIM managed identity'
        isBuffered: true
        targetResourceId: applicationInsights.outputs.resourceId
      }
    ]
    serviceDiagnostics: [
      {
        name: 'applicationinsights'
        loggerResourceId: resourceId('Microsoft.ApiManagement/service/loggers', apiManagementName, apiManagementLoggerName)
        alwaysLog: 'allErrors'
        httpCorrelationProtocol: 'W3C'
        logClientIp: false
        metrics: true
        operationNameFormat: 'Name'
        samplingPercentage: 100
        verbosity: 'information'
      }
    ]
    apis: [
      {
        name: apiName
        displayName: 'AI Foundry Chat Gateway'
        description: 'Protected chat completions surface for AI Foundry model deployments.'
        path: 'ai'
        protocols: [
          'https'
        ]
        serviceUrl: aiFoundryDataPlaneUrl
        subscriptionRequired: true
        type: 'http'
        format: 'openapi+json'
        value: string(chatOpenApiDocument)
        policies: [
          {
            format: 'rawxml'
            value: chatApiPolicy
          }
        ]
        diagnostics: [
          {
            name: 'applicationinsights'
            loggerName: apiManagementLoggerName
            alwaysLog: 'allErrors'
            httpCorrelationProtocol: 'W3C'
            logClientIp: false
            metrics: true
            operationNameFormat: 'Name'
            samplingPercentage: 100
            verbosity: 'information'
          }
        ]
      }
    ]
    products: [
      {
        name: productName
        displayName: 'AI Chat Console'
        description: 'Protected product for the local AI chat client.'
        apis: [
          apiName
        ]
        groups: [
          'developers'
        ]
        state: 'published'
        subscriptionRequired: true
      }
    ]
    subscriptions: [
      {
        name: 'ai-local-client'
        displayName: 'AI local client'
        allowTracing: false
        scope: '/products/${productName}'
        state: 'active'
      }
    ]
    tags: tags
  }
}

module gatewayModelAccess './cognitive-services-user-role.bicep' = {
  name: 'gateway-model-access'
  params: {
    name: apiManagementName
    location: location
    tags: tags
    aiFoundryAccountName: aiFoundryName
    principalId: apiManagement.outputs.systemAssignedMIPrincipalId!
  }
  dependsOn: [
    aiFoundry
  ]
}

module gatewayServerErrorAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-gateway-server-errors'
  params: {
    name: 'alert-ai-gateway-5xx-${resourceSuffix}'
    alertDescription: 'The AI gateway returned one or more HTTP 5xx responses.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'GatewayResponseCodeCategory'
              operator: 'Include'
              values: [
                '5xx'
              ]
            }
          ]
          metricName: 'Requests'
          metricNamespace: 'Microsoft.ApiManagement/service'
          name: 'GatewayHttp5xx'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT1M'
    scopes: [
      apiManagement.outputs.resourceId
    ]
    severity: 1
    tags: tags
    windowSize: 'PT5M'
  }
}

module gatewayThrottleAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-gateway-throttling'
  params: {
    name: 'alert-ai-gateway-429-${resourceSuffix}'
    alertDescription: 'The AI gateway rejected one or more requests with HTTP 429, indicating a rate or token limit was reached.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: [
            {
              name: 'GatewayResponseCodeCategory'
              operator: 'Include'
              values: [
                '4xx'
              ]
            }
          ]
          metricName: 'Requests'
          metricNamespace: 'Microsoft.ApiManagement/service'
          name: 'GatewayThrottled'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT5M'
    scopes: [
      apiManagement.outputs.resourceId
    ]
    severity: 3
    tags: tags
    windowSize: 'PT15M'
  }
}

output aiFoundryName string = aiFoundry.outputs.name
output aiFoundryProjectName string = aiFoundryProject.name
output aiFoundryEndpoint string = aiFoundryDataPlaneUrl
output apiManagementName string = apiManagement.outputs.name
output chatGatewayUrl string = 'https://${apiManagement.outputs.name}.azure-api.net/ai'
output applicationInsightsName string = applicationInsights.outputs.name
output logAnalyticsResourceId string = logAnalytics.outputs.resourceId
output modelDeploymentNames array = [for deployment in modelDeployments: deployment.name]
output expectedResourceIds array = [
  logAnalytics.outputs.resourceId
  applicationInsights.outputs.resourceId
  aiFoundry.outputs.resourceId
  aiFoundryProject.id
  apiManagement.outputs.resourceId
  gatewayModelAccess.outputs.resourceId
  gatewayServerErrorAlert.outputs.resourceId
  gatewayThrottleAlert.outputs.resourceId
]
