#!/usr/bin/env python3
"""Summarize instrumented receipts; never treat these clocks as timing results."""
import argparse
import json
from pathlib import Path

FIELDS = ("userdata", "functions", "strings", "tables", "requested_bytes", "allocations")


def summarize(document):
    if document["completed"] != document["planned"] or len(document["rows"]) != document["completed"]:
        raise ValueError("incomplete allocation run")
    groups, snapshots = {}, []
    for row in document["rows"]:
        case, result = row["case"], row["result"]
        if result["instrumented"] != 1 or result["postgc_ledger_error_bytes"] != 0:
            raise ValueError("not a valid instrumented allocation row")
        snapshot = dict(case=case, initial_lua_bytes=result["initial_live_bytes"],
            body=result["body"], after_close=result["teardown"], after_gc=result["postgc"],
            lua_peak_growth=result["teardown"]["peak_live_bytes"] - result["initial_live_bytes"],
            lua_after_gc_growth=result["postgc"]["live_bytes"] - result["initial_live_bytes"],
            process_whole_lifetime_peak_rss_kib=result["process_peak_rss_kib"],
            endpoint_collected_after_release=result["endpoint_collected_after_release"],
            consumer_receipt=row["consumer_receipt"], peer_receipt=row["peer_receipt"])
        snapshots.append(snapshot)
        if case["phase"] != "steady" or case["gc_stopped"]:
            continue
        key = json.dumps({k:v for k,v in case.items() if k != "count"}, sort_keys=True)
        group = groups.setdefault(key, {})
        if case["count"] in group:
            raise ValueError("duplicate case count")
        group[case["count"]] = result["body"]
    slopes = []
    for key, counts in groups.items():
        if set(counts) != {0,100,1000}:
            raise ValueError("steady allocation group lacks 0/100/1000 rows")
        slopes.append(dict(case=json.loads(key), zero_body=counts[0],
            per_operation_0_to_100={field:(counts[100][field]-counts[0][field])/100 for field in FIELDS},
            per_operation_100_to_1000={field:(counts[1000][field]-counts[100][field])/900 for field in FIELDS}))
    return dict(slopes=slopes, snapshots=snapshots,
        limitations=["Instrumented clocks are excluded from timing conclusions.",
            "Lua allocator traffic excludes native allocation and coroutine stacks.",
            "RSS high-water is whole-process lifetime, not per-operation or native-only memory.",
            "Weak endpoint collection does not prove release of every internal context."])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(json.loads(args.input.read_text())), indent=2))
