import {encode, makeHost, rejection, until} from './support.mjs';

// Design 10.3's measurements that need only the drive interface, recorded and
// never gated: macrotask chains as controls, the relinquish round trip and
// per-turn cost with 1 and 64 jobs, the wake latency from notify() to
// delivery in a parked drive, and call() round trips. Figures are in
// microseconds, each the median of three runs. The scheduler spec does not run
// this harness; run it by hand:
//   titan-browser-run --engine <engine> --js-test measure.mjs -- <mini-driver image>

const round = value => Math.round(value * 10) / 10;
const sorted = values => [...values].sort((a, b) => a - b);
const median = values => sorted(values)[Math.floor(values.length / 2)];
const percentile = (values, fraction) => sorted(values)[Math.floor((values.length - 1) * fraction)];

async function repeat(measure) {
  const samples = [];
  for (let run = 0; run < 3; run++) samples.push(await measure());
  return round(median(samples));
}

// The smallest step performance.now() takes on this engine.
function resolution() {
  let smallest = Infinity;
  for (let sample = 0; sample < 200; sample++) {
    const start = performance.now();
    let now = start;
    while (now === start) now = performance.now();
    smallest = Math.min(smallest, now - start);
  }
  return round(smallest * 1000);
}

// A chain of `count` macrotasks from one source, per hop.
function macrotasks(source, count) {
  return new Promise(resolve => {
    let left = count, schedule, close = () => {};
    const start = performance.now();
    const step = () => {
      if (--left > 0) {
        schedule();
        return;
      }
      close();
      resolve((performance.now() - start) * 1000 / count);
    };
    if (source === 'setImmediate') {
      schedule = () => setImmediate(step);
    } else if (source === 'setTimeout(0)') {
      schedule = () => setTimeout(step, 0);
    } else {
      const channel = new MessageChannel();
      channel.port1.onmessage = step;
      schedule = () => channel.port2.postMessage(undefined);
      close = () => channel.port1.close();
    }
    schedule();
  });
}

async function chains() {
  const report = {};
  if (typeof setImmediate === 'function') report.setImmediate = await repeat(() => macrotasks('setImmediate', 2000));
  report.MessageChannel = await repeat(() => macrotasks('MessageChannel', 2000));
  report['setTimeout(0)'] = await repeat(() => macrotasks('setTimeout(0)', 200));
  return report;
}

// Per turn of a drive with `jobs` jobs: a drive of `turns` turns less a
// one-turn drive, over the relinquishes between.
async function perTurn(context, host, jobs, turns) {
  const time = async count => {
    const start = performance.now();
    const relinquishes = await host.call('drive_counters', BigInt(jobs), BigInt(count));
    const elapsed = performance.now() - start;
    context.assert(relinquishes === BigInt(count - 1), `a ${count}-turn drive relinquished ${relinquishes} times`);
    return elapsed;
  };
  return repeat(async () => {
    const whole = await time(turns);
    const single = await time(1);
    return (whole - single) * 1000 / (turns - 1);
  });
}

// A drive parked on a never-settling request until the returned function ends it.
async function park(context, host) {
  const controller = new AbortController();
  const hanging = host.task('hang', [], {signal: controller.signal});
  await until(context, () => host.snapshot().parked, 'hang did not park its drive');
  return async () => {
    controller.abort('measured');
    await rejection(context, hanging, 'CANCELLED');
  };
}

// notify() into the parked drive until the drive delivers the note, one
// notification at a time, each sent from a macrotask once the drive parked.
function wakeRun(host, rounds) {
  const note = host.fn('note');
  const latencies = [];
  return new Promise(resolve => {
    const channel = new MessageChannel();
    const start = performance.now();
    let sent;
    channel.port1.onmessage = () => {
      if (!host.snapshot().parked) {
        channel.port2.postMessage(undefined);
        return;
      }
      sent = performance.now();
      host.instance.notify(note, latencies.length);
    };
    host.hooks.noted = () => {
      latencies.push((performance.now() - sent) * 1000);
      if (latencies.length < rounds) {
        channel.port2.postMessage(undefined);
        return;
      }
      host.hooks.noted = undefined;
      channel.port1.close();
      resolve({latencies, perRound: (performance.now() - start) * 1000 / rounds});
    };
    channel.port2.postMessage(undefined);
  });
}

// `perRound` also counts the harness's MessageChannel hop between rounds; it
// is the only figure when the timer is too coarse for single latencies.
async function wakes(context, host, rounds, fine) {
  const end = await park(context, host);
  const medians = [], tails = [], perRounds = [];
  for (let run = 0; run < 3; run++) {
    const {latencies, perRound} = await wakeRun(host, rounds);
    medians.push(median(latencies));
    tails.push(percentile(latencies, 0.9));
    perRounds.push(perRound);
  }
  await end();
  const report = {perRound: round(median(perRounds))};
  if (fine) Object.assign(report, {median: round(median(medians)), p90: round(median(tails))});
  return report;
}

// call() round trips on an idle instance and queued into a parked drive.
async function calls(context, host, rounds) {
  const echo = host.fn('echo');
  const time = async () => {
    const start = performance.now();
    for (let index = 0; index < rounds; index++) await host.instance.call(echo, 1n);
    return (performance.now() - start) * 1000 / rounds;
  };
  const idle = await repeat(time);
  const end = await park(context, host);
  const parked = await repeat(time);
  await end();
  return {idle, parked};
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the mini-driver image');
  const image = await context.image(context.args[0]);
  const report = {engine: context.engine, resolution: resolution(), chains: await chains()};
  const host = makeHost(context, image);
  try {
    await host.instance.initialize();
    await host.call('register');
    await host.call('set_probes', false);
    const oneJob = await perTurn(context, host, 1, 2000);
    const sixtyFourJobs = await perTurn(context, host, 64, 300);
    report.turns = {oneJob, sixtyFourJobs, perJobStep: round((sixtyFourJobs - oneJob) / 63)};
    report.wakes = await wakes(context, host, 300, report.resolution <= 1);
    report.calls = await calls(context, host, 300);
    await host.instance.dispose();
  } finally { await host.instance.dispose().catch(() => {}); }
  context.stdout(encode('MEASURE ' + JSON.stringify(report) + '\n'));
}
