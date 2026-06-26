#!/usr/bin/env python3
"""Smoke-test runner for Foundry hosted agents using the Responses protocol.

Reads test cases from a JSON catalog (default: ./smoke-tests.json next to this
script), POSTs each prompt to every supplied agent's Responses endpoint, and
asserts case-insensitive substring rules on the response text.

Designed for CI re-use:
- stdlib only (no pip deps)
- non-zero exit on any failure
- per-agent thread isolation for multi-turn cases
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# Bearer-token audience for the Foundry data plane. Tokens scoped to
# cognitiveservices.azure.com are rejected with 401 by this endpoint.
DATA_PLANE_SCOPE = "https://ai.azure.com/"

# Pinned because the Responses endpoint is preview and breaking changes occur
# without a stable redirect. Bump in lockstep with the deploy scripts.
API_VERSION = "2025-11-15-preview"


def acquire_token() -> str:
    # Two paths, in priority order:
    #   1. FOUNDRY_TOKEN  — CI passes a pre-acquired token so the runner
    #      doesn't need the az CLI installed on the runner image.
    #   2. az fallback    — local interactive use after `az login`.
    # Acquired once and reused for every request to every agent: data-plane
    # tokens last ~60 min and a smoke run completes in seconds.
    token = os.environ.get("FOUNDRY_TOKEN")
    if token:
        return token
    result = subprocess.run(
        ["az", "account", "get-access-token", "--resource", DATA_PLANE_SCOPE, "--query", "accessToken", "-o", "tsv"],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


def extract_text(payload: dict[str, Any]) -> str:
    """Pull the response text out of an OpenAI-Responses-shaped payload."""
    # The Responses API can return text two ways. Prefer the flat convenience
    # field; fall back to walking the structured `output[*].content[*]` blocks.
    # `or []` guards against the keys being present but explicitly None.
    if isinstance(payload.get("output_text"), str):
        return payload["output_text"]
    parts: list[str] = []
    for item in payload.get("output", []) or []:
        for content in item.get("content", []) or []:
            text = content.get("text")
            if isinstance(text, str):
                parts.append(text)
            elif isinstance(text, dict) and isinstance(text.get("value"), str):
                parts.append(text["value"])
    return "\n".join(parts)


def post_response(project_endpoint: str, agent_name: str, token: str, prompt: str,
                  previous_response_id: str | None, timeout: float) -> tuple[int, dict[str, Any], str]:
    # The Responses data-plane URL. `previous_response_id` threads turns
    # together server-side — omitting it starts a fresh conversation.
    url = (
        f"{project_endpoint.rstrip('/')}/agents/{agent_name}"
        f"/endpoint/protocols/openai/responses?api-version={API_VERSION}"
    )
    body: dict[str, Any] = {"input": prompt}
    if previous_response_id:
        body["previous_response_id"] = previous_response_id
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    # Connection-level failures (URLError, timeout) are deliberately not
    # caught — they bubble up and crash the runner so an unreachable agent
    # fails loudly instead of looking like an assertion failure.
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - controlled URL
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw) if raw else {}, raw
    except urllib.error.HTTPError as e:
        # 4xx/5xx: still read the body so the caller can show it in the
        # failure message. Foundry returns JSON errors most of the time but
        # some 5xx come back as plain text, hence the JSONDecodeError guard.
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw), raw
        except json.JSONDecodeError:
            return e.code, {}, raw


def check_assertions(text: str, assertions: dict[str, Any]) -> list[str]:
    """Return a list of human-readable failure reasons (empty = pass)."""
    # Returns a list (not bool) so a single test that fails multiple
    # assertions prints every reason at once — saves a re-run to find the
    # next failure. All matches are case-insensitive substring checks;
    # missing assertion keys are skipped, not failed.
    failures: list[str] = []
    lower = text.lower()

    # contains_any: at least one of these substrings must appear
    any_required = assertions.get("contains_any") or []
    if any_required and not any(s.lower() in lower for s in any_required):
        failures.append(f"contains_any: none of {any_required!r} found")

    # contains_all: every one of these substrings must appear
    all_required = assertions.get("contains_all") or []
    missing = [s for s in all_required if s.lower() not in lower]
    if missing:
        failures.append(f"contains_all: missing {missing!r}")

    # contains_none: none of these substrings may appear
    forbidden = assertions.get("contains_none") or []
    present = [s for s in forbidden if s.lower() in lower]
    if present:
        failures.append(f"contains_none: forbidden {present!r} present")

    return failures


def run_agent(project_endpoint: str, agent_name: str, tests: list[dict[str, Any]],
              token: str, timeout: float) -> tuple[int, int]:
    """Run all tests against one agent. Returns (passed, total)."""
    print(f"\n--- Agent: {agent_name} ---")
    # response_ids is reset per agent so the same thread key used by 
    # two agents doesn't cross-contaminate —
    # each agent has its own server-side conversation.
    response_ids: dict[str, str] = {}
    passed = 0
    for test in tests:
        tid = test["id"]
        prompt = test["prompt"]

        # Resolve a stored previous_response_id if this test continues a
        # thread. Failing when the key was never saved catches catalog
        # typos at runtime instead of silently dropping the thread link.
        prev_key = test.get("use_previous_response_id")
        prev_id = response_ids.get(prev_key) if prev_key else None
        if prev_key and not prev_id:
            print(f"  FAIL  {tid}: previous_response_id key {prev_key!r} not set by an earlier test")
            continue

        status, payload, raw = post_response(
            project_endpoint, agent_name, token, prompt, prev_id, timeout,
        )

        # Status assertion (default 200). A test can override with
        # assertions.status to exercise a deliberate 4xx response.
        expected_status = test.get("assertions", {}).get("status", 200)
        if status != expected_status:
            preview = raw[:300].replace("\n", " ")
            print(f"  FAIL  {tid}: HTTP {status} (expected {expected_status}) — {preview}")
            continue

        # Content assertions. On failure include a preview of what the agent
        # actually said — critical for diagnosing "why didn't my regex match"
        # without having to re-run the test manually.
        text = extract_text(payload)
        failures = check_assertions(text, test.get("assertions", {}))
        if failures:
            preview = text[:300].replace("\n", " ")
            print(f"  FAIL  {tid}: {'; '.join(failures)}")
            print(f"        response: {preview}")
            continue

        # Capture the response id for use by a later turn. Failing when
        # `id` is missing prevents a downstream use_previous_response_id
        # test from silently sending without thread context.
        save_key = test.get("save_response_id_as")
        if save_key:
            rid = payload.get("id")
            if not rid:
                print(f"  FAIL  {tid}: response had no id field (cannot thread)")
                continue
            response_ids[save_key] = rid

        passed += 1
        print(f"  PASS  {tid}")

    print(f"  → {passed}/{len(tests)} passed for {agent_name}")
    return passed, len(tests)


def main() -> int:
    # Default catalog is the sibling smoke-tests.json so callers can run the
    # script from any cwd (e.g. azd hooks run from deployment/).
    default_tests = Path(__file__).resolve().parent / "smoke-tests.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-endpoint", required=True,
                        help="Foundry project endpoint, e.g. https://<acct>.services.ai.azure.com/api/projects/<proj>")
    # action="append" so the same flag can be repeated to run the catalog
    # against multiple agents in one invocation (image-based + source-code).
    parser.add_argument("--agent-name", required=True, action="append", dest="agent_names",
                        help="Agent name to test. Repeat to test multiple agents.")
    parser.add_argument("--tests-file", default=str(default_tests),
                        help=f"Path to test catalog JSON (default: {default_tests}).")
    # 120s default covers cold-start of the hosted agent micro-VM; subsequent
    # requests in the same run are typically sub-second.
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="Per-request timeout in seconds (default: 120).")
    args = parser.parse_args()

    # Exit code 2 (not 1) for runner errors so CI can distinguish "smoke
    # tests ran and something failed" (1) from "the runner couldn't even
    # start" (2). The shell scripts treat both as failure but the signal is
    # there if needed.
    tests_path = Path(args.tests_file)
    if not tests_path.is_file():
        print(f"ERROR: tests file not found: {tests_path}", file=sys.stderr)
        return 2
    catalog = json.loads(tests_path.read_text())
    tests = catalog.get("tests") or []
    if not tests:
        print(f"ERROR: no tests found in {tests_path}", file=sys.stderr)
        return 2

    try:
        token = acquire_token()
    except subprocess.CalledProcessError as e:
        print(f"ERROR: failed to acquire token via az: {e.stderr}", file=sys.stderr)
        return 2

    # Run header. Echoed to CI logs so failure investigations don't have to
    # cross-reference workflow inputs to know which agent/endpoint was hit.
    print(f"Project endpoint : {args.project_endpoint}")
    print(f"Tests            : {len(tests)} from {tests_path.name}")
    print(f"Agents           : {', '.join(args.agent_names)}")
    print(f"Per-req timeout  : {args.timeout}s")

    total_passed = 0
    total = 0
    for agent in args.agent_names:
        p, t = run_agent(args.project_endpoint, agent, tests, token, args.timeout)
        total_passed += p
        total += t

    print(f"\n=== Summary: {total_passed}/{total} passed across {len(args.agent_names)} agent(s) ===")
    # Exit 0 only when every test passed for every agent. Any test failure
    # → 1, runner error → 2 (handled above).
    return 0 if total_passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
