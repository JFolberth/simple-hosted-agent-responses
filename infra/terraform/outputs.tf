output "AZURE_AI_ACCOUNT_NAME" {
  description = "Name of the AI Services account."
  value       = module.foundry.ai_services_account_name
}

output "AZURE_AI_PROJECT_NAME" {
  description = "Name of the AI Foundry project."
  value       = module.foundry_project.project_name
}

output "AZURE_AI_PROJECT_ID" {
  description = "Resource ID of the AI Foundry project."
  value       = module.foundry_project.project_id
}

output "AZURE_AI_PROJECT_ENDPOINT" {
  description = "AI Foundry data-plane endpoint for the project."
  value       = module.foundry_project.project_endpoint
}

output "AZURE_CONTAINER_REGISTRY_ENDPOINT" {
  description = "Login server hostname for the container registry."
  value       = module.acr.login_server
}

output "AZURE_AI_MODEL_DEPLOYMENT_NAME" {
  description = "Name of the first model deployment (used as the agent's model)."
  value       = length(var.deployments) > 0 ? var.deployments[0].name : ""
}

output "TOOLBOX_KEY_VAULT_NAME" {
  description = "Name of the Key Vault that stores Toolbox connection credentials, or an empty string when disabled."
  value       = var.enable_web_iq ? module.toolbox_key_vault[0].name : ""
}

output "TOOLBOX_KEY_VAULT_ENDPOINT" {
  description = "Data-plane endpoint of the Toolbox Key Vault, or an empty string when disabled."
  value       = var.enable_web_iq ? module.toolbox_key_vault[0].uri : ""
}

output "WEB_IQ_CONNECTION_NAME" {
  description = "Name of the Web IQ Foundry project connection, or an empty string when disabled."
  value       = var.enable_web_iq ? module.web_iq[0].connection_name : ""
}

output "TOOLBOX_NAME" {
  description = "Foundry Toolbox name (matches the project name)."
  value       = module.foundry_project.project_name
}

output "TOOLBOX_ENDPOINT" {
  description = "Consumer MCP endpoint for the Foundry Toolbox."
  value       = "${module.foundry_project.project_endpoint}/toolboxes/${module.foundry_project.project_name}/mcp?api-version=v1"
}

# JSON array of tools that should live in the toolbox — assembled from the
# optional connection modules that are actually enabled. Consumers reconcile
# by POSTing this array as a new version and PATCHing default_version.
# Empty array ("[]") means no toolbox reconciliation should happen.
output "TOOLBOX_TOOLS_JSON" {
  description = "Desired-state JSON array of tools for the Foundry Toolbox."
  value = jsonencode(concat(
    var.enable_web_iq ? [{
      type                  = "mcp"
      server_label          = "web-iq"
      project_connection_id = module.web_iq[0].connection_name
      require_approval      = "never"
    }] : [],
  ))
}
