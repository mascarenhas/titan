import {closeBytes, disposed, encode, expectedBytes, join, prefixes, ran, reentry, rejection, tail} from './checks.mjs';

function contains(bytes, part) {
  outer: for (let index = 0; index + part.length <= bytes.length; ++index) {
    for (let offset = 0; offset < part.length; ++offset) {
      if (bytes[index + offset] !== part[offset]) continue outer;
    }
    return true;
  }
  return false;
}

export async function fidelity(context, paths) {
  let runs = 0;
  for (const path of paths) {
    const initialRuns = runs;
    const image = await context.image(path);
    async function execute(mode) {
      const stdout = [], stderr = [];
      const instance = image.create({locateFile: image.locateFile,
        stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
      try {
        const result = await instance.run([mode]);
        await instance.dispose();
        return {result, stdout: join(stdout), stderr: join(stderr)};
      } finally { await instance.dispose(); runs++; }
    }
    const ordinary = await execute('fidelity');
    context.assert(ordinary.result.kind === 'returned' && ordinary.result.status === 23);
    context.equalBytes(ordinary.stdout, expectedBytes('stdout'), 'stdout lost buffered binary tail or close output');
    context.equalBytes(ordinary.stderr, expectedBytes('stderr'), 'stderr lost buffered binary tail or close output');

    for (const [mode, status] of [['cycle', 23], ['status0', 0], ['status1', 1], ['status2', 2],
      ['negative', -2147483648], ['wrapped', 1]]) {
      const actual = await execute(mode);
      context.assert(actual.result.kind === 'returned' && actual.result.status === status,
        `wrong signed low32 completion after JSPI transfers: ${mode}`);
      context.equalBytes(actual.result.bytes, new Uint8Array(0));
      context.equalBytes(actual.stdout, closeBytes, 'lua_close stdout did not run exactly once');
      context.equalBytes(actual.stderr, closeBytes, 'lua_close stderr did not run exactly once');
    }
    const failed = await execute('uncaught');
    const message = new Uint8Array([102, 97, 105, 108, 117, 114, 101, 0, 255, 195, 40]);
    context.assert(failed.result.kind === 'failed' && failed.result.status === 1,
      'uncaught binary failure was converted to a JS rejection or returned status');
    context.equalBytes(failed.result.bytes, message, 'completion truncated/reencoded the binary failure');
    context.equalBytes(failed.stdout, join([prefixes.stdout, closeBytes]));
    context.equalBytes(failed.stderr.slice(0, prefixes.stderr.length), prefixes.stderr);
    context.equalBytes(failed.stderr.slice(-closeBytes.length), closeBytes);
    context.assert(contains(failed.stderr, join([encode('fidelity: '), message, encode('\n')])),
      'standalone report did not preserve the binary message');
    context.assert(contains(failed.stderr, encode('stack traceback:\n\t')),
      'uncaught error omitted the standalone trace report');

    for (const mode of ['duplicate', 'invalid']) {
      const stdout = [], stderr = [], failures = [];
      const instance = image.create({locateFile: image.locateFile,
        onEngineFailure: event => { failures.push(event); },
        stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
      try {
        const saved = await rejection(context, instance.run([mode]), {code: 'TITAN_BROWSER_PROTOCOL',
          message: 'browser entry reported a duplicate or mismatched completion'});
        context.assert(failures.length === 1 && failures[0].kind === 'protocol' && failures[0].cause === saved,
          'handled protocol failure lost its local poison observation');
        for (const promise of [instance.initialize(), instance.run(), instance.call(undefined), instance.drain()]) {
          context.assert(await rejection(context, promise, {code: saved.code}) === saved,
            'an application method replaced the saved poison');
        }
        context.equalBytes(join(stdout), new Uint8Array(), 'protocol poison attempted unsafe C cleanup');
        context.equalBytes(join(stderr), new Uint8Array(), 'protocol poison attempted unsafe C cleanup');
      } finally { await instance.dispose(); runs++; }
    }

    for (const stream of ['stdout', 'stderr']) {
      for (const behavior of ['throw', 'value', 'thenable']) {
        const cause = new Error(`${stream} ${behavior}`);
        const healthy = stream === 'stdout' ? 'stderr' : 'stdout';
        const chunks = [], admissions = [];
        let calls = 0, safe = true, controls, instance, closing = false;
        instance = image.create({locateFile: image.locateFile,
          bindings: {__titanTest(value) { controls = value; }},
          [healthy]: bytes => { chunks.push(bytes); },
          [stream]: () => {
            calls++;
            const snapshot = controls.snapshot();
            safe &&= snapshot.safe && !snapshot.owner;
            admissions.push(rejection(context, instance.drain(), closing ? disposed : reentry));
            if (behavior === 'throw') throw cause;
            if (behavior === 'value') return 0;
            return Promise.reject(cause);
          }});
        const expected = {code: 'TITAN_BROWSER_SINK', stream,
          message: `browser ${stream} sink ${behavior === 'value' ? 'must return undefined or a promise' : 'failed'}`,
          ...(behavior === 'value' ? {} : {cause})};
        try {
          await rejection(context, instance.run(['fidelity']), expected);
          await Promise.all(admissions);
          await rejection(context, instance.run(), ran);
          closing = true;
          await rejection(context, instance.dispose(), expected);
          await Promise.all(admissions);
          context.assert(safe && calls === 2, 'sink failure suppressed a later close entry or ran inside Wasm');
          context.equalBytes(join(chunks), expectedBytes(healthy), 'sink failure abandoned/duplicated Lua cleanup');
        } finally {
          closing = true;
          await instance.dispose().catch(() => {});
          controls = undefined;
          runs++;
        }
      }
    }

    const first = [];
    const causes = {stdout: new Error('first stdout'), stderr: new Error('first stderr')};
    const both = image.create({locateFile: image.locateFile,
      stdout: () => { first.push('stdout'); throw causes.stdout; },
      stderr: () => { first.push('stderr'); throw causes.stderr; }});
    try {
      const error = await rejection(context, both.run(['fidelity']), {code: 'TITAN_BROWSER_SINK'});
      context.assert(first.length === 2 && error.stream === first[0] && error.cause === causes[first[0]],
        'secondary sink failure replaced the first');
      await rejection(context, both.dispose(), {code: error.code, stream: error.stream, cause: error.cause});
      context.assert(first.length === 4, 'first failure suppressed a later entry on either stream');
    } finally { await both.dispose().catch(() => {}); runs++; }

    let entered, release, stdoutCalls = 0, stderrCalls = 0;
    const started = new Promise(resolve => { entered = resolve; });
    const pending = new Promise(resolve => { release = resolve; });
    const interruptionCause = new Error('stdout failed before stderr interruption');
    const cleanup = [];
    const interrupted = image.create({locateFile: image.locateFile,
      stdout() { if (++stdoutCalls === 1) throw interruptionCause; },
      stderr() { stderrCalls++; entered(); return pending; },
      onNotificationError(event) { cleanup.push(event); }});
    const sinkFailure = {code: 'TITAN_BROWSER_SINK', stream: 'stdout', cause: interruptionCause};
    try {
      const running = rejection(context, interrupted.run(['fidelity']), sinkFailure);
      await started;
      await rejection(context, interrupted.drain(), reentry);
      const disposal = interrupted.dispose();
      const error = await running;
      context.assert(await rejection(context, disposal, sinkFailure) === error,
        'disposal replaced the sink failure captured before its interruption');
      context.assert(cleanup.length === 1 && cleanup[0].kind === 'cleanup' &&
        cleanup[0].operation === 'run' && cleanup[0].error.code === 'TITAN_BROWSER_DISPOSED',
        'a later stream interruption replaced or duplicated the already captured sink failure');
      release();
      await context.tick();
      context.assert(stdoutCalls === 2 && stderrCalls === 1 && cleanup.length === 1,
        'interrupted stream overlapped finalizer output or a late settlement repeated cleanup');
    } finally {
      release();
      await interrupted.dispose().catch(() => {});
      runs++;
    }

    let controls;
    const copies = {stdout: [], stderr: []}, retained = {stdout: [], stderr: []};
    const mutable = image.create({locateFile: image.locateFile,
      bindings: {__titanTest(value) { controls = value; }},
      ...Object.fromEntries(['stdout', 'stderr'].map(stream => [stream, bytes => {
        context.assert(bytes.buffer !== controls.weakTargets()[1].deref(), 'sink received a borrowed Wasm view');
        context.assert(retained[stream].every(previous => previous.buffer !== bytes.buffer), 'sink chunks reused storage');
        copies[stream].push(bytes.slice());
        retained[stream].push(bytes);
        bytes.fill(90);
      }])),
    });
    try {
      const result = await mutable.run(['fidelity']);
      context.assert(result.kind === 'returned' && result.status === 23);
      for (const stream of ['stdout', 'stderr']) {
        context.assert(retained[stream].length === 1, 'internal transfers exposed an early sink delivery');
        context.equalBytes(join(copies[stream]), join([prefixes[stream], tail]));
      }
      await mutable.dispose();
      for (const stream of ['stdout', 'stderr']) {
        context.assert(retained[stream].length === 2, 'explicit close omitted finalizer output');
        context.equalBytes(join(copies[stream]), expectedBytes(stream));
        context.assert(retained[stream].every(bytes => bytes.every(byte => byte === 90)), 'retained sink chunk changed later');
      }
    } finally { await mutable.dispose(); controls = undefined; runs++; }
    context.stdout(encode(`loader fidelity: ${path}: ${runs - initialRuns} runs passed\n`));
  }
  return runs;
}

export async function names(context, paths) {
  for (const path of paths) {
    const image = await context.image(path);
    const stdout = [], stderr = [];
    const instance = image.create({locateFile: image.locateFile,
      stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
    try {
      const result = await instance.run();
      const parent = encode('loader_names.test_names');
      const child = join([parent, encode('.name'), new Uint8Array([0, 255, 195, 40])]);
      const sections = [
        join([encode('[==========] Running Titan tests.\n[ RUN      ] '), parent,
          encode('\n[ RUN      ] '), child,
          encode('\n[----------] '), child, encode(': message'), new Uint8Array([0, 255, 195, 40]),
          encode('\n[       OK ] '), child]),
        join([encode('\n[       OK ] '), parent]),
        encode('\n[----------] loader_names'),
        encode('\n[==========] 2 tests ran.'),
        encode('\n[  PASSED  ] 2 tests.\n'),
      ];
      const bytesText = bytes => Array.from(bytes, byte => String.fromCharCode(byte)).join('');
      const literal = bytes => bytesText(bytes).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      let expression = '^';
      for (let index = 0; index < sections.length; index++) {
        expression += literal(sections[index]);
        if (index < 4) expression += ' \\(([0-9]+\\.[0-9]{2}) ms' + (index >= 2 ? ' total' : '') + '\\)';
      }
      const actual = join(stdout);
      const raw = bytesText(actual);
      const timing = new RegExp(expression + '$').exec(raw);
      context.assert(timing && timing[0] === raw, 'test output omitted or malformed wall timings');
      context.assert(Number(timing[2]) >= Number(timing[1]) && timing[2] === timing[3] &&
        Number(timing[4]) >= Number(timing[3]), 'inclusive case/owner/run timings are inconsistent');
      const expected = join([
        sections[0], encode(` (${timing[1]} ms)`),
        sections[1], encode(` (${timing[2]} ms)`),
        sections[2], encode(` (${timing[3]} ms total)`),
        sections[3], encode(` (${timing[4]} ms total)`), sections[4],
      ]);
      context.assert(result.kind === 'returned' && result.status === 0, 'binary names fixture failed');
      context.equalBytes(actual, expected, 'test names/messages were truncated or decoded');
      context.equalBytes(join(stderr), new Uint8Array(0));
    } finally { await instance.dispose(); }
    context.stdout(encode(`loader names: ${path}: 2 native cases passed\n`));
  }
  return paths.length;
}
