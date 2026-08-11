#!/usr/bin/env python3
"""Run a bounded batch of client hardening audits on one provisioned runner."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def client_environment(base: dict[str, str], client: dict[str, Any]) -> dict[str, str]:
    env = dict(base)
    required = (
        "repo",
        "org",
        "name",
        "prefix",
        "zed_org",
        "zed_name",
        "zed_coordinate",
        "default_branch",
        "test_org",
    )
    missing = [key for key in required if not isinstance(client.get(key), str) or not client[key]]
    if missing:
        raise ValueError("missing client fields: " + ", ".join(missing))
    env.update(
        {
            "CLIENT_REPO": client["repo"],
            "CLIENT_ORG": client["org"],
            "CLIENT_NAME": client["name"],
            "CLIENT_PREFIX": client["prefix"],
            "ZED_ORG": client["zed_org"],
            "ZED_NAME": client["zed_name"],
            "ZED_COORDINATE": client["zed_coordinate"],
            "DEFAULT_BRANCH": client["default_branch"],
            "TEST_ORG": client["test_org"],
            "CONSUMERS_JSON": compact(client.get("consumers", [])),
            "TEST_CONSUMERS_JSON": compact(client.get("test_consumers", [])),
            "DISCOVERY_ERRORS_JSON": compact(client.get("errors", [])),
            "DISCOVERY_WARNINGS_JSON": compact(client.get("warnings", [])),
        }
    )
    return env


def write_clone_failure(workspace: Path, client: dict[str, Any], result: subprocess.CompletedProcess[str]) -> None:
    report = workspace / "reports" / f"{client.get('org', 'unknown')}__{client.get('name', 'unknown')}"
    report.mkdir(parents=True, exist_ok=True)
    (report / "clone-target.log").write_text((result.stdout or "") + (result.stderr or ""), encoding="utf-8")
    (report / "clone-target.exit-code").write_text(f"{result.returncode}\n", encoding="utf-8")
    run_url = (
        f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
        f"{os.environ.get('GITHUB_REPOSITORY', 'zed-pkg/.github')}/actions/runs/"
        f"{os.environ.get('GITHUB_RUN_ID', 'unknown')}"
    )
    summary = (
        f"# {client.get('repo', 'unknown')} nightly hardening\n\n"
        "- final status: **failed**\n"
        f"- blocker: target repository clone failed with exit code {result.returncode}\n"
        f"- run: {run_url}\n"
    )
    (report / "summary.md").write_text(summary, encoding="utf-8")


def main() -> int:
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    clients = json.loads(os.environ.get("CLIENTS_JSON", "[]"))
    if not isinstance(clients, list) or not clients:
        print("CLIENTS_JSON must be a non-empty JSON array", file=sys.stderr)
        return 2

    failed = False
    for position, client in enumerate(clients, start=1):
        if not isinstance(client, dict):
            print(f"batch item {position} is not an object", file=sys.stderr)
            failed = True
            continue
        repo = str(client.get("repo", "unknown"))
        print(f"::group::prepare {repo}")
        fleet = workspace / "fleet-workspace"
        shutil.rmtree(fleet, ignore_errors=True)
        (fleet / "consumers").mkdir(parents=True, exist_ok=True)
        target = fleet / "target"
        clone = subprocess.run(
            [
                "gh",
                "repo",
                "clone",
                repo,
                str(target),
                "--",
                "--branch",
                str(client.get("default_branch") or "main"),
                "--no-single-branch",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if clone.stdout:
            print(clone.stdout, end="")
        if clone.stderr:
            print(clone.stderr, end="", file=sys.stderr)
        print("::endgroup::")
        if clone.returncode != 0:
            write_clone_failure(workspace, client, clone)
            failed = True
            continue

        try:
            env = client_environment(os.environ, client)
        except ValueError as error:
            print(f"::{repo}::error::{error}", file=sys.stderr)
            failed = True
            continue
        result = subprocess.run(
            ["bash", str(workspace / "tools" / "audit_harden_client.sh")],
            cwd=workspace,
            env=env,
            check=False,
        )
        if result.returncode != 0:
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
