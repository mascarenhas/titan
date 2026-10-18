#!/usr/bin/env python3
"""Paired alternating/randomized baseline vs candidate comparison runner (Issue #252 Workstream 2)."""
import argparse
import json
from pathlib import Path
import random
import statistics
import sys
import time

sys.dont_write_bytecode = True
import measure


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--baseline", required=True, type=Path, help="built baseline harness directory")
    p.add_argument("--candidate", required=True, type=Path, help="built candidate harness directory")
    p.add_argument("--output", required=True, type=Path, help="fresh comparison output directory")
    p.add_argument("--quiescence-note", type=Path, required=True,
                   help="dated operator evidence confirming local and VM builds are quiet")
    p.add_argument("--batches", type=int, default=2)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--instrumented-repeats", type=int, default=2)
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--seed", type=int, default=252)
    p.add_argument("--cases", default=None, help="comma-separated subset of cases")
    args = p.parse_args()

    if args.batches < 1 or args.repeats < 1 or args.instrumented_repeats < 1 or args.scale <= 0:
        raise ValueError("batches, repeats, and scale must be positive")

    selected_names = (
        [c.strip() for c in args.cases.split(",") if c.strip()]
        if args.cases else [c["name"] for c in measure.CASE_CATALOG]
    )
    for name in selected_names:
        if name not in measure.CASE_BY_NAME:
            raise ValueError(f"unknown case: {name}")

    note_text = None
    note_sha = None
    if args.quiescence_note is not None:
        note_text = args.quiescence_note.read_text()
        if not note_text.strip():
            raise ValueError("quiescence note is empty")
        note_sha = measure.digest(args.quiescence_note)

    output = args.output.expanduser().resolve()
    runners = {
        lane: measure.Runner(measure.parser().parse_args(["--output", str(path), "audit"]))
        for lane, path in (("baseline", args.baseline), ("candidate", args.candidate))
    }
    for runner in runners.values():
        runner.validate()

    base_m = runners["baseline"].manifest
    cand_m = runners["candidate"].manifest
    for field in ("payload_sha256", "helper_sha256", "tools", "platform", "machine", "lua_sha256", "native_policy"):
        if base_m[field] != cand_m[field]:
            raise ValueError(f"comparison inputs differ: {field}")
    for field in ("link_libraries", "titan_cflags", "sdk_profile"):
        if base_m["config"][field] != cand_m["config"][field]:
            raise ValueError(f"comparison build policy differs: {field}")
    for field in (
            "generated_cflags", "extra_cflags", "build_profile", "emit_line_directives",
            "module_random_seed", "probe_cflags", "probe_policy_difference"):
        if base_m["source_compile_policy"][field] != cand_m["source_compile_policy"][field]:
            raise ValueError(f"comparison generated-source policy differs: {field}")
    if base_m["abi_version"] != "2" or cand_m["abi_version"] != "2":
        raise ValueError("both measured checkpoints must use current ABI 2")

    if output.is_relative_to(measure.CODE) or any(
        output.is_relative_to(r.prefix) or output.is_relative_to(r.output)
        for r in runners.values()
    ):
        raise ValueError("comparison output must be outside prefixes, harness sources, and lane outputs")

    output.mkdir(parents=True, exist_ok=False)
    rng = random.Random(args.seed)

    evidence = {
        "started": time.time(),
        "quiescence_note": note_text,
        "quiescence_note_sha256": note_sha,
        "host_before": measure.snapshot_host(),
        "scale": args.scale,
        "batches": args.batches,
        "repeats_per_batch": args.repeats,
        "instrumented_repeats": args.instrumented_repeats,
        "seed": args.seed,
        "builds": {
            lane: {
                "manifest_path": str(r.manifest_path),
                "manifest_sha256": measure.digest(r.manifest_path),
                "abi_version": r.manifest["abi_version"],
                "sdk_profile": r.config["sdk_profile"],
                "source_commit": r.config.get("source_commit"),
                "provider_files": r.manifest["provider_files"],
                "source_sha256": r.manifest["source_sha256"],
                "source_probe_sha256": r.manifest["source_probe_sha256"],
                "thread_wait_contract": r.manifest["thread_wait_contract"],
                "provider_receipt_sha256": r.manifest["provider_receipt_sha256"],
                "sdk_content_sha256": r.manifest["sdk_content_sha256"],
                "native_policy": r.manifest["native_policy"],
                "source_compile_policy": r.manifest["source_compile_policy"],
                "codec_contract": r.manifest["codec_contract"],
                "generated_consumer_sha256": r.manifest["generated_consumer_sha256"],
            }
            for lane, r in runners.items()
        },
        "rows": [],
    }
    raw_path = output / "PAIRED-RAW.json"

    pair_counter = 0
    for batch in range(args.batches):
        for repeat in range(args.repeats):
            ordered = list(selected_names)
            rng.shuffle(ordered)
            for case_name in ordered:
                meta = measure.CASE_BY_NAME[case_name]
                cnt = measure.scaled_count(meta["count"], args.scale)
                wmp = measure.scaled_count(meta["warmup"], args.scale, minimum=2)
                lane_order = (
                    ("baseline", "candidate")
                    if pair_counter % 2 == 0
                    else ("candidate", "baseline")
                )
                pair_counter += 1
                for lane in lane_order:
                    row = runners[lane].run_case(
                        case_name, count=cnt, warmup=wmp,
                        instrumented=False, tag=f"paired-b{batch}-r{repeat}-{lane}")
                    evidence["rows"].append({
                        "lane": lane,
                        "batch": batch,
                        "repeat": repeat,
                        "case": case_name,
                        "instrumented": False,
                        "pair_order": list(lane_order),
                        **row,
                    })
                    measure.write_json(raw_path, evidence)

    for irep in range(args.instrumented_repeats):
        ordered = list(selected_names)
        rng.shuffle(ordered)
        for case_name in ordered:
            meta = measure.CASE_BY_NAME[case_name]
            cnt = measure.scaled_count(meta["count"], args.scale)
            wmp = measure.scaled_count(meta["warmup"], args.scale, minimum=2)
            lane_order = (
                ("baseline", "candidate")
                if pair_counter % 2 == 0
                else ("candidate", "baseline")
            )
            pair_counter += 1
            for lane in lane_order:
                row = runners[lane].run_case(
                    case_name, count=cnt, warmup=wmp,
                    instrumented=True, tag=f"paired-inst-r{irep}-{lane}")
                evidence["rows"].append({
                    "lane": lane,
                    "batch": 0,
                    "repeat": irep,
                    "case": case_name,
                    "instrumented": True,
                    "pair_order": list(lane_order),
                    **row,
                })
                measure.write_json(raw_path, evidence)

    evidence["host_after"] = measure.snapshot_host()
    evidence["finished"] = time.time()
    measure.write_json(raw_path, evidence)

    lane_summaries = {
        lane: measure.summarize_campaign(
            runners[lane].manifest,
            [r for r in evidence["rows"] if r["lane"] == lane],
        )
        for lane in ("baseline", "candidate")
    }

    comparisons = {}
    for case_name in selected_names:
        b_case = lane_summaries["baseline"]["cases"].get(case_name, {})
        c_case = lane_summaries["candidate"]["cases"].get(case_name, {})
        comp = {"meta": measure.CASE_BY_NAME[case_name]}
        if "uninstrumented" in b_case and "uninstrumented" in c_case:
            bu = b_case["uninstrumented"]
            cu = c_case["uninstrumented"]
            b_med = bu["median_us_per_op"]
            c_med = cu["median_us_per_op"]
            if not (bu["all_checksums_equal"] and cu["all_checksums_equal"] and
                    bu["checksum"] == cu["checksum"]):
                raise RuntimeError(f"unstable or mismatched paired checksum: {case_name}")
            comp["uninstrumented"] = {
                "checksum_match": bu["checksum"] == cu["checksum"],
                "baseline_median_us_per_op": b_med,
                "candidate_median_us_per_op": c_med,
                "delta_us_per_op": c_med - b_med,
                "ratio_candidate_over_baseline": (c_med / b_med) if b_med > 0 else None,
                "baseline_rtt_p50_us": bu["median_rtt_p50_us"],
                "candidate_rtt_p50_us": cu["median_rtt_p50_us"],
                "baseline_rtt_p95_us": bu["median_rtt_p95_us"],
                "candidate_rtt_p95_us": cu["median_rtt_p95_us"],
                "baseline_rtt_p99_us": bu["median_rtt_p99_us"],
                "candidate_rtt_p99_us": cu["median_rtt_p99_us"],
                "baseline_throughput_ops_per_sec": bu["median_throughput_ops_per_sec"],
                "candidate_throughput_ops_per_sec": cu["median_throughput_ops_per_sec"],
            }
            pairs = {}
            for row in evidence["rows"]:
                if row["case"] == case_name and not row["instrumented"]:
                    pairs.setdefault((row["batch"], row["repeat"]), {})[row["lane"]] = row["result"]
            paired_rows = []
            for (batch, repeat), pair in sorted(pairs.items()):
                baseline = pair["baseline"]
                candidate = pair["candidate"]
                if (baseline["operations"] != candidate["operations"] or
                    baseline["checksum"] != candidate["checksum"]):
                    raise RuntimeError(f"mismatched paired observations: {case_name}")
                before = baseline["clocks"]["us_per_op"]
                after = candidate["clocks"]["us_per_op"]
                before_fairness = baseline.get("fairness")
                after_fairness = candidate.get("fairness")
                fairness_deltas = {}
                if before_fairness is not None and after_fairness is not None:
                    for metric in measure.FAIRNESS_METRICS:
                        b_value, c_value = before_fairness[metric], after_fairness[metric]
                        fairness_deltas[metric] = (
                            c_value - b_value if b_value is not None and c_value is not None else None)
                paired_rows.append({
                    "batch": batch, "repeat": repeat, "operations": baseline["operations"],
                    "baseline_us_per_op": before, "candidate_us_per_op": after,
                    "delta_us_per_op": after - before,
                    "ratio": after / before if before > 0 else None,
                    "p99_delta_us": (candidate["distributions"]["rtt"]["p99_ns"] -
                                     baseline["distributions"]["rtt"]["p99_ns"]) / 1000,
                    "fairness_delta_ns": fairness_deltas,
                })
            deltas = [row["delta_us_per_op"] for row in paired_rows]
            ratios = [row["ratio"] for row in paired_rows if row["ratio"] is not None]
            comp["paired"] = {
                "pairs": paired_rows,
                "pair_count": len(paired_rows),
                "median_delta_us_per_op": statistics.median(deltas),
                "range_delta_us_per_op": [min(deltas), max(deltas)],
                "median_ratio": statistics.median(ratios) if ratios else None,
                "batch_median_deltas_us_per_op": {
                    str(batch): statistics.median([
                        row["delta_us_per_op"] for row in paired_rows if row["batch"] == batch])
                    for batch in range(args.batches)
                },
            }
            if case_name.startswith("mpmc_"):
                fairness_stats = {}
                for metric in measure.FAIRNESS_METRICS:
                    def values(batch=None):
                        return [
                            row["fairness_delta_ns"][metric] for row in paired_rows
                            if (batch is None or row["batch"] == batch) and
                            row["fairness_delta_ns"].get(metric) is not None]
                    observed = values()
                    fairness_stats[metric] = {
                        "pair_samples": len(observed),
                        "median_delta_ns": statistics.median(observed) if observed else None,
                        "range_delta_ns": [min(observed), max(observed)] if observed else None,
                        "batch_median_deltas_ns": {
                            str(batch): statistics.median(values(batch)) if values(batch) else None
                            for batch in range(args.batches)},
                    }
                comp["paired"]["fairness"] = fairness_stats
        if "instrumented" in b_case and "instrumented" in c_case:
            bi = b_case["instrumented"]
            ci = c_case["instrumented"]
            comp["instrumented"] = {
                "baseline_per_op": bi["per_op"],
                "candidate_per_op": ci["per_op"],
                "baseline_wait_counters": bi["wait_counters"],
                "candidate_wait_counters": ci["wait_counters"],
                "baseline_handle_counters": bi["handle_counters"],
                "candidate_handle_counters": ci["handle_counters"],
                "baseline_stage_attribution": bi["stage_attribution"],
                "candidate_stage_attribution": ci["stage_attribution"],
            }
        comparisons[case_name] = comp

    paired_summary = {
        "builds": evidence["builds"],
        "lanes": lane_summaries,
        "comparisons": comparisons,
        "quiescence_note": evidence["quiescence_note"],
        "quiescence_note_sha256": evidence["quiescence_note_sha256"],
        "host_before": evidence["host_before"],
        "host_after": evidence["host_after"],
        "raw_evidence": str(raw_path),
        "raw_evidence_sha256": measure.digest(raw_path),
    }
    summary_path = output / "PAIRED-SUMMARY.json"
    measure.write_json(summary_path, paired_summary)

    for runner in runners.values():
        runner.validate()
        runner.audit()

    print(json.dumps({"raw": str(raw_path), "summary": str(summary_path)}, indent=2))


if __name__ == "__main__":
    main()
