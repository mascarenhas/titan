import {closed, encode, join, reentry, rejection} from '../fixtures/browser_loader/checks.mjs';
import {fidelity, names} from '../fixtures/browser_loader/fidelity-tests.mjs';
import {lifecycle} from '../fixtures/browser_loader/lifecycle-tests.mjs';

export async function run(context) {
  const images = [], fidelityImages = [], nameImages = [];
  let selected = images;
  for (const argument of context.args) {
    if (argument === '--fidelity') selected = fidelityImages;
    else if (argument === '--names') selected = nameImages;
    else selected.push(argument);
  }
  context.assert(images.length > 0 && fidelityImages.length > 0 && nameImages.length > 0,
    'pass loader_app images, --fidelity fidelity images, and --names loader_names --test images');
  for (const path of images) {
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
      await rejection(context, instance.run(), reentry);
      const disposing = disposeWhileRunning ? instance.dispose() : undefined;
      if (disposing) {
        await rejection(context, instance.run(), closed);
      }
      const result = await running;
      context.assert(result?.kind === 'returned' && result.status === 23,
        'completion did not preserve the status after a final coroutine resume');
      context.equalBytes(result.bytes, new Uint8Array(0), 'successful completion had payload');
      context.equalBytes(join(stdout), expectedOut, 'stdout bytes changed');
      context.equalBytes(join(stderr), expectedErr, 'stderr bytes changed');
      await rejection(context, instance.run(), closed);
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
      context.equalBytes(join(stdout), encode('growth'),
        'heap-growing argument was not copied intact');
    } finally {
      await instance.dispose();
    }
    context.stdout(encode(`loader bytes: ${path}: 5 runs passed\n`));
  }
  const fidelityRuns = await fidelity(context, fidelityImages);
  const nameRuns = await names(context, nameImages);
  const lifecycleRuns = await lifecycle(context, fidelityImages);
  context.stdout(encode(`loader suite: ${images.length * 5 + fidelityRuns + nameRuns + lifecycleRuns} completed Titan runs passed\n`));
}
