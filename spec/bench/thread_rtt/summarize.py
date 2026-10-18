#!/usr/bin/env python3
"""Render measured baseline/paired evidence; never infer unmeasured performance."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True


def fmt(value, digits=3):
    return "unavailable" if value is None else f"{value:.{digits}f}"


def span(values):
    return f"{min(values):.1f}..{max(values):.1f}" if values else "unavailable"


def map_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def provenance(manifest, lane):
    if manifest.get("abi_version") != "2":
        raise ValueError("reports require the current ABI 2")
    config = manifest.get("config", {})
    lines = [f"### {lane} provenance", "", "| Input | Recorded evidence |", "|---|---|"]
    values = {
        "ABI / SDK / language-server API": "2 / 0.6 / 1 (compile guard)",
        "Claimed source revision (builder-attested, not inferred)": config.get("source_commit"),
        "SDK profile": config.get("sdk_profile"),
        "Complete generated-C flags (including optimization / LTO / debug)": config.get("titan_cflags"),
        "Generated-C source-line directives": manifest.get("source_compile_policy", {}).get("emit_line_directives"),
        "Full SDK content manifest SHA-256": manifest.get("sdk_content_sha256"),
        "Source hash-map SHA-256": map_hash(manifest.get("source_sha256", {})),
        "Source probe recipe SHA-256": manifest.get("source_probe_sha256"),
        "Original builder receipt SHA-256": manifest.get("provider_receipt_sha256"),
        "Preserved native payload archive SHA-256": manifest.get("native_payload_archive_sha256"),
        "Generated consumer SHA-256": manifest.get("generated_consumer_sha256"),
        "Raw codec calling contract": manifest.get("codec_contract"),
    }
    for key, value in values.items():
        lines.append(f"| {key} | `{value if value is not None else 'unavailable'}` |")
    details = {key: manifest.get(key) for key in (
        "provider_files", "private_provider_files", "executable_sha256", "lua_sha256", "tools", "native_policy",
        "source_sha256", "private_source_sha256", "link_evidence", "provider_build_evidence",
        "source_compile_policy", "native_compile_argv")}
    lines += ["", "<details><summary>Exact provider/source/tool/link evidence</summary>", "", "```json",
              json.dumps(details, indent=2, sort_keys=True), "```", "", "</details>", ""]
    return lines


def lane_tables(summary, title):
    cases = summary.get("cases", {})
    lines = [f"## {title}", "", f"Catalog: {summary.get('catalog_case_count', 'unavailable')} cases; "
             f"this report contains {len(cases)} measured cases.", "",
             "Uninstrumented timing uses the original immutable SDK. Instrumented timing uses a private "
             "full-provider rebuild with source-scoped semantic probes and the original native payload. "
             "The difference below is instrumentation overhead, not a production speedup.", "",
             "### Uninstrumented end-to-end timing", "",
             "| Case | Protocol | Rounds / samples | us/op median [range] | RTT p50/p95/p99 us | ops/s | Cold first use us | Residual GC us/op | Retire us |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for name, entry in cases.items():
        row = entry.get("uninstrumented")
        if row is None:
            continue
        low, high = row["range_us_per_op"]
        lines.append(
            f"| `{name}` | `{entry['meta']['protocol']}` | {row['rounds']} / "
            f"{row['rounds'] * row['operations_per_round']} | {row['median_us_per_op']:.3f} "
            f"[{low:.3f}..{high:.3f}] | {row['median_rtt_p50_us']:.3f}/"
            f"{row['median_rtt_p95_us']:.3f}/{row['median_rtt_p99_us']:.3f} | "
            f"{row['median_throughput_ops_per_sec']:.1f} | {row['median_cold_first_use_us']:.1f} | "
            f"{row['median_residual_gc_us_per_op']:.3f} | {row['median_retire_workers_us']:.1f} |")
    lines += ["", "RTT columns are medians of per-round percentiles, not pooled percentiles. "
              "Directed full-sender samples are admission/previous-packet release acknowledgements, "
              "not processing RTTs for the newly admitted request. Churn includes fresh resource/state creation.",
              "", "### Exact native branch counts (representative instrumented round)", "",
              "Counters/per-op traffic select the actual upper-median body-time round; all instrumented "
              "rounds remain in the summary JSON. Counts are branch events within the body window, including "
              "worker request receives and protocol-control channels. A wait can begin before the window. "
              "Fast successes are successful first readiness checks, not post-suspension retry successes. "
              "Closed outcomes are never counted as successful fast paths/rechecks. Slow attempts are failed "
              "ready checks entering registration; native suspensions, successful registration rechecks, selected waiter "
              "notification attempts and nominal CancellationReason errors are separate events.", "",
              "| Case | Fast | Slow | Recheck OK | Suspends | Ordinary / cleanup join suspends | Notify | Cancel | Async init / public close requests |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for name, entry in cases.items():
        row = entry.get("instrumented")
        if row is None:
            continue
        wait = row["wait_counters"]
        handles = row["handle_counters"]
        lines.append(
            f"| `{name}` | {wait['fast_successes']} | {wait['slow_path_attempts']} | "
            f"{wait['registration_recheck_successes']} | {wait['actual_suspensions']} | "
            f"{wait['ordinary_join_suspensions']} / {wait['cleanup_join_suspensions']} | "
            f"{wait['notifications']} | {wait['cancellations']} | "
            f"{handles['body_uv_async_init_calls']} / {handles['body_uv_async_close_calls']} |")
    lines += ["", "### Native async handle retirement (representative instrumented round)", "",
              "| Case | Whole-case async init | Public close requests | Terminal close callbacks | Async retirements at successful loop close | Successful / attempted loop closes |",
              "|---|---:|---:|---:|---:|---:|"]
    for name, entry in cases.items():
        row = entry.get("instrumented")
        if row is None:
            continue
        handles = row["handle_counters"]
        lines.append(
            f"| `{name}` | {handles['whole_case_uv_async_init_calls']} | "
            f"{handles['whole_case_uv_async_close_calls']} | "
            f"{handles['whole_case_uv_async_close_callbacks']} | "
            f"{handles['whole_case_uv_async_loop_retirements']} | "
            f"{handles['whole_case_uv_loop_close_successes']} / "
            f"{handles['whole_case_uv_loop_close_calls']} |")
    lines += ["", "Whole-case counters start at the setup snapshot after cold first use; identities are "
              "tracked from process birth, including cold loops. Libuv initializes loop-internal async "
              "handles through uv_async_init but retires them directly during successful uv_loop_close. "
              "Those retirements are not fabricated public close requests or callbacks. A busy/failed loop "
              "close retires no identity; active_async_handles remains the actual unretired registry count "
              "and must be zero. Real UV allocation traffic is not suppressed.", ""]
    lines += ["", "### Allocation and observed copy traffic", "",
              "| Case | Lua allocs / requested B per op | Native allocs / requested B per op | Interposed copy B/op (outside / inside Lua allocator) | Analytical reference B/op (not wire/copy bytes) |",
              "|---|---:|---:|---:|---:|"]
    for name, entry in cases.items():
        row = entry.get("instrumented")
        if row is None:
            continue
        traffic = row["per_op"]
        lines.append(
            f"| `{name}` | {traffic['lua_allocs_per_op']:.2f} / {traffic['lua_requested_bytes_per_op']:.1f} | "
            f"{traffic['native_allocs_per_op']:.2f} / {traffic['native_requested_bytes_per_op']:.1f} | "
            f"{traffic['interposed_memcpy_bytes_per_op']:.1f} "
            f"({traffic['outside_lua_alloc_memcpy_bytes_per_op']:.1f} / "
            f"{traffic['inside_lua_alloc_memcpy_bytes_per_op']:.1f}) | "
            f"{row['copy_traffic']['analytical_reference_bytes_per_op']} |")
    lines += ["", "Lua allocator requests include state birth and terminal close. Only allocations made "
              "inside the underlying Lua allocator are excluded from native traffic; real UV allocations are "
              "not suppressed. Copy counts cover interposed memcpy **and memmove** calls, not inlined copies, "
              "scalar stores or libc-internal copying. Actual total wire bytes are unavailable; the analytical "
              "reference can use a different payload/ID and is not presented as measured transfer traffic.", "",
              "### Lifecycle and post-retirement evidence (all instrumented rounds)", "",
              "| Case | Rounds | Channels delta range | Controls delta range | Active worker range | Lua state delta / active async handles / pending wait probes | Observed native block / usable B net ranges | Host Lua net B range | Checksums / lifecycle |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---|"]
    for name, entry in cases.items():
        row = entry.get("instrumented")
        if row is None:
            continue
        rounds = row["counter_rounds"]
        life = lambda key: span([item["lifecycle"][key] for item in rounds])
        native_blocks = span([item["native_memory"]["whole_case_post_gc2_live_blocks_delta"] for item in rounds])
        native_bytes = span([item["native_memory"]["whole_case_post_gc2_usable_bytes_delta"] for item in rounds])
        lua_bytes = span([item["lua_memory"]["host_post_gc2_minus_setup_start_bytes"] for item in rounds])
        checksums = entry.get("uninstrumented", {}).get("all_checksums_equal", False)
        lines.append(
            f"| `{name}` | {len(rounds)} | {life('channels_delta')} | {life('controls_delta')} | "
            f"{life('active_workers')} | {life('lua_states_delta')} / {life('active_async_handles')} / "
            f"{life('pending_waiter_probes')} | {native_blocks} / {native_bytes} | {lua_bytes} | "
            f"{'valid' if checksums and row['all_lifecycles_balanced'] else 'INVALID'} |")
    lines += ["", "Channel/control counts are actual native birth/destruction probes. Worker quiescence "
              "waits for the native end-of-worker release, not a fixed number of loop turns or public join "
              "alone; it is native domain-ownership retirement evidence, not an OS-join proof. The pre-wake "
              "resource-ownership correctness checkpoint intentionally retains known legacy detached-thread/"
              "proxy-early-terminal behavior and is not final Thread approval. The separate final corrected "
              "wake/join candidate requires actual OS join before every proxy terminal and full platform "
              "correctness evidence. Explicit residual "
              "collections occur outside body timing. The allocator's signed net "
              "delta is an observed ledger, **not** a complete retained-native-memory oracle; lifecycle counts "
              "are reported separately. Failed calibration, missing/truncated samples, checksum errors and "
              "unretired native domains reject a campaign.", "",
              "### Overlapping source-scoped stage intervals", "",
              "| Case | Wake attribution | Sender entry through encode | Queue lock + branch | Registration after failed check | Notify to continuation | Post-dequeue decode + return | Reply processing |",
              "|---|---|---:|---:|---:|---:|---:|---:|"]
    for name, entry in cases.items():
        row = entry.get("instrumented")
        if row is None:
            continue
        def cell(key):
            stage = row["stage_attribution"].get(key, {})
            if not stage.get("samples"):
                return "unavailable (0 samples)"
            low, high = stage["samples_per_round_range"]
            return (f"{stage['median_p50_us']:.3f}/{stage['median_p99_us']:.3f} "
                    f"({stage['samples']} total; {low}..{high}/round)")
        lines.append(
            f"| `{name}` | `{row['native_wake_attribution_mode']}` | {cell('sender_encode')} | "
            f"{cell('queue_admission')} | {cell('wait_registration')} | {cell('native_wake')} | "
            f"{cell('receiver_decode')} | {cell('reply_processing')} |")
    lines += ["", "Cells are medians of per-round p50/p99 microseconds, with total sample count and per-round count range. "
              "Wake modes list all observed round modes, not only the representative counter round. "
              "Encode/decode subintervals cover selected benchmark call brackets, not every worker's codec. "
              "Queue intervals include lock acquisition and readiness/closed branches, ending before unlock. "
              "Native wake correlates the exact selected waiter with its notification and successful continuation; "
              "cancelled/failed/nonunique notifications are unavailable, never attributed to a global last signal. "
              "It is not isolated kernel wake latency. Stages overlap across OS threads: do not add medians or "
              "subtract independently measured RTTs to manufacture a component time.", "",
              "### Instrumentation overhead", "",
              "| Case | Original SDK us/op | Private instrumented us/op | Difference us/op | Ratio |",
              "|---|---:|---:|---:|---:|"]
    for name, row in summary.get("instrumentation_overhead", {}).items():
        lines.append(f"| `{name}` | {row['uninstrumented_median_us_per_op']:.3f} | "
                     f"{row['instrumented_median_us_per_op']:.3f} | {row['overhead_us_per_op']:+.3f} | "
                     f"{fmt(row['overhead_ratio'])} |")
    for group, heading in (
        ("endpoint_contrasts", "Matched protocol/shape endpoint component contrasts"),
        ("policy_contrasts", "Payload-policy controls (not isolated endpoint costs)"),
        ("protocol_contrasts", "Application-protocol contrasts (not matched endpoint components)"),
    ):
        lines += ["", f"### {heading}", "",
                  "| Case | Control | Case us/op | Control us/op | Difference us/op |", "|---|---|---:|---:|---:|"]
        for name, row in summary.get(group, {}).items():
            lines.append(f"| `{name}` | `{row['control_case']}` | {row['case_median_us_per_op']:.3f} | "
                         f"{row['control_median_us_per_op']:.3f} | {row['delta_us_per_op']:+.3f} |")
    lines += ["", "Matched endpoint contrasts retain common field count, capacity, OS producer/consumer "
              "counts, in-flight budget and validation/protocol; payload representation, hooks, wrapper "
              "allocation and ownership differ together. They do not isolate only retain/release cost. "
              "Fresh/pool-four and large pool-four/persistent comparisons change application protocol and "
              "are kept in the separate protocol table.", ""]
    return lines


def render_single_lane(summary):
    lines = ["# Cross-thread RTT and component evidence", ""]
    lines += provenance(summary["provenance"], "Measured checkpoint")
    lines += lane_tables(summary, "Measured results")
    return "\n".join(lines) + "\n"


def render_paired(summary):
    lines = ["# Paired baseline/candidate cross-thread evidence", "",
             f"Raw evidence: `{summary['raw_evidence']}` (SHA-256 `{summary['raw_evidence_sha256']}`).", "",
             "## Operator quiescence evidence", "", summary["quiescence_note"], "",
             f"Note SHA-256: `{summary['quiescence_note_sha256']}`.", "",
             "## Actual within-pair differences", "",
             "| Case | Pairs | Median candidate - baseline us/op | Difference range | Median within-pair ratio | Independent batch median differences |",
             "|---|---:|---:|---:|---:|---|"]
    for name, entry in summary["comparisons"].items():
        row = entry.get("paired")
        if row is None:
            continue
        low, high = row["range_delta_us_per_op"]
        batches = ", ".join(f"{batch}: {value:+.3f}" for batch, value in row["batch_median_deltas_us_per_op"].items())
        lines.append(f"| `{name}` | {row['pair_count']} | {row['median_delta_us_per_op']:+.3f} | "
                     f"{low:+.3f}..{high:+.3f} | {fmt(row['median_ratio'])} | {batches} |")
    lines += ["", "These are statistics of actual alternating-order matched observations, not differences "
              "of marginal medians. Raw per-pair observations/order and lane marginal summaries are retained. "
              "Ranges and batch differences expose observed variation; this renderer does not assert "
              "statistical significance or attribute a resource-ownership checkpoint change to a later final "
              "corrected wake/join cutover.", ""]
    for lane in ("baseline", "candidate"):
        lane_summary = summary["lanes"][lane]
        lines += provenance(lane_summary["provenance"], lane)
        lines += lane_tables(lane_summary, lane + " marginal results")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary_json", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    summary = json.loads(args.summary_json.read_text())
    text = render_paired(summary) if "comparisons" in summary else render_single_lane(summary)
    if args.output:
        args.output.write_text(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
