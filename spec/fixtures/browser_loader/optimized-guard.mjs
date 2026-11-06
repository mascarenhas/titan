import {encode, expectedBytes, join, reentry, rejection} from './checks.mjs';

// Exercise an optimized/assertions-off JSPI image. Emscripten 6.0.13 disables
// Wasm import/export minification for JSPI, even with a shrink-level override;
// the fixture asserts that pinned behavior rather than claiming minification.
export async function run(context) {
  context.assert(context.args.length > 0, 'pass an optimized fidelity.mjs image');
  for (const path of context.args) {
    const wasm = await WebAssembly.compile(await context.bytes(path.replace(/\.mjs$/, '.wasm')));
    context.assert(WebAssembly.Module.exports(wasm).some(item => item.name === 'titan_browser_entry'),
      'JSPI export names did not follow the pinned toolchain contract');
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
      context.assert(bridge.owner && !bridge.safe(), 'optimized real C outer wait lost its logical owner');
      await rejection(context, module._titan_browser_entry(0, 0, 0), reentry);
      const pointer = module._malloc(16);
      context.assert(pointer !== 0, 'non-suspending malloc was unavailable');
      module._free(pointer);
      await rejection(context, instance.run(), reentry);
      const result = await running;
      context.assert(result.kind === 'returned' && result.status === 23,
        'optimization lost initial admission or original completion after JSPI transfers');
      context.equalBytes(join(stdout), expectedBytes('stdout'));
      context.equalBytes(join(stderr), expectedBytes('stderr'));
      context.stdout(encode(`loader optimized guard: ${path}: minified=false pending=rejected status=23\n`));
    } finally { await instance.dispose(); module = bridge = undefined; }
  }
}
