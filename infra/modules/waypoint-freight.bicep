targetScope = 'resourceGroup'

metadata description = 'Waypoint Freight baseline resources composed from pinned Azure Verified Modules.'

@description('Environment name used to derive stable globally unique resource names.')
param name string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('API Management publisher email.')
param publisherEmail string

@description('Ownership and lifecycle tags inherited from the environment boundary.')
param tags object = {}

@description('Container image for the API. The public placeholder is replaced by the built application image during deployment.')
param apiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Enable the protected diagnostic scenario endpoints on this disposable backend.')
param enableTestScenarios bool = true

var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, name, location), 8)
var containerRegistryName = 'acrwf${resourceSuffix}'
var managedEnvironmentName = 'cae-wf-${resourceSuffix}'
var containerAppName = 'ca-wf-${resourceSuffix}'
var apiManagementName = 'apim-wf-${resourceSuffix}'
var logAnalyticsName = 'log-wf-${resourceSuffix}'
var applicationInsightsName = 'appi-wf-${resourceSuffix}'
var apiManagementLoggerName = 'applicationinsights'
var apiName = 'waypoint-freight'
var productName = 'waypoint-console'
var telemetryAbsenceQuery = '''
union isfuzzy=true
  (datatable(TimeGenerated:datetime, TelemetrySource:string)[]),
  (AppRequests | project TimeGenerated, TelemetrySource = 'request'),
  (AppDependencies | project TimeGenerated, TelemetrySource = 'dependency'),
  (AppExceptions | project TimeGenerated, TelemetrySource = 'exception'),
  (AppTraces | project TimeGenerated, TelemetrySource = 'trace')
| where TimeGenerated >= ago(15m)
| summarize TelemetryCount = count()
'''
var backendServerErrorQuery = replace('''
AppRequests
| where TimeGenerated >= ago(5m)
| where AppRoleName =~ '__CONTAINER_APP__'
| where ResultCode startswith '5'
| summarize ServerErrors = count()
''', '__CONTAINER_APP__', containerAppName)
var openApiDocument = union(
  loadJsonContent('../../case-study/WaypointFreight/backend/WaypointFreight.Api/openapi/waypoint-freight-openapi.json'),
  {
    openapi: '3.0.3'
  }
)
var apiPolicy = loadTextContent('../apim/waypoint-freight-policy.xml')

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.0' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    dataRetention: 30
    dailyQuotaGb: '1'
    features: {
      // The Container Apps environment log agent authenticates with the workspace shared key.
      disableLocalAuth: false
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

module containerRegistry 'br/public:avm/res/container-registry/registry:0.12.1' = {
  name: 'container-registry'
  params: {
    name: containerRegistryName
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled'
    tags: tags
  }
}

module managedEnvironment 'br/public:avm/res/app/managed-environment:0.14.0' = {
  name: 'container-apps-environment'
  params: {
    name: managedEnvironmentName
    location: location
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    }
    zoneRedundant: false
    tags: tags
  }
}

module apiManagement 'br/public:avm/res/api-management/service:0.14.4' = {
  name: 'api-management'
  params: {
    name: apiManagementName
    publisherEmail: publisherEmail
    publisherName: 'Waypoint Freight'
    location: location
    sku: 'Developer'
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
        displayName: 'Waypoint Freight Shipment API'
        description: 'Synthetic shipment tracking API for AzureIQ operational validation.'
        path: 'waypoint'
        protocols: [
          'https'
        ]
        serviceUrl: 'https://${containerAppName}.${managedEnvironment.outputs.defaultDomain}'
        subscriptionRequired: true
        type: 'http'
        format: 'openapi+json'
        value: string(openApiDocument)
        policies: [
          {
            format: 'rawxml'
            value: apiPolicy
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
        displayName: 'Waypoint Shipment Console'
        description: 'Protected product for the local Waypoint Freight client.'
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
        name: 'waypoint-local-client'
        displayName: 'Waypoint local client'
        allowTracing: false
        scope: '/products/${productName}'
        state: 'active'
      }
    ]
    tags: tags
  }
}

resource deployedApiManagement 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

module containerApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'container-app'
  params: {
    name: containerAppName
    location: location
    environmentResourceId: managedEnvironment.outputs.resourceId
    managedIdentities: {
      systemAssigned: true
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: 'system'
      }
    ]
    ingressExternal: true
    ingressTargetPort: 8080
    ingressAllowInsecure: false
    ipSecurityRestrictions: [
      {
        name: 'Allow-APIM'
        description: 'Allow only the exclusive public IP of this API Management instance.'
        action: 'Allow'
        ipAddressRange: '${deployedApiManagement.properties.publicIPAddresses[0]}/32'
      }
    ]
    activeRevisionsMode: 'Single'
    scaleSettings: {
      minReplicas: 0
      maxReplicas: 10
    }
    containers: [
      {
        name: 'api'
        image: apiImage
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: 'Production'
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: applicationInsights.outputs.connectionString
          }
          {
            name: 'Cors__AllowedOrigins__0'
            value: 'http://localhost:5265'
          }
          {
            name: 'Cors__AllowedOrigins__1'
            value: 'http://127.0.0.1:5265'
          }
          {
            name: 'TestScenarios__Enabled'
            value: string(enableTestScenarios)
          }
          {
            name: 'TestScenarios__TimeoutDelayMilliseconds'
            value: '1500'
          }
          {
            name: 'TestScenarios__SlowDelayMilliseconds'
            value: '2500'
          }
        ]
        probes: [
          {
            type: 'Readiness'
            httpGet: {
              path: '/health/ready'
              port: 8080
            }
            initialDelaySeconds: 5
            periodSeconds: 10
          }
        ]
      }
    ]
    tags: union(tags, {
      'azd-service-name': 'api'
    })
  }
  dependsOn: [
    apiManagement
  ]
}

module containerAppRegistryPull './acr-pull-role.bicep' = {
  name: 'container-app-acr-pull'
  params: {
    name: containerAppName
    location: location
    tags: tags
    containerRegistryName: containerRegistryName
    principalId: containerApp.outputs.systemAssignedMIPrincipalId!
  }
}

module appTelemetryPublisher './application-insights-publisher-role.bicep' = {
  name: 'app-telemetry-publisher'
  params: {
    name: containerAppName
    location: location
    tags: tags
    applicationInsightsName: applicationInsightsName
    principalId: containerApp.outputs.systemAssignedMIPrincipalId!
  }
}

module apiManagementTelemetryPublisher './application-insights-publisher-role.bicep' = {
  name: 'apim-telemetry-publisher'
  params: {
    name: apiManagementName
    location: location
    tags: tags
    applicationInsightsName: applicationInsightsName
    principalId: apiManagement.outputs.systemAssignedMIPrincipalId!
  }
}

module containerRestartAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-container-restarts'
  params: {
    name: 'alert-wf-container-restarts-${resourceSuffix}'
    alertDescription: 'Waypoint Freight Container App reported one or more container restarts.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: 'RestartCount'
          metricNamespace: 'Microsoft.App/containerApps'
          name: 'ContainerRestarts'
          operator: 'GreaterThan'
          skipMetricValidation: true
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT5M'
    scopes: [
      containerApp.outputs.resourceId
    ]
    severity: 2
    tags: tags
    windowSize: 'PT15M'
  }
}

module backendServerErrorAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: 'alert-backend-server-errors'
  params: {
    name: 'alert-wf-backend-5xx-${resourceSuffix}'
    alertDisplayName: 'Waypoint Freight backend returned server errors'
    alertDescription: 'The Waypoint Freight backend application recorded one or more HTTP 5xx responses.'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          dimensions: []
          metricMeasureColumn: 'ServerErrors'
          operator: 'GreaterThan'
          query: backendServerErrorQuery
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    evaluationFrequency: 'PT5M'
    queryTimeRange: 'PT5M'
    scopes: [
      logAnalytics.outputs.resourceId
    ]
    severity: 1
    skipQueryValidation: true
    tags: tags
    windowSize: 'PT5M'
  }
}

module apiManagementServerErrorAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-apim-server-errors'
  params: {
    name: 'alert-wf-apim-5xx-${resourceSuffix}'
    alertDescription: 'Waypoint Freight API Management gateway returned one or more HTTP 5xx responses.'
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

module apiManagementLatencyAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-apim-latency'
  params: {
    name: 'alert-wf-apim-latency-${resourceSuffix}'
    alertDescription: 'Waypoint Freight API Management average gateway duration exceeded two seconds.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: 'Duration'
          metricNamespace: 'Microsoft.ApiManagement/service'
          name: 'GatewayDuration'
          operator: 'GreaterThan'
          threshold: 2000
          timeAggregation: 'Average'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT1M'
    scopes: [
      apiManagement.outputs.resourceId
    ]
    severity: 2
    tags: tags
    windowSize: 'PT5M'
  }
}

module telemetryAbsenceAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: 'alert-telemetry-absence'
  params: {
    name: 'alert-wf-telemetry-absence-${resourceSuffix}'
    alertDisplayName: 'Waypoint Freight telemetry ingestion absent'
    alertDescription: 'No Waypoint Freight application telemetry reached the workspace during the last 15 minutes.'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          dimensions: []
          metricMeasureColumn: 'TelemetryCount'
          operator: 'LessThan'
          query: telemetryAbsenceQuery
          threshold: 1
          timeAggregation: 'Average'
        }
      ]
    }
    evaluationFrequency: 'PT5M'
    queryTimeRange: 'PT15M'
    scopes: [
      logAnalytics.outputs.resourceId
    ]
    severity: 1
    skipQueryValidation: true
    tags: tags
    windowSize: 'PT15M'
  }
}

module resourceHealthAlert 'br/public:avm/res/insights/activity-log-alert:0.4.2' = {
  name: 'alert-resource-health'
  params: {
    name: 'alert-wf-resource-health-${resourceSuffix}'
    alertDescription: 'A resource in the subscription reported an unavailable, degraded, or unknown health state.'
    conditions: [
      {
        field: 'category'
        equals: 'ResourceHealth'
      }
      {
        anyOf: [
          {
            field: 'properties.currentHealthStatus'
            equals: 'Unavailable'
          }
          {
            field: 'properties.currentHealthStatus'
            equals: 'Degraded'
          }
          {
            field: 'properties.currentHealthStatus'
            equals: 'Unknown'
          }
        ]
      }
    ]
    scopes: [
      subscription().id
    ]
    tags: tags
  }
}

output containerAppName string = containerApp.outputs.name
output containerAppUrl string = 'https://${containerApp.outputs.fqdn}'
output containerRegistryLoginServer string = containerRegistry.outputs.loginServer
output apiManagementName string = apiManagement.outputs.name
output gatewayApiUrl string = 'https://${apiManagement.outputs.name}.azure-api.net/waypoint'
output applicationInsightsName string = applicationInsights.outputs.name
output logAnalyticsResourceId string = logAnalytics.outputs.resourceId
output expectedResourceIds array = [
  logAnalytics.outputs.resourceId
  applicationInsights.outputs.resourceId
  containerRegistry.outputs.resourceId
  managedEnvironment.outputs.resourceId
  apiManagement.outputs.resourceId
  containerApp.outputs.resourceId
  containerRestartAlert.outputs.resourceId
  backendServerErrorAlert.outputs.resourceId
  apiManagementServerErrorAlert.outputs.resourceId
  apiManagementLatencyAlert.outputs.resourceId
  telemetryAbsenceAlert.outputs.resourceId
  resourceHealthAlert.outputs.resourceId
  containerAppRegistryPull.outputs.resourceId
  appTelemetryPublisher.outputs.resourceId
  apiManagementTelemetryPublisher.outputs.resourceId
]
