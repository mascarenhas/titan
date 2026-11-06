// Titan's private channels and JSPI continuation owner (--js-library).
addToLibrary({
  $TitanBrowser__deps: ['$addOnInit', '$stackSave', '$stackRestore',
    'emscripten_stack_get_base', 'emscripten_stack_get_end',
    'emscripten_stack_set_limits', '$setStackLimits'],
  $TitanBrowser__postset: 'addOnInit(() => TitanBrowser.install());',
  $TitanBrowser: {
    owner: false,
    entered: false,
    current: 0,
    contexts: null,
    retired: null,
    pending: null,
    terminalFailure: null,
    blocked: false,
    poisoned: false,
    queued: false,

    safe() {
      return !TitanBrowser.owner;
    },

    error(code, message) {
      var error = new Error(message);
      error.name = 'TitanBrowserError';
      error.code = 'TITAN_BROWSER_' + code;
      return error;
    },

    schedule() {
      if (TitanBrowser.queued) return;
      TitanBrowser.queued = true;
      queueMicrotask(() => {
        TitanBrowser.queued = false;
        if (TitanBrowser.safe()) Module['titanBrowserSafePoint']?.();
      });
    },

    // The owner outlives every internal transfer microtask, including a GC
    // finalizer's abandoned-stack unwind. This is also the internal entry hook
    // for future stateful gateways; call must invoke a promising Wasm export.
    enter(call, id, kind) {
      if (TitanBrowser.owner) {
        return Promise.reject(TitanBrowser.error('REENTRY',
          'browser instance is active; reentry is not allowed'));
      }
      if (TitanBrowser.blocked || TitanBrowser.poisoned) {
        return Promise.reject(TitanBrowser.terminalFailure || TitanBrowser.error('DISPOSED',
          'browser instance is disposed'));
      }
      TitanBrowser.owner = true;
      TitanBrowser.entered = false;
      TitanBrowser.pending = {id, kind, completed: false};
      var result;
      try {
        result = call();
      } catch (cause) {
        result = Promise.reject(cause);
      }
      return Promise.resolve(result).catch(cause => {
        TitanBrowser.poison(cause);
        if (cause instanceof WebAssembly.RuntimeError) Module['titanBrowserTrap']?.(cause);
        throw cause;
      }).finally(() => {
        TitanBrowser.owner = false;
        TitanBrowser.pending = null;
        TitanBrowser.schedule();
      });
    },

    poison(cause) {
      TitanBrowser.terminalFailure ||= cause;
      TitanBrowser.blocked = true;
      TitanBrowser.poisoned = true;
      // Fatal engine failure is not a Titan unwind. Reject engine gates so
      // their invocations retire, but never call into C to recycle allocations.
      for (var context of TitanBrowser.contexts.values()) {
        context.gate?.reject(cause);
        context.gate = null;
      }
      Module['titanBrowserBridge']?.poison(cause);
    },

    save(context) {
      checkStackCookie();
      context.sp = stackSave();
      context.low = _emscripten_stack_get_end();
      context.high = _emscripten_stack_get_base();
    },

    restore(context) {
      _emscripten_stack_set_limits(context.high, context.low);
      setStackLimits();
      stackRestore(context.sp);
      TitanBrowser.current = context.id;
      if (context.started) checkStackCookie();
      else writeStackCookie();
    },

    context(id) {
      var context = TitanBrowser.contexts.get(id);
      if (!context) throw new Error('unknown Titan coroutine context');
      return context;
    },

    park(context) {
      if (context.gate) throw new Error('Titan coroutine context is already parked');
      var promise = new Promise((resolve, reject) => { context.gate = {resolve, reject}; });
      // Both successful wakes and retirement exceptions restore the linear
      // stack/bounds before the engine resumes the suspended Wasm activation.
      return promise.then(value => {
        TitanBrowser.restore(context);
        return value;
      }, cause => {
        TitanBrowser.restore(context);
        throw cause;
      });
    },

    activate(context) {
      // Defer first entry too: do not recursively nest JS import frames or
      // execute a destination before the source import has actually suspended.
      queueMicrotask(() => {
        if (TitanBrowser.poisoned) return;
        try {
          if (context.started) {
            var gate = context.gate;
            if (!gate || context.retiring) throw new Error('Titan coroutine destination is not parked');
            context.gate = null;
            gate.resolve();
            return;
          }
          TitanBrowser.restore(context);
          context.started = true;
          context.lifetime = Promise.resolve(_titan_mco_entry(context.id)).then(() => {
            context.finished = true;
            if (!context.terminal) throw new Error('Titan coroutine returned without terminal handoff');
            TitanBrowser.activate(context.terminal);
          }, cause => {
            context.finished = true;
            if (context.retiring && cause === TitanBrowser.retired) return;
            throw cause;
          }).catch(cause => { TitanBrowser.poison(cause); });
        } catch (cause) {
          TitanBrowser.poison(cause);
        }
      });
    },

    transfer(from, fromBack, to, toBack, terminal) {
      var source = TitanBrowser.context(TitanBrowser.current);
      var fromContext = TitanBrowser.context(from);
      var toContext = TitanBrowser.context(to);
      if (fromBack) fromContext.back = source;
      else if (source !== fromContext) throw new Error('Titan coroutine transfer source is not current');
      var destination = toBack ? toContext.back : toContext;
      if (!destination) throw new Error('Titan coroutine transfer has no BACK continuation');
      if (toBack) toContext.back = null;
      TitanBrowser.save(source);
      if (terminal) {
        // Do not wake the resumer yet. _mco_main must return all the way out of
        // its promising export before that resumer may free the native stack.
        source.terminal = destination;
        return;
      }
      var parked = TitanBrowser.park(source);
      TitanBrowser.activate(destination);
      return parked;
    },

    destroy(id) {
      var context = TitanBrowser.context(id);
      if (!context.started || context.finished) {
        TitanBrowser.contexts.delete(id);
        return;
      }
      if (!context.gate || context.retiring) throw new Error('cannot retire a running Titan coroutine');
      var caller = TitanBrowser.context(TitanBrowser.current);
      TitanBrowser.save(caller);
      context.retiring = true;
      var gate = context.gate;
      context.gate = null;
      gate.reject(TitanBrowser.retired);
      return context.lifetime.then(() => {
        TitanBrowser.restore(caller);
        if (TitanBrowser.poisoned) throw TitanBrowser.terminalFailure;
        TitanBrowser.contexts.delete(id);
      });
    },

    install() {
      if (typeof WebAssembly.promising !== 'function' || typeof WebAssembly.Suspending !== 'function') {
        throw TitanBrowser.error('CAPABILITY', 'Titan browser images require WebAssembly JSPI (Node 26 or a JSPI-capable browser)');
      }
      TitanBrowser.contexts = new Map([[0, {id: 0, started: true, gate: null, back: null}]]);
      TitanBrowser.retired = new Error('Titan coroutine continuation retired');
      // Emscripten's explicit JSPI_EXPORTS set uses WebAssembly.promising.
      // Wrap only general state-entering Module exports; C-only helpers stay
      // synchronous. Static wasmExports accesses survive export minification.
      for (var [name, kind] of [
        ['titan_browser_initialize', 1], ['titan_browser_entry', 2],
        ['titan_browser_invoke', 3], ['titan_browser_release_callable', 4],
        ['titan_browser_close', 5], ['titan_browser_gate_guarded', 3],
      ]) {
        var entry = wasmExports[name];
        if (entry) {
          // Each closure captures its own entry/kind, not the loop's var home.
          ((name, entry, kind) => {
            Module['_' + name] = (...args) => TitanBrowser.enter(() => entry(...args), args[0], kind);
          })(name, entry, kind);
        }
      }
      // Only the driver may start an engine coroutine. Its lexical raw export
      // stays private even though Emscripten publishes KEEPALIVE aliases.
      Module['_titan_mco_entry'] = () => Promise.reject(TitanBrowser.error('REENTRY',
        'Titan coroutine engine entry is private'));
      Module['titanBrowserAttach']?.(TitanBrowser);
    },
  },

  titan_mco_create__deps: ['$TitanBrowser'],
  titan_mco_create__sig: 'vppp',
  titan_mco_create: (id, low, high) => {
    if (TitanBrowser.contexts.has(id)) throw new Error('duplicate Titan coroutine context');
    TitanBrowser.contexts.set(id, {id, low, high, sp: high, started: false,
      finished: false, gate: null, back: null, terminal: null, lifetime: null, retiring: false});
  },

  titan_mco_transfer__deps: ['$TitanBrowser', 'titan_mco_entry'],
  titan_mco_transfer__sig: 'vpipii',
  titan_mco_transfer: (from, fromBack, to, toBack, terminal) =>
    TitanBrowser.transfer(from, fromBack, to, toBack, terminal),

  titan_mco_destroy__deps: ['$TitanBrowser'],
  titan_mco_destroy__sig: 'vp',
  titan_mco_destroy: id => TitanBrowser.destroy(id),

  titan_browser_entry_allowed__deps: ['$TitanBrowser'],
  titan_browser_entry_allowed__sig: 'iji',
  titan_browser_entry_allowed: (id, kind) => {
    id = BigInt.asUintN(64, id);
    var pending = TitanBrowser.pending;
    if (!TitanBrowser.owner || TitanBrowser.entered || !pending ||
        id === 0n || pending.id !== id || pending.kind !== kind) return 0;
    TitanBrowser.entered = true;
    return 1;
  },
});
