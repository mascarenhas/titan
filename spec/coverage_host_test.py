"""Host coverage contract tests; run with Python 3, GCC/gcov 14+ and gcovr 8.4.

No Titan SDK or source-adjacent native build is touched. The fixture deliberately
contains build-time counters, notes-only production code and a loaded provider.
"""

import copy
import hashlib
from html.parser import HTMLParser
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
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


if __name__ == "__main__":
    unittest.main()
