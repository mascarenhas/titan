function wasmAction(hang = false) {
    // A real engine trap / CPU-bound Wasm loop, not a synthetic RuntimeError.
    const body = hang ? [0, 3, 64, 12, 0, 11, 11] : [0, 0, 11];
    const bytes = new Uint8Array([
        0, 97, 115, 109, 1, 0, 0, 0,
        1, 4, 1, 96, 0, 0, 3, 2, 1, 0,
        7, 7, 1, 3, 114, 117, 110, 0, 0,
        10, body.length + 2, 1, body.length, ...body,
    ]);
    return new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.run;
}

function privateControl(context, message) {
    if (context.engine === "node") process.send(message);
    else globalThis.__titanRunner(btoa(JSON.stringify(message)));
}

async function abortImage(context) {
    const image = await context.image(context.args[1]);
    const instance = context.create(image.factory, { locateFile: () => image.locateFile("missing-runner-329.wasm") });
    try { await instance.initialize(); }
    finally { await instance.dispose(); }
}

export async function run(context) {
    const mode = context.args[0] ?? "context";
    if (mode === "args") {
        context.stdout(new TextEncoder().encode(JSON.stringify(context.args.slice(1))));
        return;
    }
    if (mode === "trap") { wasmAction()(); return; }
    if (mode === "late-trap") { setTimeout(wasmAction(), 40); return; }
    if (mode === "timeout") {
        context.stdout(new TextEncoder().encode("hang-entered\n"));
        wasmAction(true)();
        context.assert(false, "CPU-bound Wasm loop returned");
    }
    if (mode === "abort") { await abortImage(context); return; }
    if (mode === "caught-abort") {
        try { await abortImage(context); } catch { /* Completion cannot erase onAbort. */ }
        return;
    }
    if (mode === "abort-hang") {
        // Private control-unit fault: an observed abort is not a disposal ack.
        privateControl(context, { type: "abort", reason: "runner abort with hung cleanup" });
        context.stdout(new TextEncoder().encode("hang-entered\n"));
        await new Promise(() => {});
    }
    if (mode === "trap-priority") {
        try { wasmAction()(); }
        catch (error) {
            // Retain the real engine object, using the loader's explicit identity
            // tag in this private supervisor-protocol precedence test.
            error.code = "TITAN_BROWSER_TRAP";
            privateControl(context, { type: "abort", reason: "subsequent abort wrapper" });
            throw error;
        }
    }
    if (mode === "late-abort") {
        // The initialization rejection is deliberately observed. onAbort, not an
        // unhandled Promise rejection, must establish the runner's category.
        setTimeout(() => { abortImage(context).catch(() => {}); }, 40);
        return;
    }
    if (mode === "unhandled") {
        Promise.reject(new Error("runner deliberate rejection"));
        await new Promise(() => {});
    }
    if (mode === "late-unhandled") {
        setTimeout(() => { Promise.reject(new Error("runner late rejection")); }, 40);
        return;
    }
    if (mode === "sink-stdout" || mode === "sink-stderr" || mode === "sink-thenable") {
        const image = await context.image(context.args[1]);
        const instance = context.create(image.factory, {
            locateFile: image.locateFile,
            stdout: mode === "sink-stdout" ? () => { throw new Error("runner stdout sink"); } :
                mode === "sink-thenable" ? () => Promise.reject(new Error("runner Promise sink")) : context.stdout,
            stderr: mode === "sink-stderr" ? () => { throw new Error("runner stderr sink"); } : context.stderr,
        });
        try { await instance.run(["--filter=^runner_image[.]test_bytes$"]); }
        finally { await instance.dispose(); }
        context.assert(false, "throwing sink was accepted");
    }
    if (mode === "host-fail") { context.assert(false, "runner host assertion"); }
    if (mode === "bad-return") return 17;
    if (mode === "duplicate") {
        privateControl(context, { type: "complete", kind: "host-test", status: 0 });
        privateControl(context, { type: "complete", kind: "host-test", status: 0 });
        return;
    }
    if (mode === "malformed") { privateControl(context, { type: "unknown" }); return; }
    if (mode === "premature-exit") { process.exit(0); }
    if (mode === "image-cache") {
        const first = await context.image(context.args[1]);
        const second = await context.image("./" + context.args[1]);
        context.assert(Object.isFrozen(first) && Object.isFrozen(second));
        context.assert(first.factory === second.factory, "image factory identity was not cached");
        return;
    }
    if (mode === "http-paths") {
        context.assert(context.engine === "chromium", "HTTP checks need Chromium");
        const origin = new URL(import.meta.url).origin;
        for (const path of ["/root/%2e%2e%2fetc/passwd", "/root/%2Fetc/passwd", "/sdk/%2e%2e%2ftitan-browser-run.mjs"]) {
            context.assert((await fetch(origin + path)).status === 404, "HTTP server accepted traversal");
        }
        const sdk = origin + "/sdk/titan-browser.mjs";
        context.assert((await fetch(sdk, { method: "POST" })).status === 405, "SDK route was writable");
        const head = await fetch(sdk, { method: "HEAD" });
        context.assert(head.ok && head.headers.get("content-type").startsWith("text/javascript"));
        return;
    }
    context.assert(mode === "context", "unknown runner fixture mode");
    context.assert(Object.isFrozen(context), "host-test context is mutable");
    context.assert(Object.isFrozen(context.args), "host-test args are mutable");
    context.equalBytes(new TextEncoder().encode(Object.keys(context).sort().join(",")),
        new TextEncoder().encode("args,assert,bytes,create,engine,equalBytes,gc,image,stderr,stdout,tick"));
    context.assert(context.engine === "node" || context.engine === "chromium");
    const first = await context.bytes("spec/browser/runner-fixtures.mjs");
    const original = first[0];
    first[0] ^= 255;
    const second = await context.bytes("spec/browser/runner-fixtures.mjs");
    context.assert(second[0] === original, "bytes returned reused storage");
    let timer = false;
    setTimeout(() => { timer = true; }, 0);
    await context.tick();
    context.assert(timer, "tick did not cross a macrotask boundary");
    await context.gc();
    for (const path of ["/etc/passwd", "../outside", "C:/outside", "a/../../outside", "a\\b"]) {
        let rejected = false;
        try { await context.bytes(path); } catch { rejected = true; }
        context.assert(rejected, "escaping asset path was accepted");
    }
    context.assert(context.stdout(new Uint8Array([0, 255, 195, 40, 65])) === undefined);
    context.assert(context.stderr(new Uint8Array([254, 0, 226, 40, 66])) === undefined);
}
