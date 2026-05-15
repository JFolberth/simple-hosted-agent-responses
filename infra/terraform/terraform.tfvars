# terraform.tfvars — variable values for the simple-hosted-agent Terraform deployment.
# This file contains no secrets and is safe to commit.
#
# Uses a "-tf" suffix on the environment name to avoid colliding with the Bicep deployment.
# Change these values to match your target environment before running deploy-terraform.sh.

environment_name        = "simple-hosted-agent-tf2"
resource_group_name     = "rg-simple-hosted-agent-tf2"
location                = "swedencentral"
ai_deployments_location = "swedencentral"
ai_foundry_project_name = "ai-project-tf2"

deployments = [
  {
    name = "gpt-4.1-mini"
    model = {
      format  = "OpenAI"
      name    = "gpt-4.1-mini"
      version = "2025-04-14"
    }
    sku = {
      name     = "Standard"
      capacity = 10
    }
  }
]
