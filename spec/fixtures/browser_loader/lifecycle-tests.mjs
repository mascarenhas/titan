import {disposed, encode, expectedBytes, join, prefixes, reentry, rejection, tail} from './checks.mjs';

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
    context.assert(image.create === (await context.image(path)).create, 'creator identity changed between instances');
    let controls, loaderControls, mainRetired = false, deliveries = 0, expectedSinks = 0;
    let handoffs = 0, terminalHandoffs = 0;
    const checks = [], failures = [], completions = [];
    const internal = image.create({locateFile: image.locateFile, imports: context.imports,
      bindings: {
        __titanTest(value) { controls = value; },
        __loaderTest(value) { loaderControls = value; },
      },
      stdout: () => { deliveries++; }, stderr: () => { deliveries++; }});
    let unwatchTransfers, unwatchCompletions;
    try {
      await internal.initialize();
      unwatchTransfers = controls.watchTransfers(event => {
        handoffs++;
        if (event.terminal) terminalHandoffs++;
        checks.push(Promise.resolve().then(async () => {
          const snapshot = controls.snapshot();
          context.assert(snapshot.owner && !snapshot.safe, 'an internal JSPI microtask released entry admission');
          context.assert(deliveries === expectedSinks, 'an internal handoff drained an application sink');
          await rejection(context, loaderControls.rawEntry(), reentry);
        }).catch(error => { failures.push(error); }));
      });
      unwatchCompletions = controls.watchCompletions(record => {
        const snapshot = controls.snapshot();
        context.assert(snapshot.owner && !snapshot.safe, 'completion was not copied inside its native entry');
        if (record.kind === 2) context.assert(!mainRetired, 'main completion followed public promise settlement');
        completions.push({id: record.id, kind: record.kind});
      });
      const result = await internal.run(['fidelity']);
      mainRetired = true;
      await Promise.all(checks);
      if (failures.length) throw failures[0];
      const snapshot = controls.snapshot();
      context.assert(result.status === 23 && snapshot.safe && !snapshot.owner && deliveries === 4,
        'main completion did not wait for promised entry and both sink queues');
      context.assert(completions.length === 1 && completions[0].kind === 2, 'main emitted more than one completion');
      await rejection(context, loaderControls.privateEntry(), {code: 'TITAN_BROWSER_REENTRY'});
      expectedSinks = deliveries;
      await internal.dispose();
      await Promise.all(checks);
      if (failures.length) throw failures[0];
      context.assert(handoffs >= 4 && terminalHandoffs >= 2 && deliveries === 6,
        'separate main/close entries did not exercise parked, terminal and finalizer transitions');
      context.assert(completions.length === 2 && completions[1].kind === 5 &&
        completions[1].id > completions[0].id && completions[0].id > 0n,
        'main and close did not use distinct authoritative operation identities');
    } finally {
      unwatchTransfers?.(); unwatchCompletions?.();
      await internal.dispose();
      controls = loaderControls = undefined;
      runs++;
    }

    const references = [], keptHandles = [];
    async function cycle() {
      let controls;
      const instance = image.create({locateFile: image.locateFile, imports: context.imports,
        bindings: {__titanTest(value) { controls = value; }}});
      try {
        const result = await instance.run(['cycle']);
        context.assert(result.kind === 'returned' && result.status === 23, 'coroutine cycle failed');
        references.push(...controls.weakTargets());
      } finally { await instance.dispose(); controls = undefined; }
      // A live disposed facade must not retain its native image or callbacks.
      keptHandles.push(instance);
    }
    for (let index = 0; index < 50; index++) {
      await cycle(); runs++;
      await context.tick();
      await context.gc();
    }
    await collect(context, references);
    context.assert(keptHandles.length === 50);

    let locations = 0;
    const never = image.create({locateFile(name) { locations++; return image.locateFile(name); }});
    await never.dispose();
    await rejection(context, never.initialize(), disposed);
    await rejection(context, never.run(['cycle']), disposed);
    context.assert(locations === 0, 'disposing an uninitialized instance fetched assets');

    let lateControls;
    const late = image.create({locateFile: image.locateFile, imports: context.imports,
      bindings: {__titanTest(value) { lateControls = value; }}});
    const initializing = late.initialize();
    context.assert(initializing === late.initialize(), 'initialization race did not share one promise');
    const initRejected = rejection(context, initializing, {code: disposed.code});
    const disposing = late.dispose();
    context.assert(disposing === late.dispose(), 'initialization disposal did not share one promise');
    await initRejected;
    await disposing;
    await rejection(context, late.run(['cycle']), disposed);
    if (lateControls) references.push(...lateControls.weakTargets());
    lateControls = undefined;
    keptHandles.push(late);
    await collect(context, references);

    let fromImport, importCalls = 0, imported;
    imported = image.create({locateFile: image.locateFile, imports: context.imports,
      bindings: {initialize_hook() { importCalls++; fromImport = imported.dispose(); }}});
    await rejection(context, imported.initialize(), {code: disposed.code});
    await fromImport;
    context.assert(importCalls === 1 && fromImport === imported.dispose(),
      'disposal from a real initializer import was not a single retirement request');
    await rejection(context, imported.drain(), disposed);

    const unusedOutput = [];
    const notStarted = image.create({locateFile: image.locateFile, stdout: bytes => { unusedOutput.push(bytes); }});
    const runRejected = rejection(context, notStarted.run(['cycle']), {code: disposed.code});
    const notStartedDisposal = notStarted.dispose();
    await runRejected;
    await notStartedDisposal;
    context.assert(unusedOutput.length === 0, 'interrupted initialization entered main');

    const captures = [{stdout: [], stderr: []}, {stdout: [], stderr: []}];
    const peerControls = [];
    const cause = new Error('first independent instance sink');
    let failedCalls = 0;
    const instances = captures.map((capture, index) => image.create({locateFile: image.locateFile,
      imports: context.imports,
      bindings: {__titanTest(value) { peerControls[index] = value; }},
      stdout(bytes) {
        if (index === 0) { failedCalls++; throw cause; }
        capture.stdout.push(bytes);
      }, stderr: bytes => { capture.stderr.push(bytes); }}));
    await Promise.all(instances.map(instance => instance.initialize()));
    const sinkFailure = {code: 'TITAN_BROWSER_SINK', message: 'browser stdout sink failed', stream: 'stdout', cause};
    const first = rejection(context, instances[0].run(['fidelity']), sinkFailure);
    const second = instances[1].run(['fidelity']);
    try {
      await context.tick();
      context.assert(peerControls.every(control => {
        const snapshot = control.snapshot(); return snapshot.owner && !snapshot.safe;
      }), 'independent logical entries did not overlap');
      await rejection(context, instances[1].run(), reentry);
      await first;
      await rejection(context, instances[0].dispose(), sinkFailure);
      await rejection(context, instances[0].run(), disposed);
      const result = await second;
      context.equalBytes(join(captures[1].stdout), join([prefixes.stdout, tail]), 'main closed the peer state early');
      await instances[1].dispose();
      context.assert(result.kind === 'returned' && result.status === 23 && failedCalls === 3,
        'one failed/disposed instance poisoned its overlapping peer or skipped close output');
      context.equalBytes(join(captures[0].stderr), expectedBytes('stderr'), 'failed peer cleanup did not complete');
      context.equalBytes(join(captures[1].stdout), expectedBytes('stdout'));
      context.equalBytes(join(captures[1].stderr), expectedBytes('stderr'));
    } finally {
      await Promise.all(instances.map(instance => instance.dispose().catch(() => {})));
      peerControls.length = 0;
      runs += 2;
    }
    context.stdout(encode(`loader lifecycle: ${path}: 50 coroutine cycles, ${references.length} collected Module/heap targets, 2 overlapping instances, 4 lifecycle races passed\n`));
  }
  return runs;
}
