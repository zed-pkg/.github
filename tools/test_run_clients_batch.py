from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("run_clients_batch.py")
spec = importlib.util.spec_from_file_location("run_clients_batch", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class BatchRunnerTests(unittest.TestCase):
    def test_client_environment_is_complete_and_compact(self) -> None:
        client = {
            "repo": "fiducia-cloud/fiducia-clients",
            "org": "fiducia-cloud",
            "name": "fiducia-clients",
            "prefix": "fiducia",
            "zed_org": "fiducia-cloud",
            "zed_name": "fiducia-clients",
            "zed_coordinate": "fiducia-cloud/fiducia-clients",
            "default_branch": "main",
            "test_org": "fiducia-cloud-test",
            "consumers": ["fiducia-cloud-test/fiducia-e2e"],
            "test_consumers": ["fiducia-cloud-test/fiducia-e2e"],
            "errors": [],
            "warnings": ["example"],
        }
        env = module.client_environment({"KEEP": "yes"}, client)
        self.assertEqual(env["KEEP"], "yes")
        self.assertEqual(env["ZED_COORDINATE"], "fiducia-cloud/fiducia-clients")
        self.assertEqual(env["CONSUMERS_JSON"], '["fiducia-cloud-test/fiducia-e2e"]')
        self.assertEqual(env["DISCOVERY_WARNINGS_JSON"], '["example"]')

    def test_missing_required_field_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "zed_coordinate"):
            module.client_environment({}, {"repo": "acme/a-clients"})

    def test_target_clone_materializes_recorded_gitlinks(self) -> None:
        command = module.clone_command(
            "opto-sync/opto-sync-clients",
            Path("fleet-workspace/target"),
            branch="main",
        )
        self.assertEqual(command[:5], ["gh", "repo", "clone", "opto-sync/opto-sync-clients", "fleet-workspace/target"])
        self.assertIn("--branch", command)
        self.assertIn("main", command)
        self.assertIn("--no-single-branch", command)
        self.assertIn("--recurse-submodules", command)
        self.assertGreater(command.index("--recurse-submodules"), command.index("--"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
