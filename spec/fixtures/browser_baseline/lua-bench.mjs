/* Host entry for the #329 Lua interpreter baseline cells.
 *
 * A `lua-main` image is a plain Emscripten factory exporting `_main`, so the
 * harness measures instantiation and one explicit interpreter invocation:
 * argv is marshalled into the current heap, `main` is called through the
 * exported `ccall`, and the interpreter's own rows are forwarded.
 */
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function now() {
  return performance.now();
}

// Emscripten's per-byte TTY hooks deliver numbers, while larger sinks hand
// over Uint8Array chunks; accept both without losing either.
function join(list) {
  const bytes = [];
  for (const item of list) {
    if (typeof item === 'number') bytes.push(item & 0xff);
    else for (const byte of item) bytes.push(byte);
  }
  return Uint8Array.from(bytes);
}

// Append an argument vector to the current heap. The view is reacquired after
// every allocation because growing memory detaches the previous buffer.
function marshal(module, args) {
  const pointers = module._malloc((args.length + 1) * 4);
  for (let index = 0; index < args.length; index++) {
    const bytes = encoder.encode(args[index]);
    const pointer = module._malloc(bytes.length + 1);
    module.HEAPU8.set(bytes, pointer);
    module.HEAPU8[pointer + bytes.length] = 0;
    new DataView(module.HEAPU8.buffer).setUint32(pointers + index * 4, pointer, true);
  }
  new DataView(module.HEAPU8.buffer).setUint32(pointers + args.length * 4, 0, true);
  return { count: args.length, pointers };
}

export async function run(context) {
  const path = context.args[0];
  context.assert(typeof path === 'string' && path.length > 0,
    'pass one lua-main image path');
  const {factory, locateFile} = await context.image(path);
  const source = decoder.decode(await context.bytes('bench.lua'));
  const chunks = [];
  const errors = [];
  const started = now();
  const module = await factory({
    locateFile,
    stdout: chunk => { chunks.push(chunk); },
    stderr: chunk => { errors.push(chunk); },
  });
  const instantiated = now();
  // A comment-first chunk looks like another option, so keep it off the
  // interpreter's option scan with a leading newline.
  const argv = marshal(module, ['lua', '-e', '\n' + source]);
  const status = module.ccall('main', 'number', ['number', 'number'],
    [argv.count, argv.pointers]);
  const finished = now();
  context.stdout(encoder.encode(
    `lua.instantiate_ms=${instantiated - started}\n` +
    `lua.run_ms=${finished - instantiated}\n` +
    `lua.total_ms=${finished - started}\n` +
    `lua.status=${status}\n` +
    `lua.stderr_bytes=${join(errors).length}\n`));
  context.stdout(join(chunks));
  context.assert(status === 0,
    `lua-main exited ${status}: ${decoder.decode(join(errors))}`);
}
