# ── Container Registry ─────────────────────────────────────────────────────────

resource "azapi_resource" "container_registry" {
  type      = "Microsoft.ContainerRegistry/registries@2023-07-01"
  name      = var.resource_name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    sku = {
      name = "Basic"
    }
    properties = {
      adminUserEnabled    = false
      publicNetworkAccess = "Enabled"
    }
  }

  response_export_values = ["properties.loginServer"]
}

# ── AcrPull for the project managed identity ───────────────────────────────────
# Allows the Foundry Agent Service runtime to pull the hosted agent image.

resource "azapi_resource" "acr_pull_role" {
  type = "Microsoft.Authorization/roleAssignments@2022-04-01"
  # Deterministic UUID scoped to: registry × project name × role
  name      = uuidv5("url", "${azapi_resource.container_registry.id}/${var.ai_project_name}/acrpull")
  parent_id = azapi_resource.container_registry.id

  body = {
    properties = {
      principalId      = var.project_principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d" # AcrPull
    }
  }
}

# ── ACR connection on the Foundry project ─────────────────────────────────────
# Registers the registry so Foundry Agent Service knows where to pull the image.
# authType ManagedIdentity — the project MI (granted AcrPull above) is used;
# no stored credentials are required.

module "acr_connection" {
  source = "../foundry_project_connection"

  project_id = var.project_id
  connection_config = {
    name             = var.connection_name
    category         = "ContainerRegistry"
    target           = azapi_resource.container_registry.output.properties.loginServer
    auth_type        = "ManagedIdentity"
    is_shared_to_all = true
    metadata = {
      ResourceId = azapi_resource.container_registry.id
    }
  }
  credentials = {
    clientId   = var.project_principal_id
    resourceId = azapi_resource.container_registry.id
  }
}
