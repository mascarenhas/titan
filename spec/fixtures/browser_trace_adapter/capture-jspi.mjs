// Run through titan-browser-run --js-test after spec/browser/build-trace.lua.
// The one selected native case captures before/after yield and after an outer
// wait. Preserve the real Error objects/stack strings at construction time;
// never reconstruct a throw's trace in a later promise-rejection callback.
export async function run(context) {
  context.assert(context.args.length === 1, 'pass a trace runtime image');
  const image = await context.image(context.args[0]);
  const instance = image.create({locateFile: image.locateFile});
  const NativeError = globalThis.Error;
  const captures = [];
  try {
    await instance.initialize();
    globalThis.Error = new Proxy(NativeError, {
      construct(target, args) {
        const error = Reflect.construct(target, args);
        const stack = error.stack;
        if (typeof stack === 'string' && stack.includes('wasm-function[')) captures.push(stack);
        return error;
      },
    });
    const result = await instance.run(['--filter=^trace_cases%.test_locations_before_after_yield$']);
    context.assert(result.kind === 'returned' && result.status === 0, 'real post-resume native trace case failed');
  } finally {
    globalThis.Error = NativeError;
    await instance.dispose();
  }
  context.assert(captures.length >= 6, 'post-resume case did not record its native captures');
  context.stdout(new TextEncoder().encode('JSPI-STACKS ' + JSON.stringify({engine: context.engine, captures}) + '\n'));
}
