const encoder = new TextEncoder();
const decoder = new TextDecoder();

export async function run(context) {
  const [gatePath, finalPath] = context.args;
  context.assert(gatePath && finalPath, "gate image paths are required");
  const gateImage = await context.image(gatePath);
  const finalImage = await context.image(finalPath);
  const provenItems = new Set();
  let nativeCases = 0;
  const emit = record => {
    if (record.item !== undefined) provenItems.add(record.item);
    context.stdout(encoder.encode(JSON.stringify({engine: context.engine, ...record}) + "\n"));
  };

  async function execute(image, args, selected, inspect = false, timer = null) {
    let controls;
    let completed = false;
    let output = "";
    const tickTimes = [];
    let frames = 0;
    let raf;
    let interval;
    function startTimers() {
      interval = setInterval(() => tickTimes.push(performance.now()), 10);
      if (context.engine === "chromium") {
        const frame = () => { frames++; raf = requestAnimationFrame(frame); };
        raf = requestAnimationFrame(frame);
      }
    }
    const instance = image.create({
      locateFile: image.locateFile,
      bindings: {__titanTest(value) { controls = value; }},
      stdout(chunk) { output += decoder.decode(chunk, {stream: true}); context.stdout(chunk); },
      stderr: context.stderr,
    });
    await instance.initialize();
    const before = performance.now();
    if (timer) startTimers();
    let settled = false;
    let running;
    try {
      if (inspect) {
        context.assert(controls, "native initializer omitted its test-owned observations");
        const snapshot = () => controls.snapshot();
        const beforeGuard = snapshot();
        const admittedGuard = await controls.guarded();
        emit({guardStatus: String(admittedGuard), before: beforeGuard, after: snapshot()});
        context.assert(admittedGuard === 1,
          "admitted guarded export did not execute its real nonlocal unwind: " + String(admittedGuard));
      }
      running = instance.run(args);
      running.then(() => { settled = true; }, () => { settled = true; });
      if (inspect) {
        await new Promise((resolve, reject) => setTimeout(async () => {
          try {
            context.assert(!settled, "entry completed instead of returning to JS with parked owners");
            const observed = controls.observe() >>> 0;
            context.assert((observed & 255) > 0, "no retained authored FFI frames at outer suspension");
            let directRejected = false;
            try { await controls.rawGuarded(); }
            catch (error) { directRejected = error.code === "TITAN_BROWSER_REENTRY"; }
            const snapshot = controls.snapshot();
            context.assert(directRejected && snapshot.owner && !snapshot.safe,
              "direct export admitted a new entry between JSPI continuations");
            let wrapperRejected = false;
            try { await instance.run([]); }
            catch (error) {
              wrapperRejected = error.name === "TitanBrowserError" && error.code === "TITAN_BROWSER_REENTRY" &&
                error.message === "browser instance is active; reentry is not allowed";
            }
            context.assert(wrapperRejected, "JS wrapper did not reject suspension reentry exactly");
            context.assert((controls.observe() >>> 0) === observed,
              "guard refusal mutated the admitted run");
            emit({item: 1, hostReturnBeforeCompletion: true, parkedFFIFrames: observed & 255});
            emit({item: 8, wrapperRejected, rawResult: "rejected", observeCallable: true});
            resolve();
          } catch (error) { reject(error); }
        }, 5));
      }
      const result = await running;
      const finished = performance.now();
      const elapsed = finished - before;
      context.assert(result.kind === "returned" && result.status === 0, "native gate did not complete successfully");
      if (selected !== null) {
        context.assert(output.includes(`[==========] ${selected} test${selected === 1 ? "" : "s"} ran.`),
          `native selection did not run exactly ${selected} cases`);
        context.assert(output.includes(`[  PASSED  ] ${selected} test${selected === 1 ? "" : "s"}.`),
          "native gate did not pass every selected case");
        nativeCases += selected;
      }
      for (const match of output.matchAll(/GATE item=(\d+)/g)) provenItems.add(Number(match[1]));
      completed = true;
      return {elapsed, started: before, finished, tickTimes, frames, output};
    } finally {
      clearInterval(interval);
      if (raf !== undefined) cancelAnimationFrame(raf);
      await instance.dispose();
      if (inspect && completed) {
        const observed = controls.observe() >>> 0;
        context.assert((observed & 255) === 0, "authored FFI frames did not retire");
        context.assert(((observed >>> 8) & 63) === 63, "lua_close omitted a retained nested defer");
        context.assert((observed & (1 << 14)) === 0, "lua_close repeated a defer or entered abandoned continuation/catch");
        context.assert((observed >>> 16) === 2578, "gate did not perform exactly 2578 real waits");
        emit({item: 9, closeMask: (observed >>> 8) & 63, duplicateOrContinuation: 0, waits: observed >>> 16});
      }
      controls = undefined;
    }
  }

  // MODULARIZE is exercised before the expensive gate, in the same realm with
  // the same imported factory (never a cache-busting import or new process).
  let repeatedInstantiation = 0;
  for (let cycle = 0; cycle < 3; cycle++) {
    await execute(gateImage, ["--filter=^entry_gate%.test_06_"], 1);
    repeatedInstantiation++;
    await context.tick();
    await context.gc();
  }
  emit({repeatedInstantiation, creatorIdentityStable: gateImage.create === (await context.image(gatePath)).create});
  context.assert(gateImage.create === (await context.image(gatePath)).create, "image creator was not cached");

  await execute(gateImage, ["--filter=^entry_gate%.test_0[1-9]_"], 9, true);

  // Isolate responsiveness from busy work and from initialization time.
  const responsive = await execute(gateImage, ["--filter=^entry_gate%.test_07_"], 1, false, "responsive");
  const ideal = responsive.elapsed / 10;
  const boundaries = [responsive.started, ...responsive.tickTimes, responsive.finished];
  const gaps = boundaries.slice(1).map((time, index) => time - boundaries[index]);
  const maxGap = Math.max(0, ...gaps);
  emit({item: 7, elapsedMs: responsive.elapsed,
    ticks: responsive.tickTimes.length, idealTicks: ideal,
    ratio: responsive.tickTimes.length / ideal, maxGapMs: maxGap, animationFrames: responsive.frames,
    thresholds: {minimumRatio: 0.75, maximumRatio: 1.25, maximumGapMs: 100}});
  context.assert(responsive.tickTimes.length >= ideal * 0.75 && responsive.tickTimes.length <= ideal * 1.25,
    "10ms interval count was not close to elapsed/10");
  context.assert(maxGap <= 100, "outer suspension left a host timer gap above 100ms");
  if (context.engine === "chromium") context.assert(responsive.frames >= 2, "requestAnimationFrame did not advance");

  const busy = await execute(gateImage, ["--filter=^entry_gate%.test_negative_busy_"], 1, false, "busy");
  emit({negative: "busy_wait", elapsedMs: busy.elapsed, ticks: busy.tickTimes.length, animationFrames: busy.frames});
  context.assert(busy.elapsed >= 140 && busy.tickTimes.length === 0, "busy-wait control did not block timers");
  await execute(gateImage, ["--filter=^entry_gate%.test_negative_coroutine_"], 1);

  for (const [args, status] of [[[], 0], [["nonzero"], 7], [["two"], 2]]) {
    const instance = finalImage.create({locateFile: finalImage.locateFile,
      stdout: context.stdout, stderr: context.stderr});
    try {
      const result = await instance.run(args);
      context.assert(result.kind === "returned" && result.status === status && result.bytes.length === 0,
        "final coroutine transfer lost Titan completion status");
      emit({item: 6, finalAction: "coroutine_transfer", completionStatus: result.status, exportResultAsserted: false});
    } finally { await instance.dispose(); }
  }
  emit({verdict: "PASS", items: provenItems.size, nativeCases, waitForms: ["emscripten_sleep", "EM_ASYNC_JS/setTimeout"]});
}
