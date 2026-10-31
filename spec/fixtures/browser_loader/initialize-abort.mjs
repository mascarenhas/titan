// Real generated-factory failure, not a replacement/fake factory. E's parent
// asserts exit 70 AND the marker after terminal-admission/disposal assertions.
export async function run(context) {
  const [path] = context.args;
  context.assert(path, 'pass a real browser image');
  const image = await context.image(path);
  const instance = context.create(image.factory, {
    locateFile: () => image.locateFile('__titan_loader_missing_initialization__.wasm'),
  });
  const initializing = instance.initialize();
  context.assert(initializing === instance.initialize(), 'initialization did not share its in-flight Promise');
  let original;
  try { await initializing; } catch (error) { original = error; }
  context.assert(original?.name === 'TitanBrowserError' && original.code === 'TITAN_BROWSER_ABORT',
    'failed Wasm initialization did not preserve its original abort');
  context.assert(initializing === instance.initialize(), 'failed initialization did not keep its original Promise');
  let state;
  try { await instance.run(); } catch (error) { state = error; }
  context.assert(state?.name === 'TitanBrowserError' && state.code === 'TITAN_BROWSER_STATE' &&
    state.message === 'browser instance has already run or is disposed',
    'run admitted an instance whose initialization already failed');
  await instance.dispose();
  context.stdout(new TextEncoder().encode('dispose-complete\n'));
  throw original;
}
