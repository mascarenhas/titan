import { spawn, execFile } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdtemp, readFile, realpath, rm, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { delimiter, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const assets = dirname(fileURLToPath(import.meta.url));
const diagnostic = text => process.stderr.write(`titan-browser-run: ${text}\n`);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function later(callback, milliseconds) {
    // Node clamps delays above INT32_MAX to 1ms. Preserve the CLI's millisecond
    // contract by arming bounded slices against a monotonic deadline instead.
    const end = performance.now() + milliseconds;
    let timer;
    function arm() {
        timer = setTimeout(() => {
            if (performance.now() >= end) callback();
            else arm();
        }, Math.min(Math.max(0, end - performance.now()), 2147483647));
    }
    arm();
    return () => clearTimeout(timer);
}

async function bounded(promise, milliseconds) {
    let timer;
    try {
        return await Promise.race([promise, new Promise(resolve => {
            timer = setTimeout(resolve, milliseconds);
        })]);
    } finally { clearTimeout(timer); }
}
const usage = "usage: titan-browser-run [--engine node|chromium] [--timeout MS] [--grace MS]\n" +
    "                         [--chrome PATH] [--cdp pipe|port] [--root DIR]\n" +
    "                         [--allow-degraded-trace] [--js-test] FILE [-- ARG...]\n";

function parse(argv) {
    const options = { engine: "node", timeout: 30000, grace: 1500, cdp: "pipe", args: [], jsTest: false };
    const values = new Set(["engine", "timeout", "grace", "chrome", "cdp", "root"]);
    for (let index = 0; index < argv.length; index++) {
        const arg = argv[index];
        if (arg === "--") { options.args = argv.slice(index + 1); break; }
        if (arg === "--help" || arg === "-h") { options.help = true; continue; }
        if (arg === "--version") { options.version = true; continue; }
        if (arg === "--probe") { options.probe = true; continue; }
        if (arg === "--js-test") { options.jsTest = true; continue; }
        if (arg === "--allow-degraded-trace") { options.allowDegradedTrace = true; continue; }
        if (arg.startsWith("--") && values.has(arg.slice(2))) {
            if (++index === argv.length) throw new Error(`${arg} requires a value`);
            options[arg.slice(2)] = argv[index];
        } else if (arg.startsWith("-")) throw new Error(`unknown option ${arg}`);
        else if (options.file) throw new Error("only one FILE is allowed; pass program arguments after --");
        else options.file = arg;
    }
    if (!["node", "chromium"].includes(options.engine)) throw new Error("--engine must be node or chromium");
    if (!["pipe", "port"].includes(options.cdp)) throw new Error("--cdp must be pipe or port");
    for (const key of ["timeout", "grace"]) {
        if (!/^\d+$/.test(String(options[key])) || !Number.isSafeInteger(Number(options[key])) ||
            (key === "timeout" && Number(options[key]) === 0)) {
            throw new Error(`--${key} must be ${key === "timeout" ? "a positive" : "a nonnegative"} safe integer number of milliseconds`);
        }
        options[key] = Number(options[key]);
    }
    if (!options.help && !options.version && !options.probe && !options.file) throw new Error("FILE is required");
    if (options.probe && (options.file || options.args.length || options.jsTest)) throw new Error("--probe does not accept FILE or arguments");
    return options;
}

async function executable(value) {
    if (!value) return null;
    const candidates = value.includes("/") || value.includes("\\") ? [resolve(value)] :
        (process.env.PATH ?? "").split(delimiter).map(dir => resolve(dir || ".", value));
    for (const path of candidates) {
        try {
            await access(path, constants.X_OK);
            if ((await stat(path)).isFile()) return path;
        } catch { /* Try the next PATH entry. */ }
    }
    return null;
}

async function chromeInfo(override) {
    let path = null;
    const chosen = override ?? process.env.TITAN_CHROME;
    if (chosen !== undefined) path = await executable(chosen);
    else for (const name of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome-headless-shell"]) {
        path = await executable(name);
        if (path) break;
    }
    if (!path) return { path: chosen ? resolve(chosen) : null, version: null, ok: false, reason: "headless Chromium not found; set TITAN_CHROME to a Chrome executable" };
    try {
        const { stdout, stderr } = await exec(path, ["--version"], { timeout: 5000, maxBuffer: 65536 });
        const version = (stdout || stderr).trim();
        const ok = /(?:Google Chrome(?: for Testing)?|Chromium|Chrome Headless Shell)\s+\d+\.\d+\.\d+\.\d+/i.test(version);
        return { path, version: version || null, ok, reason: ok ? null : "unrecognized Chrome/Chromium version banner" };
    } catch (error) {
        // A launched executable with an ordinary nonzero result is an unavailable
        // capability. Spawn/IO failures are harness failures, not fake probe JSON.
        if (typeof error.code !== "number" && !error.killed) throw error;
        return { path, version: error.stdout?.trim() || error.stderr?.trim() || null, ok: false, reason: `cannot run Chrome --version: ${error.message}` };
    }
}

export function within(root, path) {
    const rel = relative(root, path);
    return rel !== ".." && !rel.startsWith(".." + sep) && !isAbsolute(rel);
}

export class Monitor {
    constructor(options) {
        this.options = options;
        this.done = new Promise(resolve => { this.finish = resolve; });
        this.deadline = later(() => this.fail("timeout", `timed out after ${options.timeout} ms`), options.timeout);
    }
    fail(category, reason, knownTrap = false) {
        if (this.stopped) return;
        // Only tagged original trap identity can overrule observed onAbort.
        if (!this.failure || (category === "trap" && knownTrap && this.failure.category === "abort")) {
            this.failure = { category, reason, late: !!this.completion };
        }
        this.finish();
    }
    control(message) {
        if (!message || typeof message !== "object" || Array.isArray(message)) return this.fail("harness", "malformed control message");
        if (message.type === "abort") {
            if (typeof message.reason !== "string") return this.fail("harness", "malformed abort observation");
            this.abortReason ??= message.reason;
            if (this.completion) this.fail("abort", this.abortReason);
        } else if (message.type === "failure") {
            if (!["abort", "trap", "unhandled", "sink", "harness"].includes(message.category) || typeof message.reason !== "string") {
                return this.fail("harness", "malformed failure control");
            }
            const originalTrap = message.category === "trap" && message.knownTrap === true;
            if (this.abortReason !== undefined && !this.completion && !originalTrap &&
                ["abort", "trap", "harness"].includes(message.category)) {
                // An onAbort callback can be followed by a raw RuntimeError before
                // the loader's rejection/dispose continuation gets its microtask.
                // Observation is not cleanup completion: wait for execute's terminal
                // failure, retaining the ordinary deadline if disposal is broken.
                if (message.terminal !== true) return;
                this.fail("abort", this.abortReason);
            } else this.fail(message.category, message.reason, originalTrap);
        } else if (message.type === "complete") {
            if (this.completion) return this.fail("harness", "duplicate completion");
            if (!["returned", "failed", "exited", "host-test"].includes(message.kind) || !Number.isInteger(message.status) ||
                message.status < -2147483648 || message.status > 2147483647 ||
                (message.kind === "host-test" && ![0, 1].includes(message.status))) {
                return this.fail("harness", "malformed completion control");
            }
            if (this.abortReason !== undefined) return this.fail("abort", this.abortReason);
            this.completion = message;
            this.deadline();
            this.grace = later(() => this.finish(), this.options.grace);
        } else this.fail("harness", "unknown control message");
    }
    stop() { this.stopped = true; this.deadline(); this.grace?.(); }
    result() {
        const failure = this.failure;
        if (failure) {
            const { category, reason, late } = failure;
            if (late && ["abort", "trap"].includes(category)) {
                diagnostic(`late engine failure: ${reason} (${category})`);
                return 73;
            }
            const status = { abort: 70, trap: 71, timeout: 72, unhandled: 74, harness: 75, sink: 76 }[category];
            diagnostic(category === "timeout" ? reason : category === "unhandled" ? `unhandled rejection: ${reason}` :
                category === "harness" ? `harness failure: ${reason}` : category === "sink" ? `sink failure: ${reason}` : `${category}: ${reason}`);
            return status;
        }
        if (!this.completion) { diagnostic("harness failure: engine ended without completion"); return 75; }
        if (this.completion.reason) diagnostic(`JS test failed: ${this.completion.reason}`);
        return this.completion.status & 255;
    }
}

function exited(child) { return !child.pid || child.exitCode !== null || child.signalCode !== null; }
function waitExit(child, ms) {
    if (exited(child)) return Promise.resolve(true);
    return new Promise(resolve => {
        const done = () => { clearTimeout(timer); child.off("exit", done); resolve(true); };
        const timer = setTimeout(() => { child.off("exit", done); resolve(false); }, ms);
        child.once("exit", done);
    });
}
async function hasLiveMembers(group, pid) {
    // Darwin can report EPERM for an empty group or zombie-only membership.
    // Inspect only the owned PGID/PID and confirm non-zombie rows individually:
    // a stale ps row may already be gone, while PID-level EPERM is still live
    // (permission denied), never evidence that cleanup succeeded.
    const { stdout } = await exec("ps", ["-axo", "pid=,pgid=,stat="], { timeout: 2000, maxBuffer: 4 * 1024 * 1024 });
    for (const line of stdout.split("\n")) {
        if (!line.trim()) continue;
        const member = /^\s*(\d+)\s+(\d+)\s+(\S+)\s*$/.exec(line);
        if (!member) throw new Error("cannot inspect owned processes: malformed ps output");
        const memberPid = Number(member[1]);
        if ((group !== null && Number(member[2]) !== group) || (pid !== undefined && memberPid !== pid) ||
            /^[ZX]/.test(member[3])) continue;
        try { process.kill(memberPid, 0); return true; }
        catch (error) {
            if (error.code === "ESRCH") continue;
            if (error.code === "EPERM") return true;
            throw error;
        }
    }
    return false;
}

async function killGroup(child, signal) {
    if (!child?.pid) return;
    try { process.kill(-child.pid, signal); }
    catch (error) {
        if (error.code === "ESRCH") return;
        if (error.code === "EPERM" && !await hasLiveMembers(child.pid)) return;
        throw error;
    }
}

async function groupAlive(child) {
    if (!child?.pid) return false;
    try { process.kill(-child.pid, 0); return true; }
    catch (error) {
        if (error.code === "ESRCH") return false;
        if (error.code === "EPERM") return hasLiveMembers(child.pid);
        throw error;
    }
}

async function waitGroup(child, milliseconds) {
    const deadline = performance.now() + milliseconds;
    while (await groupAlive(child)) {
        const remaining = deadline - performance.now();
        if (remaining <= 0) return false;
        await delay(Math.min(25, remaining));
    }
    return true;
}

async function retireGroup(child) {
    // Leader exit is not group retirement: a descendant can retain this PGID
    // without either the leader PID or a browser profile in its argv.
    await killGroup(child, "SIGTERM");
    if (!await waitGroup(child, 500)) {
        await killGroup(child, "SIGKILL");
        if (!await waitGroup(child, 1500)) throw new Error(`owned process group ${child.pid} survived SIGKILL`);
    }
    if (!await waitExit(child, 1000)) throw new Error(`engine leader ${child.pid} did not exit`);
}

class NodeEngine {
    constructor(monitor) { this.monitor = monitor; }
    async start(config) {
        const child = this.child = spawn(process.execPath, ["--expose-gc", join(assets, "titan-browser-node-worker.mjs")], {
            detached: true, stdio: ["ignore", "pipe", "pipe", "ipc"],
        });
        this.drained = new Promise(resolve => child.once("close", resolve));
        child.stdout.pipe(process.stdout, { end: false });
        child.stderr.pipe(process.stderr, { end: false });
        child.on("error", error => this.monitor.fail("harness", `cannot start Node worker: ${error.message}`));
        child.on("message", message => this.monitor.control(message));
        child.on("exit", (code, signal) => {
            if (!this.closing) this.monitor.fail("harness", `Node worker exited before shutdown (${signal ?? code})`);
        });
        child.on("disconnect", () => {
            if (!this.closing) this.monitor.fail("harness", "Node worker IPC disconnected before shutdown");
        });
        child.send({ type: "start", config }, error => { if (error && !this.closing) this.monitor.fail("harness", error.message); });
    }
    async close() {
        this.closing = true;
        const child = this.child;
        if (!child) return;
        if (!exited(child) && child.connected) child.send({ type: "shutdown" }, () => {});
        await waitExit(child, 500);
        try { await retireGroup(child); }
        finally {
            // close, unlike exit, follows EOF/drain of both output pipes.
            await bounded(this.drained, 1000);
        }
    }
}

class CDP {
    constructor(fail) { this.fail = fail; this.next = 0; this.pending = new Map(); }
    dispatch(text) {
        try {
            const message = JSON.parse(text);
            if (message.id !== undefined) {
                const item = this.pending.get(message.id);
                if (!item) return;
                this.pending.delete(message.id);
                if (message.error) item.reject(new Error(`${item.method}: ${message.error.message}`));
                else item.resolve(message.result ?? {});
            } else this.event?.(message);
        } catch (error) { this.fail("harness", `invalid CDP message: ${error.message}`); }
    }
    request(method, params = {}, sessionId) {
        const id = ++this.next;
        return new Promise((resolve, reject) => {
            this.pending.set(id, { resolve, reject, method });
            try { this.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); }
            catch (error) { this.pending.delete(id); reject(error); }
        });
    }
    close() {
        for (const item of this.pending.values()) item.reject(new Error("CDP transport closed"));
        this.pending.clear();
        this.socket?.close();
    }
}

class ChromiumEngine {
    constructor(monitor, options, chrome) { this.monitor = monitor; this.options = options; this.chrome = chrome; }
    fail(reason) {
        if (this.closing) return;
        this.engineFailure = true;
        this.monitor.fail("harness", reason);
    }
    reportFailure() {
        if (!this.child || !this.monitor.failure ||
            (!this.engineFailure && this.monitor.failure.category !== "harness")) return;
        // Format only after shutdown/drain: pipe EOF can win before the exit
        // event or the final stderr chunk, but must not hide either diagnostic.
        diagnostic(`Chromium child status: exit code=${JSON.stringify(this.child.exitCode)}, signal=${JSON.stringify(this.child.signalCode)}`);
        diagnostic(`Chromium stderr tail:\n${this.engineLog?.trim() || "(empty)"}`);
    }
    async start(config) {
        this.server = createServer((request, response) => { this.serve(request, response, config).catch(() => { response.writeHead(404); response.end(); }); });
        await new Promise((resolve, reject) => { this.server.once("error", reject); this.server.listen(0, "127.0.0.1", resolve); });
        if (this.closing) return;
        this.origin = `http://127.0.0.1:${this.server.address().port}`;
        const profile = await mkdtemp(join(tmpdir(), "titan-browser-"));
        if (this.closing) { await rm(profile, { recursive: true, force: true }); return; }
        this.profile = profile;
        // Keep shared-memory backing files off size-limited /dev/shm mounts.
        const args = ["--headless=new", "--disable-gpu", "--disable-dev-shm-usage",
            "--no-first-run", "--no-default-browser-check",
            "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
            `--user-data-dir=${this.profile}`];
        if (this.options.cdp === "pipe") args.push("--remote-debugging-pipe");
        else args.push("--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0");
        // Root-only act containers must opt in explicitly; ordinary runs keep the sandbox.
        if (process.getuid?.() === 0 && process.env.TITAN_BROWSER_ROOT_NO_SANDBOX === "1") args.push("--no-sandbox");
        const child = this.child = spawn(this.chrome.path, args, {
            detached: true, stdio: this.options.cdp === "pipe" ? ["ignore", "ignore", "pipe", "pipe", "pipe"] : ["ignore", "ignore", "pipe"],
        });
        diagnostic(`Chromium ${this.chrome.version}; executable ${JSON.stringify(this.chrome.path)}; CDP ${this.options.cdp}; pid ${child.pid}; profile ${JSON.stringify(this.profile)}`);
        this.drained = new Promise(resolve => child.once("close", resolve));
        this.engineLog = "";
        child.stderr.on("data", chunk => { this.engineLog = (this.engineLog + chunk.toString()).slice(-8192); });
        child.on("error", error => this.fail(`cannot launch Chromium: ${error.message}`));
        child.on("exit", () => this.fail("Chromium exited before shutdown"));
        const cdp = this.cdp = new CDP((_category, reason) => this.fail(reason));
        if (this.options.cdp === "pipe") {
            let buffer = "";
            child.stdio[4].setEncoding("utf8");
            child.stdio[4].on("data", chunk => {
                buffer += chunk;
                let end;
                while ((end = buffer.indexOf("\0")) !== -1) {
                    const text = buffer.slice(0, end); buffer = buffer.slice(end + 1);
                    if (text) cdp.dispatch(text);
                }
            });
            for (const stream of [child.stdio[3], child.stdio[4]]) stream.on("error", error => this.fail(error.message));
            child.stdio[4].on("end", () => this.fail("CDP pipe closed before shutdown"));
            cdp.send = text => child.stdio[3].write(text + "\0");
        } else {
            let endpoint;
            let malformedSince;
            while (!this.closing && !this.monitor.failure) {
                try {
                    const text = await readFile(join(this.profile, "DevToolsActivePort"), "utf8");
                    const [port, websocketPath] = text.trim().split("\n");
                    if (/^\d+$/.test(port) && websocketPath?.startsWith("/devtools/browser/")) {
                        endpoint = `ws://127.0.0.1:${port}${websocketPath}`;
                        break;
                    }
                    // Chromium creates the file before writing its endpoint.
                    malformedSince ??= performance.now();
                    if (performance.now() - malformedSince > 1000) {
                        throw new Error(`invalid DevToolsActivePort: ${JSON.stringify(text)}`);
                    }
                } catch (error) { if (error.code !== "ENOENT") throw error; }
                await delay(20);
            }
            if (!endpoint || this.closing) return;
            const socket = cdp.socket = new WebSocket(endpoint);
            socket.addEventListener("message", event => cdp.dispatch(event.data));
            socket.addEventListener("close", () => this.fail("CDP WebSocket closed before shutdown"));
            await new Promise((resolve, reject) => {
                socket.addEventListener("open", resolve, { once: true });
                socket.addEventListener("error", () => reject(new Error("cannot connect CDP WebSocket")), { once: true });
            });
            cdp.send = text => socket.send(text);
        }
        if (this.closing) return;
        cdp.event = message => this.event(message);
        const { targetId } = await cdp.request("Target.createTarget", { url: "about:blank" });
        this.target = targetId;
        const { sessionId } = await cdp.request("Target.attachToTarget", { targetId, flatten: true });
        this.session = sessionId;
        await cdp.request("Runtime.enable", {}, sessionId);
        await cdp.request("Page.enable", {}, sessionId);
        await cdp.request("Runtime.addBinding", { name: "__titanRunner" }, sessionId);
        const pageConfig = { ...config, root: this.origin + "/root/" };
        this.html = "<!doctype html><meta charset=utf-8><title>Titan browser runner</title><script type=module>" +
            `import { startPage } from '/sdk/titan-browser-page.mjs'; startPage(${JSON.stringify(pageConfig).replaceAll("<", "\\u003c")});</script>`;
        await cdp.request("Page.navigate", { url: this.origin + "/" }, sessionId);
        await cdp.request("Page.bringToFront", {}, sessionId);
    }
    async serve(request, response, config) {
        if (request.method !== "GET" && request.method !== "HEAD") { response.writeHead(405); response.end(); return; }
        const raw = (request.url ?? "").split("?")[0];
        if (raw === "/") {
            response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
            response.end(request.method === "HEAD" ? undefined : this.html ?? ""); return;
        }
        const mount = raw.startsWith("/root/") ? config.root : raw.startsWith("/sdk/") ? assets : null;
        if (!mount) throw new Error("unknown asset mount");
        const encoded = raw.slice(raw.indexOf("/", 1) + 1);
        const parts = encoded.split("/").map(decodeURIComponent);
        if (parts.some(part => !part || part === "." || part === ".." || part.includes("/") || part.includes("\\") || part.includes("\0"))) throw new Error("invalid asset path");
        const path = await realpath(join(mount, ...parts));
        if (!within(mount, path) || !(await stat(path)).isFile()) throw new Error("asset escapes mount");
        const type = path.endsWith(".wasm") ? "application/wasm" : path.endsWith(".mjs") || path.endsWith(".js") ? "text/javascript; charset=utf-8" : "application/octet-stream";
        const bytes = await readFile(path);
        response.writeHead(200, { "Content-Type": type, "Content-Length": bytes.length, "Cache-Control": "no-store" });
        response.end(request.method === "HEAD" ? undefined : bytes);
    }
    event(message) {
        if (this.closing) return;
        if (message.method === "Runtime.bindingCalled" && message.params.name === "__titanRunner") {
            try {
                const payload = message.params.payload;
                if (!validBase64(payload)) throw new Error("invalid binding base64");
                const control = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
                if (control.type === "ready") {
                    if (this.pageReady) throw new Error("duplicate page-ready control");
                    this.pageReady = true;
                } else if (control.type === "bytes") {
                    if (!["stdout", "stderr"].includes(control.stream) || !validBase64(control.data)) throw new Error("malformed byte control");
                    process[control.stream].write(Buffer.from(control.data, "base64"));
                } else if (control.type === "gc") {
                    if (!Number.isSafeInteger(control.id) || control.id <= 0) throw new Error("malformed GC request");
                    this.collect(control.id).catch(error => this.monitor.fail("harness", error.message));
                } else this.monitor.control(control);
            } catch (error) { this.monitor.fail("harness", `malformed page control: ${error.message}`); }
        } else if (message.method === "Runtime.exceptionThrown") {
            // Once page handlers are installed they retain original error identity.
            // This path is for bootstrap failures before that private handshake.
            if (!this.pageReady) {
                const details = message.params.exceptionDetails;
                this.monitor.fail("harness", details.exception?.description ?? details.text);
            }
        } else if (["Inspector.targetCrashed", "Target.targetCrashed"].includes(message.method)) {
            this.monitor.fail("harness", "Chromium target crashed");
        }
    }
    async collect(id) {
        let error = null;
        try { await this.cdp.request("HeapProfiler.collectGarbage", {}, this.session); }
        catch (cause) { error = cause.message; }
        if (!this.closing) await this.cdp.request("Runtime.evaluate", { expression: `globalThis.__titanRunnerGc(${id},${JSON.stringify(error)})` }, this.session);
    }
    async close() {
        this.closing = true;
        try {
            if (this.cdp?.send) await bounded(this.cdp.request("Browser.close").catch(() => {}), 500);
            if (this.child) {
                await waitExit(this.child, 1500);
                try { await retireGroup(this.child); }
                finally { await this.removeProfileProcesses(); }
            }
        } finally {
            this.cdp?.close();
            // Close control fds first, but retain stderr until its final bytes and
            // the child's exit status have been observed. This wait is bounded.
            this.child?.stdio[3]?.destroy();
            this.child?.stdio[4]?.destroy();
            if (this.drained) await bounded(this.drained, 1000);
            for (const stream of this.child?.stdio ?? []) stream?.destroy?.();
            try {
                if (this.server) { this.server.closeAllConnections(); await new Promise(resolve => this.server.close(resolve)); }
            } finally {
                if (this.profile) {
                    await rm(this.profile, { recursive: true, force: true, maxRetries: 4, retryDelay: 50 });
                    diagnostic(`cleanup: profile ${JSON.stringify(this.profile)} removed`);
                }
            }
        }
    }
    async removeProfileProcesses() {
        // A wrapper or detached Chrome child can outlive the launcher. Only exact
        // unique-profile matches belong to this run; never kill by executable name.
        const profileArg = `--user-data-dir=${this.profile}`.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const belongs = new RegExp(`(?:^|\\s)${profileArg}(?=\\s|$)`);
        const matching = async () => {
            const { stdout } = await exec("ps", ["-axo", "pid=,args="], { timeout: 2000, maxBuffer: 4 * 1024 * 1024 });
            return stdout.split("\n").flatMap(line => {
                const match = /^\s*(\d+)\s+(.*)$/.exec(line);
                if (!match || Number(match[1]) === process.pid) return [];
                return belongs.test(match[2]) ? [Number(match[1])] : [];
            });
        };
        for (const signal of ["SIGTERM", "SIGKILL"]) {
            const pids = await matching();
            if (!pids.length) return;
            for (const pid of pids) {
                try { process.kill(pid, signal); }
                catch (error) {
                    if (error.code === "ESRCH") continue;
                    if (error.code === "EPERM" && !await hasLiveMembers(null, pid)) continue;
                    throw error;
                }
            }
            await delay(100);
        }
        if ((await matching()).length) throw new Error("Chromium profile processes survived cleanup");
    }
}

function validBase64(value) { return typeof value === "string" && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value); }

async function main() {
    let options;
    try { options = parse(process.argv.slice(2)); }
    catch (error) { diagnostic(error.message); process.stderr.write(usage); return 2; }
    if (options.help) { process.stderr.write(usage); return 0; }
    if (options.version) { diagnostic("Titan 0.6.0 browser runner (Node 26+)"); return 0; }
    const chrome = options.probe || options.engine === "chromium" ? await chromeInfo(options.chrome) : null;
    const nodeOK = Number(process.versions.node.split(".")[0]) >= 26 &&
        typeof WebAssembly.promising === "function" && typeof WebAssembly.Suspending === "function";
    const nodeReason = nodeOK ? null : "Node 26 or newer with WebAssembly JSPI is required";
    if (!nodeOK) { diagnostic(nodeReason); return 75; }
    if (options.probe) {
        process.stdout.write(JSON.stringify({ node: { path: process.execPath, version: process.version, ok: nodeOK, reason: nodeReason }, chrome }) + "\n");
        return 0;
    }
    if (chrome && !chrome.ok) { diagnostic("headless Chromium not found; set TITAN_CHROME to a Chrome executable"); return 75; }
    if (process.platform === "win32") throw new Error("browser execution is supported from Linux and macOS hosts");
    const file = await realpath(resolve(options.file));
    const root = await realpath(resolve(options.root ?? dirname(file)));
    if (!(await stat(root)).isDirectory() || !(await stat(file)).isFile() || !within(root, file)) throw new Error("FILE must be a regular file beneath --root");
    if (!file.endsWith(".mjs")) throw new Error("FILE must end in .mjs");
    const config = { engine: options.engine, root, file: relative(root, file).split(sep).join("/"), args: options.args,
        jsTest: options.jsTest, allowDegradedTrace: !!options.allowDegradedTrace };
    const monitor = new Monitor(options);
    const engine = options.engine === "node" ? new NodeEngine(monitor) : new ChromiumEngine(monitor, options, chrome);
    const interrupted = signal => monitor.fail("harness", `interrupted by ${signal}`);
    const sigint = () => interrupted("SIGINT");
    const sigterm = () => interrupted("SIGTERM");
    process.on("SIGINT", sigint); process.on("SIGTERM", sigterm);
    try {
        const starting = engine.start(config).catch(error => monitor.fail("harness", error.message));
        await Promise.race([starting, monitor.done]);
        await monitor.done;
        // Allow same-turn original-trap evidence to precede its later abort wrapper.
        await new Promise(resolve => setImmediate(resolve));
    } finally {
        monitor.stop();
        try { await engine.close(); }
        catch (error) {
            const reason = `cleanup failed: ${error.message}`;
            if (monitor.failure) diagnostic(`harness failure: ${reason}`);
            else monitor.failure = { category: "harness", reason };
        }
        engine.reportFailure?.();
        process.off("SIGINT", sigint); process.off("SIGTERM", sigterm);
    }
    return monitor.result();
}

const invokedPath = process.argv[1] && await realpath(process.argv[1]).catch(() => null);
if (invokedPath && import.meta.url === pathToFileURL(invokedPath).href) {
    try { process.exitCode = await main(); }
    catch (error) { diagnostic(`harness failure: ${error.message}`); process.exitCode = 75; }
}
