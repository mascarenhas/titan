import copy
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

from check_reports import HERE, ReportError, check_reports, load_manifest, read_json


class ReportCheckerTests(unittest.TestCase):
    def setUp(self):
        artifacts = HERE / ".artifacts" / "checker-tests"
        artifacts.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=artifacts)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.agent = "titan-client-test"
        self.manifest = {"selected_cases": ["1.1.1", "7.1.6", "7.5.1"]}
        self.index = {self.agent: {}}
        self.details = {}
        for case in self.manifest["selected_cases"]:
            entry = {"behavior": "OK", "behaviorClose": "OK", "duration": 3,
                     "remoteCloseCode": 1000, "reportfile": "case_" + case.replace('.', '_') + ".json"}
            self.index[self.agent][case] = entry
            self.details[case] = dict(entry, id=case, agent=self.agent, isServer=True,
                                      wirelog=[], wasOpenHandshakeTimeout=False)
        self.write()

    def write(self):
        (self.root / "index.json").write_text(json.dumps(self.index))
        (self.root / "index.html").write_text("<html>index</html>")
        for case, detail in self.details.items():
            filename = self.index[self.agent][case]["reportfile"]
            (self.root / filename).write_text(json.dumps(detail))
            (self.root / filename).with_suffix(".html").write_text("<html>wire log</html>")

    def check(self):
        return check_reports(self.root, self.agent, "client", self.manifest)

    def test_valid_client_and_server_roles(self):
        self.assertEqual(self.check()["selected"], 3)
        for detail in self.details.values():
            detail["isServer"] = False
        self.write()
        self.assertTrue(check_reports(self.root, self.agent, "server", self.manifest)["passed"])

    def test_audited_information_is_recorded(self):
        self.index[self.agent]["7.1.6"]["behavior"] = "INFORMATIONAL"
        self.details["7.1.6"]["behavior"] = "INFORMATIONAL"
        self.write()
        self.assertEqual(self.check()["informational"], ["7.1.6"])

    def test_reject_each_bad_state_in_either_behavior_field(self):
        for field in ("behavior", "behaviorClose"):
            for state in ("FAILED", "FAIL", "NON-STRICT", "UNCLEAN", "WRONG CODE",
                          "FAILED BY CLIENT", "UNIMPLEMENTED", "MISSING", "SKIPPED",
                          "NO_CLOSE", "UNKNOWN", "INFORMATIONAL", "", None, False):
                with self.subTest(field=field, state=state):
                    self.index[self.agent]["1.1.1"][field] = state
                    self.details["1.1.1"][field] = state
                    self.write()
                    with self.assertRaises(ReportError):
                        self.check()
            self.index[self.agent]["1.1.1"][field] = "OK"
            self.details["1.1.1"][field] = "OK"

    def test_missing_or_malformed_index(self):
        for content in (None, "", "{", "null", "[]", "{}"):
            with self.subTest(content=content):
                path = self.root / "index.json"
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(content)
                with self.assertRaises(ReportError):
                    self.check()

    def test_wrong_extra_or_duplicate_agents(self):
        for content in ({"wrong-agent": self.index[self.agent]},
                        dict(self.index, unrelated={})):
            (self.root / "index.json").write_text(json.dumps(content))
            with self.assertRaises(ReportError):
                self.check()
        (self.root / "index.json").write_text('{"a":{},"a":{}}')
        with self.assertRaisesRegex(ReportError, "duplicate JSON key"):
            self.check()

    def test_exact_nonempty_coverage(self):
        for remove in (True, False):
            changed = copy.deepcopy(self.index)
            if remove:
                del changed[self.agent]["7.5.1"]
            else:
                changed[self.agent]["12.1.1"] = changed[self.agent]["1.1.1"]
            (self.root / "index.json").write_text(json.dumps(changed))
            with self.assertRaisesRegex(ReportError, "coverage mismatch"):
                self.check()
        with self.assertRaisesRegex(ReportError, "empty selected"):
            check_reports(self.root, self.agent, "client", {"selected_cases": []})

    def test_missing_behavior_close_even_when_message_behavior_is_ok(self):
        del self.index[self.agent]["1.1.1"]["behaviorClose"]
        self.write()
        with self.assertRaisesRegex(ReportError, "missing behaviorClose"):
            self.check()

    def test_cli_missing_report_returns_failure(self):
        result = subprocess.run([sys.executable, str(HERE / "check_reports.py"),
                                 str(self.root / "missing"), "--agent", self.agent, "--role", "client"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("conformance FAILED", result.stderr)

    def test_cli_complete_301_case_report_then_one_close_failure(self):
        self.manifest = load_manifest()
        self.index = {self.agent: {}}
        self.details = {}
        for case in self.manifest["selected_cases"]:
            entry = {"behavior": "OK", "behaviorClose": "OK", "duration": 3,
                     "remoteCloseCode": 1000, "reportfile": "case_" + case.replace('.', '_') + ".json"}
            self.index[self.agent][case] = entry
            self.details[case] = dict(entry, id=case, agent=self.agent, isServer=True,
                                     wirelog=[], wasOpenHandshakeTimeout=False)
        self.write()
        argv = [sys.executable, str(HERE / "check_reports.py"), str(self.root),
                "--agent", self.agent, "--role", "client"]
        passed = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertEqual(json.loads(passed.stdout)["selected"], 301)
        self.index[self.agent]["7.7.8"]["behaviorClose"] = "WRONG CODE"
        self.details["7.7.8"]["behaviorClose"] = "WRONG CODE"
        self.write()
        failed = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("7.7.8 behaviorClose rejected", failed.stderr)

    def test_index_detail_disagree(self):
        self.details["1.1.1"]["behaviorClose"] = "FAILED"
        self.write()
        with self.assertRaisesRegex(ReportError, "disagree"):
            self.check()

    def test_missing_malformed_or_empty_detail(self):
        path = self.root / self.index[self.agent]["1.1.1"]["reportfile"]
        for content in (None, "", "null", "{"):
            with self.subTest(content=content):
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(content)
                with self.assertRaises(ReportError):
                    self.check()

    def test_detail_identity_and_role_are_required(self):
        for field, value in (("agent", "stale"), ("id", "9.1.1"),
                             ("isServer", False), ("isServer", 1)):
            with self.subTest(field=field):
                original = self.details["1.1.1"][field]
                self.details["1.1.1"][field] = value
                self.write()
                with self.assertRaises(ReportError):
                    self.check()
                self.details["1.1.1"][field] = original

    def test_unsafe_detail_path(self):
        for filename in ("../detail.json", "/detail.json", "sub/detail.json", "case.html", None):
            with self.subTest(filename=filename):
                self.index[self.agent]["1.1.1"]["reportfile"] = filename
                (self.root / "index.json").write_text(json.dumps(self.index))
                with self.assertRaises(ReportError):
                    self.check()

    def test_missing_html_and_wirelog(self):
        del self.details["1.1.1"]["wirelog"]
        self.write()
        with self.assertRaisesRegex(ReportError, "wire log"):
            self.check()
        self.details["1.1.1"]["wirelog"] = []
        self.write()
        (self.root / "case_1_1_1.html").unlink()
        with self.assertRaisesRegex(ReportError, "detail HTML"):
            self.check()
        self.write()
        (self.root / "index.html").write_text("")
        with self.assertRaisesRegex(ReportError, "HTML report index"):
            self.check()

    def test_invalid_duration(self):
        for duration in (-1, True, None, "5"):
            self.index[self.agent]["1.1.1"]["duration"] = duration
            self.details["1.1.1"]["duration"] = duration
            self.write()
            with self.assertRaises(ReportError):
                self.check()

    def test_boolean_numeric_fields_cannot_impersonate_numbers(self):
        self.index[self.agent]["1.1.1"]["duration"] = True
        self.details["1.1.1"]["duration"] = 1
        self.write()
        with self.assertRaises(ReportError):
            self.check()
        self.index[self.agent]["1.1.1"]["duration"] = 3
        self.details["1.1.1"]["duration"] = 3
        self.index[self.agent]["1.1.1"]["remoteCloseCode"] = True
        self.details["1.1.1"]["remoteCloseCode"] = True
        self.write()
        with self.assertRaises(ReportError):
            self.check()

    def test_duplicate_case_or_detail_fields(self):
        (self.root / "index.json").write_text('{"' + self.agent + '":{"1.1.1":{},"1.1.1":{}}}')
        with self.assertRaisesRegex(ReportError, "duplicate JSON key"):
            self.check()
        self.write()
        (self.root / "case_1_1_1.json").write_text('{"id":"1.1.1","id":"1.1.1"}')
        with self.assertRaisesRegex(ReportError, "duplicate JSON key"):
            self.check()

    def test_nonstandard_json_nan_is_rejected(self):
        (self.root / "index.json").write_text('{"test":NaN}')
        with self.assertRaises(ReportError):
            self.check()

    def test_missing_opening_status(self):
        self.details["1.1.1"]["wasOpenHandshakeTimeout"] = True
        self.write()
        with self.assertRaisesRegex(ReportError, "opening-handshake"):
            self.check()

    def test_pinned_manifest_is_exact(self):
        manifest = load_manifest()
        self.assertEqual(len(manifest["all_cases"]), 517)
        self.assertEqual(len(manifest["selected_cases"]), 301)
        self.assertEqual(len(manifest["excluded_cases"]), 216)
        for required in ("7.5.1", "7.7.8", "9.1.6", "10.1.1"):
            self.assertIn(required, manifest["selected_cases"])

    def test_manifest_cannot_weaken_selection_or_informational_policy(self):
        manifest = read_json(HERE / "expected.json")
        for field, replacement in (("selected_cases", []), ("selected_cases", manifest["selected_cases"][:-1]),
                                   ("excluded_cases", manifest["excluded_cases"] + ["7.5.1"]),
                                   ("all_cases", manifest["all_cases"][:-1]),
                                   ("informational_cases", ["1.1.1"]), ("source_revision", "wrong")):
            with self.subTest(field=field):
                changed = copy.deepcopy(manifest)
                changed[field] = replacement
                path = self.root / "manifest.json"
                path.write_text(json.dumps(changed))
                with self.assertRaises(ReportError):
                    load_manifest(path)


if __name__ == "__main__":
    unittest.main()
