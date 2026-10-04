#!/usr/bin/env python3
"""Explicit-prefix, read-only-provider async measurement runner (Python 3.11+)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import time

CODE = Path(__file__).resolve().parent
PAYLOADS = ("alloc_probe.c", "bench.titan", "bench.lua", "run.lua",
            "latency_probe.c", "latency.titan", "latency.lua")
HELPERS = ("measure.py", "compare.py", "compile_guard.lua")
CASES = ("control", "inline_success_nil", "inline_error_nil",
         "inline_success_false", "inline_error_false", "cleanup_inline",
         "yield", "yield_observed", "fs_stat", "fs_reject", "fs_write",
         "os_write", "cleanup_close", "timer_sleep", "subscription_setup",
         "subscription_next", "cancel_queued", "cancel_running")
STOPPED_CASES = ("control", "yield", "fs_stat", "os_write", "timer_sleep",
                 "subscription_next")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


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


def snapshot_host():
    result = {"platform": platform.platform(), "machine": platform.machine(),
              "cpu_count": os.cpu_count(), "load_average": os.getloadavg()}
    if hasattr(os, "sched_getaffinity"):
        result["cpu_affinity"] = sorted(os.sched_getaffinity(0))
    # Excludes command-line arguments, which can contain unrelated secrets.
    result["processes"] = subprocess.run(
        ["ps", "-eo", "pid,ppid,comm,time,pcpu"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False).stdout
    return result


class Runner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.expanduser().resolve()
        self.work = self.output / "work"
        self.logs = self.output / "logs"
        self.manifest_path = self.output / "BUILD.json"
        self.manifest = None
        if args.action != "build":
            self.manifest = json.loads(self.manifest_path.read_text())
            self.config = self.manifest["config"]
        else:
            if self.output.exists():
                raise ValueError("build output already exists; choose a fresh output directory")
            if args.prefix is None:
                raise ValueError("build requires --prefix")
            prefix = args.prefix.expanduser().resolve()
            if args.compiler_script:
                compiler = args.compiler_script.expanduser().resolve()
            else:
                matches = list(prefix.glob("lib/luarocks/rocks-*/titan/*/bin/titanc"))
                if len(matches) != 1:
                    raise ValueError("cannot select one installed compiler; pass --compiler-script")
                compiler = matches[0]
            fixture = (args.fixture.expanduser().resolve() if args.fixture
                       else self.output / "fixture.txt")
            self.config = dict(prefix=str(prefix), compiler_script=str(compiler),
                               fixture=str(fixture), cc=command_argv(args.cc),
                               ar=command_argv(args.ar), ranlib=command_argv(args.ranlib),
                               path=os.environ.get("PATH", os.defpath),
                               link_libraries=args.link_libraries,
                               titan_cflags=args.titan_cflags,
                               source_manifest=(str(args.source_manifest.resolve())
                                                if args.source_manifest else None))
        self.prefix = Path(self.config["prefix"]).resolve()
        fixture = Path(self.config["fixture"]).resolve()
        if self.output.is_relative_to(self.prefix) or fixture.is_relative_to(self.prefix):
            raise ValueError("output and fixture must be outside the read-only prefix")
        if self.output.is_relative_to(CODE):
            raise ValueError("output must be outside the harness source directory")
        if args.action == "build":
            if self.config["source_manifest"] and not Path(self.config["source_manifest"]).is_file():
                raise ValueError("source manifest does not exist")
            self.output.mkdir(parents=True, exist_ok=False)
            self.work.mkdir()
            (self.work / "tmp").mkdir()
            self.logs.mkdir()
            if not fixture.exists():
                fixture.write_text("Titan async allocation measurement fixture.\n")
        if not fixture.is_file():
            raise ValueError("fixture must be a regular file")
        if Path(str(fixture) + ".missing").exists():
            raise ValueError("the fs_reject fixture pathname already exists")
        self.lua = self.prefix / "bin/lua"
        self.env = self.environment()

    def environment(self):
        env = {"PATH": self.config["path"] if "path" in self.config else os.defpath,
               "LANG": "C", "TZ": "UTC"}
        env.update(LC_ALL="C", CC=shlex.join(self.config["cc"]),
                   AR=shlex.join(self.config["ar"]), RANLIB=shlex.join(self.config["ranlib"]),
                   MAKEFLAGS="-j1", TITAN_JOBS="1", TITAN_PROBE_CACHE_DISABLE="1",
                   CCACHE_DISABLE="1",
                   TITAN_PATH_0_6=str(self.prefix / "lib/titan/0.6"),
                   LUA_PATH_5_5=f"{self.work}/?.lua;{self.prefix}/share/lua/5.5/?.lua;{self.prefix}/share/lua/5.5/?/init.lua",
                   LUA_CPATH_5_5=f"{self.work}/?.so;{self.prefix}/lib/titan/0.6/?.so;{self.prefix}/lib/lua/5.5/?.so",
                   MEASURE_PROBE=str(self.work / "alloc_probe.so"),
                   MEASURE_LUA_BENCH=str(CODE / "bench.lua"),
                   MEASURE_FIXTURE=self.config["fixture"],
                   MEASURE_LATENCY_PROBE=str(self.work / "latency_probe.so"),
                   TMPDIR=str(self.work / "tmp"))
        if self.config["titan_cflags"]:
            env["TITAN_EXTRA_CFLAGS"] = self.config["titan_cflags"]
        return env

    def command(self, label, argv, timeout=120, allow_failure=False):
        stem = self.logs / f"{time.time_ns()}-{label}"
        started = time.time()
        process = subprocess.Popen(argv, cwd=self.work, env=self.env,
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
        stdout, stderr = stem.with_suffix(".stdout"), stem.with_suffix(".stderr")
        stdout.write_bytes(out)
        stderr.write_bytes(err)
        receipt = dict(argv=argv, cwd=str(self.work), started=started,
                       wall_seconds=time.time() - started, exit_code=process.returncode,
                       timeout=timed_out, stdout_sha256=digest(stdout),
                       stderr_sha256=digest(stderr),
                       payload_sha256={name: digest(CODE / name) for name in PAYLOADS},
                       helper_sha256={name: digest(CODE / name) for name in HELPERS},
                       runner_sha256=digest(Path(__file__)),
                       build_sha256=(digest(self.manifest_path) if self.manifest else None),
                       environment=self.env)
        receipt_path = stem.with_suffix(".json")
        write_json(receipt_path, receipt)
        if timed_out or (process.returncode and not allow_failure):
            raise RuntimeError(f"command failed; receipt: {receipt_path}\n{err.decode(errors='replace')[-2500:]}")
        return out, str(receipt_path)

    def build(self):
        before = fingerprints(self.prefix, recursive=True)
        write_json(self.output / "PREFIX-BEFORE.json", before)
        sources = self.output / "sources"
        sources.mkdir()
        for name in PAYLOADS + HELPERS:
            shutil.copy2(CODE / name, sources / name)
        for name in ("cc", "ar", "ranlib"):
            self.command("version-" + name, self.config[name] + ["--version"], allow_failure=True)
        self.command("version-lua", [str(self.lua), "-v"])
        shared = ["-bundle", "-undefined", "dynamic_lookup"] if sys.platform == "darwin" else ["-shared"]
        for module in ("alloc_probe", "latency_probe"):
            self.command("compile-" + module,
                         self.config["cc"] + ["-std=c99", "-O3", "-Wall", "-Wextra", "-Werror", "-fPIC"]
                         + shared + [f"-I{self.prefix}/include", str(CODE / (module + ".c")),
                                     "-o", str(self.work / (module + ".so"))], 300)
        for module in ("bench", "latency"):
            shutil.copy2(CODE / (module + ".titan"), self.work / (module + ".titan"))
            argv = [str(self.lua), str(CODE / "compile_guard.lua"), self.config["compiler_script"],
                    str(self.work / (module + ".titan")), "-v", "--tree", str(self.work), module]
            if self.config["link_libraries"]:
                argv += ["-l", self.config["link_libraries"]]
            self.command("compile-" + module, argv, 300)
        after = fingerprints(self.prefix, recursive=True)
        if before != after:
            write_json(self.output / "PREFIX-CHANGED.json", after)
            raise RuntimeError("build modified the supplied prefix")
        selected = [self.lua, Path(self.config["compiler_script"])]
        selected += [self.prefix / "lib/titan/0.6" / name for name in ("titan.so", "titan.a", "libtitan.a")]
        self.manifest = dict(config=self.config, platform=platform.platform(),
                             payload_sha256={name: digest(CODE / name) for name in PAYLOADS},
                             helper_sha256={name: digest(CODE / name) for name in HELPERS},
                             runner_sha256=digest(Path(__file__)),
                             fixture_sha256=digest(self.config["fixture"]),
                             artifacts=fingerprints(self.work, recursive=True),
                             lua_sha256={name: digest(self.prefix / name)
                                         for name in ("bin/lua", "lib/liblua.a")},
                             provider_files={str(path): digest(path) for path in selected if path.exists()},
                             tools={name: {"argv": self.config[name],
                                           "executable_sha256": digest(Path(self.config[name][0]).resolve())}
                                    for name in ("cc", "ar", "ranlib")},
                             source_manifest_sha256=(digest(self.config["source_manifest"])
                                                     if self.config["source_manifest"] else None),
                             prefix_before_sha256=digest(self.output / "PREFIX-BEFORE.json"))
        write_json(self.manifest_path, self.manifest)
        return {"build": str(self.manifest_path), "prefix_unchanged": True}

    def validate(self):
        actual = {name: digest(CODE / name) for name in PAYLOADS}
        if actual != self.manifest["payload_sha256"]:
            raise RuntimeError("measurement payload changed after build; use a new output directory")
        if {name: digest(CODE / name) for name in HELPERS} != self.manifest["helper_sha256"]:
            raise RuntimeError("measurement runner changed after build; use a new output directory")
        if fingerprints(self.work, recursive=True) != self.manifest["artifacts"]:
            raise RuntimeError("built measurement artifact changed")
        for path, expected in self.manifest["provider_files"].items():
            if digest(path) != expected:
                raise RuntimeError(f"provider changed after build: {path}")
        for name, expected in self.manifest["lua_sha256"].items():
            if digest(self.prefix / name) != expected:
                raise RuntimeError(f"Lua changed after build: {name}")
        if Path(self.config["fixture"] + ".missing").exists():
            raise RuntimeError("the fs_reject fixture pathname exists")
        self.validate_fixture()

    def validate_fixture(self):
        if digest(self.config["fixture"]) != self.manifest["fixture_sha256"]:
            raise RuntimeError("fixture changed after build")

    def run(self, case, count, host, gc="running", timing=False, scope="body"):
        self.validate_fixture()
        argv = [str(self.lua), str(CODE / "run.lua"), case, str(count), host,
                "0" if timing else "1", "1" if gc == "stopped" else "0", scope]
        output, receipt = self.command(f"{host}-{case}-{count}-{gc}-{scope}-{'timing' if timing else 'alloc'}", argv)
        result = json.loads(output)
        if sys.platform == "darwin":
            # macOS ru_maxrss is bytes; Linux reports KiB. Probe bytes stay identical.
            result["process_peak_rss_kib"] /= 1024
        return {"result": result, "receipt": receipt}

    def matrix(self):
        plan = [(case, count, host, "running", False, "body")
                for host in ("lua", "typed") for case in CASES for count in (0, 100, 1000)]
        for host in ("lua", "typed"):
            plan.append(("control", 0, host, "running", False, "whole"))
            plan.extend((case, 1000, host, "stopped", False, "body") for case in STOPPED_CASES)
        path = self.output / f"matrix-{time.time_ns()}.json"
        rows = []
        for index, entry in enumerate(plan, 1):
            rows.append(self.run(*entry))
            write_json(path, {"planned": len(plan), "completed": index, "rows": rows})
            print(f"{index}/{len(plan)} {' '.join(map(str, entry))}", file=sys.stderr, flush=True)
        self.validate()
        return {"matrix": str(path), "passed": len(rows)}

    def latency(self, tasks, iterations):
        output, receipt = self.command(f"latency-{tasks}-{iterations}",
                                      [str(self.lua), str(CODE / "latency.lua"), str(tasks), str(iterations)])
        return {"result": json.loads(output), "receipt": receipt}

    def audit(self):
        before = json.loads((self.output / "PREFIX-BEFORE.json").read_text())
        after = fingerprints(self.prefix, recursive=True)
        path = self.output / f"prefix-audit-{time.time_ns()}.json"
        changes = [name for name in sorted(before.keys() | after.keys()) if before.get(name) != after.get(name)]
        write_json(path, dict(files=len(after), unchanged=not changes, changed=changes))
        if changes:
            raise RuntimeError(f"prefix changed; audit: {path}")
        return {"audit": str(path), "unchanged": True, "files": len(after)}


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--output", required=True, type=Path, help="private output; fresh for build")
    result.add_argument("--prefix", type=Path, help="existing installed Titan prefix; build only")
    result.add_argument("--compiler-script", type=Path, help="underlying compiler Lua script, not wrapper")
    result.add_argument("--fixture", type=Path, help="shared stat fixture pathname; create only if absent")
    result.add_argument("--source-manifest", type=Path, help="optional frozen source-manifest provenance")
    result.add_argument("--cc", default=os.environ.get("CC", "cc"))
    result.add_argument("--ar", default=os.environ.get("AR", "ar"))
    result.add_argument("--ranlib", default=os.environ.get("RANLIB", "ranlib"))
    result.add_argument("--link-libraries", default="", help="explicit comma-separated final libraries")
    result.add_argument("--titan-cflags", default="", help="explicit generated-consumer flag additions")
    actions = result.add_subparsers(dest="action", required=True)
    actions.add_parser("build")
    actions.add_parser("matrix")
    actions.add_parser("audit")
    run = actions.add_parser("run")
    run.add_argument("--case", choices=CASES, default="yield")
    run.add_argument("--count", type=int, default=1000)
    run.add_argument("--host", choices=("lua", "typed"), default="typed")
    run.add_argument("--gc", choices=("running", "stopped"), default="running")
    run.add_argument("--scope", choices=("body", "whole"), default="body")
    run.add_argument("--timing-only", action="store_true")
    latency = actions.add_parser("latency")
    latency.add_argument("--tasks", type=int, default=64)
    latency.add_argument("--iterations", type=int, default=1000)
    return result


def main():
    args = parser().parse_args()
    if sys.platform not in ("linux", "darwin"):
        raise ValueError("this POSIX harness currently supports Linux and macOS")
    runner = Runner(args)
    if args.action == "build":
        result = runner.build()
    else:
        runner.validate()
        if args.action == "run":
            if args.count < 0:
                raise ValueError("count must be nonnegative")
            result = runner.run(args.case, args.count, args.host, args.gc, args.timing_only, args.scope)
        elif args.action == "latency":
            result = runner.latency(args.tasks, args.iterations)
        elif args.action == "matrix":
            result = runner.matrix()
        else:
            result = runner.audit()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
