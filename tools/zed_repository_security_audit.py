#!/usr/bin/env python3
"""Read-only, fail-closed security audit for repositories in a GitHub organization.

The existing ``zed_fleet_audit.py`` validates package-family topology.  This
companion checks repository-level invariants that are easy to regress across a
large fleet: workflow pinning and trust boundaries, plaintext environment
files, generated-code provenance markers, manifest/lock consistency, and
backend repository visibility.

The auditor never mutates GitHub.  It emits deterministic JSON and Markdown
receipts and can be configured to fail on warning, error, or critical findings.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any, Final

API: Final = "https://api.github.com"
USER_AGENT: Final = "zed-repository-security-audit/1"
MAX_TEXT_BYTES: Final = 512 * 1024
SEVERITY_RANK: Final = {"warning": 1, "error": 2, "critical": 3}

# Deliberately concatenate well-known prefixes so this source file is not itself
# mistaken for a credential by simple repository scanners.
SECRET_PATTERNS: Final[tuple[tuple[str, re.Pattern[str]], ...]] = (
    (
        "github-classic-pat",
        re.compile("gh" + r"p_[A-Za-z0-9]{30,}"),
    ),
    (
        "github-fine-grained-pat",
        re.compile("github" + r"_pat_[A-Za-z0-9_]{40,}"),
    ),
    (
        "linear-api-token",
        re.compile("lin" + r"_api_[A-Za-z0-9]{30,}"),
    ),
    (
        "aws-access-key",
        re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    ),
    (
        "private-key",
        re.compile("-----BEGIN " + r"(?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ),
)

USES_RE: Final = re.compile(r"^\s*-?\s*uses\s*:\s*['\"]?([^\s'\"#]+)", re.M)
WRITE_ALL_RE: Final = re.compile(r"^\s*permissions\s*:\s*write-all\s*(?:#.*)?$", re.M)
PERMISSIONS_RE: Final = re.compile(r"^permissions\s*:", re.M)
PULL_REQUEST_TARGET_RE: Final = re.compile(r"^\s*pull_request_target\s*:", re.M)
UNTRUSTED_HEAD_RE: Final = re.compile(
    r"github\.event\.pull_request\.(?:head\.(?:sha|ref)|head\.repo\.full_name)"
)
EVENT_TEXT_IN_RUN_RE: Final = re.compile(
    r"\$\{\{\s*github\.event\.(?:issue|pull_request|comment)\.(?:title|body)\s*\}\}"
)
PIPE_TO_SHELL_RE: Final = re.compile(
    r"(?:curl|wget)[^\n|]*\|\s*(?:sudo\s+)?(?:ba|z|k)?sh\b",
    re.I,
)
PERSIST_CREDENTIALS_RE: Final = re.compile(
    r"^\s*persist-credentials\s*:\s*true\s*(?:#.*)?$",
    re.M | re.I,
)

BACKEND_PRIVATE_PATTERNS: Final[tuple[re.Pattern[str], ...]] = (
    re.compile(r"(?:^|-)orm-core$"),
    re.compile(r"(?:^|-)admin-api-server(?:\.rs)?$"),
    re.compile(r"(?:^|-)admin-web-server(?:\.rs)?$"),
)

PLAIN_ENV_EXEMPT_BASENAMES: Final = {
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.schema",
    ".env.enc",
}


class AuditAPIError(RuntimeError):
    """GitHub returned a response that prevents a trustworthy audit."""


@dataclasses.dataclass(frozen=True, order=True)
class Finding:
    severity: str
    code: str
    repository: str
    path: str
    message: str

    def as_dict(self) -> dict[str, str]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class RepoSnapshot:
    full_name: str
    name: str
    private: bool
    archived: bool
    disabled: bool
    default_branch: str
    default_sha: str
    tree_sha: str
    paths: tuple[str, ...]
    truncated_tree: bool


class GitHubClient:
    """Small GitHub REST client with bounded retries and pagination."""

    def __init__(self, token: str, *, timeout_seconds: int = 30) -> None:
        if not token.strip():
            raise ValueError("token must not be blank")
        self._token = token
        self._timeout_seconds = timeout_seconds

    def _request(self, path: str) -> Any:
        request = urllib.request.Request(
            API + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "User-Agent": USER_AGENT,
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout_seconds) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            remaining = error.headers.get("x-ratelimit-remaining")
            reset = error.headers.get("x-ratelimit-reset")
            suffix = ""
            if remaining == "0":
                suffix = f" (rate limit exhausted; reset={reset or 'unknown'})"
            raise AuditAPIError(f"HTTP {error.code} GET {path}{suffix}: {body[:1000]}") from error
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise AuditAPIError(f"GET {path} failed: {error}") from error

    def repositories(self, org: str) -> list[dict[str, Any]]:
        output: list[dict[str, Any]] = []
        page = 1
        while True:
            encoded = urllib.parse.quote(org, safe="")
            batch = self._request(
                f"/orgs/{encoded}/repos?type=all&sort=full_name&direction=asc&per_page=100&page={page}"
            )
            if not isinstance(batch, list):
                raise AuditAPIError(f"repository inventory for {org} was not a list")
            output.extend(item for item in batch if isinstance(item, dict))
            if len(batch) < 100:
                return output
            page += 1

    def snapshot(self, repo: Mapping[str, Any]) -> RepoSnapshot:
        full_name = str(repo.get("full_name") or "")
        name = str(repo.get("name") or "")
        default_branch = str(repo.get("default_branch") or "")
        if not full_name or not name or not default_branch:
            raise AuditAPIError(f"repository metadata is incomplete: {repo!r}")

        encoded_repo = "/".join(urllib.parse.quote(part, safe="") for part in full_name.split("/"))
        branch = self._request(
            f"/repos/{encoded_repo}/branches/{urllib.parse.quote(default_branch, safe='')}"
        )
        try:
            default_sha = str(branch["commit"]["sha"])
            tree_sha = str(branch["commit"]["commit"]["tree"]["sha"])
        except (KeyError, TypeError) as error:
            raise AuditAPIError(f"branch metadata is incomplete for {full_name}:{default_branch}") from error

        tree = self._request(f"/repos/{encoded_repo}/git/trees/{tree_sha}?recursive=1")
        if not isinstance(tree, dict) or not isinstance(tree.get("tree"), list):
            raise AuditAPIError(f"recursive tree is invalid for {full_name}@{tree_sha}")
        paths = tuple(
            sorted(
                str(item["path"])
                for item in tree["tree"]
                if isinstance(item, dict) and item.get("type") == "blob" and item.get("path")
            )
        )
        return RepoSnapshot(
            full_name=full_name,
            name=name,
            private=bool(repo.get("private")),
            archived=bool(repo.get("archived")),
            disabled=bool(repo.get("disabled")),
            default_branch=default_branch,
            default_sha=default_sha,
            tree_sha=tree_sha,
            paths=paths,
            truncated_tree=bool(tree.get("truncated")),
        )

    def text(self, full_name: str, path: str, ref: str) -> str | None:
        encoded_repo = "/".join(urllib.parse.quote(part, safe="") for part in full_name.split("/"))
        encoded_path = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
        query = urllib.parse.urlencode({"ref": ref})
        try:
            value = self._request(f"/repos/{encoded_repo}/contents/{encoded_path}?{query}")
        except AuditAPIError as error:
            if str(error).startswith("HTTP 404 "):
                return None
            raise
        if not isinstance(value, dict) or value.get("type") != "file":
            return None
        size = int(value.get("size") or 0)
        if size > MAX_TEXT_BYTES:
            raise AuditAPIError(
                f"refusing to decode oversized audit input {full_name}:{path} ({size} bytes)"
            )
        content = value.get("content")
        if not isinstance(content, str):
            raise AuditAPIError(f"missing inline file content for {full_name}:{path}")
        try:
            return base64.b64decode(content, validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise AuditAPIError(f"non-UTF-8 or malformed content at {full_name}:{path}") from error


def _finding(
    snapshot: RepoSnapshot,
    severity: str,
    code: str,
    message: str,
    path: str = "",
) -> Finding:
    return Finding(severity, code, snapshot.full_name, path, message)


def _is_plaintext_env(path: str) -> bool:
    value = PurePosixPath(path)
    lowered_parts = tuple(part.lower() for part in value.parts)
    basename = value.name.lower()
    if "env" in lowered_parts and "dec" in lowered_parts:
        return True
    if not basename.startswith(".env"):
        return False
    if basename in PLAIN_ENV_EXEMPT_BASENAMES or basename.endswith(".enc"):
        return False
    return True


def _generated_roots(paths: Iterable[str]) -> set[str]:
    roots: set[str] = set()
    for path in paths:
        parts = PurePosixPath(path).parts
        for index, part in enumerate(parts[:-1]):
            if part.lower() == "generated":
                roots.add("/".join(parts[: index + 1]))
    return roots


def _secret_findings(snapshot: RepoSnapshot, path: str, text: str) -> list[Finding]:
    output: list[Finding] = []
    for name, pattern in SECRET_PATTERNS:
        if pattern.search(text):
            output.append(
                _finding(
                    snapshot,
                    "critical",
                    f"credential-literal-{name}",
                    "credential-shaped literal is committed; rotate it and purge the reachable history",
                    path,
                )
            )
    return output


def _workflow_findings(snapshot: RepoSnapshot, path: str, text: str) -> list[Finding]:
    output: list[Finding] = []
    if not PERMISSIONS_RE.search(text):
        output.append(
            _finding(
                snapshot,
                "warning",
                "workflow-permissions-implicit",
                "workflow omits a top-level permissions boundary",
                path,
            )
        )
    if WRITE_ALL_RE.search(text):
        output.append(
            _finding(
                snapshot,
                "critical",
                "workflow-write-all",
                "workflow grants write-all permissions",
                path,
            )
        )
    for action in USES_RE.findall(text):
        if action.startswith(("./", "docker://")):
            continue
        if "@" not in action:
            output.append(
                _finding(snapshot, "error", "action-missing-ref", f"action `{action}` has no ref", path)
            )
            continue
        owner_repo, ref = action.rsplit("@", 1)
        if not owner_repo or not re.fullmatch(r"[0-9a-fA-F]{40}", ref):
            output.append(
                _finding(
                    snapshot,
                    "error",
                    "action-not-sha-pinned",
                    f"action `{action}` is not pinned to an immutable 40-hex commit",
                    path,
                )
            )
    if PERSIST_CREDENTIALS_RE.search(text):
        output.append(
            _finding(
                snapshot,
                "warning",
                "checkout-persists-credentials",
                "checkout explicitly persists the GitHub token",
                path,
            )
        )
    if PIPE_TO_SHELL_RE.search(text):
        output.append(
            _finding(
                snapshot,
                "critical",
                "download-piped-to-shell",
                "workflow pipes a network download directly to a shell",
                path,
            )
        )
    if PULL_REQUEST_TARGET_RE.search(text):
        output.append(
            _finding(
                snapshot,
                "warning",
                "pull-request-target-used",
                "pull_request_target requires an explicit trusted-code boundary review",
                path,
            )
        )
        if UNTRUSTED_HEAD_RE.search(text):
            output.append(
                _finding(
                    snapshot,
                    "critical",
                    "pull-request-target-checks-out-head",
                    "privileged pull_request_target workflow references attacker-controlled PR head data",
                    path,
                )
            )
        if EVENT_TEXT_IN_RUN_RE.search(text):
            output.append(
                _finding(
                    snapshot,
                    "critical",
                    "event-text-interpolated-in-shell",
                    "untrusted event text is interpolated directly into a shell script",
                    path,
                )
            )
    output.extend(_secret_findings(snapshot, path, text))
    return output


def _manifest_findings(snapshot: RepoSnapshot, text: str, has_lock: bool) -> list[Finding]:
    path = ".zpkg.toml"
    try:
        manifest = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return [_finding(snapshot, "error", "manifest-invalid-toml", str(error), path)]

    output: list[Finding] = []
    package = manifest.get("package")
    if not isinstance(package, dict):
        return [_finding(snapshot, "error", "manifest-missing-package", "missing [package]", path)]

    org = package.get("org")
    name = package.get("name")
    if not isinstance(org, str) or not isinstance(name, str) or not org or not name:
        output.append(
            _finding(snapshot, "error", "manifest-coordinate-invalid", "package org/name is missing", path)
        )
    repository = package.get("repository")
    url = repository.get("url") if isinstance(repository, dict) else None
    if isinstance(url, str):
        normalized = url.rstrip("/").removesuffix(".git").lower()
        expected = f"github.com/{snapshot.full_name}".lower()
        if normalized.startswith(("https://", "http://", "ssh://")) and expected not in normalized:
            output.append(
                _finding(
                    snapshot,
                    "warning",
                    "manifest-repository-mismatch",
                    f"package.repository.url does not identify {snapshot.full_name}",
                    path,
                )
            )

    dependencies = manifest.get("dependencies")
    if isinstance(dependencies, dict) and dependencies and not has_lock:
        output.append(
            _finding(
                snapshot,
                "error",
                "manifest-dependencies-without-lock",
                "manifest declares dependencies but .zpkg.lock is absent",
                path,
            )
        )

    interop = manifest.get("interop")
    flags = interop.get("flags-2-env") if isinstance(interop, dict) else None
    if flags is None and isinstance(interop, dict):
        flags = interop.get("flags2env")
    if flags is not None:
        if not isinstance(flags, dict):
            output.append(
                _finding(snapshot, "error", "flags2env-invalid", "flags-2-env must be a table", path)
            )
            return output
        config = flags.get("config")
        bins = flags.get("bins")
        if not isinstance(config, str) or not config.strip():
            output.append(
                _finding(snapshot, "error", "flags2env-config-missing", "config is required", path)
            )
        elif PurePosixPath(config).is_absolute() or ".." in PurePosixPath(config).parts:
            output.append(
                _finding(snapshot, "critical", "flags2env-config-escapes", "config must remain package-relative", path)
            )
        if not isinstance(bins, list) or not bins or any(not isinstance(item, str) or not item for item in bins):
            output.append(
                _finding(snapshot, "error", "flags2env-bins-invalid", "bins must be a nonempty string array", path)
            )
        declared_bins = manifest.get("bin")
        if isinstance(bins, list) and isinstance(declared_bins, dict):
            missing = sorted({item for item in bins if isinstance(item, str)} - set(declared_bins))
            if missing:
                output.append(
                    _finding(
                        snapshot,
                        "error",
                        "flags2env-bin-undeclared",
                        f"bound bins are absent from [bin]: {', '.join(missing)}",
                        path,
                    )
                )
        build = manifest.get("build")
        outputs = build.get("outputs") if isinstance(build, dict) else None
        if not isinstance(outputs, list) or not outputs:
            output.append(
                _finding(
                    snapshot,
                    "error",
                    "flags2env-build-outputs-missing",
                    "[build].outputs must be nonempty and retain the flags contract",
                    path,
                )
            )
        elif isinstance(config, str) and config not in outputs:
            output.append(
                _finding(
                    snapshot,
                    "error",
                    "flags2env-config-not-retained",
                    f"[build].outputs does not retain `{config}`",
                    path,
                )
            )
    return output


def audit_snapshot(client: GitHubClient, snapshot: RepoSnapshot) -> list[Finding]:
    if snapshot.archived:
        return []
    output: list[Finding] = []
    path_set = set(snapshot.paths)

    if snapshot.disabled:
        output.append(_finding(snapshot, "critical", "repository-disabled", "repository is disabled"))
    if snapshot.default_branch != "main":
        output.append(
            _finding(
                snapshot,
                "warning",
                "default-branch-not-main",
                f"default branch is `{snapshot.default_branch}`, expected `main`",
            )
        )
    if snapshot.truncated_tree:
        output.append(
            _finding(
                snapshot,
                "critical",
                "recursive-tree-truncated",
                "GitHub truncated the recursive tree; absence checks are not trustworthy",
            )
        )

    if not snapshot.private and any(pattern.search(snapshot.name) for pattern in BACKEND_PRIVATE_PATTERNS):
        output.append(
            _finding(
                snapshot,
                "critical",
                "backend-repository-public",
                "backend-only ORM/admin repository must be private before credentials or persistence code land",
            )
        )

    for path in snapshot.paths:
        if _is_plaintext_env(path) and not snapshot.private:
            output.append(
                _finding(
                    snapshot,
                    "critical",
                    "public-plaintext-environment",
                    "public repository contains a plaintext environment file",
                    path,
                )
            )

    for root in sorted(_generated_roots(snapshot.paths)):
        readme = f"{root}/README.md"
        if readme not in path_set:
            output.append(
                _finding(
                    snapshot,
                    "error",
                    "generated-readme-missing",
                    "generated directory lacks README.md provenance/do-not-edit guidance",
                    root,
                )
            )

    manifest_path = ".zpkg.toml"
    if manifest_path in path_set:
        manifest = client.text(snapshot.full_name, manifest_path, snapshot.default_sha)
        if manifest is None:
            output.append(
                _finding(snapshot, "critical", "manifest-unreadable", "tree lists .zpkg.toml but content is unavailable", manifest_path)
            )
        else:
            output.extend(_manifest_findings(snapshot, manifest, ".zpkg.lock" in path_set))
        if not any(path.startswith(".github/workflows/") for path in snapshot.paths):
            output.append(
                _finding(
                    snapshot,
                    "warning",
                    "package-without-workflow",
                    "publishable package has no repository-local GitHub Actions workflow",
                )
            )

    if "AGENTS.md" not in path_set:
        output.append(
            _finding(
                snapshot,
                "warning",
                "agents-instructions-missing",
                "repository lacks a local AGENTS.md pointer or specialization",
            )
        )

    for path in snapshot.paths:
        if not path.startswith(".github/workflows/") or not path.endswith((".yml", ".yaml")):
            continue
        text = client.text(snapshot.full_name, path, snapshot.default_sha)
        if text is None:
            output.append(
                _finding(snapshot, "critical", "workflow-unreadable", "workflow tree entry could not be read", path)
            )
            continue
        output.extend(_workflow_findings(snapshot, path, text))

    return sorted(set(output))


def audit_organization(
    client: GitHubClient,
    org: str,
    *,
    max_workers: int,
) -> tuple[list[RepoSnapshot], list[Finding]]:
    metadata = [repo for repo in client.repositories(org) if not repo.get("archived")]
    snapshots: list[RepoSnapshot] = []
    findings: list[Finding] = []

    def inspect(repo: Mapping[str, Any]) -> tuple[RepoSnapshot | None, list[Finding]]:
        full_name = str(repo.get("full_name") or f"{org}/<unknown>")
        try:
            snapshot = client.snapshot(repo)
            return snapshot, audit_snapshot(client, snapshot)
        except AuditAPIError as error:
            fallback = RepoSnapshot(
                full_name=full_name,
                name=str(repo.get("name") or "<unknown>"),
                private=bool(repo.get("private")),
                archived=bool(repo.get("archived")),
                disabled=bool(repo.get("disabled")),
                default_branch=str(repo.get("default_branch") or ""),
                default_sha="",
                tree_sha="",
                paths=(),
                truncated_tree=True,
            )
            return None, [
                _finding(fallback, "critical", "repository-audit-incomplete", str(error))
            ]

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        for snapshot, repo_findings in executor.map(inspect, metadata):
            if snapshot is not None:
                snapshots.append(snapshot)
            findings.extend(repo_findings)

    snapshots.sort(key=lambda item: item.full_name.lower())
    findings = sorted(set(findings))
    return snapshots, findings


def _summary(findings: Sequence[Finding]) -> dict[str, int]:
    counts = {severity: 0 for severity in SEVERITY_RANK}
    for item in findings:
        counts[item.severity] += 1
    return counts


def build_report(orgs: Sequence[str], snapshots: Sequence[RepoSnapshot], findings: Sequence[Finding]) -> dict[str, Any]:
    serialized_findings = [item.as_dict() for item in findings]
    canonical = json.dumps(serialized_findings, sort_keys=True, separators=(",", ":")).encode()
    return {
        "schema": "zed.repository-security-audit.v1",
        "generated_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "organizations": list(orgs),
        "summary": {
            "repositories": len(snapshots),
            **_summary(findings),
            "findings_sha256": hashlib.sha256(canonical).hexdigest(),
        },
        "repositories": [
            {
                "full_name": item.full_name,
                "private": item.private,
                "default_branch": item.default_branch,
                "default_sha": item.default_sha,
                "tree_sha": item.tree_sha,
                "path_count": len(item.paths),
                "tree_truncated": item.truncated_tree,
            }
            for item in snapshots
        ],
        "findings": serialized_findings,
    }


def report_markdown(report: Mapping[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Zed repository security audit",
        "",
        f"- Repositories inspected: **{summary['repositories']}**",
        f"- Critical: **{summary['critical']}**",
        f"- Errors: **{summary['error']}**",
        f"- Warnings: **{summary['warning']}**",
        f"- Findings digest: `{summary['findings_sha256']}`",
        "",
    ]
    findings = report["findings"]
    if not findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"
    current = None
    for item in findings:
        if item["repository"] != current:
            current = item["repository"]
            lines.extend((f"## `{current}`", ""))
        location = f" (`{item['path']}`)" if item["path"] else ""
        icon = {"critical": "🛑", "error": "❌", "warning": "⚠️"}[item["severity"]]
        lines.append(f"- {icon} **{item['severity']}** `{item['code']}`{location} — {item['message']}")
    return "\n".join(lines) + "\n"


def should_fail(findings: Sequence[Finding], threshold: str) -> bool:
    if threshold == "never":
        return False
    minimum = SEVERITY_RANK[threshold]
    return any(SEVERITY_RANK[item.severity] >= minimum for item in findings)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orgs", default="zed-pkg", help="comma-separated GitHub organizations")
    parser.add_argument("--json", type=Path, default=Path("zed-repository-security-audit.json"))
    parser.add_argument("--markdown", type=Path, default=Path("zed-repository-security-audit.md"))
    parser.add_argument(
        "--fail-on",
        choices=("never", "critical", "error", "warning"),
        default="critical",
        help="minimum finding severity that makes the process fail",
    )
    parser.add_argument("--max-workers", type=int, default=8)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    orgs = tuple(dict.fromkeys(part.strip() for part in args.orgs.split(",") if part.strip()))
    if not orgs:
        raise SystemExit("at least one organization is required")
    if not 1 <= args.max_workers <= 16:
        raise SystemExit("--max-workers must be between 1 and 16")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        raise SystemExit("GITHUB_TOKEN or GH_TOKEN is required")

    client = GitHubClient(token)
    snapshots: list[RepoSnapshot] = []
    findings: list[Finding] = []
    try:
        for org in orgs:
            org_snapshots, org_findings = audit_organization(
                client,
                org,
                max_workers=args.max_workers,
            )
            snapshots.extend(org_snapshots)
            findings.extend(org_findings)
    except AuditAPIError as error:
        print(f"audit failed before a complete receipt could be produced: {error}", file=sys.stderr)
        return 2

    snapshots.sort(key=lambda item: item.full_name.lower())
    findings = sorted(set(findings))
    report = build_report(orgs, snapshots, findings)
    args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.markdown.write_text(report_markdown(report), encoding="utf-8")
    print(report_markdown(report), end="")
    return 1 if should_fail(findings, args.fail_on) else 0


if __name__ == "__main__":
    raise SystemExit(main())
