const encoder = new TextEncoder();
export async function run(context) {
  context.assert(context.args.length === 1, 'pass the entry-lifetimes image');
  const image = await context.image(context.args[0]);
  const hops = [], checks = [];
  const peers = [0, 1].map(id => {
    const peer = {id, phase: 0, module: null, driver: null, deliveries: 0, lifetimes: null};
    peer.instance = context.create(async options => {
      const attach = options.titanBrowserAttach;
      options.titanBrowserAttach = state => {
        peer.driver = state;
        const transfer = state.transfer;
        state.transfer = (...args) => {
          const result = transfer(...args);
          hops.push({id, phase: peer.phase, terminal: !!args[4]});
          checks.push(Promise.resolve().then(async () => {
            context.assert(state.owner && !state.safe(), 'a coroutine/GC handoff released its entry owner');
            context.assert(peer.deliveries === 0, 'collector/private handoff delivered a sink');
            let rejected;
            try { await peer.module._titan_browser_gate_guarded(); } catch (error) { rejected = error; }
            context.assert(rejected?.code === 'TITAN_BROWSER_REENTRY', 'private hop admitted an external state entry');
          }));
          return result;
        };
        attach(state);
      };
      peer.module = await image.factory(options);
      return peer.module;
    }, {locateFile: image.locateFile, stdout: bytes => {
      context.assert(peer.driver.safe() && !peer.driver.owner && peer.phase === 3,
        'allocation-finalizer output escaped before its logical entry retired');
      context.equalBytes(bytes, encoder.encode('allocation-cleanup\n'));
      peer.deliveries++;
    }});
    return peer;
  });
  try {
    await Promise.all(peers.map(peer => peer.instance.initialize()));
    for (const phase of [1, 2, 3]) {
      await Promise.all(peers.map(async peer => {
        peer.phase = phase;
        const call = peer.module._titan_browser_gate_guarded();
        context.assert(call instanceof Promise, 'state-entering export did not return a promise');
        context.assert(await call === phase, 'independent state entry phase failed');
        context.assert(peer.driver.safe() && !peer.driver.owner && peer.driver.current === 0,
          'a completed promised entry retained execution ownership');
        context.assert(peer.module._titan_browser_gate_observe() === phase,
          'state-neutral observer changed the entry lifetime');
        const contexts = [...peer.driver.contexts.values()].filter(item => item.id !== 0);
        if (phase === 1) {
          context.assert(contexts.length === 5 && contexts.every(item => item.gate && item.lifetime),
            'first entry did not leave ordinary and stacked real continuations parked');
          peer.lifetimes = contexts.map(item => [item, item.lifetime]);
        } else if (phase === 2) {
          context.assert(peer.lifetimes.every(([item, lifetime]) =>
            peer.driver.contexts.get(item.id) === item && item.lifetime === lifetime),
            'a later C entry replaced an existing engine continuation lifetime');
          context.assert(contexts.filter(item => item.finished).length === 4,
            'second entry did not retire the ordinary and stacked continuations');
        } else {
          context.assert(contexts.length === 0 && peer.deliveries === 1,
            'independent-state close did not retire every continuation/allocation');
        }
      }));
      await Promise.all(checks);
    }
    const switches = hops.slice(1).filter((hop, index) => hop.id !== hops[index].id).length;
    context.assert(switches >= 4, 'two instances did not interleave their private JSPI hops');
    context.assert(peers.every(peer => hops.some(hop => hop.id === peer.id && hop.phase === 3)),
      'allocation-triggered cleanup did not perform private handoffs in both instances');
    context.stdout(encoder.encode('ENTRY-LIFETIMES ' + JSON.stringify({instances: 2, entries: 6,
      parked: 10, resumed: 8, independentCloses: 2, allocationCleanup: 2,
      privateHops: hops.length, interleavedSwitches: switches, earlySinks: 0}) + '\n'));
  } finally {
    await Promise.all(peers.map(peer => peer.instance.dispose()));
    for (const peer of peers) peer.module = peer.driver = peer.lifetimes = null;
  }
}
