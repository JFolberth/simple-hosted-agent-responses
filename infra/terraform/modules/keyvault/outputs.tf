output "id" {
  description = "Resource ID of the Key Vault."
  value       = azapi_resource.vault.id
}

output "name" {
  description = "Name of the Key Vault."
  value       = azapi_resource.vault.name
}

output "uri" {
  description = "Data-plane URI of the Key Vault."
  value       = azapi_resource.vault.output.properties.vaultUri
}

output "secret_id" {
  description = "ARM resource ID of the secret."
  value       = azapi_resource.secret.id
}
