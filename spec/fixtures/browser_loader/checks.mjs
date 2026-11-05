export const encode = text => new TextEncoder().encode(text);

export function join(chunks) {
  const result = new Uint8Array(chunks.reduce((size, bytes) => size + bytes.length, 0));
  let offset = 0;
  for (const bytes of chunks) { result.set(bytes, offset); offset += bytes.length; }
  return result;
}

export async function rejection(context, promise, expected) {
  let caught;
  try { await promise; } catch (error) { caught = error; }
  context.assert(caught?.name === 'TitanBrowserError', 'expected TitanBrowserError rejection');
  for (const key of ['code', 'message', 'stream', 'cause']) {
    if (Object.hasOwn(expected, key)) {
      context.assert(caught[key] === expected[key], `wrong rejection ${key}: ${caught[key]}`);
    }
  }
  return caught;
}

export const closed = {
  code: 'TITAN_BROWSER_STATE', message: 'browser instance has already run or is disposed',
};
export const reentry = {
  code: 'TITAN_BROWSER_REENTRY', message: 'browser instance is active; reentry is not allowed',
};
export const closeBytes = new Uint8Array([99, 108, 111, 115, 101, 0, 255]);
export const tail = new Uint8Array([0, 116, 97, 105, 108, 255]);
export const prefixes = {
  stdout: new Uint8Array([79, 85, 84, 0, 255, 195, 40]),
  stderr: new Uint8Array([69, 82, 82, 0, 255, 195, 40]),
};
export const expectedBytes = stream => join([prefixes[stream], tail, closeBytes]);
