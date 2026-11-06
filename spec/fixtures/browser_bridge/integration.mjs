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
  context.assert(host.callbacks.size >= 26, 'native owner omitted published production Callables');
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
  return {status: outcome.status, values: outcome.value.map(value =>
    value instanceof Uint8Array ? Array.from(value) : typeof value === 'bigint' ? `${value}n` : value)};
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
    context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure'))[0] === 42n,
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
      context.assert(outer.status === 'rejected' && outer.error instanceof TypeError,
        'Proxy bytes did not receive an ordinary TypeError: ' + JSON.stringify(report));
      context.assert(hooks.length === 0 && nested === undefined,
        'byte admission invoked substituting Proxy hooks');
      context.assert(engineFailures.length === 0 && following.status === 'fulfilled' && following.value[0] === 42n,
        'byte argument inspection poisoned the instance or stranded its operation');
      let error;
      try { host.instance.notify(host.callbacks.get('typed_echo'), true, 7n, 7, bytes); }
      catch (cause) { error = cause; }
      context.assert(error instanceof TypeError && hooks.length === 0,
        'notification byte admission invoked Proxy hooks or lost ordinary rejection');
      await host.instance.drain();
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
      context.equalBytes((await copying)[3], binary(), 'native byte view was not snapshotted at call time');
    }
    bytes.set(binary());
    host.instance.notify(host.callbacks.get('sdk_write'), bytes);
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
      const before = host.controls.snapshot().operationId;
      await rejected(context, host.call('typed_echo', ...args), 'TypeError');
      context.assert(host.controls.snapshot().operationId === before,
        'boxed/coercing scalar reached Wasm');
    }
    context.assert(coercions === 0 && hooks.length === 0, 'strict scalar checks invoked host coercion');
    const hostValues = await hostValueMaterialization(context, host);
    context.assert(engineFailures.length === 0 && host.notificationErrors.length === 0 &&
      (await host.call('valid_after_failure'))[0] === 42n,
      'host-value materialization poisoned a later valid call or reported an unreturnable error');
    return {proxyBytes: 2, nativeByteViews: sources.length, strictScalars: 3, runGetters: reads.length, ...hostValues};
  } finally {
    await host.instance?.dispose().catch(() => {});
    host.releaseObservations();
  }
}

async function hostValueMaterialization(context, host) {
  const checks = [];
  let byteReads = 0, lengthReads = 0;
  const reads = host.ioReads.length;
  host.input.push({
    get bytes() {
      byteReads++;
      checks.push(rejected(context, host.call('valid_after_failure'), 'REENTRY'));
      return binary();
    },
    get length() {
      lengthReads++;
      checks.push(rejected(context, host.instance.drain(), 'REENTRY'));
      return 4;
    },
  });
  await host.call('sdk_read', 4n);
  await Promise.all(checks);
  await host.instance.drain();
  context.assert(byteReads > 0 && lengthReads > 0 && host.ioReads.length === reads + 1,
    'counted stdin getters did not complete under their existing operation owner');
  context.equalBytes(host.ioReads.at(-1), binary());

  const source = gate(), successes = host.successes.length, failures = host.failures.length;
  host.bindings.admission_result = formBinding({kind: 'detachable', promise: source.promise});
  await host.call('start_request', encode('admission_result'));
  let indexReads = 0, substitutions = 0, nested;
  const result = [41n, binary()];
  Object.defineProperty(result, '0', {get() {
    indexReads++;
    if (!nested) nested = admissionOutcome(context, host.call('valid_after_failure'));
    return 41n;
  }});
  for (const [key, value] of [['map', Array.prototype.map], ['constructor', Array],
    [Symbol.iterator, Array.prototype[Symbol.iterator]]]) {
    Object.defineProperty(result, key, {get() { substitutions++; return value; }});
  }
  source.resolve(result);
  await context.tick();
  const called = await nested;
  context.assert(indexReads === 1 && substitutions === 0 && called?.status === 'fulfilled' && called.value[0] === 42n,
    'request completion did not materialize exact dense indices independently of its substituting hooks');
  await host.instance.drain();
  context.assert(host.successes.length === successes + 1 && host.successes.at(-1)[0] === 41n &&
    host.failures.length === failures && host.controls.snapshot().requests === 0,
    'reentering request-result getter lost or duplicated its terminal completion');
  context.equalBytes(host.successes.at(-1)[1], binary());
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
  await host.call('start_request', encode('admission_rejection'));
  rejectedSource.reject(rejection);
  await context.tick();
  const rejectedCall = await rejectedNested;
  context.assert(messageReads > 0 && coercions === 1 && rejectedCall?.status === 'fulfilled' &&
    rejectedCall.value[0] === 42n, 'request rejection message inspection lost its legitimate nested operation');
  await host.instance.drain();
  context.assert(host.failures.length === failures + 1 && host.failures.at(-1)[1] === rejection &&
    host.successes.length === successes + 1 && host.controls.snapshot().requests === 0,
    'reentering host rejection lost its original thrown identity or terminal retirement');
  context.equalBytes(host.failures.at(-1)[0], encode('host rejection reentry'));
  await host.call('close_request');
  delete host.bindings.admission_rejection;
  return {countedGetters: 1, completionGetters: 1, rejectionCoercions: 1};
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
        await host.call('start_request', encode('admission_dispose'));
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
      terminal.resolve([91n, binary()]);
      await context.tick();
      context.assert(host.successes.length === 0 && host.failures.length === 0 && signals === 1,
        ownership + ' late settlement revived a disposed request');
    } finally {
      terminal.resolve([91n, binary()]);
      await host.instance?.dispose().catch(() => {});
      host.releaseObservations();
    }
  }
  return {cancel: 1, unregister: 1};
}

async function values(context, host, completions) {
  context.assert((await host.call('read_capture'))[0] === 0n);
  context.assert((await host.call('increment', 1n))[0] === 1n);
  context.assert((await host.call('increment', 2n))[0] === 3n);
  await host.call('force_gc');
  context.assert((await host.call('read_capture'))[0] === 3n, 'collection reconstructed or lost original capture cells');
  const zero = await host.call('zero_results'), nil = await host.call('one_nil');
  context.assert(Array.isArray(zero) && zero.length === 0, 'zero results were not an empty carrier');
  context.assert(nil.length === 1 && nil[0] === null, 'one nil result was not distinct from zero results');
  const trailing = await host.call('trailing_nil', 19n, null);
  context.assert(trailing.length === 4 && trailing[0] === 19n && trailing[1] === null &&
    trailing[2] === false && trailing[3] === null, 'result arity/trailing nils changed');
  const wide = Array.from({length: 10}, (_, index) => BigInt(index + 1));
  const echoed = await host.call('wide_echo', ...wide);
  context.assert(echoed.length === wide.length && echoed.every((value, index) => value === wide[index]),
    'wide callback arguments/results lost protected dynamic storage');

  for (const integer of [-(1n << 63n), (1n << 63n) - 1n, (1n << 53n) - 1n,
    1n << 53n, (1n << 53n) + 1n, -(1n << 53n) - 1n]) {
    for (const number of [17, -0, NaN]) {
      const result = await host.call('typed_echo', false, integer, number, binary());
      context.assert(result.length === 4 && result[0] === false && result[1] === integer &&
        Object.is(result[2], number), 'typed scalar roundtrip changed kind or bits');
      context.equalBytes(result[3], binary());
    }
  }
  const empty = await host.call('typed_echo', true, 0n, 0, new Uint8Array());
  context.equalBytes(empty[3], new Uint8Array());
  const large = new Uint8Array(34 * 1024 * 1024);
  large.set(binary()); large.set(binary(), large.length - 4);
  const grown = await host.call('typed_echo', true, 1n, 1, large);
  context.equalBytes(grown[3], large, 'JS-to-Titan bytes used a stale heap after growth');
  large.fill(91);
  context.equalBytes(grown[3].subarray(0, 4), binary(), 'returned bytes were a borrowed input view');
  const alias = new AliasingBytes(binary());
  const copying = host.call('typed_echo', true, 2n, 2, alias);
  alias.fill(90);
  context.equalBytes((await copying)[3], binary(), 'call argument slice-as-view escaped snapshot ownership');

  const invalid = [
    () => host.call('typed_echo', false, 1, 0, binary()),
    () => host.call('typed_echo', false, 1n << 63n, 0, binary()),
    () => host.call('typed_echo', 0, 1n, 0, binary()),
    () => host.call('typed_echo', true, 1n, 1n, binary()),
    () => host.call('typed_echo', true, 1n, 1, 'bytes'),
    () => host.call('typed_echo', true, 1n, 1),
    () => host.call('zero_results', null),
    () => host.call('trailing_nil', 1n, undefined),
  ];
  for (const call of invalid) {
    const before = host.controls.snapshot().operationId;
    await rejected(context, call(), 'TypeError');
    context.assert(host.controls.snapshot().operationId === before, 'invalid signature reached Wasm');
  }
  const object = Object.freeze({opaque: true});
  host.opaquePromise = new Promise(() => {});
  let adoptions = 0;
  const thenable = Object.freeze({then() { adoptions++; throw new Error('opaque thenable was adopted'); }});
  for (const value of [false, 0, null, undefined, object, Promise.resolve('opaque'), host.opaquePromise, thenable]) {
    const result = await host.call('handle_echo', value);
    context.assert(result.length === 1 && Object.is(result[0], value), 'JSHandle carrier lost raw value identity');
  }
  context.assert(adoptions === 0, 'reverse-call Promise resolution adopted an opaque handle result');
  const original = host.callbacks.get('increment');
  context.assert((await host.call('callable_echo', original))[0] === original, 'Callable result reconstructed its wrapper/root');
  const error = await captureRejection(context, host.call('titan_failure'), 'TITAN');
  context.equalBytes(error.bytes, new Uint8Array([...encode('Titan bridge failure'), 0, 255]));
  const trace = decode(error.trace);
  const originalFrame = /^tests\.browser\.titan(?::(\d+))?: in anonymous function at (?:.*[\\/])?tests\.browser\.titan:(\d+)(?:\n|$)/.exec(trace);
  // The publisher has returned; the retained inline closure is the error site.
  // WebKit preserves its function name without a program-counter source line.
  context.assert(error.trace instanceof Uint8Array && originalFrame &&
    (!originalFrame[1] || originalFrame[1] === originalFrame[2]),
    `Titan callback failure lost its original source trace: ${JSON.stringify(trace)}`);
  context.assert((await host.call('valid_after_failure'))[0] === 42n, 'ordinary Titan error poisoned later calls');
  context.assert((await host.call('resume_single', 71n))[0] === 71n, 'later C entry did not restore a parked coroutine');
  context.assert((await host.call('resume_stacked', 72n))[0] === 72n, 'later C entry did not restore the real STACKED chain');

  host.hooks.cleanup = () => {
    host.checks.push(rejected(context, host.call('valid_after_failure'), 'REENTRY'));
    host.checks.push(rejected(context, host.instance.drain(), 'REENTRY'));
    const pointer = host.controls.allocate(32);
    context.assert(pointer !== 0, 'C-only allocation was not callable during an import');
    host.controls.free(pointer);
  };
  context.assert((await host.call('allocation_gc'))[0] === 42n && host.cleanup === 1,
    'apparently nonyielding callback did not complete allocation-triggered abandonment cleanup');
  await Promise.all(host.checks);
  host.hooks.cleanup = undefined;
  const beforeClosed = host.controls.snapshot().operationId;
  await rejected(context, host.instance.call(host.callbacks.get('independent_1'), 1n), 'HANDLE');
  await rejected(context, host.instance.call(host.callbacks.get('independent_2'), 1n), 'HANDLE');
  await rejected(context, host.call('callable_echo', host.callbacks.get('independent_3')), 'HANDLE');
  context.assert(host.controls.snapshot().operationId === beforeClosed, 'closed/cross-state argument entered Wasm');
  context.assert((await host.call('independent_3', 4n))[0] === 7n, 'detaching independently owned state invalidated it early');
  await host.call('close_detached');
  await host.call('close_detached');
  await rejected(context, host.instance.call(host.callbacks.get('independent_3'), 4n), 'HANDLE');
  context.assert(host.independentCloses.length === 6 && host.forbiddenRequests === 0,
    'explicit/GC/detach close did not run each registry-last finalizer exactly once');
  for (const index of [1n, 2n, 3n]) {
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
    for (const [name, positions] of [
      ['r1_release_results', [1n, 2n, 3n, 4n]],
      ['r1_gc_results', [1n, 2n, 3n]],
    ]) {
      for (const position of positions) {
        const results = await host.call('r1_prepare_results');
        context.assert(results.length === 4 && results[0] === host.bindings.r1_handle_first &&
          results[2] === host.bindings.r1_handle_last, 'R1 live handle results lost their actual host owners');
        context.assert((await results[1].call())[0] === 101n && (await results[3].call())[0] === 202n,
          'R1 live callable results lost their original closures');
        const before = invalidations;
        host.hooks.r1Release = selected => {
          context.assert(selected === position, 'R1 invalidation targeted the wrong result position');
          const value = results[Number(selected - 1n)];
          if (selected === 1n || selected === 3n) {
            context.assert(host.controls.invalidateHandle(value) === 1, 'R1 handle invalidation did not own exactly one real unit');
          } else value.release();
          invalidations++;
        };
        await rejected(context, host.call(name, position), 'TITAN');
        context.assert(invalidations === before + 1, 'R1 failure bypassed the real active-import invalidation');
        context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure'))[0] === 42n,
          'stale result identity poisoned an intact image instead of rejecting under protection');
      }
    }
  } finally {
    host.hooks.r1Release = undefined;
  }
  const recovered = host.callbacks.get('r1_publication_recovery');
  context.assert((await recovered.call())[0] === 42n, 'failed root publication prevented later original-closure recovery');
  recovered.release();
  await host.instance.drain();
  const before = host.controls.snapshot().operationId;
  await rejected(context, host.instance.call(recovered), 'HANDLE');
  context.assert(host.controls.snapshot().operationId === before, 'released publication-recovery root entered Wasm');
  await host.call('r1_close_publication');
  context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure'))[0] === 42n,
    'publication rollback/recovery/close poisoned the persistent owner');
  return {activeReleasePositions: 4, laterGcPositions: 3, publicationRecovery: 1};
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
        context.assert(attempts.length === 1 && attempts[0] === (mode === 'owner-allocation' ? 2n : 0n),
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
        (await host.call('valid_after_failure'))[0] === 42n,
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
    for (const name of ['r1_admit_start', 'r1_admit_listener', 'sdk_read', 'sdk_write']) {
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
      if (name === 'sdk_read') host.input.push(source.promise);
      const before = host.controls.snapshot();
      const counts = [host.successes.length, host.failures.length, host.ioDone,
        host.ioReads.length, host.ioFailures.length, host.stdout.length, host.capacities.length];
      restore = host.controls.exhaustSlotIdentities();
      try {
        const args = name === 'sdk_read' ? [4n] : name === 'sdk_write' ? [binary()] : [];
        await rejected(context, host.call(name, ...args), 'TITAN');
      } finally { restore(); restore = undefined; }
      context.assert(accepted === 0 && cancelled === 0 && host.controls.snapshot().requests === 0 &&
        host.controls.snapshot().units === before.units && host.stdout.length === counts[5] &&
        host.capacities.length === counts[6], 'slot refusal occurred after host/source/output acceptance: ' + name);
      if (name === 'sdk_read') context.assert(host.input.pop() === source.promise, 'rejected stdin consumed its host source');
      source.resolve([96n, binary()]);
      await context.tick(); await host.instance.drain();
      context.assert(host.successes.length === counts[0] && host.failures.length === counts[1] &&
        host.ioDone === counts[2] && host.ioReads.length === counts[3] && host.ioFailures.length === counts[4],
        'unaccepted request produced a terminal notification: ' + name);
      context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure'))[0] === 42n,
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
      else source.resolve([97n, binary()]);
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

    const input = gate(), reads = host.ioReads.length, capacities = host.capacities.length;
    let readAccepted = 0;
    host.input.push({
      get kind() {
        if (!restore) { readAccepted++; restore = host.controls.exhaustSlotIdentities(); }
        return 'detachable';
      },
      promise: input.promise,
    });
    try { await host.call('sdk_read', 4n); }
    finally { restore?.(); restore = undefined; }
    context.assert(readAccepted === 1 && host.capacities.length === capacities + 1 &&
      host.controls.snapshot().requests === 1, 'stdin did not reserve its owner before source acceptance');
    input.resolve(binary());
    await context.tick(); await host.instance.drain();
    context.assert(host.ioReads.length === reads + 1 && host.controls.snapshot().requests === 0,
      'accepted stdin did not complete and retire its actual source');
    context.equalBytes(host.ioReads.at(-1), binary());
    context.assert(engineFailures.length === 0 && (await host.call('valid_after_failure'))[0] === 42n,
      'reserved request/source publication poisoned later calls');
  } finally {
    restore?.();
    host.hooks.r1Start = host.hooks.r1Listen = undefined;
  }
  return {rejectedBeforeAcceptance: 4, acceptedStarts: 2, acceptedListeners: 1, acceptedReads: 1};
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
  context.assert((await host.call('valid_after_failure'))[0] === 42n, 'notification observer error poisoned the owner');

  let target = (await host.call('make_callable'))[0];
  const beforeTarget = completions.filter(record => record.kind === 3).length;
  host.instance.notify(target);
  target.release(); target.release();
  await host.instance.drain();
  context.assert(completions.filter(record => record.kind === 3).length === beforeTarget,
    'released notification target still entered Lua');
  await rejected(context, target.call(), 'DISPOSED');
  await rejected(context, host.instance.call(target), 'HANDLE');
  await rejected(context, host.call('stored_callable'), 'TITAN');
  context.assert((await host.call('valid_after_failure'))[0] === 42n,
    'stale native Callable result escaped protected encoding or poisoned the owner');
  const previous = target;
  target = (await host.call('make_callable'))[0];
  context.assert(target !== previous && (await target.call())[0] === 77n, 'reused callable generation revived its old wrapper');
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

async function requests(context, host) {
  const rejection = Object.freeze({request: 'original rejection'});
  const source = gate();
  host.bindings.success_request = formBinding({kind: 'detachable', promise: source.promise});
  await host.call('start_request', encode('success_request'));
  let snapshot = host.controls.snapshot();
  source.resolve([23n, binary()]);
  await context.tick();
  context.assert(host.successes.length === 0 && host.controls.snapshot().operationId === snapshot.operationId &&
    host.controls.snapshot().slots === snapshot.slots, 'request settlement entered Lua or eagerly allocated a slot');
  await host.instance.drain();
  context.assert(host.successes.length === 1 && host.successes[0][0] === 23n);
  context.equalBytes(host.successes[0][1], binary());
  await host.call('close_request');

  const failed = gate();
  host.bindings.failure_request = formBinding({kind: 'detachable', promise: failed.promise});
  await host.call('start_request', encode('failure_request'));
  snapshot = host.controls.snapshot();
  const errors = host.notificationErrors.length;
  failed.reject(rejection);
  await context.tick();
  context.assert(host.failures.length === 0 && host.controls.snapshot().slots === snapshot.slots &&
    host.controls.snapshot().operationId === snapshot.operationId, 'request rejection bypassed copied notification admission');
  await host.instance.drain();
  context.assert(host.failures.length === 1 && host.failures[0][1] === rejection && host.notificationErrors.length === errors,
    'host rejection did not reach exactly its mandatory failure Callable with original thrown identity');
  await host.call('close_request');

  const duplicate = {then(resolve, reject) { resolve([24n, binary()]); resolve([25n, binary()]); reject(rejection); }};
  host.bindings.duplicate_request = formBinding({kind: 'detachable', promise: duplicate});
  await host.call('start_request', encode('duplicate_request'));
  await context.tick(); await host.instance.drain();
  context.assert(host.successes.length === 2 && host.successes.at(-1)[0] === 24n && host.failures.length === 1,
    'request terminal settlement was not at-most-once');
  await host.call('close_request');

  const cancelled = gate();
  let cancels = 0;
  host.bindings.cancel_request = formBinding({kind: 'detachable', promise: cancelled.promise, cancel() { cancels++; }});
  await host.call('start_request', encode('cancel_request'));
  await host.call('cancel_request'); await host.call('cancel_request');
  cancelled.resolve([26n, binary()]);
  await context.tick(); await host.instance.drain();
  context.assert(cancels === 1 && host.successes.length === 2 && host.controls.snapshot().requests === 0,
    'logical cancellation was duplicated or admitted late settlement');
  await host.call('close_request');

  const never = gate();
  host.bindings.never_request = formBinding({kind: 'detachable', promise: never.promise});
  await host.call('start_request', encode('never_request'));
  await host.call('cancel_request'); await host.call('close_request');
  host.retainedPromise = never.promise; // Kept externally through post-disposal GC.

  const initial = host.successes.length;
  await host.call('start_listener');
  context.assert(host.successes.length === initial, 'synchronously fired listener entered inline');
  await host.instance.drain();
  context.assert(host.successes.at(-1)[0] === 31n);
  for (const emit of host.listeners) { emit(32n, binary()); emit(33n, binary()); }
  await host.instance.drain();
  context.assert(host.successes.slice(initial).map(item => item[0]).join(',') === '31,32,33', 'listener events lost FIFO order');
  await host.call('cancel_request'); await host.call('close_request');
  for (const emit of host.retainedListeners) emit(34n, binary());
  await context.tick(); await host.instance.drain();
  context.assert(host.unregisters === 1 && host.listeners.size === 0 && host.successes.length === initial + 3,
    'listener unregister or late-event retirement was not exact');
  for (const [name, binding] of [
    ['ordinary_runtime', () => { throw new WebAssembly.RuntimeError('ordinary host RuntimeError'); }],
    ['bare_request', () => Promise.resolve([1n, binary()])],
  ]) {
    host.bindings[name] = binding;
    await rejected(context, host.call('start_request', encode(name)), 'TITAN');
    context.assert(host.controls.snapshot().requests === 0 && (await host.call('valid_after_failure'))[0] === 42n,
      name + ' bypassed import containment/explicit ownership or poisoned the instance');
  }
  const terminal = gate(), explicitCancel = new Error('explicit cancel failed');
  let signals = 0;
  const successes = host.successes.length, failures = host.failures.length;
  host.bindings.throwing_cancel = formBinding({kind: 'retained', promise: terminal.promise,
    cancel() { signals++; throw explicitCancel; }});
  await host.call('start_request', encode('throwing_cancel'));
  await rejected(context, host.call('cancel_request'), 'TITAN');
  context.assert(signals === 1 && host.controls.snapshot().requests === 1 &&
    (await host.call('valid_after_failure'))[0] === 42n, 'explicit cancel error retired retained work or poisoned the owner');
  await host.call('cancel_request');
  terminal.resolve([77n, binary()]);
  await context.tick(); await host.instance.drain();
  context.assert(signals === 1 && host.controls.snapshot().requests === 0 &&
    host.successes.length === successes && host.failures.length === failures, 'cancel failure admitted late or duplicate terminal work');
  await host.call('close_request');
}

async function stdio(context, host) {
  const cause = new Error('latched C-stdio append failure');
  host.sinks.stdout = () => { throw cause; };
  const appendFailure = await captureRejection(context, host.call('stdio_append', binary()), 'SINK');
  context.assert(appendFailure.cause === cause);
  host.sinks.stdout = undefined;
  context.assert((await host.call('valid_after_failure'))[0] === 42n,
    'latched C-only sink failure poisoned an unrelated output-free call');
  await host.instance.drain();
  const beforeFailure = host.ioFailures.length, beforeSuccess = host.ioDone;
  const delayed = await captureRejection(context, host.call('sdk_write', encode('after-append')), 'SINK');
  context.assert(delayed === appendFailure, 'next completion-carrying write lost the C-only append failure');
  await host.instance.drain();
  context.assert(host.ioFailures.length === beforeFailure + 1 && host.ioFailures.at(-1)[1] === appendFailure &&
    host.ioDone === beforeSuccess, 'latched append failure did not reach exactly its next write failure target');
  await host.call('sdk_write', encode('after-latch'));
  await host.instance.drain();
  context.assert(host.ioDone === beforeSuccess + 1, 'consumed C-stdio latch suppressed a later write');
  const alias = new AliasingBytes(binary());
  host.instance.notify(host.callbacks.get('sdk_write'), alias);
  alias.fill(90);
  await host.instance.drain();
  context.equalBytes(host.stdout.at(-1), binary(), 'notification argument slice-as-view escaped snapshot ownership');
  await host.instance.drain();
  const payloads = [binary(), new Uint8Array(), encode('unterminated-tail')];
  let pending = 0, maximum = 0, calls = 0;
  const output = gate();
  host.sinks.stdout = () => {
    pending++; calls++; maximum = Math.max(maximum, pending);
    return (calls === 1 ? output.promise : Promise.resolve()).then(() => { pending--; });
  };
  const beforeDone = host.ioDone, beforeChunks = host.stdout.length;
  for (const bytes of payloads) host.instance.notify(host.callbacks.get('sdk_write'), bytes);
  const draining = host.instance.drain();
  await until(context, () => calls === 1, 'ordered output did not start its first sink');
  await rejected(context, host.call('valid_after_failure'), 'REENTRY');
  await rejected(context, host.instance.drain(), 'REENTRY');
  context.assert(host.ioDone === beforeDone && calls === 1, 'pending sink overlapped another write or callback');
  output.resolve();
  await draining;
  context.assert(calls === 3 && maximum === 1 && host.ioDone === beforeDone, 'stream did not serialize the detached write batch');
  for (let index = 0; index < payloads.length; index++) {
    context.equalBytes(host.stdout[beforeChunks + index], payloads[index]);
  }
  await host.instance.drain();
  context.assert(host.ioDone === beforeDone + 3, 'write completion callbacks did not use the following protected batch');

  for (const behavior of ['throw', 'reject']) {
    const cause = new Error(`ordered sink ${behavior}`);
    host.sinks.stdout = behavior === 'throw' ? () => { throw cause; } : () => Promise.reject(cause);
    const done = host.ioDone, failed = host.ioFailures.length;
    const error = await captureRejection(context, host.call('sdk_write', binary()), 'SINK');
    context.assert(error.cause === cause, 'write operation replaced its original sink cause');
    host.sinks.stdout = undefined;
    await host.instance.drain();
    context.assert(host.ioDone === done && host.ioFailures.length === failed + 1 && host.ioFailures.at(-1)[1] === error,
      'failed completion-carrying write did not deliver its own failure Callable');
    await host.call('sdk_write', binary());
    await host.instance.drain();
    context.assert(host.ioDone === done + 1, 'sink failure suppressed a later entry');
  }
  host.sinks.stdout = undefined;

  const bytes = new Uint8Array([0, 255, 195, 40, 88, 99]);
  host.input.push({bytes, length: 4});
  await host.call('sdk_read', 4n);
  bytes.fill(90);
  context.assert(host.ioReads.length === 0, 'stdin completion was entered synchronously');
  await host.instance.drain();
  context.equalBytes(host.ioReads[0], binary(), 'stdin did not copy exact returned length');
  const source = gate();
  host.input.push({kind: 'detachable', promise: source.promise});
  await host.call('sdk_read', 8n);
  source.resolve(new Uint8Array([1, 2, 3]));
  await context.tick(); await host.instance.drain();
  context.equalBytes(host.ioReads.at(-1), new Uint8Array([1, 2, 3]));
  const failures = host.ioFailures.length;
  host.input.push(new Uint8Array(5));
  await host.call('sdk_read', 4n);
  await host.instance.drain();
  context.assert(host.ioFailures.length === failures + 1 && host.ioFailures.at(-1)[1] instanceof TypeError,
    'over-capacity stdin bypassed mandatory failure delivery');
  context.assert(host.capacities.map(Number).join(',') === '4,8,4', 'stdin requested capacity changed');
  return {writes: host.ioDone - beforeDone, maximumInflight: maximum, reads: host.ioReads.length};
}

async function prepareRetainedDisposal(context, host) {
  await host.call('close_detached');
  const request = gate(), input = gate();
  let cancellations = 0;
  host.bindings.retained_request = formBinding({kind: 'retained', promise: request.promise,
    cancel() { cancellations++; }});
  await host.call('start_request', encode('retained_request'));
  host.input.push({kind: 'retained', promise: input.promise, cancel() { cancellations++; }});
  await host.call('sdk_read', 16n);
  const references = host.controls.weakTargets();
  const trace = host.instance.trace;
  const disposal = host.instance.dispose(), marker = watch(disposal);
  await context.tick();
  context.assert(!marker.settled && cancellations === 2, 'disposal confused retained cancellation with physical completion');
  await rejected(context, host.instance.run(), 'DISPOSED');
  await rejected(context, host.instance.call(host.callbacks.get('increment'), 1n), 'DISPOSED');
  await rejected(context, host.instance.drain(), 'DISPOSED');
  request.resolve([99n, binary()]);
  await context.tick();
  context.assert(!marker.settled, 'one terminal request freed another retained owner');
  input.resolve(binary());
  await disposal;
  context.assert(Object.isFrozen(host.instance.trace) && host.instance.trace.state === trace.state &&
    host.instance.trace.reason === trace.reason, 'ordinary disposal discarded its final trace snapshot');
  context.assert(host.successes.length === 0 && host.ioReads.length === 0 && host.closes.length === 2,
    'retirement admitted an application callback or skipped close');
  context.assert(host.controls.snapshot().units === 0 && host.controls.snapshot().requests === 0,
    'retained disposal leaked state-owned units');
  host.releaseObservations();
  return references;
}

async function retainedDisposal(context, host) {
  const references = await prepareRetainedDisposal(context, host);
  await collected(context, references, 'retainedDisposal');
  return references.length;
}

async function prepareDetachableDisposal(context, host) {
  const input = gate();
  host.input.push({kind: 'detachable', promise: input.promise});
  await host.call('sdk_read', 16n);
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
  const successes = host.successes.length, reads = host.ioReads.length;
  for (const emit of emitters) emit(98n, binary());
  input.resolve(binary());
  host.instance.notify(undefined, Object.freeze({postDispose: true})); // Inert after disposal.
  await context.tick();
  context.assert(host.successes.length === successes && host.ioReads.length === reads && host.unregisters === 2,
    'disposed listener/stdin admitted late application work');
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
  const interrupted = rejected(context, host.call('sdk_write', binary()), 'DISPOSED');
  await until(context, () => observation.calls === 1, 'pending output sink was not entered');
  const references = host.controls.weakTargets();
  let disposal = host.instance.dispose();
  await interrupted;
  await rejected(context, disposal, 'DISPOSED');
  context.assert(observation.calls === 1 && host.closes.length === 2 && host.ioDone === 0 && host.ioFailures.length === 0,
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

      const background = (await host.call('make_callable'))[0];
      const beforeBackground = host.notificationErrors.length;
      host.controls.failNextRelease();
      background.release();
      await until(context, () => host.notificationErrors.length > beforeBackground,
        'callerless physical release failure was discarded');
      const notification = host.notificationErrors[beforeBackground];
      context.assert(host.notificationErrors.length === beforeBackground + 1 && notification.kind === 'cleanup' &&
        notification.operation === 'release_callable' && notification.error.code === 'TITAN_BROWSER_TITAN',
        'callerless release did not report exactly one tagged cleanup failure');
      context.equalBytes(notification.error.bytes, encode('browser state is closed'));
      const afterRelease = host.controls.snapshot().operationId;
      await context.tick(); await context.tick();
      context.assert(host.controls.snapshot().operationId === afterRelease,
        'failed physical release was retried instead of leaving retirement to state close');
      context.assert((await host.call('valid_after_failure'))[0] === 42n,
        'callerless release failure poisoned later valid entry');
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
      const deferred = (await host.call('make_callable'))[0];
      const beforeErrors = host.notificationErrors.length;
      const beforeOut = host.stdout.length, beforeErr = host.stderr.length;
      host.controls.failNextRelease();
      deferred.release();
      const error = await captureRejection(context, host.call('cleanup_failure', binary()), 'TITAN');
      context.equalBytes(error.bytes, original.bytes, 'cleanup replaced the primary Titan message');
      context.equalBytes(error.trace, original.trace, 'cleanup replaced the primary Titan trace');
      await Promise.all(checks);
      checks.length = 0;
      host.sinks.stdout = host.sinks.stderr = undefined;
      context.equalBytes(join(host.stdout.slice(beforeOut)), binary(), 'retirement failure skipped the surviving stdout flush');
      context.equalBytes(join(host.stderr.slice(beforeErr)), binary(), 'retirement failure skipped the stderr flush');
      const events = host.notificationErrors.slice(beforeErrors);
      context.assert(events.every(event => event.kind === 'cleanup' && event.operation === 'call') &&
        events.length === 1 + calls.stdout + calls.stderr, 'secondary cleanup failures were lost, duplicated or mistagged');
      const releases = events.filter(event => event.error.code === 'TITAN_BROWSER_TITAN');
      context.assert(releases.length === 1, 'primary failure replaced or duplicated its failed physical retirement');
      context.equalBytes(releases[0].error.bytes, encode('browser state is closed'));
      secondaryReleases++;
      for (const stream of ['stdout', 'stderr']) {
        const failures = events.filter(event => event.error.stream === stream);
        context.assert(failures.length === calls[stream] &&
          failures.every(event => event.error.code === 'TITAN_BROWSER_SINK' && event.error.cause === causes[stream]),
          `${stream} secondary failure lost its original cause or per-invocation identity`);
        secondarySinks += failures.length;
      }
      const count = host.notificationErrors.length;
      context.assert((await host.call('valid_after_failure'))[0] === 42n,
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
}

async function operationIdentities(context, image) {
  const host = createHost(context, image, {stdin: undefined});
  let unwatch;
  const records = [];
  try {
    await host.instance.initialize();
    await nativeRun(context, host);
    await host.call('close_detached');
    await rejected(context, host.call('sdk_read', 1n), 'TITAN');
    context.assert(host.controls.snapshot().requests === 0 && (await host.call('valid_after_failure'))[0] === 42n,
      'missing stdin silently supplied data, accepted a request or poisoned the intact owner');
    const signedBoundary = (1n << 63n) - 1n;
    host.controls.advanceOperationId(signedBoundary - 1n);
    unwatch = host.controls.watchCompletions(record => { records.push({id: record.id, kind: record.kind}); });
    for (let index = 0; index < 3; index++) context.assert((await host.call('valid_after_failure'))[0] === 42n);
    context.assert(records.length === 3 && records.every((record, index) =>
      record.id === signedBoundary + BigInt(index) && record.kind === 3),
      'uint64 identity changed sign across the Wasm import boundary');
    const callable = (await host.call('make_callable'))[0];
    const maximum = (1n << 64n) - 1n;
    host.controls.advanceOperationId(maximum - 2n);
    callable.release(); // Its root must retire with close, without spending the reserved final id.
    context.assert((await host.call('valid_after_failure'))[0] === 42n);
    context.assert(records.at(-1).id === maximum - 1n, 'last application entry used the reserved close identity');
    const before = records.length;
    await rejected(context, host.call('valid_after_failure'), 'STATE');
    await rejected(context, host.instance.drain(), 'STATE');
    context.assert(records.length === before, 'exhausted admission entered Wasm or reused an identity');
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
      await rejected(context, host.call('start_request', encode('dispose_request')), 'DISPOSED');
      await context.tick();
      context.assert(!marker.settled && host.closes.length === 0 && signals === 1 &&
        host.controls.snapshot().requests === 1, 'throwing cancellation retired a live retained operation');
      terminal.resolve([88n, binary()]);
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
    context.assert((await second.call('increment', 100n))[0] === 100n && (await first.call('read_capture'))[0] === 3n,
      'instances shared original capture ownership');
    const announcements = await notifications(context, first, completions);
    await requests(context, first);
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
    const cleanup = await cleanupFailures(context, image);
    await interruptedFailure(context, image);
    await initializationFailure(context, failedImage);
    const identities = await operationIdentities(context, image);
    context.stdout(encode('BRIDGE ' + JSON.stringify({verdict: 'PASS', nativeCases: counts,
      instances: 2, interleavedSwitches: switches, operations: completions.length, requestDrain: announcements,
      notifications: first.notifications.length, requests: first.successes.length + first.failures.length,
      io, repairs, cleanup, identities, materialization, collectedTargets, finalizerDrains: 2}) + '\n'));
  } finally {
    unwatchFirst?.(); unwatchSecond?.(); unwatchCompletions?.();
    await Promise.all([first, second].map(host => host.instance?.dispose().catch(() => {})));
    first.releaseObservations(); second.releaseObservations();
  }
}
