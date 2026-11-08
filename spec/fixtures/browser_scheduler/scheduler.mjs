import {decode, encode, observe, rejection, thrown, until} from './support.mjs';

// Harness for the async scheduler owner (spec/stdlib/titan/async/browser_tests):
// its bindings, a macrotask ticker, and the drives it disposes or that exit.
function join(chunks) {
  const bytes = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

function makeHost(context, image) {
  const host = {callables: new Map(), notes: [], stdout: [], stderr: [], notificationErrors: [],
    ticks: 0, disposing: undefined};
  // A self-renewing MessageChannel ticker: it runs only while Wasm has given
  // the event loop back, so it counts the macrotasks between turns.
  const channel = new MessageChannel();
  let ticking = true;
  channel.port1.onmessage = () => {
    host.ticks++;
    if (ticking) channel.port2.postMessage(null);
  };
  channel.port2.postMessage(null);
  host.bindings = {
    publish(name, callable) { host.callables.set(name, callable); },
    note(text) { host.notes.push(text); },
    macrotasks() { return BigInt(host.ticks); },
    echo_integer(value) { return value; },
    delay(ms, value) {
      return {kind: 'detachable', promise: new Promise(resolve => { setTimeout(() => resolve(value), Number(ms)); })};
    },
    never() { return {kind: 'detachable', promise: new Promise(() => {})}; },
    ticks(count) {
      return {kind: 'listener', subscribe(emit) {
        let emitted = 0;
        const timer = setInterval(() => {
          emitted++;
          emit(BigInt(emitted));
          if (emitted >= Number(count)) clearInterval(timer);
        }, 1);
        return () => clearInterval(timer);
      }};
    },
    dispose_now() { host.disposing = observe(host.instance.dispose()); },
  };
  host.instance = image.create({locateFile: image.locateFile, bindings: host.bindings,
    stdout(bytes) { host.stdout.push(bytes.slice()); },
    stderr(bytes) { host.stderr.push(bytes.slice()); },
    onNotificationError(event) { host.notificationErrors.push(event); }});
  host.fn = name => {
    const callable = host.callables.get(name);
    context.assert(callable, `the scheduler owner did not publish ${name}`);
    return callable;
  };
  host.call = (name, ...args) => observe(host.instance.call(host.fn(name), ...args));
  host.task = (name, args = [], options = {}) => observe(host.instance.callTask(host.fn(name), args, options));
  host.close = async () => {
    ticking = false;
    channel.port1.onmessage = null;
    channel.port1.close();
    await host.instance.dispose().catch(() => {});
  };
  return host;
}

function notes(host) { return host.notes.join('|'); }

// The Titan cases: scheduler gate items 1-5, 7, 8 and ownership.
async function gate(context, image) {
  const host = makeHost(context, image);
  try {
    const result = await host.instance.run([]);
    const out = decode(join(host.stdout)), err = decode(join(host.stderr));
    context.assert(result.kind === 'returned' && result.status === 0, `scheduler gate failed:\n${out}${err}`);
    const passed = out.match(/\[  PASSED  \] (\d+) tests?\./);
    context.assert(passed && Number(passed[1]) === 8, `the gate did not pass its eight cases:\n${out}`);
    context.assert(err.includes('uncaught error in async Task: ordinary Task failure'),
      `an ordinary Task failure was not reported on stderr:\n${err}`);
    context.assert(host.notificationErrors.length === 0, 'a gate case reported a notification error');
    return Number(passed[1]);
  } finally { await host.close(); }
}

// Task-form calls on idle and driving instances.
async function entries(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    context.assert(await host.task('echo', [5n]) === 5n, 'an idle Task-form call');
    context.assert(await host.fn('echo').callTask([6n]) === 6n, 'a wrapper Task-form call');
    const failed = await rejection(context, host.task('fail', ['boom']), 'TITAN');
    context.assert(decode(failed.bytes) === 'boom' && failed.status === 1 && failed.trace.length > 0,
      'a failed Task-form call lost its bytes, status or trace');
    context.assert(await host.task('nap', [10n]) === 'woke', 'a Task-form call waiting on a host request');
    const early = {why: 'pre-aborted'};
    const pre = new AbortController();
    pre.abort(early);
    const refused = await rejection(context, host.task('hold', [], {signal: pre.signal}), 'CANCELLED');
    context.assert(refused.reason === early && !host.notes.includes('holding'), 'a pre-aborted Task-form call started');
    const controller = new AbortController();
    const holding = host.task('hold', [], {signal: controller.signal});
    await until(context, () => host.notes.includes('holding'), 'hold did not start');
    context.assert(await host.call('echo', 7n) === 7n, 'a call queued during the drive');
    context.assert(await host.task('echo', [8n]) === 8n, 'a Task-form call joining the drive');
    const reason = {why: 'aborted while holding'};
    controller.abort(reason);
    const cancelled = await rejection(context, holding, 'CANCELLED');
    context.assert(cancelled.reason === reason, 'AbortSignal cancellation lost its reason');
    return host.notes.length;
  } finally { await host.close(); }
}

// Disposal while relinquished, mid-turn, with an orphaned cleanup wait, and
// with no drive at all.
async function disposal(context, image) {
  const summary = {};
  let host = makeHost(context, image);
  try {
    await host.instance.initialize();
    const parked = host.call('park', 200n);
    await until(context, () => host.notes.includes('park parked'), 'park did not park');
    const queuedCall = host.call('echo', 1n);
    const queuedTask = host.task('hold');
    const started = Date.now();
    const disposing = host.instance.dispose();
    await rejection(context, queuedCall, 'DISPOSED');
    await rejection(context, queuedTask, 'DISPOSED');
    await rejection(context, parked, 'DISPOSED');
    await disposing;
    summary.parkedMs = Date.now() - started;
    context.assert(notes(host) === 'park parked|park cleanup instance disposed|' +
      'park new work: browser state is closing|park cleanup got 200', `park notes: ${notes(host)}`);
    context.assert(summary.parkedMs >= 150, `disposal did not wait for the cleanup's host request: ${summary.parkedMs} ms`);
  } finally { await host.close(); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await rejection(context, host.call('dispose_mid_turn'), 'DISPOSED');
    context.assert(host.disposing, 'dispose_now did not run');
    await host.disposing;
    context.assert(notes(host) === 'peer parked|after dispose request|peer cleanup instance disposed',
      `mid-turn notes: ${notes(host)}`);
  } finally { await host.close(); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    const orphaned = host.call('orphan');
    await until(context, () => host.notes.includes('orphan parked'), 'orphan did not park');
    const disposing = host.instance.dispose();
    await rejection(context, orphaned, 'DISPOSED');
    await disposing;
    context.assert(notes(host) === 'orphan parked|orphan cleanup', `orphan notes: ${notes(host)}`);
  } finally { await host.close(); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('park_idle', 50n);
    await host.instance.dispose();
    context.assert(notes(host) === 'idle cleanup instance disposed|' +
      'idle new work: browser state is closing|idle cleanup got 50', `shutdown notes: ${notes(host)}`);
  } finally { await host.close(); }
  return summary;
}

// The exit latch with a running Runtime.
async function exits(context, image) {
  let host = makeHost(context, image);
  try {
    await host.instance.initialize();
    const exiting = host.call('exit_drive', 3n);
    await until(context, () => host.notes.includes('exit peer parked'), 'exit_drive did not park its peer');
    const joined = host.task('hold');
    for (const promise of [exiting, joined]) {
      const error = await rejection(context, promise, 'EXITED');
      context.assert(error.status === 3, 'an exited rejection lost its status');
    }
    context.assert(host.notes.includes('exit peer cleanup program exit'), `exit notes: ${notes(host)}`);
    for (const promise of [host.call('echo', 1n), host.task('echo', [1n]), observe(host.instance.drain()),
        observe(host.instance.run([]))]) {
      const error = await rejection(context, promise, 'EXITED');
      context.assert(error.status === 3, 'a later entry lost the exit status');
    }
    thrown(context, () => host.instance.notify(host.fn('echo'), 1n), 'EXITED');
  } finally { await host.close(); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    const holding = host.task('hold');
    await until(context, () => host.notes.includes('holding'), 'hold did not start');
    const exiter = host.task('exit_task', [4n]);
    for (const promise of [holding, exiter]) {
      const error = await rejection(context, promise, 'EXITED');
      context.assert(error.status === 4, 'a Task-form exit lost its status');
    }
  } finally { await host.close(); }

  host = makeHost(context, image);
  try {
    await host.instance.initialize();
    const failed = await rejection(context, host.call('exit_and_fail'), 'TITAN');
    context.assert(decode(failed.bytes) === 'exit and fail', 'a failure in an exiting drive was not reported');
    const latched = await rejection(context, host.call('echo', 1n), 'EXITED');
    context.assert(latched.status === 5, 'the exit latch after a failed drive');
  } finally { await host.close(); }
}

// A C-created child state is refused during the owner's drive.
async function ownership(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('make_child');
    context.assert(await host.call('child_echo', 3n) === 3n, 'an idle call into the child state');
    context.assert(await host.task('echo', [1n]) === 1n, "the child replaced the owner's driver");
    const napping = host.task('nap', [40n]);
    await until(context, () => host.notes.includes('napping'), 'nap did not start');
    await rejection(context, host.call('child_echo', 1n), 'REENTRY');
    thrown(context, () => host.instance.notify(host.fn('child_echo'), 1n), 'REENTRY');
    context.assert(await napping === 'woke', 'the drive did not progress after refusing the child');
    context.assert(await host.call('child_echo', 2n) === 2n, 'a child call after the drive');
  } finally { await host.close(); }
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the scheduler image');
  const image = await context.image(context.args[0]);
  const report = {verdict: 'PASS'};
  report.gate = await gate(context, image);
  report.entries = await entries(context, image);
  report.disposal = await disposal(context, image);
  await exits(context, image);
  await ownership(context, image);
  context.stdout(encode('SCHEDULER ' + JSON.stringify(report) + '\n'));
}
