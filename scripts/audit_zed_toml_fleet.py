#!/usr/bin/env python3
"""Read-only zed-pkg fleet audit for contracts and CI provenance."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterator

ORG = "zed-pkg"
CANONICAL_FLAG_TYPES = {"array", "bool", "double", "integer", "json", "map", "string"}
STALE_ZED_CLI = re.compile(r"^\^(?:0\.[012])(?:\.|$)")
EXACT_RUST_CHANNEL = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
IMMUTABLE_GITHUB_REF = re.compile(r"^[0-9a-fA-F]{40}$")
REMOTE_USES = re.compile(
    r"(?m)^\s*(?:-\s*)?uses:\s*"
    r"(?P<target>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?)"
    r"@(?P<ref>[^\s#]+)"
)
PULL_REQUEST_EVENT = re.compile(r"(?m)^\s*pull_request(?:_target)?:")
MOVING_RUST_PATTERNS = (
    re.compile(r"(?m)^\s*toolchain:\s*(stable|beta|nightly)\s*(?:#.*)?$"),
    re.compile(r"\brustup\s+toolchain\s+install\s+(stable|beta|nightly)\b"),
    re.compile(r"\brustup\s+default\s+(stable|beta|nightly)\b"),
)
RUST_WORKFLOW_MARKERS = (
    "cargo ",
    "cargo\n",
    "rustc ",
    "rustup ",
    "dtolnay/rust-toolchain@",
)


@dataclass(frozen=True)
class Finding:
    repo: str
    severity: str
    code: str
    detail: str


def request_json(url: str, token: str | None) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "zed-pkg-contract-provenance-audit/2",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_text(repo: str, path: str, token: str | None) -> str | None:
    url = f"https://api.github.com/repos/{ORG}/{repo}/contents/{path}"
    try:
        payload = request_json(url, token)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    if not isinstance(payload, dict) or payload.get("encoding") != "base64":
        raise RuntimeError(f"{repo}/{path}: unsupported GitHub contents payload")
    return base64.b64decode(payload["content"]).decode("utf-8")


def fetch_workflows(repo: str, token: str | None) -> dict[str, str]:
    url = f"https://api.github.com/repos/{ORG}/{repo}/contents/.github/workflows"
    try:
        payload = request_json(url, token)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {}
        raise
    if not isinstance(payload, list):
        raise RuntimeError(f"{repo}/.github/workflows: expected directory listing")

    workflows: dict[str, str] = {}
    for item in payload:
        if not isinstance(item, dict) or item.get("type") != "file":
            continue
        name = item.get("name")
        path = item.get("path")
        if not isinstance(name, str) or not isinstance(path, str):
            continue
        if not name.endswith((".yml", ".yaml")):
            continue
        text = fetch_text(repo, path, token)
        if text is not None:
            workflows[path] = text
    return workflows


def walk_flag_tables(value: Any, prefix: str = "") -> Iterator[tuple[str, dict[str, Any]]]:
    if isinstance(value, dict):
        if "env" in value and ("type" in value or "aliases" in value):
            yield prefix, value
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else key
            yield from walk_flag_tables(child, child_prefix)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk_flag_tables(child, f"{prefix}[{index}]")


def audit_cli_flags(repo: str, text: str, findings: list[Finding]) -> None:
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        findings.append(Finding(repo, "error", "cli-flags-invalid-toml", str(error)))
        return

    parse = document.get("parse")
    if not isinstance(parse, dict) or parse.get("allow_unknown") is not False:
        findings.append(
            Finding(repo, "error", "cli-flags-not-fail-closed", "parse.allow_unknown must be false")
        )

    env = document.get("env")
    if not isinstance(env, dict):
        findings.append(Finding(repo, "error", "cli-flags-missing-env", "[env] must be declared explicitly"))
    else:
        if env.get("dotenv") is not False:
            findings.append(Finding(repo, "error", "cli-flags-dotenv-enabled", "env.dotenv must be false"))
        if env.get("files") not in ([], None):
            findings.append(Finding(repo, "error", "cli-flags-dotenv-files", "env.files must be [] when declared"))

    if "github.com/oresoftware/flags-2-env" in text.lower():
        findings.append(
            Finding(repo, "error", "legacy-flags-authority", "legacy ORESoftware/flags-2-env authority is active")
        )

    root_envs: dict[str, str] = {}
    root_spellings: dict[str, str] = {}
    root_flags = document.get("flags", {})
    if isinstance(root_flags, dict):
        for name, definition in root_flags.items():
            if not isinstance(definition, dict):
                continue
            env_name = definition.get("env")
            if isinstance(env_name, str):
                owner = root_envs.get(env_name)
                if owner and owner != name:
                    findings.append(
                        Finding(repo, "error", "duplicate-root-env", f"{env_name}: {owner} and {name}")
                    )
                root_envs[env_name] = name
            spellings = [name.replace("_", "-")]
            aliases = definition.get("aliases")
            if isinstance(aliases, list):
                spellings.extend(alias for alias in aliases if isinstance(alias, str))
            for spelling in set(spellings):
                owner = root_spellings.get(spelling)
                if owner and owner != name:
                    findings.append(
                        Finding(
                            repo,
                            "error",
                            "duplicate-root-spelling",
                            f"--{spelling}: {owner} and {name}",
                        )
                    )
                root_spellings[spelling] = name

    for location, definition in walk_flag_tables(document):
        if "long" in definition or "switch" in definition:
            findings.append(
                Finding(
                    repo,
                    "error",
                    "legacy-flags-key",
                    f"{location} uses unsupported long/switch authoring",
                )
            )
        kind = definition.get("type")
        if isinstance(kind, str) and kind not in CANONICAL_FLAG_TYPES:
            findings.append(Finding(repo, "error", "noncanonical-flag-type", f"{location}.type={kind!r}"))


def audit_zpkg(repo: str, text: str, cli_exists: bool, findings: list[Finding]) -> None:
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        findings.append(Finding(repo, "error", "zpkg-invalid-toml", str(error)))
        return

    package = document.get("package")
    if not isinstance(package, dict):
        findings.append(Finding(repo, "error", "zpkg-missing-package", "[package] is required"))
        return
    if package.get("org") != ORG:
        findings.append(Finding(repo, "error", "zpkg-org-drift", f"package.org={package.get('org')!r}"))

    repository = package.get("repository")
    if isinstance(repository, dict) and isinstance(repository.get("url"), str):
        expected = f"https://github.com/{ORG}/{repo}"
        actual = repository["url"].rstrip("/")
        if actual != expected:
            findings.append(Finding(repo, "error", "zpkg-repository-drift", f"expected {expected}, got {actual}"))

    cli = document.get("cli")
    if isinstance(cli, dict) and cli.get("flags_runtime") == "flags-2-env":
        contract = cli.get("flags_contract", ".cli-flags.toml")
        if contract == ".cli-flags.toml" and not cli_exists:
            findings.append(
                Finding(
                    repo,
                    "error",
                    "missing-cli-flags-contract",
                    ".zpkg.toml selects flags-2-env but .cli-flags.toml is absent",
                )
            )

    dependencies = document.get("dependencies")
    if isinstance(dependencies, dict):
        requirement = dependencies.get("zed-pkg/zed-cli")
        if isinstance(requirement, str) and STALE_ZED_CLI.match(requirement):
            findings.append(Finding(repo, "error", "stale-zed-cli-range", f"zed-pkg/zed-cli={requirement}"))


def audit_rust_toolchain(repo: str, text: str, findings: list[Finding]) -> None:
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        findings.append(Finding(repo, "error", "rust-toolchain-invalid-toml", str(error)))
        return
    toolchain = document.get("toolchain")
    channel = toolchain.get("channel") if isinstance(toolchain, dict) else None
    if not isinstance(channel, str) or EXACT_RUST_CHANNEL.fullmatch(channel) is None:
        findings.append(
            Finding(
                repo,
                "error",
                "rust-toolchain-not-patch-exact",
                f"toolchain.channel must be numeric major.minor.patch, got {channel!r}",
            )
        )


def is_rust_workflow(text: str) -> bool:
    lowered = text.lower()
    return any(marker in lowered for marker in RUST_WORKFLOW_MARKERS)


def step_blocks_for_action(text: str, action_prefix: str) -> Iterator[str]:
    lines = text.splitlines()
    matcher = re.compile(rf"^\s*(?:-\s*)?uses:\s*{re.escape(action_prefix)}", re.IGNORECASE)
    for index, line in enumerate(lines):
        if matcher.search(line) is None:
            continue
        indent = len(line) - len(line.lstrip())
        block = [line]
        for following in lines[index + 1 :]:
            stripped = following.lstrip()
            following_indent = len(following) - len(stripped)
            if stripped.startswith("- ") and following_indent < indent:
                break
            if stripped and following_indent < indent and not stripped.startswith("#"):
                break
            block.append(following)
        yield "\n".join(block)


def audit_workflow(
    repo: str,
    path: str,
    text: str,
    toolchain_exists: bool,
    findings: list[Finding],
) -> None:
    for match in REMOTE_USES.finditer(text):
        ref = match.group("ref")
        if IMMUTABLE_GITHUB_REF.fullmatch(ref) is None:
            findings.append(
                Finding(
                    repo,
                    "error",
                    "workflow-action-mutable",
                    f"{path}: {match.group('target')}@{ref} is not pinned to a 40-hex commit",
                )
            )

    if PULL_REQUEST_EVENT.search(text):
        for block in step_blocks_for_action(text, "actions/checkout@"):
            if "persist-credentials: false" not in block:
                findings.append(
                    Finding(
                        repo,
                        "error",
                        "workflow-checkout-persists-credentials",
                        f"{path}: pull-request checkout must set persist-credentials: false",
                    )
                )

    if not is_rust_workflow(text):
        return

    if not toolchain_exists:
        findings.append(
            Finding(
                repo,
                "error",
                "rust-workflow-missing-toolchain-authority",
                f"{path}: Rust workflow has no repository rust-toolchain.toml authority",
            )
        )

    for pattern in MOVING_RUST_PATTERNS:
        match = pattern.search(text)
        if match:
            findings.append(
                Finding(
                    repo,
                    "error",
                    "workflow-rust-toolchain-moving",
                    f"{path}: moving Rust channel `{match.group(1)}` is active",
                )
            )

    for block in step_blocks_for_action(text, "dtolnay/rust-toolchain@"):
        if re.search(r"(?m)^\s*toolchain:\s*", block) is None:
            findings.append(
                Finding(
                    repo,
                    "error",
                    "workflow-rust-toolchain-implicit-stable",
                    f"{path}: dtolnay/rust-toolchain omits toolchain and therefore installs moving stable",
                )
            )


def render_summary(audited: list[dict[str, Any]], findings: list[Finding]) -> str:
    errors = [item for item in findings if item.severity == "error"]
    lines = [
        "# Zed contract and provenance fleet audit",
        "",
        f"- repositories audited: {len(audited)}",
        f"- errors: {len(errors)}",
        "",
    ]
    if findings:
        lines.extend(["| Repo | Severity | Code | Detail |", "|---|---|---|---|"])
        for item in findings:
            detail = item.detail.replace("|", "\\|").replace("\n", " ")
            lines.append(f"| `{item.repo}` | {item.severity} | `{item.code}` | {detail} |")
    else:
        lines.append("No policy drift found.")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--org", default=ORG)
    parser.add_argument("--report", default="artifacts/zed-toml-fleet-report.json")
    parser.add_argument("--summary", default="artifacts/zed-toml-fleet-summary.md")
    parser.add_argument("--enforce", action="store_true", help="exit non-zero when policy errors exist")
    args = parser.parse_args()
    if args.org != ORG:
        raise SystemExit(f"this policy is scoped to {ORG}, got {args.org}")

    token = os.environ.get("GITHUB_TOKEN")
    repositories: list[dict[str, Any]] = []
    page = 1
    while True:
        batch = request_json(
            f"https://api.github.com/orgs/{ORG}/repos?per_page=100&page={page}&type=public",
            token,
        )
        repositories.extend(batch)
        if len(batch) < 100:
            break
        page += 1

    findings: list[Finding] = []
    audited: list[dict[str, Any]] = []
    for metadata in sorted(repositories, key=lambda item: item["name"]):
        if metadata.get("archived"):
            continue
        name = metadata["name"]
        zpkg = fetch_text(name, ".zpkg.toml", token)
        flags = fetch_text(name, ".cli-flags.toml", token)
        rust_toolchain = fetch_text(name, "rust-toolchain.toml", token)
        workflows = fetch_workflows(name, token)
        if zpkg is None and flags is None and rust_toolchain is None and not workflows:
            continue

        audited.append(
            {
                "repo": name,
                "zpkg": zpkg is not None,
                "cli_flags": flags is not None,
                "rust_toolchain": rust_toolchain is not None,
                "workflow_count": len(workflows),
            }
        )
        if flags is not None:
            audit_cli_flags(name, flags, findings)
        if zpkg is not None:
            audit_zpkg(name, zpkg, flags is not None, findings)
        if rust_toolchain is not None:
            audit_rust_toolchain(name, rust_toolchain, findings)
        for path, text in sorted(workflows.items()):
            audit_workflow(name, path, text, rust_toolchain is not None, findings)

    report = {
        "schema": "zed.contract-provenance-fleet-audit/v2",
        "org": ORG,
        "repositories_audited": audited,
        "finding_count": len(findings),
        "findings": [asdict(item) for item in findings],
    }
    report_path = Path(args.report)
    summary_path = Path(args.summary)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    summary_path.write_text(render_summary(audited, findings))
    print(summary_path.read_text())

    errors = [item for item in findings if item.severity == "error"]
    return 1 if args.enforce and errors else 0


if __name__ == "__main__":
    sys.exit(main())
