#!/usr/bin/env bash
# run-smoke-tests.sh — azd postdeploy hook
#
# Runs the post-deploy smoke test suite against the hosted agent that
# `azd deploy` just created. Equivalent to Step 8 of deployment/deploy-bicep.sh
# and deployment/deploy-terraform.sh.
#
# The runner lives in JFolberth/ai-smoketest (pinned to a tag for immutability);
# we curl it into a tempfile so local behaviour tracks the marketplace action
# consumed in CI without keeping a duplicate copy in this repo. The catalog
# stays here at ../smoke-tests.json.
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
#
# Runner-ref override:
#   SMOKETEST_RUNNER_REF=<ref> defaults to v1.0. Any git ref valid on
#                              JFolberth/ai-smoketest (tag, branch, or SHA).

set -euo pipefail

if [ "${SMOKE_TEST:-true}" != "true" ]; then
  echo "==> Skipping smoke tests (SMOKE_TEST=false)."
  exit 0
fi

PROJECT_ENDPOINT="${AZURE_AI_PROJECT_ENDPOINT:?AZURE_AI_PROJECT_ENDPOINT not set — was azd provision successful?}"
AGENT_NAME="${AGENT_NAME:-agent-framework-agent-basic-responses}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_FILE="${SCRIPT_DIR}/../smoke-tests.json"

SMOKETEST_RUNNER_REF="${SMOKETEST_RUNNER_REF:-v1.0}"
SMOKETEST_RUNNER_URL="https://raw.githubusercontent.com/JFolberth/ai-smoketest/${SMOKETEST_RUNNER_REF}/scripts/smoke-tests.py"

SMOKETEST_RUNNER="$(mktemp -t smoke-tests.XXXXXX.py)"
trap 'rm -f "$SMOKETEST_RUNNER"' EXIT

echo "==> Fetching smoke-test runner from JFolberth/ai-smoketest@${SMOKETEST_RUNNER_REF}..."
curl -fsSL "${SMOKETEST_RUNNER_URL}" -o "${SMOKETEST_RUNNER}"

echo "==> Running smoke tests against ${AGENT_NAME}..."
python3 "${SMOKETEST_RUNNER}" \
  --project-endpoint "${PROJECT_ENDPOINT}" \
  --agent-name "${AGENT_NAME}" \
  --tests-file "${TESTS_FILE}"
