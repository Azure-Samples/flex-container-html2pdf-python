targetScope = 'resourceGroup'

@description('Azure Developer CLI environment name used for resource tags.')
param environmentName string
param functionAppName string
param functionLocation string
param appServicePlanId string
param applicationInsightsConnectionString string
param registryImage string
param registryUsername string

@secure()
param storageConnectionString string

@secure()
param registryPassword string

var tags = {
  'azd-env-name': environmentName
  'azd-service-name': 'api'
}

resource functionApp 'Microsoft.Web/sites@2026-08-01' = {
  name: functionAppName
  location: functionLocation
  tags: tags
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'Registry'
          value: registryImage
          authentication: {
            type: 'Basic'
            usernameSettingName: 'FLEX_CONTAINER_REGISTRY_USERNAME'
            passwordSettingName: 'FLEX_CONTAINER_REGISTRY_PASSWORD'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 2
      }
      siteUpdateStrategy: {
        type: 'Recreate'
      }
    }
    siteConfig: {
      alwaysOn: false
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      remoteDebuggingEnabled: false
      scmMinTlsVersion: '1.2'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'FLEX_CONTAINER_REGISTRY_PASSWORD'
          value: registryPassword
        }
        {
          name: 'FLEX_CONTAINER_REGISTRY_USERNAME'
          value: registryUsername
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
      ]
    }
  }
}

output API_URL string = 'https://${functionApp.properties.defaultHostName}'
output FUNCTION_APP_NAME string = functionApp.name
