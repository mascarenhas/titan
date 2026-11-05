const encoder = new TextEncoder();
const text = value => encoder.encode(value);
const binary = prefix => new Uint8Array([...text(prefix), 0, 255, 195, 40, 237, 160, 128, ...text(":end")]);
const join = chunks => {
  const result = new Uint8Array(chunks.reduce((count, chunk) => count + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
};
const equal = (left, right) => left.length === right.length && left.every((byte, index) => byte === right[index]);
function occurrences(haystack, needle) {
  let count = 0;
  for (let offset = 0; offset <= haystack.length - needle.length; offset++) {
    if (needle.every((byte, index) => byte === haystack[offset + index])) count++;
  }
  return count;
}

export async function run(context) {
  const [subsetPath, fidelityPath, ...isolatedPaths] = context.args;
  context.assert(isolatedPaths.length === 13, "all thirteen isolated module images are required");
  const emit = record => context.stdout(text(JSON.stringify({engine: context.engine, ...record}) + "\n"));
  async function execute(image) {
    const stdout = [], stderr = [];
    const instance = context.create(image.factory, {locateFile: image.locateFile,
      stdout: chunk => { stdout.push(chunk.slice()); },
      stderr: chunk => { stderr.push(chunk.slice()); }});
    try {
      await instance.initialize();
      const result = await instance.run([]);
      return {result, stdout: join(stdout), stderr: join(stderr)};
    } finally { await instance.dispose(); }
  }
  function passed(observed) {
    context.assert(observed.result.kind === "returned" && observed.result.status === 0,
      "initializer image failed through the Titan completion channel");
    context.assert(occurrences(observed.stdout, text("[==========] 1 test ran.\n")) === 1 &&
      occurrences(observed.stdout, text("[  PASSED  ] 1 test.\n")) === 1,
      "initializer image did not execute its one native Titan test");
    context.assert(observed.stderr.length === 0, "initializer image emitted unexpected stderr");
  }
  for (const path of isolatedPaths) {
    passed(await execute(await context.image(path)));
    emit({isolatedInitializer: path, passed: 1});
  }
  const subset = await context.image(subsetPath);
  for (let cycle = 0; cycle < 3; cycle++) {
    passed(await execute(subset));
    await context.tick();
    await context.gc();
  }
  context.assert(subset.factory === (await context.image(subsetPath)).factory,
    "repeated subset instances did not share the cached image factory");
  emit({subsetInitializeRunDisposeCycles: 3});

  const observed = await execute(await context.image(fidelityPath));
  context.assert(observed.result.kind === "returned" && observed.result.status === 1,
    "post-fiber failure did not survive the Titan-owned completion channel");
  const fullName = join([text("fidelity_test.test_binary_failure_after_coroutine_owner."), binary("name")]);
  const runLine = join([text("[ RUN      ] "), fullName, text("\n")]);
  const failureLine = join([text("[  FAILED  ] "), fullName, text("\n")]);
  const message = join([text(": "), binary("message"), text("\n")]);
  context.assert(occurrences(observed.stdout, runLine) === 1,
    "test name was not reported byte-exact on the run line");
  context.assert(occurrences(observed.stdout, failureLine) === 2,
    "test name was not reported byte-exact on the failure and summary lines");
  context.assert(occurrences(observed.stdout, message) === 1,
    "test failure message was not reported byte-exact");
  // The real coroutine owner intentionally reports one cleanup warning.
  const expectedStderr = join([text("Lua warning: error in coroutine cleanup (cleanup failure)\n"),
    binary("stderr"), text("\n")]);
  context.assert(equal(observed.stderr, expectedStderr),
    "stderr hook did not preserve the warning and binary marker exactly: " +
      Array.from(observed.stderr).join(","));
  const coroutinePass = text("[       OK ] coroutine.tests.test_");
  context.assert(occurrences(observed.stdout, coroutinePass) > 0,
    "fidelity image did not run the real coroutine owner before failing");
  const firstFiber = observed.stdout.findIndex((_, offset) =>
    coroutinePass.every((byte, index) => byte === observed.stdout[offset + index]));
  const binaryRun = observed.stdout.findIndex((_, offset) =>
    runLine.every((byte, index) => byte === observed.stdout[offset + index]));
  context.assert(firstFiber >= 0 && firstFiber < binaryRun,
    "deliberate failure ran before the coroutine owner");
  emit({fidelity: "byte-exact", completionStatus: observed.result.status,
    coroutineOwnerPassedCases: occurrences(observed.stdout, coroutinePass), verdict: "PASS"});
}
