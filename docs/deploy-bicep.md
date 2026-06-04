# Deploying with Bicep

This guide covers local deployment of the simple-hosted-agent using Bicep infrastructure via the shell script and the Azure Developer CLI (`azd`). For CI/CD automation, see [GitHub Actions](./github-actions.md).

---

## Prerequisites

| Tool | Notes |
|---|---|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | Required for all paths. Run `az login` before deploying. |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Required when deploying the image-based agent. Not required for source-code-only deploys. |
| Bicep CLI | Installed automatically by the deploy script (`az bicep install`). No manual install needed. |

All prerequisites are pre-installed in the dev container.

---

## Configuration

Edit `infra/bicep/main.bicepparam` to match your environment before deploying:

```bicep
param environmentName       = 'simple-hosted-agent-bicep' // Used in resource naming
param resourceGroupName     = 'rg-simple-hosted-agent-bicep' // Resource group to create
param location              = 'swedencentral'              // Region for the resource group
param aiDeploymentsLocation = 'swedencentral'              // Region for model deployments (may differ)
param aiFoundryProjectName  = 'ai-project'                 // Foundry project name
```

`location` and `aiDeploymentsLocation` must be regions that support Foundry hosted agents. See the [availability table](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#limits-pricing-and-availability-preview).

`aiDeploymentsLocation` can differ from `location` — useful when your primary region supports the hosted agent runtime but not the specific model you need.

Also edit the configuration block at the top of `deployment/deploy-bicep.sh` to match:

```bash
ENVIRONMENT_NAME="simple-hosted-agent-bicep"        # Set to the same value as environmentName in main.bicepparam
LOCATION="swedencentral"                            # Set to the same value as location in main.bicepparam
AGENT_NAME="agent-framework-agent-basic-responses"  # Name for the hosted agent in Foundry
IMAGE_NAME="agent-framework-agent-basic-responses"  # Container image name (without registry/tag)
```

---

## Shell Script

`deployment/deploy-bicep.sh` runs the full deployment from your local machine in seven steps. By default, it deploys both the image-based agent and the source-code agent.

### Usage

```bash
# Full deploy — infrastructure + image-based agent + source-code agent
./deployment/deploy-bicep.sh

# Code-only update — skip infrastructure, update both agents
./deployment/deploy-bicep.sh --skip-infra

# Only the image-based agent
./deployment/deploy-bicep.sh --no-source-code-agent

# Only the source-code agent — skips Docker entirely
./deployment/deploy-bicep.sh --no-image-agent

# Skip the Foundry Project Manager grant and 120s RBAC wait
./deployment/deploy-bicep.sh --skip-rbac
```

> Run from anywhere in the repo. The script resolves the repo root from its own location.

### Flags and environment variables

| Flag | Environment variable | Default | Effect |
|---|---|---|---|
| `--no-image-agent` | `IMAGE_BASED_AGENT=false` | `true` | Skip ACR login, Docker build/push, and image-based agent version creation |
| `--no-source-code-agent` | `SOURCE_CODE_BASED_AGENT=false` | `true` | Skip source-code zip creation, multipart upload, and remote-build polling |
| `--skip-rbac` | `SKIP_RBAC=true` | `false` | Skip the Foundry Project Manager role assignment and the 120-second RBAC propagation wait |

CLI flags override the default values. The script exits before deployment if both agent modes resolve to `false`.

### What each step does

**Step 1 — Deploy infrastructure** (`az deployment sub create`)

Deploys `infra/bicep/main.bicep` at subscription scope using values from `main.bicepparam`. The deployment name is `deploy-{ENVIRONMENT_NAME}`. Bicep is idempotent — re-running reconciles drift without recreating unchanged resources.

**Step 2 — Read deployment outputs**

Retrieves outputs from the completed deployment via `az deployment sub show`: project endpoint URL, ACR login server, and model deployment name. These values are used in every subsequent step. See [IaC outputs reference](./iac-outputs.md) for the full list and which step consumes each.

**Step 3 — Grant Foundry Project Manager**

Assigns the **Foundry Project Manager** role (`eadc314b-1a2d-4efa-be10-5d325db5065e`) to the signed-in user at the Foundry project resource scope. This role grants `Microsoft.CognitiveServices/accounts/AIServices/agents/write`, which is required to call the Foundry data plane. The assignment is idempotent. A 120-second wait follows for RBAC propagation — this is a known platform requirement.

> The Foundry data plane evaluates this permission at **project scope** specifically. Subscription or resource group scoped assignments are not reliably inherited. See [Hosted agent permissions — agent creation](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions#agent-creation).

If you already granted the role and are iterating locally, pass `--skip-rbac` or set `SKIP_RBAC=true` to skip the role assignment and wait.

**Step 4 — Authenticate to ACR**

Runs `az acr login` against the project's container registry so Docker can push images.

**Step 5 — Build and push image**

Builds the agent container image from `src/agent-framework/responses/basic/` with `--platform linux/amd64` (required — the Foundry runtime does not support arm64) and pushes it to ACR. The image tag is the short git SHA (`git rev-parse --short HEAD`), or a UTC timestamp if git is unavailable.

**Step 6 — Create image-based agent version**

POSTs to the Foundry data plane to register a new hosted agent version:

```
POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview
```

The request body specifies `kind: hosted`, the container image reference, CPU/memory allocation (`0.25` CPU, `0.5Gi`), the Responses protocol version (`1.0.0`), and the `AZURE_AI_MODEL_DEPLOYMENT_NAME` environment variable. The platform pulls the image and provisions a micro VM automatically.

> **Auth:** The script acquires a token scoped to `https://ai.azure.com/` via `az account get-access-token`. `az rest` is **not** used — it does not reliably acquire the correct audience token for this endpoint.
>
> `metadata.enableVnextExperience: "true"` is a required server-side field. Omitting it causes a silent failure.
>
> `az cognitiveservices agent create` is **not** used — it calls a separate start operation that returns 404 for hosted (container) agents.

**Step 7 — Create source-code agent version**

When `SOURCE_CODE_BASED_AGENT=true`, the script creates a flat zip from `src/agent-framework/responses/basic/` using `git archive`, computes its SHA-256 hash, writes a metadata JSON file, and uploads both parts with a multipart request:

```text
POST {projectEndpoint}/agents/{sourceCodeAgentName}/versions?api-version=2025-11-15-preview
```

The source-code agent name is `${AGENT_NAME}-src`, so it can coexist with the image-based agent in the same project. The `/versions` endpoint auto-creates the agent if it does not exist and creates a new version if it does.

The source-code metadata uses `protocol_versions` and `code_configuration` with `dependency_resolution: remote_build`; Foundry builds the runtime container remotely. After the POST returns, the script polls the new version until it reaches `active`, `failed`, or the timeout (`SOURCE_CODE_MAX_POLLING_SECONDS`, default `600`).

> Source-code deployments use `protocol_versions`. Image-based deployments use `container_protocol_versions`. These field names are not interchangeable.

---

## Azure Developer CLI (azd)

`azd` automates the full deployment — infrastructure provisioning, container image build (via ACR remote build), and agent registration — in a single `azd up` command. No local Docker build required.

### Additional prerequisites

| Tool | Install |
|---|---|
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | `brew tap azure/azd && brew install azd` / [installer](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) |
| `azure.ai.agents` extension | `azd extension install azure.ai.agents` |

Both are pre-installed in the dev container.

### Setup

```bash
# 1. Select Bicep as the IaC provider — writes deployment/azure.yaml (gitignored)
./deployment/azd-select.sh   # choose 1

# 2. All azd commands run from the deployment/ directory
cd deployment

# 3. Authenticate (azd auth is separate from az login — both are required)
azd auth login

# 4. Create a named environment
azd env new <env-name>

# 5. Set required environment variables
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_AI_DEPLOYMENTS_LOCATION swedencentral
azd env set AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"

# 6. Provision infrastructure and deploy the agent
azd up
```

### Code-only updates

```bash
cd deployment
azd deploy
```

### How azd maps to the shell script

| Shell script step | azd equivalent |
|---|---|
| Step 1 — deploy infrastructure | `azd provision` using `deployment/infra-azd/main.bicepparam` → `infra/bicep/main.bicep` |
| Step 3 — grant Foundry Project Manager | `postprovision` hook → `deployment/scripts/grant-project-manager.sh` |
| Step 5 — build and push image | `azure.ai.agents` extension via ACR remote build (no local Docker required) |
| Step 6 — create agent version | `azure.ai.agents` extension via Foundry data plane POST |

### Notes

- `deployment/azure.yaml` is gitignored. It is generated locally by `azd-select.sh` and must not be committed.
- `azd auth login` is required separately from `az login`. Without it, the `azure.ai.agents` extension cannot populate `AZURE_TENANT_ID` into hook processes, causing authentication failures.
- Setting `AZURE_TENANT_ID` explicitly via `az account show` is the reliable workaround and works regardless of azd auth state.
- Model deployments are hardcoded in `deployment/infra-azd/main.bicepparam`. Edit that file to change the model or capacity.

---

## GitHub Actions

For automated CI/CD deployment, see [GitHub Actions CI/CD](./github-actions.md).
