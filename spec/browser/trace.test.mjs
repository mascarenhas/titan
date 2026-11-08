const encoder = new TextEncoder();
const decoder = new TextDecoder();
const unavailable = "(native Titan frames unavailable: trace map not loaded)";
const captureFailed = "(native Titan frames unavailable: capture failed)";
const truncated = "(...native frames truncated...)";
const own = (object, key) => Object.getOwnPropertyDescriptor(object, key);

function equalDescriptor(left, right) {
  if (!left || !right) return left === right;
  const keys = ["value", "writable", "get", "set", "enumerable", "configurable"];
  return keys.every(key => Object.hasOwn(left, key) === Object.hasOwn(right, key) && Object.is(left[key], right[key]));
}
function restore(object, key, descriptor) {
  if (descriptor) Object.defineProperty(object, key, descriptor);
  else if (!Reflect.deleteProperty(object, key)) throw new Error("cannot restore absent " + key);
}
function frames(output) {
  const found = [];
  const pattern = /^TRACE-BEGIN ([a-z0-9_]+)\n([\s\S]*?)\nTRACE-END \1\r?$/gm;
  for (const match of output.matchAll(pattern)) found.push({label: match[1], trace: match[2]});
  return found;
}
function occurrences(text, needle) { return text.split(needle).length - 1; }
function frameCount(trace, suffix) {
  return trace.split("\n").filter(line => line.endsWith(suffix)).length;
}

export async function run(context) {
  const degraded = context.args.length === 1 && context.args[0] === "--degraded";
  context.assert(degraded || context.args.length === 0, "trace gate accepts only --degraded");
  const manifest = JSON.parse(decoder.decode(await context.bytes("manifest.json")));
  context.assert(Array.isArray(manifest.cases) && Array.isArray(manifest.degradedCases), "invalid trace manifest lists");
  context.assert(manifest.profile === "production" || manifest.profile === "validation",
    "invalid trace manifest profile");
  const names = new Set();
  for (const row of [...manifest.cases, ...manifest.degradedCases]) {
    context.assert(typeof row.name === "string" && !names.has(row.name), "duplicate/invalid manifest name");
    names.add(row.name);
    context.assert(typeof row.image === "string" && !row.image.startsWith("/") && row.image.endsWith(".mjs") &&
      !row.image.split("/").includes(".."), "invalid manifest image");
    context.assert(Array.isArray(row.args) && row.args.every(value => typeof value === "string"), "invalid manifest args");
    context.assert(["returned", "failed"].includes(row.kind) && Number.isInteger(row.status) &&
      row.status >= -2147483648 && row.status <= 2147483647, "invalid manifest outcome");
    context.assert(Number.isInteger(row.testCount) && row.testCount >= 0 && Array.isArray(row.stderrContains) &&
      row.stderrContains.every(value => typeof value === "string") && typeof row.program === "boolean",
      "invalid manifest assertions");
  }
  const selected = degraded ? manifest.degradedCases : manifest.cases;
  context.assert(selected.length > 0, "empty trace gate");
  for (const mode of ["assertions-2/", "assertions-0/"]) {
    context.assert(selected.some(row => row.image.startsWith(mode)), "manifest omitted " + mode);
  }
  const webkit = context.engine === "webkit";
  const firefox = context.engine === "firefox";
  let nativeExecutions = 0;
  let recordCost = !degraded;
  for (const row of selected) {
    nativeExecutions += await executeRow(context, row, degraded, recordCost, manifest.profile);
    recordCost = false;
    await context.tick();
    await context.gc();
  }
  const emit = record => context.stdout(encoder.encode(JSON.stringify({engine: context.engine, ...record}) + "\n"));
  emit({verdict:"PASS", degraded, manifestCases:selected.length, nativeExecutions,
    fidelity:webkit ? "function-level/no-line; 512-record capacity" : firefox ? "file/line; 128-frame engine ceiling" : "file/line; 512-record capacity"});
}

async function executeRow(context, row, degraded, recordCost, profile) {
  // The installation profile is required: a missing or unknown value must not
  // silently weaken a production program row into the exact contract.
  context.assert(profile === "production" || profile === "validation",
    "invalid trace manifest profile");
  const emit = record => context.stdout(encoder.encode(JSON.stringify({engine: context.engine, ...record}) + "\n"));
  const webkit = context.engine === "webkit";
  const firefox = context.engine === "firefox";
  // A production program image inlines, as native production does, so its
  // Titan frames may be absent; whatever survives must still be an ordered
  // subsequence of the exact expectation with the exact file and line (D28).
  // Test images and the validation profile stay exact.
  const orderedSubsequence = profile === "production" && row.program === true;

  // Titan frames with the attribution the contract compares: file, execution
  // line and name. WebKit's documented no-line form compares file only.
  function titanFrameLines(trace) {
    const frames = [];
    for (const line of trace.split("\n")) {
      const match = /^([^:\n]+\.titan)(?::([0-9]+))?: in (.+)$/.exec(line);
      if (match) frames.push({file: match[1],
        line: match[2] === undefined ? undefined : Number(match[2]),
        name: match[3], text: line});
    }
    return frames;
  }

  // Lines the program-row grammar accepts besides Titan frames: `[C]` frames,
  // Lua frames from the fixture's loaded-Lua shapes, and the documented
  // truncation marker. Anything else must be a parsed Titan frame.
  function acceptedNonTitan(line) {
    return line.startsWith("[C]:") || /^[^:\n]+\.lua(?::[0-9]+)?: in /.test(line) ||
      line === unavailable || line === captureFailed || line === truncated;
  }

  function exactFrame(file, line, name) {
    return `${file}:${webkit ? "" : line + ":"} in ${name}`;
  }
  function exactLine(trace, expected) {
    context.assert(trace.split("\n").includes(expected), "missing engine-specific frame " + expected + "\n" + trace);
    return expected;
  }
  function exact(trace, file, line, name) {
    return exactLine(trace, exactFrame(file, line, name));
  }
  // Program rows: their own exact frames, innermost first, ending at the
  // entry, and the only frames that may follow it. A main run as the async
  // bootstrap Task (titan#334, D14) is followed by the async runtime: the
  // bootstrap and Task-root closures, the coroutine entry and the driver that
  // resumed the Task. Their lines are the runtime's own, so they match by
  // file and name; a production image may drop or rename them within this
  // set when it inlines (D28).
  const asyncRuntimeFiles = new Set(["async.titan", "coroutine.titan", "runtime.browser.titan"]);
  const asyncRuntimeNames = new Set(["titan.async.bootstrap", "titan.async.loop", "titan.async.drain_ready",
    "titan.async.advance_task", "titan.async.resume_root", "titan.coroutine.coro_entry",
    "titan.coroutine.coro_entry_trampoline"]);
  const asyncRuntimeFrame = frame => asyncRuntimeFiles.has(frame.file) &&
    (asyncRuntimeNames.has(frame.name) || /^anonymous function at (?:.*[/\\])?async[.]titan:[0-9]+$/.test(frame.name));
  // D23: a production image may inline minicoro's C titan_coroutine_enter into
  // the coroutine trampoline. Its frame then shows that C callee's own
  // location under the trampoline's name, the inlining rendering of D32 with
  // a C callee, and carries a line exactly where Titan frames do.
  const inlinedRuntimeC = /^(minicoro[.]c)(?::([0-9]+))?: in (titan[.]coroutine[.]coro_entry_trampoline)$/;
  function inlinedRuntimeFrame(line) {
    const match = inlinedRuntimeC.exec(line);
    if (!match || (webkit ? match[2] !== undefined : !(Number(match[2]) > 0))) return undefined;
    return {file: match[1], line: match[2] === undefined ? undefined : Number(match[2]), name: match[3], text: line};
  }
  const programs = {
    uncaught: {file: "trace_uncaught.titan", entry: "trace_uncaught.main", inlinedC: false,
      trailing: () => false, frames: [
        ["trace_uncaught.titan", 4, "trace_uncaught.uncaught_leaf"],
        ["trace_uncaught.titan", 8, "trace_uncaught.uncaught_middle"],
        ["trace_uncaught.titan", 16, "trace_uncaught.main"],
      ]},
    async_uncaught: {file: "trace_async.titan", entry: "trace_async.main", inlinedC: true,
      trailing: frame => asyncRuntimeFrame(frame) || frame.file === "minicoro.c", frames: [
        ["trace_async.titan", 7, "trace_async.async_leaf"],
        ["trace_async.titan", 11, "trace_async.async_middle"],
        ["trace_async.titan", 16, "trace_async.main"],
      ]},
  };
  // The program-row oracle: the first way `trace` breaks the contract, or
  // undefined. Every line is a Titan frame, a `[C]` or Lua frame, or a
  // documented marker; a production async row may also show the D23 frame.
  // The program's own frames come first and end at its entry, which is
  // called from C or by the async bootstrap through a function value and so
  // is never inlined away; only `program.trailing` frames follow. Test images
  // and the validation profile show every own frame exactly, in order. A
  // production image may keep fewer of them, in this order, and an inlined
  // callee keeps its own physical line under the surviving enclosing
  // function's name, exactly as native production does (D28, D32).
  function programViolation(program, trace) {
    const shown = [], unexplained = [];
    for (const line of trace.split("\n")) {
      const frame = titanFrameLines(line)[0] ||
        (program.inlinedC && orderedSubsequence ? inlinedRuntimeFrame(line) : undefined);
      if (frame) shown.push(frame);
      else if (line.length > 0 && !acceptedNonTitan(line)) unexplained.push(line);
    }
    if (unexplained.length > 0) return "program trace has unparsed lines: " + unexplained.join(" | ");
    const count = shown.findIndex(frame => frame.file !== program.file);
    const ownFrames = shown.slice(0, count < 0 ? shown.length : count);
    if (ownFrames.length === 0) return "program trace does not start with its own frames";
    const outside = shown.slice(ownFrames.length).find(frame => !program.trailing(frame));
    if (outside) return "program trace has a frame outside its expectation: " + outside.text;
    if (ownFrames.at(-1).name !== program.entry) return "program trace omitted the entry frame " + program.entry;
    if (!orderedSubsequence) {
      const expected = program.frames.map(([file, line, name]) => exactFrame(file, line, name));
      if (ownFrames.length !== expected.length || ownFrames.some((frame, index) => frame.text !== expected[index])) {
        return "program frames are not exactly " + expected.join(" | ");
      }
      return undefined;
    }
    let next = 0;
    for (const frame of ownFrames) {
      const index = program.frames.findIndex(([file, line], position) =>
        position >= next && frame.file === file && frame.line === (webkit ? undefined : line));
      if (index < 0) return "program frame outside the exact expectation: " + frame.text;
      // The surviving name is either the matched frame's own name or one of
      // the enclosing callers it was inlined into, which are exactly the
      // later expected frames.
      if (!program.frames.slice(index).some(([, , name]) => name === frame.name)) {
        return "program frame name is not the matched frame or an enclosing caller: " + frame.text;
      }
      next = index + 1;
    }
    return undefined;
  }
  function checkTrace(label, trace, missingSymbols) {
    let currentStateTrace = trace;
    if (label === "nested_outer") {
      // Only these parent-runner frames are absent from the capturing state's
      // names table. D15 requires their exact raw fallbacks, not a blanket
      // exception for nested traces or arbitrary mangled function names. The
      // generated runner numbers the sorted cases, so adding a case before
      // test_nested_capture or anywhere in the list moves these (and the
      // matching pair in trace_support.c).
      const parentLines = new Set();
      for (const [line, symbol] of [[113, "titan_test_runner_ℳ_run_test_28_titan"],
                                    [239, "titan_test_runner_ℳ_main_titan"]]) {
        parentLines.add(exact(trace, "trace_cases__test_runner.titan", line, symbol));
        context.assert(frameCount(trace, ": in " + symbol) === 1,
          "nested trace duplicated/omitted parent raw fallback " + symbol);
      }
      currentStateTrace = trace.split("\n").filter(line => !parentLines.has(line)).join("\n");
    }
    context.assert(!/titanentry|_titan|wasm-function|\b0x[0-9a-f]|:0: in|dynCall_|trace_support\.c:/.test(currentStateTrace),
      "trace exposed internal/false location: " + label + "\n" + trace);
    for (const line of trace.split("\n")) {
      const match = /^([^:\n]+\.titan)(?::([0-9]+))?: in /.exec(line);
      if (match) context.assert(webkit ? match[2] === undefined : Number(match[2]) > 0,
        "wrong execution-line fidelity on " + context.engine + ": " + line);
    }
    if (label === "nested_held") {
      context.assert(occurrences(trace, captureFailed) === 1, "nested capture did not use one fallback marker");
      return;
    }
    if (label === "host_failed" || label === "lua_fallback_failed" || label.startsWith("degraded")) return;
    context.assert(!trace.includes(unavailable) && !trace.includes(captureFailed), "positive trace degraded: " + label);
    const program = programs[label];
    if (program) {
      const violation = programViolation(program, trace);
      context.assert(violation === undefined, violation + "\n" + trace);
      if (orderedSubsequence) {
        emit({programFrames: titanFrameLines(trace).filter(frame => frame.file === program.file).map(frame => frame.text),
          expectedFrames: program.frames.map(([file, line, name]) => exactFrame(file, line, name))});
      }
      // Oracle negatives: the same trace without its entry frame, with an
      // unrelated Titan frame after its last one, or with the D23 C location
      // under any other runtime name, must be rejected.
      const lines = trace.split("\n");
      const last = lines.findLastIndex(line => titanFrameLines(line).length > 0);
      const appended = extra => [...lines.slice(0, last + 1), extra, ...lines.slice(last + 1)].join("\n");
      const negatives = {
        "a trace without its entry frame": lines.filter(line => !line.endsWith(": in " + program.entry)).join("\n"),
        "an unrelated trailing Titan frame": appended(exactFrame("unrelated.titan", 1, "unrelated.saved_resumer")),
        "an inlined C location under another runtime name": appended(
          `minicoro.c:${webkit ? "" : "66:"} in titan.async.loop`),
      };
      for (const [what, mutated] of Object.entries(negatives)) {
        context.assert(programViolation(program, mutated) !== undefined, `${label} oracle accepted ${what}:\n${mutated}`);
      }
      emit({programOracle: label, negativesRejected: Object.keys(negatives).length});
      return;
    }
    if (missingSymbols) {
      exact(trace, "trace_cases.titan", 80, "?");
      return;
    }
    if (["direct", "host_ready", "host_recovered", "fiber_before", "fiber_after", "fiber_after_sleep"].includes(label)) {
      exact(trace, "trace_cases.titan", 80, "trace_cases.original_leaf");
      exact(trace, "trace_cases.titan", 84, "trace_cases.direct_middle");
      exact(trace, "trace_cases.titan", 88, "trace_cases.direct_outer");
    }
    if (label === "selected" || label.startsWith("selected_fiber_")) {
      exact(trace, "locations.browser.titan", 2, "trace_cases.selected_leaf");
      exact(trace, "locations.browser.titan", 6, "trace_cases.selected_outer");
    }
    if (label.startsWith("fiber_") || label.startsWith("selected_fiber_")) {
      context.assert(!trace.includes("in trace_cases.test_") && !trace.includes("in titan.test."),
        "in-fiber trace included saved resumer/test-runner history: " + label + "\n" + trace);
    }
    // Post-suspension traces in async Tasks (titan#334, tasks.browser.titan):
    // the same exact frames after turn and wait relinquishes, in a delivered
    // handler, through an async.Error handoff and in a cancellation cleanup;
    // and across entries: a Task-form call failing after a turn, and a call
    // and a notification failing where the driver delivers them.
    if (["task_after_turn", "task_after_timer", "task_after_request", "task_after_channel",
         "delivered_handler", "task_handoff", "task_cleanup",
         "entry_task", "entry_call", "entry_notify"].includes(label)) {
      exact(trace, "trace_cases.titan", 80, "trace_cases.original_leaf");
      exact(trace, "trace_cases.titan", 84, "trace_cases.direct_middle");
      exact(trace, "trace_cases.titan", 88, "trace_cases.direct_outer");
    }
    if (label.startsWith("task_after_") || label.startsWith("entry_")) {
      context.assert(!trace.includes("in trace_cases.test_") && !trace.includes("in titan.test."),
        "Task or entry trace included saved resumer/test-runner history: " + label + "\n" + trace);
    }
    if (label === "task_rethrow") exact(trace, "trace_cases.titan", 80, "trace_cases.original_leaf");
    if (label === "task_fresh") exact(trace, "tasks.browser.titan", 194, "trace_cases.fresh_after_await");
    if (label === "task_append") exact(trace, "coroutines.titan", 42, "trace_cases.resumed_leaf");
    if (label === "lambda") context.assert(new RegExp("^wrappers[.]titan:" + (webkit ? "" : "108:") +
      " in anonymous function at (?:.*[/\\\\])?wrappers[.]titan:107$", "m").test(trace), "lambda execution/definition locations changed");
    if (label === "fresh") exact(trace, "errors.titan", 14, "trace_cases.fresh_raise");
    if (label === "literal") {
      context.assert(frameCount(trace, ": in trace_cases.literal_call") === 1 &&
        frameCount(trace, "wrappers.titan:122") === 0, "literal acquired a fabricated activation");
    }
    if (label.startsWith("depth_")) {
      const depth = Number(label.slice(6));
      const count = frameCount(trace, ": in trace_cases.recurse");
      if (depth === 48) {
        context.assert(count === 49, "ordinary deep trace omitted/duplicated recursion frames");
        for (const name of ["original_leaf", "recursive_trace", "test_recursion_beyond_ten"]) {
          context.assert(frameCount(trace, ": in trace_cases." + name) === 1,
            "ordinary deep trace omitted/duplicated " + name);
        }
        context.assert(!trace.includes(truncated), "ordinary deep trace was spuriously truncated");
      } else if (firefox) {
        context.assert(count >= 40 && count < 128 && occurrences(trace, truncated) === 1,
          "engine-ceiling trace was not bounded/marked");
      } else if (depth === 460) {
        context.assert(count === 461 && !trace.includes(truncated), "near512 real capture was incomplete");
      } else context.assert(count >= 450 && count < 512 && occurrences(trace, truncated) === 1,
        "capacity trace was not bounded/marked");
      emit({depth, retainedTitanRecursions: count, truncated: trace.includes(truncated)});
    }
    if (label === "mixed_depth_90") {
      const count = frameCount(trace, ": in trace_cases.mixed_recurse");
      context.assert(count <= 91, "mixed trace duplicated recursive frames");
      if (count < 91) context.assert(occurrences(trace, truncated) === 1, "mixed JS headroom cut was not marked");
      emit({mixedDepth: 90, retainedTitanRecursions: count, truncated: trace.includes(truncated)});
    }
    if (label === "mixed_overflow" || label === "pcall_overflow") {
      // Mirrors the native arms: the mixed chain keeps recursion activations,
      // while the pcall chain unwinds them and keeps the protected chunk.
      const mixed = label === "mixed_overflow";
      const count = frameCount(trace, ": in trace_cases.mixed_overflow_step");
      context.assert(!trace.includes(captureFailed) && !trace.includes(unavailable),
        "overflow trace lost its capture: " + label);
      if (mixed) context.assert(count >= 10, "overflow trace omitted the recursion: " + label);
      else context.assert(trace.includes("trace-pcall.lua"),
        "overflow trace omitted the protected call: " + label);
      context.assert(occurrences(trace, truncated) <= 1, "overflow trace has duplicate truncation markers");
      emit({overflow: label, retainedTitanRecursions: count, truncated: trace.includes(truncated)});
    }
    if (label === "append") {
      for (const name of ["original_leaf", "resumed_leaf", "append_middle", "append_outer", "test_coroutine_propagation_append"]) {
        context.assert(frameCount(trace, ": in trace_cases." + name) === 1,
          "coroutine append duplicated/omitted " + name);
      }
    }
  }

  let nativeExecutions = 0;
  async function execute(row) {
    const image = await context.image(row.image);
    const originalConstructor = own(globalThis, "Error");
    const originalLimit = own(Error, "stackTraceLimit");
    const originalPrepare = own(Error, "prepareStackTrace");
    const originalFetch = own(globalThis, "fetch");
    const originalWarn = console.warn;
    const originalError = console.error;
    let controls, output = "", stderr = "", hostCalls = 0, fetchCalls = 0, located = 0, warnings = 0, recoveries = 0;
    let expectedLimit, expectedPrepare, targets, releaseHold;
    const notificationErrors = [];
    const suffix = row.name.split(".").at(-1);
    const hostMode = suffix;
    const notice = values => { warnings += values.reduce((sum, value) => sum + occurrences(String(value), "Titan browser trace: "), 0); };
    console.warn = (...values) => { notice(values); originalWarn.apply(console, values); };
    console.error = (...values) => { notice(values); originalError.apply(console, values); };
    const instance = image.create({
      bindings: {
        __traceTest(value) { controls = value; },
        traceFixtureRestoreDescriptors() {
          context.assert(equalDescriptor(own(Error, "stackTraceLimit"), expectedLimit) &&
            equalDescriptor(own(Error, "prepareStackTrace"), expectedPrepare), "failed capture did not restore descriptors before recovery");
          restore(Error, "stackTraceLimit", originalLimit);
          restore(Error, "prepareStackTrace", originalPrepare);
          expectedLimit = own(Error, "stackTraceLimit"); expectedPrepare = own(Error, "prepareStackTrace");
          recoveries++;
        },
        // test_task_entry_targets publishes its targets; hold awaits traceHold.
        traceTaskTargets(...callables) { targets = callables; },
        traceHold() { return {kind: "detachable", promise: new Promise(resolve => { releaseHold = resolve; })}; },
      },
      onNotificationError(event) { notificationErrors.push(event); },
      locateFile(name) { located++; return image.locateFile(name); },
      stdout(chunk) { output += decoder.decode(chunk, {stream:true}); context.stdout(chunk); },
      stderr(chunk) { stderr += decoder.decode(chunk, {stream:true}); context.stderr(chunk); },
    });
    async function rejected(promise) {
      try { await promise; } catch (error) { return error; }
      context.assert(false, "a failing entry resolved");
    }
    async function until(predicate, message) {
      for (let attempt = 0; attempt < 200 && !predicate(); attempt++) await context.tick();
      context.assert(predicate(), message);
    }
    // A failed entry carries Titan's error data and the raw trace (titan#334).
    function checkEntry(label, error) {
      context.assert(error?.code === "TITAN_BROWSER_TITAN" && error.status === 1 &&
        decoder.decode(error.bytes) === "trace-original" && error.trace instanceof Uint8Array,
        label + " lost its Titan error data: " + error?.code + " " + error?.message);
      const trace = decoder.decode(error.trace);
      context.stdout(encoder.encode(`TRACE-BEGIN ${label}\n${trace}\nTRACE-END ${label}\n`));
      checkTrace(label, trace, false);
    }
    // After the case: a Task-form call that fails after a turn, then a call
    // and a notification that fail where the driver delivers them, during a
    // drive held on a JavaScript request.
    async function entries() {
      context.assert(Array.isArray(targets) && targets.length === 3, "trace fixture did not publish its entry targets");
      const [failAfterTurn, failDirect, hold] = targets;
      // The failed Task-form call is also reported as an uncaught Task error,
      // which the operation delivers to the stderr sink before it settles.
      const before = stderr.length;
      context.stderr(encoder.encode("BEGIN expected uncaught async Task diagnostics\n"));
      checkEntry("entry_task", await rejected(failAfterTurn.callTask([])));
      context.assert(occurrences(stderr.slice(before), "uncaught error in async Task: trace-original\n") === 1,
        "the failed Task-form call was not reported once as an uncaught Task error");
      context.stderr(encoder.encode("END expected uncaught async Task diagnostics\n"));
      const holding = hold.callTask([]);
      await until(() => releaseHold !== undefined, "the held Task never started its request");
      const queued = rejected(instance.call(failDirect));
      instance.notify(failDirect);
      checkEntry("entry_call", await queued);
      await until(() => notificationErrors.length > 0, "the driver did not deliver the failing notification");
      releaseHold();
      context.assert(await holding === null, "the held Task-form call did not return nil");
      context.assert(notificationErrors.length === 1 && notificationErrors[0].kind === "callback" &&
        notificationErrors[0].operation === "callTask", "the failing notification was not reported once from its drive");
      checkEntry("entry_notify", notificationErrors[0].error);
    }
    try {
      await instance.initialize();
      context.assert(controls, "trace fixture did not publish its test-owned observations");
      const metadata = controls.metadata();
      context.assert(metadata && metadata.state === (degraded ? "degraded" : "ready"), "missing/wrong eager trace readiness");
      context.assert(degraded ? typeof metadata.reason === "string" : metadata.reason === null, "invalid readiness reason");
      context.assert(warnings + occurrences(stderr, "Titan browser trace: ") === (degraded ? 1 : 0), "map load did not warn exactly once per degraded instance");
      if (recordCost && !degraded) {
        const wasm = await context.bytes(row.image.replace(/\.mjs$/, ".wasm"));
        const map = await context.bytes(row.image.replace(/\.mjs$/, ".wasm.map"));
        context.assert(Number.isFinite(metadata.loadMilliseconds) && metadata.loadMilliseconds >= 0 &&
          Number.isSafeInteger(metadata.mapBytes) && metadata.mapBytes === map.length &&
          Number.isSafeInteger(metadata.indexBytes) && metadata.indexBytes > 0, "invalid trace cost metadata");
        emit({traceCost: {wasmBytes: wasm.length, mapBytes: map.length, mapToWasmRatio: map.length / wasm.length,
          loadMilliseconds: metadata.loadMilliseconds, retainedTypedArrayBytes: metadata.indexBytes}});
      }
      if (hostMode === "host_limit_small") Object.defineProperty(Error, "stackTraceLimit", {value:1, writable:true, configurable:true, enumerable:false});
      if (hostMode === "host_limit_absent") context.assert(Reflect.deleteProperty(Error, "stackTraceLimit"), "cannot remove configurable stack limit");
      if (hostMode === "host_limit_accessor") Object.defineProperty(Error, "stackTraceLimit", {
        get() { hostCalls++; throw new Error("stack limit getter invoked"); },
        set() { hostCalls++; throw new Error("stack limit setter invoked"); }, configurable:true, enumerable:true});
      if (hostMode === "host_prepare_callback" || hostMode === "host_limit_absent") Object.defineProperty(Error, "prepareStackTrace", {
        value() { hostCalls++; throw new Error("host stack formatter invoked"); }, writable:true, configurable:true, enumerable:false});
      if (hostMode === "host_prepare_accessor" || hostMode === "host_lua_fallback_capacity") Object.defineProperty(Error, "prepareStackTrace", {
        get() { hostCalls++; throw new Error("stack formatter getter invoked"); },
        set() { hostCalls++; throw new Error("stack formatter setter invoked"); }, configurable:true, enumerable:true});
      expectedLimit = own(Error, "stackTraceLimit"); expectedPrepare = own(Error, "prepareStackTrace");
      const locatedBefore = located;
      if (originalFetch && typeof originalFetch.value === "function") Object.defineProperty(globalThis, "fetch", {
        ...originalFetch, value(...args) { fetchCalls++; return originalFetch.value.apply(this, args); }});
      const result = await instance.run(row.args);
      if (suffix === "task_entries") await entries();
      await instance.dispose();
      context.assert(notificationErrors.length === (suffix === "task_entries" ? 1 : 0),
        "unexpected notification errors: " + notificationErrors.map(event => event.kind + "/" + event.operation).join(", "));
      context.assert(equalDescriptor(own(Error, "stackTraceLimit"), expectedLimit) &&
        equalDescriptor(own(Error, "prepareStackTrace"), expectedPrepare), "capture did not restore exact own descriptors");
      context.assert(equalDescriptor(own(globalThis, "Error"), originalConstructor), "Error constructor identity changed");
      context.assert(hostMode !== "host_limit_absent" || own(Error, "stackTraceLimit") === undefined,
        "absent stack limit became an own property");
      context.assert(hostCalls === 0, "trace capture invoked host stack callbacks/accessors");
      context.assert(recoveries === (["host_prepare_accessor", "host_lua_fallback_capacity"].includes(hostMode) ? 1 : 0), "wrong same-instance recovery count");
      context.assert(fetchCalls === 0 && located === locatedBefore, "error path fetched/located an asset");
      context.assert(result.kind === row.kind && result.status === row.status,
        `wrong outcome for ${row.name}: ${result.kind}/${result.status}, expected ${row.kind}/${row.status}`);
      if (row.testCount) {
        const plural = row.testCount === 1 ? "test" : "tests";
        context.assert(output.includes(`[==========] ${row.testCount} ${plural} ran.`) &&
          output.includes(`[  PASSED  ] ${row.testCount} ${plural}.`) &&
          occurrences(output, "[ RUN      ] ") === row.testCount, "wrong native case count/pass summary for " + row.name);
        nativeExecutions += row.testCount;
        const traces = frames(output);
        for (const {label, trace} of traces) checkTrace(label, trace, suffix === "missing_symbols");
        // task_entries checks its entries' traces in entries().
        const noTraceCases = ["test_public_backtrace_and_pin", "test_caught_trace_clearing", "task_entries"];
        context.assert(traces.length > 0 || noTraceCases.includes(suffix), "native trace fixture emitted no evidence");
      } else if (suffix === "async_uncaught") {
        // D14: the uncaught-Task report is the only stderr report, and run()
        // returns that report's message and trace.
        const trace = decoder.decode(result.trace);
        context.assert(decoder.decode(result.bytes) === "trace-async-original", "async main failure replaced its payload");
        context.assert(stderr === "uncaught error in async Task: trace-async-original\nstack traceback:\n" + trace + "\n",
          "async main stderr is not exactly the Task report of run()'s trace:\n" + stderr);
        checkTrace("async_uncaught", trace, false);
      } else {
        context.assert(decoder.decode(result.bytes) === "trace-uncaught-original", "uncaught completion replaced original payload");
        const raw = stderr.split("\n").filter(line => line.startsWith("\t")).map(line => line.slice(1)).join("\n");
        checkTrace("uncaught", raw, false);
        context.assert(occurrences(stderr, "TRACE uncaught cleanup=1") === 1, "uncaught cleanup repeated");
      }
      for (const required of row.stderrContains) context.assert(stderr.includes(required), "missing required stderr: " + required);
      context.assert(warnings + occurrences(stderr, "Titan browser trace: ") === (degraded ? 1 : 0), "error path repeated degraded warning");
      emit({case:row.name, recoveries, kind:result.kind, status:result.status, nativeCases:row.testCount,
        descriptorCalls:hostCalls, errorPathFetches:fetchCalls, errorPathAssetLookups:located-locatedBefore,
        limitAbsent:hostMode === "host_limit_absent" ? own(Error, "stackTraceLimit") === undefined : null});
    } finally {
      restore(Error, "stackTraceLimit", originalLimit);
      restore(Error, "prepareStackTrace", originalPrepare);
      restore(globalThis, "fetch", originalFetch);
      console.warn = originalWarn; console.error = originalError;
      await instance.dispose();
      controls = undefined;
    }
  }
  await execute(row);
  return nativeExecutions;
}
