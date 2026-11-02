import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { classify, knownTrap, observeFactory, relativePath } from "../../titan-runtime/browser/titan-browser-page.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const runner = resolve(process.env.TITAN_BROWSER_RUNNER ?? join(root, "titan-runtime/browser/titan-browser-run"));
const fixture = join(root, "spec/browser/runner-fixtures.mjs");
const supported = process.platform !== "win32";
const strict = process.env.TITAN_REQUIRE_BROWSER_TOOLCHAIN === "1";
const exec = promisify(execFile);

function testImage(t) {
    const image = process.env.TITAN_BROWSER_RUNNER_IMAGE;
    if (image) return resolve(image);
    if (strict) assert.fail("TITAN_BROWSER_RUNNER_IMAGE must name the compiled runner_image fixture");
    t.skip("TITAN_BROWSER_RUNNER_IMAGE is unset");
    return null;
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

function launch(args, env = {}) {
    const child = spawn(runner, args, { cwd: tmpdir(), env: { ...process.env, TITAN_NODE: process.execPath, ...env } });
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

function run(args, env = {}) { return launch(args, env).result; }

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
    const { stdout } = await exec("ps", ["-axo", "pid=,args="]);
    assert.equal(stdout.includes(`--user-data-dir=${path}`), false, `Chromium process still owns ${path}`);
}

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
    assert.match(await readFile(files.term, "utf8"), /TERM\n/, "descendant never observed and resisted group SIGTERM");
    assert.throws(() => process.kill(record.pid, 0), { code: "ESRCH" }, "TERM-resistant descendant survived");
    assert.throws(() => process.kill(-leader, 0), { code: "ESRCH" }, "owned process group survived");
}

async function cleanupTrackedRun(execution, files, directory) {
    try {
        if (execution && execution.child.exitCode === null && execution.child.signalCode === null) {
            execution.child.kill("SIGTERM");
            await execution.result;
        }
    } finally {
        try {
            // Retire the recorded, test-owned group even if a regression failed.
            const leader = Number(await readFile(files.leader, "utf8"));
            if (leader > 0) process.kill(-leader, "SIGKILL");
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
    const factory = observeFactory(options => options.onAbort("late"), value => events.push(value));
    const sentinel = new Error("caller abort");
    assert.throws(() => factory({ onAbort() { events.push("caller"); throw sentinel; } }), error => error === sentinel);
    assert.deepEqual(events, ["caller", { type: "abort", reason: "late" }]);
});

test("launcher rejects absent and wrong-major Node without stdout", { skip: !supported }, async () => {
    const missing = join(tmpdir(), "titan-missing-node-329");
    const result = await run(["--probe"], { TITAN_NODE: missing });
    assert.equal(result.status, 75);
    assert.equal(result.stdout.length, 0);
    assert.equal(result.stderr.toString(), `titan-browser-run: Node 24 is required (node not executable at "${missing}")\n`);
    const noPath = await run(["--probe"], { TITAN_NODE: undefined, PATH: "" });
    assert.equal(noPath.status, 75);
    assert.equal(noPath.stdout.length, 0);
    assert.equal(noPath.stderr.toString(), "titan-browser-run: Node 24 is required (node not found (TITAN_NODE unset; not on PATH))\n");
    const explicit = await run(["--probe"], { PATH: "", TITAN_CHROME: "/missing/chrome-329" });
    assert.equal(explicit.status, 0, explicit.stderr.toString());
    const dir = await mkdtemp(join(tmpdir(), "titan-node-resolver-"));
    try {
        const node = join(dir, "node");
        await writeFile(node, "#!/bin/sh\nprintf 'v22.23.4\\n'\n", { mode: 0o755 });
        const wrong = await run(["--probe"], { TITAN_NODE: node });
        assert.equal(wrong.status, 75);
        assert.equal(wrong.stdout.length, 0);
        assert.equal(wrong.stderr.toString(), `titan-browser-run: Node 24 is required ("${node}" reports v22.23.4; expected Node 24)\n`);
    } finally { await rm(dir, { recursive: true, force: true }); }
});

test("probe is closed JSON and needs no SDK or browser launch", { skip: !supported }, async () => {
    const result = await run(["--probe"], { TITAN_CHROME: "/missing/chrome-329" });
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
    assert.equal(info.chrome.path, "/missing/chrome-329");
    assert.equal(info.chrome.version, null);
    assert.ok(info.chrome.reason);
});

test("CLI misuse is 2 and absent image is harness 75", { skip: !supported }, async () => {
    for (const args of [[], ["--engine", "bad", fixture], ["--timeout", "0", fixture], ["--grace", "-1", fixture], ["--cdp", "bad", fixture]]) {
        const result = await run(args);
        assert.equal(result.status, 2, result.stderr.toString());
        assert.equal(result.stdout.length, 0);
        assert.match(result.stderr.toString(), /usage: titan-browser-run/);
    }
    const result = await run(["/missing/image-329.mjs"]);
    assert.equal(result.status, 75);
    assert.equal(result.stdout.length, 0);
    assert.match(result.stderr.toString(), /titan-browser-run: harness failure:/);
});

for (const engine of ["node", "chromium"]) {
    for (const cdp of engine === "node" ? ["pipe"] : ["pipe", "port"]) {
        test(`portable frozen context, GC, exact bytes, and cleanup (${engine}/${cdp})`, { skip: !supported }, async t => {
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
        });
        test(`real CLI test image preserves bytes and 0/1/2 status (${engine}/${cdp})`, { skip: !supported }, async t => {
            const image = testImage(t);
            if (!image) return;
            if (engine === "chromium" && !await chromium(t)) return;
            const passed = await run(["--engine", engine, "--cdp", cdp, "--grace", "20", image,
                "--", "--filter=^runner_image[.]test_bytes$"]);
            assert.equal(passed.status, 0, passed.stderr.toString());
            const expected = Buffer.concat([
                Buffer.from("[==========] Running Titan tests.\n[ RUN      ] runner_image.test_bytes\n"),
                Buffer.from([0, 255, 195, 40, 116, 97, 105, 108]),
                Buffer.from("[       OK ] runner_image.test_bytes\n[==========] 1 test ran.\n[  PASSED  ] 1 test.\n"),
            ]);
            assert.deepEqual(passed.stdout, expected);
            const rawStderr = engine === "node" ? passed.stderr : Buffer.from(passed.stderr.toString("latin1")
                .replace(/titan-browser-run: (?:Chromium|cleanup:)[^\n]*\n/g, ""), "latin1");
            assert.deepEqual(rawStderr, Buffer.from([0, 254, 226, 40, 116, 97, 105, 108]));
            const failed = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image,
                "--", "--filter=^runner_image[.]test_failure$"]);
            assert.equal(failed.status, 1, failed.stderr.toString());
            assert.ok(failed.stdout.includes(Buffer.from("[==========] 1 test ran.\n")));
            assert.ok(failed.stdout.includes(Buffer.from("[  FAILED  ] 1 test.\n")));
            const invalid = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", image, "--", "--unknown"]);
            assert.equal(invalid.status, 2, invalid.stderr.toString());
            assert.equal(invalid.stdout.toString(), "error: unknown option '--unknown'\n" +
                "Usage: <test-executable> [-h|--help] [-v|--verbose] [-f PATTERN|--filter=PATTERN]...\n");
            if (engine === "chromium") for (const result of [passed, failed, invalid]) await cleanChromium(result);
        });
        test(`failure categories and bounded cleanup (${engine}/${cdp})`, { skip: !supported }, async t => {
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
                ["sink-thenable", 76, /titan-browser-run: sink failure: browser stdout sink must return undefined/],
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
        for (const [phase, fixtureName] of [["suspended", "abort-dispose"], ["initializing", "initialize-abort"]]) {
            test(`fatal ${phase} abort completes disposal before shutdown (${engine}/${cdp})`, { skip: !supported }, async t => {
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
                    relative(directory, image).split(sep).join("/")]);
                assert.equal(result.status, 70, result.stderr.toString());
                assert.deepEqual(result.stdout, Buffer.from("dispose-complete\n"), "abort status alone does not prove fatal disposal finished");
                assert.ok(performance.now() - before < 5000, "fatal disposal waited for an unusable instance");
                if (engine === "chromium") await cleanChromium(result);
            });
        }
        test(`JS module/path isolation and long deadlines (${engine}/${cdp})`, { skip: !supported }, async t => {
            if (engine === "chromium" && !await chromium(t)) return;
            const directory = await mkdtemp(join(tmpdir(), "titan runner-"));
            try {
                const inside = join(directory, "inside");
                const outside = join(directory, "outside");
                await mkdir(inside); await mkdir(outside);
                await writeFile(join(outside, "secret"), "not a served asset");
                await writeFile(join(outside, "image.mjs"), "export default function forbidden() {};\n");
                await symlink(outside, join(inside, "escape"), "dir");
                const file = join(inside, "fixture unicode λ.mjs");
                // Fetch and instantiate a real sibling Wasm whose filename contains
                // URL query/fragment characters, not merely inspect its locateFile URL.
                await writeFile(join(inside, "sibling #?.wasm"), new Uint8Array([
                    0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127,
                    3, 2, 1, 0, 7, 10, 1, 6, 97, 110, 115, 119, 101, 114, 0, 0,
                    10, 6, 1, 4, 0, 65, 42, 11,
                ]));
                await writeFile(join(inside, "factory #?.mjs"), `export default async ({locateFile}) => {
                    const filename = locateFile("sibling #?.wasm");
                    const bytes = typeof process === "object" && process.versions?.node ?
                        await (await import("node:fs/promises")).readFile(filename) :
                        await (await fetch(filename)).arrayBuffer();
                    return new WebAssembly.Instance(await WebAssembly.compile(bytes)).exports.answer();
                };\n`);
                await writeFile(file, `export async function run(context) {
                    for (const [method, path] of [["bytes", "escape/secret"], ["image", "escape/image.mjs"]]) {
                        let rejected = false;
                        try { await context[method](path); } catch { rejected = true; }
                        context.assert(rejected, "symlink escaped --root");
                    }
                    const image = await context.image("factory #?.mjs");
                    context.assert(await image.factory({locateFile: image.locateFile}) === 42,
                        "real special-name sibling Wasm was not fetched and instantiated");
                }\n`);
                const isolated = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--js-test", file]);
                assert.equal(isolated.status, 0, isolated.stderr.toString());
                if (engine === "chromium") await cleanChromium(isolated);
                await writeFile(file, "export const notRun = true;\n");
                const missing = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--js-test", file]);
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
        test(`application signed status is masked only at CLI exit (${engine}/${cdp})`, { skip: !supported }, async t => {
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
    test(`launch/connect failure retires only its own process and profile (${cdp})`, { skip: !supported }, async t => {
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

test("Node retires TERM-resistant descendants independently of its worker leader", { skip: !supported }, async t => {
    for (const mode of ["leader-exit", "deadline", "SIGINT", "SIGTERM"]) await t.test(mode, async () => {
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
    test(`Chromium retires TERM-resistant profile-less descendants (${cdp})`, { skip: !supported }, async t => {
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

    test(`SIGINT and SIGTERM retire Chromium while real Wasm is busy (${cdp})`, { skip: !supported }, async t => {
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

test("owned group EPERM distinguishes retired members from live permission failures", { skip: !supported }, async t => {
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

test("exact-profile PID EPERM ignores only retired processes", { skip: !supported }, async t => {
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

test("degraded trace metadata fails runner unless explicitly allowed", {skip: !supported}, async () => {
    const base = ["--engine", "node", "--grace", "0", "--root", root, "--js-test", fixture,
        "--", "trace-policy"];
    const strictResult = await run(base);
    assert.equal(strictResult.status, 75, strictResult.stderr.toString());
    assert.match(strictResult.stderr.toString(), /degraded browser trace: intentional missing map/);
    const allowed = await run(["--allow-degraded-trace", ...base]);
    assert.equal(allowed.status, 0, allowed.stderr.toString());
});

test("factory observer admits ready and fabricated metadata-free factories", async () => {
    for (const module of [{titanBrowserTrace: {state: "ready"}}, {}]) {
        const controls = [];
        assert.equal(await observeFactory(async () => module, value => controls.push(value))({}), module);
        assert.deepEqual(controls, []);
    }
});
