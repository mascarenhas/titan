import {decode, encode, makeHost, observe, rejection, settledMarker, thrown, until} from './support.mjs';

// The drive interface without async: owner identity, SDK bindings, idle and
// queued Task-form calls, waits, idle detection and AbortSignal admission.
async function surface(context, image) {
  const reserved = thrown(context, () => image.create({locateFile: image.locateFile,
    bindings: {'titan:timeout': () => 0}}), 'TypeError');
  context.assert(reserved.message.includes('reserved'), 'a reserved titan: binding name was accepted');
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    context.assert(Number.isInteger(host.snapshot().ownerState), 'the owner state was not reported');
    context.assert(await host.call('owner_probe') ===
      "owner: browser relinquish requires the driving owner's main thread outside delivery",
      'the owner state did not refuse a relinquish outside its drive');
    context.assert(await host.call('child_probe') ===
      "child: browser drive requires the instance owner's main thread",
      'a C-created state claimed ownership or began a drive');
    context.assert(await host.call('sdk_unknown') === 'unknown browser binding titan:unknown',
      'an unknown titan: name resolved to a user or SDK binding');
    const missing = await rejection(context, host.task('echo', [1n]), 'STATE');
    context.assert(missing.message === 'browser image has no async Runtime', 'Task-form call without a driver');
    await host.call('register');
    context.assert(await host.task('echo', [9n]) === 9n, 'idle Task-form call');
    context.assert(await host.fn('echo').callTask([3n]) === 3n, 'wrapper Task-form call');
    await rejection(context, host.task('child_echo', [1n]), 'STATE');
    const failed = await rejection(context, host.task('fail', ['boom']), 'TITAN');
    context.assert(decode(failed.bytes) === 'boom' && failed.status === 1 && failed.trace.length > 0,
      'a failed Task lost its bytes, status or trace');
    context.assert(await host.task('nap', [5]) === 'woke', 'a Task waiting on titan:timeout');
    const idle = await rejection(context, host.task('orphan'), 'TITAN');
    context.assert(decode(idle.bytes) === 'mini driver became idle while jobs were waiting' &&
      host.probes.some(probe => probe.status === 1), 'a wait with no wake source did not report IDLE');
    const reason = {why: 'pre-aborted'};
    const controller = new AbortController();
    controller.abort(reason);
    const cancelled = await rejection(context, host.task('echo', [1n], {signal: controller.signal}), 'CANCELLED');
    context.assert(cancelled.reason === reason, 'a pre-aborted signal lost its reason');
    const result = await host.instance.run(['return']);
    context.assert(result.kind === 'returned' && result.status === 7, 'a run without a drive');
    const snapshot = host.snapshot();
    context.assert(!snapshot.driving && snapshot.settling === 0 && snapshot.queue === 0, 'drive state leaked');
    return host.probes.length;
  } finally { await host.instance.dispose(); }
}

// Turns are macrotasks, and output reaches the sinks during the drive.
async function turns(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    setTimeout(() => { host.flag = true; }, 0);
    const spun = await host.task('spin', [5000n]);
    context.assert(spun > 0n, 'turn relinquishes never yielded to a host macrotask');
    context.assert(host.probes.length > 0 && host.probes.every(probe => probe.status === 0),
      'a turn relinquish reported a status other than RESUMED');
    const chatty = await host.task('chatter', [500n]);
    context.assert(chatty > 1n && decode(host.stdout[0]).startsWith('chatter\n'),
      'drive output reached the sink only after the drive');
    return {spun: Number(spun), chatter: Number(chatty)};
  } finally { await host.instance.dispose(); }
}

// A forever-pending sink holds the operation, never the drive.
async function pendingSink(context, image) {
  let sinkCalls = 0;
  const host = makeHost(context, image);
  host.hooks.stdout = () => { sinkCalls++; return new Promise(() => {}); };
  try {
    await host.instance.initialize();
    await host.call('register');
    const task = host.task('chatter', [500n]);
    const marker = settledMarker(task);
    await until(context, () => sinkCalls === 1 && !host.snapshot().driving, 'a pending sink stalled the drive');
    context.assert(!marker.settled, 'the operation settled before its pending sink');
    const disposing = host.instance.dispose();
    await rejection(context, task, 'DISPOSED');
    await disposing.catch(error => context.assert(error.code === 'TITAN_BROWSER_DISPOSED',
      `pending-sink disposal failed with ${error.code}`));
    return sinkCalls;
  } finally { await host.instance.dispose().catch(() => {}); }
}

// A wait relinquish with no wake source returns IDLE without parking: output
// written before it stays buffered through the coroutine switches the idle
// drive then makes, and reaches the sinks at the operation's final flush.
async function idleOutput(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    const idle = await rejection(context, host.task('idle_output'), 'TITAN');
    context.assert(decode(idle.bytes) === 'mini driver became idle while jobs were waiting' &&
      host.probes.some(probe => probe.status === 1), 'idle_output did not end in an IDLE relinquish');
    await until(context, () => host.stdout.length > 0 && host.stderr.length > 0,
      'output written before an IDLE relinquish was lost');
    context.assert(decode(host.stdout[0]) === 'before idle\n' && decode(host.stderr[0]) === 'before idle\n',
      'output written before an IDLE relinquish changed');
    context.assert(host.unparkedSinks === 0, 'a sink ran while the idle drive switched coroutines');
    await host.instance.dispose();
    return host.stdout.length + host.stderr.length;
  } finally { await host.instance.dispose().catch(() => {}); }
}

// Output a parked gate publishes while an earlier sink call is pending
// reaches its sink when that call resolves, with the drive still parked and
// no new wake. The sweep releases the pending call from inside the turn that
// writes the next line, a few microtasks deep and across a few coroutine
// round trips, so the runner retires on every side of the next gate.
async function delayedSinks(context, image) {
  const report = {};
  for (const stream of ['stdout', 'stderr']) {
    const host = makeHost(context, image);
    const lines = [];
    let hold = false, release;
    host.hooks[stream] = bytes => {
      lines.push(decode(bytes));
      if (!hold) return undefined;
      hold = false;
      return new Promise(resolve => { release = resolve; });
    };
    const reached = text => () => lines.includes(text) && host.snapshot().parked;
    try {
      await host.instance.initialize();
      await host.call('register');
      const controller = new AbortController();
      const hanging = host.task('hang', [], {signal: controller.signal});
      await until(context, () => host.snapshot().parked, 'hang did not park its drive');
      hold = true;
      await host.task('hop_write', ['first\n', stream, 0n]);
      await until(context, reached('first\n'), `the first ${stream} line never reached its sink`);
      await host.task('hop_write', ['second\n', stream, 0n]);
      for (let tick = 0; tick < 5; tick++) await context.tick();
      context.assert(lines.length === 1, `a second ${stream} sink call overlapped a pending one`);
      const wakes = host.probes.length;
      release();
      await until(context, reached('second\n'), `${stream} output published during a pending sink call was stranded`);
      context.assert(host.probes.length === wakes, `delivering pending ${stream} output woke the drive`);
      let rounds = 0;
      for (let hops = 0n; hops <= 4n; hops++) {
        for (let depth = 0; depth <= 4; depth++) {
          const before = `before ${hops}/${depth}\n`, after = `after ${hops}/${depth}\n`;
          hold = true;
          await host.task('hop_write', [before, stream, 0n]);
          await until(context, reached(before), `${stream} line ${before.trim()} never reached its sink`);
          host.hooks.kick = () => {
            let chain = Promise.resolve();
            for (let step = 0; step < depth; step++) chain = chain.then();
            chain.then(release);
          };
          await host.task('hop_write', [after, stream, hops]);
          host.hooks.kick = undefined;
          await until(context, reached(after),
            `${stream} output after ${hops} hops and a release ${depth} microtasks deep was stranded`);
          rounds++;
        }
      }
      context.assert(host.unparkedSinks === 0, `a ${stream} sink ran while the drive was not parked`);
      controller.abort('done');
      await rejection(context, hanging, 'CANCELLED');
      await host.instance.dispose();
      report[stream] = rounds;
    } finally { await host.instance.dispose().catch(() => {}); }
  }
  return report;
}

// A held sink call that settles while the drive runs a later turn's
// coroutine switches starts no further sink call: output already published
// behind it, and full 1024-byte chunks that turn sealed before switching,
// wait for the next parked gate. Each case parks a drive on `hang` and holds
// the sink call for a first line; `release()` arms the next `kick` to settle
// it from a microtask, which runs at the turn's first internal handoff.
const heldSinkCases = {
  async published(host, stream, release) {
    await host.task('hop_write', ['second\n', stream, 0n]);
    release();
    await host.task('hops');
    return 'second\n';
  },
  async chunks(host, stream, release) {
    const big = 'x'.repeat(4096) + '\n';
    release();
    await Promise.all([host.task('hop_write', [big, stream, 0n]), host.task('hops')]);
    return big;
  },
};

async function heldSinkHandoffs(context, image) {
  const report = {};
  for (const stream of ['stdout', 'stderr']) {
    for (const [name, exercise] of Object.entries(heldSinkCases)) {
      const host = makeHost(context, image);
      const lines = [];
      let held = true, settle;
      host.hooks[stream] = bytes => {
        lines.push(decode(bytes));
        if (!held) return undefined;
        held = false;
        return new Promise(resolve => { settle = resolve; });
      };
      const release = () => {
        host.hooks.kick = () => {
          host.hooks.kick = undefined;
          queueMicrotask(settle);
        };
      };
      const parkedWith = text => () => lines.join('').includes(text) && host.snapshot().parked;
      const label = `${stream} ${name}`;
      try {
        await host.instance.initialize();
        await host.call('register');
        const controller = new AbortController();
        const hanging = host.task('hang', [], {signal: controller.signal});
        await until(context, () => host.snapshot().parked, 'hang did not park its drive');
        await host.task('hop_write', ['first\n', stream, 0n]);
        await until(context, parkedWith('first\n'), `${label}: the held line never reached its sink`);
        const expected = await exercise(host, stream, release);
        await until(context, parkedWith(expected), `${label}: output waiting behind a held sink call was lost`);
        context.assert(host.unparkedSinks === 0, `${label}: a sink call started while the drive ran`);
        controller.abort('done');
        await rejection(context, hanging, 'CANCELLED');
        await host.instance.dispose();
        report[label] = lines.length;
      } finally { await host.instance.dispose().catch(() => {}); }
    }
  }
  return report;
}

// Calls and notifications made during a drive, and the rows that refuse.
async function queue(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    const controller = new AbortController();
    const hanging = host.task('hang', [], {signal: controller.signal});
    await until(context, () => host.snapshot().parked, 'hang did not park its drive');
    context.assert(await host.call('echo', 5n) === 5n && host.snapshot().driving,
      'a call made while the drive was relinquished');
    host.instance.notify(host.fn('note'), 'n1');
    await until(context, () => host.notes.length === 1, 'the driver did not deliver a notification');
    context.assert(host.notes[0] === 'n1' && host.snapshot().driving, 'notification delivery');
    await rejection(context, host.call('child_echo', 1n), 'REENTRY');
    thrown(context, () => host.instance.notify(host.fn('child_echo'), 1n), 'REENTRY');
    context.assert(await host.task('echo', [11n]) === 11n && host.snapshot().driving,
      'a Task-form call joining the drive');
    host.hooks.reenter = () => {
      host.reentered = [host.call('echo', 1n), host.task('echo', [1n]), observe(host.instance.drain())];
    };
    await host.task('reenter');
    for (const promise of host.reentered) await rejection(context, promise, 'REENTRY');
    host.hooks.kick = () => queueMicrotask(() => { host.hopCall = host.call('echo', 7n); });
    await host.task('hops');
    context.assert(await host.hopCall === 7n, 'a call from a microtask between internal hops');
    const releases = host.snapshot().releases;
    host.fn('spare').release();
    context.assert(host.snapshot().releases === releases + 1, 'a wrapper release was not deferred');
    host.instance.notify(host.fn('note'), 'n2');
    await until(context, () => host.notes.length === 2, 'the second notification');
    context.assert(host.snapshot().releases === 0 && host.snapshot().driving,
      'the driver did not apply deferred releases between turns');
    const reason = {why: 'aborted while waiting'};
    controller.abort(reason);
    const cancelled = await rejection(context, hanging, 'CANCELLED');
    context.assert(cancelled.reason === reason && !host.snapshot().driving, 'AbortSignal cancellation');
    // The hops job is the drive's only job, so a call queued during its hops
    // misses the last batch, outlives the drive and runs as an idle call.
    host.hooks.kick = () => queueMicrotask(() => { host.leftCall = host.call('echo', 8n); });
    await host.task('hops');
    context.assert(await host.leftCall === 8n, 'a call left by an ended drive did not run');
    return host.notes.length;
  } finally { await host.instance.dispose(); }
}

async function disposeHost(context, image) {
  const host = makeHost(context, image);
  await host.instance.initialize();
  await host.call('register');
  return host;
}

function statusesAfter(host, index) {
  return host.probes.slice(index).map(probe => probe.status);
}

// Disposal with a running drive, a cleanup drive, and no Runtime after exit.
async function disposal(context, image) {
  const summary = {};
  let host = await disposeHost(context, image);
  const hanging = host.task('hang');
  await until(context, () => host.snapshot().parked, 'hang did not park');
  let before = host.probes.length;
  const queued = host.call('echo', 1n);
  let disposing = host.instance.dispose();
  await rejection(context, queued, 'DISPOSED');
  await rejection(context, hanging, 'DISPOSED');
  await disposing;
  summary.parked = statusesAfter(host, before);
  context.assert(summary.parked.join() === '2', `a parked drive saw ${summary.parked} after dispose`);

  // Cleanup awaiting host work started before dispose() gets its settlement.
  host = await disposeHost(context, image);
  const guarded = host.task('guarded', [60]);
  await until(context, () => host.snapshot().parked, 'guarded did not park');
  before = host.probes.length;
  disposing = host.instance.dispose();
  await rejection(context, guarded, 'DISPOSED');
  await disposing;
  summary.cleanup = statusesAfter(host, before);
  context.assert(host.cleanup.join('|') === 'new work: browser state is closing|cleanup settled',
    `cleanup notes: ${host.cleanup}`);
  context.assert(summary.cleanup.length <= 3 && summary.cleanup.every(status => status === 2),
    `cleanup awaiting host work spun: ${summary.cleanup}`);

  // Cleanup waiting on no wake source still reaches idle detection.
  host = await disposeHost(context, image);
  const hung = host.task('hang');
  await until(context, () => host.snapshot().parked, 'hang did not park');
  before = host.probes.length;
  const stubborn = host.task('stubborn');
  await until(context, () => host.probes.length > before && host.snapshot().parked, 'stubborn did not start');
  before = host.probes.length;
  disposing = host.instance.dispose();
  await rejection(context, hung, 'DISPOSED');
  await rejection(context, stubborn, 'DISPOSED');
  await disposing;
  summary.orphaned = statusesAfter(host, before);
  context.assert(summary.orphaned.join() === '2,1', `orphaned cleanup saw ${summary.orphaned}`);

  // No drive at dispose(): the shutdown callable drives the cleanup.
  host = await disposeHost(context, image);
  await host.call('park_idle', 50);
  before = host.probes.length;
  await host.instance.dispose();
  summary.shutdown = statusesAfter(host, before);
  context.assert(host.shutdowns === 1 && summary.shutdown.join() === '2,2' &&
    host.cleanup.join('|') === 'new work: browser state is closing|cleanup settled',
    `shutdown cleanup: ${host.shutdowns} ${summary.shutdown} ${host.cleanup}`);

  // An exited instance has no Runtime for shutdown to clean up.
  host = await disposeHost(context, image);
  const exited = await host.instance.run(['exit']);
  context.assert(exited.kind === 'exited', 'exit before disposal');
  await host.instance.dispose();
  context.assert(host.shutdowns === 0, 'disposal ran shutdown after exit');
  return summary;
}

// The exit latch: results, precedence and later admission.
async function exits(context, image) {
  let host = await disposeHost(context, image);
  const result = await host.instance.run(['exit']);
  context.assert(result.kind === 'exited' && result.status === 259 && result.bytes.length === 0,
    `exit result ${JSON.stringify(result)}`);
  for (const promise of [host.call('echo', 1n), host.task('echo', [1n]), observe(host.instance.drain()),
      observe(host.instance.run([]))]) {
    const error = await rejection(context, promise, 'EXITED');
    context.assert(error.status === 259, 'an exited rejection lost its status');
  }
  thrown(context, () => host.instance.notify(host.fn('note'), 'late'), 'EXITED');
  await host.instance.dispose();

  host = await disposeHost(context, image);
  const drove = await rejection(context, host.call('drive_job', host.fn('exit_with'), 5n), 'EXITED');
  context.assert(drove.status === 5, 'a call whose drive exited');
  await host.instance.dispose();

  host = await disposeHost(context, image);
  const failed = await host.instance.run(['exit-fail']);
  context.assert(failed.kind === 'failed' && failed.status === 1 &&
    decode(failed.bytes).includes('main failed after its drive exited'), 'a failure after exit stays failed');
  const latched = await rejection(context, host.call('echo', 1n), 'EXITED');
  context.assert(latched.status === 4, 'the latch after a failed exiting entry');
  await host.instance.dispose();

  // browser.main_failed marks the run: failed, status 1, with its message and
  // trace, unless a drive latched an exit, which wins.
  host = await disposeHost(context, image);
  const marked = await host.instance.run(['main-failed']);
  context.assert(marked.kind === 'failed' && marked.status === 1 && decode(marked.bytes) === 'main task failed' &&
    decode(marked.trace) === 'main task trace', `main-failed result ${marked.kind}/${marked.status}`);
  await host.instance.dispose();
  host = await disposeHost(context, image);
  const latchWins = await host.instance.run(['main-failed-exit']);
  context.assert(latchWins.kind === 'exited' && latchWins.status === 7,
    `main-failed then exit gave ${latchWins.kind}/${latchWins.status}`);
  await host.instance.dispose();

  // Both Task-form calls join one batch: hops queues a call between its
  // internal hops, then exit_with ends the drive before that call's turn.
  host = await disposeHost(context, image);
  const hanging = host.task('hang');
  await until(context, () => host.snapshot().parked, 'hang did not park');
  host.hooks.kick = () => queueMicrotask(() => { host.leftCall = host.call('echo', 9n); });
  const hopping = host.task('hops');
  const joined = host.task('exit_with', [6n]);
  for (const promise of [hanging, hopping, joined]) {
    const error = await rejection(context, promise, 'EXITED');
    context.assert(error.status === 6, 'a Task-form call in the exiting drive');
  }
  const undelivered = await rejection(context, host.leftCall, 'EXITED');
  context.assert(undelivered.status === 6, 'a call the exiting drive never delivered');
  await host.instance.dispose();
}

// A titan:interval period beyond the host's timer range, on held host
// timeouts: chunked, never early, re-armed for the whole period at each tick,
// and cleared by a cancellation during a chunk.
async function longInterval(context, host, spy) {
  const period = 3e9, first = 2147483647, rest = period - first;
  const held = () => [...spy.held.values()].map(timer => timer.delay);
  const fire = () => {
    context.assert(spy.held.size === 1, `expected one held chunk, found ${held()}`);
    const [[id, timer]] = spy.held;
    spy.held.delete(id);
    timer.callback(...timer.rest);
  };
  const quiet = async () => { for (let tick = 0; tick < 5; tick++) await context.tick(); };
  const ticking = host.task('ticks', [2n, period]);
  await until(context, () => spy.held.size === 1 && host.snapshot().parked, 'a long titan:interval was not armed');
  for (let tick = 1; tick <= 2; tick++) {
    context.assert(held()[0] === first, `period ${tick} did not start with a whole first chunk: ${held()}`);
    const woken = host.probes.length;
    fire();
    await quiet();
    context.assert(held()[0] === rest && host.probes.length === woken,
      `the first chunk of period ${tick} ticked early or lost the remainder: ${held()}`);
    fire();
    if (tick === 1) await until(context, () => host.probes.length > woken, 'a whole long period never ticked');
  }
  context.assert(await ticking === 2n && spy.held.size === 0,
    'a long titan:interval did not tick twice or kept a host timeout after its listener closed');
  const controller = new AbortController();
  const cancelled = host.task('ticks', [1n, period], {signal: controller.signal});
  await until(context, () => spy.held.size === 1 && host.snapshot().parked, 'a second long titan:interval was not armed');
  fire();
  context.assert(held()[0] === rest, 'the second long titan:interval did not reach its last chunk');
  controller.abort('stop');
  await rejection(context, cancelled, 'CANCELLED');
  context.assert(spy.held.size === 0, 'a cancellation during a chunk left its host timeout');
  return [first, rest];
}

// SDK timer sources: chunked delays, cancellation and interval cleanup.
// Timeouts of at least 10^8 ms (about 28 hours) never reach the host: the
// test fires them.
async function timers(context, image) {
  const saved = {setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout,
    setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval};
  const spy = {timeouts: new Map(), delays: [], held: new Map(), intervals: new Map(), periods: []};
  globalThis.setTimeout = function (callback, delay, ...rest) {
    spy.delays.push(delay);
    if (delay >= 1e8) {
      const id = Symbol('held timeout');
      spy.held.set(id, {callback, delay, rest});
      return id;
    }
    const id = saved.setTimeout.call(globalThis, (...values) => {
      spy.timeouts.delete(id);
      callback(...values);
    }, delay, ...rest);
    spy.timeouts.set(id, delay);
    return id;
  };
  globalThis.clearTimeout = function (id) {
    if (spy.held.delete(id)) return;
    spy.timeouts.delete(id);
    saved.clearTimeout.call(globalThis, id);
  };
  globalThis.setInterval = function (callback, period, ...rest) {
    const id = saved.setInterval.call(globalThis, callback, period, ...rest);
    spy.intervals.set(id, period);
    spy.periods.push(period);
    return id;
  };
  globalThis.clearInterval = function (id) {
    spy.intervals.delete(id);
    saved.clearInterval.call(globalThis, id);
  };
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    await host.task('timer_cancel', [3e9]);
    context.assert(spy.delays.includes(2147483647) && spy.held.size === 0,
      'a long titan:timeout was not chunked or survived its cancellation');
    context.assert(await host.task('nap', [3]) === 'woke' && ![...spy.timeouts.values()].includes(3),
      'a fired titan:timeout left its host timer');
    context.assert(await host.task('ticks', [3n, 5]) === 3n && spy.periods.includes(5) && spy.intervals.size === 0,
      'titan:interval did not tick or kept its host interval');
    const chunks = await longInterval(context, host, spy);
    return {intervals: spy.periods.filter(period => period === 5).length, longIntervalChunks: chunks};
  } finally {
    Object.assign(globalThis, saved);
    await host.instance.dispose();
  }
}

// An open BrowserPin is a wake source: a job waiting only for a C callback
// keeps the drive parked instead of idle, and the callback settles it. With
// every pin closed the same wait is idle.
async function pinWakeSource(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    await host.call('pin_callbacks');
    const waiting = host.task('await_callback');
    await until(context, () => host.snapshot().parked, 'a job waiting on a pin did not park the drive');
    for (let tick = 0; tick < 5; tick++) await context.tick();
    context.assert(host.snapshot().parked && !host.probes.some(probe => probe.status === 1),
      'an open pin did not keep the waiting drive parked');
    context.assert(host.fire('finish') === 0, 'the settling callback failed');
    context.assert(await waiting === 'called back', 'the callback did not settle the waiting job');
    await host.call('unpin_callbacks');
    const orphaned = await rejection(context, host.task('await_callback'), 'TITAN');
    context.assert(decode(orphaned.bytes) === 'mini driver became idle while jobs were waiting',
      'a wait with every pin closed did not go idle');
    return 'parked until called back';
  } finally { await host.instance.dispose(); }
}

// Authored C that switches stacks inside a synchronous callback poisons the
// instance, whether the callback ran idle, from a parked drive, or nested in a
// binding of an entry. V8 refuses the suspending import before calling it, so
// the callback's caller gets the engine's SuspendError, and the bridge poisons
// once the callback is gone without its leave; later operations reject.
async function callbackSwitch(context, image) {
  const report = {};
  const fireSwitch = host => {
    try { host.fire('switch'); } catch (error) { return error?.code ?? error?.name ?? String(error); }
    return 'returned';
  };
  let host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('pin_callbacks');
    const unwound = fireSwitch(host);
    const poison = await rejection(context, host.call('echo', 1n), 'PROTOCOL');
    report.idle = [unwound, poison.message];
  } finally { await host.instance.dispose().catch(() => {}); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    await host.call('pin_callbacks');
    const waiting = host.task('await_callback');
    await until(context, () => host.snapshot().parked, 'a job waiting on a pin did not park the drive');
    const unwound = fireSwitch(host);
    const poison = await rejection(context, waiting, 'PROTOCOL');
    report.parked = [unwound, poison.message];
  } finally { await host.instance.dispose().catch(() => {}); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('pin_callbacks');
    let unwound;
    host.hooks.reenter = () => { unwound = fireSwitch(host); };
    const poison = await rejection(context, host.call('reenter'), 'PROTOCOL');
    report.nested = [unwound, poison.message];
    await rejection(context, host.call('echo', 1n), 'PROTOCOL');
  } finally { await host.instance.dispose().catch(() => {}); }
  for (const [where, [unwound, poison]] of Object.entries(report)) {
    context.assert(unwound === 'SuspendError' && poison === 'a synchronous C callback ended by an exception',
      `a switching callback (${where}) unwound with ${unwound} and poisoned with "${poison}"`);
  }
  return report;
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the mini-driver image');
  const image = await context.image(context.args[0]);
  const report = {verdict: 'PASS'};
  report.surfaceProbes = await surface(context, image);
  report.turns = await turns(context, image);
  report.pendingSink = await pendingSink(context, image);
  report.idleOutput = await idleOutput(context, image);
  report.delayedSinks = await delayedSinks(context, image);
  report.heldSinkHandoffs = await heldSinkHandoffs(context, image);
  report.notes = await queue(context, image);
  report.disposal = await disposal(context, image);
  await exits(context, image);
  report.timers = await timers(context, image);
  report.pinWakeSource = await pinWakeSource(context, image);
  report.callbackSwitch = await callbackSwitch(context, image);
  context.stdout(encode('MINI-DRIVER ' + JSON.stringify(report) + '\n'));
}
