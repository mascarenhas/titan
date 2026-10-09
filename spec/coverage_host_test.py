"""Host coverage contract tests; run with Python 3, GCC/gcov 14+ and gcovr 8.4.

No Titan SDK or source-adjacent native build is touched. The fixture deliberately
contains build-time counters, notes-only production code and a loaded provider.
"""

import copy
import base64
import struct
import hashlib
from html.parser import HTMLParser
import importlib.machinery
import importlib.util
import io
from types import SimpleNamespace
import json
import os
from pathlib import Path
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("titan_coverage_host", str(REPO / "titan-coverage"))
spec = importlib.util.spec_from_loader(loader.name, loader)
coverage = importlib.util.module_from_spec(spec)
loader.exec_module(coverage)
CC = os.environ.get("TITAN_COVERAGE_TEST_CC", "/usr/bin/gcc" if Path("/usr/bin/gcc").exists() else "gcc")
GCOV = os.environ.get("TITAN_COVERAGE_TEST_GCOV", "/usr/bin/gcov" if Path("/usr/bin/gcov").exists() else "gcov")
GCOVR = os.environ.get("TITAN_COVERAGE_TEST_GCOVR", "gcovr")


class ReportHeaders(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.current = ""
        self.headers = []

    def handle_starttag(self, tag, attrs):
        if tag in ("th", "caption", "summary"):
            self.active = True
            self.current = ""

    def handle_data(self, data):
        if self.active:
            self.current += data

    def handle_endtag(self, tag):
        if tag in ("th", "caption", "summary"):
            self.headers.append(self.current)
            self.active = False


class ReportSourceRows(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.cells = []
        self.rows = []

    def handle_starttag(self, tag, attrs):
        if tag == "tr" and "source-line" in dict(attrs).get("class", "").split():
            self.active = True
            self.cells = []
        if self.active and tag == "td":
            self.cells.append("")

    def handle_data(self, data):
        if self.active and self.cells:
            self.cells[-1] += data

    def handle_endtag(self, tag):
        if tag == "tr" and self.active:
            self.rows.append(tuple(cell.strip() if index < 2 else cell
                                   for index, cell in enumerate(self.cells)))
            self.active = False


class CoverageHostTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = coverage.probe_backend(CC, GCOV)
        cls.reporter = coverage.identify_reporter(GCOVR)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="titan-coverage-host-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = self.root / "src"
        self.sources.mkdir()
        first = self.sources / "first.titan"
        second = self.sources / "unreached.titan"
        first.write_text("function choose(x: boolean): integer\nif x then\n-- body\nreturn 4\nelse\nreturn 6\nend\nend\n", encoding="utf-8")
        second.write_text("function never(): integer\n-- uncalled\nreturn 9\nend\n", encoding="utf-8")
        c = self.root / "first.c"
        c.write_text("int choose(int x) {{\n#line 2 {}\nif(x) {{\n#line 4 {}\nreturn 4;\n"
                     "#line 2 {}\n}}\n#line 6 {}\nreturn 6;\n#line 1 {}\n}}\n".format(
                         coverage.c_filename(first), coverage.c_filename(first), coverage.c_filename(first),
                         coverage.c_filename(first), coverage.c_filename(c)), encoding="utf-8")
        never_c = self.root / "unreached.c"
        never_c.write_text("#line 3 {}\nint never(void) {{return 9;}}\n".format(coverage.c_filename(second)), encoding="utf-8")
        main_c = self.root / "main.c"
        main_c.write_text("#include <stdlib.h>\nint choose(int);\nint main(int argc,char **argv) {\n"
                          "if(argc>1 && argv[1][0]=='x') return 7;\n"
                          "return choose(argc>1 ? atoi(argv[1]):0)==4?0:0;\n}\n", encoding="utf-8")
        self.flags = ["-O0", "-fno-lto", "--coverage", "-fprofile-update=atomic"]
        for stem in ("first", "unreached"):
            coverage.invoke(coverage.command_argv(CC) + self.flags + ["-dumpbase", stem + ".c", "-dumpbase-ext", ".c",
                            "-c", str(self.root / (stem + ".c")), "-o", str(self.root / (stem + ".tmp.o"))])
            (self.root / (stem + ".tmp.o")).replace(self.root / (stem + ".o"))
        self.program = self.root / ("program.exe" if os.name == "nt" else "program")
        coverage.invoke(coverage.command_argv(CC) + ["-O0", "-c", str(main_c), "-o", str(self.root / "main.o")])
        coverage.invoke(coverage.command_argv(CC) + ["--coverage", str(self.root / "main.o"), str(self.root / "first.o"), "-o", str(self.program)])
        self.manifest_path = self.root / "build.json"
        self.manifest = {"version": 1, "backend": "gcc-gcov", "root": str(self.root),
                         "sources": [{"path": str(first), "report_path": "src/first.titan", "module": "first"},
                                     {"path": str(second), "report_path": "src/unreached.titan", "module": "unreached"}],
                         "objects": [{"path": str(self.root / (stem + ".o")),
                                      "notes": str(self.root / (stem + ".gcno")),
                                      "data": str(self.root / (stem + ".gcda")),
                                      "sources": ["src/" + stem + ".titan"], "expect_data": stem == "first"}
                                     for stem in ("first", "unreached")],
                         "providers": [{"path": str(self.program), "objects": [str(self.root / "first.o")]}],
                         "link_inventory": [{"path": str(self.root / "main.o"), "role": "unmeasured-test-entrypoint"}],
                         "settings": {"metric": "titan-executable-lines", "line_mapping": "titan-coverage-markers-v1"}}
        coverage.save_json(self.manifest_path, self.manifest)
        self.manifest = coverage.seal_manifest(self.manifest_path, CC, GCOV)

    def run_fixture(self, name, *arguments):
        path = self.root / name
        status = coverage.execute_run(self.manifest_path, path, [str(self.program)] + list(arguments))
        return path, status

    def report_fixture(self, runs, name="report", allow_incomplete=False):
        path = self.root / name
        status = coverage.report_runs(self.manifest_path, runs, path, GCOVR, allow_incomplete)
        return path, status

    def second_build(self, staged=False):
        directory = self.root / "second-image"
        directory.mkdir()
        manifest = copy.deepcopy(self.manifest)
        manifest.pop("manifest_id")
        c_text = (self.root / "first.c").read_text()
        if staged:
            staged_directory = self.root / "server-stage"
            staged_directory.mkdir()
            staged_source = staged_directory / "first.titan"
            shutil.copyfile(self.sources / "first.titan", staged_source)
            c_text = c_text.replace(coverage.c_filename(self.sources / "first.titan"), coverage.c_filename(staged_source))
            manifest["sources"][0]["path"] = str(staged_source)
        c = directory / "body.c"
        c.write_text(c_text)
        obj = directory / "production.o"
        coverage.invoke(coverage.command_argv(CC) + self.flags + ["-dumpbase", "production.c", "-dumpbase-ext", ".c",
                        "-c", str(c), "-o", str(obj)])
        program = directory / ("server.exe" if os.name == "nt" else "server")
        coverage.invoke(coverage.command_argv(CC) + ["--coverage", str(self.root / "main.o"), str(obj), "-o", str(program)])
        manifest["objects"][0].update({"path": str(obj), "notes": str(directory / "production.gcno"),
                                       "data": str(directory / "production.gcda")})
        manifest["objects"][0].pop("sha256")
        manifest["objects"][0].pop("notes_sha256")
        manifest["providers"] = [{"path": str(program), "objects": [str(obj)]}]
        manifest["settings"].update({"test": False, "source_tree": str(directory),
                                      "working_directory": str(directory), "pretty_print": True})
        path = directory / "build.json"
        coverage.save_json(path, manifest)
        return path, coverage.seal_manifest(path, CC, GCOV), program

    def test_real_backend_probe_verifies_mapping_notes_and_relocation(self):
        self.assertTrue(all(self.probe["checks"].values()))

    def test_notes_only_zero_lines_and_standard_source_reports(self):
        run, status = self.run_fixture("run", "0")
        self.assertEqual(status, 0)
        report, status = self.report_fixture([run])
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")
        by_file = {file["file"]: {line["line_number"]: line["count"] for line in file["lines"]} for file in lines["files"]}
        self.assertEqual(by_file["src/first.titan"], {2: 1, 4: 0, 6: 1})
        self.assertEqual(by_file["src/unreached.titan"], {3: 0})
        lcov = (report / "coverage.info").read_text()
        self.assertIn("SF:src/first.titan", lcov)
        self.assertIn("DA:4,0", lcov)
        self.assertIn("SF:src/unreached.titan", lcov)
        self.assertIn("src/first.titan", (report / "coverage.xml").read_text())
        self.assertIn("Titan executable-line coverage", (report / "coverage.html").read_text())
        headers = ReportHeaders()
        headers.feed((report / "coverage.html").read_text())
        self.assertIn("Line coverage", headers.headers)
        self.assertIn("Count", headers.headers)
        self.assertFalse(any("branch" in header.lower() or "function" in header.lower() for header in headers.headers))
        self.assertNotIn("FNF:", lcov)
        self.assertNotIn("BRF:", lcov)
        self.assertNotIn("condition-coverage", (report / "coverage.xml").read_text())
        self.assertNotIn('branch="true"', (report / "coverage.xml").read_text())
        self.assertEqual(coverage.read_json(report / "summary.json")["lines_total"], 4)

    def test_bare_cr_inside_long_string_rejects_seal_instead_of_shifting_lines(self):
        first = self.sources / "first.titan"
        # This is valid Titan, whose source locations count only LF. The CR
        # remains inside a long string but gcovr would display an extra row.
        first.write_bytes(b"function choose(x: boolean): integer\n"
                          b"local text = [[one\rtwo]]\n"
                          b"if x then return 4 else return 6 end\nend\n")
        manifest = copy.deepcopy(self.manifest)
        manifest.pop("manifest_id")
        manifest["sources"][0]["sha256"] = coverage.digest(first)
        coverage.save_json(self.manifest_path, manifest)
        with self.assertRaisesRegex(coverage.CoverageError, "LF or CRLF; bare carriage return"):
            coverage.seal_manifest(self.manifest_path, CC, GCOV)

    def test_seal_tracks_separate_unmeasured_consumer_inputs(self):
        helper = self.root / "consumer-fixture.txt"
        helper.write_text("first consumer input\n")
        manifest = coverage.seal_manifest(self.manifest_path, CC, GCOV,
            unmeasured_inputs=[str(helper), str(helper), str(self.root / "main.o")])
        inputs = manifest["link_inventory"]
        self.assertEqual(len(inputs), 2)
        retained = next(item for item in inputs if item["path"] == str(helper))
        self.assertEqual(retained["role"], "unmeasured-consumer-input")
        self.assertEqual(retained["sha256"], coverage.digest(helper))
        self.assertEqual(manifest["sources"], self.manifest["sources"])
        run, status = self.run_fixture("run-consumer-input", "1")
        self.assertEqual(status, 0)
        helper.write_text("changed consumer input\n")
        with self.assertRaisesRegex(coverage.CoverageError, "linked input changed"):
            self.report_fixture([run])
        with self.assertRaisesRegex(coverage.CoverageError, "linked input changed"):
            self.run_fixture("run-changed-consumer-input", "1")

    def test_crlf_and_literal_unicode_separators_keep_physical_line_indexes(self):
        first = self.sources / "first.titan"
        literal_line = 'local text = "raw\u2028\v\f\x85\u2029bytes"'
        source_lines = ["function choose(x: boolean): integer", "if x then",
                        literal_line, "return 4", "else", "return 6", "end", "end"]
        first.write_bytes(("\r\n".join(source_lines) + "\r\n").encode("utf-8"))
        self.assertEqual(coverage.physical_source_lines(first), source_lines)
        c = self.root / "first.c"
        marker = "#line 4 " + coverage.c_filename(first)
        c.write_text(c.read_text().replace(marker, "#line 3 " + coverage.c_filename(first) +
                                          "\nvolatile int literal_probe=1;\n" + marker, 1))
        coverage.invoke(coverage.command_argv(CC) + self.flags +
                        ["-dumpbase", "first.c", "-dumpbase-ext", ".c", "-c", str(c),
                         "-o", str(self.root / "first.tmp.o")])
        (self.root / "first.tmp.o").replace(self.root / "first.o")
        coverage.invoke(coverage.command_argv(CC) + ["--coverage", str(self.root / "main.o"),
                        str(self.root / "first.o"), "-o", str(self.program)])
        manifest = copy.deepcopy(self.manifest)
        manifest.pop("manifest_id")
        manifest["sources"][0]["sha256"] = coverage.digest(first)
        manifest["objects"][0]["sha256"] = coverage.digest(self.root / "first.o")
        manifest["objects"][0]["notes_sha256"] = coverage.digest(self.root / "first.gcno")
        manifest["providers"][0]["sha256"] = coverage.digest(self.program)
        coverage.save_json(self.manifest_path, manifest)
        self.manifest = coverage.seal_manifest(self.manifest_path, CC, GCOV)
        run, status = self.run_fixture("run-physical-lines", "1")
        self.assertEqual(status, 0)
        report, status = self.report_fixture([run])
        self.assertEqual(status, 0)
        file = next(file for file in coverage.read_json(report / "lines.json")["files"]
                    if file["file"] == "src/first.titan")
        lines = {line["line_number"]: line for line in file["lines"]}
        self.assertEqual({number: line["count"] for number, line in lines.items()},
                         {2: 1, 3: 1, 4: 1, 6: 0})
        for number in (3, 4, 6):
            checksum = hashlib.md5(source_lines[number - 1].encode("utf-8"),
                                   usedforsecurity=False).hexdigest()
            self.assertEqual(lines[number]["gcovr/md5"], checksum)
            self.assertIn(f"DA:{number},{lines[number]['count']},{checksum}",
                          (report / "coverage.info").read_text())
        rows = ReportSourceRows()
        rows.feed((report / "coverage.html").read_text())
        self.assertIn(("3", "1", literal_line), rows.rows)
        self.assertIn(("4", "1", "return 4"), rows.rows)
        self.assertIn(("6", "0", "return 6"), rows.rows)

    def test_build_activity_and_repeated_runs_do_not_accumulate(self):
        for _ in range(4):
            coverage.invoke([str(self.program), "1"])
        original = coverage.digest(self.root / "first.gcda")
        first, _ = self.run_fixture("run-first", "0")
        second, _ = self.run_fixture("run-second", "0")
        report, status = self.report_fixture([first, second])
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")["files"][0]["lines"]
        self.assertEqual({line["line_number"]: line["count"] for line in lines}, {2: 2, 4: 0, 6: 2})
        self.assertEqual(coverage.digest(self.root / "first.gcda"), original)

    def test_parallel_shards_have_separate_matching_counter_ownership(self):
        commands = [[sys.executable, str(REPO / "titan-coverage"), "run", "--manifest", str(self.manifest_path),
                     "--run", str(self.root / name), "--", str(self.program), argument]
                    for name, argument in (("one", "0"), ("two", "1"))]
        children = [subprocess.Popen(command) for command in commands]
        self.assertEqual([child.wait() for child in children], [0, 0])
        report, status = self.report_fixture([self.root / "one", self.root / "two"])
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")["files"][0]["lines"]
        self.assertEqual({line["line_number"]: line["count"] for line in lines}, {2: 2, 4: 1, 6: 1})

    def test_joined_child_process_counters_are_collected(self):
        child = "import subprocess,sys; sys.exit(subprocess.call(sys.argv[1:]))"
        run = self.root / "child-run"
        status = coverage.execute_run(self.manifest_path, run, [sys.executable, "-c", child, str(self.program), "1"])
        self.assertEqual(status, 0)
        if os.name != "nt":
            receipt = coverage.read_json(run / "run.json")
            self.assertEqual(receipt["leader_exit_status"], 0)
            self.assertTrue(receipt["process_group_empty_confirmed"])
            self.assertFalse(receipt["group_retirement_requested"])
        report, status = self.report_fixture([run])
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")["files"][0]["lines"]
        self.assertEqual({line["line_number"]: line["count"] for line in lines}, {2: 1, 4: 1, 6: 0})

    def test_failure_exit_is_preserved_even_with_successful_reports(self):
        run, status = self.run_fixture("failure", "x")
        self.assertEqual(status, 7)
        if os.name != "nt":
            receipt = coverage.read_json(run / "run.json")
            self.assertEqual(receipt["leader_exit_status"], 7)
            self.assertTrue(receipt["process_group_empty_confirmed"])
            self.assertFalse(receipt["group_retirement_requested"])
        report, status = self.report_fixture([run])
        self.assertEqual(status, 1)
        summary = coverage.read_json(report / "summary.json")
        self.assertTrue(summary["complete"])
        self.assertFalse(summary["tests_passed"])
        self.assertEqual(summary["runs"][0]["exit_status"], 7)

    @unittest.skipIf(os.name == "nt", "POSIX process-group ownership")
    def test_natural_leader_exit_retires_unjoined_child_before_counter_collection(self):
        for leader_status in (0, 23):
            with self.subTest(leader_status=leader_status):
                directory = self.root / ("held-child-" + str(leader_status))
                directory.mkdir()
                fifo, ready = directory / "output", directory / "ready.json"
                os.mkfifo(fifo)
                reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
                worker = (
                    "import json,os,signal,sys,time; from pathlib import Path; "
                    "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                    "output=open(sys.argv[1],'wb',buffering=0); "
                    "Path(sys.argv[2]).write_text(json.dumps({'group':os.getpgrp()})); "
                    "time.sleep(30)"
                )
                launcher = (
                    "import subprocess,sys,time; from pathlib import Path; "
                    "subprocess.run([sys.argv[1],'0'],check=True); "
                    "subprocess.Popen([sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4]]); "
                    "deadline=time.monotonic()+5\n"
                    "while not Path(sys.argv[4]).exists():\n"
                    " if time.monotonic()>=deadline: raise SystemExit(92)\n"
                    " time.sleep(0.01)\n"
                    "raise SystemExit(int(sys.argv[5]))"
                )
                try:
                    started = time.monotonic()
                    run = directory / "run"
                    status = coverage.execute_run(self.manifest_path, run,
                        [sys.executable, "-c", launcher, str(self.program), worker,
                         str(fifo), str(ready), str(leader_status)], timeout=10)
                    self.assertLess(time.monotonic() - started, 8)
                    self.assertEqual(status, 125)
                    self.assertTrue(ready.is_file(), "held descendant never became ready")
                    receipt = coverage.read_json(run / "run.json")
                    self.assertEqual(receipt["state"], "incomplete")
                    self.assertEqual(receipt["leader_exit_status"], leader_status)
                    self.assertEqual(receipt["exit_status"], 125)
                    self.assertTrue(receipt["group_retirement_requested"])
                    self.assertIn("owned process group remained after leader exit", receipt["reason"])
                    # EOF proves that the held descendant has released its
                    # descriptor. It works even if an orphan zombie remains.
                    deadline = time.monotonic() + 1
                    while True:
                        try:
                            self.assertEqual(os.read(reader, 1), b"")
                            break
                        except BlockingIOError:
                            if time.monotonic() >= deadline:
                                self.fail("unjoined descendant retained its output")
                            time.sleep(0.01)
                    if receipt["process_group_empty_confirmed"]:
                        report, status = self.report_fixture([run], name="held-report-" + str(leader_status))
                        self.assertEqual(status, 2)
                        summary = coverage.read_json(report / "summary.json")
                        self.assertFalse(summary["complete"])
                        self.assertFalse(summary["tests_passed"])
                    else:
                        # A remaining zombie still prevents proof of group
                        # emptiness; no counter hash or partial report is safe.
                        self.assertEqual(receipt["counters"], [])
                        self.assertIn("counter_collection_skipped", receipt)
                        with self.assertRaisesRegex(coverage.CoverageError, "process group was not confirmed empty"):
                            self.report_fixture([run], name="held-report-" + str(leader_status),
                                                allow_incomplete=True)
                finally:
                    os.close(reader)
                    if ready.is_file():
                        try:
                            os.killpg(json.loads(ready.read_text())["group"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    @unittest.skipIf(os.name == "nt", "POSIX process-group ownership")
    def test_run_readback_rejects_legacy_or_unconfirmed_process_ownership(self):
        run, status = self.run_fixture("owned-run", "0")
        self.assertEqual(status, 0)
        original = coverage.read_json(run / "run.json")
        self.assertEqual(original["version"], 2)
        for updates, diagnostic in (
                ({"version": 1}, "legacy"),
                ({"process_ownership": None}, "process group was not confirmed empty"),
                ({"process_group_id": True}, "process group was not confirmed empty"),
                ({"process_group_empty_confirmed": False}, "process group was not confirmed empty"),
                ({"group_retirement_requested": True}, "disagrees with its owned process group lifecycle")):
            with self.subTest(updates=updates):
                receipt = dict(original, **updates)
                coverage.save_json(run / "run.json", receipt)
                with self.assertRaisesRegex(coverage.CoverageError, diagnostic):
                    coverage.load_run(run, self.manifest)
        coverage.save_json(run / "run.json", original)
        coverage.load_run(run, self.manifest)

    def test_missing_expected_counters_are_incomplete(self):
        run = self.root / "missing"
        status = coverage.execute_run(self.manifest_path, run, [sys.executable, "-c", "pass"])
        self.assertEqual(status, 0)
        report, status = self.report_fixture([run])
        self.assertEqual(status, 2)
        self.assertFalse(coverage.read_json(report / "summary.json")["complete"])
        self.assertIn("INCOMPLETE", (report / "coverage.html").read_text())

    def test_timeout_records_incomplete_collection(self):
        run = self.root / "timeout"
        status = coverage.execute_run(self.manifest_path, run, [sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)
        self.assertEqual(status, 124)
        self.assertEqual(coverage.read_json(run / "run.json")["state"], "incomplete")

    @unittest.skipIf(os.name == "nt", "POSIX process-group cleanup")
    def test_timeout_kills_term_resistant_descendant_after_leader_exits(self):
        fifo = self.root / "descendant-output"
        ready = self.root / "descendant-ready.json"
        os.mkfifo(fifo)
        reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        self.addCleanup(os.close, reader)
        worker = (
            "import json,os,signal,sys,time; from pathlib import Path; "
            "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
            "output=open(sys.argv[1],'wb',buffering=0); "
            "Path(sys.argv[2]).write_text(json.dumps({'group':os.getpgrp()})); "
            "time.sleep(30)"
        )
        launcher = (
            "import subprocess,sys,time; "
            "subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2],sys.argv[3]]); "
            "time.sleep(30)"
        )
        try:
            run = self.root / "descendant-timeout"
            status = coverage.execute_run(self.manifest_path, run,
                [sys.executable, "-c", launcher, worker, str(fifo), str(ready)], timeout=1)
            self.assertEqual(status, 124)
            self.assertTrue(ready.is_file(), "descendant did not become ready before timeout")
            self.assertEqual(coverage.read_json(run / "run.json")["state"], "incomplete")
            # EOF proves the descendant closed its output, including when its
            # terminated leader has already been reaped. A zombie has no open
            # descriptor and does not make this check platform-dependent.
            deadline = time.monotonic() + 1
            while True:
                try:
                    self.assertEqual(os.read(reader, 1), b"")
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        self.fail("TERM-resistant descendant retained its output after leader exit")
                    time.sleep(0.01)
        finally:
            if ready.is_file():
                group = json.loads(ready.read_text())["group"]
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    @unittest.skipIf(os.name == "nt", "POSIX signal result convention")
    def test_crash_records_incomplete_collection(self):
        run = self.root / "crash"
        status = coverage.execute_run(self.manifest_path, run, [sys.executable, "-c", "import os,signal; os.kill(os.getpid(),signal.SIGKILL)"])
        self.assertEqual(status, 137)
        self.assertEqual(coverage.read_json(run / "run.json")["state"], "incomplete")

    @unittest.skipIf(os.name == "nt", "POSIX interrupt cleanup")
    def test_interrupt_wait_is_bounded_when_the_process_ignores_sigint(self):
        ready = self.root / "interrupt-ready"
        original_popen = subprocess.Popen
        worker = (
            "import signal,sys,time; from pathlib import Path; "
            "signal.signal(signal.SIGINT,signal.SIG_IGN); "
            "Path(sys.argv[1]).write_text('ready'); time.sleep(30)"
        )
        def interrupt_first_wait(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            if list(args[0])[:3] != [sys.executable, "-c", worker]:
                return child
            self.addCleanup(lambda: child.poll() is None and child.kill())
            deadline = time.monotonic() + 3
            while not ready.exists():
                self.assertIsNone(child.poll(), "interrupt fixture exited before readiness")
                self.assertLess(time.monotonic(), deadline, "interrupt fixture did not become ready")
                time.sleep(0.01)
            original_wait = child.wait
            calls = 0
            def wait(*wait_args, **wait_kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise KeyboardInterrupt
                return original_wait(*wait_args, **wait_kwargs)
            child.wait = wait
            return child
        run = self.root / "interrupted"
        started = time.monotonic()
        with mock.patch.object(coverage.subprocess, "Popen", side_effect=interrupt_first_wait):
            status = coverage.execute_run(self.manifest_path, run,
                [sys.executable, "-c", worker, str(ready)])
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(status, 130)
        receipt = coverage.read_json(run / "run.json")
        self.assertEqual(receipt["state"], "incomplete")
        self.assertTrue(receipt["leader_reaped"])

    def test_duplicate_runs_cannot_be_double_counted(self):
        run, _ = self.run_fixture("run", "0")
        with self.assertRaisesRegex(coverage.CoverageError, "supplied twice"):
            self.report_fixture([run, run])

    def test_changed_counters_reject_late_children_and_stale_data(self):
        run, _ = self.run_fixture("run", "0")
        receipt = coverage.read_json(run / "run.json")
        path = Path(receipt["counters"][0]["path"])
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(coverage.CoverageError, "counters changed"):
            self.report_fixture([run])

    def test_changed_sources_or_provider_cannot_be_merged(self):
        run, _ = self.run_fixture("run", "0")
        first = self.sources / "first.titan"
        first.write_text(first.read_text() + "-- changed\n")
        with self.assertRaisesRegex(coverage.CoverageError, "source changed"):
            self.report_fixture([run])

    def test_missing_notes_are_an_error_not_empty_success(self):
        (self.root / "unreached.gcno").unlink()
        with self.assertRaisesRegex(coverage.CoverageError, "cannot read"):
            self.run_fixture("run", "0")

    def test_seal_cannot_relabel_stale_objects_with_changed_source_bytes(self):
        first = self.sources / "first.titan"
        first.write_text(first.read_text() + "-- changed after compilation\n")
        with self.assertRaisesRegex(coverage.CoverageError, "source changed"):
            coverage.seal_manifest(self.manifest_path, CC, GCOV)

    def test_uninstrumented_link_input_changes_are_provenance_failures(self):
        run, _ = self.run_fixture("run", "0")
        main_object = self.root / "main.o"
        main_object.write_bytes(main_object.read_bytes() + b"different-helper")
        with self.assertRaisesRegex(coverage.CoverageError, "linked input changed"):
            self.report_fixture([run])

    def test_unknown_inventory_sources_are_not_silently_filtered(self):
        run, _ = self.run_fixture("run", "0")
        raw = {"format_version": "2", "current_working_directory": str(self.root),
               "files": [{"file": str(self.root / "unknown.titan"), "lines": []}]}
        with self.assertRaisesRegex(coverage.CoverageError, "outside the declared inventory"):
            coverage.normalized_trace(self.manifest, [(self.manifest["objects"][0], raw)])

    def test_staged_mapping_requires_matching_original_source_bytes(self):
        staged = self.root / "stage"
        staged.mkdir()
        shutil.copyfile(self.sources / "first.titan", staged / "first.titan")
        manifest = copy.deepcopy(self.manifest)
        manifest["sources"][0]["path"] = str(staged / "first.titan")
        coverage.validate_inventory(manifest, check_hashes=True)
        (staged / "first.titan").write_text("stale stage\n")
        with self.assertRaisesRegex(coverage.CoverageError, "staged and tracked"):
            coverage.validate_inventory(manifest)

    def test_gcov_stamp_mismatch_is_not_silently_treated_as_zero(self):
        run, _ = self.run_fixture("run", "0")
        data = coverage.read_json(run / "run.json")["counters"][0]["path"]
        with self.assertRaisesRegex(coverage.CoverageError, "exited|diagnostics"):
            coverage.gcov_json(coverage.command_argv(GCOV), self.root / "unreached.gcno", self.root / "mismatch", data)

    def test_fresh_run_directory_is_required(self):
        run, _ = self.run_fixture("run", "0")
        with self.assertRaisesRegex(coverage.CoverageError, "already exists"):
            self.run_fixture("run", "1")

    def test_reporter_pin_is_enforced(self):
        with self.assertRaisesRegex(coverage.CoverageError, "pinned gcovr"):
            coverage.identify_reporter([sys.executable, "-c", "print('gcovr 8.3')"])

    def test_concurrent_joined_children_share_locked_counter_updates(self):
        child = ("import subprocess,sys; children=[subprocess.Popen([sys.argv[1],str(i%2)]) for i in range(8)]; "
                 "sys.exit(max(child.wait() for child in children))")
        run = self.root / "joined-parallel-children"
        status = coverage.execute_run(self.manifest_path, run, [sys.executable, "-c", child, str(self.program)])
        self.assertEqual(status, 0)
        report, status = self.report_fixture([run])
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")["files"][0]["lines"]
        self.assertEqual({line["line_number"]: line["count"] for line in lines}, {2: 8, 4: 4, 6: 4})

    def test_native_test_and_staged_server_images_merge_matching_source_provenance(self):
        second_path, second_manifest, second_program = self.second_build(staged=True)
        first_run, _ = self.run_fixture("native-tests", "0")
        second_run = self.root / "server-run"
        self.assertEqual(coverage.execute_run(second_path, second_run, [str(second_program), "1"]), 0)
        report = self.root / "combined-report"
        status = coverage.report_runs([self.manifest_path, second_path], [first_run, second_run], report, GCOVR)
        self.assertEqual(status, 0)
        lines = coverage.read_json(report / "lines.json")["files"][0]["lines"]
        self.assertEqual({line["line_number"]: line["count"] for line in lines}, {2: 2, 4: 1, 6: 1})
        summary = coverage.read_json(report / "summary.json")
        self.assertEqual(summary["manifest_ids"], [self.manifest["manifest_id"], second_manifest["manifest_id"]])
        self.assertTrue((report / "build-0.json").is_file())
        self.assertTrue((report / "build-1.json").is_file())
        self.assertNotIn("server-stage", (report / "coverage.info").read_text())

    def test_source_tool_platform_and_compilation_divergence_cannot_be_merged(self):
        variants = []
        source = copy.deepcopy(self.manifest)
        source["sources"][0]["sha256"] = "different-revision"
        variants.append(source)
        compiler = copy.deepcopy(self.manifest)
        compiler["tools"]["cc"]["sha256"] = "different-compiler"
        variants.append(compiler)
        target = copy.deepcopy(self.manifest)
        target["platform"]["machine"] = "different-architecture"
        variants.append(target)
        settings = copy.deepcopy(self.manifest)
        settings["settings"]["compile_prefix"] = ["-O3"]
        variants.append(settings)
        for variant in variants:
            with self.subTest(variant=coverage.compatible_manifest_identity(variant)):
                with mock.patch.object(coverage, "load_manifest", side_effect=[self.manifest, variant]):
                    with self.assertRaisesRegex(coverage.CoverageError, "incompatible"):
                        coverage.report_runs(["first-build", "second-build"], [], self.root / "invalid-report", GCOVR)

    def test_duplicate_run_is_rejected_across_compatible_manifest_set(self):
        second_path, _, _ = self.second_build()
        first_run, _ = self.run_fixture("run", "0")
        with self.assertRaisesRegex(coverage.CoverageError, "supplied twice"):
            coverage.report_runs([self.manifest_path, second_path], [first_run, first_run], self.root / "invalid-report", GCOVR)

    def test_run_from_unsupplied_build_cannot_be_assumed_compatible(self):
        second_path, _, second_program = self.second_build()
        run = self.root / "second-run"
        coverage.execute_run(second_path, run, [str(second_program), "0"])
        with self.assertRaisesRegex(coverage.CoverageError, "any supplied"):
            self.report_fixture([run])


# Retained LLVM22.1.8/Windows B11 DLL pair from the independently executed
# synthetic4-process/16-thread matrix. No PE execution is needed to test the
# exact raw contract. Sources are identity-only virtual C/Titan filenames.
LLVM_NOTES = base64.b64decode('b25jZyoxMUJd46T9AQAAAC4AAAAAAAAAAAAAASUAAAAAAAAAdAFjvV3jpP0EAAAAZGxsX21lYXN1cmVkAAAAAAAAAAAXAAAAQzovVXNlcnMvdGl0YW4tZGV2L3RpdGFuLTIxMC13aW5kb3dzLWNhcGFiaWxpdHktcjItNmM1MzkwMGYvc3ludGhldGljL2NvbmN1cnJlbnRfZGxsLnRpdGFuAADIAAAAAAAAAMoAAAAAAAAAAABBAQEAAAAGAAAAAABDAQMAAAAAAAAAAgAAAAEAAAAAAEMBBQAAAAIAAAADAAAAAAAAAAQAAAABAAAAAABDAQMAAAADAAAABQAAAAEAAAAAAEMBAwAAAAQAAAAFAAAAAAAAAAAAQwEDAAAABQAAAAEAAAABAAAAAABFAR4AAAACAAAAAAAAABcAAABDOi9Vc2Vycy90aXRhbi1kZXYvdGl0YW4tMjEwLXdpbmRvd3MtY2FwYWJpbGl0eS1yMi02YzUzOTAwZi9zeW50aGV0aWMvY29uY3VycmVudF9kbGwudGl0YW4AAMgAAADKAAAAAAAAAAAAAAAAAEUBHQAAAAMAAAAAAAAAFwAAAEM6L1VzZXJzL3RpdGFuLWRldi90aXRhbi0yMTAtd2luZG93cy1jYXBhYmlsaXR5LXIyLTZjNTM5MDBmL3N5bnRoZXRpYy9jb25jdXJyZW50X2RsbC50aXRhbgAAzAAAAAAAAAAAAAAAAABFAR0AAAAEAAAAAAAAABcAAABDOi9Vc2Vycy90aXRhbi1kZXYvdGl0YW4tMjEwLXdpbmRvd3MtY2FwYWJpbGl0eS1yMi02YzUzOTAwZi9zeW50aGV0aWMvY29uY3VycmVudF9kbGwudGl0YW4AAM8AAAAAAAAAAAAAAAAARQEdAAAABQAAAAAAAAAXAAAAQzovVXNlcnMvdGl0YW4tZGV2L3RpdGFuLTIxMC13aW5kb3dzLWNhcGFiaWxpdHktcjItNmM1MzkwMGYvc3ludGhldGljL2NvbmN1cnJlbnRfZGxsLnRpdGFuAADQAAAAAAAAAAAAAAAAAAAAAAAAAA==')
LLVM_DATA = base64.b64decode('YWRjZyoxMUJd46T9AAAAAQMAAAAAAAAAdAFjvV3jpP0AAKEBBAAAABAIAAAAAAAAAAgAAAAAAAAAAAChAgAAAAQAAAAAAAAAAAAAAAAAAAA=')
LLVM_INTERMEDIATE = b'file:C:/Users/titan-dev/titan-210-windows-capability-r2-6c53900f/synthetic/concurrent_dll.titan\r\nfunction:200,4112,dll_measured\r\nlcount:200,4112\r\nlcount:202,4112\r\nlcount:204,2064\r\nlcount:207,2048\r\nlcount:208,4112\r\n'


class LLVMReaderContractTest(unittest.TestCase):
    def setUp(self):
        self.notes = coverage.llvm_reader_parse_notes(LLVM_NOTES)

    def changed(self, raw, offset, value):
        return raw[:offset] + value + raw[offset + len(value):]

    def test_exact_retained_counts_and_full_notes_only_zero_inventory(self):
        coverage.llvm_reader_validate_data(LLVM_DATA, self.notes)
        value = coverage.llvm_reader_parse_intermediate(LLVM_INTERMEDIATE, self.notes)
        actual = {line['line_number']: line['count'] for line in value['files'][0]['lines']}
        self.assertEqual([actual[n] for n in (202, 204, 207)], [4112, 2064, 2048])
        zero = LLVM_INTERMEDIATE.replace(b',4112', b',0').replace(b',2064', b',0').replace(b',2048', b',0')
        result = coverage.llvm_reader_parse_intermediate(zero, self.notes, notes_only=True)
        self.assertEqual([(x['line_number'], x['count']) for x in result['files'][0]['lines']], [(n, 0) for n in sorted(actual)])
        with self.assertRaises(coverage.CoverageError):
            coverage.llvm_reader_parse_intermediate(LLVM_INTERMEDIATE, self.notes, notes_only=True)

    def test_native_tolerated_version_variants_reject_before_reader(self):
        for version in (b'*21B', b'ZZZZ', b'*704', b'B11*'):
            with self.subTest(version=version), self.assertRaises(coverage.CoverageError):
                coverage.llvm_reader_validate_data(self.changed(LLVM_DATA, 4, version), self.notes)
            with self.subTest(notes=version), self.assertRaises(coverage.CoverageError):
                coverage.llvm_reader_parse_notes(self.changed(LLVM_NOTES, 4, version))

    def test_native_pair_stamp_function_id_both_checksums_and_arity_reject(self):
        for offset in (8, 20, 24, 28, 36):
            with self.subTest(offset=offset), self.assertRaises(coverage.CoverageError):
                coverage.llvm_reader_validate_data(self.changed(LLVM_DATA, offset, bytes([LLVM_DATA[offset] ^ 1])), self.notes)

    def test_truncated_or_unknown_binary_records_never_become_zeros(self):
        for raw in (LLVM_DATA[:11], LLVM_DATA[:40], LLVM_DATA[:-8], LLVM_DATA + b'\0' * 4):
            with self.subTest(length=len(raw)), self.assertRaises(coverage.CoverageError):
                coverage.llvm_reader_validate_data(raw, self.notes)
        for raw in (LLVM_NOTES[:11], LLVM_NOTES[:-4], self.changed(LLVM_NOTES, 24, struct.pack('<I', 0x02000000))):
            with self.assertRaises(coverage.CoverageError): coverage.llvm_reader_parse_notes(raw)

    def test_intermediate_unknown_missing_duplicate_or_invalid_rows_reject(self):
        variants = [LLVM_INTERMEDIATE + b'branch:202,taken\r\n',
            LLVM_INTERMEDIATE + b'lcount:202,0\r\n',
            LLVM_INTERMEDIATE.replace(b'lcount:202,4112\r\n', b''),
            LLVM_INTERMEDIATE.replace(b'function:200,4112,dll_measured\r\n', b''),
            LLVM_INTERMEDIATE.replace(b'dll_measured', b'wrong_function'),
            LLVM_INTERMEDIATE.replace(b'concurrent_dll.titan', b'unknown.titan'),
            LLVM_INTERMEDIATE.replace(b'202,4112', b'202,-1'),
            LLVM_INTERMEDIATE.replace(b'202,4112', b'202,01'),
            LLVM_INTERMEDIATE.replace(b'202,4112', b'202,18446744073709551616'),
            LLVM_INTERMEDIATE.replace(b'202,4112', b'4294967296,4112'),
            LLVM_INTERMEDIATE.replace(b'\r\n', b'\r'), LLVM_INTERMEDIATE.rstrip(b'\r\n')]
        for index, raw in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(coverage.CoverageError):
                coverage.llvm_reader_parse_intermediate(raw, self.notes)

    def test_precheck_precedes_tool_and_reader_uses_explicit_fresh_pair_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); notes = root / 'notes'; data = root / 'data'
            notes.write_bytes(LLVM_NOTES); data.write_bytes(self.changed(LLVM_DATA, 4, b'ZZZZ'))
            with mock.patch.object(coverage.subprocess, 'run') as tool, self.assertRaises(coverage.CoverageError):
                coverage.llvm_gcov_raw(['/explicit/llvm-cov', 'gcov'], notes, root / 'bad', data)
            tool.assert_not_called()
            data.write_bytes(LLVM_DATA)
            def reader(argv, **kw):
                work = Path(kw['cwd'])
                self.assertEqual(argv, ['/explicit/llvm-cov', 'gcov', '--intermediate-format', str(work / 'object.gcno')])
                self.assertEqual(kw['timeout'], 30)
                self.assertEqual((work / 'object.gcno').read_bytes(), LLVM_NOTES)
                self.assertEqual((work / 'object.gcda').read_bytes(), LLVM_DATA)
                (work / 'object.gcno.gcov').write_bytes(LLVM_INTERMEDIATE)
                return subprocess.CompletedProcess(argv, 0, b'summary\n', b'')
            with mock.patch.object(coverage.subprocess, 'run', side_effect=reader):
                value = coverage.llvm_gcov_raw(['/explicit/llvm-cov', 'gcov'], notes, root / 'good', data)
            self.assertEqual(value['files'][0]['lines'][1]['count'], 4112)
            self.assertEqual(coverage.read_json(root / 'good/gcov-command.json')['exit_status'], 0)

    def test_reader_zero_exit_stderr_timeout_mutation_and_extra_output_are_fatal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); notes = root / 'notes'; data = root / 'data'
            notes.write_bytes(LLVM_NOTES); data.write_bytes(LLVM_DATA)
            for index, mode in enumerate(('stderr', 'timeout', 'mutation', 'extra')):
                def reader(argv, **kw):
                    if mode == 'timeout': raise subprocess.TimeoutExpired(argv, 30, b'partial', b'error')
                    work = Path(kw['cwd']); (work / 'object.gcno.gcov').write_bytes(LLVM_INTERMEDIATE)
                    if mode == 'mutation': (work / 'object.gcda').write_bytes(b'changed')
                    if mode == 'extra': (work / 'unexpected.gcov').write_bytes(b'')
                    return subprocess.CompletedProcess(argv, 0, b'', b'error' if mode == 'stderr' else b'')
                with self.subTest(mode=mode), mock.patch.object(coverage.subprocess, 'run', side_effect=reader), self.assertRaises(coverage.CoverageError):
                    coverage.llvm_gcov_raw(['/explicit/llvm-cov', 'gcov'], notes, root / str(index), data)


    def test_line_remap_function_endpoints_are_independent_of_per_source_line_inventory(self):
        words=coverage.llvm_reader_Words(LLVM_NOTES,'test');words.pos=12
        words.string('cwd');words.word()
        for tag,body in coverage.llvm_reader_records(words):
            if tag != coverage.llvm_reader_FUNCTION:continue
            body.word();body.word();body.word();body.string('name');body.word();body.string('file')
            endpoint_offset=words.pos-len(body.data)+body.pos
            first=struct.unpack_from('<I',LLVM_NOTES,endpoint_offset)[0]
            changed=self.changed(LLVM_NOTES,endpoint_offset+8,struct.pack('<I',1))
            notes=coverage.llvm_reader_parse_notes(changed)
            self.assertTrue(any(f['first']==first and f['last']==1 for f in notes['functions'].values()))
            self.assertEqual(coverage.llvm_reader_parse_intermediate(LLVM_INTERMEDIATE,notes),
                             coverage.llvm_reader_parse_intermediate(LLVM_INTERMEDIATE,self.notes))
            for offset in (endpoint_offset,endpoint_offset+8):
                with self.assertRaises(coverage.CoverageError):
                    coverage.llvm_reader_parse_notes(self.changed(LLVM_NOTES,offset,struct.pack('<I',0)))
            return
        self.fail('fixture missing real function record')


class TemplateByteIdentityContractTest(unittest.TestCase):
    def test_written_templates_match_utf8_hashes_with_windows_text_newlines(self):
        with tempfile.TemporaryDirectory(prefix='titan-template-bytes-') as temporary:
            directory = Path(temporary) / 'html-templates'
            write_text = Path.write_text

            def windows_text_write(path, contents, *args, **kwargs):
                # Exercise the Windows default-text boundary on every host.
                if path.parent == directory and kwargs.get('newline') is None:
                    return path.write_bytes(contents.replace('\n', '\r\n').encode('utf-8'))
                return write_text(path, contents, *args, **kwargs)

            with mock.patch.object(Path, 'write_text', windows_text_write):
                identities = coverage.write_html_templates(directory)
            self.assertEqual(set(identities), set(coverage.HTML_TEMPLATES))
            self.assertEqual({p.name for p in directory.iterdir()}, set(identities))
            for name, contents in coverage.HTML_TEMPLATES.items():
                raw = (directory / name).read_bytes()
                self.assertEqual(raw, contents.encode('utf-8'))
                self.assertEqual(hashlib.sha256(raw).hexdigest(), identities[name])
            with self.assertRaises(FileExistsError):
                coverage.write_html_templates(directory)
            self.assertEqual({p.name: coverage.digest(p) for p in directory.iterdir()}, identities)


class LLVMSourceMappingContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='titan-llvm-source-mapping-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source_root = self.root / 'sealed source'
        self.source = self.source_root / 'titan' / 'async.titan'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('first\nsecond\nthird\n', encoding='utf-8')
        self.report_cwd = self.root / 'report working directory'
        self.report_cwd.mkdir()
        self.manifest = dict(backend='llvm-gcov', root=str(self.source_root), sources=[
            dict(path=str(self.source), tracked_path=str(self.source), report_path='titan/async.titan')])
        self.obj = dict(sources=['titan/async.titan'])

    def trace(self, filename, cwd='.', manifest=None, obj=None):
        # Actual LLVM22 Windows notes use cwd='.' and authored relative names.
        raw = dict(current_working_directory=cwd, files=[dict(file=filename, lines=[
            dict(line_number=2, count=3), dict(line_number=3, count=0)])])
        old_cwd = Path.cwd()
        try:
            os.chdir(self.report_cwd)
            return coverage.normalized_trace(manifest or self.manifest, [(obj or self.obj, raw)])
        finally:
            os.chdir(old_cwd)

    def test_relative_llvm_authored_sources_use_sealed_root_from_another_report_cwd(self):
        result = self.trace('titan/async.titan')
        self.assertEqual(result['files'][0]['file'], 'titan/async.titan')
        self.assertEqual([(line['line_number'], line['count']) for line in result['files'][0]['lines']],
                         [(2, 3), (3, 0)])
        self.assertEqual(self.trace(str(self.source)), result)

    def test_llvm_unknown_sources_and_wrong_object_owner_remain_errors(self):
        with self.assertRaisesRegex(coverage.CoverageError, 'outside the declared inventory'):
            self.trace('titan/unknown.titan')
        with self.assertRaisesRegex(coverage.CoverageError, 'contributor inventory'):
            self.trace('titan/async.titan', obj=dict(sources=['titan/other.titan']))

    def test_llvm_unsafe_authored_paths_cannot_alias_a_declared_source(self):
        for filename in ('titan/../titan/async.titan', '../sealed source/titan/async.titan',
                         'C:titan/async.titan', r'\titan\async.titan'):
            with self.subTest(filename=filename), self.assertRaises(coverage.CoverageError):
                self.trace(filename)

    def test_llvm_relative_mapping_requires_matching_physical_source_inventory(self):
        other = self.root / 'elsewhere.titan'
        other.write_bytes(self.source.read_bytes())
        changed = copy.deepcopy(self.manifest)
        changed['sources'][0]['path'] = str(other)
        with self.assertRaises(coverage.CoverageError):
            self.trace('titan/async.titan', manifest=changed)

    def test_gcc_relative_mapping_retains_its_recorded_compiler_cwd(self):
        manifest = copy.deepcopy(self.manifest)
        manifest['backend'] = 'gcc-gcov'
        self.assertEqual(self.trace('titan/async.titan', cwd=str(self.source_root), manifest=manifest)
                         ['files'][0]['lines'][0]['count'], 3)
        with self.assertRaisesRegex(coverage.CoverageError, 'outside the declared inventory'):
            self.trace('titan/async.titan', cwd=str(self.report_cwd), manifest=manifest)


class CoverageOwnershipContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='titan-host-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_llvm_probe_success_cleans_and_failure_retains_exact_diagnostics(self):
        diagnostics = dict(schema=1, backend='llvm-gcov', stage='exact-counts-provider',
                           expected_counts={3: 128, 6: 0, 7: 64},
                           observed_counts={3: 126, 6: 0, 7: 63})
        with coverage.llvm_probe_workspace(self.root, dict(diagnostics)) as passed:
            (passed / 'probe.gcda').write_bytes(b'passed counters')
        self.assertFalse(passed.exists())
        with self.assertRaisesRegex(coverage.CoverageError, 'diagnostics retained at') as caught:
            with coverage.llvm_probe_workspace(self.root, diagnostics) as failed:
                (failed / 'probe.gcda').write_bytes(b'failed counters')
                raise coverage.CoverageError('exact count mismatch')
        self.assertIn(str(failed), str(caught.exception))
        self.assertEqual((failed / 'probe.gcda').read_bytes(), b'failed counters')
        failure = coverage.read_json(failed / 'failure.json')
        self.assertEqual(failure['state'], 'failed')
        self.assertEqual(failure['stage'], 'exact-counts-provider')
        self.assertEqual(failure['expected_counts'], {'3': 128, '6': 0, '7': 64})
        self.assertEqual(failure['observed_counts'], {'3': 126, '6': 0, '7': 63})

    def test_llvm_probe_timeout_preserves_bounded_partial_output_and_original_failure(self):
        diagnostics = dict(stage='compile-probe')
        partial = b'x' * 70000
        with self.assertRaisesRegex(coverage.CoverageError, 'compile-probe failed'):
            with coverage.llvm_probe_workspace(self.root, diagnostics) as failed:
                with mock.patch.object(coverage.subprocess, 'run', side_effect=subprocess.TimeoutExpired(
                        ['clang'], 30, output=partial, stderr=b'partial stderr')):
                    coverage.llvm_probe_command(failed, 'compile-probe', ['clang'])
        command = coverage.read_json(failed / 'compile-probe-command.json')
        self.assertIsNone(command['exit_status'])
        self.assertTrue(command['timed_out'])
        self.assertEqual(command['stdout'], dict(bytes=70000, sha256=hashlib.sha256(partial).hexdigest(),
                                                retained_bytes=65536, truncated=True))
        self.assertEqual((failed / 'compile-probe.stdout').stat().st_size, 65536)
        self.assertEqual((failed / 'compile-probe.stderr').read_bytes(), b'partial stderr')
        self.assertEqual(coverage.read_json(failed / 'failure.json')['stage'], 'compile-probe')
        with mock.patch.object(coverage, 'save_json', side_effect=OSError('disk full')), \
             mock.patch.object(coverage.sys, 'stderr', io.StringIO()), \
             self.assertRaisesRegex(coverage.CoverageError, 'primary rejection'):
            with coverage.llvm_probe_workspace(self.root, {}) as unavailable:
                raise coverage.CoverageError('primary rejection')
        self.assertTrue(unavailable.is_dir())

    def test_llvm_probe_interruption_retains_workspace_without_converting_status(self):
        with mock.patch.object(coverage.sys, 'stderr', io.StringIO()), self.assertRaises(KeyboardInterrupt):
            with coverage.llvm_probe_workspace(self.root, dict(stage='collect-provider')) as failed:
                raise KeyboardInterrupt()
        self.assertEqual(coverage.read_json(failed / 'failure.json')['error_type'], 'KeyboardInterrupt')

    def test_llvm_probe_command_evidence_write_failure_keeps_native_failure(self):
        result = subprocess.CompletedProcess(['clang'], 7, stdout=b'', stderr=b'compiler rejection')
        with self.assertRaisesRegex(coverage.CoverageError, 'compile-probe failed \\(exit 7, timeout False\\)'):
            with coverage.llvm_probe_workspace(self.root, dict(stage='compile-probe')) as failed:
                with mock.patch.object(coverage.subprocess, 'run', return_value=result), \
                     mock.patch.object(Path, 'write_bytes', side_effect=OSError('disk full')):
                    coverage.llvm_probe_command(failed, 'compile-probe', ['clang'])
        failure = coverage.read_json(failed / 'failure.json')
        self.assertIn('exit 7', failure['error'])
        self.assertIn('diagnostics could not be written', failure['error'])

    def native_receipt(self):
        return dict(schema=4, runner_kind='titan-coverage-job-v1', leader_created=True,
            leader_pid=123, leader_status_dword=0, leader_status_hex='0x00000000', leader_exited_naturally=True,
            active_processes_at_leader_exit=0, active_processes_before_retirement=0, active_processes_final=0,
            retirement_requested=False, retirement_succeeded=False, forced_leader_retirement=False,
            forced_descendant_retirement=False, timeout=False, interrupted=False, interrupt_code=None,
            empty_job_confirmed=True, reason='normal_exit', complete=True, tests_passed=True,
            supervisor_exit_code=0, supervisor_error_operation=None, win32_error=0, interruption_source='none',
            control_read_handle=10, control_present=True, control_inherit_cleared=True, control_excluded_leader=True,
            leader_handle_list=[20,21,22], control_initial_open=True, control_eof_observed=False,
            control_boundary_ready=True, control_final_observation='open', control_read_closed=True,
            private_console_confirmed=True, console_process_count=1, console_error=0, console_count_before=1,
            console_error_before=0, console_window_before=0, console_window_after=0,
            console_policy='private-headless-inherited', console_free_attempted=False,
            helper_pid=456, console_pid_before=456, console_pid_after=456,
            leader_console_inherit_requested=True, leader_creation_flags=0x80204,
            console_query_capacity=16, console_dword_size=4)

    def test_native_joined_and_ordinary_nonzero_keep_real_dword(self):
        value = self.native_receipt()
        self.assertIs(coverage.validate_windows_receipt(value, 0), value)
        value.update(leader_status_dword=23, leader_status_hex='0x00000017', supervisor_exit_code=23, tests_passed=False)
        self.assertTrue(coverage.validate_windows_receipt(value, 23)['complete'])
        for code in (124, 130):
            value.update(leader_status_dword=code, leader_status_hex='0x{:08x}'.format(code), supervisor_exit_code=code)
            self.assertTrue(coverage.validate_windows_receipt(value, code)['complete'])

    def test_timeout_and_eof_retirement_are_incomplete_despite_empty_job(self):
        for timeout in (False, True):
            value = self.native_receipt()
            value.update(leader_status_dword=125, leader_status_hex='0x0000007d', leader_exited_naturally=False,
                retirement_requested=True, retirement_succeeded=True, forced_leader_retirement=True,
                forced_descendant_retirement=True, active_processes_before_retirement=2,
                timeout=timeout, interrupted=not timeout, complete=False, tests_passed=False,
                supervisor_exit_code=124 if timeout else 130,
                control_eof_observed=not timeout, control_final_observation='open' if timeout else 'eof',
                interruption_source='none' if timeout else 'control_pipe_eof')
            self.assertFalse(coverage.validate_windows_receipt(value, value['supervisor_exit_code'])['complete'])
            with self.assertRaises(coverage.CoverageError): coverage.validate_windows_receipt(dict(value, complete=True), value['supervisor_exit_code'])

    def test_missing_dword_wait_error_unconfirmed_or_contradictory_receipt_reject(self):
        mutations = dict(leader_status_dword=None, empty_job_confirmed=False, active_processes_final=1,
            supervisor_error_operation='bounded leader wait', control_inherit_cleared=False, control_excluded_leader=False,
            control_boundary_ready=False, control_read_closed=False, private_console_confirmed=False,
            console_process_count=0, console_window_after=3, control_final_observation='error',
            control_present=1, leader_status_hex='0x0000007d', tests_passed=False, interrupted=True)
        for key, value in mutations.items():
            with self.subTest(key=key), self.assertRaises(coverage.CoverageError):
                coverage.validate_windows_receipt(dict(self.native_receipt(), **{key:value}), 0)

    def test_private_headless_console_requires_exact_own_pid_and_inherited_leader_policy(self):
        mutations = (
            {'schema':3}, {'runner_kind':'titan-coverage-scratch-private-console-v1'},
            {'console_policy':'private-headless-detached'}, {'private_console_confirmed':False},
            {'console_free_attempted':True}, {'helper_pid':0}, {'console_pid_before':999},
            {'console_pid_after':999}, {'console_count_before':0}, {'console_count_before':2},
            {'console_process_count':0}, {'console_process_count':2}, {'console_window_before':123},
            {'console_window_after':123}, {'leader_console_inherit_requested':False},
            {'leader_creation_flags':0x8080204}, {'leader_creation_flags':0x8020c},
            {'console_query_capacity':1}, {'console_dword_size':8}, {'helper_pid':True},
            {'console_count_before':True}, {'console_window_after':False},
            {'console_free_attempted':0}, {'leader_creation_flags':524804.0})
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(coverage.CoverageError):
                coverage.validate_windows_receipt(dict(self.native_receipt(), **mutation), 0)

    def test_private_console_errors_are_raw_observations_with_strict_numeric_shape(self):
        value = self.native_receipt(); value.update(console_error=123, console_error_before=6)
        self.assertTrue(coverage.validate_windows_receipt(value, 0)['private_console_confirmed'])
        for mutation in ({'console_error':True}, {'console_error_before':-1},
                         {'console_error':1 << 32}, {'console_window_before':None}):
            with self.subTest(mutation=mutation), self.assertRaises(coverage.CoverageError):
                coverage.validate_windows_receipt(dict(value, **mutation), 0)

    def test_live_descendant_and_abnormal_native_exit_remain_incomplete(self):
        value = self.native_receipt()
        value.update(supervisor_exit_code=125, complete=False, tests_passed=False,
            active_processes_at_leader_exit=1, active_processes_before_retirement=1,
            retirement_requested=True, retirement_succeeded=True,
            forced_descendant_retirement=True, reason='leader_exit_with_live_descendants')
        self.assertFalse(coverage.validate_windows_receipt(value, 125)['complete'])
        with self.assertRaises(coverage.CoverageError):
            coverage.validate_windows_receipt(dict(value, complete=True, tests_passed=True), 125)
        value = self.native_receipt()
        value.update(leader_status_dword=0xc0000005, leader_status_hex='0xc0000005',
            supervisor_exit_code=0xc0000005, reason='abnormal_exit', complete=False, tests_passed=False)
        self.assertEqual(coverage.validate_windows_receipt(value, 0xc0000005)['leader_status_dword'], 0xc0000005)
        with self.assertRaises(coverage.CoverageError):
            coverage.validate_windows_receipt(dict(value, complete=True), 0xc0000005)

    def test_unmeasured_list_strict_shape_encoding_nul_missing_and_duplicates(self):
        path = self.root / 'inputs.json'; item = self.root / 'input'; item.write_bytes(b'input')
        for value in ({'path': str(item)}, [1], [''], ['a\0b'], [str(self.root / 'missing')], [str(item), str(item.parent / '.' / item.name)]):
            path.write_text(json.dumps(value), encoding='utf-8')
            with self.subTest(value=value), self.assertRaises(coverage.CoverageError): coverage.unmeasured_input_list(path)
        path.write_bytes(b'\xff')
        with self.assertRaises(coverage.CoverageError): coverage.unmeasured_input_list(path)
        path.write_text(json.dumps([str(item)]), encoding='utf-8')
        self.assertEqual(coverage.unmeasured_input_list(path), [str(item)])

    def fake_runner(self, directory):
        directory.mkdir()
        source = directory / 'titan-coverage-runner.c'; image = directory / 'titan-coverage-runner.exe'; identity = directory / 'runner.json'
        source.write_text(coverage.WINDOWS_RUNNER_SOURCE, encoding='utf-8', newline='\n'); image.write_bytes(b'fake PE')
        compiler = {'argv':['/explicit/clang'], 'effective_compile_args':['-std=c99'], 'sha256':'compiler'}
        python = dict(executable=str(Path(sys.executable).resolve()), sha256=coverage.digest(sys.executable),
            implementation=sys.implementation.name, version=sys.version, version_info=list(sys.version_info[:3]),
            bitness=struct.calcsize('P')*8, implementation_dlls=[])
        argv = compiler['argv'] + compiler['effective_compile_args'] + ['-std=c99','-O0','-fno-lto','-g0','-Wall','-Wextra','-Werror','-municode','-static','-Wl,--no-insert-timestamp',str(source),'-o',str(image)]
        runner = dict(schema=4, path=str(image), sha256=coverage.digest(image), source_path=str(source),
            source_sha256=coverage.runner_source_hash(), identity_path=str(identity), compile_argv=argv,
            compiler_identity=compiler, interpreter_identity=python, pe_image={'imports':['kernel32.dll'], 'subsystem':3})
        coverage.save_json(identity, runner)
        return runner, {'cc':compiler, 'python':python}

    def test_runner_durable_identity_validates_without_rebuilding_or_path_fallback(self):
        runner, tools = self.fake_runner(self.root / 'tools')
        with mock.patch.object(coverage, 'pe_image_identity', return_value=runner['pe_image']), mock.patch.object(coverage, 'invoke') as invoke:
            self.assertEqual(coverage.materialize_runner(self.root / 'tools', tools), runner)
            invoke.assert_not_called()
        Path(runner['path']).write_bytes(b'changed PE')
        with mock.patch.object(coverage, 'invoke') as invoke, self.assertRaisesRegex(coverage.CoverageError, 'bytes changed'):
            coverage.materialize_runner(self.root / 'tools', tools)
        invoke.assert_not_called()

    def test_runner_existing_unsealed_directory_cannot_be_repaired(self):
        path = self.root / 'tools'; path.mkdir()
        with mock.patch.object(coverage, 'invoke') as invoke, self.assertRaisesRegex(coverage.CoverageError, 'without a sealed'):
            coverage.materialize_runner(path, {'cc':{}})
        invoke.assert_not_called()

    def test_runner_overrides_measured_debug_flags_and_rejects_missing_helper_policy(self):
        template, tools = self.fake_runner(self.root / 'template')
        tools['cc']['effective_compile_args'].append('-g')
        def compile_helper(argv, timeout=None):
            Path(argv[-1]).write_bytes(b'ordinary helper PE')
            return subprocess.CompletedProcess(argv, 0, '', '')
        with mock.patch.object(coverage, 'pe_image_identity', return_value=template['pe_image']), mock.patch.object(coverage, 'invoke', side_effect=compile_helper) as invoke:
            runner = coverage.materialize_runner(self.root / 'debug-override', tools)
            invoke.assert_called_once()
            self.assertGreater(runner['compile_argv'].index('-g0'), runner['compile_argv'].index('-g'))
            changed = dict(runner, compile_argv=[arg for arg in runner['compile_argv'] if arg != '-g0'])
            with self.assertRaisesRegex(coverage.CoverageError, 'compile/identity provenance changed'):
                coverage.validate_runner(changed, tools)

    def test_identical_runner_bytes_in_different_build_roots_are_semantically_compatible(self):
        one, _ = self.fake_runner(self.root / 'one'); two, _ = self.fake_runner(self.root / 'two')
        self.assertEqual(coverage.runner_semantic_identity(one), coverage.runner_semantic_identity(two))
        for key, value in (('sha256','changed'), ('source_sha256','changed'), ('schema',3)):
            self.assertNotEqual(coverage.runner_semantic_identity(one), coverage.runner_semantic_identity(dict(two, **{key:value})))

    def test_explicit_llvm_backend_does_not_replace_default_gcc_or_fallback_on_posix(self):
        if os.name == 'nt': self.skipTest('POSIX rejection is a host platform test')
        with mock.patch.object(coverage, 'tool_identity') as tool, self.assertRaisesRegex(coverage.CoverageError, 'native Windows'):
            coverage.identify_backend('clang', 'llvm-cov gcov', backend='llvm-gcov')
        tool.assert_not_called()


    def test_json_input_list_is_hashed_and_merges_repeat_arguments_without_argv_growth(self):
        source = self.root / 'app.titan'; source.write_bytes(b'line\n')
        obj = self.root / 'app.o'; obj.write_bytes(b'object')
        notes = self.root / 'app.gcno'; notes.write_bytes(b'notes')
        image = self.root / 'app'; image.write_bytes(b'program')
        extra = self.root / 'extra'; extra.write_bytes(b'consumer')
        inputs = self.root / 'inputs.json'; inputs.write_text(json.dumps([str(extra)]), encoding='utf-8')
        manifest = dict(version=1, backend='gcc-gcov', root=str(self.root),
            sources=[dict(path=str(source), report_path='app.titan', module='app')],
            objects=[dict(path=str(obj), notes=str(notes), data=str(notes.with_suffix('.gcda')), sources=['app.titan'])],
            providers=[dict(path=str(image), objects=[str(obj)])], settings={'metric':'titan-executable-lines'})
        path = self.root / 'build.json'; coverage.save_json(path, manifest)
        tools = {'cc':{'argv':['gcc'], 'version':'16.2.0'}, 'gcov':{'argv':['gcov'], 'version':'16.2.0'}}
        probe = dict(tools=tools, platform={'system':coverage.platform.system(), 'machine':coverage.platform.machine()}, checks={})
        with mock.patch.object(coverage, 'probe_backend', return_value=probe):
            sealed = coverage.seal_manifest(path, unmeasured_inputs=[str(extra)], unmeasured_input_file=inputs)
        self.assertEqual({item['path'] for item in sealed['link_inventory']}, {str(extra), str(inputs)})
        self.assertEqual(len(sealed['link_inventory']), 2)
        self.assertEqual(next(x for x in sealed['link_inventory'] if x['path'] == str(inputs))['role'], 'unmeasured-input-list')
        inputs.write_text('[]', encoding='utf-8')
        with self.assertRaisesRegex(coverage.CoverageError, 'linked input changed'):
            coverage.validate_inventory(sealed, check_hashes=True)

    def test_drive_strip1_removes_drive_only_without_losing_first_directory(self):
        prefix = self.root / 'counters'
        self.assertEqual(coverage.counter_path(prefix, r'C:\Users\titan-dev\build\app.gcda', 'llvm-gcov'),
                         prefix / 'Users/titan-dev/build/app.gcda')
        self.assertEqual(coverage.counter_path(prefix, 'D:/space dir/app.gcda', 'llvm-gcov'), prefix / 'space dir/app.gcda')
        for path in ('relative.gcda', 'C:relative.gcda', '//server/share/app.gcda', '/tmp/app.gcda'):
            with self.subTest(path=path), self.assertRaises(coverage.CoverageError): coverage.counter_path(prefix, path, 'llvm-gcov')

    def test_windows_readback_rejects_unconfirmed_legacy_and_false_green_parent_interrupt(self):
        run = self.root / 'run'; run.mkdir(); (run / 'counters').mkdir()
        native = self.native_receipt(); coverage.save_json(run / 'native-runner.json', native)
        manifest = dict(backend='llvm-gcov', manifest_id='build', runner={'sha256':'runner'}, objects=[])
        receipt = dict(version=2, manifest_id='build', state='incomplete', exit_status=130, parent_interrupted=True,
            process_ownership='windows-job-object-v1', job_empty_confirmed=True, runner_sha256='runner',
            leader_exit_status=0, native_runner=native, native_receipt_sha256=coverage.digest(run / 'native-runner.json'),
            counter_prefix=str(run / 'counters'), counters=[])
        coverage.save_json(run / 'run.json', receipt)
        loaded, counts = coverage.load_run(run, manifest)
        self.assertEqual(loaded['state'], 'incomplete'); self.assertEqual(counts, {})
        for mutation in ({'state':'complete'}, {'job_empty_confirmed':False}, {'version':1},
                         {'leader_exit_status':125}, {'exit_status':0}, {'runner_sha256':'changed'}):
            coverage.save_json(run / 'run.json', dict(receipt, **mutation))
            with self.subTest(mutation=mutation), self.assertRaises(coverage.CoverageError): coverage.load_run(run, manifest)

    def test_public_popen_enrolls_only_control_read_resets_inheritance_and_streams(self):
        native = self.native_receipt(); captured = {}
        class Child:
            returncode = 0
            stdout = io.BytesIO(b'ordinary output\n')
            stderr = io.BytesIO(b'ordinary error\n')
            def poll(self): return self.returncode
            def wait(self, timeout=None): return self.returncode
        def launch(argv, **kwargs):
            captured.update(argv=argv, kwargs=kwargs)
            native['control_read_handle'] = int(argv[6])
            self.assertTrue(os.get_inheritable(native['control_read_handle']))
            self.assertEqual(kwargs['startupinfo'].lpAttributeList, {'handle_list':[native['control_read_handle']]})
            self.assertTrue(kwargs['close_fds'])
            return Child()
        output, errors, input_stream = io.StringIO(), io.StringIO(), io.StringIO('input')
        with mock.patch.dict(sys.modules, {'msvcrt':SimpleNamespace(get_osfhandle=lambda fd:fd)}), \
             mock.patch.object(coverage.os, 'get_handle_inheritable', side_effect=os.get_inheritable, create=True), \
             mock.patch.object(coverage.os, 'set_handle_inheritable', side_effect=os.set_inheritable, create=True) as inheritance, \
             mock.patch.object(coverage.subprocess, 'STARTUPINFO', side_effect=SimpleNamespace, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x200, create=True), \
             mock.patch.object(coverage.subprocess, 'Popen', side_effect=launch), \
             mock.patch.object(coverage, 'read_json', return_value=native), \
             mock.patch.object(coverage.sys, 'stdout', output), mock.patch.object(coverage.sys, 'stderr', errors), \
             mock.patch.object(coverage.sys, 'stdin', input_stream):
            result = coverage.windows_supervised_run({'path':'/sealed/helper.exe'}, ['program','arg'], self.root / 'native.json', {}, 600)
        self.assertEqual([call.args[1] for call in inheritance.call_args_list], [True, False])
        self.assertIs(captured['kwargs']['stdin'], input_stream)
        self.assertEqual(captured['kwargs']['stdout'], subprocess.PIPE)
        self.assertEqual(captured['kwargs']['stderr'], subprocess.PIPE)
        self.assertEqual(captured['argv'][2], '600000')
        self.assertEqual(output.getvalue(), 'ordinary output\n'); self.assertEqual(errors.getvalue(), 'ordinary error\n')
        self.assertTrue(result['complete']); self.assertFalse(result['parent_interrupted'])

    def test_public_popen_launch_failure_resets_read_inheritance(self):
        with mock.patch.dict(sys.modules, {'msvcrt':SimpleNamespace(get_osfhandle=lambda fd:fd)}), \
             mock.patch.object(coverage.os, 'get_handle_inheritable', side_effect=os.get_inheritable, create=True), \
             mock.patch.object(coverage.os, 'set_handle_inheritable', side_effect=os.set_inheritable, create=True) as inheritance, \
             mock.patch.object(coverage.subprocess, 'STARTUPINFO', side_effect=SimpleNamespace, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x200, create=True), \
             mock.patch.object(coverage.subprocess, 'Popen', side_effect=OSError('creation failed')), \
             self.assertRaisesRegex(OSError, 'creation failed'):
            coverage.windows_supervised_run({'path':'/sealed/helper.exe'}, ['program'], self.root / 'native.json', {})
        self.assertEqual([call.args[1] for call in inheritance.call_args_list], [True,False])

    def test_failed_native_probe_retains_bounded_streams_and_natural_status(self):
        native = self.native_receipt()
        native.update(leader_status_dword=23, leader_status_hex='0x00000017', supervisor_exit_code=23,
                      reason='nonzero_exit', tests_passed=False)
        output = b'native stdout\n'
        errors = b'native stderr\n' + b'x' * 70000
        class Child:
            returncode = 23
            stdout = io.BytesIO(output)
            stderr = io.BytesIO(errors)
            def poll(self): return self.returncode
            def wait(self, timeout=None): return self.returncode
        def launch(argv, **kwargs):
            native['control_read_handle'] = int(argv[6])
            return Child()
        forwarded_output, forwarded_errors = io.StringIO(), io.StringIO()
        with mock.patch.dict(sys.modules, {'msvcrt':SimpleNamespace(get_osfhandle=lambda fd:fd)}), \
             mock.patch.object(coverage.os, 'get_handle_inheritable', side_effect=os.get_inheritable, create=True), \
             mock.patch.object(coverage.os, 'set_handle_inheritable', side_effect=os.set_inheritable, create=True), \
             mock.patch.object(coverage.subprocess, 'STARTUPINFO', side_effect=SimpleNamespace, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x200, create=True), \
             mock.patch.object(coverage.subprocess, 'Popen', side_effect=launch), \
             mock.patch.object(coverage, 'read_json', return_value=native), \
             mock.patch.object(coverage.sys, 'stdout', forwarded_output), \
             mock.patch.object(coverage.sys, 'stderr', forwarded_errors), \
             self.assertRaisesRegex(coverage.CoverageError, 'provider \\(exit 23, complete True\\)'):
            with coverage.llvm_probe_workspace(self.root, dict(stage='collect-provider')) as failed:
                coverage.llvm_probe_run({'path':'/sealed/helper.exe'}, ['program'], failed, 'provider', {})
        self.assertEqual(forwarded_output.getvalue().encode(), output)
        self.assertEqual(forwarded_errors.getvalue().encode(), errors)
        self.assertEqual((failed / 'provider.native.stdout').read_bytes(), output)
        self.assertEqual((failed / 'provider.native.stderr').read_bytes(), errors[:65536])
        streams = coverage.read_json(failed / 'provider-native-streams.json')
        self.assertEqual(streams['capture_errors'], [])
        self.assertEqual(streams['stderr'], dict(bytes=len(errors), sha256=hashlib.sha256(errors).hexdigest(),
                                               retained_bytes=65536, truncated=True))
        outcome = coverage.read_json(failed / 'provider-outcome.json')
        self.assertEqual(outcome['exit_status'], 23)
        self.assertTrue(outcome['complete'])
        self.assertEqual(outcome['native']['active_processes_final'], 0)
        self.assertEqual(coverage.read_json(failed / 'failure.json')['stage'], 'collect-provider')

    def test_native_probe_capture_write_failure_keeps_draining_and_primary_status(self):
        native = self.native_receipt()
        native.update(leader_status_dword=23, leader_status_hex='0x00000017', supervisor_exit_code=23,
                      reason='nonzero_exit', tests_passed=False)
        errors = b'native stderr\n' + b'x' * 70000
        class Child:
            returncode = 23
            stdout = io.BytesIO(b'native stdout\n')
            stderr = io.BytesIO(errors)
            def poll(self): return self.returncode
            def wait(self, timeout=None): return self.returncode
        class PartialWrite:
            def __init__(self, file): self.file = file
            def write(self, data):
                self.file.write(data[:3])
                raise OSError('disk full after partial write')
            def close(self): self.file.close()
        original_open = Path.open
        def open_capture(path, *args, **kwargs):
            file = original_open(path, *args, **kwargs)
            return PartialWrite(file) if path.name == 'provider.native.stderr' else file
        def launch(argv, **kwargs):
            native['control_read_handle'] = int(argv[6])
            return Child()
        forwarded = io.StringIO()
        with mock.patch.dict(sys.modules, {'msvcrt':SimpleNamespace(get_osfhandle=lambda fd:fd)}), \
             mock.patch.object(coverage.os, 'get_handle_inheritable', side_effect=os.get_inheritable, create=True), \
             mock.patch.object(coverage.os, 'set_handle_inheritable', side_effect=os.set_inheritable, create=True), \
             mock.patch.object(coverage.subprocess, 'STARTUPINFO', side_effect=SimpleNamespace, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x200, create=True), \
             mock.patch.object(coverage.subprocess, 'Popen', side_effect=launch), \
             mock.patch.object(coverage, 'read_json', return_value=native), \
             mock.patch.object(coverage.sys, 'stdout', io.StringIO()), \
             mock.patch.object(coverage.sys, 'stderr', forwarded), \
             mock.patch.object(Path, 'open', new=open_capture), \
             self.assertRaisesRegex(coverage.CoverageError, 'provider \\(exit 23, complete True\\)'):
            with coverage.llvm_probe_workspace(self.root, dict(stage='collect-provider')) as failed:
                coverage.llvm_probe_run({'path':'/sealed/helper.exe'}, ['program'], failed, 'provider', {})
        self.assertTrue(forwarded.getvalue().startswith(errors.decode()))
        self.assertEqual((failed / 'provider.native.stderr').read_bytes(), errors[:3])
        streams = coverage.read_json(failed / 'provider-native-streams.json')
        self.assertEqual(streams['stderr']['bytes'], len(errors))
        self.assertEqual(streams['stderr']['retained_bytes'], 3)
        self.assertTrue(streams['stderr']['truncated'])
        self.assertTrue(any('disk full' in error for error in streams['capture_errors']))
        self.assertIn('exit 23', coverage.read_json(failed / 'failure.json')['error'])
        self.assertEqual(coverage.read_json(failed / 'provider-outcome.json')['native']['active_processes_final'], 0)


    def test_python_keyboard_interrupt_remains_incomplete_even_after_helper_final_boundary(self):
        native = self.native_receipt(); captured = {}
        class Child:
            returncode = None
            stdout = io.BytesIO(b'')
            stderr = io.BytesIO(b'')
            def poll(self): return self.returncode
            def wait(self, timeout=None):
                # Native helper legitimately completed its finite EOF boundary
                # just as Python received KI; independent parent must not green.
                self.returncode = 0
                raise KeyboardInterrupt
        def launch(argv, **kwargs):
            native['control_read_handle'] = int(argv[6]); captured['argv']=argv
            return Child()
        with mock.patch.dict(sys.modules, {'msvcrt':SimpleNamespace(get_osfhandle=lambda fd:fd)}), \
             mock.patch.object(coverage.os, 'get_handle_inheritable', side_effect=os.get_inheritable, create=True), \
             mock.patch.object(coverage.os, 'set_handle_inheritable', side_effect=os.set_inheritable, create=True), \
             mock.patch.object(coverage.subprocess, 'STARTUPINFO', side_effect=SimpleNamespace, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True), \
             mock.patch.object(coverage.subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x200, create=True), \
             mock.patch.object(coverage.subprocess, 'Popen', side_effect=launch), \
             mock.patch.object(coverage, 'read_json', return_value=native), \
             mock.patch.object(coverage.sys, 'stdin', io.StringIO()):
            result = coverage.windows_supervised_run({'path':'/sealed/helper.exe'}, ['program'], self.root / 'native.json', {})
        self.assertTrue(result['parent_interrupted']); self.assertFalse(result['complete'])
        self.assertTrue(result['native']['complete']); self.assertEqual(result['exit_status'], 130)
        self.assertEqual(captured['argv'][2], '0')

    def minimal_pe(self, imports=('kernel32.dll',)):
        raw = bytearray(2048); raw[:2]=b'MZ'; struct.pack_into('<I',raw,0x3c,128)
        raw[128:132]=b'PE\0\0'; struct.pack_into('<HH',raw,132,0x8664,1)
        struct.pack_into('<H',raw,148,240); optional=152
        struct.pack_into('<H',raw,optional,0x20b); struct.pack_into('<H',raw,optional+68,3)
        struct.pack_into('<I',raw,optional+108,16)
        struct.pack_into('<II',raw,optional+120,0x1000,(len(imports)+1)*20)
        section=optional+240
        struct.pack_into('<IIII',raw,section+8,1536,0x1000,1536,512)
        name_offset=512+(len(imports)+1)*20
        for index,name in enumerate(imports):
            struct.pack_into('<I',raw,512+index*20+12,0x1000+name_offset-512)
            data=name.encode()+b'\0';raw[name_offset:name_offset+len(data)]=data;name_offset+=len(data)
        return raw

    def test_pe_import_audit_rejects_extra_runtime_wrong_target_and_delayed_imports(self):
        image = self.root / 'runner.exe'; image.write_bytes(self.minimal_pe())
        self.assertEqual(coverage.pe_image_identity(image)['imports'], ['kernel32.dll'])
        image.write_bytes(self.minimal_pe(('kernel32.dll','libwinpthread-1.dll')))
        with self.assertRaisesRegex(coverage.CoverageError, 'extra runtime'): coverage.pe_image_identity(image)
        self.assertEqual(len(coverage.pe_image_identity(image, require_runtime=False)['imports']),2)
        raw=self.minimal_pe();struct.pack_into('<H',raw,132,0x14c);image.write_bytes(raw)
        with self.assertRaisesRegex(coverage.CoverageError, 'AMD64'): coverage.pe_image_identity(image)
        raw=self.minimal_pe();struct.pack_into('<II',raw,152+216,0x1100,32);image.write_bytes(raw)
        with self.assertRaisesRegex(coverage.CoverageError, 'delayed'): coverage.pe_image_identity(image)

    def test_tool_implementation_dll_graph_uses_explicit_sibling_paths_only(self):
        image=self.root/'clang.exe';image.write_bytes(b'driver')
        implementation=self.root/'libclang-cpp.dll';implementation.write_bytes(b'compiler implementation')
        llvm=self.root/'libllvm.dll';llvm.write_bytes(b'backend implementation')
        def pe(path, require_runtime=True):
            self.assertFalse(require_runtime)
            return {'imports':{'clang.exe':['kernel32.dll','libclang-cpp.dll'],
                'libclang-cpp.dll':['api-ms-win-crt-runtime-l1-1-0.dll','libllvm.dll'],
                'libllvm.dll':['kernel32.dll','libclang-cpp.dll']}[Path(path).name]}
        with mock.patch.object(coverage, 'pe_image_identity', side_effect=pe):
            graph=coverage.owned_tool_dlls(image)
            self.assertEqual({x['path'] for x in graph},{str(implementation),str(llvm)})
            self.assertEqual(next(x['sha256'] for x in graph if x['path']==str(llvm)),coverage.digest(llvm))
            llvm.unlink()
            with self.assertRaisesRegex(coverage.CoverageError, 'absent beside'): coverage.owned_tool_dlls(image)


    def test_native_python_semantics_allow_same_bytes_at_another_owned_path_and_reject_mutation(self):
        runner, tools = self.fake_runner(self.root / 'tools')
        original = runner['interpreter_identity']
        relocated = dict(original, executable=str(self.root / 'python-copy'))
        shutil.copyfile(original['executable'], relocated['executable'])
        self.assertEqual(coverage.interpreter_semantic_identity(original), coverage.interpreter_semantic_identity(relocated))
        self.assertIs(coverage.validate_interpreter(relocated, original), relocated)
        for key, value in (('version','changed'), ('implementation','changed'), ('bitness',32)):
            with self.subTest(key=key), self.assertRaises(coverage.CoverageError):
                coverage.validate_interpreter(dict(relocated, **{key:value}), original)
        Path(relocated['executable']).write_bytes(b'changed Python')
        with self.assertRaisesRegex(coverage.CoverageError, 'executable identity changed'):
            coverage.validate_interpreter(relocated, original)

    def test_manifest_merge_binds_runner_bytes_and_counter_policy_without_helper_root_path(self):
        one, tools = self.fake_runner(self.root / 'one'); two, _ = self.fake_runner(self.root / 'two')
        manifest = dict(version=1, backend='llvm-gcov', root=str(self.root), platform={'system':'Windows','machine':'AMD64'},
            sources=[], settings={}, tools=dict(tools, gcov={'sha256':'reader'}), runner=one,
            counter_policy=copy.deepcopy(coverage.LLVM_COUNTER_POLICY))
        other = dict(manifest, runner=two)
        self.assertEqual(coverage.compatible_manifest_identity(manifest), coverage.compatible_manifest_identity(other))
        for changed in (dict(other, runner=dict(two, sha256='changed')),
                        dict(other, counter_policy=dict(coverage.LLVM_COUNTER_POLICY, gcov_prefix_strip=0))):
            self.assertNotEqual(coverage.compatible_manifest_identity(manifest), coverage.compatible_manifest_identity(changed))


    def test_llvm_probe_exercises_real_dumpdir_temporary_object_contract(self):
        tools={'cc':{'argv':['/explicit/clang'], 'effective_compile_args':['-std=c99']}}
        captured=[]
        def compile(work, name, argv):
            captured.append(argv)
            self.assertIn('-dumpdir', argv)
            self.assertNotIn('-Xclang', argv)
            self.assertTrue(argv[argv.index('-dumpdir')+1].endswith(os.sep))
            self.assertTrue(argv[-1].endswith('probe.tmp.o'))
            raise coverage.CoverageError('stop after actual compile argv inspection')
        with mock.patch.object(coverage, 'identify_llvm_backend', return_value=tools), \
             mock.patch.object(coverage, 'materialize_runner', return_value={'path': str(self.root / 'runner.exe')}), \
             mock.patch.object(coverage, 'llvm_probe_command', side_effect=compile), \
             self.assertRaisesRegex(coverage.CoverageError,'argv inspection'):
            coverage.probe_llvm_backend('clang','llvm-cov gcov',runner_directory=self.root/'tools')
        self.assertEqual(len(captured),1)


    def test_windows_inventory_rejects_physical_case_aliases_for_every_native_role(self):
        source=self.root/'app.titan';source.write_bytes(b'line\n')
        obj=self.root/'app.o';obj.write_bytes(b'object')
        notes=self.root/'app.gcno';notes.write_bytes(b'notes')
        image=self.root/'app.dll';image.write_bytes(b'provider')
        linked=self.root/'linked.o';linked.write_bytes(b'linked')
        manifest=dict(version=1,backend='llvm-gcov',root=str(self.root),
            sources=[dict(path=str(source),report_path='app.titan',module='app')],
            objects=[dict(path=str(obj),notes=str(notes),data=str(notes.with_suffix('.gcda')),sources=['app.titan'])],
            providers=[dict(path=str(image),objects=[str(obj)])],link_inventory=[dict(path=str(linked))],
            settings={'metric':'titan-executable-lines'})
        coverage.validate_inventory(manifest)
        for field in ('path','notes','data'):
            changed=copy.deepcopy(manifest); duplicate=copy.deepcopy(changed['objects'][0])
            if field!='path':
                other=self.root/'other.o';other.write_bytes(b'other');duplicate['path']=str(other)
            duplicate[field]=str(Path(duplicate[field]).with_name(Path(duplicate[field]).name.upper()))
            changed['objects'].append(duplicate)
            with self.subTest(field=field), self.assertRaisesRegex(coverage.CoverageError,'physically unique'):
                coverage.validate_inventory(changed)
        for category in ('providers','link_inventory'):
            changed=copy.deepcopy(manifest);duplicate=copy.deepcopy(changed[category][0])
            duplicate['path']=str(Path(duplicate['path']).with_name(Path(duplicate['path']).name.upper()))
            changed[category].append(duplicate)
            with self.subTest(category=category), self.assertRaisesRegex(coverage.CoverageError,'physically unique'):
                coverage.validate_inventory(changed)




# Real Bash control-flow tests; native Windows interfaces are explicit stand-ins.
WINDOWS_WORKFLOW_PUBLIC = REPO / 'scripts/windows_native_coverage.sh'
WINDOWS_WORKFLOW_HELPER = REPO / 'spec/support/windows_stdlib_tests.sh'

WINDOWS_WORKFLOW_HOST = r'''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['WORKFLOW_TRACE'], 'a', encoding='utf-8') as trace:
    trace.write(json.dumps({'kind':'host', 'cwd':os.getcwd(), 'script':sys.argv[0], 'argv':args}) + '\n')
def option(name): return args[args.index(name)+1]
if args[0] == 'run':
    run = pathlib.Path(option('--run'))
    run.mkdir(parents=True, exist_ok=False)
    (run / 'run.json').write_text('{"fixture":"shell-path-status-only"}\n', encoding='utf-8')
    print('fixture native runner output', flush=True)
    sys.exit(int(os.environ.get('HOST_RUN_STATUS', '0')))
if args[0] == 'report':
    output = pathlib.Path(option('--output'))
    output.mkdir(parents=True, exist_ok=False)
    (output / 'coverage.html').write_text('fixture formatted report\n', encoding='utf-8')
    sys.exit(int(os.environ.get('HOST_REPORT_STATUS', '0')))
raise SystemExit('unexpected host action')
'''

WINDOWS_WORKFLOW_AUDITOR = r'''import json, os, sys
with open(os.environ['WORKFLOW_TRACE'], 'a', encoding='utf-8') as trace:
    trace.write(json.dumps({'kind':'auditor', 'cwd':os.getcwd(), 'argv':sys.argv[1:]}) + '\n')
sys.exit(int(os.environ.get('AUDIT_STATUS', '0')))
'''

@unittest.skipUnless(os.name == 'posix' and shutil.which('bash') and shutil.which('perl'),
                     'POSIX shell workflow contract stand-ins')
class WindowsWorkflowShellTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # These Windows-only scripts use MSYS2's modern Bash. Apple ships Bash3.
        probe = subprocess.run(['bash', '-c', 'type mapfile >/dev/null 2>&1'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        if probe.returncode:
            raise unittest.SkipTest('Windows shell workflow stand-ins require Bash4+ with mapfile')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='titan-workflow-shell-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'caller ação 東京'
        self.root.mkdir()
        self.trace = self.root / 'trace.jsonl'
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.executable(self.tools / 'cygpath', '''import pathlib, sys
option, value = sys.argv[1:]
print(str(pathlib.Path(value).resolve()) if 'a' in option else value)
''')
        self.executable(self.tools / 'powershell.exe', 'raise SystemExit(0)\n')
        self.build = self.root / 'build'
        self.work = self.build / 'native'
        for relative in ('sdk/bin', 'cwd', 'scratch'):
            (self.work / relative).mkdir(parents=True)
        (self.work / '.titan-test-owner').write_text('titan-windows-stdlib-tests-v1\n')
        (self.work / 'build.complete').write_text('fixture\n')
        (self.work / 'roots.txt').write_text('test.tests\n')
        (self.work / 'compiler.env').write_text('export TITAN_BUILD_PROFILE=validation\n')
        (self.work / 'check_stdlib_test_output.lua').write_text('-- auditor fixture\n')
        (self.work / 'sdk/bin/titan-stdlib-tests.exe').write_text('fixture\n')
        self.executable(self.work / 'sdk/bin/lua.exe', WINDOWS_WORKFLOW_AUDITOR)
        self.manifest = self.build / 'provider/build.json'
        self.manifest.parent.mkdir()
        self.manifest.write_text('{"fixture":"shell-path-status-only"}\n')
        self.host = self.build / 'sdk-input/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titan-coverage'
        self.host.parent.mkdir(parents=True)
        self.host.write_text(WINDOWS_WORKFLOW_HOST)
        (self.build / '.titan-coverage-owner').write_text('titan-windows-native-coverage-v1\n')
        (self.build / 'build.complete').write_text('fixture\n')
        self.python = shlex.join([sys.executable, '-I', '-B'])
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'],
                        MSYSTEM='CLANG64', TITAN_BUILD_PROFILE='validation',
                        WORKFLOW_TRACE=str(self.trace), TITAN_FILTER='')

    def executable(self, path, body):
        path.write_text('#!' + sys.executable + '\n' + body, encoding='utf-8')
        path.chmod(0o755)

    def invoke(self, script, *arguments, **environment):
        return subprocess.run(['bash', str(script), *map(str, arguments)],
                              cwd=self.root, env=dict(self.env, **environment),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=20)

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def public_run(self, name='runs/one', **environment):
        return self.invoke(WINDOWS_WORKFLOW_PUBLIC, 'run', 'build', name, self.python, **environment)

    def public_report(self, name='reports/one', **environment):
        return self.invoke(WINDOWS_WORKFLOW_PUBLIC, 'report', 'build', 'runs/one', name,
                           self.python, 'fixture-gcovr', **environment)

    def retained_audit(self, value):
        run = self.root / 'runs/one'
        run.mkdir(parents=True)
        (run / 'native-audit.exit').write_bytes(value)

    def assert_status(self, expected, result):
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)

    def test_direct_helper_resolves_all_relative_paths_before_cwd_change(self):
        result = self.invoke(WINDOWS_WORKFLOW_HELPER, 'coverage-run', 'build/native', 'build/provider/build.json',
                             'runs/one', self.python, self.host.relative_to(self.root))
        self.assert_status(0, result)
        host, audit = self.events()
        self.assertEqual(str(self.work / 'cwd'), host['cwd'])
        self.assertEqual(str(self.host), host['script'])
        argv = host['argv']
        self.assertEqual(str(self.manifest), argv[argv.index('--manifest')+1])
        self.assertEqual(str(self.root / 'runs/one'), argv[argv.index('--run')+1])
        self.assertEqual('auditor', audit['kind'])
        self.assertEqual(b'0\n', (self.root / 'runs/one/native-audit.exit').read_bytes())
        self.assertIn('fixture native runner output', (self.root / 'runs/one/output.log').read_text())
        self.assertFalse((self.work / 'cwd/runs').exists())

    def test_public_relative_run_and_report_share_the_callers_directory(self):
        self.assert_status(0, self.public_run())
        self.assert_status(0, self.public_report())
        report = self.events()[-1]
        self.assertEqual(str(self.root), report['cwd'])
        argv = report['argv']
        self.assertEqual(str(self.root / 'runs/one'), argv[argv.index('--run')+1])
        self.assertEqual(str(self.root / 'reports/one'), argv[argv.index('--output')+1])
        self.assertTrue((self.root / 'reports/one/coverage.html').is_file())
        self.assertEqual(b'0\n', (self.root / 'reports/one/native-audit.exit').read_bytes())

    def test_failed_native_run_preserves_its_status_and_can_render_failed_diagnostics(self):
        self.assert_status(23, self.public_run(HOST_RUN_STATUS='23', AUDIT_STATUS='1'))
        self.assert_status(1, self.public_report(HOST_REPORT_STATUS='1'))
        self.assertTrue((self.root / 'reports/one/coverage.html').is_file())
        self.assertEqual(b'1\n', (self.root / 'reports/one/native-audit.exit').read_bytes())

    def test_failed_audit_cannot_become_success_when_reporter_succeeds(self):
        self.retained_audit(b'1\n')
        self.assert_status(1, self.public_report())
        self.assertTrue((self.root / 'reports/one/coverage.html').is_file())
        self.assertEqual(b'1\n', (self.root / 'reports/one/native-audit.exit').read_bytes())

    def test_successful_audit_preserves_reporter_failure(self):
        self.retained_audit(b'0\n')
        self.assert_status(2, self.public_report(HOST_REPORT_STATUS='2'))
        self.assertEqual(b'0\n', (self.root / 'reports/one/native-audit.exit').read_bytes())

    def test_failed_audit_retains_a_partial_report_and_keeps_its_status(self):
        self.retained_audit(b'7\n')
        self.assert_status(7, self.public_report(HOST_REPORT_STATUS='2'))
        self.assertEqual(b'7\n', (self.root / 'reports/one/native-audit.exit').read_bytes())

    def test_missing_audit_rejects_report_without_invoking_host(self):
        self.assert_status(1, self.public_report())
        self.assertEqual([], self.events())
        self.assertFalse((self.root / 'reports/one').exists())

    def test_malformed_audit_rejects_report_without_invoking_host(self):
        self.retained_audit(b'')
        audit = self.root / 'runs/one/native-audit.exit'
        for value in (b'', b'bad\n', b'256\n', b'01\n', b'1\n\n', b'1\0\n', b'1\0', b'0\0', b'0'):
            with self.subTest(value=value):
                audit.write_bytes(value)
                self.assert_status(1, self.public_report())
                self.assertEqual([], self.events())
                self.assertFalse((self.root / 'reports/one').exists())

    def test_existing_report_is_not_changed_after_host_freshness_rejection(self):
        self.retained_audit(b'1\n')
        report = self.root / 'reports/one'
        report.mkdir(parents=True)
        (report / 'native-audit.exit').write_bytes(b'old evidence\n')
        self.assert_status(1, self.public_report())
        self.assertEqual([], self.events())
        self.assertEqual(b'old evidence\n', (report / 'native-audit.exit').read_bytes())

if __name__ == "__main__":
    unittest.main()
