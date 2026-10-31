function collected(chunks) {
  const size = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

async function rejected(context, promise, code, message) {
  let caught;
  try { await promise; } catch (error) { caught = error; }
  context.assert(caught?.name === 'TitanBrowserError', 'operation did not reject with TitanBrowserError');
  context.assert(caught.code === code, `unexpected error code: ${caught?.code}`);
  context.assert(caught.message === message, `unexpected error message: ${caught?.message}`);
}

export async function run(context) {
  context.assert(context.args.length > 0, 'pass one or more loader_app.mjs image paths');
  for (const path of context.args) {
    const {factory, locateFile} = await context.image(path);
    const expectedOut = new Uint8Array([65, 0, 255, 195, 40, 240, 159, 140, 141]);
    const expectedErr = new Uint8Array([0, 255, 195, 40]);
    async function instanceRun(disposeWhileRunning = false) {
      const stdout = [];
      const stderr = [];
      const instance = context.create(factory, {
        locateFile,
        stdout: chunk => { stdout.push(chunk); },
        stderr: chunk => { stderr.push(chunk); },
      });
      const first = instance.initialize();
      context.assert(first === instance.initialize(), 'initialize did not share its Promise');
      const running = instance.run(['bytes', '', new Uint8Array([65, 0, 255, 195, 40]), '🌍']);
      await first;
      await rejected(context, instance.run(), 'TITAN_BROWSER_REENTRY',
        'browser instance is suspended; reentry is not allowed');
      const disposing = disposeWhileRunning ? instance.dispose() : undefined;
      const result = await running;
      context.assert(result?.kind === 'returned' && result.status === 23,
        'completion did not preserve the status after a final coroutine resume');
      context.equalBytes(result.bytes, new Uint8Array(0), 'successful completion had payload');
      context.equalBytes(collected(stdout), expectedOut, 'stdout bytes changed');
      context.equalBytes(collected(stderr), expectedErr, 'stderr bytes changed');
      await rejected(context, instance.run(), 'TITAN_BROWSER_STATE',
        'browser instance has already run or is disposed');
      await (disposing || instance.dispose());
      context.assert(instance.dispose() === instance.dispose(), 'dispose did not share its Promise');
    }

    await instanceRun();
    await instanceRun();
    await Promise.all([instanceRun(true), instanceRun()]);

    const large = new Uint8Array(20 * 1024 * 1024);
    for (let index = 0; index < large.length; ++index) large[index] = index % 251;
    const stdout = [];
    const instance = context.create(factory, {locateFile, stdout: chunk => { stdout.push(chunk); }});
    try {
      const result = await instance.run(['growth', large]);
      context.assert(result.kind === 'returned' && result.status === 23,
        'heap-growing argument run failed');
      context.equalBytes(collected(stdout), new TextEncoder().encode('growth'),
        'heap-growing argument was not copied intact');
    } finally {
      await instance.dispose();
    }
    context.stdout(new TextEncoder().encode(`loader phase 1: ${path}: 5 runs passed\n`));
  }
}
