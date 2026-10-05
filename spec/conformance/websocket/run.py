#!/usr/bin/env python3
"""Compile installed consumers and run the complete pinned both-role Autobahn gate."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
import uuid

from check_reports import HERE, ReportError, check_reports, load_manifest, read_json


def save(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(argv, *, env=None, cwd=None, timeout=60):
    result = subprocess.run(list(map(str, argv)), env=env, cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("command failed: " + repr(list(map(str, argv))) + "\n" + result.stderr + result.stdout)
    return result.stdout


def prefix_identity(prefix):
    # The prefix is a read-only provider. Disable probe caches for consumers.
    paths = [prefix / "bin/lua", prefix / "bin/titanc", prefix / "lib/titan/0.6/titan.so",
             prefix / "lib/titan/0.6/titan.a", prefix / "lib/titan/0.6/libtitan.a"]
    paths += sorted((prefix / "share/lua/5.5/titan-compiler").rglob("*.lua"))
    paths += sorted((prefix / "share/lua/5.5/titan").glob("*.lua"))
    # libtitan.a is SDK-layout dependent; capture its actual locations too.
    paths = [path for path in paths if path.is_file()]
    paths += sorted(prefix.glob("**/libtitan.a"))
    mandatory = ("bin/lua", "bin/titanc", "lib/titan/0.6/titan.so", "lib/titan/0.6/titan.a",
                 "share/lua/5.5/titan/websocket.lua")
    for relative in mandatory:
        if not (prefix / relative).is_file():
            raise RuntimeError("current installed prefix missing " + relative)
    return {str(path.relative_to(prefix)): sha256(path) for path in sorted(set(paths))}


def source_identity(checkout):
    paths = sorted((checkout / "titan").rglob("*.titan"))
    paths += sorted((checkout / "titan-compiler").rglob("*.lua"))
    return {"head": command(["git", "rev-parse", "HEAD"], cwd=checkout).strip(),
            "branch": command(["git", "branch", "--show-current"], cwd=checkout).strip(),
            "status": command(["git", "status", "--porcelain=v1"], cwd=checkout),
            "source_sha256": {str(path.relative_to(checkout)): sha256(path) for path in paths}}


def unused_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def evidence_size(root):
    size = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                size += path.stat().st_size
        except FileNotFoundError:
            # Compiler temporary files may retire during a live size sample.
            # The final report checker separately requires every case file.
            continue
    return size


def assert_evidence_budget(root, limit):
    if root is not None and evidence_size(root) > limit:
        raise RuntimeError("evidence size budget exceeded; full conformance not proven")


def wait_ready(process, port, *, http=False, timeout=30, evidence_root=None, evidence_limit_bytes=None):
    end = time.monotonic() + timeout
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    while time.monotonic() < end:
        assert_evidence_budget(evidence_root, evidence_limit_bytes)
        if process.poll() is not None:
            raise RuntimeError("peer exited before readiness; see its log")
        try:
            if http:
                with opener.open("http://127.0.0.1:" + str(port) + "/health", timeout=0.5) as response:
                    if response.read() == b"ready":
                        return
            else:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    return
        except (OSError, TimeoutError):
            pass
        time.sleep(0.1)
    raise RuntimeError("peer readiness deadline exceeded")


class Processes:
    def __init__(self, docker, root, env):
        self.docker, self.root, self.env = docker, root, env
        self.children = []
        self.log_pumps = {}
        self.containers = []
        self.commands = read_json(root / "commands.json") if (root / "commands.json").exists() else []

    def start(self, argv, name, cwd=None):
        log = (self.root / (name + ".log")).open("wb")
        try:
            process = subprocess.Popen(list(map(str, argv)), cwd=cwd, env=self.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
        except Exception:
            log.close()
            raise
        failures = []
        def pump():
            # Titan's asynchronous stdio requires a pipe/TTY. Drain continuously
            # into disk-backed evidence so neither logs nor pipe pressure stall
            # the peer. Join this owned thread when retiring the child group.
            try:
                with log, process.stdout:
                    while block := process.stdout.read1(65536):
                        log.write(block)
                        log.flush()
            except Exception as error:
                failures.append(str(error))
        thread = threading.Thread(target=pump, name="log-" + name, daemon=True)
        self.log_pumps[process] = (thread, failures)
        thread.start()
        self.children.append(process)
        self.commands.append({"argv": list(map(str, argv)), "cwd": str(cwd) if cwd else None,
                              "pid": process.pid, "log": name + ".log"})
        save(self.root / "commands.json", self.commands)
        return process

    def stop_process(self, process):
        if process not in self.children:
            return
        # Every child gets its own group. Retire descendants even if the leader
        # exited normally; never use a broad killall or terminate other runs.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        self.children.remove(process)
        thread, failures = self.log_pumps.pop(process)
        thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError("owned log pipe did not reach EOF after child-group retirement")
        if failures:
            raise RuntimeError("owned log capture failed: " + "; ".join(failures))

    def stop_container(self, name):
        result = subprocess.run([self.docker, "rm", "-f", name], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, timeout=30)
        if result.returncode and "No such container" not in result.stderr:
            raise RuntimeError("could not retire owned container " + name + ": " + result.stderr)
        if name in self.containers:
            self.containers.remove(name)

    def close(self):
        failures = []
        for name in list(self.containers):
            try:
                self.stop_container(name)
            except Exception as error:
                failures.append(str(error))
        for child in reversed(list(self.children)):
            try:
                self.stop_process(child)
            except Exception as error:
                failures.append(str(error))
        if failures:
            raise RuntimeError("owned-process cleanup failed: " + "; ".join(failures))


def rss_bytes(pid):
    try:
        return int(Path("/proc", str(pid), "statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, IndexError):
        return 0


def wait_measured(process, *, timeout, events=None, case_timeout=600, observed_processes=(),
                  evidence_root=None, evidence_limit_bytes=None):
    started = time.monotonic()
    phase_started = started
    phase_line = None
    phase = None
    evidence_sampled = started - 1
    peak_rss = {str(peer.pid): 0 for peer in (process, *observed_processes)}
    while process.poll() is None:
        now = time.monotonic()
        if now - evidence_sampled >= 1:
            assert_evidence_budget(evidence_root, evidence_limit_bytes)
            evidence_sampled = now
        for peer in observed_processes:
            if peer.poll() is not None:
                raise RuntimeError("required peer exited during run; see logs")
        for peer in (process, *observed_processes):
            peak_rss[str(peer.pid)] = max(peak_rss[str(peer.pid)], rss_bytes(peer.pid))
        if now - started > timeout:
            raise RuntimeError("full-run deadline exceeded; no case exclusions or pass inferred")
        if events and events.exists():
            lines = events.read_text().splitlines()
            if lines and lines[-1] != phase_line:
                phase_line = lines[-1]
                phase = json.loads(phase_line)
                if phase.get("phase") in ("case-start", "case-end", "metadata-start", "reports-start", "complete"):
                    phase_started = now
            if phase and now - phase_started > case_timeout:
                raise RuntimeError("client case/progress deadline exceeded: " + repr(phase))
        time.sleep(0.2)
    elapsed = time.monotonic() - started
    assert_evidence_budget(evidence_root, evidence_limit_bytes)
    if process.returncode:
        raise RuntimeError("owned process exited " + str(process.returncode) + "; see logs")
    return {"wall_seconds": elapsed, "sampled_peak_rss_bytes": peak_rss}


def docker_run(docker, image, name, config, reports, mode):
    return [docker, "run", "--rm", "--name", name, "--network", "host",
            "--security-opt", "label=disable", "-v", str(config) + ":/config:ro",
            "-v", str(reports) + ":/reports", image, "wstest", "-m", mode,
            "-s", "/config/" + mode + ".json", "--webport=0"]


def audit_driver_events(path, cases):
    events = [json.loads(line) for line in path.read_text().splitlines()]
    count = [entry["ordinal"] for entry in events if entry["phase"] == "case-count"]
    if count != [len(cases)]:
        raise RuntimeError("driver metadata case count mismatch")
    expected = [(ordinal, case) for ordinal, case in enumerate(cases, 1)]
    for phase in ("case-start", "case-end"):
        actual = [(entry["ordinal"], entry["id"]) for entry in events if entry["phase"] == phase]
        if actual != expected:
            raise RuntimeError("driver exact " + phase + " coverage mismatch")
    if not events or events[-1]["phase"] != "complete":
        raise RuntimeError("driver did not await report completion")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path,
                        help="disk-backed directory; a new unique run directory is always created")
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--run-timeout", type=int)
    parser.add_argument("--case-timeout", type=int)
    args = parser.parse_args()
    pins = read_json(HERE / "pins.json")
    manifest = load_manifest()
    run_timeout = args.run_timeout or pins["run_timeout_seconds"]
    case_timeout = args.case_timeout or pins["case_timeout_seconds"]
    evidence_limit = pins["evidence_limit_bytes"]
    if case_timeout < 600 or run_timeout < case_timeout:
        parser.error("case timeout must be at least 600s (suite cases reach 480s); run timeout must be longer")
    prefix, checkout = args.prefix.resolve(), args.checkout.resolve()
    args.output_root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:10]
    root = args.output_root.resolve() / stamp
    root.mkdir()
    print("Evidence directory: " + str(root), flush=True)
    for child in ("harness", "fixtures", "config", "reports", "tmp", "ccache"):
        (root / child).mkdir()
    for source in HERE.glob("*.py"):
        shutil.copy2(source, root / "harness" / source.name)
    for source in (HERE / "pins.json", HERE / "expected.json", HERE / "README.md", HERE / "measurement.json"):
        shutil.copy2(source, root / "harness" / source.name)
    for source in (HERE / "fixtures").glob("*.titan"):
        shutil.copy2(source, root / "fixtures" / source.name)
    env = os.environ.copy()
    for key in ("LUA_PATH", "LUA_CPATH", "LUA_PATH_5_5", "LUA_CPATH_5_5",
                "TITAN_ROCKS_ROOT", "TITAN_PATH", "TITAN_PATH_0_6", "TITAN_PREFIX"):
        env.pop(key, None)
    env.update(PATH=str(prefix / "bin") + os.pathsep + env.get("PATH", ""),
               TMPDIR=str(root / "tmp"), CCACHE_DIR=str(root / "ccache"),
               TITAN_PROBE_CACHE_DISABLE="1", TITAN_JOBS="1",
               TITAN_PATH_0_6=str(prefix / "lib/titan/0.6"))
    processes = Processes(args.docker, root, env)
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    summary = {"passed": False, "output": str(root), "started_utc": stamp,
               "budgets": {"run_timeout_seconds": run_timeout, "case_timeout_seconds": case_timeout,
                           "evidence_limit_bytes": evidence_limit},
               "selected_per_role": len(manifest["selected_cases"]),
               "excluded_cases": manifest["excluded_cases"], "roles": {}}
    started = time.monotonic()
    measured_budget = dict(evidence_root=root, evidence_limit_bytes=evidence_limit)
    try:
        source = source_identity(checkout)
        if source["branch"] != "codex/issue-193-websocket":
            raise RuntimeError("checkout branch differs from authorized implementation branch")
        identity = prefix_identity(prefix)
        save(root / "consumer-environment.json", {key: env[key] for key in
             ("PATH", "TMPDIR", "CCACHE_DIR", "TITAN_PROBE_CACHE_DISABLE", "TITAN_JOBS", "TITAN_PATH_0_6")})
        save(root / "source-identity.json", source)
        save(root / "prefix-identity.json", identity)
        image_metadata = json.loads(command([args.docker, "image", "inspect", pins["image"]]))
        save(root / "image-inspect.json", image_metadata)
        image = image_metadata[0]
        if image.get("Architecture") != "amd64" or image.get("Os") != "linux":
            raise RuntimeError("runner platform differs from pinned linux/amd64")
        labels = image["Config"]["Labels"]
        revision = labels.get("org.label-schema.vcs-ref", "")
        if len(revision) < 7 or not pins["source_revision"].startswith(revision) or labels.get("org.label-schema.version") != pins["version"]:
            raise RuntimeError("runner source/version identity mismatch")
        digest = pins["image"].split("@", 1)[1]
        if not any(entry.endswith("@" + digest) for entry in image.get("RepoDigests", [])):
            raise RuntimeError("runner digest not present in inspected image")
        inventory_name = "titan-ws-" + stamp.lower() + "-inventory"
        processes.containers.append(inventory_name)
        inventory = json.loads(command([args.docker, "run", "--rm", "--name", inventory_name,
                                       "--network", "none", "--read-only",
                                       "--security-opt", "label=disable", "--entrypoint", "python", "-v",
                                       str(root / "harness") + ":/harness:ro", pins["image"],
                                       "/harness/runner_inventory.py"]))
        processes.stop_container(inventory_name)
        save(root / "runner-inventory.json", inventory)
        if inventory["all_cases"] != manifest["all_cases"]:
            raise RuntimeError("actual pinned runner inventory differs from expected manifest")
        build_started = time.monotonic()
        for fixture in ("echo_server", "case_driver"):
            build = processes.start([prefix / "bin/titanc", "--jobs", "1", "--tree", root / "fixtures", fixture],
                                    "compile-" + fixture, cwd=root / "fixtures")
            wait_measured(build, timeout=600, **measured_budget)
            processes.stop_process(build)
        summary["compile_wall_seconds"] = time.monotonic() - build_started
        executables = {name: sha256(root / "fixtures" / name) for name in ("echo_server", "case_driver")}
        save(root / "fixture-identity.json", executables)
        agent_hash = identity["lib/titan/0.6/titan.so"][:12] + "-" + stamp.lower()
        cap = str(pins["read_limit_bytes"])
        selected, excluded = manifest["selected_cases"], manifest["excluded_cases"]
        common_config = {"cases": selected, "exclude-cases": excluded, "exclude-agent-cases": {}}
        server_agent, client_agent = "titan-server-" + agent_hash, "titan-client-" + agent_hash
        server_port, fuzz_port = unused_port(), unused_port()
        client_config = dict(common_config, outdir="/reports/servers",
                             servers=[{"agent": server_agent, "url": "ws://127.0.0.1:" + str(server_port)}])
        server_config = dict(common_config, outdir="/reports/clients", url="ws://127.0.0.1:" + str(fuzz_port))
        save(root / "config/fuzzingclient.json", client_config)
        save(root / "config/fuzzingserver.json", server_config)
        for role in ("server", "client"):
            role_started = time.monotonic()
            measured = {}
            try:
                if prefix_identity(prefix) != identity:
                    raise RuntimeError("installed provider changed before role execution")
                if role == "server":
                    echo = processes.start([root / "fixtures/echo_server", str(server_port), cap], "titan-server")
                    wait_ready(echo, server_port, http=True, **measured_budget)
                    name = "titan-ws-" + stamp.lower() + "-fuzzingclient"
                    processes.containers.append(name)
                    fuzzing = processes.start(docker_run(args.docker, pins["image"], name,
                                                        root / "config", root / "reports", "fuzzingclient"), "fuzzingclient")
                    measured = wait_measured(fuzzing, timeout=run_timeout, observed_processes=(echo,), **measured_budget)
                    processes.stop_container(name)
                    processes.stop_process(fuzzing)
                    processes.stop_process(echo)
                    agent, report_path = server_agent, root / "reports/servers"
                else:
                    name = "titan-ws-" + stamp.lower() + "-fuzzingserver"
                    processes.containers.append(name)
                    fuzzing = processes.start(docker_run(args.docker, pins["image"], name,
                                                        root / "config", root / "reports", "fuzzingserver"), "fuzzingserver")
                    wait_ready(fuzzing, fuzz_port, **measured_budget)
                    events = root / "client-events.jsonl"
                    driver = processes.start([root / "fixtures/case_driver", "ws://127.0.0.1:" + str(fuzz_port),
                                              client_agent, root / "harness/expected.json", events, cap], "titan-client")
                    measured = wait_measured(driver, timeout=run_timeout, events=events,
                                             case_timeout=case_timeout, observed_processes=(fuzzing,), **measured_budget)
                    processes.stop_process(driver)
                    audit_driver_events(events, selected)
                    processes.stop_container(name)
                    processes.stop_process(fuzzing)
                    agent, report_path = client_agent, root / "reports/clients"
                report = check_reports(report_path, agent, role, manifest)
                measured.update(report)
                measured["role_wall_seconds"] = time.monotonic() - role_started
                measured["max_case_duration_ms"] = max(report["case_duration_ms"].values())
                summary["roles"][role] = measured
            except (RuntimeError, ReportError, OSError, subprocess.TimeoutExpired) as error:
                measured.update(passed=False, error=str(error),
                                role_wall_seconds=time.monotonic() - role_started)
                summary["roles"][role] = measured
                # Run the other full role even if this role fails; retain all evidence.
                processes.close()
                processes = Processes(args.docker, root, env)
            save(root / "summary.json", summary)
        if prefix_identity(prefix) != identity:
            raise RuntimeError("installed provider changed during execution")
        summary["passed"] = all(summary["roles"].get(role, {}).get("passed") is True for role in ("server", "client"))
    except (RuntimeError, ReportError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        summary["error"] = str(error)
    except KeyboardInterrupt:
        summary["error"] = "interrupted; complete coverage not proven"
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            processes.close()
        except Exception as error:
            summary["cleanup_error"] = str(error)
            summary["passed"] = False
        summary["wall_seconds"] = time.monotonic() - started
        summary["evidence_bytes_before_archive"] = evidence_size(root)
        if summary["evidence_bytes_before_archive"] > evidence_limit:
            summary["error"] = "evidence size budget exceeded"
            summary["passed"] = False
        save(root / "summary.json", summary)
        evidence = {str(path.relative_to(root)): sha256(path) for path in sorted(root.rglob("*"))
                    if path.is_file() and "ccache" not in path.relative_to(root).parts and "tmp" not in path.relative_to(root).parts}
        save(root / "evidence-sha256.json", evidence)
        with tarfile.open(root.with_suffix(".tar.gz"), "w:gz") as archive:
            for path in sorted(root.rglob("*")):
                relative = path.relative_to(root)
                if "ccache" not in relative.parts and "tmp" not in relative.parts:
                    archive.add(path, arcname=str(Path(root.name) / relative), recursive=False)
        print(json.dumps(summary, sort_keys=True, indent=2), flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
