import {encode, makeHost, rejection, until} from './support.mjs';

// Expected trap71 plus marker: a checked C-stack overflow during a drive
// poisons the instance; the drive's entry, a delivered Task-form call still
// waiting for its outcome, a call in the delivery batch and every later call
// reject with the one saved failure. Binaryen 133's wasm-opt --stack-check
// traps with a plain unreachable in the overflowing prologue.
export async function run(context) {
  context.assert(context.args.length === 1, 'pass the mini-driver image');
  const image = await context.image(context.args[0]);
  let observed, saved;
  const host = makeHost(context, image, {onEngineFailure(event) { observed = event; }});
  try {
    await host.instance.initialize();
    await host.call('register');
    const hanging = host.task('hang');
    await until(context, () => host.snapshot().parked, 'hang did not park its drive');
    const held = host.task('stubborn');
    await until(context, () => host.snapshot().openTasks === 1, 'the Task-form call did not start');
    host.instance.notify(host.fn('overflow'));
    const queued = host.call('echo', 1n);
    try { await hanging; } catch (error) { saved = error; }
    context.assert(saved?.code === 'TITAN_BROWSER_TRAP' && /unreachable/.test(saved.message) &&
      observed?.kind === 'trap' && observed.cause === saved,
      `a checked C-stack overflow did not trap the drive: ${saved?.code}: ${saved?.message}`);
    const pending = await rejection(context, held, 'TRAP');
    context.assert(pending === saved, 'a delivered Task-form call did not reject the saved trap');
    let late, after;
    try { await queued; } catch (error) { late = error; }
    try { await host.call('echo', 2n); } catch (error) { after = error; }
    context.assert(late === saved && after === saved, 'a queued or later call did not reject the saved trap');
    await host.instance.dispose();
  } finally {
    await host.instance.dispose();
  }
  context.stdout(encode('mini-driver-abort-complete\n'));
  throw saved;
}
