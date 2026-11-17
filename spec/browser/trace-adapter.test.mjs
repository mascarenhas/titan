import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import vm from 'node:vm';

const source = await readFile(new URL('../../titan-runtime/browser/titan-browser-trace.js', import.meta.url), 'utf8');
const stacks = JSON.parse(await readFile(new URL('../fixtures/browser_trace_adapter/stacks.json', import.meta.url), 'utf8'));
const currentStacks = JSON.parse(await readFile(new URL('../fixtures/browser_trace_adapter/stacks-jspi-current.json', import.meta.url), 'utf8'));
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
// The compiler's writer turns an extended map into the published table, so
// these units read exactly what a link writes (TITAN_LUA selects the Lua).
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const tables = new Map();
function table(data) {
    const input = JSON.stringify(data);
    if (!tables.has(input)) tables.set(input, new Uint8Array(execFileSync(process.env.TITAN_LUA ?? 'lua', ['-E', '-e',
        `package.path = ${JSON.stringify(repository + '/?.lua;')} .. package.path
        local bytes = assert(require("titan-compiler.browsertrace").trace_table(io.read("a")))
        io.stdout:write(bytes)`], {input})));
    return tables.get(input);
}
function adapter({realError = false, bytes = table(map()), node = true, fetch: fetcher} = {}) {
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
        readBinary(path) { reads.push(path); return bytes; },
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
    api.index = api.readTable(bytes, identity);
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
        if (name.includes('-jspi-')) {
            // These raw V8 captures come from capture-jspi.mjs driving the real
            // native post-resume trace case, not from renamed old snapshots.
            const expected = Array.from(stack.matchAll(/wasm-function\[(\d+)\]:(0x[0-9a-f]+)/gi),
                match => [Number.parseInt(match[2], 16), Number(match[1]), 3]);
            assert.ok(expected.length > 0, 'JSPI capture has no actual Wasm frames');
            assert.deepEqual(JSON.parse(JSON.stringify(result.records)), expected);
            assert.equal(result.truncated, false);
            return;
        }
        const isJsc = /^(webkit|safari)/.test(name);
        const isDepth = name.includes('-depth-');
        const isV8Default = name.includes('-default') && /^(node|chrom)/.test(name);
        const expected = isV8Default ? 9 : isDepth ? (isJsc ? 99 : name.startsWith('firefox') ? 127 : 199)
            : name.includes('-longjmp-before-') ? 54 : name.includes('-longjmp-after-') ? 53 : 51;
        assert.equal(result.records.length, expected);
        assert.equal(result.records[0][1], 39);
        assert.equal(result.records[0][2], isJsc ? 2 : 3);
        assert.equal(result.records[0][0] > 0, !isJsc);
        // Historical JSC snapshots ended at its then-hidden 100-frame ceiling.
        // That old bound cannot be inferred from current JSC's frame dialect.
        assert.equal(result.truncated, (isDepth && !isJsc) || isV8Default);
        if (isDepth && isJsc) assert.equal(api.parse(stack, 512, 100).truncated, true,
            'the recorded 100-frame input still reaches an explicit host limit');
    });
}

for (const row of currentStacks.cases) test('current JSPI parser: ' + row.name, () => {
    const {api} = adapter();
    const result = api.parse(row.stack, row.capacity, row.limit);
    assert.deepEqual(JSON.parse(JSON.stringify(result.records)), row.expectedRecords);
    assert.equal(result.truncated, row.truncated);
});

test('mixed warm/cold JSC always uses bracketed indexes and never invents lines', () => {
    const {api} = adapter();
    assert.deepEqual(JSON.parse(JSON.stringify(api.parse('123@wasm-function[1]\nname@image.wasm:wasm-function[3]', 512, 640).records)), [[0, 1, 2], [0, 3, 2]]);
    assert.equal(api.lookup(0, 1, 2).line, 0);
    assert.equal(api.lookup(0, 1, 2).base, 'one.browser.titan');
});

for (const [engine, wasm] of [
    ['V8', '    at leaf (wasm://wasm/image:wasm-function[1]:0x6e)'],
    ['JSC', 'leaf@image.wasm:wasm-function[1]'],
]) for (const count of [511, 512, 513]) test(`${engine} raw capacity boundary ${count}`, () => {
    const {api} = adapter();
    const stack = (engine === 'V8' ? 'Error\n' : '') + Array(count).fill(wasm).join('\n');
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

for (const [engine, wasm, ceiling, limit] of [
    ['JSC explicit host limit', 'leaf@image.wasm:wasm-function[1]', 100, 100],
    ['SpiderMonkey engine ceiling', 'leaf@image.wasm:wasm-function[1]:0x6e', 128, 640],
]) for (const [form, frame] of [
    ['URL without line', 'foo@http://host/app.js'],
    ['debugger eval', '@debugger eval code'],
    ['bare name', 'bareName@'],
    ['named location without line', 'bareName@native'],
    ['anonymous without location', '@'],
]) for (const count of [ceiling - 1, ceiling]) {
    test(`${engine} counts ${form} at boundary ${count}`, () => {
        const {api} = adapter();
        const stack = [wasm, ...Array(count - 1).fill(frame), '', '  '].join('\n');
        const result = api.parse(stack, 512, limit);
        assert.equal(result.records.length, 1, 'JS-only forms never become Wasm records');
        assert.equal(result.truncated, count === ceiling);
    });
}

for (const cause of ['async', 'promise callback', 'VoidFunction', 'setTimeout handler', 'other host task']) {
    for (const count of [127, 128]) test(`SpiderMonkey excludes ${cause} ancestry after ${count} current frames`, () => {
        const {api} = adapter();
        const current = ['leaf@image.wasm:wasm-function[1]:0x6e',
            ...Array(count - 1).fill('foo@http://host/app.js')];
        const history = [cause + '*saved@debugger eval code', ...Array(100).fill('bareName@'),
            'old@image.wasm:wasm-function[3]:0x91'];
        const result = api.parse([...current, ...history].join('\n'), 512, 640);
        assert.equal(result.records.length, 1, 'saved Wasm ancestry is excluded too');
        assert.equal(result.truncated, count === 128, 'only synchronous frames reach the ceiling');
    });
}

test('asterisks in Wasm names or JS URLs are not saved-parent boundaries', () => {
    const {api} = adapter();
    const stack = ['image*.wasm.leaf@http://host/image*.wasm:wasm-function[1]:0x6e',
        'host@http://host/app*.js:1:2',
        'image*.wasm.outer@http://host/image*.wasm:wasm-function[3]:0x91'].join('\n');
    const result = api.parse(stack, 512, 640);
    assert.deepEqual(JSON.parse(JSON.stringify(result.records)), [[110, 1, 3], [145, 3, 3]]);
    assert.equal(result.truncated, false);
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

test('a frame takes its file and line from .titan segments only', () => {
    // Body 1 (100..120): C inlined before the first statement (minicoro.c:66),
    // the body's own line (coroutine.titan:44), then inlined C again.
    // Body 2 (120..130): its own line (coroutine.titan:10), then Titan code
    // inlined from another file (other.titan:5). Body 3 (140..160): C only.
    const {api} = adapter({bytes: table(map({
        sources: ['path/coroutine.titan', 'runtime/minicoro.c', 'path/other.titan'],
        mappings: [[100, 1, 65, 0], [5, -1, -22, 0], [5, 1, 22, 0],
            [10, -1, -56, 0], [5, 2, -5, 0], [15, -1, -4, 0]]
            .map(row => row.map(vlq).join('')).join(','),
        x_titan_function_names: [null, 'trampoline_titan', 'caller_titan', 'c_helper'],
    }))});
    for (const [pc, index, flags, base, line] of [
        // A PC in inlined C: the declaring basename and no line, also when
        // the C comes first in the body.
        [100, 1, 3, 'coroutine.titan', 0], [112, 1, 3, 'coroutine.titan', 0],
        [105, 1, 3, 'coroutine.titan', 44], [0, 1, 2, 'coroutine.titan', 0],
        // Titan code inlined from another file keeps its own file and line.
        [121, 2, 3, 'coroutine.titan', 10], [126, 2, 3, 'other.titan', 5],
        [0, 2, 2, 'coroutine.titan', 0],
        // A body with no .titan segment declares nothing.
        [145, 3, 3, '?', 0], [0, 3, 2, '?', 0],
    ]) {
        const result = api.lookup(pc, index, flags);
        assert.equal(result.base, base, `base at ${pc}/${index}/${flags}`);
        assert.equal(result.line, line, `line at ${pc}/${index}/${flags}`);
    }
    assert.equal(api.lookup(112, 1, 3).symbol, 'trampoline_titan');
    assert.equal(api.lookup(145, 3, 3).symbol, 'c_helper');
});

// The writer refuses malformed maps (spec/browser_trace_map_spec.lua); the
// reader checks only what a damaged or foreign table could get wrong.
const valid = table(map());
function damaged(edit) {
    const bytes = new Uint8Array(valid);
    edit(new DataView(bytes.buffer), bytes);
    return bytes;
}
// Header words: imports 72, bodies 76, rows 80, bases 84, string bytes 88;
// then bodies, rows, offsets and the i16 sources and declaring files.
const rowsAt = 92 + 4 * 2 * 3, offsetsAt = rowsAt + 4 * 2 * 4, sourcesAt = offsetsAt + 4 * (2 + 1 + 3 + 1);
for (const [name, bytes, message = 'invalid trace table'] of [
    ['short', valid.subarray(0, 91)], ['magic', damaged((_, b) => { b[0] = 0x58; })],
    ['version', damaged(v => v.setUint32(4, 2, true))],
    ['image', damaged((_, b) => { b[8] = 0x62; }), 'trace table image does not match'],
    ['truncated', valid.subarray(0, valid.length - 1)], ['trailing byte', new Uint8Array([...valid, 0])],
    ['row count', damaged(v => v.setUint32(80, 5, true))],
    ['empty body', damaged(v => v.setUint32(92 + 4 * 3, 0, true))],
    ['body overflow', damaged(v => v.setUint32(92, 0xffffffff, true))],
    ['offset overflow', damaged(v => v.setUint32(rowsAt + 4, 0xffffffff, true))],
    ['row source', damaged(v => v.setInt16(sourcesAt, 2, true))],
    ['negative row source', damaged(v => v.setInt16(sourcesAt, -2, true))],
    ['declaring file', damaged(v => v.setInt16(sourcesAt + 2 * 4, 2, true))],
    ['decreasing string offset', damaged(v => v.setUint32(offsetsAt + 4, 0xffff, true))],
    ['string end', damaged(v => v.setUint32(offsetsAt + 4 * 6, 0, true))],
]) test('rejects malformed table: ' + name, () => {
    const {api} = adapter({realError: true});
    assert.throws(() => api.readTable(bytes, identity), {message});
});

test('reads a table at any byte offset', () => {
    const {api} = adapter();
    const shifted = new Uint8Array(valid.length + 1);
    shifted.set(valid, 1);
    assert.equal(api.readTable(shifted.subarray(1), identity).lines[2], 8);
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
    const unit = adapter({bytes: table(map({x_titan_function_names: [null, 'ℳ'.repeat(100), 'dynCall_v', 'two_titan']}))});
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
        assert.equal(path, '/maps/image.wasm.trace');
        return new Promise(resolve => { deliver = resolve; });
    }});
    unit.api.index = null;
    assert.equal(unit.hooks.length, 1);
    unit.hooks[0]();
    assert.equal(unit.dependencies.has('titan-trace-table'), true);
    await Promise.resolve();
    assert.equal(unit.context.Module.titanBrowserTrace, undefined);
    assert.equal(unit.capture(), 1);
    deliver({ok: true, arrayBuffer: async () => valid.slice().buffer});
    await settle(unit);
    const result = unit.context.Module.titanBrowserTrace;
    assert.equal(result.state, 'ready');
    assert.equal(result.reason, null);
    assert.equal(result.traceBytes, valid.length);
    // The table itself, then four rows of offsets and lines, three bodies of starts and ends.
    assert.equal(result.indexBytes, valid.length + 2 * 4 * 4 + 2 * 3 * 4);
    assert.ok(result.loadMilliseconds >= 0);
    assert.equal(unit.capture(), 0);
    assert.equal(unit.warnings.length, 0);
});

for (const [name, bytes] of [['ready', valid], ['a map instead of a table', new TextEncoder().encode(JSON.stringify(map()))],
    ['wrong image', table(map({x_titan_image: 'b'.repeat(64)}))]]) {
    test('Node eager load: ' + name, async () => {
        // Build a valid unit first; the eager loader reads the independently supplied bytes.
        const unit = adapter();
        unit.context.readBinary = path => { unit.reads.push(path); return bytes; };
        unit.api.index = null;
        unit.hooks[0]();
        await settle(unit);
        assert.equal(unit.context.Module.titanBrowserTrace.state, name === 'ready' ? 'ready' : 'degraded');
        assert.equal(unit.warnings.length, name === 'ready' ? 0 : 1);
        if (name !== 'ready') assert.match(unit.warnings[0], /^Titan browser trace: /);
        const requests = unit.reads.length;
        assert.equal(unit.capture(), name === 'ready' ? 0 : 1);
        assert.equal(unit.capture(), name === 'ready' ? 0 : 1);
        assert.equal(unit.reads.length, requests, 'capture never reloads a table');
    });
}

test('pinned generated Emscripten factory waits for trace initialization with instantiated exports', {
    skip: !process.env.TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE,
}, async () => {
    const image = resolve(process.env.TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE);
    const directory = await mkdtemp(join(tmpdir(), 'titan-trace-lifecycle-'));
    try {
        const originalMap = JSON.parse(await readFile(image.replace(/\.mjs$/, '.wasm.map'), 'utf8'));
        const tablePath = join(directory, 'lifecycle.wasm.trace');
        await writeFile(tablePath, table({...originalMap, x_titan_image: identity, x_titan_function_imports: 0,
            x_titan_function_ranges: [], x_titan_function_names: []}));
        const {default: factory} = await import(pathToFileURL(image).href);
        let tableRequested = 0;
        const module = await factory({locateFile(name) {
            if (name.endsWith('.trace')) { ++tableRequested; return tablePath; }
            return join(dirname(image), name);
        }});
        assert.equal(tableRequested, 1);
        assert.equal(module.titanBrowserTrace.state, 'ready', module.titanBrowserTrace.reason);
        assert.equal(module._trace_capture_once(), 0);
        // Without its table the image runs degraded.
        const degraded = await factory({locateFile: name => join(dirname(image), name)});
        assert.equal(degraded.titanBrowserTrace.state, 'degraded');
        assert.equal(degraded._trace_capture_once(), 1);
    } finally { await rm(directory, {recursive: true, force: true}); }
});

test('C merge keeps entry and known names and drops symbols with no .titan source', {
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
        const tablePath = join(directory, 'filter.wasm.trace');
        await writeFile(tablePath, table(index));
        const {default: factory} = await import(pathToFileURL(image).href);
        const module = await factory({locateFile: name => name.endsWith('.trace') ? tablePath : join(dirname(image), name)});
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
