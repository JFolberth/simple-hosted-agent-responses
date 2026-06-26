# Smoke Tests

This guide covers the post-deploy smoke test suite that validates a deployed Foundry hosted agent's behavior via its Responses endpoint. The suite is invoked automatically by both shell scripts and by GitHub Actions, and can also be run on demand against any deployed agent.

For local deployment, see [Deploying with Bicep](./deploy-bicep.md) or [Deploying with Terraform](./deploy-terraform.md). For CI/CD, see [GitHub Actions CI/CD](./github-actions.md).

---

## What the smoke tests validate

The suite has two jobs:

1. **Reachability** — confirm the agent's Responses data-plane endpoint accepts requests and returns a well-formed OpenAI-Responses payload (`output_text` or `output[*].content[*].text`).
2. **System-prompt rule compliance** — confirm the agent obeys the rules declared in [main.py](../src/agent-framework/responses/basic/main.py). The sample agent is a Transformers expert with four numbered rules: off-topic refusal, no fabrication, continuity awareness, and brevity.

Each catalog entry is one HTTP step. A **scenario** is what the suite logically validates and can be either single-step (one entry, one prompt) or multi-step (two or three entries chained via threading fields). Assertions on each step are **case-insensitive substring checks** on the returned text. Steps run sequentially per agent; passing every step is the deploy contract. The 9 bundled catalog entries compose into 6 scenarios — 4 single-step rule checks and 2 multi-step threading scenarios.

---

## File layout

| File | Purpose |
|---|---|
| [deployment/smoke-tests.json](../deployment/smoke-tests.json) | The test catalog — list of prompts and assertions |
| [deployment/smoke-tests.py](../deployment/smoke-tests.py) | The runner — stdlib only, no pip dependencies |
| [.github/actions/smoke-test/action.yml](../.github/actions/smoke-test/action.yml) | Composite action wrapping the runner for CI |

---

## Catalog

The catalog is a JSON document with one `tests` array. Each entry is one **step**. Each entry has the following shape:

```json
{
  "id": "string — unique step name",
  "description": "string — human-readable purpose",
  "prompt": "string — the message sent to the agent",
  "assertions": {
    "status":        200,            // optional, HTTP status; default 200
    "contains_any":  ["...", "..."], // optional, at least one must match
    "contains_all":  ["...", "..."], // optional, all must match
    "contains_none": ["...", "..."]  // optional, none may match
  },
  "save_response_id_as":      "string — optional, store response.id under this key",
  "use_previous_response_id": "string — optional, send previous_response_id from the named key",
  "create_conversation_as":   "string — optional, setup-only step that POSTs to /conversations and stores the new conversation id under this key (no prompt or assertions)",
  "use_conversation":         "string — optional, send conversation: <id> from the named key"
}
```

All substring matches are case-insensitive. Assertion keys are evaluated independently; missing keys are skipped, not failed.

### Multi-turn threading

The Responses protocol offers two ways to thread turns together server-side, and the test catalog supports both. The [Sessions versus conversations](https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-sessions#sessions-versus-conversations) reference is the authoritative comparison; the short version is:

| Mechanism | Catalog fields | What the platform does |
|---|---|---|
| `previous_response_id` | `save_response_id_as` → `use_previous_response_id` | Chains each new response to the previous response's id. Each call lands in a **new** sandbox unless you also pass `agent_session_id`. |
| `conversation` id | `create_conversation_as` → `use_conversation` | The platform stores history under the conversation id, and (per the docs) "a stable `agent_session_id` is automatically associated with the conversation. Subsequent calls reuse the same sandbox without you having to track the session id." |

Both mechanisms produce the same threaded-context behavior at the model level. The `conversation` path adds value when an agent needs **stable sandbox state** across turns (uploaded files, `$HOME`); the bundled reference agent doesn't, so the `conversation_*` steps exercise the platform plumbing as a regression guard rather than to retain sandbox state.

#### By `previous_response_id`

`save_response_id_as` and `use_previous_response_id` provide a per-agent key/value store of response ids. A step that saves an id under `"megatron_thread"` can be followed by another step that sends `previous_response_id` from `"megatron_thread"`. The store is reset between agents — agents do not share threading state.

```mermaid
flowchart LR
    T1["thread_turn_1<br/>prompt: Who is Megatron?"]
    T1 -- "save_response_id_as: megatron_thread" --> S["per-agent store<br/>{megatron_thread: id-xyz}"]
    T2["thread_turn_2<br/>prompt: What faction does he lead?"]
    S -- "use_previous_response_id: megatron_thread<br/>→ previous_response_id: id-xyz" --> T2
    T2 -- "assertion: contains 'decepticon'" --> OK["✅ context survived"]
```

#### By `conversation` id

`create_conversation_as` is a **setup-only step** — it has no `prompt` and no `assertions`. The runner POSTs to the [Create conversation REST endpoint](https://learn.microsoft.com/rest/api/microsoft-foundry/aiproject#conversations) (`POST .../endpoint/protocols/openai/conversations`) and stores the returned id under the named key. Later steps reference that key via `use_conversation`, which causes the runner to send `conversation: <id>` in the Responses request body instead of `previous_response_id`. As with response-id threading, the conversation store is per-agent.

```mermaid
flowchart LR
    C["conversation_create<br/>setup: POST /conversations"]
    C -- "create_conversation_as: starscream_convo" --> S["per-agent store<br/>{starscream_convo: conv-abc}"]
    T1["conversation_turn_1<br/>prompt: Who is Starscream?"]
    T2["conversation_turn_2<br/>prompt: Who does he serve?"]
    S -- "use_conversation: starscream_convo<br/>→ conversation: conv-abc" --> T1
    S -- "use_conversation: starscream_convo<br/>→ conversation: conv-abc" --> T2
    T2 -- "assertion: contains 'megatron' or 'decepticon'" --> OK["✅ platform replayed history"]
```

### Test scenarios

The 9 catalog entries compose into 6 scenarios. Single-step scenarios have one row in the table; multi-step scenarios list every step in execution order.

| # | Scenario | Steps (in order) | Asserts |
|---|---|---|---|
| 1 | Reachability | `basic_response` | Reply contains `optimus` or `prime` |
| 2 | Off-topic refusal (Rule 1) | `offtopic_refusal` | Reply contains `only answer questions about transformers` and does **not** contain `paris` |
| 3 | No fabrication (Rule 2) | `no_hallucination` | Reply contains an honest-rejection marker (`i don't know`, `not certain`, `no such`, `no storyline`, `does not`, `doesn't`, `did not`, `didn't`, `never happens`, …) |
| 4 | Continuity disclosure (Rule 3) | `continuity_aware` | Reply contains `continuity`, `depends`, `differs`, `varies`, … |
| 5 | Multi-turn threading via `previous_response_id` | `thread_turn_1` → `thread_turn_2` | Step 1 reply contains `megatron` and saves the response id; step 2 reply to "What faction does he lead?" contains `decepticon` (only correct if context survived) |
| 6 | Multi-turn threading via `conversation` id + history replay | `conversation_create` → `conversation_turn_1` → `conversation_turn_2` | Step 1 creates a conversation resource (`POST /conversations`); step 2 reply contains `starscream`; step 3 reply to "Who does he serve?" contains `megatron` or `decepticon` (only correct if the platform replayed step 2 under the same conversation id) |

Rule 4 (brevity) is intentionally not asserted — length-based assertions tend to be flaky across model versions.

---

## Runner

[deployment/smoke-tests.py](../deployment/smoke-tests.py) is a single-file Python script with no third-party dependencies (stdlib only — `argparse`, `json`, `urllib`, `subprocess`).

### CLI

```text
smoke-tests.py
  --project-endpoint URL         (required) Foundry project endpoint
  --agent-name NAME              (required, repeatable) Agent to test; repeat to test more than one
  --tests-file PATH              (optional) JSON catalog (default: ./smoke-tests.json next to the script)
  --timeout SECONDS              (optional) Per-request timeout (default: 120)
```

Each `--agent-name` runs the full catalog against that agent. Per-agent results are summarised at the end. Counts are at the **step** granularity (e.g. `9/9 passed`); see [Test scenarios](#test-scenarios) for how steps group into scenarios. Exit code is **0** when every step passes for every agent, **1** if any step failed, **2** for runner errors (missing tests file, token acquisition failure).

### Example

```bash
python3 deployment/smoke-tests.py \
  --project-endpoint "https://ai-account-xxx.services.ai.azure.com/api/projects/ai-project" \
  --agent-name agent-framework-agent-basic-responses \
  --agent-name agent-framework-agent-basic-responses-src
```

### Authentication

The runner requires a bearer token scoped to the Foundry data plane (`https://ai.azure.com/`). Token acquisition order:

1. If the `FOUNDRY_TOKEN` environment variable is set, it is used verbatim. This is how CI passes a pre-acquired token and how callers can override the default.
2. Otherwise the runner shells out to `az account get-access-token --resource https://ai.azure.com/` and uses the returned token. This is what happens locally — you must have run `az login` first.

The runner does **not** use `az rest` — that command does not reliably acquire the correct audience token for the Foundry data plane.

### Response-shape tolerance

The runner accepts both shapes the Responses endpoint can return:

- `payload["output_text"]` — flat string convenience field
- `payload["output"][*]["content"][*]["text"]` — structured output array, joined with newlines

If neither is present, the assertion text is empty and any `contains_*` rule will fail with a readable preview of the raw response.

---

## Running locally

### As part of a deploy

Both shell scripts invoke the runner as Step 8 by default. See [Deploying with Bicep](./deploy-bicep.md#what-each-step-does) and [Deploying with Terraform](./deploy-terraform.md#what-each-step-does) for the integration details.

### As part of an azd deploy

Both `azure-bicep.yaml` and `azure-terraform.yaml` register a `postdeploy` hook that runs [`deployment/scripts/run-smoke-tests.sh`](../deployment/scripts/run-smoke-tests.sh) after the `azure.ai.agents` extension creates the agent version. The hook is automatic for `azd up` and `azd deploy` — no extra wiring required. azd auto-injects `AZURE_AI_PROJECT_ENDPOINT` from infra outputs into the hook process.

Overrides (all via `azd env set` or one-shot `VAR=... azd up`):

| Variable | Default | Effect |
|---|---|---|
| `SMOKE_TEST` | `true` | Set to `false` to skip the postdeploy hook entirely |
| `AGENT_NAME` | `agent-framework-agent-basic-responses` | Override when the service has been renamed in `azure.yaml` |

The azd flow only deploys the image-based agent (not the source-code variant), so the hook smoke-tests one agent per `azd up`. For both variants, use the shell scripts.

### Standalone

To re-run smoke tests against an already-deployed agent without re-deploying:

```bash
# Get the project endpoint from your IaC outputs
PROJECT_ENDPOINT=$(az cognitiveservices account show \
  --name <ai-account> --resource-group <rg> \
  --query 'properties.endpoints["AI Foundry API"]' -o tsv)/api/projects/<project-name>

python3 deployment/smoke-tests.py \
  --project-endpoint "$PROJECT_ENDPOINT" \
  --agent-name agent-framework-agent-basic-responses-src
```

For Terraform users, `terraform output -raw AZURE_AI_PROJECT_ENDPOINT` (run from `infra/terraform/`) prints the value directly.

---

## In CI

The `smoke-test` composite action ([action.yml](../.github/actions/smoke-test/action.yml)) wraps the runner for GitHub Actions. It runs **four times per pipeline** — once per agent variant × IaC tool:

| Workflow | Job | Agent name passed |
|---|---|---|
| `deploy-bicep.yml` | `update-agent` | `${{ inputs.agent_name }}` |
| `deploy-bicep.yml` | `update-agent-source-code` | `${{ inputs.agent_name }}-src` |
| `deploy-terraform.yml` | `update-agent` | `${{ inputs.agent_name }}` |
| `deploy-terraform.yml` | `update-agent-source-code` | `${{ inputs.agent_name }}-src` |

The smoke step is the **last step** of each update job. A smoke failure fails that single update job — parallel jobs (the other agent variant, or the other IaC tool entirely) continue running independently. See [GitHub Actions — Smoke tests in CI](./github-actions.md#smoke-tests-in-ci) for the full job context.

The composite action assumes the caller has already run `actions/checkout@v6` (so the runner script and catalog are on disk) and `azure/login@v3` (so the runner can call `az account get-access-token`). It does not perform either itself.

---

## Adding a new scenario

1. Add one or more entries to the `tests` array in [smoke-tests.json](../deployment/smoke-tests.json) — one entry per HTTP step. Single-step scenarios are a single entry; multi-step scenarios chain entries via `save_response_id_as` → `use_previous_response_id` or `create_conversation_as` → `use_conversation`. Pick a unique `id` for each step.
2. Keep assertions **broad enough to cover any reasonable phrasing** the agent might use. The original `no_hallucination` step only matched `does not happen` / `did not happen`; the agent answered with `does not marry` and `no storyline` and the step failed. Broadening `contains_any` to include `does not`, `doesn't`, `no storyline`, etc. fixed it.
3. Run the runner locally against your deployed agent (see [Standalone](#standalone)) until N/N passes.
4. Commit. CI will pick up the change automatically — the runner reads the catalog at runtime from the checked-out repo.

To assert HTTP failure instead of a 200, set `"assertions": {"status": 4xx}`. To pin negative semantics, combine `contains_any` (must include an honest marker) with `contains_none` (must not include the off-topic answer), as the `offtopic_refusal` scenario does.

---

## Troubleshooting

| Failure | Likely cause | Fix |
|---|---|---|
| All tests time out | Agent is cold-starting; first request can take longer than 120s | Re-run, or pass `--timeout 180` |
| One test asserts `contains_any` but the response is reasonable | Assertion list is too narrow for the way the model phrased its answer | Broaden the `contains_any` list. See the `no_hallucination` history. |
| `HTTP 404` on every test | Agent name does not exist in the project | Check spelling; image-based vs source-code agents use different names (`-src` suffix for source-code in this repo's deploy scripts and CI) |
| `HTTP 401/403` | Token has the wrong audience, or RBAC has not propagated | Make sure you ran `az login` and have **Foundry Project Manager** at the project scope. If the deploy script ran with `--skip-rbac`, the step prints a warning. |
| Runner exits with code 2 immediately | `smoke-tests.json` not found, or `az` not on `PATH` | Check the `--tests-file` path; install or login with Azure CLI |
| `contains_any: none of [...] found` with a preview that looks correct | Substring matching is case-insensitive but exact — punctuation or whitespace differences can still miss | Add the literal phrasing the agent used to the list |
