// Expected-failure supervisor probe over the real fidelity image. Every case
// invokes its own Emscripten abort from inside a production bridge import.
export async function run(context) {
  const [path, mode = 'throw'] = context.args;
  context.assert(path && ['throw', 'return', 'bytes', 'format', 'allocation'].includes(mode), 'pass a fidelity image and abort branch');
  const image = await context.image(path);
  let controls, probe, atAbort, original, allocationAbort = false, observerCalls = 0;
  const afterPoison = [];
  function abortAndReturn() { try { controls.abort(); } catch {} }
  const instance = image.create({locateFile: image.locateFile, stdout: context.stdout, stderr: context.stderr,
    bindings: {
      __loaderTest(value) { controls = value; },
      abort_binding() {
        if (mode === 'throw') controls.abort();
        if (mode === 'return') { abortAndReturn(); return; }
        if (mode === 'bytes') return {get bytes() { abortAndReturn(); return new Uint8Array([65]); }, length: 1};
        if (mode === 'format') throw {get message() { abortAndReturn(); return 'owned abort during error formatting'; }};
        throw new Error('owned abort during error allocation');
      },
    },
    onEngineFailure(info) {
      observerCalls++;
      original = info.cause;
      atAbort = probe?.copy();
    },
  });
  let unwatchMemory, unwatchResponses;
  try {
    await instance.initialize();
    unwatchResponses = controls.watchResponses(value => { probe = value; });
    unwatchMemory = controls.watchMemoryCalls(event => {
      if (event.poisoned) afterPoison.push(event.kind);
      if (mode === 'allocation' && probe && event.kind === 'allocate' && !allocationAbort) {
        allocationAbort = true;
        controls.abort();
      }
    });
    let caught;
    try { await instance.run(['abort_binding', mode]); } catch (error) { caught = error; }
    context.assert(caught?.code === 'TITAN_BROWSER_ABORT' && caught === original && observerCalls === 1,
      'owned import abort lost its first saved engine failure');
    context.assert(atAbort instanceof Uint8Array, 'owned abort did not occur inside the real response import');
    context.equalBytes(probe.copy(), atAbort, 'response memory was written after owned fatal poison');
    context.assert(afterPoison.length === 0, 'C allocation/free ran after owned fatal poison: ' + afterPoison);
    context.assert(mode !== 'allocation' || allocationAbort, 'nested error-allocation branch was not reached');
    for (const promise of [instance.initialize(), instance.run(), instance.call(undefined), instance.drain()]) {
      let failure;
      try { await promise; } catch (error) { failure = error; }
      context.assert(failure === original, 'application method replaced the import engine poison');
    }
    await instance.dispose();
    context.assert(afterPoison.length === 0, 'fatal disposal attempted C cleanup');
  } finally {
    unwatchMemory?.(); unwatchResponses?.();
    await instance.dispose();
    controls = probe = undefined;
  }
  context.stdout(new TextEncoder().encode('dispose-complete\n'));
  throw original;
}
