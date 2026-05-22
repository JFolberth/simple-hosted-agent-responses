output "account_id" {
  description = "Resource ID of the AI Services account."
  value       = azapi_resource.ai_account.id
}

output "ai_services_account_name" {
  description = "Name of the AI Services account."
  value       = azapi_resource.ai_account.name
}
