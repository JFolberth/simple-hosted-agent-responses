data "azapi_client_config" "current" {}

locals {
  resource_group_name     = coalesce(var.resource_group_name, "rg-${var.environment_name}")
  ai_foundry_project_name = coalesce(var.ai_foundry_project_name, "ai-project-${var.environment_name}")

  tags = {
    environment = var.environment_name
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────────────────────────────────────────

resource "azapi_resource" "resource_group" {
  type      = "Microsoft.Resources/resourceGroups@2022-09-01"
  name      = local.resource_group_name
  location  = var.location
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  tags      = local.tags
  body      = {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource Token
# Deterministic per subscription × resource group × AI deployments location,
# mirroring Bicep's uniqueString(subscription().id, resourceGroup().id, location).
# Keepers ensure the token is stable as long as these three values don't change.
# ─────────────────────────────────────────────────────────────────────────────

resource "random_id" "resource_token" {
  byte_length = 8

  keepers = {
    subscription_id     = data.azapi_client_config.current.subscription_id
    resource_group_name = local.resource_group_name
    location            = var.ai_deployments_location
  }
}

locals {
  resource_token = lower(random_id.resource_token.hex)
}

# ─────────────────────────────────────────────────────────────────────────────
# Log Analytics Workspace
# Provides structured log storage for Application Insights. All telemetry from
# the AI project and hosted agents is retained here for querying and alerting.
# ─────────────────────────────────────────────────────────────────────────────

module "log_analytics" {
  source = "./modules/loganalytics"

  resource_group_id = azapi_resource.resource_group.id
  location          = var.ai_deployments_location
  name              = "logs-${local.resource_token}"
  tags              = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Application Insights
# Captures distributed traces, metrics, and exceptions from the hosted agent.
# Connected to the Log Analytics workspace above. The project MI is granted
# Log Analytics Reader so evaluations can run against agent traces.
# ─────────────────────────────────────────────────────────────────────────────

module "application_insights" {
  source = "./modules/applicationinsights"

  resource_group_id          = azapi_resource.resource_group.id
  location                   = var.ai_deployments_location
  name                       = "appi-${local.resource_token}"
  log_analytics_workspace_id = module.log_analytics.id
  tags                       = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure AI Foundry (AI Services Account)
# Provisions the Azure AI Services account and all model deployments. Also
# enables the account-level capability host when hosted agents are active,
# which provides the shared agent runtime infrastructure for all projects.
# ─────────────────────────────────────────────────────────────────────────────

module "foundry" {
  source = "./modules/foundry"

  resource_group_id = azapi_resource.resource_group.id
  location          = var.ai_deployments_location
  resource_token    = local.resource_token
  deployments       = var.deployments
  tags              = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# AI Foundry Project
# Creates the Foundry project under the AI Services account and links it to
# Application Insights for trace collection. A single account can host
# multiple projects; this module manages exactly one.
# ─────────────────────────────────────────────────────────────────────────────

module "foundry_project" {
  source = "./modules/foundry_project"

  subscription_id                = data.azapi_client_config.current.subscription_id
  location                       = var.ai_deployments_location
  resource_token                 = local.resource_token
  ai_foundry_project_name        = local.ai_foundry_project_name
  ai_account_id                  = module.foundry.account_id
  app_insights_id                = module.application_insights.id
  app_insights_connection_string = module.application_insights.connection_string
  tags                           = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure Container Registry
# Stores Docker images built for the hosted agent. The Foundry project
# managed identity is granted AcrPull so the agent runtime can pull images.
# Registers the registry as a connection in the Foundry project.
# ─────────────────────────────────────────────────────────────────────────────

module "acr" {
  source = "./modules/acr"

  subscription_id      = data.azapi_client_config.current.subscription_id
  resource_group_id    = azapi_resource.resource_group.id
  location             = var.ai_deployments_location
  resource_name        = "cr${local.resource_token}"
  connection_name      = "acr-${local.resource_token}"
  project_id           = module.foundry_project.project_id
  project_principal_id = module.foundry_project.project_principal_id
  ai_project_name      = local.ai_foundry_project_name
  tags                 = local.tags
}

