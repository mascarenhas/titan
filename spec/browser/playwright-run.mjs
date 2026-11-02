// Test infrastructure: reuse the production page/loader host on managed engines.
import {createServer} from 'node:http';
import {readFile, realpath, stat} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const playwrightVersion = '1.56.1';
const diagnostic = text => process.stderr.write(`titan-playwright-run: ${text}\n`);
const usage = `usage: node spec/browser/playwright-run.mjs --engine chromium|firefox|webkit
       [--root DIR] [--sdk DIR] [--timeout MS] [--grace MS]
       [--allow-degraded-trace] [--image] FILE [-- ARG...]

FILE is a portable run(context) test unless --image selects a Titan image.
Set TITAN_PLAYWRIGHT_ROOT to an npm prefix containing playwright@${playwrightVersion}.
Set PLAYWRIGHT_BROWSERS_PATH to a session-owned managed-browser directory.
`;

export function parseOptions(argv) {
  const options = {engine: undefined, root: undefined, sdk: undefined,
    timeout: 300000, grace: 1500, args: [], jsTest: true, allowDegradedTrace: false};
  const values = new Set(['engine', 'root', 'sdk', 'timeout', 'grace']);
  for (let index = 0; index < argv.length; ++index) {
    const arg = argv[index];
    if (arg === '--') { options.args = argv.slice(index + 1); break; }
    if (arg === '--help' || arg === '-h') { options.help = true; continue; }
    if (arg === '--image') { options.jsTest = false; continue; }
    if (arg === '--allow-degraded-trace') { options.allowDegradedTrace = true; continue; }
    if (arg.startsWith('--') && values.has(arg.slice(2))) {
      if (++index === argv.length) throw new Error(`${arg} requires a value`);
      options[arg.slice(2)] = argv[index];
    } else if (arg.startsWith('-')) throw new Error(`unknown option ${arg}`);
    else if (options.file) throw new Error('only one FILE is allowed; pass arguments after --');
    else options.file = arg;
  }
  if (options.help) return options;
  if (!['chromium', 'firefox', 'webkit'].includes(options.engine)) {
    throw new Error('--engine must be chromium, firefox or webkit');
  }
  for (const key of ['timeout', 'grace']) {
    const value = String(options[key]);
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) ||
        Number(value) > 2147483647 || (key === 'timeout' && Number(value) === 0)) {
      throw new Error(`--${key} must be ${key === 'timeout' ? 'a positive' : 'a nonnegative'} integer <= 2147483647`);
    }
    options[key] = Number(value);
  }
  if (!options.file) throw new Error('FILE is required');
  return options;
}

export function within(root, file) {
  const rel = relative(root, file);
  return rel !== '..' && !rel.startsWith('..' + sep) && !isAbsolute(rel);
}

// Keep the existing runner's completion/status arbitration, including its grace
// period for late failures. The shared page supplies original trap identity.
export class RunMonitor {
  constructor(options) {
    this.options = options;
    this.done = new Promise(resolve => { this.finish = resolve; });
    this.deadline = setTimeout(() => this.fail('timeout', `timed out after ${options.timeout} ms`), options.timeout);
  }
  fail(category, reason, knownTrap = false) {
    if (this.stopped) return;
    if (!this.failure || (category === 'trap' && knownTrap && this.failure.category === 'abort')) {
      this.failure = {category, reason, late: !!this.completion};
    }
    this.finish();
  }
  control(message) {
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      return this.fail('harness', 'malformed control message');
    }
    if (message.type === 'abort') {
      if (typeof message.reason !== 'string') return this.fail('harness', 'malformed abort observation');
      this.abortReason ??= message.reason;
      if (this.completion) this.fail('abort', this.abortReason);
    } else if (message.type === 'failure') {
      if (!['abort', 'trap', 'unhandled', 'sink', 'harness'].includes(message.category) || typeof message.reason !== 'string') {
        return this.fail('harness', 'malformed failure control');
      }
      const originalTrap = message.category === 'trap' && message.knownTrap === true;
      if (this.abortReason !== undefined && !this.completion && !originalTrap &&
          ['abort', 'trap', 'harness'].includes(message.category)) {
        if (message.terminal === true) this.fail('abort', this.abortReason);
      } else this.fail(message.category, message.reason, originalTrap);
    } else if (message.type === 'complete') {
      if (this.completion) return this.fail('harness', 'duplicate completion');
      if (!['returned', 'failed', 'host-test'].includes(message.kind) ||
          !Number.isInteger(message.status) || message.status < -2147483648 || message.status > 2147483647 ||
          (message.kind === 'host-test' && ![0, 1].includes(message.status))) {
        return this.fail('harness', 'malformed completion control');
      }
      if (this.abortReason !== undefined) return this.fail('abort', this.abortReason);
      this.completion = message;
      clearTimeout(this.deadline);
      this.grace = setTimeout(() => this.finish(), this.options.grace);
    } else this.fail('harness', 'unknown control message');
  }
  stop() {
    this.stopped = true;
    clearTimeout(this.deadline);
    clearTimeout(this.grace);
  }
  result() {
    if (this.failure) {
      const {category, reason, late} = this.failure;
      diagnostic(`${late ? 'late ' : ''}${category} failure: ${reason}`);
      if (late && ['abort', 'trap'].includes(category)) return 73;
      return {abort: 70, trap: 71, timeout: 72, unhandled: 74, harness: 75, sink: 76}[category];
    }
    if (!this.completion) { diagnostic('harness failure: engine ended without completion'); return 75; }
    if (this.completion.reason) diagnostic(`JS test failed: ${this.completion.reason}`);
    return this.completion.status & 255;
  }
}

export async function assetPath(root, encoded) {
  const parts = encoded.split('/').map(decodeURIComponent);
  if (parts.some(part => !part || part === '.' || part === '..' || /[/\\\0]/.test(part))) {
    throw new Error('invalid asset path');
  }
  const file = await realpath(join(root, ...parts));
  if (!within(root, file) || !(await stat(file)).isFile()) throw new Error('asset escapes mount');
  return file;
}

async function bounded(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

async function run(options) {
  const file = await realpath(resolve(options.file));
  const root = await realpath(resolve(options.root ?? dirname(file)));
  if (!(await stat(root)).isDirectory() || !(await stat(file)).isFile() ||
      !within(root, file) || !file.endsWith('.mjs')) {
    throw new Error('FILE must be a regular .mjs file beneath --root');
  }
  const sdk = await realpath(resolve(options.sdk ??
    fileURLToPath(new URL('../../titan-runtime/browser/', import.meta.url))));
  for (const name of ['titan-browser.mjs', 'titan-browser-page.mjs']) {
    await assetPath(sdk, name);
  }
  const require = createRequire(join(resolve(process.env.TITAN_PLAYWRIGHT_ROOT ?? process.cwd()), 'package.json'));
  if (require('playwright/package.json').version !== playwrightVersion) {
    throw new Error(`Playwright ${playwrightVersion} is required`);
  }
  const browserType = require('playwright')[options.engine];
  const monitor = new RunMonitor(options);
  let server, browserServer, browser, page, html, ready = false, closing = false;
  const interrupt = signal => monitor.fail('harness', `interrupted by ${signal}`);
  const sigint = () => interrupt('SIGINT'), sigterm = () => interrupt('SIGTERM');
  process.on('SIGINT', sigint);
  process.on('SIGTERM', sigterm);
  try {
    server = createServer((request, response) => {
      (async () => {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
          response.writeHead(405); response.end(); return;
        }
        const raw = (request.url ?? '').split('?')[0];
        if (raw === '/') {
          response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
          response.end(request.method === 'HEAD' ? undefined : html); return;
        }
        const mount = raw.startsWith('/root/') ? root : raw.startsWith('/sdk/') ? sdk : null;
        if (!mount) throw new Error('unknown asset mount');
        const path = await assetPath(mount, raw.slice(raw.indexOf('/', 1) + 1));
        const bytes = await readFile(path);
        const type = path.endsWith('.wasm') ? 'application/wasm' :
          /\.(?:mjs|js)$/.test(path) ? 'text/javascript; charset=utf-8' :
          /\.(?:json|map)$/.test(path) ? 'application/json' : 'application/octet-stream';
        response.writeHead(200, {'Content-Type': type, 'Content-Length': bytes.length, 'Cache-Control': 'no-store'});
        response.end(request.method === 'HEAD' ? undefined : bytes);
      })().catch(() => { if (!response.headersSent) response.writeHead(404); response.end(); });
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const origin = `http://127.0.0.1:${server.address().port}`;
    const config = {engine: options.engine, root: origin + '/root/',
      file: relative(root, file).split(sep).join('/'), loader: origin + '/sdk/titan-browser.mjs',
      args: options.args, jsTest: options.jsTest, allowDegradedTrace: options.allowDegradedTrace};
    html = '<!doctype html><meta charset=utf-8><title>Titan Playwright tests</title><script type=module>' +
      `import {startPage} from '/sdk/titan-browser-page.mjs'; startPage(${JSON.stringify(config).replaceAll('<', '\\u003c')});</script>`;
    browserServer = await browserType.launchServer({headless: true, timeout: Math.min(options.timeout, 30000),
      ...(options.engine === 'chromium' ? {args: ['--disable-dev-shm-usage']} : {})});
    browser = await browserType.connect(browserServer.wsEndpoint(), {timeout: Math.min(options.timeout, 30000)});
    diagnostic(`${options.engine} ${browser.version()}; Playwright ${playwrightVersion}; pid ${browserServer.process().pid}`);
    browser.on('disconnected', () => { if (!closing) monitor.fail('harness', 'browser disconnected before shutdown'); });
    page = await browser.newPage();
    page.on('crash', () => monitor.fail('harness', 'browser page crashed'));
    page.on('pageerror', error => { if (!ready) monitor.fail('harness', error.message); });
    page.on('console', message => {
      if (['warning', 'error'].includes(message.type())) diagnostic(`page ${message.type()}: ${message.text()}`);
    });
    await page.exposeBinding('__titanRunner', async (_source, payload) => {
      if (closing) return;
      try {
        if (typeof payload !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(payload)) {
          throw new Error('invalid binding base64');
        }
        const message = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
        if (message.type === 'ready') {
          if (ready) throw new Error('duplicate page-ready control');
          ready = true;
        } else if (message.type === 'bytes') {
          if (!['stdout', 'stderr'].includes(message.stream) || typeof message.data !== 'string' ||
              !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(message.data)) {
            throw new Error('malformed byte control');
          }
          process[message.stream].write(Buffer.from(message.data, 'base64'));
        } else if (message.type === 'gc') {
          if (!Number.isSafeInteger(message.id) || message.id <= 0) throw new Error('malformed GC request');
          let error = null;
          try { await page.requestGC(); } catch (cause) { error = cause.message; }
          if (!closing) await page.evaluate(({id, error}) => globalThis.__titanRunnerGc(id, error), {id: message.id, error});
        } else monitor.control(message);
      } catch (error) { monitor.fail('harness', `malformed page control: ${error.message}`); }
    });
    const navigating = page.goto(origin + '/', {waitUntil: 'commit', timeout: options.timeout})
      .catch(error => { if (!closing) monitor.fail('harness', error.message); });
    await Promise.race([navigating, monitor.done]);
    await monitor.done;
    await new Promise(resolve => setImmediate(resolve));
  } catch (error) {
    monitor.fail('harness', error.message);
  } finally {
    closing = true;
    monitor.stop();
    try {
      // BrowserServer owns the launched engine process tree. Always retire it,
      // even when the page is executing a CPU-bound Wasm loop.
      if (browserServer) {
        try { await bounded(browserServer.close(), 5000, 'browser close timed out'); }
        catch { await bounded(browserServer.kill(), 5000, 'browser process retirement timed out'); }
        const child = browserServer.process();
        if (child.exitCode === null && child.signalCode === null) {
          await bounded(new Promise(resolve => child.once('exit', resolve)), 5000, 'browser process survived shutdown');
        }
      }
      if (browser?.isConnected()) await bounded(browser.close(), 5000, 'browser connection close timed out');
    } catch (error) {
      diagnostic(`cleanup failed: ${error.message}`);
      monitor.failure ??= {category: 'harness', reason: error.message};
    } finally {
      if (server) {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
      }
      process.off('SIGINT', sigint);
      process.off('SIGTERM', sigterm);
    }
  }
  return monitor.result();
}

export async function main(argv) {
  let options;
  try { options = parseOptions(argv); }
  catch (error) { diagnostic(error.message); process.stderr.write(usage); return 2; }
  if (options.help) { process.stdout.write(usage); return 0; }
  try { return await run(options); }
  catch (error) { diagnostic(`harness failure: ${error.message}`); return 75; }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  process.exitCode = await main(process.argv.slice(2));
}
