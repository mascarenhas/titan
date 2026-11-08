import {encode, makeHost, until} from './support.mjs';

// Expected abort70 plus marker: a checked C-stack overflow during a drive
// poisons the instance; the drive's entry, a call still queued in the
// delivery batch and every later call reject with the one saved failure.
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
    host.instance.notify(host.fn('overflow'));
    const queued = host.call('echo', 1n);
    try { await hanging; } catch (error) { saved = error; }
    context.assert(saved?.code === 'TITAN_BROWSER_ABORT' && observed?.kind === 'abort' && observed.cause === saved,
      `a checked C-stack overflow did not abort the drive: ${saved?.code}: ${saved?.message}`);
    let late, after;
    try { await queued; } catch (error) { late = error; }
    try { await host.call('echo', 2n); } catch (error) { after = error; }
    context.assert(late === saved && after === saved, 'a queued or later call did not reject the saved abort');
    await host.instance.dispose();
  } finally {
    await host.instance.dispose();
  }
  context.stdout(encode('mini-driver-abort-complete\n'));
  throw saved;
}
