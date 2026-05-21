# simple-hosted-agent — Copilot Instructions

A minimal reference for deploying a Python AI agent to Azure AI Foundry Hosted Agents using the **Responses protocol**. Infrastructure is available in two flavors — **Bicep** and **Terraform (azapi)** — deployed either with a single shell script or with the **Azure Developer CLI (`azd`)**.

---

## Architecture

| Layer | What it is |
|---|---|
| `src/agent-framework/responses/basic/` | Python agent built with Agent Framework + `ResponsesHostServer` |
| `infra/bicep/modules/foundry.bicep` | AI Services account, model deployments |
| `infra/bicep/modules/foundry-project.bicep` | Foundry project, App Insights connection, Foundry User role for project MI |
| `infra/bicep/modules/acr.bicep` | Container registry, AcrPull for project MI, ACR connection |
| `infra/terraform/modules/foundry/` | Terraform equivalent of `foundry.bicep` — AI account + deployments |
| `infra/terraform/modules/foundry_project/` | Terraform equivalent of `foundry-project.bicep` — project + App Insights + roles |
| `infra/terraform/modules/acr/` | Terraform equivalent of `acr.bicep` — registry + AcrPull + ACR connection |
| `infra/terraform/modules/loganalytics/` | Log Analytics workspace (Terraform) |
| `infra/terraform/modules/applicationinsights/` | Application Insights component (Terraform) |
| `infra/terraform/modules/foundry_project_connection/` | Reusable Terraform module for Foundry project connections |
| `deployment/deploy-bicep.sh` | Single-script deploy (Bicep): infra → image → agent |
| `deployment/deploy-terraform.sh` | Single-script deploy (Terraform): infra → image → agent |
| `deployment/azd-select.sh` | Interactive prompt — copies `azure-bicep.yaml` or `azure-terraform.yaml` to `deployment/azure.yaml` |
| `deployment/azure-bicep.yaml` | azd config for Bicep (`infra.provider: bicep`, points to `deployment/infra-azd/`) |
| `deployment/azure-terraform.yaml` | azd config for Terraform (`infra.provider: terraform`, points to `infra/terraform/`) |
| `deployment/scripts/grant-project-manager.sh` | azd `postprovision` hook — grants Foundry Project Manager to the deploying principal at project scope (equivalent to Step 3 of the deploy scripts) |
| `deployment/infra-azd/main.bicepparam` | azd-compatible Bicep parameter shim — uses `readEnvironmentVariable()` for azd env var injection |

The **Foundry data plane** (`POST {projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview`) is used to create agent versions — NOT `az cognitiveservices agent create`, which calls a broken `containers/default:start` operation.

---

## Build & Deploy

### Shell scripts

```bash
# Bicep
./deployment/deploy-bicep.sh             # Full deploy (infra + image + agent)
./deployment/deploy-bicep.sh --skip-infra  # Code change only

# Terraform
./deployment/deploy-terraform.sh             # Full deploy
./deployment/deploy-terraform.sh --skip-infra  # Code change only
```

Prerequisites: `az login`, Docker daemon running. Terraform also requires `terraform >= 1.9` in PATH.

> **Sync rule:** `deploy-bicep.sh` and `deploy-terraform.sh` share the same post-infra flow (Steps 2–6: read outputs → assign Project Manager → Docker login → build/push image → create agent version). Only Step 1 (infra provisioning) differs between them. Any change made to the shared steps in one script **must be reconciled in the other**.

### azd

```bash
# 1. Select Bicep or Terraform — writes deployment/azure.yaml (gitignored)
./deployment/azd-select.sh

# 2. Run from deployment/ — azd reads azure.yaml from CWD
cd deployment
azd auth login                                        # required — azd auth is separate from az login
azd env new <env-name>
azd env set AZURE_LOCATION <region>
azd env set AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"  # required by azure.ai.agents extension
azd env set AZURE_AI_DEPLOYMENTS_LOCATION <region>   # Bicep only
azd env set AI_DEPLOYMENTS_LOCATION <region>          # Terraform only → TF_VAR_ai_deployments_location
azd up

# Code-only changes:
azd deploy
```

Prerequisites: `az login`, `azd auth login`, `azd` CLI, `azure.ai.agents` extension (`azd extension install azure.ai.agents`). The dev container installs all of these automatically. `azd auth login` is required separately from `az login` — without it azd cannot populate `AZURE_TENANT_ID` into hook and extension processes, causing the `azure.ai.agents` extension to fail with `AZURE_TENANT_ID is not set in the environment`. Setting `AZURE_TENANT_ID` explicitly via `azd env set AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"` is the reliable workaround.

The `postprovision` hook (`deployment/scripts/grant-project-manager.sh`) grants **Foundry Project Manager** (`eadc314b`) to the deploying principal at project scope after infrastructure is provisioned — this is equivalent to Step 3 of the deploy scripts and is required before the `azure.ai.agents` extension can call `POST .../agents/*/versions`.

---

## Key Conventions

### RBAC — always use GUIDs for role assignments
Role display names (e.g. "Azure AI Project Manager", "Azure AI User") have been renamed in the past without changing GUIDs. All `az role assignment create` calls in deploy scripts and hooks **must use the GUID**, not the display name, to be rename-proof.

### RBAC — roles required at infrastructure time
The project managed identity needs **this one** role provisioned by IaC:

| Role | GUID | Scope | Grants |
|---|---|---|-|
| AcrPull | `7f951dda` | Container Registry | Image pull at container start |

### RBAC — role granted at deploy time (Step 3 — before agent version creation)
The deploying principal needs **Foundry Project Manager** at project scope so the Foundry data plane accepts the agent version creation call.

| Role | GUID | Scope | When |
|---|---|---|---|
| Foundry Project Manager | `eadc314b` | Foundry project | Step 3 of deploy script / `postprovision` hook |

### Bicep scope
`infra/bicep/main.bicep` is `targetScope = 'subscription'`; all modules are `targetScope = 'resourceGroup'`. Modules are called with `scope: rg`. Role assignment GUIDs are always deterministic: `guid(resourceGroup().id, <discriminator>, <roleGuid>)`.

### Terraform provider and state
Terraform uses the **`Azure/azapi`** provider (`~> 2.0`) with `hashicorp/random` (`~> 3.0`). `required_version = ">= 1.9"`. State is local (`backend "local" {}`) — suitable for development; switch to a remote backend for production. Child modules each declare their own `versions.tf` requiring `Azure/azapi` to avoid the `hashicorp/azapi` source ambiguity.

`schema_validation_enabled = false` is required on all resources using API versions `2026-03-01` and `2025-10-01-preview` — these are not yet in the provider's bundled schema.

`count` expressions in Terraform child modules must be plan-time-known. Use explicit `bool` input variables (e.g. `enable_app_insights`) rather than deriving count from resource output strings.

### Docker platform
Always build with `--platform linux/amd64`. Foundry runtime does not support arm64; building on Apple Silicon without this flag produces a platform mismatch error in the portal.

### Foundry data plane call
Required fields in the request body:
```json
{
  "metadata": {"enableVnextExperience": "true"},
  "definition": {
    "kind": "hosted",
    "container_protocol_versions": [{"protocol": "responses", "version": "1.0.0"}],
    "image": "<acr>/<name>:<tag>",
    "cpu": "0.25",
    "memory": "0.5Gi",
    "environment_variables": {"AZURE_AI_MODEL_DEPLOYMENT_NAME": "<model>"}
  }
}
```
`metadata.enableVnextExperience: "true"` is a hard server-side requirement — omitting it causes a silent failure. Auth scope: `https://ai.azure.com/` (not `cognitiveservices.azure.com`). Use `az account get-access-token --resource "https://ai.azure.com/"` + `curl` for the POST — `az rest --resource "https://ai.azure.com/"` does not reliably acquire the correct audience token for this endpoint.

### Responses protocol
The agent uses `ResponsesHostServer` on port 8088. The `@app.response_handler` receives the request; conversation history is managed automatically by the platform via `previous_response_id`. There is no in-memory session store required.

### Environment variables
The Foundry runtime injects these automatically at container start — do not set them manually in agent versions:
- `FOUNDRY_PROJECT_ENDPOINT`
- `APPLICATIONINSIGHTS_CONNECTION_STRING`

`AZURE_AI_MODEL_DEPLOYMENT_NAME` is NOT injected automatically — it must be set explicitly in the agent version request body and is present in `agent.yaml`.

---

## Infrastructure patterns to follow

### Bicep
- All resource names use `resourceToken = uniqueString(subscription().id, resourceGroup().id, location)` — never hardcode names.
- ACR connection uses `authType: ManagedIdentity`. No stored credentials anywhere.
- Model deployments run with `@batchSize(1)` to avoid capacity conflicts.
- New Bicep modules belong in `infra/bicep/modules/`; always add them to `infra/bicep/main.bicep` with a section comment block.
- The azd-compatible parameter shim is `deployment/infra-azd/main.bicepparam`. It uses `readEnvironmentVariable()` and references `infra/bicep/main.bicep` via `using '../../infra/bicep/main.bicep'`. Do not modify `infra/bicep/main.bicepparam` for azd use — that file is for the shell-script workflow.

### Terraform
- All resource names use `resource_token = lower(random_id.resource_token.hex)` keyed on `subscription_id × resource_group_name × ai_deployments_location` — mirrors Bicep's `uniqueString`.
- ACR connection uses `auth_type = "ManagedIdentity"`. No stored credentials anywhere.
- New Terraform modules belong in `infra/terraform/modules/`; always add them to `infra/terraform/main.tf` with a section comment block and add `versions.tf` declaring `Azure/azapi ~> 2.0`.
- Role assignment resource names use `uuidv5("url", "${scope_id}/${discriminator}/${role_short_name}")` for determinism.
- Configure `tfvars` in `infra/terraform/terraform.tfvars` (gitignored for sensitive values).

### GitHub Actions — pinned versions
Always use these exact major versions in workflow files. Do not downgrade.

| Action | Version | Notes |
|---|---|---|
| `actions/checkout` | `v6` | |
| `actions/upload-artifact` | `v7` | |
| `actions/download-artifact` | `v8` | |
| `azure/login` | `v3` | Natively targets Node 24; `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` not needed |
| `hashicorp/setup-terraform` | `v4` | |
| `terraform-linters/setup-tflint` | `v6` | |

Do not add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` — all actions above already target Node 24 natively.

### GitHub Actions — DRY pattern
Apply the **Don't Repeat Yourself** principle to GitHub Actions. When the same logic appears in more than one workflow or job, extract it:

| Duplicated unit | Solution | Location |
|---|---|---|
| Steps (within or across jobs) | Composite action | `.github/actions/<name>/action.yml` |
| A whole job or multi-job sequence | Reusable workflow (`workflow_call`) | `.github/workflows/<name>.yml` |

**Composite action conventions:**
- Create a dedicated folder: `.github/actions/<name>/action.yml`.
- Pass all inputs via `env:` vars inside `run:` steps — never interpolate `${{ inputs.* }}` directly into shell strings (injection risk).
- The calling job handles Azure CLI authentication (`azure/login@v3`) before invoking the action; the action assumes an authenticated session. This keeps actions auth-strategy-agnostic.
- Existing composite actions in this repo: `update-agent` (Foundry data plane POST), `push-image` (ACR image push).

**Reusable workflow conventions:**
- Declare `on: workflow_call:` only (no `push:` / `pull_request:` triggers) for workflows that are always called from another workflow.
- Pass secrets explicitly or via `secrets: inherit` from the calling workflow.
- Existing reusable workflows: `build.yml`, `deploy.yml`, `deploy-bicep.yml`, `deploy-terraform.yml`.

- Do not use `az cognitiveservices agent create` — it calls a broken start operation for hosted agents.
- Do not build Docker images without `--platform linux/amd64` on Apple Silicon.
- Do not omit `metadata.enableVnextExperience: "true"` in agent version payloads.
- Do not add the `cognitiveservices` Azure CLI extension as a prerequisite — it is not used.
- Do not use `azurerm` or `hashicorp/azapi` as the Terraform provider source — use `Azure/azapi`.
- Do not omit `schema_validation_enabled = false` on `azapi_resource` blocks using `@2026-03-01` or `@2025-10-01-preview` API versions.
- Do not derive Terraform `count` values from resource attributes that are unknown at plan time — use explicit bool input variables instead.
- Do not place an `azure.yaml` at the repo root — azd must be run from `deployment/` where it finds the generated `azure.yaml`.
- Do not commit `deployment/azure.yaml` — it is gitignored and generated locally by `deployment/azd-select.sh`.
- Do not modify `infra/` or `src/` to accommodate azd — the `deployment/infra-azd/` shim and `deployment/azure-*.yaml` files are the only azd-specific additions.
- Do not change the shared post-infra steps (Steps 2–6: read outputs, RBAC, Docker login, build/push image, create agent version) in `deploy-bicep.sh` without making the equivalent change in `deploy-terraform.sh`, and vice versa. Only Step 1 (infrastructure provisioning) intentionally differs between the two scripts.
- Do not duplicate steps across workflows — extract shared steps to a composite action in `.github/actions/`. See the DRY pattern section above.
