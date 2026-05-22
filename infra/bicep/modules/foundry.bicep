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

}

output accountId string = aiAccount.id
output aiServicesAccountName string = aiAccount.name

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
