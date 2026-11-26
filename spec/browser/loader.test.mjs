import {disposed, encode, join, ran, reentry, rejection} from '../fixtures/browser_loader/checks.mjs';
import {fidelity, names} from '../fixtures/browser_loader/fidelity-tests.mjs';
import {imports} from '../fixtures/browser_loader/import-tests.mjs';
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
    const { create, locateFile } = await context.image(path);
    const expectedOut = new Uint8Array([65, 0, 255, 195, 40, 240, 159, 140, 141]);
    const expectedErr = new Uint8Array([0, 255, 195, 40]);
    async function instanceRun(disposeWhileRunning = false) {
      const stdout = [];
      const stderr = [];
      const instance = create({
        locateFile,
        imports: context.imports,
        stdout: chunk => { stdout.push(chunk); },
        stderr: chunk => { stderr.push(chunk); },
      });
      const first = instance.initialize();
      context.assert(first === instance.initialize(), 'initialize did not share its Promise');
      await first;
      const running = instance.run(['bytes', '', new Uint8Array([65, 0, 255, 195, 40]), '🌍']);
      await rejection(context, instance.run(), reentry);
      const disposing = disposeWhileRunning ? instance.dispose() : undefined;
      if (disposing) {
        await rejection(context, instance.run(), disposed);
      }
      if (disposing) await rejection(context, running, {code: disposed.code});
      else {
        const result = await running;
        context.assert(result?.kind === 'returned' && result.status === 23,
          'completion did not preserve the status after a final coroutine resume');
        context.equalBytes(result.bytes, new Uint8Array(0), 'successful completion had payload');
      }
      // An interrupted operation rejects before physical retirement. Its
      // remaining buffered output belongs to the explicit close-phase drain.
      if (disposing) await disposing;
      context.equalBytes(join(stdout), expectedOut, 'stdout bytes changed');
      context.equalBytes(join(stderr), expectedErr, 'stderr bytes changed');
      await rejection(context, instance.run(), disposing ? disposed : ran);
      await (disposing || instance.dispose());
      context.assert(instance.dispose() === instance.dispose(), 'dispose did not share its Promise');
    }

    await instanceRun();
    await instanceRun();
    await Promise.all([instanceRun(true), instanceRun()]);

    const large = new Uint8Array(20 * 1024 * 1024);
    for (let index = 0; index < large.length; ++index) large[index] = index % 251;
    const stdout = [];
    const instance = create({locateFile, imports: context.imports, stdout: chunk => { stdout.push(chunk); }});
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
  // Each module refuses a Wasm from another link before entry. The
  // optimized module (the second loader_app) is paired with the program
  // build's Wasm: the same sources and imports, another identity.
  if (images.length > 1) {
    const module = await context.image(images[1]);
    const other = await context.image(images[0]);
    const instance = module.create({locateFile: (name, prefix) => other.locateFile(name, prefix),
      imports: context.imports});
    try {
      const caught = await rejection(context, instance.initialize(), {code: 'TITAN_BROWSER_PROTOCOL'});
      context.assert(/^browser image mismatch: loader_app\.mjs belongs to image [0-9a-f]{12}, loader_app\.wasm is image [0-9a-f]{12}$/
        .test(caught.message), `wrong mismatch message: ${caught.message}`);
      await rejection(context, instance.run(), {code: 'TITAN_BROWSER_PROTOCOL', message: caught.message});
    } finally {
      await instance.dispose();
    }
    context.stdout(encode('loader identity: a Wasm from another link was refused before entry\n'));
  }
  const fidelityRuns = await fidelity(context, fidelityImages);
  const nameRuns = await names(context, nameImages);
  const lifecycleRuns = await lifecycle(context, fidelityImages);
  const importRuns = await imports(context, nameImages);
  context.stdout(encode(`loader suite: ${images.length * 5 + fidelityRuns + nameRuns + lifecycleRuns + importRuns} completed Titan runs passed\n`));
}
