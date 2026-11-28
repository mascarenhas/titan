// Real-browser durable storage gate of the browser filesystem and SQLite
// runtime. spec/browser/build-bridge.lua builds its two Titan images with the
// installed `titanc --target browser`: images/durable, the scenario program
// of spec/fixtures/browser_durable/durable.titan, and images/stock-novfs, a
// control program that links no filesystem runtime.
//
//   TITAN_BRIDGE_OUTPUT=OUTPUT node --test spec/browser/vfs-durable.test.mjs
//
// By default the gate runs under Node 26, which has no Origin Private File
// System, and in the headless Chromium titan-browser-run finds (TITAN_CHROME)
// over the DevTools protocol. TITAN_PLAYWRIGHT_TEST_ENGINES, a comma-separated
// list of chromium, firefox and webkit, runs it in those Playwright engines
// instead (TITAN_PLAYWRIGHT_ROOT: the npm prefix of playwright@1.64.1). Pages
// come from a local server on one origin, so a reload keeps the origin's
// storage, and every response under /csp/ carries a strict Content Security
// Policy. A missing image output or Chromium skips its cases, unless
// TITAN_REQUIRE_BROWSER_TOOLCHAIN=1 makes that a failure.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile, spawn} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {mkdtemp, readFile, realpath, rm} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {promisify} from 'node:util';
import {assetPath} from './playwright-run.mjs';
import * as host from '../fixtures/browser_durable/host.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const fixture = join(root, 'spec/fixtures/browser_durable');
const strict = process.env.TITAN_REQUIRE_BROWSER_TOOLCHAIN === '1';
const output = process.env.TITAN_BRIDGE_OUTPUT ? resolve(process.env.TITAN_BRIDGE_OUTPUT) : undefined;
if (!output && strict) throw new Error('TITAN_BRIDGE_OUTPUT must name the spec/browser/build-bridge.lua output');
const images = {skip: !output && 'TITAN_BRIDGE_OUTPUT is unset'};
const engines = (process.env.TITAN_PLAYWRIGHT_TEST_ENGINES ?? '').split(',').filter(Boolean);
const exec = promisify(execFile);
const diagnostic = text => process.stderr.write(`vfs-durable: ${text}\n`);
const image = (name, suffix) => join(output, 'images', name + suffix);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

// The policy of every response under /csp/: scripts, workers and fetches
// from the page's origin only, WebAssembly compilation, and nothing else (no
// blob: or data: URL, no eval). Images only so that the engine's own favicon
// request is no violation.
const policy = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; " +
  "connect-src 'self'; img-src 'self'";

// What durable.titan prints, its bytes in hexadecimal where they need not be
// text.
const hex = bytes => Buffer.from(bytes).toString('hex');
const note = Buffer.concat([Buffer.from('durable ação 世界\n'), Buffer.from([0, 1, 255]), Buffer.from(' end')]);
const persisted = `hello.bin ${hex(note)}\n` +
  `chunks.txt ${hex('chunk 1\nchunk 2\nchunk 3\n')}\n` +
  `note i1,t${hex('ação 世界')},b0001ff,f1.5,null;i2,t,b,f-0.25,null;` +
  `i3,t${hex('line\nbreak')},b78,f1.0000000000000001e+300,i9007199254740993;\n`;
const committed = `entry t${hex('committed')}; written written flushed flushed\n`;
const coherent = `coherence lines 2 anonymous anonymous relative ${hex('from lua\0\n')} cwd /data/sub\n`;
const placed = `place t${hex('/data/sub')}; lua.txt ${hex('from lua\0\n')}\n`;
const contended = 'contention exclusive 5,5 immediate 5,5 count 3 autocommit true\n';
// journal_mode=WAL stays delete without shared memory, becomes wal under
// exclusive locking; the other connection is then SQLITE_BUSY (5), and
// SQLITE_CANTOPEN (14) on the log-mode file until it locks exclusively too.
const logged = 'wal delete wal locked 5 shared 14 count 1\n';
const donated = `donor t${hex('in transit')};t${hex('adopted')};\n`;
const progressed = /^tasks i1125000750000 least (\d+)\n$/;
const dirty = 'TITAN_BROWSER_DISPOSED_DIRTY';

function assertRan(report, stdout) {
  const context = JSON.stringify(report);
  assert.equal(report.error, null, context);
  assert.equal(report.kind, 'returned', context);
  assert.equal(report.status, 0, context);
  assert.equal(report.stderr, '', context);
  if (stdout instanceof RegExp) assert.match(report.stdout, stdout, context);
  else assert.equal(report.stdout, stdout, context);
}

// A clean run: main returns and the disposal persists everything.
function assertClean(report, stdout) {
  assertRan(report, stdout);
  assert.equal(report.disposal, null, JSON.stringify(report));
}

function opfs(directory, options = {}) {
  return {mounts: {'/data': {backend: 'opfs', directory}}, ...options};
}

// After dispose({force: true}) the browser releases the stopped worker's
// sync access handles on its own schedule; until then the store is busy.
async function afterStop(client, url, args, options) {
  for (let attempt = 0; ; attempt++) {
    const report = await client.call('run', url, args, options);
    if (report.error?.name !== 'OPFSStoreBusyError' || attempt === 50) return report;
    diagnostic(`${args[0]}: the stopped worker's store is still busy (attempt ${attempt + 1})`);
    await delay(100);
  }
}

// Every import of each class of scripts/browser_imports.lua, as module.name.
function importClasses() {
  const classes = new Map();
  const rows = readFileSync(join(root, 'scripts/browser_imports.lua'), 'utf8')
    .matchAll(/^\s*\{\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)"/gm);
  for (const [, name, module, field] of rows) {
    if (!classes.has(name)) classes.set(name, new Set());
    classes.get(name).add(`${module}.${field}`);
  }
  return classes;
}

function wasmImports(file) {
  return WebAssembly.Module.imports(new WebAssembly.Module(readFileSync(file)))
    .map(entry => `${entry.module}.${entry.name}`);
}

test('the stock-novfs control image links no filesystem runtime; the durable image links all of it', images, () => {
  const classes = importClasses();
  const allowed = (...names) => new Set(names.flatMap(name => [...classes.get(name)]));
  for (const suffix of ['.mjs', '.wasm', '.wasm.map', '.wasm.trace']) {
    assert.ok(existsSync(image('stock-novfs', suffix)), `missing stock-novfs${suffix}`);
  }
  for (const suffix of ['.worker.mjs', '.sqlite3.wasm']) {
    assert.ok(!existsSync(image('stock-novfs', suffix)), `stock-novfs${suffix} was published`);
    assert.ok(existsSync(image('durable', suffix)), `durable${suffix} was not published`);
  }
  const module = readFileSync(image('stock-novfs', '.mjs'), 'utf8');
  const linked = readFileSync(image('durable', '.mjs'), 'utf8');
  for (const text of ['titanBrowserStorage', 'titanBrowserSql', 'worker.mjs', 'sqlite3.wasm', 'uwasi', 'OPFS']) {
    assert.ok(!module.includes(text), `stock-novfs.mjs contains ${text}`);
    assert.ok(linked.includes(text), `durable.mjs lacks ${text}`);
  }
  const entry = allowed('entry'), storage = allowed('entry', 'vfs', 'sqlite3');
  const control = wasmImports(image('stock-novfs', '.wasm'));
  assert.deepEqual(control.filter(name => !entry.has(name)), [], 'stock-novfs.wasm imports past the entry class');
  const durable = wasmImports(image('durable', '.wasm'));
  assert.deepEqual(durable.filter(name => !storage.has(name)), []);
  for (const name of ['env.titan_browser_vfs_linked', 'env.titan_browser_vfs_retire_sync',
    'env.titan_browser_sql_retire_sync']) {
    assert.ok(durable.includes(name), `durable.wasm lacks ${name}`);
    assert.ok(!control.includes(name), `stock-novfs.wasm imports ${name}`);
  }
});

// The scenarios that run wherever the image runs: Node, or a page at the
// instance host's URLs. `client.call(name, ...args)` calls host.mjs.
async function portableScenarios(t, client, urls, vfs) {
  await t.test('4. four Tasks keep running while a statement runs in the storage worker', async () => {
    const report = await client.call('run', urls.durable, ['tasks'], {vfs});
    assertClean(report, progressed);
    assert.ok(Number(progressed.exec(report.stdout)[1]) >= 3, report.stdout);
  });
  await t.test('6. SQLITE_BUSY between two connections: BEGIN EXCLUSIVE, BEGIN IMMEDIATE and WAL', async () => {
    assertClean(await client.call('run', urls.durable, ['contention'], {vfs}), contended);
    assertClean(await client.call('run', urls.durable, ['wal'], {vfs}), logged);
  });
  await t.test('7. PB-5: a donor state closes while its connection is in transit to the owner', async () => {
    assertClean(await client.call('run', urls.durable, ['donor-close'], {vfs}), donated);
  });
  await t.test('2. an open transaction makes a forced disposal report DISPOSED_DIRTY', async () => {
    const report = await client.call('run', urls.durable, ['open-transaction'], {vfs, disposal: 'force'});
    assertRan(report, 'open-transaction ok\n');
    assert.equal(report.disposal?.code, dirty, JSON.stringify(report));
  });
  await t.test('9. the stock-novfs control runs, refuses a vfs, and its stock Lua reaches no file', async () => {
    assertClean(await client.call('run', urls.control, [], {}), 'STOCK-NOVFS PASS\n');
    assert.deepEqual(await client.call('refusal', urls.control, {vfs: {}}), {name: 'TypeError', code: null,
      message: 'browser vfs needs an image that links the filesystem'});
  });
}

if (!engines.length) {
  test('Node 26: storage scenarios on a memory mount, and the control image', images, async t => {
    const urls = {durable: pathToFileURL(image('durable', '.mjs')).href,
      control: pathToFileURL(image('stock-novfs', '.mjs')).href};
    const client = {call: (name, ...args) => host[name](...args)};
    const vfs = {mounts: {'/data': {backend: 'memory'}}};
    await portableScenarios(t, client, urls, vfs);
    await t.test('5. titan.fs, stock Lua io and os, os.chdir and ATTACH ? share one tree', async () => {
      assertClean(await client.call('run', urls.durable, ['coherence'], {vfs}), coherent);
    });
    await t.test('2. a memory mount holds no durable write a forced disposal could lose', async () => {
      const report = await client.call('run', urls.durable, ['unsynchronized'], {vfs, disposal: 'force'});
      assertClean(report, 'unsynchronized ok\n');
    });
  });
}

// The gate's origin: the fixture's page under /durable/, the built images
// under /images/, and both again under /csp/ with the strict policy. Every
// request is recorded.
async function serve() {
  const mounts = {durable: await realpath(fixture), images: await realpath(join(output, 'images'))};
  const requests = [];
  const types = {'.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm'};
  const server = createServer((request, response) => {
    const path = (request.url ?? '').split('?')[0], csp = path.startsWith('/csp/');
    (async () => {
      const [, mount, ...parts] = (csp ? path.slice(4) : path).split('/');
      if (request.method !== 'GET' || !Object.hasOwn(mounts, mount)) throw new Error('unknown asset');
      const file = await assetPath(mounts[mount], parts.join('/'));
      const bytes = await readFile(file);
      const headers = {'Content-Type': types[/\.[a-z]+$/.exec(file)?.[0]] ?? 'application/octet-stream',
        'Content-Length': bytes.length, 'Cache-Control': 'no-store'};
      if (csp) headers['Content-Security-Policy'] = policy;
      response.writeHead(200, headers);
      response.end(bytes);
      requests.push({path, status: 200, policy: headers['Content-Security-Policy'] ?? null});
    })().catch(() => {
      requests.push({path, status: 404, policy: null});
      if (!response.headersSent) response.writeHead(404);
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {origin: `http://127.0.0.1:${server.address().port}`, requests, async close() {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }};
}

// The scenarios that need the Origin Private File System, in pages of one
// browser profile. `browser.page()` opens a page that `goto`, `reload`,
// `call` and `close` drive.
async function pageScenarios(t, browser) {
  const server = await serve();
  try {
    const at = prefix => ({durable: `${server.origin}${prefix}/images/durable.mjs`,
      control: `${server.origin}${prefix}/images/stock-novfs.mjs`, page: `${server.origin}${prefix}/durable/index.html`});
    const urls = at('');
    const page = await browser.page();
    await page.goto(urls.page);
    await t.test('1. titan.fs files and SQLite rows survive disposal and a page reload verbatim', async () => {
      const vfs = opfs('durable-persist');
      assertClean(await page.call('run', urls.durable, ['persist-write'], {vfs}), 'persist-write ok\n');
      await page.reload();
      assertClean(await page.call('run', urls.durable, ['persist-read'], {vfs}), persisted);
    });
    await t.test('2. a forced disposal keeps committed and flushed data, and reports lost writes', async () => {
      const vfs = opfs('durable-crash');
      assertClean(await page.call('run', urls.durable, ['commit'], {vfs, disposal: 'force'}), 'commit ok\n');
      for (const mode of ['open-transaction', 'unsynchronized']) {
        const report = await afterStop(page, urls.durable, [mode], {vfs, disposal: 'force'});
        assertRan(report, `${mode} ok\n`);
        assert.equal(report.disposal?.code, dirty, JSON.stringify(report));
      }
      await page.reload();
      assertClean(await afterStop(page, urls.durable, ['check-commit'], {vfs}), committed);
      // An ordinary disposal flushes what synchronous=OFF left unflushed.
      assertClean(await page.call('run', urls.durable, ['unsynchronized'], {vfs: opfs('durable-graceful')}),
        'unsynchronized ok\n');
    });
    await t.test('3. a second opener of a held OPFS store fails with OPFSStoreBusyError until it is released', async () => {
      const vfs = opfs('durable-busy');
      const other = await browser.page();
      try {
        await other.goto(urls.page);
        assert.deepEqual(await page.call('initialize', urls.durable, 'holder', {vfs}), {error: null, disposal: null});
        const refused = await other.call('initialize', urls.durable, 'contender', {vfs});
        assert.equal(refused.error?.name, 'OPFSStoreBusyError', JSON.stringify(refused));
        assert.equal(refused.disposal, null, JSON.stringify(refused));
        assert.equal((await page.call('dispose', 'holder')).disposal, null);
        assertClean(await other.call('run', urls.durable, ['bulk-write'], {vfs}), 'bulk-write ok\n');
      } finally {
        await other.close();
      }
    });
    await t.test('5. titan.fs, stock Lua io and os, os.chdir and ATTACH ? share one durable tree', async () => {
      const vfs = opfs('durable-coherence');
      assertClean(await page.call('run', urls.durable, ['coherence'], {vfs}), coherent);
      await page.reload();
      assertClean(await page.call('run', urls.durable, ['coherence-check'], {vfs}), placed);
    });
    await portableScenarios(t, page, urls, opfs('durable-portable'));
    await t.test('8. a page under a strict Content Security Policy runs durable OPFS SQLite', async () => {
      const csp = at('/csp'), vfs = opfs('durable-csp');
      await page.goto(csp.page);
      assertClean(await page.call('run', csp.durable, ['persist-write'], {vfs}), 'persist-write ok\n');
      await page.reload();
      assertClean(await page.call('run', csp.durable, ['persist-read'], {vfs}), persisted);
      assert.deepEqual(await page.call('violations'), []);
      for (const name of ['durable/index.html', 'durable/page.mjs', 'images/durable.mjs', 'images/durable.wasm',
        'images/durable.worker.mjs', 'images/durable.sqlite3.wasm']) {
        const served = server.requests.filter(request => request.path === `/csp/${name}`);
        assert.ok(served.length > 0 && served.every(request => request.status === 200 && request.policy === policy),
          `${name}: ${JSON.stringify(served)}`);
      }
      await page.goto(urls.page);
    });
    await t.test('10. a mount past maxHydratedBytes fails initialization with RangeError and leaks no handle', async () => {
      const directory = 'durable-hydration';
      assertClean(await page.call('run', urls.durable, ['bulk-write'], {vfs: opfs(directory)}), 'bulk-write ok\n');
      const refused = await page.call('initialize', urls.durable, 'bounded',
        {vfs: opfs(directory, {maxHydratedBytes: 100000})});
      assert.equal(refused.error?.name, 'RangeError', JSON.stringify(refused));
      assert.match(refused.error.message, /maxHydratedBytes \(100000\)/);
      assert.equal(refused.disposal, null, JSON.stringify(refused));
      assertClean(await page.call('run', urls.durable, ['bulk-check'],
        {vfs: opfs(directory, {maxHydratedBytes: 300000})}), 'bulk-check ok\n');
    });
    const control = server.requests.filter(request => request.path.includes('stock-novfs'));
    assert.deepEqual(control.filter(request => /\.(worker\.mjs|sqlite3\.wasm)$/.test(request.path)), []);
    await page.close();
  } finally {
    await server.close();
  }
}

// A DevTools protocol connection over Chromium's --remote-debugging-pipe.
class DevTools {
  constructor(child, fail) {
    this.next = 0;
    this.pending = new Map();
    this.waiters = new Set();
    this.listeners = new Set();
    this.send = text => child.stdio[3].write(text + '\0');
    let buffer = '';
    child.stdio[4].setEncoding('utf8');
    child.stdio[4].on('data', chunk => {
      buffer += chunk;
      for (let end = buffer.indexOf('\0'); end !== -1; end = buffer.indexOf('\0')) {
        const text = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (text) this.dispatch(JSON.parse(text));
      }
    });
    child.stdio[4].on('end', () => this.stop(fail('the DevTools pipe closed')));
  }
  dispatch(message) {
    if (message.id !== undefined) {
      const request = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) request?.reject(new Error(`${request.method}: ${message.error.message}`));
      else request?.resolve(message.result ?? {});
      return;
    }
    for (const waiter of this.waiters) {
      if (waiter.method === message.method && waiter.session === message.sessionId) {
        this.waiters.delete(waiter);
        waiter.resolve(message.params);
      }
    }
    for (const listener of this.listeners) listener(message);
  }
  request(method, params = {}, session) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject, method});
      this.send(JSON.stringify({id, method, params, ...(session ? {sessionId: session} : {})}));
    });
  }
  // The next `method` event of `session`, registered before its cause runs.
  event(method, session) {
    return new Promise(resolve => this.waiters.add({method, session, resolve}));
  }
  stop(error) {
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }
}

async function chromium(t) {
  const {stdout} = await exec(process.execPath, [join(root, 'titan-runtime/browser/titan-browser-run.mjs'), '--probe']);
  const {chrome} = JSON.parse(stdout);
  if (chrome.ok) return chrome;
  if (strict) assert.fail(chrome.reason);
  t.skip(chrome.reason);
  return null;
}

// Headless Chromium on a fresh profile, so its Origin Private File System
// starts empty; its pages share it.
async function launchChromium(chrome) {
  const profile = await mkdtemp(join(tmpdir(), 'titan-durable-chromium-'));
  const args = ['--headless=new', '--disable-gpu', '--disable-dev-shm-usage', '--no-first-run',
    '--no-default-browser-check', '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows', `--user-data-dir=${profile}`, '--remote-debugging-pipe'];
  // Root-only containers opt in explicitly, as for titan-browser-run.
  if (process.getuid?.() === 0 && process.env.TITAN_BROWSER_ROOT_NO_SANDBOX === '1') args.push('--no-sandbox');
  const child = spawn(chrome.path, args, {stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe']});
  let log = '';
  child.stderr.on('data', chunk => { log = (log + chunk).slice(-8192); });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const devtools = new DevTools(child, reason => new Error(`${reason}; Chromium stderr:\n${log}`));
  devtools.listeners.add(message => {
    if (message.method === 'Runtime.exceptionThrown') {
      diagnostic(`page exception: ${message.params.exceptionDetails.exception?.description}`);
    } else if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
      diagnostic(`page error: ${message.params.args.map(arg => arg.value ?? arg.description).join(' ')}`);
    }
  });
  diagnostic(`${chrome.version}; profile ${profile}`);
  return {
    async page() {
      const {targetId} = await devtools.request('Target.createTarget', {url: 'about:blank'});
      const {sessionId: session} = await devtools.request('Target.attachToTarget', {targetId, flatten: true});
      await devtools.request('Page.enable', {}, session);
      await devtools.request('Runtime.enable', {}, session);
      const load = async navigate => {
        const loaded = devtools.event('Page.loadEventFired', session);
        const {errorText} = await navigate();
        if (errorText) throw new Error(errorText);
        await loaded;
      };
      return {
        goto: url => load(() => devtools.request('Page.navigate', {url}, session)),
        reload: () => load(() => devtools.request('Page.reload', {ignoreCache: true}, session)),
        async call(name, ...args) {
          const {result, exceptionDetails} = await devtools.request('Runtime.evaluate', {
            expression: `globalThis.titanDurable.${name}(...${JSON.stringify(args)})`,
            awaitPromise: true, returnByValue: true}, session);
          if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
          return result.value;
        },
        close: () => devtools.request('Target.closeTarget', {targetId}),
      };
    },
    async close() {
      try {
        await Promise.race([devtools.request('Browser.close').catch(() => {}), delay(2000)]);
        if (child.exitCode === null && child.signalCode === null) {
          if (await Promise.race([exited.then(() => true), delay(3000).then(() => false)]) === false) {
            child.kill('SIGKILL');
            await exited;
          }
        }
      } finally {
        for (const stream of child.stdio) stream?.destroy();
        await rm(profile, {recursive: true, force: true, maxRetries: 4, retryDelay: 50});
      }
    },
  };
}

// One Playwright engine on a fresh persistent profile; its pages share one
// context, as tabs of one browser do.
async function launchPlaywright(engine) {
  const require = createRequire(join(resolve(process.env.TITAN_PLAYWRIGHT_ROOT ?? process.cwd()), 'package.json'));
  assert.equal(require('playwright/package.json').version, '1.64.1');
  const profile = await mkdtemp(join(tmpdir(), `titan-durable-${engine}-`));
  const context = await require('playwright')[engine].launchPersistentContext(profile, {headless: true,
    ...(engine === 'chromium' ? {args: ['--disable-dev-shm-usage']} : {})});
  diagnostic(`${engine} ${context.browser()?.version() ?? ''}; Playwright 1.64.1; profile ${profile}`);
  let first = context.pages()[0];
  return {
    async page() {
      const page = first ?? await context.newPage();
      first = undefined;
      page.on('pageerror', error => diagnostic(`page exception: ${error.message}`));
      page.on('console', message => { if (message.type() === 'error') diagnostic(`page error: ${message.text()}`); });
      return {
        goto: async url => { await page.goto(url, {waitUntil: 'load'}); },
        reload: async () => { await page.reload({waitUntil: 'load'}); },
        call: (name, ...args) => page.evaluate(([name, args]) => globalThis.titanDurable[name](...args), [name, args]),
        close: () => page.close(),
      };
    },
    async close() {
      try {
        await context.close();
      } finally {
        await rm(profile, {recursive: true, force: true, maxRetries: 4, retryDelay: 50});
      }
    },
  };
}

if (!engines.length) {
  test('headless Chromium over DevTools: durable OPFS storage across pages, reloads and stops', images, async t => {
    const chrome = await chromium(t);
    if (!chrome) return;
    const browser = await launchChromium(chrome);
    try {
      await pageScenarios(t, browser);
    } finally {
      await browser.close();
    }
  });
}

for (const engine of engines) {
  test(`Playwright ${engine}: durable OPFS storage across pages, reloads and stops`, images, async t => {
    const browser = await launchPlaywright(engine);
    try {
      await pageScenarios(t, browser);
    } finally {
      await browser.close();
    }
  });
}
