import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, mkdir, rm, symlink, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {assetPath, parseOptions, RunMonitor, within} from './playwright-run.mjs';

const options = {timeout: 1000, grace: 0};

function result(action) {
  const monitor = new RunMonitor(options);
  try { action(monitor); return monitor.result(); }
  finally { monitor.stop(); }
}

test('Playwright CLI keeps engine, policy, image mode and test arguments explicit', () => {
  assert.deepEqual(parseOptions(['--engine', 'webkit', '--root', '/output', '--sdk', '/sdk',
    '--timeout', '20000', '--grace', '10', '--allow-degraded-trace', '--image',
    '/output/main.mjs', '--', '--filter=^case$']), {
    engine: 'webkit', root: '/output', sdk: '/sdk', timeout: 20000, grace: 10,
    allowDegradedTrace: true, jsTest: false, file: '/output/main.mjs', args: ['--filter=^case$'],
  });
  for (const engine of ['chromium', 'firefox', 'webkit']) {
    const parsed = parseOptions(['--engine', engine, 'suite.mjs']);
    assert.equal(parsed.engine, engine);
    assert.equal(parsed.jsTest, true);
    assert.equal(parsed.allowDegradedTrace, false);
  }
  assert.equal(parseOptions(['--help']).help, true);
});

test('Playwright CLI rejects missing, extra and unsafe timer values', () => {
  for (const argv of [[], ['--engine', 'node', 'suite.mjs'], ['--engine'],
    ['--engine', 'firefox'], ['--engine', 'webkit', 'a.mjs', 'b.mjs'],
    ['--engine', 'chromium', '--unknown', 'a.mjs']]) {
    assert.throws(() => parseOptions(argv));
  }
  for (const [name, value] of [['timeout', '0'], ['timeout', '-1'], ['grace', '-1'],
    ['timeout', '2147483648'], ['grace', 'NaN'], ['timeout', '1.5']]) {
    assert.throws(() => parseOptions(['--engine', 'chromium', `--${name}`, value, 'suite.mjs']));
  }
});

test('Playwright monitor retains signed statuses and malformed completion checks', () => {
  assert.equal(result(m => m.control({type: 'complete', kind: 'returned', status: -1})), 255);
  assert.equal(result(m => m.control({type: 'complete', kind: 'host-test', status: 0})), 0);
  for (const message of [null, [], {type: 'other'}, {type: 'complete', kind: 'host-test', status: 2},
    {type: 'complete', kind: 'returned', status: 2147483648}, {type: 'abort'},
    {type: 'failure', category: 'other', reason: 'wrong'}]) {
    assert.equal(result(m => m.control(message)), 75);
  }
  assert.equal(result(m => {
    m.control({type: 'complete', kind: 'host-test', status: 0});
    m.control({type: 'complete', kind: 'host-test', status: 0});
  }), 75);
});

test('Playwright monitor keeps trap identity and late-failure arbitration', () => {
  assert.equal(result(m => {
    m.control({type: 'abort', reason: 'abort'});
    m.control({type: 'failure', category: 'harness', reason: 'wrapper', terminal: true});
  }), 70);
  assert.equal(result(m => {
    m.control({type: 'abort', reason: 'abort'});
    m.control({type: 'failure', category: 'harness', reason: 'wrapper', terminal: true});
    m.control({type: 'failure', category: 'trap', reason: 'original', knownTrap: true, terminal: true});
  }), 71);
  assert.equal(result(m => {
    m.control({type: 'complete', kind: 'returned', status: 0});
    m.control({type: 'abort', reason: 'late'});
  }), 73);
  assert.equal(result(m => m.control({type: 'failure', category: 'unhandled', reason: 'rejected'})), 74);
});

test('Playwright monitor times out without completion and stops its timers', async () => {
  const monitor = new RunMonitor({timeout: 10, grace: 0});
  await monitor.done;
  assert.equal(monitor.result(), 72);
  monitor.stop();
  monitor.fail('harness', 'after stop');
  assert.equal(monitor.failure.category, 'timeout');
});

test('Playwright asset server rejects traversal and symlinks outside its mount', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'titan-playwright-unit-'));
  try {
    const root = join(directory, 'root');
    await mkdir(root);
    await writeFile(join(root, 'image.wasm'), 'wasm');
    await writeFile(join(directory, 'outside.mjs'), 'outside');
    await symlink(join(directory, 'outside.mjs'), join(root, 'outside.mjs'));
    assert.equal(await assetPath(root, 'image.wasm'), join(root, 'image.wasm'));
    for (const path of ['../outside.mjs', '%2e%2e/outside.mjs', 'a%2fb', '%00', '', 'outside.mjs']) {
      await assert.rejects(assetPath(root, path));
    }
    assert.equal(within(root, join(directory, 'root-other', 'file')), false);
    assert.equal(within(root, join(root, 'child', 'file')), true);
  } finally { await rm(directory, {recursive: true, force: true}); }
});

const repository = fileURLToPath(new URL('../../', import.meta.url));
const execute = promisify(execFile);
for (const engine of (process.env.TITAN_PLAYWRIGHT_TEST_ENGINES ?? '').split(',').filter(Boolean)) {
  test(`Playwright ${engine} runs the shared page, preserves bytes and retires failed pages`, async () => {
    async function fixture(name) {
      const args = [fileURLToPath(new URL('./playwright-run.mjs', import.meta.url)),
        '--engine', engine, '--root', repository, '--timeout', '15000', '--grace', '0',
        fileURLToPath(new URL(`../fixtures/browser_playwright/${name}.mjs`, import.meta.url))];
      let output;
      try {
        output = {...await execute(process.execPath, args, {encoding: 'buffer', timeout: 30000}), status: 0};
      } catch (error) {
        if (!Number.isInteger(error.code)) throw error;
        output = {stdout: error.stdout, stderr: error.stderr, status: error.code};
      }
      const stderr = output.stderr.toString();
      assert.doesNotMatch(stderr, /cleanup failed:/);
      const leaders = [...stderr.matchAll(/\bpid ([1-9]\d*)\b/g)];
      assert.equal(leaders.length, 1, stderr);
      assert.throws(() => process.kill(Number(leaders[0][1]), 0), {code: 'ESRCH'});
      return output;
    }
    const success = await fixture('context');
    assert.equal(success.status, 0, success.stderr.toString());
    assert.deepEqual(success.stdout, Buffer.from([65, 0, 255, 10]));
    assert.match(success.stderr.toString(), /Playwright context passed/);
    const failure = await fixture('failure');
    assert.equal(failure.status, 1, failure.stderr.toString());
    assert.match(failure.stderr.toString(), /Playwright fixture rejected/);
    const timeout = await fixture('timeout');
    assert.equal(timeout.status, 72, timeout.stderr.toString());
    assert.match(timeout.stdout.toString(), /Playwright timeout entered/);
    assert.match(timeout.stderr.toString(), /timed out after 15000 ms/);
  });
}
