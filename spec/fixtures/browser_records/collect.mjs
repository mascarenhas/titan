// Browser records of the release profile (doc/implementation/browser-target.md#records):
//
//   node collect.mjs --sdk SDK --images DIR [--app APP] --engines node,chromium
//       [--measure sizes,startup,memory,recursion] --out FILE
//
// DIR holds records.mjs and stack.mjs (spec/browser/build-records.lua), and APP
// the complete application's build. It records, unless --measure selects
// fewer:
//
// - sizes: app.wasm, app.mjs, app.wasm.trace and app.wasm.map, raw, gzip -9
//   and brotli -q 11;
// - startup under Node, in 5 fresh instances: create() until initialize()
//   resolves for the application and records.mjs, and until records.mjs's
//   first output;
// - memory on each engine: records.mjs's `memory` run, which parks Tasks until
//   creating one fails, with Titan's allocation error, or until the engine
//   fails first;
// - recursion on each engine: the deepest passing depth of each stack shape,
//   each probe in a fresh run.
//
// Node runs images through the SDK's titan-browser-run, the other engines
// through spec/browser/playwright-run.mjs. It writes FILE and FILE with `.md`
// in place of `.json`. The numbers never fail it; a run that fails in a way no
// record explains does, and so does a memory run that completes without
// Titan's allocation error.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {parseArgs} from 'node:util';
import {brotliCompressSync, constants, gzipSync} from 'node:zlib';

const {values: options} = parseArgs({options: {
  sdk: {type: 'string'}, images: {type: 'string'}, app: {type: 'string'},
  engines: {type: 'string'}, measure: {type: 'string', default: 'sizes,startup,memory,recursion'},
  out: {type: 'string'},
}});
const measure = new Set(options.measure.split(','));
for (const name of measure) assert.ok(['sizes', 'startup', 'memory', 'recursion'].includes(name), name);
const needed = ['sdk', 'images', 'engines', 'out'];
if (measure.has('sizes') || measure.has('startup')) needed.push('app');
for (const name of needed) {
  assert.ok(options[name], 'usage: collect.mjs --sdk SDK --images DIR [--app APP] --engines LIST ' +
    '[--measure LIST] --out FILE');
}
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const sdk = resolve(options.sdk);
const images = resolve(options.images);
const app = options.app && resolve(options.app);
const engines = options.engines.split(',');
for (const engine of engines) assert.ok(['node', 'chromium', 'firefox', 'webkit'].includes(engine), engine);

function summary(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  const round = value => Math.round(value * 10) / 10;
  return {median: round(sorted[Math.floor(sorted.length / 2)]), max: round(sorted.at(-1)), samples: samples.length};
}

async function sizes() {
  const result = {};
  for (const name of ['app.wasm', 'app.mjs', 'app.wasm.trace', 'app.wasm.map']) {
    const bytes = await readFile(join(app, name));
    result[name] = {
      raw: bytes.length,
      gzip: gzipSync(bytes, {level: 9}).length,
      brotli: brotliCompressSync(bytes, {params: {
        [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: bytes.length}}).length,
    };
  }
  return result;
}

// Fresh instances of one image in this Node process. With `args`, each also
// runs main and times its first output.
async function startup(file, args) {
  const {default: create} = await import(pathToFileURL(file).href);
  const initialize = [], output = [];
  for (let index = 0; index < 5; index++) {
    let first;
    const started = performance.now();
    const instance = create({stdout() { first ??= performance.now(); }, stderr() {}, requireTrace: true});
    try {
      await instance.initialize();
      initialize.push(performance.now() - started);
      if (args) {
        const result = await instance.run(args);
        assert.equal(`${result.kind} ${result.status}`, 'returned 0', `${file} ${args.join(' ')}`);
        output.push(first - started);
      }
    } finally {
      await instance.dispose();
    }
  }
  return args ? {initializeMs: summary(initialize), firstOutputMs: summary(output)}
    : {initializeMs: summary(initialize)};
}

// One run of an image in a fresh engine.
function run(engine, image, args, timeout) {
  const file = join(images, image + '.mjs');
  const command = engine === 'node'
    ? [join(sdk, 'titan-browser-run.mjs'), '--engine', 'node']
    : [join(repository, 'spec/browser/playwright-run.mjs'), '--engine', engine, '--image', '--sdk', sdk];
  const result = spawnSync(process.execPath, [...command, '--timeout', String(timeout), '--root', images,
    file, '--', ...args], {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: timeout + 60000});
  if (result.error) throw result.error;
  return {status: result.status, text: result.stdout + result.stderr};
}

// How a recursion that ran out of stack ended.
function exhaustion(result, what) {
  if (result.status === 75 && /call stack|too much recursion/i.test(result.text)) return 'engine call stack';
  if (result.status === 70) return 'abort';
  if (result.status === 71) return 'trap';
  if (result.status === 1) return 'Titan error';
  throw new Error(`${what} failed with ${result.status}:\n${result.text}`);
}

// The deepest depth that passes, to within 1%: doubling from 1000 to the
// first failure, then bisecting.
function deepest(engine, image, mode) {
  const probe = depth => {
    const result = run(engine, image, [mode, String(depth)], 60000);
    return result.status === 0 ? undefined : exhaustion(result, `${engine} ${image} ${mode} ${depth}`);
  };
  let low = 0, high = 1000, failure, probes = 0;
  for (;;) {
    probes++;
    failure = probe(high);
    if (failure) break;
    low = high;
    high *= 2;
    assert.ok(high <= 1 << 24, `${engine} ${mode} recursion never ran out of stack`);
  }
  while (high - low > Math.max(1, Math.floor(low / 100))) {
    const middle = Math.floor((low + high) / 2);
    probes++;
    const outcome = probe(middle);
    if (outcome) [high, failure] = [middle, outcome];
    else low = middle;
  }
  return {passing: low, failing: high, failure, probes};
}

// The memory run ends with Titan's allocation error once creating a Task
// fails. An engine that fails before that, which the browser target documents
// as fatal, is recorded as that engine's limit instead.
function memory(engine) {
  const result = run(engine, 'records', ['memory'], 300000);
  const phases = {}, parked = [];
  for (const match of result.text.matchAll(/^RECORD (\w+) heap=(\d+) used=(\d+) lua=(\d+)(?: tasks=(\d+))?(?: error=(.*))?$/gm)) {
    const phase = {heap: Number(match[2]), used: Number(match[3]), lua: Number(match[4])};
    if (match[5] !== undefined) phase.tasks = Number(match[5]);
    if (match[6] !== undefined) phase.error = match[6];
    if (match[1] === 'parked') parked.push(phase);
    else phases[match[1]] = phase;
  }
  const what = `${engine} memory run (status ${result.status}):\n${result.text}`;
  assert.ok(phases.start && phases.steady && parked.length >= 2, what);
  const [first, last] = [parked[0], parked.at(-1)];
  const record = {...phases, perTaskBytes: Math.round((last.used - first.used) / (last.tasks - first.tasks))};
  if (result.status === 0) {
    assert.ok(phases.limit && phases.end, what);
    assert.match(phases.limit.error, /could not create coroutine: Out of memory/,
      `${engine}: the Task limit was not Titan's allocation error`);
    record.limit.failure = 'Titan error';
  } else {
    const failure = {70: 'engine abort', 71: 'trap', 75: 'engine failure'}[result.status];
    assert.ok(failure, what);
    const diagnostic = result.text.split('\n').filter(line => /^titan-(browser|playwright)-run: /.test(line)).at(-1);
    record.limit = {...last, failure, error: diagnostic ?? ''};
  }
  return record;
}

const records = {
  profile: (await readFile(join(sdk, 'build-profile'), 'utf8')).trim(),
  node: process.version,
};
if (measure.has('sizes')) records.sizes = await sizes();
if (measure.has('startup')) {
  records.startup = {node: {app: await startup(join(app, 'app.mjs')),
    records: await startup(join(images, 'records.mjs'), ['start'])}};
}
if (measure.has('memory')) records.memory = {};
if (measure.has('recursion')) records.recursion = {};
for (const engine of engines) {
  if (records.memory) records.memory[engine] = memory(engine);
  if (records.recursion) {
    records.recursion[engine] = {
      main: deepest(engine, 'stack', 'main'),
      coroutine: deepest(engine, 'stack', 'coroutine'),
      task: deepest(engine, 'records', 'task'),
      'task-sleep': deepest(engine, 'records', 'sleep'),
    };
  }
}

const kib = bytes => (bytes / 1024).toFixed(1);
const mib = bytes => (bytes / 1048576).toFixed(1);
const lines = [`# Browser records (${records.profile}, Node ${records.node})`];
if (records.sizes) {
  lines.push('', '| File | Raw KiB | gzip -9 KiB | brotli -q 11 KiB |', '| --- | ---: | ---: | ---: |');
  for (const [name, size] of Object.entries(records.sizes)) {
    lines.push(`| ${name} | ${kib(size.raw)} | ${kib(size.gzip)} | ${kib(size.brotli)} |`);
  }
}
if (records.startup) {
  lines.push('', '| Node startup (5 fresh instances) | Median ms | Max ms |', '| --- | ---: | ---: |');
  for (const [image, timing] of Object.entries(records.startup.node)) {
    for (const [name, value] of Object.entries(timing)) lines.push(`| ${image} ${name} | ${value.median} | ${value.max} |`);
  }
}
if (records.memory) {
  lines.push('', 'Memory is the WebAssembly memory size, which never shrinks; in use is what malloc has handed out.', '',
    '| Engine | Start MiB (in use) | Steady MiB (in use) | Parked Tasks at the limit | KiB per Task | Limit | Peak MiB | In use at the end MiB |',
    '| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |');
  for (const [engine, phase] of Object.entries(records.memory)) {
    const peak = phase.end ?? phase.limit;
    lines.push(`| ${engine} | ${mib(phase.start.heap)} (${mib(phase.start.used)}) | ` +
      `${mib(phase.steady.heap)} (${mib(phase.steady.used)}) | ${phase.limit.tasks} | ` +
      `${kib(phase.perTaskBytes)} | ${phase.limit.failure} | ${mib(peak.heap)} | ` +
      `${phase.end ? mib(phase.end.used) : '—'} |`);
  }
}
if (records.recursion) {
  lines.push('', '| Engine | Stack | Deepest passing depth | Failing depth | How it failed |', '| --- | --- | ---: | ---: | --- |');
  for (const [engine, shapes] of Object.entries(records.recursion)) {
    for (const [shape, row] of Object.entries(shapes)) {
      lines.push(`| ${engine} | ${shape} | ${row.passing} | ${row.failing} | ${row.failure} |`);
    }
  }
}
const out = resolve(options.out);
await mkdir(dirname(out), {recursive: true});
await writeFile(out, JSON.stringify(records, null, 2) + '\n');
await writeFile(out.replace(/\.json$/, '') + '.md', lines.join('\n') + '\n');
console.log(lines.join('\n'));
