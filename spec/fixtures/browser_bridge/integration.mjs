import {AliasingBytes, binary, decode, encode, formBinding, gate, join, makeHost} from './bindings.mjs';

async function expectRejection(context, promise, code, keepError) {
  context.assert(promise instanceof Promise, 'general bridge method threw instead of returning a promise');
  let caught;
  try { await promise; } catch (error) { caught = error; }
  context.assert(caught !== undefined, `expected ${code} rejection`);
  context.assert(code === 'TypeError' ? caught instanceof TypeError : caught.code === `TITAN_BROWSER_${code}`,
    `wrong bridge rejection: ${caught?.code}: ${caught?.message}`);
  return keepError ? caught : undefined;
}

// Assertions carry no Error value: its native frames can retain a closed image.
function rejected(context, promise, code) {
  return expectRejection(context, promise, code, false);
}

function captureRejection(context, promise, code) {
  return expectRejection(context, promise, code, true);
}

function finalizedState(context, host, index) {
  const observed = host.stateCloseObservations.filter(entry => entry.index === index);
  context.assert(observed.length === 1 && host.earlierCloses.filter(tag => tag === index).length === 1,
    'user finalizer or earlier-object cleanup was lost or duplicated');
  context.assert(host.stateInvalidations.filter(token => token === observed[0].token).length === 1,
    'browser state did not invalidate exactly once after its user finalizer');
  const warnings = decode(join(host.stderr)).split('\n').filter(line =>
    line.startsWith('Lua warning: ') && line.includes('browser state is closed'));
  context.assert(warnings.length === host.earlierCloses.length,
    'an earlier-object binding call did not produce its expected Lua finalizer warning');
}

function markSettled(marker) { marker.settled = true; }
function watch(promise) {
  const marker = {settled: false};
  promise.then(markSettled.bind(undefined, marker), markSettled.bind(undefined, marker));
  return marker;
}

async function until(context, predicate, message) {
  for (let attempt = 0; attempt < 40; attempt++) {
    if (predicate()) return;
    await context.tick();
  }
  context.assert(false, message);
}

// Preparation must return before collection: a suspended frame can conservatively
// retain a target it used earlier even after its visible local has been cleared.
async function collected(context, references, phase, kinds = ['Module', 'ArrayBuffer', 'instance']) {
  for (let attempt = 0; attempt < 40; attempt++) {
    await context.tick(); await context.gc(); await context.tick();
    if (references.every(reference => reference.deref() === undefined)) return;
  }
  // weakTargets() returns Module then its heap buffer; finalizerDrain appends the facade.
  const survivors = references.flatMap((reference, index) => reference.deref() === undefined ? [] :
    [{kind: kinds[index], identity: `${phase}/target-${index}`}]);
  context.assert(false, `${phase}: ${survivors.length} native/instance targets survived acknowledged GC; targets=${JSON.stringify(survivors)}`);
}

function createHost(context, image, extra = {}) {
  const host = makeHost(context);
  host.instance = image.create({...host.options, locateFile: image.locateFile, ...extra});
  return host;
}

async function nativeRun(context, host, args = []) {
  const result = await host.instance.run(args);
  context.assert(result.kind === 'returned' && result.status === 0,
    'native browser.tests failed:\n' + decode(join(host.stdout)) + decode(join(host.stderr)));
  const summary = decode(join(host.stdout)).match(/\[  PASSED  \] (\d+) tests?\./);
  context.assert(summary && Number(summary[1]) > 0, 'native test owner did not report its passing cases');
  context.assert(host.callbacks.size >= 26, 'native owner omitted published production callable wrappers');
  return Number(summary[1]);
}

function admissionOutcome(context, promise) {
  context.assert(promise instanceof Promise, 'argument inspection threw instead of returning a promise');
  return promise.then(value => ({status: 'fulfilled', value}), error => ({status: 'rejected', error}));
}

function admissionDescription(outcome) {
  if (!outcome) return {status: 'not-attempted'};
  if (outcome.status === 'rejected') return {status: outcome.status,
    code: outcome.error.code ?? outcome.error.name, message: outcome.error.message};
  const item = outcome.value;
  return {status: outcome.status, value:
    item instanceof Uint8Array ? Array.from(item) : typeof item === 'bigint' ? `${item}n` : item};
}

async function argumentMaterialization(context, image) {
  const engineFailures = [], host = createHost(context, image,
    {onEngineFailure(event) { engineFailures.push(event); }});
  try {
    await host.instance.initialize();
    const reads = [], checks = [];
    const argv = new Proxy(['--verbose'], {
      get(target, key, receiver) {
        if (key === 'map' || key === 'length' || key === '0') {
          reads.push(key);
          checks.push(rejected(context, host.instance.call(undefined), 'REENTRY'));
          checks.push(rejected(context, host.instance.drain(), 'REENTRY'));
        }
        return Reflect.get(target, key, receiver);
      },
    });
    await nativeRun(context, host, argv);
    await Promise.all(checks);
    context.assert(reads.includes('length') && reads.includes('0'),
      'run argument regression did not inspect its real host Array');
    context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure')) === 42n,
      'run argument getter overwrote its published operation');

    for (const trigger of ['prototype', 'iterator']) {
      const hooks = [];
      let nested;
      const attempt = hook => {
        hooks.push(hook);
        if (hook === trigger && !nested) nested = admissionOutcome(context, host.call('allocation_gc'));
      };
      const bytes = new Proxy(binary(), {
        getPrototypeOf(target) { attempt('prototype'); return Reflect.getPrototypeOf(target); },
        get(target, key) {
          if (key === Symbol.iterator) {
            attempt('iterator');
            return function* () { yield* binary(); };
          }
          if (key === 'length' || key === '0') attempt(key);
          return Reflect.get(target, key, target);
        },
      });
      const outer = await admissionOutcome(context, host.call('typed_echo', true, 7n, 7, bytes));
      const attempted = await nested;
      const following = await admissionOutcome(context, host.call('valid_after_failure'));
      const report = {trigger, hooks, outer: admissionDescription(outer), nested: admissionDescription(attempted),
        following: admissionDescription(following), engineFailures: engineFailures.map(event =>
          ({kind: event.kind, code: event.cause.code, message: event.cause.message}))};
      context.stdout(encode('BRIDGE-ADMISSION ' + JSON.stringify(report) + '\n'));
      // Under runtime-type marshalling, a Proxy has no TypedArray slot and crosses
      // as is_handle without invoking Proxy traps; typed_echo then rejects it in Titan.
      context.assert(outer.status === 'rejected' && outer.error?.code === 'TITAN_BROWSER_TITAN',
        'Proxy bytes did not fail variant check in Titan: ' + JSON.stringify(report));
      context.assert(hooks.length === 0 && nested === undefined,
        'byte admission invoked substituting Proxy hooks');
      context.assert(engineFailures.length === 0 && following.status === 'fulfilled' && following.value === 42n,
        'byte argument inspection poisoned the instance or stranded its operation');
      const beforeErrors = host.notificationErrors.length;
      host.instance.notify(host.callbacks.get('typed_echo'), true, 7n, 7, bytes);
      context.assert(hooks.length === 0, 'notification byte admission invoked Proxy hooks');
      await host.instance.drain();
      context.assert(host.notificationErrors.length === beforeErrors + 1 &&
        host.notificationErrors.at(-1).error.code === 'TITAN_BROWSER_TITAN',
        'queued Proxy argument did not fail at delivery time');
      host.notificationErrors.pop();
    }

    const hooks = [], attempted = [];
    const attempt = name => {
      hooks.push(name);
      attempted.push(admissionOutcome(context, host.call('valid_after_failure')));
    };
    class HookBytes extends Uint8Array {}
    const backing = new Uint8Array([91, 92, ...binary(), 93]);
    const bytes = new HookBytes(backing.buffer, 2, 4);
    const native = {buffer: bytes.buffer, byteOffset: bytes.byteOffset,
      byteLength: bytes.byteLength, length: bytes.length};
    class HookConstructor {
      static get [Symbol.species]() { attempt('species'); return Uint8Array; }
    }
    for (const [key, value] of [...Object.entries(native), ['constructor', HookConstructor],
      ['slice', function() { attempt('slice-call'); return this; }],
      [Symbol.iterator, function* () { attempt('iterator-call'); yield* binary(); }]]) {
      Object.defineProperty(bytes, key, {get() { attempt(String(key)); return value; }});
    }
    const sources = [new Uint8Array(backing.buffer, 2, 4), bytes];
    if (typeof globalThis.Buffer === 'function') {
      sources.push(globalThis.Buffer.from([91, ...binary(), 93]).subarray(1, 5));
    }
    for (const source of sources) {
      source.set(binary());
      const copying = host.call('typed_echo', true, 8n, 8, source);
      source.fill(90);
      context.equalBytes(await copying, binary(), 'native byte view was not snapshotted at call time');
    }
    bytes.set(binary());
    host.instance.notify(host.callbacks.get('stdio_append'), bytes);
    bytes.fill(90);
    await host.instance.drain();
    context.equalBytes(host.stdout.at(-1), binary(), 'native byte view was not snapshotted at notify time');
    await host.instance.drain();
    await Promise.all(attempted);
    context.assert(hooks.length === 0, 'native byte copying consulted a substituting property/iterator/species');

    let coercions = 0;
    const coercing = {
      [Symbol.toPrimitive]() { coercions++; attempt('scalar coercion'); return 1n; },
      valueOf() { coercions++; attempt('scalar valueOf'); return 1n; },
    };
    for (const args of [[coercing, 1n, 1, binary()], [true, coercing, 1, binary()],
      [true, 1n, coercing, binary()]]) {
      await rejected(context, host.call('typed_echo', ...args), 'TITAN');
    }
    context.assert(coercions === 0 && hooks.length === 0, 'runtime-type marshalling invoked host coercion');
    const hostValues = await hostValueMaterialization(context, host);
    const reverseArguments = await reverseArgumentFailures(context, host);
    context.assert(engineFailures.length === 0 && host.notificationErrors.length === 0 &&
      (await host.call('valid_after_failure')) === 42n,
      'host-value materialization poisoned a later valid call or reported an unreturnable error');
    return {proxyBytes: 2, nativeByteViews: sources.length, strictScalars: 3,
      runGetters: reads.length, reverseArguments, ...hostValues};
  } finally {
    await host.instance?.dispose().catch(() => {});
    host.releaseObservations();
  }
}

async function reverseArgumentFailures(context, host) {
  const target = host.callbacks.get('handle_echo');
  let cases = 0;
  for (const method of ['instance', 'wrapper']) {
    const call = (...args) => method === 'instance' ?
      host.instance.call(target, ...args) : target.call(...args);
    await host.call('force_gc');
    await host.instance.drain();
    const beforeAllocation = host.controls.snapshot();
    const fault = host.controls.failAllocationAfter(1);
    try {
      const result = await admissionOutcome(context, call({first: method}, binary()));
      context.assert(result.status === 'rejected' && result.error instanceof RangeError &&
        fault.failed && fault.slotsAtFailure === beforeAllocation.slots + 1,
        `${method} allocation failure did not follow the first handle argument`);
    } finally { fault.restore(); }
    const afterAllocation = host.controls.snapshot();
    context.assert(afterAllocation.slots === beforeAllocation.slots &&
      afterAllocation.units === beforeAllocation.units,
      `${method} allocation failure leaked a reverse-call argument slot`);
    context.assert((await host.call('valid_after_failure')) === 42n);
    cases++;

    const wrapper = await host.call('make_callable');
    await host.call('force_gc');
    await host.instance.drain();
    const beforeRelease = host.controls.snapshot();
    const rejectedCall = call({first: method}, wrapper);
    wrapper.release();
    await rejected(context, rejectedCall, 'HANDLE');
    const afterRelease = host.controls.snapshot();
    context.assert(afterRelease.slots === beforeRelease.slots &&
      afterRelease.units === beforeRelease.units,
      `${method} released-wrapper failure leaked an earlier handle argument`);
    context.assert((await host.call('valid_after_failure')) === 42n);
    cases++;
  }
  return cases;
}

async function hostValueMaterialization(context, host) {
  const source = gate(), successes = host.successes.length, failures = host.failures.length;
  host.bindings.admission_result = formBinding({kind: 'detachable', promise: source.promise});
  await host.call('start_request', 'admission_result');
  source.resolve(41n);
  await context.tick();
  await host.instance.drain();
  context.assert(host.successes.length === successes + 1 && host.successes.at(-1)[0] === 41n &&
    host.failures.length === failures && host.controls.snapshot().requests === 0,
    'one-shot request settlement did not deliver its single value');
  await host.call('close_request');
  delete host.bindings.admission_result;

  const rejectedSource = gate();
  let messageReads = 0, coercions = 0, rejectedNested;
  const message = {[Symbol.toPrimitive](hint) {
    context.assert(hint === 'string', 'host rejection used a non-string coercion');
    coercions++;
    if (!rejectedNested) rejectedNested = admissionOutcome(context, host.call('valid_after_failure'));
    return 'host rejection reentry';
  }};
  const rejection = Object.freeze({get message() { messageReads++; return message; }});
  host.bindings.admission_rejection = formBinding({kind: 'detachable', promise: rejectedSource.promise});
  await host.call('start_request', 'admission_rejection');
  rejectedSource.reject(rejection);
  await context.tick();
  const rejectedCall = await rejectedNested;
  context.assert(messageReads > 0 && coercions === 1 && rejectedCall?.status === 'fulfilled' &&
    rejectedCall.value === 42n, 'request rejection message inspection lost its legitimate nested operation');
  await host.instance.drain();
  context.assert(host.failures.length === failures + 1 && host.failures.at(-1)[1] === rejection &&
    host.successes.length === successes + 1 && host.controls.snapshot().requests === 0,
    'reentering host rejection lost its original thrown identity or terminal retirement');
  context.equalBytes(host.failures.at(-1)[0], encode('host rejection reentry'));
  await host.call('close_request');
  delete host.bindings.admission_rejection;
  return {completionGetters: 1, rejectionCoercions: 1};
}

async function disposalMaterialization(context, image) {
  for (const ownership of ['detachable', 'listener']) {
    const engineFailures = [], host = createHost(context, image,
      {onEngineFailure(event) { engineFailures.push(event); }});
    const terminal = gate();
    let signals = 0, reentrant, observed;
    const cancel = () => {
      signals++;
      reentrant = host.instance.dispose();
      observed = admissionOutcome(context, reentrant);
    };
    try {
      await host.instance.initialize();
      await nativeRun(context, host);
      await host.call('close_detached');
      if (ownership === 'detachable') {
        host.bindings.admission_dispose = formBinding({kind: 'detachable', promise: terminal.promise, cancel});
        await host.call('start_request', 'admission_dispose');
      } else {
        host.bindings.listener = () => ({kind: 'listener', subscribe() { return cancel; }});
        await host.call('start_listener');
      }
      const disposing = host.instance.dispose();
      const outer = admissionOutcome(context, disposing);
      context.assert(reentrant === disposing, ownership + ' cancellation reentered before dispose promise publication');
      const [result, nested] = await Promise.all([outer, observed]);
      context.assert(result.status === 'fulfilled' && nested?.status === 'fulfilled' && signals === 1 &&
        host.controls.snapshot().requests === 0 && host.controls.snapshot().units === 0 &&
        host.closes.length === 2 && engineFailures.length === 0 && host.notificationErrors.length === 0,
        ownership + ' reentrant disposal duplicated cancellation/close or poisoned the engine');
      terminal.resolve(91n);
      await context.tick();
      context.assert(host.successes.length === 0 && host.failures.length === 0 && signals === 1,
        ownership + ' late settlement revived a disposed request');
    } finally {
      terminal.resolve(91n);
      await host.instance?.dispose().catch(() => {});
      host.releaseObservations();
    }
  }
  return {cancel: 1, unregister: 1};
}

async function values(context, host, completions) {
  context.assert((await host.call('read_capture')) === 0n);
  context.assert((await host.call('increment', 1n)) === 1n);
  context.assert((await host.call('increment', 2n)) === 3n);
  await host.call('force_gc');
  context.assert((await host.call('read_capture')) === 3n, 'collection reconstructed or lost original capture cells');
  context.assert((await host.call('one_nil')) === null, 'nil result was not null');
  context.assert((await host.call('one_nil', null)) === null, 'null argument was not is_nil');
  context.assert((await host.call('one_nil', undefined)) === null, 'undefined argument was not is_nil');
  const wide = Array.from({length: 10}, (_, index) => BigInt(index + 1));
  context.assert((await host.call('wide_sum', ...wide)) === 55n,
    'wide callback arguments lost protected dynamic storage');

  for (const integer of [-(1n << 63n), (1n << 63n) - 1n, (1n << 53n) - 1n,
    1n << 53n, (1n << 53n) + 1n, -(1n << 53n) - 1n]) {
    context.assert((await host.call('echo_value', integer)) === integer, 'BigInt roundtrip changed value');
    for (const number of [17, -0, NaN]) {
      context.assert(Object.is(await host.call('echo_value', number), number), 'Number roundtrip changed bits');
      const result = await host.call('typed_echo', false, integer, number, binary());
      context.equalBytes(result, binary());
    }
  }
  for (const text of ['', 'ascii', 'hello 🌍\0world', '\ufeffx', '\ufeff']) {
    context.assert((await host.call('echo_value', text)) === text, 'UTF-8 string roundtrip changed text');
  }
  await rejected(context, host.call('bad_utf8_result'), 'TITAN');
  const empty = await host.call('typed_echo', true, 0n, 0, new Uint8Array());
  context.equalBytes(empty, new Uint8Array());
  const large = new Uint8Array(34 * 1024 * 1024);
  large.set(binary()); large.set(binary(), large.length - 4);
  const grown = await host.call('typed_echo', true, 1n, 1, large);
  context.equalBytes(grown, large, 'JS-to-Titan bytes used a stale heap after growth');
  large.fill(91);
  context.equalBytes(grown.subarray(0, 4), binary(), 'returned bytes were a borrowed input view');
  const alias = new AliasingBytes(binary());
  const copying = host.call('typed_echo', true, 2n, 2, alias);
  alias.fill(90);
  context.equalBytes(await copying, binary(), 'call argument slice-as-view escaped snapshot ownership');

  // Out-of-range BigInts and ill-formed UTF-16 strings reject with TypeError before Wasm entry.
  for (const call of [
    () => host.call('echo_value', 1n << 63n),
    () => host.call('echo_value', -(1n << 63n) - 1n),
    () => host.call('echo_value', '\ud800'),
    () => host.call('echo_value', 'prefix\udfff'),
  ]) {
    const before = host.controls.snapshot().operationId;
    await rejected(context, call(), 'TypeError');
    context.assert(host.controls.snapshot().operationId === before, 'invalid BigInt/string reached Wasm');
  }

  // Variant rejections happen inside the Titan callable and reject with TITAN error + trace.
  for (const [call, expectedMessage] of [
    [() => host.call('typed_echo', false, 1, 0, binary()), 'expected BrowserValue.is_integer'],
    [() => host.call('typed_echo', 0, 1n, 0, binary()), 'expected BrowserValue.is_boolean'],
    [() => host.call('typed_echo', true, 1n, 1n, binary()), 'expected BrowserValue.is_float'],
    [() => host.call('typed_echo', true, 1n, 1, 'bytes'), 'expected BrowserValue.is_bytes'],
    [() => host.call('typed_echo', true, 1n, 1), 'typed_echo expects 4 arguments'],
    [() => host.call('one_nil', 1n), 'one_nil expects nil or no arguments'],
  ]) {
    const variantError = await captureRejection(context, call(), 'TITAN');
    context.equalBytes(variantError.bytes, encode(expectedMessage),
      'callable variant rejection did not carry the callable error message');
    context.assert(variantError.trace instanceof Uint8Array && variantError.trace.length > 0,
      'callable variant rejection omitted its Titan trace');
  }

  // Non-string error objects raised by callables use the base conversion rule and preserve original traces.
  for (const [mode, expectedMessage] of [
    [1n, '(error object is a boolean value)'],
    [2n, '(error object is a table value)'],
    [3n, 'custom error tostring'],
    [4n, 'error while reporting browser failure'],
    [5n, 'converted after inner catch'],
    [6n, '(error object is a userdata value)'],
    [7n, 'error while reporting browser failure'],
    [8n, '2.0'],
    [9n, '-0.0'],
    [10n, '42'],
    [11n, '2.5'],
    [12n, '(error object is a table value)'],
  ]) {
    const raisedError = await captureRejection(context, host.call('raise_error_kind', mode), 'TITAN');
    context.equalBytes(raisedError.bytes, encode(expectedMessage),
      `callable non-string error mode ${mode} returned wrong message: ${decode(raisedError.bytes)}`);
    const traceText = decode(raisedError.trace);
    context.assert(traceText.includes('tests.browser.titan') && !traceText.includes('inner_caught_worker'),
      `callable non-string error mode ${mode} lost or replaced its original trace: ${traceText}`);
    if (mode === 7n) {
      context.assert((await host.call('finish_invoke_oom')) > 0n, 'error-formatting OOM did not trigger');
    }
    context.assert((await host.call('valid_after_failure')) === 42n,
      `callable non-string error mode ${mode} damaged subsequent calls`);
  }
  await host.call('arm_invoke_oom', 1n);
  const invokeOomError = await captureRejection(context, host.call('echo_value', 1n), 'TITAN');
  context.equalBytes(invokeOomError.bytes, encode('not enough memory'));
  context.assert((await host.call('finish_invoke_oom')) > 0n, 'invoke setup OOM did not trigger');
  context.assert((await host.call('valid_after_failure')) === 42n, 'invoke setup OOM poisoned the instance');

  // invoke_entry leaves 15 free slots here; invoke_work's 34-slot preamble must grow.
  host.controls.failNextEntryStack('invoke', 22, 2);
  const preambleStackError = await captureRejection(context, host.call('echo_value', 1n), 'TITAN');
  context.equalBytes(preambleStackError.bytes, encode('not enough memory'));
  context.assert((await host.call('finish_invoke_oom')) > 0n, 'invoke preamble stack-growth OOM did not trigger');
  context.assert((await host.call('valid_after_failure')) === 42n, 'invoke preamble stack-growth OOM poisoned the instance');

  // With only 19 free slots, the trampoline's non-raising 20-slot check fails.
  const trampolineCompletions = [];
  const unwatchTrampoline = host.controls.watchCompletions(record => {
    trampolineCompletions.push({kind: record.kind, failed: record.failed});
  });
  try {
    host.controls.failNextEntryStack('invoke', 19, 2);
    const trampolineError = await captureRejection(context, host.call('echo_value', 1n), 'TITAN');
    context.equalBytes(trampolineError.bytes, encode('not enough memory'));
    context.assert(trampolineError.trace.length === 0 &&
      trampolineCompletions.length === 1 && trampolineCompletions[0].kind === 3 &&
      trampolineCompletions[0].failed, 'invoke trampoline did not emit exactly one untraced fallback');
  } finally { unwatchTrampoline(); }
  context.assert((await host.call('finish_invoke_oom')) === 1n, 'invoke trampoline stack check did not fail once');
  context.assert((await host.call('valid_after_failure')) === 42n, 'invoke trampoline failure poisoned the instance');
  const object = Object.freeze({opaque: true});
  const jsFn = x => x + 1n;
  for (const value of [object, jsFn]) {
    const result = await host.call('handle_echo', value);
    context.assert(Object.is(result, value), 'BrowserHandle carrier lost raw value identity');
  }
  // A forever-pending Promise returned in a BrowserHandle is adopted by the user-facing
  // promise, but must not hold logical admission or disposal open.
  host.opaquePromise = new Promise(() => {});
  const pendingOpaque = host.call('handle_echo', host.opaquePromise);
  await until(context, () => host.controls.snapshot().safe && !host.controls.snapshot().owner && !host.controls.snapshot().active,
    'forever-pending Promise result held internal operation admission open');
  context.assert(pendingOpaque instanceof Promise);

  const original = host.callbacks.get('increment');
  context.assert((await host.call('callable_echo', original)) === original, 'callable result reconstructed its wrapper/root');
  const error = await captureRejection(context, host.call('titan_failure'), 'TITAN');
  context.equalBytes(error.bytes, new Uint8Array([...encode('Titan bridge failure'), 0, 255]));
  const trace = decode(error.trace);
  const originalFrame = /^tests\.browser\.titan(?::(\d+))?: in anonymous function at (?:.*[\\/])?tests\.browser\.titan:(\d+)(?:\n|$)/.exec(trace);
  // The publisher has returned; the retained inline closure is the error site.
  // WebKit preserves its function name without a program-counter source line.
  context.assert(error.trace instanceof Uint8Array && originalFrame &&
    (!originalFrame[1] || originalFrame[1] === originalFrame[2]),
    `Titan callback failure lost its original source trace: ${JSON.stringify(trace)}`);
  context.assert((await host.call('valid_after_failure')) === 42n, 'ordinary Titan error poisoned later calls');
  context.assert((await host.call('resume_single', 71n)) === 71n, 'later C entry did not restore a parked coroutine');
  context.assert((await host.call('resume_stacked', 72n)) === 72n, 'later C entry did not restore the real STACKED chain');

  host.hooks.cleanup = () => {
    host.checks.push(rejected(context, host.call('valid_after_failure'), 'REENTRY'));
    host.checks.push(rejected(context, host.instance.drain(), 'REENTRY'));
    const pointer = host.controls.allocate(32);
    context.assert(pointer !== 0, 'C-only allocation was not callable during an import');
    host.controls.free(pointer);
  };
  context.assert((await host.call('allocation_gc')) === 42n && host.cleanup === 1,
    'apparently nonyielding callback did not complete allocation-triggered abandonment cleanup');
  await Promise.all(host.checks);
  host.hooks.cleanup = undefined;
  const beforeClosed = host.controls.snapshot().operationId;
  await rejected(context, host.instance.call(host.callbacks.get('independent_1'), 1n), 'HANDLE');
  await rejected(context, host.instance.call(host.callbacks.get('independent_2'), 1n), 'HANDLE');
  await rejected(context, host.call('callable_echo', host.callbacks.get('independent_3')), 'HANDLE');
  context.assert(host.controls.snapshot().operationId === beforeClosed, 'closed/cross-state argument entered Wasm');
  context.assert((await host.call('independent_3', 4n)) === 7n, 'detaching independently owned state invalidated it early');
  await host.call('close_detached');
  await host.call('close_detached');
  await rejected(context, host.instance.call(host.callbacks.get('independent_3'), 4n), 'HANDLE');
  context.assert(host.independentCloses.length === 6 && host.forbiddenRequests === 0,
    'explicit/GC/detach close did not run each coroutine finalizer exactly once');
  for (const index of [1n, 2n, 3n]) {
    finalizedState(context, host, index);
    const closed = host.independentCloses.filter(entry => entry.index === index);
    context.assert(closed.length === 2 && closed.some(entry => entry.value === host.bindings.close_value) &&
      closed.some(entry => entry.value === host.thrown.throw_value), 'independent close lost close-phase JS values');
    const states = host.controls.snapshot().states;
    context.assert(closed.every(entry => entry.closingTokens.every(token =>
      states.some(state => state.token === token && state.closed && !state.closing))),
      'independent state did not transition from closing to closed');
  }
  context.assert(completions.every((entry, index) => entry.id > 0n && (!index || entry.id > completions[index - 1].id)),
    'contained C entries reused or reordered operation identities');
}

async function resultRepairs(context, host, engineFailures) {
  let invalidations = 0;
  try {
    // 1. Handle invalidated during an active import before return rejects under protection.
    const handleResult = await host.call('r1_prepare_handle');
    context.assert(handleResult === host.bindings.r1_handle_first, 'R1 live handle result lost its actual host owner');
    host.hooks.r1Release = selected => {
      context.assert(selected === 1n, 'R1 handle invalidation targeted wrong position');
      context.assert(host.controls.invalidateHandle(handleResult) === 1, 'R1 handle invalidation did not own one real unit');
      invalidations++;
    };
    await rejected(context, host.call('r1_release_results', 1n), 'TITAN');
    context.assert(invalidations === 1, 'R1 handle failure bypassed active-import invalidation');

    // 2. Re-export after synchronous wrapper release returns a fresh working wrapper.
    const callableResult = await host.call('r1_prepare_callable');
    context.assert((await callableResult.call()) === 101n, 'R1 live callable result lost its original closure');
    host.hooks.r1Release = selected => {
      context.assert(selected === 2n, 'R1 callable release targeted wrong position');
      callableResult.release();
      invalidations++;
    };
    const reexported = await host.call('r1_release_results', 2n);
    context.assert(reexported !== callableResult && (await reexported.call()) === 101n,
      're-export after release did not issue a fresh working wrapper');
    await rejected(context, callableResult.call(), 'DISPOSED');
    reexported.release();
    await host.instance.drain();

    // A due collector must not re-export the released function inside release().
    const dueRelease = await host.call('make_callable');
    let freshAfterGc;
    host.hooks.r1Release = value => {
      if (value !== undefined) { freshAfterGc = value; return; }
      dueRelease.release();
      return freshAfterGc === undefined;
    };
    context.assert((await host.call('release_with_gc_due')) === true,
      'a due finalizer ran inside synchronous wrapper release');
    context.assert(freshAfterGc && freshAfterGc !== dueRelease &&
      (await freshAfterGc.call()) === 77n,
      'the finalizer did not re-export a fresh working wrapper after retirement');
    await rejected(context, dueRelease.call(), 'DISPOSED');
    freshAfterGc.release();

    const pausedRelease = await host.call('make_callable');
    host.hooks.r1Release = () => pausedRelease.release();
    context.assert((await host.call('release_with_gc_paused')) === true,
      'synchronous release cleared a user GC pause');
    await rejected(context, pausedRelease.call(), 'DISPOSED');

    // 3. Handle or callable invalidated by a GC finalizer after encoding and before completion rejects under protection.
    for (const position of [1n, 2n]) {
      const prepared = await host.call(position === 1n ? 'r1_prepare_handle' : 'r1_prepare_callable');
      const before = invalidations;
      host.hooks.r1Release = selected => {
        context.assert(selected === position, 'R1 GC invalidation targeted wrong position');
        if (selected === 1n) {
          context.assert(host.controls.invalidateHandle(prepared) === 1, 'R1 GC handle invalidation did not own one unit');
        } else {
          prepared.release();
        }
        invalidations++;
      };
      await rejected(context, host.call('r1_gc_results', position), 'TITAN');
      context.assert(invalidations === before + 1, 'R1 GC failure bypassed active-import invalidation');
      context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure')) === 42n,
        'stale GC result identity poisoned an intact image instead of rejecting under protection');
    }

    // 4. Pin held by wrapper + request + listener survives until all three holders drop their holds.
    const holdSource = gate();
    let holdEmit;
    host.hooks.pinHoldRequest = () => ({kind: 'detachable', promise: holdSource.promise});
    host.hooks.pinHoldListener = () => ({kind: 'listener', subscribe(emit) {
      holdEmit = emit;
      return () => { holdEmit = undefined; };
    }});
    const sharedWrapper = await host.call('prepare_pin_holders');
    const sharedAgain = await host.call('callable_echo', sharedWrapper);
    context.assert(sharedAgain === sharedWrapper, 'pinned callable did not keep one wrapper identity');
    context.assert((await sharedWrapper.call(10n)) === 1n && host.successes.at(-1)[0] === 11n);
    sharedWrapper.release();
    await host.instance.drain();
    context.assert((await host.call('pin_holders_collected')) === 0n,
      'wrapper release dropped a pin still held by an active request and listener');
    holdSource.resolve(50n);
    await context.tick();
    await host.instance.drain();
    context.assert(host.successes.at(-1)[0] === 51n && (await host.call('pin_holders_collected')) === 0n,
      'the one-shot callback dropped a pin still held by an active listener');
    holdEmit(60n);
    await host.instance.drain();
    context.assert(host.successes.at(-1)[0] === 61n);
    await host.call('close_pin_holders');
    await host.instance.drain();
    context.assert((await host.call('pin_holders_collected')) === 3n,
      'closing the last holder did not drop the completion and failure pins');
    host.successes.length = 0;
    // 5. Listener close drops its holds before a failed wrapper re-export (R-H4).
    host.hooks.pinHoldListener = () => ({kind: 'listener', subscribe() { return () => {}; }});
    await host.call('lost_release_regression');
    await host.instance.drain();
    context.assert((await host.call('pin_holders_collected')) === 64n,
      'failed wrapper re-export retained a closed listener callback');

    // 6. Wrapper exposed to host JS before the host throws, returns an unmarshallable value, or refuses start stays live (R-H5).
    for (const mode of [1n, 2n, 3n]) {
      const collectedBeforeRelease = await host.call('test_host_saved_wrapper', mode);
      context.assert(collectedBeforeRelease === (mode === 3n ? 30n : 0n),
        `saved-wrapper mode ${mode} did not preserve exposed wrapper or roll back unexposed request holds`);
      context.assert(host.savedCallable && (await host.savedCallable.call(21n)) === 42n,
        `saved-wrapper mode ${mode} revoked a wrapper already handed to host JavaScript`);
      host.savedCallable.release();
      host.savedCallable = undefined;
      await host.instance.drain();
      context.assert((await host.call('pin_holders_collected')) === (mode === 3n ? 133n : 100n + mode),
        `saved-wrapper mode ${mode} did not retire after explicit release()`);
    }

    // R-H5: nested finalizer hostCall during marshalling does not expose the outer crossing's provisional callable.
    const nestedErr = await captureRejection(context, host.call('nested_finalizer_rollback', 0n), 'TITAN');
    context.equalBytes(nestedErr.bytes, encode('browser identity is released or belongs to a closed state'));
    context.assert((await host.call('nested_finalizer_ran')) === true,
      'nested finalizer did not execute its hostCall during marshalling');
    const nestedCollected = await host.call('pin_holders_collected');
    context.assert(nestedCollected === 88n,
      `nested finalizer hostCall exposed outer provisional callable and leaked its capture (got ${nestedCollected})`);

    // R-H3(b): outer invoke handler after inner-handler OOM rolls back provisional callable and emits fallback completion.
    const outerInvokeErr = await captureRejection(context, host.call('nested_finalizer_rollback', 1n), 'TITAN');
    context.equalBytes(outerInvokeErr.bytes, encode('not enough memory'));
    context.assert((await host.call('finish_invoke_oom')) === 2n,
      'outer invoke OOM did not fail both the error handler and the inner reporting helper');
    context.assert((await host.call('nested_finalizer_ran')) === true,
      'outer invoke OOM test did not execute nested finalizer before OOM');
    context.assert((await host.call('pin_holders_collected')) === 77n,
      'outer invoke OOM leaked provisional callable capture');
    context.assert((await host.call('valid_after_failure')) === 42n, 'outer invoke OOM poisoned the instance');

    // The input includes the base-function slot: 21 refuses admission.
    // At 22, the handler and 2-slot entry leave 18 slots, so apply_release
    // must grow its 18-slot frame under catch; 23 leaves 19 and retires.
    for (const [freeSlots, weight, status, retired] of [
      [21, 55n, 4, false], [22, 66n, 0, false], [23, 77n, 0, true],
    ]) {
      const wrapper = await host.call('make_pinned_wrapper', weight);
      const records = [], beforeErrors = host.notificationErrors.length;
      const beforeId = host.controls.snapshot().operationId;
      const unwatch = host.controls.watchCompletions(record => records.push(record));
      try {
        const attempt = host.controls.failNextEntryStack('release_callable', freeSlots, 2);
        context.assert(wrapper.release() === undefined, 'synchronous release did not return normally');
        context.assert(attempt.status === status,
          `release with stack input ${freeSlots} reached the wrong admission branch`);
        context.assert(records.length === 0 && host.controls.snapshot().operationId === beforeId,
          'synchronous release emitted a completion or consumed an entry identity');
      } finally { unwatch(); }
      await host.instance.drain();
      const failures = await host.call('finish_invoke_oom');
      context.assert(retired ? failures === 0n : failures > 0n,
        `release with stack input ${freeSlots} had the wrong allocation outcome`);
      context.assert((await host.call('pin_holders_collected')) === (retired ? weight : 0n),
        `release with stack input ${freeSlots} had the wrong pin retirement outcome`);
      context.assert(host.notificationErrors.length === beforeErrors &&
        (await host.call('valid_after_failure')) === 42n,
        `release with stack input ${freeSlots} poisoned the instance or reported an error`);
    }
  } finally {
    host.hooks.r1Release = undefined;
    host.hooks.pinHoldRequest = host.hooks.pinHoldListener = undefined;
  }
  const recovered = host.callbacks.get('r1_publication_recovery');
  context.assert((await recovered.call()) === 42n, 'failed provisional publication prevented later recovery');
  recovered.release();
  await host.instance.drain();
  const before = host.controls.snapshot().operationId;
  await rejected(context, host.instance.call(recovered), 'HANDLE');
  context.assert(host.controls.snapshot().operationId === before, 'released publication-recovery root entered Wasm');
  await host.call('r1_close_publication');
  context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure')) === 42n,
    'publication rollback/recovery/close poisoned the persistent owner');
  return {activeReleasePositions: 2, laterGcPositions: 2, publicationRecovery: 1};
}

async function responseRepairs(context, host, engineFailures) {
  await host.call('r1_setup_responses');
  await host.call('force_gc');
  const units = host.controls.snapshot().units;
  let restore;
  try {
    for (const mode of ['normal', 'memory-zero', 'owner-allocation']) {
      let armed = false;
      host.r1Thrown = mode === 'owner-allocation' ? Object.freeze({
        get message() {
          if (!armed) { armed = true; host.controls.armResponseOwnerFailure(); }
          return 'R1 real thrown owner allocation failure';
        },
      }) : Object.freeze({message: 'R1 real thrown value', mode});
      const original = host.r1Thrown;
      const before = host.r1Responses.length;
      if (mode === 'memory-zero') restore = host.controls.exhaustSlotIdentities();
      try {
        const attempts = await host.call('r1_response_call');
        context.assert(attempts === (mode === 'owner-allocation' ? 2n : 0n),
          'R1 response fault did not exercise its real native allocation/retry boundary');
      }
      finally { restore?.(); restore = undefined; }
      context.assert(host.r1Responses.length === before + 1, 'R1 response failure did not reach its native observer exactly once');
      const observed = host.r1Responses.at(-1);
      context.stdout(encode('BRIDGE-RESPONSE ' + JSON.stringify({mode, hasThrown: observed.hasThrown,
        nullValue: observed.value === null, originalValue: observed.value === original,
        beforeUnits: units, observedUnits: observed.units, afterUnits: host.controls.snapshot().units}) + '\n'));
      context.assert(observed.message instanceof Uint8Array && observed.message.length > 0,
        'R1 contained response failure lost its counted message');
      if (mode === 'normal') {
        context.assert(observed.hasThrown === true && observed.value === original && observed.units === units + 1,
          'real returned thrown unit was not adopted exactly once with its original value');
      } else {
        context.assert(observed.hasThrown === false && observed.value === null && observed.units === units,
          `MEMORY/owner-allocation failure fabricated an owner or failed its real-unit rollback: ${mode}; hasThrown=${observed.hasThrown}; null=${observed.value === null}; units=${observed.units}/${units}`);
        if (mode === 'owner-allocation') context.assert(armed, 'native owner allocation failure was not armed after a real thrown unit');
      }
      context.assert(host.controls.snapshot().units === units && engineFailures.length === 0 &&
        (await host.call('valid_after_failure')) === 42n,
        'response failure leaked/adopted zero, poisoned the image, or prevented later recovery');
    }
  } finally {
    restore?.();
    host.r1Thrown = host.hooks.r1Throw = undefined;
  }
  return {memoryWithoutOwner: 1, realOwnerAdoption: 1, realOwnerRollback: 1};
}

async function admissionRepairs(context, host, engineFailures) {
  await host.call('r1_prepare_admissions');
  let restore;
  try {
    for (const name of ['r1_admit_start', 'r1_admit_listener']) {
      await host.call('r1_close_admission');
      await host.call('force_gc');
      const source = gate();
      let accepted = 0, cancelled = 0;
      host.hooks.r1Start = () => {
        accepted++;
        return {kind: 'retained', promise: source.promise, cancel() { cancelled++; }};
      };
      host.hooks.r1Listen = () => {
        accepted++;
        return {kind: 'listener', subscribe() { return () => { cancelled++; }; }};
      };
      const before = host.controls.snapshot();
      const counts = [host.successes.length, host.failures.length, host.stdout.length];
      restore = host.controls.exhaustSlotIdentities();
      try {
        await rejected(context, host.call(name), 'TITAN');
      } finally { restore(); restore = undefined; }
      context.assert(accepted === 0 && cancelled === 0 && host.controls.snapshot().requests === 0 &&
        host.controls.snapshot().units === before.units && host.stdout.length === counts[2],
        'slot refusal occurred after host acceptance: ' + name);
      source.resolve(96n);
      await context.tick(); await host.instance.drain();
      context.assert(host.successes.length === counts[0] && host.failures.length === counts[1],
        'unaccepted request produced a terminal notification: ' + name);
      context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure')) === 42n,
        'request-unit refusal poisoned later admission: ' + name);
    }

    for (const ownership of ['detachable', 'retained']) {
      await host.call('r1_close_admission');
      await host.call('force_gc');
      const source = gate(), before = host.controls.snapshot();
      const successes = host.successes.length, failures = host.failures.length;
      let accepted = 0, cancelled = 0;
      host.hooks.r1Start = () => {
        accepted++;
        restore = host.controls.exhaustSlotIdentities();
        return {kind: ownership, promise: source.promise, cancel() { cancelled++; }};
      };
      try { await host.call('r1_admit_start'); }
      finally { restore?.(); restore = undefined; }
      context.assert(accepted === 1 && host.controls.snapshot().requests === 1 &&
        host.controls.snapshot().units === before.units + 1, 'accepted request did not publish its already reserved unit');
      await host.call('r1_cancel_admission');
      await host.call('r1_cancel_admission');
      context.assert(cancelled === 1 && host.controls.snapshot().requests === (ownership === 'retained' ? 1 : 0),
        'reserved-unit cancellation lost detachable/physical-retirement semantics');
      if (ownership === 'retained') source.reject(Object.freeze({r1: 'cancelled retained rejection'}));
      else source.resolve(97n);
      await context.tick(); await host.instance.drain();
      await host.call('r1_close_admission');
      context.assert(host.controls.snapshot().requests === 0 && host.controls.snapshot().units === before.units &&
        host.successes.length === successes && host.failures.length === failures,
        'cancelled reserved owner leaked a unit or admitted late settlement');
    }

    await host.call('force_gc');
    const units = host.controls.snapshot().units, successes = host.successes.length;
    let accepted = 0, subscribed = 0, unregistered = 0, late;
    host.hooks.r1Listen = () => {
      accepted++;
      restore = host.controls.exhaustSlotIdentities();
      return {kind: 'listener', subscribe(emit) {
        subscribed++; late = emit; emit(98n, binary());
        return () => { unregistered++; };
      }};
    };
    try { await host.call('r1_admit_listener'); }
    finally { restore?.(); restore = undefined; }
    context.assert(accepted === 1 && subscribed === 1 && host.successes.length === successes,
      'reserved listener entered its synchronous event inline');
    await host.instance.drain();
    context.assert(host.successes.length === successes + 1 && host.successes.at(-1)[0] === 98n,
      'reserved listener lost its synchronous event after publication');
    await host.call('r1_cancel_admission');
    await host.call('r1_close_admission');
    late(99n, binary());
    await context.tick(); await host.instance.drain();
    context.assert(unregistered === 1 && host.successes.length === successes + 1 &&
      host.controls.snapshot().requests === 0 && host.controls.snapshot().units === units,
      'reserved listener unregister or late-event/unit retirement was not exact');

  } finally {
    restore?.();
    host.hooks.r1Start = host.hooks.r1Listen = undefined;
  }
  return {rejectedBeforeAcceptance: 2, acceptedStarts: 2, acceptedListeners: 1};
}

async function notifications(context, host, completions) {
  let announcements = 0;
  host.hooks.requestDrain = () => {
    const snapshot = host.controls.snapshot();
    context.assert(snapshot.safe && !snapshot.owner, 'requestDrain ran in a Wasm import/private hop');
    announcements++;
  };
  const callback = host.callbacks.get('notification');
  host.hooks.notification = number => {
    host.checks.push(rejected(context, host.call('valid_after_failure'), 'REENTRY'));
    if (number === 1n) host.instance.notify(callback, 3n);
  };
  const before = host.controls.snapshot();
  for (const invalidArg of [1n << 63n, -(1n << 63n) - 1n, '\ud800']) {
    let threwTypeError = false;
    try { host.instance.notify(callback, invalidArg); }
    catch (cause) { threwTypeError = cause instanceof TypeError; }
    context.assert(threwTypeError, 'notify() did not throw TypeError for unmarshallable argument');
  }
  for (const number of [1n, -1n, 2n]) host.instance.notify(callback, number);
  const queued = host.controls.snapshot();
  context.assert(queued.operationId === before.operationId && queued.slots === before.slots &&
    queued.units === before.units && announcements === 0, 'notification enqueue entered Wasm/allocated slots/reported inline');
  await context.tick();
  context.assert(announcements === 1, 'requestDrain did not coalesce one queued batch');
  await host.instance.drain();
  context.assert(host.notifications.join(',') === '1,-1,2', 'drain consumed a next-batch import enqueue or lost FIFO order');
  context.assert(host.notificationErrors.length === 1 && host.notificationErrors[0].kind === 'callback' &&
    host.notificationErrors[0].operation === 'drain' &&
    host.notificationErrors[0].error.code === 'TITAN_BROWSER_TITAN',
    'handler failure did not reach its tagged notification error observer');
  await host.instance.drain();
  await Promise.all(host.checks);
  context.assert(host.notifications.join(',') === '1,-1,2,3', 'next detached batch did not deliver exactly once');
  host.hooks.notification = undefined;
  const observerFailure = new Error('notification observer failed');
  host.hooks.notificationError = () => { throw observerFailure; };
  host.instance.notify(callback, -1n);
  host.instance.notify(callback, 4n);
  const reported = await captureRejection(context, host.instance.drain(), 'HOST');
  context.assert(reported.cause === observerFailure && host.notifications.at(-1) === 4n,
    'notification observer exception escaped its host boundary or abandoned later entries');
  host.hooks.notificationError = undefined;
  context.assert((await host.call('valid_after_failure')) === 42n, 'notification observer error poisoned the owner');

  let target = await host.call('make_callable');
  const sameTarget = await host.call('reexport_callable');
  context.assert(sameTarget === target, 're-exporting a live callable created a duplicate wrapper');
  const beforeTarget = completions.filter(record => record.kind === 3).length;
  host.instance.notify(target);
  target.release(); target.release();
  await host.instance.drain();
  context.assert(completions.filter(record => record.kind === 3).length === beforeTarget,
    'released notification target still entered Lua');
  await rejected(context, target.call(), 'DISPOSED');
  await rejected(context, host.instance.call(target), 'HANDLE');
  context.assert((await host.call('valid_after_failure')) === 42n,
    'released callable poisoned the owner');
  const previous = target;
  target = await host.call('make_callable');
  context.assert(target !== previous && (await target.call()) === 77n, 'reused callable generation revived its old wrapper');
  const beforeArgument = completions.filter(record => record.kind === 3).length;
  host.instance.notify(host.callbacks.get('callable_echo'), target);
  target.release();
  await host.instance.drain();
  context.assert(completions.filter(record => record.kind === 3).length === beforeArgument &&
    host.notificationErrors.at(-1).kind === 'callback' && host.notificationErrors.at(-1).operation === 'drain' &&
    host.notificationErrors.at(-1).error.code === 'TITAN_BROWSER_HANDLE',
    'released queued argument entered Lua or was not reported');

  const references = await prepareNotificationCollection(context, host);
  await collected(context, references, 'notifications(opaque argument)', ['Object']);
  host.hooks.requestDrain = undefined;
  return announcements;
}

async function prepareNotificationCollection(context, host) {
  let opaque = {queue: 'retire without delivery'};
  const reference = new WeakRef(opaque);
  const handleTarget = host.callbacks.get('handle_echo');
  const slots = host.controls.snapshot().slots;
  host.instance.notify(handleTarget, opaque);
  opaque = undefined;
  context.assert(host.controls.snapshot().slots === slots, 'raw JS notification input eagerly allocated a table slot');
  handleTarget.release();
  await host.instance.drain();
  return [reference];
}

// Kept-open request owners must not keep the callables after Titan ends delivery.
async function requestHolds(context, host) {
  const prepare = (name, listener = false) => host.call('prepare_request_lifetime', name, listener);
  const collectedPins = () => host.call('pin_holders_collected');
  const errors = host.notificationErrors.length;
  let source = gate();
  host.bindings.lifetime_request = () => ({kind: 'detachable', promise: source.promise});
  await prepare('lifetime_request');
  context.assert(await collectedPins() === 0n, 'an active request lost its captures');
  source.resolve(101n);
  await context.tick(); await host.instance.drain();
  context.assert(await collectedPins() === 3n, 'a delivered one-shot kept captures until close');
  await host.call('close_request');

  source = gate();
  await prepare('lifetime_request');
  await host.call('cancel_request');
  context.assert(await collectedPins() === 3n, 'a cancelled one-shot kept captures until close');
  await host.call('close_request');

  // A settled request is retired on the host, but cancel still drops its queued event.
  source = gate();
  await prepare('lifetime_request');
  const successes = host.successes.length;
  source.resolve(102n);
  await context.tick();
  await host.call('cancel_request');
  await host.instance.drain();
  context.assert(host.successes.length === successes && await collectedPins() === 3n,
    'cancel after settlement delivered an event or kept its captures');
  await host.call('close_request');

  source = gate();
  await prepare('lifetime_request');
  const wrapper = await host.call('make_pinned_wrapper', 0n);
  source.resolve(wrapper);
  await context.tick();
  wrapper.release();
  const failures = host.failures.length;
  let announced = 0;
  host.hooks.requestDrain = () => { announced++; };
  await host.instance.drain();
  context.assert(host.failures.length === failures && announced > 0,
    'unmarshallable settlement retried in place or failed to announce its queued failure');
  await host.instance.drain();
  context.assert(host.failures.length === failures + 1 &&
    host.failures.at(-1)[1].code === 'TITAN_BROWSER_HANDLE' &&
    decode(host.failures.at(-1)[0]) === host.failures.at(-1)[1].message &&
    await collectedPins() === 3n, 'delivery marshalling failure did not reach failure and drop holds');
  host.hooks.requestDrain = undefined;
  await host.call('close_request');

  let emit;
  host.bindings.lifetime_listener = () => ({kind: 'listener', subscribe(callback) {
    emit = callback;
    return () => { emit = undefined; };
  }});
  await prepare('lifetime_listener', true);
  const argument = await host.call('make_pinned_wrapper', 0n);
  emit(argument);
  emit(103n);
  argument.release();
  const listenerFailures = host.failures.length;
  await host.instance.drain();
  context.assert(host.successes.at(-1)[0] === 103n && host.failures.length === listenerFailures &&
    await collectedPins() === 0n, 'listener failure displaced an already queued emission or dropped holds');
  await host.instance.drain();
  context.assert(host.failures.length === listenerFailures + 1 && await collectedPins() === 0n,
    'listener delivery failure did not keep its callable holds');
  emit(104n);
  await host.instance.drain();
  context.assert(host.successes.at(-1)[0] === 104n, 'listener stopped after a marshalling failure');
  await host.call('cancel_request');
  context.assert(await collectedPins() === 3n, 'listener cancel kept captures until close');
  await host.call('close_request');
  context.assert(host.notificationErrors.length === errors, 'request delivery failure reached the observer');

  // D8: idle delivery has no Titan stack on a double fault; close ends the holds.
  source = gate();
  await prepare('lifetime_request');
  source.resolve(null);
  await context.tick();
  const restore = host.controls.failNextAllocations(2);
  try {
    await host.instance.drain();
    await host.instance.drain();
  } finally { restore(); }
  context.assert(host.notificationErrors.length === errors + 1 &&
    host.notificationErrors.at(-1).kind === 'callback' &&
    host.notificationErrors.at(-1).operation === 'drain' && await collectedPins() === 0n,
    'idle double fault did not report once and retain the callables');
  await host.call('close_request');
  context.assert(await collectedPins() === 3n, 'close did not release idle double-fault holds');
  // Injected JavaScript Error stack frames retain the fixture's Module closure.
  // Discard only this case's observations before the later whole-image GC proof.
  host.notificationErrors.length = errors;
  host.failures.length = failures;
  delete host.bindings.lifetime_request;
  delete host.bindings.lifetime_listener;
}

async function requests(context, host) {
  const rejection = Object.freeze({request: 'original rejection'});
  const source = gate();
  host.bindings.success_request = formBinding({kind: 'detachable', promise: source.promise});
  await host.call('start_request', 'success_request');
  let snapshot = host.controls.snapshot();
  source.resolve(23n);
  await context.tick();
  context.assert(host.successes.length === 0 && host.controls.snapshot().operationId === snapshot.operationId &&
    host.controls.snapshot().slots === snapshot.slots, 'request settlement entered Lua or eagerly allocated a slot');
  await host.instance.drain();
  context.assert(host.successes.length === 1 && host.successes[0].length === 1 && host.successes[0][0] === 23n);
  await host.call('close_request');

  const failed = gate();
  host.bindings.failure_request = formBinding({kind: 'detachable', promise: failed.promise});
  await host.call('start_request', 'failure_request');
  snapshot = host.controls.snapshot();
  const errors = host.notificationErrors.length;
  failed.reject(rejection);
  await context.tick();
  context.assert(host.failures.length === 0 && host.controls.snapshot().slots === snapshot.slots &&
    host.controls.snapshot().operationId === snapshot.operationId, 'request rejection bypassed copied notification admission');
  await host.instance.drain();
  context.assert(host.failures.length === 1 && host.failures[0][1] === rejection && host.notificationErrors.length === errors,
    'host rejection did not reach exactly its mandatory failure callable with original thrown identity');
  await host.call('close_request');

  // Primitive rejection still arrives as a BrowserHandle in the failure callable (M9).
  const primitiveFailed = gate();
  host.bindings.primitive_failure_request = formBinding({kind: 'detachable', promise: primitiveFailed.promise});
  await host.call('start_request', 'primitive_failure_request');
  primitiveFailed.reject('primitive rejection string');
  await context.tick();
  await host.instance.drain();
  context.assert(host.failures.length === 2 && host.failures[1][1] === 'primitive rejection string',
    'primitive host rejection was not wrapped as a BrowserHandle for the failure callable');
  await host.call('close_request');

  // Failure callable that rejects its arguments fails at delivery time via onNotificationError.
  const badFailureGate = gate();
  host.bindings.bad_failure_request = formBinding({kind: 'detachable', promise: badFailureGate.promise});
  await host.call('start_bad_failure_request', 'bad_failure_request');
  const beforeBadErrors = host.notificationErrors.length;
  badFailureGate.reject(rejection);
  await context.tick();
  await host.instance.drain();
  context.assert(host.notificationErrors.length === beforeBadErrors + 1 &&
    host.notificationErrors.at(-1).kind === 'callback' &&
    host.notificationErrors.at(-1).operation === 'drain' &&
    host.notificationErrors.at(-1).error.code === 'TITAN_BROWSER_TITAN',
    'failure callable rejecting its arguments did not report at delivery through onNotificationError');
  await host.call('close_request');

  const duplicate = {then(resolve, reject) { resolve(24n); resolve(25n); reject(rejection); }};
  host.bindings.duplicate_request = formBinding({kind: 'detachable', promise: duplicate});
  await host.call('start_request', 'duplicate_request');
  await context.tick(); await host.instance.drain();
  context.assert(host.successes.length === 2 && host.successes.at(-1)[0] === 24n && host.failures.length === 2,
    'request terminal settlement was not at-most-once');
  await host.call('close_request');

  const cancelled = gate();
  let cancels = 0;
  host.bindings.cancel_request = formBinding({kind: 'detachable', promise: cancelled.promise, cancel() { cancels++; }});
  await host.call('start_request', 'cancel_request');
  await host.call('cancel_request'); await host.call('cancel_request');
  cancelled.resolve(26n);
  await context.tick(); await host.instance.drain();
  context.assert(cancels === 1 && host.successes.length === 2 && host.controls.snapshot().requests === 0,
    'logical cancellation was duplicated or admitted late settlement');
  await host.call('close_request');

  const never = gate();
  host.bindings.never_request = formBinding({kind: 'detachable', promise: never.promise});
  await host.call('start_request', 'never_request');
  await host.call('cancel_request'); await host.call('close_request');
  host.retainedPromise = never.promise; // Kept externally through post-disposal GC.

  const initial = host.successes.length;
  await host.call('start_listener');
  context.assert(host.successes.length === initial, 'synchronously fired listener entered inline');
  await host.instance.drain();
  context.assert(host.successes.at(-1).length === 2 && host.successes.at(-1)[0] === 31n);
  context.equalBytes(host.successes.at(-1)[1], binary());
  for (const emit of host.listeners) { emit(32n, binary()); emit(33n, binary()); }
  await host.instance.drain();
  context.assert(host.successes.slice(initial).map(item => item[0]).join(',') === '31,32,33', 'listener events lost FIFO order');
  await host.call('cancel_request'); await host.call('close_request');
  for (const emit of host.retainedListeners) emit(34n, binary());
  await context.tick(); await host.instance.drain();
  context.assert(host.unregisters === 1 && host.listeners.size === 0 && host.successes.length === initial + 3,
    'listener unregister or late-event retirement was not exact');
  // Unmarshallable start settlement or listener emission routes to the failure callable as TypeError (R-M9, R-L6).
  for (const badSettlement of [1n << 63n, '\ud800']) {
    const badStart = gate();
    host.bindings.unmarshallable_start = formBinding({kind: 'detachable', promise: badStart.promise});
    const failuresBefore = host.failures.length;
    await host.call('start_request', 'unmarshallable_start');
    badStart.resolve(badSettlement);
    await context.tick(); await host.instance.drain();
    context.assert(host.failures.length === failuresBefore + 1 && host.failures.at(-1)[1] instanceof TypeError,
      'unmarshallable start settlement was not routed to the failure callable as TypeError');
    await host.call('close_request');
  }
  const originalListener = host.bindings.listener;
  let badEmit;
  host.bindings.listener = () => ({kind: 'listener', subscribe(emit) {
    badEmit = emit;
    return () => { badEmit = undefined; };
  }});
  const failuresBeforeEmit = host.failures.length;
  await host.call('start_listener');
  badEmit(1n << 63n);
  badEmit('\ud800');
  await context.tick(); await host.instance.drain();
  context.assert(host.failures.length === failuresBeforeEmit + 2 &&
    host.failures.at(-2)[1] instanceof TypeError && host.failures.at(-1)[1] instanceof TypeError,
    'unmarshallable listener emission was not routed to the failure callable as TypeError');
  await host.call('close_request');
  host.bindings.listener = originalListener;
  for (const [name, binding] of [
    ['ordinary_runtime', () => { throw new WebAssembly.RuntimeError('ordinary host RuntimeError'); }],
    ['bare_request', () => Promise.resolve(1n)],
  ]) {
    host.bindings[name] = binding;
    await rejected(context, host.call('start_request', name), 'TITAN');
    context.assert(host.controls.snapshot().requests === 0 && (await host.call('valid_after_failure')) === 42n,
      name + ' bypassed import containment/explicit ownership or poisoned the instance');
  }
  const terminal = gate(), explicitCancel = new Error('explicit cancel failed');
  let signals = 0;
  const successes = host.successes.length, failures = host.failures.length;
  host.bindings.throwing_cancel = formBinding({kind: 'retained', promise: terminal.promise,
    cancel() { signals++; throw explicitCancel; }});
  await host.call('start_request', 'throwing_cancel');
  await rejected(context, host.call('cancel_request'), 'TITAN');
  context.assert(signals === 1 && host.controls.snapshot().requests === 1 &&
    (await host.call('valid_after_failure')) === 42n, 'explicit cancel error retired retained work or poisoned the owner');
  await host.call('cancel_request');
  terminal.resolve(77n);
  await context.tick(); await host.instance.drain();
  context.assert(signals === 1 && host.controls.snapshot().requests === 0 &&
    host.successes.length === successes && host.failures.length === failures, 'cancel failure admitted late or duplicate terminal work');
  await host.call('close_request');
}

async function listenerBatchCancellation(context, image) {
  for (const close of [false, true]) {
    const mode = close ? 'close' : 'cancel';
    const engineFailures = [], host = createHost(context, image,
      {onEngineFailure(event) { engineFailures.push(event); }});
    try {
      await host.instance.initialize();
      await nativeRun(context, host);
      await host.call('close_detached');

      const settled = gate();
      host.bindings.batch_once = formBinding({kind: 'detachable', promise: settled.promise});
      await host.call('start_request', 'batch_once');
      settled.resolve(29n);
      await context.tick();
      context.assert(host.controls.snapshot().requests === 0 && host.successes.length === 0,
        'one-shot control did not retire before its queued completion');
      await host.instance.drain();
      context.assert(host.successes.length === 1 && host.successes[0][0] === 29n,
        'normally settled one-shot completion was dropped with its retired request');
      await host.call('close_request');

      await host.call('stop_listener_on_success', close);
      await host.call('start_listener'); // subscribe queues 31 before returning.
      context.assert(host.listeners.size === 1, 'listener regression did not register one emitter');
      const [emit] = host.listeners;
      emit(32n, binary());
      context.assert(host.successes.length === 1, 'queued listener events entered before drain');
      await host.instance.drain();
      context.assert(host.successes.length === 2 && host.successes[1][0] === 31n,
        mode + ' from the first listener callback did not suppress the detached second event');
      context.equalBytes(host.successes[1][1], binary());
      context.assert(host.unregisters === 1 && host.listeners.size === 0 &&
        host.controls.snapshot().requests === 0, mode + ' did not unregister and retire the listener once');
      emit(33n, binary());
      await context.tick(); await host.instance.drain();
      context.assert(host.successes.length === 2 && host.unregisters === 1 &&
        host.notificationErrors.length === 0 && engineFailures.length === 0,
        mode + ' admitted a late event or reported a callback/engine failure');
      await host.call('close_request');
      context.assert((await host.call('valid_after_failure')) === 42n,
        mode + ' during drain left the instance unusable');
    } finally {
      await host.instance?.dispose().catch(() => {});
      host.releaseObservations();
    }
  }
  return {cancel: 1, close: 1, settledOneShots: 2};
}

async function stdio(context, host) {
  const cause = new Error('latched C-stdio append failure');
  host.sinks.stdout = () => { throw cause; };
  const appendFailure = await captureRejection(context, host.call('stdio_append', binary()), 'SINK');
  context.assert(appendFailure.cause === cause);
  host.sinks.stdout = undefined;
  context.assert((await host.call('valid_after_failure')) === 42n,
    'C-stdio sink failure poisoned an unrelated output-free call');
  const alias = new AliasingBytes(binary());
  host.instance.notify(host.callbacks.get('stdio_append'), alias);
  alias.fill(90);
  await host.instance.drain();
  context.equalBytes(host.stdout.at(-1), binary(), 'notification argument slice-as-view escaped snapshot ownership');
  const payloads = [new Uint8Array(1024).fill(65), new Uint8Array(1024).fill(66), encode('unterminated-tail')];
  let pending = 0, maximum = 0, calls = 0;
  const output = gate();
  host.sinks.stdout = () => {
    pending++; calls++; maximum = Math.max(maximum, pending);
    return (calls === 1 ? output.promise : Promise.resolve()).then(() => { pending--; });
  };
  const beforeChunks = host.stdout.length;
  for (const bytes of payloads) host.instance.notify(host.callbacks.get('stdio_append'), bytes);
  const draining = host.instance.drain();
  await until(context, () => calls === 1, 'ordered output did not start its first sink');
  await rejected(context, host.call('valid_after_failure'), 'REENTRY');
  await rejected(context, host.instance.drain(), 'REENTRY');
  context.assert(calls === 1, 'pending sink overlapped another write or callback');
  output.resolve();
  await draining;
  context.assert(calls === 3 && maximum === 1, 'stream did not serialize the detached write batch');
  for (let index = 0; index < payloads.length; index++) {
    context.equalBytes(host.stdout[beforeChunks + index], payloads[index]);
  }

  for (const behavior of ['throw', 'reject']) {
    const sinkCause = new Error(`ordered sink ${behavior}`);
    host.sinks.stdout = behavior === 'throw' ? () => { throw sinkCause; } : () => Promise.reject(sinkCause);
    const error = await captureRejection(context, host.call('stdio_append', binary()), 'SINK');
    context.assert(error.cause === sinkCause, 'write operation replaced its original sink cause');
    host.sinks.stdout = undefined;
    await host.call('stdio_append', binary());
  }
  return {writes: payloads.length + 2, maximumInflight: maximum};
}

async function sinkFailureValues(context, image) {
  let cases = 0;
  for (const phase of ['call', 'dispose']) {
    for (const behavior of ['throw', 'reject']) {
      for (const shape of ['accessor', 'lookalike']) {
        let reads = 0, calls = 0;
        const cause = shape === 'accessor' ? Object.defineProperty({}, 'code', {
          get() { reads++; throw new Error('sink code getter must not run'); },
        }) : {code: 'TITAN_BROWSER_SINK'};
        const host = createHost(context, image);
        try {
          await host.instance.initialize();
          if (phase === 'call') await nativeRun(context, host);
          host.sinks.stdout = () => {
            calls++;
            if (behavior === 'throw') throw cause;
            return Promise.reject(cause);
          };
          const operation = phase === 'call' ? host.call('stdio_append', binary()) : host.instance.dispose();
          const error = await captureRejection(context, operation, 'SINK');
          context.assert(error instanceof Error && error.name === 'TitanBrowserError' &&
            error.stream === 'stdout' && error.cause === cause && reads === 0 && calls === 1,
            `${phase} ${behavior} ${shape} sink value was inspected, lost or passed through`);
          host.sinks.stdout = undefined;
          if (phase === 'call') {
            context.assert((await host.call('valid_after_failure')) === 42n,
              'arbitrary sink failure poisoned a later operation');
            // The handled primary failure is not pending for disposal.
            await host.instance.dispose();
          }
          context.assert(host.notificationErrors.length === 0 && host.controls.snapshot().units === 0,
            'sink failure was reported twice or skipped state-close cleanup');
          cases++;
        } finally {
          host.sinks.stdout = undefined;
          await host.instance?.dispose().catch(() => {});
          host.releaseObservations();
        }
      }
    }
  }
  return cases;
}

async function prepareRetainedDisposal(context, host) {
  await host.call('close_detached');
  const request = gate(), second = gate();
  let cancellations = 0;
  host.bindings.retained_request = formBinding({kind: 'retained', promise: request.promise,
    cancel() { cancellations++; }});
  await host.call('start_request', 'retained_request');
  host.bindings.second_retained_request = formBinding({kind: 'retained', promise: second.promise,
    cancel() { cancellations++; }});
  await host.call('start_request', 'second_retained_request');
  const references = host.controls.weakTargets();
  const trace = host.instance.trace;
  const disposal = host.instance.dispose(), marker = watch(disposal);
  await context.tick();
  context.assert(!marker.settled && cancellations === 2, 'disposal confused retained cancellation with physical completion');
  await rejected(context, host.instance.run(), 'DISPOSED');
  await rejected(context, host.instance.call(host.callbacks.get('increment'), 1n), 'DISPOSED');
  await rejected(context, host.instance.drain(), 'DISPOSED');
  request.resolve(99n);
  await context.tick();
  context.assert(!marker.settled, 'one terminal request freed another retained owner');
  second.resolve(binary());
  await disposal;
  context.assert(Object.isFrozen(host.instance.trace) && host.instance.trace.state === trace.state &&
    host.instance.trace.reason === trace.reason, 'ordinary disposal discarded its final trace snapshot');
  context.assert(host.successes.length === 0 && host.closes.length === 2,
    'retirement admitted an application callback or skipped close');
  context.assert(host.controls.snapshot().units === 0 && host.controls.snapshot().requests === 0,
    'retained disposal leaked state-owned units');
  finalizedState(context, host, 0n);
  host.releaseObservations();
  return references;
}

async function retainedDisposal(context, host) {
  const references = await prepareRetainedDisposal(context, host);
  await collected(context, references, 'retainedDisposal');
  return references.length;
}

async function prepareDetachableDisposal(context, host) {
  const pending = gate();
  host.bindings.detachable_disposal_request = formBinding({kind: 'detachable', promise: pending.promise});
  await host.call('start_request', 'detachable_disposal_request');
  await host.call('start_listener');
  const references = host.controls.weakTargets();
  const retainedPromise = host.retainedPromise;
  const opaquePromise = host.opaquePromise;
  const emitters = host.retainedListeners.slice();
  const disposal = host.instance.dispose();
  context.assert(disposal === host.instance.dispose(), 'dispose did not return one stable promise');
  await disposal;
  context.assert(host.closes.length === 2 && host.closes.includes(host.bindings.close_value) &&
    host.closes.includes(host.thrown.throw_string), 'initializer coroutine did not see its registry during close');
  context.assert(decode(join(host.stdout)).endsWith('bridge-finalizer\n'), 'ordinary disposal omitted finalizer output');
  context.assert(host.controls.snapshot().units === 0 && host.controls.snapshot().requests === 0,
    'close-phase-created units survived statewide retirement');
  finalizedState(context, host, 0n);
  const successes = host.successes.length;
  for (const emit of emitters) emit(98n, binary());
  pending.resolve(binary());
  host.instance.notify(undefined, Object.freeze({postDispose: true})); // Inert after disposal.
  await context.tick();
  context.assert(host.successes.length === successes && host.unregisters === 2,
    'disposed listener/request admitted late application work');
  host.releaseObservations();
  return {references, retainedPromise, opaquePromise, emitters};
}

async function detachableDisposal(context, host) {
  const prepared = await prepareDetachableDisposal(context, host);
  await collected(context, prepared.references, 'detachableDisposal');
  context.assert(prepared.retainedPromise instanceof Promise && prepared.opaquePromise instanceof Promise &&
    prepared.emitters.length === 2,
    'collection test did not keep external never-settling work/opaque Promise/listener continuations alive');
  return prepared.references.length;
}

async function prepareInterruptedSink(context, image) {
  const host = createHost(context, image);
  await host.instance.initialize();
  await nativeRun(context, host);
  await host.call('close_detached');
  const output = gate();
  const observation = {calls: 0};
  host.sinks.stdout = () => { observation.calls++; return output.promise; };
  const interrupted = rejected(context, host.call('stdio_append', binary()), 'DISPOSED');
  await until(context, () => observation.calls === 1, 'pending output sink was not entered');
  const references = host.controls.weakTargets();
  let disposal = host.instance.dispose();
  await interrupted;
  await rejected(context, disposal, 'DISPOSED');
  context.assert(observation.calls === 1 && host.closes.length === 2,
    'pending-sink disposal overlapped finalizer output or delivered application completion');
  disposal = undefined; // Its completed Error observation is not the pending sink under test.
  host.releaseObservations();
  return {references, output, observation};
}

async function interruptedSink(context, image) {
  const prepared = await prepareInterruptedSink(context, image);
  await collected(context, prepared.references, 'interruptedSink');
  prepared.output.resolve();
  await context.tick();
  context.assert(prepared.observation.calls === 1, 'late sink settlement revived its terminal stream');
  return prepared.references.length;
}

async function prepareFinalizerDrain(context, image) {
  const host = createHost(context, image);
  await host.instance.initialize(); // Its real initializer coroutine must unwind even without main.
  const output = gate();
  host.sinks.stdout = formBinding(output.promise);
  let instance = host.instance;
  const references = [...host.controls.weakTargets(), new WeakRef(instance)];
  const trace = instance.trace;
  const disposal = instance.dispose(), marker = watch(disposal);
  await until(context, () => host.closes.length === 2 && host.stdout.length === 1,
    'native close did not hand finalizer bytes to the owner-free drain');
  context.assert(host.controls.snapshot().units === 0 && !marker.settled, 'finalizer sink retained live Lua ownership');
  context.assert(Object.isFrozen(instance.trace) && instance.trace.state === trace.state &&
    instance.trace.reason === trace.reason, 'owner-free drain discarded its final trace snapshot');
  host.releaseObservations();
  instance = undefined;
  return {host, output, references, disposal};
}

async function finalizerDrain(context, image, fail) {
  const prepared = await prepareFinalizerDrain(context, image);
  // Keep the unresolved disposal and host sink promises, but not their preparation frame.
  await collected(context, prepared.references, `finalizerDrain(${fail ? 'reject' : 'resolve'})`);
  const cause = new Error('finalizer sink rejection');
  if (fail) {
    prepared.output.reject(cause);
    const error = await captureRejection(context, prepared.disposal, 'SINK');
    context.assert(error.cause === cause, 'owner-free disposal drain replaced its eventual sink failure');
  } else { prepared.output.resolve(); await prepared.disposal; }
  context.equalBytes(join(prepared.host.stdout), encode('bridge-finalizer\n'));
  return prepared.references.length;
}

async function cleanupFailures(context, image) {
  let secondarySinks = 0, backgroundReleases = 0, secondaryReleases = 0;
  const nativeCases = [];
  for (const [stdoutMode, stderrMode] of [[undefined, 'throw'], [undefined, 'reject'], ['throw', 'reject']]) {
    const host = createHost(context, image);
    try {
      await host.instance.initialize();
      nativeCases.push(await nativeRun(context, host));
      await host.call('close_detached');
      const original = await captureRejection(context, host.call('cleanup_failure', binary()), 'TITAN');
      context.equalBytes(original.bytes, new Uint8Array([...encode('Titan bridge failure'), 0, 255]));
      context.assert(original.trace instanceof Uint8Array && original.trace.length > 0,
        'native primary-failure fixture did not capture its original Titan trace');

      const background = await host.call('make_callable');
      const beforeBackground = host.notificationErrors.length;
      host.controls.refuseNextRelease();
      background.release();
      await context.tick();
      context.assert(host.notificationErrors.length === beforeBackground,
        'refused wrapper release reported a notification error');
      context.assert((await host.call('valid_after_failure')) === 42n,
        'refused wrapper release poisoned a later valid entry');
      backgroundReleases++;

      const causes = {stdout: new Error('secondary stdout failure'), stderr: new Error('secondary stderr failure')};
      const checks = [], calls = {stdout: 0, stderr: 0};
      for (const [stream, mode] of [['stdout', stdoutMode], ['stderr', stderrMode]]) {
        if (!mode) continue;
        host.sinks[stream] = () => {
          calls[stream]++;
          const snapshot = host.controls.snapshot();
          context.assert(snapshot.safe && !snapshot.owner, 'failure flush invoked a sink during a native entry');
          checks.push(rejected(context, host.call('valid_after_failure'), 'REENTRY'));
          checks.push(rejected(context, host.instance.drain(), 'REENTRY'));
          if (mode === 'throw') throw causes[stream];
          return Promise.reject(causes[stream]);
        };
      }
      const deferred = await host.call('make_callable');
      const beforeErrors = host.notificationErrors.length;
      const beforeOut = host.stdout.length, beforeErr = host.stderr.length;
      host.controls.refuseNextRelease();
      deferred.release();
      const error = await captureRejection(context, host.call('cleanup_failure', binary()), 'TITAN');
      context.equalBytes(error.bytes, original.bytes, 'cleanup replaced the primary Titan message');
      context.equalBytes(error.trace, original.trace, 'cleanup replaced the primary Titan trace');
      await Promise.all(checks);
      checks.length = 0;
      host.sinks.stdout = host.sinks.stderr = undefined;
      context.equalBytes(join(host.stdout.slice(beforeOut)), binary(), 'refused release skipped the surviving stdout flush');
      context.equalBytes(join(host.stderr.slice(beforeErr)), binary(), 'refused release skipped the stderr flush');
      const events = host.notificationErrors.slice(beforeErrors);
      context.assert(events.every(event => event.kind === 'cleanup' && event.operation === 'call') &&
        events.length === calls.stdout + calls.stderr, 'secondary cleanup failures were lost, duplicated or mistagged');
      context.assert(events.every(event => event.error.code !== 'TITAN_BROWSER_TITAN'),
        'refused wrapper release reported a secondary cleanup failure');
      secondaryReleases++;
      for (const stream of ['stdout', 'stderr']) {
        const failures = events.filter(event => event.error.stream === stream);
        context.assert(failures.length === calls[stream] &&
          failures.every(event => event.error.code === 'TITAN_BROWSER_SINK' && event.error.cause === causes[stream]),
          `${stream} secondary failure lost its original cause or per-invocation identity`);
        secondarySinks += failures.length;
      }
      const count = host.notificationErrors.length;
      context.assert((await host.call('valid_after_failure')) === 42n,
        'a previously observed cleanup failure poisoned an unrelated output-free call');
      await host.instance.drain();
      const disposal = await captureRejection(context, host.instance.dispose(), 'SINK');
      const expected = events.find(event => event.error.stream === (stdoutMode ? 'stdout' : 'stderr')).error;
      context.assert(disposal === expected && host.notificationErrors.length === count &&
        host.closes.length === 2 && host.controls.snapshot().units === 0,
        'state-close fallback lost its pending C-byte error or reported an old cleanup failure again');
    } finally {
      await host.instance?.dispose().catch(() => {});
      host.releaseObservations();
    }
  }
  return {nativeCases, backgroundReleases, secondaryReleases, secondarySinks};
}

async function interruptedFailure(context, image) {
  const host = createHost(context, image);
  const output = gate();
  try {
    await host.instance.initialize();
    await nativeRun(context, host);
    await host.call('close_detached');
    const original = await captureRejection(context, host.call('cleanup_failure', binary()), 'TITAN');
    const calls = {stdout: 0, stderr: 0};
    for (const stream of ['stdout', 'stderr']) {
      host.sinks[stream] = () => { calls[stream]++; return output.promise; };
    }
    const before = host.notificationErrors.length;
    const pending = captureRejection(context, host.call('cleanup_failure', binary()), 'TITAN');
    await until(context, () => calls.stdout === 1 && calls.stderr === 1,
      'failed callback did not start both report sinks');
    await rejected(context, host.call('valid_after_failure'), 'REENTRY');
    const disposal = host.instance.dispose();
    const error = await pending;
    context.equalBytes(error.bytes, original.bytes, 'disposal replaced the already captured Titan message');
    context.equalBytes(error.trace, original.trace, 'disposal replaced the already captured Titan trace');
    const interruption = await captureRejection(context, disposal, 'DISPOSED');
    const events = host.notificationErrors.slice(before);
    context.assert(events.length === 1 && events[0].kind === 'cleanup' &&
      events[0].operation === 'call' && events[0].error === interruption,
      'two interrupted report streams did not report their shared interruption exactly once');
    context.assert(host.closes.length === 2 && host.controls.snapshot().units === 0,
      'already-failed callback prevented legitimate native close');
    output.resolve();
    await context.tick();
    context.assert(calls.stdout === 1 && calls.stderr === 1 && host.notificationErrors.length === before + 1,
      'late sink settlement revived an interrupted report or duplicated its cleanup event');
  } finally {
    output.resolve();
    await host.instance?.dispose().catch(() => {});
    host.releaseObservations();
  }
}

async function initializationFailure(context, image) {
  let expectedTrace;
  for (const mode of ['normal', 'throw', 'reject', 'interrupt']) {
    const stdout = [], stderr = [], events = [];
    const cause = new Error(`initializer stderr ${mode}`);
    const output = mode === 'interrupt' ? gate() : undefined;
    let closed = 0, main = 0, calls = 0, repaired = false;
    const instance = image.create({locateFile: image.locateFile,
      stdout: bytes => { stdout.push(bytes); },
      stderr(bytes) {
        stderr.push(bytes);
        if (mode === 'normal' || repaired) return;
        calls++;
        if (output) return output.promise;
        if (mode === 'throw') throw cause;
        return Promise.reject(cause);
      },
      onNotificationError(event) { events.push(event); },
      bindings: {initializer_close() { closed++; }, initializer_main() { main++; }}});
    try {
      const promise = instance.initialize();
      context.assert(promise === instance.initialize(), 'failed initialization did not share its promise');
      let disposal;
      if (output) {
        await until(context, () => calls === 1, 'failed initializer did not start its report sink');
        disposal = instance.dispose();
      }
      const error = await captureRejection(context, promise, 'TITAN');
      const bytes = new Uint8Array([...encode('bridge initializer failed'), 0, 255]);
      context.equalBytes(error.bytes, bytes);
      context.assert(error.trace instanceof Uint8Array && error.trace.length > 0,
        'failed initializer lost its captured Titan trace');
      if (!expectedTrace) expectedTrace = error.trace;
      else context.equalBytes(error.trace, expectedTrace, 'sink failure replaced the initializer trace');
      if (output) {
        const interruption = await captureRejection(context, disposal, 'DISPOSED');
        context.assert(events.length === 1 && events[0].kind === 'cleanup' &&
          events[0].operation === 'initialize' && events[0].error === interruption &&
          closed === 1 && main === 0 && stdout.length === 0,
          'disposal replaced the captured initializer failure or lost its one cleanup interruption');
        await rejected(context, instance.run(), 'DISPOSED');
        output.resolve();
        await context.tick();
        context.assert(calls === 1 && events.length === 1, 'late initializer sink settlement revived its retired stream');
        continue;
      }
      context.assert(events.length === calls && events.every(event => event.kind === 'cleanup' &&
        event.operation === 'initialize' && event.error.code === 'TITAN_BROWSER_SINK' &&
        event.error.stream === 'stderr' && event.error.cause === cause),
        'initializer secondary sink failures were lost, duplicated or mistagged');
      repaired = true;
      const reports = join(stderr);
      const result = await instance.run([]);
      context.assert(result.kind === 'failed' && result.status === 1 && main === 0);
      context.equalBytes(result.bytes, bytes);
      context.equalBytes(join(stderr), reports, 'run repeated the saved initializer report');
      context.assert(decode(reports).split('bridge initializer failed').length === 2, 'initializer was not reported exactly once');
      if (calls) {
        const disposal = await captureRejection(context, instance.dispose(), 'SINK');
        context.assert(disposal === events[0].error && events.length === calls,
          'disposal lost or re-reported an already observed initializer C-byte failure');
      } else await instance.dispose();
      context.assert(closed === 1 && stdout.length === 0, 'failed partial state was not disposable exactly once');
      await rejected(context, instance.run(), 'DISPOSED');
    } finally {
      output?.resolve();
      await instance.dispose().catch(() => {});
    }
  }
  for (const [arg, expectedStatus, expectedMessage, forbiddenFrame] of [
    ['ok', 0, undefined, undefined],
    ['stale-trace', 1, 'main failed after caught initializer error', 'initializer_raise_record'],
    ['record', 1, '(error object is a userdata value)', 'initializer_raise_record'],
    ['false', 1, '(error object is a boolean value)', 'initializer_raise_record'],
    ['browser-error', 1, '(error object is a userdata value)', 'initializer_raise_record'],
    ['float', 1, '2.0', 'initializer_raise_record'],
    ['negative-zero', 1, '-0.0', 'initializer_raise_record'],
    ['integer', 1, '42', 'initializer_raise_record'],
    ['fractional', 1, '2.5', 'initializer_raise_record'],
  ]) {
    const stderr = [];
    const instance = image.create({locateFile: image.locateFile,
      stderr: bytes => { stderr.push(bytes); },
      bindings: {
        initializer_allow_main() { return true; },
        throw_error() { throw new Error('uncaught binding error in main'); },
      }});
    try {
      const result = await instance.run([arg]);
      if (expectedMessage === undefined) {
        context.assert(result.kind === 'returned' && result.status === expectedStatus,
          `caught initializer record test returned ${result.kind} status ${result.status}`);
      } else {
        context.assert(result.kind === 'failed' && result.status === expectedStatus,
          `main error case ${arg} did not report failed status 1`);
        context.equalBytes(result.bytes, encode(expectedMessage),
          `main error case ${arg} returned wrong message: ${decode(result.bytes)}`);
        const stderrText = decode(join(stderr));
        context.assert(stderrText.includes(`initializer_failure: ${expectedMessage}`) &&
          stderrText.includes('stack traceback:') &&
          stderrText.includes('initializer_failure.main') &&
          !stderrText.includes(forbiddenFrame),
          `main error case ${arg} stderr report was wrong: ${stderrText}`);
      }
    } finally {
      await instance.dispose();
    }
  }
}

async function terminalReleases(context, image) {
  for (const terminal of ['dispose', 'exit']) {
    const host = createHost(context, image);
    let unwatch;
    try {
      await host.instance.initialize();
      await nativeRun(context, host);
      await host.call('close_detached');
      const wrapper = await host.call('make_pinned_wrapper', 99n);
      if (terminal === 'exit') await rejected(context, host.call('exit_for_release'), 'EXITED');
      const records = [], beforeId = host.controls.snapshot().operationId;
      unwatch = host.controls.watchCompletions(record => records.push(record));
      const disposing = terminal === 'dispose' ? host.instance.dispose() : undefined;
      context.assert(wrapper.release() === undefined && wrapper.release() === undefined,
        `release after ${terminal} did not remain nonthrowing and idempotent`);
      context.assert(records.length === 0 && host.controls.snapshot().operationId === beforeId &&
        host.notificationErrors.length === 0, `release after ${terminal} entered a promising operation`);
      await (disposing ?? host.instance.dispose());
      context.assert(host.controls.snapshot().units === 0 &&
        host.controls.snapshot().states.every(state => state.closed),
        `release after ${terminal} prevented state-close retirement`);
    } finally {
      unwatch?.();
      await host.instance?.dispose();
      host.releaseObservations();
    }
  }
}

async function operationIdentities(context, image) {
  const host = createHost(context, image);
  let unwatch;
  const records = [];
  try {
    await host.instance.initialize();
    await nativeRun(context, host);
    await host.call('close_detached');
    const signedBoundary = (1n << 63n) - 1n;
    host.controls.advanceOperationId(signedBoundary - 1n);
    unwatch = host.controls.watchCompletions(record => { records.push({id: record.id, kind: record.kind}); });
    for (let index = 0; index < 3; index++) context.assert((await host.call('valid_after_failure')) === 42n);
    context.assert(records.length === 3 && records.every((record, index) =>
      record.id === signedBoundary + BigInt(index) && record.kind === 3),
      'uint64 identity changed sign across the Wasm import boundary');
    const callable = await host.call('make_callable');
    const maximum = (1n << 64n) - 1n;
    host.controls.advanceOperationId(maximum - 2n);
    callable.release(); // Synchronous retirement spends no entry identity.
    context.assert((await host.call('valid_after_failure')) === 42n);
    context.assert(records.at(-1).id === maximum - 1n, 'last application entry used the reserved close identity');
    const before = records.length;
    await rejected(context, host.call('valid_after_failure'), 'STATE');
    await host.instance.drain();
    context.assert(records.length === before && host.controls.snapshot().operationId === maximum - 1n,
      'empty drain allocated an exhausted identity or emitted a completion');
    const beforeErrors = host.notificationErrors.length;
    host.instance.notify(host.callbacks.get('valid_after_failure'));
    await host.instance.drain();
    const failure = host.notificationErrors[beforeErrors];
    context.assert(host.notificationErrors.length === beforeErrors + 1 &&
      failure.kind === 'callback' && failure.operation === 'drain' &&
      failure.error.code === 'TITAN_BROWSER_STATE' &&
      failure.error.message === 'browser operation identity exhausted',
      'notification delivery did not report identity exhaustion at allocation');
    context.assert(records.length === before && host.controls.snapshot().operationId === maximum - 1n,
      'exhausted identity allocation entered Wasm or reused an identity');
    await host.instance.dispose();
    context.assert(records.at(-1).id === maximum && records.at(-1).kind === 5 && host.closes.length === 2 &&
      host.controls.snapshot().units === 0, 'uint64 exhaustion prevented intact-state close/root retirement');
    return {signedBoundary: 3, exhaustionClose: true};
  } finally {
    unwatch?.();
    await host.instance?.dispose();
    host.releaseObservations();
  }
}

async function prepareImportDisposal(context, image, ownership) {
  const host = createHost(context, image);
  let disposal, marker, signals = 0, late;
  const terminal = gate(), cancelFailure = new Error('late classified cancellation failed');
  try {
    await host.instance.initialize();
    await nativeRun(context, host);
    await host.call('close_detached');
    const references = host.controls.weakTargets();
    if (ownership === 'retained') {
      host.bindings.dispose_request = () => {
        disposal = host.instance.dispose(); marker = watch(disposal);
        return {kind: 'retained', promise: terminal.promise,
          cancel() { signals++; throw cancelFailure; }};
      };
      await rejected(context, host.call('start_request', 'dispose_request'), 'DISPOSED');
      await context.tick();
      context.assert(!marker.settled && host.closes.length === 0 && signals === 1 &&
        host.controls.snapshot().requests === 1, 'throwing cancellation retired a live retained operation');
      terminal.resolve(88n);
      let error = await captureRejection(context, disposal, 'HOST');
      context.assert(error.cause === cancelFailure, 'late cancellation error was lost by disposal');
      error = undefined;
    } else {
      host.bindings.listener = () => ({kind: 'listener', subscribe(emit) {
        late = emit;
        disposal = host.instance.dispose(); marker = watch(disposal);
        emit(87n, binary());
        return () => { signals++; emit(86n, binary()); };
      }});
      await rejected(context, host.call('start_listener'), 'DISPOSED');
      await disposal;
      late(85n, binary());
    }
    await context.tick();
    context.assert(signals === 1 && host.successes.length === 0 && host.failures.length === 0 &&
      host.closes.length === 2 && host.controls.snapshot().requests === 0 &&
      host.controls.snapshot().units === 0, 'import disposal skipped unregister/terminal retirement or delivered application work');
    disposal = undefined; // Outcome assertions are complete; retain only the intended host work.
    host.releaseObservations();
    return {references, terminal, late};
  } finally {
    await host.instance?.dispose().catch(() => {});
    host.releaseObservations();
  }
}

async function disposalFromImport(context, image) {
  let targets = 0;
  for (const ownership of ['retained', 'listener']) {
    const prepared = await prepareImportDisposal(context, image, ownership);
    await collected(context, prepared.references, `disposalFromImport(${ownership})`);
    targets += prepared.references.length;
  }
  return targets;
}

export async function run(context) {
  context.assert(context.args.length === 2, 'pass browser.tests and failed-initializer image paths');
  const image = await context.image(context.args[0]);
  const failedImage = await context.image(context.args[1]);
  context.assert(!Object.hasOwn(image, 'factory') && typeof image.create === 'function', 'raw factory escaped context.image');
  const materialization = {arguments: await argumentMaterialization(context, image),
    disposal: await disposalMaterialization(context, image)};
  const listenerCancellation = await listenerBatchCancellation(context, image);
  const engineFailures = [];
  const onEngineFailure = failure => { engineFailures.push(failure); };
  const first = createHost(context, image, {onEngineFailure}), second = createHost(context, image, {onEngineFailure});
  let unwatchFirst, unwatchSecond, unwatchCompletions;
  const hops = [], completions = [];
  try {
    context.assert(await rejected(context, first.instance.call(undefined), 'STATE') === undefined,
      'assertion-only rejection retained an Error result');
    await rejected(context, first.instance.drain(), 'STATE');
    const initializing = first.instance.initialize();
    context.assert(initializing === first.instance.initialize());
    await Promise.all([initializing, second.instance.initialize()]);
    context.assert(Object.isFrozen(first.instance.trace) && first.instance.trace.state === 'ready', 'trace was not ready before main');
    unwatchFirst = first.controls.watchTransfers(() => { hops.push(0); });
    unwatchSecond = second.controls.watchTransfers(() => { hops.push(1); });
    unwatchCompletions = first.controls.watchCompletions(record => { completions.push({id: record.id, kind: record.kind}); });
    const running = nativeRun(context, first);
    const peer = nativeRun(context, second);
    await rejected(context, first.instance.run(), 'REENTRY');
    const counts = await Promise.all([running, peer]);
    await rejected(context, first.instance.run(), 'STATE');
    const switches = hops.slice(1).filter((id, index) => id !== hops[index]).length;
    context.assert(switches >= 4, 'two actual instances did not interleave private JSPI hops');
    const beforeForeign = first.controls.snapshot().operationId;
    await rejected(context, first.instance.call(second.callbacks.get('increment'), 1n), 'HANDLE');
    context.assert(first.controls.snapshot().operationId === beforeForeign, 'foreign-instance target reached Wasm');
    await values(context, first, completions);
    context.assert((await second.call('increment', 100n)) === 100n && (await first.call('read_capture')) === 3n,
      'instances shared original capture ownership');
    const announcements = await notifications(context, first, completions);
    await requests(context, first);
    await requestHolds(context, first);
    const io = await stdio(context, first);
    const repairs = {results: await resultRepairs(context, first, engineFailures),
      responses: await responseRepairs(context, first, engineFailures),
      admissions: await admissionRepairs(context, first, engineFailures)};
    unwatchFirst(); unwatchSecond(); unwatchCompletions();
    unwatchFirst = unwatchSecond = unwatchCompletions = undefined;
    let collectedTargets = await retainedDisposal(context, second);
    collectedTargets += await detachableDisposal(context, first);
    collectedTargets += await interruptedSink(context, image);
    collectedTargets += await finalizerDrain(context, image, false);
    collectedTargets += await finalizerDrain(context, image, true);
    collectedTargets += await disposalFromImport(context, image);
    const sinkValues = await sinkFailureValues(context, image);
    const cleanup = await cleanupFailures(context, image);
    await interruptedFailure(context, image);
    await initializationFailure(context, failedImage);
    const identities = await operationIdentities(context, image);
    await terminalReleases(context, image);
    context.stdout(encode('BRIDGE ' + JSON.stringify({verdict: 'PASS', nativeCases: counts,
      instances: 2, interleavedSwitches: switches, operations: completions.length, requestDrain: announcements,
      notifications: first.notifications.length, requests: first.successes.length + first.failures.length,
      io, repairs, cleanup, identities, materialization, listenerCancellation, sinkValues, collectedTargets,
      stateFinalizers: first.earlierCloses.length + second.earlierCloses.length, finalizerDrains: 2}) + '\n'));
  } finally {
    unwatchFirst?.(); unwatchSecond?.(); unwatchCompletions?.();
    await Promise.all([first, second].map(host => host.instance?.dispose().catch(() => {})));
    first.releaseObservations(); second.releaseObservations();
  }
}
