const reentryMessage = 'browser instance is active; reentry is not allowed';
const stateMessage = 'browser instance is not initialized';
const maximumOperationId = (1n << 64n) - 1n;
const maximumApplicationOperationId = maximumOperationId - 1n; // Reserve the final id for intact-state close.
const wrapperRecords = new WeakMap();
const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const typedArrayTag = Object.getOwnPropertyDescriptor(typedArrayPrototype, Symbol.toStringTag).get;
const typedArrayLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'length').get;
const typedArraySet = typedArrayPrototype.set;
// titan/browser.h's asserted wasm32 layout and discriminants.
const valueSize = 32;
const kind = Object.freeze({nil: 0, boolean: 1, integer: 2, float: 3,
  bytes: 4, handle: 5, callable: 6, void: 7, request: 8});
const operationKinds = Object.freeze({initialize: 1, entry: 2, invoke: 3,
  release_callable: 4, close: 5, gate_guarded: 3});

function failure(code, message, cause, stream) {
  const error = new Error(message, cause === undefined ? undefined : {cause});
  error.name = 'TitanBrowserError';
  error.code = `TITAN_BROWSER_${code}`;
  if (stream !== undefined) error.stream = stream;
  return error;
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

function copiedBytes(value) {
  // Call/notify snapshot before publication: native slots cannot reenter through
  // a Proxy, iterator, accessor, constructor or species hook.
  if (typedArrayTag.call(value) !== 'Uint8Array') throw new TypeError('browser bytes must be a Uint8Array');
  const copy = new Uint8Array(typedArrayLength.call(value));
  typedArraySet.call(copy, value);
  return copy;
}

function messageBytes(cause) {
  let message;
  try { message = cause?.message === undefined ? String(cause) : String(cause.message); }
  catch { message = 'JavaScript binding failed'; }
  return new TextEncoder().encode(message);
}

function sinkResult(result, stream) {
  if (result === undefined) return result;
  const then = result !== null && (typeof result === 'object' || typeof result === 'function') && result.then;
  if (typeof then !== 'function') {
    throw failure('SINK', `browser ${stream} sink must return undefined or a promise`, undefined, stream);
  }
  return new Promise((resolve, reject) => { then.call(result, resolve, reject); });
}

// These continuations deliberately live outside the image/instance factory.
// An externally retained host promise or listener keeps only its detachable
// cell, never an otherwise retired Module or an instance lexical environment.
function mailboxFulfilled(cell, value) {
  const target = cell.target;
  if (target) target.resolve(value);
}

function mailboxRejected(cell, cause) {
  const target = cell.target;
  if (target) target.reject(cause);
}

function relayPromise(promise, cell) {
  Promise.resolve(promise).then(
    mailboxFulfilled.bind(undefined, cell),
    mailboxRejected.bind(undefined, cell));
}

function listenerEvent(cell, ...args) {
  const target = cell.target;
  if (target) target.owner.emitRequest(target.request, args);
}

function requestFulfilled(cell, value) {
  const target = cell.target;
  if (target) target.owner.settleRequest(target.request, true, value);
}

function requestRejected(cell, cause) {
  const target = cell.target;
  if (target) target.owner.settleRequest(target.request, false, cause);
}

function checkedReadSpan(value, capacity) {
  const counted = value instanceof Uint8Array ? {bytes: value, length: value.length} : value;
  const bytes = counted?.bytes, length = counted?.length;
  if (!(bytes instanceof Uint8Array) || !Number.isSafeInteger(length) || length < 0 ||
      length > bytes.length || length > capacity) {
    throw new TypeError('browser input returned an invalid byte length or capacity');
  }
  // The notification queue copies this validated prefix before it escapes.
  return new Uint8Array(bytes.buffer, bytes.byteOffset, length);
}

function observe(promise) {
  // Only bridge-owned retirement promises are observed here. User promises
  // returned as opaque JSHandle values retain their host rejection semantics.
  promise.catch(() => {});
  return promise;
}

function notifyError(observer, kind, operation, error) {
  try {
    const event = {kind, operation, error};
    if (observer) observer(event);
    else console.error('Titan browser notification failed:', event);
  } catch (cause) {
    return failure('HOST', 'browser notification error observer failed', cause);
  }
}

// Disposal can cancel an uncaptured outcome, not a failure already being cleaned up.
function captureFailure(token, error, fault) {
  if (token.failed) return;
  token.failed = true;
  token.error = error;
  token.failureCaptured = !token.interrupted;
  token.primaryFault = fault;
}

class OutputChannel {
  constructor(sink, stream) {
    this.sink = sink;
    this.stream = stream;
    this.queue = [];
    this.tail = [];
    this.inflight = undefined;
    this.terminal = false;
    this.firstFailure = undefined;
  }

  byte(byte) {
    if (byte === null || byte === undefined) return;
    if (this.terminal) {
      this.firstFailure ||= {error: failure('DISPOSED', `browser ${this.stream} stream is disposed`)};
      return;
    }
    this.tail.push(byte & 255);
    if (this.tail.length === 1024) this.seal();
  }

  seal() {
    if (this.tail.length) {
      this.queue.push({bytes: Uint8Array.from(this.tail)});
      this.tail = [];
    }
  }

  append(bytes, completion) {
    this.seal();
    if (this.terminal) {
      const error = failure('DISPOSED', `browser ${this.stream} stream is disposed`);
      this.firstFailure ||= {error};
      completion?.reject(error);
      return;
    }
    this.queue.push({bytes: copiedBytes(bytes), completion});
  }

  async flush(token) {
    this.seal();
    let failures;
    while (this.queue.length && !this.terminal) {
      const entry = this.queue.shift();
      // A C-byte fault is consumed only by a completing write, not by an
      // unrelated flush. Its observed bit prevents reporting it twice.
      const pending = entry.completion ? this.firstFailure : undefined;
      if (entry.completion) this.firstFailure = undefined;
      if (pending) {
        (failures ||= []).push(pending);
        captureFailure(token, pending.error, pending);
      }
      let current;
      try {
        if (this.sink) {
          // A separate gate lets disposal detach a forever-pending host sink.
          // The stream then becomes terminal: it can never overlap that call.
          const gate = deferred();
          const cell = {target: gate};
          this.inflight = cell;
          try {
            relayPromise(sinkResult(this.sink(entry.bytes), this.stream), cell);
            await gate.promise;
          } finally {
            cell.target = undefined;
            this.inflight = undefined;
          }
        }
      } catch (cause) {
        const error = cause?.code === 'TITAN_BROWSER_DISPOSED' || cause?.code === 'TITAN_BROWSER_SINK' ? cause :
          failure('SINK', `browser ${this.stream} sink failed`, cause, this.stream);
        current = error === token.interrupted?.error ? token.interrupted : {error};
        (failures ||= []).push(current);
        captureFailure(token, error, current);
      }
      const error = pending?.error || current?.error;
      if (error) {
        if (entry.completion) entry.completion.reject(error);
        else this.firstFailure ||= current;
      } else entry.completion?.resolve();
    }
    return failures;
  }

  interrupt(error, fault) {
    if (this.inflight) {
      this.terminal = true;
      const target = this.inflight.target;
      this.inflight.target = undefined;
      target?.reject(error);
    }
    this.discard(error, fault);
  }

  discard(error, fault) {
    if (error.code === 'TITAN_BROWSER_DISPOSED' &&
        (this.tail.length || this.queue.some(entry => !entry.completion))) this.firstFailure ||= fault || {error};
    this.tail = [];
    for (const entry of this.queue) entry.completion?.reject(error);
    this.queue = [];
  }

  takeDrain() {
    this.seal();
    const drain = {
      sink: this.terminal ? undefined : this.sink,
      stream: this.stream,
      entries: this.queue,
      failure: this.firstFailure,
    };
    this.sink = undefined;
    this.queue = [];
    this.tail = [];
    this.firstFailure = undefined;
    return drain;
  }
}

// The argument contains copied bytes, a sink and status only. In particular,
// this function must never become an async instance method or close over one.
async function drainOutput(drain) {
  let first = drain.failure;
  let failures = first ? [first] : undefined;
  for (const entry of drain.entries) {
    try {
      if (drain.sink) await sinkResult(drain.sink(entry.bytes), drain.stream);
      if (first) entry.completion?.reject(first.error);
      else entry.completion?.resolve();
    } catch (cause) {
      const error = failure('SINK', `browser ${drain.stream} sink failed`, cause, drain.stream);
      const current = {error};
      first ||= current;
      (failures ||= []).push(current);
      entry.completion?.reject(error);
    }
  }
  drain.sink = undefined;
  drain.entries = [];
  return failures;
}

async function finishDisposal(disposal) {
  const failures = await Promise.all(disposal.drains.map(drainOutput));
  let first = disposal.failure;
  for (const stream of failures) {
    if (!stream) continue;
    for (const fault of stream) {
      if (!first) first = fault;
      else if (!fault.observed) notifyError(disposal.observer, 'cleanup', 'dispose', fault.error);
      fault.observed = true;
    }
  }
  disposal.drains = [];
  disposal.observer = undefined;
  if (first) throw first.error;
}

class CallableView {
  call(...args) {
    const record = wrapperRecords.get(this);
    return record?.owner ? record.owner.call(this, args) :
      Promise.reject(failure('DISPOSED', 'browser callable is disposed'));
  }

  release() {
    const record = wrapperRecords.get(this);
    record?.owner?.releaseCallable(record);
  }
}

function announceDrain(owner) {
  owner.drainAnnouncement = false;
  if (owner.active || owner.closing || owner.terminal || !owner.queue.length ||
      owner.drainAnnounced || !owner.options?.requestDrain) return;
  owner.drainAnnounced = true;
  try { owner.options.requestDrain(); }
  catch (cause) { owner.reportNotification('callback', 'requestDrain', cause); }
}

function releaseAtSafePoint(owner) {
  owner.releaseScheduled = false;
  if (owner.active || owner.closing || owner.terminal || !owner.releases.length ||
      owner.operationId >= maximumApplicationOperationId) return;
  observe(owner.operate('release_callable', () => owner.retireCallables()).catch(cause => {
    if (!owner.terminal) owner.reportNotification('cleanup', 'release_callable', cause);
  }));
}

class BrowserOwner {
  constructor(factory, options) {
    this.factory = factory;
    this.options = options;
    this.module = undefined;
    this.lastTrace = undefined;
    this.backend = undefined;
    this.state = 'created';
    this.active = undefined;
    this.initialized = undefined;
    this.initializationFailure = undefined;
    this.initializationSucceeded = false;
    this.disposed = undefined;
    this.closing = false;
    this.mainStarted = false;
    this.terminal = undefined;
    this.abortSeen = false;
    this.originalTrap = undefined;
    this.operationId = 0n;
    this.pending = undefined;
    this.queue = [];
    this.releases = [];
    this.releaseScheduled = false;
    this.callables = new Map();
    this.slots = new Map();
    this.freeSlots = [];
    this.nextSlot = 1;
    this.states = new Map();
    this.requests = new Set();
    this.drainAnnouncement = false;
    this.drainAnnounced = false;
    this.notificationFailure = undefined;
    this.out = new OutputChannel(options.stdout, 'stdout');
    this.err = new OutputChannel(options.stderr, 'stderr');
  }

  admission(requireReady = true) {
    if (this.terminal) return this.terminal;
    if (this.closing) return failure('DISPOSED', 'browser instance is disposed');
    if (this.active) return failure('REENTRY', reentryMessage);
    if (requireReady && this.state !== 'ready') return failure('STATE', stateMessage);
    if (this.operationId >= maximumApplicationOperationId) return failure('STATE', 'browser operation identity exhausted');
  }

  poison(cause, kind) {
    if (this.terminal) return this.terminal;
    kind ||= this.originalTrap || cause instanceof WebAssembly.RuntimeError ? 'trap' :
      this.abortSeen ? 'abort' : 'protocol';
    const original = this.originalTrap || cause;
    const error = original?.code?.startsWith('TITAN_BROWSER_') ? original :
      failure(kind.toUpperCase(), original instanceof Error ? original.message : String(original), original);
    this.terminal = error;
    this.state = 'poisoned';
    this.backend?.poison(error);
    this.out.interrupt(error);
    this.err.interrupt(error);
    // Poison is visible to every application method before observing failure.
    try { this.options?.onEngineFailure?.(Object.freeze({kind, cause: error})); }
    catch { /* An observer cannot replace the engine's original failure. */ }
    this.active?.fatal.reject(error);
    return error;
  }

  complete(record) {
    const pending = this.pending;
    if (!pending || record.id !== pending.id || record.kind !== pending.kind ||
        pending.completion !== undefined) {
      this.poison(failure('PROTOCOL', 'browser entry reported a duplicate or mismatched completion'));
      return;
    }
    pending.completion = record;
  }

  async entry(kind, ...args) {
    if (this.terminal) throw this.terminal;
    if (this.operationId >= (kind === 'close' ? maximumOperationId : maximumApplicationOperationId)) {
      throw failure('STATE', 'browser operation identity exhausted');
    }
    const id = ++this.operationId;
    const pending = {id, kind: operationKinds[kind], completion: undefined};
    this.pending = pending;
    try {
      const entry = this.module[`_titan_browser_${kind}`];
      if (typeof entry !== 'function') throw failure('PROTOCOL', `browser image has no ${kind} entry`);
      // Fulfillment is physical retirement, not an application return value.
      await Promise.race([entry(id, ...args), this.active.fatal.promise]);
      if (this.terminal) throw this.terminal;
      if (!this.backend.safe()) throw failure('PROTOCOL', 'browser entry retained its execution owner');
      if (pending.completion === undefined) throw failure('PROTOCOL', 'browser entry returned without completion');
      return pending.completion;
    } catch (cause) {
      throw this.poison(cause);
    } finally {
      this.pending = undefined;
    }
  }

  operate(operation, action, deferOutput = false) {
    const token = {fatal: deferred(), interrupted: undefined, promise: undefined,
      failed: false, error: undefined, failureCaptured: false, primaryFault: undefined};
    observe(token.fatal.promise);
    this.active = token;
    const promise = Promise.resolve().then(async () => {
      let result, failures;
      try { result = await action(); }
      catch (error) { captureFailure(token, error); }
      if (!this.terminal) {
        try { await this.retireCallables(); }
        catch (error) {
          const fault = {error};
          failures = [fault];
          captureFailure(token, error, fault);
        }
      }
      if (!deferOutput && !token.interrupted && !this.terminal) {
        const streams = await Promise.all([this.out.flush(token), this.err.flush(token)]);
        for (const stream of streams) {
          if (!stream) continue;
          if (!failures) failures = stream;
          else for (const fault of stream) failures.push(fault);
        }
      }
      if (token.interrupted && !token.failureCaptured) {
        token.failed = true;
        token.error = token.interrupted.error;
        token.primaryFault = token.interrupted;
      }
      if (failures) {
        for (const fault of failures) {
          if (this.terminal) break;
          if (fault !== token.primaryFault && !fault.observed) {
            this.reportNotification('cleanup', operation, fault.error);
          }
          fault.observed = true;
        }
      }
      if (token.interrupted && token.failureCaptured && !token.interrupted.observed &&
          !this.terminal) {
        this.reportNotification('cleanup', operation, token.interrupted.error);
        token.interrupted.observed = true;
      }
      if (this.terminal) throw this.terminal;
      if (token.failed) throw token.error;
      if (this.notificationFailure) {
        const error = this.notificationFailure;
        this.notificationFailure = undefined;
        throw error;
      }
      return result;
    }).finally(() => {
      this.active = undefined;
      if (!this.closing && !this.terminal && this.state === 'active') this.state = 'ready';
      this.scheduleSafePoint();
    });
    token.promise = promise;
    return promise;
  }

  async instantiate() {
    if (typeof WebAssembly.promising !== 'function' ||
        typeof WebAssembly.Suspending !== 'function') {
      throw failure('CAPABILITY', 'Titan browser images require WebAssembly JSPI (Node 26 or a JSPI-capable browser)');
    }
    // Avoid AllocationSite -> literal boilerplate -> instance-bound accessor -> Module.
    // Emscripten mutates this input, so it must not share a cached literal map.
    const incoming = Object.create(null);
    incoming.stdin = () => null;
    incoming.stdout = byte => this.out.byte(byte);
    incoming.stderr = byte => this.err.byte(byte);
    incoming.onAbort = cause => { this.abortSeen = true; this.poison(cause, this.originalTrap ? 'trap' : 'abort'); };
    incoming.titanBrowserAttach = backend => { this.backend = backend; };
    incoming.titanBrowserSafePoint = () => this.scheduleSafePoint();
    incoming.titanBrowserTrap = cause => { this.originalTrap ||= cause; this.poison(cause, 'trap'); };
    incoming.titanBrowserComplete = record => this.complete(record);
    incoming.titanBrowserBridge = this;
    if (this.options.locateFile !== undefined) incoming.locateFile = this.options.locateFile;
    try {
      this.module = await Promise.race([this.factory(incoming), this.active.fatal.promise]);
      this.factory = undefined;
      if (this.terminal) throw this.terminal;
      if (!this.backend || !(this.module?.HEAPU8 instanceof Uint8Array)) {
        throw failure('PROTOCOL', 'browser image does not provide Titan channels');
      }
    } catch (cause) {
      if (cause?.code === 'TITAN_BROWSER_CAPABILITY') throw cause;
      throw this.poison(cause);
    }
  }

  async initializeEntry() {
    await this.instantiate();
    let result;
    if (this.options.requireTrace) {
      const trace = this.trace();
      if (trace.state !== 'ready') {
        const bytes = new TextEncoder().encode(`degraded browser trace: ${trace.reason ?? 'metadata is not ready'}`);
        result = {failed: true, status: 1, bytes};
        for (const byte of bytes) this.err.byte(byte);
        this.err.byte(10);
      }
    }
    if (!result) result = await this.entry('initialize');
    if (result.failed) {
      this.initializationFailure = result;
      this.state = 'failed';
      throw this.titanError(result);
    }
    this.initializationSucceeded = true;
    if (!this.closing) this.state = 'ready';
  }

  initialize() {
    if (this.terminal) {
      return this.initialized && !this.initializationSucceeded ? this.initialized : Promise.reject(this.terminal);
    }
    if (this.closing) return Promise.reject(failure('DISPOSED', 'browser instance is disposed'));
    if (this.initialized) return this.initialized;
    const error = this.admission(false);
    if (error) return Promise.reject(error);
    this.state = 'initializing';
    this.initialized = this.operate('initialize', () => this.initializeEntry());
    return this.initialized;
  }

  run(args) {
    const error = this.admission(false);
    if (error) return Promise.reject(error);
    if (this.mainStarted) return Promise.reject(failure('STATE', 'browser main has already run'));
    this.mainStarted = true;
    return this.operate('run', async () => {
      if (!this.initialized) {
        this.state = 'initializing';
        this.initialized = observe(this.initializeEntry());
      }
      try { await this.initialized; }
      catch (cause) { if (!this.initializationFailure) throw cause; }
      if (this.initializationFailure) return this.runResult(this.initializationFailure);
      if (this.closing) throw failure('DISPOSED', 'browser instance is disposed');
      this.state = 'active';
      const allocations = [];
      try {
        const argv = this.marshalArguments(args, allocations);
        return this.runResult(await this.entry('entry', ...argv));
      } finally { this.free(allocations); }
    });
  }

  runResult(result) {
    return Object.freeze({kind: result.failed ? 'failed' : 'returned', status: result.status, bytes: result.bytes});
  }

  titanError(result) {
    const error = failure('TITAN', new TextDecoder().decode(result.bytes));
    error.bytes = result.bytes;
    error.trace = result.trace;
    error.status = result.status;
    return error;
  }

  allocate(size, allocations) {
    if (this.terminal) throw this.terminal;
    if (!size) return 0;
    const pointer = this.module._titan_browser_alloc(size) >>> 0;
    if (this.terminal) throw this.terminal;
    if (!pointer) throw new RangeError('not enough memory for browser arguments');
    allocations.push(pointer);
    return pointer;
  }

  free(allocations) {
    if (!this.terminal && this.module) {
      for (let index = allocations.length - 1; index >= 0 && !this.terminal; --index) {
        this.module._titan_browser_free(allocations[index]);
      }
    }
  }

  marshalArguments(args, allocations) {
    if (!Array.isArray(args)) throw new TypeError('browser arguments must be an array');
    const encoded = args.map(arg => typeof arg === 'string' ? new TextEncoder().encode(arg) : copiedBytes(arg));
    const pointers = encoded.map(bytes => {
      const pointer = this.allocate(bytes.length, allocations);
      if (bytes.length) this.module.HEAPU8.set(bytes, pointer);
      return pointer;
    });
    const argv = this.allocate(encoded.length * 4, allocations);
    const lengths = this.allocate(encoded.length * 4, allocations);
    const heap = this.module.HEAPU8;
    const view = new DataView(heap.buffer, heap.byteOffset, heap.byteLength);
    for (let index = 0; index < encoded.length; ++index) {
      view.setUint32(argv + index * 4, pointers[index], true);
      view.setUint32(lengths + index * 4, encoded[index].length, true);
    }
    return [encoded.length, argv, lengths];
  }

  validateCallable(value, state) {
    const record = wrapperRecords.get(value);
    if (!record || record.owner !== this || record.released || !this.states.has(record.state) ||
        this.states.get(record.state) === 'closed' || state !== undefined && state !== record.state) {
      throw failure('HANDLE', 'browser callable is foreign, released, or belongs to a closed state');
    }
    return record;
  }

  wrapCallable(state, slot, generation, signature) {
    const key = `${state}:${slot}:${generation}`;
    let record = this.callables.get(key);
    if (!record) {
      record = {owner: this, state, slot, generation, signature, released: false, key};
      const wrapper = Object.freeze(new CallableView());
      wrapperRecords.set(wrapper, record);
      record.wrapper = wrapper;
      this.callables.set(key, record);
    }
    return record.wrapper;
  }

  releaseCallable(record) {
    if (record.released) return;
    record.released = true;
    record.owner = undefined;
    this.callables.delete(record.key);
    if (this.states.get(record.state) !== 'closed' && !this.closing && !this.terminal) {
      this.releases.push({state: record.state, slot: record.slot, generation: record.generation});
      this.scheduleSafePoint();
    }
  }

  async retireCallables() {
    while (this.releases.length && !this.terminal && this.operationId < maximumApplicationOperationId) {
      const release = this.releases.shift();
      if (this.states.get(release.state) === 'closed') continue;
      const result = await this.entry('release_callable', release.state, release.slot, release.generation);
      if (result.failed) throw this.titanError(result);
    }
  }

  async invoke(record, args) {
    this.validateCallable(record.wrapper);
    const allocations = [], temporary = [];
    try {
      const argv = this.marshalValues(record, args, allocations, temporary);
      const result = await this.entry('invoke', record.state, record.slot, record.generation, args.length, argv);
      if (result.failed) throw this.titanError(result);
      return result.values;
    } finally {
      this.free(allocations);
      for (const handle of temporary) {
        const entry = this.slots.get(handle.slot);
        if (entry?.generation === handle.generation && entry.temporary) this.releaseSlot(handle.slot, handle.generation);
      }
    }
  }

  call(value, args) {
    const error = this.admission();
    if (error) return Promise.reject(error);
    let record, copied;
    try {
      record = this.validateCallable(value);
      copied = this.snapshotArguments(record, args);
    } catch (cause) { return Promise.reject(cause); }
    this.state = 'active';
    return this.operate('call', () => this.invoke(record, copied));
  }

  notify(value, args) {
    if (this.closing) return;
    if (this.terminal) throw this.terminal;
    if (this.state === 'created' || this.state === 'failed') throw failure('STATE', stateMessage);
    const record = this.validateCallable(value);
    const copied = this.snapshotArguments(record, args);
    this.queue.push({record, args: copied});
    this.scheduleSafePoint();
  }

  drain() {
    const error = this.admission();
    if (error) return Promise.reject(error);
    const batch = this.queue;
    this.queue = [];
    this.drainAnnounced = false;
    this.state = 'active';
    return this.operate('drain', async () => {
      try {
        for (const notification of batch) {
          if (this.closing) break;
          const {record, args, request} = notification;
          // Cancellation filters the live queue, not this detached batch.
          // Normally settled one-shots are retired too, but still deliver.
          if (request?.cancelled || record.released || this.states.get(record.state) === 'closed') continue;
          try { await this.invoke(record, this.snapshotArguments(record, args)); }
          catch (cause) {
            if (this.terminal) throw this.terminal;
            this.reportNotification('callback', 'drain', cause);
          } finally {
            notification.record = notification.args = undefined;
          }
        }
      } finally { batch.length = 0; }
    });
  }

  reportNotification(kind, operation, cause) {
    const error = notifyError(this.options?.onNotificationError, kind, operation, cause);
    this.notificationFailure ||= error;
  }

  scheduleSafePoint() {
    if (this.active || this.closing || this.terminal || this.backend && !this.backend.safe()) return;
    if (this.releases.length && !this.releaseScheduled && this.operationId < maximumApplicationOperationId) {
      this.releaseScheduled = true;
      queueMicrotask(releaseAtSafePoint.bind(undefined, this));
    }
    if (this.queue.length && !this.drainAnnouncement && !this.drainAnnounced && this.options?.requestDrain) {
      this.drainAnnouncement = true;
      queueMicrotask(announceDrain.bind(undefined, this));
    }
  }

  registerState(state) {
    if (this.states.has(state)) throw failure('PROTOCOL', 'duplicate browser state identity');
    this.states.set(state, 'open');
  }

  closeState(state) {
    this.states.set(state, 'closed');
    for (const record of this.callables.values()) {
      if (record.state === state) {
        record.released = true;
        record.owner = undefined;
        this.callables.delete(record.key);
      }
    }
    this.queue = this.queue.filter(entry => entry.record.state !== state);
    this.releases = this.releases.filter(entry => entry.state !== state);
    for (const request of this.requests) {
      if (request.state === state) {
        try { this.cancelRequest(request); }
        catch (cause) { this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause); }
      }
    }
    for (const [slot, entry] of this.slots) {
      if (entry.state === state) {
        entry.units = 1;
        this.releaseSlot(slot, entry.generation);
      }
    }
  }

  newSlot(state, value, kind = 'value') {
    if (this.states.get(state) === 'closed' || !this.states.has(state)) {
      throw failure('HANDLE', 'browser handle belongs to a closed state');
    }
    let slot, generation;
    while (this.freeSlots.length) {
      const free = this.freeSlots.pop();
      if (free.generation < 0xffffffff) {
        slot = free.slot;
        generation = free.generation + 1;
        break;
      }
    }
    if (slot === undefined) {
      if (this.nextSlot > 0xffffffff) throw failure('HANDLE', 'browser handle identity exhausted');
      slot = this.nextSlot++;
      generation = 1;
    }
    this.slots.set(slot, {value, state, generation, kind, units: 1});
    return {slot, generation};
  }

  getSlot(state, slot, generation, kind) {
    const entry = this.slots.get(slot);
    if (!entry || entry.state !== state || entry.generation !== generation ||
        kind && entry.kind !== kind || this.states.get(state) === 'closed') {
      throw failure('HANDLE', 'browser handle is foreign, released, or belongs to a closed state');
    }
    return entry;
  }

  identityLive(state, slot, generation, type) {
    if (this.terminal || !state || !slot || !generation || !this.states.has(state) ||
        this.states.get(state) === 'closed') return 0;
    if (type === kind.handle) {
      const entry = this.slots.get(slot);
      return entry && entry.kind === 'value' && entry.state === state &&
        entry.generation === generation && entry.units > 0 ? 1 : 0;
    }
    if (type === kind.callable) {
      const record = this.callables.get(`${state}:${slot}:${generation}`);
      return record && record.owner === this && !record.released ? 1 : 0;
    }
    return 0;
  }

  releaseSlot(slot, generation) {
    const entry = this.slots.get(slot);
    if (!entry || entry.generation !== generation) return;
    if (--entry.units > 0) return;
    this.slots.delete(slot);
    if (entry.kind === 'request') {
      try { this.cancelRequest(entry.value); }
      catch (cause) { this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause); }
    }
    this.freeSlots.push({slot, generation});
  }

  heapView(pointer = 0, length = this.module.HEAPU8.byteLength) {
    const heap = this.module.HEAPU8;
    if (!Number.isSafeInteger(pointer) || !Number.isSafeInteger(length) ||
        pointer < 0 || length < 0 || pointer + length > heap.byteLength) {
      throw failure('PROTOCOL', 'browser bridge memory range is invalid');
    }
    return new DataView(heap.buffer, heap.byteOffset + pointer, length);
  }

  bytesAt(pointer, length) {
    this.heapView(pointer, length);
    return this.module.HEAPU8.slice(pointer, pointer + length);
  }

  signatureAt(pointer) {
    const view = this.heapView(pointer, 16);
    const parameters = view.getUint32(0, true), results = view.getUint32(4, true);
    const read = (address, count) => {
      const data = this.heapView(address, count * 4);
      const values = [];
      for (let index = 0; index < count; ++index) {
        const value = data.getUint32(index * 4, true);
        if (value > kind.callable) throw failure('PROTOCOL', 'unsupported browser callable descriptor');
        values.push(value);
      }
      return Object.freeze(values);
    };
    return Object.freeze({params: read(view.getUint32(8, true), parameters),
      results: read(view.getUint32(12, true), results)});
  }

  registerCallable(state, slot, generation, pointer) {
    this.wrapCallable(state, slot, generation, this.signatureAt(pointer));
  }

  invalidateCallable(state, slot, generation) {
    const key = `${state}:${slot}:${generation}`;
    const record = this.callables.get(key);
    if (!record) return;
    record.released = true;
    record.owner = undefined;
    this.callables.delete(key);
  }

  callableAt(state, slot, generation) {
    const record = this.callables.get(`${state}:${slot}:${generation}`);
    if (!record) throw failure('HANDLE', 'browser callable is released');
    this.validateCallable(record.wrapper, state);
    return record.wrapper;
  }

  snapshotArguments(record, args) {
    if (args.length !== record.signature.params.length) {
      throw new TypeError(`browser callable expects exactly ${record.signature.params.length} arguments`);
    }
    return args.map((value, index) => {
      switch (record.signature.params[index]) {
        case kind.nil:
          if (value !== null) throw new TypeError('browser nil argument must be null');
          break;
        case kind.boolean:
          if (typeof value !== 'boolean') throw new TypeError('browser boolean argument must be a boolean');
          break;
        case kind.integer:
          if (typeof value !== 'bigint' || value < -(1n << 63n) || value >= 1n << 63n) {
            throw new TypeError('browser integer argument must be a signed i64 BigInt');
          }
          break;
        case kind.float:
          if (typeof value !== 'number') throw new TypeError('browser float argument must be a Number');
          break;
        case kind.bytes: return copiedBytes(value);
        case kind.handle:
          if (wrapperRecords.has(value)) this.validateCallable(value, record.state);
          break;
        case kind.callable: this.validateCallable(value, record.state); break;
        default: throw failure('PROTOCOL', 'unsupported browser argument descriptor');
      }
      return value;
    });
  }

  marshalValues(record, args, allocations, temporary) {
    const pointer = this.allocate(args.length * valueSize, allocations);
    if (args.length) this.module.HEAPU8.fill(0, pointer, pointer + args.length * valueSize);
    for (let index = 0; index < args.length; ++index) {
      const value = args[index], type = record.signature.params[index];
      const address = pointer + index * valueSize;
      let bytes, handle;
      if (type === kind.bytes) {
        bytes = this.allocate(value.length, allocations);
        if (value.length) this.module.HEAPU8.set(value, bytes);
      } else if (type === kind.handle) {
        handle = this.newSlot(record.state, value);
        this.slots.get(handle.slot).temporary = true;
        temporary.push(handle);
      } else if (type === kind.callable) handle = this.validateCallable(value, record.state);
      // Allocations above may have grown Wasm memory.
      const view = this.heapView(address, valueSize);
      view.setUint32(0, type, true);
      if (type === kind.boolean) view.setBigInt64(8, value ? 1n : 0n, true);
      else if (type === kind.integer) view.setBigInt64(8, value, true);
      else if (type === kind.float) view.setFloat64(8, value, true);
      else if (type === kind.bytes) {
        view.setUint32(16, bytes, true);
        view.setUint32(20, value.length, true);
      } else if (handle) {
        view.setUint32(4, record.state, true);
        view.setUint32(24, handle.slot, true);
        view.setUint32(28, handle.generation, true);
      }
    }
    return pointer;
  }

  valuesAt(pointer, count, state) {
    const view = this.heapView(pointer, count * valueSize);
    const values = [];
    for (let index = 0; index < count; ++index) {
      const address = index * valueSize, type = view.getUint32(address, true);
      switch (type) {
        case kind.nil: values.push(null); break;
        case kind.boolean: {
          const value = view.getBigInt64(address + 8, true);
          if (value !== 0n && value !== 1n) throw new TypeError('browser boolean has an invalid representation');
          values.push(value === 1n);
          break;
        }
        case kind.integer: values.push(view.getBigInt64(address + 8, true)); break;
        case kind.float: values.push(view.getFloat64(address + 8, true)); break;
        case kind.bytes:
          values.push(this.bytesAt(view.getUint32(address + 16, true), view.getUint32(address + 20, true)));
          break;
        case kind.handle:
        case kind.callable: {
          const ownerState = view.getUint32(address + 4, true);
          if (state !== undefined && ownerState !== state) throw failure('HANDLE', 'browser argument belongs to another state');
          const slot = view.getUint32(address + 24, true), generation = view.getUint32(address + 28, true);
          values.push(type === kind.handle ? this.getSlot(ownerState, slot, generation).value :
            this.callableAt(ownerState, slot, generation));
          break;
        }
        default: throw failure('PROTOCOL', 'browser value has an invalid kind');
      }
    }
    return values;
  }

  receiveCompletion(pointer) {
    const view = this.heapView(pointer, 48);
    const id = view.getBigUint64(0, true), operation = view.getUint32(8, true);
    const pending = this.backend.pending;
    if (!pending || pending.id !== id || pending.kind !== operation || pending.completed ||
        operation < 1 || operation > 5) {
      this.poison(failure('PROTOCOL', 'browser entry reported a duplicate or mismatched completion'));
      return;
    }
    pending.completed = true;
    const status = view.getUint32(12, true);
    const record = {id, kind: operation, failed: status !== 0,
      status: view.getInt32(16, true),
      bytes: this.bytesAt(view.getUint32(28, true), view.getUint32(32, true)),
      trace: this.bytesAt(view.getUint32(36, true), view.getUint32(40, true)),
      values: this.valuesAt(view.getUint32(24, true), view.getUint32(20, true))};
    this.complete(record);
  }

  openState() {
    this.nextState = (this.nextState ?? 0) + 1;
    if (this.nextState > 0xffffffff) throw failure('STATE', 'browser state identity exhausted');
    this.registerState(this.nextState);
    return this.nextState;
  }

  markStateClosing(state) {
    if (this.states.get(state) !== 'closed') this.states.set(state, 'closing');
    for (const request of this.requests) {
      if (request.state === state) {
        try { this.cancelRequest(request); }
        catch (cause) { this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause); }
      }
    }
  }

  releaseOwnedSlot(state, slot, generation) {
    const entry = this.slots.get(slot);
    if (entry?.state === state) this.releaseSlot(slot, generation);
  }

  adoptSlot(state, slot, generation) {
    const entry = this.getSlot(state, slot, generation);
    entry.temporary = false;
  }

  binding(pointer, length, state) {
    const name = new TextDecoder('utf-8', {fatal: true}).decode(this.bytesAt(pointer, length));
    const bindings = this.options.bindings;
    if (!bindings || !Object.hasOwn(bindings, name)) throw new Error(`unknown browser binding ${name}`);
    return {kind: kind.handle, value: bindings[name], state};
  }

  hostCall(state, slot, generation, count, pointer, resultKind) {
    const target = this.getSlot(state, slot, generation).value;
    if (typeof target !== 'function') throw new TypeError('browser binding is not callable');
    const args = this.valuesAt(pointer, count, state);
    return {kind: resultKind, value: target(...args), state};
  }

  completionTarget(state, slot, generation, parameters) {
    const wrapper = this.callableAt(state, slot, generation);
    const record = this.validateCallable(wrapper, state);
    if (record.signature.results.length ||
        parameters && (record.signature.params.length !== parameters.length ||
          parameters.some((type, index) => record.signature.params[index] !== type))) {
      throw new TypeError('browser request completion has an incompatible signature');
    }
    return record;
  }

  newRequest(state, success, rejected) {
    if (this.closing || this.states.get(state) !== 'open') {
      throw failure('DISPOSED', 'browser state is closing');
    }
    const request = {state, success, rejected, kind: 'starting', cancelled: false,
      cancelSignalled: false, retired: false, cancel: undefined,
      terminal: deferred(), cell: undefined};
    request.cell = {target: {owner: this, request}};
    // Reserve the native owner before host acceptance or output publication.
    request.identity = this.newSlot(state, request, 'request');
    this.requests.add(request);
    return request;
  }

  startRequest(request, target, args, listener) {
    try {
      const form = target(...args);
      const ownership = form?.kind;
      if (!form || listener && ownership !== 'listener' ||
          !listener && !['detachable', 'retained'].includes(ownership)) {
        throw new TypeError('browser host request must declare its ownership form');
      }
      if (listener) {
        const subscribe = form.subscribe;
        if (typeof subscribe !== 'function') throw new TypeError('browser listener requires subscribe(emit)');
        const unregister = subscribe.call(form, listenerEvent.bind(undefined, request.cell));
        if (typeof unregister !== 'function') throw new TypeError('browser listener requires an unregister function');
        request.cancel = unregister;
      } else {
        const cancel = form.cancel;
        if (cancel !== undefined && typeof cancel !== 'function') {
          throw new TypeError('browser request cancel must be a function');
        }
        request.cancel = cancel;
        Promise.resolve(form.promise).then(
          requestFulfilled.bind(undefined, request.cell),
          requestRejected.bind(undefined, request.cell));
      }
      request.kind = ownership;
    } catch (cause) {
      this.retireRequest(request, true);
      this.releaseSlot(request.identity.slot, request.identity.generation);
      throw cause;
    }
    // Disposal may have been requested by the binding/subscribe import. Its
    // starting owner cannot retire until the ownership form is fully installed.
    // Cancellation failure never retires an accepted retained host operation.
    if (request.cancelled || this.closing) {
      try { this.cancelRequest(request); }
      catch (cause) {
        if (this.closing) this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause);
        this.releaseSlot(request.identity.slot, request.identity.generation);
        throw cause;
      }
    }
    return request;
  }

  emitRequest(request, args, rejected = false) {
    if (request.retired || request.cancelled || this.closing || this.terminal) return;
    const record = rejected ? request.rejected : request.success;
    if (record.released || this.states.get(request.state) !== 'open') return;
    try {
      this.notify(record.wrapper, args);
      this.queue[this.queue.length - 1].request = request;
    } catch (cause) {
      if (!rejected) this.emitRequest(request, [messageBytes(cause), cause], true);
      else this.reportNotification('callback', 'notify', cause);
    }
  }

  settleRequest(request, success, value) {
    if (request.retired) return;
    if (!request.cancelled && !this.closing && !this.terminal) {
      if (success) {
        try {
          if (request.capacity !== undefined) value = checkedReadSpan(value, request.capacity);
          const count = request.success.signature.params.length;
          let args;
          if (count === 0) {
            if (value !== undefined) throw new TypeError('zero-argument completion requires undefined');
            args = [];
          } else if (count === 1) args = [value];
          else {
            if (!Array.isArray(value) || value.length !== count) {
              throw new TypeError('multiple-argument completion requires an exact dense array');
            }
            // Host indices may reenter or dispose. Materialize under the request
            // owner before emitRequest checks liveness and publishes a notification.
            args = [];
            for (let index = 0; index < count; ++index) {
              if (!Object.hasOwn(value, index)) {
                throw new TypeError('multiple-argument completion requires an exact dense array');
              }
              args.push(value[index]);
            }
          }
          this.emitRequest(request, args);
        } catch (cause) { this.emitRequest(request, [messageBytes(cause), cause], true); }
      } else this.emitRequest(request, [messageBytes(value), value], true);
    }
    this.retireRequest(request);
  }

  retireRequest(request, discard = false) {
    if (request.retired) return;
    request.retired = true;
    request.cell.target = undefined;
    if (discard) this.queue = this.queue.filter(entry => entry.request !== request);
    request.terminal.resolve();
    this.requests.delete(request);
    request.success = request.rejected = request.cancel = undefined;
  }

  cancelRequest(request) {
    if (request.retired) return;
    request.cancelled = true;
    if (request.kind === 'starting') return;
    let error;
    if (!request.cancelSignalled) {
      request.cancelSignalled = true;
      try { request.cancel?.(); }
      catch (cause) { error = cause; }
      request.cancel = undefined;
    }
    if (request.kind !== 'retained') this.retireRequest(request, true);
    else this.queue = this.queue.filter(entry => entry.request !== request);
    if (error) throw error;
  }

  hostStart(state, slot, generation, count, pointer, successSlot, successGeneration,
      failureSlot, failureGeneration, listener) {
    const success = this.completionTarget(state, successSlot, successGeneration);
    const rejected = this.completionTarget(state, failureSlot, failureGeneration, [kind.bytes, kind.handle]);
    const target = this.getSlot(state, slot, generation).value;
    if (typeof target !== 'function') throw new TypeError('browser request binding is not callable');
    const args = this.valuesAt(pointer, count, state);
    const request = this.newRequest(state, success, rejected);
    this.startRequest(request, target, args, listener);
    return {kind: kind.request, value: request};
  }

  hostCancel(state, slot, generation) {
    const request = this.getSlot(state, slot, generation, 'request').value;
    this.cancelRequest(request);
    return {kind: kind.void, value: undefined};
  }

  hostRead(state, capacity, successSlot, successGeneration, failureSlot, failureGeneration) {
    const success = this.completionTarget(state, successSlot, successGeneration, [kind.bytes]);
    const rejected = this.completionTarget(state, failureSlot, failureGeneration, [kind.bytes, kind.handle]);
    const source = this.options.stdin;
    if (!source) throw new Error('browser stdin source is unavailable');
    const request = this.newRequest(state, success, rejected);
    request.capacity = capacity;
    this.startRequest(request, () => {
      const result = source(capacity);
      return result?.kind === 'retained' || result?.kind === 'detachable' ? result :
        {kind: 'detachable', promise: result};
    }, [], false);
    return {kind: kind.request, value: request};
  }

  hostWrite(state, stream, pointer, length, successSlot, successGeneration, failureSlot, failureGeneration) {
    const channel = stream === 1 ? this.out : stream === 2 ? this.err : undefined;
    if (!channel) throw new TypeError('browser output stream must be STDOUT or STDERR');
    this.heapView(pointer, length);
    let completion, request;
    if (successSlot !== 0) {
      const success = this.completionTarget(state, successSlot, successGeneration, []);
      const rejected = this.completionTarget(state, failureSlot, failureGeneration, [kind.bytes, kind.handle]);
      request = this.newRequest(state, success, rejected);
      request.kind = 'detachable';
      completion = {resolve: requestFulfilled.bind(undefined, request.cell),
        reject: requestRejected.bind(undefined, request.cell)};
    }
    try {
      channel.append(this.module.HEAPU8.subarray(pointer, pointer + length), completion);
    } catch (cause) {
      if (request) this.releaseSlot(request.identity.slot, request.identity.generation);
      throw cause;
    }
    return request ? {kind: kind.request, value: request} : {kind: kind.void, value: undefined};
  }

  importResponse(pointer, state, action) {
    const allocations = [], handles = [];
    try {
      if (this.terminal) throw this.terminal;
      this.module.HEAPU8.fill(0, pointer, pointer + 56);
      const result = action();
      if (this.terminal) throw this.terminal;
      this.writeResponseValue(pointer + 8, state, result.kind, result.value, allocations, handles);
      if (this.terminal) throw this.terminal;
    } catch (cause) {
      if (this.terminal) throw this.terminal;
      this.free(allocations);
      if (this.terminal) throw this.terminal;
      for (const handle of handles) {
        this.releaseSlot(handle.slot, handle.generation);
        if (this.terminal) throw this.terminal;
      }
      this.module.HEAPU8.fill(0, pointer, pointer + 56);
      let thrown;
      try {
        thrown = this.newSlot(state, cause);
        const message = messageBytes(cause);
        const address = this.allocate(message.length, []);
        if (message.length) this.module.HEAPU8.set(message, address);
        const view = this.heapView(pointer, 56);
        view.setUint32(0, 2, true);
        view.setUint32(40, address, true);
        view.setUint32(44, message.length, true);
        view.setUint32(48, thrown.slot, true);
        view.setUint32(52, thrown.generation, true);
      } catch {
        if (this.terminal) throw this.terminal;
        const view = this.heapView(pointer, 56);
        view.setUint32(0, thrown ? 2 : 5, true);
        if (thrown) {
          view.setUint32(48, thrown.slot, true);
          view.setUint32(52, thrown.generation, true);
        }
      }
    } finally {
      if (!this.terminal) this.heapView(pointer, 56).setUint32(4, state, true);
    }
  }

  writeResponseValue(pointer, state, type, value, allocations, handles) {
    let handle, bytes, length = 0;
    switch (type) {
      case kind.void:
        if (value !== undefined) throw new TypeError('browser void binding must return undefined');
        break;
      case kind.boolean:
        if (typeof value !== 'boolean') throw new TypeError('browser boolean binding must return a boolean');
        break;
      case kind.integer:
        if (typeof value !== 'bigint' || value < -(1n << 63n) || value >= 1n << 63n) {
          throw new TypeError('browser integer binding must return a signed i64 BigInt');
        }
        break;
      case kind.float:
        if (typeof value !== 'number') throw new TypeError('browser float binding must return a Number');
        break;
      case kind.bytes: {
        const counted = value instanceof Uint8Array ? {bytes: value, length: value.length} : value;
        const returned = counted?.bytes, count = counted?.length;
        if (this.terminal) throw this.terminal;
        if (!(returned instanceof Uint8Array) || !Number.isSafeInteger(count) || count < 0 ||
            count > returned.length || count > 0xffffffff) {
          throw new TypeError('browser byte result has an invalid length or capacity');
        }
        let source = new Uint8Array(returned.buffer, returned.byteOffset, count);
        if (this.terminal) throw this.terminal;
        // A host may return this image's own heap. Preserve that span before
        // allocating its response buffer can grow/detach the current memory.
        if (source.buffer === this.module.HEAPU8.buffer) source = new Uint8Array(source);
        length = count;
        bytes = this.allocate(length, allocations);
        if (length) this.module.HEAPU8.set(source, bytes);
        break;
      }
      case kind.handle:
        if (wrapperRecords.has(value)) this.validateCallable(value, state);
        handle = this.newSlot(state, value);
        handles.push(handle);
        break;
      case kind.request:
        handle = value.identity;
        this.getSlot(state, handle.slot, handle.generation, 'request');
        handles.push(handle);
        break;
      default: throw new TypeError('unsupported browser binding result kind');
    }
    if (this.terminal) throw this.terminal;
    const view = this.heapView(pointer, valueSize);
    view.setUint32(0, type, true);
    view.setUint32(4, state, true);
    if (type === kind.boolean) view.setBigInt64(8, value ? 1n : 0n, true);
    else if (type === kind.integer) view.setBigInt64(8, value, true);
    else if (type === kind.float) view.setFloat64(8, value, true);
    else if (type === kind.bytes) {
      view.setBigInt64(8, BigInt(length), true);
      view.setUint32(16, bytes, true);
      view.setUint32(20, length, true);
    } else if (handle) {
      view.setUint32(24, handle.slot, true);
      view.setUint32(28, handle.generation, true);
    }
  }

  trace() {
    const trace = this.module?.titanBrowserTrace || this.lastTrace;
    return Object.freeze({state: trace?.state ?? 'created', reason: trace?.reason ?? null});
  }

  dispose() {
    if (this.disposed) return this.disposed;
    // Cancellation may synchronously call dispose again; publish its stable
    // promise before signalling any host owner.
    const disposal = deferred();
    this.disposed = disposal.promise;
    this.closing = true;
    this.state = this.terminal ? 'poisoned' : 'disposing';
    const error = failure('DISPOSED', 'browser instance is disposed');
    const fault = {error};
    if (this.active) this.active.interrupted = fault;
    this.out.interrupt(error, fault);
    this.err.interrupt(error, fault);
    this.queue = [];
    for (const request of this.requests) {
      try { this.cancelRequest(request); }
      catch (cause) { this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause); }
    }
    // The final drain's continuation is module-scoped, not an instance method.
    disposal.resolve(retireOwner(this).then(finishDisposal));
    return this.disposed;
  }
}

async function retireOwner(owner) {
  if (owner.active) {
    try { await owner.active.promise; }
    catch { /* The interrupted operation reports its own failure. */ }
  }
  await Promise.all([...owner.requests].map(request => request.terminal.promise));
  let error = owner.retirementFailure;
  if (owner.module && !owner.terminal) {
    try {
      await owner.operate('dispose', async () => {
        const result = await owner.entry('close');
        if (result.failed) throw owner.titanError(result);
      }, true);
    } catch (cause) {
      if (error && !owner.terminal) owner.reportNotification('cleanup', 'dispose', error);
      error = cause;
    }
  }
  if (owner.backend) owner.backend.blocked = true;
  for (const state of owner.states.keys()) owner.closeState(state);
  const drains = [owner.out.takeDrain(), owner.err.takeDrain()];
  const disposal = {drains, failure: error ? {error} : undefined,
    observer: owner.options?.onNotificationError};
  owner.lastTrace = owner.trace();
  owner.module = owner.backend = owner.factory = owner.options = undefined;
  owner.pending = undefined;
  owner.queue = owner.releases = owner.freeSlots = [];
  owner.slots.clear();
  owner.callables.clear();
  owner.requests.clear();
  owner.state = 'disposed';
  return disposal;
}

/** Create one persistent instance; the image supplies its private factory. */
export function create(factory, options = {}) {
  if (typeof factory !== 'function') throw new TypeError('browser factory must be a function');
  for (const name of ['stdout', 'stderr', 'stdin', 'locateFile', 'onNotificationError', 'requestDrain', 'onEngineFailure']) {
    if (options[name] !== undefined && typeof options[name] !== 'function') {
      throw new TypeError(`browser ${name} must be a function`);
    }
  }
  if (options.requireTrace !== undefined && typeof options.requireTrace !== 'boolean') {
    throw new TypeError('browser requireTrace must be a boolean');
  }
  if (options.bindings !== undefined && (options.bindings === null ||
      typeof options.bindings !== 'object')) throw new TypeError('browser bindings must be an object');
  const owner = new BrowserOwner(factory, {...options});
  return Object.freeze({
    initialize: () => owner.initialize(),
    run: (args = []) => owner.run(args),
    call: (callable, ...args) => owner.call(callable, args),
    notify: (callable, ...args) => owner.notify(callable, args),
    drain: () => owner.drain(),
    dispose: () => owner.dispose(),
    get trace() { return owner.trace(); },
  });
}
