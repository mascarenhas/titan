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
    hooks: {}, pinned: {}};
  // A sink may run only after the operation or from a parked drive gate.
  const sinkCalled = () => {
    const snapshot = host.controls?.snapshot();
    if (snapshot?.driving && !snapshot.parked) host.unparkedSinks++;
  };
  host.held = [];
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
    noted(value) {
      host.notes.push(value);
      host.hooks.noted?.(value);
    },
    cleanup_note(text) { host.cleanup.push(text); },
    shutdown_ran() { host.shutdowns++; },
    // A detachable request that settles only when the harness calls settleHeld().
    held() { return {kind: 'detachable', promise: new Promise(resolve => { host.held.push(resolve); })}; },
    never() { return {kind: 'detachable', promise: new Promise(() => {})}; },
    slow(ms) { return {kind: 'detachable', promise: new Promise(resolve => { setTimeout(resolve, ms); })}; },
    pinned(name, state, slot, generation) {
      host.pinned[name] = [Number(state), Number(slot), Number(generation)];
    },
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
  host.settleHeld = () => { for (const resolve of host.held.splice(0)) resolve(); };
  host.task = (name, args = [], options = {}) => observe(host.instance.callTask(host.fn(name), args, options));
  host.snapshot = () => host.controls.snapshot();
  // A synchronous C callback of a pinned target; returns its result status.
  host.fire = name => host.controls.fire(...host.pinned[name]);
  host.poke = action => { host.controls.hooks.poke = action; };
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

// Shared timer spy. Timeouts of at least 10^8 ms (about 28 hours) never reach
// the host: the timer cases fire them explicitly.
export function watchTimers() {
  const saved = {setTimeout, clearTimeout, setInterval, clearInterval};
  const spy = {timeouts: new Map(), delays: [], held: new Map(), intervals: new Map(), periods: []};
  globalThis.setTimeout = function (callback, delay, ...rest) {
    spy.delays.push(delay);
    if (delay >= 1e8) {
      const id = Symbol('held timeout');
      spy.held.set(id, {callback, delay, rest});
      return id;
    }
    const id = saved.setTimeout.call(globalThis, (...values) => {
      spy.timeouts.delete(id);
      callback(...values);
    }, delay, ...rest);
    spy.timeouts.set(id, delay);
    return id;
  };
  globalThis.clearTimeout = function (id) {
    if (spy.held.delete(id)) return;
    spy.timeouts.delete(id);
    saved.clearTimeout.call(globalThis, id);
  };
  globalThis.setInterval = function (callback, period, ...rest) {
    const id = saved.setInterval.call(globalThis, callback, period, ...rest);
    spy.intervals.set(id, period);
    spy.periods.push(period);
    return id;
  };
  globalThis.clearInterval = function (id) {
    spy.intervals.delete(id);
    saved.clearInterval.call(globalThis, id);
  };
  spy.count = delay => [...spy.timeouts.values(), ...spy.intervals.values(), ...spy.held.values()].filter(
    timer => (typeof timer === 'object' ? timer.delay : timer) === delay).length;
  spy.fire = delay => {
    const entry = [...spy.held].find(([, timer]) => timer.delay === delay);
    if (!entry) return false;
    const [id, timer] = entry;
    spy.held.delete(id);
    timer.callback(...timer.rest);
    return true;
  };
  spy.restore = () => { Object.assign(globalThis, saved); };
  return spy;
}
