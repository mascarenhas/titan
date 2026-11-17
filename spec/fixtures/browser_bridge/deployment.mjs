// Real HTTP and Vite deployment: the served roots contain no SDK loader.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {copyFile, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {basename, extname, join, resolve, sep} from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawn} from 'node:child_process';

const image = resolve(process.argv[2]);
const viteRoot = resolve(process.env.TITAN_VITE_ROOT);
const playwrightRoot = resolve(process.env.TITAN_PLAYWRIGHT_ROOT);
const require = createRequire(join(playwrightRoot, 'package.json'));
assert.equal(require('playwright/package.json').version, '1.64.1');
const vitePackage = JSON.parse(await readFile(join(viteRoot, 'node_modules/vite/package.json'), 'utf8'));
assert.equal(vitePackage.version, '8.3.6');
const {chromium} = require('playwright');
const root = await mkdtemp(join(tmpdir(), 'titan-deployment-'));
const name = basename(image), wasmName = name.replace(/\.mjs$/, '.wasm');
const requests = [];
let browser, server;

function pageSource(relocated) {
  return `<!doctype html><meta charset="utf-8"><title>Titan deployment</title><script type="module">
import create from ${JSON.stringify('./' + name)};
const stdout = [], stderr = [], located = [];
const instance = create({stdout: bytes => { stdout.push(...bytes); }, stderr: bytes => { stderr.push(...bytes); },
${relocated ? 'locateFile(name) { located.push(name); return new URL("./assets/" + name, import.meta.url).href; },' : ''}
});
try {
  await instance.initialize();
  if (instance.trace.state !== 'ready' || !Object.isFrozen(instance.trace)) throw new Error('deployment trace is not ready');
  const trace = instance.trace;
  const result = await instance.run([]);
  await instance.dispose();
  globalThis.__titanDeployment = {kind: result.kind, status: result.status, stdout, stderr, located, trace};
} catch (error) {
  try { await instance.dispose(); } catch {}
  globalThis.__titanDeployment = {error: String(error?.stack || error)};
}
</script>`;
}

async function prepare(directory, relocated = false) {
  await mkdir(directory, {recursive: true});
  await copyFile(image, join(directory, name));
  const assets = relocated ? join(directory, 'assets') : directory;
  await mkdir(assets, {recursive: true});
  // The deployed set is the module, its Wasm and its trace table; the map only serves DevTools.
  for (const suffix of ['', '.trace']) {
    await copyFile(image.replace(/\.mjs$/, '.wasm') + suffix, join(assets, wasmName + suffix));
  }
  await writeFile(join(directory, 'index.html'), pageSource(relocated));
}

async function serve(directory) {
  const seen = [];
  server = createServer((request, response) => {
    (async () => {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const file = resolve(directory, '.' + (pathname === '/' ? '/index.html' : pathname));
      if (file !== directory && !file.startsWith(directory + sep)) throw new Error('outside served root');
      if (!(await stat(file)).isFile()) throw new Error('not a file');
      const bytes = await readFile(file);
      const type = file.endsWith('.wasm') ? 'application/wasm' : file.endsWith('.trace') ? 'application/octet-stream' :
        ['.mjs', '.js'].includes(extname(file)) ? 'text/javascript' : 'text/html';
      seen.push({pathname, status: 200});
      response.writeHead(200, {'Content-Type': type, 'Content-Length': bytes.length});
      response.end(bytes);
    })().catch(() => {
      seen.push({pathname: request.url, status: 404});
      response.writeHead(404); response.end();
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return {url: `http://127.0.0.1:${server.address().port}/`, seen};
}

async function execute(label, directory, relocated = false) {
  const {url, seen} = await serve(directory);
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => { errors.push(error.message); });
  try {
    await page.goto(url);
    await page.waitForFunction(() => globalThis.__titanDeployment !== undefined, null, {timeout: 30000});
    const result = await page.evaluate(() => globalThis.__titanDeployment);
    assert.equal(result.error, undefined, result.error);
    assert.deepEqual(errors, []);
    assert.equal(result.kind, 'returned');
    assert.equal(result.status, 7);
    assert.equal(Buffer.from(result.stdout).toString(), 'deployment-ready\n');
    assert.deepEqual(result.stderr, []);
    assert.equal(result.trace.state, 'ready');
    assert.ok(seen.some(item => item.status === 200 && /\.wasm$/.test(item.pathname)), label + ': no Wasm request');
    assert.ok(seen.some(item => item.status === 200 && /\.wasm(?:-[^/]*)?\.trace$|\.trace(?:\?|$)/.test(item.pathname)), label + ': no trace-table request');
    assert.ok(!seen.some(item => /titan-browser|\/sdk\//.test(item.pathname)), label + ': external loader dependency');
    if (relocated) assert.deepEqual(result.located.sort(), [wasmName, wasmName + '.trace'].sort());
    requests.push({label, trace: result.trace.state, assets: seen.filter(item => /\.wasm|\.trace/.test(item.pathname))});
  } finally {
    await page.close();
    await new Promise(resolve => server.close(resolve));
    server = undefined;
  }
}

async function viteBuild(directory) {
  await writeFile(join(directory, 'vite.config.mjs'), 'export default {build:{target:"esnext",assetsInlineLimit:0},base:"./"};\n');
  await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [join(viteRoot, 'node_modules/vite/bin/vite.js'), 'build', directory,
      '--config', join(directory, 'vite.config.mjs')], {stdio: ['ignore', 'pipe', 'pipe']});
    let output = '';
    child.stdout.on('data', bytes => { output += bytes; });
    child.stderr.on('data', bytes => { output += bytes; });
    child.once('error', reject);
    child.once('close', code => code === 0 ? resolve() : reject(new Error(`Vite exited ${code}: ${output}`)));
  });
  const assets = await readdir(join(directory, 'dist/assets'));
  assert.ok(assets.some(name => name.endsWith('.wasm')), 'Vite did not emit Wasm');
  assert.ok(assets.some(name => name.endsWith('.trace')), 'Vite did not emit the trace table');
  assert.ok(!assets.includes(wasmName), 'Vite did not rewrite the Wasm URL');
}

async function nodeDefault(directory) {
  const {default: create} = await import(pathToFileURL(join(directory, name)).href);
  const stdout = [], stderr = [];
  const instance = create({stdout: bytes => { stdout.push(...bytes); }, stderr: bytes => { stderr.push(...bytes); }});
  try {
    await instance.initialize();
    assert.equal(instance.trace.state, 'ready', instance.trace.reason);
    const result = await instance.run([]);
    await instance.dispose();
    assert.equal(result.kind, 'returned');
    assert.equal(result.status, 7);
    assert.equal(Buffer.from(stdout).toString(), 'deployment-ready\n');
    assert.deepEqual(stderr, []);
  } finally { await instance.dispose(); }
}

try {
  browser = await chromium.launch({headless: true,
    ...(process.env.TITAN_CHROME ? {executablePath: process.env.TITAN_CHROME} : {})});
  const plain = join(root, 'plain'), relocated = join(root, 'relocated'), bundled = join(root, 'bundled');
  await prepare(plain);
  await prepare(relocated, true);
  await prepare(bundled);
  await nodeDefault(plain);
  await execute('http', plain);
  await execute('locateFile', relocated, true);
  await viteBuild(bundled);
  await execute('vite', join(bundled, 'dist'));
  process.stdout.write(JSON.stringify({verdict: 'PASS', browser: browser.version(), vite: vitePackage.version,
    nodeDefault: true, pages: requests.length, requests}) + '\n');
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  await browser?.close();
  await rm(root, {recursive: true, force: true});
}
