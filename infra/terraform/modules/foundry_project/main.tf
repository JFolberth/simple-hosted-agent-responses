# ── AI Foundry Project ─────────────────────────────────────────────────────────

resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2026-03-01"
  name      = var.ai_foundry_project_name
  parent_id = var.ai_account_id
  location  = var.location
  tags      = var.tags

  # Schema validation disabled — api-version 2026-03-01 is not yet bundled.
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      description = "${var.ai_foundry_project_name} Project"
      displayName = "${var.ai_foundry_project_name}Project"
    }
  }

  response_export_values = ["properties.endpoints"]
}

# ── App Insights connection ────────────────────────────────────────────────────
# Links the project to Application Insights for trace collection.
# Not hosted-agent-specific: prompt-based agents and evaluations in the portal
# also use it to surface traces.
#
# auth_type "ApiKey" with the connection string is the only option the Foundry portal
# supports for the AppInsights connection category — "AAD" is not accepted here.
#
# Why not use Entra-authenticated telemetry ingestion?
# Microsoft Entra auth for App Insights (APPLICATIONINSIGHTS_AUTHENTICATION_STRING +
# Monitoring Metrics Publisher role) exists but Microsoft docs explicitly state it does
# NOT support autoinstrumentation scenarios. The agent framework relies on autoinstrumentation
# via the injected APPLICATIONINSIGHTS_CONNECTION_STRING env var, so Entra ingestion auth
# would not take effect. The portal connection still requires the key regardless, making
# the extra role assignment all cost with no benefit.

module "app_insights_connection" {
  count  = var.enable_app_insights ? 1 : 0
  source = "../foundry_project_connection"

  project_id = azapi_resource.project.id
  connection_config = {
    name             = "appi-${var.resource_token}"
    category         = "AppInsights"
    target           = var.app_insights_id
    auth_type        = "ApiKey"
    is_shared_to_all = true
    metadata = {
      ApiType    = "Azure"
      ResourceId = var.app_insights_id
    }
  }
  credentials = {
    key = var.app_insights_connection_string
  }
}

# ── Log Analytics Reader ───────────────────────────────────────────────────────
# Grants the project MI read access to App Insights / Log Analytics so
# evaluations can query agent traces.

resource "azapi_resource" "log_analytics_reader_role" {
  count = var.enable_app_insights ? 1 : 0

  type = "Microsoft.Authorization/roleAssignments@2022-04-01"
  # Deterministic UUID scoped to: App Insights resource × project name × role
  name      = uuidv5("url", "${var.app_insights_id}/${var.ai_foundry_project_name}/lareader")
  parent_id = var.app_insights_id

  body = {
    properties = {
      principalId      = azapi_resource.project.identity[0].principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/73c42c96-874c-492b-b04d-ab87d138a893"
    }
  }
}

# ── Azure AI User ──────────────────────────────────────────────────────────────
# Grants the project MI Microsoft.CognitiveServices/* data actions on the AI
# account so the container can call the model endpoint. Without this the
# container receives 401 PermissionDenied on every model call.

resource "azapi_resource" "ai_user_role" {
  type = "Microsoft.Authorization/roleAssignments@2022-04-01"
  # Deterministic UUID scoped to: AI account × project name × role
  name      = uuidv5("url", "${var.ai_account_id}/${var.ai_foundry_project_name}/aiuser")
  parent_id = var.ai_account_id

  body = {
    properties = {
      principalId      = azapi_resource.project.identity[0].principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
    }
  }
}
