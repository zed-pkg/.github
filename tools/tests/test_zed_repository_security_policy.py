from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

TOOLS = Path(__file__).parents[1]
sys.path.insert(0, str(TOOLS))

CORE_SPEC = importlib.util.spec_from_file_location(
    "zed_repository_security_audit", TOOLS / "zed_repository_security_audit.py"
)
assert CORE_SPEC and CORE_SPEC.loader
CORE = importlib.util.module_from_spec(CORE_SPEC)
sys.modules[CORE_SPEC.name] = CORE
CORE_SPEC.loader.exec_module(CORE)

POLICY_SPEC = importlib.util.spec_from_file_location(
    "zed_repository_security_policy", TOOLS / "zed_repository_security_policy.py"
)
assert POLICY_SPEC and POLICY_SPEC.loader
POLICY = importlib.util.module_from_spec(POLICY_SPEC)
sys.modules[POLICY_SPEC.name] = POLICY
POLICY_SPEC.loader.exec_module(POLICY)


class FakeClient:
    def __init__(self, texts: dict[str, str | None]) -> None:
        self.texts = texts

    def text(self, full_name: str, path: str, ref: str) -> str | None:
        del full_name, ref
        return self.texts.get(path)


def snapshot(*paths: str, private: bool = False) -> CORE.RepoSnapshot:
    return CORE.RepoSnapshot(
        full_name="zed-pkg/example",
        name="example",
        private=private,
        archived=False,
        disabled=False,
        default_branch="main",
        default_sha="a" * 40,
        tree_sha="b" * 40,
        paths=tuple(sorted(paths)),
        truncated_tree=False,
    )


class AgentPolicyTests(unittest.TestCase):
    def test_root_lowercase_agents_is_canonical(self) -> None:
        snap = snapshot("agents.md")
        findings = POLICY.hardened_audit_snapshot(FakeClient({}), snap)
        self.assertNotIn("agents-instructions-missing", {item.code for item in findings})

    def test_nested_agents_does_not_replace_root_policy(self) -> None:
        snap = snapshot("docs/agents.md")
        findings = POLICY.hardened_audit_snapshot(FakeClient({}), snap)
        self.assertIn("agents-instructions-missing", {item.code for item in findings})


class DirenvPolicyTests(unittest.TestCase):
    def test_safe_flake_only_envrc_is_clean(self) -> None:
        text = """watch_file flake.nix
watch_file flake.lock
use flake
# Deliberately does not load secrets.
"""
        snap = snapshot("AGENTS.md", ".envrc")
        self.assertEqual(
            POLICY.hardened_audit_snapshot(FakeClient({".envrc": text}), snap),
            [],
        )

    def test_plaintext_dotenv_is_critical(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        findings = POLICY.hardened_audit_snapshot(
            FakeClient({".envrc": "dotenv_if_exists .env.production\n"}), snap
        )
        self.assertIn(
            ("critical", "envrc-loads-plaintext-environment"),
            {(item.severity, item.code) for item in findings},
        )

    def test_plaintext_source_is_critical(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        findings = POLICY.hardened_audit_snapshot(
            FakeClient({".envrc": "source .env.local\n"}), snap
        )
        self.assertIn(
            ("critical", "envrc-sources-plaintext-environment"),
            {(item.severity, item.code) for item in findings},
        )

    def test_dynamic_source_is_not_silently_accepted(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        findings = POLICY.hardened_audit_snapshot(
            FakeClient({".envrc": 'dotenv "$ENV_FILE"\n'}), snap
        )
        self.assertIn("envrc-dynamic-environment-source", {item.code for item in findings})

    def test_sensitive_literal_and_command_are_critical(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        findings = POLICY.hardened_audit_snapshot(
            FakeClient(
                {
                    ".envrc": (
                        "export DATABASE_URL=postgres://example.invalid/db\n"
                        "export API_TOKEN=$(secret-tool lookup service zed)\n"
                    )
                }
            ),
            snap,
        )
        codes = [item.code for item in findings]
        self.assertEqual(codes.count("envrc-sensitive-assignment"), 2)

    def test_sensitive_variable_forwarding_is_allowed(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        findings = POLICY.hardened_audit_snapshot(
            FakeClient(
                {
                    ".envrc": (
                        'export DATABASE_URL="$DATABASE_URL"\n'
                        "export API_TOKEN=${API_TOKEN:?managed secret required}\n"
                    )
                }
            ),
            snap,
        )
        self.assertNotIn("envrc-sensitive-assignment", {item.code for item in findings})

    def test_malformed_or_unreadable_envrc_fails_closed(self) -> None:
        snap = snapshot("AGENTS.md", ".envrc")
        malformed = POLICY.hardened_audit_snapshot(
            FakeClient({".envrc": "dotenv '.env\n"}), snap
        )
        self.assertIn("envrc-shell-syntax-unparseable", {item.code for item in malformed})

        unreadable = POLICY.hardened_audit_snapshot(FakeClient({".envrc": None}), snap)
        self.assertIn("envrc-unreadable", {item.code for item in unreadable})


if __name__ == "__main__":
    unittest.main()
