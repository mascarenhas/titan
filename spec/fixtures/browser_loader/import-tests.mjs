import {encode, rejection} from './checks.mjs';

// The embedder's raw Wasm import maps, create({imports}), on loader_names
// images, which import nothing beyond Titan's own entry imports. Accepted
// maps initialize and run, from this realm or another one; refused maps fail
// at create, and a function's refused result fails initialization before any
// C runs.
export async function imports(context, paths) {
  const foreign = await foreignRealm();
  context.assert(Object.getPrototypeOf(foreign.record({})) !== Object.prototype,
    'the foreign realm shares this realm\'s Object');
  const plain = 'browser imports must be a plain object of modules, or a function returning one synchronously';
  const reserved = name => `browser import ${name} is reserved for the Titan runtime`;
  let runs = 0;
  for (const path of paths) {
    const image = await context.image(path);
    const make = imports => image.create({locateFile: image.locateFile, imports, stdout() {}});
    const accepted = async (label, imports) => {
      const instance = make(imports);
      try {
        const result = await instance.run();
        context.assert(result.kind === 'returned' && result.status === 0, `${label}: the image did not run`);
        runs++;
      } finally {
        await instance.dispose();
      }
    };
    const refusedAtCreate = (label, imports, message) => {
      let caught;
      try { make(imports); } catch (error) { caught = error; }
      context.assert(caught?.name === 'TypeError' && caught.message === message,
        `${label}: create did not refuse the map: ${caught?.message}`);
    };
    const refusedAtInitialize = async (label, imports, message) => {
      const instance = make(imports);
      try {
        await rejection(context, instance.initialize(), {code: 'TITAN_BROWSER_PROTOCOL', message});
      } finally {
        await instance.dispose();
      }
    };

    await accepted('custom namespace', {custom: {unused() {}}, env: {fixture_unused() {}}});
    await accepted('suspending member', {env: {fixture_wait: new WebAssembly.Suspending(async () => {})}});
    await accepted('prototype-less maps',
      Object.assign(Object.create(null), {custom: Object.assign(Object.create(null), {unused() {}})}));
    let seen;
    await accepted('function form', instance => {
      seen = instance;
      return {custom: {unused() {}}};
    });
    context.assert(typeof seen?.readCString === 'function',
      'the imports function did not receive the instance context');
    await accepted('foreign-realm maps', foreign.record({custom: foreign.record({unused() {}})}));
    await accepted('foreign-realm function form', () => foreign.record({custom: foreign.record({})}));

    for (const [label, map] of [['array', []], ['Map', new Map()], ['class instance', new (class Imports {})()],
        ['promise', Promise.resolve({})], ['foreign array', foreign.array()], ['foreign Map', foreign.map()]]) {
      refusedAtCreate(label, map, plain);
    }
    for (const [label, entries] of [['array', []], ['Map', new Map()], ['foreign Map', foreign.map()]]) {
      refusedAtCreate(`${label} module`, {env: entries}, 'browser imports.env must be a plain object of imports');
    }
    // The WASI module and Titan's env prefixes belong to the runtime, also
    // names the image does not import today.
    for (const [module, name] of [['wasi_snapshot_preview1', 'fd_write'], ['wasi_snapshot_preview1', 'sock_accept'],
        ['env', 'titan_browser_relinquish'], ['env', 'titan_browser_unused'], ['env', 'titan_mco_transfer']]) {
      refusedAtCreate(`${module}.${name}`, {[module]: {[name]() {}}}, reserved(`${module}.${name}`));
      await refusedAtInitialize(`function ${module}.${name}`, () => ({[module]: {[name]() {}}}),
        reserved(`${module}.${name}`));
    }
    await refusedAtInitialize('async function', async () => ({}), plain);
    await refusedAtInitialize('function returning a foreign Map', () => foreign.map(), plain);
    context.stdout(encode(`loader imports: ${path}: accepted and refused import maps passed\n`));
  }
  return runs;
}

// Plain objects, arrays and Maps of another realm: a same-origin frame's in
// a page, a vm context's under Node.
async function foreignRealm() {
  const global = typeof document !== 'undefined' ? frameGlobal() :
    (await import('node:vm')).runInNewContext('globalThis');
  return {
    record: entries => Object.assign(new global.Object(), entries),
    array: () => new global.Array(),
    map: () => new global.Map(),
  };
}

function frameGlobal() {
  const frame = document.createElement('iframe');
  (document.body ?? document.documentElement).append(frame);
  return frame.contentWindow;
}
