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
    const values = await host.instance.call(host.callbacks.get('handle_echo'), value);
    context.assert(values.length === 1 && values[0] === value, 'reverse result adopted its opaque rejected Promise');
    // Deliberately no handler on values[0]. A carrier is not a rejection observer.
  } finally {
    await host.instance.dispose();
    host.releaseObservations();
  }
}
