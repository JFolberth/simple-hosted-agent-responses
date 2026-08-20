variable "environment_name" {
  type        = string
  description = "Name of the environment — used in resource naming and tags."
  validation {
    condition     = length(var.environment_name) >= 1 && length(var.environment_name) <= 64
    error_message = "environment_name must be 1–64 characters."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to create. Defaults to 'rg-{environment_name}'."
  default     = null
}

variable "location" {
  type        = string
  description = "Primary Azure region for the resource group."
  validation {
    condition = contains([
      "australiaeast", "brazilsouth", "canadacentral", "canadaeast",
      "eastus", "eastus2", "francecentral", "germanywestcentral",
      "italynorth", "japaneast", "koreacentral", "northcentralus",
      "norwayeast", "polandcentral", "southafricanorth", "southcentralus",
      "southeastasia", "southindia", "spaincentral", "swedencentral",
      "switzerlandnorth", "uaenorth", "uksouth", "westus", "westus2", "westus3"
    ], var.location)
    error_message = "location must be a supported Azure AI Foundry hosted-agent region."
  }
}

variable "ai_deployments_location" {
  type        = string
  description = "Region for AI model deployments and the AI Services account (may differ from location)."
}

variable "ai_foundry_project_name" {
  type        = string
  description = "Name of the AI Foundry project. Defaults to 'ai-project-{environment_name}'."
  default     = null
}

variable "deployments" {
  type = list(object({
    name = string
    model = object({
      name    = string
      format  = string
      version = string
    })
    sku = object({
      name     = string
      capacity = number
    })
  }))
  description = "List of model deployments to create on the AI Services account."
  default     = []
}

variable "enable_web_iq" {
  type        = bool
  description = "Enable the optional Microsoft Web IQ connection and supporting Key Vault."
  default     = true
}

variable "web_iq_api_key" {
  type        = string
  description = "Web IQ API key. Required when enable_web_iq is true. The value is stored in Terraform state."
  default     = null
  sensitive   = true

  validation {
    condition     = !var.enable_web_iq || (var.web_iq_api_key != null && length(trimspace(var.web_iq_api_key)) > 0)
    error_message = "web_iq_api_key must be set when enable_web_iq is true."
  }
}

variable "web_iq_connection_name" {
  type        = string
  description = "Name of the Web IQ Foundry project connection."
  default     = "WebIQ"
}
