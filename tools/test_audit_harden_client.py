from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
AUDIT_SCRIPT = REPOSITORY_ROOT / "tools" / "audit_harden_client.sh"


class NativeCoverageTests(unittest.TestCase):
    def run_fixture(self, files: dict[str, str]) -> tuple[int, list[str], str]:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            fixture_root = temporary_root / "fixture"
            fixture_root.mkdir()
            for relative, content in files.items():
                path = fixture_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")

            capture = temporary_root / "commands.txt"
            workspace = temporary_root / "workspace"
            workspace.mkdir()
            environment = os.environ.copy()
            environment.update(
                {
                    "AUDIT_SCRIPT": str(AUDIT_SCRIPT),
                    "CAPTURE": str(capture),
                    "CASE_ROOT": str(fixture_root),
                    "CLIENT_REPO": "example/example-clients",
                    "CLIENT_ORG": "example",
                    "CLIENT_NAME": "example-clients",
                    "CLIENT_PREFIX": "example",
                    "ZED_ORG": "example",
                    "ZED_NAME": "example-clients",
                    "ZED_COORDINATE": "example/example-clients",
                    "DEFAULT_BRANCH": "main",
                    "TEST_ORG": "example-test",
                    "GITHUB_WORKSPACE": str(workspace),
                }
            )
            command = r'''
source "$AUDIT_SCRIPT"
run_logged() {
  printf '%s\n' "$1" >>"$CAPTURE"
}
STATUS=0
run_native_tests "$CASE_ROOT" consumer-fixture
printf 'STATUS=%s\n' "$STATUS"
'''
            result = subprocess.run(
                ["bash", "-c", command],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            commands = capture.read_text(encoding="utf-8").splitlines() if capture.exists() else []
            status_line = next(
                (line for line in result.stdout.splitlines() if line.startswith("STATUS=")),
                "STATUS=99",
            )
            return int(status_line.removeprefix("STATUS=")), commands, result.stdout + result.stderr

    def test_manifest_without_native_command_fails_closed(self) -> None:
        status, commands, output = self.run_fixture(
            {
                ".zpkg.toml": """
[package]
org = "example"
name = "consumer"
version = "0.1.0"
""",
            }
        )

        self.assertEqual(status, 1, output)
        self.assertEqual(commands, [])
        self.assertIn("no native build, check, or test command ran", output)

    def test_node_build_runs_before_test(self) -> None:
        status, commands, output = self.run_fixture(
            {
                "package.json": json.dumps(
                    {
                        "name": "consumer",
                        "scripts": {
                            "test": "node --test",
                            "build": "tsc",
                        },
                    }
                ),
            }
        )

        self.assertEqual(status, 0, output)
        self.assertLess(
            commands.index("consumer-fixture-.-node-build"),
            commands.index("consumer-fixture-.-node-test"),
        )

    def test_dotnet_solution_gets_build_and_test_coverage(self) -> None:
        status, commands, output = self.run_fixture(
            {
                "Consumer.sln": "Microsoft Visual Studio Solution File, Format Version 12.00\n",
                "src/Consumer.csproj": '<Project Sdk="Microsoft.NET.Sdk" />\n',
            }
        )

        self.assertEqual(status, 0, output)
        self.assertIn("consumer-fixture-.-dotnet-build", commands)
        self.assertIn("consumer-fixture-.-dotnet-test", commands)

    def test_maven_project_gets_test_coverage(self) -> None:
        status, commands, output = self.run_fixture(
            {
                "pom.xml": "<project />\n",
            }
        )

        self.assertEqual(status, 0, output)
        self.assertIn("consumer-fixture-.-maven-test", commands)

    def test_php_and_ruby_behavioral_tests_are_not_only_linted(self) -> None:
        status, commands, output = self.run_fixture(
            {
                "php/composer.json": json.dumps({"name": "example/consumer"}),
                "php/tests/client_test.php": "<?php exit(0);\n",
                "ruby/consumer.gemspec": "Gem::Specification.new {}\n",
                "ruby/test/client_test.rb": "exit 0\n",
            }
        )

        self.assertEqual(status, 0, output)
        self.assertIn("consumer-fixture-._php-php-test", commands)
        self.assertIn("consumer-fixture-._ruby-ruby-test", commands)


    def test_existing_automation_branch_is_not_reset_to_default(self) -> None:
        source = AUDIT_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'checkout -B "$BRANCH" "origin/$BRANCH"',
            source,
        )
        self.assertIn(
            'merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD',
            source,
        )
        self.assertNotIn(
            'fetch origin "$DEFAULT_BRANCH" "$BRANCH" || git -C "$TARGET" fetch origin "$DEFAULT_BRANCH"',
            source,
        )

    def test_failed_validation_cannot_push_generated_changes(self) -> None:
        source = AUDIT_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            '[[ "$CHANGED" == true && "$APPLY" == true && "$STATUS" -eq 0 ]]',
            source,
        )
        self.assertIn("unsafe branch refresh blocked", source)

    def test_automation_push_is_fast_forward_only(self) -> None:
        source = AUDIT_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'git -C "$TARGET" push origin "HEAD:$BRANCH"',
            source,
        )
        self.assertNotIn("push --force", source)


if __name__ == "__main__":
    unittest.main()
