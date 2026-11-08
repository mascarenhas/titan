// Responsiveness of the browser driver on a real page (titan#334). Each
// scenario of responsive.titan runs as a Task-form call while the page samples
// a 10 ms setInterval and requestAnimationFrame:
// - while Tasks wait, the interval keeps within 10% of its ideal count and
//   frames advance;
// - while 128 Tasks yield continuously, both still advance, with the largest
//   interval gap under GAP_BOUND_MS;
// - no driver turn shares a macrotask with the next one, while Tasks yield
//   and when every request settles at once: a self-renewing MessageChannel
//   ticker counts the page's macrotasks, and no Task may see the same count
//   in two turns;
// - a busy-wait control shows no ticks while it runs.
const GAP_BOUND_MS = 100;

// Starts sampling; the returned function stops it and summarizes.
function sample() {
  const ticks = [], frames = [];
  const start = performance.now();
  const interval = setInterval(() => { ticks.push(performance.now()); }, 10);
  let animating = true;
  const frame = time => {
    frames.push(time);
    if (animating) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  return () => {
    clearInterval(interval);
    animating = false;
    const end = performance.now();
    let gap = 0, previous = start;
    for (const tick of ticks) {
      gap = Math.max(gap, tick - previous);
      previous = tick;
    }
    gap = Math.max(gap, end - previous);
    return {ms: end - start, ticks, frames: frames.length, gap};
  };
}

// One message is always pending, so the count advances once per macrotask of
// this ticker between the driver's turn messages.
function ticker() {
  const channel = new MessageChannel();
  const state = {count: 0, running: true};
  channel.port1.onmessage = () => {
    state.count++;
    if (state.running) channel.port2.postMessage(null);
  };
  channel.port2.postMessage(null);
  return {state, stop() {
    state.running = false;
    channel.port1.close();
  }};
}

const round = value => Math.round(value * 10) / 10;

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the responsiveness image');
  context.assert(typeof requestAnimationFrame === 'function', 'the responsiveness test needs a page');
  const image = await context.image(context.args[0]);
  const callables = new Map();
  const reports = {};
  const marks = {};
  const held = [];
  let counter = {count: 0};
  const instance = image.create({locateFile: image.locateFile, bindings: {
    publish(name, callable) { callables.set(name, callable); },
    now() { return performance.now(); },
    report(key, value) { reports[key] = Number(value); },
    mark(name) { marks[name] = performance.now(); },
    macrotask() { return BigInt(counter.count); },
    held() { return {kind: 'detachable', promise: new Promise(resolve => { held.push(resolve); })}; },
  }});
  const result = {engine: context.engine};
  try {
    await instance.initialize();
    const task = (name, ...args) => instance.callTask(callables.get(name), args);

    let stop = sample();
    await task('wait_tasks', 8n, 600n);
    const waiting = stop();
    const ideal = Math.floor(waiting.ms / 10);
    result.wait = {ms: round(waiting.ms), ticks: waiting.ticks.length, ideal, frames: waiting.frames,
      gap: round(waiting.gap)};
    context.assert(Math.abs(waiting.ticks.length - ideal) <= Math.ceil(ideal / 10),
      `while Tasks waited the interval ticked ${waiting.ticks.length} times, ideal ${ideal}`);
    context.assert(waiting.frames > 0, 'animation frames stopped while Tasks waited');

    let macrotasks = ticker();
    counter = macrotasks.state;
    stop = sample();
    await task('yield_tasks', 128n, 600n);
    const yielding = stop();
    macrotasks.stop();
    result.yield = {ms: round(yielding.ms), ticks: yielding.ticks.length, frames: yielding.frames,
      gap: round(yielding.gap), resumptions: reports.yieldResumptions, macrotasks: reports.yieldMacrotasks,
      mostPerMacrotask: reports.yieldMostPerMacrotask, repeats: reports.yieldRepeats};
    context.assert(yielding.ticks.length > 0 && yielding.frames > 0,
      'the interval or animation frames stopped while 128 Tasks yielded');
    context.assert(yielding.gap <= GAP_BOUND_MS,
      `while 128 Tasks yielded the largest interval gap was ${round(yielding.gap)} ms`);
    context.assert(reports.yieldRepeats === 0 && reports.yieldMostPerMacrotask <= 64,
      `yielding Tasks shared a macrotask across turns (${JSON.stringify(result.yield)})`);

    macrotasks = ticker();
    counter = macrotasks.state;
    const settling = task('settle_all', 128n, 4n);
    while (held.length < 128) await new Promise(resolve => { setTimeout(resolve, 0); });
    for (const resolve of held.splice(0)) resolve(null);
    await settling;
    macrotasks.stop();
    result.settle = {resumptions: reports.settleResumptions, macrotasks: reports.settleMacrotasks,
      mostPerMacrotask: reports.settleMostPerMacrotask, repeats: reports.settleRepeats};
    context.assert(reports.settleResumptions === 128 * 5 && reports.settleRepeats === 0,
      `after every request settled at once, Tasks shared a macrotask across turns (${JSON.stringify(result.settle)})`);

    stop = sample();
    await task('busy', 150n);
    const busy = stop();
    const inside = busy.ticks.filter(time => time > marks.busyStart && time < marks.busyEnd).length;
    result.busy = {ms: round(marks.busyEnd - marks.busyStart), ticksInside: inside, gap: round(busy.gap)};
    context.assert(inside === 0 && busy.gap >= 140,
      `the busy-wait control did not block the page (${JSON.stringify(result.busy)})`);
  } finally {
    await instance.dispose();
  }
  context.stdout(new TextEncoder().encode(`RESPONSIVE ${JSON.stringify({verdict: 'PASS', ...result})}\n`));
}
