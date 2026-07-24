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

var resourceSuffix = take(uniqueString(subscription().id, resourceGroup().id, name, location), 8)
var appServicePlanName = 'asp-wf-${resourceSuffix}'
var appServiceName = 'app-wf-${resourceSuffix}'
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

module appServicePlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'app-service-plan'
  params: {
    name: appServicePlanName
    location: location
    kind: 'linux'
    reserved: true
    skuCapacity: 1
    skuName: 'B1'
    tags: tags
    zoneRedundant: false
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalytics.outputs.resourceId
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
      }
    ]
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
        serviceUrl: 'https://${appServiceName}.azurewebsites.net'
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

module appService 'br/public:avm/res/web/site:0.24.0' = {
  name: 'app-service'
  params: {
    name: appServiceName
    location: location
    kind: 'app,linux'
    serverFarmResourceId: appServicePlan.outputs.resourceId
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      systemAssigned: true
    }
    basicPublishingCredentialsPolicies: [
      {
        name: 'ftp'
        allow: false
      }
      {
        name: 'scm'
        allow: false
      }
    ]
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      healthCheckPath: '/health/ready'
      http20Enabled: true
      linuxFxVersion: 'DOTNETCORE|10.0'
      minTlsVersion: '1.2'
      remoteDebuggingEnabled: false
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: [
        {
          name: 'Allow-APIM'
          description: 'Allow only the exclusive public IP of this APIM instance.'
          action: 'Allow'
          ipAddress: '${deployedApiManagement.properties.publicIPAddresses[0]}/32'
          priority: 100
        }
      ]
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Allow'
      appSettings: [
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.outputs.connectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'recommended'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_PreemptSdk'
          value: '1'
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
          name: 'WEBSITE_HEALTHCHECK_MAXPINGFAILURES'
          value: '3'
        }
      ]
    }
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
    tags: union(tags, {
      'azd-service-name': 'api'
    })
  }
  dependsOn: [
    apiManagement
  ]
}

module appTelemetryPublisher './application-insights-publisher-role.bicep' = {
  name: 'app-telemetry-publisher'
  params: {
    name: appServiceName
    location: location
    tags: tags
    applicationInsightsName: applicationInsightsName
    principalId: appService.outputs.systemAssignedMIPrincipalId!
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

module appHealthAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-app-health'
  params: {
    name: 'alert-wf-app-health-${resourceSuffix}'
    alertDescription: 'Waypoint Freight App Service health check is reporting an unhealthy instance.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: 'HealthCheckStatus'
          metricNamespace: 'Microsoft.Web/sites'
          name: 'AppHealthCheckUnhealthy'
          operator: 'LessThan'
          threshold: 1
          timeAggregation: 'Average'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT5M'
    scopes: [
      appService.outputs.resourceId
    ]
    severity: 1
    tags: tags
    windowSize: 'PT15M'
  }
}

module appServerErrorAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-app-server-errors'
  params: {
    name: 'alert-wf-app-5xx-${resourceSuffix}'
    alertDescription: 'Waypoint Freight App Service returned one or more HTTP 5xx responses.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: 'Http5xx'
          metricNamespace: 'Microsoft.Web/sites'
          name: 'AppHttp5xx'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT1M'
    scopes: [
      appService.outputs.resourceId
    ]
    severity: 1
    tags: tags
    windowSize: 'PT5M'
  }
}

module appLatencyAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: 'alert-app-latency'
  params: {
    name: 'alert-wf-app-latency-${resourceSuffix}'
    alertDescription: 'Waypoint Freight App Service average response time exceeded two seconds.'
    criteria: {
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          dimensions: []
          metricName: 'HttpResponseTime'
          metricNamespace: 'Microsoft.Web/sites'
          name: 'AppResponseTime'
          operator: 'GreaterThan'
          threshold: 2
          timeAggregation: 'Average'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    evaluationFrequency: 'PT1M'
    scopes: [
      appService.outputs.resourceId
    ]
    severity: 2
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
    alertDescription: 'No App Service application telemetry reached the workspace during the last 15 minutes.'
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

output appServiceName string = appService.outputs.name
output appServiceUrl string = 'https://${appService.outputs.defaultHostname}'
output apiManagementName string = apiManagement.outputs.name
output gatewayApiUrl string = 'https://${apiManagement.outputs.name}.azure-api.net/waypoint'
output applicationInsightsName string = applicationInsights.outputs.name
output logAnalyticsResourceId string = logAnalytics.outputs.resourceId
output expectedResourceIds array = [
  logAnalytics.outputs.resourceId
  applicationInsights.outputs.resourceId
  appServicePlan.outputs.resourceId
  apiManagement.outputs.resourceId
  appService.outputs.resourceId
  appHealthAlert.outputs.resourceId
  appServerErrorAlert.outputs.resourceId
  appLatencyAlert.outputs.resourceId
  apiManagementServerErrorAlert.outputs.resourceId
  apiManagementLatencyAlert.outputs.resourceId
  telemetryAbsenceAlert.outputs.resourceId
  resourceHealthAlert.outputs.resourceId
  appTelemetryPublisher.outputs.resourceId
  apiManagementTelemetryPublisher.outputs.resourceId
]