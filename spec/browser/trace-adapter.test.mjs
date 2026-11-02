import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import vm from 'node:vm';

const source = await readFile(new URL('../../titan-runtime/browser/titan-browser-trace.js', import.meta.url), 'utf8');
const stacks = JSON.parse(await readFile(new URL('../fixtures/browser_trace_adapter/stacks.json', import.meta.url), 'utf8'));
const identity = 'a'.repeat(64);
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function vlq(number) {
    let value = Math.abs(number) * 2 + (number < 0 ? 1 : 0), text = '';
    do { const digit = value % 32; value = Math.floor(value / 32); text += alphabet[digit + (value ? 32 : 0)]; } while (value);
    return text;
}
function map(overrides = {}) {
    // Body 1: located 100..104, explicit unknown 105..109, located 110..119.
    // Body 2: wholly unmapped. Body 3: first segment at 145, no borrowing 140..144.
    return {version: 3, sources: ['path/one.browser.titan', 'C:\\path\\two.titan'], names: [],
        mappings: [[100, 0, 6, 0], [5], [5, 0, 1, 0], [35, 1, 2, 0]].map(row => row.map(vlq).join('')).join(','),
        x_titan_image: identity, x_titan_function_imports: 1,
        x_titan_function_ranges: [[100, 120], [120, 130], [140, 160]],
        x_titan_function_names: [null, 'one_titan', 'dynCall_v', 'two_titan'], ...overrides};
}
function adapter({realError = false, data = map(), node = true, fetch: fetcher} = {}) {
    const hooks = [], dependencies = new Set(), warnings = [], reads = [];
    const heap = new Uint8Array(16384);
    let library;
    const context = vm.createContext({
        HEAPU32: new Uint32Array(heap.buffer), Module: {},
        TextDecoder, TextEncoder, performance,
        addToLibrary(value) { library = value; },
        addOnPreRun(hook) { hooks.push(hook); },
        addRunDependency(name) { dependencies.add(name); },
        removeRunDependency(name) { dependencies.delete(name); },
        ENVIRONMENT_IS_NODE: node,
        locateFile(name) { reads.push(name); return '/maps/' + name; },
        readBinary(path) { reads.push(path); return new TextEncoder().encode(JSON.stringify(data)); },
        fetch: fetcher,
        wasmExports: {titan_browser_trace_identity() { return 64; }},
        UTF8ToString(pointer) { assert.equal(pointer, 64); return identity; },
        stringToUTF8(text, pointer, size) {
            // Match Emscripten's bounded UTF-8 behavior, including whole codepoints.
            let length = 0;
            for (const character of text) {
                const bytes = new TextEncoder().encode(character);
                if (length + bytes.length >= size) break;
                heap.set(bytes, pointer + length); length += bytes.length;
            }
            heap[pointer + length] = 0;
        },
        console: {warn(text) { warnings.push(text); }},
    });
    vm.runInContext(source.replaceAll('{{{ WASM_BINARY_FILE }}}', 'image.wasm'), context);
    context.TitanBrowserTrace = library.$TitanBrowserTrace;
    if (!realError) vm.runInContext(`
        globalThis.stackText = 'Error\\n    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)';
        globalThis.constructed = 0; globalThis.stackReads = 0;
        globalThis.captureFailure = false; globalThis.stackReadFailure = false;
        globalThis.Error = function Error() {
            ++constructed;
            if (captureFailure) throw 'capture failed';
            Object.defineProperty(this, 'stack', {get() {
                ++stackReads; if (stackReadFailure) throw 'stack read'; return stackText;
            }});
        };
    `, context);
    const api = context.TitanBrowserTrace;
    vm.runInContext(library.$TitanBrowserTrace__postset, context);
    api.index = api.buildIndex(data, identity);
    return {context, api, library, heap, hooks, dependencies, warnings, reads,
        evaluate(code) { return vm.runInContext(code, context); },
        capture(capacity = 512) { return library.titan_browser_trace_capture(1024, capacity); },
        records() {
            const words = new Uint32Array(heap.buffer);
            return Array.from({length: words[256]}, (_, i) => Array.from(words.slice(258 + i * 3, 261 + i * 3)));
        },
        text(pointer) { const end = heap.indexOf(0, pointer); return new TextDecoder().decode(heap.subarray(pointer, end)); },
    };
}

for (const [name, stack] of Object.entries(stacks)) {
    test('recorded parser: ' + name, () => {
        const {api} = adapter();
        const result = api.parse(stack, 512, name.includes('-default') && /^(node|chrom)/.test(name) ? 10 : 200);
        const isJsc = /^(webkit|safari)/.test(name);
        const isDepth = name.includes('-depth-');
        const isV8Default = name.includes('-default') && /^(node|chrom)/.test(name);
        const expected = isV8Default ? 9 : isDepth ? (isJsc ? 99 : name.startsWith('firefox') ? 127 : 199)
            : name.includes('-fiber-') || name.includes('-longjmp-before-') ? 54 : name.includes('-longjmp-after-') ? 53 : 51;
        assert.equal(result.records.length, expected);
        assert.equal(result.records[0][1], 39);
        assert.equal(result.records[0][2], isJsc ? 2 : 3);
        assert.equal(result.records[0][0] > 0, !isJsc);
        assert.equal(result.truncated, isDepth || isV8Default);
        if (name.includes('-fiber-')) assert.equal(result.records.at(-1)[1], 84, 'fiber chain ends at current dynCall, not saved async ancestry');
    });
}

test('mixed warm/cold JSC always uses bracketed indexes and never invents lines', () => {
    const {api} = adapter();
    assert.deepEqual(JSON.parse(JSON.stringify(api.parse('123@wasm-function[1]\nname@image.wasm:wasm-function[3]', 512, 640).records)), [[0, 1, 2], [0, 3, 2]]);
    assert.equal(api.lookup(0, 1, 2).line, 0);
    assert.equal(api.lookup(0, 1, 2).base, 'one.browser.titan');
});

for (const count of [511, 512, 513]) test('raw capacity boundary ' + count, () => {
    const {api} = adapter();
    const stack = 'Error\n' + Array.from({length: count}, () => '    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)').join('\n');
    const result = api.parse(stack, 512, 640);
    assert.equal(result.records.length, Math.min(count, 512));
    assert.equal(result.truncated, count > 512);
});

test('limit accounting includes JS frames, not titles or Firefox saved parents', () => {
    const {api} = adapter();
    assert.equal(api.parse('Error\n    at host (image.js:1:2)\n    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)', 512, 2).truncated, true);
    assert.equal(api.parse('host@image.js:1:2\nleaf@image.wasm:wasm-function[1]:0x6e\nasync*old@image.js:2:3\nleaf@image.wasm:wasm-function[1]:0x6e', 512, 3).truncated, false);
});

test('recorded V8 frame accounting ignores titles containing @ or apparent locations', () => {
    const {api} = adapter();
    const recorded = stacks['node-24.19.0-named-direct-raised-200.txt'];
    for (const title of ['Error: contact a@b.com', 'Error: contact a@image.js:1:2',
        'Error: contact a@image.wasm:wasm-function[1]:0x6e']) {
        const stack = title + recorded.slice(recorded.indexOf('\n'));
        assert.equal(api.parse(stack, 512, 58).truncated, false);
        assert.equal(api.parse(stack, 512, 57).truncated, true);
        assert.equal(api.parse(stack, 512, 58).records.length, 51);
    }
});

test('capture uses the C-declared capacity rather than a duplicated fixed limit', () => {
    const unit = adapter();
    unit.context.stackText = 'Error\n' + Array.from({length: 513},
        () => '    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)').join('\n');
    assert.equal(unit.capture(513), 0);
    assert.equal(unit.records().length, 513);
    assert.equal(unit.capture(256), 0);
    assert.equal(unit.records().length, 256);
    assert.equal(new Uint32Array(unit.heap.buffer)[257], 1);
    for (const capacity of [0, -1, 1.5, 0x100000000, 1280]) {
        assert.equal(unit.capture(capacity), 2, `invalid capacity ${capacity}`);
        assert.equal(unit.records().length, 0);
    }
});

test('validated lookup respects bodies, boundaries, gaps, indexes and no-PC identity', () => {
    const {api} = adapter();
    for (const [pc, index, flags, base, line] of [
        [99, 1, 3, 'one.browser.titan', 0], [100, 1, 3, 'one.browser.titan', 7],
        [104, 1, 3, 'one.browser.titan', 7], [105, 1, 3, 'one.browser.titan', 0],
        [109, 1, 3, 'one.browser.titan', 0], [110, 1, 3, 'one.browser.titan', 8],
        [120, 2, 3, '?', 0], [129, 2, 3, '?', 0], [130, 2, 3, '?', 0],
        [140, 3, 3, 'two.titan', 0], [145, 3, 3, 'two.titan', 10],
        [159, 3, 3, 'two.titan', 10], [160, 3, 3, 'two.titan', 0],
        [110, 3, 3, 'two.titan', 0], [110, 999, 3, '?', 0],
        [110, 1, 2, 'one.browser.titan', 0], [110, 0, 1, 'one.browser.titan', 8],
    ]) {
        const result = api.lookup(pc, index, flags);
        assert.equal(result.base, base, `base at ${pc}/${index}/${flags}`);
        assert.equal(result.line, line, `line at ${pc}/${index}/${flags}`);
    }
    assert.equal(api.lookup(110, 3, 3).symbol, 'two_titan', 'mismatch keeps independently verified name');
    assert.equal(api.lookup(120, 2, 3).symbol, 'dynCall_v');
});

for (const [name, overrides] of [
    ['extensions absent', {x_titan_image: undefined}], ['identity mismatch', {x_titan_image: 'b'.repeat(64)}],
    ['overlapping bodies', {x_titan_function_ranges: [[100, 121], [120, 130], [140, 160]]}],
    ['fractional index', {x_titan_function_imports: 1.5}], ['short names', {x_titan_function_names: [null]}],
    ['bad segment arity', {mappings: 'AA'}], ['bad VLQ', {mappings: '!'}], ['unfinished VLQ', {mappings: 'g'}],
    ['overflow VLQ', {mappings: 'ggggggggA'}], ['decreasing PC', {mappings: 'oGAAA,D'}],
    ['source index overflow', {mappings: 'oGEAA'}], ['negative original line', {mappings: 'oGADA'}],
    ['indexed map', {sections: []}], ['second generated line', {mappings: ';AAAA'}],
]) test('rejects malformed map: ' + name, () => {
    const {api} = adapter();
    assert.throws(() => api.buildIndex(map(overrides), identity));
});

const descriptorCases = [
    ['absent', ''],
    ['data', `Object.defineProperty(Error, key, {value: key === 'stackTraceLimit' ? 7 : function() { ++callbacks; }, writable: true, configurable: true, enumerable: true});`],
    ['nonwritable configurable', `Object.defineProperty(Error, key, {value: key === 'stackTraceLimit' ? 7 : function() { ++callbacks; }, writable: false, configurable: true, enumerable: true});`],
    ['accessor', `Object.defineProperty(Error, key, {get() { ++callbacks; throw 'getter invoked'; }, set(_) { ++callbacks; throw 'setter invoked'; }, configurable: true, enumerable: true});`],
    ['nonconfigurable writable', `Object.defineProperty(Error, key, {value: key === 'stackTraceLimit' ? 7 : function() { ++callbacks; }, writable: true, configurable: false, enumerable: true});`],
    ['immutable', `Object.defineProperty(Error, key, {value: key === 'stackTraceLimit' ? 7 : function() { ++callbacks; }, writable: false, configurable: false, enumerable: true});`],
    ['immutable undefined', `Object.defineProperty(Error, key, {value: undefined, writable: false, configurable: false, enumerable: true});`],
    ['immutable accessor', `Object.defineProperty(Error, key, {get() { ++callbacks; throw 'getter invoked'; }, set(_) { ++callbacks; }, configurable: false, enumerable: true});`],
];
for (const key of ['stackTraceLimit', 'prepareStackTrace']) for (const [name, setup] of descriptorCases) {
    test(`descriptor restoration: ${key} ${name}`, () => {
        const unit = adapter();
        unit.context.key = key;
        unit.evaluate('globalThis.callbacks = 0; ' + setup);
        const before = unit.evaluate('Object.getOwnPropertyDescriptor(Error, key)');
        const unsafe = key === 'prepareStackTrace' && ['accessor', 'immutable accessor', 'immutable'].includes(name);
        assert.equal(unit.capture(), unsafe ? 2 : 0);
        const after = unit.evaluate('Object.getOwnPropertyDescriptor(Error, key)');
        assert.deepEqual(after, before);
        assert.equal(unit.context.callbacks, 0);
        assert.equal(unit.context.constructed, unsafe ? 0 : 1);
        assert.equal(unit.context.stackReads, unsafe ? 0 : 1);
    });
}

test('larger finite stackTraceLimit is retained during capture and restored', () => {
    const unit = adapter();
    unit.evaluate(`Object.defineProperty(Error, 'stackTraceLimit', {value: 900, configurable: true});
        const original = Error;
        globalThis.Error = new Proxy(Error, {construct(target, args) {
            globalThis.observedLimit = Object.getOwnPropertyDescriptor(Error, 'stackTraceLimit').value;
            return Reflect.construct(target, args);
        }});`);
    assert.equal(unit.capture(), 0);
    assert.equal(unit.context.observedLimit, 900);
    assert.equal(unit.evaluate('Object.getOwnPropertyDescriptor(Error, "stackTraceLimit").value'), 900);
});

for (const operation of ['descriptor read', 'prepare descriptor read', 'limit replace', 'prepare replace', 'prepare restore', 'limit restore', 'capture', 'stack read', 'parse', 'storage']) {
    test('failure is contained and following transaction succeeds: ' + operation, () => {
        const unit = adapter();
        unit.evaluate(`Object.defineProperty(Error, 'stackTraceLimit', {value: 7, writable: true, configurable: true});
            Object.defineProperty(Error, 'prepareStackTrace', {value: function() { throw 'host callback'; }, writable: true, configurable: true, enumerable: true});
            globalThis.beforeLimit = Object.getOwnPropertyDescriptor(Error, 'stackTraceLimit');
            globalThis.beforePrepare = Object.getOwnPropertyDescriptor(Error, 'prepareStackTrace');`);
        const beforeLimit = unit.context.beforeLimit, beforePrepare = unit.context.beforePrepare;
        if (operation.includes('descriptor read')) unit.evaluate(`const originalGet = Object.getOwnPropertyDescriptor; let descriptorReads = 0;
            Object.getOwnPropertyDescriptor = function(...args) {
                if (++descriptorReads === ${operation === 'descriptor read' ? 1 : 2}) {
                    Object.getOwnPropertyDescriptor = originalGet; throw 'descriptor read';
                }
                return originalGet(...args);
            };`);
        else if (operation.includes('replace') || operation.includes('restore')) {
            const call = {'limit replace': 1, 'prepare replace': 2, 'prepare restore': 4, 'limit restore': 5}[operation];
            // defineProperty #3 defines the test Error's stack getter.
            unit.evaluate(`const originalDefine = Object.defineProperty; let definitions = 0;
                Object.defineProperty = function(...args) {
                    if (++definitions === ${call}) { Object.defineProperty = originalDefine; throw 'descriptor write'; }
                    return originalDefine(...args);
                };`);
        } else if (operation === 'capture') unit.context.captureFailure = true;
        else if (operation === 'stack read') unit.context.stackReadFailure = true;
        else if (operation === 'parse') unit.context.stackText = {};
        else unit.evaluate(`globalThis.originalHeap = HEAPU32; globalThis.writes = 0;
            globalThis.HEAPU32 = new Proxy(HEAPU32, {get(target, key) { return Reflect.get(target, key, target); }, set(target, key, value) {
                if (++writes === 3) throw 'storage write'; return Reflect.set(target, key, value);
            }});`);
        assert.equal(unit.capture(), 2);
        assert.equal(unit.records().length, 0);
        if (operation === 'parse') assert.equal(unit.context.constructed, 1, 'parsing never constructs another Error');
        // Even a failed restoration must not prevent restoring the other property.
        if (operation !== 'limit restore') assert.deepEqual(unit.evaluate('Object.getOwnPropertyDescriptor(Error, "stackTraceLimit")'), beforeLimit);
        if (operation !== 'prepare restore') assert.deepEqual(unit.evaluate('Object.getOwnPropertyDescriptor(Error, "prepareStackTrace")'), beforePrepare);
        unit.context.captureFailure = false;
        unit.context.stackReadFailure = false;
        unit.context.stackText = 'Error\n    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)';
        if (operation === 'storage') unit.evaluate('HEAPU32 = originalHeap;');
        assert.equal(unit.capture(), 0);
        assert.equal(unit.records().length, 1);
    });
}

for (const key of ['stackTraceLimit', 'prepareStackTrace']) test('absent descriptor deletion failure is contained: ' + key, () => {
    const unit = adapter();
    unit.context.refuseKey = key;
    unit.evaluate(`let refused = false;
        globalThis.Error = new Proxy(Error, {deleteProperty(target, key) {
            if (key === refuseKey && !refused) { refused = true; throw 'descriptor delete'; }
            return Reflect.deleteProperty(target, key);
        }});`);
    assert.equal(unit.capture(), 2);
    const other = key === 'stackTraceLimit' ? 'prepareStackTrace' : 'stackTraceLimit';
    unit.context.other = other;
    assert.equal(unit.evaluate('Object.getOwnPropertyDescriptor(Error, other)'), undefined);
    assert.equal(unit.capture(), 0);
    assert.equal(unit.records().length, 1);
});

test('symbolization writes bounded UTF-8 and contains output failures', () => {
    const unit = adapter();
    unit.api.index.names[1] = 'ℳ'.repeat(100);
    assert.equal(unit.capture(), 0);
    assert.equal(unit.library.titan_browser_trace_symbolize(1032, 8000, 9, 8100, 8, 8200), 1);
    assert.equal(unit.text(8000), 'one.brow');
    assert.equal(unit.text(8100), 'ℳℳ');
    const write = unit.context.stringToUTF8;
    let calls = 0;
    unit.context.stringToUTF8 = (...args) => { if (++calls === 3) throw new Error('output limit'); return write(...args); };
    assert.equal(unit.library.titan_browser_trace_symbolize(1032, 8000, 9, 8100, 8, 8200), 2);
    assert.equal(new Uint32Array(unit.heap.buffer)[2050], 0);
    assert.equal(unit.text(8000), '?');
    assert.equal(unit.library.titan_browser_trace_symbolize(1032, 8000, 9, 8100, 8, 8200), 1);
});

test('real Node Error capture preserves host descriptors and never runs prepare callback', () => {
    const unit = adapter({realError: true});
    unit.evaluate('globalThis.callbacks = 0; Error.prepareStackTrace = () => { ++callbacks; throw "host prepare"; };');
    const before = unit.evaluate('Object.getOwnPropertyDescriptor(Error, "stackTraceLimit")');
    assert.equal(unit.capture(), 0);
    assert.equal(unit.context.callbacks, 0);
    assert.deepEqual(unit.evaluate('Object.getOwnPropertyDescriptor(Error, "stackTraceLimit")'), before);
});

async function settle(unit) {
    for (let i = 0; i < 20 && unit.dependencies.size; ++i) await new Promise(resolve => setImmediate(resolve));
    assert.equal(unit.dependencies.size, 0);
}

test('eager preRun dependency gates readiness until exports-verified browser fetch finishes', async () => {
    let deliver;
    const unit = adapter({node: false, fetch: path => {
        assert.equal(path, '/maps/image.wasm.map');
        return new Promise(resolve => { deliver = resolve; });
    }});
    unit.api.index = null;
    assert.equal(unit.hooks.length, 1);
    unit.hooks[0]();
    assert.equal(unit.dependencies.has('titan-trace-map'), true);
    await Promise.resolve();
    assert.equal(unit.context.Module.titanBrowserTrace, undefined);
    assert.equal(unit.capture(), 1);
    deliver({ok: true, arrayBuffer: async () => new TextEncoder().encode(JSON.stringify(map())).buffer});
    await settle(unit);
    const result = unit.context.Module.titanBrowserTrace;
    assert.equal(result.state, 'ready');
    assert.equal(result.reason, null);
    assert.equal(result.mapBytes, new TextEncoder().encode(JSON.stringify(map())).length);
    assert.equal(result.indexBytes, 4 * 12 + 3 * 12);
    assert.ok(result.loadMilliseconds >= 0);
    assert.equal(unit.capture(), 0);
    assert.equal(unit.warnings.length, 0);
});

for (const [name, data] of [['ready', map()], ['extensions absent', {version: 3, sources: [], names: [], mappings: ''}], ['wrong image', map({x_titan_image: 'b'.repeat(64)})]]) {
    test('Node eager load: ' + name, async () => {
        // Build a valid unit first; the eager loader reads the independently supplied bytes.
        const unit = adapter();
        unit.context.readBinary = path => { unit.reads.push(path); return new TextEncoder().encode(JSON.stringify(data)); };
        unit.api.index = null;
        unit.hooks[0]();
        await settle(unit);
        assert.equal(unit.context.Module.titanBrowserTrace.state, name === 'ready' ? 'ready' : 'degraded');
        assert.equal(unit.warnings.length, name === 'ready' ? 0 : 1);
        if (name !== 'ready') assert.match(unit.warnings[0], /^Titan browser trace: /);
        const requests = unit.reads.length;
        assert.equal(unit.capture(), name === 'ready' ? 0 : 1);
        assert.equal(unit.capture(), name === 'ready' ? 0 : 1);
        assert.equal(unit.reads.length, requests, 'capture never reloads a map');
    });
}

test('pinned generated Emscripten factory waits for trace initialization with instantiated exports', {
    skip: !process.env.TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE,
}, async () => {
    const image = resolve(process.env.TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE);
    const directory = await mkdtemp(join(tmpdir(), 'titan-trace-lifecycle-'));
    try {
        const originalMap = JSON.parse(await readFile(image.replace(/\.mjs$/, '.wasm.map'), 'utf8'));
        const extendedMap = {...originalMap, x_titan_image: identity, x_titan_function_imports: 0,
            x_titan_function_ranges: [], x_titan_function_names: []};
        const mapPath = join(directory, 'lifecycle.wasm.map');
        await writeFile(mapPath, JSON.stringify(extendedMap));
        const {default: factory} = await import(pathToFileURL(image).href);
        let mapRequested = 0;
        const module = await factory({locateFile(name) {
            if (name.endsWith('.map')) { ++mapRequested; return mapPath; }
            return join(dirname(image), name);
        }});
        assert.equal(mapRequested, 1);
        assert.equal(module.titanBrowserTrace.state, 'ready', module.titanBrowserTrace.reason);
        assert.equal(module._trace_capture_once(), 0);
        // The unextended emcc map is intentionally accepted only as degraded.
        const degraded = await factory({locateFile: name => join(dirname(image), name)});
        assert.equal(degraded.titanBrowserTrace.state, 'degraded');
        assert.equal(degraded._trace_capture_once(), 1);
    } finally { await rm(directory, {recursive: true, force: true}); }
});

test('pinned emcc empty sourcesContent table needs no source text', () => {
    const {api} = adapter();
    const index = api.buildIndex(map({sourcesContent: []}), identity);
    assert.equal(index.bases[0], 'one.browser.titan');
    assert.throws(() => api.buildIndex(map({sourcesContent: ['only one source']}), identity));
});

test('C merge retains entry and known-name identity despite runtime/Lua basenames', {
    skip: !process.env.TITAN_BROWSER_TRACE_FILTER_IMAGE,
}, async () => {
    const image = resolve(process.env.TITAN_BROWSER_TRACE_FILTER_IMAGE);
    const directory = await mkdtemp(join(tmpdir(), 'titan-trace-filter-'));
    try {
        const index = map({sources: ['titan.c', 'lvm.c'],
            mappings: [[100, 1, 0, 0], [10, -1, 0, 0], [10, 1, 0, 0],
                [10, -1, 0, 0], [10, 0, 0, 0], [10, 1, 0, 0]]
                .map(row => row.map(vlq).join('')).join(','),
            x_titan_function_ranges: [[100, 110], [110, 120], [120, 130],
                [130, 140], [140, 150], [150, 160]],
            x_titan_function_names: [null, 'filter_inner_native', 'filter_inner_titanentry_lua',
                'filter_outer_native', 'filter_outer_titanentry_lua', 'unregistered_titan', 'lua_helper']});
        const mapPath = join(directory, 'filter.wasm.map');
        await writeFile(mapPath, JSON.stringify(index));
        const {default: factory} = await import(pathToFileURL(image).href);
        const module = await factory({locateFile: name => name.endsWith('.map') ? mapPath : join(dirname(image), name)});
        assert.equal(module.titanBrowserTrace.state, 'ready', module.titanBrowserTrace.reason);
        const original = Object.getOwnPropertyDescriptor(globalThis, 'Error');
        const captured = 'Error\n' + [
            [1, 101], [5, 141], [2, 111], [3, 121], [6, 151], [4, 131],
        ].map(([index, pc]) => `    at frame (wasm://wasm/image:wasm-function[${index}]:0x${pc.toString(16)})`).join('\n');
        let pointer;
        try {
            Object.defineProperty(globalThis, 'Error', {...original,
                value: function Error() { this.stack = captured; }});
            pointer = module._trace_filter_case();
        } finally { Object.defineProperty(globalThis, 'Error', original); }
        assert.equal(module._trace_filter_status(), 2, 'original Lua error outcome is preserved');
        const bytes = module.HEAPU8;
        const trace = new TextDecoder().decode(bytes.subarray(pointer, bytes.indexOf(0, pointer)));
        const inner = trace.indexOf('in filter.inner');
        const between = trace.indexOf('filter-wrapper.lua:2:');
        const outer = trace.indexOf('in filter.outer');
        assert.ok(inner >= 0 && between > inner && outer > between, trace);
        assert.equal(trace.match(/in filter[.]inner/g)?.length, 1, trace);
        assert.equal(trace.match(/in filter[.]outer/g)?.length, 1, trace);
        assert.doesNotMatch(trace, /titanentry|unregistered_titan|lua_helper/);
    } finally { await rm(directory, {recursive: true, force: true}); }
});
