# terraform.tfvars — variable values for the simple-hosted-agent Terraform deployment.
# This file contains no secrets and is safe to commit.
#
# Uses a "-tf" suffix on the environment name to avoid colliding with the Bicep deployment.
# Change these values to match your target environment before running deploy-terraform.sh.

environment_name        = "simple-hosted-agent-tf"
resource_group_name     = "rg-simple-hosted-agent-tf"
location                = "swedencentral"
ai_deployments_location = "swedencentral"
ai_foundry_project_name = "ai-project-tf"

deployments = [
  {
    name = "gpt-5.4-mini"
    model = {
      format  = "OpenAI"
      name    = "gpt-5.4-mini"
      version = "2026-03-17"
    }
    sku = {
      name     = "Standard"
      capacity = 10
    }
  }
]
