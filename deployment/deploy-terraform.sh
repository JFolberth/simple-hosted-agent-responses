#!/usr/bin/env bash
# deploy-terraform.sh — deploy simple-hosted-agent using Terraform (azapi)
#
# Prerequisites:
#   - az login (or service principal auth already configured)
#   - terraform >= 1.9 in PATH
#   - Docker daemon running locally
#
# Usage:
#   First deploy:   ./deployment/deploy-terraform.sh
#   Code change:    ./deployment/deploy-terraform.sh --skip-infra

set -euo pipefail

# Resolve the repo root regardless of the caller's working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — edit these to match your environment
# ─────────────────────────────────────────────────────────────────────────────
AGENT_NAME="agent-framework-agent-basic-responses-tf"
AGENT_SOURCE_DIR="${REPO_ROOT}/src/agent-framework/responses/basic"
IMAGE_NAME="agent-framework-agent-basic-responses"
TF_DIR="${REPO_ROOT}/infra/terraform"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
SKIP_INFRA=false
for arg in "$@"; do
  case $arg in
    --skip-infra) SKIP_INFRA=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Deploy infrastructure with Terraform
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SKIP_INFRA" = false ]; then
  echo "==> Deploying infrastructure with Terraform..."
  pushd "${TF_DIR}" > /dev/null
  terraform init -upgrade
  terraform apply -var-file=terraform.tfvars -auto-approve
  popd > /dev/null
  echo "    Infrastructure deployed."
else
  echo "==> Skipping infrastructure deployment (--skip-infra)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Read Terraform outputs
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Reading Terraform outputs..."
OUTPUTS=$(cd "${TF_DIR}" && terraform output -json)

if [ -z "${OUTPUTS}" ] || [ "${OUTPUTS}" = "{}" ]; then
  echo "ERROR: Terraform returned no outputs. Run 'terraform apply' first."
  exit 1
fi

_get() { echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['$1']['value'])"; }

AI_ACCOUNT_NAME=$(      _get AZURE_AI_ACCOUNT_NAME)
PROJECT_NAME=$(          _get AZURE_AI_PROJECT_NAME)
PROJECT_ID=$(            _get AZURE_AI_PROJECT_ID)
PROJECT_ENDPOINT=$(      _get AZURE_AI_PROJECT_ENDPOINT)
ACR_ENDPOINT=$(          _get AZURE_CONTAINER_REGISTRY_ENDPOINT)
MODEL_DEPLOYMENT_NAME=$( _get AZURE_AI_MODEL_DEPLOYMENT_NAME)
ACR_NAME="${ACR_ENDPOINT%.azurecr.io}"

echo "    AI Account      : ${AI_ACCOUNT_NAME}"
echo "    Project         : ${PROJECT_NAME}"
echo "    Project endpoint: ${PROJECT_ENDPOINT}"
echo "    ACR             : ${ACR_ENDPOINT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Assign Foundry Project Manager (eadc314b) at project scope
#
# The Foundry data plane evaluates 'Microsoft.CognitiveServices/accounts/
# AIServices/agents/write' at project scope. This role assignment is idempotent.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Assigning Foundry Project Manager (eadc314b) at project scope..."
PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv)
ROLE_FOUNDRY_PM="eadc314b-1a2d-4efa-be10-5d325db5065e"  # Foundry Project Manager

az role assignment create \
  --role "${ROLE_FOUNDRY_PM}" \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --assignee-principal-type User \
  --scope "${PROJECT_ID}" \
  --output none 2>/dev/null || echo "    Role already assigned."

echo "    Waiting 120s for RBAC propagation..."
sleep 120

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Authenticate Docker to ACR
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Authenticating to ACR..."
az acr login --name "${ACR_NAME}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Build and push the container image
# ─────────────────────────────────────────────────────────────────────────────
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)
FULL_IMAGE="${ACR_ENDPOINT}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "==> Building image ${FULL_IMAGE}..."
docker build \
  --platform linux/amd64 \
  --tag  "${FULL_IMAGE}" \
  --file "${AGENT_SOURCE_DIR}/Dockerfile" \
  "${AGENT_SOURCE_DIR}"

echo "==> Pushing image..."
docker push "${FULL_IMAGE}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Deploy the hosted agent via Foundry data plane
#
#   POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview
#
# Auth scope: https://ai.azure.com/.default — NOT cognitiveservices.azure.com.
# metadata.enableVnextExperience=true is required by the server-side API.
# The runtime auto-starts the container; no separate start call is needed.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Deploying hosted agent via Foundry data plane..."
AGENT_REQUEST_BODY=$(python3 - <<EOF
import json
body = {
  "metadata": {"enableVnextExperience": "true"},
  "definition": {
    "kind": "hosted",
    "container_protocol_versions": [{"protocol": "responses", "version": "2.0.0"}],
    "cpu": "0.25",
    "memory": "0.5Gi",
    "environment_variables": {
      "AZURE_AI_MODEL_DEPLOYMENT_NAME": "${MODEL_DEPLOYMENT_NAME}"
    },
    "image": "${FULL_IMAGE}"
  }
}
print(json.dumps(body))
EOF
)

# az rest does not reliably acquire a token scoped to https://ai.azure.com/ for
# this endpoint. Use az account get-access-token + curl instead.
FOUNDRY_TOKEN=$(az account get-access-token --resource "https://ai.azure.com/" --query accessToken -o tsv)
AGENT_VERSION_RESPONSE=$(curl -s -f -X POST \
  "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer ${FOUNDRY_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${AGENT_REQUEST_BODY}")

AGENT_VERSION=$(echo "${AGENT_VERSION_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")

echo "    Agent name    : ${AGENT_NAME}"
echo "    Agent version : ${AGENT_VERSION}"
echo "    Portal URL    : https://ai.azure.com/"
echo ""
echo "    Open the Foundry portal, navigate to project '${PROJECT_NAME}', and"
echo "    select Agents to test your agent."
