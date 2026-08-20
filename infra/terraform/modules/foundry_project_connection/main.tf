resource "azapi_resource" "connection" {
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2026-05-15-preview"
  name      = var.connection_config.name
  parent_id = var.project_id

  # Schema validation disabled — these preview API versions are not yet bundled.
  schema_validation_enabled = false

  # Don't fail plan when the API returns system-managed properties that aren't
  # in our config (common for connection resources).
  ignore_missing_property = true

  body = {
    properties = merge(
      {
        category = var.connection_config.category
        target   = var.connection_config.target
        authType = var.connection_config.auth_type
      },
      var.connection_config.is_shared_to_all == null ? {} : {
        isSharedToAll = var.connection_config.is_shared_to_all
      },
      var.connection_config.metadata == null ? {} : {
        metadata = var.connection_config.metadata
      },
      var.credentials == null ? {} : {
        credentials = var.credentials
      }
    )
  }
}
