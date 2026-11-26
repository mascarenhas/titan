import {encode, expectedBytes, join, reentry, rejection} from './checks.mjs';

// Exercise an optimized measurement JSPI image: wasm-opt keeps the entry's
// export names, and correctness must not depend on the program profile.
export async function run(context) {
  context.assert(context.args.length > 0, 'pass an optimized fidelity.mjs image');
  for (const path of context.args) {
    const wasm = await WebAssembly.compile(await context.bytes(path.replace(/\.mjs$/, '.wasm')));
    context.assert(WebAssembly.Module.exports(wasm).some(item => item.name === 'titan_browser_entry'),
      'JSPI export names did not survive the optimized link');
    const image = await context.image(path);
    const stdout = [], stderr = [];
    let controls, loaderControls;
    const instance = image.create({locateFile: image.locateFile, imports: context.imports,
      bindings: {__titanTest(value) { controls = value; }, __loaderTest(value) { loaderControls = value; }},
      stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
    try {
      await instance.initialize();
      const running = instance.run(['fidelity']);
      await context.tick();
      const snapshot = controls.snapshot();
      context.assert(snapshot.owner && !snapshot.safe, 'optimized real C outer wait lost its logical owner');
      await rejection(context, loaderControls.rawEntry(), reentry);
      const pointer = controls.allocate(16);
      context.assert(pointer !== 0, 'non-suspending C-only allocator was unavailable');
      controls.free(pointer);
      await rejection(context, instance.run(), reentry);
      const result = await running;
      context.assert(result.kind === 'returned' && result.status === 23,
        'optimization lost initial admission or original completion after JSPI transfers');
      await instance.dispose();
      context.equalBytes(join(stdout), expectedBytes('stdout'));
      context.equalBytes(join(stderr), expectedBytes('stderr'));
      context.stdout(encode(`loader optimized guard: ${path}: minified=false pending=rejected status=23\n`));
    } finally { await instance.dispose(); controls = loaderControls = undefined; }
  }
}
