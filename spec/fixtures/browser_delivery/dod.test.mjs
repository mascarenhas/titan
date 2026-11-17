// The browser chapter's complete application under Node, run by
//   titan-browser-run --engine node --root OUTPUT --js-test OUTPUT/dod.test.mjs
// in the output of spec/browser/build-delivery.lua. It supplies the page's two
// bindings, serves greeting.txt with the documented http-dev-server, and
// compares the program's output and trace with the chapter.
import {spawn} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {errorsViolation, outputViolation} from './expectations.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const encoder = new TextEncoder();

function text(chunks) {
  const decoder = new TextDecoder();
  return chunks.map(bytes => decoder.decode(bytes, {stream: true})).join('') + decoder.decode();
}

// The documented server on the first free port of a fixed range; it exits
// with status 1 when the port is taken.
async function serve(site) {
  for (let port = 28600; port < 28700; port++) {
    const server = spawn(join(root, 'http-dev-server'), [site, String(port)],
      {cwd: root, stdio: ['ignore', 'pipe', 'pipe']});
    let output = '';
    let diagnostics = '';
    const outcome = await new Promise(resolve => {
      server.stdout.on('data', bytes => {
        output += bytes;
        if (output.includes('\n')) resolve('ready');
      });
      server.stderr.on('data', bytes => { diagnostics += bytes; });
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
  context.assert(context.engine === 'node', 'dod.test.mjs runs under Node');
  const delivery = JSON.parse(await readFile(join(root, 'delivery.json'), 'utf8'));
  const {portable} = await import(pathToFileURL(join(root, delivery.site, 'titan-protobuf.mjs')).href);
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
    const violation = outputViolation(output, delivery.output) ?? errorsViolation(errors, delivery.errors, 'node');
    context.assert(violation === undefined, violation);
  } finally {
    await instance.dispose();
    server.kill('SIGTERM');
  }
  context.stdout(encoder.encode(`BROWSER-DELIVERY-NODE {"verdict":"PASS","profile":"${delivery.profile}"}\n`));
}
