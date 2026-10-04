#!/usr/bin/env python3
"""Bounded no-network cleanup diagnostic using an existing private consumer."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import measure

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--repo", type=Path, required=True)
args = parser.parse_args()
args.action = "audit"
args.quiet_note = None
runner = measure.Runner(args)
if runner.ready.get("allocations_ready") is not True:
    raise ValueError("cleanup regression requires explicit owner runtime authorization")
original_inputs = runner.manifest["inputs"]
assert runner.hashes()["reused"] == original_inputs["reused"]
assert runner.hashes()["payloads"]["bench.titan"] == original_inputs["payloads"]["bench.titan"]
prefix_before = runner.helper.fingerprints(runner.prefix, recursive=True)
assert prefix_before == json.loads((runner.output / "PREFIX-BEFORE.json").read_text())
artifacts_before = runner.helper.fingerprints(runner.work, recursive=True)
assert artifacts_before == runner.manifest["artifacts"]
out = runner.output / ("cleanup-regression-" + str(time.time_ns()))
out.mkdir()
runner.logs = out / "logs"
runner.logs.mkdir()
rows = []
base = dict(transport="control", role="client", operation="read", count=0,
    port=0, size=0, kind="binary", cleanup="abort", ca="", certificate="", key="",
    preload_marker="", retain_endpoint=False, instrumented=True)
for stopped in (False, True):
    for scenario in ("api_guard", "task_before_body_stop", "task_after_body_stop"):
        lane = out / f"{scenario}-gc-stopped-{stopped}"
        lane.mkdir()
        config = base | dict(phase="setup" if scenario == "api_guard" else "steady",
                            gc_stopped=stopped)
        if scenario == "api_guard": config["port"] = "intentional-wrong-type"
        script = measure.CODE / "run.lua"
        if scenario != "api_guard":
            script = lane / "inject.lua"
            script.write_text("local async = require 'titan.async'\n"
                "package.loaded['bench'] = {launch=function(...)\n"
                "  local argv = {...}\n"
                "  return async.run(function()\n"
                "    argv[14](nil)\n" +
                ("    argv[15]()\n" if scenario == "task_after_body_stop" else "") +
                "    error('intentional active-probe Task failure')\n"
                "  end)\n"
                "end}\n"
                f"dofile({measure.lua_value(str(measure.CODE / 'run.lua'))})\n")
        case = lane / "case.lua"
        case.write_text("return {\n" + ",\n".join(
            f"[{measure.lua_value(k)}]={measure.lua_value(v)}" for k,v in config.items()) + "\n}\n")
        before_receipts = set(runner.logs.glob("*.json"))
        try:
            runner.command(scenario, [str(runner.prefix / "bin/lua"), str(script), str(case)], timeout=15)
        except RuntimeError:
            pass
        else:
            raise AssertionError("intentional failure unexpectedly succeeded")
        receipt_path, = set(runner.logs.glob("*.json")) - before_receipts
        receipt = json.loads(receipt_path.read_text())
        stderr = receipt_path.with_suffix(".stderr").read_text()
        assert receipt["exit_code"] == 1 and not receipt["timeout"], receipt_path
        if scenario == "api_guard": assert "expected integer but found string" in stderr
        else: assert "intentional active-probe Task failure" in stderr
        assert "allocator cleanup failed" not in stderr
        rows.append(dict(scenario=scenario, gc_stopped=stopped, expected_exit=1,
                         receipt=str(receipt_path), passed=True))

for phase in ("setup", "steady", "teardown"):
    case = out / (phase + "-success.lua")
    config = base | dict(phase=phase, gc_stopped=False)
    case.write_text("return {\n" + ",\n".join(
        f"[{measure.lua_value(k)}]={measure.lua_value(v)}" for k,v in config.items()) + "\n}\n")
    stdout, receipt = runner.command(phase + "-success", [str(runner.prefix / "bin/lua"),
        str(measure.CODE / "run.lua"), str(case)], timeout=15)
    result = json.loads(stdout)
    assert result["postgc_ledger_error_bytes"] == 0
    rows.append(dict(scenario=phase + "-success", receipt=receipt, passed=True))

assert runner.helper.fingerprints(runner.prefix, recursive=True) == prefix_before
assert runner.helper.fingerprints(runner.work, recursive=True) == artifacts_before
runner.helper.write_json(out / "RESULT.json", dict(passed=len(rows), rows=rows,
    kind="no-network cleanup diagnostic, not accepted allocation/performance evidence",
    original_build=str(runner.output / "BUILD.json"),
    original_build_sha256=runner.helper.digest(runner.output / "BUILD.json"),
    regression_source_sha256=runner.helper.digest(Path(__file__)),
    compiled_artifacts_unchanged=True, full_prefix_unchanged=True,
    original_inputs=original_inputs, diagnostic_inputs=runner.hashes(),
    owner_readiness=runner.ready, allocations_ready=runner.ready.get("allocations_ready", False)))
print(json.dumps(dict(result=str(out / "RESULT.json"), passed=len(rows), prefix_unchanged=True)))
