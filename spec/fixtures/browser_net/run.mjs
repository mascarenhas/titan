import {spawn} from 'node:child_process';
import {mkdir, mkdtemp, rm} from 'node:fs/promises';
import {resolve, join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromiumTrust} from './nss_trust.mjs';

const fixture = dirname(fileURLToPath(import.meta.url));
const options = {};
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index], value = process.argv[index + 1];
  if (!['--root', '--engine', '--sdk', '--runner', '--repository'].includes(key) || value === undefined || options[key]) {
    throw new Error('usage: run.mjs --root OUTPUT --engine ENGINE --sdk SDK --runner RUNNER --repository REPO');
  }
  options[key] = value;
}
for (const key of ['--root', '--engine', '--sdk', '--runner', '--repository']) {
  if (!options[key]) throw new Error('missing ' + key);
}
const root = resolve(options['--root']), repository = resolve(options['--repository']);
const engine = options['--engine'], runner = resolve(options['--runner']), sdk = resolve(options['--sdk']);
const children = [];
let interrupted = false;
const interrupt = () => { interrupted = true; for (const child of children) signal(child, 'SIGTERM'); };
process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
function signal(child, name) {
  if (!child.pid) return;
  try { process.kill(-child.pid, name); } catch (error) { if (error.code !== 'ESRCH') throw error; }
}
function start(command, args, env) {
  const child = spawn(command, args, {env, detached: true, stdio: ['ignore', 'pipe', 'pipe']});
  child.done = new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (code, signal) => resolve({code, signal})); });
  // Attach immediately: startup failures are also awaited by ready().
  child.done.catch(() => {});
  child.stderr.on('data', chunk => process.stderr.write(chunk));
  children.push(child);
  return child;
}
function ready(child) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('network peer readiness timed out')), 30000);
    const data = chunk => {
      output += chunk.toString();
      const match = output.match(/^READY ([^\r\n]+)$/m);
      if (match) { clearTimeout(timer); child.stdout.off('data', data); resolve(match[1].split(' ')); }
    };
    child.stdout.on('data', data);
    child.done.then(result => { clearTimeout(timer); reject(new Error('network peer exited before readiness: ' + JSON.stringify(result))); }, reject);
  });
}
await mkdir(root, {recursive: true});
const home = await mkdtemp(join(root, 'chromium-home-'));
try {
  const ca = join(repository, 'spec/fixtures/ssl/ca.pem');
  const verified = engine === 'node' || (engine === 'chromium' && await chromiumTrust(home, ca));
  const env = {...process.env, NODE_EXTRA_CA_CERTS: ca,
    ...(engine === 'chromium' && process.platform === 'linux' ? {HOME: home} : {})};
  const native = start(join(root, 'native/server'), [join(root, 'images'), join(repository, 'spec/fixtures/ssl'), join(fixture, 'untrusted.pem')], env);
  const [http, valid, wrongHost, untrusted] = await ready(native);
  native.stdout.on('data', chunk => process.stdout.write(chunk));
  const raw = start(process.execPath, [join(fixture, 'wire_peer.mjs')], env);
  const [rawURL] = await ready(raw);
  raw.stdout.on('data', chunk => process.stdout.write(chunk));
  const config = {TITAN_TEST_HTTP_URL: http, TITAN_TEST_HTTPS_VALID_URL: valid,
    TITAN_TEST_HTTPS_WRONG_HOST_URL: wrongHost, TITAN_TEST_HTTPS_UNTRUSTED_URL: untrusted,
    TITAN_TEST_RAW_URL: rawURL, TITAN_TEST_VERIFIED_TLS: verified ? '1' : '0',
    TITAN_TEST_BROWSER: engine === 'node' ? '0' : '1'};
  const args = [runner, '--engine', engine, '--timeout', '300000', '--grace', '2000', '--root', root];
  if (runner.endsWith('playwright-run.mjs')) args.push('--sdk', sdk, join(root, 'images/net.test.mjs'));
  else args.push('--js-test', join(root, 'images/net.test.mjs'));
  args.push('--', 'images/http.mjs', JSON.stringify(config));
  const running = start(process.execPath, args, env);
  running.stdout.on('data', chunk => process.stdout.write(chunk));
  const result = await running.done;
  if (interrupted || result.code !== 0) throw new Error('network runner failed: ' + JSON.stringify(result));
} finally {
  let cleanupError;
  for (const child of children.reverse()) {
    signal(child, 'SIGTERM');
    const timer = setTimeout(() => signal(child, 'SIGKILL'), 3000);
    try { await child.done; } catch (error) { cleanupError ??= error; }
    finally { clearTimeout(timer); signal(child, 'SIGKILL'); }
  }
  await rm(home, {recursive: true, force: true});
  process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
  if (cleanupError) throw cleanupError;
}
