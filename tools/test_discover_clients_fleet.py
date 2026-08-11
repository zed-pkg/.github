from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).with_name("discover_clients_fleet.py")
spec = importlib.util.spec_from_file_location("discover_clients_fleet", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class FakeGitHub:
    def __init__(self, files: dict[tuple[str, str], str | None]) -> None:
        self.files = files

    def text(self, repository: str, path: str) -> str | None:
        return self.files.get((repository, path))


class DiscoveryTests(unittest.TestCase):
    def test_client_filter_is_exact_and_active(self) -> None:
        repos = [
            {"name": "alpha-clients", "full_name": "acme/alpha-clients", "default_branch": "dev"},
            {"name": "clients", "full_name": "acme/clients"},
            {"name": "alpha-clients-old", "full_name": "acme/alpha-clients-old"},
            {"name": "beta-clients", "full_name": "acme/beta-clients", "archived": True},
        ]
        values = module.client_repositories("acme", repos)
        self.assertEqual([item.full_name for item in values], ["acme/alpha-clients"])
        self.assertEqual(values[0].default_branch, "dev")
        self.assertEqual(values[0].test_org, "acme-test")

    def test_coordinate_matching_covers_zed_and_vcs_forms(self) -> None:
        client = module.ClientRepo("fiducia-cloud", "fiducia-clients", "main")
        self.assertTrue(module.contains_coordinate('"fiducia-cloud/fiducia-clients" = "^1"', client))
        self.assertTrue(module.contains_coordinate("https://github.com/fiducia-cloud/fiducia-clients.git", client))
        self.assertFalse(module.contains_coordinate("other-org/fiducia-clients", client))

    def test_distinct_zed_package_coordinate_is_honored(self) -> None:
        client = module.ClientRepo(
            "AcmeEngineering",
            "sdk-clients",
            "main",
            package_org="acme",
            package_name="public-clients",
        )
        self.assertEqual(client.zed_coordinate, "acme/public-clients")
        self.assertTrue(module.contains_coordinate('"acme/public-clients" = "^2"', client))
        self.assertTrue(module.contains_coordinate("github.com/AcmeEngineering/sdk-clients", client))

    def test_manifest_identity_enrichment_and_slug_fallback(self) -> None:
        gh = FakeGitHub(
            {
                (
                    "AcmeEngineering/sdk-clients",
                    ".zpkg.toml",
                ): '[package]\norg = "acme"\nname = "public-clients"\nversion = "1.0.0"\n',
            }
        )
        enriched = module.enrich_zed_identity(
            gh,
            module.ClientRepo("AcmeEngineering", "sdk-clients", "main"),
        )
        self.assertEqual(enriched.zed_coordinate, "acme/public-clients")

        fallback = module.enrich_zed_identity(
            FakeGitHub({}),
            module.ClientRepo("AcmeEngineering", "SDK-clients", "main"),
        )
        self.assertEqual(fallback.zed_coordinate, "acmeengineering/sdk-clients")

    def test_batch_matrix_is_stable_and_bounded(self) -> None:
        values = [{"repo": f"acme/client-{index}-clients"} for index in range(9)]
        matrix = module.build_batch_matrix(values, 4)
        self.assertEqual([item["batch_id"] for item in matrix["include"]], [1, 2, 3])
        self.assertEqual([len(item["clients"]) for item in matrix["include"]], [4, 4, 1])
        self.assertEqual(matrix["include"][1]["clients"][0]["repo"], "acme/client-4-clients")
        with self.assertRaises(ValueError):
            module.build_batch_matrix(values, 0)

    def test_likely_test_repositories_are_prefix_scoped(self) -> None:
        client = module.ClientRepo("fiducia-cloud", "fiducia-clients", "main")
        repos = [
            {"name": "fiducia-e2e", "full_name": "fiducia-cloud-test/fiducia-e2e"},
            {"name": "other-e2e", "full_name": "fiducia-cloud-test/other-e2e"},
            {"name": "fiducia-test-old", "full_name": "fiducia-cloud-test/fiducia-test-old", "archived": True},
        ]
        self.assertEqual(module.likely_test_repos(repos, client), ["fiducia-cloud-test/fiducia-e2e"])


    def test_explicit_ca_bundle_is_loaded_by_verified_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "runner-ca.pem"
            bundle.write_text("test certificate bundle\n", encoding="utf-8")
            sentinel = object()
            with mock.patch.object(module.ssl, "create_default_context", return_value=sentinel) as create:
                context = module.github_ssl_context(
                    environ={"GITHUB_CA_BUNDLE": str(bundle)},
                    candidates=(),
                )
            self.assertIs(context, sentinel)
            create.assert_called_once_with(cafile=str(bundle))

    def test_invalid_explicit_ca_bundle_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "missing.pem"
            with self.assertRaisesRegex(ValueError, "GITHUB_CA_BUNDLE"):
                module.github_ca_bundle(
                    environ={"GITHUB_CA_BUNDLE": str(missing)},
                    candidates=(),
                )

    def test_system_ca_bundle_is_used_when_python_defaults_diverge(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "missing.pem"
            bundle = Path(temporary) / "system-ca.pem"
            bundle.write_text("test certificate bundle\n", encoding="utf-8")
            self.assertEqual(
                module.github_ca_bundle(environ={}, candidates=(missing, bundle)),
                bundle,
            )

    def test_github_requests_receive_the_verified_ssl_context(self) -> None:
        context = mock.sentinel.ssl_context
        response = io.BytesIO(b'{"ok": true}')
        with mock.patch.object(module.urllib.request, "urlopen", return_value=response) as urlopen:
            value = module.GitHub(
                "token",
                api="https://example.test",
                ssl_context=context,
            ).get("/repos/acme/sdk")
        self.assertEqual(value, {"ok": True})
        self.assertIs(urlopen.call_args.kwargs["context"], context)
        self.assertEqual(urlopen.call_args.kwargs["timeout"], 45)


if __name__ == "__main__":
    unittest.main(verbosity=2)
