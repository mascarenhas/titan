import {decode, encode} from './support.mjs';

// Harness for bootstrap.titan: run() drives main as the async bootstrap Task.
// The drive cannot end before release() settles, and release() settles only
// after stdout has received the line main wrote before waiting, so that line
// reached the sink while the drive was relinquished.
function join(chunks) {
  const bytes = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

async function program(image, mode) {
  const stdout = [], stderr = [];
  let settle;
  const maybeRelease = () => {
    if (settle && decode(join(stdout)).includes('waiting\n')) { settle(null); settle = undefined; }
  };
  const instance = image.create({locateFile: image.locateFile,
    bindings: {release() {
      return {kind: 'detachable', promise: new Promise(resolve => { settle = resolve; maybeRelease(); })};
    }},
    stdout(bytes) { stdout.push(bytes.slice()); maybeRelease(); },
    stderr(bytes) { stderr.push(bytes.slice()); }});
  try {
    const result = await instance.run([mode, 'release']);
    return {result, out: decode(join(stdout)), err: decode(join(stderr))};
  } finally { await instance.dispose().catch(() => {}); }
}

const ORDER = 'order m1w1m2w2m3w3\nwaiting\nreleased\n';
const REPORT = 'uncaught error in async Task: bootstrap failure\nstack traceback:\n';

function expect(context, outcome, mode, kind, status, out) {
  const {result} = outcome;
  context.assert(result.kind === kind && result.status === status,
    `${mode}: ${JSON.stringify(result)}\n${outcome.err}`);
  context.assert(outcome.out === out, `${mode} output: ${outcome.out}`);
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the bootstrap image');
  const image = await context.image(context.args[0]);
  const returned = await program(image, 'return');
  expect(context, returned, 'return', 'returned', 3, ORDER);
  context.assert(returned.err === '', `return stderr: ${returned.err}`);
  // A failed main Task prints its own uncaught report, as natively, and run()
  // reports that message and trace as `failed` with no second report.
  const failed = await program(image, 'fail');
  expect(context, failed, 'fail', 'failed', 1, ORDER);
  context.assert(decode(failed.result.bytes) === 'bootstrap failure', `fail bytes: ${decode(failed.result.bytes)}`);
  context.assert(failed.result.trace instanceof Uint8Array && failed.result.trace.length > 0 &&
    failed.err === REPORT + decode(failed.result.trace) + '\n', `fail stderr and trace: ${failed.err}`);
  // A cancelled main is not a failure: status 1 and no report, as natively.
  const cancelled = await program(image, 'cancel');
  expect(context, cancelled, 'cancel', 'returned', 1, ORDER);
  context.assert(cancelled.err === '', `cancel stderr: ${cancelled.err}`);
  const exited = await program(image, 'exit');
  expect(context, exited, 'exit', 'exited', 7, ORDER);
  // An exit requested after main failed wins.
  const failedExit = await program(image, 'fail-exit');
  expect(context, failedExit, 'fail-exit', 'exited', 7, '');
  context.assert(failedExit.err.startsWith(REPORT), `fail-exit stderr: ${failedExit.err}`);
  context.stdout(encode('BOOTSTRAP {"verdict":"PASS"}\n'));
}
