const encode = value => new TextEncoder().encode(value);
const cases = new Map([
  ['entry-close', { kind: 'returned', status: -1, stdout: [67, 0, 255], stderr: [68, 0, 254] }],
  ['entry-binary', { kind: 'failed', status: 1, bytes: [69, 0, 255, 195, 40], report: [69, 0, 255, 195, 40] }],
  ['entry-tostring', { kind: 'failed', status: 1, bytes: encode('error while reporting browser failure'), stdout: encode('trace-preserved') }],
  ['entry-state-oom', { kind: 'failed', status: 1, bytes: encode('not enough memory for state'), stdout: encode('state-allocator'), stderr: [] }],
  ['entry-long-error', { kind: 'failed', status: 1, bytes: Uint8Array.from({ length: 433 }, (_, index) => index === 1 ? 0 : 113), report: Uint8Array.from({ length: 433 }, (_, index) => index === 1 ? 0 : 113) }],
  ['entry-bootstrap-oom', { kind: 'failed', status: 1, stdout: encode('bootstrap-allocator'), allocationFailure: true }],
]);

export async function run(context) {
  context.assert(context.args.length === cases.size, 'entry matrix must run all six cases');
  for (const name of context.args) {
    const expected = cases.get(name);
    context.assert(expected !== undefined, `unknown entry case ${name}`);
    const { create, locateFile } = await context.image(`${name}.mjs`);
    const stdout = [], stderr = [];
    let absentProbe;
    const instance = create({
      locateFile,
      bindings: { __absentProbe: probe => { absentProbe = probe; } },
      stdout: bytes => { stdout.push(...bytes); },
      stderr: bytes => { stderr.push(...bytes); },
    });
    try {
      const result = await instance.run();
      if (name === 'entry-close') {
        context.assert(absentProbe !== undefined, 'entry-close did not publish absentProbe');
        context.assert((await absentProbe.unadmittedInvoke()) === -1, 'absent invoke did not reject unadmitted entry');
        context.assert(absentProbe.releaseUnknown() === 3, 'absent synchronous release did not return STATE');
        const invokeResult = await absentProbe.admittedInvoke();
        context.assert(invokeResult.failed && invokeResult.status === 1 &&
          new TextDecoder().decode(invokeResult.bytes) === 'browser state is closed, closing or uninitialized',
          'absent invoke fallback did not emit state failure completion');
      }
      await instance.dispose();
      context.assert(result.kind === expected.kind && result.status === expected.status,
        `${name}: wrong completion ${result.kind}/${result.status}`);
      if (expected.bytes) context.equalBytes(result.bytes, new Uint8Array(expected.bytes), `${name}: completion bytes`);
      if (expected.kind === 'returned') context.equalBytes(result.bytes, new Uint8Array(), `${name}: success payload`);
      if (expected.stdout) context.equalBytes(new Uint8Array(stdout), new Uint8Array(expected.stdout), `${name}: stdout tail`);
      if (expected.stderr) context.equalBytes(new Uint8Array(stderr), new Uint8Array(expected.stderr), `${name}: stderr tail`);
      if (expected.report) {
        const prefix = new Uint8Array([...encode('titan: '), ...expected.report, 10]);
        context.equalBytes(new Uint8Array(stderr).subarray(0, prefix.length), prefix, `${name}: binary stderr report`);
      }
      if (expected.allocationFailure) {
        const message = new TextDecoder().decode(result.bytes);
        context.assert(message === 'not enough memory' || message === 'error in error handling', `${name}: ${message}`);
      }
    } finally {
      await instance.dispose();
    }
  }
}
