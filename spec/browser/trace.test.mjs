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
function terminalMarker(trace, marker, allowed) {
  const found = trace.indexOf(marker);
  if (found < 0) return true;
  if (!allowed || (found !== 0 && trace[found - 1] !== "\n")) return false;
  const end = found + marker.length;
  return end === trace.length || (trace[end] === "\n" && end + 1 === trace.length);
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
    nativeExecutions += webkit && row.name.endsWith(".host_limit_absent")
      ? await executeIsolatedRow(context, row, degraded, recordCost, manifest.profile)
      : await executeRow(context, row, degraded, recordCost, false, manifest.profile);
    recordCost = false;
    await context.tick();
    await context.gc();
  }
  const emit = record => context.stdout(encoder.encode(JSON.stringify({engine: context.engine, ...record}) + "\n"));
  emit({verdict:"PASS", degraded, manifestCases:selected.length, nativeExecutions,
    fidelity:webkit ? "function-level/no-line; 100-frame engine ceiling" : firefox ? "file/line; 128-frame engine ceiling" : "file/line; 512-record capacity"});
}

export async function executeRow(context, row, degraded, recordCost, isolated = false,
    profile) {
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
  function checkTrace(label, trace, missingSymbols) {
    let currentStateTrace = trace;
    if (label === "nested_outer") {
      // Only these parent-runner frames are absent from the capturing state's
      // names table. D15 requires their exact raw fallbacks, not a blanket
      // exception for nested traces or arbitrary mangled function names.
      const parentLines = new Set();
      for (const [line, symbol] of [[109, "titan_test_runner_ℳ_run_test_27_titan"],
                                    [189, "titan_test_runner_ℳ_main_titan"]]) {
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
    if (label === "host_absent") {
      const count = trace.split("\n").filter(line => line.includes(": in ")).length;
      context.assert(webkit && occurrences(trace, captureFailed) === 1 &&
        terminalMarker(trace, captureFailed, true) && !trace.includes(unavailable) &&
        !trace.includes(truncated) && !trace.includes(".titan:") && count > 0 && count <= 512,
        "absent JSC limit did not retain a bounded Lua-only capture-failed trace");
      return;
    }
    if (label === "host_failed" || label === "lua_fallback_failed" || label.startsWith("degraded")) return;
    context.assert(!trace.includes(unavailable) && !trace.includes(captureFailed), "positive trace degraded: " + label);
    if (label === "uncaught") {
      // The row's exact frames, as the validation profile renders them. A
      // production program image may keep fewer of them, in this order, and
      // an inlined callee keeps its own physical line under the surviving
      // enclosing function's name, exactly as native production does (D28).
      const uncaughtFrames = [
        ["trace_uncaught.titan", 4, "trace_uncaught.uncaught_leaf"],
        ["trace_uncaught.titan", 8, "trace_uncaught.uncaught_middle"],
        ["trace_uncaught.titan", 16, "trace_uncaught.main"],
      ];
      if (orderedSubsequence) {
        const shown = titanFrameLines(trace);
        const lines = trace.split("\n").filter(line => line.length > 0);
        const titanTexts = new Set(shown.map(frame => frame.text));
        const unexplained = lines.filter(line => !titanTexts.has(line) && !acceptedNonTitan(line));
        context.assert(unexplained.length === 0,
          "program trace has unparsed lines: " + unexplained.join(" | ") + "\n" + trace);
        // The program entry is called from C and cannot be inlined away, so a
        // production program row always shows at least one Titan frame and the
        // outermost of them is the entry frame.
        context.assert(shown.length > 0, "program trace showed no Titan frame:\n" + trace);
        context.assert(shown.at(-1).name === "trace_uncaught.main",
          "program trace omitted the entry frame trace_uncaught.main:\n" + trace);
        let next = 0;
        for (const frame of shown) {
          const index = uncaughtFrames.findIndex(([file, line], position) =>
            position >= next && frame.file === file && frame.line === (webkit ? undefined : line));
          context.assert(index >= 0,
            "program frame outside the exact expectation: " + frame.text + "\n" + trace);
          // The surviving name is either the matched frame's own name or one
          // of the enclosing callers it was inlined into, which are exactly
          // the later expected frames (D32).
          const enclosing = uncaughtFrames.slice(index).map(([, , name]) => name);
          context.assert(enclosing.includes(frame.name),
            "program frame name is not the matched frame or an enclosing caller: " +
            frame.text + "\n" + trace);
          next = index + 1;
        }
        emit({programFrames: shown.map(frame => frame.text),
          expectedFrames: uncaughtFrames.map(([file, line, name]) => exactFrame(file, line, name))});
      } else {
        for (const [file, line, name] of uncaughtFrames.slice(0, 2)) exact(trace, file, line, name);
        for (const name of ["uncaught_leaf", "uncaught_middle"]) {
          context.assert(frameCount(trace, ": in trace_uncaught." + name) === 1,
            "uncaught report duplicated/omitted " + name);
        }
      }
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
        context.assert(terminalMarker(trace, truncated, webkit), "ordinary deep trace has invalid engine truncation");
      } else if (webkit || firefox) {
        context.assert(count >= 40 && count < (webkit ? 100 : 128) && occurrences(trace, truncated) === 1,
          "engine-ceiling trace was not bounded/marked");
      } else if (depth === 460) {
        context.assert(count === 461 && !trace.includes(truncated), "near512 real V8 capture was incomplete");
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
    let module, output = "", stderr = "", hostCalls = 0, fetchCalls = 0, located = 0, warnings = 0, recoveries = 0;
    let expectedLimit, expectedPrepare;
    const suffix = row.name.split(".").at(-1);
    const hostMode = suffix;
    const notice = values => { warnings += values.reduce((sum, value) => sum + occurrences(String(value), "Titan browser trace: "), 0); };
    console.warn = (...values) => { notice(values); originalWarn.apply(console, values); };
    console.error = (...values) => { notice(values); originalError.apply(console, values); };
    const factory = async options => {
      module = await image.factory(options);
      module['traceFixtureWebKit'] = webkit;
      module['traceFixtureAbsentLimit'] = webkit && hostMode === "host_limit_absent";
      return module;
    };
    const instance = context.create(factory, {
      locateFile(name) { located++; return image.locateFile(name); },
      stdout(chunk) { output += decoder.decode(chunk, {stream:true}); context.stdout(chunk); },
      stderr(chunk) { stderr += decoder.decode(chunk, {stream:true}); context.stderr(chunk); },
    });
    try {
      await instance.initialize();
      context.assert(!isolated || (module.HEAPU8 instanceof Uint8Array && instance.run instanceof Function),
        "isolated image and loader did not execute in their own realm");
      const metadata = module.titanBrowserTrace;
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
      module['traceFixtureRestoreDescriptors'] = () => {
        context.assert(equalDescriptor(own(Error, "stackTraceLimit"), expectedLimit) &&
          equalDescriptor(own(Error, "prepareStackTrace"), expectedPrepare), "failed capture did not restore descriptors before recovery");
        restore(Error, "stackTraceLimit", originalLimit);
        restore(Error, "prepareStackTrace", originalPrepare);
        expectedLimit = own(Error, "stackTraceLimit"); expectedPrepare = own(Error, "prepareStackTrace");
        recoveries++;
      };
      const locatedBefore = located;
      if (originalFetch && typeof originalFetch.value === "function") Object.defineProperty(globalThis, "fetch", {
        ...originalFetch, value(...args) { fetchCalls++; return originalFetch.value.apply(this, args); }});
      const result = await instance.run(row.args);
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
        const noTraceCases = ["test_public_backtrace_and_pin", "test_caught_trace_clearing"];
        context.assert(traces.length > 0 || noTraceCases.includes(suffix), "native trace fixture emitted no evidence");
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
        isolatedRealm:isolated, limitAbsent:hostMode === "host_limit_absent" ? own(Error, "stackTraceLimit") === undefined : null});
    } finally {
      restore(Error, "stackTraceLimit", originalLimit);
      restore(Error, "prepareStackTrace", originalPrepare);
      restore(globalThis, "fetch", originalFetch);
      console.warn = originalWarn; console.error = originalError;
      await instance.dispose();
      module = undefined;
    }
  }
  await execute(row);
  return nativeExecutions;
}

async function executeIsolatedRow(context, row, degraded, recordCost, profile) {
  const originalConstructor = own(globalThis, "Error");
  const originalLimit = own(Error, "stackTraceLimit");
  const originalPrepare = own(Error, "prepareStackTrace");
  context.assert(typeof new Error().stack === "string", "parent realm lost native stack capture before isolated row");
  const frame = document.createElement("iframe");
  frame.hidden = true;
  const loaded = new Promise(resolve => frame.addEventListener("load", resolve, {once:true}));
  frame.src = "about:blank";
  document.body.append(frame);
  try {
    await loaded;
    return await new Promise((resolve, reject) => {
      const child = frame.contentWindow;
      child.addEventListener("error", event => {
        event.preventDefault();
        reject(event.error ?? new Error(event.message));
      });
      child.addEventListener("unhandledrejection", event => {
        event.preventDefault();
        reject(event.reason);
      });
      child.traceFixtureRealm = {engine:context.engine, row, degraded, recordCost, profile, resolve, reject,
        root:new URL("./", import.meta.url).href,
        sdk:new URL("/sdk/titan-browser.mjs", import.meta.url).href,
        page:new URL("/sdk/titan-browser-page.mjs", import.meta.url).href,
        stdout:chunk => context.stdout(new Uint8Array(chunk)),
        stderr:chunk => context.stderr(new Uint8Array(chunk))};
      const script = frame.contentDocument.createElement("script");
      script.type = "module";
      script.addEventListener("error", () => reject(new Error("cannot import isolated trace gate")), {once:true});
      script.textContent = `import {runInRealm} from ${JSON.stringify(import.meta.url)};` +
        "const bridge = globalThis.traceFixtureRealm;" +
        "runInRealm(bridge).then(bridge.resolve, bridge.reject);";
      frame.contentDocument.body.append(script);
    });
  } finally {
    frame.remove();
    context.assert(equalDescriptor(own(globalThis, "Error"), originalConstructor) &&
      equalDescriptor(own(Error, "stackTraceLimit"), originalLimit) &&
      equalDescriptor(own(Error, "prepareStackTrace"), originalPrepare),
      "isolated row changed parent Error descriptors");
    context.assert(typeof new Error().stack === "string", "isolated row poisoned parent native capture");
  }
}

export async function runInRealm(bridge) {
  const {create} = await import(bridge.sdk);
  const {observeFactory, relativePath} = await import(bridge.page);
  const url = path => new URL(relativePath(path).split("/").map(encodeURIComponent).join("/"), bridge.root).href;
  const context = Object.freeze({engine:bridge.engine, create, stdout:bridge.stdout, stderr:bridge.stderr,
    assert(condition, message = "assertion failed") {
      if (!condition) throw new Error(message);
    },
    async image(path) {
      const imageUrl = url(path);
      const {default:factory} = await import(imageUrl);
      if (typeof factory !== "function") throw new Error("isolated image must export a factory");
      return Object.freeze({
        factory:observeFactory(factory, message => {
          throw new Error(`isolated image ${message.type}: ${message.reason}`);
        }, bridge.degraded),
        locateFile:name => new URL(name.split("/").map(encodeURIComponent).join("/"), imageUrl).href});
    },
    async bytes(path) {
      const response = await fetch(url(path));
      if (!response.ok) throw new Error(`cannot read isolated asset ${path}: HTTP ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    }});
  return executeRow(context, bridge.row, bridge.degraded, bridge.recordCost, true, bridge.profile);
}
