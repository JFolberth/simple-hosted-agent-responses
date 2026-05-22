# IaC Outputs Reference

The Bicep template ([`infra/bicep/main.bicep`](../infra/bicep/main.bicep)) and the Terraform configuration ([`infra/terraform/outputs.tf`](../infra/terraform/outputs.tf)) emit the **same six outputs**. They form the contract between provisioning and every downstream consumer — the shell scripts, `azd` (hooks + `azure.ai.agents` extension), and GitHub Actions.

If you add or remove an output, mirror the change in both IaC stacks and update this file.

---

## Outputs reference

| Output | Example value | Purpose |
|---|---|---|
| `AZURE_AI_ACCOUNT_NAME` | `cog-abc123` | Foundry/AI Services account name. Used for operator logging and to reconstruct the project resource ID in the azd hook. |
| `AZURE_AI_PROJECT_NAME` | `ai-project` | Foundry project name. Surfaced for operator UX and used by the azd hook + `azure.ai.agents` extension. |
| `AZURE_AI_PROJECT_ID` | `/subscriptions/…/projects/ai-project` | Full project resource ID. Used as `--scope` for the `az role assignment create` that grants Foundry Project Manager. |
| `AZURE_AI_PROJECT_ENDPOINT` | `https://ai-project.services.ai.azure.com/api/projects/ai-project` | Base URL for the Foundry data plane (`POST {endpoint}/agents/{name}/versions`). Also injected into the running container as `FOUNDRY_PROJECT_ENDPOINT`. |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | `crabc123.azurecr.io` | ACR login server. Used for `az acr login`, the `docker build`/`push` image tag, and the `image` field in the agent version request body. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | `gpt-4.1-mini` | Model deployment name. Set as `environment_variables.AZURE_AI_MODEL_DEPLOYMENT_NAME` on the agent version. The Foundry runtime does NOT inject this automatically (unlike `FOUNDRY_PROJECT_ENDPOINT`). |

---

## Consumption matrix

| Output | Shell scripts<br/>([deploy-bicep.sh](../deployment/deploy-bicep.sh) / [deploy-terraform.sh](../deployment/deploy-terraform.sh)) | azd<br/>(`azd up`) | GitHub Actions |
|---|---|---|---|
| `AZURE_AI_ACCOUNT_NAME` | Step 2 — echoed for operator visibility | [grant-project-manager.sh](../deployment/scripts/grant-project-manager.sh) — `${AZURE_AI_ACCOUNT_NAME:?…}`; used to reconstruct the project resource ID | — not surfaced |
| `AZURE_AI_PROJECT_NAME` | Step 2 — echoed; final "navigate to project X" message | [grant-project-manager.sh](../deployment/scripts/grant-project-manager.sh) — `${AZURE_AI_PROJECT_NAME:?…}`; also read by `azure.ai.agents` extension for portal links | — not surfaced |
| `AZURE_AI_PROJECT_ID` | **Step 3** — `--scope "${PROJECT_ID}"` for `az role assignment create` | Not used directly — the hook **rebuilds** this from `AI_ACCOUNT_NAME` + `PROJECT_NAME` via `az resource list` | — not surfaced |
| `AZURE_AI_PROJECT_ENDPOINT` | **Step 6** — POST URL for the Foundry data plane | Read by the `azure.ai.agents` extension to call `POST …/agents/*/versions` | [deploy-bicep/action.yml](../.github/actions/deploy-bicep/action.yml) → `project_endpoint` → consumed by [update-agent/action.yml](../.github/actions/update-agent/action.yml) |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | **Steps 4, 5, 6** (`az acr login`, image tag, request body) | Read by `azure.ai.agents` extension to resolve the image reference | [deploy-bicep/action.yml](../.github/actions/deploy-bicep/action.yml) → `acr_endpoint` → consumed by [push-image/action.yml](../.github/actions/push-image/action.yml) and [update-agent/action.yml](../.github/actions/update-agent/action.yml) |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | **Step 6** — `environment_variables` in request body | Passed by `azure.ai.agents` extension into the agent version env vars | [deploy-bicep/action.yml](../.github/actions/deploy-bicep/action.yml) → `model_deployment_name` → consumed by [update-agent/action.yml](../.github/actions/update-agent/action.yml) |

> The GitHub Actions composite actions only emit three outputs (`project_endpoint`, `acr_endpoint`, `model_deployment_name`) because the OIDC service principal has **Foundry Project Manager** pre-assigned out-of-band — no in-workflow RBAC step is needed, so `AZURE_AI_ACCOUNT_NAME` / `AZURE_AI_PROJECT_NAME` / `AZURE_AI_PROJECT_ID` are unused.

---

## Per-path summary

### Shell scripts
Uses **all six** outputs.
- `PROJECT_ID` → Step 3 RBAC
- `ACR_ENDPOINT` → Steps 4, 5, 6
- `PROJECT_ENDPOINT` → Step 6 POST
- `MODEL_DEPLOYMENT_NAME` → Step 6 request body
- `AI_ACCOUNT_NAME`, `PROJECT_NAME` → operator logging

### azd
All outputs are auto-promoted to environment variables in azd hooks and extensions.
- `AI_ACCOUNT_NAME` + `PROJECT_NAME` → [grant-project-manager.sh](../deployment/scripts/grant-project-manager.sh) reconstructs `PROJECT_ID` dynamically
- `PROJECT_ENDPOINT`, `ACR_ENDPOINT`, `MODEL_DEPLOYMENT_NAME` → consumed by the `azure.ai.agents` extension
- `PROJECT_ID` itself is technically unused on this path

### GitHub Actions
Only three outputs are surfaced from the `deploy-bicep` / `deploy-terraform` composite actions:
- `project_endpoint`, `acr_endpoint`, `model_deployment_name`

`AI_ACCOUNT_NAME` / `PROJECT_NAME` / `PROJECT_ID` are not surfaced because the OIDC service principal has Foundry Project Manager pre-assigned out-of-band — no in-workflow RBAC step is needed.

---

## Adding a new output

1. Add the output to [`infra/bicep/main.bicep`](../infra/bicep/main.bicep).
2. Mirror it in [`infra/terraform/outputs.tf`](../infra/terraform/outputs.tf) using the same `AZURE_…` name.
3. Add a row to **Outputs reference** and **Consumption matrix** above.
4. Update the consuming script, action, or hook.
5. Regenerate [`infra/bicep/main.json`](../infra/bicep/main.json) (`az bicep build --file infra/bicep/main.bicep`).
