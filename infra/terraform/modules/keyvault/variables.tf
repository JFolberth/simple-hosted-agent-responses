variable "resource_group_id" {
  type        = string
  description = "Resource ID of the resource group that owns the Key Vault."
}

variable "location" {
  type        = string
  description = "Azure region for the Key Vault."
}

variable "name" {
  type        = string
  description = "Name of the Key Vault."
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID for the Key Vault."
}

variable "secret_name" {
  type        = string
  description = "Name of the secret."
}

variable "secret_content_type" {
  type        = string
  description = "Content type that describes the secret value."
}

variable "secret_value" {
  type        = string
  description = "Value of the secret."
  sensitive   = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the Key Vault."
  default     = {}
}
