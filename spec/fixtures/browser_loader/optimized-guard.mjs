import {encode, expectedBytes, join, reentry, rejection} from './checks.mjs';

// Link fidelity with the unchanged baseline profile: optimization=O2,
// assertions=0, Asyncify enabled, exact production C/runtime exports.
// Harness-only --cflag=-g2 --ldflag=-g2 --ldflag=-Os reduces full validation
// DWARF and enables SHRINK_LEVEL=1: pinned will_metadce needs shrink >=1 or
// optimization >=3, so -O2 alone does not minify even with -g0. Compile/profile
// optimization stays O2; no production profile is changed.
export async function run(context) {
  context.assert(context.args.length > 0, 'pass an optimized fidelity.mjs image');
  for (const path of context.args) {
    const wasm = await WebAssembly.compile(await context.bytes(path.replace(/\.mjs$/, '.wasm')));
    context.assert(!WebAssembly.Module.exports(wasm).some(item => item.name === 'titan_browser_entry'),
      'optimized fixture did not actually minify Wasm export names');
    const image = await context.image(path);
    const stdout = [], stderr = [];
    let module, bridge;
    const instance = context.create(async options => {
      const attach = options.titanBrowserAttach;
      options.titanBrowserAttach = state => { bridge = state; attach(state); };
      module = await image.factory(options);
      return module;
    }, {locateFile: image.locateFile,
      stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
    try {
      await instance.initialize();
      const running = instance.run(['fidelity']);
      await context.tick();
      context.assert(bridge.suspensionPending, 'optimized real C outer wait was not pending');
      context.assert(module._titan_browser_entry(0, 0, 0) === -1,
        'minified raw C entry admitted a pending reentry');
      const pointer = module._malloc(16);
      context.assert(pointer !== 0, 'non-suspending malloc was unavailable');
      module._free(pointer);
      await rejection(context, instance.run(), reentry);
      const result = await running;
      context.assert(result.kind === 'returned' && result.status === 23,
        'minification lost initial admission or original completion after fibers');
      context.equalBytes(join(stdout), expectedBytes('stdout'));
      context.equalBytes(join(stderr), expectedBytes('stderr'));
      context.stdout(encode(`loader optimized guard: ${path}: minified=true pending=-1 status=23\n`));
    } finally { await instance.dispose(); module = bridge = undefined; }
  }
}
