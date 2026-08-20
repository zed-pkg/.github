from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


MODULE_PATH = Path(__file__).with_name("zed_fleet_audit.py")
SPEC = importlib.util.spec_from_file_location("zed_fleet_audit", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeGitHub:
    def __init__(self, files: dict[tuple[str, str], str]) -> None:
        self.files = files

    def text(self, repo: str, path: str) -> str | None:
        return self.files.get((repo, path))

    def names(self, _repo: str, _path: str) -> set[str]:
        return set()


def manifest(org: str, name: str, dependencies: tuple[str, ...] = ()) -> str:
    lines = [
        "[package]",
        f'org = "{org}"',
        f'name = "{name}"',
        'version = "0.1.0"',
        "",
        "[install]",
        'destination = ".vendor/.zed"',
        "",
        "[dependencies]",
    ]
    lines.extend(f'"{dependency}" = "^0.1.0"' for dependency in dependencies)
    lines.extend(["", "[targets.repository]", 'root = "."', ""])
    return "\n".join(lines)


class RepositoryRoleSelectionTests(unittest.TestCase):
    def test_lib_core_wins_when_historical_lib_still_exists(self) -> None:
        files = {
            ("zed-pkg/zed-clients", ".zpkg.toml"): manifest(
                "zed-pkg", "zed-clients", ("zed-pkg/zed-interfaces",)
            ),
            ("zed-pkg/zed-interfaces", ".zpkg.toml"): manifest("zed-pkg", "zed-interfaces"),
            ("zed-pkg/zed-lib", ".zpkg.toml"): manifest("zed-pkg", "zed-lib"),
            ("zed-pkg/zed-lib-core", ".zpkg.toml"): manifest("zed-pkg", "zed-lib-core"),
            ("zed-pkg/zed-cli", ".zpkg.toml"): manifest(
                "zed-pkg", "zed-cli", ("zed-pkg/zed-clients", "zed-pkg/zed-interfaces")
            ),
            ("zed-pkg/zed-monorepo", ".zpkg.toml"): manifest("zed-pkg", "zed-monorepo"),
        }
        repositories = {
            "zed-clients",
            "zed-interfaces",
            "zed-lib",
            "zed-lib-core",
            "zed-cli",
            "zed-monorepo",
        }

        family = MODULE.audit_family(FakeGitHub(files), "zed-pkg", repositories, "zed-clients")

        self.assertEqual(family["repositories"]["library"], "zed-lib-core")
        dependency_findings = [
            item for item in family["findings"]
            if item["code"] in {"clients-missing-library", "cli-missing-dependency"}
        ]
        self.assertEqual(len(dependency_findings), 2)
        self.assertTrue(all("zed-pkg/zed-lib-core" in item["message"] for item in dependency_findings))


if __name__ == "__main__":
    unittest.main(verbosity=2)
