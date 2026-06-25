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

DATA_PLANE_SCOPE = "https://ai.azure.com/"
API_VERSION = "2025-11-15-preview"


def acquire_token() -> str:
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
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - controlled URL
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw) if raw else {}, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw), raw
        except json.JSONDecodeError:
            return e.code, {}, raw


def check_assertions(text: str, assertions: dict[str, Any]) -> list[str]:
    """Return a list of human-readable failure reasons (empty = pass)."""
    failures: list[str] = []
    lower = text.lower()

    any_required = assertions.get("contains_any") or []
    if any_required and not any(s.lower() in lower for s in any_required):
        failures.append(f"contains_any: none of {any_required!r} found")

    all_required = assertions.get("contains_all") or []
    missing = [s for s in all_required if s.lower() not in lower]
    if missing:
        failures.append(f"contains_all: missing {missing!r}")

    forbidden = assertions.get("contains_none") or []
    present = [s for s in forbidden if s.lower() in lower]
    if present:
        failures.append(f"contains_none: forbidden {present!r} present")

    return failures


def run_agent(project_endpoint: str, agent_name: str, tests: list[dict[str, Any]],
              token: str, timeout: float) -> tuple[int, int]:
    """Run all tests against one agent. Returns (passed, total)."""
    print(f"\n--- Agent: {agent_name} ---")
    response_ids: dict[str, str] = {}
    passed = 0
    for test in tests:
        tid = test["id"]
        prompt = test["prompt"]
        prev_key = test.get("use_previous_response_id")
        prev_id = response_ids.get(prev_key) if prev_key else None
        if prev_key and not prev_id:
            print(f"  FAIL  {tid}: previous_response_id key {prev_key!r} not set by an earlier test")
            continue

        status, payload, raw = post_response(
            project_endpoint, agent_name, token, prompt, prev_id, timeout,
        )

        expected_status = test.get("assertions", {}).get("status", 200)
        if status != expected_status:
            preview = raw[:300].replace("\n", " ")
            print(f"  FAIL  {tid}: HTTP {status} (expected {expected_status}) — {preview}")
            continue

        text = extract_text(payload)
        failures = check_assertions(text, test.get("assertions", {}))
        if failures:
            preview = text[:300].replace("\n", " ")
            print(f"  FAIL  {tid}: {'; '.join(failures)}")
            print(f"        response: {preview}")
            continue

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
    default_tests = Path(__file__).resolve().parent / "smoke-tests.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-endpoint", required=True,
                        help="Foundry project endpoint, e.g. https://<acct>.services.ai.azure.com/api/projects/<proj>")
    parser.add_argument("--agent-name", required=True, action="append", dest="agent_names",
                        help="Agent name to test. Repeat to test multiple agents.")
    parser.add_argument("--tests-file", default=str(default_tests),
                        help=f"Path to test catalog JSON (default: {default_tests}).")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="Per-request timeout in seconds (default: 120).")
    args = parser.parse_args()

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
    return 0 if total_passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
