#!/usr/bin/env python3
"""Paired uninstrumented measurements; run only after all builds are quiet."""
import argparse
import json
from pathlib import Path
import statistics
import sys
import time

sys.dont_write_bytecode = True
import measure

TIMING_CASES = ("inline_success_nil", "yield", "yield_observed", "fs_stat",
                "fs_write", "os_write", "timer_sleep", "subscription_next",
                "cancel_queued", "cancel_running")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path, help="built harness output directory")
    parser.add_argument("--candidate", required=True, type=Path, help="built harness output directory")
    parser.add_argument("--output", required=True, type=Path, help="new comparison evidence directory")
    parser.add_argument("--quiescence-note", required=True, type=Path,
                        help="dated note confirming local and VM builds are finished")
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--target-seconds", type=float, default=0.1)
    parser.add_argument("--max-count", type=int, default=100000)
    parser.add_argument("--cases", default=",".join(TIMING_CASES))
    parser.add_argument("--skip-latency", action="store_true")
    args = parser.parse_args()
    if args.repeats < 1 or args.max_count < 1 or args.target_seconds <= 0:
        raise ValueError("repeats, count and target duration must be positive")
    cases = args.cases.split(",")
    if not cases or any(case not in measure.CASES for case in cases):
        raise ValueError("unknown workload")
    note = args.quiescence_note.read_text()
    if not note.strip():
        raise ValueError("quiescence note is empty")
    args.output = args.output.expanduser().resolve()
    runners = {name: measure.Runner(measure.parser().parse_args(["--output", str(path), "run"]))
               for name, path in (("baseline", args.baseline), ("candidate", args.candidate))}
    for runner in runners.values():
        runner.validate()
    baseline, candidate = (runners[name].manifest for name in ("baseline", "candidate"))
    for field in ("payload_sha256", "helper_sha256", "tools", "platform", "lua_sha256"):
        if baseline[field] != candidate[field]:
            raise ValueError(f"comparison inputs differ: {field}")
    for field in ("link_libraries", "titan_cflags", "fixture", "path"):
        if baseline["config"][field] != candidate["config"][field]:
            raise ValueError(f"comparison build policy differs: {field}")
    if baseline["fixture_sha256"] != candidate["fixture_sha256"]:
        raise ValueError("comparison fixture bytes differ")
    if args.output.is_relative_to(measure.CODE) or any(
            args.output.is_relative_to(runner.prefix) or args.output.is_relative_to(runner.output)
            for runner in runners.values()):
        raise ValueError("comparison output must be outside prefixes, harness sources and lane outputs")
    args.output.mkdir(parents=True, exist_ok=False)
    evidence = {"started": time.time(), "quiescence_note": note,
                "quiescence_note_sha256": measure.digest(args.quiescence_note),
                "host_before": measure.snapshot_host(), "rows": [], "plans": [],
                "builds": {name: {"path": str(runner.manifest_path),
                                   "sha256": measure.digest(runner.manifest_path)}
                           for name, runner in runners.items()}}
    raw = args.output / "PAIRED.json"

    def save_row(kind, lane, key, row, repeat=None):
        evidence["rows"].append(dict(kind=kind, lane=lane, key=key, repeat=repeat, **row))
        measure.write_json(raw, evidence)
        return row["result"]

    for host in ("lua", "typed"):
        for case in cases:
            count = min(1000, args.max_count)
            while True:
                samples = {lane: save_row("pilot", lane, [host, case, count],
                                         runners[lane].run(case, count, host, timing=True))
                           for lane in ("baseline", "candidate")}
                duration = min(sample["body_wall_seconds"] for sample in samples.values())
                if duration >= args.target_seconds or count == args.max_count:
                    break
                count = min(count * 10, args.max_count)
            evidence["plans"].append(dict(host=host, case=case, count=count,
                                          target_seconds=args.target_seconds,
                                          short_pilot={lane: sample["body_wall_seconds"] < args.target_seconds
                                                       for lane, sample in samples.items()}))
            for lane in ("baseline", "candidate"):
                save_row("warmup", lane, [host, case, count],
                         runners[lane].run(case, count, host, timing=True))
            for repeat in range(args.repeats):
                order = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
                for lane in order:
                    save_row("timing", lane, [host, case, count],
                             runners[lane].run(case, count, host, timing=True), repeat)

    if not args.skip_latency:
        for tasks in (1, 16, 64, 256):
            iterations = 1000
            maximum = min(1000000, 4000000 // tasks)
            while True:
                samples = {lane: save_row("latency-pilot", lane, [tasks, iterations],
                                         runners[lane].latency(tasks, iterations))
                           for lane in ("baseline", "candidate")}
                adequate = {lane: (sample["wall_seconds"] >= 0.25
                                    and sample["one_ms_timer_interarrival"]["samples"] >= 100)
                            for lane, sample in samples.items()}
                if all(adequate.values()) or iterations == maximum:
                    break
                iterations = min(iterations * 4, maximum)
            evidence["plans"].append(dict(tasks=tasks, iterations=iterations,
                                          insufficient_pilot={lane: not valid for lane, valid in adequate.items()}))
            for lane in ("baseline", "candidate"):
                save_row("latency-warmup", lane, [tasks, iterations],
                         runners[lane].latency(tasks, iterations))
            for repeat in range(args.repeats):
                order = ("baseline", "candidate") if repeat % 2 == 0 else ("candidate", "baseline")
                for lane in order:
                    row = runners[lane].latency(tasks, iterations)
                    row["insufficient_samples"] = (row["result"]["wall_seconds"] < 0.25
                                                   or row["result"]["one_ms_timer_interarrival"]["samples"] < 100)
                    save_row("latency", lane, [tasks, iterations], row, repeat)
    evidence["host_after"] = measure.snapshot_host()
    evidence["finished"] = time.time()
    measure.write_json(raw, evidence)
    summary = []
    for plan in evidence["plans"]:
        if "host" not in plan:
            continue
        key = [plan["host"], plan["case"], plan["count"]]
        row = dict(plan)
        for lane in runners:
            samples = [entry["result"] for entry in evidence["rows"]
                       if entry["kind"] == "timing" and entry["lane"] == lane and entry["key"] == key]
            row[lane] = {clock: {"median": statistics.median(values), "min": min(values), "max": max(values)}
                         for clock in ("body_wall_seconds", "body_cpu_seconds")
                         for values in [[sample[clock] for sample in samples]]}
            row[lane]["short_sample"] = any(sample["body_wall_seconds"] < plan["target_seconds"]
                                             for sample in samples)
        summary.append(row)
    measure.write_json(args.output / "TIMING-SUMMARY.json", summary)
    for runner in runners.values():
        runner.validate()
        runner.audit()
    print(json.dumps({"raw": str(raw), "summary": str(args.output / "TIMING-SUMMARY.json")}, indent=2))


if __name__ == "__main__":
    main()
