targetScope = 'resourceGroup'

@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Storage account resource name')
param resourceName string

@description('AI Services account name for the project parent')
param aiServicesAccountName string

@description('AI project name for creating the connection')
param aiProjectName string

@description('Name for the AI Foundry storage connection')
param connectionName string

// Storage Account for the AI Services account
resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: resourceName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    accessTier: 'Hot'
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// Get reference to the AI Services account and project to access their managed identities
resource aiAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: aiServicesAccountName

  resource aiProject 'projects' existing = {
    name: aiProjectName
  }
}

// Role assignment for AI Services to access the storage account
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, resourceName, aiServicesAccountName, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: aiAccount::aiProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Hosted-agent-specific ──────────────────────────────────────────────────
// Storage connection — registered on the Foundry project so the account-level
// capability host (foundry.bicep) can discover it and use it to persist agent
// session thread state (conversation history, in-flight tool calls) across the
// 15-minute idle timeout. The runtime resolves the storage connection from the
// project's registered connections automatically — no project-level capability
// host resource is needed.
//
// authType: 'AAD' means the project managed identity (granted Storage Blob
// Data Contributor above) authenticates — no stored keys in the connection.
module storageConnection './foundry-project-connection.bicep' = {
  name: 'storage-connection-creation'
  params: {
    aiServicesAccountName: aiServicesAccountName
    aiProjectName: aiProjectName
    connectionConfig: {
      name: connectionName
      category: 'AzureStorageAccount'
      target: storageAccount.properties.primaryEndpoints.blob
      authType: 'AAD'
      isSharedToAll: true
      metadata: {
        ApiType: 'Azure'
        ResourceId: storageAccount.id
        location: storageAccount.location
      }
    }
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output storageAccountPrincipalId string = storageAccount.identity.principalId
output storageConnectionName string = storageConnection.outputs.connectionName
