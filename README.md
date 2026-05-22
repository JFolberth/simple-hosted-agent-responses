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
| `foundry.bicep` | `modules/foundry/` | `Microsoft.CognitiveServices/accounts` (kind: `AIServices`) | AI Services account + model deployments | No |
| `foundry-project.bicep` | `modules/foundry_project/` | `Microsoft.CognitiveServices/accounts/projects` | Foundry project + App Insights connection + **Foundry User** role for project MI on AI account | Project and App Insights connection are general purpose; **Foundry User** role is hosted-agent-specific — it grants `Microsoft.CognitiveServices/*` data actions to the container's managed identity so it can call the model endpoint at runtime |
| `acr.bicep` | `modules/acr/` | `Microsoft.ContainerRegistry/registries` | Container image registry + AcrPull role for project MI + ACR connection to the project | The registry itself is general purpose, but the **ACR connection registered on the Foundry project** is hosted-agent-specific — it tells Foundry Agent Service which registry to pull the container image from at runtime |
| `loganalytics.bicep` | `modules/loganalytics/` | `Microsoft.OperationalInsights/workspaces` | Log retention backend for Application Insights | No |
| `applicationinsights.bicep` | `modules/applicationinsights/` | `Microsoft.Insights/components` | Distributed traces, metrics, and exceptions | No — prompt-based agents and evaluations also use it |

#### What makes this different from a standard Foundry project at the IaC level

A standard Foundry project (used for prompt-based agents, evaluations, or model calls) needs only the AI Services account and a project resource. Hosted agents require one additional thing declared in this template:

1. **An ACR connection on the project** — tells the micro VM runtime which container registry to pull images from. The registry itself is general purpose, but registering it as a connection on the Foundry project is specific to hosted agents. No stored credentials — the project managed identity (granted AcrPull on the registry) handles authentication.

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

### Local prerequisites

If not using the dev container, see the deployment guides for prerequisites and configuration:

- [Deploying with Bicep](docs/deploy-bicep.md) — Azure CLI, Docker, Bicep (auto-installed via `az bicep install`)
- [Deploying with Terraform](docs/deploy-terraform.md) — Azure CLI, Docker, Terraform ≥ 1.9

The shell scripts require a Bash environment (macOS, Linux, WSL, or Azure Cloud Shell). Use `azd` for cross-platform Windows support.

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

## Deploying

### azd

```bash
# 1. Select Bicep or Terraform (writes deployment/azure.yaml)
./deployment/azd-select.sh

# 2. Authenticate and configure
cd deployment
azd auth login
azd env new <env-name>
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_TENANT_ID "$(az account show --query tenantId -o tsv)"

# 3. Provision infrastructure and deploy
azd up

# Subsequent code-only changes
azd deploy
```

See [Deploying with Bicep](docs/deploy-bicep.md#azure-developer-cli-azd) or [Deploying with Terraform](docs/deploy-terraform.md#azure-developer-cli-azd) for the full setup, including IaC-specific environment variables and how azd maps to each deployment step.

### Shell scripts

```bash
./deployment/deploy-bicep.sh          # Full deploy (Bicep)
./deployment/deploy-terraform.sh      # Full deploy (Terraform)

./deployment/deploy-bicep.sh --skip-infra      # Code changes only
./deployment/deploy-terraform.sh --skip-infra  # Code changes only
```

See [Deploying with Bicep](docs/deploy-bicep.md) or [Deploying with Terraform](docs/deploy-terraform.md) for configuration, step-by-step walkthrough, and state management.

For CI/CD automation, see [GitHub Actions CI/CD](docs/github-actions.md).

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

## Documentation

Detailed guides for each deployment path and the CI/CD pipeline:

| Guide | What it covers |
|---|---|
| [Deploying with Bicep](docs/deploy-bicep.md) | Shell script and azd deployment using Bicep infrastructure |
| [Deploying with Terraform](docs/deploy-terraform.md) | Shell script and azd deployment using Terraform; includes local and remote state management |
| [GitHub Actions CI/CD](docs/github-actions.md) | Workflow architecture, OIDC auth setup, RBAC requirements, secrets/variables reference, composite action internals |

---

## Further Reading

- [What are hosted agents?](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents) — platform concepts, session model, and protocol comparison
- [Deploy a hosted agent](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent) — full deployment lifecycle reference
- [Agent Framework — Foundry Hosted Agents (Python)](https://learn.microsoft.com/agent-framework/hosting/foundry-hosted-agent) — Agent Framework hosting integration
- [Azure AI Foundry documentation](https://learn.microsoft.com/azure/foundry/) — broader platform documentation
