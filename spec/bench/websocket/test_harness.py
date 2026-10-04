"""Host-only checks. Never invoke Lua, titanc, a provider, or a benchmark."""
import argparse
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import measure
import peer
import ssl
import summarize


class BytesStream:
    def __init__(self, payload): self.payload = payload
    def recv(self, count):
        result, self.payload = self.payload[:count], self.payload[count:]
        return result


class HarnessTests(unittest.TestCase):
    def test_frame_length_boundaries_and_masks(self):
        for size in (0,1,125,126,65535,65536):
            for masked in (False,True):
                with self.subTest(size=size, masked=masked):
                    payload = b"x" * size
                    wire = peer.Wire(BytesStream(peer.frame(2, payload, masked=masked)))
                    self.assertEqual(wire.receive(masked), (2, True, payload))

    def test_frame_rejects_wrong_masks_nonminimal_lengths_and_controls(self):
        for payload in (b"\x82\x80\0\0\0\0", b"\x82\x7e\0\x01x",
                        b"\x09\0", b"\x89\x7e\0\x7ex" + b"x"*125):
            with self.subTest(payload=payload[:8]):
                with self.assertRaises(ValueError): peer.Wire(BytesStream(payload)).receive(False)

    def test_opening_known_accept(self):
        self.assertEqual(peer.accept_key(b"dGhlIHNhbXBsZSBub25jZQ=="), b"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_matrix_unique_complete_and_separate(self):
        rows = measure.matrix()
        self.assertEqual(len(rows), len({measure.case_id(row) for row in rows}))
        self.assertEqual({r["transport"] for r in rows}, {"control","tcp","tls","ws","wss"})
        self.assertEqual({r["phase"] for r in rows}, {"setup","steady","teardown","sessions"})
        groups = {}
        for row in rows:
            if row["phase"] == "steady" and not row["gc_stopped"]:
                key = json.dumps({k:v for k,v in row.items() if k != "count"}, sort_keys=True)
                groups.setdefault(key, set()).add(row["count"])
        self.assertTrue(groups)
        self.assertTrue(all(counts == {0,100,1000} for counts in groups.values()))

    def test_build_without_owner_readiness_fails_before_prefix_access(self):
        with tempfile.TemporaryDirectory() as temp:
            args = argparse.Namespace(repo=Path("/var/home/mascarenhas/Code/titan"),
                output=Path(temp)/"untouched", action="build", readiness=None)
            with self.assertRaisesRegex(ValueError, "owner readiness"):
                measure.Runner(args)
            self.assertFalse(args.output.exists())

    def test_refused_readiness_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as temp:
            ready = Path(temp)/"ready.json"
            ready.write_text(json.dumps(dict(owner_thread_id=measure.OWNER,
                consumer_compile_ready=False, frozen_inputs=False)))
            args = argparse.Namespace(repo=Path("/var/home/mascarenhas/Code/titan"),
                output=Path(temp)/"untouched", action="build", readiness=ready)
            with self.assertRaisesRegex(ValueError, "not confirmed"):
                measure.Runner(args)
            self.assertFalse(args.output.exists())

    def test_empty_fairness_samples_have_no_zero_latency(self):
        self.assertFalse(measure.fairness_sufficient(dict(wall_seconds=.3,
                         one_ms_timer_interarrival={"samples":0})))
        self.assertFalse(measure.fairness_sufficient(dict(wall_seconds=.2,
                         one_ms_timer_interarrival={"samples":100})))
        self.assertTrue(measure.fairness_sufficient(dict(wall_seconds=.3,
                        one_ms_timer_interarrival={"samples":100})))

    def test_allocation_authorization_does_not_authorize_quiet_timing(self):
        runner = measure.Runner.__new__(measure.Runner)
        runner.ready = dict(owner_thread_id=measure.OWNER, consumer_compile_ready=True)
        with self.assertRaisesRegex(ValueError, "runtime/allocation readiness"):
            runner.allocation_authorization()
        runner.ready["allocations_ready"] = True
        runner.args = argparse.Namespace(quiet_note=None)
        with self.assertRaisesRegex(ValueError, "quiet-window note"):
            runner.quiet()

    def test_peer_fixture_context_keeps_chain_and_hostname_verification(self):
        context = peer.fixture_client_context("/var/home/mascarenhas/Code/titan/spec/fixtures/ssl/ca.pem")
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        self.assertFalse(context.verify_flags & ssl.VERIFY_X509_STRICT)

    def test_raw_tls_broken_pipe_is_only_tolerated_after_byte_budget(self):
        class BrokenStream:
            def recv(self, _count): raise BrokenPipeError("post-abort TLS output")
        config = dict(transport="tls", role="client", operation="write",
                      size=0, count=0, go_marker="unused")
        with patch("peer.wait_marker"):
            self.assertEqual(peer.exercise(BrokenStream(), config)["bytes"], 0)
            with self.assertRaises(BrokenPipeError):
                peer.exercise(BrokenStream(), config | dict(size=1, count=1))

    def test_slope_report_and_incomplete_rejection(self):
        rows = []
        for count in (0,100,1000):
            body = {field:7 + count*3 for field in summarize.FIELDS}
            body.update(live_bytes=200, peak_live_bytes=300)
            rows.append(dict(case=dict(transport="ws", phase="steady", count=count, gc_stopped=False),
                result=dict(instrumented=1, postgc_ledger_error_bytes=0, initial_live_bytes=100,
                    body=body, teardown=body, postgc=body, process_peak_rss_kib=1000,
                    endpoint_collected_after_release=True), consumer_receipt="c",peer_receipt="p"))
        report = summarize.summarize(dict(completed=3,planned=3,rows=rows))
        self.assertEqual(report["slopes"][0]["per_operation_100_to_1000"]["userdata"], 3)
        self.assertEqual(report["slopes"][0]["per_operation_0_to_100"]["requested_bytes"], 3)
        with self.assertRaisesRegex(ValueError,"incomplete"):
            summarize.summarize(dict(completed=2,planned=3,rows=rows[:2]))
        with self.assertRaisesRegex(ValueError,"lacks"):
            summarize.summarize(dict(completed=2,planned=2,rows=rows[:2]))


if __name__ == "__main__": unittest.main()
