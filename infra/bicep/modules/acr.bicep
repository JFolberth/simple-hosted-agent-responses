targetScope = 'resourceGroup'

@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Resource name for the container registry')
param resourceName string

@description('AI Services account name for the project parent')
param aiServicesAccountName string

@description('AI project name for creating the connection')
param aiProjectName string

@description('Name for the AI Foundry ACR connection')
param connectionName string

// Get reference to the AI Services account and project to access their managed identities
resource aiAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: aiServicesAccountName

  resource aiProject 'projects' existing = {
    name: aiProjectName
  }
}

// Create the Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2026-01-01-preview' = {
  name: resourceName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

// AcrPull for the Foundry project managed identity — allows the hosted agent to pull images
resource projectAcrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, resourceName, aiProjectName, '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
    principalId: aiAccount::aiProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Hosted-agent-specific ──────────────────────────────────────────────────
// ACR connection — registers this registry as a connection on the Foundry
// project, which is what tells Foundry Agent Service where to pull the
// container image from when provisioning a micro VM. The registry itself is
// general purpose; it is this project-scoped connection that is specific to
// hosted agents.
//
// authType: 'ManagedIdentity' means the project managed identity (granted
// AcrPull above) is used for image pulls — no stored credentials required.
module acrConnection './foundry-project-connection.bicep' = {
  name: 'acr-connection-creation'
  params: {
    aiServicesAccountName: aiServicesAccountName
    aiProjectName: aiProjectName
    connectionConfig: {
      name: connectionName
      category: 'ContainerRegistry'
      target: containerRegistry.properties.loginServer
      authType: 'ManagedIdentity'
      isSharedToAll: true
      metadata: {
        ResourceId: containerRegistry.id
      }
    }
    credentials: {
      clientId: aiAccount::aiProject.identity.principalId
      resourceId: containerRegistry.id
    }
  }
}

output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerRegistryResourceId string = containerRegistry.id
output containerRegistryConnectionName string = acrConnection.outputs.connectionName
