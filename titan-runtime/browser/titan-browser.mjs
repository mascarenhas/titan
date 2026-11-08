const reentryMessage = 'browser instance is active; reentry is not allowed';
const stateMessage = 'browser instance is not initialized';
const maximumOperationId = (1n << 64n) - 1n;
const maximumApplicationOperationId = maximumOperationId - 1n; // Reserve the final id for intact-state close.
const wrapperRecords = new WeakMap();
const stringIsWellFormed = String.prototype.isWellFormed;
const utf8Decoder = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});
const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const typedArrayTag = Object.getOwnPropertyDescriptor(typedArrayPrototype, Symbol.toStringTag).get;
const typedArrayLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'length').get;
const typedArraySet = typedArrayPrototype.set;
// titan/browser.h's asserted wasm32 layout and discriminants.
const valueSize = 32;
const kind = Object.freeze({nil: 0, boolean: 1, integer: 2, float: 3,
  string: 4, bytes: 5, handle: 6, callable: 7, request: 8});
const responseStatus = Object.freeze({ok: 0, titanError: 1, jsError: 2, state: 3, memory: 4});
const operationKinds = Object.freeze({initialize: 1, entry: 2, invoke: 3,
  release_callable: 4, close: 5, gate_guarded: 3});
const relinquishStatus = Object.freeze({resumed: 0, idle: 1, disposing: 2});
const deliveryKind = Object.freeze({notify: 1, call: 2, release: 3});
const deliverySize = 32;
const anotherStateMessage = 'calls for another Lua state are not admitted while the owner drives';

const bridgeFailures = new WeakSet();
function ownFailure(value, code) {
  return bridgeFailures.has(value) && value.code === `TITAN_BROWSER_${code}`;
}

function failure(code, message, cause, stream) {
  const error = new Error(message, cause === undefined ? undefined : {cause});
  error.name = 'TitanBrowserError';
  error.code = `TITAN_BROWSER_${code}`;
  if (stream !== undefined) error.stream = stream;
  bridgeFailures.add(error);
  return error;
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

function isUint8Array(value) {
  return typedArrayTag.call(value) === 'Uint8Array';
}

function copiedBytes(value) {
  // Call/notify snapshot before publication: native slots cannot reenter through
  // a Proxy, iterator, accessor, constructor or species hook.
  if (!isUint8Array(value)) throw new TypeError('browser bytes must be a Uint8Array');
  const copy = new Uint8Array(typedArrayLength.call(value));
  typedArraySet.call(copy, value);
  return copy;
}

function encodeString(value) {
  if (typeof value !== 'string' || !stringIsWellFormed.call(value)) {
    throw new TypeError('browser string must be well-formed UTF-16');
  }
  return new TextEncoder().encode(value);
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

// The driver's turn source: one unclamped macrotask per relinquish point or
// coalesced wake. Its handler sees only the owner's detachable cell.
function turnFired(cell) {
  const owner = cell.target;
  if (owner) owner.turnFired();
}

// A Task-form call's AbortSignal listener; settlement or disposal detaches it.
function taskAborted(cell) {
  const target = cell.target;
  if (target) target.owner.abortTask(target.item);
}

// SDK-owned sources reached through the reserved `titan:` binding names.
// They capture no instance: request ownership belongs to the bridge.
const maximumTimerDelay = 2147483647;

function timeoutSource(ms) {
  if (typeof ms !== 'number' || !(ms >= 0)) throw new TypeError('titan:timeout delay must be a nonnegative Number');
  const timer = {id: undefined, resolve: undefined};
  const promise = new Promise(resolve => { timer.resolve = resolve; });
  armChunk(timer, ms, timeoutElapsed);
  return {kind: 'detachable', promise, cancel: cancelTimeout.bind(undefined, timer)};
}

// Delays beyond the host's 32-bit timer range are re-armed in chunks.
function armChunk(timer, remaining, elapsed) {
  const delay = Math.min(remaining, maximumTimerDelay);
  timer.id = setTimeout(elapsed, delay, timer, remaining - delay);
}

function timeoutElapsed(timer, remaining) {
  timer.id = undefined;
  if (remaining > 0) {
    armChunk(timer, remaining, timeoutElapsed);
    return;
  }
  const resolve = timer.resolve;
  timer.resolve = undefined;
  resolve?.(undefined);
}

function cancelTimeout(timer) {
  clearTimeout(timer.id);
  timer.id = timer.resolve = undefined;
}

function intervalSource(ms) {
  if (typeof ms !== 'number' || !(ms > 0)) throw new TypeError('titan:interval period must be a positive Number');
  return {kind: 'listener', subscribe: intervalSubscribe.bind(undefined, ms)};
}

// A period beyond the host's timer range repeats through chunked timeouts.
function intervalSubscribe(ms, emit) {
  if (ms <= maximumTimerDelay) return stopInterval.bind(undefined, setInterval(intervalTick, ms, emit));
  const timer = {id: undefined, period: ms, emit};
  armChunk(timer, ms, periodElapsed);
  return stopPeriod.bind(undefined, timer);
}

function intervalTick(emit) { emit(); }

function stopInterval(id) { clearInterval(id); }

// The whole period is re-armed before the tick is emitted, so unregistering
// after any tick clears the next period's first chunk.
function periodElapsed(timer, remaining) {
  if (remaining > 0) {
    armChunk(timer, remaining, periodElapsed);
    return;
  }
  armChunk(timer, timer.period, periodElapsed);
  timer.emit();
}

function stopPeriod(timer) {
  clearTimeout(timer.id);
  timer.id = undefined;
}

const sdkBindings = Object.freeze(Object.assign(Object.create(null), {
  'titan:timeout': () => timeoutSource,
  'titan:interval': () => intervalSource,
  'titan:driver': (owner, state) => owner.registerDriver.bind(owner, state),
}));

function observe(promise) {
  // Only bridge-owned retirement promises are observed here. User promises
  // returned as opaque BrowserHandle values retain their host rejection semantics.
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
  constructor(sink, stream, host) {
    this.sink = sink;
    this.stream = stream;
    this.host = host;
    this.queue = [];
    this.tail = [];
    this.inflight = undefined;
    this.terminal = false;
    this.firstFailure = undefined;
    this.running = undefined;
    this.pumped = undefined;
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

  // A relinquish point publishes the buffered tail and starts at most one
  // runner without awaiting it, so a slow sink never stalls the drive. Bytes
  // written after that point wait for the next one, not for a sink call to
  // resolve. Pump failures wait for the operation's final flush.
  pump(token) {
    if (this.terminal) return;
    this.seal();
    if (!this.running && this.queue.length) this.running = this.runPump(token);
  }

  // The runner retires in the same step that finds the queue empty, so the
  // next relinquish point either feeds it or starts another one.
  async runPump(token) {
    try {
      do {
        const current = await this.send(token, this.queue.shift());
        if (current) (this.pumped ||= []).push(current);
      } while (this.queue.length && !this.terminal);
    } finally {
      this.running = undefined;
    }
  }

  async flush(token) {
    while (this.running) await this.running;
    const failures = await this.flushQueue(token);
    const pumped = this.pumped;
    this.pumped = undefined;
    if (!pumped) return failures;
    if (failures) pumped.push(...failures);
    return pumped;
  }

  async flushQueue(token) {
    this.seal();
    let failures;
    while (this.queue.length && !this.terminal) {
      const current = await this.send(token, this.queue.shift());
      if (current) (failures ||= []).push(current);
    }
    return failures;
  }

  // One sink call. Its failure is captured for the operation and returned.
  async send(token, entry) {
    let current;
    try {
      if (this.sink) {
        // A separate gate lets disposal detach a forever-pending host sink.
        // The stream then becomes terminal: it can never overlap that call.
        const gate = deferred();
        const cell = {target: gate};
        this.inflight = cell;
        try {
          // A sink is host code: an immediate reverse call from it rejects.
          let result;
          this.host.inHost++;
          try { result = this.sink(entry.bytes); }
          finally { this.host.inHost--; }
          relayPromise(sinkResult(result, this.stream), cell);
          await gate.promise;
        } finally {
          cell.target = undefined;
          this.inflight = undefined;
        }
      }
    } catch (cause) {
      const error = ownFailure(cause, 'DISPOSED') || ownFailure(cause, 'SINK') ? cause :
        failure('SINK', `browser ${this.stream} sink failed`, cause, this.stream);
      current = error === token.interrupted?.error ? token.interrupted : {error};
      captureFailure(token, error, current);
    }
    if (current && current !== token.primaryFault) this.firstFailure ||= current;
    return current;
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
    if (error.code === 'TITAN_BROWSER_DISPOSED' && (this.tail.length || this.queue.length)) {
      this.firstFailure ||= fault || {error};
    }
    this.tail = [];
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
    } catch (cause) {
      const error = ownFailure(cause, 'SINK') ? cause :
        failure('SINK', `browser ${drain.stream} sink failed`, cause, drain.stream);
      const current = {error};
      first ||= current;
      (failures ||= []).push(current);
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

  callTask(args = [], options = {}) {
    const record = wrapperRecords.get(this);
    return record?.owner ? record.owner.callTask(this, args, options) :
      Promise.reject(failure('DISPOSED', 'browser callable is disposed'));
  }

  release() {
    const record = wrapperRecords.get(this);
    record?.owner?.releaseCallable(record);
  }
}

function announceDrain(owner) {
  owner.drainAnnouncement = false;
  if (owner.active || owner.closing || owner.terminal || owner.drainAnnounced ||
      !owner.options?.requestDrain || !owner.queue.some(entry => entry.kind !== 'call')) return;
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

// A call queued during a drive that ended before delivering it runs at the
// next safe point as an ordinary idle call, in queue order.
function runQueuedCall(owner) {
  owner.callsScheduled = false;
  if (owner.active || owner.closing || owner.terminal || owner.inHost) return;
  const index = owner.queue.findIndex(entry => entry.kind === 'call');
  if (index !== -1) owner.runQueued(owner.queue.splice(index, 1)[0]);
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
    this.stateRecords = new Map();
    this.requests = new Set();
    this.drainAnnouncement = false;
    this.drainAnnounced = false;
    this.notificationFailure = undefined;
    // Driver state (titan.browser's drive interface and the call queue).
    this.ownerState = undefined;
    this.drive = undefined;
    this.exited = undefined;
    this.driver = undefined;
    this.inHost = 0;
    this.batch = [];
    this.delivering = undefined;
    this.settling = [];
    this.turnCell = {target: this};
    this.turnScheduled = false;
    this.turnChannel = undefined;
    this.retainOwnerWork = false;
    this.disposalDriven = false;
    this.callsScheduled = false;
    this.out = new OutputChannel(options.stdout, 'stdout', this);
    this.err = new OutputChannel(options.stderr, 'stderr', this);
  }

  // Every application method rejects after exit; a host invocation in flight
  // (binding, listener subscribe, sink) refuses a reverse entry even when idle.
  admission(requireReady = true) {
    if (this.terminal) return this.terminal;
    if (this.exited) return this.exitedError();
    if (this.closing) return failure('DISPOSED', 'browser instance is disposed');
    if (this.active || this.inHost > 0) return failure('REENTRY', reentryMessage);
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
    // Queued calls share the saved failure; a suspended drive never resumes.
    this.failQueuedCalls(error);
    this.drive = undefined;
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
      if (this.drive) throw failure('PROTOCOL', 'browser entry returned during its drive');
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
    const token = {fatal: deferred(), interrupted: undefined, promise: undefined, operation,
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

  // A failed completion stays failed even when its drive latched an exit, as
  // native bootstrap reports a failure that loop() re-raises.
  runResult(result) {
    const kind = result.failed ? 'failed' : this.exited ? 'exited' : 'returned';
    const status = kind === 'exited' ? this.exited.status : result.status;
    return Object.freeze({kind, status, bytes: result.bytes});
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
    const pointer = this.module._malloc(size) >>> 0;
    if (this.terminal) throw this.terminal;
    if (!pointer) throw new RangeError('not enough memory for browser arguments');
    allocations.push(pointer);
    return pointer;
  }

  free(allocations) {
    if (!this.terminal && this.module) {
      for (let index = allocations.length - 1; index >= 0 && !this.terminal; --index) {
        this.module._free(allocations[index]);
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

  releaseCallable(record) {
    if (record.released) return;
    record.released = true;
    record.owner = undefined;
    this.callables.delete(record.key);
    this.queueCallableRelease(record.state, record.slot, record.generation, true);
  }

  queueCallableRelease(state, slot, generation, wrapper = false) {
    if (!slot || !generation) return;
    if (this.states.get(state) !== 'closed' && !this.closing && !this.terminal) {
      this.releases.push({state, slot, generation, wrapper});
      this.scheduleSafePoint();
    }
  }

  async retireCallables() {
    while (this.releases.length && !this.terminal && this.operationId < maximumApplicationOperationId) {
      const release = this.releases.shift();
      if (this.states.get(release.state) === 'closed') continue;
      const result = await this.entry(
        'release_callable', release.state, release.slot, release.generation, release.wrapper ? 1 : 0);
      if (result.failed) throw this.titanError(result);
    }
  }

  async invokeTarget(state, slot, generation, args) {
    const allocations = [], temporary = [];
    try {
      const argv = this.marshalValues(state, args, allocations, temporary);
      const result = await this.entry('invoke', state, slot, generation, args.length, argv);
      if (result.failed) throw this.titanError(result);
      if (result.values.length !== 1) throw failure('PROTOCOL', 'browser invoke must return one value');
      // Box the decoded value inside operate() so an opaque thenable/Promise in a
      // BrowserHandle cannot hold logical admission or disposal open.
      return {value: result.values[0]};
    } finally { this.releaseMarshalled(allocations, temporary); }
  }

  // Frees an invocation's argument buffers and the handle slots Titan never adopted.
  releaseMarshalled(allocations, temporary) {
    this.free(allocations);
    for (const handle of temporary) {
      const entry = this.slots.get(handle.slot);
      if (entry?.generation === handle.generation && entry.temporary) this.releaseSlot(handle.slot, handle.generation);
    }
  }

  // During a drive only a host invocation in flight refuses call and callTask;
  // otherwise they queue for the driver. Idle calls use ordinary admission.
  callAdmission() {
    if (this.drive && !this.terminal && !this.exited && !this.closing && this.inHost === 0) return undefined;
    return this.admission();
  }

  call(value, args) {
    const error = this.callAdmission();
    if (error) return Promise.reject(error);
    let record, copied;
    try {
      record = this.validateCallable(value);
      copied = this.snapshotArguments(record.state, args);
    } catch (cause) { return Promise.reject(cause); }
    const item = {kind: 'call', record, target: record, args: copied, deferred: undefined,
      task: undefined, outcome: undefined, settled: false};
    if (this.drive) return this.queueCall(item);
    this.state = 'active';
    return this.operate('call', () => this.runCall(item)).then(box => box.value);
  }

  async runCall(item) {
    const record = item.record;
    this.validateCallable(record.wrapper);
    const box = await this.invokeTarget(record.state, record.slot, record.generation, item.args);
    // A call whose own entry drove the instance to exit reports the exit.
    if (this.exited) throw this.exitedError();
    return box;
  }

  // A Task-form call runs the callable as an async Task through the spawn
  // callable that async's browser backend registered as `titan:driver`.
  callTask(value, args, options) {
    const error = this.callAdmission();
    if (error) return Promise.reject(error);
    let item;
    try { item = this.taskItem(value, args, options); }
    catch (cause) { return Promise.reject(cause); }
    const signal = item.task.signal;
    if (signal?.aborted) return Promise.reject(this.cancelledError(signal.reason));
    if (this.drive) return this.queueCall(item);
    this.state = 'active';
    return this.operate('callTask', () => this.runTask(item)).then(box => box.value);
  }

  taskItem(value, args, options) {
    if (!Array.isArray(args)) throw new TypeError('browser Task-form arguments must be an array');
    if (options === null || typeof options !== 'object') throw new TypeError('browser Task-form options must be an object');
    const signal = options.signal;
    if (signal !== undefined && (signal === null || typeof signal !== 'object' ||
        typeof signal.addEventListener !== 'function' || typeof signal.removeEventListener !== 'function')) {
      throw new TypeError('browser Task-form signal must be an AbortSignal');
    }
    const record = this.validateCallable(value);
    if (record.state !== this.ownerState) {
      throw failure('STATE', 'browser Task-form calls run only in the instance owner state');
    }
    const spawn = this.driver?.spawn;
    if (!spawn) throw failure('STATE', 'browser image has no async Runtime');
    this.validateCallable(spawn.wrapper);
    const copied = this.snapshotArguments(record.state, args);
    const item = {kind: 'call', record: spawn, target: spawn, args: undefined, deferred: undefined,
      task: {signal, cancel: undefined, cell: undefined, listener: undefined, signalled: false,
        signalReason: undefined, done: false},
      outcome: undefined, settled: false};
    item.args = [{kind: kind.callable, wrapper: record.wrapper},
      {kind: kind.handle, value: this.taskSettled.bind(this, item)}, ...copied];
    return item;
  }

  async runTask(item) {
    try {
      const spawn = item.record;
      this.validateCallable(spawn.wrapper);
      // The spawn entry drives until the Task retires. A failed entry wins
      // over a stored outcome, and a drive that exited reports the exit.
      await this.invokeTarget(spawn.state, spawn.slot, spawn.generation, item.args);
      if (this.exited) throw this.exitedError();
      if (!item.outcome) throw failure('STATE', 'browser Task-form call returned before its Task finished');
      const outcome = this.taskOutcome(item);
      if (outcome.error) throw outcome.error;
      return {value: outcome.value};
    } finally { this.detachTask(item); }
  }

  // The spawn callable's settle protocol: ("started", cancel), then one of
  // ("succeeded", value), ("failed", message, trace) or ("cancelled", reason).
  taskSettled(item, phase, value, extra) {
    const task = item.task;
    if (task.done) return;
    if (phase === 'started') {
      if (!wrapperRecords.has(value)) throw new TypeError('browser Task-form start requires a cancel callable');
      task.cancel = value;
      const signal = task.signal;
      if (!signal || item.settled) return;
      if (signal.aborted) {
        this.abortTask(item);
        return;
      }
      task.cell = {target: {owner: this, item}};
      task.listener = taskAborted.bind(undefined, task.cell);
      signal.addEventListener('abort', task.listener, {once: true});
      return;
    }
    if (phase === 'succeeded') item.outcome = {value};
    else if (phase === 'failed') item.outcome = {error: this.taskFailure(value, extra)};
    else if (phase === 'cancelled') item.outcome = {cancelled: String(value)};
    else throw new TypeError('browser Task-form settlement has an unknown kind');
    task.done = true;
    this.detachTask(item);
  }

  taskFailure(message, trace) {
    if (!isUint8Array(message) || !isUint8Array(trace)) {
      throw new TypeError('browser Task-form failure requires message and trace bytes');
    }
    const error = failure('TITAN', new TextDecoder().decode(message));
    error.bytes = message;
    error.trace = trace;
    error.status = 1;
    return error;
  }

  // The first abort queues one notification of the Task's cancel callable.
  abortTask(item) {
    const task = item.task;
    if (task.signalled || task.done || item.settled || !task.cancel) return;
    task.signalled = true;
    task.signalReason = task.signal.reason;
    try { this.notify(task.cancel, [String(task.signalReason)]); }
    catch { /* An exited or poisoned instance settles the call itself. */ }
  }

  detachTask(item) {
    const task = item.task;
    if (!task) return;
    if (task.listener) task.signal.removeEventListener('abort', task.listener);
    if (task.cell) task.cell.target = undefined;
    task.listener = task.cell = undefined;
    const cancel = task.cancel;
    task.cancel = undefined;
    cancel?.release();
  }

  taskOutcome(item) {
    const outcome = item.outcome;
    if (outcome.cancelled === undefined) return outcome;
    if (this.exited) return {error: this.exitedError()};
    if (this.closing) return {error: failure('DISPOSED', 'browser instance is disposed')};
    const task = item.task;
    const reason = task.signalled && outcome.cancelled === String(task.signalReason) ?
      task.signalReason : outcome.cancelled;
    return {error: this.cancelledError(reason)};
  }

  exitedError() {
    const error = failure('EXITED', 'browser instance has exited');
    error.status = this.exited.status;
    return error;
  }

  cancelledError(reason) {
    const error = failure('CANCELLED', 'browser Task-form call was cancelled');
    error.reason = reason;
    return error;
  }

  queueCall(item) {
    if (item.record.state !== this.ownerState) return Promise.reject(failure('REENTRY', anotherStateMessage));
    if (this.operationId >= maximumApplicationOperationId) {
      return Promise.reject(failure('STATE', 'browser operation identity exhausted'));
    }
    item.deferred = deferred();
    this.queue.push(item);
    this.wakeDriver();
    return item.deferred.promise;
  }

  runQueued(item) {
    this.state = 'active';
    this.operate(item.task ? 'callTask' : 'call', () => item.task ? this.runTask(item) : this.runCall(item))
      .then(box => this.finishCall(item, {value: box.value}), error => this.finishCall(item, {error}));
  }

  // Settle one queued call once; the outcome defaults to its stored result.
  finishCall(item, outcome) {
    if (item.settled) return;
    item.settled = true;
    outcome ||= item.task ? this.taskOutcome(item) : item.outcome;
    this.detachTask(item);
    if (outcome.error) item.deferred.reject(outcome.error);
    else item.deferred.resolve(outcome.value);
    item.record = item.target = item.args = undefined;
  }

  // Relinquish points settle the queued calls whose outcomes arrived.
  settleOutcomes() {
    const waiting = [];
    for (const item of this.settling) {
      if (item.settled) continue;
      if (item.outcome) this.finishCall(item);
      else waiting.push(item);
    }
    this.settling = waiting;
  }

  // Settle every admitted, unsettled queued call: queued, in the current
  // batch, in delivery, or waiting for its outcome.
  settleQueuedCalls(outcomeFor) {
    const items = [...this.queue, ...this.batch].filter(entry => entry.kind === 'call');
    const current = this.delivering?.item;
    if (current?.kind === 'call') items.push(current);
    items.push(...this.settling);
    this.queue = this.queue.filter(entry => entry.kind !== 'call');
    this.batch = this.batch.filter(entry => entry.kind !== 'call');
    this.settling = [];
    for (const item of items) if (!item.settled) this.finishCall(item, outcomeFor(item));
  }

  failQueuedCalls(error) {
    this.settleQueuedCalls(() => ({error}));
  }

  notify(value, args) {
    if (this.closing) return;
    if (this.terminal) throw this.terminal;
    if (this.exited) throw this.exitedError();
    if (this.state === 'created' || this.state === 'failed') throw failure('STATE', stateMessage);
    const record = this.validateCallable(value);
    const copied = this.snapshotArguments(record.state, args);
    const owner = record.state === this.ownerState;
    if (this.drive && !owner) throw failure('REENTRY', anotherStateMessage);
    this.queue.push({kind: 'notify', record, target: record, args: copied});
    if (this.drive) this.wakeDriver();
    else this.scheduleSafePoint();
  }

  drain() {
    const error = this.admission();
    if (error) return Promise.reject(error);
    // Calls left by an ended drive are not notifications: they run on their own.
    const batch = this.queue.filter(entry => entry.kind !== 'call');
    this.queue = this.queue.filter(entry => entry.kind === 'call');
    this.drainAnnounced = false;
    this.state = 'active';
    return this.operate('drain', async () => {
      try {
        for (const notification of batch) {
          try {
            if (this.closing) continue;
            const {record, target, args, request} = notification;
            // Cancellation filters the live queue, not this detached batch.
            // Normally settled one-shots are retired too, but still deliver.
            if (request?.cancelled || record?.released || this.states.get(target.state) === 'closed') continue;
            await this.invokeTarget(target.state, target.slot, target.generation, args);
          } catch (cause) {
            if (this.terminal) throw this.terminal;
            this.reportNotification('callback', 'drain', cause);
          } finally {
            if (notification.request) {
              notification.request.pendingNotifications--;
              this.releaseRequestHolds(notification.request);
            }
            notification.record = notification.target = notification.args = notification.request = undefined;
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
    if (!this.callsScheduled && this.queue.some(entry => entry.kind === 'call')) {
      this.callsScheduled = true;
      queueMicrotask(runQueuedCall.bind(undefined, this));
    }
  }

  registerState(state, record = 0) {
    if (this.states.has(state)) throw failure('PROTOCOL', 'duplicate browser state identity');
    this.states.set(state, 'open');
    if (record) this.stateRecords.set(state, record >>> 0);
  }

  closeState(state) {
    this.states.set(state, 'closed');
    this.stateRecords.delete(state);
    for (const record of this.callables.values()) {
      if (record.state === state) {
        record.released = true;
        record.owner = undefined;
        this.callables.delete(record.key);
      }
    }
    const dropped = [...this.queue, ...this.batch].filter(entry => entry.target.state === state);
    this.queue = this.queue.filter(entry => entry.target.state !== state);
    this.batch = this.batch.filter(entry => entry.target.state !== state);
    const closed = failure('HANDLE', 'browser callable belongs to a closed state');
    for (const entry of dropped) if (entry.kind === 'call') this.finishCall(entry, {error: closed});
    if (state === this.ownerState) this.driver = undefined;
    this.releases = this.releases.filter(entry => entry.state !== state);
    for (const request of this.requests) {
      if (request.state === state) {
        request.holdsReleased = true;
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

  newSlot(state, value, kind = 'value', temporary = false) {
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
    this.slots.set(slot, {value, state, generation, kind, units: 1, temporary});
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

  registerCallable(state, slot, generation) {
    // Re-exporting a callable cancels any queued, undelivered wrapper release,
    // while preserving any queued request-hold drops for the same pin.
    const index = this.releases.findIndex(entry =>
      entry.wrapper && entry.state === state && entry.slot === slot && entry.generation === generation);
    if (index !== -1) this.releases.splice(index, 1);
    const key = `${state}:${slot}:${generation}`;
    if (this.callables.has(key)) return 0;
    const record = {owner: this, state, slot, generation, released: false, exposed: false, key};
    const wrapper = Object.freeze(new CallableView());
    wrapperRecords.set(wrapper, record);
    record.wrapper = wrapper;
    this.callables.set(key, record);
    return 1;
  }

  invalidateCallable(state, slot, generation) {
    const key = `${state}:${slot}:${generation}`;
    const record = this.callables.get(key);
    if (!record) return 1;
    if (record.exposed) return 0;
    record.released = true;
    record.owner = undefined;
    this.callables.delete(key);
    return 1;
  }

  callableRecordAt(state, slot, generation) {
    const record = this.callables.get(`${state}:${slot}:${generation}`);
    if (!record) throw failure('HANDLE', 'browser callable is released');
    this.validateCallable(record.wrapper, state);
    return record;
  }

  snapshotFailureArguments(message, cause) {
    return [
      {kind: kind.string, bytes: message},
      {kind: kind.handle, value: cause},
    ];
  }

  snapshotArguments(state, args) {
    return args.map(value => {
      if (value === null || value === undefined) return {kind: kind.nil};
      if (typeof value === 'boolean') return {kind: kind.boolean, value};
      if (typeof value === 'bigint') {
        if (value < -(1n << 63n) || value >= 1n << 63n) {
          throw new TypeError('browser integer argument must be a signed i64 BigInt');
        }
        return {kind: kind.integer, value};
      }
      if (typeof value === 'number') return {kind: kind.float, value};
      if (typeof value === 'string') return {kind: kind.string, bytes: encodeString(value)};
      if (isUint8Array(value)) return {kind: kind.bytes, bytes: copiedBytes(value)};
      if (wrapperRecords.has(value)) {
        this.validateCallable(value, state);
        return {kind: kind.callable, wrapper: value};
      }
      return {kind: kind.handle, value};
    });
  }

  writeValue(address, state, item, allocations, handles, temporary = false) {
    const type = item.kind;
    let bytes, length = 0, handle;
    if (type === kind.string || type === kind.bytes) {
      if (this.terminal) throw this.terminal;
      length = item.bytes.length;
      if (length > 0xffffffff) throw new TypeError('browser byte result has an invalid length or capacity');
      bytes = this.allocate(length, allocations);
      if (length) this.module.HEAPU8.set(item.bytes, bytes);
    } else if (type === kind.handle) {
      handle = this.newSlot(state, item.value, 'value', temporary);
      handles.push(handle);
    } else if (type === kind.callable) {
      handle = this.validateCallable(item.wrapper, state);
    }
    if (this.terminal) throw this.terminal;
    const view = this.heapView(address, valueSize);
    view.setUint32(0, type, true);
    view.setUint32(4, state, true);
    if (type === kind.boolean) view.setBigInt64(8, item.value ? 1n : 0n, true);
    else if (type === kind.integer) view.setBigInt64(8, item.value, true);
    else if (type === kind.float) view.setFloat64(8, item.value, true);
    else if (type === kind.string || type === kind.bytes) {
      view.setBigInt64(8, BigInt(length), true);
      view.setUint32(16, bytes, true);
      view.setUint32(20, length, true);
    } else if (handle) {
      view.setUint32(24, handle.slot, true);
      view.setUint32(28, handle.generation, true);
    }
  }

  marshalValues(state, args, allocations, temporary) {
    const pointer = this.allocate(args.length * valueSize, allocations);
    if (args.length) this.module.HEAPU8.fill(0, pointer, pointer + args.length * valueSize);
    for (let index = 0; index < args.length; ++index) {
      this.writeValue(pointer + index * valueSize, state, args[index], allocations, temporary, true);
    }
    return pointer;
  }

  valuesAt(pointer, count, state) {
    const view = this.heapView(pointer, count * valueSize);
    const values = [], callables = [];
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
        case kind.string: {
          const bytes = this.bytesAt(view.getUint32(address + 16, true), view.getUint32(address + 20, true));
          values.push(utf8Decoder.decode(bytes));
          break;
        }
        case kind.bytes:
          values.push(this.bytesAt(view.getUint32(address + 16, true), view.getUint32(address + 20, true)));
          break;
        case kind.handle:
        case kind.callable: {
          const ownerState = view.getUint32(address + 4, true);
          if (state !== undefined && ownerState !== state) throw failure('HANDLE', 'browser argument belongs to another state');
          const slot = view.getUint32(address + 24, true), generation = view.getUint32(address + 28, true);
          if (type === kind.handle) {
            values.push(this.getSlot(ownerState, slot, generation).value);
          } else {
            const record = this.callableRecordAt(ownerState, slot, generation);
            callables.push(record);
            values.push(record.wrapper);
          }
          break;
        }
        default: throw failure('PROTOCOL', 'browser value has an invalid kind');
      }
    }
    for (const record of callables) record.exposed = true;
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
    this.complete(this.completionAt(view, id, operation));
  }

  // Copies a completion's values, message and raw trace while C still owns them.
  completionAt(view, id, operation) {
    const status = view.getUint32(12, true);
    const values = status === 0 ? this.valuesAt(view.getUint32(24, true), view.getUint32(20, true)) : [];
    return {id, kind: operation, failed: status !== 0,
      status: view.getInt32(16, true),
      bytes: this.bytesAt(view.getUint32(28, true), view.getUint32(32, true)),
      trace: this.bytesAt(view.getUint32(36, true), view.getUint32(40, true)),
      values};
  }

  setOwnerState(state) {
    if (this.ownerState !== undefined && this.ownerState !== state) {
      this.poison(failure('PROTOCOL', 'browser instance reported a second owner state'));
      return;
    }
    this.ownerState = state;
  }

  // The `titan:driver` binding: only the owner state's Runtime serves
  // Task-form calls and disposal; other states' registrations are ignored.
  registerDriver(state, spawn, shutdown) {
    if (state !== this.ownerState) return;
    this.driver = {spawn: this.validateCallable(spawn, state), shutdown: this.validateCallable(shutdown, state)};
  }

  driveBegin(state) {
    if (this.terminal) return;
    if (state !== this.ownerState || !this.active || this.drive) {
      this.poison(failure('PROTOCOL', 'browser drive began outside an owner operation'));
      return;
    }
    this.drive = {state, gate: undefined, disposalSignalled: false};
    if (this.closing) this.disposalDriven = true;
  }

  driveEnd(state, status, exited) {
    if (this.terminal) return;
    if (this.drive?.state !== state || this.delivering) {
      this.poison(failure('PROTOCOL', 'browser drive ended outside its drive'));
      return;
    }
    this.drive = undefined;
    if (this.batch.length) {
      this.queue.unshift(...this.batch);
      this.batch = [];
    }
    if (exited) {
      this.exited = Object.freeze({status});
      // A Task-form call that joined the drive, and a call it never
      // delivered, report the exit; a delivered call keeps its result.
      const error = this.exitedError();
      this.settleQueuedCalls(item => !item.task && item.outcome ? item.outcome : {error});
      return;
    }
    this.settleOutcomes();
    for (const item of this.settling) {
      this.finishCall(item, {error: failure('STATE', 'browser drive ended before the Task-form call finished')});
    }
    this.settling = [];
  }

  wakeDriver(state = this.drive?.state) {
    if (this.drive && state === this.drive.state) this.scheduleTurn();
  }

  // One macrotask per relinquish point or coalesced wake: setImmediate where
  // the host has it (Node), otherwise one MessageChannel per instance.
  scheduleTurn() {
    if (this.turnScheduled || this.terminal) return;
    this.turnScheduled = true;
    if (typeof setImmediate === 'function') {
      setImmediate(turnFired, this.turnCell);
      return;
    }
    if (!this.turnChannel) {
      this.turnChannel = new MessageChannel();
      this.turnChannel.port1.onmessage = turnFired.bind(undefined, this.turnCell);
    }
    this.turnChannel.port2.postMessage(undefined);
  }

  turnFired() {
    this.turnScheduled = false;
    const drive = this.drive, gate = drive?.gate;
    if (!gate) return;
    drive.gate = undefined;
    gate.resolve(this.closing ? relinquishStatus.disposing : relinquishStatus.resumed);
  }

  relinquish(state, mode) {
    const drive = this.drive;
    if (this.terminal) return new Promise(() => {});
    if (drive?.state !== state || drive.gate || this.delivering) {
      this.poison(failure('PROTOCOL', 'browser relinquish outside its drive'));
      return new Promise(() => {});
    }
    // A relinquish point: queued calls settle now; output waits for a gate.
    this.settleOutcomes();
    // Disposal is signalled once, after one macrotask, before idle detection.
    if (this.closing && !drive.disposalSignalled) {
      drive.disposalSignalled = true;
      return this.parkDrive(drive, true);
    }
    if (mode === 0 || this.queue.some(entry => entry.target.state === state)) return this.parkDrive(drive, true);
    if (!this.hasWakeSources()) return relinquishStatus.idle;
    return this.parkDrive(drive, false);
  }

  // A parked gate is the drive's output safe point: the pump runs on a
  // microtask once the drive has suspended, never inside this import, and
  // only while that gate is still parked. A numeric IDLE parks nothing and
  // starts no sink, even if the drive then switches coroutines.
  parkDrive(drive, turn) {
    const gate = deferred();
    drive.gate = gate;
    if (turn) this.scheduleTurn();
    if (!this.closing) queueMicrotask(() => this.pumpStreams(gate));
    return gate.promise;
  }

  pumpStreams(gate) {
    const token = this.active;
    if (this.drive?.gate !== gate || !token || token.interrupted || this.closing || this.terminal) return;
    this.out.pump(token);
    this.err.pump(token);
  }

  // A later JS call is not a wake source: only queued owner work, an open
  // owner request or listener, or an already scheduled wake.
  hasWakeSources() {
    const owner = this.ownerState;
    if (this.turnScheduled || this.queue.some(entry => entry.target.state === owner)) return true;
    for (const request of this.requests) if (request.state === owner) return true;
    return false;
  }

  operationName() {
    return this.active?.operation ?? 'drive';
  }

  requireDelivery(state) {
    if (this.drive?.state === state && !this.delivering) return true;
    this.poison(failure('PROTOCOL', 'browser delivery outside its drive'));
    return false;
  }

  // The owner's items queued now form the turn's batch, in FIFO order.
  batchItems(state) {
    if (this.terminal || !this.requireDelivery(state)) return 0;
    const keep = [];
    for (const entry of this.queue) (entry.target.state === state ? this.batch : keep).push(entry);
    this.queue = keep;
    return this.batch.length;
  }

  nextItem(state, pointer) {
    if (this.terminal || !this.requireDelivery(state)) return 0;
    while (this.batch.length) {
      const item = this.batch.shift();
      if (item.settled) continue;
      const {record, target, request} = item;
      // Released targets retire undelivered and cancelled requests drop their
      // events; a settled one-shot still delivers, as in drain().
      if (request?.cancelled || record?.released || this.states.get(target.state) === 'closed') {
        if (item.kind === 'call') {
          this.finishCall(item, {error: failure('HANDLE', 'browser callable is foreign, released, or belongs to a closed state')});
        } else this.finishNotification(item);
        continue;
      }
      const allocations = [], temporary = [];
      let argv;
      try {
        if (this.operationId >= maximumApplicationOperationId) throw failure('STATE', 'browser operation identity exhausted');
        argv = this.marshalValues(target.state, item.args, allocations, temporary);
      } catch (cause) {
        if (this.terminal) return 0;
        this.releaseMarshalled(allocations, temporary);
        if (item.kind === 'call') this.finishCall(item, {error: cause});
        else {
          this.reportNotification('callback', this.operationName(), cause);
          this.finishNotification(item);
        }
        continue;
      }
      const id = ++this.operationId;
      this.delivering = {id, item, allocations, temporary, settled: false};
      const view = this.heapView(pointer, deliverySize);
      view.setBigUint64(0, id, true);
      view.setUint32(8, item.kind === 'call' ? deliveryKind.call : deliveryKind.notify, true);
      view.setUint32(12, target.slot, true);
      view.setUint32(16, target.generation, true);
      view.setUint32(20, item.args.length, true);
      view.setUint32(24, argv, true);
      view.setUint32(28, 0, true);
      return 1;
    }
    return 0;
  }

  finishNotification(item) {
    const request = item.request;
    if (request) {
      request.pendingNotifications--;
      this.releaseRequestHolds(request);
    }
    item.record = item.target = item.args = item.request = undefined;
  }

  settleQueued(pointer) {
    if (this.terminal) return;
    const view = this.heapView(pointer, 48);
    const id = view.getBigUint64(0, true), operation = view.getUint32(8, true);
    const delivering = this.delivering;
    if (!delivering || delivering.id !== id || delivering.settled || operation !== operationKinds.invoke) {
      this.poison(failure('PROTOCOL', 'browser delivery reported a duplicate or mismatched settlement'));
      return;
    }
    delivering.settled = true;
    const record = this.completionAt(view, id, operation);
    const item = delivering.item;
    if (item.kind !== 'call') {
      // A notification's value is discarded; its failure has no caller.
      if (record.failed) this.reportNotification('callback', this.operationName(), this.titanError(record));
      return;
    }
    if (item.settled) return;
    if (record.failed) item.outcome = {error: this.titanError(record)};
    else if (record.values.length !== 1) {
      this.poison(failure('PROTOCOL', 'browser invoke must return one value'));
      return;
    } else if (!item.task) item.outcome = {value: record.values[0]};
    this.settling.push(item);
  }

  itemDone(state, id) {
    const delivering = this.delivering;
    if (this.terminal) {
      this.delivering = undefined;
      return;
    }
    if (delivering?.id !== id || this.drive?.state !== state) {
      this.poison(failure('PROTOCOL', 'browser delivery finished an unknown item'));
      return;
    }
    this.delivering = undefined;
    this.releaseMarshalled(delivering.allocations, delivering.temporary);
    if (!delivering.settled) {
      this.poison(failure('PROTOCOL', 'browser delivery returned without settlement'));
      return;
    }
    if (delivering.item.kind !== 'call') this.finishNotification(delivering.item);
  }

  // Deferred physical releases of the driving state, applied between turns.
  nextRelease(state, pointer) {
    if (this.terminal || !this.requireDelivery(state)) return 0;
    const index = this.releases.findIndex(entry => entry.state === state);
    if (index === -1) return 0;
    const [release] = this.releases.splice(index, 1);
    const view = this.heapView(pointer, deliverySize);
    view.setBigUint64(0, 0n, true);
    view.setUint32(8, deliveryKind.release, true);
    view.setUint32(12, release.slot, true);
    view.setUint32(16, release.generation, true);
    view.setUint32(20, 0, true);
    view.setUint32(24, 0, true);
    view.setUint32(28, release.wrapper ? 1 : 0, true);
    return 1;
  }

  openState(record = 0) {
    this.nextState = (this.nextState ?? 0) + 1;
    if (this.nextState > 0xffffffff) throw failure('STATE', 'browser state identity exhausted');
    this.registerState(this.nextState, record >>> 0);
    return this.nextState;
  }

  stateRecord(state) {
    if (this.terminal || !state || this.states.get(state) === 'closed') return 0;
    return this.stateRecords.get(state) ?? 0;
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
    // Reserved `titan:` names resolve only to SDK sources, never to user bindings.
    if (name.startsWith('titan:')) {
      const source = sdkBindings[name];
      if (!source) throw new Error(`unknown browser binding ${name}`);
      return {kind: kind.handle, value: source(this, state), state};
    }
    const bindings = this.options.bindings;
    if (!bindings || !Object.hasOwn(bindings, name)) throw new Error(`unknown browser binding ${name}`);
    return {kind: kind.handle, value: bindings[name], state};
  }

  // A binding, listener subscription, cancel or sink runs as host code: an
  // immediate reverse entry from it rejects with REENTRY.
  hostInvoke(target, thisValue, args) {
    this.inHost++;
    try { return Reflect.apply(target, thisValue, args); }
    finally { this.inHost--; }
  }

  hostCall(state, slot, generation, count, pointer) {
    const target = this.getSlot(state, slot, generation).value;
    if (typeof target !== 'function') throw new TypeError('browser binding is not callable');
    const args = this.valuesAt(pointer, count, state);
    return {value: this.hostInvoke(target, undefined, args), state};
  }

  newRequest(state, successSlot, successGeneration, failureSlot, failureGeneration) {
    if (!state || !successSlot || !successGeneration || !failureSlot || !failureGeneration ||
        !this.states.has(state) || this.states.get(state) === 'closed') {
      throw failure('HANDLE', 'browser callable is foreign, released, or belongs to a closed state');
    }
    if (this.closing || this.states.get(state) !== 'open') {
      throw failure('DISPOSED', 'browser state is closing');
    }
    const request = {state,
      success: {state, slot: successSlot, generation: successGeneration},
      rejected: {state, slot: failureSlot, generation: failureGeneration},
      kind: 'starting', cancelled: false, cancelSignalled: false, retired: false,
      holdsReleased: false, pendingNotifications: 0,
      cancel: undefined, terminal: deferred(), cell: undefined};
    request.cell = {target: {owner: this, request}};
    // Reserve the native owner before host acceptance or output publication.
    request.identity = this.newSlot(state, request, 'request');
    this.requests.add(request);
    return request;
  }

  releaseRequestHolds(request) {
    if (request.holdsReleased || !request.retired || request.pendingNotifications > 0) return;
    request.holdsReleased = true;
    if (request.success) this.queueCallableRelease(request.state, request.success.slot, request.success.generation);
    if (request.rejected) this.queueCallableRelease(request.state, request.rejected.slot, request.rejected.generation);
    request.success = request.rejected = undefined;
  }

  abortRequest(request) {
    request.holdsReleased = true;
    this.retireRequest(request, true);
    this.releaseSlot(request.identity.slot, request.identity.generation);
  }

  dropQueuedRequest(request) {
    this.queue = this.queue.filter(entry => entry.request !== request || (--request.pendingNotifications, false));
  }

  startRequest(request, target, args, listener) {
    try {
      const form = this.hostInvoke(target, undefined, args);
      const ownership = form?.kind;
      if (!form || listener && ownership !== 'listener' ||
          !listener && !['detachable', 'retained'].includes(ownership)) {
        throw new TypeError('browser host request must declare its ownership form');
      }
      if (listener) {
        const subscribe = form.subscribe;
        if (typeof subscribe !== 'function') throw new TypeError('browser listener requires subscribe(emit)');
        const unregister = this.hostInvoke(subscribe, form, [listenerEvent.bind(undefined, request.cell)]);
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
      this.abortRequest(request);
      throw cause;
    }
    // Disposal may have been requested by the binding/subscribe import. Its
    // starting owner cannot retire until the ownership form is fully installed.
    // Cancellation failure never retires an accepted retained host operation.
    if (request.cancelled || this.closing) {
      try { this.cancelRequest(request); }
      catch (cause) {
        if (this.closing) this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause);
        request.holdsReleased = true;
        this.releaseSlot(request.identity.slot, request.identity.generation);
        throw cause;
      }
    }
    return request;
  }

  // While disposal's cleanup drive is active or pending, the owner state's
  // settlements keep flowing so Task cleanup can await work started earlier.
  emitRequest(request, args, rejected = false) {
    if (request.retired || request.cancelled || this.terminal) return;
    const owner = request.state === this.ownerState;
    if (this.closing && !(owner && this.retainOwnerWork)) return;
    const target = rejected ? request.rejected : request.success;
    if (!target || this.states.get(request.state) !== 'open') return;
    try {
      const copied = rejected ? this.snapshotFailureArguments(args[0], args[1]) :
        this.snapshotArguments(request.state, args);
      request.pendingNotifications++;
      this.queue.push({kind: 'notify', target, args: copied, request});
      if (owner && this.drive) this.wakeDriver();
      else this.scheduleSafePoint();
    } catch (cause) {
      if (!rejected) this.emitRequest(request, [messageBytes(cause), cause], true);
      else this.reportNotification('callback', 'notify', cause);
    }
  }

  settleRequest(request, success, value) {
    if (request.retired) return;
    if (!request.cancelled && !this.terminal) {
      if (success) this.emitRequest(request, [value]);
      else this.emitRequest(request, [messageBytes(value), value], true);
    }
    this.retireRequest(request);
  }

  retireRequest(request, discard = false) {
    if (request.retired) return;
    request.retired = true;
    request.cell.target = undefined;
    if (discard) this.dropQueuedRequest(request);
    request.terminal.resolve();
    this.requests.delete(request);
    request.cancel = undefined;
    this.releaseRequestHolds(request);
  }

  cancelRequest(request) {
    if (request.retired) return;
    request.cancelled = true;
    if (request.kind === 'starting') return;
    let error;
    if (!request.cancelSignalled) {
      request.cancelSignalled = true;
      try { if (request.cancel) this.hostInvoke(request.cancel, undefined, []); }
      catch (cause) { error = cause; }
      request.cancel = undefined;
    }
    if (request.kind !== 'retained') this.retireRequest(request, true);
    else this.dropQueuedRequest(request);
    if (error) throw error;
  }

  hostStart(state, slot, generation, count, pointer, successSlot, successGeneration,
      failureSlot, failureGeneration, listener) {
    const target = this.getSlot(state, slot, generation).value;
    if (typeof target !== 'function') throw new TypeError('browser request binding is not callable');
    const request = this.newRequest(state, successSlot, successGeneration, failureSlot, failureGeneration);
    let args;
    try { args = this.valuesAt(pointer, count, state); }
    catch (cause) { this.abortRequest(request); throw cause; }
    this.startRequest(request, target, args, listener);
    return {kind: kind.request, value: request};
  }

  hostCancel(state, slot, generation) {
    const request = this.getSlot(state, slot, generation, 'request').value;
    this.cancelRequest(request);
    return {kind: kind.nil, value: undefined};
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
        view.setUint32(0, responseStatus.jsError, true);
        view.setUint32(40, address, true);
        view.setUint32(44, message.length, true);
        view.setUint32(48, thrown.slot, true);
        view.setUint32(52, thrown.generation, true);
      } catch {
        if (this.terminal) throw this.terminal;
        const view = this.heapView(pointer, 56);
        view.setUint32(0, thrown ? responseStatus.jsError : responseStatus.memory, true);
        if (thrown) {
          view.setUint32(48, thrown.slot, true);
          view.setUint32(52, thrown.generation, true);
        }
      }
    } finally {
      if (!this.terminal) this.heapView(pointer, 56).setUint32(4, state, true);
    }
  }

  writeResponseValue(pointer, state, explicitKind, value, allocations, handles) {
    if (explicitKind === undefined) {
      const [item] = this.snapshotArguments(state, [value]);
      this.writeValue(pointer, state, item, allocations, handles);
      return;
    }
    let handle;
    if (explicitKind === kind.handle) {
      if (wrapperRecords.has(value)) this.validateCallable(value, state);
      handle = this.newSlot(state, value);
      handles.push(handle);
    } else if (explicitKind === kind.request) {
      handle = value.identity;
      this.getSlot(state, handle.slot, handle.generation, 'request');
      handles.push(handle);
    } else if (explicitKind !== kind.nil) {
      throw new TypeError('unsupported browser binding result kind');
    }
    const view = this.heapView(pointer, valueSize);
    view.setUint32(0, explicitKind, true);
    view.setUint32(4, state, true);
    if (handle) {
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
    // Close-admission: queued application calls reject (an already captured
    // failure stays primary) and application notifications drop. With a
    // Runtime to clean up, the owner state's request events keep flowing and
    // request cancellation waits until that cleanup drive ends.
    this.retainOwnerWork = !this.terminal && !this.exited &&
      (this.drive !== undefined || this.driver !== undefined);
    this.disposalDriven = this.drive !== undefined;
    this.settleQueuedCalls(item => item.outcome?.error ? {error: item.outcome.error} : {error});
    this.queue = this.dropNotifications(this.queue);
    this.batch = this.dropNotifications(this.batch);
    if (!this.retainOwnerWork) this.cancelRequests();
    // A parked drive resumes with the one-shot disposal signal.
    if (this.drive?.gate) {
      this.drive.disposalSignalled = true;
      this.scheduleTurn();
    }
    // The final drain's continuation is module-scoped, not an instance method.
    disposal.resolve(retireOwner(this).then(finishDisposal));
    return this.disposed;
  }

  // Keeps the owner state's request events while its cleanup drive needs them.
  dropNotifications(entries) {
    const kept = [];
    for (const entry of entries) {
      const request = entry.request;
      if (request && this.retainOwnerWork && request.state === this.ownerState) kept.push(entry);
      else if (request) {
        request.pendingNotifications = 0;
        request.holdsReleased = true;
      }
    }
    return kept;
  }

  cancelRequests() {
    for (const request of this.requests) {
      request.holdsReleased = true;
      try { this.cancelRequest(request); }
      catch (cause) { this.retirementFailure ||= failure('HOST', 'browser host cancellation failed', cause); }
    }
  }
}

async function retireOwner(owner) {
  let interruptedFailure;
  if (owner.active) {
    const token = owner.active;
    try { await token.promise; }
    catch { /* The interrupted operation reports its own failure. */ }
    if (token.failed && token.primaryFault && token.primaryFault !== token.interrupted) {
      interruptedFailure = token.primaryFault;
    }
  }
  // Cleanup: with no drive since disposal began, async's shutdown callable
  // cancels the Runtime's Tasks and drives until they retire. An exited
  // instance has no Runtime left to clean up.
  let cleanupError;
  const shutdown = owner.driver?.shutdown;
  if (shutdown && owner.module && !owner.terminal && !owner.exited && !owner.disposalDriven) {
    try {
      await owner.operate('dispose', async () => {
        await owner.invokeTarget(shutdown.state, shutdown.slot, shutdown.generation, []);
      }, true);
    } catch (cause) { cleanupError = cause; }
  }
  // Final disposal: the deferred request cancellation, then retirement.
  owner.retainOwnerWork = false;
  owner.queue = owner.dropNotifications(owner.queue);
  owner.batch = owner.dropNotifications(owner.batch);
  owner.cancelRequests();
  await Promise.all([...owner.requests].map(request => request.terminal.promise));
  let error = owner.retirementFailure;
  if (cleanupError && !owner.terminal) {
    if (error) owner.reportNotification('cleanup', 'dispose', error);
    error = cleanupError;
  }
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
  const disposal = {drains, failure: error ? {error} : interruptedFailure,
    observer: owner.options?.onNotificationError};
  owner.lastTrace = owner.trace();
  owner.module = owner.backend = owner.factory = owner.options = undefined;
  owner.pending = undefined;
  owner.queue = owner.releases = owner.freeSlots = [];
  owner.batch = [];
  owner.settling = [];
  owner.drive = owner.driver = owner.delivering = undefined;
  // Pending turn macrotasks keep only the detached cell.
  owner.turnCell.target = undefined;
  if (owner.turnChannel) {
    owner.turnChannel.port1.onmessage = null;
    owner.turnChannel.port1.close();
    owner.turnChannel.port2.close();
    owner.turnChannel = undefined;
  }
  owner.slots.clear();
  owner.stateRecords.clear();
  owner.callables.clear();
  owner.requests.clear();
  owner.state = 'disposed';
  return disposal;
}

/** Create one persistent instance; the image supplies its private factory. */
export function create(factory, options = {}) {
  if (typeof factory !== 'function') throw new TypeError('browser factory must be a function');
  for (const name of ['stdout', 'stderr', 'locateFile', 'onNotificationError', 'requestDrain', 'onEngineFailure']) {
    if (options[name] !== undefined && typeof options[name] !== 'function') {
      throw new TypeError(`browser ${name} must be a function`);
    }
  }
  if (options.requireTrace !== undefined && typeof options.requireTrace !== 'boolean') {
    throw new TypeError('browser requireTrace must be a boolean');
  }
  if (options.bindings !== undefined && (options.bindings === null ||
      typeof options.bindings !== 'object')) throw new TypeError('browser bindings must be an object');
  for (const name of Object.keys(options.bindings ?? {})) {
    if (name.startsWith('titan:')) throw new TypeError(`browser binding name ${name} is reserved for the Titan SDK`);
  }
  const owner = new BrowserOwner(factory, {...options});
  return Object.freeze({
    initialize: () => owner.initialize(),
    run: (args = []) => owner.run(args),
    call: (callable, ...args) => owner.call(callable, args),
    callTask: (callable, args = [], options = {}) => owner.callTask(callable, args, options),
    notify: (callable, ...args) => owner.notify(callable, args),
    drain: () => owner.drain(),
    dispose: () => owner.dispose(),
    get trace() { return owner.trace(); },
  });
}
