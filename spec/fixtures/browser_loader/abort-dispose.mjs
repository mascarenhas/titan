// Expected-failure supervisor fixture: successful observation is exit 70 plus
// this marker, never exit 70 alone (the abort observer can report before cleanup).
export async function run(context) {
  const [path] = context.args;
  context.assert(path, 'pass a fidelity.mjs image');
  const image = await context.image(path);
  const instance = image.create({locateFile: image.locateFile, imports: context.imports});
  let caught;
  try { await instance.run(['abort_wait']); }
  catch (error) { caught = error; }
  context.assert(caught?.name === 'TitanBrowserError' && caught.code === 'TITAN_BROWSER_ABORT',
    'real suspended abort did not reject through the loader arbiter');
  for (const promise of [instance.initialize(), instance.run(), instance.call(undefined), instance.drain()]) {
    let failure;
    try { await promise; } catch (error) { failure = error; }
    context.assert(failure === caught, 'application method replaced the saved suspended abort');
  }
  let notification;
  try { instance.notify(undefined); } catch (error) { notification = error; }
  context.assert(notification === caught, 'notification admission bypassed the saved suspended abort');
  await instance.dispose();
  context.stdout(new TextEncoder().encode('dispose-complete\n'));
  throw caught;
}
