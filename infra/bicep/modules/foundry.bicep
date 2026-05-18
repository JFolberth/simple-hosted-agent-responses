targetScope = 'resourceGroup'

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Location for the AI Services account')
param location string

@description('List of model deployments to create on the account')
param deployments deploymentsType

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

resource aiAccount 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: 'ai-account-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: 'ai-account-${resourceToken}'
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }

  // Deploy models sequentially to avoid capacity conflicts
  @batchSize(1)
  resource seqDeployments 'deployments' = [
    for dep in (deployments ?? []): {
      name: dep.name
      properties: {
        model: dep.model
      }
      sku: dep.sku
    }
  ]

  // ── Hosted-agent-specific ──────────────────────────────────────────────────
  // Account-level capability host — this is what makes the AI Services account
  // capable of running hosted agents. Without it the account can serve model
  // calls but the Foundry Agent Service micro VM runtime is never provisioned.
  //
  // capabilityHostKind: 'Agents'      → registers with Foundry Agent Service
  // enablePublicHostingEnvironment    → allows the micro VMs to reach the
  //                                     public ACR endpoint for image pulls
  //                                     (private ACR is not yet supported)
  //
  // This account-level host is sufficient — no project-level capability host
  // resource is needed. The runtime discovers the ACR connection registered on
  // the project (acr.bicep) automatically.
  resource aiFoundryAccountCapabilityHost 'capabilityHosts@2025-10-01-preview' = {
    name: 'agents'
    properties: {
      capabilityHostKind: 'Agents'
      enablePublicHostingEnvironment: true
    }
    dependsOn: [
      seqDeployments
    ]
  }
}

output accountId string = aiAccount.id
output aiServicesAccountName string = aiAccount.name
output AZURE_OPENAI_ENDPOINT string = aiAccount.properties.endpoints['OpenAI Language Model Instance API']

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
