// JavaScript half of titan/browser.h. Offsets and widths are asserted there.
// This library owns no instance singleton: every import reaches its Module's owner.
addToLibrary({
  $TitanBridge__deps: ['$TitanBrowser'],
  $TitanBridge: {
    trusted(method, ...args) {
      var owner = Module['titanBrowserBridge'];
      try { return owner[method](...args); }
      catch (cause) {
        try { owner.poison(cause); } catch (_) {}
        return 0;
      }
    },
    response(pointer, state, call) {
      var owner = Module['titanBrowserBridge'];
      owner.importResponse(pointer >>> 0, state >>> 0, call);
    },
  },

  titan_browser_complete__deps: ['$TitanBridge'],
  titan_browser_complete__sig: 'vp',
  titan_browser_complete: pointer => TitanBridge.trusted('receiveCompletion', pointer >>> 0),

  titan_browser_host_state_open__deps: ['$TitanBridge'],
  titan_browser_host_state_open__sig: 'ip',
  titan_browser_host_state_open: record => TitanBridge.trusted('openState', record >>> 0),

  titan_browser_host_state_record__deps: ['$TitanBridge'],
  titan_browser_host_state_record__sig: 'pi',
  titan_browser_host_state_record: state => TitanBridge.trusted('stateRecord', state >>> 0),

  titan_browser_host_state_closing__deps: ['$TitanBridge'],
  titan_browser_host_state_closing__sig: 'vi',
  titan_browser_host_state_closing: state => TitanBridge.trusted('markStateClosing', state >>> 0),

  titan_browser_host_state_closed__deps: ['$TitanBridge'],
  titan_browser_host_state_closed__sig: 'vi',
  titan_browser_host_state_closed: state => TitanBridge.trusted('closeState', state >>> 0),

  titan_browser_host_callable__deps: ['$TitanBridge'],
  titan_browser_host_callable__sig: 'iiii',
  titan_browser_host_callable: (state, slot, generation) =>
    TitanBridge.trusted('registerCallable', state >>> 0, slot >>> 0, generation >>> 0),

  titan_browser_host_callable_closed__deps: ['$TitanBridge'],
  titan_browser_host_callable_closed__sig: 'iiii',
  titan_browser_host_callable_closed: (state, slot, generation) =>
    TitanBridge.trusted('invalidateCallable', state >>> 0, slot >>> 0, generation >>> 0),

  titan_browser_host_release__deps: ['$TitanBridge'],
  titan_browser_host_release__sig: 'viii',
  titan_browser_host_release: (state, slot, generation) =>
    TitanBridge.trusted('releaseOwnedSlot', state >>> 0, slot >>> 0, generation >>> 0),

  titan_browser_host_adopt__deps: ['$TitanBridge'],
  titan_browser_host_adopt__sig: 'viii',
  titan_browser_host_adopt: (state, slot, generation) =>
    TitanBridge.trusted('adoptSlot', state >>> 0, slot >>> 0, generation >>> 0),

  titan_browser_host_retain__deps: ['$TitanBridge'],
  titan_browser_host_retain__sig: 'viii',
  titan_browser_host_retain: (state, slot, generation) =>
    TitanBridge.trusted('retainSlot', state >>> 0, slot >>> 0, generation >>> 0),

  titan_browser_host_identity_live__deps: ['$TitanBridge'],
  titan_browser_host_identity_live__sig: 'iiiii',
  titan_browser_host_identity_live: (state, slot, generation, kind) => {
    // Stale owners are ordinary protected errors, not completion corruption.
    var owner = Module['titanBrowserBridge'];
    return owner ? owner.identityLive(state >>> 0, slot >>> 0, generation >>> 0, kind >>> 0) : 0;
  },

  titan_browser_host_binding__deps: ['$TitanBridge'],
  titan_browser_host_binding__sig: 'vipip',
  titan_browser_host_binding: (state, name, length, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].binding(name >>> 0, length >>> 0, state >>> 0)),

  titan_browser_host_call__deps: ['$TitanBridge'],
  titan_browser_host_call__sig: 'viiiipp',
  titan_browser_host_call: (state, slot, generation, argc, args, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostCall(
      state >>> 0, slot >>> 0, generation >>> 0, argc >>> 0, args >>> 0)),

  titan_browser_host_start__deps: ['$TitanBridge'],
  titan_browser_host_start__sig: 'viiiipiiiiip',
  titan_browser_host_start: (state, slot, generation, argc, args, successSlot, successGeneration,
      failureSlot, failureGeneration, mode, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostStart(
      state >>> 0, slot >>> 0, generation >>> 0, argc >>> 0, args >>> 0,
      successSlot >>> 0, successGeneration >>> 0, failureSlot >>> 0, failureGeneration >>> 0, mode !== 0)),

  titan_browser_host_cancel__deps: ['$TitanBridge'],
  titan_browser_host_cancel__sig: 'viiip',
  titan_browser_host_cancel: (state, slot, generation, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostCancel(state >>> 0, slot >>> 0, generation >>> 0)),

  // Driver imports: trusted owner calls; a broken protocol poisons, never throws.
  titan_browser_host_owner__deps: ['$TitanBridge'],
  titan_browser_host_owner__sig: 'vi',
  titan_browser_host_owner: state => TitanBridge.trusted('setOwnerState', state >>> 0),

  titan_browser_host_drive_begin__deps: ['$TitanBridge'],
  titan_browser_host_drive_begin__sig: 'vi',
  titan_browser_host_drive_begin: state => TitanBridge.trusted('driveBegin', state >>> 0),

  titan_browser_host_drive_end__deps: ['$TitanBridge'],
  titan_browser_host_drive_end__sig: 'viii',
  titan_browser_host_drive_end: (_state, status, exited) =>
    TitanBridge.trusted('driveEnd', status | 0, exited !== 0),

  titan_browser_host_main_failed__deps: ['$TitanBridge'],
  titan_browser_host_main_failed__sig: 'vipppp',
  titan_browser_host_main_failed: (state, message, length, trace, traceLength) =>
    TitanBridge.trusted('mainFailed', state >>> 0, message >>> 0, length >>> 0, trace >>> 0, traceLength >>> 0),

  titan_browser_host_wake__deps: ['$TitanBridge'],
  titan_browser_host_wake__sig: 'vi',
  titan_browser_host_wake: state => TitanBridge.trusted('wakeDriver', state >>> 0),

  titan_browser_host_batch__deps: ['$TitanBridge'],
  titan_browser_host_batch__sig: 'ii',
  titan_browser_host_batch: state => TitanBridge.trusted('batchItems', state >>> 0),

  titan_browser_host_item__deps: ['$TitanBridge'],
  titan_browser_host_item__sig: 'iip',
  titan_browser_host_item: (_state, out) => TitanBridge.trusted('nextItem', out >>> 0),

  titan_browser_host_item_done__deps: ['$TitanBridge'],
  titan_browser_host_item_done__sig: 'vij',
  titan_browser_host_item_done: (state, id) =>
    TitanBridge.trusted('itemDone', state >>> 0, BigInt.asUintN(64, id)),

  titan_browser_host_settle__deps: ['$TitanBridge'],
  titan_browser_host_settle__sig: 'vp',
  titan_browser_host_settle: record => TitanBridge.trusted('settleQueued', record >>> 0),
});
