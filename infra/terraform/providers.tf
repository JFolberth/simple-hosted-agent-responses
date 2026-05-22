terraform {
  required_version = ">= 1.9"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Local state — suitable for individual development and running locally.
  # For team or production use, switch to a remote backend:
  #   cp infra/terraform/backend.hcl.example infra/terraform/backend.hcl
  #   terraform init -backend-config=backend.hcl -migrate-state
  # For GitHub Actions, set TF_BACKEND_* repository variables (see backend.hcl.example).
  backend "local" {}
}

provider "azapi" {}
