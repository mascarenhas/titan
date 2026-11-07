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
  titan_browser_host_state_open__sig: 'i',
  titan_browser_host_state_open: () => TitanBridge.trusted('openState'),

  titan_browser_host_state_closing__deps: ['$TitanBridge'],
  titan_browser_host_state_closing__sig: 'vi',
  titan_browser_host_state_closing: state => TitanBridge.trusted('markStateClosing', state >>> 0),

  titan_browser_host_state_closed__deps: ['$TitanBridge'],
  titan_browser_host_state_closed__sig: 'vi',
  titan_browser_host_state_closed: state => TitanBridge.trusted('closeState', state >>> 0),

  titan_browser_host_callable__deps: ['$TitanBridge'],
  titan_browser_host_callable__sig: 'viii',
  titan_browser_host_callable: (state, slot, generation) =>
    TitanBridge.trusted('registerCallable', state >>> 0, slot >>> 0, generation >>> 0),
  titan_browser_host_callable_closed__deps: ['$TitanBridge'],
  titan_browser_host_callable_closed__sig: 'viii',
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

  titan_browser_host_write__deps: ['$TitanBridge'],
  titan_browser_host_write__sig: 'viipiiiiip',
  titan_browser_host_write: (state, stream, bytes, length, successSlot, successGeneration,
      failureSlot, failureGeneration, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostWrite(
      state >>> 0, stream >>> 0, bytes >>> 0, length >>> 0, successSlot >>> 0,
      successGeneration >>> 0, failureSlot >>> 0, failureGeneration >>> 0)),

  titan_browser_host_read__deps: ['$TitanBridge'],
  titan_browser_host_read__sig: 'viiiiiip',
  titan_browser_host_read: (state, capacity, successSlot, successGeneration,
      failureSlot, failureGeneration, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostRead(
      state >>> 0, capacity >>> 0, successSlot >>> 0, successGeneration >>> 0,
      failureSlot >>> 0, failureGeneration >>> 0)),

  titan_browser_host_cancel__deps: ['$TitanBridge'],
  titan_browser_host_cancel__sig: 'viiip',
  titan_browser_host_cancel: (state, slot, generation, response) =>
    TitanBridge.response(response, state, () => Module['titanBrowserBridge'].hostCancel(state >>> 0, slot >>> 0, generation >>> 0)),
});
