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

    def test_patch_exact_rust_toolchain_passes_and_moving_channel_fails(self):
        findings = []
        AUDIT.audit_rust_toolchain(
            "demo",
            '[toolchain]\nchannel = "1.98.1"\ncomponents = ["rustfmt", "clippy"]\n',
            findings,
        )
        self.assertEqual(findings, [])

        AUDIT.audit_rust_toolchain(
            "demo",
            '[toolchain]\nchannel = "stable"\n',
            findings,
        )
        self.assertEqual(findings[-1].code, "rust-toolchain-not-patch-exact")

    def test_canonical_rust_pr_workflow_passes_provenance_audit(self):
        findings = []
        AUDIT.audit_workflow(
            "demo",
            ".github/workflows/ci.yml",
            """
name: ci
on:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    steps:
      - name: checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - name: rust
        uses: dtolnay/rust-toolchain@4be7066ada62dd38de10e7b70166bc74ed198c30
        with:
          toolchain: 1.98.1
      - run: cargo test --locked
""",
            True,
            findings,
        )
        self.assertEqual(findings, [])

    def test_verified_imported_rust_authority_is_accepted(self):
        findings = []
        AUDIT.audit_workflow(
            "demo-e2e",
            ".github/workflows/ci.yml",
            r"""
name: ci
on:
  pull_request:
jobs:
  test:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - name: Install admitted sibling Rust authority
        run: |
          toolchain="$(sed -n 's/^channel = \"\\([^\"]*\\)\"/\\1/p' zed-cli/rust-toolchain.toml)"
          [[ "$toolchain" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
          rustup toolchain install "$toolchain" --profile minimal --no-self-update
          rustup default "$toolchain"
          test "$(rustc --version | awk '{print $2}')" = "$toolchain"
      - run: cargo test --locked
""",
            False,
            findings,
        )
        self.assertEqual(findings, [])

    def test_imported_rust_authority_must_be_fully_verified(self):
        findings = []
        AUDIT.audit_workflow(
            "demo-e2e",
            ".github/workflows/ci.yml",
            """
name: ci
on:
  workflow_dispatch:
jobs:
  test:
    steps:
      - run: |
          toolchain="$(cat zed-cli/rust-toolchain.toml)"
          rustup toolchain install "$toolchain"
          cargo test
""",
            False,
            findings,
        )
        self.assertIn(
            "rust-workflow-missing-toolchain-authority",
            {item.code for item in findings},
        )

    def test_workflow_rejects_mutable_actions_credentials_and_moving_rust(self):
        findings = []
        AUDIT.audit_workflow(
            "demo",
            ".github/workflows/ci.yml",
            """
name: ci
on:
  pull_request:
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@master
        with:
          toolchain: stable
      - run: rustup default stable && cargo test
""",
            False,
            findings,
        )
        codes = {item.code for item in findings}
        self.assertTrue(
            {
                "workflow-action-mutable",
                "workflow-checkout-persists-credentials",
                "rust-workflow-missing-toolchain-authority",
                "workflow-rust-toolchain-moving",
            }.issubset(codes)
        )

    def test_bare_rust_toolchain_action_is_implicit_stable(self):
        findings = []
        AUDIT.audit_workflow(
            "demo",
            ".github/workflows/ci.yml",
            """
name: ci
on:
  workflow_dispatch:
jobs:
  test:
    steps:
      - uses: dtolnay/rust-toolchain@4be7066ada62dd38de10e7b70166bc74ed198c30
      - run: cargo check --locked
""",
            True,
            findings,
        )
        self.assertEqual(
            [item.code for item in findings],
            ["workflow-rust-toolchain-implicit-stable"],
        )

    def test_non_rust_workflow_does_not_require_rust_authority(self):
        findings = []
        AUDIT.audit_workflow(
            "demo",
            ".github/workflows/docs.yml",
            """
name: docs
on:
  workflow_dispatch:
jobs:
  docs:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - run: node scripts/docs.mjs
""",
            False,
            findings,
        )
        self.assertEqual(findings, [])

    def test_remote_reusable_workflow_must_be_commit_pinned(self):
        findings = []
        AUDIT.audit_workflow(
            "demo",
            ".github/workflows/reuse.yml",
            """
name: reuse
on:
  workflow_dispatch:
jobs:
  shared:
    uses: zed-pkg/.github/.github/workflows/shared.yml@main
""",
            False,
            findings,
        )
        self.assertEqual([item.code for item in findings], ["workflow-action-mutable"])


if __name__ == "__main__":
    unittest.main()
