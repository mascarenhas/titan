import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { classify, knownTrap, observeFactory, relativePath } from "../../titan-runtime/browser/titan-browser-page.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const runner = join(root, "titan-runtime/browser/titan-browser-run");
const fixture = join(root, "spec/browser/runner-fixtures.mjs");
const supported = process.platform !== "win32";
const strict = process.env.TITAN_REQUIRE_BROWSER_TOOLCHAIN === "1";

function run(args, env = {}) {
    return new Promise((resolve, reject) => {
        const child = spawn(runner, args, { env: { ...process.env, TITAN_NODE: process.execPath, ...env } });
        const stdout = [], stderr = [];
        child.stdout.on("data", chunk => stdout.push(chunk));
        child.stderr.on("data", chunk => stderr.push(chunk));
        child.on("error", reject);
        child.on("close", (status, signal) => resolve({ status, signal, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) }));
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
    const match = /profile ("[^"\n]+")/.exec(text);
    assert.ok(match, text);
    const path = JSON.parse(match[1]);
    assert.ok(text.includes(`cleanup: profile ${JSON.stringify(path)} removed`), text);
    return path;
}

async function absent(path) {
    await assert.rejects(readFile(path), { code: "ENOENT" });
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
    assert.deepEqual(events, ["caller", { type: "failure", category: "abort", reason: "late" }]);
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
                await absent(cleanProfile(result));
            }
            const args = ["a b", "--option", "λ"];
            const forwarded = await run(["--engine", engine, "--cdp", cdp, "--grace", "0", "--root", root, "--js-test", fixture, "--", "args", ...args]);
            assert.equal(forwarded.status, 0, forwarded.stderr.toString());
            assert.deepEqual(forwarded.stdout, Buffer.from(JSON.stringify(args)));
            if (engine === "chromium") await absent(cleanProfile(forwarded));
        });
    }
}
