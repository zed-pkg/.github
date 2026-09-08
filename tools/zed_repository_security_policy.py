#!/usr/bin/env python3
"""Compatibility policy layer for the Zed repository security auditor.

The v1 auditor intentionally classified unknown evidence conservatively. This
layer makes two repository conventions explicit without weakening the boundary:
root-level ``agents.md`` is accepted as the canonical instruction file, and a
public ``.envrc`` is evaluated by content rather than by its filename alone.
Plaintext dotenv loading, dynamic environment sources, committed sensitive
assignments, malformed shell syntax, unreadable files, and credential-shaped
literals remain findings.
"""

from __future__ import annotations

import re
import shlex
from pathlib import PurePosixPath
from typing import Final, Sequence

import zed_repository_security_audit as core

_DOTENV_COMMANDS: Final = {"dotenv", "dotenv_if_exists"}
_SOURCE_COMMANDS: Final = {"source", ".", "source_env", "source_env_if_exists"}
_SENSITIVE_ASSIGNMENT_RE: Final = re.compile(
    r"^(?:export\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY|DATABASE_URL|API_KEY)[A-Za-z0-9_]*)\s*=\s*(?P<value>.*)$",
    re.I,
)
_SIMPLE_ENV_REFERENCE_RE: Final = re.compile(
    r"^(?:['\"])?\$\{?[A-Za-z_][A-Za-z0-9_]*(?::[-?+][^}]*)?\}?(?:['\"])?$"
)


def _root_has_agent_instructions(paths: Sequence[str]) -> bool:
    return any(
        PurePosixPath(path).parent == PurePosixPath(".")
        and PurePosixPath(path).name.lower() == "agents.md"
        for path in paths
    )


def _is_dynamic_path(path: str) -> bool:
    return any(marker in path for marker in ("$", "`", "$("))


def _envrc_findings(snapshot: core.RepoSnapshot, text: str) -> list[core.Finding]:
    findings: list[core.Finding] = []
    path = ".envrc"

    for number, raw_line in enumerate(text.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            words = shlex.split(stripped, comments=True, posix=True)
        except ValueError as error:
            findings.append(
                core._finding(
                    snapshot,
                    "critical",
                    "envrc-shell-syntax-unparseable",
                    f"line {number} cannot be parsed safely: {error}",
                    path,
                )
            )
            continue
        if not words:
            continue

        command = words[0]
        if command in _DOTENV_COMMANDS:
            target = words[1] if len(words) > 1 else ".env"
            if _is_dynamic_path(target):
                findings.append(
                    core._finding(
                        snapshot,
                        "error",
                        "envrc-dynamic-environment-source",
                        f"line {number} computes a dotenv path that cannot be audited statically",
                        path,
                    )
                )
            elif core._is_plaintext_env(target):
                findings.append(
                    core._finding(
                        snapshot,
                        "critical",
                        "envrc-loads-plaintext-environment",
                        f"line {number} loads plaintext environment file `{target}`",
                        path,
                    )
                )

        if command in _SOURCE_COMMANDS and len(words) > 1:
            target = words[1]
            if _is_dynamic_path(target):
                findings.append(
                    core._finding(
                        snapshot,
                        "error",
                        "envrc-dynamic-environment-source",
                        f"line {number} computes a sourced path that cannot be audited statically",
                        path,
                    )
                )
            elif core._is_plaintext_env(target):
                findings.append(
                    core._finding(
                        snapshot,
                        "critical",
                        "envrc-sources-plaintext-environment",
                        f"line {number} sources plaintext environment file `{target}`",
                        path,
                    )
                )

        assignment = _SENSITIVE_ASSIGNMENT_RE.match(stripped)
        if assignment:
            value = assignment.group("value").strip()
            if value and not _SIMPLE_ENV_REFERENCE_RE.fullmatch(value):
                findings.append(
                    core._finding(
                        snapshot,
                        "critical",
                        "envrc-sensitive-assignment",
                        f"line {number} assigns `{assignment.group('name')}` from committed literal or executable content",
                        path,
                    )
                )

    findings.extend(core._secret_findings(snapshot, path, text))
    return sorted(set(findings))


def hardened_audit_snapshot(
    client: core.GitHubClient,
    snapshot: core.RepoSnapshot,
) -> list[core.Finding]:
    """Apply content-aware Zed policy to one immutable repository snapshot."""

    findings = list(_BASE_AUDIT_SNAPSHOT(client, snapshot))
    has_root_agents = _root_has_agent_instructions(snapshot.paths)
    filtered = [
        finding
        for finding in findings
        if not (
            finding.code == "public-plaintext-environment"
            and finding.path == ".envrc"
        )
        and not (
            finding.code == "agents-instructions-missing"
            and has_root_agents
        )
    ]

    if not snapshot.private and ".envrc" in snapshot.paths:
        text = client.text(snapshot.full_name, ".envrc", snapshot.default_sha)
        if text is None:
            filtered.append(
                core._finding(
                    snapshot,
                    "critical",
                    "envrc-unreadable",
                    "public .envrc is listed in the tree but its exact content is unavailable",
                    ".envrc",
                )
            )
        else:
            filtered.extend(_envrc_findings(snapshot, text))

    return sorted(set(filtered))


_BASE_AUDIT_SNAPSHOT = core.audit_snapshot


def main(argv: Sequence[str] | None = None) -> int:
    core.audit_snapshot = hardened_audit_snapshot
    return core.main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
