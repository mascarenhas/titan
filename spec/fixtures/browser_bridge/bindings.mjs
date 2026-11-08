export const encode = text => new TextEncoder().encode(text);
export const decode = bytes => new TextDecoder().decode(bytes);
export const binary = () => new Uint8Array([0, 255, 195, 40]);

// Node Buffer has this slice-as-view behavior. Exercise it in every engine.
export class AliasingBytes extends Uint8Array {
  slice(start, end) { return this.subarray(start, end); }
}

export function gate() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

// The test-owned host callback itself has no instance/Module capture.
export function formBinding(form) {
  return () => form;
}

export function join(chunks) {
  const bytes = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

function asText(name) {
  return typeof name === 'string' ? name : decode(name);
}

function asBytes(value) {
  return typeof value === 'string' ? encode(value) : value.slice();
}

export function makeHost(context) {
  const thrown = {throw_error: new Error('bridge failure'), throw_string: 'bridge failure string',
    throw_value: Object.freeze({message: 'bridge failure value', marker: 332})};
  const values = {false_value: false, zero_value: 0, null_value: null, undefined_value: undefined};
  const host = {
    callbacks: new Map(), controls: undefined, instance: undefined,
    stdout: [], stderr: [], notificationErrors: [], notifications: [], checks: [],
    successes: [], failures: [], closes: [], independentCloses: [], cleanup: 0,
    stateCloseObservations: [], stateInvalidations: [], earlierCloses: [],
    r1Responses: [], r1Thrown: undefined,
    r1CloseCount: 0n,
    listeners: new Set(), retainedListeners: [], unregisters: 0, forbiddenRequests: 0,
    sinks: {}, hooks: {}, thrown, values,
  };
  const bindings = host.bindings = {
    __titanTest(controls) { host.controls = controls; },
    __titanStateClosed(token) {
      context.assert(!host.stateInvalidations.includes(token), 'browser record invalidated its state twice');
      host.stateInvalidations.push(token);
      const observed = host.stateCloseObservations.find(entry => entry.token === token);
      if (observed) {
        const unwound = observed.index === 0n ? host.closes :
          host.independentCloses.filter(entry => entry.index === observed.index);
        context.assert(unwound.length === 2, 'record invalidation preceded coroutine unwinding');
      }
    },
    __titanEarlierCleanup(index) {
      const tag = BigInt(index);
      const observed = host.stateCloseObservations.find(entry => entry.index === tag);
      context.assert(observed && host.stateInvalidations.includes(observed.token) &&
        host.controls.snapshot().states.some(state => state.token === observed.token && state.closed),
        'earlier-object cleanup did not follow record invalidation');
      const before = host.controls.snapshot();
      const wrapper = host.callbacks.get(tag === 0n ? 'increment' : `independent_${tag}`);
      context.assert(wrapper, 'earlier-object test lost its released callable wrapper');
      wrapper.release();
      wrapper.release();
      const after = host.controls.snapshot();
      context.assert(after.operationId === before.operationId && after.units === before.units,
        'release on an invalidated state entered native code or changed slots');
      host.earlierCloses.push(tag);
    },
    echo_boolean(value) { context.assert(typeof value === 'boolean'); return value; },
    echo_integer(value) { context.assert(typeof value === 'bigint'); return value; },
    overflow_bigint() { return 1n << 63n; },
    echo_float(value) { context.assert(typeof value === 'number'); return value; },
    echo_string(value) { context.assert(typeof value === 'string'); return value; },
    ill_formed_string() { return '\ud800'; },
    echo_bytes(value) { context.assert(value instanceof Uint8Array); return value.slice(); },
    return_null(value) { context.assert(value === null); return null; },
    return_undefined() { return undefined; },
    make_js_adder(base) {
      context.assert(typeof base === 'bigint');
      return delta => base + delta;
    },
    check_same_wrapper(left, right) { return left === right; },
    echo_callable(callable) { return callable; },
    large_bytes() {
      const length = 20 * 1024 * 1024;
      const pointer = host.controls.allocate(length);
      context.assert(pointer !== 0, 'C-only source allocation failed');
      const bytes = new Uint8Array(host.controls.weakTargets()[1].deref(), pointer, length);
      bytes.fill(0);
      bytes.set(binary()); bytes.set(binary(), length - 4);
      // The response import copies synchronously; its own allocation must not
      // detach this borrowed source before that copy. No borrowed data escapes.
      queueMicrotask(() => host.controls.free(pointer));
      return bytes;
    },
    throw_error() { throw thrown.throw_error; },
    throw_string() { throw thrown.throw_string; },
    throw_value() { throw thrown.throw_value; },
    check_thrown(name, value) { return value === thrown[asText(name)]; },
    ...values,
    check_value(name, value) { return Object.is(value, values[asText(name)]); },
    promise_value() { return Promise.resolve('opaque promise'); },
    is_promise(value) { return value instanceof Promise; },
    handle_count() {
      context.assert(host.controls, 'native browser.tests did not publish test-owned observations');
      return BigInt(host.controls.snapshot().units);
    },
    publish(name, callable) {
      context.assert(callable && typeof callable.call === 'function' && typeof callable.release === 'function',
        'publish did not receive a production branded callable wrapper');
      context.assert(!Object.hasOwn(callable, 'slot') && !Object.hasOwn(callable, 'state') &&
        !Object.hasOwn(callable, 'generation'), 'callable exposed private identity');
      host.callbacks.set(asText(name), callable);
    },
    notification(value) { host.notifications.push(value); host.hooks.notification?.(value); },
    allocation_cleanup() {
      host.cleanup++;
      const snapshot = host.controls.snapshot();
      context.assert(snapshot.owner && !snapshot.safe, 'hidden allocation cleanup released its execution owner');
      host.hooks.cleanup?.();
    },
    close_value: Object.freeze({close: 'owner'}),
    close_observe(value) { host.closes.push(value); host.hooks.close?.(value); },
    state_close_handle: Object.freeze({close: 'user-finalizer'}),
    state_close_request() { return {kind: 'detachable', promise: Promise.resolve(0n)}; },
    state_close_observe(index) {
      const closing = host.controls.snapshot().states.filter(state => state.closing && !state.closed);
      context.assert(closing.length === 1, 'user finalizer did not see exactly one live closing state');
      host.stateCloseObservations.push({index, token: closing[0].token});
    },
    independent_close(index, asyncRejected, value) {
      context.assert(asyncRejected === true, 'independent close admitted new async work');
      const closing = host.controls.snapshot().states.filter(state => state.closing && !state.closed);
      context.assert(closing.length > 0, 'independent finalizer did not observe its state closing');
      host.independentCloses.push({index, value, closingTokens: closing.map(state => state.token)});
    },
    detachable_request() {
      host.forbiddenRequests++;
      throw new Error('a closing state invoked its forbidden host request');
    },
    request_success(...items) {
      host.successes.push(items.map(item => item instanceof Uint8Array ? item.slice() : item));
    },
    request_failure(message, value) { host.failures.push([asBytes(message), value]); },
    listener() {
      return {kind: 'listener', subscribe(emit) {
        host.listeners.add(emit);
        host.retainedListeners.push(emit);
        emit(31n, binary());
        let removed = false;
        return () => {
          if (removed) return;
          removed = true;
          host.unregisters++;
          host.listeners.delete(emit);
        };
      }};
    },
    pin_hold_request() { return host.hooks.pinHoldRequest(); },
    pin_hold_listener() { return host.hooks.pinHoldListener(); },
    save_and_throw(cb) { host.savedCallable = cb; throw new Error('saved then threw'); },
    save_and_bad_return(cb) { host.savedCallable = cb; return 1n << 80n; },
    save_and_refuse_start(cb) { host.savedCallable = cb; return {}; },
    r1_handle_first: Object.freeze({r1: 'first'}),
    r1_handle_last: Object.freeze({r1: 'last'}),
    r1_start_source() { return host.hooks.r1Start(); },
    r1_listener_source() { return host.hooks.r1Listen(); },
    r1_close_source() {
      const pending = gate();
      return {kind: 'detachable', promise: pending.promise, cancel() { host.r1CloseCount++; }};
    },
    r1_close_count() { return host.r1CloseCount; },
    r1_release_result(position) { host.hooks.r1Release(position); },
    r1_response_throw() { host.hooks.r1Throw?.(); throw host.r1Thrown; },
    r1_response_observe(message, value, hasThrown) {
      host.r1Responses.push({message: asBytes(message), value, hasThrown,
        units: host.controls.snapshot().units});
    },
  };
  host.options = {
    bindings,
    stdout(bytes) { host.stdout.push(bytes.slice()); return host.sinks.stdout?.(bytes); },
    stderr(bytes) { host.stderr.push(bytes.slice()); return host.sinks.stderr?.(bytes); },
    onNotificationError(event) { host.notificationErrors.push(event); host.hooks.notificationError?.(event); },
    requestDrain() { host.hooks.requestDrain?.(); },
  };
  host.call = (name, ...args) => {
    const callable = host.callbacks.get(name);
    context.assert(callable, `native tests did not publish ${name}`);
    return host.instance.call(callable, ...args);
  };
  host.releaseObservations = () => {
    host.controls = host.instance = host.r1Thrown = host.savedCallable = undefined;
    host.hooks.r1Release = host.hooks.r1Throw = undefined;
    host.hooks.r1Start = host.hooks.r1Listen = undefined;
    host.hooks.pinHoldRequest = host.hooks.pinHoldListener = undefined;
    host.r1Responses.length = 0;
    // Awaited assertion promises hold returned Errors and their native stack closures.
    host.checks.length = 0;
    host.callbacks.clear();
  };
  return host;
}
