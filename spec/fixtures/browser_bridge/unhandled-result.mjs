import {makeHost} from './bindings.mjs';

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the native browser.tests image');
  const image = await context.image(context.args[0]);
  const host = makeHost(context);
  host.instance = image.create({...host.options, locateFile: image.locateFile});
  try {
    await host.instance.initialize();
    const result = await host.instance.run([]);
    context.assert(result.kind === 'returned' && result.status === 0, 'native owner failed before rejection proof');
    await host.instance.call(host.callbacks.get('close_detached'));
    const value = Promise.reject(new Error('bridge unhandled reverse result'));
    host.instance.call(host.callbacks.get('handle_echo'), value);
    while (host.controls.snapshot().owner || !host.controls.snapshot().safe || host.controls.snapshot().active) await context.tick();
    // Deliberately no handler on the adopted call() result.
  } finally {
    await host.instance.dispose();
    host.releaseObservations();
  }
}
