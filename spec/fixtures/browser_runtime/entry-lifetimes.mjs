const encoder = new TextEncoder();
export async function run(context) {
  context.assert(context.args.length === 1, 'pass the entry-lifetimes image');
  const image = await context.image(context.args[0]);
  const hops = [], checks = [], failures = [];
  const observed = {entries: 0, parked: 0, resumed: 0, independentCloses: 0,
    allocationCleanup: 0, earlySinks: 0};
  const peers = [0, 1].map(id => {
    const peer = {id, phase: 0, controls: undefined, callbacks: new Map(), deliveries: 0, lifetimes: undefined};
    peer.instance = image.create({locateFile: image.locateFile, imports: context.imports,
      bindings: {
        __titanTest(controls) { peer.controls = controls; },
        publish(name, callback) { peer.callbacks.set(name, callback); },
      },
      stdout(bytes) {
        const snapshot = peer.controls.snapshot();
        const safe = snapshot.safe && !snapshot.owner && peer.phase === 3;
        if (!safe) observed.earlySinks++;
        context.assert(safe, 'allocation-finalizer output escaped before its logical entry retired');
        context.equalBytes(bytes, encoder.encode('allocation-cleanup\n'));
        peer.deliveries++;
        observed.allocationCleanup++;
      },
    });
    return peer;
  });
  try {
    await Promise.all(peers.map(peer => peer.instance.initialize()));
    for (const peer of peers) {
      context.assert(peer.controls && peer.callbacks.size === 3, 'initializer did not publish real lifetime Callables');
      peer.unwatch = peer.controls.watchTransfers(event => {
        hops.push({id: peer.id, phase: peer.phase, terminal: event.terminal});
        checks.push(Promise.resolve().then(async () => {
          const snapshot = peer.controls.snapshot();
          context.assert(snapshot.owner && !snapshot.safe, 'a coroutine/GC handoff released its entry owner');
          context.assert(peer.deliveries === 0, 'collector/private handoff delivered a sink');
          let rejected;
          try { await peer.controls.rawGuarded(); } catch (error) { rejected = error; }
          context.assert(rejected?.code === 'TITAN_BROWSER_REENTRY', 'private hop admitted an external state entry');
        }).catch(error => { failures.push(error); }));
      });
    }
    for (const phase of [1, 2, 3]) {
      await Promise.all(peers.map(async peer => {
        peer.phase = phase;
        const name = ['entry_prepare', 'entry_resume', 'entry_finish'][phase - 1];
        const call = peer.instance.call(peer.callbacks.get(name));
        context.assert(call instanceof Promise, 'production protected invoke did not return a promise');
        const result = await call;
        context.assert(result === null, 'nil-result lifetime callback returned a non-null value');
        const snapshot = peer.controls.snapshot();
        context.assert(snapshot.safe && !snapshot.owner && snapshot.current === 0,
          'a completed promised entry retained execution ownership');
        context.assert(peer.controls.observe() === phase, 'state-neutral observer changed the entry lifetime');
        observed.entries++;
        const contexts = peer.controls.lifetimes();
        if (phase === 1) {
          context.assert(contexts.length === 5 && contexts.every(item => item.parked && item.lifetime),
            'first entry did not leave ordinary and stacked real continuations parked');
          peer.lifetimes = contexts;
          observed.parked += contexts.length;
        } else if (phase === 2) {
          context.assert(peer.lifetimes.every(original => contexts.some(item =>
            item.id === original.id && item.lifetime === original.lifetime)),
            'a later C entry replaced an existing engine continuation lifetime');
          const resumed = contexts.filter(item => item.finished).length;
          context.assert(resumed === 4, 'second entry did not retire the ordinary and stacked continuations');
          observed.resumed += resumed;
        } else {
          context.assert(contexts.length === 0 && peer.deliveries === 1,
            'independent-state close did not retire every continuation/allocation');
          observed.independentCloses++;
        }
      }));
      await Promise.all(checks);
      if (failures.length) throw failures[0];
    }
    const switches = hops.slice(1).filter((hop, index) => hop.id !== hops[index].id).length;
    context.assert(switches >= 4, 'two instances did not interleave their private JSPI hops');
    context.assert(peers.every(peer => hops.some(hop => hop.id === peer.id && hop.phase === 3)),
      'allocation-triggered cleanup did not perform private handoffs in both instances');
    context.stdout(encoder.encode('ENTRY-LIFETIMES ' + JSON.stringify({instances: peers.length,
      entries: observed.entries, parked: observed.parked, resumed: observed.resumed,
      independentCloses: observed.independentCloses, allocationCleanup: observed.allocationCleanup,
      privateHops: hops.length, interleavedSwitches: switches, earlySinks: observed.earlySinks}) + '\n'));
  } finally {
    for (const peer of peers) peer.unwatch?.();
    await Promise.all(peers.map(peer => peer.instance.dispose()));
    for (const peer of peers) {
      peer.callbacks.clear();
      peer.controls = peer.lifetimes = undefined;
    }
  }
}
