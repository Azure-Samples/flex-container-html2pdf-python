targetScope = 'resourceGroup'

@minLength(1)
@maxLength(32)
param name string

param location string = resourceGroup().location
param functionLocation string
param tags object = {}

var abbrs = loadJsonContent('../abbreviations.json')
var resourceToken = take(toLower(uniqueString(subscription().id, resourceGroup().id, name, location)), 10)
var compactName = take(replace(replace(toLower(name), '-', ''), '_', ''), 10)
var storageAccountName = '${abbrs.storageStorageAccounts}${compactName}${resourceToken}'
var containerRegistryName = '${abbrs.containerRegistryRegistries}${compactName}${resourceToken}'
var logAnalyticsName = '${abbrs.operationalInsightsWorkspaces}${take(name, 20)}-${take(resourceToken, 6)}'
var applicationInsightsName = '${abbrs.insightsComponents}${take(name, 18)}-${take(resourceToken, 6)}'
var appServicePlanName = '${abbrs.webServerFarms}${take(name, 18)}-${take(resourceToken, 6)}'
var functionAppName = '${abbrs.webSitesFunctions}${take(name, 20)}-${take(resourceToken, 8)}'
var imageRepository = 'flex-container-html2pdf-python'
var scopeMapName = 'pull-${take(resourceToken, 10)}-ro'
var tokenName = 'pull-${take(resourceToken, 10)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    DisableLocalAuth: false
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    dataEndpointEnabled: false
    encryption: {
      status: 'disabled'
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource scopeMap 'Microsoft.ContainerRegistry/registries/scopeMaps@2025-04-01' = {
  parent: containerRegistry
  name: scopeMapName
  properties: {
    actions: [
      'repositories/${imageRepository}/content/read'
      'repositories/${imageRepository}/metadata/read'
    ]
    description: 'Read-only pull access for the Flex Consumption Function App.'
  }
}

resource pullToken 'Microsoft.ContainerRegistry/registries/tokens@2025-04-01' = {
  parent: containerRegistry
  name: tokenName
  properties: {
    scopeMapId: scopeMap.id
    status: 'enabled'
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2026-08-01' = {
  name: appServicePlanName
  location: functionLocation
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    maximumElasticWorkerCount: 2
    reserved: true
  }
}

output containerRegistryName string = containerRegistry.name
output containerRegistryEndpoint string = containerRegistry.properties.loginServer
output imageRepository string = imageRepository
output scopeMapName string = scopeMap.name
output tokenName string = pullToken.name
output functionAppName string = functionAppName
output functionAppId string = resourceId('Microsoft.Web/sites', functionAppName)
output appServicePlanId string = appServicePlan.id
output storageAccountName string = storageAccount.name
output applicationInsightsName string = applicationInsights.name
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
