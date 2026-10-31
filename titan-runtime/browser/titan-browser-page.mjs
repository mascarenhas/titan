// Shared host-test context and browser-page entry. No Node imports in this module.
export function relativePath(value) {
    if (typeof value !== "string" || !value || value.includes("\\") ||
        value.includes("\0") || value.startsWith("/") || /^[A-Za-z]:/.test(value)) {
        throw new Error("asset path must be relative to --root");
    }
    const parts = [];
    for (const part of value.split("/")) {
        if (!part || part === ".") continue;
        if (part === "..") {
            if (!parts.length) throw new Error("asset path escapes --root");
            parts.pop();
        } else parts.push(part);
    }
    if (!parts.length) throw new Error("asset path must name a file");
    return parts.join("/");
}

export function reason(error) {
    return error?.message === undefined ? String(error) : String(error.message);
}

export function classify(error) {
    const chain = [];
    for (let item = error; item && !chain.includes(item); item = item.cause) chain.push(item);
    if (chain.some(item => item.code === "TITAN_BROWSER_TRAP")) return "trap";
    if (chain.some(item => item.code === "TITAN_BROWSER_ABORT")) return "abort";
    if (chain.some(item => item.code === "TITAN_BROWSER_SINK")) return "sink";
    if (chain.some(item => item instanceof WebAssembly.RuntimeError)) return "trap";
    return "harness";
}

export function knownTrap(error) {
    const seen = new Set();
    for (let item = error; item && !seen.has(item); item = item.cause) {
        if (item.code === "TITAN_BROWSER_TRAP") return true;
        seen.add(item);
    }
    return false;
}

// One wrapper per imported factory, approved by Main as the §4 identity amendment.
// The production loader remains unmodified; its abort callback always runs first.
export function observeFactory(factory, control) {
    return options => factory({
        ...options,
        onAbort(value) {
            try { options.onAbort?.(value); }
            finally { control({ type: "failure", category: "abort", reason: reason(value) }); }
        },
    });
}

function byteSink(sink) {
    return chunk => {
        if (!(chunk instanceof Uint8Array)) throw new Error("output chunk must be a Uint8Array");
        sink(chunk);
    };
}

export async function execute(config, host) {
    const { create } = await import(config.loader);
    const stdout = byteSink(host.stdout);
    const stderr = byteSink(host.stderr);
    const context = Object.freeze({
        engine: config.engine,
        args: Object.freeze([...config.args]),
        create,
        image: async path => Object.freeze(await host.image(relativePath(path))),
        bytes: async path => new Uint8Array(await host.bytes(relativePath(path))),
        stdout, stderr,
        assert(condition, message = "assertion failed") {
            if (!condition) throw new Error(message);
        },
        equalBytes(actual, expected, message = "byte mismatch") {
            if (!(actual instanceof Uint8Array) || !(expected instanceof Uint8Array) ||
                actual.length !== expected.length || actual.some((byte, index) => byte !== expected[index])) {
                throw new Error(message);
            }
        },
        tick: () => new Promise(resolve => setTimeout(resolve, 0)),
        gc: host.gc,
    });
    if (config.jsTest) {
        const module = await host.module(config.file);
        if (typeof module.run !== "function") throw new Error("JS test module must export run(context)");
        let result;
        try { result = await module.run(context); }
        catch (error) {
            const category = classify(error);
            if (category !== "harness" || error?.code?.startsWith("TITAN_BROWSER_")) throw error;
            host.control({ type: "complete", kind: "host-test", status: 1, reason: reason(error) });
            return;
        }
        if (result !== undefined) throw new Error("JS test run(context) must return undefined");
        host.control({ type: "complete", kind: "host-test", status: 0 });
        return;
    }
    const { factory, locateFile } = await context.image(config.file);
    const instance = create(factory, { stdout, stderr, locateFile });
    try {
        const result = await instance.run(config.args);
        // Disposal is part of quiescence, never a cancellation mechanism.
        await instance.dispose();
        host.control({ type: "complete", kind: result.kind, status: result.status });
    } catch (error) {
        // Fatal disposal may drop broken Wasm without waiting for its internal ccall.
        try { await instance.dispose(); } catch { /* The original failure wins. */ }
        throw error;
    }
}

function base64(bytes) {
    let text = "";
    for (let offset = 0; offset < bytes.length; offset += 16384) {
        text += String.fromCharCode(...bytes.subarray(offset, offset + 16384));
    }
    return btoa(text);
}

export async function startPage(config) {
    const send = message => globalThis.__titanRunner(base64(new TextEncoder().encode(JSON.stringify(message))));
    const failure = (category, error) => send({ type: "failure", category, reason: reason(error), knownTrap: knownTrap(error) });
    addEventListener("error", event => {
        failure(classify(event.error), event.error ?? event.message);
        event.preventDefault();
    });
    addEventListener("unhandledrejection", event => {
        failure("unhandled", event.reason);
        event.preventDefault();
    });
    send({ type: "ready" });
    const gcWaiters = new Map();
    let gcId = 0;
    globalThis.__titanRunnerGc = (id, error) => {
        const waiter = gcWaiters.get(id);
        if (!waiter) return;
        gcWaiters.delete(id);
        if (error) waiter.reject(new Error(error));
        else waiter.resolve();
    };
    const url = path => config.root + relativePath(path).split("/").map(encodeURIComponent).join("/");
    const images = new Map();
    const wrappers = new WeakMap();
    const host = {
        stdout: chunk => send({ type: "bytes", stream: "stdout", data: base64(chunk) }),
        stderr: chunk => send({ type: "bytes", stream: "stderr", data: base64(chunk) }),
        control: send,
        module: path => import(url(path)),
        image(path) {
            if (!images.has(path)) images.set(path, import(url(path)).then(module => {
                if (typeof module.default !== "function") throw new Error("image must export a default factory");
                if (!wrappers.has(module.default)) wrappers.set(module.default, observeFactory(module.default, send));
                return Object.freeze({
                    factory: wrappers.get(module.default),
                    locateFile: name => new URL(name, url(path)).href,
                });
            }));
            return images.get(path);
        },
        async bytes(path) {
            const response = await fetch(url(path));
            if (!response.ok) throw new Error(`cannot read asset ${path}: HTTP ${response.status}`);
            return new Uint8Array(await response.arrayBuffer());
        },
        gc: () => new Promise((resolve, reject) => {
            const id = ++gcId;
            gcWaiters.set(id, { resolve, reject });
            send({ type: "gc", id });
        }),
    };
    // Do not await this in CDP: a CPU-bound Wasm loop must not block its supervisor.
    execute(config, host).catch(error => failure(classify(error), error));
}
