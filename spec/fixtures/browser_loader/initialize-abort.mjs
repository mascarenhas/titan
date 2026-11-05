// Real generated-image initialization failure, not a replacement factory.
// The supervisor asserts exit70 AND the post-disposal marker.
export async function run(context) {
  const [path] = context.args;
  context.assert(path, 'pass a real browser image');
  const image = await context.image(path);
  const observerFailure = new Error('observer must not replace initialization abort');
  const observations = [], failures = [];
  let observed, observerCalls = 0;
  const instance = image.create({
    locateFile: () => image.locateFile('__titan_loader_missing_initialization__.wasm'),
    onEngineFailure(info) {
      observed = info;
      observerCalls++;
      for (const promise of [instance.initialize(), instance.run(), instance.call(undefined), instance.drain()]) {
        observations.push(promise.then(() => { failures.push(undefined); }, error => { failures.push(error); }));
      }
      throw observerFailure;
    },
  });
  const initializing = instance.initialize();
  context.assert(initializing === instance.initialize(), 'initialization did not share its in-flight Promise');
  let original;
  try { await initializing; } catch (error) { original = error; }
  context.assert(original?.name === 'TitanBrowserError' && original.code === 'TITAN_BROWSER_ABORT',
    'failed Wasm initialization did not preserve its original abort');
  context.assert(initializing === instance.initialize(), 'failed initialization did not keep its original Promise');
  await Promise.all(observations);
  context.assert(observerCalls === 1 && observed.kind === 'abort' && observed.cause === original &&
    failures.length === 4 && failures.every(error => error === original),
    'poison was not latched before the observer or observer failure replaced it');
  for (const promise of [instance.initialize(), instance.run(), instance.call(undefined), instance.drain()]) {
    let error;
    try { await promise; } catch (caught) { error = caught; }
    context.assert(error === original, 'application method did not reject the saved initialization poison');
  }
  let notification;
  try { instance.notify(undefined); } catch (error) { notification = error; }
  context.assert(notification === original, 'notification admission bypassed saved poison');
  const disposing = instance.dispose();
  context.assert(disposing === instance.dispose(), 'fatal disposal did not share one promise');
  await disposing;
  context.stdout(new TextEncoder().encode('dispose-complete\n'));
  throw original;
}
