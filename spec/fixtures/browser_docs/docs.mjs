// The browser chapter's opening, as built by doc_check: run the documented
// image under plain Node, then serve each documented folder with the documented
// http-dev-server and compare the page in Chromium with the chapter's text.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {copyFile, mkdtemp, readdir, readFile, rm} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const workspace = resolve(process.argv[2]);
const expected = await readFile(resolve(process.argv[3]), 'utf8');
const require = createRequire(join(resolve(process.env.TITAN_PLAYWRIGHT_ROOT), 'package.json'));
assert.equal(require('playwright/package.json').version, '1.64.1');
const vite = JSON.parse(await readFile(join(resolve(process.env.TITAN_VITE_ROOT), 'node_modules/vite/package.json'), 'utf8'));
assert.equal(vite.version, '8.3.6');
const {chromium} = require('playwright');
const pages = [];
let browser;

// The image's default export works in plain Node, finding its files beside it.
async function nodeDefault() {
  const {default: create} = await import(pathToFileURL(join(workspace, 'site/hello.mjs')).href);
  const stdout = [], stderr = [];
  const instance = create({stdout: bytes => { stdout.push(...bytes); }, stderr: bytes => { stderr.push(...bytes); }});
  try {
    await instance.initialize();
    assert.equal(instance.trace.state, 'ready', instance.trace.reason);
    assert.ok(Object.isFrozen(instance.trace));
    const result = await instance.run(['Node']);
    assert.equal(result.kind, 'returned');
    assert.equal(result.status, 0);
    assert.equal(Buffer.from(stdout).toString(), expected.replace('browser', 'Node').replace(/\(returned.*\n$/, ''));
    assert.deepEqual(stderr, []);
  } finally { await instance.dispose(); }
}

// Start the documented server on the first free port of a fixed range; it
// exits with status 1 when a port is taken.
async function serve(folder) {
  for (let port = 28500; port < 28600; port++) {
    const server = spawn(join(workspace, 'http-dev-server'), [folder, String(port)],
      {cwd: workspace, stdio: ['ignore', 'pipe', 'pipe']});
    let output = '';
    const outcome = await new Promise(resolve => {
      const listen = bytes => {
        output += bytes;
        if (output.includes('\n')) resolve('ready');
      };
      server.stdout.on('data', listen);
      server.stderr.on('data', listen);
      server.once('exit', code => resolve(code));
    });
    if (outcome === 'ready') {
      assert.equal(output, `Serving ${folder} at http://127.0.0.1:${port}/\n`);
      return {server, url: `http://127.0.0.1:${port}/`};
    }
    assert.equal(outcome, 1, output);
    assert.equal(output, `http-dev-server: port ${port} is already in use\n`);
  }
  throw new Error('no free port in 28500-28599');
}

async function stop(server) {
  if (server.exitCode !== null) throw new Error(`http-dev-server exited early with ${server.exitCode}`);
  const exited = new Promise(resolve => server.once('exit', resolve));
  server.kill('SIGTERM');
  await exited;
}

// Load one served folder and return the page text and every response.
async function load(folder) {
  const {server, url} = await serve(folder);
  const page = await browser.newPage();
  const responses = [], errors = [];
  page.on('response', response => {
    responses.push({path: new URL(response.url()).pathname, status: response.status(),
      type: response.headers()['content-type'] ?? ''});
  });
  page.on('pageerror', error => { errors.push(error.message); });
  try {
    await page.goto(url);
    await page.waitForFunction(() => /\((returned|failed|exited), status -?\d+\)\n$/
      .test(document.getElementById('output')?.textContent ?? ''), null, {timeout: 30000});
    const text = await page.evaluate(() => document.getElementById('output').textContent);
    assert.deepEqual(errors, []);
    return {text, responses: responses.filter(item => item.path !== '/favicon.ico')};
  } finally {
    await page.close();
    await stop(server);
  }
}

function only(responses, pattern, label) {
  const found = responses.filter(item => pattern.test(item.path));
  assert.equal(found.length, 1, `${label}: ${JSON.stringify(responses)}`);
  assert.equal(found[0].status, 200, label);
  return found[0];
}

async function documented(label, folder, location) {
  const {text, responses} = await load(folder);
  assert.equal(text, expected, label);
  for (const item of responses) assert.equal(item.status, 200, `${label}: ${JSON.stringify(item)}`);
  assert.ok(!responses.some(item => /titan-browser|\/sdk\//.test(item.path)), `${label}: external loader`);
  const wasm = only(responses, location.wasm, `${label} Wasm`);
  assert.equal(wasm.type, 'application/wasm', label);
  only(responses, location.trace, `${label} trace table`);
  const module = only(responses, location.module, `${label} module`);
  assert.equal(module.type, 'text/javascript', label);
  pages.push({label, assets: responses.filter(item => /\.wasm|\.trace/.test(item.path)).map(item => item.path)});
}

// Vite emits the Wasm and trace table under hashed names in dist/assets.
async function viteAssets() {
  const assets = await readdir(join(workspace, 'vite-app/dist/assets'));
  assert.ok(assets.some(name => /^hello-[^.]+\.wasm$/.test(name)), `no hashed Wasm in ${assets}`);
  assert.ok(assets.some(name => /^hello\.wasm-[^.]+\.trace$|^hello-[^.]+\.wasm\.trace$/.test(name)),
    `no hashed trace table in ${assets}`);
  assert.ok(!assets.includes('hello.wasm') && !assets.includes('hello.wasm.trace'), `unhashed assets in ${assets}`);
}

// The page's requireTrace makes a deployment without the trace table fail.
async function missingTrace() {
  const folder = await mkdtemp(join(workspace, 'site-without-trace-'));
  try {
    for (const name of ['index.html', 'hello.mjs', 'hello.wasm']) await copyFile(join(workspace, 'site', name), join(folder, name));
    const {text} = await load(folder.slice(workspace.length + 1));
    assert.match(text, /\(failed, status 1\)\n$/);
    assert.ok(!text.includes('Hello,'), text);
  } finally { await rm(folder, {recursive: true, force: true}); }
}

try {
  await nodeDefault();
  browser = await chromium.launch({headless: true,
    ...(process.env.TITAN_CHROME ? {executablePath: process.env.TITAN_CHROME} : {})});
  await documented('site', 'site', {module: /^\/hello\.mjs$/, wasm: /^\/hello\.wasm$/, trace: /^\/hello\.wasm\.trace$/});
  await documented('locateFile', 'site-assets',
    {module: /^\/hello\.mjs$/, wasm: /^\/assets\/hello\.wasm$/, trace: /^\/assets\/hello\.wasm\.trace$/});
  await viteAssets();
  await documented('vite', 'vite-app/dist',
    {module: /^\/assets\/index-[^/]+\.js$/, wasm: /^\/assets\/hello-[^/]+\.wasm$/, trace: /^\/assets\/[^/]+\.trace$/});
  await missingTrace();
  process.stdout.write(JSON.stringify({verdict: 'PASS', browser: browser.version(), vite: vite.version,
    nodeDefault: true, missingTrace: 'failed', pages: pages.length, requests: pages}) + '\n');
} finally {
  await browser?.close();
}
