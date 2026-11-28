// `make playground-sdk`'s last check: the bundled compiler, through its
// adapter, opens over its own catalog; checks, describes, completes and emits
// a program; recovers from refused requests; and refuses work once disposed.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

const bundle = process.argv[2];
const asset = name => readFile(join(bundle, name)).then(bytes => new Uint8Array(bytes));
const {openCompiler} = await import(pathToFileURL(join(bundle, 'titanc.mjs')).href);
const assets = {wasm: await asset('titanc.wasm'), catalog: await asset('stdlib_catalog.bin'),
  analysisTarget: await asset('analysis-target'), absentModules: await asset('absent-modules')};

// A damaged catalog fails the open itself.
const damaged = assets.catalog.slice();
damaged[damaged.length - 1] ^= 0xff;
await assert.rejects(openCompiler({...assets, catalog: damaged}), /catalog/);

const compiler = await openCompiler(assets);
// Non-ASCII text before every position exercises the UTF-16/UTF-8 conversion.
const main = `local io = import "io"
local moons = import "moons"

function main(args: {string}): integer
  io.print("Titan — ☾ " .. moons.count() .. " neighbours")
  return 0
end
`;
const files = {'main.titan': main, 'moons.titan': 'function count(): integer\n  return 146\nend\n'};
assert.deepEqual(compiler.check(files), []);

const broken = compiler.check({...files, 'moons.titan': 'function count(): integer\n  return "many"\nend\n'});
assert.equal(broken.length, 1);
assert.deepEqual(broken[0].at, {path: 'moons.titan', from: 35, to: 35});
assert.match(broken[0].message, /expected integer but found string/);

const count = main.indexOf('count()');
const hover = compiler.hover(files, {path: 'main.titan', offset: count + 1});
assert.equal(hover.signature, 'count: function (): integer');
assert.deepEqual(hover.at, {path: 'main.titan', from: count, to: count + 5});

const partial = main.replace('io.print(', 'io.pr(');
const completion = compiler.complete({...files, 'main.titan': partial},
  {path: 'main.titan', offset: partial.indexOf('io.pr(') + 5});
assert.ok(completion.items.some(item => item.label === 'print' && item.kind === 'function'));

const importing = main.replace('import "moons"', 'import ""');
const caret = importing.indexOf('""') + 1;
const modules = compiler.complete({...files, 'main.titan': importing}, {path: 'main.titan', offset: caret});
assert.deepEqual(modules.replace, {path: 'main.titan', from: caret, to: caret});
const labels = new Set(modules.items.map(item => item.label));
for (const label of ['moons', 'moons.titan', 'json', 'titan.json', 'io']) assert.ok(labels.has(label), label);
assert.ok(!labels.has('main'));

const emitted = compiler.emit_c(files, '0123456789abcdef'.repeat(4));
assert.deepEqual(emitted.diagnostics, []);
assert.deepEqual(emitted.units, ['main.c', 'moons.c']);
assert.equal(emitted.entry, '.titan-links/main/synthetic/main__entrypoint.c');
assert.ok(emitted.files[emitted.entry].includes('0123456789abcdef'));
assert.ok(!emitted.files['main.c'].includes('titan_source'));

// A unit importing titan.lua retains the filesystem runtime's marker; a pure
// program does not. The bundle carries the storage runtime build_trace embeds.
assert.ok(!emitted.files['main.c'].includes('titan_browser_vfs_linked'));
const storage = compiler.emit_c({'main.titan': 'local lua = import "lua"\n\nfunction main(args: {string}): integer\n' +
  '  local state = lua.new()\n  state:close()\n  return 0\nend\n'}, 'fedcba9876543210'.repeat(4));
assert.deepEqual(storage.diagnostics, []);
assert.ok(storage.files['main.c'].includes('(void)titan_browser_vfs_linked();'));
for (const name of ['titan-browser-vfs.mjs', 'titan-browser-sql.mjs', 'titan-storage-worker.mjs',
  'titan-sqlite3-service.wasm']) {
  assert.ok((await asset(name)).length > 0, name);
}

// Refused requests leave the compiler usable.
assert.throws(() => compiler.check({'../main.titan': ''}), /invalid project path/);
assert.throws(() => compiler.hover(files, {path: 'absent.titan', offset: 0}), TypeError);
assert.throws(() => compiler.check({'main.titan': 7}), TypeError);
// A partial storage tuple is refused before it reaches the compiler, even without vfs.
assert.throws(() => compiler.build_trace({linked: new Uint8Array(), identity: '0'.repeat(64), factory: '',
  loader: '', sql: '', worker: '', sqlite: new Uint8Array()}), TypeError);
assert.deepEqual(compiler.check(files), []);

// A second compiler is independent; disposal is idempotent and final.
const second = await openCompiler(assets);
compiler.dispose();
compiler.dispose();
assert.throws(() => compiler.check(files), /disposed/);
assert.deepEqual(second.check(files), []);
second.dispose();
