#!/usr/bin/env python3
"""Discover every accessible GitHub ``*-clients`` repository and its consumers.

The script is intentionally read-only.  Mutation, compilation, and pull-request
creation happen in the matrix job so one broken repository cannot hide the rest
of the fleet.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

API = "https://api.github.com"

class GitHubError(RuntimeError):
    def __init__(self, status: int, path: str, body: str) -> None:
        super().__init__(f"GitHub API {status} for {path}: {body[:500]}")
        self.status = status
        self.path = path


class GitHub:
    def __init__(self, token: str, api: str = API) -> None:
        if not token:
            raise ValueError("GITHUB_TOKEN is required")
        self.token = token
        self.api = api.rstrip("/")

    def get(self, path: str) -> Any:
        request = urllib.request.Request(
            self.api + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "zed-clients-fleet-discovery/1",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            raise GitHubError(error.code, path, body) from error

    def paginate(self, path: str) -> list[Any]:
        separator = "&" if "?" in path else "?"
        output: list[Any] = []
        for page in range(1, 101):
            value = self.get(f"{path}{separator}per_page=100&page={page}")
            if isinstance(value, dict):
                batch = value.get("items")
                if batch is None:
                    batch = value.get("repositories", [])
            else:
                batch = value
            if not isinstance(batch, list):
                raise TypeError(f"Unexpected paginated response for {path}")
            output.extend(batch)
            if len(batch) < 100:
                return output
        raise RuntimeError(f"Pagination safety limit reached for {path}")

    def organizations(self) -> list[str]:
        try:
            values = self.paginate("/user/orgs?")
            names = [str(item["login"]) for item in values if isinstance(item, dict) and item.get("login")]
            if names:
                return sorted(set(names), key=str.casefold)
        except GitHubError as error:
            if error.status not in {401, 403, 404}:
                raise

        values = self.paginate("/installation/repositories?")
        owners = {
            str(item.get("owner", {}).get("login"))
            for item in values
            if isinstance(item, dict) and isinstance(item.get("owner"), dict)
        }
        owners.discard("")
        owners.discard("None")
        return sorted(owners, key=str.casefold)

    def repositories(self, org: str) -> list[dict[str, Any]]:
        encoded = urllib.parse.quote(org, safe="")
        values = self.paginate(f"/orgs/{encoded}/repos?type=all&sort=full_name&direction=asc")
        return [item for item in values if isinstance(item, dict)]

    def organization_exists(self, org: str) -> bool:
        encoded = urllib.parse.quote(org, safe="")
        try:
            self.get(f"/orgs/{encoded}")
            return True
        except GitHubError as error:
            if error.status == 404:
                return False
            raise

    def text(self, repository: str, path: str) -> str | None:
        owner, name = repository.split("/", 1)
        encoded = "/".join(urllib.parse.quote(part, safe="") for part in path.split("/"))
        try:
            value = self.get(
                f"/repos/{urllib.parse.quote(owner, safe='')}/{urllib.parse.quote(name, safe='')}/contents/{encoded}"
            )
        except GitHubError as error:
            if error.status == 404:
                return None
            raise
        if not isinstance(value, dict) or value.get("type") != "file":
            return None
        import base64

        return base64.b64decode(str(value.get("content", ""))).decode("utf-8", "replace")

    def code_search(self, needle: str, *, filename: str | None = None) -> set[str]:
        expression = f'"{needle}"'
        if filename:
            expression += f" filename:{filename}"
        query = urllib.parse.quote(expression, safe="")
        try:
            items = self.paginate(f"/search/code?q={query}")
        except GitHubError as error:
            if error.status in {403, 422}:
                return set()
            raise
        repositories: set[str] = set()
        for item in items:
            repository = item.get("repository", {}) if isinstance(item, dict) else {}
            full_name = repository.get("full_name") if isinstance(repository, dict) else None
            if full_name:
                repositories.add(str(full_name))
        return repositories


@dataclass(frozen=True)
class ClientRepo:
    org: str
    name: str
    default_branch: str
    package_org: str = ""
    package_name: str = ""

    @property
    def full_name(self) -> str:
        return f"{self.org}/{self.name}"

    @property
    def prefix(self) -> str:
        return self.name[: -len("-clients")]

    @property
    def test_org(self) -> str:
        return f"{self.org}-test"

    @property
    def zed_org(self) -> str:
        return self.package_org or slug(self.org)

    @property
    def zed_name(self) -> str:
        return self.package_name or slug(self.name)

    @property
    def zed_coordinate(self) -> str:
        return f"{self.zed_org}/{self.zed_name}"


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "client"


def parse_orgs(raw: str) -> list[str]:
    return sorted({part.strip() for part in raw.split(",") if part.strip()}, key=str.casefold)


def active_repo(repo: dict[str, Any]) -> bool:
    return not bool(repo.get("archived")) and not bool(repo.get("disabled"))


def client_repositories(org: str, repos: Iterable[dict[str, Any]]) -> list[ClientRepo]:
    output: list[ClientRepo] = []
    for repo in repos:
        name = str(repo.get("name", ""))
        if not active_repo(repo) or not name.endswith("-clients") or name == "clients":
            continue
        output.append(ClientRepo(org, name, str(repo.get("default_branch") or "main")))
    return sorted(output, key=lambda item: item.full_name.casefold())


def contains_coordinate(text: str, client: ClientRepo) -> bool:
    folded = text.casefold()
    needles = (
        client.zed_coordinate.casefold(),
        client.full_name.casefold(),
        f"github.com/{client.full_name}".casefold(),
        f"github.com:{client.full_name}".casefold(),
        f"{client.zed_coordinate}@".casefold(),
    )
    return any(needle in folded for needle in needles)


def enrich_zed_identity(gh: GitHub, client: ClientRepo) -> ClientRepo:
    package_org = ""
    package_name = ""
    manifest = gh.text(client.full_name, ".zpkg.toml")
    if manifest:
        try:
            parsed = tomllib.loads(manifest)
            package = parsed.get("package", {})
            if isinstance(package, dict):
                if isinstance(package.get("org"), str):
                    package_org = package["org"]
                if isinstance(package.get("name"), str):
                    package_name = package["name"]
        except tomllib.TOMLDecodeError:
            pass
    return ClientRepo(
        client.org,
        client.name,
        client.default_branch,
        package_org=package_org or slug(client.org),
        package_name=package_name or slug(client.name),
    )


def fallback_consumers(gh: GitHub, repos: Iterable[dict[str, Any]], client: ClientRepo) -> set[str]:
    found: set[str] = set()
    for repo in repos:
        if not active_repo(repo):
            continue
        full_name = str(repo.get("full_name") or "")
        if not full_name:
            continue
        manifest = gh.text(full_name, ".zpkg.toml")
        if manifest and contains_coordinate(manifest, client):
            found.add(full_name)
    return found


def likely_test_repos(repos: Iterable[dict[str, Any]], client: ClientRepo) -> list[str]:
    markers = ("e2e", "test", "consumer", "integration", "clients")
    prefix = client.prefix.casefold()
    candidates = []
    for repo in repos:
        if not active_repo(repo):
            continue
        name = str(repo.get("name", ""))
        folded = name.casefold()
        if prefix in folded and any(marker in folded for marker in markers):
            candidates.append(str(repo.get("full_name") or f"{client.test_org}/{name}"))
    return sorted(set(candidates), key=str.casefold)


def discover(gh: GitHub, organizations: list[str]) -> dict[str, Any]:
    production_orgs = [org for org in organizations if not org.casefold().endswith("-test")]
    accessible = set(organizations)
    repo_cache: dict[str, list[dict[str, Any]]] = {}
    clients: list[ClientRepo] = []
    discovery_errors: list[str] = []

    for org in production_orgs:
        try:
            repos = gh.repositories(org)
            repo_cache[org] = repos
            clients.extend(client_repositories(org, repos))
        except GitHubError as error:
            discovery_errors.append(str(error))

    include: list[dict[str, Any]] = []
    for raw_client in clients:
        client = enrich_zed_identity(gh, raw_client)
        errors: list[str] = []
        warnings: list[str] = []
        test_repos: list[dict[str, Any]] = []
        test_org_exists = client.test_org in accessible
        if not test_org_exists:
            try:
                test_org_exists = gh.organization_exists(client.test_org)
            except GitHubError as error:
                errors.append(str(error))
        if not test_org_exists:
            errors.append(f"Missing paired organization {client.test_org}")
        else:
            try:
                if client.test_org not in repo_cache:
                    repo_cache[client.test_org] = gh.repositories(client.test_org)
                test_repos = repo_cache[client.test_org]
            except GitHubError as error:
                errors.append(str(error))

        searched = gh.code_search(client.zed_coordinate, filename=".zpkg.toml")
        if client.full_name.casefold() != client.zed_coordinate.casefold():
            searched |= gh.code_search(client.full_name, filename=".zpkg.toml")
        searched.discard(client.full_name)
        accessible_folded = {org.casefold() for org in accessible}
        consumers = {
            repo
            for repo in searched
            if repo.split("/", 1)[0].casefold() in accessible_folded
            or repo.split("/", 1)[0].casefold() == client.test_org.casefold()
        }
        if test_repos:
            consumers |= fallback_consumers(gh, test_repos, client)
        test_consumers = sorted(
            (repo for repo in consumers if repo.split("/", 1)[0].casefold() == client.test_org.casefold()),
            key=str.casefold,
        )
        if not test_consumers:
            candidates = likely_test_repos(test_repos, client)
            errors.append(f"No discoverable {client.full_name} consumer in {client.test_org}")
            if candidates:
                warnings.append("Likely consumer candidates: " + ", ".join(candidates))

        include.append(
            {
                "repo": client.full_name,
                "org": client.org,
                "name": client.name,
                "prefix": client.prefix,
                "zed_org": client.zed_org,
                "zed_name": client.zed_name,
                "zed_coordinate": client.zed_coordinate,
                "default_branch": client.default_branch,
                "test_org": client.test_org,
                "consumers": sorted(consumers, key=str.casefold),
                "test_consumers": test_consumers,
                "errors": errors,
                "warnings": warnings,
            }
        )

    include.sort(key=lambda item: str(item["repo"]).casefold())
    total_errors = len(discovery_errors) + sum(len(item["errors"]) for item in include)
    return {
        "schemaVersion": 1,
        "organizations": organizations,
        "matrix": {"include": include},
        "summary": {
            "organizations": len(organizations),
            "productionOrganizations": len(production_orgs),
            "clientRepositories": len(include),
            "consumerRepositories": len({repo for item in include for repo in item["consumers"]}),
            "errors": total_errors,
        },
        "errors": discovery_errors,
    }



def build_batch_matrix(include: list[dict[str, Any]], batch_size: int) -> dict[str, Any]:
    if batch_size < 1:
        raise ValueError("batch_size must be at least 1")
    return {
        "include": [
            {
                "batch_id": index // batch_size + 1,
                "clients": include[index : index + batch_size],
            }
            for index in range(0, len(include), batch_size)
        ]
    }

def markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Nightly client fleet discovery",
        "",
        f"- Organizations visible: **{summary['organizations']}**",
        f"- Production organizations: **{summary['productionOrganizations']}**",
        f"- `*-clients` repositories: **{summary['clientRepositories']}**",
        f"- Discoverable consumer repositories: **{summary['consumerRepositories']}**",
        f"- Discovery errors: **{summary['errors']}**",
        "",
        "| Client repository | Zed coordinate | Paired test org | Test consumers | Status |",
        "|---|---|---|---:|---|",
    ]
    for item in report["matrix"]["include"]:
        status = "ok" if not item["errors"] else "blocked: " + "; ".join(item["errors"])
        lines.append(
            f"| `{item['repo']}` | `{item['zed_coordinate']}` | `{item['test_org']}` | {len(item['test_consumers'])} | {status} |"
        )
    if report["errors"]:
        lines.extend(["", "## Discovery errors", ""] + [f"- {value}" for value in report["errors"]])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--orgs", default="")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--matrix-output", type=Path, required=True)
    parser.add_argument("--batch-matrix-output", type=Path)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--markdown", type=Path, required=True)
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    gh = GitHub(os.environ.get("GITHUB_TOKEN", ""))
    organizations = parse_orgs(args.orgs) if args.orgs.strip() else gh.organizations()
    report = discover(gh, organizations)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.matrix_output.write_text(json.dumps(report["matrix"], separators=(",", ":")) + "\n", encoding="utf-8")
    if args.batch_matrix_output:
        args.batch_matrix_output.write_text(
            json.dumps(build_batch_matrix(report["matrix"]["include"], args.batch_size), separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
    args.markdown.write_text(markdown(report), encoding="utf-8")
    print(json.dumps(report["summary"], sort_keys=True))
    if not args.allow_empty and not report["matrix"]["include"]:
        print("No *-clients repositories discovered", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
