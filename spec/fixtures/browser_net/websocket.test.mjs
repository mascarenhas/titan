function text(chunks) {
  const decoder = new TextDecoder();
  return chunks.map(bytes => decoder.decode(bytes, {stream: true})).join('') + decoder.decode();
}
async function until(predicate, message) {
  const deadline = performance.now() + 10000;
  do {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  } while (performance.now() < deadline);
  throw new Error(message);
}

function observe() {
  const original = globalThis.WebSocket, rows = new Map();
  globalThis.WebSocket = new Proxy(original, {construct(target, args) {
    const socket = Reflect.construct(target, args);
    const row = {socket, opened: false, added: 0, removed: 0, sends: 0};
    rows.set(socket.url, row);
    const add = socket.addEventListener, remove = socket.removeEventListener, send = socket.send;
    const listeners = new Map();
    socket.addEventListener = function(type, listener, options) {
      const actual = type === 'open' ? function(...args) { row.opened = true; return listener.apply(this, args); } : listener;
      listeners.set(listener, actual); row.added++;
      return add.call(this, type, actual, options);
    };
    socket.removeEventListener = function(type, listener, options) {
      const actual = listeners.get(listener) ?? listener;
      listeners.delete(listener); row.removed++;
      return remove.call(this, type, actual, options);
    };
    socket.send = function(data) {
      row.sends++;
      return send.call(this, data);
    };
    return socket;
  }});
  return {rows, metric(name, source) {
    const row = rows.get(source);
    if (!row) throw new Error('unknown observed WebSocket ' + source);
    if (name === 'send') return row.sends;
    if (name === 'buffered') return row.socket.bufferedAmount;
    if (name === 'ready') return row.socket.readyState;
    throw new Error('unknown WebSocket metric ' + name);
  }, restore() { globalThis.WebSocket = original; rows.clear(); }};
}

function host(context, image, env) {
  const state = {stdout: [], stderr: [], errors: [], notes: [], armed: new Map(), pending: [],
    entry: undefined, controls: undefined, observer: observe()};
  state.instance = image.create({locateFile: image.locateFile, env,
    bindings: {__titanTest(controls) { state.controls = controls; },
      ws_publish(entry) { state.entry = entry; }, ws_note(note) { state.notes.push(note); },
      ws_arm(source, id, action) { state.armed.set(source, {id, action, sent: 0}); },
      ws_high(source) {
        const entry = state.armed.get(source);
        if (!entry || entry.sent) return;
        entry.sent = state.observer.metric('send', source);
        const pending = fetch(env.TITAN_TEST_RAW_URL + '/ws-control/' + entry.id + '/' + entry.action)
          .then(async response => {
            context.assert(response.ok && await response.text() === 'ready', 'observed-high peer action was not admitted');
          });
        state.pending.push(pending); pending.catch(error => state.errors.push(error));
      },
      ws_metric(name, source) {
        if (name === 'clock') return BigInt(Math.floor(performance.now()));
        if (name === 'exactWrite') return env.TITAN_TEST_ENGINE === 'webkit' ? 0n : 1n;
        if (name === 'armedSend') return BigInt(state.armed.get(source)?.sent ?? 0);
        const marks = state.controls.snapshot();
        return BigInt(Object.hasOwn(marks, name) ? marks[name] : state.observer.metric(name, source));
      }},
    stdout(bytes) { state.stdout.push(bytes.slice()); context.stdout(bytes); },
    stderr(bytes) { state.stderr.push(bytes.slice()); context.stderr(bytes); },
    onNotificationError(error) { state.errors.push(error); }});
  return state;
}

async function peersClosed(context, state, env) {
  for (const [source, row] of state.observer.rows) {
    const url = new URL(source);
    const raw = url.origin.replace(/^ws/, 'http') === env.TITAN_TEST_RAW_URL;
    const endpoint = raw ? env.TITAN_TEST_RAW_URL + '/events' + url.pathname
      : env.TITAN_TEST_HTTP_URL + '/ws-events' + url.search;
    const firefoxOpening = raw && !row.opened && env.TITAN_TEST_ENGINE === 'firefox' && url.pathname.endsWith('/hold');
    const nodeRejection = raw && !row.opened && env.TITAN_TEST_ENGINE === 'node' &&
      (url.pathname.endsWith('/unselected') || url.pathname.endsWith('/malformed'));
    if (firefoxOpening || nodeRejection) {
      context.assert(row.added === row.removed && state.errors.length === 0,
        'opening retirement did not detach the Titan request before peer cleanup');
      const counts = await (await fetch(endpoint)).json();
      if (counts.opened === 1 && counts.closed === 0) {
        // These hosts retain the TCP after their DOM socket has already closed.
        const id = url.pathname.split('/')[2], action = firefoxOpening ? 'release' : 'fin';
        const response = await fetch(env.TITAN_TEST_RAW_URL + '/ws-control/' + id + '/' + action);
        context.assert(response.ok && await response.text() === 'ready', 'opening peer cleanup was not admitted');
      }
    }
    await until(async () => {
      const response = await fetch(endpoint), body = await response.text();
      const counts = raw ? JSON.parse(body) : {opened: Number(body.split(':')[0]), closed: Number(body.split(':')[1])};
      const complete = (row.opened ? counts.opened === 1 : counts.opened === 0 || counts.opened === 1) &&
        counts.closed === counts.opened;
      if (complete && raw && url.pathname.endsWith('/close-reset')) {
        context.assert(counts.closeReply === true && counts.closeReplyTimedOut === false,
          'close-reset peer did not receive the client Close reply within 5 s: ' + body);
      }
      return complete;
    }, 'peer socket did not close before dispose: ' + source);
    context.assert(row.added === row.removed, 'WebSocket DOM listeners leaked: ' + source);
  }
}

async function close(context, state, env) {
  try {
    await Promise.all(state.pending);
    await peersClosed(context, state, env);
    context.assert(state.errors.length === 0, 'WebSocket notification errors before disposal');
  } finally {
    try {
      await state.instance.dispose();
      context.assert(state.errors.length === 0, 'WebSocket notification errors during disposal');
    } finally {
      state.controls?.restore(); state.controls = state.entry = undefined;
      state.observer.restore();
      state.armed.clear(); state.pending.length = 0;
    }
  }
}

async function suite(context, image, env) {
  const state = host(context, image, env);
  try {
    const result = await state.instance.run([]);
    const output = text(state.stdout), errors = text(state.stderr);
    context.assert(result.kind === 'returned' && result.status === 0, 'live WebSocket suite failed:\n' + output + errors);
    const passed = output.match(/\[  PASSED  \] (\d+) tests?\./);
    context.assert(passed && Number(passed[1]) === 29, 'live WebSocket suite did not pass its 29 cases:\n' + output);
    return Number(passed[1]);
  } finally { await close(context, state, env); }
}

async function cancellation(context, image, env, phase) {
  const state = host(context, image, env), controller = new AbortController();
  const mode = phase === 'connect' ? 'hold' : phase === 'write' ? 'paused' : 'idle';
  const route = '/ws/cancel-' + phase + '/' + mode, source = env.TITAN_TEST_RAW_URL.replace(/^http/, 'ws') + route;
  try {
    await state.instance.initialize();
    context.assert(state.entry, 'WebSocket image did not publish its cancellation entry');
    const pending = state.instance.callTask(state.entry, [phase, source], {signal: controller.signal});
    pending.catch(() => {});
    await until(async () => {
      if (phase === 'connect') return (await (await fetch(env.TITAN_TEST_RAW_URL + '/events' + route)).json()).opened === 1;
      if (phase === 'read') return state.notes.includes('read-ready');
      return state.notes.includes('write-ready') && state.observer.metric('buffered', source) > 262144;
    }, phase + ' cancellation did not reach its admitted wait');
    controller.abort('cancel WebSocket ' + phase);
    let cancelled = false;
    try { await pending; } catch (error) {
      context.assert(error.code === 'TITAN_BROWSER_CANCELLED', 'wrong WebSocket cancellation identity: ' + error.code);
      cancelled = true;
    }
    context.assert(cancelled, 'WebSocket operation completed instead of cancelling');
    if (phase === 'write') await fetch(env.TITAN_TEST_RAW_URL + '/ws-control/cancel-write/resume');
    return phase;
  } finally { await close(context, state, env); }
}

export async function websocket(context, image, env) {
  const report = {cases: await suite(context, image, env), cancellation: []};
  for (const phase of ['connect', 'read', 'write']) report.cancellation.push(await cancellation(context, image, env, phase));
  return report;
}
