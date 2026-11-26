/* Portable host-test entry for the #329 baseline harness.
 *
 * It never asserts a speed; it reports what one instance cost so the harness can
 * record instantiate and run times next to the same image's sizes. Every record
 * is a `name=value` line, so the harness needs no JSON decoder for browser data.
 */
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function now() {
  return performance.now();
}

export async function run(context) {
  const path = context.args[0];
  context.assert(typeof path === 'string' && path.length > 0,
    'pass one relative image path');
  const {create, locateFile} = await context.image(path);
  const chunks = [];
  const errors = [];
  const created = now();
  const instance = create({
    locateFile,
    imports: context.imports,
    stdout: chunk => { chunks.push(chunk); },
    stderr: chunk => { errors.push(chunk); },
  });
  await instance.initialize();
  const initialized = now();
  const result = await instance.run(context.args.slice(1));
  const finished = now();
  await instance.dispose();
  const join = list => {
    const size = list.reduce((sum, chunk) => sum + chunk.length, 0);
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of list) { bytes.set(chunk, offset); offset += chunk.length; }
    return bytes;
  };
  const program = join(chunks);
  const stderr = join(errors);
  context.stdout(encoder.encode(
    `browser.instantiate_ms=${initialized - created}\n` +
    `browser.run_ms=${finished - initialized}\n` +
    `browser.total_ms=${finished - created}\n` +
    `browser.kind=${result.kind}\n` +
    `browser.status=${result.status}\n` +
    `browser.payload_bytes=${result.bytes.length}\n` +
    `browser.stderr_bytes=${stderr.length}\n` +
    `browser.program_bytes=${program.length}\n`));
  context.stdout(program);
  context.assert(result.kind === 'returned' && result.status === 0,
    `baseline image failed: ${decoder.decode(stderr)}`);
}
