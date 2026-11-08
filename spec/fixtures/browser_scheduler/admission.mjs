import {encode, makeHost, observe, rejection, until} from './support.mjs';

// Design 4.2's admission matrix against the mini driver. Every JavaScript
// action runs in each context a drive leaves to JavaScript: a parked wait, a
// macrotask between turn relinquishes, a microtask between internal coroutine
// hops, and a synchronous binding the drive's Titan code invoked. Then come
// the request rows, dispose() from each context, and the idle-instance rows
// of FD-M1. Rows that need a synchronous C callback wait for WI-D's bracket.

const actions = [
  ['call(owner)', host => host.instance.call(host.fn('echo'), 5n)],
  ['call(other state)', host => host.instance.call(host.fn('child_echo'), 1n)],
  ['callTask(owner)', host => host.instance.callTask(host.fn('echo'), [6n])],
  ['callTask(other state)', host => host.instance.callTask(host.fn('child_echo'), [1n])],
  ['notify(owner)', host => host.instance.notify(host.fn('note'), 'matrix')],
  ['notify(other state)', host => host.instance.notify(host.fn('child_echo'), 1n)],
  ['drain()', host => host.instance.drain()],
  ['initialize()', host => host.instance.initialize()],
  ['run()', host => host.instance.run([])],
  ['trace', host => host.instance.trace.state],
  ['_malloc/_free', host => host.controls.allocate()],
];

const elsewhere = Object.freeze({
  'call(owner)': 'value 5 in drive', 'call(other state)': 'REENTRY',
  'callTask(owner)': 'value 6 in drive', 'callTask(other state)': 'STATE',
  'notify(owner)': 'delivered in drive', 'notify(other state)': 'throws REENTRY',
  'drain()': 'REENTRY', 'initialize()': 'resolved', 'run()': 'REENTRY',
  'trace': 'value ready', '_malloc/_free': 'value true',
});
const inHost = Object.freeze({...elsewhere, 'call(owner)': 'REENTRY', 'callTask(owner)': 'REENTRY',
  'callTask(other state)': 'REENTRY'});
const expected = Object.freeze({parked: elsewhere, turn: elsewhere, hop: elsewhere, host: inHost});

// The callback rows of 4.2 and FD-M1 need titan_browser_call_sync (WI-D).
const pending = ['drive-sync-callback', 'callback-binding-entry', 'callback-caller-entry',
  'callback-notify', 'callback-dispose', 'callback-nested-call'];

const code = error => error?.code?.replace(/^TITAN_BROWSER_/, '') ?? error?.name ?? String(error);

// Which context JavaScript runs in, from the loader's own drive state.
function where(host) {
  const snapshot = host.snapshot();
  if (!snapshot.driving) return 'idle';
  if (snapshot.inHost > 0) return 'host';
  if (!snapshot.parked) return 'hop';
  return snapshot.turnScheduled ? 'turn' : 'parked';
}

// Settlement records whether the drive was still live when it happened.
function inDrive(host, promise) {
  return promise.then(value => ({value, driving: host.snapshot().driving}), error => ({error}));
}

function describe(settled) {
  if (settled.error) return code(settled.error);
  if (settled.value === undefined) return 'resolved';
  return `value ${settled.value} ${settled.driving ? 'in drive' : 'after drive'}`;
}

// Runs every action synchronously in the current context.
function attemptAll(host) {
  return actions.map(([name, action]) => {
    try {
      const result = action(host);
      return result instanceof Promise ? {name, settled: inDrive(host, result)} : {name, result};
    } catch (error) { return {name, error}; }
  });
}

async function outcomes(context, host, attempts) {
  const observed = {};
  for (const attempt of attempts) {
    if (attempt.error) {
      observed[attempt.name] = `throws ${code(attempt.error)}`;
    } else if (attempt.name === 'notify(owner)') {
      await until(context, () => host.notes.includes('matrix'), 'a notification made during the drive was lost');
      observed[attempt.name] = host.snapshot().driving ? 'delivered in drive' : 'delivered after drive';
    } else if (attempt.settled) {
      const settled = await attempt.settled;
      observed[attempt.name] = attempt.name === 'initialize()' && !settled.error ? 'resolved' : describe(settled);
    } else {
      observed[attempt.name] = `value ${attempt.result}`;
    }
  }
  return observed;
}

async function driverHost(context, image) {
  const host = makeHost(context, image);
  await host.instance.initialize();
  await host.call('register');
  return host;
}

// A drive held in a wait relinquish by a job waiting on a never-settling request.
async function parkDrive(context, host) {
  const controller = new AbortController();
  const hanging = host.task('hang', [], {signal: controller.signal});
  await until(context, () => host.snapshot().parked, 'hang did not park its drive');
  return async () => {
    controller.abort('matrix done');
    await rejection(context, hanging, 'CANCELLED');
  };
}

// Each context runs the actions once, from where JavaScript gets control.
const contexts = {
  async parked(context, host) {
    const end = await parkDrive(context, host);
    const seen = where(host);
    const observed = await outcomes(context, host, attemptAll(host));
    await end();
    return {seen, observed};
  },
  async turn(context, host) {
    const spinning = host.task('spin', [1000000n]);
    await until(context, () => host.probes.length > 0, 'spin never relinquished');
    const {seen, attempts} = await new Promise(resolve => {
      setTimeout(() => resolve({seen: where(host), attempts: attemptAll(host)}), 0);
    });
    const observed = await outcomes(context, host, attempts);
    host.flag = true;
    context.assert(await spinning > 0n, 'spin did not stop at the flag');
    return {seen, observed};
  },
  async hop(context, host) {
    const end = await parkDrive(context, host);
    let seen, attempts;
    host.hooks.kick = () => queueMicrotask(() => { seen = where(host); attempts = attemptAll(host); });
    await host.task('hops');
    host.hooks.kick = undefined;
    context.assert(attempts, 'the microtask between hops never ran');
    const observed = await outcomes(context, host, attempts);
    await end();
    return {seen, observed};
  },
  async host(context, host) {
    const end = await parkDrive(context, host);
    let seen, attempts;
    host.hooks.reenter = () => { seen = where(host); attempts = attemptAll(host); };
    await host.task('reenter');
    host.hooks.reenter = undefined;
    context.assert(attempts, 'the drive never invoked the reenter binding');
    const observed = await outcomes(context, host, attempts);
    await end();
    return {seen, observed};
  },
};

async function matrix(context, image) {
  const report = {};
  for (const [name, runContext] of Object.entries(contexts)) {
    const host = await driverHost(context, image);
    try {
      const {seen, observed} = await runContext(context, host);
      context.assert(seen === name, `the ${name} context ran ${seen}`);
      for (const [action, outcome] of Object.entries(expected[name])) {
        context.assert(observed[action] === outcome,
          `${name}: ${action} gave ${observed[action]}, expected ${outcome}`);
      }
      report[name] = observed;
    } finally { await host.instance.dispose(); }
  }
  return report;
}

// Settlements and listener events reach the owner's drive; another state's
// settlement waits in the queue for a later drain().
async function requests(context, image) {
  const host = await driverHost(context, image);
  try {
    const observed = {};
    let end = await parkDrive(context, host);
    observed['request settlement (owner)'] = describe(await inDrive(host, host.task('nap', [5])));
    observed['listener event (owner)'] = describe(await inDrive(host, host.task('ticks', [3n, 5])));
    await end();
    await host.call('child_wait', 20);
    end = await parkDrive(context, host);
    await until(context, () => host.snapshot().queue === 1, "the child's settlement never arrived");
    const parked = where(host) === 'parked' && !host.notes.includes('child settled');
    await end();
    await host.instance.drain();
    observed['request settlement (other state)'] = (parked ? 'queued in drive' : 'woke the drive') +
      (host.notes.includes('child settled') ? ', delivered by drain()' : ', lost');
    const wanted = {'request settlement (owner)': 'value woke in drive', 'listener event (owner)': 'value 3 in drive',
      'request settlement (other state)': 'queued in drive, delivered by drain()'};
    for (const [row, outcome] of Object.entries(wanted)) {
      context.assert(observed[row] === outcome, `${row} gave ${observed[row]}, expected ${outcome}`);
    }
    return observed;
  } finally { await host.instance.dispose(); }
}

// dispose() closes admission at once; queued notifications are dropped. The
// context is read first: dispose() schedules the turn that wakes the drive.
function disposeNow(host) {
  const seen = where(host);
  const before = host.probes.length;
  const disposing = observe(host.instance.dispose());
  const after = observe(host.instance.call(host.fn('echo'), 1n));
  let notified = 'dropped';
  try { host.instance.notify(host.fn('note'), 'after dispose'); }
  catch (error) { notified = `throws ${code(error)}`; }
  return {seen, before, disposing, after, notified};
}

const disposals = {
  async parked(context, host) {
    const work = host.task('hang');
    await until(context, () => host.snapshot().parked, 'hang did not park');
    return {...disposeNow(host), work: [work]};
  },
  async turn(context, host) {
    const work = host.task('spin', [1000000n]);
    await until(context, () => host.probes.length > 0, 'spin never relinquished');
    const state = await new Promise(resolve => { setTimeout(() => resolve(disposeNow(host)), 0); });
    return {...state, work: [work]};
  },
  async hop(context, host) {
    const hanging = host.task('hang');
    await until(context, () => host.snapshot().parked, 'hang did not park');
    let state;
    host.hooks.kick = () => queueMicrotask(() => { state = disposeNow(host); });
    const hopping = host.task('hops');
    await until(context, () => state, 'the microtask between hops never ran');
    return {...state, work: [hanging, hopping]};
  },
  async host(context, host) {
    const hanging = host.task('hang');
    await until(context, () => host.snapshot().parked, 'hang did not park');
    let state;
    host.hooks.reenter = () => { state = disposeNow(host); };
    const reentering = host.task('reenter');
    await until(context, () => state, 'the drive never invoked the reenter binding');
    return {...state, work: [hanging, reentering]};
  },
};

async function disposal(context, image) {
  const report = {};
  for (const [name, runContext] of Object.entries(disposals)) {
    const host = await driverHost(context, image);
    try {
      const state = await runContext(context, host);
      await rejection(context, state.after, 'DISPOSED');
      for (const work of state.work) await rejection(context, work, 'DISPOSED');
      await state.disposing;
      const statuses = host.probes.slice(state.before).map(probe => probe.status);
      report[name] = {seen: state.seen, after: 'DISPOSED', notify: state.notified, statuses};
      context.assert(state.seen === name, `dispose() from the ${name} context ran ${state.seen}`);
      context.assert(state.notified === 'dropped', `${name}: notify() after dispose() ${state.notified}`);
      context.assert(statuses[0] === 2, `${name}: the drive saw ${statuses} after dispose()`);
    } finally { await host.instance.dispose().catch(() => {}); }
  }
  return report;
}

// The idle-instance rows without a synchronous callback (FD-M1's invariant).
async function idle(context, image) {
  const host = await driverHost(context, image);
  const observed = {};
  try {
    let before = host.notes.length;
    const call = host.call('note', 'idle call');
    observed['call() entry'] = host.notes.length === before ? 'deferred' : 'synchronous';
    await call;
    before = host.notes.length;
    const task = host.task('note', ['idle task']);
    observed['callTask() entry'] = host.notes.length === before ? 'deferred' : 'synchronous';
    await task;
    host.instance.notify(host.fn('note'), 'idle note');
    const enqueued = host.snapshot().queue === 1 && !host.notes.includes('idle note');
    const drained = host.instance.drain();
    observed['drain() entry'] = host.notes.includes('idle note') ? 'synchronous' : 'deferred';
    await drained;
    observed['notify() then drain()'] = (enqueued ? 'enqueued' : 'delivered early') +
      (host.notes.includes('idle note') ? ', delivered by drain()' : ', lost');
    host.instance.notify(host.fn('note'), 'drive note');
    await host.task('echo', [1n]);
    observed['notify() then a drive'] = host.notes.includes('drive note') ? 'delivered by the drive' : 'not delivered';
    const disposing = observe(host.instance.dispose());
    const late = observe(host.instance.call(host.fn('echo'), 1n));
    observed['dispose() then call()'] = code((await inDrive(host, late)).error);
    await disposing;
    const wanted = {'call() entry': 'deferred', 'callTask() entry': 'deferred', 'drain() entry': 'deferred',
      'notify() then drain()': 'enqueued, delivered by drain()', 'notify() then a drive': 'delivered by the drive',
      'dispose() then call()': 'DISPOSED'};
    for (const [row, outcome] of Object.entries(wanted)) {
      context.assert(observed[row] === outcome, `idle ${row} gave ${observed[row]}, expected ${outcome}`);
    }
    return observed;
  } finally { await host.instance.dispose().catch(() => {}); }
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the mini-driver image');
  const image = await context.image(context.args[0]);
  const report = {verdict: 'PASS'};
  report.contexts = await matrix(context, image);
  report.requests = await requests(context, image);
  report.disposal = await disposal(context, image);
  report.idle = await idle(context, image);
  report.pending = pending;
  context.stdout(encode('ADMISSION ' + JSON.stringify(report) + '\n'));
}
