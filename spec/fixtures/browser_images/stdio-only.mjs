export async function run(context) {
  const {create, locateFile} = await context.image(context.args[0]);
  const stdout = [], stderr = [];
  let prompts = 0;
  const originalPrompt = globalThis.prompt;
  globalThis.prompt = () => { prompts++; return null; };
  const instance = create({
    locateFile,
    stdout: bytes => { stdout.push(bytes); },
    stderr: bytes => { stderr.push(bytes); },
  });
  try {
    const result = await instance.run();
    context.assert(result.kind === 'returned' && result.status === 0, 'stdio-only C image did not complete normally');
    context.assert(stdout.length === 4 && stderr.length === 1, 'native iovecs were split, merged or empty');
    context.equalBytes(stdout[0], new Uint8Array([0x41, 0, 0xff, 0x80, 0x42]), 'stdout bypassed byte sink');
    context.equalBytes(stdout[1], new Uint8Array(5000).fill(120), 'large fwrite batch was split or aliased');
    context.equalBytes(stdout[2], new TextEncoder().encode('left'));
    context.equalBytes(stdout[3], new TextEncoder().encode('right'));
    context.equalBytes(stderr[0], new TextEncoder().encode('err-tail'), 'unterminated stderr was lost');
    context.assert(prompts === 0, 'C stdin opened a browser dialog');
  } finally {
    await instance.dispose();
    globalThis.prompt = originalPrompt;
  }
}
