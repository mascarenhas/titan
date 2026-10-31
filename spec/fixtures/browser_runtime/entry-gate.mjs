const encoder = new TextEncoder();
const decoder = new TextDecoder();

export async function run(context) {
  const [gatePath, finalPath] = context.args;
  context.assert(gatePath && finalPath, "gate image paths are required");
  const gateImage = await context.image(gatePath);
  const finalImage = await context.image(finalPath);
  const emit = record => context.stdout(encoder.encode(JSON.stringify({engine: context.engine, ...record}) + "\n"));

  async function execute(image, args, selected, inspect = false, timer = false) {
    let module;
    let output = "";
    const factory = async options => {
      module = await image.factory(options);
      return module;
    };
    const instance = context.create(factory, {
      locateFile: image.locateFile,
      stdout(chunk) { output += decoder.decode(chunk, {stream: true}); context.stdout(chunk); },
      stderr: context.stderr,
    });
    await instance.initialize();
    if (inspect) context.assert(module._titan_browser_gate_guarded() === 1,
      "admitted guarded export did not execute its real nonlocal unwind");
    const before = performance.now();
    const tickTimes = [];
    let frames = 0;
    let raf;
    let interval;
    if (timer) {
      interval = setInterval(() => tickTimes.push(performance.now()), 10);
      if (context.engine === "chromium") {
        const frame = () => { frames++; raf = requestAnimationFrame(frame); };
        raf = requestAnimationFrame(frame);
      }
    }
    let settled = false;
    let running;
    try {
      running = instance.run(args);
      running.then(() => { settled = true; }, () => { settled = true; });
      if (inspect) {
        await new Promise((resolve, reject) => setTimeout(async () => {
          try {
            context.assert(!settled, "entry completed instead of returning to JS with parked owners");
            const observed = module._titan_browser_gate_observe() >>> 0;
            context.assert((observed & 255) > 0, "no retained authored FFI frames at outer suspension");
            context.assert(module._titan_browser_gate_guarded() === -1, "raw C guard admitted a new unwind while suspended");
            let wrapperRejected = false;
            try { await instance.run([]); }
            catch (error) {
              wrapperRejected = error.name === "TitanBrowserError" && error.code === "TITAN_BROWSER_REENTRY" &&
                error.message === "browser instance is suspended; reentry is not allowed";
            }
            context.assert(wrapperRejected, "JS wrapper did not reject suspension reentry exactly");
            context.assert((module._titan_browser_gate_observe() >>> 0) === observed,
              "guard refusal mutated the admitted run");
            emit({item: 1, hostReturnBeforeCompletion: true, parkedFFIFrames: observed & 255});
            emit({item: 8, wrapperRejected, rawResult: -1, observeCallable: true});
            resolve();
          } catch (error) { reject(error); }
        }, 5));
      }
      const result = await running;
      const elapsed = performance.now() - before;
      context.assert(result.kind === "returned" && result.status === 0, "native gate did not complete successfully");
      if (selected !== null) {
        context.assert(output.includes(`[==========] ${selected} test${selected === 1 ? "" : "s"} ran.`),
          `native selection did not run exactly ${selected} cases`);
        context.assert(output.includes(`[  PASSED  ] ${selected} test${selected === 1 ? "" : "s"}.`),
          "native gate did not pass every selected case");
      }
      if (inspect) {
        const observed = module._titan_browser_gate_observe() >>> 0;
        context.assert((observed & 255) === 0, "authored FFI frames did not retire");
        context.assert(((observed >>> 8) & 63) === 63, "lua_close omitted a retained nested defer");
        context.assert((observed & (1 << 14)) === 0, "lua_close repeated a defer or entered abandoned continuation/catch");
        context.assert((observed >>> 16) === 2578, "gate did not perform exactly 2578 real waits");
        emit({item: 9, closeMask: (observed >>> 8) & 63, duplicateOrContinuation: 0, waits: observed >>> 16});
      }
      return {elapsed, tickTimes, frames, output};
    } finally {
      clearInterval(interval);
      if (raf !== undefined) cancelAnimationFrame(raf);
      await instance.dispose();
      module = undefined;
    }
  }

  // MODULARIZE is exercised before the expensive gate, in the same realm with
  // the same imported factory (never a cache-busting import or new process).
  for (let cycle = 0; cycle < 3; cycle++) {
    await execute(gateImage, ["--filter=^entry_gate%.test_06_"], 1);
    await context.tick();
    await context.gc();
  }
  emit({repeatedInstantiation: 3, factoryIdentityStable: gateImage.factory === (await context.image(gatePath)).factory});
  context.assert(gateImage.factory === (await context.image(gatePath)).factory, "image factory was not cached");

  await execute(gateImage, ["--filter=^entry_gate%.test_0[1-9]_"], 9, true);

  // Isolate responsiveness from busy work and from initialization time.
  const responsive = await execute(gateImage, ["--filter=^entry_gate%.test_07_"], 1, false, true);
  const ideal = responsive.elapsed / 10;
  const gaps = responsive.tickTimes.slice(1).map((time, index) => time - responsive.tickTimes[index]);
  const maxGap = Math.max(0, ...gaps);
  emit({item: 7, elapsedMs: responsive.elapsed, ticks: responsive.tickTimes.length, idealTicks: ideal,
    ratio: responsive.tickTimes.length / ideal, maxGapMs: maxGap, animationFrames: responsive.frames,
    thresholds: {minimumRatio: 0.75, maximumRatio: 1.25, maximumGapMs: 100}});
  context.assert(responsive.tickTimes.length >= ideal * 0.75 && responsive.tickTimes.length <= ideal * 1.25,
    "10ms interval count was not close to elapsed/10");
  context.assert(maxGap <= 100, "outer suspension left a host timer gap above 100ms");
  if (context.engine === "chromium") context.assert(responsive.frames >= 2, "requestAnimationFrame did not advance");

  const busy = await execute(gateImage, ["--filter=^entry_gate%.test_negative_busy_"], 1, false, true);
  emit({negative: "busy_wait", elapsedMs: busy.elapsed, ticks: busy.tickTimes.length, animationFrames: busy.frames});
  context.assert(busy.elapsed >= 140 && busy.tickTimes.length === 0, "busy-wait control did not block timers");
  await execute(gateImage, ["--filter=^entry_gate%.test_negative_fiber_"], 1);

  for (const [args, status] of [[[], 0], [["nonzero"], 7], [["two"], 2]]) {
    const instance = context.create(finalImage.factory, {locateFile: finalImage.locateFile,
      stdout: context.stdout, stderr: context.stderr});
    try {
      const result = await instance.run(args);
      context.assert(result.kind === "returned" && result.status === status && result.bytes.length === 0,
        "final fiber switch lost Titan completion status");
      emit({item: 6, finalAction: "fiber_switch", completionStatus: result.status, ccallResultAsserted: false});
    } finally { await instance.dispose(); }
  }
  emit({verdict: "PASS", items: 9, nativeCases: 15, waitForms: ["emscripten_sleep", "EM_ASYNC_JS/setTimeout"]});
}
