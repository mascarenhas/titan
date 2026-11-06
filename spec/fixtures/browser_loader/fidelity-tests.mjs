import {closeBytes, closed, encode, expectedBytes, join, prefixes, reentry, rejection} from './checks.mjs';

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
    const image = await context.image(path);
    async function execute(mode) {
      const stdout = [], stderr = [];
      const instance = context.create(image.factory, {locateFile: image.locateFile,
        stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
      try {
        const result = await instance.run([mode]);
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

    for (const [mode, message] of [['duplicate', 'browser entry completed more than once'],
      ['invalid', 'browser entry reported invalid completion kind 9']]) {
      const stdout = [], stderr = [];
      const instance = context.create(image.factory, {locateFile: image.locateFile,
        stdout: bytes => { stdout.push(bytes); }, stderr: bytes => { stderr.push(bytes); }});
      try {
        await rejection(context, instance.run([mode]), {code: 'TITAN_BROWSER_PROTOCOL', message});
        context.equalBytes(join(stdout), closeBytes, 'protocol failure abandoned stdout cleanup');
        context.equalBytes(join(stderr), closeBytes, 'protocol failure abandoned stderr cleanup');
        await rejection(context, instance.run(), closed);
      } finally { await instance.dispose(); runs++; }
    }

    for (const stream of ['stdout', 'stderr']) {
      for (const behavior of ['throw', 'value', 'thenable']) {
        const cause = new Error(`${stream} ${behavior}`);
        const healthy = stream === 'stdout' ? 'stderr' : 'stdout';
        const chunks = [];
        let calls = 0, admission, safe = false, bridge;
        const factory = options => {
          const attach = options.titanBrowserAttach;
          options.titanBrowserAttach = state => { bridge = state; attach(state); };
          return image.factory(options);
        };
        let instance;
        instance = context.create(factory, {locateFile: image.locateFile,
          [healthy]: bytes => { chunks.push(bytes); },
          [stream]: () => {
            calls++;
            safe = bridge.safe();
            admission = rejection(context, instance.run(), reentry);
            if (behavior === 'throw') throw cause;
            if (behavior === 'value') return 0;
            return Promise.reject(cause);
          }});
        try {
          await rejection(context, instance.run(['fidelity']), {
            code: 'TITAN_BROWSER_SINK', stream,
            message: `browser ${stream} sink ${behavior === 'throw' ? 'failed' : 'must return undefined'}`,
            ...(behavior === 'throw' ? {cause} : {}),
          });
          await admission;
          context.assert(safe && calls === 1, 'failed sink ran again or ran before logical-entry retirement');
          context.equalBytes(join(chunks), expectedBytes(healthy), 'sink failure abandoned/duplicated Lua cleanup');
          await rejection(context, instance.run(), closed);
        } finally { await instance.dispose(); runs++; }
      }
    }

    const first = [];
    const causes = {stdout: new Error('first stdout'), stderr: new Error('first stderr')};
    const both = context.create(image.factory, {locateFile: image.locateFile,
      stdout: () => { first.push('stdout'); throw causes.stdout; },
      stderr: () => { first.push('stderr'); throw causes.stderr; }});
    try {
      const error = await rejection(context, both.run(['fidelity']), {code: 'TITAN_BROWSER_SINK'});
      context.assert(first.length === 2 && error.stream === first[0] && error.cause === causes[first[0]],
        'secondary sink failure replaced the first or a failed sink was retried');
    } finally { await both.dispose(); runs++; }

    let module;
    const copies = {stdout: [], stderr: []}, retained = {stdout: [], stderr: []};
    const mutable = context.create(async options => { module = await image.factory(options); return module; }, {
      locateFile: image.locateFile,
      ...Object.fromEntries(['stdout', 'stderr'].map(stream => [stream, bytes => {
        context.assert(bytes.buffer !== module.HEAPU8.buffer, 'sink received a borrowed Wasm view');
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
        context.equalBytes(join(copies[stream]), expectedBytes(stream));
        context.assert(retained[stream].every(bytes => bytes.every(byte => byte === 90)), 'retained sink chunk changed later');
      }
    } finally { await mutable.dispose(); module = undefined; runs++; }
    context.stdout(encode(`loader fidelity: ${path}: 18 runs passed\n`));
  }
  return runs;
}

export async function names(context, paths) {
  for (const path of paths) {
    const image = await context.image(path);
    const stdout = [], stderr = [];
    const instance = context.create(image.factory, {locateFile: image.locateFile,
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
