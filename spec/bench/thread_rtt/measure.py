#!/usr/bin/env python3
"""Reproducible cross-thread RTT & component benchmark harness (Issue #252 Workstream 2)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True

CODE = Path(__file__).resolve().parent
PAYLOADS = ("rtt_probe.h", "rtt_probe.c", "bench.titan")
HELPERS = ("compile_guard.lua", "measure.py", "compare.py", "summarize.py")

WRAP_SYMBOLS = (
    "malloc", "calloc", "realloc", "free",
    "memcpy", "memmove",
    "lua_newstate", "lua_close",
    "uv_async_init", "uv_async_send", "uv_close", "uv_loop_close", "mco_yield",
)

CASE_CATALOG = (
    # Group 1: Same-state codec & overhead controls
    dict(name="call_control", category="same_state_codec", protocol="same_state",
         count=10000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="overhead_control", category="same_state_codec", protocol="same_state",
         count=10000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="inspect_record", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="inspect_function", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_scalar_roundtrip", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_small_encode", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_small_decode", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_small_transfer_roundtrip", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_wide16_encode", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_wide16_decode", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_wide16_transfer_roundtrip", category="same_state_codec", protocol="same_state",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_large64k_encode", category="same_state_codec", protocol="same_state",
         count=256, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_large64k_decode", category="same_state_codec", protocol="same_state",
         count=256, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="codec_large64k_transfer_roundtrip", category="same_state_codec", protocol="same_state",
         count=256, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="closure_roundtrip_cap0", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="closure_roundtrip_cap1", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="closure_roundtrip_cap8", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="closure_roundtrip_cap64", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="closure_roundtrip_complex_sig", category="same_state_codec", protocol="same_state",
         count=1000, warmup=100, in_flight=1, producers=1, consumers=1, capacity=1),

    # Group 2: Same-state immediate nonblocking queue controls
    dict(name="queue_plain_bytes8", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="queue_plain_bytes8"),
    dict(name="queue_opaque_hook8", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="queue_plain_bytes8"),
    dict(name="queue_packed_hook8", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="queue_plain_bytes8"),
    dict(name="queue_real_sender", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="queue_plain_bytes8"),
    dict(name="queue_real_receiver", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="queue_plain_bytes8"),
    dict(name="sender_clone", category="same_state_queue", protocol="same_state_queue",
         count=5000, warmup=200, in_flight=1, producers=1, consumers=1, capacity=1),

    # Group 3: Cross-thread SPSC request/reply
    dict(name="spsc_scalar_persistent", category="spsc_rtt", protocol="persistent_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="spsc_record_persistent", category="spsc_rtt", protocol="persistent_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_record_persistent"),
    dict(name="spsc_opaque_persistent", category="spsc_rtt", protocol="persistent_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_record_persistent"),
    dict(name="spsc_endpoint_carried_persistent", category="spsc_rtt", protocol="persistent_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_record_persistent"),
    dict(name="spsc_record_pool4_control", category="spsc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_record_pool4_control"),
    dict(name="spsc_endpoint_pool4_reply", category="spsc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_record_pool4_control"),
    dict(name="spsc_endpoint_fresh_reply", category="spsc_rtt", protocol="fresh_reply",
         count=500, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_endpoint_pool4_reply"),
    dict(name="spsc_large64k_persistent", category="spsc_rtt", protocol="persistent_reply",
         count=256, warmup=16, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_large64k_persistent"),
    dict(name="spsc_large64k_endpoint_pool4", category="spsc_rtt", protocol="pool_four_reply",
         count=256, warmup=16, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="spsc_large64k_persistent"),

    # Group 4: Bounded MPMC & Directed Full/Empty Waits
    dict(name="mpmc_record_inflight1_cap1_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=1, producers=2, consumers=2, capacity=1,
         paired_control="mpmc_record_inflight1_cap1_2p2c"),
    dict(name="mpmc_endpoint_inflight1_cap1_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=1, producers=2, consumers=2, capacity=1,
         paired_control="mpmc_record_inflight1_cap1_2p2c"),
    dict(name="mpmc_record_inflight4_cap1_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=4, producers=2, consumers=2, capacity=1,
         paired_control="mpmc_record_inflight4_cap1_2p2c"),
    dict(name="mpmc_endpoint_inflight4_cap1_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=4, producers=2, consumers=2, capacity=1,
         paired_control="mpmc_record_inflight4_cap1_2p2c"),
    dict(name="mpmc_record_inflight4_cap4_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=4, producers=2, consumers=2, capacity=4,
         paired_control="mpmc_record_inflight4_cap4_2p2c"),
    dict(name="mpmc_endpoint_inflight4_cap4_2p2c", category="mpmc_rtt", protocol="pool_four_reply",
         count=1000, warmup=64, in_flight=4, producers=2, consumers=2, capacity=4,
         paired_control="mpmc_record_inflight4_cap4_2p2c"),
    dict(name="mpmc_record_inflight16_cap2_4p4c", category="mpmc_rtt", protocol="pool_16_reply",
         count=1000, warmup=64, in_flight=16, producers=4, consumers=4, capacity=2,
         paired_control="mpmc_record_inflight16_cap2_4p4c"),
    dict(name="mpmc_endpoint_inflight16_cap2_4p4c", category="mpmc_rtt", protocol="pool_16_reply",
         count=1000, warmup=64, in_flight=16, producers=4, consumers=4, capacity=2,
         paired_control="mpmc_record_inflight16_cap2_4p4c"),
    dict(name="mpmc_record_inflight16_cap16_4p4c", category="mpmc_rtt", protocol="pool_16_reply",
         count=1000, warmup=64, in_flight=16, producers=4, consumers=4, capacity=16,
         paired_control="mpmc_record_inflight16_cap16_4p4c"),
    dict(name="mpmc_endpoint_inflight16_cap16_4p4c", category="mpmc_rtt", protocol="pool_16_reply",
         count=1000, warmup=64, in_flight=16, producers=4, consumers=4, capacity=16,
         paired_control="mpmc_record_inflight16_cap16_4p4c"),
    dict(name="wait_full_sender_record", category="mpmc_rtt", protocol="directed_full_wait",
         count=500, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="wait_full_sender_record"),
    dict(name="wait_full_sender_endpoint", category="mpmc_rtt", protocol="directed_full_wait",
         count=500, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="wait_full_sender_record"),
    dict(name="wait_empty_receiver_record", category="mpmc_rtt", protocol="directed_empty_wait",
         count=500, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="wait_empty_receiver_record"),
    dict(name="wait_empty_receiver_endpoint", category="mpmc_rtt", protocol="directed_empty_wait",
         count=500, warmup=32, in_flight=1, producers=1, consumers=1, capacity=1,
         paired_control="wait_empty_receiver_record"),

    # Group 5: Close/Cancel Churn & Join Paths
    dict(name="churn_close_parked_senders", category="churn_and_join", protocol="close_churn",
         count=500, warmup=32, in_flight=2, producers=2, consumers=1, capacity=1),
    dict(name="churn_close_parked_receivers", category="churn_and_join", protocol="close_churn",
         count=500, warmup=32, in_flight=2, producers=1, consumers=2, capacity=1),
    dict(name="churn_cancel_parked_waiters", category="churn_and_join", protocol="cancel_churn",
         count=500, warmup=32, in_flight=2, producers=1, consumers=1, capacity=1),
    dict(name="join_ordinary", category="churn_and_join", protocol="ordinary_join",
         count=100, warmup=8, in_flight=1, producers=1, consumers=1, capacity=1),
    dict(name="join_cleanup_cancelled_task", category="churn_and_join", protocol="cleanup_join",
         count=100, warmup=8, in_flight=1, producers=1, consumers=1, capacity=1),
)

CASE_BY_NAME = {entry["name"]: entry for entry in CASE_CATALOG}

STDLIB_MODULES = (
    "async", "coroutine", "fs", "gc", "http", "io", "iteration", "json",
    "lua", "math", "net", "os", "path", "peg", "protobuf", "reflect",
    "sqlite3", "ssl", "string", "test", "thread", "timer", "transfer", "url",
    "uv", "websocket",
)


def source_fingerprints(root):
    return {
        str(path.relative_to(root)): digest(path)
        for subtree in ("titan", "vendor/lpeglabel")
        for path in sorted((root / subtree).rglob("*"))
        if path.is_file() and path.suffix in (".titan", ".h")
    }

def specialize_consumer(path, provider_source):
    """Select the measured raw-codec calling contract, never its ABI number."""
    source = (provider_source / "titan/transfer.titan").read_text()
    if "foreign function decode_message(state: *lua_State, slot: *(*void))" in source:
        return "native_consuming_slot"
    if "function decode_message(raw_message: foreign *void): value" not in source:
        raise ValueError("unrecognized measured transfer raw decode contract")
    text = path.read_text()
    start = text.index("local function raw_roundtrip(candidate: value): value\n")
    end = text.index("\nend", start) + len("\nend")
    replacement = (
        "local function raw_roundtrip(candidate: value): value\n"
        "  return transfer.decode_message(transfer.encode_message(candidate))\nend")
    path.write_text(text[:start] + replacement + text[end:])
    return "ordinary_consuming_value"

def expected_checksum(case_name, count, result):
    codec_values = {
        "call_control": 1, "overhead_control": 1, "inspect_record": 2,
        "inspect_function": 1, "codec_scalar_roundtrip": 1,
        "codec_small_decode": 7, "codec_small_transfer_roundtrip": 7,
        "codec_wide16_decode": 17, "codec_wide16_transfer_roundtrip": 17,
        "codec_large64k_decode": 65536, "codec_large64k_transfer_roundtrip": 65536,
        "closure_roundtrip_cap0": 10, "closure_roundtrip_cap1": 4,
        "closure_roundtrip_cap8": 39, "closure_roundtrip_cap64": 2083,
        "closure_roundtrip_complex_sig": 30,
    }
    if case_name in codec_values:
        return codec_values[case_name] * count
    if case_name.endswith("_encode"):
        return result["copy_traffic"]["analytical_reference_bytes_per_op"] * count
    if case_name.startswith(("queue_", "wait_empty_receiver_")) or case_name == "sender_clone":
        return count * (count + 1) // 2
    if case_name.startswith(("spsc_", "mpmc_", "wait_full_sender_")):
        return count * (count + 2)
    if case_name.startswith("churn_"):
        return count * 2
    if case_name == "join_ordinary":
        return count * (count + 3) // 2
    if case_name == "join_cleanup_cancelled_task":
        return count
    raise ValueError(f"missing checksum oracle: {case_name}")


def instrument_thread(root, probe_header):
    """Fail-closed, source-scoped instrumentation of the two audited ABIs.

    Only harness-owned source bytes are changed. Each replacement is scoped to
    its named top-level function; changes in control flow fail the build rather
    than silently falling back to lock-order inference.
    """
    edits = []

    def transform(filename, name, change):
        path = root / "titan/thread" / filename
        text = path.read_text()
        pattern = rf"(?m)^(?:local )?(?:foreign )?function {re.escape(name)}(?:[(<:])"
        match = re.search(pattern, text)
        if match is None:
            raise ValueError(f"missing audited probe owner: {filename}:{name}")
        end = text.find("\nend", match.start())
        if end < 0:
            raise ValueError(f"unterminated probe owner: {filename}:{name}")
        end += len("\nend")
        before = text[match.start():end]
        after = change(before)
        if before == after:
            raise ValueError(f"probe did not change {filename}:{name}")
        path.write_text(text[:match.start()] + after + text[end:])
        edits.append({"file": filename, "owner": name,
                      "before_sha256": hashlib.sha256(before.encode()).hexdigest(),
                      "after_sha256": hashlib.sha256(after.encode()).hexdigest()})

    def once(text, before, after):
        if text.count(before) != 1:
            raise ValueError(f"audited source anchor changed: {before!r}")
        return text.replace(before, after, 1)

    def attempt(text, kind, mutex, expected_returns):
        text = once(text, f"  uv.native_mutex_lock({mutex})",
                    f"  local rtt_attempt = ffi.rtt_probe_attempt_begin({kind})\n"
                    f"  uv.native_mutex_lock({mutex})")
        # Hook immediately BEFORE the exact branch's unlock. A successful
        # dequeue in the native-ABI version assigns result[0] after unlocking.
        pattern = (rf"(?m)^(\s*)uv.native_mutex_unlock\({re.escape(mutex)}\)"
                   rf"\n(\s*(?:result\[0\] = msg\n\s*)?return ([012])(?:[^\n]*))")
        hits = 0
        def branch(match):
            nonlocal hits
            hits += 1
            result = int(match[3])
            # Channel:0 ready/1 blocked/2 closed; join:0 done/1 blocked.
            return (f"{match[1]}ffi.rtt_probe_attempt_end({kind}, waiter as foreign *void, "
                    f"{result}, rtt_attempt)\n{match[0]}")
        text = re.sub(pattern, branch, text)
        if hits != expected_returns:
            raise ValueError(f"expected {expected_returns} exact queue branches, found {hits}")
        return text

    transform("channel.titan", "channel_try_enqueue_native",
              lambda text: attempt(text, 1, "ch.mutex", 3))
    transform("channel.titan", "channel_try_dequeue_native",
              lambda text: attempt(text, 2, "ch.mutex", 4))
    transform("spawn.titan", "thread_control_register_join_waiter",
              lambda text: attempt(text, 3, "ctrl.mutex", 2))
    transform("thread.titan", "waiter_enqueue", lambda text: once(
        text, "  waiter.signaled = 0",
        "  waiter.signaled = 0\n  ffi.rtt_probe_waiter_bind(waiter as foreign *void)"))
    def notify_probe(text):
        text = once(text, "  waiter.signaled = 1",
                    "  waiter.signaled = 1\n  ffi.rtt_probe_waiter_notify(waiter as foreign *void)")
        return once(text, "    uv.async_send_native(waiter.async_handle)",
                    "    local rtt_signal = uv.async_send_native(waiter.async_handle)\n"
                    "    ffi.rtt_probe_waiter_signal_result(waiter as foreign *void, rtt_signal as foreign int)")
    transform("thread.titan", "waiter_wake_one", notify_probe)
    for filename, name in (
        ("channel.titan", "Sender:send"),
        ("channel.titan", "Receiver:dequeue_or_wait"),
        ("spawn.titan", "Thread:join"),
    ):
        def complete_wait(text):
            pattern = r"(?m)^([ \t]*)end\)\n"
            text, count = re.subn(
                pattern, lambda match: match[0] +
                match[1][:-2] + "ffi.rtt_probe_waiter_complete(waiter as foreign *void, 1)\n", text)
            if count != 1:
                raise ValueError(f"native wait completion anchor changed ({count})")
            return text
        transform(filename, name, complete_wait)
    for name, status in (("Sender:send", "fast"), ("Receiver:dequeue_or_wait", "fast_status")):
        def initial_fast(text, status=status):
            text = once(text, "  while true do", "  local rtt_first = true\n  while true do")
            text = once(text, f"    if {status} == 0 then",
                        f"    if {status} == 0 then\n"
                        "      if rtt_first then ffi.rtt_probe_fast_success() end")
            return once(text, "    local waiter_storage = foreign titan_thread_waiter.new()",
                        "    rtt_first = false\n"
                        "    local waiter_storage = foreign titan_thread_waiter.new()")
        transform("channel.titan", name, initial_fast)
    def cancellation_probe(text):
        if re.search(r"(?m)^catch$", text):
            raise ValueError("native wait catch policy changed")
        return text[:-len("\nend")] + (
            "\ncatch\n"
            "  if error is async.CancellationReason<|value|> then\n"
            "    ffi.rtt_probe_cancelled_wait()\n"
            "  end\n"
            "  raise\nend")
    transform("thread.titan", "wait_on_native_waiter", cancellation_probe)
    for filename, name in (
        ("channel.titan", "channel_unregister_overflow_waiter"),
        ("channel.titan", "channel_unregister_underflow_waiter"),
        ("spawn.titan", "thread_control_unregister_join_waiter"),
    ):
        transform(filename, name, lambda text: once(
            text, "  waiter.async_handle = nil",
            "  ffi.rtt_probe_waiter_complete(waiter as foreign *void, 0)\n"
            "  waiter.async_handle = nil"))
    for name in ("Thread:join", "Thread:wait_until_finished_cleanup"):
        def join_probe(text, cleanup=name.endswith("_cleanup")):
            text = once(text, "  local done = ctrl.finished ~= 0",
                        "  local done = ctrl.finished ~= 0\n"
                        "  ffi.rtt_probe_join_check(done and 1 or 0)")
            if cleanup:
                text = once(text,
                    "  local waiter: foreign *titan_thread_waiter = waiter_storage",
                    "  local waiter: foreign *titan_thread_waiter = waiter_storage\n"
                    "  ffi.rtt_probe_cleanup_prepare(waiter as foreign *void)\n"
                    "  defer ffi.rtt_probe_waiter_complete(waiter as foreign *void, 0)")
                text = text[:-len("\nend")] + (
                    "\n  ffi.rtt_probe_waiter_complete(waiter as foreign *void, 1)\nend")
            elif "    return cached" in text:
                text = once(text, "    return cached",
                            "    ffi.rtt_probe_join_check(1)\n    return cached")
            return text
        transform("spawn.titan", name, join_probe)
    for filename, name, anchor, kind, delta in (
        ("channel.titan", "channel_new_native", "  return ch", 1, 1),
        ("thread.titan", "channel_destroy_unreferenced", "  ffi.free(ch)", 1, -1),
        ("spawn.titan", "thread_control_new_native", "  return ctrl", 2, 1),
        ("spawn.titan", "thread_control_destroy_unreferenced", "  ffi.free(ctrl)", 2, -1),
    ):
        transform(filename, name, lambda text, a=anchor, k=kind, d=delta: once(
            text, a, f"  ffi.rtt_probe_resource({k}, {d})\n{a}"))
    def worker_probe(text):
        text = once(text, "  local ctrl = arg as foreign *titan_thread_control",
                    "  ffi.rtt_probe_resource(3, 1)\n"
                    "  local ctrl = arg as foreign *titan_thread_control")
        return once(text, "  thread_control_release_native(ctrl)",
                    "  thread_control_release_native(ctrl)\n  ffi.rtt_probe_resource(3, -1)")
    transform("spawn.titan", "thread_worker_main", worker_probe)
    main = root / "titan/thread/thread.titan"
    main.write_text(f'foreign import "{probe_header}"\n' + main.read_text())
    return edits


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def fingerprints(root, recursive=False):
    paths = root.rglob("*") if recursive else root.iterdir()
    result = {}
    for path in sorted(paths):
        if path.is_symlink():
            result[str(path.relative_to(root))] = {"symlink": os.readlink(path)}
        elif path.is_file():
            stat = path.stat()
            result[str(path.relative_to(root))] = dict(
                sha256=digest(path), size=stat.st_size,
                mode=stat.st_mode, mtime_ns=stat.st_mtime_ns)
    return result


def command_argv(value):
    argv = shlex.split(value)
    if not argv:
        raise ValueError("empty tool command")
    executable = shutil.which(argv[0])
    if executable is None:
        raise ValueError(f"tool not found: {argv[0]}")
    argv[0] = str(Path(executable).absolute())
    return argv


def native_compile_commands(stdout, cc):
    commands = []
    for line in stdout.decode(errors="replace").splitlines():
        try:
            argv = shlex.split(line)
        except ValueError:
            continue
        if argv[:len(cc)] == cc and "-c" in argv:
            commands.append(argv)
    if not commands:
        raise ValueError("verbose compiler receipt contains no actual native C compile argv")
    return commands


def module_seed_inventory(commands, expected):
    observed = [
        flag.split("=", 1)[1] for argv in commands for flag in argv
        if flag.startswith("-frandom-seed=")
    ]
    if sorted(observed) != sorted(expected):
        raise ValueError(f"native module random-seed policy differs: expected {expected}, got {observed}")
    return sorted(observed)


def verify_sdk_header_replay(source, prefix, replay):
    uv_include = prefix / "include/uv"
    if not uv_include.is_dir():
        raise ValueError("SDK must contain the pinned public libuv header directory")
    required = {"include/uv.h", "include/llhttp.h", "include/sqlite3.h"}
    required.update(str(path.relative_to(prefix)) for path in uv_include.rglob("*.h") if path.is_file())
    if not isinstance(replay, dict) or set(replay) != required:
        raise ValueError("native_policy.sdk_header_replay must cover every pinned SDK UV/llhttp/sqlite header exactly")
    for relative, entry in replay.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("source"), str):
            raise ValueError(f"invalid original source header binding: {relative}")
        original = (source / entry["source"]).resolve()
        installed = (prefix / relative).resolve()
        if not original.is_relative_to(source) or not installed.is_relative_to(prefix):
            raise ValueError(f"header replay must stay inside its immutable source/SDK roots: {relative}")
        expected = entry.get("sha256")
        if digest(original) != expected or digest(installed) != expected:
            raise ValueError(f"SDK header differs from the original provider build header: {relative}")
    original_uv = (source / replay["include/uv.h"]["source"]).parent / "uv"
    original_uv_headers = {
        "include/uv/" + str(path.relative_to(original_uv))
        for path in original_uv.rglob("*.h") if path.is_file()
    }
    if not original_uv.is_dir() or original_uv_headers != required - {
            "include/uv.h", "include/llhttp.h", "include/sqlite3.h"}:
        raise ValueError("SDK libuv public header inventory differs from the original source include root")


def snapshot_host():
    result = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "load_average": os.getloadavg() if hasattr(os, "getloadavg") else None,
        "timestamp": time.time(),
    }
    if hasattr(os, "sched_getaffinity"):
        result["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    result["processes"] = subprocess.run(
        ["ps", "-eo", "pid,ppid,comm,time,pcpu"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False).stdout
    return result


def scaled_count(default_value, scale, minimum=4):
    if scale == 1.0:
        return default_value
    return max(minimum, int(round(default_value * scale)))


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.expanduser().resolve()
        self.work = self.output / "work"
        self.logs = self.output / "logs"
        self.samples_dir = self.output / "samples"
        self.manifest_path = self.output / "BUILD.json"
        self.manifest = None
        if args.action != "build":
            self.manifest = json.loads(self.manifest_path.read_text())
            self.config = self.manifest["config"]
        else:
            if self.output.exists():
                raise ValueError("output already exists; choose a fresh owned directory")
            if args.prefix is None:
                raise ValueError("build requires --prefix")
            if not args.titan_cflags or not shlex.split(args.titan_cflags):
                raise ValueError("build requires --titan-cflags with the complete original generated-C flag sequence")
            prefix = args.prefix.expanduser().resolve()
            if args.compiler_script:
                compiler = args.compiler_script.expanduser().resolve()
            else:
                matches = list(prefix.glob("lib/luarocks/rocks-*/titan/*/bin/titanc"))
                if len(matches) != 1:
                    raise ValueError("cannot select one installed compiler; pass --compiler-script")
                compiler = matches[0]
            profile_file = prefix / "etc/titan/build-profile"
            sdk_profile = profile_file.read_text().strip() if profile_file.is_file() else "unknown"
            self.config = dict(
                prefix=str(prefix),
                compiler_script=str(compiler),
                sdk_profile=sdk_profile,
                source_commit=args.source_commit,
                provider_source=str(args.provider_source.resolve()) if args.provider_source else None,
                provider_receipt=str(args.provider_receipt.resolve()) if args.provider_receipt else None,
                cc=command_argv(args.cc),
                ar=command_argv(args.ar),
                ranlib=command_argv(args.ranlib),
                path=os.environ.get("PATH", os.defpath),
                link_libraries=args.link_libraries,
                titan_cflags=args.titan_cflags,
                wrappers_supported=sys.platform.startswith("linux"),
            )
        self.prefix = Path(self.config["prefix"]).resolve()
        if self.output.is_relative_to(self.prefix):
            raise ValueError("output must be outside the read-only prefix")
        if self.output.is_relative_to(CODE):
            raise ValueError("output must be outside the harness source directory")
        if args.action == "build":
            self.output.mkdir(parents=True, exist_ok=False)
            self.work.mkdir()
            (self.work / "tmp").mkdir()
            self.logs.mkdir()
            self.samples_dir.mkdir()
        self.lua = self.prefix / "bin/lua"
        self.env = self.environment()

    def environment(self, extra_ldflags=None):
        env = {
            "PATH": self.config["path"] if "path" in self.config else os.defpath,
            "LANG": "C",
            "LC_ALL": "C",
            "TZ": "UTC",
            "CC": shlex.join(self.config["cc"]),
            "AR": shlex.join(self.config["ar"]),
            "RANLIB": shlex.join(self.config["ranlib"]),
            "MAKEFLAGS": "-j1",
            "TITAN_JOBS": "1",
            "TITAN_PROBE_CACHE_DISABLE": "1",
            "TITAN_ROCKS_ROOT": str(self.prefix),
            "CCACHE_DISABLE": "1",
            "TITAN_PATH_0_6": str(self.prefix / "lib/titan/0.6"),
            "LUA_PATH_5_5": f"{self.prefix}/share/lua/5.5/?.lua;{self.prefix}/share/lua/5.5/?/init.lua",
            "LUA_CPATH_5_5": f"{self.prefix}/lib/titan/0.6/?.so;{self.prefix}/lib/lua/5.5/?.so",
            "TMPDIR": str(self.work / "tmp"),
            "TITAN_BUILD_PROFILE": self.config["sdk_profile"],
        }
        env["TITAN_EXTRA_CFLAGS"] = self.config.get("provider_extra_cflags", "")
        if "emit_line_directives" in self.config:
            env["TITAN_NO_LINE_DIRECTIVES"] = "0" if self.config["emit_line_directives"] else "1"
        env["TITAN_EXTRA_CPPFLAGS"] = self.config.get("provider_cppflags", "")
        ldflags = " ".join(value for value in (
            self.config.get("provider_ldflags", ""), extra_ldflags) if value)
        if ldflags:
            env["TITAN_EXTRA_LDFLAGS"] = ldflags
        return env

    def command(self, label, argv, timeout=300, allow_failure=False, env=None):
        active_env = env or self.env
        stem = self.logs / f"{time.time_ns()}-{label}"
        started = time.time()
        process = subprocess.Popen(
            argv, cwd=self.work, env=active_env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        timed_out = False
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                out, err = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                out, err = process.communicate()
        stdout_path = stem.with_suffix(".stdout")
        stderr_path = stem.with_suffix(".stderr")
        stdout_path.write_bytes(out)
        stderr_path.write_bytes(err)
        receipt = dict(
            argv=argv, cwd=str(self.work), started=started,
            wall_seconds=time.time() - started, exit_code=process.returncode,
            timeout=timed_out, stdout_sha256=digest(stdout_path),
            stderr_sha256=digest(stderr_path), stderr_bytes=len(err),
            payload_sha256={name: digest(CODE / name) for name in PAYLOADS},
            helper_sha256={name: digest(CODE / name) for name in HELPERS if (CODE / name).exists()},
            build_sha256=(digest(self.manifest_path) if self.manifest else None),
            environment=active_env,
        )
        receipt_path = stem.with_suffix(".json")
        write_json(receipt_path, receipt)
        if timed_out or (process.returncode and not allow_failure):
            raise RuntimeError(
                f"command failed ({label}); receipt: {receipt_path}\n"
                f"{err.decode(errors='replace')[-2500:]}")
        return out, err, str(receipt_path)

    def build(self):
        if not self.config["wrappers_supported"]:
            raise ValueError("full accounting currently requires Linux/GNU --wrap; no zero-filled fallback")
        if not self.config["provider_source"] or not self.config["provider_receipt"]:
            raise ValueError("build requires --provider-source and --provider-receipt")
        before = fingerprints(self.prefix, recursive=True)
        write_json(self.output / "PREFIX-BEFORE.json", before)
        provider_source = Path(self.config["provider_source"])
        source_before = source_fingerprints(provider_source)
        receipt_path = Path(self.config["provider_receipt"])
        provider_receipt = json.loads(receipt_path.read_text())
        sdk_hashes = {name: entry["sha256"] for name, entry in before.items() if "sha256" in entry}
        if provider_receipt["source_sha256"] != source_before:
            raise ValueError("provider receipt does not match exact source snapshot")
        if provider_receipt["sdk_sha256"] != sdk_hashes:
            raise ValueError("provider receipt does not match exact immutable SDK files")
        if provider_receipt["titan_cflags"] != self.config["titan_cflags"]:
            raise ValueError("provider/generated-C native flag policy differs")
        if not provider_receipt.get("build_evidence"):
            raise ValueError("provider receipt must identify original build/source matching evidence")
        if not isinstance(provider_receipt.get("native_policy"), dict) or not provider_receipt["native_policy"]:
            raise ValueError("provider receipt requires the original native build policy")
        for key, target in (
                ("titan_cppflags", "provider_cppflags"),
                ("titan_extra_cflags", "provider_extra_cflags"),
                ("titan_ldflags", "provider_ldflags")):
            value = provider_receipt["native_policy"].get(key)
            if not isinstance(value, str):
                raise ValueError(f"native_policy requires explicit {key} (empty is valid)")
            self.config[target] = value
        profile = provider_receipt["native_policy"].get("titan_build_profile")
        if profile not in ("production", "validation") or profile != self.config["sdk_profile"]:
            raise ValueError("native_policy.titan_build_profile must equal the installed SDK profile")
        line_directives = provider_receipt["native_policy"].get("emit_line_directives")
        if not isinstance(line_directives, bool):
            raise ValueError("native_policy.emit_line_directives must be an explicit boolean")
        self.config["emit_line_directives"] = line_directives
        header_replay = provider_receipt["native_policy"].get("sdk_header_replay")
        verify_sdk_header_replay(provider_source, self.prefix, header_replay)
        self.env = self.environment()
        shutil.copy2(receipt_path, self.output / "PROVIDER-RECEIPT.json")
        snapshot = self.work / "provider-source"
        snapshot.mkdir()
        for relative in source_before:
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(provider_source / relative, target)
        probe_edits = instrument_thread(snapshot, self.work / "rtt_probe.h")
        write_json(self.output / "SOURCE-PROBES.json", probe_edits)
        sources = self.output / "sources"
        sources.mkdir()
        for name in PAYLOADS + HELPERS:
            if (CODE / name).exists():
                shutil.copy2(CODE / name, sources / name)
        for name in ("rtt_probe.h", "rtt_probe.c", "bench.titan"):
            shutil.copy2(CODE / name, self.work / name)

        for name in ("cc", "ar", "ranlib"):
            self.command("version-" + name, self.config[name] + ["--version"], allow_failure=True)
        self.command("version-lua", [str(self.lua), "-v"])
        codec_contract = specialize_consumer(self.work / "bench.titan", provider_source)

        uninst_obj = self.work / "rtt_probe_uninst.o"
        inst_obj = self.work / "rtt_probe_inst.o"
        probe_cflags = shlex.split(self.config["titan_cflags"]) + [
            "-std=c11", "-Wextra", "-Werror", "-fno-builtin", "-frandom-seed=rtt_probe",
        ]
        c_base = self.config["cc"] + shlex.split(self.config["provider_cppflags"]) + probe_cflags + [
            f"-I{self.prefix}/include", f"-I{self.work}",
        ]
        self.command(
            "compile-rtt-probe-uninst",
            c_base + ["-DRTT_PROBE_WRAPPERS=0", "-c", str(self.work / "rtt_probe.c"), "-o", str(uninst_obj)],
            300)

        wrap_flag_value = "1" if self.config["wrappers_supported"] else "0"
        self.command(
            "compile-rtt-probe-inst",
            c_base + [f"-DRTT_PROBE_WRAPPERS={wrap_flag_value}", "-c",
                      str(self.work / "rtt_probe.c"), "-o", str(inst_obj)],
            300)

        source_policy_args = [
            self.config["titan_cflags"],
            "1" if self.config["emit_line_directives"] else "0",
            self.config["sdk_profile"],
        ]
        base_titanc = [
            str(self.lua), str(CODE / "compile_guard.lua"),
            self.config["compiler_script"], "./bench.titan",
        ] + source_policy_args + [
            "-v", "--static", "--no-uv-bootstrap", "--tree", ".",
        ]
        link_args = ["-l", self.config["link_libraries"]] if self.config["link_libraries"] else []

        out_uninst, _, _ = self.command(
            "compile-bench-uninstrumented",
            base_titanc + ["-o", "uninstrumented", "-X", str(uninst_obj)] + link_args + ["bench"],
            300)

        wrap_ldflags = " ".join(f"-Wl,--wrap={sym}" for sym in WRAP_SYMBOLS)
        # Rebuild the complete provider namespace, never an overlapping thread provider.
        original_archive = self.prefix / "lib/titan/0.6/titan.a"
        members_raw, _, _ = self.command(
            "original-provider-members", self.config["ar"] + ["t", str(original_archive)])
        members = members_raw.decode().splitlines()
        module_members = [name + ".o" for name in STDLIB_MODULES]
        if members[:len(module_members)] != module_members:
            raise ValueError("original provider member inventory differs from audited full-root layout")
        native_archive = self.work / "original-native.a"
        shutil.copy2(original_archive, native_archive)
        for member in module_members:
            self.command("retain-original-native-" + member,
                         self.config["ar"] + ["dN", "1", str(native_archive), member])
        self.command("index-original-native", self.config["ranlib"] + [str(native_archive)])
        provider_env = self.environment(extra_ldflags=wrap_ldflags)
        provider_env["TITAN_EXTRA_CPPFLAGS"] = shlex.join(
            [f"-I{snapshot / 'vendor/lpeglabel'}", f"-I{self.work}"] +
            shlex.split(self.config["provider_cppflags"]))
        provider_env["TITAN_PATH_0_6"] = str(self.work / "provider")
        out_provider, _, provider_compile_receipt = self.command(
            "compile-private-full-provider",
            [str(self.lua), str(CODE / "compile_guard.lua"),
             self.config["compiler_script"], "provider:" + str(snapshot)] +
            source_policy_args + ["-v", "--source-first", "--tree", str(snapshot),
             "-o", str(self.work / "provider")] +
            ["titan." + name for name in STDLIB_MODULES] +
            ["-X", str(native_archive), str(inst_obj)] + link_args,
            3600, env=provider_env)
        instrumented_env = self.environment(extra_ldflags=wrap_ldflags)
        instrumented_env["TITAN_PATH_0_6"] = str(self.work / "provider")
        out_inst, _, _ = self.command(
            "compile-bench-instrumented",
            base_titanc + ["-o", "instrumented"] + link_args + ["bench"],
            300, env=instrumented_env)
        compile_commands = {
            "private_provider": native_compile_commands(out_provider, self.config["cc"]),
            "consumer_uninstrumented": native_compile_commands(out_uninst, self.config["cc"]),
            "consumer_instrumented": native_compile_commands(out_inst, self.config["cc"]),
        }
        lto = False
        for flag in shlex.split(self.config["titan_cflags"]):
            if flag == "-fno-lto":
                lto = False
            elif flag == "-flto" or flag.startswith("-flto="):
                lto = True
        module_seeds = {
            role: module_seed_inventory(
                commands,
                (["titan." + name for name in STDLIB_MODULES] if role == "private_provider" else ["bench"])
                if lto else [])
            for role, commands in compile_commands.items()
        }
        link_evidence = {}
        for mode in ("uninstrumented", "instrumented"):
            dynamic, _, receipt = self.command(
                "link-dependencies-" + mode,
                ["readelf", "-d", str(self.work / mode / "bench")])
            if re.search(rb"NEEDED.*(?:titan|liblua)", dynamic):
                raise RuntimeError("measurement executable fell back to a dynamic Titan/Lua provider")
            link_evidence[mode] = receipt
        if source_fingerprints(provider_source) != source_before:
            raise RuntimeError("immutable provider source changed during private build")
        verify_sdk_header_replay(provider_source, self.prefix, header_replay)

        abi_version = "unknown"
        for line in out_uninst.decode(errors="replace").splitlines():
            if line.startswith("SOURCE_FREE_IMPORTS:"):
                for token in line.split():
                    if token.startswith("ABI="):
                        abi_version = token.split("=", 1)[1]

        after = fingerprints(self.prefix, recursive=True)
        write_json(self.output / "PREFIX-AFTER.json", after)
        if before != after:
            write_json(self.output / "PREFIX-CHANGED.json", after)
            raise RuntimeError("build modified the supplied prefix")

        selected = [self.lua, Path(self.config["compiler_script"])]
        selected += [
            self.prefix / "lib/titan/0.6" / name
            for name in ("titan.so", "titan.a", "libtitan.a")
        ]
        self.manifest = dict(
            config=self.config,
            abi_version=abi_version,
            source_sha256=source_before,
            private_source_sha256=source_fingerprints(snapshot),
            provider_receipt_sha256=digest(receipt_path),
            provider_build_evidence=provider_receipt["build_evidence"],
            native_policy=provider_receipt["native_policy"],
            source_compile_policy={
                "generated_cflags": shlex.split(self.config["titan_cflags"]),
                "extra_cflags": shlex.split(self.config["provider_extra_cflags"]),
                "build_profile": self.config["sdk_profile"],
                "emit_line_directives": self.config["emit_line_directives"],
                "module_random_seed": module_seeds,
                "probe_cflags": probe_cflags,
                "probe_policy_difference": "C11, instrumentation diagnostics, no builtins, fixed probe-only random seed",
                "private_provider_compile_receipt": provider_compile_receipt,
            },
            native_compile_argv=compile_commands,
            source_probe_sha256=digest(self.output / "SOURCE-PROBES.json"),
            sdk_content_sha256=hashlib.sha256(
                json.dumps(sdk_hashes, sort_keys=True).encode()).hexdigest(),
            native_payload_archive_sha256=digest(native_archive),
            link_evidence=link_evidence,
            platform=platform.platform(),
            machine=platform.machine(),
            payload_sha256={name: digest(CODE / name) for name in PAYLOADS},
            generated_consumer_sha256=digest(self.work / "bench.titan"),
            codec_contract=codec_contract,
            helper_sha256={name: digest(CODE / name) for name in HELPERS if (CODE / name).exists()},
            artifacts=fingerprints(self.work, recursive=True),
            executables={
                "uninstrumented": str(self.work / "uninstrumented/bench"),
                "instrumented": str(self.work / "instrumented/bench"),
            },
            executable_sha256={
                "uninstrumented": digest(self.work / "uninstrumented/bench"),
                "instrumented": digest(self.work / "instrumented/bench"),
            },
            lua_sha256={
                name: digest(self.prefix / name)
                for name in ("bin/lua", "lib/liblua.a")
                if (self.prefix / name).exists()
            },
            provider_files={str(path): digest(path) for path in selected if path.exists()},
            private_provider_files={
                str(path): digest(path) for path in (
                    self.work / "provider/titan.a", self.work / "provider/titan.so")
            },
            tools={
                name: {
                    "argv": self.config[name],
                    "executable_sha256": digest(Path(self.config[name][0]).resolve()),
                }
                for name in ("cc", "ar", "ranlib")
            },
            prefix_before_sha256=digest(self.output / "PREFIX-BEFORE.json"),
        )
        write_json(self.manifest_path, self.manifest)
        return {"build": str(self.manifest_path), "abi": abi_version, "prefix_unchanged": True}

    def validate(self):
        actual_payloads = {name: digest(CODE / name) for name in PAYLOADS}
        if self.manifest["abi_version"] != "2":
            raise RuntimeError("measurement requires exactly ABI 2")
        for filename, field in (
            ("SOURCE-PROBES.json", "source_probe_sha256"),
            ("PROVIDER-RECEIPT.json", "provider_receipt_sha256"),
            ("PREFIX-BEFORE.json", "prefix_before_sha256"),
        ):
            if digest(self.output / filename) != self.manifest[field]:
                raise RuntimeError(f"immutable measurement evidence changed: {filename}")
        helpers = {name: digest(CODE / name) for name in HELPERS}
        if helpers != self.manifest["helper_sha256"]:
            raise RuntimeError("measurement helpers changed after build")
        if actual_payloads != self.manifest["payload_sha256"]:
            raise RuntimeError("measurement payload changed after build; use a new output directory")
        if fingerprints(self.work, recursive=True) != self.manifest["artifacts"]:
            raise RuntimeError("built measurement artifact changed")
        for path, expected in self.manifest["provider_files"].items():
            if digest(path) != expected:
                raise RuntimeError(f"provider changed after build: {path}")
        for name, expected in self.manifest["lua_sha256"].items():
            if digest(self.prefix / name) != expected:
                raise RuntimeError(f"Lua changed after build: {name}")

    def audit(self):
        self.validate()
        before = json.loads((self.output / "PREFIX-BEFORE.json").read_text())
        after = fingerprints(self.prefix, recursive=True)
        path = self.output / f"AUDIT-{time.time_ns()}.json"
        write_json(path, {"unchanged": before == after, "files": len(after)})
        if before != after:
            raise RuntimeError(f"prefix changed since build; see {path}")
        return {"audit": str(path), "unchanged": True, "files": len(after)}

    def run_case(self, case_name, count=None, warmup=None, instrumented=False, tag="single"):
        if case_name not in CASE_BY_NAME:
            raise ValueError(f"unknown benchmark case: {case_name}")
        meta = CASE_BY_NAME[case_name]
        actual_count = count if count is not None else meta["count"]
        actual_warmup = warmup if warmup is not None else meta["warmup"]
        mode_key = "instrumented" if instrumented else "uninstrumented"
        exe = self.manifest["executables"][mode_key]
        sample_file = self.samples_dir / f"{time.time_ns()}-{tag}-{mode_key}-{case_name}.tsv"
        argv = [
            exe, case_name, str(actual_count), str(actual_warmup),
            "1" if instrumented else "0", str(sample_file),
        ]
        out, err, receipt = self.command(
            f"{tag}-{mode_key}-{case_name}-{actual_count}", argv, timeout=300)
        if len(err) != 0:
            raise RuntimeError(
                f"benchmark {case_name} produced unexpected stderr ({len(err)} bytes): "
                f"{err.decode(errors='replace')}")
        result = json.loads(out.decode("utf-8"))
        if result["case"] != case_name or result["operations"] != actual_count:
            raise RuntimeError("benchmark returned a different case/count")
        if result["instrumented"] != instrumented:
            raise RuntimeError("benchmark instrumentation mode mismatch")
        for field in ("in_flight", "producers", "consumers", "capacity"):
            if result[field] != meta[field]:
                raise RuntimeError(f"benchmark topology mismatch: {field}")
        if result["checksum"] != expected_checksum(case_name, actual_count, result):
            raise RuntimeError(f"benchmark checksum mismatch in {case_name}")
        for stage, distribution in result["distributions"].items():
            if distribution["truncated"] != 0:
                raise RuntimeError(f"{stage} sample buffer truncated in {case_name}")
        if result["distributions"]["rtt"]["samples"] != actual_count:
            raise RuntimeError(f"wrong RTT sample count in {case_name}")
        if not sample_file.is_file():
            raise RuntimeError(f"missing required raw samples in {case_name}")
        with sample_file.open() as stream:
            if sum(1 for _ in stream) != actual_count + 1:
                raise RuntimeError(f"wrong raw RTT sample count in {case_name}")
        if instrumented and self.config.get("wrappers_supported"):
            cal = result.get("calibration", {})
            if not ( result.get("wrapper_hooks_compiled") is True and
                     cal.get("ran") is True and cal.get("passed") is True and
                     cal.get("slot_exhaustion_failures") == 0 ):
                raise RuntimeError(f"wrapper calibration/hook check failed in {case_name}: {cal}")
            if any(result["lifecycle"].values()):
                raise RuntimeError(f"native domain resources not retired in {case_name}: {result['lifecycle']}")
            cat = meta["category"]
            if cat in ("spsc_rtt", "mpmc_rtt") or case_name.startswith(("queue_", "codec_", "closure_")):
                total_alloc_hits = (
                    result["lua_memory"]["body_alloc_calls"] +
                    result["native_memory"]["body_malloc_calls"] +
                    result["native_memory"]["body_calloc_calls"]
                )
                if total_alloc_hits <= 0:
                    raise RuntimeError(f"zero allocator hook hits in instrumented case {case_name}")
            if cat in ("spsc_rtt", "mpmc_rtt", "same_state_queue", "churn_and_join") and case_name != "sender_clone":
                wc = result["wait_counters"]
                total_wait_ops = wc["fast_successes"] + wc["slow_path_attempts"] + wc["cancellations"]
                if total_wait_ops <= 0:
                    raise RuntimeError(f"zero mutex/wait hook hits in instrumented case {case_name}")
            if case_name.startswith(("wait_full_sender_", "wait_empty_receiver_")) or case_name == "join_ordinary":
                if result["wait_counters"]["actual_suspensions"] < actual_count:
                    raise RuntimeError(
                        f"directed wait case {case_name} did not suspend every iteration "
                        f"({result['wait_counters']['actual_suspensions']} < {actual_count})")
            if case_name == "churn_cancel_parked_waiters":
                if result["wait_counters"]["cancellations"] < actual_count * 2:
                    raise RuntimeError(
                        f"cancel churn case did not record expected cancellations "
                        f"({result['wait_counters']['cancellations']} < {actual_count * 2})")
            if case_name == "join_ordinary" and result["wait_counters"]["ordinary_join_suspensions"] < actual_count:
                raise RuntimeError("ordinary join did not take its actual native slow path")
            if case_name == "join_cleanup_cancelled_task" and result["wait_counters"]["cleanup_join_suspensions"] < actual_count:
                raise RuntimeError("proxy cleanup join did not take its actual native slow path")
        return {
            "result": result,
            "receipt": receipt,
            "raw_samples_tsv": str(sample_file),
            "raw_samples_sha256": digest(sample_file),
        }


def summarize_campaign(manifest, rows):
    summary = {
        "provenance": manifest,
        "catalog_case_count": len(CASE_CATALOG),
        "cases": {}, "instrumentation_overhead": {},
        "endpoint_contrasts": {}, "protocol_contrasts": {}, "policy_contrasts": {},
    }
    cases_seen = sorted({r["case"] for r in rows})
    for case_name in cases_seen:
        uninst_rows = [
            r["result"] for r in rows
            if r["case"] == case_name and not r["instrumented"]
        ]
        inst_rows = [
            r["result"] for r in rows
            if r["case"] == case_name and r["instrumented"]
        ]
        entry = {"meta": CASE_BY_NAME.get(case_name, {})}
        if uninst_rows:
            us_list = [r["clocks"]["us_per_op"] for r in uninst_rows]
            tp_list = [r["clocks"]["throughput_ops_per_sec"] for r in uninst_rows]
            p50_list = [r["distributions"]["rtt"]["p50_ns"] / 1000.0 for r in uninst_rows]
            p95_list = [r["distributions"]["rtt"]["p95_ns"] / 1000.0 for r in uninst_rows]
            p99_list = [r["distributions"]["rtt"]["p99_ns"] / 1000.0 for r in uninst_rows]
            gc_list = [
                (r["clocks"]["gc1_wall_ns"] + r["clocks"]["gc2_wall_ns"]) / 1000.0 / r["operations"]
                for r in uninst_rows
            ]
            retire_list = [r["clocks"]["retire_wall_ns"] / 1000.0 for r in uninst_rows]
            cold_list = [r["clocks"]["cold_init_ns"] / 1000.0 for r in uninst_rows]
            entry["uninstrumented"] = {
                "rounds": len(uninst_rows),
                "operations_per_round": uninst_rows[0]["operations"],
                "checksum": uninst_rows[0]["checksum"],
                "all_checksums_equal": len({r["checksum"] for r in uninst_rows}) == 1,
                "median_us_per_op": statistics.median(us_list),
                "range_us_per_op": [min(us_list), max(us_list)],
                "median_throughput_ops_per_sec": statistics.median(tp_list),
                "median_rtt_p50_us": statistics.median(p50_list),
                "median_rtt_p95_us": statistics.median(p95_list),
                "median_rtt_p99_us": statistics.median(p99_list),
                "range_rtt_p99_us": [min(p99_list), max(p99_list)],
                "median_residual_gc_us_per_op": statistics.median(gc_list),
                "median_retire_workers_us": statistics.median(retire_list),
                "median_cold_first_use_us": statistics.median(cold_list),
                "max_peak_rss_kib": max(r["process_peak_rss_kib"] for r in uninst_rows),
                "host_lua_post_gc2_minus_setup_bytes": [
                    r["lua_memory"]["host_post_gc2_minus_setup_start_bytes"] for r in uninst_rows
                ],
            }
        if inst_rows:
            us_inst = [r["clocks"]["us_per_op"] for r in inst_rows]
            r0 = sorted(inst_rows, key=lambda row: row["clocks"]["us_per_op"])[len(inst_rows) // 2]
            ops = r0["operations"]
            stages = {}
            for sname in (
                "sender_encode", "queue_admission", "wait_registration",
                "native_wake", "receiver_decode", "reply_processing",
                "req_one_way", "reply_one_way",
            ):
                s_samples = [r["distributions"][sname]["samples"] for r in inst_rows]
                if max(s_samples) > 0:
                    s_p50 = [r["distributions"][sname]["p50_ns"] / 1000.0 for r in inst_rows if r["distributions"][sname]["samples"] > 0]
                    s_p95 = [r["distributions"][sname]["p95_ns"] / 1000.0 for r in inst_rows if r["distributions"][sname]["samples"] > 0]
                    s_p99 = [r["distributions"][sname]["p99_ns"] / 1000.0 for r in inst_rows if r["distributions"][sname]["samples"] > 0]
                    stages[sname] = {
                        "samples": sum(s_samples),
                        "samples_per_round_range": [min(s_samples), max(s_samples)],
                        "rounds_with_samples": sum(count > 0 for count in s_samples),
                        "median_p50_us": statistics.median(s_p50),
                        "median_p95_us": statistics.median(s_p95),
                        "median_p99_us": statistics.median(s_p99),
                    }
                else:
                    stages[sname] = {"samples": 0}
            entry["instrumented"] = {
                "rounds": len(inst_rows),
                "representative_round_policy": "upper median body us/op; counters/per-op values below are that actual round",
                "counter_rounds": [
                    {key: row[key] for key in (
                        "clocks", "wait_counters", "handle_counters", "lua_memory",
                        "native_memory", "copy_traffic", "lifecycle", "calibration",
                        "distributions", "native_wake_attribution_mode")}
                    for row in inst_rows
                ],
                "lifecycle": r0["lifecycle"],
                "all_lifecycles_balanced": all(not any(row["lifecycle"].values()) for row in inst_rows),
                "median_us_per_op": statistics.median(us_inst),
                "native_wake_attribution_mode": " / ".join(sorted({
                    row.get("native_wake_attribution_mode", "unknown") for row in inst_rows})),
                "representative_native_wake_attribution_mode": r0.get("native_wake_attribution_mode", "unknown"),
                "calibration": r0.get("calibration", {}),
                "wait_counters": r0["wait_counters"],
                "handle_counters": r0["handle_counters"],
                "lua_memory": r0["lua_memory"],
                "native_memory": r0["native_memory"],
                "copy_traffic": r0["copy_traffic"],
                "per_op": {
                    "lua_allocs_per_op": (
                        r0["lua_memory"]["body_alloc_calls"] + r0["lua_memory"]["body_realloc_calls"]
                    ) / ops,
                    "lua_requested_bytes_per_op": r0["lua_memory"]["body_requested_bytes"] / ops,
                    "native_allocs_per_op": (
                        r0["native_memory"]["body_malloc_calls"] +
                        r0["native_memory"]["body_calloc_calls"] +
                        r0["native_memory"]["body_realloc_calls"]
                    ) / ops,
                    "native_requested_bytes_per_op": r0["native_memory"]["body_requested_bytes"] / ops,
                    "interposed_memcpy_bytes_per_op": r0["copy_traffic"]["body_interposed_memcpy_bytes"] / ops,
                    "outside_lua_alloc_memcpy_bytes_per_op": r0["copy_traffic"]["body_outside_lua_alloc_memcpy_bytes"] / ops,
                    "inside_lua_alloc_memcpy_bytes_per_op": r0["copy_traffic"]["body_inside_lua_alloc_memcpy_bytes"] / ops,
                    "uv_async_init_per_op": r0["handle_counters"]["body_uv_async_init_calls"] / ops,
                },
                "stage_attribution": stages,
            }
        if uninst_rows and inst_rows:
            u_med = entry["uninstrumented"]["median_us_per_op"]
            i_med = entry["instrumented"]["median_us_per_op"]
            summary["instrumentation_overhead"][case_name] = {
                "uninstrumented_median_us_per_op": u_med,
                "instrumented_median_us_per_op": i_med,
                "overhead_us_per_op": i_med - u_med,
                "overhead_ratio": (i_med / u_med) if u_med > 0 else None,
            }
        summary["cases"][case_name] = entry

    for case_name, entry in summary["cases"].items():
        ctrl_name = entry["meta"].get("paired_control")
        if ctrl_name and ctrl_name != case_name and ctrl_name in summary["cases"]:
            c_entry = summary["cases"][ctrl_name]
            if "uninstrumented" in entry and "uninstrumented" in c_entry:
                u_case = entry["uninstrumented"]["median_us_per_op"]
                u_ctrl = c_entry["uninstrumented"]["median_us_per_op"]
                if entry["meta"]["protocol"] != c_entry["meta"]["protocol"]:
                    contrast_group = "protocol_contrasts"
                elif "endpoint" in case_name or case_name in ("queue_real_sender", "queue_real_receiver"):
                    contrast_group = "endpoint_contrasts"
                else:
                    contrast_group = "policy_contrasts"
                if contrast_group == "endpoint_contrasts":
                    fields = ("in_flight", "producers", "consumers", "capacity")
                    if any(entry["meta"][field] != c_entry["meta"][field] for field in fields):
                        raise ValueError("component contrast has mismatched topology")
                summary[contrast_group][case_name] = {
                    "control_case": ctrl_name,
                    "case_median_us_per_op": u_case,
                    "control_median_us_per_op": u_ctrl,
                    "delta_us_per_op": u_case - u_ctrl,
                }
    return summary


def run_campaign(runner, args):
    runner.validate()
    selected_names = (
        [c.strip() for c in args.cases.split(",") if c.strip()]
        if args.cases else [c["name"] for c in CASE_CATALOG]
    )
    for name in selected_names:
        if name not in CASE_BY_NAME:
            raise ValueError(f"unknown case: {name}")

    rng = random.Random(args.seed)
    evidence = {
        "started": time.time(),
        "host_before": snapshot_host(),
        "build_manifest": str(runner.manifest_path),
        "build_manifest_sha256": digest(runner.manifest_path),
        "abi_version": runner.manifest["abi_version"],
        "sdk_profile": runner.config["sdk_profile"],
        "source_commit": runner.config.get("source_commit"),
        "scale": args.scale,
        "batches": args.batches,
        "repeats_per_batch": args.repeats,
        "instrumented_repeats": args.instrumented_repeats,
        "seed": args.seed,
        "rows": [],
    }
    raw_path = runner.output / "BASELINE-RAW.json"

    for batch in range(args.batches):
        for repeat in range(args.repeats):
            ordered = list(selected_names)
            rng.shuffle(ordered)
            for case_name in ordered:
                meta = CASE_BY_NAME[case_name]
                cnt = scaled_count(meta["count"], args.scale)
                wmp = scaled_count(meta["warmup"], args.scale, minimum=2)
                row = runner.run_case(
                    case_name, count=cnt, warmup=wmp,
                    instrumented=False, tag=f"b{batch}-r{repeat}")
                evidence["rows"].append({
                    "batch": batch,
                    "repeat": repeat,
                    "case": case_name,
                    "instrumented": False,
                    **row,
                })
                write_json(raw_path, evidence)

    for irep in range(args.instrumented_repeats):
        ordered = list(selected_names)
        rng.shuffle(ordered)
        for case_name in ordered:
            meta = CASE_BY_NAME[case_name]
            cnt = scaled_count(meta["count"], args.scale)
            wmp = scaled_count(meta["warmup"], args.scale, minimum=2)
            row = runner.run_case(
                case_name, count=cnt, warmup=wmp,
                instrumented=True, tag=f"inst-r{irep}")
            evidence["rows"].append({
                "batch": 0,
                "repeat": irep,
                "case": case_name,
                "instrumented": True,
                **row,
            })
            write_json(raw_path, evidence)

    evidence["host_after"] = snapshot_host()
    evidence["finished"] = time.time()
    write_json(raw_path, evidence)

    summary = summarize_campaign(runner.manifest, evidence["rows"])
    summary_path = runner.output / "BASELINE-SUMMARY.json"
    write_json(summary_path, summary)
    runner.audit()
    return {
        "raw": str(raw_path),
        "summary": str(summary_path),
        "cases": len(selected_names),
        "total_rows": len(evidence["rows"]),
    }


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--prefix", type=Path, help="installed Titan 0.6 / Lua 5.5 prefix")
    p.add_argument("--output", type=Path, help="fresh measurement output directory outside repo and prefix")
    p.add_argument("--provider-source", type=Path, help="immutable source snapshot matching the installed provider")
    p.add_argument("--provider-receipt", type=Path, help="original build evidence binding exact source/SDK hashes and flags")
    p.add_argument("--compiler-script", type=Path, help="explicit titanc Lua script path")
    p.add_argument("--source-commit", default=None, help="git commit SHA of the measured provider source")
    p.add_argument("--cc", default=os.environ.get("CC", "cc"))
    p.add_argument("--ar", default=os.environ.get("AR", "ar"))
    p.add_argument("--ranlib", default=os.environ.get("RANLIB", "ranlib"))
    p.add_argument("--link-libraries", default="pthread,rt,ssl,crypto")
    p.add_argument("--titan-cflags", help="required for build: complete original generated-C flags, not only EXTRA_CFLAGS")
    p.add_argument("--case", default="spsc_record_persistent")
    p.add_argument("--cases", default=None, help="comma-separated subset of cases")
    p.add_argument("--count", type=int, default=None)
    p.add_argument("--warmup", type=int, default=None)
    p.add_argument("--instrumented", action="store_true")
    p.add_argument("--batches", type=int, default=2)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--instrumented-repeats", type=int, default=2)
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--seed", type=int, default=252)
    p.add_argument(
        "action",
        choices=("plan", "build", "run", "baseline", "smoke", "audit"),
    )
    return p


def main():
    args = parser().parse_args()
    if args.action == "plan":
        print(json.dumps({"cases": list(CASE_CATALOG), "total_cases": len(CASE_CATALOG)}, indent=2))
        return
    if args.output is None:
        raise ValueError(f"{args.action} requires --output")
    runner = Runner(args)
    if args.action == "build":
        print(json.dumps(runner.build(), indent=2))
    elif args.action == "audit":
        print(json.dumps(runner.audit(), indent=2))
    elif args.action == "run":
        runner.validate()
        print(json.dumps(
            runner.run_case(args.case, count=args.count, warmup=args.warmup,
                            instrumented=args.instrumented),
            indent=2))
    elif args.action == "smoke":
        args.scale = 0.05
        args.batches = 1
        args.repeats = 1
        args.instrumented_repeats = 1
        print(json.dumps(run_campaign(runner, args), indent=2))
    elif args.action == "baseline":
        print(json.dumps(run_campaign(runner, args), indent=2))


if __name__ == "__main__":
    main()
