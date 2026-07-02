# Evaluations

Reference for the agent evaluation gate that runs against every new hosted agent version — in the local deploy scripts (Step 9) and in the CI pipeline. The gate uses [`microsoft/ai-agent-evals@v3-beta`](https://github.com/microsoft/ai-agent-evals) to compare the newly-deployed version against the previous serving version via Azure AI Foundry's [Cloud Evaluation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/cloud-evaluation) service.

---

## Sequence

```mermaid
flowchart TD
    A[Build image / source-code zip] --> B[POST /agents/{name}/versions]
    B --> C[Smoke tests<br/><i>fast fail on connectivity, ~30s, no judge tokens</i>]
    C -->|pass| D[Agent evaluation gate<br/><i>ai-agent-evals runs each row against baseline + new</i>]
    C -->|fail| X[stop — new version orphaned, old keeps serving]
    D -->|pass| E[Promotion allowed]
    D -->|fail| X
```

Smoke tests come first because they use zero judge tokens and fail cheap. The evaluation gate is much more expensive per run — it uses judge-model tokens across every row × every evaluator × every agent under test — so it only runs on agents that already passed the basic connectivity smoke tests. See [Managing evaluation costs](#managing-evaluation-costs) below.

---

## Prerequisites

### Roles

The minimum Foundry role for cloud evaluation is **`Foundry User`** (GUID `53ca6127-db72-4b80-b1b0-d745d6d5456d`) at Foundry project scope. Source: [Cloud Evaluation prerequisites](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/cloud-evaluation#prerequisites). See [RBAC for Azure AI Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry) for the full role catalog and inheritance rules.

The SDK inside ai-agent-evals uses `DefaultAzureCredential`, so the identity is:

- **Local dev:** whoever ran `az login`.
- **CI:** the OIDC service principal configured via `azure/login@v3`.

| Actor | Minimum required | How it's granted today |
|---|---|---|
| Local developer | Foundry User at project scope | Step 3 of `deploy-*.sh` grants Foundry Project Manager (superset) — see [Deploying with Bicep](./deploy-bicep.md#shell-script) or [Deploying with Terraform](./deploy-terraform.md#shell-script) |
| CI OIDC service principal | Foundry User at project scope | **Not currently automated** — see next section |
| Judge model | The `AZURE_AI_MODEL_DEPLOYMENT_NAME` deployment | Provisioned by IaC (both Bicep and Terraform) |

### CI service principal RBAC — manual grant required per project

**Neither IaC nor the CI workflows grant any Foundry role to the CI service principal.** This is setup drift outside version control: the CI SP typically holds subscription-level `Contributor` and `User Access Administrator`, neither of which include `Microsoft.CognitiveServices/*` data actions.

Symptom when this is missing:

```
Could not fetch metadata for evaluator 'builtin.task_adherence': (PermissionDenied)
The principal <ci-sp-object-id> lacks the required data action
`Microsoft.CognitiveServices/accounts/AIServices/assets/read` to perform
`GET /api/projects/{projectName}/evaluators/{name}/versions/{version}`.
```

**Fix — one-time per Foundry project:**

```bash
# Values you need:
CI_SP_OBJECT_ID=<object id of the CI OIDC service principal>
PROJECT_SCOPE="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>"

az role assignment create \
  --role "53ca6127-db72-4b80-b1b0-d745d6d5456d" \
  --assignee-object-id "$CI_SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$PROJECT_SCOPE"
```

> **Always use the role GUID, not the display name.** The display name has been renamed in the past ("Azure AI User" → "Foundry User"); the GUID is stable. See the [RBAC section of copilot-instructions](../.github/copilot-instructions.md#key-conventions) for the canonical list.

Verify:

```bash
az role assignment list \
  --assignee "$CI_SP_OBJECT_ID" \
  --scope "$PROJECT_SCOPE" \
  --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

The 120-second RBAC-propagation wait applies here too — new grants aren't effective immediately.

A structural fix (self-provisioning inside the `deploy-*` composite actions) is in the "Future work" section below.

---

## How it works

Both the local script and the CI composite action invoke `microsoft/ai-agent-evals@v3-beta` with the same environment-variable contract, so behaviour is identical between them. The only difference is where the action code comes from.

| | Local (Step 9 of deploy scripts) | CI (`.github/actions/agent-eval`) |
|---|---|---|
| How ai-agent-evals is obtained | `git clone --depth 1 --branch v3-beta` into a tempdir, then `pip install` into a venv (avoids Debian PEP 668) | `uses: microsoft/ai-agent-evals@v3-beta` — GitHub resolves it |
| Entry point | `python action.py` from the clone | Composite action step (invokes `action.py` internally) |
| Env-var contract | `AZURE_AI_PROJECT_ENDPOINT`, `DEPLOYMENT_NAME`, `DATA_PATH`, `AGENT_IDS`, `BASELINE_AGENT_ID` | Same |
| Baseline selection | `curl` + `jq` over `GET /agents/{name}/versions?api-version=2025-11-15-preview`, pick highest version < new | Same, in `.github/actions/agent-eval/action.yml` step 1 |
| Auth | `DefaultAzureCredential` picks up `az login` | `DefaultAzureCredential` picks up `azure/login@v3` OIDC |
| When it runs | After smoke tests, before script exit | After smoke test step in `update-agent` and `update-agent-source-code` jobs |
| Skippable via | `--no-eval` or `EVAL=false` | Not currently skippable — CI treats it as a hard gate |

Both agents (image-based and source-code) get evaluated. See [Managing evaluation costs](#managing-evaluation-costs) for the levers that control per-run cost.

---

## The dataset

`evals/promotion-gate.json` follows the [ai-agent-evals data file schema](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/README.md#data-file). Fields:

| Field | Type | Notes |
|---|---|---|
| `name` | string | **Ignored by ai-agent-evals** — see "Known limitations" below |
| `evaluators` | string[] | Evaluator IDs from the Foundry evaluator catalog (`builtin.*` for built-ins) |
| `data` | object[] | Rows with `query` + optional `ground_truth` |
| `data_mapping` | object | Optional; auto-generated from data field names when omitted |
| `evaluator_parameters` | object | Optional per-evaluator thresholds |

Current file: 7 evaluators, 30 rows targeted at the four rules encoded in the Transformers agent's system prompt.

To add a row, change an evaluator, or read the full schema reference, see [`evals/README.md`](../evals/README.md). To browse the full evaluator catalog with descriptions, open the Foundry portal at `Build → Evaluations → Evaluator catalog`.

---

## Reading the results

`microsoft/ai-agent-evals` produces one classification per evaluator using a paired statistical significance test between baseline and treatment agents. The classifier logic (verified from [`analysis/analysis.py`](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/analysis/analysis.py)):

```python
if count == 0:                   return "Zero samples"
if count < SAMPLE_SIZE_THRESHOLD: return "Too few samples"   # < 10
if isnan(p_value):               return "Inconclusive"        # zero variance / undefined
if p_value > 0.05:               return "Inconclusive"        # not statistically significant
# else Improved / Degraded / Changed based on the evaluator's desired direction
```

Constants: `SAMPLE_SIZE_THRESHOLD = 10`, `SS_THRESHOLD = 0.05`.

### Verdict meanings

| Verdict | Meaning | Gate outcome |
|---|---|---|
| **Improved** | Statistically significant change in the desired direction (p ≤ 0.05) | Pass |
| **Degraded** | Statistically significant change in the wrong direction | **Fail** |
| **Changed** | Statistically significant change on a neutral-direction evaluator | Neutral — inspect manually |
| **Inconclusive** | No statistically significant difference between baseline and new | Pass — no evidence of regression |
| **Too few samples** | Dataset had < 10 usable rows for this evaluator | Pass — insufficient data to fail on |
| **Zero samples** | Evaluator produced no scored rows at all | Investigate — usually a config error |

### Why identical code produces "Inconclusive"

When you deploy the same source code twice, both agents are literally identical, so any observed delta is random noise from judge-model non-determinism. That gets `p > 0.05` for the quality evaluators, and NaN p-values for safety evaluators (both are near-zero with no variance) — both mapping to `"Inconclusive"`. **This is the correct verdict for identical code**: "no evidence of change, promotion allowed."

### When to actually worry

- **`Degraded` on any safety evaluator** (`violence`, `self_harm`, `hate_unfairness`, `sexual`, `hate_unfairness`). Safety evaluators score severity 0–7 (higher is worse). Any regression here should block.
- **`Degraded` on `task_adherence`** — the agent stopped following its instructions (typically the refusal or continuity rules for the Transformers agent).
- **`Degraded` on `f1_score`** — response text drifted materially from ground truth. Might be legit (better paraphrasing) or a regression (garbled output).
- **`Inconclusive` on a change you expected to improve things** — the dataset is probably underpowered. See "Future work" for how to fix.

The Foundry portal's compare view (linked in the GH Actions summary) shows per-row detail, per-evaluator confidence intervals, and raw judge outputs. Follow the "View compare report" link from the summary.

### Score scale reference

| Evaluator category | Scale | Direction |
|---|---|---|
| Agent (`task_adherence`, `task_completion`, `intent_resolution`, `tool_call_accuracy`, etc.) | 1–5 Likert | Higher is better |
| General quality (`coherence`, `fluency`, `relevance`, `groundedness`, `response_completeness`) | 1–5 Likert | Higher is better |
| NLP text similarity (`f1_score`, `bleu_score`, `rouge_score`, `meteor_score`, `gleu_score`) | 0–1 | Higher is better |
| Risk & safety (`violence`, `self_harm`, `hate_unfairness`, `sexual`, `code_vulnerability`, `protected_material`, `indirect_attack`) | 0–7 severity | Lower is better |

---

## Local iteration

The fastest way to iterate on the dataset (or on evaluator selection) without redeploying the agent:

```bash
# 1. Deploy once with the gate skipped
./deployment/deploy-bicep.sh --skip-infra --skip-rbac --no-eval

# 2. Edit evals/promotion-gate.json — add a row, swap an evaluator, tune thresholds

# 3. Redeploy with eval enabled (the deploy is essentially cached — same image tag)
./deployment/deploy-bicep.sh --skip-infra --skip-rbac
```

Each redeploy creates a new agent version, which becomes the new "treatment" against the previously-serving version as baseline — even with identical code, this lets you validate that the eval catalog loads, the evaluators reach the model, and the gate reports as expected.

To run the gate against a specific existing version pair without touching the deploy scripts, mimic what Step 9 does — clone `microsoft/ai-agent-evals`, `pip install` into a venv, and invoke `action.py` with `AGENT_IDS=<name>:<baseline>,<name>:<treatment>` and `BASELINE_AGENT_ID=<name>:<baseline>`.

---

## Managing evaluation costs

The gate is billed at judge-model token rates on your `AZURE_AI_MODEL_DEPLOYMENT_NAME` deployment. Actual dollar cost varies substantially by model choice, region pricing, tenant discounts, evaluator mix, and row length, so this section describes the levers rather than point estimates.

### What drives cost

Every evaluation run scales the base cost by the product of:

- **Rows in the dataset** — each row is called against each agent under test.
- **LLM-as-judge evaluators** in `evaluators` — quality and agent evaluators (`task_adherence`, `coherence`, `fluency`, `relevance`, `groundedness`, etc.) each call the judge model per row. NLP evaluators (`f1_score`, `bleu_score`, `rouge_score`, `meteor_score`, `gleu_score`) are computed locally and are effectively free.
- **Agents under test** — both the image-based and the source-code agent are evaluated by default, doubling the cost per run.
- **Baseline present** — when a previous version exists, every row is called against baseline *and* new agent for statistical comparison. First deploy has no baseline and skips that doubling.
- **Row length** — the model bills per token, so verbose `query` and `ground_truth` fields raise cost proportionally.

### Levers to reduce cost

Ordered from lowest to highest engineering effort:

- **Skip locally when iterating on unrelated changes.** Pass `--no-eval` (or `EVAL=false`) to `deploy-bicep.sh` / `deploy-terraform.sh` when you're only touching infra, docs, or unrelated code. See [Deploying with Bicep](./deploy-bicep.md) or [Deploying with Terraform](./deploy-terraform.md) for the flag reference.
- **Deploy one agent at a time when validating changes.** `--no-image-agent` or `--no-source-code-agent` halves the run cost. Both agents run identical source code, so evaluating one is usually enough for a validation loop.
- **Prefer NLP evaluators when they answer your question.** `f1_score`, `bleu_score`, and `rouge_score` are free and often sufficient for regression detection on refusal-phrasing or ground-truth-couples rules. Drop LLM-as-judge evaluators you don't need from `evaluators` in `evals/promotion-gate.json`.
- **Keep rows lean.** Long `ground_truth` fields are billed as tokens on every judge call. Trim to what's needed for the evaluator to score.
- **Trim the dataset for local iteration.** Duplicate `evals/promotion-gate.json` to a smaller file and point `DATA_PATH` at it for the local run when iterating on evaluator selection or dataset design. The full 30-row file should still be what CI uses to gate promotion.
- **Pick a cheaper judge model.** `AZURE_AI_MODEL_DEPLOYMENT_NAME` is set by IaC; changing it changes the judge-model cost for every run. Mini/small variants of the same model family are typically an order of magnitude cheaper per token and score similarly for most gating use cases.
- **Cache smoke tests as your fast-fail.** Because the gate only runs when smoke tests pass, any regression that a smoke test can catch is caught before spending judge tokens. Broaden the smoke test catalog rather than the eval dataset when you can.

### Estimate for your case

Use the [Azure OpenAI pricing calculator](https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/) with the token counts printed in the ai-agent-evals summary output (per-model `prompt_tokens` and `completion_tokens` fields on each eval run) to get a concrete per-run figure for your specific model + region + evaluator selection. Judge-token counts are stable across runs against the same dataset, so a single reference run gives you a repeatable estimate.

---

## Known upstream limitations

Two active issues filed against `microsoft/ai-agent-evals` that affect this repo:

| # | Issue | Impact | Workaround |
|---|---|---|---|
| [#72](https://github.com/microsoft/ai-agent-evals/issues/72) | Eval object name hardcoded to `"Agent Evaluation"` | Every eval in the Foundry portal appears under the same name; cross-repo/branch disambiguation is impossible without opening each one | Rely on the dataset name (derived from `input_data_path.stem`) or run names (`Agent {name}:{version}`) to disambiguate |
| [#74](https://github.com/microsoft/ai-agent-evals/issues/74) | `actions/setup-python@v5` targets deprecated Node.js 20 | Every CI run emits a "Node.js 20 is deprecated" warning annotation | Cosmetic; runner auto-forces Node 24 |

### Naming quirks worth knowing

The `"name"` field inside `evals/promotion-gate.json` is **ignored** by ai-agent-evals v3-beta. Actual names used:

| Foundry object | Value we get | Source |
|---|---|---|
| Eval object | `Agent Evaluation` | Hardcoded in `action.py` (upstream #72) |
| Dataset | `promotion-gate` | Filename stem: `input_data_path.stem` |
| Each run | `Agent {name}:{version}` (e.g. `Agent agent-framework-agent-basic-responses:26`) | Built at runtime |

If you rename `evals/promotion-gate.json` to something more descriptive, that new name becomes the dataset name — currently the only meaningful lever for disambiguation.

---

## Further reading

- [Cloud Evaluation for Azure AI Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/cloud-evaluation) — prerequisites, API, SDK usage, troubleshooting
- [RBAC for Azure AI Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry) — full role catalog, scope inheritance, GUID reference
- [microsoft/ai-agent-evals README](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/README.md) — inputs, sample data files, evaluator categories
- [ai-agent-evals sample datasets](https://github.com/microsoft/ai-agent-evals/tree/v3-beta/samples/data) — reference for `openai_graders`, `evaluator_parameters`, `data_mapping`, custom evaluators
- [Foundry portal — Evaluator catalog](https://ai.azure.com/) — Build → Evaluations → Evaluator catalog for the authoritative list with descriptions
- [`evals/README.md`](../evals/README.md) — this repo's dataset-editing guide
- [Deploying with Bicep](./deploy-bicep.md) / [Deploying with Terraform](./deploy-terraform.md) — Step 9 in the shell-script workflow
- [GitHub Actions CI/CD](./github-actions.md) — composite action wiring
