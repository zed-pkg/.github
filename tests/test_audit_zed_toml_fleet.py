#!/usr/bin/env python3

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_NAME = "audit_zed_toml_fleet"
SPEC = importlib.util.spec_from_file_location(
    MODULE_NAME, ROOT / "scripts" / "audit_zed_toml_fleet.py"
)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[MODULE_NAME] = AUDIT
SPEC.loader.exec_module(AUDIT)


class FleetAuditTests(unittest.TestCase):
    def test_canonical_flags_contract_passes(self):
        findings = []
        AUDIT.audit_cli_flags(
            "demo",
            """
[parse]
allow_unknown = false

[env]
dotenv = false
files = []

[flags.jobs]
env = "JOBS"
aliases = ["jobs"]
type = "integer"
""",
            findings,
        )
        self.assertEqual(findings, [])

    def test_flags_contract_rejects_legacy_and_ambient_state(self):
        findings = []
        AUDIT.audit_cli_flags(
            "demo",
            """
# github.com/ORESoftware/flags-2-env
[parse]
allow_unknown = true

[env]
dotenv = true
files = [".env"]

[flags.jobs]
env = "JOBS"
long = "jobs"
type = "int"
""",
            findings,
        )
        codes = {item.code for item in findings}
        self.assertTrue(
            {
                "cli-flags-not-fail-closed",
                "cli-flags-dotenv-enabled",
                "cli-flags-dotenv-files",
                "legacy-flags-authority",
                "legacy-flags-key",
                "noncanonical-flag-type",
            }.issubset(codes)
        )

    def test_root_alias_and_env_collisions_fail(self):
        findings = []
        AUDIT.audit_cli_flags(
            "demo",
            """
[parse]
allow_unknown = false
[env]
dotenv = false
files = []

[flags.first]
env = "SHARED"
aliases = ["same"]
type = "string"

[flags.second]
env = "SHARED"
aliases = ["same"]
type = "string"
""",
            findings,
        )
        codes = [item.code for item in findings]
        self.assertIn("duplicate-root-env", codes)
        self.assertIn("duplicate-root-spelling", codes)

    def test_zpkg_requires_current_cli_range_and_owned_repository(self):
        findings = []
        AUDIT.audit_zpkg(
            "demo-server.rs",
            """
[package]
org = "zed-pkg"
name = "demo-server"
version = "1.0.0"

[package.repository]
url = "https://github.com/zed-pkg/wrong-repo"

[dependencies]
"zed-pkg/zed-cli" = "^0.2.3"

[cli]
flags_runtime = "flags-2-env"
flags_contract = ".cli-flags.toml"
""",
            False,
            findings,
        )
        codes = {item.code for item in findings}
        self.assertEqual(
            codes,
            {"zpkg-repository-drift", "stale-zed-cli-range", "missing-cli-flags-contract"},
        )

    def test_current_cli_range_is_not_stale(self):
        self.assertIsNone(AUDIT.STALE_ZED_CLI.match("^0.3.0"))
        self.assertIsNone(AUDIT.STALE_ZED_CLI.match("=0.3.0"))
        self.assertIsNotNone(AUDIT.STALE_ZED_CLI.match("^0.2.3"))


if __name__ == "__main__":
    unittest.main()
