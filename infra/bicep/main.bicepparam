using './main.bicep'

param environmentName = 'simple-hosted-agent-bicep'
param resourceGroupName = 'rg-simple-hosted-agent-bicep'
param location = 'swedencentral'
param aiDeploymentsLocation = 'swedencentral'
param aiFoundryProjectName = 'ai-project'
param deployments = [
  {
    name: 'gpt-5.4-mini'
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-mini'
      version: '2026-03-17'
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 10
    }
  }
]
