output "id" {
  description = "Resource ID of the Application Insights instance."
  value       = azapi_resource.application_insights.id
}

output "name" {
  description = "Name of the Application Insights instance."
  value       = azapi_resource.application_insights.name
}

output "connection_string" {
  description = "Connection string for the Application Insights instance."
  value       = azapi_resource.application_insights.output.properties.ConnectionString
  sensitive   = true
}

