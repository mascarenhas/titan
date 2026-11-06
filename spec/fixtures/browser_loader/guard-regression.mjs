// Consume D's real --test gate image; no substitute C entry or scheduler.
export async function run(context) {
  context.assert(context.args.length > 0, 'pass a real entry_gate.mjs image');
  for (const path of context.args) {
    const image = await context.image(path);
    let module;
    let bridge;
    const stdout = [];
    const stderr = [];
    const instance = context.create(async options => {
      const attach = options.titanBrowserAttach;
      options.titanBrowserAttach = state => { bridge = state; attach(state); };
      module = await image.factory(options);
      return module;
    }, {
      locateFile: image.locateFile,
      stdout: bytes => { stdout.push(bytes); },
      stderr: bytes => { stderr.push(bytes); },
    });
    try {
      await instance.initialize();
      // gate.c's guarded setjmp/longjmp reaches entry_allowed through the
      // pinned toolchain's SJLJ invoke_i/dynCall_i compiled trampoline.
      context.assert(module._titan_browser_gate_guarded() === 1,
        'fresh guarded SJLJ call was mistaken for external reentry');
      const running = instance.run(['--filter=^entry_gate%.test_08_']);
      await context.tick();
      context.assert(bridge.suspensionPending, 'guard fixture did not park at its real outer wait');
      const observed = module._titan_browser_gate_observe();
      context.assert(module._titan_browser_gate_guarded() === -1,
        'raw guarded SJLJ call entered a pending suspension');
      context.assert(module._titan_browser_gate_observe() === observed,
        'guard refusal changed the admitted run');
      let rejected;
      try { await instance.run(); } catch (error) { rejected = error; }
      context.assert(rejected?.name === 'TitanBrowserError' &&
        rejected.code === 'TITAN_BROWSER_REENTRY' &&
        rejected.message === 'browser instance is suspended; reentry is not allowed',
        'wrapper did not preserve the exact reentry diagnostic');
      const result = await running;
      context.assert(result.kind === 'returned' && result.status === 0,
        'guard refusal poisoned the original wait/completion');
      context.equalBytes(result.bytes, new Uint8Array(0));
      const transcript = stdout.map(chunk =>
        Array.from(chunk, byte => String.fromCharCode(byte)).join('')).join('');
      const timing = /^\[==========\] Running Titan tests\.\n\[ RUN      \] entry_gate\.test_08_guard_window\n\[----------\] entry_gate\.test_08_guard_window: GATE item=8 outer_waits=2 host_checks=wrapper_reentry,raw_guard,observe\n\[       OK \] entry_gate\.test_08_guard_window \(([0-9]+\.[0-9]{2}) ms\)\n\[----------\] entry_gate \(([0-9]+\.[0-9]{2}) ms total\)\n\[==========\] 1 test ran\. \(([0-9]+\.[0-9]{2}) ms total\)\n\[  PASSED  \] 1 test\.\n$/.exec(transcript);
      context.assert(timing && timing[0] === transcript, 'guard image omitted or malformed wall timings');
      context.assert(timing[1] === timing[2] && Number(timing[3]) >= Number(timing[2]),
        'guard image case/owner/run timings are inconsistent');
      const expected = new TextEncoder().encode(
        '[==========] Running Titan tests.\n' +
        '[ RUN      ] entry_gate.test_08_guard_window\n' +
        '[----------] entry_gate.test_08_guard_window: GATE item=8 outer_waits=2 host_checks=wrapper_reentry,raw_guard,observe\n' +
        `[       OK ] entry_gate.test_08_guard_window (${timing[1]} ms)\n` +
        `[----------] entry_gate (${timing[2]} ms total)\n` +
        `[==========] 1 test ran. (${timing[3]} ms total)\n` +
        '[  PASSED  ] 1 test.\n');
      const actual = new Uint8Array(stdout.reduce((count, chunk) => count + chunk.length, 0));
      let offset = 0;
      for (const chunk of stdout) { actual.set(chunk, offset); offset += chunk.length; }
      context.equalBytes(actual, expected, 'guard image stdout was not byte-exact');
      context.assert(stderr.every(chunk => chunk.length === 0), 'guard image wrote unexpected stderr');
      context.stdout(actual);
      context.stdout(new TextEncoder().encode(`loader guard regression: ${path}: ready=1 pending=-1 status=0\n`));
    } finally {
      await instance.dispose();
      module = bridge = undefined;
    }
  }
}
