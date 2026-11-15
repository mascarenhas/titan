const encoder = new TextEncoder(), decoder = new TextDecoder();
function text(chunks) { return chunks.map(bytes => decoder.decode(bytes)).join(''); }
function host(image, env) {
  const state = {stdout: [], stderr: [], errors: [], notes: [], entry: undefined};
  state.instance = image.create({locateFile: image.locateFile, env,
    bindings: {net_publish(entry) { state.entry = entry; }, net_note(note) { state.notes.push(note); }},
    stdout(bytes) { state.stdout.push(bytes.slice()); }, stderr(bytes) { state.stderr.push(bytes.slice()); },
    onNotificationError(error) { state.errors.push(error); }});
  return state;
}
async function until(predicate, message) {
  const deadline = performance.now() + 10000;
  do {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  } while (performance.now() < deadline);
  throw new Error(message);
}
async function rejection(context, promise, code) {
  try { await promise; } catch (error) {
    context.assert(error.code === 'TITAN_BROWSER_' + code, `expected ${code}, received ${error.code}: ${error.message}`);
    return error;
  }
  throw new Error('expected a rejected ' + code + ' operation');
}
async function close(context, state) {
  context.assert(state.errors.length === 0, 'notification errors before disposal: ' + JSON.stringify(state.errors));
  await state.instance.dispose();
  context.assert(state.errors.length === 0, 'notification errors during disposal: ' + JSON.stringify(state.errors));
}
async function suite(context, image, env) {
  const state = host(image, env);
  try {
    const result = await state.instance.run([]);
    const output = text(state.stdout), errors = text(state.stderr);
    context.stdout(encoder.encode(output));
    if (errors) context.stderr(encoder.encode(errors));
    context.assert(result.kind === 'returned' && result.status === 0, 'live HTTP suite failed:\n' + output + errors);
    const passed = output.match(/\[  PASSED  \] (\d+) tests?\./);
    context.assert(passed && Number(passed[1]) === 39, 'live HTTP owner did not pass its thirty-nine active cases:\n' + output);
    return Number(passed[1]);
  } finally { await close(context, state); }
}

// Interpose on the public Fetch boundary, not Titan internals. Calling the
// SDK's promise continuation first retires its headers BrowserRequest; only
// then is the Task cancelled, before any subsequent Wasm driver turn.
function fetchBoundary(context, phase, source, controller, marks) {
  const original = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const pending = original(input, init);
    if (String(input) !== source) return pending;
    marks.signal = init.signal;
    const then = pending.then.bind(pending);
    pending.then = (encodeHead, rejected) => {
      const head = then(response => {
        if (phase === 'metadata') {
          response = new Proxy(response, {get(target, name) {
            return name === 'status' ? 100 : Reflect.get(target, name, target);
          }});
        }
        return encodeHead(response);
      }, rejected);
      if (phase === 'settled') {
        const settled = head.then.bind(head);
        head.then = (fulfilled, failed) => settled(value => {
          const result = fulfilled(value);
          marks.settled = true;
          context.assert(!init.signal.aborted, 'headers settlement had already aborted the session');
          controller.abort('headers settled before adoption');
          context.assert(!init.signal.aborted, 'cancellation synchronously retired an already-settled headers request');
          return result;
        }, failed);
      }
      return head;
    };
    return pending;
  };
  return () => { globalThis.fetch = original; };
}

async function cancellation(context, image, env, phase) {
  const state = host(image, env), controller = new AbortController(), marks = {};
  const route = phase === 'headers' ? 'headers/' + phase : 'body/' + phase;
  const source = env.TITAN_TEST_RAW_URL + '/' + route;
  const originalFetch = globalThis.fetch;
  const restore = phase === 'settled' || phase === 'metadata'
    ? fetchBoundary(context, phase, source, controller, marks) : () => {};
  const events = async () => (await originalFetch(env.TITAN_TEST_RAW_URL + '/events/' + route)).json();
  try {
    await state.instance.initialize();
    context.assert(state.entry, 'HTTP image did not publish its cancellation entry');
    const pending = state.instance.callTask(state.entry, [phase, source], {signal: controller.signal});
    pending.catch(() => {});
    if (phase === 'headers') {
      await until(async () => (await events()).opened === 1, 'held headers request never reached the peer');
      controller.abort('waiting for headers');
    } else if (phase === 'body') {
      await until(() => state.notes.includes('body-ready'), 'stream did not deliver its first chunk');
      controller.abort('waiting for body');
    }
    if (phase === 'metadata') context.assert(await pending === 'metadata EIO', 'metadata failure lost OperationError EIO');
    else await rejection(context, pending, 'CANCELLED');
    if (phase === 'settled') context.assert(marks.settled && marks.signal.aborted, 'settled-before-adoption session was not aborted');
    // This observation must precede dispose(): disposal is not the leak oracle.
    await until(async () => {
      const count = await events();
      return count.opened === 1 && count.closed === 1;
    }, phase + ' did not promptly abort its peer socket before dispose');
    context.assert(state.errors.length === 0, phase + ' produced a notification error');
    return phase;
  } finally { restore(); await close(context, state); }
}

async function sameOrigin(context, env) {
  if (env.TITAN_TEST_BROWSER !== '1') return 0;
  const iframe = document.createElement('iframe');
  const token = 'browser-net-' + crypto.randomUUID();
  const url = new URL(env.TITAN_TEST_HTTP_URL + '/runner');
  url.searchParams.set('config', JSON.stringify({...env, TITAN_TEST_SAME_ORIGIN: '1'}));
  url.searchParams.set('token', token);
  let listener, timer;
  try {
    const result = new Promise((resolve, reject) => {
      listener = event => {
        if (event.origin !== url.origin || event.source !== iframe.contentWindow || event.data?.token !== token) return;
        resolve(event.data);
      };
      window.addEventListener('message', listener);
      timer = setTimeout(() => reject(new Error('same-origin cache runner timed out')), 120000);
    });
    iframe.src = url.href;
    document.body.append(iframe);
    const report = await result;
    context.assert(report.ok && report.passed === 1, 'same-origin HTTP cache suite failed: ' + report.output);
    context.stdout(encoder.encode(report.output));
    return report.passed;
  } finally { clearTimeout(timer); window.removeEventListener('message', listener); iframe.remove(); }
}

export async function run(context) {
  context.assert(context.args.length === 2, 'pass HTTP image and fixture configuration');
  const [imagePath, configuration] = context.args, env = JSON.parse(configuration);
  const image = await context.image(imagePath);
  const report = {verdict: 'PASS', cases: await suite(context, image, env), cancellation: []};
  for (const phase of ['headers', 'settled', 'metadata', 'body']) {
    report.cancellation.push(await cancellation(context, image, env, phase));
  }
  report.sameOrigin = await sameOrigin(context, env);
  context.stdout(encoder.encode('BROWSER-NET ' + JSON.stringify(report) + '\n'));
}
