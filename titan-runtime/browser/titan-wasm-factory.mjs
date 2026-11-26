// Titan's Wasm host for browser images. It instantiates an image's `.wasm`
// with the WASI, coroutine, bridge, calendar and trace imports it links, owns
// the JSPI continuations of its C stacks, and loads its trace table. The loader
// (titan-browser.mjs) is its only caller; a linked image module embeds both.
// Wasm ABI: titan/browser.h, minicoro.h, browser/titan-browser-trace.h.
// Implementation notes: doc/implementation/browser-bridge.md

// The two words of the cookie at each coroutine stack's low end.
const cookieLow = 0x02135467, cookieHigh = 0x89bacdfe;
// State-entering exports and their operation kinds; C-only helpers stay raw.
const promisedEntries = [['titan_browser_initialize', 1], ['titan_browser_entry', 2],
  ['titan_browser_invoke', 3], ['titan_browser_close', 5], ['titan_browser_gate_guarded', 3]];
const requiredExports = ['memory', '_initialize', '__indirect_function_table', '__stack_pointer',
  '__stack_low', '__stack_high', '__set_stack_limits', 'malloc', 'free', 'titan_browser_trace_identity'];
const errno = Object.freeze({badf: 8, inval: 28, nosys: 52, spipe: 70});
const daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const nodeFs = globalThis.process?.getBuiltinModule?.('node:fs');

function browserError(code, message) {
  const error = new Error(message);
  error.name = 'TitanBrowserError';
  error.code = 'TITAN_BROWSER_' + code;
  return error;
}

// One instance's linear memory and exports: the loader's module, and the
// context handed to an embedder's `imports` function before instantiation.
class ImageContext {
  #u8 = new Uint8Array(0);
  #u32 = new Uint32Array(0);

  constructor(bridge) {
    this.bridge = bridge;
    this.memory = this.table = this.exports = this.trace = undefined;
  }

  get HEAPU8() {
    if (this.#u8.buffer !== this.memory.buffer) this.#u8 = new Uint8Array(this.memory.buffer);
    return this.#u8;
  }

  get HEAPU32() {
    if (this.#u32.buffer !== this.memory.buffer) this.#u32 = new Uint32Array(this.memory.buffer);
    return this.#u32;
  }

  readCString(pointer) {
    const heap = this.HEAPU8, end = heap.indexOf(0, pointer);
    return decoder.decode(heap.subarray(pointer, end < 0 ? heap.length : end));
  }

  readBytes(pointer, length) { return this.HEAPU8.slice(pointer, pointer + length); }

  writeBytes(pointer, bytes) { this.HEAPU8.set(bytes, pointer); }

  // A fatal abort: the instance is poisoned and the Wasm caller unwinds.
  abort(message) {
    this.bridge.abortEngine(message);
    throw new WebAssembly.RuntimeError(`Aborted(${message})`);
  }
}

// The JSPI owner of the instance: every promised entry, the linear C stack of
// each minicoro context, and the engine continuation parked on it.
class Continuations {
  constructor(bridge, image) {
    this.bridge = bridge;
    this.image = image;
    this.wasm = undefined;
    this.engineEntry = undefined;
    this.owner = false;
    this.entered = false;
    this.current = 0;
    this.contexts = new Map([[0, {id: 0, started: true, gate: null, back: null}]]);
    this.retired = new Error('Titan coroutine continuation retired');
    this.pending = null;
    this.terminalFailure = null;
    this.blocked = false;
    this.poisoned = false;
    this.queued = false;
    // Synchronous C callbacks running now: the one engine stack below them
    // cannot suspend, whichever Lua state they entered.
    this.callbackDepth = 0;
    this.high = 0;
    this.low = 0;
  }

  imports() {
    return {
      titan_mco_create: (id, low, high) => this.create(id >>> 0, low >>> 0, high >>> 0),
      titan_mco_transfer: new WebAssembly.Suspending((from, fromBack, to, toBack, terminal) =>
        this.transfer(from >>> 0, fromBack, to >>> 0, toBack, terminal)),
      titan_mco_destroy: new WebAssembly.Suspending(id => this.destroy(id >>> 0)),
      titan_browser_relinquish: new WebAssembly.Suspending((state, mode) => this.relinquish(state, mode)),
      titan_browser_entry_allowed: (id, kind) => this.admit(BigInt.asUintN(64, id), kind),
      titan_browser_host_callback: (_state, delta) => this.callback(delta | 0),
      // titan_no_switch's import: true while any synchronous callback runs.
      titan_browser_in_callback: () => this.callbackDepth > 0 ? 1 : 0,
    };
  }

  safe() {
    return !this.owner;
  }

  schedule() {
    if (this.queued) return;
    this.queued = true;
    queueMicrotask(() => {
      this.queued = false;
      if (this.safe()) this.bridge.scheduleSafePoint();
    });
  }

  // The owner outlives every internal transfer microtask, including a GC
  // finalizer's abandoned-stack unwind. call must invoke a promising export.
  enter(call, id, kind) {
    if (this.owner) {
      return Promise.reject(browserError('REENTRY', 'browser instance is active; reentry is not allowed'));
    }
    if (this.blocked || this.poisoned) {
      return Promise.reject(this.terminalFailure || browserError('DISPOSED', 'browser instance is disposed'));
    }
    this.owner = true;
    this.entered = false;
    this.pending = {id, kind, completed: false};
    let result;
    try {
      result = call();
    } catch (cause) {
      result = Promise.reject(cause);
    }
    return Promise.resolve(result).catch(cause => {
      this.poison(cause);
      if (cause instanceof WebAssembly.RuntimeError) this.bridge.trapEngine(cause);
      throw cause;
    }).finally(() => {
      this.owner = false;
      this.pending = null;
      this.schedule();
    });
  }

  admit(id, kind) {
    const pending = this.pending;
    if (!this.owner || this.entered || !pending || id === 0n || pending.id !== id ||
        pending.kind !== kind) return 0;
    this.entered = true;
    return 1;
  }

  poison(cause) {
    this.terminalFailure ||= cause;
    this.blocked = true;
    this.poisoned = true;
    // Fatal engine failure is not a Titan unwind. Reject engine gates so
    // their invocations retire, but never call into C to recycle allocations.
    for (const context of this.contexts.values()) {
      context.gate?.reject(cause);
      context.gate = null;
    }
    this.bridge.poison(cause);
  }

  // titan_browser_host_callback: the loader admits a callback unless the
  // instance is closing, exited or poisoned.
  callback(delta) {
    if (delta < 0) {
      if (this.callbackDepth > 0) this.callbackDepth--;
      return 1;
    }
    if (this.poisoned || !this.bridge.callbackAdmit()) return 0;
    if (this.callbackDepth++ === 0) queueMicrotask(() => this.callbacksLeft());
    return 1;
  }

  // No microtask runs while a synchronous callback is on the stack, so a
  // depth still above zero here means a callback ended by an exception (an
  // engine SuspendError, a JavaScript exception) that unwound its C frames
  // without the leave, leaving the Lua state it ran on inconsistent.
  callbacksLeft() {
    if (this.callbackDepth === 0 || this.poisoned) return;
    this.poison(browserError('PROTOCOL', 'a synchronous C callback ended by an exception'));
  }

  // A stack switch below a JavaScript frame cannot suspend: outside a
  // promising entry, or inside a synchronous callback. V8 throws its
  // SuspendError before calling the import (callbacksLeft then poisons); an
  // engine that calls it first gets this named failure, thrown to the
  // callback's JavaScript caller.
  switchRefused() {
    return !this.owner || this.callbackDepth > 0;
  }

  refuseSwitch() {
    this.poison(browserError('PROTOCOL',
      'Titan stack switch outside a promising entry or inside a synchronous callback'));
    throw this.terminalFailure;
  }

  // The current C stack bounds, for the --stack-check prologues and cookies.
  bound(high, low) {
    this.high = high;
    this.low = low;
    this.wasm.__set_stack_limits(high, low);
  }

  // A cookie at each coroutine stack's low end catches an overflow the
  // prologue checks missed. Under --stack-first the main stack ends at
  // address 0, below which an overflow already traps; never write there.
  writeCookie() {
    if (this.low === 0) return;
    const words = this.image.HEAPU32;
    words[this.low >>> 2] = cookieLow;
    words[(this.low >>> 2) + 1] = cookieHigh;
  }

  checkCookie() {
    if (this.low === 0) return;
    const words = this.image.HEAPU32;
    if (words[this.low >>> 2] !== cookieLow || words[(this.low >>> 2) + 1] !== cookieHigh) {
      this.image.abort(`Stack overflow! Stack cookie has been overwritten at 0x${this.low.toString(16)}`);
    }
  }

  save(context) {
    this.checkCookie();
    context.sp = this.wasm.__stack_pointer.value >>> 0;
    context.low = this.low;
    context.high = this.high;
  }

  // Bounds before the stack pointer, so no check runs against stale ones.
  restore(context) {
    this.bound(context.high, context.low);
    this.wasm.__stack_pointer.value = context.sp;
    this.current = context.id;
    if (context.started) this.checkCookie();
    else this.writeCookie();
  }

  create(id, low, high) {
    if (this.contexts.has(id)) throw new Error('duplicate Titan coroutine context');
    this.contexts.set(id, {id, low, high, sp: high, started: false,
      finished: false, gate: null, back: null, terminal: null, lifetime: null, retiring: false});
  }

  context(id) {
    const context = this.contexts.get(id);
    if (!context) throw new Error('unknown Titan coroutine context');
    return context;
  }

  park(context) {
    if (context.gate) throw new Error('Titan coroutine context is already parked');
    const promise = new Promise((resolve, reject) => { context.gate = {resolve, reject}; });
    // Both successful wakes and retirement exceptions restore the linear
    // stack/bounds before the engine resumes the suspended Wasm activation.
    return promise.then(value => {
      this.restore(context);
      return value;
    }, cause => {
      this.restore(context);
      throw cause;
    });
  }

  activate(context) {
    // Defer first entry too: do not recursively nest JS import frames or
    // execute a destination before the source import has actually suspended.
    queueMicrotask(() => {
      if (this.poisoned) return;
      try {
        if (context.started) {
          const gate = context.gate;
          if (!gate || context.retiring) throw new Error('Titan coroutine destination is not parked');
          context.gate = null;
          gate.resolve();
          return;
        }
        this.restore(context);
        context.started = true;
        context.lifetime = Promise.resolve(this.engineEntry(context.id)).then(() => {
          context.finished = true;
          if (!context.terminal) throw new Error('Titan coroutine returned without terminal handoff');
          this.activate(context.terminal);
        }, cause => {
          context.finished = true;
          if (context.retiring && cause === this.retired) return;
          throw cause;
        }).catch(cause => { this.poison(cause); });
      } catch (cause) {
        this.poison(cause);
      }
    });
  }

  transfer(from, fromBack, to, toBack, terminal) {
    if (this.switchRefused()) this.refuseSwitch();
    const source = this.context(this.current);
    const fromContext = this.context(from);
    const toContext = this.context(to);
    if (fromBack) fromContext.back = source;
    else if (source !== fromContext) throw new Error('Titan coroutine transfer source is not current');
    const destination = toBack ? toContext.back : toContext;
    if (!destination) throw new Error('Titan coroutine transfer has no BACK continuation');
    if (toBack) toContext.back = null;
    this.save(source);
    if (terminal) {
      // Do not wake the resumer yet. _mco_main must return all the way out of
      // its promising export before that resumer may free the native stack.
      source.terminal = destination;
      return;
    }
    const parked = this.park(source);
    this.activate(destination);
    return parked;
  }

  destroy(id) {
    const context = this.context(id);
    if (!context.started || context.finished) {
      this.contexts.delete(id);
      return;
    }
    // Retiring a parked context suspends; dead and never-started ones above
    // are destroyed at once, which a synchronous callback may do.
    if (this.switchRefused()) this.refuseSwitch();
    if (!context.gate || context.retiring) throw new Error('cannot retire a running Titan coroutine');
    const caller = this.context(this.current);
    this.save(caller);
    context.retiring = true;
    const gate = context.gate;
    context.gate = null;
    gate.reject(this.retired);
    return context.lifetime.then(() => {
      this.restore(caller);
      if (this.poisoned) throw this.terminalFailure;
      this.contexts.delete(id);
    });
  }

  // The driver's suspending import. It is legal only on the main context of
  // the promised entry that holds the owner; the loader then decides
  // whether the drive suspends (a promise) or reports IDLE (a number).
  // A poisoned drive never resumes: disposal drops its suspended stack.
  relinquish(state, mode) {
    if (this.switchRefused()) this.refuseSwitch();
    if (this.current !== 0) {
      this.poison(browserError('PROTOCOL',
        'Titan stack switch outside a promising entry or inside a synchronous callback'));
      return new Promise(() => {});
    }
    try {
      return this.bridge.relinquish(state >>> 0, mode >>> 0);
    } catch (cause) {
      this.poison(cause);
      return new Promise(() => {});
    }
  }
}

// titan/browser.h's host imports. Each forwards to the loader's owner of the
// capability; a broken protocol poisons the instance instead of throwing.
function bridgeImports(bridge) {
  const trusted = (method, ...args) => {
    try { return bridge[method](...args); }
    catch (cause) {
      try { bridge.poison(cause); } catch { /* The first failure stands. */ }
      return 0;
    }
  };
  const respond = (response, state, call) => bridge.importResponse(response >>> 0, state >>> 0, call);
  return {
    titan_browser_complete: pointer => trusted('receiveCompletion', pointer >>> 0),
    titan_browser_host_state_open: record => trusted('openState', record >>> 0),
    titan_browser_host_state_record: state => trusted('stateRecord', state >>> 0),
    titan_browser_host_state_closing: state => trusted('markStateClosing', state >>> 0),
    titan_browser_host_state_closed: state => trusted('closeState', state >>> 0),
    titan_browser_host_callable: (state, slot, generation) =>
      trusted('registerCallable', state >>> 0, slot >>> 0, generation >>> 0),
    titan_browser_host_callable_closed: (state, slot, generation) =>
      trusted('invalidateCallable', state >>> 0, slot >>> 0, generation >>> 0),
    titan_browser_host_release: (state, slot, generation) =>
      trusted('releaseOwnedSlot', state >>> 0, slot >>> 0, generation >>> 0),
    titan_browser_host_adopt: (state, slot, generation) =>
      trusted('adoptSlot', state >>> 0, slot >>> 0, generation >>> 0),
    titan_browser_host_retain: (state, slot, generation) =>
      trusted('retainSlot', state >>> 0, slot >>> 0, generation >>> 0),
    // Stale identities are ordinary protected errors, not completion corruption.
    titan_browser_host_identity_live: (state, slot, generation, kind) =>
      bridge.identityLive(state >>> 0, slot >>> 0, generation >>> 0, kind >>> 0),
    titan_browser_host_binding: (state, name, length, response) =>
      respond(response, state, () => bridge.binding(name >>> 0, length >>> 0, state >>> 0)),
    titan_browser_host_call: (state, slot, generation, argc, args, response) =>
      respond(response, state, () => bridge.hostCall(
        state >>> 0, slot >>> 0, generation >>> 0, argc >>> 0, args >>> 0)),
    titan_browser_host_start: (state, slot, generation, argc, args, successSlot, successGeneration,
        failureSlot, failureGeneration, mode, response) =>
      respond(response, state, () => bridge.hostStart(
        state >>> 0, slot >>> 0, generation >>> 0, argc >>> 0, args >>> 0,
        successSlot >>> 0, successGeneration >>> 0, failureSlot >>> 0, failureGeneration >>> 0, mode !== 0)),
    titan_browser_host_cancel: (state, slot, generation, response) =>
      respond(response, state, () => bridge.hostCancel(state >>> 0, slot >>> 0, generation >>> 0)),
    titan_browser_host_owner: state => trusted('setOwnerState', state >>> 0),
    titan_browser_host_drive_begin: state => trusted('driveBegin', state >>> 0),
    titan_browser_host_drive_end: (_state, status, exited) => trusted('driveEnd', status | 0, exited !== 0),
    titan_browser_host_main_failed: (state, message, length, trace, traceLength) =>
      trusted('mainFailed', state >>> 0, message >>> 0, length >>> 0, trace >>> 0, traceLength >>> 0),
    titan_browser_host_wake: state => trusted('wakeDriver', state >>> 0),
    titan_browser_host_batch: state => trusted('batchItems', state >>> 0),
    titan_browser_host_item: (_state, out) => trusted('nextItem', out >>> 0),
    titan_browser_host_item_done: (state, id) => trusted('itemDone', state >>> 0, BigInt.asUintN(64, id)),
    titan_browser_host_settle: record => trusted('settleQueued', record >>> 0),
  };
}

// Minutes west of UTC on 1 January and 1 July of date's local year.
function seasons(date) {
  const january = new Date(0), july = new Date(0);
  january.setFullYear(date.getFullYear(), 0, 1);
  july.setFullYear(date.getFullYear(), 6, 1);
  return [january.getTimezoneOffset(), july.getTimezoneOffset()];
}

// Fill wasi-libc's struct tm (int fields at word offsets 0..9) with date's
// host-local calendar; the launcher names the zone from __tm_gmtoff.
function fillTm(words, tm, date) {
  const [winter, summer] = seasons(date), offset = date.getTimezoneOffset();
  const year = date.getFullYear(), month = date.getMonth();
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const yday = daysBeforeMonth[month] + date.getDate() - 1 + (leap && month > 1 ? 1 : 0);
  const dst = winter !== summer && offset === Math.min(winter, summer);
  words.set([date.getSeconds(), date.getMinutes(), date.getHours(), date.getDate(), month,
    year - 1900, date.getDay(), yday, dst ? 1 : 0, -offset * 60], tm >>> 2);
}

// wasi-libc knows only UTC; the launcher's localtime and mktime ask the host.
function calendarImports(context) {
  return {
    titan_browser_localtime(seconds, tm) {
      const date = new Date(Number(seconds) * 1000);
      if (Number.isNaN(date.getTime())) return 0;
      fillTm(context.HEAPU32, tm, date);
      return 1;
    },
    titan_browser_mktime(tm) {
      const words = context.HEAPU32, at = tm >>> 2, field = index => words[at + index] | 0;
      const date = new Date(0);
      date.setFullYear(field(5) + 1900, field(4), field(3));
      date.setHours(field(2), field(1), field(0), 0);
      // A nonnegative tm_isdst picks the offset of the hour a fall-back
      // transition repeats.
      const isdst = field(8), [winter, summer] = seasons(date);
      const daylight = Math.min(winter, summer), offset = date.getTimezoneOffset();
      if (isdst >= 0 && (isdst > 0) !== (winter !== summer && offset === daylight)) {
        const wanted = isdst > 0 ? daylight : Math.max(winter, summer);
        date.setTime(date.getTime() + (wanted - offset) * 60000);
      }
      if (Number.isNaN(date.getTime())) return -1n;
      fillTm(words, tm, date);
      return BigInt(date.getTime() / 1000);
    },
  };
}

/**
 * The image's wasi_snapshot_preview1 imports. `bridge.output(stream, pointer,
 * length)` copies standard output (1) and error (2), `bridge.options.env`
 * lists `NAME=value` entries, `views` supplies HEAPU8 and HEAPU32, and
 * `onAbort(message)` reports a fatal exit and throws. A browser image has no
 * preopened directories, so wasi-libc fails every path call before it gets
 * here; descriptors 0 to 2 are character streams that are not terminals.
 */
export function createWasiImports(bridge, views, onAbort) {
  const standard = fd => fd >>> 0 <= 2;
  const nosys = () => errno.nosys;
  const environment = () => bridge.options.env.map(entry => encoder.encode(`${entry}\0`));
  return {
    clock_time_get(id, _precision, out) {
      let now;
      if (id === 0) now = BigInt(Date.now()) * 1000000n;
      else if (id >>> 0 <= 3) now = BigInt(Math.round(performance.now() * 1e6));
      else return errno.inval;
      const words = views.HEAPU32;
      words[out >>> 2] = Number(now & 0xffffffffn);
      words[(out >>> 2) + 1] = Number(now >> 32n);
      return 0;
    },
    environ_get(pointers, buffer) {
      let at = buffer >>> 0;
      for (const [index, entry] of environment().entries()) {
        views.HEAPU32[(pointers >>> 2) + index] = at;
        views.HEAPU8.set(entry, at);
        at += entry.length;
      }
      return 0;
    },
    environ_sizes_get(count, size) {
      const entries = environment(), words = views.HEAPU32;
      words[count >>> 2] = entries.length;
      words[size >>> 2] = entries.reduce((total, entry) => total + entry.length, 0);
      return 0;
    },
    fd_close: fd => standard(fd) ? 0 : errno.badf,
    // An unknown file type keeps isatty false, so stdout stays fully buffered.
    fd_fdstat_get(fd, stat) {
      if (!standard(fd)) return errno.badf;
      views.HEAPU8.fill(0, stat >>> 0, (stat >>> 0) + 24);
      return 0;
    },
    fd_fdstat_set_flags: nosys,
    fd_prestat_dir_name: () => errno.badf,
    fd_prestat_get: () => errno.badf,
    fd_read: nosys,
    fd_renumber: nosys,
    fd_seek: fd => standard(fd) ? errno.spipe : errno.badf,
    fd_write(fd, iovs, count, written) {
      if (fd !== 1 && fd !== 2) return errno.badf;
      let total = 0;
      for (let index = 0; index < count; index++) {
        const words = views.HEAPU32, at = (iovs >>> 2) + 2 * index, length = words[at + 1];
        if (length) bridge.output(fd, words[at], length);
        total += length;
      }
      views.HEAPU32[written >>> 2] = total;
      return 0;
    },
    path_open: nosys,
    path_remove_directory: nosys,
    path_rename: nosys,
    path_unlink_file: nosys,
    proc_exit: code => onAbort(`exit(${code})`),
    random_get(buffer, length) {
      const heap = views.HEAPU8;
      // getRandomValues fills at most 65536 bytes per call.
      for (let at = 0; at < length; at += 65536) {
        crypto.getRandomValues(heap.subarray(buffer + at, buffer + Math.min(length, at + 65536)));
      }
      return 0;
    },
  };
}

// C's bounded copy of a string: whole UTF-8 code points and a terminator.
function writeCString(views, text, pointer, size) {
  if (!size) return;
  const heap = views.HEAPU8;
  const {written} = encoder.encodeInto(text, heap.subarray(pointer, pointer + size - 1));
  heap[pointer + written] = 0;
}

/**
 * The trace adapter of browser/titan-browser-trace.h over `views` (HEAPU8,
 * HEAPU32): it parses engine stack text into Wasm PC records and symbolizes
 * them through the image's `.wasm.trace` table, with no capture-time I/O or
 * Wasm allocation.
 */
export function createTrace(views) {
  const u32 = value => Number.isInteger(value) && value >= 0 && value <= 0xffffffff;
  const upper = (array, value) => {
    let lo = 0, hi = array.length;
    while (lo < hi) {
      const mid = lo + Math.floor((hi - lo) / 2);
      if (array[mid] <= value) lo = mid + 1;
      else hi = mid;
    }
    return lo - 1;
  };
  // Survey330: V8, SpiderMonkey, then cold/warm JSC.
  const patterns = [
    /^\s*at .*?wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)\)?\s*$/,
    /^.*?@.*?wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)\s*$/,
    /^.*?@.*?wasm-function\[(\d+)\]\s*$/,
  ];
  const trace = {
    index: null,

    // The compiler validates the map and writes `<stem>.wasm.trace`; this
    // checks only what the bytes could get wrong: the header, the image, the
    // counts and every index. Layout: doc/implementation/browser-target.md#the-trace-table
    readTable(data, identity) {
      const invalid = () => new Error('invalid trace table');
      if (data.byteOffset % 4) data = new Uint8Array(data);
      if (data.byteLength < 92) throw invalid();
      const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
      const word = at => view.getUint32(at, true);
      if (String.fromCharCode(data[0], data[1], data[2], data[3]) !== 'TTRC' || word(4) !== 1) throw invalid();
      if (String.fromCharCode.apply(null, data.subarray(8, 72)) !== identity) {
        throw new Error('trace table image does not match');
      }
      const imports = word(72), count = word(76), rows = word(80), bases = word(84), text = word(88);
      const strings = bases + imports + count + 1;
      if (92 + 4 * (2 * count + 2 * rows + strings) + 2 * (rows + count) + text !== data.byteLength) throw invalid();
      let at = data.byteOffset + 92;
      const array = (Type, length) => {
        const result = new Type(data.buffer, at, length);
        at += result.byteLength;
        return result;
      };
      const gaps = array(Uint32Array, count), lengths = array(Uint32Array, count);
      const pcDeltas = array(Uint32Array, rows), lineDeltas = array(Uint32Array, rows);
      const offsets = array(Uint32Array, strings), sources = array(Int16Array, rows), first = array(Int16Array, count);
      const bytes = array(Uint8Array, text);
      const starts = new Uint32Array(count), ends = new Uint32Array(count);
      let end = 0;
      for (let i = 0; i < count; ++i) {
        const start = end + gaps[i];
        end = start + lengths[i];
        if (!lengths[i] || end > 0xffffffff || first[i] < -1 || first[i] >= bases) throw invalid();
        starts[i] = start; ends[i] = end;
      }
      const pcs = new Uint32Array(rows), lines = new Uint32Array(rows);
      let pc = 0, line = 0;
      for (let r = 0; r < rows; ++r) {
        pc += pcDeltas[r];
        line = (line + lineDeltas[r]) >>> 0;
        // Rows strictly ascend, and a `.titan` row names a line.
        if (pc > 0xffffffff || (r > 0 && !pcDeltas[r]) || sources[r] < -1 || sources[r] >= bases ||
            (sources[r] >= 0 && line === 0)) throw invalid();
        pcs[r] = pc; lines[r] = line;
      }
      if (offsets[0] !== 0 || offsets[strings - 1] !== text) throw invalid();
      for (let s = 1; s < strings; ++s) if (offsets[s] < offsets[s - 1]) throw invalid();
      const string = index => decoder.decode(bytes.subarray(offsets[index], offsets[index + 1]));
      const names = [];
      for (let b = 0; b < bases; ++b) names.push(string(b));
      return {pcs, sources, lines, starts, ends, first, imports, count: imports + count, bases: names,
        // Decoded on demand: only traced frames need their function names.
        name: index => string(bases + index),
        bytes: data.byteLength + pcs.byteLength + lines.byteLength + starts.byteLength + ends.byteLength};
    },

    lookup(pc, index, flags) {
      const map = trace.index;
      let body = -1, known = -1;
      if ((flags & 2) && u32(index) && index < map.count) known = index;
      if ((flags & 1) && u32(pc)) {
        body = upper(map.starts, pc);
        if (body < 0 || pc >= map.ends[body]) body = -1;
      }
      if (known < 0 && body >= 0 && !(flags & 2)) known = map.imports + body;
      const declared = known - map.imports;
      let base = declared >= 0 && declared < map.first.length && map.first[declared] >= 0
        ? map.bases[map.first[declared]] : '?';
      const symbol = known >= 0 ? map.name(known) || '?' : '?';
      let line = 0;
      if (body >= 0 && (!(flags & 2) || index === map.imports + body)) {
        const segment = upper(map.pcs, pc);
        // Only a `.titan` row locates the frame. A PC in a gap, such as C
        // inlined into the body, keeps the declaring basename and no line.
        if (segment >= 0 && map.pcs[segment] >= map.starts[body] &&
            map.pcs[segment] < map.ends[body] && map.sources[segment] >= 0) {
          base = map.bases[map.sources[segment]]; line = map.lines[segment];
        }
      }
      return {base, symbol, line};
    },

    parse(stack, capacity, limit) {
      if (typeof stack !== 'string') throw 'stack is not text';
      const records = [];
      let frames = 0, engine = -1, truncated = false;
      const v8 = /^[ \t]*at[ \t]/m.test(stack);
      for (const text of stack.split('\n')) {
        if (!text.trim()) continue;
        const frame = v8 ? /^[ \t]*at[ \t]/.test(text) : text.includes('@');
        if (!frame) continue; // Count frame shapes, never V8's Error title.
        let kind;
        for (kind = 0; kind < patterns.length; ++kind) {
          const match = patterns[kind].exec(text);
          if (!match) continue;
          if (engine < 0) engine = kind;
          const index = Number(match[1]), pc = match[2] === undefined ? 0 : Number.parseInt(match[2], 16);
          if (!u32(index) || !u32(pc)) throw 'invalid Wasm frame';
          if (records.length < capacity) records.push([pc, index, match[2] === undefined ? 2 : 3]);
          else truncated = true;
          break;
        }
        // SpiderMonkey prefixes saved JS parents with an arbitrary async cause
        // and '*'. Match before '@', after recognizing Wasm: image names may
        // themselves contain '*'. Saved parents are not active ancestry.
        if (engine === 1 && kind === patterns.length && /^[^@]+\*[^@]*@/.test(text)) break;
        ++frames;
      }
      // Firefox still caps synchronous capture at 128 frames. Current JSC does
      // not have the historical 100-frame ceiling; use its effective limit.
      const ceiling = engine === 1 ? 128 : Infinity;
      if (frames >= Math.min(limit, ceiling)) truncated = true;
      return {records, truncated};
    },

    capture(out, capacity) {
      try {
        const words = views.HEAPU32;
        words[out >>> 2] = 0; words[(out + 4) >>> 2] = 0;
        if (!trace.index) return 1;
        // C owns the record capacity. Validate its declared storage against the
        // current heap, rather than duplicating the private header's constant.
        if (!u32(capacity) || capacity === 0 ||
            capacity > Math.floor((words.byteLength - (out >>> 0) - 8) / 12)) return 2;
        let limitDescriptor, prepareDescriptor, changedLimit = false, changedPrepare = false;
        let failed = false, stack, limit = capacity + 128;
        try {
          limitDescriptor = Object.getOwnPropertyDescriptor(Error, 'stackTraceLimit');
          prepareDescriptor = Object.getOwnPropertyDescriptor(Error, 'prepareStackTrace');
          if (limitDescriptor && 'value' in limitDescriptor && Number.isFinite(limitDescriptor.value) && limitDescriptor.value > limit) limit = limitDescriptor.value;
          if (!limitDescriptor || limitDescriptor.configurable) {
            Object.defineProperty(Error, 'stackTraceLimit', {value: limit, writable: true, enumerable: false, configurable: true});
            changedLimit = true;
          } else if ('value' in limitDescriptor && limitDescriptor.writable) {
            Object.defineProperty(Error, 'stackTraceLimit', {value: limit}); changedLimit = true;
          } else {
            limit = limitDescriptor && 'value' in limitDescriptor && Number.isFinite(limitDescriptor.value)
              ? Math.max(0, limitDescriptor.value) : Infinity;
          }
          if (prepareDescriptor && (!('value' in prepareDescriptor) ||
              (!prepareDescriptor.configurable && !prepareDescriptor.writable && prepareDescriptor.value !== undefined))) {
            throw 'unsafe prepareStackTrace descriptor';
          }
          if (!prepareDescriptor || prepareDescriptor.configurable) {
            Object.defineProperty(Error, 'prepareStackTrace', {value: undefined, writable: true, enumerable: false, configurable: true});
            changedPrepare = true;
          } else if (prepareDescriptor.writable) {
            Object.defineProperty(Error, 'prepareStackTrace', {value: undefined}); changedPrepare = true;
          }
          stack = new Error().stack; // Exactly one construction and one read.
        } catch { failed = true; }
        finally {
          try {
            if (changedPrepare) {
              if (prepareDescriptor) Object.defineProperty(Error, 'prepareStackTrace', prepareDescriptor);
              else if (!delete Error.prepareStackTrace) failed = true;
            }
          } catch { failed = true; }
          try {
            if (changedLimit) {
              if (limitDescriptor) Object.defineProperty(Error, 'stackTraceLimit', limitDescriptor);
              else if (!delete Error.stackTraceLimit) failed = true;
            }
          } catch { failed = true; }
        }
        if (failed) return 2;
        const parsed = trace.parse(stack, capacity, limit);
        const records = views.HEAPU32;
        for (let i = 0; i < parsed.records.length; ++i) {
          const address = (out + 8 + i * 12) >>> 2, record = parsed.records[i];
          records[address] = record[0]; records[address + 1] = record[1]; records[address + 2] = record[2];
        }
        records[(out + 4) >>> 2] = parsed.truncated ? 1 : 0;
        records[out >>> 2] = parsed.records.length;
        return 0;
      } catch {
        try { const words = views.HEAPU32; words[out >>> 2] = 0; words[(out + 4) >>> 2] = 0; } catch { /* Report only the failure. */ }
        return 2;
      }
    },

    symbolize(record, base, baseBytes, symbol, symbolBytes, line) {
      try {
        views.HEAPU32[line >>> 2] = 0;
        writeCString(views, '?', base, baseBytes);
        writeCString(views, '?', symbol, symbolBytes);
        if (!trace.index) return 0;
        const words = views.HEAPU32, at = record >>> 2;
        const found = trace.lookup(words[at], words[at + 1], words[at + 2]);
        writeCString(views, found.base, base, baseBytes);
        writeCString(views, found.symbol, symbol, symbolBytes);
        views.HEAPU32[line >>> 2] = found.line;
        return found.line ? 1 : 0;
      } catch {
        try {
          views.HEAPU32[line >>> 2] = 0;
          writeCString(views, '?', base, baseBytes);
          writeCString(views, '?', symbol, symbolBytes);
        } catch { /* Report only the failure. */ }
        return 2;
      }
    },

    // Index the table that `bytes` resolves to, or degrade to unsymbolized
    // traces. Returns the metadata the loader reports as instance.trace.
    async load(bytes, identity, started = performance.now()) {
      let size = 0;
      try {
        const data = await bytes;
        size = data.byteLength;
        trace.index = trace.readTable(data, identity);
        return {state: 'ready', reason: null, traceBytes: size,
          loadMilliseconds: performance.now() - started, indexBytes: trace.index.bytes};
      } catch (cause) {
        trace.index = null;
        const reason = cause instanceof Error ? cause.message : String(cause);
        console.warn('Titan browser trace: ' + reason);
        return {state: 'degraded', reason, traceBytes: size,
          loadMilliseconds: performance.now() - started, indexBytes: 0};
      }
    },
  };
  return trace;
}

// Node reads paths and file: URLs; everything else is fetched like a page.
async function resource(url, what) {
  if (nodeFs && !/^(https?|data|blob):/i.test(url)) {
    return nodeFs.promises.readFile(url.startsWith('file:') ? new URL(url) : url);
  }
  const response = await fetch(url, {credentials: 'same-origin'});
  if (!response.ok) throw new Error(`${what} request failed (${response.status})`);
  return response;
}

async function compileImage(url, imports) {
  const source = await resource(url, 'browser image');
  if (!(source instanceof Response)) return (await WebAssembly.instantiate(source, imports)).instance;
  // Streaming compilation needs the Wasm media type; other servers still work.
  if (source.headers.get('Content-Type')?.startsWith('application/wasm')) {
    return (await WebAssembly.instantiateStreaming(source, imports)).instance;
  }
  return (await WebAssembly.instantiate(await source.arrayBuffer(), imports)).instance;
}

async function traceBytes(url) {
  const source = await resource(url, 'trace table');
  return source instanceof Response ? new Uint8Array(await source.arrayBuffer()) : source;
}

/**
 * Instantiate the image of `bridge` (the loader's owner): its options name
 * `locateFile` and the embedder's `imports`, and its image binding names the
 * `.wasm` and the module directory. Both resources load concurrently; the
 * trace table is indexed before C constructors run. Resolves to the context.
 */
async function instantiate(bridge) {
  const {locateFile} = bridge.options, {wasm, directory} = bridge.image;
  const context = new ImageContext(bridge);
  const backend = bridge.backend = new Continuations(bridge, context);
  const trace = createTrace(context);
  const started = performance.now();
  const table = traceBytes(locateFile(`${wasm}.trace`, directory));
  table.catch(() => { /* trace.load reports it after instantiation. */ });
  const imports = bridge.userImports(context);
  const output = (stream, pointer, length) => {
    try { bridge.output(stream, pointer, length); }
    catch (cause) { try { bridge.poison(cause); } catch { /* The first failure stands. */ } }
  };
  imports.wasi_snapshot_preview1 = createWasiImports({output, get options() { return bridge.options; }},
    context, message => context.abort(message));
  imports.env = Object.assign(Object.create(null), imports.env, backend.imports(), bridgeImports(bridge),
    calendarImports(context), {
      titan_browser_trace_capture: (out, capacity) => trace.capture(out, capacity),
      titan_browser_trace_symbolize: (record, base, baseBytes, symbol, symbolBytes, line) =>
        trace.symbolize(record, base, baseBytes, symbol, symbolBytes, line),
    });
  let instance;
  try {
    instance = await compileImage(locateFile(wasm, directory), imports);
  } catch (cause) {
    // A missing, unreadable or unlinkable image aborts the instance.
    bridge.abortEngine(cause);
    throw cause;
  }
  const raw = instance.exports;
  for (const name of requiredExports) {
    if (!(name in raw)) throw browserError('PROTOCOL', `browser image ${wasm} lacks the ${name} export`);
  }
  context.memory = raw.memory;
  context.table = raw.__indirect_function_table;
  context.exports = {...raw};
  for (const [name, kind] of promisedEntries) {
    if (typeof raw[name] !== 'function') continue;
    const promised = WebAssembly.promising(raw[name]);
    context.exports[name] = (...args) => backend.enter(() => promised(...args), args[0], kind);
  }
  // Only the driver may start an engine coroutine.
  if (raw.titan_mco_entry) {
    backend.engineEntry = WebAssembly.promising(raw.titan_mco_entry);
    context.exports.titan_mco_entry = () => Promise.reject(browserError('REENTRY',
      'Titan coroutine engine entry is private'));
  }
  backend.wasm = raw;
  backend.bound(raw.__stack_high.value >>> 0, raw.__stack_low.value >>> 0);
  context.trace = await trace.load(table, context.readCString(raw.titan_browser_trace_identity()), started);
  raw._initialize();
  return context;
}

export default instantiate;
