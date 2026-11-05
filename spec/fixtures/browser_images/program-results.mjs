export async function run(context) {
  context.assert(context.args.length === 2, 'default and explicit program images are required');
  const encode = value => new TextEncoder().encode(value);
  const binary = new Uint8Array([65, 0, 255, 195, 40]);
  const failure = new Uint8Array([...encode('uncaught'), 0, 255, 195, 40]);
  for (const image of context.args) {
    const { create, locateFile } = await context.image(image);
    for (const [args, kind, status] of [
      [[], 'returned', 0],
      [['minus'], 'returned', -1],
      [[new Uint8Array(), binary, new Uint8Array(2097152)], 'returned', 1],
      [['error'], 'failed', 1],
    ]) {
      const stdout = [], stderr = [];
      const instance = create({
        locateFile,
        stdout: bytes => { stdout.push(...bytes); },
        stderr: bytes => { stderr.push(...bytes); },
      });
      try {
        await instance.initialize();
        context.assert(stdout.length === 0 && stderr.length === 0, 'initialization must not execute main');
        const result = await instance.run(args);
        context.assert(result.kind === kind && result.status === status, `${image}: ${result.kind}/${result.status}`);
        context.equalBytes(new Uint8Array(stdout), encode('support-bootstrap'), `${image}: preload/bootstrap route`);
        context.equalBytes(result.bytes, kind === 'failed' ? failure : new Uint8Array(), `${image}: completion bytes`);
        if (kind === 'failed') {
          const prefix = new Uint8Array([...encode('image_main: '), ...failure, 10]);
          context.equalBytes(new Uint8Array(stderr).subarray(0, prefix.length), prefix, `${image}: uncaught binary report`);
        }
      } finally {
        await instance.dispose();
      }
    }
  }
}
