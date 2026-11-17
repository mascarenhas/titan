// Hosted deployment test of the browser chapter's complete application, in
// the output of spec/browser/build-delivery.lua:
//
//   node hosted.mjs --engine chromium|firefox|webkit --root OUTPUT [--records FILE]
//
// The documented http-dev-server serves the documented site, and Playwright
// loads its page in one engine; no Node image host, native provider or WASI
// host takes part. The page must show the chapter's output and, for the
// engine, its error trace; it must request exactly its six files, the trace
// table must arrive before the first output, and nothing may be requested
// after the deliberate error. With --records it loads the page four more
// times and writes startup and responsiveness measurements, taken by an init
// script so that the page itself stays as documented.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {dirname, join, resolve} from 'node:path';
import {parseArgs} from 'node:util';
import {errorsViolation, outputViolation} from './expectations.mjs';

const {values: options} = parseArgs({options: {
  engine: {type: 'string'}, root: {type: 'string'}, records: {type: 'string'},
}});
const engine = options.engine;
assert.ok(['chromium', 'firefox', 'webkit'].includes(engine), 'usage: hosted.mjs --engine ENGINE --root OUTPUT');
const root = resolve(options.root);
const delivery = JSON.parse(await readFile(join(root, 'delivery.json'), 'utf8'));
const require = createRequire(join(resolve(process.env.TITAN_PLAYWRIGHT_ROOT), 'package.json'));
assert.equal(require('playwright/package.json').version, '1.64.1');
const browserType = require('playwright')[engine];

// Every request of one load, by path.
const allowed = ['/', '/app.mjs', '/app.wasm', '/app.wasm.trace', '/titan-protobuf.mjs', '/greeting.txt'];
// Output lines that open and close the Task phase.
const marks = {tasksStart: 'and the count is 3\n', tasksEnd: 'All five Tasks returned'};

// Runs in the page before its own scripts: timestamps of the first output, of
// the Task phase and of the caught error, animation frames, click delays, and
// the WebAssembly instantiation.
function measure(marks) {
  const record = {frames: [], clicks: [], instantiate: []};
  globalThis.__delivery = record;
  const observe = () => {
    const output = document.getElementById('output')?.textContent ?? '';
    const errors = document.getElementById('errors')?.textContent ?? '';
    const now = performance.now();
    if (output.length > 0) record.firstOutput ??= now;
    if (output.includes(marks.tasksStart)) record.tasksStart ??= now;
    if (output.includes(marks.tasksEnd)) record.tasksEnd ??= now;
    if (errors.includes('caught: ')) record.errorShown ??= now;
  };
  new MutationObserver(observe).observe(document, {subtree: true, childList: true, characterData: true});
  const frame = time => { record.frames.push(time); requestAnimationFrame(frame); };
  requestAnimationFrame(frame);
  addEventListener('click', event => { record.clicks.push(performance.now() - event.timeStamp); }, true);
  for (const name of ['instantiate', 'instantiateStreaming']) {
    const original = WebAssembly[name];
    WebAssembly[name] = function (...args) {
      const start = performance.now();
      const result = original.apply(this, args);
      result.then(() => record.instantiate.push({start, end: performance.now()}), () => {});
      return result;
    };
  }
}

async function serve() {
  const site = join(root, delivery.site);
  for (let port = 28700; port < 28800; port++) {
    const server = spawn(join(root, 'http-dev-server'), [site, String(port)],
      {stdio: ['ignore', 'pipe', 'pipe']});
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
    if (outcome === 'ready') return {server, origin: `http://127.0.0.1:${port}`};
    assert.equal(outcome, 1, output + diagnostics);
    assert.ok(diagnostics.includes('is already in use'), diagnostics);
  }
  throw new Error('no free port in 28700-28799');
}

function median(samples) {
  if (samples.length === 0) return null;
  const sorted = [...samples].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function summary(samples) {
  return {median: median(samples), max: samples.length ? Math.max(...samples) : null, samples: samples.length};
}

// One load in a fresh context: the page's texts, requests and measurements.
async function load(browser, origin) {
  const context = await browser.newContext({serviceWorkers: 'block'});
  try {
    const page = await context.newPage();
    const requests = [], responses = [], failed = [], sockets = [];
    const path = request => new URL(request.url()).pathname;
    page.on('request', request => requests.push(path(request)));
    page.on('response', response => responses.push({path: path(response.request()), status: response.status()}));
    page.on('requestfailed', request => failed.push({path: path(request), error: request.failure()?.errorText}));
    page.on('websocket', socket => sockets.push(socket.url()));
    const problems = [];
    page.on('pageerror', error => problems.push(error.message));
    page.on('crash', () => problems.push('page crashed'));
    await page.addInitScript(measure, marks);
    await page.goto(origin + '/');
    // Click every 10 ms while the Tasks wait, to sample input delay. A page
    // that completes without reaching them fails the output check.
    const completed = /\((?:returned|failed|exited), status -?[0-9]+\)\n$/;
    const shows = mark => page.evaluate(wanted => document.getElementById('output').textContent.includes(wanted), mark);
    await page.waitForFunction(({mark, completed}) => {
      const output = document.getElementById('output').textContent;
      return output.includes(mark) || new RegExp(completed).test(output);
    }, {mark: marks.tasksStart, completed: completed.source}, {timeout: 120000});
    const clickUntil = Date.now() + 5000;
    while (Date.now() < clickUntil && await shows(marks.tasksStart) && !(await shows(marks.tasksEnd))) {
      await page.mouse.click(5, 5);
      await page.waitForTimeout(10);
    }
    await page.waitForFunction(completed => new RegExp(completed).test(document.getElementById('output').textContent),
      completed.source, {timeout: 120000});
    // Anything requested late, after completion and disposal, still counts.
    await page.waitForTimeout(500);
    const observed = await page.evaluate(() => ({
      output: document.getElementById('output').textContent,
      errors: document.getElementById('errors').textContent,
      record: globalThis.__delivery,
      resources: performance.getEntriesByType('resource').map(entry => ({
        path: new URL(entry.name).pathname, start: entry.startTime, end: entry.responseEnd})),
    }));
    return {...observed, requests, responses, failed, sockets, problems};
  } finally {
    await context.close();
  }
}

function check(observed) {
  assert.deepEqual(observed.problems, [], 'page errors');
  const output = outputViolation(observed.output, delivery.output);
  assert.equal(output, undefined, output);
  const errors = errorsViolation(observed.errors, delivery.errors, engine);
  assert.equal(errors, undefined, errors);
  assert.deepEqual([...observed.requests].sort(), [...allowed].sort(),
    'the page must request exactly ' + allowed.join(', ') + '; it requested ' + observed.requests.join(', '));
  assert.deepEqual(observed.responses.map(item => `${item.path} ${item.status}`).sort(),
    allowed.map(item => `${item} 200`).sort(), 'every request must be answered with 200');
  // The page's own Resource Timing shows each fetched file complete. Chromium
  // reports a fetch whose body was read through a stream reader, as http.get
  // reads greeting.txt, as net::ERR_ABORTED to Playwright even after its
  // body completed, so only a failure before the response counts.
  for (const item of allowed.slice(1)) {
    const entries = observed.resources.filter(entry => entry.path === item);
    assert.ok(entries.length === 1 && entries[0].end > 0, `${item} did not complete in the page`);
  }
  const answered = new Set(observed.responses.map(item => item.path));
  assert.deepEqual(observed.failed.filter(item => !answered.has(item.path)), [], 'failed requests');
  assert.deepEqual(observed.sockets, [], 'WebSockets');
  const {record, resources} = observed;
  const trace = resources.find(entry => entry.path === '/app.wasm.trace');
  assert.ok(trace && record.firstOutput !== undefined && trace.end <= record.firstOutput,
    `the trace table (ending at ${trace?.end}) must arrive before the first output (${record.firstOutput})`);
  assert.ok(record.errorShown !== undefined, 'the caught error never appeared');
  const late = resources.filter(entry => entry.start >= record.errorShown);
  assert.deepEqual(late, [], 'requests after the deliberate error');
  // The chapter says the frame counter keeps advancing while the Tasks wait.
  assert.ok(record.frames.some(time => time > record.tasksStart && time < record.tasksEnd),
    'the page drew no frame while the Tasks waited');
}

function measurements(observed) {
  const {record, resources} = observed;
  const fetch = path => {
    const entry = resources.find(item => item.path === path);
    return entry ? entry.end - entry.start : null;
  };
  const instantiate = record.instantiate.at(-1);
  const phase = record.frames.filter(time => time >= record.tasksStart && time <= record.tasksEnd);
  const gaps = phase.slice(1).map((time, index) => time - phase[index]);
  return {
    firstOutputMs: record.firstOutput,
    instantiateMs: instantiate ? instantiate.end - instantiate.start : null,
    wasmFetchMs: fetch('/app.wasm'), traceFetchMs: fetch('/app.wasm.trace'),
    taskPhaseMs: record.tasksEnd - record.tasksStart, taskPhaseFrames: phase.length,
    taskPhaseMaxFrameGapMs: gaps.length ? Math.max(...gaps) : null, inputDelaysMs: record.clicks,
  };
}

const launch = {headless: true, ...(engine === 'chromium' ? {args: ['--disable-dev-shm-usage']} : {})};
const browser = await browserType.launch(launch);
let server;
try {
  let origin;
  ({server, origin} = await serve());
  const first = await load(browser, origin);
  check(first);
  const loads = [measurements(first)];
  if (options.records) {
    for (let index = 1; index < 5; index++) {
      const again = await load(browser, origin);
      assert.equal(outputViolation(again.output, delivery.output), undefined, `load ${index + 1} output`);
      loads.push(measurements(again));
    }
    const field = name => summary(loads.map(item => item[name]).filter(item => item !== null));
    const records = {
      job: 'browser-playwright', engine, browser: browser.version(), profile: delivery.profile,
      loads: loads.length,
      startup: {firstOutputMs: field('firstOutputMs'), instantiateMs: field('instantiateMs'),
        wasmFetchMs: field('wasmFetchMs'), traceFetchMs: field('traceFetchMs')},
      responsiveness: {taskPhaseMs: field('taskPhaseMs'), taskPhaseFrames: field('taskPhaseFrames'),
        taskPhaseMaxFrameGapMs: field('taskPhaseMaxFrameGapMs'),
        inputDelayMs: summary(loads.flatMap(item => item.inputDelaysMs))},
    };
    await mkdir(dirname(resolve(options.records)), {recursive: true});
    await writeFile(resolve(options.records), JSON.stringify(records, null, 2) + '\n');
  }
  const {inputDelaysMs, ...measured} = loads[0];
  console.log('BROWSER-DELIVERY-HOSTED ' + JSON.stringify({verdict: 'PASS', engine, browser: browser.version(),
    profile: delivery.profile, requests: first.requests.length, ...measured, inputDelayMs: summary(inputDelaysMs)}));
} finally {
  await browser.close();
  server?.kill('SIGTERM');
}
