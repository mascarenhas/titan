export async function run(context) {
  context.assert(['chromium', 'firefox', 'webkit'].includes(context.engine), 'unexpected engine');
  const bytes = await context.bytes('spec/fixtures/browser_playwright/context.mjs');
  context.assert(bytes.length > 0, 'asset bytes were empty');
  await context.gc();
  context.stdout(new Uint8Array([65, 0, 255, 10]));
  context.stderr(new TextEncoder().encode('Playwright context passed\n'));
}
