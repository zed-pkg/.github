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


if __name__ == "__main__":
    unittest.main(verbosity=2)
