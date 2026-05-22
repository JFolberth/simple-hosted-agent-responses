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
