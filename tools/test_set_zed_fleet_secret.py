from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest


SCRIPT = pathlib.Path(__file__).with_name('set-zed-fleet-secret.sh').resolve()
TOKEN = 'github_pat_unit_test_value_with_entropy_1234567890'


class SetZedFleetSecretTests(unittest.TestCase):
    def make_stub(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        bindir = root / 'bin'
        bindir.mkdir()
        log = root / 'gh.log'
        state = root / 'state'
        stub = bindir / 'gh'
        stub.write_text(
            textwrap.dedent(
                r'''#!/usr/bin/env bash
                set -euo pipefail
                printf '%q ' "$@" >>"$GH_STUB_LOG"
                printf '\n' >>"$GH_STUB_LOG"

                case "${1:-}" in
                  api)
                    case "${2:-}" in
                      user)
                        printf 'unit-test-user\n'
                        ;;
                      repos/zed-pkg/.github)
                        printf 'zed-pkg/.github\n'
                        ;;
                      repos/zed-pkg/.github/actions/secrets?per_page=1)
                        :
                        ;;
                      *)
                        echo "unexpected api target: ${2:-}" >&2
                        exit 90
                        ;;
                    esac
                    ;;
                  secret)
                    case "${2:-}" in
                      set)
                        IFS= read -r -d '' supplied || true
                        [[ "$supplied" == "$EXPECTED_FLEET_TOKEN" ]] || {
                          echo 'candidate token mismatch' >&2
                          exit 91
                        }
                        ;;
                      list)
                        printf 'ZED_FLEET_GH_TOKEN\n'
                        ;;
                      *)
                        echo "unexpected secret subcommand: ${2:-}" >&2
                        exit 92
                        ;;
                    esac
                    ;;
                  workflow)
                    [[ "${2:-}" == run ]] || exit 93
                    ;;
                  run)
                    case "${2:-}" in
                      list)
                        count=0
                        [[ -f "$GH_STUB_STATE" ]] && count="$(cat "$GH_STUB_STATE")"
                        count=$((count + 1))
                        printf '%s' "$count" >"$GH_STUB_STATE"
                        if (( count == 1 )); then
                          printf '100\n'
                        else
                          printf '101\n'
                        fi
                        ;;
                      view)
                        printf 'https://github.example.invalid/actions/runs/101\n'
                        ;;
                      watch)
                        :
                        ;;
                      *)
                        echo "unexpected run subcommand: ${2:-}" >&2
                        exit 94
                        ;;
                    esac
                    ;;
                  *)
                    echo "unexpected gh command: ${1:-}" >&2
                    exit 95
                    ;;
                esac
                '''
            ).lstrip(),
            encoding='utf-8',
        )
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        return bindir, log

    def run_script(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            bindir, log = self.make_stub(root)
            env = os.environ.copy()
            env.update(
                {
                    'PATH': f'{bindir}:{env.get("PATH", "")}',
                    'ZED_FLEET_GH_TOKEN': TOKEN,
                    'EXPECTED_FLEET_TOKEN': TOKEN,
                    'GH_STUB_LOG': str(log),
                    'GH_STUB_STATE': str(root / 'state'),
                    'GITHUB_ACTIONS': 'true',
                }
            )
            completed = subprocess.run(
                ['bash', str(SCRIPT), *args],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            completed.gh_log = log.read_text(encoding='utf-8') if log.exists() else ''  # type: ignore[attr-defined]
            return completed

    def assert_token_absent(self, completed: subprocess.CompletedProcess[str]) -> None:
        mask_command = f'::add-mask::{TOKEN}\n'
        observable_stdout = completed.stdout.replace(mask_command, '')
        combined = observable_stdout + completed.stderr + getattr(completed, 'gh_log', '')
        self.assertNotIn(TOKEN, combined)

    def test_sets_and_verifies_without_dispatch(self) -> None:
        completed = self.run_script(['--apply', 'false', '--no-run'])
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('Verified repository Actions secret name: ZED_FLEET_GH_TOKEN', completed.stdout)
        self.assertIn(f'::add-mask::{TOKEN}\n', completed.stdout)
        self.assertNotIn('workflow run', getattr(completed, 'gh_log', ''))
        self.assert_token_absent(completed)

    def test_dispatches_exact_read_only_canary_and_resolves_new_run(self) -> None:
        completed = self.run_script(
            ['--apply', 'false', '--orgs', 'zed-pkg', '--no-watch']
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        log = getattr(completed, 'gh_log', '')
        self.assertIn('workflow run nightly-clients-fleet-hardening.yml', log)
        self.assertIn('apply=false', log)
        self.assertIn('orgs=zed-pkg', log)
        self.assertIn('Workflow run: https://github.example.invalid/actions/runs/101', completed.stdout)
        self.assertIn(f'::add-mask::{TOKEN}\n', completed.stdout)
        self.assert_token_absent(completed)

    def test_rejects_invalid_apply_value_before_secret_access(self) -> None:
        completed = self.run_script(['--apply', 'maybe'])
        self.assertEqual(completed.returncode, 2)
        self.assertIn('--apply must be true or false', completed.stderr)
        self.assertEqual(getattr(completed, 'gh_log', ''), '')
        self.assert_token_absent(completed)


if __name__ == '__main__':
    unittest.main()
