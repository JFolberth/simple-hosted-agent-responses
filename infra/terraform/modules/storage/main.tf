# ── Storage Account ────────────────────────────────────────────────────────────

resource "azapi_resource" "storage_account" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = var.resource_name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "StorageV2"
    sku = {
      name = "Standard_LRS"
    }
    properties = {
      supportsHttpsTrafficOnly = true
      allowBlobPublicAccess    = false
      minimumTlsVersion        = "TLS1_2"
      accessTier               = "Hot"
      encryption = {
        services = {
          blob = { enabled = true }
          file = { enabled = true }
        }
        keySource = "Microsoft.Storage"
      }
    }
  }

  response_export_values = ["properties.primaryEndpoints"]
}

# ── Storage Blob Data Contributor for the project MI ──────────────────────────
# Allows the hosted agent runtime to persist session thread state in blob storage.

resource "azapi_resource" "storage_role" {
  type = "Microsoft.Authorization/roleAssignments@2022-04-01"
  # Deterministic UUID scoped to: storage account × project name × role
  name      = uuidv5("url", "${azapi_resource.storage_account.id}/${var.ai_project_name}/storageblobdatacontrib")
  parent_id = azapi_resource.storage_account.id

  body = {
    properties = {
      principalId      = var.project_principal_id
      principalType    = "ServicePrincipal"
      roleDefinitionId = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe" # Storage Blob Data Contributor
    }
  }
}

# ── Storage connection on the Foundry project ──────────────────────────────────
# Registers the storage account so the account-level capability host can persist
# agent session thread state. authType AAD — the project MI (granted Storage Blob
# Data Contributor above) authenticates; no stored keys are required.

module "storage_connection" {
  source = "../foundry_project_connection"

  project_id = var.project_id
  connection_config = {
    name             = var.connection_name
    category         = "AzureStorageAccount"
    target           = azapi_resource.storage_account.output.properties.primaryEndpoints.blob
    auth_type        = "AAD"
    is_shared_to_all = true
    metadata = {
      ApiType    = "Azure"
      ResourceId = azapi_resource.storage_account.id
      location   = var.location
    }
  }
  # No credentials — AAD auth uses the project MI automatically.
}
