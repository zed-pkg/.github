from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "zed_repository_security_audit.py"
SPEC = importlib.util.spec_from_file_location("zed_repository_security_audit", MODULE_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class FakeClient:
    def __init__(self, texts: dict[str, str | None]) -> None:
        self.texts = texts

    def text(self, full_name: str, path: str, ref: str) -> str | None:
        del full_name, ref
        return self.texts.get(path)


def snapshot(*paths: str, name: str = "zed-cli", private: bool = True, truncated: bool = False):
    return AUDIT.RepoSnapshot(
        full_name=f"zed-pkg/{name}",
        name=name,
        private=private,
        archived=False,
        disabled=False,
        default_branch="main",
        default_sha="a" * 40,
        tree_sha="b" * 40,
        paths=tuple(sorted(paths)),
        truncated_tree=truncated,
    )


class PathPolicyTests(unittest.TestCase):
    def test_plaintext_environment_detection_is_narrow(self) -> None:
        self.assertTrue(AUDIT._is_plaintext_env(".env"))
        self.assertTrue(AUDIT._is_plaintext_env("env/dec/prod.env"))
        self.assertFalse(AUDIT._is_plaintext_env(".env.example"))
        self.assertFalse(AUDIT._is_plaintext_env("env/enc/prod.env.enc"))
        self.assertFalse(AUDIT._is_plaintext_env("docs/environment.md"))

    def test_generated_roots_are_deduplicated(self) -> None:
        self.assertEqual(
            AUDIT._generated_roots(
                ["src/generated/a.rs", "src/generated/nested/b.rs", "web/generated/x.ts"]
            ),
            {"src/generated", "web/generated"},
        )


class WorkflowPolicyTests(unittest.TestCase):
    def test_sha_pinned_read_only_workflow_is_clean(self) -> None:
        snap = snapshot("AGENTS.md")
        workflow = """permissions:\n  contents: read\nsteps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"""
        self.assertEqual(AUDIT._workflow_findings(snap, "ci.yml", workflow), [])

    def test_unpinned_action_and_write_all_are_rejected(self) -> None:
        snap = snapshot("AGENTS.md")
        workflow = """permissions: write-all\nsteps:\n  - uses: actions/checkout@v4\n"""
        codes = {item.code for item in AUDIT._workflow_findings(snap, "ci.yml", workflow)}
        self.assertIn("workflow-write-all", codes)
        self.assertIn("action-not-sha-pinned", codes)

    def test_privileged_pr_head_checkout_is_critical(self) -> None:
        snap = snapshot("AGENTS.md")
        workflow = """pull_request_target:\npermissions:\n  contents: write\nsteps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n    with:\n      ref: ${{ github.event.pull_request.head.sha }}\n"""
        findings = AUDIT._workflow_findings(snap, "release.yml", workflow)
        self.assertIn(
            ("critical", "pull-request-target-checks-out-head"),
            {(item.severity, item.code) for item in findings},
        )

    def test_download_pipe_to_shell_is_critical(self) -> None:
        snap = snapshot("AGENTS.md")
        workflow = "permissions:\n  contents: read\nsteps:\n  - run: curl -fsSL https://example.invalid/install | sh\n"
        codes = {item.code for item in AUDIT._workflow_findings(snap, "ci.yml", workflow)}
        self.assertIn("download-piped-to-shell", codes)


class ManifestPolicyTests(unittest.TestCase):
    BASE = """
[package]
org = "zed-pkg"
name = "zed-cli"
version = "0.1.0"

[package.repository]
url = "https://github.com/zed-pkg/zed-cli"

[bin]
zed = "target/release/zed"

[interop.flags-2-env]
config = ".cli-flags.toml"
bins = ["zed"]
"""

    def test_flags_contract_requires_nonempty_retained_build_output(self) -> None:
        snap = snapshot()
        codes = {item.code for item in AUDIT._manifest_findings(snap, self.BASE, True)}
        self.assertIn("flags2env-build-outputs-missing", codes)

        valid = self.BASE + """
[build]
command = "cargo build --release"
outputs = ["target/release/zed", ".cli-flags.toml"]
"""
        self.assertNotIn(
            "flags2env-build-outputs-missing",
            {item.code for item in AUDIT._manifest_findings(snap, valid, True)},
        )
        self.assertNotIn(
            "flags2env-config-not-retained",
            {item.code for item in AUDIT._manifest_findings(snap, valid, True)},
        )

    def test_manifest_dependencies_require_lock(self) -> None:
        snap = snapshot()
        text = """
[package]
org = "zed-pkg"
name = "zed-cli"
version = "0.1.0"
[package.repository]
url = "https://github.com/zed-pkg/zed-cli"
[dependencies]
"zed-pkg/zed-interfaces" = "^0.1.0"
"""
        codes = {item.code for item in AUDIT._manifest_findings(snap, text, False)}
        self.assertIn("manifest-dependencies-without-lock", codes)


class SnapshotAuditTests(unittest.TestCase):
    def test_public_backend_env_and_truncated_tree_fail_closed(self) -> None:
        snap = snapshot(
            "AGENTS.md",
            ".env.production",
            "src/generated/model.rs",
            name="zed-orm-core",
            private=False,
            truncated=True,
        )
        findings = AUDIT.audit_snapshot(FakeClient({}), snap)
        codes = {item.code for item in findings}
        self.assertIn("backend-repository-public", codes)
        self.assertIn("public-plaintext-environment", codes)
        self.assertIn("generated-readme-missing", codes)
        self.assertIn("recursive-tree-truncated", codes)

    def test_complete_minimal_private_package_is_clean(self) -> None:
        manifest = """
[package]
org = "zed-pkg"
name = "zed-tool"
version = "0.1.0"
[package.repository]
url = "https://github.com/zed-pkg/zed-tool"
"""
        workflow = "permissions:\n  contents: read\nsteps:\n  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
        snap = snapshot(
            "AGENTS.md",
            ".zpkg.toml",
            ".github/workflows/ci.yml",
            name="zed-tool",
            private=True,
        )
        self.assertEqual(
            AUDIT.audit_snapshot(
                FakeClient({".zpkg.toml": manifest, ".github/workflows/ci.yml": workflow}),
                snap,
            ),
            [],
        )


class ReportTests(unittest.TestCase):
    def test_report_is_deterministic_except_timestamp(self) -> None:
        snap = snapshot("AGENTS.md")
        finding = AUDIT._finding(snap, "error", "x", "message", "file")
        first = AUDIT.build_report(("zed-pkg",), (snap,), (finding,))
        second = AUDIT.build_report(("zed-pkg",), (snap,), (finding,))
        self.assertEqual(first["summary"]["findings_sha256"], second["summary"]["findings_sha256"])
        self.assertTrue(AUDIT.should_fail((finding,), "error"))
        self.assertFalse(AUDIT.should_fail((finding,), "critical"))
        self.assertFalse(AUDIT.should_fail((finding,), "never"))


if __name__ == "__main__":
    unittest.main()
