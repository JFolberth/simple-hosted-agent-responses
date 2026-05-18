targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention')
param environmentName string

@minLength(1)
@maxLength(90)
@description('Name of the resource group to use or create')
param resourceGroupName string = 'rg-${environmentName}'

@minLength(1)
@description('Primary location for all resources')
@allowed([
  'australiaeast'
  'brazilsouth'
  'canadacentral'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'norwayeast'
  'polandcentral'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'southindia'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'uaenorth'
  'uksouth'
  'westus'
  'westus2'
  'westus3'
])
param location string

param aiDeploymentsLocation string

@description('Name of the AI Foundry project')
param aiFoundryProjectName string = 'ai-project-${environmentName}'

@description('List of model deployments')
param deployments deploymentsType

// Tags applied to all resources
var tags = {
  'azd-env-name': environmentName
}

// Abbreviations for resource naming conventions
var abbrs = loadJsonContent('abbreviations.json')

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Deterministic token used for unique resource naming, scoped to this deployment
var resourceToken = uniqueString(subscription().id, rg.id, aiDeploymentsLocation)

// ─────────────────────────────────────────────────────────────────────────────
// Log Analytics Workspace
// Provides structured log storage for Application Insights. All telemetry from
// the AI project and hosted agents is retained here for querying and alerting.
// ─────────────────────────────────────────────────────────────────────────────
module logAnalytics 'modules/loganalytics.bicep' = {
  scope: rg
  name: 'logAnalytics'
  params: {
    location: aiDeploymentsLocation
    tags: tags
    name: 'logs-${resourceToken}'
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Application Insights
// Captures distributed traces, metrics, and exceptions from the hosted agent.
// Connected to the Log Analytics workspace above. The project MI is granted
// Log Analytics Reader so evaluations can run against agent traces.
// ─────────────────────────────────────────────────────────────────────────────
module applicationInsights 'modules/applicationinsights.bicep' = {
  scope: rg
  name: 'applicationInsights'
  params: {
    location: aiDeploymentsLocation
    tags: tags
    name: 'appi-${resourceToken}'
    logAnalyticsWorkspaceId: logAnalytics!.outputs.id
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Azure AI Foundry (AI Services Account)
// Provisions the Azure AI Services account and all model deployments. Also
// enables the account-level capability host when hosted agents are active,
// which provides the shared agent runtime infrastructure for all projects.
// ─────────────────────────────────────────────────────────────────────────────
module foundry 'modules/foundry.bicep' = {
  scope: rg
  name: 'foundry'
  params: {
    tags: tags
    location: aiDeploymentsLocation
    deployments: deployments
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AI Foundry Project
// Creates the Foundry project under the AI Services account and links it to
// Application Insights for trace collection. A single account can host
// multiple projects; this module manages exactly one.
// ─────────────────────────────────────────────────────────────────────────────
module foundryProject 'modules/foundry-project.bicep' = {
  scope: rg
  name: 'foundry-project'
  params: {
    tags: tags
    location: aiDeploymentsLocation
    aiFoundryProjectName: aiFoundryProjectName
    aiServicesAccountName: foundry.outputs.aiServicesAccountName
    appInsightsId: applicationInsights.outputs.id
    appInsightsConnectionString: applicationInsights.outputs.connectionString
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Azure Container Registry
// Stores Docker images built for the hosted agent. The Foundry project
// managed identity is granted AcrPull so the agent runtime can pull images.
// Registers the registry as a connection in the Foundry project.
// ─────────────────────────────────────────────────────────────────────────────
module acr 'modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: {
    location: aiDeploymentsLocation
    tags: tags
    resourceName: '${abbrs.containerRegistryRegistries}${resourceToken}'
    connectionName: 'acr-${resourceToken}'
    aiServicesAccountName: foundry.outputs.aiServicesAccountName
    aiProjectName: foundryProject.outputs.projectName
  }
}


// Outputs
output AZURE_AI_ACCOUNT_NAME string = foundry.outputs.aiServicesAccountName
output AZURE_AI_PROJECT_NAME string = foundryProject.outputs.projectName
output AZURE_AI_PROJECT_ID string = foundryProject.outputs.projectId
output AZURE_AI_PROJECT_ENDPOINT string = foundryProject.outputs.AZURE_AI_PROJECT_ENDPOINT
output AZURE_OPENAI_ENDPOINT string = foundry.outputs.AZURE_OPENAI_ENDPOINT
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.containerRegistryLoginServer
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = deployments![0].name

type deploymentsType = {
  @description('Specify the name of cognitive service account deployment.')
  name: string

  @description('Required. Properties of Cognitive Services account deployment model.')
  model: {
    @description('Required. The name of Cognitive Services account deployment model.')
    name: string

    @description('Required. The format of Cognitive Services account deployment model.')
    format: string

    @description('Required. The version of Cognitive Services account deployment model.')
    version: string
  }

  @description('The resource model definition representing SKU.')
  sku: {
    @description('Required. The name of the resource model definition representing SKU.')
    name: string

    @description('The capacity of the resource model definition representing SKU.')
    capacity: int
  }
}[]?
