"""Exercise actual child retirement and missing/progress evidence rejection."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from run import HERE, Processes, audit_driver_events, wait_measured


class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        artifacts = HERE / ".artifacts" / "orchestration-tests"
        artifacts.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=artifacts)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.processes = Processes("docker", self.root, os.environ.copy())
        self.addCleanup(self.processes.close)

    def sleeper(self):
        return self.processes.start([sys.executable, "-c", "import time; time.sleep(30)"], "sleeper")

    def test_owned_process_group_is_retired_and_joined(self):
        child = self.sleeper()
        self.assertIsNone(child.poll())
        self.processes.stop_process(child)
        self.assertIsNotNone(child.poll())
        self.assertEqual(self.processes.children, [])
        self.processes.stop_process(child)  # idempotent ownership retirement

    def test_timeout_does_not_turn_into_success_and_cleanup_joins_child(self):
        child = self.sleeper()
        with self.assertRaisesRegex(RuntimeError, "deadline exceeded"):
            wait_measured(child, timeout=0.1)
        self.processes.close()
        self.assertIsNotNone(child.poll())

    def test_peer_exit_aborts_run(self):
        child = self.sleeper()
        peer = self.processes.start([sys.executable, "-c", "pass"], "peer")
        peer.wait(timeout=5)
        with self.assertRaisesRegex(RuntimeError, "required peer exited"):
            wait_measured(child, timeout=5, observed_processes=(peer,))

    def test_child_exit_nonzero_is_a_failed_run(self):
        child = self.processes.start([sys.executable, "-c", "raise SystemExit(7)"], "failed")
        with self.assertRaisesRegex(RuntimeError, "exited 7"):
            wait_measured(child, timeout=5)

    def test_child_uses_drained_log_pipe_and_retirement_joins_capture(self):
        child = self.processes.start([sys.executable, "-c",
            "import os, stat; assert stat.S_ISFIFO(os.fstat(1).st_mode); print('stdout'); os.write(2, b'stderr\\n')"], "logged")
        wait_measured(child, timeout=5)
        self.processes.stop_process(child)
        self.assertEqual(set((self.root / "logged.log").read_text().splitlines()), {"stdout", "stderr"})
        self.assertEqual(self.processes.log_pumps, {})

    def test_evidence_budget_fails_and_cleanup_joins_child(self):
        child = self.sleeper()
        (self.root / "oversize").write_bytes(b"x" * 1024)
        with self.assertRaisesRegex(RuntimeError, "evidence size budget exceeded"):
            wait_measured(child, timeout=5, evidence_root=self.root, evidence_limit_bytes=512)
        self.processes.close()
        self.assertIsNotNone(child.poll())

    def test_driver_evidence_requires_exact_order_and_completion(self):
        path = self.root / "events.jsonl"
        cases = ["1.1.1", "7.7.8"]
        events = [{"phase": "case-count", "ordinal": 2, "id": ""}]
        for ordinal, case in enumerate(cases, 1):
            events.extend([{"phase": "case-start", "ordinal": ordinal, "id": case},
                           {"phase": "case-end", "ordinal": ordinal, "id": case}])
        events.append({"phase": "complete", "ordinal": 2, "id": ""})
        path.write_text("".join(json.dumps(event) + "\n" for event in events))
        audit_driver_events(path, cases)
        for malformed in (events[:-1], events[:2] + events[3:], events + [events[2]]):
            path.write_text("".join(json.dumps(event) + "\n" for event in malformed))
            with self.assertRaises(RuntimeError):
                audit_driver_events(path, cases)


if __name__ == "__main__":
    unittest.main()
