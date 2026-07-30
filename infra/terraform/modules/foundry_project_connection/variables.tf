variable "project_id" {
  type        = string
  description = "Resource ID of the AI Foundry project that owns this connection."
}

variable "api_version" {
  type        = string
  description = "API version used to manage the project connection."
  default     = "2026-03-01"
}

variable "connection_config" {
  type = object({
    name             = string
    category         = string
    target           = string
    auth_type        = string
    is_shared_to_all = optional(bool)
    metadata         = optional(map(string))
  })
  description = "Connection configuration."
}

variable "credentials" {
  type        = any
  description = "Connection credentials (e.g. { key = '...' } for ApiKey, { clientId = '...', resourceId = '...' } for ManagedIdentity). Null omits credentials from the request."
  default     = null
  sensitive   = true
}
