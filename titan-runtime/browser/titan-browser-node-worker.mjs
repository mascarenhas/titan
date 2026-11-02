import { readFile, realpath } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { classify, execute, knownTrap, observeFactory, reason, relativePath } from "./titan-browser-page.mjs";

const control = message => process.send?.(message);
const failure = (error, terminal = false) =>
    control({ type: "failure", category: classify(error), reason: reason(error), knownTrap: knownTrap(error), terminal });
process.on("uncaughtException", error => failure(error));
process.on("unhandledRejection", error => control({ type: "failure", category: "unhandled", reason: reason(error) }));

// IPC keeps the worker alive even if an unfinished image has no live JS handles.
process.on("message", message => {
    if (message?.type === "shutdown") {
        process.stdout.write("", () => process.stderr.write("", () => process.exit(0)));
    } else if (message?.type === "start") {
        run(message.config).catch(error => failure(error, true));
    } else {
        control({ type: "failure", category: "harness", reason: "invalid supervisor command" });
    }
});

async function run(config) {
    const root = await realpath(config.root);
    async function asset(path) {
        const file = await realpath(resolve(root, ...relativePath(path).split("/")));
        const rel = relative(root, file);
        if (isAbsolute(rel) || rel === ".." || rel.startsWith(".." + sep)) throw new Error("asset path escapes --root");
        return file;
    }
    const images = new Map();
    const wrappers = new WeakMap();
    const host = {
        stdout: chunk => { process.stdout.write(Buffer.from(chunk)); },
        stderr: chunk => { process.stderr.write(Buffer.from(chunk)); },
        control,
        module: async path => import(pathToFileURL(await asset(path)).href),
        image(path) {
            if (!images.has(path)) images.set(path, (async () => {
                const file = await asset(path);
                const module = await import(pathToFileURL(file).href);
                if (typeof module.default !== "function") throw new Error("image must export a default factory");
                if (!wrappers.has(module.default)) wrappers.set(module.default, observeFactory(module.default, control, config.allowDegradedTrace));
                return Object.freeze({
                    factory: wrappers.get(module.default),
                    locateFile: name => resolve(dirname(file), name),
                });
            })());
            return images.get(path);
        },
        bytes: async path => new Uint8Array(await readFile(await asset(path))),
        async gc() {
            if (typeof globalThis.gc !== "function") throw new Error("Node garbage collection is unavailable");
            globalThis.gc();
        },
    };
    await execute(config, host);
}
