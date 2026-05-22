targetScope = 'resourceGroup'

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Location for the project')
param location string

@description('Name of the AI Foundry project')
param aiFoundryProjectName string

@description('Name of the parent AI Services account')
param aiServicesAccountName string

@description('Resource ID of the Application Insights instance. Pass empty string to skip.')
param appInsightsId string = ''

@description('Connection string for Application Insights. Pass empty string to skip.')
@secure()
param appInsightsConnectionString string = ''

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Reference the parent AI Services account (created by foundry.bicep)
resource aiAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: aiServicesAccountName
}

// The AI Foundry project — scoped under the AI Services account
resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' = {
  parent: aiAccount
  name: aiFoundryProjectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: '${aiFoundryProjectName} Project'
    displayName: '${aiFoundryProjectName}Project'
  }
}

// App Insights connection — links the project to Application Insights for trace collection.
// Unlike the ACR connection, this is NOT hosted-agent-specific: prompt-based agents and
// evaluations in the Foundry portal also use it to surface traces. It is included here
// because it is scoped to the project, not the capability host.
//
// authType 'ApiKey' with the connection string is the only option the Foundry portal
// supports for the AppInsights connection category — 'AAD' is not accepted here.
//
// Why not use Entra-authenticated telemetry ingestion?
// Microsoft Entra auth for App Insights (APPLICATIONINSIGHTS_AUTHENTICATION_STRING +
// Monitoring Metrics Publisher role) exists but Microsoft docs explicitly state it does
// NOT support autoinstrumentation scenarios. The agent framework relies on autoinstrumentation
// via the injected APPLICATIONINSIGHTS_CONNECTION_STRING env var, so Entra ingestion auth
// would not take effect. The portal connection still requires the key regardless, making
// the extra role assignment all cost with no benefit.
module appInsightConnection './foundry-project-connection.bicep' = if (!empty(appInsightsId)) {
  name: 'appi-connection'
  params: {
    aiServicesAccountName: aiServicesAccountName
    aiProjectName: aiFoundryProjectName
    connectionConfig: {
      name: 'appi-${resourceToken}'
      category: 'AppInsights'
      target: appInsightsId
      authType: 'ApiKey'
      isSharedToAll: true
      metadata: {
        ApiType: 'Azure'
        ResourceId: appInsightsId
      }
    }
    credentials: {
      key: appInsightsConnectionString
    }
  }
  dependsOn: [project]
}

// Reference App Insights for scoping the Log Analytics Reader role assignment
resource existingAppInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsId)) {
  name: last(split(appInsightsId, '/'))
}

// Log Analytics Reader for the project managed identity — required for running
// evaluations against agent traces stored in the Log Analytics workspace
resource logAnalyticsReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(appInsightsId)) {
  scope: existingAppInsights
  name: guid(resourceGroup().id, aiFoundryProjectName, '73c42c96-874c-492b-b04d-ab87d138a893') // Log Analytics Reader
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893') // Log Analytics Reader
  }
}

// ── Hosted-agent-specific ──────────────────────────────────────────────────
// Foundry User for the project managed identity — grants
// Microsoft.CognitiveServices/* data actions on the AI account so the
// container running inside the hosted agent can call the model endpoint.
// (Previously named "Azure AI User"; the GUID 53ca6127 is unchanged.)
//
// The Foundry runtime injects FOUNDRY_PROJECT_ENDPOINT into the container
// automatically; this role is what allows that endpoint to be called with
// the container's managed identity. Without it the container receives:
//   401 PermissionDenied — lacks Microsoft.CognitiveServices/accounts/
//   AIServices/agents/write to perform POST /api/projects/{name}/openai/*
resource foundryUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiAccount
  name: guid(resourceGroup().id, aiFoundryProjectName, '53ca6127-db72-4b80-b1b0-d745d6d5456d') // Foundry User
  properties: {
    principalId: project.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d') // Foundry User
  }
}

output AZURE_AI_PROJECT_ENDPOINT string = project.properties.endpoints['AI Foundry API']
output projectId string = project.id
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
