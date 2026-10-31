// Titan's private channels. This file is consumed by Emscripten --js-library.
addToLibrary({
#if ASYNCIFY
  $TitanBrowser__deps: ['$Asyncify'],
#endif
  $TitanBrowser__postset: 'TitanBrowser.install();',
  $TitanBrowser: {
    liveDepth: 0,
    continuing: 0,
    suspensionPending: false,
    completionCount: 0,
    terminalFailure: null,
    blocked: false,
    queued: false,

    safe() {
      return !TitanBrowser.liveDepth &&
#if ASYNCIFY
        !Asyncify.exportCallStack.length &&
        !(typeof Fibers !== 'undefined' && Fibers.trampolineRunning) &&
#endif
        true;
    },

    schedule() {
      if (TitanBrowser.queued) return;
      TitanBrowser.queued = true;
      queueMicrotask(() => {
        TitanBrowser.queued = false;
        if (TitanBrowser.safe()) {
          Module['titanBrowserSafePoint']?.(TitanBrowser.suspensionPending);
        }
      });
    },

    install() {
#if ASYNCIFY
      // Pin to Emscripten 6.0.13's export instrumentation. The outer wrapper
      // stays live through maybeStopUnwind's entire fiber trampoline, not just
      // one fiber switch. doRewind's map must use this same wrapper.
      var instrument = Asyncify.instrumentFunction;
      Asyncify.instrumentFunction = (original) => {
        var inner = instrument(original);
        var outer = (...args) => {
          ++TitanBrowser.liveDepth;
          try {
            return inner(...args);
          } catch (cause) {
            if (cause instanceof WebAssembly.RuntimeError) {
              Module['titanBrowserTrap']?.(cause);
            }
            throw cause;
          } finally {
            --TitanBrowser.liveDepth;
            TitanBrowser.schedule();
          }
        };
        Asyncify.funcWrappers.set(original, outer);
        return outer;
      };
      var sleep = Asyncify.handleSleep;
      Asyncify.handleSleep = (startAsync) => {
        var rewinding = Asyncify.state === Asyncify.State.Rewinding;
        try {
          return sleep(startAsync);
        } finally {
          // Set before returning to the unwinding compiled caller. Normal
          // state alone is insufficient: stop_unwind leaves currData alive.
          if (Asyncify.state === Asyncify.State.Unwinding) {
            TitanBrowser.suspensionPending = true;
          } else if (rewinding && !Asyncify.currData) {
            TitanBrowser.suspensionPending = false;
          }
        }
      };
      var rewind = Asyncify.doRewind;
      Asyncify.doRewind = (data) => {
        // A resolved-Promise wake can beat our queued safe-point microtask.
        // Deliver the fully unwound batch before its continuation enters C;
        // nested fiber trampolines are explicitly not safe delivery points.
        if (TitanBrowser.safe()) {
          Module['titanBrowserSafePoint']?.(TitanBrowser.suspensionPending);
        }
        ++TitanBrowser.continuing;
        try {
          return rewind(data);
        } finally {
          --TitanBrowser.continuing;
          TitanBrowser.schedule();
        }
      };
#endif
      Module['titanBrowserAttach']?.(TitanBrowser);
    },
  },

  titan_browser_complete__deps: ['$TitanBrowser'],
  titan_browser_complete__sig: 'viiii',
  titan_browser_complete: (kind, status, bytes, length) => {
    // Copy synchronously while C still owns the payload. Never retain a heap
    // view, and never invoke an application sink from a compiled stack.
    Module['titanBrowserComplete'](kind, status,
      HEAPU8.slice(bytes >>> 0, (bytes >>> 0) + (length >>> 0)),
      ++TitanBrowser.completionCount);
    TitanBrowser.schedule();
  },

  titan_browser_entry_allowed__deps: ['$TitanBrowser'],
  titan_browser_entry_allowed__sig: 'i',
  titan_browser_entry_allowed: () => {
    // Rewind/fiber continuations are already admitted. External calls must not
    // enter an active compiled stack, a pending wait, or a retired instance.
    return TitanBrowser.continuing ||
      (!TitanBrowser.blocked && !TitanBrowser.terminalFailure &&
       !TitanBrowser.completionCount && !TitanBrowser.suspensionPending &&
#if ASYNCIFY
       TitanBrowser.liveDepth === 1
#else
       true
#endif
      ) ? 1 : 0;
  },
});
