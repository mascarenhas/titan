import {closed, encode, expectedBytes, join, reentry, rejection} from './checks.mjs';

async function collect(context, references) {
  for (let attempt = 0; attempt < 30; attempt++) {
    await context.tick();
    await context.gc();
    await context.tick();
    if (references.every(reference => reference.deref() === undefined)) return;
  }
  context.assert(false, `${references.filter(reference => reference.deref() !== undefined).length} Module/heap owners survived repeated acknowledged GC`);
}

export async function lifecycle(context, paths) {
  let runs = 0;
  for (const path of paths) {
    const image = await context.image(path);
    context.assert(image.factory === (await context.image(path)).factory, 'factory identity changed between instances');
    let driver, native, published = false, retired = false, deliveries = 0;
    let handoffs = 0, terminalHandoffs = 0;
    const checks = [];
    const internal = context.create(async options => {
      const attach = options.titanBrowserAttach;
      options.titanBrowserAttach = state => {
        driver = state;
        const transfer = state.transfer;
        state.transfer = (...args) => {
          const result = transfer(...args);
          handoffs++;
          if (args[4]) terminalHandoffs++;
          checks.push(Promise.resolve().then(async () => {
            context.assert(state.owner && !state.safe(),
              'an internal JSPI microtask released logical-entry admission');
            context.assert(deliveries === 0, 'an internal handoff drained an application sink');
            await rejection(context, native._titan_browser_entry(0, 0, 0), reentry);
          }));
          return result;
        };
        attach(state);
      };
      const complete = options.titanBrowserComplete;
      options.titanBrowserComplete = (...args) => {
        context.assert(driver.owner && !retired && !published,
          'completion was not copied inside the one admitted native entry');
        context.assert(driver.contexts.size === 1,
          'completion preceded coroutine engine-continuation retirement');
        published = true;
        complete(...args);
      };
      native = await image.factory(options);
      const entry = native._titan_browser_entry;
      native._titan_browser_entry = (...args) => entry(...args).finally(() => { retired = true; });
      return native;
    }, {locateFile: image.locateFile, stdout: () => { deliveries++; }, stderr: () => { deliveries++; }});
    try {
      const result = await internal.run(['fidelity']);
      await Promise.all(checks);
      context.assert(result.status === 23 && published && retired && driver.safe(),
        'loader completion did not wait for the promised native entry to retire');
      context.assert(handoffs >= 4 && terminalHandoffs >= 2 && deliveries === 2,
        'internal handoff fixture did not exercise parked/terminal/close transitions');
      await rejection(context, native._titan_mco_entry(0), {code: 'TITAN_BROWSER_REENTRY'});
    } finally { await internal.dispose(); driver = native = undefined; runs++; }
    const references = [], keptHandles = [];
    async function cycle() {
      let module;
      const instance = context.create(async options => { module = await image.factory(options); return module; },
        {locateFile: image.locateFile});
      try {
        const result = await instance.run(['cycle']);
        context.assert(result.kind === 'returned' && result.status === 23, 'coroutine cycle failed');
        references.push(new WeakRef(module), new WeakRef(module.HEAPU8.buffer));
      } finally { await instance.dispose(); module = undefined; }
      // Keep the disposed public handle alive: it must not retain the Module,
      // its current memory buffer, the factory, or callback owners.
      keptHandles.push(instance);
    }
    for (let index = 0; index < 50; index++) {
      await cycle(); runs++;
      await context.tick();
      await context.gc();
    }
    await collect(context, references);
    context.assert(keptHandles.length === 50);

    let calls = 0;
    const never = context.create(options => { calls++; return image.factory(options); }, {locateFile: image.locateFile});
    await never.dispose();
    await rejection(context, never.initialize(), closed);
    await rejection(context, never.run(['cycle']), closed);
    context.assert(calls === 0, 'disposed new instance instantiated a factory');

    let release;
    const ready = new Promise(resolve => { release = resolve; });
    const late = context.create(async options => {
      await ready;
      const module = await image.factory(options);
      references.push(new WeakRef(module), new WeakRef(module.HEAPU8.buffer));
      return module;
    }, {locateFile: image.locateFile});
    const initializing = late.initialize();
    context.assert(initializing === late.initialize(), 'initialization race created two factory calls');
    await context.tick();
    await late.dispose();
    await rejection(context, late.run(['cycle']), closed);
    release();
    await initializing;
    keptHandles.push(late);
    await collect(context, references);

    let releaseRun;
    const runReady = new Promise(resolve => { releaseRun = resolve; });
    const notStarted = context.create(async options => { await runReady; return image.factory(options); },
      {locateFile: image.locateFile});
    const run = notStarted.run(['cycle']);
    const runRejected = rejection(context, run, closed);
    let disposed = false;
    const disposing = notStarted.dispose().then(() => { disposed = true; });
    await context.tick();
    context.assert(!disposed, 'disposal abandoned an admitted initialization');
    releaseRun();
    await runRejected;
    await disposing;

    const captures = [{stdout: [], stderr: []}, {stdout: [], stderr: []}];
    const bridges = [];
    const cause = new Error('first independent instance sink');
    let failedCalls = 0;
    const instances = captures.map((capture, index) => context.create(options => {
      const attach = options.titanBrowserAttach;
      options.titanBrowserAttach = state => { bridges[index] = state; attach(state); };
      return image.factory(options);
    }, {locateFile: image.locateFile,
      stdout: bytes => {
        if (index === 0) { failedCalls++; throw cause; }
        capture.stdout.push(bytes);
      }, stderr: bytes => { capture.stderr.push(bytes); }}));
    await Promise.all(instances.map(instance => instance.initialize()));
    const first = rejection(context, instances[0].run(['fidelity']), {
      code: 'TITAN_BROWSER_SINK', message: 'browser stdout sink failed', stream: 'stdout', cause,
    });
    const second = instances[1].run(['fidelity']);
    try {
      await context.tick();
      context.assert(bridges.every(bridge => bridge.owner && !bridge.safe()), 'independent logical entries did not overlap');
      await rejection(context, instances[1].run(), reentry);
      const disposingFirst = instances[0].dispose();
      await rejection(context, instances[0].run(), closed);
      await first;
      const result = await second;
      await disposingFirst;
      context.assert(result.kind === 'returned' && result.status === 23 && failedCalls === 1,
        'one failed/disposed instance poisoned its overlapping peer');
      context.equalBytes(join(captures[0].stderr), expectedBytes('stderr'), 'failed peer cleanup did not complete');
      context.equalBytes(join(captures[1].stdout), expectedBytes('stdout'));
      context.equalBytes(join(captures[1].stderr), expectedBytes('stderr'));
    } finally {
      await Promise.all(instances.map(instance => instance.dispose()));
      runs += 2;
    }
    context.stdout(encode(`loader lifecycle: ${path}: 50 coroutine cycles, ${references.length} collected Module/heap targets, 2 overlapping instances, 3 lifecycle races passed\n`));
  }
  return runs;
}
