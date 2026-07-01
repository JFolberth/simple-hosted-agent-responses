#!/usr/bin/env bash
# deploy-terraform.sh — deploy simple-hosted-agent using Terraform (azapi)
#
# Prerequisites:
#   - az login (or service principal auth already configured)
#   - terraform >= 1.9 in PATH
#   - Docker daemon running locally (only required when IMAGE_BASED_AGENT=true)
#   - git, curl, python3 (always)
#
# Usage:
#   First deploy:                    ./deployment/deploy-terraform.sh
#   Code change:                     ./deployment/deploy-terraform.sh --skip-infra
#   Only image-based agent:          ./deployment/deploy-terraform.sh --no-source-code-agent
#   Only source-code-based agent:    ./deployment/deploy-terraform.sh --no-image-agent
#   Skip RBAC grant + 120s wait:     ./deployment/deploy-terraform.sh --skip-rbac
#   Skip post-deploy smoke tests:    ./deployment/deploy-terraform.sh --no-smoke-test
#   Skip agent evaluation gate:      ./deployment/deploy-terraform.sh --no-eval
#
# Environment variables (override defaults; CLI flags override env):
#   IMAGE_BASED_AGENT=true|false           default: true
#   SOURCE_CODE_BASED_AGENT=true|false     default: true
#   SKIP_RBAC=true|false                   default: false
#   SMOKE_TEST=true|false                  default: true
#   EVAL=true|false                        default: true

set -euo pipefail

# Resolve the repo root regardless of the caller's working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration — edit these to match your environment
# ─────────────────────────────────────────────────────────────────────────────
AGENT_NAME="agent-framework-agent-basic-responses-tf"
AGENT_SOURCE_DIR="${REPO_ROOT}/src/agent-framework/responses/basic"
AGENT_SOURCE_GIT_PATH="src/agent-framework/responses/basic"
IMAGE_NAME="agent-framework-agent-basic-responses"
TF_DIR="${REPO_ROOT}/infra/terraform"

# Feature flags — both agents are deployed by default. Override via env or CLI.
# The source-code agent is registered as "${AGENT_NAME}-src" to match the
# convention used by ci-cd.yml so both agents can co-exist in one project.
IMAGE_BASED_AGENT="${IMAGE_BASED_AGENT:-true}"
SOURCE_CODE_BASED_AGENT="${SOURCE_CODE_BASED_AGENT:-true}"
SOURCE_CODE_AGENT_NAME="${AGENT_NAME}-src"

# Source-code deployment tunables (mirror update-agent-source-code/action.yml defaults)
SOURCE_CODE_CPU="0.25"
SOURCE_CODE_MEMORY="0.5Gi"
SOURCE_CODE_RUNTIME="python_3_13"
SOURCE_CODE_ENTRY_POINT='["python", "main.py"]'
SOURCE_CODE_MAX_POLLING_SECONDS=600

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
SKIP_INFRA=false
SKIP_RBAC="${SKIP_RBAC:-false}"
SMOKE_TEST="${SMOKE_TEST:-true}"
EVAL="${EVAL:-true}"
for arg in "$@"; do
  case $arg in
    --skip-infra) SKIP_INFRA=true ;;
    --skip-rbac) SKIP_RBAC=true ;;
    --no-image-agent) IMAGE_BASED_AGENT=false ;;
    --no-source-code-agent) SOURCE_CODE_BASED_AGENT=false ;;
    --no-smoke-test) SMOKE_TEST=false ;;
    --no-eval) EVAL=false ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [ "$IMAGE_BASED_AGENT" != true ] && [ "$SOURCE_CODE_BASED_AGENT" != true ]; then
  echo "ERROR: Both IMAGE_BASED_AGENT and SOURCE_CODE_BASED_AGENT are false. Nothing to deploy." >&2
  exit 1
fi

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
if [ "$SKIP_RBAC" = true ]; then
  echo "    Skipping (SKIP_RBAC=true / --skip-rbac)."
else
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
fi

# Acquire a Foundry data-plane token once — reused by both agent deployments.
FOUNDRY_TOKEN=$(az account get-access-token --resource "https://ai.azure.com/" --query accessToken -o tsv)

if [ "$IMAGE_BASED_AGENT" = true ]; then
  # ───────────────────────────────────────────────────────────────────────────
  # Step 4: Authenticate Docker to ACR
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Authenticating to ACR..."
  az acr login --name "${ACR_NAME}"

  # ───────────────────────────────────────────────────────────────────────────
  # Step 5: Build and push the container image
  # ───────────────────────────────────────────────────────────────────────────
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

  # ───────────────────────────────────────────────────────────────────────────
  # Step 6: Deploy the image-based hosted agent via Foundry data plane
  #
  #   POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview
  #
  # Auth scope: https://ai.azure.com/.default — NOT cognitiveservices.azure.com.
  # The runtime auto-starts the container; no separate start call is needed.
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Deploying image-based hosted agent via Foundry data plane..."
  AGENT_REQUEST_BODY=$(python3 - <<EOF
import json
body = {
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

  AGENT_VERSION_RESPONSE=$(curl -s -f -X POST \
    "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=2025-11-15-preview" \
    -H "Authorization: Bearer ${FOUNDRY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${AGENT_REQUEST_BODY}")

  AGENT_VERSION=$(echo "${AGENT_VERSION_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")

  echo "    Image agent name    : ${AGENT_NAME}"
  echo "    Image agent version : ${AGENT_VERSION}"
else
  echo "==> Skipping image-based agent deployment (IMAGE_BASED_AGENT=false)."
fi

if [ "$SOURCE_CODE_BASED_AGENT" = true ]; then
  # ───────────────────────────────────────────────────────────────────────────
  # Step 7: Deploy the source-code-based hosted agent
  #
  # Source-code agents skip the local Docker build — Foundry builds the
  # container remotely ("dependency_resolution: remote_build") from a zip of
  # the agent source. The request is multipart instead of JSON, but uses the
  # same version endpoint shape as the image flow:
  #
  #   POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview
  #
  # We use 'git archive' so the zip contains exactly the tracked files in
  # ${AGENT_SOURCE_GIT_PATH} — same approach as the build.yml CI job, keeping
  # local and CI artifacts byte-identical for a given commit.
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Deploying source-code-based hosted agent via Foundry data plane..."
  SOURCE_CODE_TMPDIR=$(mktemp -d)
  trap 'rm -rf "${SOURCE_CODE_TMPDIR}"' EXIT
  SOURCE_CODE_ZIP="${SOURCE_CODE_TMPDIR}/source-code.zip"
  SOURCE_CODE_METADATA="${SOURCE_CODE_TMPDIR}/metadata.json"

  (cd "${REPO_ROOT}" && git archive --format=zip --output="${SOURCE_CODE_ZIP}" "HEAD:${AGENT_SOURCE_GIT_PATH}")

  SOURCE_CODE_SHA256=$(sha256sum "${SOURCE_CODE_ZIP}" | awk '{print $1}')
  echo "    Zip size  : $(wc -c < "${SOURCE_CODE_ZIP}") bytes"
  echo "    Zip sha256: ${SOURCE_CODE_SHA256}"

  # NOTE: the source-code endpoint requires `protocol_versions`, NOT
  # `container_protocol_versions` (the image endpoint requires the latter).
  # The server rejects the wrong field name with HTTP 400.
  python3 - <<EOF > "${SOURCE_CODE_METADATA}"
import json
body = {
  "definition": {
    "kind": "hosted",
    "protocol_versions": [{"protocol": "responses", "version": "1.0.0"}],
    "cpu": "${SOURCE_CODE_CPU}",
    "memory": "${SOURCE_CODE_MEMORY}",
    "environment_variables": {
      "AZURE_AI_MODEL_DEPLOYMENT_NAME": "${MODEL_DEPLOYMENT_NAME}"
    },
    "code_configuration": {
      "runtime": "${SOURCE_CODE_RUNTIME}",
      "entry_point": ${SOURCE_CODE_ENTRY_POINT},
      "dependency_resolution": "remote_build"
    }
  }
}
print(json.dumps(body))
EOF

  # POST /agents/{name}/versions auto-creates the agent if it doesn't exist
  # and adds a new version if it does. We use -w to capture the HTTP status
  # without `-f` so the server's error body is still printed on failure.
  SOURCE_CODE_RESPONSE=$(curl -sS -X POST \
    "${PROJECT_ENDPOINT}/agents/${SOURCE_CODE_AGENT_NAME}/versions?api-version=2025-11-15-preview" \
    -H "Authorization: Bearer ${FOUNDRY_TOKEN}" \
    -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview" \
    -H "x-ms-agent-name: ${SOURCE_CODE_AGENT_NAME}" \
    -H "x-ms-code-zip-sha256: ${SOURCE_CODE_SHA256}" \
    -F "metadata=@${SOURCE_CODE_METADATA};type=application/json" \
    -F "code=@${SOURCE_CODE_ZIP};type=application/zip" \
    -w $'\n__HTTP_STATUS__%{http_code}')
  SOURCE_CODE_HTTP=$(echo "${SOURCE_CODE_RESPONSE}" | sed -n 's/^__HTTP_STATUS__//p')
  SOURCE_CODE_BODY=$(echo "${SOURCE_CODE_RESPONSE}" | sed '/^__HTTP_STATUS__/d')
  if [ "${SOURCE_CODE_HTTP}" -lt 200 ] || [ "${SOURCE_CODE_HTTP}" -ge 300 ]; then
    echo "ERROR: Source-code agent POST returned HTTP ${SOURCE_CODE_HTTP}" >&2
    echo "${SOURCE_CODE_BODY}" >&2
    exit 1
  fi

  SOURCE_CODE_VERSION=$(echo "${SOURCE_CODE_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")
  echo "    Source-code agent name    : ${SOURCE_CODE_AGENT_NAME}"
  echo "    Source-code agent version : ${SOURCE_CODE_VERSION}"

  # Poll until the remote build finishes. The image-based flow returns active
  # immediately because the image is already pushed; the source-code flow has
  # to build the container on the server, so we wait for status=active.
  echo "    Polling for build completion (timeout ${SOURCE_CODE_MAX_POLLING_SECONDS}s)..."
  SOURCE_CODE_DEADLINE=$(( $(date +%s) + SOURCE_CODE_MAX_POLLING_SECONDS ))
  while :; do
    SOURCE_CODE_STATUS_BODY=$(curl -s -f \
      "${PROJECT_ENDPOINT}/agents/${SOURCE_CODE_AGENT_NAME}/versions/${SOURCE_CODE_VERSION}?api-version=2025-11-15-preview" \
      -H "Authorization: Bearer ${FOUNDRY_TOKEN}")
    SOURCE_CODE_STATUS=$(echo "${SOURCE_CODE_STATUS_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
    echo "      status=${SOURCE_CODE_STATUS}"
    case "${SOURCE_CODE_STATUS}" in
      active) break ;;
      failed)
        echo "ERROR: Source-code agent version build failed." >&2
        echo "${SOURCE_CODE_STATUS_BODY}" >&2
        exit 1 ;;
    esac
    if [ "$(date +%s)" -ge "${SOURCE_CODE_DEADLINE}" ]; then
      echo "ERROR: Source-code agent build did not become active within ${SOURCE_CODE_MAX_POLLING_SECONDS}s." >&2
      exit 1
    fi
    sleep 10
  done
else
  echo "==> Skipping source-code-based agent deployment (SOURCE_CODE_BASED_AGENT=false)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Smoke tests — POST to each deployed agent's Responses endpoint and
# assert the expected behaviours from deployment/smoke-tests.json.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Running smoke tests..."
if [ "$SMOKE_TEST" != true ]; then
  echo "    Skipping (SMOKE_TEST=false / --no-smoke-test)."
else
  if [ "$SKIP_RBAC" = true ]; then
    echo "    WARNING: --skip-rbac was set; smoke tests may 404 without Foundry Project Manager."
  fi
  SMOKE_ARGS=(--project-endpoint "${PROJECT_ENDPOINT}")
  if [ "$IMAGE_BASED_AGENT" = true ]; then
    SMOKE_ARGS+=(--agent-name "${AGENT_NAME}")
  fi
  if [ "$SOURCE_CODE_BASED_AGENT" = true ]; then
    SMOKE_ARGS+=(--agent-name "${SOURCE_CODE_AGENT_NAME}")
  fi
  FOUNDRY_TOKEN="${FOUNDRY_TOKEN}" python3 "${SCRIPT_DIR}/smoke-tests.py" "${SMOKE_ARGS[@]}"
fi

# ──────────────────────────────────────────────────────────────────────────
# Step 9: Agent evaluation gate
#
# Runs microsoft/ai-agent-evals against the agent version we just deployed,
# comparing to the previous version (if any) via statistical-significance
# regression detection. Uses the same env-var contract as the GH composite
# action so local and CI behaviour stay aligned.
#
# The GH Action installs its own repo as a Python package and then runs
# action.py from that checkout (see https://github.com/microsoft/ai-agent-evals/blob/v3-beta/action.yml).
# We mirror it: clone at v3-beta into a venv and invoke `python action.py`.
# A venv avoids Debian's PEP 668 restriction on system-Python pip installs.
#
# Cost: ~$0.20-$1.00 per run, ~3-6 minutes. Skippable via EVAL=false / --no-eval.
# ──────────────────────────────────────────────────────────────────────────
echo "==> Running agent evaluation gate..."
if [ "$EVAL" != true ]; then
  echo "    Skipping (EVAL=false / --no-eval)."
else
  # Evaluate every deployed agent so consumers get consistent gating whether
  # they run image-only, source-only, or both. Cost scales linearly: budget
  # ~$0.20-$1.00 per agent per run.
  EVAL_TARGETS=()
  if [ "$IMAGE_BASED_AGENT" = true ]; then
    EVAL_TARGETS+=("${AGENT_NAME}:${AGENT_VERSION}")
  fi
  if [ "$SOURCE_CODE_BASED_AGENT" = true ]; then
    EVAL_TARGETS+=("${SOURCE_CODE_AGENT_NAME}:${SOURCE_CODE_VERSION}")
  fi

  # NOTE: on failure we intentionally leave EVAL_WORKDIR on disk for debugging;
  # `set -e` will exit the script before cleanup.
  EVAL_WORKDIR=$(mktemp -d)
  echo "    Cloning microsoft/ai-agent-evals@v3-beta into ${EVAL_WORKDIR}..."
  git clone --quiet --depth 1 --branch v3-beta \
    https://github.com/microsoft/ai-agent-evals.git "${EVAL_WORKDIR}/ai-agent-evals"
  python3 -m venv "${EVAL_WORKDIR}/venv"
  "${EVAL_WORKDIR}/venv/bin/pip" install --quiet --upgrade pip
  "${EVAL_WORKDIR}/venv/bin/pip" install --quiet "${EVAL_WORKDIR}/ai-agent-evals"

  for target in "${EVAL_TARGETS[@]}"; do
    EVAL_AGENT_NAME="${target%%:*}"
    EVAL_AGENT_VERSION="${target##*:}"
    echo ""
    echo "--> Evaluating ${EVAL_AGENT_NAME}:${EVAL_AGENT_VERSION}"

    # Baseline = highest existing version number less than the one we just
    # deployed. More robust than depending on an `is_default`-style flag whose
    # name is not stable across the preview API. Empty on first deploy.
    EVAL_VERSIONS_JSON=$(curl -s -f \
      "${PROJECT_ENDPOINT}/agents/${EVAL_AGENT_NAME}/versions?api-version=2025-11-15-preview" \
      -H "Authorization: Bearer ${FOUNDRY_TOKEN}")
    EVAL_PREV_VERSION=$(echo "${EVAL_VERSIONS_JSON}" | EVAL_AGENT_VERSION="${EVAL_AGENT_VERSION}" python3 -c "
import json, os, sys
payload = json.load(sys.stdin)
data = payload.get('data') or payload.get('value') or []
new = os.environ['EVAL_AGENT_VERSION']
others = [v['version'] for v in data if v.get('version') != new]
try:
    others.sort(key=lambda x: int(x))
except (TypeError, ValueError):
    others.sort()
print(others[-1] if others else '')
")

    if [ -n "${EVAL_PREV_VERSION}" ]; then
      echo "    Baseline version: ${EVAL_PREV_VERSION}"
      EVAL_AGENT_IDS="${EVAL_AGENT_NAME}:${EVAL_PREV_VERSION},${EVAL_AGENT_NAME}:${EVAL_AGENT_VERSION}"
      EVAL_BASELINE_AGENT_ID="${EVAL_AGENT_NAME}:${EVAL_PREV_VERSION}"
    else
      echo "    No previous version — evaluating new version only (no baseline)."
      EVAL_AGENT_IDS="${EVAL_AGENT_NAME}:${EVAL_AGENT_VERSION}"
      EVAL_BASELINE_AGENT_ID=""
    fi

    AZURE_AI_PROJECT_ENDPOINT="${PROJECT_ENDPOINT}" \
    DEPLOYMENT_NAME="${MODEL_DEPLOYMENT_NAME}" \
    DATA_PATH="${REPO_ROOT}/evals/promotion-gate.json" \
    AGENT_IDS="${EVAL_AGENT_IDS}" \
    BASELINE_AGENT_ID="${EVAL_BASELINE_AGENT_ID}" \
      "${EVAL_WORKDIR}/venv/bin/python" "${EVAL_WORKDIR}/ai-agent-evals/action.py"
  done

  rm -rf "${EVAL_WORKDIR}"
  echo "    Evaluation complete."
fi

echo ""
echo "    Portal URL    : https://ai.azure.com/"
echo "    Open the Foundry portal, navigate to project '${PROJECT_NAME}', and"
echo "    select Agents to test your agent(s)."
