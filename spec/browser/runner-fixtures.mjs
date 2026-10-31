export async function run(context) {
    const mode = context.args[0] ?? "context";
    if (mode === "args") {
        context.stdout(new TextEncoder().encode(JSON.stringify(context.args.slice(1))));
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
