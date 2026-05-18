#!/usr/bin/env bash
# grant-project-manager.sh — azd postprovision hook
#
# Assigns Foundry Project Manager to the deploying principal at project scope.
# The Foundry data plane checks this role before allowing agent version creation
# (POST .../agents/*/versions). The azure.ai.agents azd extension calls this
# endpoint as the logged-in user, so the role must be in place before deploy.
#
# Equivalent to Step 3 of deployment/deploy-bicep.sh and
# deployment/deploy-terraform.sh.

set -euo pipefail

ROLE_FOUNDRY_PM="eadc314b-1a2d-4efa-be10-5d325db5065e"  # Foundry Project Manager
echo "==> Granting Foundry Project Manager (eadc314b) at project scope..."

# azd injects all environment variables (including infra outputs) directly into
# the hook process — use them as-is. :? causes an immediate, visible failure if
# the variable is absent so the error is never silently swallowed.
AI_ACCOUNT_NAME="${AZURE_AI_ACCOUNT_NAME:?AZURE_AI_ACCOUNT_NAME not set — was azd provision successful?}"
PROJECT_NAME="${AZURE_AI_PROJECT_NAME:?AZURE_AI_PROJECT_NAME not set — was azd provision successful?}"

# Resolve the calling principal ID and type.
# az ad signed-in-user works for interactive (az login) sessions.
# For service principal / workload identity, fall back to az ad sp show.
if PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null) && [ -n "$PRINCIPAL_ID" ]; then
  PRINCIPAL_TYPE="User"
else
  CLIENT_ID=$(az account show --query user.name -o tsv 2>/dev/null)
  PRINCIPAL_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)
  PRINCIPAL_TYPE="ServicePrincipal"
fi

# Build the project resource ID from the AI account resource
ACCOUNT_RESOURCE_ID=$(az resource list \
  --name "${AI_ACCOUNT_NAME}" \
  --resource-type "Microsoft.CognitiveServices/accounts" \
  --query "[0].id" -o tsv)
PROJECT_RESOURCE_ID="${ACCOUNT_RESOURCE_ID}/projects/${PROJECT_NAME}"
ROLE_FOUNDRY_PM="eadc314b-1a2d-4efa-be10-5d325db5065e"  # Foundry Project Manager

az role assignment create \
  --role "${ROLE_FOUNDRY_PM}" \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --assignee-principal-type "${PRINCIPAL_TYPE}" \
  --scope "${PROJECT_RESOURCE_ID}" \
  --output none 2>&1 | grep -v "already exists" || true
echo "    Role assigned (or already present) for ${PRINCIPAL_TYPE} ${PRINCIPAL_ID}."

echo "    Waiting 30s for RBAC propagation..."
sleep 30
echo "    Done."
