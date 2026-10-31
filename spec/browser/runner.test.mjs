import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
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

function run(args, env = {}) {
    return new Promise((resolve, reject) => {
        const child = spawn(runner, args, { cwd: tmpdir(), env: { ...process.env, TITAN_NODE: process.execPath, ...env } });
        let hard;
        const deadline = setTimeout(() => {
            child.kill("SIGTERM");
            hard = setTimeout(() => child.kill("SIGKILL"), 3000);
        }, 45000);
        const stdout = [], stderr = [];
        child.stdout.on("data", chunk => stdout.push(chunk));
        child.stderr.on("data", chunk => stderr.push(chunk));
        child.on("error", error => { clearTimeout(deadline); reject(error); });
        child.on("close", (status, signal) => {
            clearTimeout(deadline); clearTimeout(hard);
            resolve({ status, signal, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) });
        });
    });
}

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
        test(`fatal abort drops a forever-pending ccall before shutdown (${engine}/${cdp})`, { skip: !supported }, async t => {
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
                "--js-test", join(root, "spec/fixtures/browser_loader/abort-dispose.mjs"), "--",
                relative(directory, image).split(sep).join("/")]);
            assert.equal(result.status, 70, result.stderr.toString());
            assert.deepEqual(result.stdout, Buffer.from("dispose-complete\n"), "abort status alone does not prove fatal disposal finished");
            assert.ok(performance.now() - before < 5000, "fatal disposal waited for the pending internal ccall");
            if (engine === "chromium") await cleanChromium(result);
        });
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
                // Path-only factory fixture: real Wasm execution is exercised above.
                await writeFile(join(inside, "factory #?.mjs"),
                    "export default ({locateFile}) => locateFile('sibling #?.wasm');\n");
                await writeFile(file, `export async function run(context) {
                    for (const [method, path] of [["bytes", "escape/secret"], ["image", "escape/image.mjs"]]) {
                        let rejected = false;
                        try { await context[method](path); } catch { rejected = true; }
                        context.assert(rejected, "symlink escaped --root");
                    }
                    const image = await context.image("factory #?.mjs");
                    const located = image.factory({locateFile: image.locateFile});
                    context.assert(located.endsWith(context.engine === "node" ?
                        "/sibling #?.wasm" : "/sibling%20%23%3F.wasm"), "locateFile treated filename bytes as a URL query/fragment");
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
        const banner = "if [ \"$1\" = --version ]; then printf 'Chromium 156.0.8078.80\\n'; exit 0; fi\n";
        try {
            const scripts = [
                ["exit", banner + "exit 9\n", 75],
                ["connect", banner + "for arg in \"$@\"; do case \"$arg\" in --user-data-dir=*) profile=${arg#--user-data-dir=} ;; esac; done\n" +
                    "printf '1\\n/devtools/browser/missing\\n' > \"$profile/DevToolsActivePort\"\nexec /bin/sleep 60\n", cdp === "port" ? 75 : 72],
                ["spawn", "if [ \"$1\" = --version ]; then printf 'Chromium 156.0.8078.80\\n'; rm -- \"$0\"; exit 0; fi\nexit 9\n", 75],
            ];
            for (const [name, script, status] of scripts) await t.test(name, async () => {
                await writeFile(chrome, "#!/bin/sh\n" + script, { mode: 0o755 });
                const before = performance.now();
                const result = await run(["--engine", "chromium", "--chrome", chrome, "--cdp", cdp,
                    "--timeout", "700", "--grace", "0", "--root", root, "--js-test", fixture]);
                assert.equal(result.status, status, result.stderr.toString());
                assert.equal(result.stdout.length, 0);
                assert.ok(performance.now() - before < 10000, "launch/connect cleanup was not bounded");
                await cleanChromium(result);
            });
        } finally { await rm(directory, { recursive: true, force: true }); }
    });
}
