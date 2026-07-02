# Evaluations

This directory holds the **agent evaluation gate** — the offline evaluation that runs against every new agent version created in Foundry, both locally (Step 9 of the deploy scripts) and in CI (composite action `.github/actions/agent-eval`).

The runner is [`microsoft/ai-agent-evals@v3-beta`](https://github.com/microsoft/ai-agent-evals). This directory contains its native input format — what's here is exactly what the action reads. No custom schema, no split, no runtime merge.

## Files

| File | Purpose |
|---|---|
| `promotion-gate.json` | Single-file config: evaluator list + test dataset. Consumed by `microsoft/ai-agent-evals`. |
| `README.md` | This file. |

## Schema

`promotion-gate.json` follows the [ai-agent-evals data file schema](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/README.md#data-file):

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Evaluation dataset name (appears in Foundry portal + GH summary) |
| `evaluators` | string[] | yes | Evaluator IDs from the [Foundry evaluator catalog](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/observability#evaluators). Built-ins are prefixed `builtin.`. |
| `data` | object[] | yes | Test rows. Each row must have a `query` and (for reference-based evaluators) a `ground_truth`. |
| `data_mapping` | object | no | Field renaming. Omitted here — our rows use the standard `query` / `ground_truth` names, so auto-mapping works. |
| `evaluator_parameters` | object | no | Per-evaluator thresholds. Omitted — we rely on ai-agent-evals defaults + statistical-significance regression vs. baseline. |

## Current evaluators

| Evaluator | Category | Scale | Higher is | Reads |
|---|---|---|---|---|
| `builtin.task_adherence` | Agent | 1–5 Likert | better | `query`, response |
| `builtin.coherence` | Quality | 1–5 Likert | better | response |
| `builtin.fluency` | Quality | 1–5 Likert | better | response |
| `builtin.f1_score` | RAG (text similarity) | 0–1 | better | response, `ground_truth` |
| `builtin.violence` | Safety | 0–7 severity | worse | response |
| `builtin.self_harm` | Safety | 0–7 severity | worse | response |
| `builtin.hate_unfairness` | Safety | 0–7 severity | worse | response |

Pass/fail comes from ai-agent-evals' built-in statistical-significance regression check against the previous serving agent version. Absolute thresholds are not enforced here in v1 — revisit if signal proves insufficient.

## Current dataset

`promotion-gate.json` has 30 rows targeted at the four rules encoded in the Transformers agent's system prompt (see `src/agent-framework/responses/basic/main.py`):

| Group | Rows | What it exercises |
|---|---|---|
| On-topic Transformers facts | 12 | Rule 4 (accuracy + brevity); `task_adherence`, `f1_score` |
| Off-topic refusal | 6 | Rule 1 (verbatim refusal message) |
| No-hallucination | 6 | Rule 2 (say "I don't know" / "I'm not certain") |
| Continuity-awareness | 6 | Rule 3 (explicitly name G1 / Bayverse / IDW / Prime / etc.) |

The on-topic set mixes continuities intentionally so `task_adherence` and `f1_score` reward answers that stay factual across the whole franchise, not just one series.

## How to change things

### Add a test row

Append an object to `data`:

```json
{ "query": "Your question here", "ground_truth": "The response you expect." }
```

Keep the shape identical to existing rows. `ground_truth` is used by `f1_score`; the LLM-judge evaluators (`task_adherence`, `coherence`, `fluency`, safety) evaluate the response against the `query` semantics, not verbatim string match.

### Add or remove an evaluator

Edit the `evaluators` array. Use the exact ID from the Foundry catalog (portal → **Build → Evaluations → Evaluator catalog**). If the evaluator needs a custom threshold, add it under a new `evaluator_parameters` top-level key — see the [samples in ai-agent-evals](https://github.com/microsoft/ai-agent-evals/tree/v3-beta/samples/data) for shape.

### Change the field names in `data`

If you rename `query` → `input` or `ground_truth` → `expected`, add a `data_mapping` top-level key mapping the evaluator input names to your row field names. See [`dataset-data-mapping.json`](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/samples/data/dataset-data-mapping.json) for the shape.

## Reading the GH Actions summary

After a CI run the **Actions** tab shows a per-evaluator table with mean scores, 95% confidence intervals, and a statistical-significance marker (baseline vs. new). The gate fails when a metric regresses at statistical significance.

## Local iteration

Once Step 9 is wired into `deployment/deploy-*.sh`, you can iterate on this dataset without redeploying the agent:

```bash
# Deploy once, skipping eval
./deployment/deploy-bicep.sh --skip-infra --skip-eval

# Then edit evals/promotion-gate.json and re-run Step 9 against the same version
# (invocation TBD in Phase 2)
```

## Cost

~$0.20–$1.00 per run, 3–6 minutes. 30 rows × ~7 evaluators × 2 versions (new + baseline). Judge-model tokens dominate.

## Related

- [ai-agent-evals README](https://github.com/microsoft/ai-agent-evals/blob/v3-beta/README.md)
- [Foundry evaluator catalog](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/observability#evaluators)
- [Foundry cloud evaluation prerequisites](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/cloud-evaluation#prerequisites) (minimum role: Foundry User)
