export async function run(context) {
  const { create, locateFile } = await context.image(context.args[0]);
  const encode = value => new TextEncoder().encode(value);
  for (const [mask, expected] of [
    [1, 'cannot flush browser stdout'],
    [2, 'cannot flush browser stderr'],
    [3, 'cannot flush browser stdout'],
    [7, 'original failure'],
  ]) {
    const records = {order: [], stdout: [], stderr: []};
    const instance = create({locateFile,
      stdout(bytes) { records.stdout.push(...bytes); },
      stderr(bytes) { records.stderr.push(...bytes); },
      bindings: {fixtureDrains(stream) { records.order.push(stream === 1 ? 'stdout' : 'stderr'); }}});
    try {
      const result = await instance.run([new Uint8Array([mask])]);
      context.assert(result.kind === 'failed' && result.status === 1, `flush mask ${mask}: completion`);
      context.equalBytes(result.bytes, encode(expected), `flush mask ${mask}: error precedence`);
      context.assert(records.order.length === 2 && records.order[0] === 'stdout' && records.order[1] === 'stderr',
        `flush mask ${mask}: both streams must be attempted once, stdout first: ${JSON.stringify(records)}`);
      context.equalBytes(new Uint8Array(records.stdout), encode('out-tail'), `flush mask ${mask}: stdout FILE buffer`);
      context.equalBytes(new Uint8Array(records.stderr).subarray(0, 8), encode('err-tail'), `flush mask ${mask}: stderr FILE buffer`);
    } finally {
      await instance.dispose();
    }
  }
}
