#!/usr/bin/env python3
"""Audit GitHub org repository families against the canonical Zed contract."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.github.com"
LANGS = {
    "c": ("c",), "cpp": ("cpp", "cxx"), "zig": ("zig",),
    "gleamlang": ("gleam", "gleamlang"), "erlang": ("erlang",),
    "elixir": ("elixir",), "dart": ("dart",), "rust": ("rust",),
    "java": ("java",), "golang": ("go", "golang"),
    "python3": ("python", "python3"), "ruby": ("ruby",), "php": ("php",),
    "typescript": ("typescript", "ts"),
}
RUNTIMES = {
    "nodejs": ("node", "nodejs"), "deno": ("deno",), "bun": ("bun",),
    "edge": ("edge", "edge-runtime", "workers"),
}
DEP_RE = re.compile(r'^\s*"([^"]+/[^"]+)"\s*=', re.M)
TARGET_RE = re.compile(r"^\s*\[targets\.([^\]]+)\]\s*$", re.M)
REPO_PART_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
SCP_GITHUB_RE = re.compile(
    r"^git@github\.com:(?P<org>[A-Za-z0-9_.-]+)/(?P<repo>[A-Za-z0-9_.-]+?)(?:\.git)?$"
)
RELATIVE_RE = re.compile(r"^\.\.?/(?P<repo>[A-Za-z0-9_.-]+?)(?:\.git)?$")


class APIError(RuntimeError):
    pass


class GitHub:
    def __init__(self, token: str) -> None:
        self.token = token

    def get(self, path: str):
        req = urllib.request.Request(
            API + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "zed-fleet-audit/1",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            raise APIError(f"{error.code} {path}: {body}") from error

    def repos(self, org: str) -> list[dict]:
        output, page = [], 1
        while True:
            batch = self.get(
                f"/orgs/{urllib.parse.quote(org)}/repos?type=all&per_page=100&page={page}"
            )
            output.extend(batch)
            if len(batch) < 100:
                return output
            page += 1

    def text(self, repo: str, path: str) -> str | None:
        encoded = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
        try:
            value = self.get(f"/repos/{repo}/contents/{encoded}")
        except APIError as error:
            if str(error).startswith("404 "):
                return None
            raise
        if not isinstance(value, dict) or value.get("type") != "file":
            return None
        return base64.b64decode(value["content"]).decode()

    def names(self, repo: str, path: str) -> set[str]:
        encoded = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
        try:
            value = self.get(f"/repos/{repo}/contents/{encoded}")
        except APIError as error:
            if str(error).startswith("404 "):
                return set()
            raise
        return {str(item["name"]).lower() for item in value} if isinstance(value, list) else set()


def coordinate(manifest: str | None) -> str | None:
    if not manifest:
        return None
    package = re.search(r"^\[package\]\s*$([\s\S]*?)(?=^\[|\Z)", manifest, re.M)
    if not package:
        return None
    org = re.search(r'^org\s*=\s*"([^"]+)"', package.group(1), re.M)
    name = re.search(r'^name\s*=\s*"([^"]+)"', package.group(1), re.M)
    return f"{org.group(1)}/{name.group(1)}" if org and name else None


def github_repository(raw_url: str, default_org: str) -> str | None:
    """Return a validated owner/repository pair for supported .gitmodules URLs."""
    value = raw_url.strip().strip('"').strip("'")
    relative = RELATIVE_RE.fullmatch(value)
    if relative:
        return f"{default_org}/{relative.group('repo')}"

    scp = SCP_GITHUB_RE.fullmatch(value)
    if scp:
        return f"{scp.group('org')}/{scp.group('repo')}"

    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in {"https", "ssh"} or parsed.hostname != "github.com":
        return None
    parts = [part for part in parsed.path.strip("/").split("/") if part]
    if len(parts) != 2:
        return None
    org, repo = parts
    if repo.endswith(".git"):
        repo = repo[:-4]
    if not REPO_PART_RE.fullmatch(org) or not REPO_PART_RE.fullmatch(repo):
        return None
    return f"{org}/{repo}"


def first(names: set[str], *candidates: str) -> str | None:
    return next((candidate for candidate in candidates if candidate in names), None)


def has(names: set[str], aliases: tuple[str, ...]) -> bool:
    return bool(names.intersection(aliases))


def finding(severity: str, code: str, message: str) -> dict:
    return {"severity": severity, "code": code, "message": message}


def audit_family(gh: GitHub, org: str, repos: set[str], clients: str) -> dict:
    prefix = clients[:-8]
    interfaces = first(repos, f"{prefix}-interfaces", f"{prefix}-interface")
    library = first(
        repos,
        f"{prefix}-lib-core",
        f"{prefix}-lib",
        f"{prefix}-libs",
        f"{prefix}-library",
    )
    cli = first(repos, f"{prefix}-cli", f"{prefix}-cli.rs")
    monorepo = first(repos, f"{prefix}-monorepo")
    findings = []

    for value, code, label in (
        (interfaces, "missing-interfaces-repo", "interfaces"),
        (library, "missing-library-repo", "shared library"),
        (cli, "missing-cli-repo", "CLI"),
        (monorepo, "missing-monorepo-repo", "monorepo"),
    ):
        if not value:
            findings.append(finding("error", code, f"Missing {label} repository"))

    clients_full = f"{org}/{clients}"
    manifest = gh.text(clients_full, ".zpkg.toml")
    if not manifest:
        findings.append(finding("error", "clients-missing-manifest", "Missing .zpkg.toml"))
    elif not coordinate(manifest) or "[install]" not in manifest or "[targets." not in manifest:
        findings.append(finding("error", "clients-invalid-manifest", "Incomplete package/install/target envelope"))

    expected = {}
    for role, repo in (("interfaces", interfaces), ("library", library)):
        if not repo:
            continue
        dep_manifest = gh.text(f"{org}/{repo}", ".zpkg.toml")
        dep_coordinate = coordinate(dep_manifest)
        if not dep_manifest:
            findings.append(finding("error", f"{role}-missing-manifest", f"{repo} lacks .zpkg.toml"))
        elif not dep_coordinate:
            findings.append(finding("error", f"{role}-invalid-manifest", f"{repo} lacks package org/name"))
        else:
            expected[role] = dep_coordinate

    dependencies = set(DEP_RE.findall(manifest or ""))
    for role, dep in expected.items():
        if dep not in dependencies:
            findings.append(finding("error", f"clients-missing-{role}", f"Clients do not depend on {dep}"))

    client_dirs = gh.names(clients_full, "clients")
    for language, aliases in LANGS.items():
        if not has(client_dirs, aliases):
            findings.append(finding("error", f"missing-language-{language}", f"clients/ lacks {language}"))

    mobile = any(
        marker in repo.lower()
        for repo in repos
        for marker in ("mobile", "ios", "android", "flutter")
    ) or has(client_dirs, ("kotlin", "swift"))
    if mobile:
        for language in ("kotlin", "swift"):
            if language not in client_dirs:
                findings.append(finding("error", f"missing-language-{language}", f"Mobile family lacks {language}"))

    ts = first(client_dirs, "typescript", "ts")
    if ts:
        runtime_names = gh.names(clients_full, f"clients/{ts}")
        for runtime, aliases in RUNTIMES.items():
            if not has(runtime_names, aliases):
                findings.append(finding("error", f"missing-ts-{runtime}", f"TypeScript lacks explicit {runtime} entry"))

    targets = set(TARGET_RE.findall(manifest or ""))
    for target in ("c", "cpp", "zig", "gleam", "erlang", "elixir", "dart", "rust", "java", "python", "ruby", "php"):
        if target not in targets:
            findings.append(finding("error", f"missing-target-{target}", f"Missing [targets.{target}]"))
    if not targets.intersection({"go", "golang"}):
        findings.append(finding("error", "missing-target-golang", "Missing Go target"))
    if not targets.intersection({"node", "nodejs", "typescript"}):
        findings.append(finding("error", "missing-target-typescript", "Missing TypeScript/Node target"))
    if mobile:
        for target in ("kotlin", "swift"):
            if target not in targets:
                findings.append(finding("error", f"missing-target-{target}", f"Missing [targets.{target}]"))

    if cli:
        cli_manifest = gh.text(f"{org}/{cli}", ".zpkg.toml")
        if not cli_manifest:
            findings.append(finding("error", "cli-missing-manifest", f"{cli} lacks .zpkg.toml"))
        else:
            cli_deps = set(DEP_RE.findall(cli_manifest))
            required = set(expected.values())
            clients_coordinate = coordinate(manifest)
            if clients_coordinate:
                required.add(clients_coordinate)
            for dep in sorted(required):
                if dep not in cli_deps:
                    findings.append(finding("error", "cli-missing-dependency", f"CLI does not depend on {dep}"))

    if monorepo:
        mono_full = f"{org}/{monorepo}"
        mono_manifest = gh.text(mono_full, ".zpkg.toml")
        if not mono_manifest or "[targets.repository]" not in mono_manifest:
            findings.append(finding("error", "monorepo-invalid-manifest", "Monorepo lacks Zed repository target"))

        mono_deps = set(DEP_RE.findall(mono_manifest or ""))
        mono_deps_lower = {dep.lower(): dep for dep in mono_deps}
        for dep in mono_deps:
            name = dep.rsplit("/", 1)[-1].lower()
            if name.endswith(("-infra", "-cli", "-cli.rs")):
                findings.append(finding("error", "monorepo-forbidden-zed-dependency", dep))

        gitmodules = gh.text(mono_full, ".gitmodules") or ""
        for raw_url in re.findall(r"^\s*url\s*=\s*(.+)$", gitmodules, re.M):
            repo_full = github_repository(raw_url, org)
            fallback_name = raw_url.strip().strip('"').strip("'").removesuffix(".git").rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
            name = (repo_full.rsplit("/", 1)[-1] if repo_full else fallback_name).lower()
            if name.endswith(("-infra", "-cli", "-cli.rs")):
                findings.append(finding("error", "monorepo-forbidden-submodule", name))

            if not repo_full:
                continue
            submodule_manifest = gh.text(repo_full, ".zpkg.toml")
            submodule_coordinate = coordinate(submodule_manifest)
            if submodule_coordinate and submodule_coordinate.lower() in mono_deps_lower:
                findings.append(
                    finding(
                        "error",
                        "monorepo-dual-zed-submodule-ownership",
                        f"{submodule_coordinate} is both a Zed dependency and Git submodule ({repo_full})",
                    )
                )

    return {
        "org": org, "prefix": prefix,
        "repositories": {
            "clients": clients, "interfaces": interfaces, "library": library,
            "cli": cli, "monorepo": monorepo,
        },
        "findings": findings,
    }


def markdown(report: dict) -> str:
    summary = report["summary"]
    lines = [
        "# Zed fleet audit", "",
        f"- Families: **{summary['families']}**",
        f"- Errors: **{summary['errors']}**",
        f"- Warnings: **{summary['warnings']}**", "",
    ]
    for family in report["families"]:
        lines += [f"## `{family['org']}/{family['prefix']}`", ""]
        for role, repo in family["repositories"].items():
            lines.append(f"- {role.title()}: `{repo or 'MISSING'}`")
        lines.append("")
        if not family["findings"]:
            lines.append("✅ No findings.")
        for item in family["findings"]:
            icon = "❌" if item["severity"] == "error" else "⚠️"
            lines.append(f"- {icon} `{item['code']}` — {item['message']}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--orgs", required=True, help="Comma-separated GitHub organizations")
    parser.add_argument("--json", type=Path, default=Path("zed-fleet-report.json"))
    parser.add_argument("--markdown", type=Path, default=Path("zed-fleet-report.md"))
    parser.add_argument("--allow-errors", action="store_true")
    args = parser.parse_args()
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        parser.error("GITHUB_TOKEN or GH_TOKEN is required")

    gh = GitHub(token)
    families = []
    for org in dict.fromkeys(part.strip() for part in args.orgs.split(",") if part.strip()):
        repos = {
            repo["name"] for repo in gh.repos(org)
            if not repo.get("archived") and not repo["name"].endswith("-test")
        }
        clients = sorted(repo for repo in repos if repo.endswith("-clients"))
        if not clients:
            families.append({
                "org": org, "prefix": "<none>",
                "repositories": {"clients": None, "interfaces": None, "library": None, "cli": None, "monorepo": None},
                "findings": [finding("warning", "no-client-families", "No non-archived *-clients repos")],
            })
        else:
            families.extend(audit_family(gh, org, repos, repo) for repo in clients)

    errors = sum(item["severity"] == "error" for family in families for item in family["findings"])
    warnings = sum(item["severity"] == "warning" for family in families for item in family["findings"])
    report = {"schema_version": 1, "summary": {"families": len(families), "errors": errors, "warnings": warnings}, "families": families}
    args.json.write_text(json.dumps(report, indent=2) + "\n")
    args.markdown.write_text(markdown(report) + "\n")
    print(markdown(report))
    return 0 if args.allow_errors or errors == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except APIError as error:
        print(error, file=sys.stderr)
        raise SystemExit(2)
