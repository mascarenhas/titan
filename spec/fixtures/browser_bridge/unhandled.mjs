import {makeHost} from './bindings.mjs';

// Returning this Promise through call_handle must not attach a bridge-owned
// rejection observer: it remains ordinary host data with ordinary host policy.
function unhandledPromise() { return Promise.reject(new Error('bridge unhandled opaque promise')); }

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the native browser.tests image');
  const image = await context.image(context.args[0]);
  const host = makeHost(context);
  host.bindings.promise_value = unhandledPromise;
  host.instance = image.create({...host.options, locateFile: image.locateFile});
  try {
    await host.instance.initialize();
    await host.instance.run([]);
  } finally {
    await host.instance.dispose();
    host.releaseObservations();
  }
}
