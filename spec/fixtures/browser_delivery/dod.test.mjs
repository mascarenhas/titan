// The browser chapter's complete application under Node or Chromium, run by
// titan-browser-run --js-test in the output of spec/browser/build-delivery.lua.
// It supplies the page's two bindings and compares the program's output and
// trace with the chapter. Node uses the documented server for greeting.txt;
// Chromium uses the runner's loopback server.
import {errorsViolation, outputViolation} from './expectations.mjs';

const url = new URL('.', import.meta.url);
const encoder = new TextEncoder();

function text(chunks) {
  const decoder = new TextDecoder();
  return chunks.map(bytes => decoder.decode(bytes, {stream: true})).join('') + decoder.decode();
}

// The documented server on the first free port of a fixed range; it exits
// with status 1 when the port is taken.
async function serve(site) {
  if (url.protocol !== 'file:') return { origin: new URL(`${site}/`, url) };
  const {spawn} = await import('node:child_process');
  const {fileURLToPath} = await import('node:url');
  const root = fileURLToPath(url);
  const name = process.platform === 'win32' ? 'http-dev-server.exe' : 'http-dev-server';
  for (let port = 28600; port < 28700; port++) {
    const server = spawn(fileURLToPath(new URL(name, url)), [fileURLToPath(new URL(site, url)), String(port)],
      {cwd: root, stdio: ['ignore', 'pipe', 'pipe']});
    let output = '';
    let diagnostics = '';
    const outcome = await new Promise(resolve => {
      server.stdout.on('data', bytes => {
        output += bytes;
        if (output.includes('\n')) resolve('ready');
      });
      server.stderr.on('data', bytes => { diagnostics += bytes; });
      server.once('error', error => { diagnostics += error.message; resolve(null); });
      server.once('close', code => resolve(code));
    });
    if (outcome === 'ready') return {server, origin: `http://127.0.0.1:${port}/`};
    if (outcome !== 1 || !diagnostics.includes('is already in use')) {
      throw new Error(`http-dev-server failed with ${outcome}: ${output}${diagnostics}`);
    }
  }
  throw new Error('no free port in 28600-28699');
}

export async function run(context) {
  const delivery = JSON.parse(new TextDecoder().decode(await context.bytes('delivery.json')));
  const {portable} = await import(new URL(`${delivery.site}/titan-protobuf.mjs`, url));
  const image = await context.image(`${delivery.site}/app.mjs`);
  const {server, origin} = await serve(delivery.site);
  const stdout = [], stderr = [];
  let codec;
  const instance = image.create({
    locateFile: image.locateFile,
    stdout(bytes) { stdout.push(bytes.slice()); },
    stderr(bytes) { stderr.push(bytes.slice()); },
    // The page's bindings (doc/language/browser-app/index.html).
    bindings: {
      publish(description, bytes) {
        codec ??= portable(description);
        const [card] = codec.decode(bytes);
        const Card = codec.types['app.Card'];
        return codec.encode(new Card(card.title.toUpperCase(), card.visits + 1n));
      },
      visit(bump) {
        const visits = (async () => {
          await null;
          try {
            await bump.call(1n);
            await bump.call(2n);
          } finally {
            bump.release();
          }
        })();
        return {kind: 'detachable', promise: visits};
      },
    },
  });
  try {
    const result = await instance.run([new URL('greeting.txt', origin).href]);
    const output = text(stdout) + `(${result.kind}, status ${result.status})\n`;
    const errors = text(stderr);
    context.stdout(encoder.encode(output));
    context.stderr(encoder.encode(errors));
    const violation = outputViolation(output, delivery.output) ?? errorsViolation(errors, delivery.errors, context.engine);
    context.assert(violation === undefined, violation);
  } finally {
    await instance.dispose();
    server?.kill('SIGTERM');
  }
  context.stdout(encoder.encode(`BROWSER-DELIVERY-${context.engine.toUpperCase()} {"verdict":"PASS","profile":"${delivery.profile}"}\n`));
}
