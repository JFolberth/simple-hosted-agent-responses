variable "location" {
  type        = string
  description = "Azure region for the project."
}

variable "resource_token" {
  type        = string
  description = "Unique token for deterministic resource naming (passed from root module)."
}

variable "ai_foundry_project_name" {
  type        = string
  description = "Name of the AI Foundry project."
}

variable "ai_account_id" {
  type        = string
  description = "Resource ID of the parent AI Services account."
}

variable "app_insights_id" {
  type        = string
  description = "Resource ID of the Application Insights instance."
  default     = ""
}

variable "app_insights_connection_string" {
  type        = string
  description = "Connection string for App Insights."
  sensitive   = true
  default     = ""
}

variable "enable_app_insights" {
  type        = bool
  description = "Set to false to skip the App Insights connection and Log Analytics Reader role assignment. Must be a literal value (not derived from a resource output) because Terraform evaluates it at plan time."
  default     = true
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID, used when constructing role definition resource IDs."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply."
  default     = {}
}
