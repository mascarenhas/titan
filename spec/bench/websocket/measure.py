#!/usr/bin/env python3
"""Independent issue193 fixtures using issue196 instrumentation read-only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time

CODE = Path(__file__).resolve().parent
OWNER = "01a1054f-c6d4-7253-9868-ee6198900e08"
PAYLOADS = ("bench.titan", "run.lua", "peer.py", "measure.py")
REUSED = ("measure.py", "alloc_probe.c", "latency_probe.c", "compile_guard.lua")
SIZES = (0, 32, 4096, 65536)


def matrix():
    rows = []
    def add(**row):
        row = dict(phase="steady", kind="binary", fragment=0, cleanup="abort",
                   retain_endpoint=False, gc_stopped=False) | row
        rows.append(row)
    for transport in ("ws", "wss", "tcp", "tls"):
        for role in ("client", "server"):
            for operation in ("read", "write"):
                for size in SIZES:
                    kinds = ("binary", "text") if transport in ("ws", "wss") else ("binary",)
                    for kind in kinds:
                        for count in (0, 100, 1000):
                            add(transport=transport, role=role, operation=operation,
                                size=size, count=count, kind=kind)
            for phase in ("setup", "teardown"):
                for cleanup in (("abort", "graceful") if transport in ("ws", "wss") else ("abort",)):
                    add(transport=transport, role=role, operation="read", size=0,
                        count=0, phase=phase, cleanup=cleanup)
            for count in (0, 10, 100):
                add(transport=transport, role=role, operation="sessions", size=0,
                    count=count, phase="sessions")
            if transport in ("ws", "wss"):
                for fragment, size in ((64, 4096), (16384, 65536)):
                    for count in (0, 100, 1000):
                        add(transport=transport, role=role, operation="read", size=size,
                            fragment=fragment, count=count)
                for operation in ("ping", "read_ping"):
                    for count in (0, 100, 1000):
                        add(transport=transport, role=role, operation=operation,
                            size=32, count=count)
                for count in (0, 1000):
                    add(transport=transport, role=role, operation="read", size=65536,
                        count=count, retain_endpoint=True, gc_stopped=True)
    for count in (0, 100, 1000):
        add(transport="control", role="client", operation="read", size=0, count=count)
    for phase in ("setup", "teardown"):
        add(transport="control", role="client", operation="read", size=0, count=0, phase=phase)
    return rows


def load_helpers(repo):
    root = repo / "spec/bench/async_allocations"
    spec = importlib.util.spec_from_file_location("frozen_async_measure", root / "measure.py")
    module = importlib.util.module_from_spec(spec)
    # Import without creating __pycache__ in the shared checkout.
    old = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = old
    return root, module


def lua_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        # JSON escapes for these ASCII fixture strings are valid Lua escapes.
        return json.dumps(value, ensure_ascii=True)
    raise ValueError("unsupported fixture value")


def case_id(row):
    return "-".join(str(row[key]) for key in sorted(row))


def fairness_sufficient(result):
    return (result["wall_seconds"] >= .25 and
            result["one_ms_timer_interarrival"]["samples"] >= 100)


class Runner:
    def __init__(self, args):
        self.args = args
        self.repo = args.repo.resolve()
        self.reuse, self.helper = load_helpers(self.repo)
        self.output = args.output.resolve()
        self.work = self.output / "work"
        self.logs = self.output / "logs"
        if args.action == "build":
            if args.readiness is None:
                raise ValueError("build blocked: owner readiness receipt required")
            self.ready = json.loads(args.readiness.read_text())
            if (self.ready.get("owner_thread_id") != OWNER or
                    self.ready.get("consumer_compile_ready") is not True or
                    self.ready.get("frozen_inputs") is not True):
                raise ValueError("build blocked: owner has not confirmed exact readiness/frozen inputs")
            if self.output.exists():
                raise ValueError("choose a fresh private output directory")
            self.prefix = Path(self.ready["prefix"]).resolve()
            self.source_manifest = Path(self.ready["source_manifest"]).resolve()
            if self.helper.digest(self.source_manifest) != self.ready["source_manifest_sha256"]:
                raise ValueError("owner source manifest changed")
            if self.helper.digest(self.prefix / "lib/titan/0.6/titan.so") != self.ready["provider_sha256"]:
                raise ValueError("provider differs from owner-ready identity")
            if self.ready["optimization"] != "optimized":
                raise ValueError("optimized provider required")
            compilers = list(self.prefix.glob("lib/luarocks/rocks-*/titan/*/bin/titanc"))
            if len(compilers) != 1:
                raise ValueError("cannot select exactly one installed compiler")
            self.config = dict(prefix=str(self.prefix), compiler=str(compilers[0]),
                link_libraries=args.link_libraries,
                cc=self.helper.command_argv(self.ready["cc"]),
                ar=self.helper.command_argv(self.ready["ar"]),
                ranlib=self.helper.command_argv(self.ready["ranlib"]),
                python=str(Path(sys.executable).resolve()),
                path=os.environ.get("PATH", os.defpath))
        else:
            self.manifest = json.loads((self.output / "BUILD.json").read_text())
            self.config = self.manifest["config"]
            self.prefix = Path(self.config["prefix"])
            self.ready = self.manifest["owner_readiness"]
            self.source_manifest = Path(self.ready["source_manifest"])
        if (self.output.is_relative_to(self.prefix) or self.output.is_relative_to(self.repo)
                or self.output.is_relative_to(CODE)):
            raise ValueError("output must be outside prefix, source checkout, and harness directory")
        self.env = dict(PATH=self.config["path"], LANG="C", LC_ALL="C", TZ="UTC",
            CC=shlex.join(self.config["cc"]), AR=shlex.join(self.config["ar"]),
            RANLIB=shlex.join(self.config["ranlib"]), MAKEFLAGS="-j1", TITAN_JOBS="1",
            TITAN_PROBE_CACHE_DISABLE="1", CCACHE_DISABLE="1",
            TITAN_EXTRA_CFLAGS="-O3", TMPDIR=str(self.work / "tmp"),
            TITAN_PATH_0_6=str(self.prefix / "lib/titan/0.6"),
            LUA_PATH_5_5=f"{self.work}/?.lua;{self.prefix}/share/lua/5.5/?.lua;{self.prefix}/share/lua/5.5/?/init.lua",
            LUA_CPATH_5_5=f"{self.work}/?.so;{self.prefix}/lib/titan/0.6/?.so;{self.prefix}/lib/lua/5.5/?.so",
            MEASURE_PROBE=str(self.work / "alloc_probe.so"),
            MEASURE_LATENCY_PROBE=str(self.work / "latency_probe.so"))

    def hashes(self):
        return dict(payloads={name: self.helper.digest(CODE / name) for name in PAYLOADS},
                    reused={name: self.helper.digest(self.reuse / name) for name in REUSED})

    def command(self, label, argv, cwd=None, timeout=300, watched_peer=None):
        stem = self.logs / f"{time.time_ns()}-{label}"
        started = time.time()
        process = subprocess.Popen(argv, cwd=cwd or self.work, env=self.env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True)
        timed_out = False
        peer_failed = False
        try:
            deadline = time.monotonic() + timeout
            while True:
                if watched_peer is not None and watched_peer.poll() not in (None, 0):
                    peer_failed = True
                    if process.poll() is None: os.killpg(process.pid, signal.SIGTERM)
                    try: out, err = process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL); out, err = process.communicate()
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise subprocess.TimeoutExpired(argv, timeout)
                try:
                    out, err = process.communicate(timeout=min(.1, remaining) if watched_peer else remaining)
                    break
                except subprocess.TimeoutExpired:
                    if not watched_peer: raise
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                out, err = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                out, err = process.communicate()
        stem.with_suffix(".stdout").write_bytes(out)
        stem.with_suffix(".stderr").write_bytes(err)
        receipt = dict(argv=argv, environment=self.env, cwd=str(cwd or self.work),
            started=started, exit_code=process.returncode, timeout=timed_out,
            peer_failed_before_consumer_exit=peer_failed,
            supervisor_wall_seconds=time.time() - started, inputs=self.hashes(),
            stdout_sha256=self.helper.digest(stem.with_suffix(".stdout")),
            stderr_sha256=self.helper.digest(stem.with_suffix(".stderr")))
        self.helper.write_json(stem.with_suffix(".json"), receipt)
        if timed_out or peer_failed or process.returncode:
            raise RuntimeError(f"command failed: {stem.with_suffix('.json')}\n{err.decode(errors='replace')[-1500:]}")
        return out, str(stem.with_suffix(".json"))

    def build(self):
        self.output.mkdir(parents=True)
        self.work.mkdir(); (self.work / "tmp").mkdir(); self.logs.mkdir()
        before = self.helper.fingerprints(self.prefix, recursive=True)
        self.helper.write_json(self.output / "PREFIX-BEFORE.json", before)
        inputs = self.hashes()
        sources = self.output / "sources"; sources.mkdir()
        for name in PAYLOADS:
            shutil.copy2(CODE / name, sources / name)
        for name in REUSED:
            shutil.copy2(self.reuse / name, sources / ("reused-" + name))
        for name in ("ca.pem", "server.pem", "server-key.pem"):
            shutil.copy2(self.repo / "spec/fixtures/ssl" / name, self.work / name)
        for name in ("cc", "ar", "ranlib"):
            self.command("version-" + name, self.config[name] + ["--version"])
        self.command("version-lua", [str(self.prefix / "bin/lua"), "-v"])
        for name in ("alloc_probe", "latency_probe"):
            shared = ["-bundle", "-undefined", "dynamic_lookup"] if sys.platform == "darwin" else ["-shared"]
            self.command("compile-" + name, self.config["cc"] + ["-std=c99", "-O3",
                "-Wall", "-Wextra", "-Werror", "-fPIC"] + shared +
                [f"-I{self.prefix}/include", str(self.reuse / (name + ".c")),
                 "-o", str(self.work / (name + ".so"))])
        shutil.copy2(CODE / "bench.titan", self.work / "bench.titan")
        argv = [str(self.prefix / "bin/lua"), str(self.reuse / "compile_guard.lua"),
                self.config["compiler"], "./bench.titan", "-v", "--tree", ".", "bench"]
        if self.config["link_libraries"]:
            argv += ["-l", self.config["link_libraries"]]
        self.command("compile-bench", argv)
        if self.helper.fingerprints(self.prefix, recursive=True) != before or self.hashes() != inputs:
            raise RuntimeError("prefix or source inputs changed during build")
        manifest = dict(config=self.config, owner_readiness=self.ready, inputs=inputs,
            prefix_manifest_sha256=self.helper.digest(self.output / "PREFIX-BEFORE.json"),
            artifacts=self.helper.fingerprints(self.work, recursive=True),
            tools={name: self.helper.digest(self.config[name][0]) for name in ("cc", "ar", "ranlib")},
            python_sha256=self.helper.digest(self.config["python"]),
            lua_sha256={name:self.helper.digest(self.prefix / name) for name in ("bin/lua", "lib/liblua.a")},
            host=self.helper.snapshot_host())
        self.helper.write_json(self.output / "BUILD.json", manifest)
        return {"build":str(self.output / "BUILD.json"), "prefix_unchanged":True}

    def audit(self):
        if self.hashes() != self.manifest["inputs"]:
            raise RuntimeError("harness/reused inputs changed since build")
        if self.helper.fingerprints(self.work, recursive=True) != self.manifest["artifacts"]:
            raise RuntimeError("private consumer artifacts changed")
        before = json.loads((self.output / "PREFIX-BEFORE.json").read_text())
        if self.helper.fingerprints(self.prefix, recursive=True) != before:
            raise RuntimeError("immutable prefix changed")
        if self.helper.digest(self.source_manifest) != self.ready["source_manifest_sha256"]:
            raise RuntimeError("frozen source manifest changed")
        for name, expected in self.manifest["tools"].items():
            if self.helper.digest(self.config[name][0]) != expected:
                raise RuntimeError("tool changed")
        if self.helper.digest(self.config["python"]) != self.manifest["python_sha256"]:
            raise RuntimeError("peer Python changed")
        return {"audit": "passed"}

    def quiet(self):
        if self.args.quiet_note is None:
            raise ValueError("measurement blocked: owner-approved quiet-window note required")
        note = json.loads(self.args.quiet_note.read_text())
        if (note.get("owner_thread_id") != OWNER or note.get("measurements_allowed") is not True
                or time.time() > note["expires_unix"] or time.time() < note["starts_unix"]):
            raise ValueError("measurement blocked: quiet-window approval missing/expired")
        path = self.logs / f"{time.time_ns()}-quiet.json"
        self.helper.write_json(path, dict(note=note, host=self.helper.snapshot_host()))

    def allocation_authorization(self):
        if (self.ready.get("owner_thread_id") != OWNER or
                self.ready.get("allocations_ready") is not True):
            raise ValueError("allocation run blocked: explicit owner runtime/allocation readiness required")
        path = self.logs / f"{time.time_ns()}-allocation-authorization.json"
        self.helper.write_json(path, dict(owner_readiness=self.ready,
            host=self.helper.snapshot_host(), quiet_timing_authorized=False))

    def run(self, row, instrumented=True):
        if instrumented: self.allocation_authorization()
        else: self.quiet()
        # Fast identities each row, full immutable prefix audit at batch boundaries.
        if self.hashes() != self.manifest["inputs"]:
            raise RuntimeError("measurement inputs changed")
        for name, expected in self.manifest["lua_sha256"].items():
            if self.helper.digest(self.prefix / name) != expected:
                raise RuntimeError("Lua changed")
        if self.helper.digest(self.prefix / "lib/titan/0.6/titan.so") != self.ready["provider_sha256"]:
            raise RuntimeError("provider changed")
        lane = self.output / "cases" / str(time.time_ns()); lane.mkdir(parents=True)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0)); port = reservation.getsockname()[1]
        config = dict(row, instrumented=instrumented, port=port,
            ca=str(self.work / "ca.pem"), certificate=str(self.work / "server.pem"),
            key=str(self.work / "server-key.pem"), go_marker=str(lane / "go"),
            listen_marker=str(lane / "listening"), preload_marker=str(lane / "preloaded"))
        self.helper.write_json(lane / "case.json", config)
        (lane / "case.lua").write_text("return {\n" + ",\n".join(
            f"[{lua_value(key)}]={lua_value(value)}" for key,value in config.items()) + "\n}\n")
        peer = None
        peer_out = (lane / "peer.stdout").open("wb")
        peer_err = (lane / "peer.stderr").open("wb")
        argv = [self.config["python"], str(CODE / "peer.py"), str(lane / "case.json")]
        try:
            if row["transport"] != "control":
                peer = subprocess.Popen(argv, cwd=lane, env=self.env, stdin=subprocess.DEVNULL,
                    stdout=peer_out, stderr=peer_err, start_new_session=True)
                if row["role"] == "client":
                    deadline = time.monotonic() + 10
                    while not (lane / "listening").exists():
                        if peer.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError(f"peer did not listen; logs in {lane}")
                        time.sleep(0.001)
            stdout, receipt = self.command("consumer", [str(self.prefix / "bin/lua"),
                str(CODE / "run.lua"), str(lane / "case.lua")], timeout=180, watched_peer=peer)
            if peer is not None:
                peer.wait(timeout=10)
                if peer.returncode:
                    raise RuntimeError(f"raw peer rejected run; logs in {lane}")
        finally:
            if peer is not None and peer.poll() is None:
                os.killpg(peer.pid, signal.SIGTERM)
                try: peer.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(peer.pid, signal.SIGKILL); peer.wait()
            peer_out.close(); peer_err.close()
            self.helper.write_json(lane / "peer-receipt.json", dict(argv=argv, environment=self.env,
                exit_code=peer.returncode if peer else None, fixture_sha256=self.helper.digest(lane / "case.json"),
                stdout_sha256=self.helper.digest(lane / "peer.stdout"),
                stderr_sha256=self.helper.digest(lane / "peer.stderr")))
        result = json.loads(stdout)
        if sys.platform == "darwin": result["process_peak_rss_kib"] /= 1024
        return dict(case=row, result=result, consumer_receipt=receipt, peer_receipt=str(lane / "peer-receipt.json"))

    def allocations(self):
        self.audit(); self.allocation_authorization()
        rows = []
        path = self.output / f"allocations-{time.time_ns()}.json"
        plan = matrix()
        if self.args.limit: plan = plan[:self.args.limit]
        for row in plan:
            rows.append(self.run(row))
            self.helper.write_json(path, dict(planned=len(plan), completed=len(rows), rows=rows))
            print(f"{len(rows)}/{len(plan)} {case_id(row)}", file=sys.stderr, flush=True)
        self.audit()
        return {"allocations":str(path), "completed":len(rows)}

    def timing(self):
        self.audit(); self.quiet()
        base = dict(role=self.args.role, operation=self.args.operation, size=self.args.size,
            kind="binary", fragment=0, phase="steady", cleanup="abort", retain_endpoint=False,
            gc_stopped=False)
        other = "tls" if self.args.transport == "wss" else "tcp"
        lanes = [dict(base, transport=self.args.transport), dict(base, transport=other)]
        pilot, count = [], 100
        while True:
            times = []
            for lane in lanes:
                row = self.run(dict(lane, count=count), False)
                pilot.append(row); times.append(row["result"]["body_wall_seconds"])
            if min(times) >= .25 or count >= self.args.max_count: break
            count = min(self.args.max_count, max(count + 1, count * 2))
        warmups = [self.run(dict(lane, count=count), False) for lane in lanes]
        measured = []
        for repeat in range(7):
            for index in ((0,1) if repeat % 2 == 0 else (1,0)):
                measured.append(dict(repeat=repeat, lane=index,
                    **self.run(dict(lanes[index], count=count), False)))
        summaries = []
        for index in (0,1):
            rows = [r["result"] for r in measured if r["lane"] == index]
            summaries.append(dict(transport=lanes[index]["transport"], count=count,
                wall_median=statistics.median(r["body_wall_seconds"] for r in rows),
                wall_range=[min(r["body_wall_seconds"] for r in rows),max(r["body_wall_seconds"] for r in rows)],
                cpu_median=statistics.median(r["body_cpu_seconds"] for r in rows),
                cpu_range=[min(r["body_cpu_seconds"] for r in rows),max(r["body_cpu_seconds"] for r in rows)],
                short_samples=any(r["body_wall_seconds"] < .25 for r in rows)))
        path = self.output / f"timing-{time.time_ns()}.json"
        self.helper.write_json(path, dict(calibration=pilot, warmup=warmups, measured=measured, summaries=summaries))
        self.audit()
        return {"timing":str(path), "summaries":summaries}

    def fairness(self):
        self.audit(); self.quiet()
        rows = []
        for tasks in (1,16,64,256):
            count, cap = 1000, min(200000, 4000000 // tasks - 1)
            while True:
                row = dict(transport=self.args.transport, role=self.args.role, operation="fairness",
                    size=32, count=count, kind="binary", fragment=0, phase="steady", cleanup="abort",
                    retain_endpoint=False, gc_stopped=False, tasks=tasks)
                result = self.run(row, False)
                fairness = result["result"]["fairness"]
                sufficient = fairness_sufficient(fairness)
                rows.append(dict(calibration=not sufficient and count < cap,
                                 sufficient_samples=sufficient, **result))
                if sufficient or count == cap: break
                count = min(cap, count * 2)
        path = self.output / f"fairness-{time.time_ns()}.json"
        self.helper.write_json(path, dict(rows=rows))
        self.audit()
        return {"fairness":str(path), "sufficient":all(r["sufficient_samples"] for r in rows if not r["calibration"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan","build","audit","allocations","timing","fairness"))
    parser.add_argument("--repo", type=Path, default=Path("/var/home/mascarenhas/Code/titan"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--readiness", type=Path)
    parser.add_argument("--quiet-note", type=Path)
    parser.add_argument("--link-libraries", default="pthread,rt,ssl,crypto")
    parser.add_argument("--transport", choices=("ws","wss"), default="ws")
    parser.add_argument("--role", choices=("client","server"), default="client")
    parser.add_argument("--operation", choices=("read","write"), default="write")
    parser.add_argument("--size", type=int, choices=SIZES, default=32)
    parser.add_argument("--max-count", type=int, default=100000)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if args.action == "plan":
        print(json.dumps(dict(planned=len(matrix()), cases=matrix()), indent=2)); return
    if args.output is None: parser.error("--output required")
    runner = Runner(args)
    print(json.dumps(getattr(runner, args.action)(), indent=2))


if __name__ == "__main__":
    main()
