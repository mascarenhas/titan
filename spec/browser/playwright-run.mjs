// Test infrastructure: reuse the production page/loader host on managed engines.
import {createServer} from 'node:http';
import {readFile, realpath, stat} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {basename, dirname, join, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
// Shared supervision intentionally retains the titan-browser-run diagnostic prefix.
import {Monitor, within} from '../../titan-runtime/browser/titan-browser-run.mjs';

const playwrightVersion = '1.64.1';
const diagnostic = text => process.stderr.write(`titan-playwright-run: ${text}\n`);
const usage = `usage: node spec/browser/playwright-run.mjs --engine chromium|firefox|webkit
       [--root DIR] [--sdk DIR] [--timeout MS] [--grace MS] [--imports FILE]
       [--persistent-context DIR] [--allow-degraded-trace] [--image] FILE [-- ARG...]

FILE is a portable run(context) test unless --image selects a Titan image.
--imports names a module beneath --root whose default export is create's
imports (context.imports for a portable test).
The caller owns and removes DIR when --persistent-context selects a persistent profile.
Set TITAN_PLAYWRIGHT_ROOT to an npm prefix containing playwright@${playwrightVersion}.
Set PLAYWRIGHT_BROWSERS_PATH to a session-owned managed-browser directory.
`;

export function parseOptions(argv) {
  const options = {engine: undefined, root: undefined, sdk: undefined,
    timeout: 300000, grace: 1500, args: [], jsTest: true, allowDegradedTrace: false};
  const values = new Set(['engine', 'root', 'sdk', 'timeout', 'grace', 'persistent-context', 'imports']);
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
  let imports;
  if (options.imports !== undefined) {
    const module = await realpath(resolve(options.imports));
    if (!within(root, module) || !(await stat(module)).isFile() || !module.endsWith('.mjs')) {
      throw new Error('--imports must name a regular .mjs file beneath --root');
    }
    imports = relative(root, module).split(sep).join('/');
  }
  const requestedProfile = options['persistent-context'] && resolve(options['persistent-context']);
  // The profile may not exist yet; its parent does.
  const profile = requestedProfile &&
    join(await realpath(dirname(requestedProfile)), basename(requestedProfile));
  if (profile && !within(root, profile)) throw new Error('--persistent-context must be beneath --root');
  const sdk = await realpath(resolve(options.sdk ??
    fileURLToPath(new URL('../../titan-runtime/browser/', import.meta.url))));
  await assetPath(sdk, 'titan-browser-page.mjs');
  const require = createRequire(join(resolve(process.env.TITAN_PLAYWRIGHT_ROOT ?? process.cwd()), 'package.json'));
  if (require('playwright/package.json').version !== playwrightVersion) {
    throw new Error(`Playwright ${playwrightVersion} is required`);
  }
  const browserType = require('playwright')[options.engine];
  const monitor = new Monitor(options);
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
      file: relative(root, file).split(sep).join('/'),
      args: options.args, jsTest: options.jsTest, allowDegradedTrace: options.allowDegradedTrace, imports};
    html = '<!doctype html><meta charset=utf-8><title>Titan Playwright tests</title><script type=module>' +
      `import {startPage} from '/sdk/titan-browser-page.mjs'; startPage(${JSON.stringify(config).replaceAll('<', '\\u003c')});</script>`;
    const launch = {headless: true, timeout: Math.min(options.timeout, 30000),
      ...(options.engine === 'chromium' ? {args: ['--disable-dev-shm-usage']} : {})};
    if (profile) {
      const context = await browserType.launchPersistentContext(profile, launch);
      browser = context.browser();
      diagnostic(`${options.engine} ${browser.version()}; Playwright ${playwrightVersion}; persistent context`);
      page = context.pages()[0] ?? await context.newPage();
    } else {
      browserServer = await browserType.launchServer(launch);
      browser = await browserType.connect(browserServer.wsEndpoint(), {timeout: Math.min(options.timeout, 30000)});
      diagnostic(`${options.engine} ${browser.version()}; Playwright ${playwrightVersion}; pid ${browserServer.process().pid}`);
      page = await browser.newPage();
    }
    browser.on('disconnected', () => { if (!closing) monitor.fail('harness', 'browser disconnected before shutdown'); });
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
