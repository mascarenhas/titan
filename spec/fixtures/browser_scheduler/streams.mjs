import {decode, encode, observe, rejection, settledMarker, thrown, until} from './support.mjs';

// The async owner's published entries exercise SDK sources without os policy.
function makeHost(context, image, options = {}) {
  const host = {callables: new Map(), results: [], chunks: [], notifications: [], disposing: false};
  const sink = stream => bytes => { host.chunks.push({stream, bytes: [...bytes]}); };
  host.instance = image.create({locateFile: image.locateFile,
    stdout: sink('stdout'), stderr: sink('stderr'),
    onNotificationError(error) { host.notifications.push(error); },
    ...options,
    bindings: {
      publish(name, callable) { host.callables.set(name, callable); },
      stream_result(label, ok, value) { host.results.push({label, ok, value, disposing: host.disposing}); },
    }});
  host.fn = name => {
    const callable = host.callables.get(name);
    context.assert(callable, `the stream owner did not publish ${name}`);
    return callable;
  };
  host.call = (name, ...args) => observe(host.instance.call(host.fn(name), ...args));
  host.task = (name, ...args) => observe(host.instance.callTask(host.fn(name), args));
  host.release = () => {
    for (const callable of host.callables.values()) callable.release();
    host.callables.clear();
  };
  host.close = async () => { host.release(); await host.instance.dispose(); };
  return host;
}

function equalBytes(context, actual, expected, message) {
  context.assert(actual instanceof Uint8Array && [...actual].join() === expected.join(), message);
}

async function fifo(context, image) {
  const calls = [];
  let active = 0, maximum = 0;
  const host = makeHost(context, image, {stdout(bytes) {
    active++;
    maximum = Math.max(maximum, active);
    return new Promise((resolve, reject) => { calls.push({text: decode(bytes), resolve, reject}); })
      .finally(() => { active--; });
  }});
  try {
    await host.instance.initialize();
    const operation = host.task('stream_batch', 'stdout'), marker = settledMarker(operation);
    await until(context, () => calls.length === 1, 'the first queued write never reached its sink');
    context.assert(host.results.length === 0 && !marker.settled, 'a write completed before its sink');
    for (let index = 0; index < 3; index++) {
      context.assert(calls[index].text === `chunk${index + 1}`, 'write FIFO changed byte order');
      calls[index].resolve();
      await until(context, () => host.results.length === index + 1,
        `write ${index + 1} did not complete after its sink`);
      context.assert(host.results[index].ok && host.results[index].label === String(index + 1),
        'write completions were not FIFO');
      if (index < 2) {
        await until(context, () => calls.length === index + 2, 'the next write never reached its sink');
        context.assert(!marker.settled, 'the batch completed before all sinks settled');
      }
    }
    await operation;
    context.assert(maximum === 1 && active === 0, 'stream sinks overlapped');
    return host.results.length;
  } finally { await host.close(); }
}

async function failures(context, image) {
  const sync = new Error('synchronous Titan sink failure');
  const async = new Error('asynchronous Titan sink failure');
  let calls = 0;
  const host = makeHost(context, image, {stdout() {
    calls++;
    if (calls === 1) throw sync;
    if (calls === 3) return Promise.reject(async);
  }});
  try {
    await host.instance.initialize();
    // Each drive has only its one Task and write request as a wake source.
    for (let index = 0; index < 4; index++) {
      await host.task('stream_write', 'stdout', String(index), encode('write'));
    }
    context.assert(host.results.length === 4 && host.results[0].value === sync &&
      !host.results[0].ok && host.results[1].ok && host.results[2].value === async &&
      !host.results[2].ok && host.results[3].ok, 'Titan sink rejection leaked into a later write');
    context.assert(host.notifications.length === 0, 'a Titan write failure was also a notification failure');
    return calls;
  } finally { await host.close(); }
}

async function interleave(context, image) {
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.task('stream_interleave');
    const expected = [
      {stream: 'stdout', bytes: [65, 0, 255]},
      {stream: 'stdout', bytes: [67, 0, 255]},
      {stream: 'stdout', bytes: [90, 0, 255]},
      {stream: 'stderr', bytes: [255, 0, 69]},
    ];
    context.assert(JSON.stringify(host.chunks) === JSON.stringify(expected),
      `C/Titan stream order or binary bytes changed: ${JSON.stringify(host.chunks)}`);
    context.assert(host.results.length === 3 && host.results.every(result => result.ok),
      'interleaved Titan writes failed');
    return host.chunks.length;
  } finally { await host.close(); }
}

async function cLatch(context, image) {
  const original = new Error('C sink failure');
  const calls = [];
  const host = makeHost(context, image, {stdout(bytes) {
    calls.push(decode(bytes));
    if (calls.length === 1) return Promise.reject(original);
  }});
  try {
    await host.instance.initialize();
    const failure = await rejection(context, host.task('stream_c_latch'), 'SINK');
    context.assert(calls.join('|') === 'C-stdio|first|second', 'C failure suppressed or reordered writes');
    context.assert(host.results.length === 2 && !host.results[0].ok &&
      host.results[0].value === failure && host.results[1].ok,
      'the C failure was not delivered once to the operation and next Titan write');
    return host.results.length;
  } finally { await host.close(); }
}

async function endHooks(context, image) {
  let completed = 0;
  for (const stream of ['stdout', 'stderr']) {
    let releaseWrite, releaseEnd, enteredEnd = false, active = 0, maximum = 0;
    const host = makeHost(context, image, {
      [stream]() {
        active++;
        maximum = Math.max(maximum, active);
        return new Promise(resolve => { releaseWrite = resolve; }).finally(() => { active--; });
      },
      [stream + 'End']() {
        enteredEnd = true;
        active++;
        maximum = Math.max(maximum, active);
        return new Promise(resolve => { releaseEnd = resolve; }).finally(() => { active--; });
      },
    });
    try {
      await host.instance.initialize();
      const writing = host.task('stream_write', stream, 'write', encode('before end'));
      await until(context, () => releaseWrite !== undefined, 'the write before end never reached its sink');
      const ending = host.task('stream_end', stream, 'end'), marker = settledMarker(ending);
      await context.tick();
      context.assert(!enteredEnd && !marker.settled, 'the end hook overtook an earlier write');
      releaseWrite();
      await until(context, () => enteredEnd, 'the end hook never ran');
      context.assert(host.results.length === 1 && host.results[0].label === 'write' &&
        !marker.settled, 'the end entry completed before its hook promise');
      releaseEnd();
      await writing;
      await ending;
      context.assert(host.results.length === 2 && host.results[1].ok && maximum === 1 && active === 0,
        'the end hook overlapped a sink or failed to complete');
      completed++;
    } finally { await host.close(); }
  }
  const original = new Error('end hook rejection');
  for (const options of [{}, {stdoutEnd() { return Promise.reject(original); }}]) {
    const host = makeHost(context, image, options);
    try {
      await host.instance.initialize();
      await host.task('stream_end', 'stdout', 'end');
      const result = host.results[0];
      context.assert(host.results.length === 1 && !result.ok, 'a failing end hook completed successfully');
      if (options.stdoutEnd) context.assert(result.value === original, 'end-hook rejection lost its thrown value');
      else context.assert(result.value instanceof TypeError &&
        result.value.message === 'browser stdout has no end hook', 'missing end hook did not reject with TypeError');
      await host.task('stream_write', 'stdout', 'after-end-failure', encode('still writable'));
      context.assert(host.results[1].ok, 'the loader imposed shutdown state after a failed end request');
      completed++;
    } finally { await host.close(); }
  }
  return completed;
}

async function disposal(context, image) {
  let releaseSink, calls = 0, active = 0, maximum = 0;
  const host = makeHost(context, image, {stdout() {
    calls++;
    active++;
    maximum = Math.max(maximum, active);
    return new Promise(resolve => { releaseSink = resolve; }).finally(() => { active--; });
  }});
  try {
    await host.instance.initialize();
    const operation = host.task('stream_batch', 'stdout');
    await until(context, () => releaseSink !== undefined, 'disposal fixture did not enter its first sink');
    context.assert(host.results.length === 0, 'a held write completed before disposal');
    host.release();
    host.disposing = true;
    const disposing = observe(host.instance.dispose());
    await rejection(context, operation, 'DISPOSED');
    await disposing;
    context.assert(host.results.length === 3 && host.results.every(result => !result.ok &&
      result.disposing && result.value?.code === 'TITAN_BROWSER_DISPOSED') &&
      host.results.map(result => result.label).sort().join() === '1,2,3',
      'disposal did not deliver every queued/in-flight write failure during cleanup');
    context.assert(calls === 1 && maximum === 1, 'disposal started another sink or overlapped sinks');
    releaseSink();
    await context.tick();
    await context.tick();
    context.assert(host.results.length === 3 && active === 0 && host.notifications.length === 0,
      'the late sink settlement entered the disposed instance');
    return host.results.length;
  } finally { await host.close(); }
}

async function stdin(context, image) {
  const rejected = new Error('stdin rejected'), immediate = new Error('stdin threw');
  const rows = [
    {name: 'chunk', read: () => new Uint8Array([65, 0, 255]), bytes: [65, 0, 255]},
    {name: 'empty', read: () => Promise.resolve(new Uint8Array()), bytes: []},
    {name: 'null', read: () => null, value: null},
    {name: 'undefined', read: () => Promise.resolve(undefined), value: null},
    {name: 'rejected', read: () => Promise.reject(rejected), failure: rejected},
    {name: 'threw', read: () => { throw immediate; }, failure: immediate},
    {name: 'string', read: () => 'not bytes', value: 'not bytes'},
    {name: 'integer', read: () => 42n, value: 42n},
  ];
  let reads = 0;
  const host = makeHost(context, image, {stdin() { return rows[reads++].read(); }});
  try {
    await host.instance.initialize();
    for (const row of rows) {
      const value = await host.task('stream_read', row.name), result = host.results.at(-1);
      context.assert(result.label === row.name && host.results.length === reads,
        'stdin was not called exactly once for each read');
      if (row.failure) context.assert(!result.ok && result.value === row.failure,
        `${row.name}: stdin failure lost its thrown value`);
      else {
        context.assert(result.ok, `${row.name}: stdin rejected a runtime value`);
        if (row.bytes) equalBytes(context, value, row.bytes, `${row.name}: stdin bytes changed`);
        else context.assert(value === row.value, `${row.name}: stdin runtime type changed`);
      }
    }
    return reads;
  } finally { await host.close(); }
}

async function declarations(context, image) {
  let cases = 0;
  for (const option of ['stdin', 'stdoutEnd', 'stderrEnd']) {
    for (const value of [null, 3, {}, 'function']) {
      thrown(context, () => image.create({[option]: value}), 'TypeError');
      cases++;
    }
  }
  for (const options of [{}, {stdinKind: 'pipe', stdoutKind: 'tty', stderrKind: 'file'},
    {stdoutKind: 42, stderrKind: 'unvalidated-kind'}]) {
    const host = makeHost(context, image, options);
    try {
      await host.instance.initialize();
      for (const name of ['stdin', 'stdout', 'stderr']) {
        context.assert(await host.call('stream_kind', name) === (options[name + 'Kind'] ?? null),
          `${name}: the declared kind was validated, defaulted or changed`);
        cases++;
      }
      const missing = await host.call('stream_lookup', 'stdin');
      context.assert(typeof missing === 'string' && missing.includes('unknown') &&
        missing.includes('titan:stdin'), `stdin without an option was not unknown: ${missing}`);
      context.assert(await host.call('stream_lookup', 'stdout') === true, 'the stdout SDK source was missing');
    } finally { await host.close(); }
  }
  let host, reversed;
  host = makeHost(context, image, {stdin() {
    reversed = host.call('echo', 7n);
    return new Uint8Array([7]);
  }});
  try {
    await host.instance.initialize();
    equalBytes(context, await host.task('stream_read', 'reverse'), [7], 'reverse-entry stdin lost its chunk');
    await rejection(context, reversed, 'REENTRY');
    context.assert(host.results.length === 1 && host.results[0].ok, 'stdin reverse entry failed its outer read');
    cases++;
  } finally { await host.close(); }
  return cases;
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the scheduler image');
  const image = await context.image(context.args[0]);
  const report = {verdict: 'PASS'};
  report.fifo = await fifo(context, image);
  report.failures = await failures(context, image);
  report.interleave = await interleave(context, image);
  report.cLatch = await cLatch(context, image);
  report.endHooks = await endHooks(context, image);
  report.disposal = await disposal(context, image);
  report.stdin = await stdin(context, image);
  report.declarations = await declarations(context, image);
  context.stdout(encode('STREAMS ' + JSON.stringify(report) + '\n'));
}
