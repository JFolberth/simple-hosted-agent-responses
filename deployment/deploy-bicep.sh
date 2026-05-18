#!/usr/bin/env bash
# deploy-bicep.sh — deploy simple-hosted-agent without azd
#
# Prerequisites:
#   - az login (or service principal auth already configured)
#   - Docker daemon running locally
#
# Usage:
#   First deploy:   ./deployment/deploy-bicep.sh
#   Code change:    ./deployment/deploy-bicep.sh --skip-infra

set -euo pipefail

# Resolve the repo root regardless of the caller's working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — edit these to match your environment
# ─────────────────────────────────────────────────────────────────────────────
ENVIRONMENT_NAME="simple-hosted-agent3"
LOCATION="eastus"
AGENT_NAME="agent-framework-agent-basic-responses"
AGENT_SOURCE_DIR="${REPO_ROOT}/src/agent-framework/responses/basic"
IMAGE_NAME="agent-framework-agent-basic-responses"
DEPLOYMENT_NAME="deploy-${ENVIRONMENT_NAME}"

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
# Step 1: Deploy infrastructure
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SKIP_INFRA" = false ]; then
  echo "==> Deploying infrastructure..."
  az deployment sub create \
    --name          "${DEPLOYMENT_NAME}" \
    --location      "${LOCATION}" \
    --template-file "${REPO_ROOT}/infra/bicep/main.bicep" \
    --parameters    "${REPO_ROOT}/infra/bicep/main.bicepparam" \
    --output none

  DEPLOY_STATE=$(az deployment sub show \
    --name "${DEPLOYMENT_NAME}" \
    --query properties.provisioningState \
    --output tsv)
  if [ "${DEPLOY_STATE}" != "Succeeded" ]; then
    echo "ERROR: Deployment finished in state '${DEPLOY_STATE}' — not Succeeded."
    echo "       Run this to see detailed errors:"
    echo "       az deployment sub show --name '${DEPLOYMENT_NAME}' --query properties.error"
    exit 1
  fi
  echo "    Infrastructure deployed."
else
  echo "==> Skipping infrastructure deployment (--skip-infra)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Read deployment outputs
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Reading deployment outputs..."
OUTPUTS=$(az deployment sub show \
  --name "${DEPLOYMENT_NAME}" \
  --query properties.outputs \
  --output json)

if [ -z "${OUTPUTS}" ] || [ "${OUTPUTS}" = "null" ] || [ "${OUTPUTS}" = "{}" ]; then
  echo "ERROR: Deployment '${DEPLOYMENT_NAME}' returned no outputs."
  echo "       Raw outputs value: '${OUTPUTS}'"
  echo "       Full deployment outputs:"
  az deployment sub show --name "${DEPLOYMENT_NAME}" --query '{state:properties.provisioningState,outputs:properties.outputs}' --output json
  exit 1
fi

_get() { echo "$OUTPUTS" | python3 -c "import sys,json; d={k.upper():v for k,v in json.load(sys.stdin).items()}; print(d['$1']['value'])"; }

AI_ACCOUNT_NAME=$(    _get AZURE_AI_ACCOUNT_NAME)
PROJECT_NAME=$(        _get AZURE_AI_PROJECT_NAME)
PROJECT_ID=$(          _get AZURE_AI_PROJECT_ID)
PROJECT_ENDPOINT=$(    _get AZURE_AI_PROJECT_ENDPOINT)
ACR_ENDPOINT=$(        _get AZURE_CONTAINER_REGISTRY_ENDPOINT)
MODEL_DEPLOYMENT_NAME=$(_get AZURE_AI_MODEL_DEPLOYMENT_NAME)
ACR_NAME="${ACR_ENDPOINT%.azurecr.io}"

echo "    AI Account      : ${AI_ACCOUNT_NAME}"
echo "    Project         : ${PROJECT_NAME}"
echo "    Project endpoint: ${PROJECT_ENDPOINT}"
echo "    ACR             : ${ACR_ENDPOINT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Assign Foundry Project Manager (eadc314b) at project scope
#
# The Foundry data plane evaluates the 'Microsoft.CognitiveServices/accounts/
# AIServices/agents/write' permission at the scope of the Foundry project
# resource — not at subscription or resource group scope. Subscription-level
# role assignments are not reliably inherited by the Foundry data plane.
#
# Per the Microsoft docs:
#   "Foundry Project Manager at the project scope is the recommended role
#    assignment for agent creators, as that role includes both the required
#    data plane permissions and the ability to assign the Foundry User role."
#   https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions#agent-creation
#
# We assign it here (idempotent — az role assignment create is a no-op if the
# assignment already exists) so the script is self-contained and doesn't
# require the caller to pre-configure access manually.
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

echo "    Waiting 60s for RBAC propagation..."
sleep 60

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
# Step 6: Deploy the hosted agent from the pushed image
#
# The management-plane CLI command (az cognitiveservices agent create) creates
# an agent record and then calls a separate "start" operation that returns 404
# for hosted (container) agents.  The correct path is the Foundry data plane:
#
#   POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview
#
# This is exactly what `azd up` does via the azure.ai.agents extension.  The
# runtime auto-starts the container when a version is created — no separate
# start call is required.
#
# Key differences from the management-plane approach:
#   - Auth scope:  https://ai.azure.com/.default   (not cognitiveservices)
#   - No --show-logs: container logs are available in the Foundry portal
#   - metadata.enableVnextExperience=true is required by the server-side API
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Deploying hosted agent via Foundry data plane..."
AGENT_REQUEST_BODY=$(python3 - <<EOF
import json
body = {
  "metadata": {"enableVnextExperience": "true"},
  "definition": {
    "kind": "hosted",
    "container_protocol_versions": [{"protocol": "responses", "version": "1.0.0"}],
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

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Grant Foundry User to the agent version's instance identity
#
# Foundry Agent Service provisions a dedicated per-version managed identity
# (instance_identity) for each hosted agent version. The container
# authenticates as this identity — NOT the project managed identity — when
# making model calls. This identity is only known after the version is created,
# so the role must be granted here rather than in the infrastructure step.
#
# Role: Foundry User (53ca6127) on the AI account
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Granting Foundry User (53ca6127) to agent version instance identity..."
INSTANCE_PRINCIPAL=$(echo "${AGENT_VERSION_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['instance_identity']['principal_id'])")
SUBID=$(az account show --query id -o tsv)
ACCOUNT_RESOURCE_ID=$(az resource list \
  --name "${AI_ACCOUNT_NAME}" \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[0].id" -o tsv)
ROLE_FOUNDRY_USER="53ca6127-db72-4b80-b1b0-d745d6d5456d"  # Foundry User

az role assignment create \
  --role "${ROLE_FOUNDRY_USER}" \
  --assignee-object-id "${INSTANCE_PRINCIPAL}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${ACCOUNT_RESOURCE_ID}" \
  --output none 2>/dev/null || echo "    Role already assigned."

echo "    Waiting 30s for RBAC propagation..."
sleep 30
echo "    Agent name    : ${AGENT_NAME}"
echo "    Agent version : ${AGENT_VERSION}"
echo "    Portal URL    : https://ai.azure.com/"
echo ""
echo "    Open the Foundry portal, navigate to project '${PROJECT_NAME}', and"
echo "    select Agents to test your agent."
