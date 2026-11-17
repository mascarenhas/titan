// The browser chapter's complete application, as its section documents it:
// spec/browser/build-delivery.lua copies the section's expected texts into
// delivery.json, and the hosted test and the Node run compare against them.

// The output element's text, or the program's stdout plus the completion line
// that the page appends.
export function outputViolation(text, expected) {
  return text === expected ? undefined :
    `the output is\n${text}\nnot the documented\n${expected}`;
}

// Standard error starts with the documented lines; on WebKit, Titan frames
// have no line. Only frames of the async runtime, which runs main as a Task,
// may follow them.
const runtimeFiles = new Set(['async.titan', 'coroutine.titan', 'runtime.browser.titan']);
const titanFrame = /^([^:\n]+\.titan)(?::[0-9]+)?: in .+$/;

export function errorsViolation(text, expected, engine) {
  const documented = expected.replace(/\n$/, '').split('\n').map(line => engine === 'webkit'
    ? line.replace(/^([^:\n]+\.titan):[0-9]+: in /, '$1: in ') : line);
  const lines = text.replace(/\n$/, '').split('\n');
  for (const [index, line] of documented.entries()) {
    if (lines[index] !== line) {
      return `standard error line ${index + 1} is ${JSON.stringify(lines[index])}, not ${JSON.stringify(line)}\n${text}`;
    }
  }
  const runtime = lines.slice(documented.length);
  if (runtime.length === 0) return `the trace has no async runtime frames\n${text}`;
  const stray = runtime.find(line => !runtimeFiles.has(titanFrame.exec(line)?.[1]));
  return stray === undefined ? undefined : `the trace continues with ${JSON.stringify(stray)}\n${text}`;
}
