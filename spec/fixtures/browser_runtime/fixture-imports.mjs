// Host imports of the browser fixtures' C sources (fixture_controls.h and the
// fixtures that declare their own TITAN_WASM_IMPORTs). A harness passes the
// default export to create({imports}); the runner passes it to directly run
// images with --imports and gives it to --js-test harnesses as
// context.imports. Every control reaches a test only through an explicit
// fixture binding: images never expose their instance in their public API.
//
// `context` is the instance's create({imports}) context. `bridge` is the
// loader's private owner, for fixtures only; the bridge looks up `exports`
// and its own methods at call time, so the fault injections below that
// replace them take effect.
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

export default function fixtureImports(context) {
  let miniDriverHooks;
  let remainingDeliveryFailures = 0;
  const clickListeners = new Map();
  return {env: {
    // fixture_controls.h: fault injection and close-order observers.
    gate_test_state_record(state) {
      for (const record of context.bridge.stateRecords.values()) {
        if (context.HEAPU32[record >>> 2] === state >>> 0) return record;
      }
      return 0;
    },
    titan_bridge_test_earlier_cleanup(index) {
      const observe = context.bridge.options.bindings.__titanEarlierCleanup;
      if (observe) observe(index);
    },
    gate_test_state_closed(token) {
      const observe = context.bridge.options.bindings.__titanStateClosed;
      if (observe) observe(token >>> 0);
    },
    titan_bridge_test_release_due_gc() {
      return context.bridge.options.bindings.r1_release_result();
    },
    gate_test_publish() {
      var owner = context.bridge;
      var backend = owner.backend;
      var publish = owner.options.bindings?.__titanTest;
      if (!publish) return;
      publish(Object.freeze({
        snapshot: () => Object.freeze({owner: !!backend.owner, safe: backend.safe(),
          active: !!owner.active,
          current: backend.current, contexts: backend.contexts.size,
          operationId: owner.operationId, slots: owner.slots.size,
          units: [...owner.slots.values()].reduce((n, slot) => n + slot.units, 0),
          requests: owner.requests.size,
          states: Object.freeze([...owner.states.entries()].map(([token, state]) =>
            Object.freeze({token, closing: state === 'closing', closed: state === 'closed'})))}),
        stateLedger: state => Object.freeze({
          callables: [...owner.callables.values()].filter(item => item.state === state)
            .map(item => item.key),
          slots: [...owner.slots].filter(([, item]) => item.state === state)
            .map(([slot, item]) => ({slot, generation: item.generation, kind: item.kind, units: item.units})),
          requests: [...owner.requests].filter(item => item.state === state).length,
          notifications: [...owner.queue, ...owner.batch].filter(item => item.target.state === state).length,
          duplicateFrees: owner.freeSlots.filter((item, index, list) =>
            list.findIndex(other => other.slot === item.slot && other.generation === item.generation) !== index).length,
        }),
        watchStateLedger() {
          var allocated = [], retired = [], registered = [], invalidated = [], units = [], closed = [];
          var originals = {};
          var wrap = (name, body) => {
            originals[name] = owner[name];
            owner[name] = body;
          };
          wrap('newSlot', function(state, ...args) {
            var identity = originals.newSlot.call(this, state, ...args);
            allocated.push({state, ...identity, kind: this.slots.get(identity.slot).kind});
            units.push({state, delta: 1});
            return identity;
          });
          wrap('retainSlot', function(state, slot, generation) {
            var result = originals.retainSlot.call(this, state, slot, generation);
            units.push({state, delta: 1});
            return result;
          });
          wrap('releaseSlot', function(slot, generation) {
            var entry = this.slots.get(slot);
            var matches = entry && entry.generation === generation;
            var before = matches ? entry.units : 0;
            var result = originals.releaseSlot.call(this, slot, generation);
            if (matches) {
              var after = this.slots.get(slot) === entry ? entry.units : 0;
              units.push({state: entry.state, delta: after - before});
              if (after === 0) retired.push({state: entry.state, slot, generation, kind: entry.kind});
            }
            return result;
          });
          wrap('registerCallable', function(state, slot, generation) {
            var result = originals.registerCallable.call(this, state, slot, generation);
            if (result) registered.push({state, key: state + ':' + slot + ':' + generation});
            return result;
          });
          wrap('invalidateCallable', function(state, slot, generation) {
            var key = state + ':' + slot + ':' + generation;
            var before = this.callables.has(key);
            var result = originals.invalidateCallable.call(this, state, slot, generation);
            if (before && !this.callables.has(key)) invalidated.push({state, key});
            return result;
          });
          wrap('closeState', function(state) {
            var keys = [...this.callables.values()].filter(item => item.state === state).map(item => item.key);
            var before = [...this.slots.values()].filter(item => item.state === state)
              .reduce((total, item) => total + item.units, 0);
            var start = units.length;
            var result = originals.closeState.call(this, state);
            var released = -units.slice(start).filter(item => item.state === state)
              .reduce((total, item) => total + item.delta, 0);
            // closeState drops all remaining owners, even if a slot had several units.
            if (before > released) units.push({state, delta: released - before});
            for (var key of keys) if (!this.callables.has(key)) invalidated.push({state, key});
            closed.push(state);
            return result;
          });
          return Object.freeze({
            snapshot: () => ({allocated: allocated.slice(), retired: retired.slice(),
              registered: registered.slice(), invalidated: invalidated.slice(),
              units: units.slice(), closed: closed.slice()}),
            restore() { for (var name of Object.keys(originals)) owner[name] = originals[name]; },
          });
        },
        observe: () => context.exports.titan_browser_gate_observe(),
        guarded: () => {
          var error = owner.admission();
          if (error) return Promise.reject(error);
          return owner.operate('guarded', () => owner.entry('gate_guarded')).then(result => result.status);
        },
        rawGuarded: () => context.exports.titan_browser_gate_guarded(0n),
        allocate: size => context.exports.malloc(size || 1),
        free: pointer => context.exports.free(pointer),
        abort: () => context.abort('bridge fixture owned abort'),
        armResponseOwnerFailure: () => context.exports.titan_bridge_test_arm_response_owner_failure(),
        failAllocationAfter(successes) {
          var allocate = context.exports.malloc;
          var failed = false, slotsAtFailure;
          context.exports.malloc = size => {
            if (successes-- === 0) {
              failed = true;
              slotsAtFailure = owner.slots.size;
              context.exports.malloc = allocate;
              return 0;
            }
            return allocate(size);
          };
          return Object.freeze({
            restore() { context.exports.malloc = allocate; },
            get failed() { return failed; },
            get slotsAtFailure() { return slotsAtFailure; },
          });
        },
        failNextAllocations(count) {
          const allocate = owner.allocate;
          owner.allocate = function() {
            if (--count === 0) owner.allocate = allocate;
            throw new Error('injected delivery allocation failure');
          };
          return () => { owner.allocate = allocate; };
        },
        failNextEntryStack(kind, freeSlots, maxFailures) {
          if (kind === 'release_callable') {
            var attempt = {};
            var release = context.exports.titan_browser_release_callable;
            context.exports.titan_browser_release_callable = function(state, slot, generation) {
              context.exports.titan_browser_release_callable = release;
              context.exports.titan_bridge_test_enter_with_free_stack(freeSlots, maxFailures, state);
              try { return attempt.status = release(state, slot, generation); }
              finally { context.exports.titan_bridge_test_reset_entry_stack(); }
            };
            return attempt;
          }
          var entry = owner.entry;
          owner.entry = function(entryKind, ...args) {
            if (entryKind === kind) {
              owner.entry = entry;
              context.exports.titan_bridge_test_enter_with_free_stack(freeSlots, maxFailures, 0);
              try {
                return entry.call(owner, entryKind, ...args);
              } finally {
                context.exports.titan_bridge_test_reset_entry_stack();
              }
            }
            return entry.call(owner, entryKind, ...args);
          };
        },
        refuseNextRelease() {
          var release = context.exports.titan_browser_release_callable;
          context.exports.titan_browser_release_callable = function() {
            context.exports.titan_browser_release_callable = release;
            return release(0, 0, 0);
          };
        },
        invalidateHandle(value) {
          let removed = 0;
          for (const [slot, entry] of owner.slots) {
            if (entry.kind !== 'value' || !Object.is(entry.value, value)) continue;
            owner.slots.delete(slot);
            entry.units = 0;
            owner.freeSlots.push({slot, generation: entry.generation});
            removed++;
          }
          return removed;
        },
        exhaustSlotIdentities() {
          const next = owner.nextSlot;
          const heldFree = owner.freeSlots;
          owner.nextSlot = 0x100000000;
          owner.freeSlots = [];
          let active = true;
          return () => {
            if (!active) return;
            active = false;
            if (owner.nextSlot !== 0x100000000)
              throw new Error('test slot-exhaustion control observed a fresh identity issue');
            owner.nextSlot = next;
            for (const identity of heldFree) owner.freeSlots.push(identity);
          };
        },
        advanceOperationId: value => {
          if (typeof value !== 'bigint' || value < owner.operationId ||
              value > (1n << 64n) - 1n || owner.active || owner.closing)
            throw new Error('invalid test operation counter advance');
          owner.operationId = value;
        },
        lifetimes: () => Object.freeze([...backend.contexts.values()]
          .filter(item => item.id !== 0).map(item => Object.freeze({id: item.id,
            lifetime: item.lifetime, parked: !!item.gate, finished: !!item.finished}))),
        watchTransfers: callback => {
          var transfer = backend.transfer;
          backend.transfer = (...args) => {
            var result = transfer(...args);
            callback(Object.freeze({terminal: !!args[4], owner: !!backend.owner,
              safe: backend.safe(), contexts: backend.contexts.size}));
            return result;
          };
          return () => { backend.transfer = transfer; };
        },
        watchCompletions: callback => {
          var complete = owner.complete;
          owner.complete = record => { callback(record); complete.call(owner, record); };
          return () => { owner.complete = complete; };
        },
        weakTargets: () => [new WeakRef(context), new WeakRef(context.HEAPU8.buffer)],
      }));
    },
    // A real outer JSPI wait that returns the host's Promise (fixture_sleep),
    // and one through an async host function (gate.c's second form).
    fixture_sleep: new WebAssembly.Suspending(sleep),
    gate_timeout: new WebAssembly.Suspending(async milliseconds => { await sleep(milliseconds); }),

    // browser_loader/loader.c
    browser_loader_initialize_hook() {
      const bindings = context.bridge.options.bindings;
      const publish = bindings?.__loaderTest;
      if (publish) publish(Object.freeze({
        rawEntry: () => context.exports.titan_browser_entry(0n, 0, 0, 0),
        privateEntry: () => context.exports.titan_mco_entry(0),
        abort: () => context.abort('loader abort inside bridge binding'),
        watchMemoryCalls: callback => {
          const owner = context.bridge;
          const allocate = context.exports.malloc, free = context.exports.free;
          context.exports.malloc = size => {
            callback(Object.freeze({kind: 'allocate', poisoned: !!owner.terminal}));
            return allocate(size);
          };
          context.exports.free = pointer => {
            callback(Object.freeze({kind: 'free', poisoned: !!owner.terminal}));
            return free(pointer);
          };
          return () => {
            context.exports.malloc = allocate;
            context.exports.free = free;
          };
        },
        watchResponses: callback => {
          const owner = context.bridge, respond = owner.importResponse;
          owner.importResponse = (pointer, state, action) => {
            callback(Object.freeze({copy: () => context.HEAPU8.slice(pointer, pointer + 56)}));
            return respond.call(owner, pointer, state, action);
          };
          return () => { owner.importResponse = respond; };
        },
      }));
      bindings?.initialize_hook?.();
    },
    browser_loader_async_wait: new WebAssembly.Suspending(async () => { await sleep(15); }),
    // Abort while a real JSPI entry is parked and never resolve the import:
    // fatal disposal must not wait for the permanently pending Promise.
    browser_loader_abort_wait: new WebAssembly.Suspending(async () => {
      setTimeout(() => context.abort('loader abort while suspended'), 10);
      await new Promise(() => {});
    }),
    browser_loader_current_operation() {
      return context.bridge.pending.id;
    },

    // browser_images/entry-close.c
    publish_absent_module_probe() {
      const owner = context.bridge;
      const hook = owner?.options?.bindings?.__absentProbe;
      if (hook) hook({
        unadmittedInvoke: () => context.exports.titan_browser_invoke(0n, 1, 1, 1, 0, 0),
        releaseUnknown: () => context.exports.titan_browser_release_callable(1, 1, 1),
        admittedInvoke: () => owner.operate('invoke', () => owner.entry('invoke', 1, 1, 1, 0, 0)),
      });
    },

    // websocket/browser_tests/native.h: the live network harness's controls.
    titan_net_test_publish() {
      const owner = context.bridge;
      const binding = owner.binding, release = owner.releaseSlot;
      const copy = Uint8Array.prototype.set;
      const large = 20 * 1024 * 1024;
      const marks = {takes: 0, high: 0, drains: 0,
        largeTakes: 0, largeReleased: 0, largeCopies: 0};
      owner.binding = function(pointer, length, state) {
        const result = binding.call(this, pointer, length, state);
        const name = new TextDecoder().decode(this.bytesAt(pointer, length));
        if (name === 'titan:websocket') {
          const source = result.value;
          const waiting = new WeakSet();
          result.value = function(op, ...args) {
            if (op === 'take') {
              marks.takes++;
              if (args[0].bytes?.byteLength === large) marks.largeTakes++;
            }
            const value = source(op, ...args);
            if (op === 'buffered' && value > 262144n) {
              marks.high++; waiting.add(args[0]);
              owner.options.bindings.ws_high(args[0].url);
            }
            if (op === 'buffered' && value >= 0n && value <= 65536n &&
                waiting.delete(args[0])) marks.drains++;
            return value;
          };
        }
        return result;
      };
      owner.releaseSlot = function(slot, generation) {
        const entry = this.slots.get(slot);
        const untaken = entry?.generation === generation && entry.units === 1 &&
          entry.value?.bytes?.byteLength === large;
        const result = release.call(this, slot, generation);
        if (untaken && !this.slots.has(slot)) marks.largeReleased++;
        return result;
      };
      Uint8Array.prototype.set = function(bytes, offset) {
        if (this.buffer === context.HEAPU8.buffer && bytes.byteLength === large) marks.largeCopies++;
        return copy.call(this, bytes, offset);
      };
      /* holders counts the message holder objects that Titan still owns. */
      const holder = value => value !== null && typeof value === 'object' && Object.hasOwn(value, 'bytes');
      owner.options.bindings.__titanTest(Object.freeze({
        snapshot: () => ({...marks,
          holders: [...owner.slots.values()].filter(entry => holder(entry.value)).length}),
        restore() {
          owner.binding = binding;
          owner.releaseSlot = release;
          Uint8Array.prototype.set = copy;
        }
      }));
    },

    // browser_trace/trace_support.c
    trace_fixture_publish_controls() {
      const publish = context.bridge.options.bindings?.__traceTest;
      if (!publish) return;
      publish(Object.freeze({
        metadata: () => {
          const value = context.trace;
          return Object.freeze({state: value.state, reason: value.reason, traceBytes: value.traceBytes,
            indexBytes: value.indexBytes, loadMilliseconds: value.loadMilliseconds});
        },
      }));
    },
    trace_fixture_host_recover() {
      context.bridge.options.bindings.traceFixtureRestoreDescriptors();
    },

    // browser_scheduler/mini_driver.c: `fire` makes a synchronous C callback
    // through the function table, the way a host API does; `hooks.poke` is
    // what mini_driver_poke calls, JavaScript reached from C without a
    // binding. `allocate` calls the plain malloc/free exports, which no
    // admission gate guards.
    mini_driver_controls(fire) {
      const owner = context.bridge;
      const publish = owner.options.bindings?.__miniDriver;
      if (!publish) return;
      const hooks = miniDriverHooks = {poke: undefined};
      publish(Object.freeze({
        snapshot: () => Object.freeze({driving: !!owner.drive, parked: !!owner.drive?.gate,
          queue: owner.queue.length, batch: owner.batch.length,
          openTasks: owner.openTasks.size, requests: owner.requests.size, inHost: owner.inHost,
          ownerState: owner.ownerState, exited: owner.exited ? owner.exited.status : null,
          operationId: owner.operationId, active: !!owner.active, turnScheduled: !!owner.turnScheduled}),
        allocate: () => {
          const pointer = context.exports.malloc(16);
          context.exports.free(pointer);
          return pointer !== 0;
        },
        fire: (state, slot, generation) => context.table.get(fire)(state, slot, generation),
        hooks,
      }));
    },
    mini_driver_poke() {
      miniDriverHooks?.poke?.();
    },

    // async/browser_tests/child.h: fixture-only injection into the
    // JavaScript allocator, not Titan allocation.
    scheduler_fail_deliveries(count) {
      const owner = context.bridge, allocate = owner.allocate;
      remainingDeliveryFailures = count;
      owner.allocate = function() {
        if (--remainingDeliveryFailures === 0) owner.allocate = allocate;
        throw new Error('injected delivery allocation failure');
      };
    },
    scheduler_delivery_failures() {
      return remainingDeliveryFailures;
    },

    // browser_bridge/click_host.h: the page's click registration. A click
    // calls the C callback synchronously through the function table.
    titan_test_set_click_callback(selector, userData, callback) {
      const element = document.querySelector(context.readCString(selector));
      if (!element) return -1;
      const previous = clickListeners.get(element);
      if (previous) element.removeEventListener('click', previous);
      clickListeners.delete(element);
      if (callback) {
        const listener = () => { context.table.get(callback)(userData); };
        element.addEventListener('click', listener);
        clickListeners.set(element, listener);
      }
      return 0;
    },
  }};
}
