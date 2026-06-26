#!/usr/bin/env bash
# run-smoke-tests.sh — azd postdeploy hook
#
# Runs the post-deploy smoke test suite (deployment/smoke-tests.py) against the
# hosted agent that `azd deploy` just created. Equivalent to Step 8 of
# deployment/deploy-bicep.sh and deployment/deploy-terraform.sh.
#
# azd injects all infra outputs as environment variables to hooks, so
# AZURE_AI_PROJECT_ENDPOINT is available without any explicit wiring.
#
# Skip switch:
#   SMOKE_TEST=false           skip the smoke tests entirely
#
# Agent name override:
#   AGENT_NAME=<name>          defaults to the service name in azure.yaml
#                              (agent-framework-agent-basic-responses).

set -euo pipefail

if [ "${SMOKE_TEST:-true}" != "true" ]; then
  echo "==> Skipping smoke tests (SMOKE_TEST=false)."
  exit 0
fi

PROJECT_ENDPOINT="${AZURE_AI_PROJECT_ENDPOINT:?AZURE_AI_PROJECT_ENDPOINT not set — was azd provision successful?}"
AGENT_NAME="${AGENT_NAME:-agent-framework-agent-basic-responses}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/../smoke-tests.py"

echo "==> Running smoke tests against ${AGENT_NAME}..."
python3 "${RUNNER}" \
  --project-endpoint "${PROJECT_ENDPOINT}" \
  --agent-name "${AGENT_NAME}"
