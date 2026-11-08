// Shared host for the mini-driver fixture (mini_driver.titan): explicit
// bindings, sinks and observations; no instance internals beyond the
// fixture's published controls.
export const encode = text => new TextEncoder().encode(text);
export const decode = bytes => new TextDecoder().decode(bytes);

// Marks a promise handled at creation; a later await still sees its outcome.
export function observe(promise) {
  promise.catch(() => {});
  return promise;
}

export function makeHost(context, image, extra = {}) {
  const host = {callables: new Map(), probes: [], notes: [], cleanup: [], stdout: [], stderr: [],
    notificationErrors: [], shutdowns: 0, flag: false, sinkChunks: 0, unparkedSinks: 0, controls: undefined,
    hooks: {}};
  // A sink may run only after the operation or from a parked drive gate.
  const sinkCalled = () => {
    const snapshot = host.controls?.snapshot();
    if (snapshot?.driving && !snapshot.parked) host.unparkedSinks++;
  };
  host.bindings = {
    __miniDriver(controls) { host.controls = controls; },
    publish(name, callable) { host.callables.set(name, callable); },
    probe(turn, status) {
      const event = {turn: Number(turn), status: Number(status)};
      host.probes.push(event);
      host.hooks.probe?.(event);
    },
    flag() { return host.flag; },
    sink_count() { return BigInt(host.sinkChunks); },
    kick() { host.hooks.kick?.(); },
    reenter() { host.hooks.reenter?.(); },
    noted(value) { host.notes.push(value); },
    cleanup_note(text) { host.cleanup.push(text); },
    shutdown_ran() { host.shutdowns++; },
    never() { return {kind: 'detachable', promise: new Promise(() => {})}; },
    slow(ms) { return {kind: 'detachable', promise: new Promise(resolve => { setTimeout(resolve, ms); })}; },
  };
  host.instance = image.create({locateFile: image.locateFile, bindings: host.bindings,
    stdout(bytes) {
      sinkCalled();
      host.stdout.push(bytes.slice());
      host.sinkChunks++;
      return host.hooks.stdout?.(bytes);
    },
    stderr(bytes) {
      sinkCalled();
      host.stderr.push(bytes.slice());
      return host.hooks.stderr?.(bytes);
    },
    onNotificationError(event) { host.notificationErrors.push(event); },
    ...extra});
  host.fn = name => {
    const callable = host.callables.get(name);
    context.assert(callable, `mini driver did not publish ${name}`);
    return callable;
  };
  host.call = (name, ...args) => observe(host.instance.call(host.fn(name), ...args));
  host.task = (name, args = [], options = {}) => observe(host.instance.callTask(host.fn(name), args, options));
  host.snapshot = () => host.controls.snapshot();
  return host;
}

export async function until(context, predicate, message) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await context.tick();
  }
  context.assert(false, message);
}

export async function rejection(context, promise, code) {
  context.assert(promise instanceof Promise, `expected a ${code} promise, not a synchronous result`);
  let caught;
  try { await promise; } catch (error) { caught = error; }
  context.assert(caught?.code === `TITAN_BROWSER_${code}`,
    `expected ${code}, got ${caught?.code}: ${caught?.message}`);
  return caught;
}

export function thrown(context, action, code) {
  let caught;
  try { action(); } catch (error) { caught = error; }
  context.assert(caught?.code === `TITAN_BROWSER_${code}` || code === 'TypeError' && caught instanceof TypeError,
    `expected a thrown ${code}, got ${caught?.code ?? caught?.name}: ${caught?.message}`);
  return caught;
}

export function settledMarker(promise) {
  const marker = {settled: false};
  const settle = () => { marker.settled = true; };
  promise.then(settle, settle);
  return marker;
}
