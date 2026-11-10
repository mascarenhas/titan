#ifndef TITAN_BROWSER_FIXTURE_CONTROLS_H
#define TITAN_BROWSER_FIXTURE_CONTROLS_H
#include <emscripten.h>
#include <titan/browser.h>

/* Fault injection and close-order observers are fixture-only JS boundaries. */
EM_JS(void *, gate_test_state_record, (void *state), {
  for (var record of Module['titanBrowserBridge'].stateRecords.values()) {
    if (HEAPU32[record >>> 2] === state) return record;
  }
  return 0;
});

EM_JS(void, titan_bridge_test_earlier_cleanup, (int index), {
  var observe = Module['titanBrowserBridge'].options.bindings.__titanEarlierCleanup;
  if (observe) observe(index);
});

EM_JS(void, gate_test_state_closed, (uint32_t token), {
  var observe = Module['titanBrowserBridge'].options.bindings.__titanStateClosed;
  if (observe) observe(token);
});

EM_JS(int, titan_bridge_test_release_due_gc, (), {
  return Module['titanBrowserBridge'].options.bindings.r1_release_result();
});

/* Test-owned controls deliberately go only to an explicit fixture binding;
 * generated images never expose the raw Module/factory in their public API. */
EM_JS(void, gate_test_publish, (), {
  var owner = Module['titanBrowserBridge'];
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
    observe: () => Module['_titan_browser_gate_observe'](),
    guarded: () => {
      var error = owner.admission();
      if (error) return Promise.reject(error);
      return owner.operate('guarded', () => owner.entry('gate_guarded')).then(result => result.status);
    },
    rawGuarded: () => Module['_titan_browser_gate_guarded'](0n),
    allocate: size => Module['_malloc'](size || 1),
    free: pointer => Module['_free'](pointer),
    abort: () => abort('bridge fixture owned abort'),
    armResponseOwnerFailure: () => Module['_titan_bridge_test_arm_response_owner_failure'](),
    failAllocationAfter(successes) {
      var allocate = Module['_malloc'];
      var failed = false, slotsAtFailure;
      Module['_malloc'] = size => {
        if (successes-- === 0) {
          failed = true;
          slotsAtFailure = owner.slots.size;
          Module['_malloc'] = allocate;
          return 0;
        }
        return allocate(size);
      };
      return Object.freeze({
        restore() { Module['_malloc'] = allocate; },
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
        var release = Module['_titan_browser_release_callable'];
        Module['_titan_browser_release_callable'] = function(state, slot, generation) {
          Module['_titan_browser_release_callable'] = release;
          Module['_titan_bridge_test_enter_with_free_stack'](freeSlots, maxFailures, state);
          try { return attempt.status = release(state, slot, generation); }
          finally { Module['_titan_bridge_test_reset_entry_stack'](); }
        };
        return attempt;
      }
      var entry = owner.entry;
      owner.entry = function(entryKind, ...args) {
        if (entryKind === kind) {
          owner.entry = entry;
          Module['_titan_bridge_test_enter_with_free_stack'](freeSlots, maxFailures, 0);
          try {
            return entry.call(owner, entryKind, ...args);
          } finally {
            Module['_titan_bridge_test_reset_entry_stack']();
          }
        }
        return entry.call(owner, entryKind, ...args);
      };
    },
    refuseNextRelease() {
      var release = Module['_titan_browser_release_callable'];
      Module['_titan_browser_release_callable'] = function() {
        Module['_titan_browser_release_callable'] = release;
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
    weakTargets: () => [new WeakRef(Module), new WeakRef(Module.HEAPU8.buffer)],
  }));
});
#endif
