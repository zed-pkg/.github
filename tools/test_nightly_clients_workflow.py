from __future__ import annotations

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "nightly-clients-fleet-hardening.yml"


class NightlyClientsWorkflowTests(unittest.TestCase):
    def test_schedule_is_single_timezone_aware_off_peak_trigger(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")

        self.assertEqual(source.count("- cron:"), 1)
        self.assertIn("- cron: '17 3 * * *'", source)
        self.assertIn("timezone: America/Chicago", source)
        self.assertNotIn("Skipping duplicate UTC trigger", source)
        self.assertNotIn("needs.gate", source)

    def test_bot_pushes_never_force_update_review_branches(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('git -C "$target" push origin "HEAD:$branch"', source)
        self.assertNotIn("push --force", source)
        self.assertIn("merge-base --is-ancestor origin/main HEAD", source)

    def test_runner_actions_are_node_24_compatible_pins(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")

        self.assertNotIn("11d5960a326750d5838078e36cf38b85af677262", source)
        self.assertNotIn("ea165f8d65b6e75b540449e92b4886f43607fa02", source)
        self.assertNotIn("d3f86a106a0bac45b974a628896c90dbdf5c8093", source)
        self.assertIn("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", source)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", source)
        self.assertIn("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
