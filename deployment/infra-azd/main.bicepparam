using '../../infra/bicep/main.bicep'

// azd injects standard environment variables as Bicep parameter values.
// Set these with: azd env set <VAR> <value>
//
//   azd env set AZURE_LOCATION swedencentral
//   azd env set AZURE_AI_DEPLOYMENTS_LOCATION swedencentral
//   azd env set AZURE_AI_PROJECT_NAME ai-project
//
// AZURE_ENV_NAME and AZURE_RESOURCE_GROUP are set automatically by azd.

param environmentName       = readEnvironmentVariable('AZURE_ENV_NAME')
param resourceGroupName     = readEnvironmentVariable('AZURE_RESOURCE_GROUP', 'rg-${readEnvironmentVariable('AZURE_ENV_NAME')}')
param location              = readEnvironmentVariable('AZURE_LOCATION', 'swedencentral')
param aiDeploymentsLocation = readEnvironmentVariable('AZURE_AI_DEPLOYMENTS_LOCATION', readEnvironmentVariable('AZURE_LOCATION', 'swedencentral'))
param aiFoundryProjectName  = readEnvironmentVariable('AZURE_AI_PROJECT_NAME', 'ai-project-${readEnvironmentVariable('AZURE_ENV_NAME')}')

// Model deployments — edit this array to change the model or capacity.
// The first entry is used as AZURE_AI_MODEL_DEPLOYMENT_NAME for the agent.
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
      capacity: 50
    }
  }
]
