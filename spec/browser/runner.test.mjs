import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync, execFile } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { classify, knownTrap, observeImage, relativePath } from "../../titan-runtime/browser/titan-browser-page.mjs";
import {Monitor, within} from "../../titan-runtime/browser/titan-browser-run.mjs";
import {create} from "../../titan-runtime/browser/titan-browser.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const runner = resolve(process.env.TITAN_BROWSER_RUNNER ?? join(root, "titan-runtime/browser/titan-browser-run"));
const fixture = join(root, "spec/browser/runner-fixtures.mjs");
const importsFixture = join(root, "spec/browser/runner-imports.mjs");
const windows = process.platform === "win32";
const strict = process.env.TITAN_REQUIRE_BROWSER_TOOLCHAIN === "1";
const exec = promisify(execFile);

function testImage(t) {
    const image = process.env.TITAN_BROWSER_RUNNER_IMAGE;
    if (image) return resolve(image);
    if (strict) assert.fail("TITAN_BROWSER_RUNNER_IMAGE must name the compiled runner_image fixture");
    t.skip("TITAN_BROWSER_RUNNER_IMAGE is unset");
    return null;
}

async function missingTableImage(t) {
    const image = testImage(t);
    if (!image) return null;
    const directory = await mkdtemp(join(dirname(image), "trace-policy-"));
    t.after(() => rm(directory, {recursive: true, force: true}));
    const file = join(directory, basename(image));
    await copyFile(image, file);
    await copyFile(image.replace(/\.mjs$/, ".wasm"), file.replace(/\.mjs$/, ".wasm"));
    return {file, directory};
}

function fixtureRoot(image) {
    let directory = root;
    while (image) {
        const rel = relative(directory, image);
        if (!isAbsolute(rel) && rel !== ".." && !rel.startsWith(".." + sep)) break;
        directory = dirname(directory);
    }
    return directory;
}

function launch(args, env = {}, options = {}) {
    const launcher = options.launcher ?? (windows ? runner.replaceAll("\\", "/") : runner);
    const program = windows ? "sh.exe" : launcher;
    const argv = windows ? [launcher, ...args] : args;
    const node = windows ? process.execPath.replaceAll("\\", "/") : process.execPath;
    const child = spawn(program, argv, { cwd: tmpdir(), env: { ...process.env, TITAN_NODE: node, ...env } });
    const stdout = [], stderr = [];
    let hard;
    const deadline = setTimeout(() => {
        child.kill("SIGTERM");
        hard = setTimeout(() => child.kill("SIGKILL"), 3000);
    }, 45000);
    child.stdout.on("data", chunk => stdout.push(chunk));
    child.stderr.on("data", chunk => stderr.push(chunk));
    const result = new Promise((resolve, reject) => {
        child.on("error", error => { clearTimeout(deadline); reject(error); });
        child.on("close", (status, signal) => {
            clearTimeout(deadline); clearTimeout(hard);
            resolve({ status, signal, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) });
        });
    });
    return { child, result, stdout: () => Buffer.concat(stdout), stderr: () => Buffer.concat(stderr) };
}

function run(args, env, options) { return launch(args, env, options).result; }

async function chromium(t) {
    const result = await run(["--probe"]);
    assert.equal(result.status, 0, result.stderr.toString());
    const info = JSON.parse(result.stdout);
    if (!info.chrome.ok) {
        if (strict) assert.fail(info.chrome.reason);
        t.skip(info.chrome.reason);
        return null;
    }
    return info.chrome;
}

function cleanProfile(result) {
    const text = result.stderr.toString();
    const match = /profile ("(?:[^"\\]|\\.)*")/.exec(text);
    assert.ok(match, text);
    const path = JSON.parse(match[1]);
    assert.ok(text.includes(`cleanup: profile ${JSON.stringify(path)} removed`), text);
    return path;
}

async function absent(path) {
    await assert.rejects(readFile(path), { code: "ENOENT" });
}

async function cleanChromium(result) {
    const path = cleanProfile(result);
    await absent(path);
    const pid = /\bpid (\d+); profile/.exec(result.stderr.toString());
    if (pid) assert.throws(() => process.kill(Number(pid[1]), 0), { code: "ESRCH" });
    if (!windows) {
        const { stdout } = await exec("ps", ["-axo", "pid=,args="]);
        assert.equal(stdout.includes(`--user-data-dir=${path}`), false, `Chromium process still owns ${path}`);
    }
}

test("Windows engine jobs validate descriptors, retain native IPC and retire engine on either owner loss",
    { skip: !windows && "platform: requires Windows Job Objects" }, async t => {
    const helper = resolve(dirname(runner), "../../../bin/titan-browser-job.exe");
    const providerPath = resolve(dirname(runner), "../../titan/0.6");
    for (const [name, slot] of [["engine", 3], ["acknowledgement", 4], ["owner", 5]]) {
        await t.test(`rejects unopened ${name} descriptor`, () => {
            const stdio = ["ignore", "pipe", "pipe", "pipe", "pipe", "pipe"];
            stdio[slot] = "ignore";
            const result = spawnSync(helper, [process.execPath, "-e", "console.log('engine reached')"], {
                windowsHide: true, stdio, timeout: 10000, encoding: "utf8",
                env: { ...process.env, TITAN_PATH_0_6: providerPath },
            });
            assert.ifError(result.error);
            assert.equal(result.status, 125, result.stderr);
            assert.equal(result.stdout, "");
            assert.match(result.stderr, new RegExp(`^Windows browser job: invalid inherited descriptor slot ${slot}\\r?\\n$`));
        });
    }
    await t.test("forwards CDP pipe EOF before the engine exits", async () => {
        const worker = "require('node:fs').closeSync(4); setInterval(() => {}, 1000)";
        const child = spawn(helper, [process.execPath, "-e", worker], {
            detached: true, windowsHide: true, stdio: ["ignore", "ignore", "pipe", "pipe", "pipe", "pipe", "pipe"],
            env: { ...process.env, TITAN_PATH_0_6: providerPath },
        });
        const closed = new Promise((resolve, reject) => {
            child.once("error", reject); child.once("close", resolve);
        });
        child.stdio[4].resume();
        child.stdio.at(-1).on("error", () => {});
        let acknowledgement = "";
        child.stdio.at(-2).on("data", bytes => { acknowledgement += bytes; });
        try {
            await until(() => child.stdio[4].readableEnded || child.exitCode !== null);
            assert.equal(child.exitCode, null, "helper exited before the CDP pipe closed");
            child.stdio.at(-1).destroy();
            assert.equal(await closed, 0);
            assert.equal(acknowledgement, "1");
        } finally {
            child.stdio.at(-1).destroy();
            if (child.exitCode === null && child.signalCode === null) child.kill();
        }
    });
    for (const mode of ["ipc", "ipc-empty", "ipc-absent", "supervisor-pipe", "helper-death"]) await t.test(mode, async () => {
        const ipc = mode.startsWith("ipc");
        const argv = ["", "λ with spaces", 'quote"then slash\\', "C:\\tools\\with space\\"];
        const path = mode === "ipc" ? "C:\\caller λ;;C:\\with space\\" : mode === "ipc-empty" ? "" : undefined;
        const worker = ipc
            ? `process.on('message', value => process.send({value, argv: process.argv.slice(1),
                path: process.env.TITAN_PATH_0_6 ?? null, saved: process.env.TITAN_BROWSER_JOB_SAVED_PATH ?? null},
                () => process.exit(37)))`
            : `const child = require('node:child_process').spawn(process.execPath,
                ['-e', 'setInterval(() => {}, 1000)'], {detached: true, stdio: 'ignore'});
               console.log(process.pid + ' ' + child.pid); setInterval(() => {}, 1000)`;
        const child = spawn(helper, [process.execPath, "-e", worker, "--", ...argv], {
            windowsHide: true,
            stdio: ["ignore", "pipe", "pipe", ...(ipc ? ["ipc"] : []), "pipe", "pipe"],
            env: { ...process.env, TITAN_PATH_0_6: providerPath,
                TITAN_BROWSER_JOB_SAVED_PATH: path === undefined ? "0" : `1${path}` },
        });
        const closed = new Promise((resolve, reject) => {
            child.once("error", reject); child.once("close", resolve);
        });
        let deadline;
        const expired = new Promise((_, reject) => {
            deadline = setTimeout(() => reject(new Error(`Windows ${mode} job did not settle`)), 10000);
        });
        const settle = pending => Promise.race([pending, expired]);
        const started = pending => settle(Promise.race([pending, closed.then(status => {
            throw new Error(`Windows ${mode} helper exited before readiness (${status})`);
        })]));
        let proof = "";
        child.stdio.at(-2).on("data", bytes => { proof += bytes; });
        child.stdio.at(-1).on("error", () => {});
        child.stderr.on("data", bytes => { if (strict) process.stderr.write(bytes); });
        try {
            if (ipc) {
                const replied = new Promise(resolve => child.once("message", resolve));
                child.send({ text: "spaces and λ" });
                assert.deepEqual(await started(replied), { value: { text: "spaces and λ" }, argv, path: path ?? null, saved: null });
                assert.equal(await settle(closed), 37);
                assert.equal(proof, "1");
            } else {
                const text = await started(new Promise(resolve => {
                    let line = "";
                    child.stdout.setEncoding("utf8").on("data", chunk => {
                        line += chunk;
                        if (line.includes("\n")) resolve(line.trim());
                    });
                }));
                const pids = text.split(" ").map(Number);
                assert.equal(new Set([child.pid, ...pids]).size, 3, text);
                assert.ok(pids.every(pid => pid > 0), text);
                if (mode === "supervisor-pipe") child.stdio.at(-1).destroy();
                else child.kill();
                await settle(closed);
                assert.equal(proof, mode === "supervisor-pipe" ? "1" : "");
                for (const pid of pids) {
                    await until(() => {
                        try { process.kill(pid, 0); return false; }
                        catch (error) { if (error.code === "ESRCH") return true; throw error; }
                    });
                }
            }
        } finally {
            clearTimeout(deadline);
            if (child.exitCode === null && child.signalCode === null) child.kill();
        }
    });
});

async function until(check, milliseconds = 5000) {
    const deadline = performance.now() + milliseconds;
    while (performance.now() < deadline) {
        try { if (await check()) return; }
        catch (error) { if (error.code !== "ENOENT") throw error; }
        await new Promise(resolve => setTimeout(resolve, 20));
    }
    assert.fail("fixture did not reach its explicit ready condition");
}

async function descendantFixture(directory) {
    const files = Object.fromEntries(["descendant", "record", "term", "leader", "ready", "connected"]
        .map(name => [name, join(directory, name + (name === "descendant" ? ".mjs" : ".json"))]));
    await writeFile(files.descendant, `
        import { appendFileSync, writeFileSync } from "node:fs";
        process.on("SIGTERM", () => appendFileSync(${JSON.stringify(files.term)}, "TERM\\n"));
        writeFileSync(${JSON.stringify(files.record)}, JSON.stringify({pid: process.pid, argv: process.argv}));
        process.send("ready");
        process.disconnect();
        setInterval(() => {}, 1000);
    `);
    return files;
}

async function descendantGone(files) {
    const record = JSON.parse(await readFile(files.record, "utf8"));
    const leader = Number(await readFile(files.leader, "utf8"));
    assert.ok(record.pid > 0 && leader > 0 && record.pid !== leader, "fixture did not create a separate descendant");
    assert.ok(record.argv.every(arg => !arg.includes("--user-data-dir")), "descendant unexpectedly matched profile fallback");
    if (!windows) {
        assert.match(await readFile(files.term, "utf8"), /TERM\n/, "descendant never observed and resisted group SIGTERM");
        assert.throws(() => process.kill(-leader, 0), { code: "ESRCH" }, "owned process group survived");
    }
    assert.throws(() => process.kill(record.pid, 0), { code: "ESRCH" }, "owned descendant survived");
}

async function cleanupTrackedRun(execution, files, directory) {
    try {
        if (execution && execution.child.exitCode === null && execution.child.signalCode === null) {
            execution.child.kill("SIGTERM");
            await execution.result;
        }
    } finally {
        try {
            // Retire only recorded fixture processes if a regression failed.
            if (windows) {
                for (const [file, decode] of [[files.leader, Number], [files.record, text => JSON.parse(text).pid]]) {
                    try {
                        const pid = decode(await readFile(file, "utf8"));
                        if (pid > 0) process.kill(pid);
                    } catch (error) { if (!["ENOENT", "ESRCH"].includes(error.code)) throw error; }
                }
            } else {
                const leader = Number(await readFile(files.leader, "utf8"));
                if (leader > 0) process.kill(-leader, "SIGKILL");
            }
        } catch (error) { if (!["ENOENT", "ESRCH"].includes(error.code)) throw error; }
        finally { await rm(directory, { recursive: true, force: true }); }
    }
}

async function permissionFixture(directory, mode, files) {
    const groupFile = join(directory, "group.json");
    const lastFile = join(directory, "last.json");
    const callsFile = join(directory, "calls.jsonl");
    const profileFile = join(directory, "profile.json");
    const profileSeen = join(directory, "profile-seen");
    const hook = join(directory, "permission.mjs");
    await writeFile(hook, `
        import {appendFileSync, writeFileSync} from "node:fs";
        const original = process.kill;
        const mode = ${JSON.stringify(mode)};
        const denied = () => Object.assign(new Error("kill EPERM"), {code: "EPERM", syscall: "kill"});
        process.kill = (pid, signal) => {
            const call = {pid, signal};
            appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(call) + "\\n");
            writeFileSync(${JSON.stringify(lastFile)}, JSON.stringify(call));
            if (pid < 0) {
                writeFileSync(${JSON.stringify(groupFile)}, String(-pid));
                throw denied();
            }
            if (signal === 0 && (mode === "pid-denied" || mode === "profile-denied")) throw denied();
            if (signal !== 0 && mode.startsWith("profile-")) throw denied();
            return original(pid, signal);
        };
    `);
    const ps = join(directory, "ps");
    await writeFile(ps, `#!${process.execPath}
        const {existsSync, readFileSync, writeFileSync} = require("node:fs");
        const mode = ${JSON.stringify(mode)};
        const group = Number(readFileSync(${JSON.stringify(groupFile)}, "utf8"));
        const query = process.argv.slice(2).join(" ");
        if (query === "-axo pid=,pgid=,stat=") {
            const last = JSON.parse(readFileSync(${JSON.stringify(lastFile)}, "utf8"));
            const pid = mode === "live" ? JSON.parse(readFileSync(${JSON.stringify(files.record)}, "utf8")).pid : group;
            const state = mode === "zombie" || mode === "profile-zombie" ||
                (mode === "profile-denied" && last.pid < 0) ? "Z" : "S";
            if (mode !== "empty") process.stdout.write(pid + " " + (group + (mode === "other-group" ? 1 : 0)) + " " + state + "\\n");
        } else if (query === "-axo pid=,args=" && mode.startsWith("profile-")) {
            if (!existsSync(${JSON.stringify(profileSeen)})) {
                const profile = JSON.parse(readFileSync(${JSON.stringify(profileFile)}, "utf8"));
                writeFileSync(${JSON.stringify(profileSeen)}, "seen");
                process.stdout.write(profile.pid + " owned --user-data-dir=" + profile.path + "\\n");
            }
        } else throw new Error("unexpected process inspection: " + query);
    `, { mode: 0o755 });
    const node = join(directory, "node");
    const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
    await writeFile(node, "#!/bin/sh\nexec " + quote(process.execPath) + " --import " + quote(pathToFileURL(hook).href) + " \"$@\"\n", { mode: 0o755 });
    return { node, callsFile, profileFile, env: { TITAN_NODE: node, PATH: directory + ":" + process.env.PATH } };
}

test("relative asset paths stay beneath the root", () => {
    assert.equal(relativePath("a/../b.mjs"), "b.mjs");
    assert.equal(relativePath("./a/b.mjs"), "a/b.mjs");
    for (const path of ["", "/a", "../a", "a/../../b", "C:/a", "a\\b", "a\0b"]) assert.throws(() => relativePath(path));
});

test("classification retains original trap identity and abort evidence", () => {
    const original = Object.assign(new WebAssembly.RuntimeError("unreachable"), { code: "TITAN_BROWSER_TRAP" });
    const wrapped = Object.assign(new Error("Aborted"), { code: "TITAN_BROWSER_ABORT", cause: original });
    assert.equal(classify(wrapped), "trap");
    assert.equal(knownTrap(wrapped), true);
    assert.equal(classify(Object.assign(new WebAssembly.RuntimeError("Aborted"), { code: "TITAN_BROWSER_ABORT" })), "abort");
    const events = [];
    const creator = observeImage(options => options.onEngineFailure({kind: "abort", cause: "late"}),
        value => events.push(value));
    const sentinel = new Error("caller abort");
    assert.throws(() => creator({onEngineFailure() { events.push("caller"); throw sentinel; }}), error => error === sentinel);
    assert.deepEqual(events, ["caller", { type: "abort", reason: "late" }]);
});

test("public image observation forwards aborts and traps but leaves handled protocol poison local", () => {
    const events = ["abort", "trap", "protocol"].map(kind => ({kind, cause: new Error(kind)}));
    const observed = [], controls = [];
    for (const event of events) {
        observeImage(options => options.onEngineFailure(event), value => controls.push(value))({
            onEngineFailure: value => observed.push(value),
        });
    }
    assert.deepEqual(observed, events);
    assert.deepEqual(controls, [
        {type: "abort", reason: "abort"},
        {type: "failure", category: "trap", reason: "trap", knownTrap: true},
    ]);
});

test("launcher rejects absent and wrong-major Node without stdout", async t => {
    const absent = await mkdtemp(join(tmpdir(), "titan-missing-tools-"));
    t.after(() => rm(absent, { recursive: true, force: true }));
    const missing = join(absent, windows ? "node.exe" : "node");
    const chrome = join(absent, windows ? "chrome.exe" : "chrome");
    const result = await run(["--probe"], { TITAN_NODE: missing });
    assert.equal(result.status, 75);
    assert.equal(result.stdout.length, 0);
    assert.equal(result.stderr.toString(), `titan-browser-run: Node 26 or newer is required (node not executable at "${missing}")\n`);
    const node = windows ? process.execPath.replaceAll("\\", "/") : process.execPath;
    for (const [name, path] of [["missing on PATH", undefined], ["absolute interpreter", node]]) {
        await t.test(name, async () => {
            const env = { ...process.env, TITAN_CHROME: chrome, TITAN_NODE: path };
            const { stdout, stderr, code = 0 } = await exec(windows ? "sh.exe" : "/bin/sh", [
                "-c", 'PATH=; export PATH; exec "$0" "$@"', windows ? runner.replaceAll("\\", "/") : runner, "--probe",
            ], { cwd: tmpdir(), env }).catch(error => error);
            assert.equal(code, path ? 0 : 75, stderr);
            if (!path) {
                assert.equal(stdout, "");
                assert.equal(stderr, "titan-browser-run: Node 26 or newer is required (node not found (TITAN_NODE unset; not on PATH))\n");
            }
        });
    }
    await t.test("wrong-major interpreter", async st => {
        const directory = await mkdtemp(join(tmpdir(), "titan-node-resolver-"));
        st.after(() => rm(directory, { recursive: true, force: true }));
        // A stand-in interpreter that reports an older major version. The
        // launcher runs it through sh, which honours the #! line everywhere.
        const oldNode = join(directory, "node");
        const version = "v24.19.0";
        await writeFile(oldNode, `#!/bin/sh\nprintf '${version}\\n'\n`, { mode: 0o755 });
        const wrong = await run(["--probe"], { TITAN_NODE: oldNode });
        assert.equal(wrong.status, 75);
        assert.equal(wrong.stdout.length, 0);
        assert.match(wrong.stderr.toString(), /Node 26 or newer is required/);
        assert.ok(wrong.stderr.toString().includes(`reports ${version}; expected Node 26 or newer`));
    });
});

test("probe is closed JSON and needs no SDK or browser launch", async t => {
    const directory = await mkdtemp(join(tmpdir(), "titan-missing-chrome-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const chrome = join(directory, windows ? "chrome.exe" : "chrome");
    const result = await run(["--probe"], { TITAN_CHROME: chrome });
    assert.equal(result.status, 0, result.stderr.toString());
    assert.equal(result.stderr.length, 0);
    assert.equal(result.stdout.toString().split("\n").length, 2);
    const info = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(info).sort(), ["chrome", "node"]);
    for (const record of [info.node, info.chrome]) assert.deepEqual(Object.keys(record).sort(), ["ok", "path", "reason", "version"]);
    assert.equal(info.node.version, process.version);
    assert.equal(info.node.ok, true);
    assert.equal(info.node.reason, null);
    assert.equal(info.chrome.ok, false);
    assert.equal(info.chrome.path, chrome);
    assert.equal(info.chrome.version, null);
    assert.ok(info.chrome.reason);
});

test("Windows launcher accepts native backslashes in both absolute paths",
    { skip: !windows && "platform: requires MSYS2 Windows paths" }, async t => {
    const directory = await mkdtemp(join(tmpdir(), "titan-missing-chrome-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const result = await run(["--probe"], { TITAN_NODE: process.execPath, TITAN_CHROME: join(directory, "chrome.exe") },
        { launcher: runner });
    assert.equal(result.status, 0, result.stderr.toString());
    assert.equal(JSON.parse(result.stdout).node.version, process.version);
});

test("Windows Chromium PATH respects quoted entries and never searches empty entries",
    { skip: !windows && "platform: requires a native Win32 PATH" }, async t => {
    const directory = await mkdtemp(join(tmpdir(), "titan-chrome-path-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const alias = basename(process.execPath);
    const quoted = join(directory, "tools; with space");
    await mkdir(quoted);
    // A real executable with a deliberately unrecognized Chrome banner.
    await copyFile(process.execPath, join(quoted, alias));
    const entries = `;;"";'';`;
    // Bypass MSYS for this probe so the Windows PATH syntax reaches Node verbatim.
    const probe = async path => {
        const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.toUpperCase() !== "PATH"));
        const result = await exec(process.execPath, [runner + ".mjs", "--probe"], {
            cwd: dirname(process.execPath), env: { ...env, PATH: path, TITAN_CHROME: alias },
        });
        return JSON.parse(result.stdout).chrome;
    };
    const absent = await probe(entries);
    assert.match(absent.reason, /not found/);
    assert.equal(absent.version, null);
    for (const quote of ['"', "'"]) {
        const found = await probe(`${entries}${quote}${quoted}${quote};`);
        assert.equal(found.path, join(quoted, alias));
        assert.equal(found.version, process.version);
        assert.equal(found.reason, "unrecognized Chrome/Chromium version banner");
    }
});

test("CLI misuse is 2 and absent image is harness 75", async t => {
    for (const args of [[], ["--engine", "bad", fixture], ["--timeout", "0", fixture], ["--grace", "-1", fixture], ["--cdp", "bad", fixture]]) {
        const result = await run(args);
        assert.equal(result.status, 2, result.stderr.toString());
        assert.equal(result.stdout.length, 0);
        assert.match(result.stderr.toString(), /usage: titan-browser-run/);
    }
    const directory = await mkdtemp(join(tmpdir(), "titan-missing-image-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const result = await run([join(directory, "image.mjs")]);
    assert.equal(result.status, 75);
    assert.equal(result.stdout.length, 0);
    assert.match(result.stderr.toString(), /titan-browser-run: harness failure:/);
});

for (const engine of ["node", "chromium"]) {
    for (const cdp of engine === "node" ? ["pipe"] : ["pipe", "port"]) {
        test(`portable frozen context, GC, exact bytes, and cleanup (${engine}/${cdp})`, async t => {
            if (engine === "chromium" && !await chromium(t)) return;
            const result = await run(["--engine", engine, "--cdp", cdp, "--grace", "20", "--root", root, "--js-test", fixture]);
            assert.equal(result.status, 0, result.stderr.toString());
            assert.equal(result.signal, null);
            assert.deepEqual(result.stdout, Buffer.from([0, 255, 195, 40, 65]));
            if (engine === "node") assert.deepEqual(result.stderr, Buffer.from([254, 0, 226, 40, 66]));
            else {
                assert.ok(result.stderr.includes(Buffer.from([254, 0, 226, 40, 66])));
                await cleanChromium(result);
            }
            const args = ["a b", "--option", "λ"];
            const forwarded = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--root", root, "--js-test", fixture, "--", "args", ...args]);
            assert.equal(forwarded.status, 0, forwarded.stderr.toString());
            assert.deepEqual(forwarded.stdout, Buffer.from(JSON.stringify(args)));
            if (engine === "chromium") await cleanChromium(forwarded);
            const imported = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--root", root,
                "--imports", importsFixture, "--js-test", fixture, "--", "imports"]);
            assert.equal(imported.status, 0, imported.stderr.toString());
            assert.deepEqual(imported.stdout, Buffer.from("imports"));
            if (engine === "chromium") await cleanChromium(imported);
        });
        test(`real CLI test image preserves bytes and 0/1/2 status (${engine}/${cdp})`, async t => {
            const image = testImage(t);
            if (!image) return;
            if (engine === "chromium" && !await chromium(t)) return;
            const passed = await run(["--engine", engine, "--cdp", cdp, "--grace", "20", image,
                "--", "--filter=^runner_image[.]test_bytes$"]);
            assert.equal(passed.status, 0, passed.stderr.toString());
            const prefix = Buffer.concat([
                Buffer.from("[==========] Running Titan tests.\n[ RUN      ] runner_image.test_bytes\n"),
                Buffer.from([0, 255, 195, 40, 116, 97, 105, 108]),
            ]);
            assert.deepEqual(passed.stdout.subarray(0, prefix.length), prefix);
            const tail = passed.stdout.subarray(prefix.length).toString("latin1");
            const timing = /^\[       OK \] runner_image\.test_bytes \(([0-9]+\.[0-9]{2}) ms\)\n\[----------\] runner_image \(([0-9]+\.[0-9]{2}) ms total\)\n\[==========\] 1 test ran\. \(([0-9]+\.[0-9]{2}) ms total\)\n\[  PASSED  \] 1 test\.\n$/.exec(tail);
            assert.ok(timing && timing[0] === tail, tail);
            assert.equal(timing[1], timing[2], "single owner total differs from its root case");
            assert.ok(Number(timing[3]) >= Number(timing[2]), "run wall time excluded its case");
            const rawStderr = engine === "node" ? passed.stderr : Buffer.from(passed.stderr.toString("latin1")
                .replace(/titan-browser-run: (?:Chromium|cleanup:)[^\n]*\n/g, ""), "latin1");
            assert.deepEqual(rawStderr, Buffer.from([0, 254, 226, 40, 116, 97, 105, 108]));
            const failed = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image,
                "--", "--filter=^runner_image[.]test_failure$"]);
            assert.equal(failed.status, 1, failed.stderr.toString());
            const failureOutput = failed.stdout.toString("latin1");
            assert.match(failureOutput, /^\[  FAILED  \] runner_image\.test_failure \([0-9]+\.[0-9]{2} ms\)$/m);
            assert.match(failureOutput, /^\[----------\] runner_image \([0-9]+\.[0-9]{2} ms total\)$/m);
            assert.match(failureOutput, /^\[==========\] 1 test ran\. \([0-9]+\.[0-9]{2} ms total\)$/m);
            assert.ok(failed.stdout.includes(Buffer.from("[  FAILED  ] runner_image.test_failure\n")));
            assert.ok(failed.stdout.includes(Buffer.from("[  FAILED  ] 1 test.\n")));
            const skipped = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image,
                "--", "--filter=^runner_image[.]test_skip"]);
            assert.equal(skipped.status, 0, skipped.stderr.toString());
            const skipOutput = skipped.stdout.toString("latin1");
            const skipTiming = /^\[==========\] Running Titan tests\.\n\[ RUN      \] runner_image\.test_skip\n\[  SKIPPED \] runner_image\.test_skip\.never \(parent skipped: unsupported: timing fixture\) \(0\.00 ms\)\n\[  SKIPPED \] runner_image\.test_skip \(unsupported: timing fixture\) \(([0-9]+\.[0-9]{2}) ms\)\n\[----------\] runner_image \(([0-9]+\.[0-9]{2}) ms total\)\n\[==========\] 2 tests ran\. \(([0-9]+\.[0-9]{2}) ms total\)\n\[  PASSED  \] 0 tests\.\n\[  SKIPPED \] 2 tests\.\n$/.exec(skipOutput);
            assert.ok(skipTiming && skipTiming[0] === skipOutput, skipOutput);
            assert.equal(skipTiming[1], skipTiming[2]);
            assert.ok(Number(skipTiming[3]) >= Number(skipTiming[2]));
            const empty = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image,
                "--", "--filter=^absent$"]);
            assert.equal(empty.status, 0, empty.stderr.toString());
            const emptyOutput = empty.stdout.toString("latin1");
            const emptyTiming = /^\[==========\] Running Titan tests\.\n\[==========\] 0 tests ran\. \([0-9]+\.[0-9]{2} ms total\)\n\[  PASSED  \] 0 tests\.\n$/.exec(emptyOutput);
            assert.ok(emptyTiming && emptyTiming[0] === emptyOutput, emptyOutput);
            const invalid = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image, "--", "--unknown"]);
            assert.equal(invalid.status, 2, invalid.stderr.toString());
            assert.equal(invalid.stdout.toString(), "error: unknown option '--unknown'\n" +
                "Usage: <test-executable> [-h|--help] [-v|--verbose] [-f PATTERN|--filter=PATTERN]...\n");
            if (engine === "chromium") for (const result of [passed, failed, skipped, empty, invalid]) await cleanChromium(result);
        });
        test(`uncaught real-image completion corruption remains a harness failure (${engine}/${cdp})`, async t => {
            const named = process.env.TITAN_BROWSER_LOADER_IMAGE;
            if (!named) {
                if (strict) assert.fail("TITAN_BROWSER_LOADER_IMAGE must name the compiled fidelity fixture");
                t.skip("TITAN_BROWSER_LOADER_IMAGE is unset");
                return;
            }
            if (engine === "chromium" && !await chromium(t)) return;
            for (const mode of ["duplicate", "invalid"]) await t.test(mode, async () => {
                const result = await run(["--engine", engine, "--cdp", cdp, "--timeout", "5000",
                    "--grace", "20", resolve(named), "--", mode]);
                assert.equal(result.status, 75, result.stderr.toString());
                assert.equal(result.signal, null);
                assert.match(result.stderr.toString(), /titan-browser-run: harness failure: browser entry reported a duplicate or mismatched completion/);
                if (engine === "chromium") await cleanChromium(result);
            });
        });
        test(`failure categories and bounded cleanup (${engine}/${cdp})`, async t => {
            if (engine === "chromium" && !await chromium(t)) return;
            const image = process.env.TITAN_BROWSER_RUNNER_IMAGE && resolve(process.env.TITAN_BROWSER_RUNNER_IMAGE);
            const directory = fixtureRoot(image);
            const imageArg = image && relative(directory, image).split(sep).join("/");
            const cases = [
                ["trap", 71, /titan-browser-run: trap:/],
                ["abort", 70, /titan-browser-run: abort:/],
                ["caught-abort", 70, /titan-browser-run: abort:/],
                ["abort-hang", 72, /titan-browser-run: timed out after 1500 ms/],
                ["trap-priority", 71, /titan-browser-run: trap:/],
                ["timeout", 72, /titan-browser-run: timed out after 1500 ms/],
                ["late-trap", 73, /titan-browser-run: late engine failure:.*\(trap\)/],
                ["late-abort", 73, /titan-browser-run: late engine failure:.*\(abort\)/],
                ["unhandled", 74, /titan-browser-run: unhandled rejection: runner deliberate rejection/],
                ["late-unhandled", 74, /titan-browser-run: unhandled rejection: runner late rejection/],
                ["malformed", 75, /titan-browser-run: harness failure: unknown control message/],
                ["duplicate", 75, /titan-browser-run: harness failure: duplicate completion/],
                ["bad-return", 75, /titan-browser-run: harness failure: JS test run\(context\) must return undefined/],
                ["host-fail", 1, /titan-browser-run: JS test failed: runner host assertion/],
                ["sink-stdout", 76, /titan-browser-run: sink failure: browser stdout sink failed/],
                ["sink-stderr", 76, /titan-browser-run: sink failure: browser stderr sink failed/],
                ["sink-thenable", 76, /titan-browser-run: sink failure: browser stdout sink failed/],
                ["image-cache", 0, /^(?!.*titan-browser-run: (?:harness|abort|trap))/s],
            ];
            if (engine === "node") cases.push(["premature-exit", 75, /titan-browser-run: harness failure: Node worker (?:exited|IPC disconnected)/]);
            else cases.push(["http-paths", 0, /cleanup: profile/]);
            for (const [mode, status, diagnostic] of cases) await t.test(mode, async child => {
                if (["abort", "caught-abort", "late-abort", "sink-stdout", "sink-stderr", "sink-thenable", "image-cache"].includes(mode) && !image) {
                    testImage(child); return;
                }
                const before = performance.now();
                const result = await run(["--engine", engine, "--cdp", cdp, "--timeout", ["timeout", "abort-hang"].includes(mode) ? "1500" : "5000",
                    "--grace", "200", "--root", directory, "--js-test", fixture, "--", mode, ...(imageArg ? [imageArg] : [])]);
                assert.equal(result.status, status, result.stderr.toString());
                assert.equal(result.signal, null);
                assert.match(result.stderr.toString(), diagnostic);
                if (mode === "timeout" || mode === "abort-hang") {
                    assert.equal(result.stdout.toString(), "hang-entered\n", "deadline expired before Wasm loop began");
                    assert.ok(performance.now() - before < 10000, "deadline/shutdown was not bounded");
                }
                if (engine === "chromium") await cleanChromium(result);
            });
            // A failure deliberately scheduled beyond a zero grace window must not
            // be reported after the worker/page has already been retired.
            const short = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--root", root,
                "--js-test", fixture, "--", "late-trap"]);
            assert.equal(short.status, 0, short.stderr.toString());
            if (engine === "chromium") await cleanChromium(short);
        });
        for (const [phase, fixtureName, ...args] of [
            ["suspended", "abort-dispose"], ["initializing", "initialize-abort"],
            ["binding throw", "abort-binding", "throw"], ["binding return", "abort-binding", "return"],
            ["binding bytes", "abort-binding", "bytes"], ["binding format", "abort-binding", "format"],
            ["binding allocation", "abort-binding", "allocation"],
        ]) {
            test(`fatal ${phase} abort completes disposal before shutdown (${engine}/${cdp})`, async t => {
                const named = process.env.TITAN_BROWSER_LOADER_IMAGE;
                if (!named) {
                    if (strict) assert.fail("TITAN_BROWSER_LOADER_IMAGE must name the compiled fidelity fixture");
                    t.skip("TITAN_BROWSER_LOADER_IMAGE is unset");
                    return;
                }
                if (engine === "chromium" && !await chromium(t)) return;
                const image = resolve(named);
                const directory = fixtureRoot(image);
                const before = performance.now();
                const result = await run(["--engine", engine, "--cdp", cdp, "--timeout", "5000", "--grace", "200", "--root", directory,
                    "--js-test", join(root, `spec/fixtures/browser_loader/${fixtureName}.mjs`), "--",
                    relative(directory, image).split(sep).join("/"), ...args]);
                assert.equal(result.status, 70, result.stderr.toString());
                assert.deepEqual(result.stdout, Buffer.from("dispose-complete\n"), "abort status alone does not prove fatal disposal finished");
                assert.ok(performance.now() - before < 5000, "fatal disposal waited for an unusable instance");
                if (engine === "chromium") await cleanChromium(result);
            });
        }
        test(`JS module/path isolation and long deadlines (${engine}/${cdp})`, async t => {
            if (engine === "chromium" && !await chromium(t)) return;
            const directory = await mkdtemp(join(tmpdir(), "titan runner-"));
            try {
                const inside = join(directory, "inside");
                const outside = join(directory, "outside");
                await mkdir(inside); await mkdir(outside);
                await writeFile(join(outside, "secret"), "not a served asset");
                await writeFile(join(outside, "image.mjs"), "export default function forbidden() {};\n");
                const file = join(inside, "fixture unicode λ.mjs");
                const args = ["--engine", engine, "--cdp", cdp, "--grace", "0", "--js-test", file];
                await t.test("link escape stays outside the root", async st => {
                    const escape = join(inside, "escape");
                    try {
                        await symlink(outside, escape, windows ? "junction" : "dir");
                        assert.equal(await readFile(join(escape, "secret"), "utf8"), "not a served asset");
                        assert.equal(await readFile(join(escape, "image.mjs"), "utf8"), "export default function forbidden() {};\n");
                    } catch (error) {
                        if (!windows || !["EPERM", "EACCES", "UNKNOWN"].includes(error.code)) throw error;
                        return st.skip(`capability: Windows link cannot be created or traversed (${error.code})`);
                    }
                    await writeFile(file, `export async function run(context) {
                        for (const [method, path] of [["bytes", "escape/secret"], ["image", "escape/image.mjs"]]) {
                            let rejected = false;
                            try { await context[method](path); } catch { rejected = true; }
                            context.assert(rejected, "link escaped --root");
                        }
                    }\n`);
                    const escaped = await run(args);
                    assert.equal(escaped.status, 0, escaped.stderr.toString());
                    if (engine === "chromium") await cleanChromium(escaped);
                });
                // Fetch and instantiate a real sibling Wasm whose filename contains
                // URL query/fragment characters, not merely inspect its locateFile URL.
                const wasmName = windows ? "sibling #.wasm" : "sibling #?.wasm";
                const factoryName = windows ? "factory #.mjs" : "factory #?.mjs";
                await writeFile(join(inside, wasmName), new Uint8Array([
                    0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127,
                    3, 2, 1, 0, 7, 10, 1, 6, 97, 110, 115, 119, 101, 114, 0, 0,
                    10, 6, 1, 4, 0, 65, 42, 11,
                ]));
                await writeFile(join(inside, factoryName), `export default async ({locateFile}) => {
                    const filename = locateFile(${JSON.stringify(wasmName)});
                    const bytes = typeof process === "object" && process.versions?.node ?
                        await (await import("node:fs/promises")).readFile(filename) :
                        await (await fetch(filename)).arrayBuffer();
                    return new WebAssembly.Instance(await WebAssembly.compile(bytes)).exports.answer();
                };\n`);
                await writeFile(file, `export async function run(context) {
                    const image = await context.image(${JSON.stringify(factoryName)});
                    context.assert(await image.create({locateFile: image.locateFile}) === 42,
                        "real special-name sibling Wasm was not fetched and instantiated");
                }\n`);
                const isolated = await run(args);
                assert.equal(isolated.status, 0, isolated.stderr.toString());
                if (engine === "chromium") await cleanChromium(isolated);
                await writeFile(file, "export const notRun = true;\n");
                const missing = await run(args);
                assert.equal(missing.status, 75, missing.stderr.toString());
                assert.match(missing.stderr.toString(), /JS test module must export run\(context\)/);
                if (engine === "chromium") await cleanChromium(missing);
            } finally { await rm(directory, { recursive: true, force: true }); }
            const large = await run(["--engine", engine, "--cdp", cdp, "--timeout", "2147483648", "--grace", "2147483648",
                "--root", root, "--js-test", fixture, "--", "late-trap"]);
            assert.equal(large.status, 73, large.stderr.toString());
            assert.doesNotMatch(large.stderr.toString(), /TimeoutOverflowWarning/);
            if (engine === "chromium") await cleanChromium(large);
        });
        test(`application signed status is masked only at CLI exit (${engine}/${cdp})`, async t => {
            const image = testImage(t);
            if (!image) return;
            if (engine === "chromium" && !await chromium(t)) return;
            const statusImage = join(dirname(image), "runner_status.mjs");
            for (const [argument, status] of [["", 0], ["negative", 255], ["wide", 1], ["minimum", 0], ["maximum", 255], ["wrap", 1]]) {
                const result = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", statusImage, "--", ...(argument ? [argument] : [])]);
                assert.equal(result.status, status, result.stderr.toString());
                assert.equal(result.stdout.length, 0);
                assert.doesNotMatch(result.stderr.toString(), /titan-browser-run: (?:abort:|trap:|harness failure:|timed out|sink failure:)/);
                if (engine === "chromium") await cleanChromium(result);
            }
        });
    }
}

for (const cdp of ["pipe", "port"]) {
    test(`launch/connect failure retires only its own process and profile (${cdp})`,
        { skip: windows && "platform: launches executable POSIX shell scripts as Chromium substitutes" }, async t => {
        const directory = await mkdtemp(join(tmpdir(), "titan-chrome-launch-"));
        const chrome = join(directory, "chrome");
        const banner = "if [ \"$1\" = --version ]; then printf 'Chromium 156.0.8078.80\\n'; exit 0; fi\n" +
            "printf '%s\\n' \"$@\" > \"$TITAN_BROWSER_TEST_ARGV\"\n";
        try {
            const scripts = [
                ["exit", banner + "printf 'fake Chromium stderr before exit\\n' >&2\nexit 9\n",
                    75, 9, null, "fake Chromium stderr before exit"],
                ["pipe-close", banner + "exec 4>&-\nprintf '%s\\n' 'discarded-stderr-prefix-" + "x".repeat(10000) +
                    "final-stderr-tail-after-pipe-close' >&2\nexit 17\n",
                    75, 17, null, "final-stderr-tail-after-pipe-close"],
                ["signal", banner + "printf 'fake Chromium stderr before signal\\n' >&2\nkill -TERM \"$$\"\n",
                    75, null, "SIGTERM", "fake Chromium stderr before signal"],
                ["connect", banner + "for arg in \"$@\"; do case \"$arg\" in --user-data-dir=*) profile=${arg#--user-data-dir=} ;; esac; done\n" +
                    "printf '1\\n/devtools/browser/missing\\n' > \"$profile/DevToolsActivePort\"\nexec /bin/sleep 60\n", cdp === "port" ? 75 : 72],
                ["spawn", "if [ \"$1\" = --version ]; then printf 'Chromium 156.0.8078.80\\n'; rm -- \"$0\"; exit 0; fi\nexit 9\n", 75],
            ];
            for (const [name, script, status, exitCode, exitSignal, stderrTail] of scripts) await t.test(name, async () => {
                await writeFile(chrome, "#!/bin/sh\n" + script, { mode: 0o755 });
                const argumentsFile = join(directory, name + ".args");
                const before = performance.now();
                const result = await run(["--engine", "chromium", "--chrome", chrome, "--cdp", cdp,
                    "--timeout", "700", "--grace", "0", "--root", root, "--js-test", fixture],
                    { TITAN_BROWSER_TEST_ARGV: argumentsFile, TITAN_BROWSER_ROOT_NO_SANDBOX: "" });
                assert.equal(result.status, status, result.stderr.toString());
                assert.equal(result.stdout.length, 0);
                assert.ok(performance.now() - before < 10000, "launch/connect cleanup was not bounded");
                if (name !== "spawn") {
                    const args = (await readFile(argumentsFile, "utf8")).trimEnd().split("\n");
                    for (const flag of ["--headless=new", "--disable-gpu", "--disable-dev-shm-usage"]) {
                        assert.equal(args.filter(arg => arg === flag).length, 1, `launch must pass ${flag} once`);
                    }
                    assert.equal(args.includes("--no-zygote"), false, "launch must retain the zygote");
                    assert.equal(args.includes("--no-sandbox"), false, "default launch must retain the sandbox");
                    assert.equal(args.includes("--remote-debugging-pipe"), cdp === "pipe");
                    assert.equal(args.includes("--remote-debugging-port=0"), cdp === "port");
                }
                if (stderrTail) {
                    assert.ok(result.stderr.includes(Buffer.from(`Chromium child status: exit code=${JSON.stringify(exitCode)}, signal=${JSON.stringify(exitSignal)}`)),
                        result.stderr.toString());
                    assert.ok(result.stderr.includes(Buffer.from("Chromium stderr tail:\n")), result.stderr.toString());
                    assert.ok(result.stderr.includes(Buffer.from(stderrTail)), result.stderr.toString());
                    if (name === "pipe-close") assert.doesNotMatch(result.stderr.toString(), /discarded-stderr-prefix-/);
                }
                await cleanChromium(result);
            });
        } finally { await rm(directory, { recursive: true, force: true }); }
    });
}

test("port discovery retries partial files and bounds malformed content",
    { skip: windows && "platform: fake Chromium uses a POSIX shebang and SIGTERM handler" }, async t => {
    for (const initial of ["empty", "port", "garbage", "missing"]) await t.test(initial, async () => {
        const directory = await mkdtemp(join(tmpdir(), "titan-chrome-port-"));
        try {
            const chrome = join(directory, "chrome");
            const connected = join(directory, "connected");
            const retired = join(directory, "retired");
            await writeFile(chrome, `#!${process.execPath}
                const {writeFileSync} = require("node:fs");
                const {join} = require("node:path");
                const net = require("node:net");
                if (process.argv.includes("--version")) {
                    console.log("Chromium 156.0.8078.80");
                } else {
                    const profile = process.argv.find(arg => arg.startsWith("--user-data-dir=")).slice(16);
                    const path = join(profile, "DevToolsActivePort");
                    let publishedAt;
                    process.on("SIGTERM", () => {
                        if (publishedAt !== undefined) writeFileSync(${JSON.stringify(retired)},
                            String(performance.now() - publishedAt));
                        process.exit(0);
                    });
                    const server = net.createServer(socket => {
                        writeFileSync(${JSON.stringify(connected)}, "connected");
                        socket.destroy();
                    });
                    server.listen(0, "127.0.0.1", () => {
                        const port = server.address().port;
                        const initial = ${JSON.stringify(initial)};
                        if (initial !== "missing") {
                            publishedAt = performance.now();
                            writeFileSync(path,
                                initial === "garbage" ? "nonsense\\n" : initial === "port" ? port + "\\n" : "");
                        }
                        if (initial === "empty" || initial === "port") setTimeout(() => {
                            writeFileSync(path, port + "\\n/devtools/browser/ready\\n");
                        }, 60);
                    });
                }
            `, {mode: 0o755});
            const result = await run(["--engine", "chromium", "--chrome", chrome, "--cdp", "port",
                "--timeout", initial === "missing" ? "500" : "4000", "--grace", "0",
                "--root", root, "--js-test", fixture]);
            const stderr = result.stderr.toString();
            assert.equal(result.status, initial === "missing" ? 72 : 75, stderr);
            if (initial === "empty" || initial === "port") {
                assert.equal(await readFile(connected, "utf8"), "connected");
                assert.match(stderr, /CDP WebSocket/);
                assert.doesNotMatch(stderr, /invalid DevToolsActivePort/);
            } else if (initial === "garbage") {
                assert.ok(stderr.includes('invalid DevToolsActivePort: "nonsense\\n"'), stderr);
                assert.ok(Number(await readFile(retired, "utf8")) >= 1000,
                    "malformed file was not retried before Chromium cleanup began");
                assert.doesNotMatch(stderr, /timed out after/);
            } else {
                assert.match(stderr, /timed out after 500 ms/);
                assert.doesNotMatch(stderr, /invalid DevToolsActivePort/);
            }
            await cleanChromium(result);
        } finally { await rm(directory, {recursive: true, force: true}); }
    });
});

test("Windows runner reports worker IPC disconnect before its deadline", {
    skip: !windows && "platform: checks EOF through the Windows Job Object helper",
}, async t => {
    const directory = await mkdtemp(join(tmpdir(), "titan-node-ipc-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const worker = join(directory, "worker.mjs");
    await writeFile(worker, `export async function run() {
        setInterval(() => {}, 1000);
        process.disconnect();
        await new Promise(() => {});
    }\n`);
    const result = await run(["--engine", "node", "--timeout", "6000", "--grace", "0", "--js-test", worker]);
    assert.equal(result.status, 75, result.stderr.toString());
    assert.match(result.stderr.toString(), /harness failure: Node worker IPC disconnected before shutdown/);
    assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
});

test("Node retires owned descendants independently of its worker leader", async t => {
    for (const mode of ["leader-exit", "deadline", "SIGINT", "SIGTERM"]) await t.test(mode, {
        skip: windows && mode.startsWith("SIG") && "platform: requires delivery of catchable POSIX signals",
    }, async () => {
        const directory = await mkdtemp(join(tmpdir(), "titan-node-group-"));
        const files = await descendantFixture(directory);
        let execution;
        try {
            const worker = join(directory, "worker.mjs");
            await writeFile(worker, `
                import { fork } from "node:child_process";
                import { once } from "node:events";
                import { writeFileSync } from "node:fs";
                export async function run(context) {
                    writeFileSync(${JSON.stringify(files.leader)}, String(process.pid));
                    const child = fork(${JSON.stringify(files.descendant)}, [], {stdio: ["ignore", "ignore", "ignore", "ipc"]});
                    await once(child, "message");
                    writeFileSync(${JSON.stringify(files.ready)}, "ready");
                    if (${JSON.stringify(mode)} === "leader-exit") process.exit(0);
                    const {run: block} = await import(${JSON.stringify(new URL("./runner-fixtures.mjs", import.meta.url).href)});
                    await block({...context, args: ["timeout"]});
                }
            `);
            execution = launch(["--engine", "node", "--timeout", mode === "deadline" ? "1500" : "10000",
                "--grace", "0", "--js-test", worker]);
            if (mode.startsWith("SIG")) {
                await until(async () => (await readFile(files.ready)).length > 0 &&
                    execution.stdout().includes(Buffer.from("hang-entered\n")));
                assert.equal(execution.child.kill(mode), true);
            }
            const result = await execution.result;
            assert.equal(result.status, mode === "deadline" ? 72 : 75, result.stderr.toString());
            if (mode.startsWith("SIG")) assert.ok(result.stderr.includes(Buffer.from(`interrupted by ${mode}`)));
            assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
            await descendantGone(files);
        } finally { await cleanupTrackedRun(execution, files, directory); }
    });
});

for (const cdp of ["pipe", "port"]) {
    test(`Chromium retires TERM-resistant profile-less descendants (${cdp})`,
        { skip: windows && "platform: exercises POSIX shebang and process-group termination" }, async t => {
        for (const mode of ["leader-exit", "deadline", "SIGINT", "SIGTERM"]) await t.test(mode, async () => {
            const directory = await mkdtemp(join(tmpdir(), "titan-chrome-group-"));
            const files = await descendantFixture(directory);
            let execution;
            try {
                const chrome = join(directory, "chrome");
                await writeFile(chrome, `#!${process.execPath}
                    const {fork} = require("node:child_process");
                    const {writeFileSync} = require("node:fs");
                    const {join} = require("node:path");
                    const net = require("node:net");
                    if (process.argv.includes("--version")) {
                        console.log("Chromium 156.0.8078.80");
                    } else {
                        writeFileSync(${JSON.stringify(files.leader)}, String(process.pid));
                        const child = fork(${JSON.stringify(files.descendant)}, [], {stdio: ["ignore", "ignore", "ignore", "ipc"]});
                        child.once("message", () => {
                            if (${JSON.stringify(mode)} === "leader-exit") process.exit(9);
                            if (process.argv.includes("--remote-debugging-port=0")) {
                                const profile = process.argv.find(arg => arg.startsWith("--user-data-dir=")).slice(16);
                                const server = net.createServer(() => writeFileSync(${JSON.stringify(files.connected)}, "connected"));
                                server.listen(0, "127.0.0.1", () => {
                                    writeFileSync(join(profile, "DevToolsActivePort"), server.address().port + "\\n/devtools/browser/pending\\n");
                                    writeFileSync(${JSON.stringify(files.ready)}, "ready");
                                });
                            } else writeFileSync(${JSON.stringify(files.ready)}, "ready");
                            setInterval(() => {}, 1000);
                        });
                    }
                `, { mode: 0o755 });
                execution = launch(["--engine", "chromium", "--chrome", chrome, "--cdp", cdp,
                    "--timeout", mode === "deadline" ? "1500" : "10000", "--grace", "0",
                    "--root", root, "--js-test", fixture]);
                if (mode.startsWith("SIG")) {
                    await until(async () => (await readFile(cdp === "port" ? files.connected : files.ready)).length > 0);
                    assert.equal(execution.child.kill(mode), true);
                }
                const result = await execution.result;
                assert.equal(result.status, mode === "deadline" ? 72 : 75, result.stderr.toString());
                if (mode.startsWith("SIG")) assert.ok(result.stderr.includes(Buffer.from(`interrupted by ${mode}`)));
                assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
                await descendantGone(files);
                await cleanChromium(result);
            } finally { await cleanupTrackedRun(execution, files, directory); }
        });
    });

    test(`SIGINT and SIGTERM retire Chromium while real Wasm is busy (${cdp})`,
        { skip: windows && "platform: Windows child.kill does not deliver catchable POSIX signals" }, async t => {
        if (!await chromium(t)) return;
        for (const signal of ["SIGINT", "SIGTERM"]) await t.test(signal, async () => {
            const execution = launch(["--engine", "chromium", "--cdp", cdp, "--timeout", "10000",
                "--grace", "0", "--root", root, "--js-test", fixture, "--", "timeout"]);
            try {
                await until(() => execution.stdout().includes(Buffer.from("hang-entered\n")));
                assert.equal(execution.child.kill(signal), true);
                const result = await execution.result;
                assert.equal(result.status, 75, result.stderr.toString());
                assert.ok(result.stderr.includes(Buffer.from(`interrupted by ${signal}`)));
                assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
                await cleanChromium(result);
            } finally {
                if (execution.child.exitCode === null && execution.child.signalCode === null) {
                    execution.child.kill("SIGTERM");
                    await execution.result;
                }
            }
        });
    });
}

test("owned group EPERM distinguishes retired members from live permission failures",
    { skip: windows && "platform: exercises POSIX process-group permission handling" }, async t => {
    for (const mode of ["empty", "zombie", "stale", "other-group", "live", "pid-denied"]) await t.test(mode, async () => {
        const directory = await mkdtemp(join(tmpdir(), "titan-group-eperm-"));
        const files = await descendantFixture(directory);
        const fault = await permissionFixture(directory, mode, files);
        let execution;
        let livePid;
        try {
            let args = ["--root", root, "--js-test", fixture, "--", "args"];
            if (mode === "live") {
                const worker = join(directory, "worker.mjs");
                await writeFile(worker, `
                    import {fork} from "node:child_process";
                    import {once} from "node:events";
                    import {writeFileSync} from "node:fs";
                    export async function run() {
                        writeFileSync(${JSON.stringify(files.leader)}, String(process.pid));
                        const child = fork(${JSON.stringify(files.descendant)}, [], {stdio: ["ignore", "ignore", "ignore", "ipc"]});
                        await once(child, "message");
                    }
                `);
                args = ["--js-test", worker];
            }
            execution = launch(["--engine", "node", "--timeout", "5000", "--grace", "0", ...args], fault.env);
            const result = await execution.result;
            const denied = mode === "live" || mode === "pid-denied";
            assert.equal(result.status, denied ? 75 : 0, result.stderr.toString());
            if (denied) assert.match(result.stderr.toString(), /cleanup failed: kill EPERM/);
            else assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
            const calls = (await readFile(fault.callsFile, "utf8")).trim().split("\n").map(line => JSON.parse(line));
            assert.ok(calls.some(call => call.pid < 0 && call.signal === "SIGTERM"), "group signal EPERM was not exercised");
            if (!denied) assert.ok(calls.some(call => call.pid < 0 && call.signal === 0), "group liveness EPERM was not exercised");
            if (["zombie", "other-group", "empty"].includes(mode)) {
                assert.equal(calls.some(call => call.pid > 0), false, "unowned/zombie PID was probed");
            } else assert.ok(calls.some(call => call.pid > 0 && call.signal === 0), "exact member PID was not probed");
            if (mode === "live") {
                livePid = JSON.parse(await readFile(files.record, "utf8")).pid;
                assert.equal(process.kill(livePid, 0), true, "test did not retain a real denied descendant");
            }
        } finally {
            await cleanupTrackedRun(execution, files, directory);
            if (livePid) await until(() => {
                try { process.kill(livePid, 0); return false; }
                catch (error) { if (error.code === "ESRCH") return true; throw error; }
            });
        }
    });
});

test("exact-profile PID EPERM ignores only retired processes",
    { skip: windows && "platform: exercises POSIX ps and PID permission handling" }, async t => {
    for (const mode of ["profile-zombie", "profile-stale", "profile-denied"]) await t.test(mode, async () => {
        const directory = await mkdtemp(join(tmpdir(), "titan-profile-eperm-"));
        const files = await descendantFixture(directory);
        const fault = await permissionFixture(directory, mode, files);
        let execution;
        try {
            const chrome = join(directory, "chrome");
            await writeFile(chrome, `#!${process.execPath}
                const {writeFileSync} = require("node:fs");
                if (process.argv.includes("--version")) console.log("Chromium 156.0.8078.80");
                else {
                    const path = process.argv.find(arg => arg.startsWith("--user-data-dir=")).slice(16);
                    writeFileSync(${JSON.stringify(fault.profileFile)}, JSON.stringify({pid: process.pid, path}));
                    process.exit(9);
                }
            `, { mode: 0o755 });
            execution = launch(["--engine", "chromium", "--chrome", chrome, "--cdp", "pipe",
                "--timeout", "5000", "--grace", "0", "--root", root, "--js-test", fixture], fault.env);
            const result = await execution.result;
            assert.equal(result.status, 75, result.stderr.toString());
            if (mode === "profile-denied") assert.match(result.stderr.toString(), /cleanup failed: kill EPERM/);
            else assert.doesNotMatch(result.stderr.toString(), /cleanup failed/);
            const calls = (await readFile(fault.callsFile, "utf8")).trim().split("\n").map(line => JSON.parse(line));
            assert.ok(calls.some(call => call.pid > 0 && call.signal === "SIGTERM"), "exact-profile signal EPERM was not exercised");
            await absent(cleanProfile(result));
        } finally { await cleanupTrackedRun(execution, files, directory); }
    });
});

for (const [engine, cdp] of [["node", "pipe"], ["chromium", "pipe"], ["chromium", "port"]]) {
    test(`required trace fails before main for direct and host-test images (${engine}/${cdp})`, async t => {
        const image = await missingTableImage(t);
        if (!image || (engine === "chromium" && !await chromium(t))) return;
        const directory = fixtureRoot(image.file);
        const imageArg = relative(directory, image.file).split(sep).join("/");
        const base = ["--engine", engine, "--cdp", cdp, "--grace", "0", "--root", directory];
        for (const entry of [
            [image.file, "--", "--filter=^runner_image[.]test_bytes$"],
            ["--js-test", join(root, "spec/fixtures/browser_trace_adapter/degraded.mjs"),
                "--", imageArg, "--filter=^runner_image[.]test_bytes$"],
        ]) {
            const failed = await run([...base, ...entry]);
            assert.equal(failed.status, 1, failed.stderr.toString());
            assert.match(failed.stderr.toString(), /degraded browser trace:/);
            assert.equal(failed.stdout.length, 0, "required-trace failure entered native main");
            const allowed = await run(["--allow-degraded-trace", ...base, ...entry]);
            assert.equal(allowed.status, 0, allowed.stderr.toString());
            assert.match(allowed.stdout.toString(), /\[  PASSED  \] 1 test\./);
            if (engine === "chromium") {
                await cleanChromium(failed);
                await cleanChromium(allowed);
            }
        }
    });
}

test("required trace uses the existing lazy initialization and disposal lifecycle", async t => {
    const image = await missingTableImage(t);
    if (!image) return;
    const {default: createImage} = await import(pathToFileURL(image.file).href);
    const decoder = new TextDecoder();
    const make = (extra = {}) => {
        const output = [], reports = [], counters = {located: 0};
        const instance = createImage({
            locateFile(name) { counters.located++; return join(image.directory, name); },
            stdout(bytes) { output.push(bytes); },
            stderr(bytes) { reports.push(bytes); },
            ...extra,
        });
        assert.equal(counters.located, 0, "create eagerly instantiated its image");
        assert.deepEqual(instance.trace, {state: "created", reason: null});
        return {instance, output, reports, counters};
    };
    const caught = async (promise, code) => {
        let error;
        try { await promise; } catch (cause) { error = cause; }
        assert.equal(error?.code, `TITAN_BROWSER_${code}`);
        return error;
    };
    const bytes = chunks => Buffer.concat(chunks.map(chunk => Buffer.from(chunk)));
    const args = ["--filter=^runner_image[.]test_bytes$"];
    assert.throws(() => createImage({requireTrace: 1}), /requireTrace must be a boolean/);

    const optional = make();
    try {
        const first = optional.instance.initialize();
        assert.equal(first, optional.instance.initialize());
        await first;
        assert.ok(optional.counters.located > 0);
        assert.equal(optional.instance.trace.state, "degraded");
        const result = await optional.instance.run(args);
        assert.equal(result.kind, "returned");
        assert.equal(result.status, 0, bytes(optional.reports).toString());
        assert.match(bytes(optional.output).toString(), /\[  PASSED  \] 1 test\./);
        await optional.instance.dispose();
        assert.equal(optional.instance.trace.state, "degraded");
    } finally { await optional.instance.dispose(); }

    const strictImage = make({requireTrace: true});
    try {
        await caught(strictImage.instance.call(undefined), "STATE");
        await caught(strictImage.instance.drain(), "STATE");
        const first = strictImage.instance.initialize();
        assert.equal(first, strictImage.instance.initialize());
        await caught(strictImage.instance.run(args), "REENTRY");
        const error = await caught(first, "TITAN");
        assert.equal(error.status, 1);
        assert.equal(error.trace, undefined, "pre-Lua failure fabricated a Titan trace");
        assert.match(decoder.decode(error.bytes), /^degraded browser trace:/);
        assert.equal(first, strictImage.instance.initialize(), "failed initialize lost its saved promise");
        assert.equal(strictImage.output.length, 0);
        const report = bytes(strictImage.reports);
        const result = await strictImage.instance.run(args);
        assert.equal(result.kind, "failed");
        assert.equal(result.status, 1);
        assert.deepEqual(result.bytes, error.bytes);
        assert.deepEqual(bytes(strictImage.reports), report, "run repeated the initialization report");
        await caught(strictImage.instance.run(args), "STATE");
        await caught(strictImage.instance.call(undefined), "STATE");
        await caught(strictImage.instance.drain(), "STATE");
        const disposal = strictImage.instance.dispose();
        assert.equal(disposal, strictImage.instance.dispose());
        await disposal;
        assert.equal(strictImage.instance.trace.state, "degraded");
        await caught(strictImage.instance.initialize(), "DISPOSED");
    } finally { await strictImage.instance.dispose(); }

    const automatic = make({requireTrace: true});
    try {
        const running = automatic.instance.run(args);
        await caught(automatic.instance.run(args), "REENTRY");
        const result = await running;
        assert.equal(result.kind, "failed");
        assert.equal(result.status, 1);
        const first = automatic.instance.initialize();
        assert.equal(first, automatic.instance.initialize());
        const error = await caught(first, "TITAN");
        assert.equal(error.trace, undefined);
        assert.deepEqual(result.bytes, error.bytes);
        await caught(automatic.instance.run(args), "STATE");
        assert.equal(automatic.output.length, 0);
    } finally { await automatic.instance.dispose(); }

    let begin, release, calls = 0;
    const started = new Promise(resolve => { begin = resolve; });
    const pending = new Promise(resolve => { release = resolve; });
    const cleanup = [];
    const interrupted = make({requireTrace: true, stderr() { calls++; begin(); return pending; },
        onNotificationError(event) { cleanup.push(event); }});
    try {
        const initializing = interrupted.instance.initialize();
        const failure = caught(initializing, "TITAN");
        await started;
        const disposal = interrupted.instance.dispose();
        const error = await failure;
        assert.equal(error.trace, undefined);
        assert.match(decoder.decode(error.bytes), /^degraded browser trace:/);
        const interruption = await caught(disposal, "DISPOSED");
        assert.equal(cleanup.length, 1);
        assert.equal(cleanup[0].kind, "cleanup");
        assert.equal(cleanup[0].operation, "initialize");
        assert.equal(cleanup[0].error, interruption);
        assert.equal(interrupted.instance.trace.state, "degraded");
        assert.equal(interrupted.output.length, 0);
        await caught(interrupted.instance.run(args), "DISPOSED");
        release();
        await new Promise(resolve => setTimeout(resolve, 0));
        assert.equal(calls, 1, "late trace-report sink settlement revived the disposed stream");
        assert.equal(cleanup.length, 1, "late sink settlement repeated the cleanup interruption");
    } finally {
        release();
        await interrupted.instance.dispose().catch(() => {});
    }
});

test("initialization waits for one delayed trace lookup and degrades a throwing trace locator", async t => {
    const image = testImage(t);
    if (!image) return;
    const {default: createImage} = await import(pathToFileURL(image).href);
    const directory = dirname(image);
    const wasmName = basename(image).replace(/\.mjs$/, ".wasm");
    const traceName = `${wasmName}.trace`;
    const table = await readFile(join(directory, traceName));
    const args = ["--filter=^runner_image[.]test_bytes$"];
    // An HTTP source holds the table until the test releases it, while the
    // Wasm itself loads from the image directory.
    let requests = 0, release, requested;
    const held = new Promise(resolve => { release = resolve; });
    const firstRequest = new Promise(resolve => { requested = resolve; });
    const server = createServer(async (request, response) => {
        requests++;
        requested();
        await held;
        response.writeHead(200, {"Content-Type": "application/octet-stream"});
        response.end(table);
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const tableUrl = `http://127.0.0.1:${server.address().port}/${traceName}`;
    const lookups = [];
    const delayed = createImage({
        locateFile(name) {
            lookups.push(name);
            return name === traceName ? tableUrl : join(directory, name);
        },
        stdout() {},
    });
    try {
        let settled = false;
        const initializing = delayed.initialize();
        initializing.then(() => { settled = true; }, () => { settled = true; });
        // Wait for the held request, but no longer than initialization lasts
        // or a bounded time.
        const early = initializing.then(() => {
            throw new Error("initialization finished before requesting its trace table");
        });
        early.catch(() => {});
        let timer;
        await Promise.race([
            firstRequest,
            early,
            new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error("the image never requested its trace table")), 30000);
            }),
        ]).finally(() => clearTimeout(timer));
        // The Wasm compiles while the table is held; the loader runs the C
        // constructors only after the factory has indexed the table.
        await new Promise(resolve => setTimeout(resolve, 250));
        assert.equal(settled, false, "initialization finished before its trace table arrived");
        assert.notEqual(delayed.trace.state, "ready");
        release();
        await initializing;
        assert.equal(delayed.trace.state, "ready");
        const result = await delayed.run(args);
        assert.equal(result.kind, "returned");
        assert.equal(result.status, 0);
        assert.deepEqual(lookups.slice().sort(), [wasmName, traceName].sort(),
            "the image looked a resource up more than once");
        assert.equal(requests, 1, "the trace table was fetched more than once");
    } finally {
        release();
        await delayed.dispose();
    }

    // A locator that throws for the optional table degrades the trace like a
    // missing file; a required table fails initialization with its reason.
    const decoder = new TextDecoder();
    for (const requireTrace of [false, true]) {
        const instance = createImage({
            requireTrace,
            locateFile(name) {
                if (name === traceName) throw new Error("trace locator refused");
                return join(directory, name);
            },
            stdout() {},
            stderr() {},
        });
        try {
            if (!requireTrace) {
                await instance.initialize();
                assert.equal(instance.trace.state, "degraded");
                assert.match(instance.trace.reason, /trace locator refused/);
                const result = await instance.run(args);
                assert.equal(result.kind, "returned");
                assert.equal(result.status, 0);
            } else {
                let error;
                try { await instance.initialize(); } catch (cause) { error = cause; }
                assert.equal(error?.code, "TITAN_BROWSER_TITAN");
                assert.match(decoder.decode(error.bytes), /^degraded browser trace: .*trace locator refused/);
            }
        } finally {
            await instance.dispose();
        }
    }
});

test("image observer forwards trace policy without owning another lifecycle", () => {
    for (const allow of [false, true]) {
        const instance = {};
        const controls = [];
        let options;
        const creator = observeImage(value => { options = value; return instance; },
            value => controls.push(value), allow);
        assert.equal(creator({requireTrace: allow}), instance);
        assert.equal(options.requireTrace, !allow);
        assert.deepEqual(controls, []);
    }
});

test("imported runner helpers leave CLI dormant and preserve supervisor behavior", async () => {
    const monitor = new Monitor({timeout: 1000, grace: 0});
    try {
        monitor.control({type: "complete", kind: "returned", status: -1});
        await monitor.done;
        assert.equal(monitor.result(), 255);
    } finally { monitor.stop(); }
    assert.equal(within(root, root), true);
    assert.equal(within(root, join(root, "spec/browser")), true);
    assert.equal(within(root, root + "-sibling"), false);
    assert.equal(within(root, dirname(root)), false);
});

test("direct invocation through a symlink still runs the runner CLI",
    { skip: windows && "capability: unprivileged Windows links may not be traversable" }, async () => {
    const directory = await mkdtemp(join(tmpdir(), "titan-runner-import-"));
    try {
        const link = join(directory, "runner.mjs");
        await symlink(join(root, "titan-runtime/browser/titan-browser-run.mjs"), link);
        const {stderr} = await exec(process.execPath, [link, "--version"]);
        const header = await readFile(join(root, "titan-runtime/titan.h"), "utf8");
        const release = header.match(/^#define TITAN_VERSION "(\d+\.\d+\.\d+)"$/m);
        assert.ok(release, "titan.h must declare the package version");
        assert.ok(stderr.includes(`Titan ${release[1]} browser runner`), stderr);
    } finally { await rm(directory, {recursive: true, force: true}); }
});

// The identity these fake images export, as a linked image's Wasm does, and
// the image description that the generated module passes to the loader.
const IMAGE = "0123456789abcdef".repeat(4);
const LINKED = {identity: IMAGE, wasm: "app.wasm"};

// Transport-only unit fixture, not linked-image acceptance evidence. Each
// promised gateway uses the current operation-id/kind completion protocol.
function entryOutcomeFactory(entry) {
    return owner => {
        owner.backend = {safe: () => true, poison() {}};
        const complete = (id, kind, status = 0, bytes = new Uint8Array()) =>
            owner.complete({id, kind, failed: false, status, bytes,
                trace: new Uint8Array(), values: []});
        return {
            HEAPU8: new TextEncoder().encode(IMAGE),
            exports: {
                _initialize() {},
                titan_browser_trace_identity() { return 0; },
                titan_browser_initialize(id) { complete(id, 1); return Promise.resolve(0); },
                titan_browser_entry(id) { return entry(owner, id); },
                titan_browser_close(id) { complete(id, 5); return Promise.resolve(0); },
            },
        };
    };
}

test("a Wasm from another link is a protocol failure before Lua", {timeout: 1000}, async () => {
    let entered = false;
    const other = "f".repeat(64);
    const instance = create(owner => {
        const image = entryOutcomeFactory(() => Promise.resolve(0))(owner);
        image.exports.titan_browser_initialize = () => { entered = true; return Promise.resolve(0); };
        return image;
    }, {}, {identity: other, wasm: "app.wasm"});
    try {
        const expected = {code: "TITAN_BROWSER_PROTOCOL", message: "browser image mismatch: app.mjs belongs to image " +
            `${other.slice(0, 12)}, app.wasm is image ${IMAGE.slice(0, 12)}`};
        await assert.rejects(instance.initialize(), expected);
        await assert.rejects(instance.run(), expected);
        assert.equal(entered, false);
    } finally { await instance.dispose(); }
});

test("the loader refuses a malformed image binding and a Wasm without its identity export", {timeout: 1000}, async () => {
    const factory = entryOutcomeFactory(() => Promise.resolve(0));
    for (const image of [undefined, {}, {identity: IMAGE.toUpperCase(), wasm: "app.wasm"},
        {identity: IMAGE}, {identity: IMAGE, wasm: "app.mjs"}]) {
        assert.throws(() => create(factory, {}, image), {name: "TypeError",
            message: "browser image binding must name a 64-digit identity and its .wasm"});
    }
    const instance = create(owner => {
        const image = factory(owner);
        delete image.exports.titan_browser_trace_identity;
        return image;
    }, {}, LINKED);
    try {
        const expected = {code: "TITAN_BROWSER_PROTOCOL", message: "browser image does not provide Titan channels"};
        await assert.rejects(instance.initialize(), expected);
        await assert.rejects(instance.run(), expected);
    } finally { await instance.dispose(); }
});

for (const mode of ["synchronous throw", "promise rejection"]) {
    test(`promised export ${mode} preserves its original RangeError`, {timeout: 1000}, async () => {
        const cause = new RangeError("entry stack exhausted");
        const instance = create(entryOutcomeFactory(() => {
            if (mode === "synchronous throw") throw cause;
            return Promise.reject(cause);
        }), {}, LINKED);
        try {
            await assert.rejects(instance.run(), error =>
                error.code === "TITAN_BROWSER_PROTOCOL" &&
                error.message === cause.message && error.cause === cause);
        } finally { await instance.dispose(); }
    });
}

test("fulfilled export without completion still reports protocol failure", {timeout: 1000}, async () => {
    const instance = create(entryOutcomeFactory(() => Promise.resolve(0)), {}, LINKED);
    try {
        await assert.rejects(instance.run(), {
            code: "TITAN_BROWSER_PROTOCOL", message: "browser entry returned without completion",
        });
    } finally { await instance.dispose(); }
});

test("loader refuses missing JSPI and memoizes failure for initialize and run", async () => {
    const descriptor = Object.getOwnPropertyDescriptor(WebAssembly, "promising");
    let calls = 0;
    const instance = create(() => { calls++; }, {}, LINKED);
    try {
        Object.defineProperty(WebAssembly, "promising", {...descriptor, value: undefined});
        const initializing = instance.initialize();
        assert.equal(instance.initialize(), initializing);
        const expected = {code: "TITAN_BROWSER_CAPABILITY",
            message: "Titan browser images require WebAssembly JSPI (Node 26 or a JSPI-capable browser)"};
        await assert.rejects(initializing, expected);
        assert.equal(instance.initialize(), initializing);
        await assert.rejects(instance.run(), expected);
        assert.equal(calls, 0);
    } finally {
        if (descriptor) Object.defineProperty(WebAssembly, "promising", descriptor);
        else delete WebAssembly.promising;
        await instance.dispose();
    }
});

test("completion waits for promised retirement and ignores numeric fulfillment", {timeout: 1000}, async () => {
    let release;
    const retired = new Promise(resolve => { release = resolve; });
    const instance = create(entryOutcomeFactory((owner, id) => {
        owner.complete({id, kind: 2, failed: false, status: 17,
            bytes: new Uint8Array([0, 255]), trace: new Uint8Array(), values: []});
        return retired;
    }), {}, LINKED);
    let settled = false;
    const running = instance.run();
    running.then(() => { settled = true; }, () => { settled = true; });
    try {
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(settled, false, "copied completion released an unretired entry");
        release(-923);
        assert.deepEqual(await running,
            {kind: "returned", status: 17, bytes: new Uint8Array([0, 255]), trace: new Uint8Array()});
    } finally { release(-923); await instance.dispose(); }
});

test("dispose waits accepted retirement but interrupts the application result", {timeout: 1000}, async () => {
    let release;
    const retired = new Promise(resolve => { release = resolve; });
    const instance = create(entryOutcomeFactory((owner, id) => {
        owner.complete({id, kind: 2, failed: false, status: 17,
            bytes: new Uint8Array(), trace: new Uint8Array(), values: []});
        return retired;
    }), {}, LINKED);
    const running = instance.run();
    const interrupted = assert.rejects(running, {code: "TITAN_BROWSER_DISPOSED"});
    let disposed = false;
    try {
        await new Promise(resolve => setImmediate(resolve));
        const disposing = instance.dispose().then(() => { disposed = true; });
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(disposed, false, "disposal dropped an accepted continuation");
        release(-923);
        await interrupted;
        await disposing;
    } finally { release(-923); await instance.dispose(); }
});
