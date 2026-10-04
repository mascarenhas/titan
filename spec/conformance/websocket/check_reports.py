#!/usr/bin/env python3
"""Fail closed on Autobahn coverage, identity, message behavior and close behavior."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
INFORMATIONAL = frozenset(("7.1.6", "7.13.1", "7.13.2"))


class ReportError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReportError("duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"),
                          object_pairs_hook=unique_object,
                          parse_constant=lambda value: bad("invalid JSON number " + value))
    except (OSError, UnicodeError, ValueError) as error:
        raise ReportError(str(path) + ": " + str(error)) from error


def bad(message):
    raise ReportError(message)


def number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        bad(label + " must be a finite nonnegative number")
    return value


def load_manifest(path=HERE / "expected.json"):
    manifest = read_json(path)
    pins = read_json(HERE / "pins.json")
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        bad("invalid expected manifest schema")
    if manifest.get("image") != pins["image"] or manifest.get("source_revision") != pins["source_revision"]:
        bad("expected manifest runner identity differs from pins")
    all_cases = manifest.get("all_cases")
    selected = manifest.get("selected_cases")
    excluded = manifest.get("excluded_cases")
    for label, cases in (("all", all_cases), ("selected", selected), ("excluded", excluded)):
        if not isinstance(cases, list) or not cases or any(not isinstance(case, str) or
                not all(part.isdecimal() and str(int(part)) == part for part in case.split('.')) for case in cases):
            bad(label + " case manifest must be nonempty canonical dotted case IDs")
        if len(cases) != len(set(cases)):
            bad("duplicate " + label + " manifest cases")
        if cases != sorted(cases, key=lambda case: tuple(map(int, case.split('.')))):
            bad(label + " manifest cases are out of order")
    expected_excluded = [case for case in all_cases if int(case.split('.')[0]) in (12, 13)]
    expected_selected = [case for case in all_cases if int(case.split('.')[0]) not in (12, 13)]
    if excluded != expected_excluded or selected != expected_selected:
        bad("manifest must select every case except exact compression groups 12/13")
    if manifest.get("informational_cases") != sorted(INFORMATIONAL):
        bad("manifest informational policy changed")
    canonical = json.dumps(all_cases, separators=(",", ":")).encode("ascii")
    if hashlib.sha256(canonical).hexdigest() != pins.get("all_cases_sha256"):
        bad("manifest case inventory differs from pinned inventory digest")
    return manifest


def check_state(case, field, state):
    if state == "OK":
        return
    if state == "INFORMATIONAL" and case in INFORMATIONAL:
        return
    bad(case + " " + field + " rejected: " + repr(state))


def check_reports(report_dir, agent, role, manifest):
    report_dir = Path(report_dir).resolve()
    if role not in ("client", "server"):
        bad("role must be client or server")
    if not isinstance(agent, str) or not agent:
        bad("expected agent must be nonempty")
    cases = manifest["selected_cases"]
    if not cases:
        bad("empty selected manifest")
    index = read_json(report_dir / "index.json")
    if not isinstance(index, dict) or set(index) != {agent}:
        bad("report must contain exactly the expected agent " + repr(agent))
    results = index[agent]
    if not isinstance(results, dict) or set(results) != set(cases):
        actual = set(results) if isinstance(results, dict) else set()
        bad("case coverage mismatch; missing=" + repr(sorted(set(cases) - actual)) +
            "; extra=" + repr(sorted(actual - set(cases))))
    if not (report_dir / "index.html").is_file() or (report_dir / "index.html").stat().st_size == 0:
        bad("missing/empty HTML report index")
    failures = []
    durations = {}
    informational = []
    reportfiles = set()
    for ordinal, case in enumerate(cases, 1):
        try:
            result = results[case]
            if not isinstance(result, dict):
                bad(case + " missing result object")
            for field in ("behavior", "behaviorClose"):
                if field not in result:
                    bad(case + " missing " + field)
                check_state(case, field, result[field])
            filename = result.get("reportfile")
            if not isinstance(filename, str) or Path(filename).name != filename or not filename.endswith(".json"):
                bad(case + " unsafe/missing detail filename")
            if filename in reportfiles:
                bad(case + " reused detail filename")
            reportfiles.add(filename)
            detail_path = report_dir / filename
            if detail_path.is_symlink():
                bad(case + " symlink detail report")
            detail = read_json(detail_path)
            if not isinstance(detail, dict) or detail.get("agent") != agent or detail.get("id") != case:
                bad(case + " detail report identity mismatch")
            # isServer belongs to Autobahn: true means Titan was the client.
            if detail.get("isServer") is not (role == "client"):
                bad(case + " runner/testee role mismatch")
            for field in ("behavior", "behaviorClose", "duration", "remoteCloseCode"):
                if field not in result or field not in detail or result[field] != detail[field]:
                    bad(case + " index/detail disagree or omit " + field)
            number(result["duration"], case + " index duration")
            duration = number(detail["duration"], case + " duration")
            code = detail["remoteCloseCode"]
            if code is not None and (isinstance(code, bool) or not isinstance(code, int) or not 0 <= code <= 65535):
                bad(case + " invalid reported remote close code")
            if "wirelog" not in detail or not isinstance(detail["wirelog"], list):
                bad(case + " missing wire log")
            if detail.get("wasOpenHandshakeTimeout") is not False:
                bad(case + " missing/failed opening-handshake timeout state")
            html = detail_path.with_suffix(".html")
            if not html.is_file() or html.stat().st_size == 0:
                bad(case + " missing/empty detail HTML")
            durations[case] = duration
            if "INFORMATIONAL" in (result["behavior"], result["behaviorClose"]):
                informational.append(case)
        except ReportError as error:
            failures.append(str(error))
    if failures:
        bad("\n".join(failures))
    return {"agent": agent, "role": role, "selected": len(cases),
            "informational": informational, "case_duration_ms": durations,
            "sum_case_duration_ms": sum(durations.values()), "passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_dir", type=Path)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--role", choices=("client", "server"), required=True)
    parser.add_argument("--manifest", type=Path, default=HERE / "expected.json")
    args = parser.parse_args()
    try:
        summary = check_reports(args.report_dir, args.agent, args.role, load_manifest(args.manifest))
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0
    except ReportError as error:
        print("Autobahn conformance FAILED: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
