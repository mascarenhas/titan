"""Offline tests for scripts/check_bundled_deps.py."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts/check_bundled_deps.py"
REPO_ROOT = SCRIPT_PATH.parents[1]
SPEC = importlib.util.spec_from_file_location("check_bundled_deps", SCRIPT_PATH)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MOD)


class FakeFetcher:
    def __init__(self, responses, manifest_text=""):
        self.responses = responses
        self.manifest_text = manifest_text

    def github_json(self, path):
        if path not in self.responses:
            raise RuntimeError(f"unexpected GitHub API path: {path}")
        value = self.responses[path]
        if isinstance(value, Exception):
            raise value
        return value

    def get_text(self, url, headers=None):
        if url == MOD.LUAROCKS_MANIFEST_5_5:
            if isinstance(self.manifest_text, Exception):
                raise self.manifest_text
            return self.manifest_text
        raise RuntimeError(f"unexpected URL: {url}")


SAMPLE_MANIFEST = """
commands = {}
modules = {}
repository = {
   ["15puzzle.nvim"] = {
      ["1.4.0-1"] = { { arch = "src" } }
   },
   argparse = {
      ["0.7.2-1"] = { { arch = "rockspec" } },
      ["scm-1"] = { { arch = "rockspec" } }
   },
   busted = {
      ["2.0.rc13-0"] = { { arch = "src" } },
      ["2.3.0-1"] = { { arch = "src" } }
   },
   cluacov = {
      ["0.1.4-1"] = { { arch = "src" } },
      ["1.0.0-1"] = { { arch = "src" } }
   },
   inspect = {
      ["3.1.3-0"] = { { arch = "src" } }
   },
   lpeglabel = {
      ["1.6.2-1"] = { { arch = "src" } }
   },
   luafilesystem = {
      ["1.9.0-1"] = { { arch = "src" } }
   },
   luv = {
      ["1.52.1-0"] = { { arch = "src" } },
      ["1.53.0-1"] = { { arch = "src" } },
      ["v1.50.0-0"] = { { arch = "src" } },
      ["scm-1"] = { { arch = "src" } }
   },
}
"""


class BundledDepsTests(unittest.TestCase):
    def test_version_and_constraint_helpers(self):
        self.assertTrue(MOD.satisfies_constraint("1.52.1-0", ">= 1.52.1"))
        self.assertTrue(MOD.satisfies_constraint("2.3.0-1", ">= 2.0"))
        self.assertFalse(MOD.satisfies_constraint("1.9.0-1", ">= 2.0"))
        self.assertTrue(MOD.satisfies_constraint("5.5.1", "~> 5.5"))
        self.assertFalse(MOD.satisfies_constraint("6.0.0", "~> 5.5"))
        self.assertTrue(MOD.satisfies_constraint("1.6.9", "~> 1.6.2"))
        self.assertFalse(MOD.satisfies_constraint("1.7.0", "~> 1.6.2"))
        self.assertEqual(MOD.sqlite_release_code("3.53.4"), "3530400")
        self.assertEqual(MOD.sqlite_release_code("3.54.1"), "3540100")

    def test_manifest_parser_filters_prereleases_and_non_numeric(self):
        parsed = MOD.parse_luarocks_manifest(SAMPLE_MANIFEST, ["luv", "busted", "argparse"])
        self.assertEqual(MOD.latest_stable_rock_version(parsed["luv"]), "1.53.0-1")
        self.assertEqual(MOD.latest_stable_rock_version(parsed["busted"]), "2.3.0-1")
        self.assertEqual(MOD.latest_stable_rock_version(parsed["argparse"]), "0.7.2-1")

    def test_live_repository_pins_pass_offline_parity(self):
        pins, parity_errors = MOD.load_repo_pins(REPO_ROOT)
        self.assertEqual(parity_errors, [])
        self.assertEqual(
            sorted(pins["bundled"].keys()),
            ["libbacktrace", "libuv", "llhttp", "lpeglabel", "openssl", "sqlite3", "uwasi"],
        )
        self.assertNotIn("minicoro", pins["bundled"])
        self.assertIn("luv", pins["luarocks_lock"])

    def test_parity_detects_mismatched_windows_tsv_and_uwasi_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in (
                "Makefile",
                "luarocks.lock",
                "vendor/windows-native/dependencies.tsv",
                "vendor/libbacktrace/dependencies.tsv",
                "vendor/lpeglabel/UPSTREAM.md",
                "vendor/uwasi/UPSTREAM.md",
                "scripts/build_uwasi_bundle.mjs",
            ):
                dst = root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO_ROOT / rel, dst)
            for rockspec in REPO_ROOT.glob("titan-*.rockspec"):
                shutil.copy2(rockspec, root / rockspec.name)

            tsv = root / "vendor/windows-native/dependencies.tsv"
            tsv.write_text(tsv.read_text(encoding="utf-8").replace("libuv-v", "libuv-v99."), encoding="utf-8")
            builder = root / "scripts/build_uwasi_bundle.mjs"
            builder.write_text(
                builder.read_text(encoding="utf-8").replace("11b4ebf5fef47d49eb7da8a9d21483cf921e1a6c", "0" * 40),
                encoding="utf-8",
            )
            _, errors = MOD.load_repo_pins(root)
            self.assertTrue(any("libuv:" in err for err in errors), errors)
            self.assertTrue(any("uwasi:" in err for err in errors), errors)

    def test_end_to_end_status_classification_and_openssl_4x_track(self):
        pins, parity_errors = MOD.load_repo_pins(REPO_ROOT)
        self.assertEqual(parity_errors, [])
        bt_sha = pins["bundled"]["libbacktrace"]["commit"]
        fetcher = FakeFetcher(
            {
                "/repos/libuv/libuv/releases?per_page=100&page=1": [
                    {"tag_name": f"v{pins['bundled']['libuv']['version']}", "draft": False, "prerelease": False, "html_url": "https://example.test/libuv"},
                ],
                "/repos/nodejs/llhttp/git/matching-refs/tags/release/v": [
                    {"ref": "refs/tags/release/v9.4.3"},
                    {"ref": "refs/tags/release/v9.4.4"},
                ],
                "/repos/sqlite/sqlite/git/matching-refs/tags/version-": [
                    {"ref": "refs/tags/vesion-3.45.1"},
                    {"ref": "refs/tags/version-3.53.4"},
                    {"ref": "refs/tags/version-3.54.1"},
                ],
                "/repos/ianlancetaylor/libbacktrace/commits/master": {
                    "sha": bt_sha,
                    "commit": {"committer": {"date": "2026-09-03T19:30:32Z"}},
                },
                "/repos/sqmedeiros/lpeglabel/tags?per_page=100": [
                    {"name": f"v{pins['bundled']['lpeglabel']['version']}"},
                ],
                "/repos/swiftwasm/uwasi/releases?per_page=100&page=1": [
                    {"tag_name": pins["bundled"]["uwasi"]["version"], "draft": False, "prerelease": False, "html_url": "https://example.test/uwasi"},
                ],
                "/repos/openssl/openssl/releases?per_page=100&page=1": [
                    {"tag_name": "openssl-4.2.0-beta1", "draft": False, "prerelease": True, "html_url": "https://example.test/o-beta"},
                    {"tag_name": "openssl-4.1.0", "draft": False, "prerelease": False, "html_url": "https://example.test/o-410"},
                    {"tag_name": "openssl-3.5.9", "draft": False, "prerelease": False, "html_url": "https://example.test/o-359"},
                ],
            },
            manifest_text=SAMPLE_MANIFEST,
        )
        bundled = {item.name: item for item in MOD.check_bundled_dependencies(pins, fetcher)}
        rockspec = {item.name: item for item in MOD.check_rockspec_dependencies(pins, fetcher)}

        self.assertEqual(bundled["libuv"].status, "up-to-date")
        self.assertEqual(bundled["llhttp"].status, "outdated")
        self.assertEqual(bundled["llhttp"].latest, "9.4.4")
        self.assertEqual(bundled["sqlite3"].status, "outdated")
        self.assertEqual(bundled["sqlite3"].latest, "3.54.1")
        self.assertEqual(bundled["libbacktrace"].status, "up-to-date")
        self.assertEqual(bundled["lpeglabel"].status, "up-to-date")
        self.assertEqual(bundled["uwasi"].status, "up-to-date")
        self.assertEqual(bundled["openssl"].status, "outdated")
        self.assertEqual(bundled["openssl"].latest, "4.1.0")

        self.assertEqual(rockspec["luv"].status, "outdated")
        self.assertEqual(rockspec["luv"].latest, "1.53.0-1")
        self.assertEqual(rockspec["argparse"].status, "up-to-date")
        self.assertEqual(rockspec["busted"].status, "tracked")
        self.assertEqual(rockspec["busted"].latest, "2.3.0-1")

        md = MOD.render_markdown(pins, list(bundled.values()), list(rockspec.values()), [], for_issue=True)
        self.assertIn(MOD.ISSUE_MARKER, md)
        self.assertIn("openssl", md)
        self.assertIn("4.1.0", md)
        self.assertIn("luv", md)

    def test_cli_offline_json_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out.json"
            rc = MOD.main(["--root", str(REPO_ROOT), "--offline", "--format", "json", "--output", str(out)])
            self.assertEqual(rc, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["parity_errors"], [])
            self.assertEqual(data["lookup_errors"], [])
            self.assertEqual(len(data["bundled"]), 7)

    def test_libbacktrace_behind_master_and_lookup_error_exit_code(self):
        pins, _ = MOD.load_repo_pins(REPO_ROOT)
        cur_sha = pins["bundled"]["libbacktrace"]["commit"]
        new_sha = "f" * 40
        fetcher = FakeFetcher(
            {
                "/repos/libuv/libuv/releases?per_page=100&page=1": RuntimeError("rate limited"),
                "/repos/nodejs/llhttp/git/matching-refs/tags/release/v": [
                    {"ref": f"refs/tags/release/v{pins['bundled']['llhttp']['version']}"},
                ],
                "/repos/sqlite/sqlite/git/matching-refs/tags/version-": [
                    {"ref": f"refs/tags/version-{pins['bundled']['sqlite3']['version']}"},
                ],
                "/repos/ianlancetaylor/libbacktrace/commits/master": {
                    "sha": new_sha,
                    "commit": {"committer": {"date": "2026-11-20T00:00:00Z"}},
                },
                f"/repos/ianlancetaylor/libbacktrace/compare/{cur_sha}...{new_sha}": {"ahead_by": 4},
                "/repos/sqmedeiros/lpeglabel/tags?per_page=100": [
                    {"name": f"v{pins['bundled']['lpeglabel']['version']}"},
                ],
                "/repos/swiftwasm/uwasi/releases?per_page=100&page=1": [
                    {"tag_name": pins["bundled"]["uwasi"]["version"], "draft": False, "prerelease": False, "html_url": "https://example.test/uwasi"},
                ],
                "/repos/openssl/openssl/releases?per_page=100&page=1": [
                    {"tag_name": "openssl-4.1.0", "draft": False, "prerelease": False, "html_url": "https://example.test/o"},
                ],
            },
            manifest_text=SAMPLE_MANIFEST,
        )
        bundled = {item.name: item for item in MOD.check_bundled_dependencies(pins, fetcher)}
        self.assertEqual(bundled["libuv"].status, "error")
        self.assertIn("rate limited", bundled["libuv"].error)
        self.assertEqual(bundled["libbacktrace"].status, "outdated")
        self.assertIn("4 commit(s) behind master", bundled["libbacktrace"].notes)
        self.assertIn(f"{cur_sha[:12]}...{new_sha[:12]}", bundled["libbacktrace"].url)


if __name__ == "__main__":
    unittest.main()
