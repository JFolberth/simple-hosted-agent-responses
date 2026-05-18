# ── AI Services account ────────────────────────────────────────────────────────

resource "azapi_resource" "ai_account" {
  type      = "Microsoft.CognitiveServices/accounts@2026-03-01"
  name      = "ai-account-${var.resource_token}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  # Schema validation disabled — api-version 2026-03-01 is not yet bundled in
  # the azapi provider schema. The request body mirrors the Bicep source exactly.
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      allowProjectManagement = true
      customSubDomainName    = "ai-account-${var.resource_token}"
      disableLocalAuth       = true
      publicNetworkAccess    = "Enabled"
      networkAcls = {
        defaultAction       = "Allow"
        virtualNetworkRules = []
        ipRules             = []
      }
    }
  }

  response_export_values = ["properties.endpoints"]
}

# ── Model deployments ──────────────────────────────────────────────────────────
# NOTE: Azure may reject concurrent deployments for the same model family due to
# capacity limits. If you hit a 429/conflict error run:
#   terraform apply -parallelism=1
# to deploy models sequentially (approximating Bicep's @batchSize(1)).

resource "azapi_resource" "model_deployments" {
  for_each  = { for d in var.deployments : d.name => d }
  type      = "Microsoft.CognitiveServices/accounts/deployments@2026-03-01"
  name      = each.key
  parent_id = azapi_resource.ai_account.id

  schema_validation_enabled = false

  body = {
    properties = {
      model = {
        name    = each.value.model.name
        format  = each.value.model.format
        version = each.value.model.version
      }
    }
    sku = {
      name     = each.value.sku.name
      capacity = each.value.sku.capacity
    }
  }
}

# ── Account-level capability host ─────────────────────────────────────────────
# Registers the account with Foundry Agent Service so it can run hosted agents.
# This account-level host is sufficient — no project-level capability host is
# needed. The runtime discovers the ACR connection from the project's registered
# connections automatically.

resource "azapi_resource" "capability_host" {
  type      = "Microsoft.CognitiveServices/accounts/capabilityHosts@2025-10-01-preview"
  name      = "agents"
  parent_id = azapi_resource.ai_account.id

  # Schema validation disabled — preview API schema may not be bundled.
  schema_validation_enabled = false

  body = {
    properties = {
      capabilityHostKind             = "Agents"
      enablePublicHostingEnvironment = true
    }
  }

  depends_on = [azapi_resource.model_deployments]
}
