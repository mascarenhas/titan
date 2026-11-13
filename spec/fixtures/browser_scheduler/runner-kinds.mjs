import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, open, readFile, rm} from 'node:fs/promises';
import {devNull, tmpdir} from 'node:os';
import {join} from 'node:path';

const [runner, root, image] = process.argv.slice(2);
assert(runner && root && image, 'pass the installed runner module, root and kind probe image');

async function execute(stdout = 'pipe', stderr = 'pipe') {
  const child = spawn(process.execPath, [runner, '--engine', 'node', '--timeout', '30000',
    '--grace', '1500', '--root', root, image, '--', 'stdin', 'stdout', 'stderr'],
    {stdio: ['ignore', stdout, stderr]});
  let out = '', err = '';
  child.stdout?.setEncoding('utf8').on('data', bytes => { out += bytes; });
  child.stderr?.setEncoding('utf8').on('data', bytes => { err += bytes; });
  const code = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  assert.equal(code, 0, `runner failed: ${out}\n${err}`);
  return {out, err};
}

function kinds(text, stdout, stderr) {
  for (const [name, kind] of [['stdin', 'unknown'], ['stdout', stdout], ['stderr', stderr]]) {
    assert(text.includes(`${name}=${kind}\n`), `missing ${name}=${kind}: ${text}`);
  }
}

const directory = await mkdtemp(join(tmpdir(), 'titan-runner-kinds-'));
try {
  const piped = await execute();
  kinds(piped.out, 'pipe', 'pipe');
  kinds(piped.err, 'pipe', 'pipe');
  const stdoutPath = join(directory, 'stdout'), stderrPath = join(directory, 'stderr');
  const stdout = await open(stdoutPath, 'w');
  try {
    const stderr = await open(stderrPath, 'w');
    try { await execute(stdout.fd, stderr.fd); }
    finally { await stderr.close(); }
  } finally { await stdout.close(); }
  kinds(await readFile(stdoutPath, 'utf8'), 'file', 'file');
  kinds(await readFile(stderrPath, 'utf8'), 'file', 'file');
  const discarded = await open(devNull, 'w');
  try { kinds((await execute(discarded.fd)).err, 'unknown', 'pipe'); }
  finally { await discarded.close(); }
  process.stdout.write('RUNNER-KINDS {"verdict":"PASS","cases":3}\n');
} finally { await rm(directory, {recursive: true, force: true}); }
