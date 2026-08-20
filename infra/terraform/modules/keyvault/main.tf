resource "azapi_resource" "vault" {
  type      = "Microsoft.KeyVault/vaults@2025-05-01"
  name      = var.name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  body = {
    properties = {
      accessPolicies               = []
      enablePurgeProtection        = true
      enableRbacAuthorization      = true
      enableSoftDelete             = true
      enabledForDeployment         = false
      enabledForDiskEncryption     = false
      enabledForTemplateDeployment = true
      publicNetworkAccess          = "Enabled"
      softDeleteRetentionInDays    = 7
      tenantId                     = var.tenant_id
      sku = {
        family = "A"
        name   = "standard"
      }
    }
  }

  response_export_values = ["properties.vaultUri"]
}

resource "azapi_resource" "secret" {
  type      = "Microsoft.KeyVault/vaults/secrets@2025-05-01"
  name      = var.secret_name
  parent_id = azapi_resource.vault.id

  body = {
    properties = {
      attributes = {
        enabled = true
      }
      contentType = var.secret_content_type
      value       = var.secret_value
    }
  }
}
