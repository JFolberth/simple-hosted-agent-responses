# Simple Hosted Agent

A minimal, production-ready reference for deploying a Python AI agent to [Microsoft Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents) using the **Responses protocol**. Infrastructure is available in two flavors — **Bicep** and **Terraform (azapi)** — and deployed either with a single shell script or with the **Azure Developer CLI (`azd`)**.

---

## Why Foundry Hosted Agents?

Foundry Hosted Agents are **not** the same as running a container on Azure Container Apps (ACA) or another self-managed compute service. The distinction matters:

| | Foundry Hosted Agent | Self-hosted (ACA, AKS, etc.) |
|---|---|---|
| **Infrastructure** | Per-session micro VMs (Microsoft-managed) | You provision, scale, and maintain |
| **Session isolation** | Each session gets a dedicated micro VM with persistent `$HOME` | Shared container instance; you manage state |
| **Agent identity** | Dedicated Microsoft Entra ID created automatically at deploy time | You create and bind a managed identity |
| **Scaling** | Scale-to-zero with automatic cold-start resume | You configure autoscale rules |
| **Toolbox** | Built-in access to Foundry tools (Code Interpreter, Web Search, MCP) via managed endpoint | Manual integration for each tool |
| **Observability** | Integrated with Application Insights; traces surfaced in Foundry portal | You wire up telemetry yourself |
| **Deployment** | Push a container image; platform provisions runtime | You manage container registry, ingress, and deployment rollout |

When you run a container on ACA, you own the runtime. When you deploy a hosted agent to Foundry, **you own only the agent logic**; the platform manages everything else. Use self-hosted compute when you have hard networking, compliance, or framework constraints that Foundry cannot satisfy. For everything else, hosted agents reduce operational overhead significantly.

See the official Microsoft documentation: [What are hosted agents?](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)

---

## What This Sample Deploys

### Agent

`src/agent-framework/responses/basic/` contains a Python agent built with the [Agent Framework](https://github.com/microsoft/agent-framework). It uses the **Responses protocol** — the platform manages conversation history and streaming automatically, and any OpenAI-compatible SDK can talk to it.

> **Protocol note**: This sample uses the **Responses protocol**. For a sample using the Invocations protocol instead, see [simple-hosted-agent](https://github.com/JFolberth/simple-hosted-agent). See the [protocol comparison](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#key-concepts) for guidance on when to choose each.

### Infrastructure

Five resources are deployed to a single resource group:

| Bicep | Terraform | Resource | Why it's here | Hosted-agent-specific? |
|---|---|---|---|---|
| `foundry.bicep` | `modules/foundry/` | `Microsoft.CognitiveServices/accounts` (kind: `AIServices`) | AI Services account + model deployments + **account-level capability host** | Capability host only — the account itself is used by all Foundry project types |
| `foundry-project.bicep` | `modules/foundry_project/` | `Microsoft.CognitiveServices/accounts/projects` | Foundry project + App Insights connection + **Foundry User** role for project MI on AI account | Project and App Insights connection are general purpose; **Foundry User** role is hosted-agent-specific — it grants `Microsoft.CognitiveServices/*` data actions to the container's managed identity so it can call the model endpoint at runtime |
| `acr.bicep` | `modules/acr/` | `Microsoft.ContainerRegistry/registries` | Container image registry + AcrPull role for project MI + ACR connection to the project | The registry itself is general purpose, but the **ACR connection registered on the Foundry project** is hosted-agent-specific — it tells Foundry Agent Service which registry to pull the container image from at runtime |
| `loganalytics.bicep` | `modules/loganalytics/` | `Microsoft.OperationalInsights/workspaces` | Log retention backend for Application Insights | No |
| `applicationinsights.bicep` | `modules/applicationinsights/` | `Microsoft.Insights/components` | Distributed traces, metrics, and exceptions | No — prompt-based agents and evaluations also use it |

#### What makes this different from a standard Foundry project at the IaC level

A standard Foundry project (used for prompt-based agents, evaluations, or model calls) needs only the AI Services account and a project resource. Hosted agents require two additional things, all declared in this template:

1. **`capabilityHosts` on the account** — registers the account with Foundry Agent Service and provisions the micro VM runtime layer. Without this, the account can serve model calls but cannot run hosted agents.

2. **An ACR connection on the project** — tells the micro VM runtime which container registry to pull images from. The registry itself is general purpose, but registering it as a connection on the Foundry project is specific to hosted agents. No stored credentials — the project managed identity (granted AcrPull on the registry) handles authentication.

See [Capability hosts](https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts) for the full reference.

---

## Getting Started

All paths require an **Azure subscription** and the model available in your chosen region. For a list of supported regions, see the [availability table](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#limits-pricing-and-availability-preview).

### Dev Container (recommended)

Install [VS Code](https://code.visualstudio.com/) and [Docker Desktop](https://www.docker.com/products/docker-desktop/). Everything else — Azure CLI, azd, Bicep, Terraform, tflint, the `azure.ai.agents` azd extension, and Python dependencies — is installed automatically when the container builds.

1. Clone the repository and open it in VS Code.
2. When prompted, click **Reopen in Container** (or run **Dev Containers: Reopen in Container**).
3. Authenticate with Azure:
   ```bash
   az login
   ```

### Local — azd

| Tool | Install |
|---|---|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `brew install azure-cli` / [Windows installer](https://aka.ms/installazurecliwindows) |
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | `brew tap azure/azd && brew install azd` / [installer](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) |

After installing azd, add the agent extension:
```bash
azd extension install azure.ai.agents
```

No Bicep CLI or Terraform install needed — azd uses ACR remote build for the image and handles infra through the provider you select.

### Local — Shell scripts (Bicep)

> **Note:** The shell scripts require a Bash environment (macOS, Linux, WSL, or Azure Cloud Shell). They do not run natively on Windows. Use `azd` instead for a cross-platform deployment experience.

| Tool | Install |
|---|---|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `brew install azure-cli` / [Windows installer](https://aka.ms/installazurecliwindows) |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | `az bicep install` |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Platform installer |

### Local — Shell scripts (Terraform)

> **Note:** The shell scripts require a Bash environment (macOS, Linux, WSL, or Azure Cloud Shell). They do not run natively on Windows. Use `azd` instead for a cross-platform deployment experience or a devcontainer.

| Tool | Install |
|---|---|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `brew install azure-cli` / [Windows installer](https://aka.ms/installazurecliwindows) |
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.9 — `brew install hashicorp/tap/terraform` / [installer](https://developer.hashicorp.com/terraform/install) |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Platform installer |

### Required Azure permissions (shell scripts)

The deploy scripts perform these operations. `azd` handles all of this automatically via the `azure.ai.agents` extension.

| Operation | What it does | Required role | Scope |
|---|---|---|---|
| `az deployment sub create` / `terraform apply` | Creates the resource group and all Azure resources | **Contributor** + **Role Based Access Control Administrator** | Subscription |
| `az role assignment create` | Grants Azure AI Project Manager at project scope | **Role Based Access Control Administrator** | Foundry project |
| `docker push` (via `az acr login`) | Pushes the container image to ACR | **AcrPush** or **Container Registry Repository Writer** | ACR resource |
| `az rest POST .../agents/{name}/versions` | Creates the hosted agent version via the Foundry data plane | **Azure AI Project Manager** | Foundry project |

> **Why assign at project scope explicitly, even with subscription-level access?**
> The Foundry data plane evaluates `Microsoft.CognitiveServices/accounts/AIServices/agents/write` at the scope of the Foundry **project** resource specifically. Subscription or resource group scoped role assignments are not reliably inherited by the Foundry data plane. The Microsoft docs state:
>
> > *"Azure AI Project Manager at the project scope is the recommended role assignment for agent creators, as that role includes both the required data plane permissions and the ability to assign the Azure AI User role."*
> > — [Hosted agent permissions reference — Agent creation](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions#agent-creation)
>
> The deploy scripts handle this automatically (Step 3) with an idempotent `az role assignment create` followed by a 30-second propagation wait.

If your identity has **Owner** at subscription scope it satisfies the ARM operations. The project-scope data plane assignment is always made explicitly by the script regardless.

---

## Configuration

### Bicep

Before deploying, open `infra/bicep/main.bicepparam` and set values for your environment:

```bicep
param environmentName       = 'simple-hosted-agent'      // Used in resource naming
param resourceGroupName     = 'rg-simple-hosted-agent-dev'
param location              = 'swedencentral'             // Region for all resources
param aiDeploymentsLocation = 'swedencentral'             // Region for model deployments (can differ)
param aiFoundryProjectName  = 'ai-project'

param deployments = [
  {
    name: 'gpt-4.1-mini'
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1-mini'
      version: '2025-04-14'
    }
    sku: { name: 'Standard', capacity: 10 }
  }
]
```

**Choosing a region**: Not all models are available in every region. Run the following command to check what's available before deploying:

```bash
az cognitiveservices model list --location <region> \
  --query "[?name=='gpt-4.1-mini'].{version:version, lifecycleStatus:lifecycleStatus}" \
  --output table
```

Also update the top of `deployment/deploy-bicep.sh` to match:

```bash
ENVIRONMENT_NAME="simple-hosted-agent"   # Must match environmentName in main.bicepparam
LOCATION="swedencentral"                 # Must match location in main.bicepparam
```

### Terraform

Before deploying, open `infra/terraform/terraform.tfvars` and set values for your environment:

```hcl
environment_name        = "simple-hosted-agent"
resource_group_name     = "rg-simple-hosted-agent"
location                = "swedencentral"              # Region for the resource group
ai_deployments_location = "swedencentral"              # Region for model deployments (can differ)
ai_foundry_project_name = "ai-project"

deployments = [
  {
    name = "gpt-4.1-mini"
    model = {
      format  = "OpenAI"
      name    = "gpt-4.1-mini"
      version = "2025-04-14"
    }
    sku = { name = "Standard", capacity = 10 }
  }
]
```

Also update `AGENT_NAME` at the top of `deployment/deploy-terraform.sh` to match the name you want to use in the Foundry portal.

State is stored locally in `infra/terraform/terraform.tfstate`. This is suitable for development; for team or production use, switch to a remote backend (e.g. Azure Blob Storage).

---

## Deploying

### Option 1 — azd (recommended)

`azd` handles infrastructure provisioning, image build (via ACR remote build), and agent deployment in a single `azd up` command.

**How it works under the hood:**

1. `azd provision` runs Bicep/Terraform and creates all Azure resources.
2. A `postprovision` hook (`deployment/scripts/grant-project-manager.sh`) runs automatically — it grants **Azure AI Project Manager** to the deploying principal at the Foundry project scope. This step is required because the Foundry data plane evaluates `Microsoft.CognitiveServices/accounts/AIServices/agents/write` at project scope specifically, and subscription/resource group scoped assignments are not reliably inherited. Without this grant, the next step gets a `401 PermissionDenied`.
3. The `azure.ai.agents` azd extension calls the Foundry data plane (`POST .../agents/{name}/versions`) to register the container as a hosted agent version.

**Prerequisites:** `azd` CLI installed + `azure.ai.agents` extension (both installed automatically in the dev container).

**First-time setup:**

```bash
# 1. Log in to azd (separate from az login — azd has its own auth context)
azd auth login

# 2. Choose Bicep or Terraform — creates deployment/azure.yaml
./deployment/azd-select.sh

# 3. Move into the deployment directory (azd reads azure.yaml from CWD)
cd deployment

# 4. Create a new azd environment
azd env new <env-name>

# 5. Set required environment variables
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"

# Bicep only:
azd env set AZURE_AI_DEPLOYMENTS_LOCATION swedencentral

# Terraform only (maps to TF_VAR_ai_deployments_location):
azd env set AI_DEPLOYMENTS_LOCATION swedencentral

# 6. Provision infrastructure and deploy the agent
azd up
```

> **Why set `AZURE_TENANT_ID` explicitly?** The `azure.ai.agents` extension's deploy handler requires `AZURE_TENANT_ID` to authenticate against the Foundry data plane. azd normally injects this from its own auth context (populated by `azd auth login`), but setting it explicitly from `az account show` is the reliable fallback and works regardless of azd auth state.

**Subsequent code-only changes:**

```bash
cd deployment
azd deploy
```

> **Terraform note:** azd injects `TF_VAR_environment_name`, `TF_VAR_location`, and `TF_VAR_resource_group_name` automatically from standard azd environment variables. Set `AI_DEPLOYMENTS_LOCATION` to control `TF_VAR_ai_deployments_location`. The `infra/terraform/terraform.tfvars` file is still used as a fallback for any variables not set by azd.

> **Model deployments:** The model deployment array is hardcoded in `deployment/infra-azd/main.bicepparam` (Bicep) or `infra/terraform/terraform.tfvars` (Terraform). Edit those files to change the model or capacity — there is no azd env var for this.

---

### Option 2 — Shell scripts

### Bicep

`deployment/deploy-bicep.sh` performs the entire deployment in seven steps:

```bash
chmod +x deployment/deploy-bicep.sh
./deployment/deploy-bicep.sh
```

#### What it does

**Step 1 — Deploy infrastructure**
Runs `az deployment sub create` against `infra/bicep/main.bicep`. This creates the resource group and all six Azure resources. On subsequent runs, Bicep is idempotent — only changed resources are updated.

**Step 2 — Read outputs**
Retrieves `az deployment sub show` output values: AI account name, project name, ACR endpoint, and model deployment name. These drive every subsequent step.

**Step 3 — Assign Azure AI Project Manager at project scope**
The Foundry data plane checks the `agents/write` permission at the Foundry **project** resource scope specifically — subscription-level assignments are not reliably inherited. This step runs `az role assignment create` (idempotent) scoped to the project resource ID, then waits 30 seconds for RBAC propagation.

**Step 4 — Authenticate to ACR**
Runs `az acr login` so Docker can push to the private registry.

**Step 5 — Build and push image**
Builds the Docker image from `src/agent-framework/responses/basic/` and tags it with the short Git commit hash. Tags are immutable — each commit produces a new image tag.

**Step 6 — Deploy the hosted agent**
POSTs to the Foundry data plane (`{projectEndpoint}/agents/{name}/versions?api-version=2025-11-15-preview`) via `az rest` with `--resource https://ai.azure.com/`. The request body specifies `kind: hosted`, the container image tag, CPU/memory, protocol (`responses 1.0.0`), and the `AZURE_AI_MODEL_DEPLOYMENT_NAME` environment variable. The platform pulls the image, provisions a micro VM, and creates a dedicated Entra identity and endpoint for the agent. The Foundry runtime also injects `FOUNDRY_PROJECT_ENDPOINT` and `APPLICATIONINSIGHTS_CONNECTION_STRING` automatically. The management-plane CLI (`az cognitiveservices agent create`) is **not** used — it calls a separate start operation that returns 404 for hosted agents.

#### Skipping infrastructure on subsequent deployments

If you only changed agent code (not infra), skip the Bicep step:

```bash
./deployment/deploy-bicep.sh --skip-infra
```

### Terraform

`deployment/deploy-terraform.sh` runs the same six steps, substituting `terraform apply` for `az deployment sub create` and `terraform output` for `az deployment sub show`. All image build, push, and agent creation steps are identical.

```bash
chmod +x deployment/deploy-terraform.sh
./deployment/deploy-terraform.sh
```

Skip infrastructure on code-only changes:

```bash
./deployment/deploy-terraform.sh --skip-infra
```

---

## Testing the Agent

After deployment, the agent is accessible through its Foundry endpoint. Open the [Foundry portal](https://ai.azure.com), navigate to your project, and select the agent to open the playground.

You can also call it directly using `curl`. The Responses endpoint is OpenAI-compatible:

```bash
# Non-streaming
curl -X POST \
  "<project_endpoint>/agents/agent-framework-agent-basic-responses/endpoint/protocols/responses" \
  -H "Authorization: Bearer $(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)" \
  -H "Content-Type: application/json" \
  -d '{"input": "Hi!"}'
```

For multi-turn conversation, include the `previous_response_id` from the prior response:

```bash
curl -X POST \
  "<project_endpoint>/agents/agent-framework-agent-basic-responses/endpoint/protocols/responses" \
  -H "Authorization: Bearer $(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)" \
  -H "Content-Type: application/json" \
  -d '{"input": "What did I just say?", "previous_response_id": "<response_id>"}'
```

---

## Running the Agent Locally

For iterating on agent logic without a full cloud deployment:

1. Create a `.env` file in `src/agent-framework/responses/basic/`:
   ```
   FOUNDRY_PROJECT_ENDPOINT=https://<your-project>.services.ai.azure.com/api/projects/<project>
   AZURE_AI_MODEL_DEPLOYMENT_NAME=gpt-4.1-mini
   ```

2. Install dependencies:
   ```bash
   pip install -r src/agent-framework/responses/basic/requirements.txt
   ```

3. Run the agent:
   ```bash
   python src/agent-framework/responses/basic/main.py
   ```

4. Test it:
   ```bash
   curl -X POST http://localhost:8088/responses \
     -H "Content-Type: application/json" \
     -d '{"input": "Hi!"}'
   ```

You will need an existing Foundry project and model deployment. The `FOUNDRY_PROJECT_ENDPOINT` and model deployment name can be found in the Foundry portal under your project's overview page.

---

## Cleaning Up

**If deployed with azd:**

```bash
cd deployment
azd down
```

**If deployed with the shell scripts:**

```bash
az group delete --name rg-simple-hosted-agent-dev --yes
az deployment sub delete --name deploy-simple-hosted-agent
```

---

## Further Reading

- [What are hosted agents?](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents) — platform concepts, session model, and protocol comparison
- [Capability hosts](https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts) — how the account-level capability host enables the agent runtime
- [Deploy a hosted agent](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent) — full deployment lifecycle reference
- [Agent Framework — Foundry Hosted Agents (Python)](https://learn.microsoft.com/agent-framework/hosting/foundry-hosted-agent) — Agent Framework hosting integration
- [Azure AI Foundry documentation](https://learn.microsoft.com/azure/foundry/) — broader platform documentation
