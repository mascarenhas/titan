export async function run(context) {
  const { factory, locateFile } = await context.image(context.args[0]);
  const stdout = [], stderr = [];
  const instance = context.create(factory, {
    locateFile,
    stdout: bytes => { stdout.push(...bytes); },
    stderr: bytes => { stderr.push(...bytes); },
  });
  try {
    const result = await instance.run();
    context.assert(result.kind === 'returned' && result.status === 0, 'stdio-only C image did not complete normally');
    context.equalBytes(new Uint8Array(stdout), new Uint8Array([65, 0, 255, 195, 40]), 'stdout bypassed byte sink');
    context.equalBytes(new Uint8Array(stderr), new Uint8Array([66, 0, 254, 226, 40]), 'stderr bypassed byte sink');
  } finally {
    await instance.dispose();
  }
}
