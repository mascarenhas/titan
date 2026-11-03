const reentryMessage = 'browser instance is suspended; reentry is not allowed';
const stateMessage = 'browser instance has already run or is disposed';

function failure(code, message, cause, stream) {
  const error = new Error(message, cause === undefined ? undefined : {cause});
  error.name = 'TitanBrowserError';
  error.code = `TITAN_BROWSER_${code}`;
  if (stream !== undefined) error.stream = stream;
  return error;
}

function channel(sink, stream, fail) {
  let bytes = new Uint8Array(1024);
  let length = 0;
  let broken = false;
  return {
    byte(byte) {
      if (byte === null || byte === undefined || broken) return;
      try {
        if (length === bytes.length) {
          const grown = new Uint8Array(bytes.length * 2);
          grown.set(bytes);
          bytes = grown;
        }
        bytes[length++] = byte;
      } catch (cause) {
        broken = true;
        fail(failure('PROTOCOL', `cannot buffer browser ${stream}`, cause));
      }
    },
    deliver() {
      if (!length || broken) return;
      const chunk = bytes.slice(0, length);
      length = 0;
      if (!sink) return;
      try {
        const result = sink(chunk);
        if (result !== undefined) {
          // Promise sinks are not supported, but their eventual rejection must
          // still be observed. Promise.resolve also contains throwing getters.
          Promise.resolve(result).catch(() => {});
          broken = true;
          fail(failure('SINK', `browser ${stream} sink must return undefined`, undefined, stream));
        }
      } catch (cause) {
        broken = true;
        fail(failure('SINK', `browser ${stream} sink failed`, cause, stream));
      }
    },
    clear() {
      sink = undefined;
      bytes = new Uint8Array(0);
      length = 0;
      broken = true;
    },
  };
}

/** Instantiate one generated factory; one Titan run is admitted per instance. */
export function create(factory, {stdout, stderr, locateFile} = {}) {
  if (typeof factory !== 'function') throw new TypeError('browser factory must be a function');
  for (const [name, sink] of [['stdout', stdout], ['stderr', stderr]]) {
    if (sink !== undefined && typeof sink !== 'function') {
      throw new TypeError(`browser ${name} sink must be a function`);
    }
  }

  let module;
  let bridge;
  let options;
  let initialized;
  let disposed;
  let closed = false;
  let admitted = false;
  let active = false;
  let called = false;
  let callFulfilled = false;
  let settled = false;
  let fatal = false;
  let abortSeen = false;
  let originalTrap;
  let terminal;
  let completion;
  let allocations = [];
  let resolveRun;
  let rejectRun;
  let resolveQuiet;
  const quiet = new Promise(resolve => { resolveQuiet = resolve; });

  function fail(error, isFatal = false) {
    if (!terminal) terminal = error;
    fatal ||= isFatal;
    if (bridge) bridge.terminalFailure = terminal;
    if (fatal && active && !settled) finish();
  }

  let out = channel(stdout, 'stdout', fail);
  let err = channel(stderr, 'stderr', fail);
  // Only the channels retain caller callbacks. Disposal clears those owners.
  stdout = stderr = undefined;

  function freeArguments() {
    if (module && !fatal) {
      const owned = allocations;
      allocations = [];
      for (const pointer of owned) module._free(pointer);
    } else {
      allocations = [];
    }
  }

  function finish() {
    if (settled || !active) return;
    // Fatal Wasm is not a cleanup entrypoint. An intact admitted continuation
    // must instead reach completion and leave every compiled frame first.
    if (!fatal) {
      if (!called && !terminal) return;
      if (called && (!completion || bridge?.suspensionPending || !bridge?.safe())) return;
    }
    try {
      freeArguments();
    } catch (cause) {
      fatal = true;
      terminal ||= failure(abortSeen ? 'ABORT' : 'TRAP',
        cause instanceof Error ? cause.message : String(cause), cause);
    }
    active = false;
    settled = true;
    resolveQuiet();
    const resolve = resolveRun;
    const reject = rejectRun;
    resolveRun = rejectRun = undefined;
    if (terminal) reject(terminal);
    else resolve(completion);
  }

  function engineFailure(cause) {
    const code = originalTrap || (!abortSeen && cause instanceof WebAssembly.RuntimeError)
      ? 'TRAP' : abortSeen ? 'ABORT' : 'PROTOCOL';
    const original = originalTrap || cause;
    const message = original instanceof Error ? original.message : String(original);
    fail(failure(code, message, original), true);
  }

  function safePoint(pending) {
    if (!bridge?.safe() || fatal) return;
    out.deliver();
    err.deliver();
    // An export's queued safe point can beat ccall's rejection handler.
    // Only fulfillment proves that an acknowledgement is missing.
    if (callFulfilled && !completion && !pending) {
      fail(failure('PROTOCOL', 'browser entry returned without completion or suspension'), true);
    }
    finish();
  }

  function initialize() {
    if (initialized) return initialized;
    if (closed) return Promise.reject(failure('STATE', stateMessage));
    options = {
      stdin: () => null,
      stdout: byte => out?.byte(byte),
      stderr: byte => err?.byte(byte),
      onAbort: cause => {
        abortSeen = true;
        const original = originalTrap || cause;
        const error = failure(originalTrap ? 'TRAP' : 'ABORT',
          original instanceof Error ? original.message : String(original), original);
        const late = settled;
        fail(error, true);
        // Direct API users, like the runner, can monitor late engine failures.
        // Before settlement the arbiter consumes the abort instead.
        if (late) throw error;
      },
      titanBrowserAttach: state => {
        state.blocked = closed;
        state.terminalFailure = terminal;
        if (!closed || active) bridge = state;
      },
      titanBrowserSafePoint: safePoint,
      titanBrowserTrap: cause => {
        originalTrap ||= cause;
        engineFailure(cause);
      },
      titanBrowserComplete: (kind, status, bytes, count) => {
        let protocol;
        if (count !== 1) {
          protocol = failure('PROTOCOL', 'browser entry completed more than once');
        } else if (kind !== 0 && kind !== 1) {
          protocol = failure('PROTOCOL', `browser entry reported invalid completion kind ${kind}`);
          // A malformed completion is still terminal, not a suspended run.
          completion = {kind: 'failed', status: 1, bytes: new Uint8Array(0)};
        } else {
          completion = {kind: kind === 0 ? 'returned' : 'failed', status: status | 0, bytes};
        }
        if (protocol) {
          fail(protocol);
          if (settled) throw protocol;
        }
      },
    };
    if (locateFile !== undefined) options.locateFile = locateFile;
    const instantiate = factory;
    const incoming = options;
    initialized = Promise.resolve().then(() => instantiate(incoming)).then(value => {
      if (fatal) throw terminal;
      if (closed && !active) {
        drop();
        return;
      }
      module = value;
      if (!bridge || typeof module?.ccall !== 'function' ||
          !(module.HEAPU8 instanceof Uint8Array)) {
        throw failure('PROTOCOL', 'browser image does not provide Titan channels');
      }
    }).catch(cause => {
      if (!terminal) engineFailure(cause);
      if (active && !settled) {
        fatal = true;
        finish();
      }
      throw terminal;
    });
    return initialized;
  }

  function marshal(args) {
    if (!Array.isArray(args)) throw new TypeError('browser arguments must be an array');
    const encoded = args.map(arg => {
      if (typeof arg === 'string') return new TextEncoder().encode(arg);
      if (arg instanceof Uint8Array) return arg.slice();
      throw new TypeError('browser arguments must be strings or Uint8Array values');
    });
    function allocate(size) {
      if (!size) return 0;
      const pointer = module._malloc(size) >>> 0;
      if (!pointer) throw new RangeError('not enough memory for browser arguments');
      allocations.push(pointer);
      return pointer;
    }
    const pointers = [];
    for (const bytes of encoded) {
      const pointer = allocate(bytes.length);
      // Every malloc may grow memory. Read the exported heap again afterwards.
      if (bytes.length) module.HEAPU8.set(bytes, pointer);
      pointers.push(pointer);
    }
    const argv = allocate(encoded.length * 4);
    const lengths = allocate(encoded.length * 4);
    const heap = module.HEAPU8;
    const view = new DataView(heap.buffer, heap.byteOffset, heap.byteLength);
    for (let index = 0; index < encoded.length; ++index) {
      view.setUint32(argv + index * 4, pointers[index], true);
      view.setUint32(lengths + index * 4, encoded[index].length, true);
    }
    return [encoded.length, argv, lengths];
  }

  function run(args = []) {
    if (closed) return Promise.reject(failure('STATE', stateMessage));
    if (active) return Promise.reject(failure('REENTRY', reentryMessage));
    if (admitted || terminal) return Promise.reject(failure('STATE', stateMessage));
    admitted = active = true;
    const result = new Promise((resolve, reject) => {
      resolveRun = resolve;
      rejectRun = reject;
    });
    initialize().then(() => {
      if (settled) return;
      if (closed) {
        fail(failure('STATE', stateMessage), true);
        return;
      }
      const argv = marshal(args);
      called = true;
      // Numeric arguments only: ccall's temporary stack string/array conversion
      // cannot own byte argv across suspension or a large argument allocation.
      const call = module.ccall('titan_browser_entry', 'number',
        ['number', 'number', 'number'], argv, {async: true});
      // The call's value is admission, never Titan's status. Some fiber-last
      // paths do not settle this internal Promise: completion + actual stack
      // quiescence own settlement and disposal, not Emscripten keepalive state.
      Promise.resolve(call).then(() => {
        callFulfilled = true;
        safePoint(bridge?.suspensionPending);
      }, cause => {
        engineFailure(cause);
      });
    }).catch(cause => {
      if (!called && !fatal) {
        fail(cause);
        finish();
      } else {
        engineFailure(cause);
      }
    });
    return result;
  }

  function drop() {
    if (bridge) bridge.blocked = true;
    module = bridge = options = undefined;
    factory = locateFile = undefined;
    out?.clear();
    err?.clear();
    out = err = undefined;
  }

  function dispose() {
    if (disposed) return disposed;
    closed = true;
    if (bridge) bridge.blocked = true;
    disposed = (async () => {
      if (active && !fatal) await quiet;
      // A late factory can finish without re-rooting its Module. Observe its
      // rejection, but disposal of an unstarted instance need not wait for it.
      initialized?.catch(() => {});
      freeArguments();
      drop();
    })();
    return disposed;
  }

  return Object.freeze({initialize, run, dispose});
}
