import {binary, encode, formBinding, gate, makeHost} from './bindings.mjs';

// Expected abort70 plus marker: fatal reference disposal must not run native
// finalizers, admit late callbacks, or translate settlement into observer errors.
export async function run(context) {
  context.assert(context.args.length === 1, 'pass the native browser.tests image');
  const image = await context.image(context.args[0]);
  const host = makeHost(context);
  let observed;
  host.instance = image.create({...host.options, locateFile: image.locateFile,
    onEngineFailure(info) { observed = info; }});
  let saved;
  try {
    await host.instance.initialize();
    const native = await host.instance.run([]);
    context.assert(native.kind === 'returned' && native.status === 0, 'native owner failed before poison proof');
    await host.instance.call(host.callbacks.get('close_detached'));
    const fulfilled = gate(), rejected = gate();
    host.bindings.fulfilled_request = formBinding({kind: 'detachable', promise: fulfilled.promise});
    host.bindings.rejected_request = formBinding({kind: 'detachable', promise: rejected.promise});
    await host.instance.call(host.callbacks.get('start_request'), 'fulfilled_request');
    await host.instance.call(host.callbacks.get('start_request'), 'rejected_request');
    await host.instance.call(host.callbacks.get('start_listener'));
    host.bindings.abort_request = () => host.controls.abort();
    try { await host.instance.call(host.callbacks.get('start_request'), 'abort_request'); }
    catch (error) { saved = error; }
    context.assert(saved?.code === 'TITAN_BROWSER_ABORT' && observed?.kind === 'abort' && observed.cause === saved,
      'real owned abort did not preserve its engine latch');
    const trace = host.instance.trace;
    const operationId = host.controls.snapshot().operationId;
    for (const emit of host.retainedListeners) emit(99n, binary());
    fulfilled.resolve(binary()); rejected.reject(Object.freeze({late: 'after poison'}));
    await context.tick();
    context.assert(host.successes.length === 0 && host.failures.length === 0 &&
      host.notificationErrors.length === 0,
      'poisoned request/listener settlement reached application delivery or notification observer');
    for (const promise of [host.instance.initialize(), host.instance.run(), host.instance.call(undefined), host.instance.drain()]) {
      let error;
      try { await promise; } catch (caught) { error = caught; }
      context.assert(error === saved, 'terminal method did not reject its saved owned abort');
    }
    await host.instance.dispose();
    context.assert(Object.isFrozen(host.instance.trace) && host.instance.trace.state === trace.state &&
      host.instance.trace.reason === trace.reason, 'poisoned disposal discarded its final trace snapshot');
    const snapshot = host.controls.snapshot();
    context.assert(host.closes.length === 0 && host.unregisters === 1 && snapshot.operationId === operationId &&
      snapshot.units === 0 && snapshot.requests === 0, 'fatal disposal ran C cleanup or leaked host retirement');
  } finally {
    await host.instance.dispose();
    host.releaseObservations();
  }
  context.stdout(encode('poison-retirement-complete\n'));
  throw saved;
}
