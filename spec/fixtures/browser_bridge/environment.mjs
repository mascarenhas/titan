export async function run(context) {
  context.assert(context.args.length === 1, 'pass the environment image path');
  const image = await context.image(context.args[0]);
  for (const env of [null, true, 1, 1n, 'FOO=bar', () => {}, Symbol('env')]) {
    let caught;
    try { image.create({env}); } catch (error) { caught = error; }
    context.assert(caught instanceof TypeError, 'create accepted a non-object environment');
  }
  for (const value of [undefined, null, false, 1, 1n, {}, [], () => {}, Symbol('value')]) {
    let caught;
    try { image.create({env: {FOO: value}}); } catch (error) { caught = error; }
    context.assert(caught instanceof TypeError, 'create accepted a non-string environment value');
  }
  for (const env of [{'': 'value'}, {'A=B': 'value'}, {'A\0B': 'value'}, {FOO: 'a\0b'}]) {
    let caught;
    try { image.create({env}); } catch (error) { caught = error; }
    context.assert(caught instanceof TypeError, 'create accepted an invalid environment name or NUL value');
  }
  const prepare = env => {
    const state = {};
    state.instance = image.create({env, locateFile: image.locateFile,
      bindings: {environment(read, count, set, unset) { state.callbacks = {read, count, set, unset}; }}});
    return state;
  };
  const supplied = Object.assign(Object.create({INHERITED: 42}), {FOO: 'bar', EMPTY: ''});
  Object.defineProperty(supplied, 'HIDDEN', {value: 42});
  const unicodeName = 'NOME_á', unicodeValue = 'Olá, 世界 🌍';
  const states = [prepare(), prepare(supplied), prepare({FOO: 'peer', [unicodeName]: unicodeValue})];
  supplied.FOO = 'changed after create';
  supplied.EXTRA = 'must not appear';
  delete supplied.EMPTY;
  try {
    const results = await Promise.all(states.map(state => state.instance.run()));
    context.assert(results.every(result => result.kind === 'returned' && result.status === 0),
      'environment fixture did not publish its libc probes');
    const [empty, first, second] = states.map(state => state.callbacks);
    for (const name of ['USER', 'LOGNAME', 'PATH', 'PWD', 'HOME', 'LANG', '_', 'TZ']) {
      context.assert(await empty.read.call(name) === null, `invented environment variable ${name}`);
    }
    context.assert(await empty.count.call() === 0n, 'default environ was not empty');
    context.assert(await first.read.call('FOO') === 'bar' && await first.read.call('EMPTY') === '',
      'environment options were not snapshotted at create or lost an empty value');
    context.assert(await first.count.call() === 2n && await first.read.call('INHERITED') === null &&
      await first.read.call('HIDDEN') === null && await first.read.call('EXTRA') === null,
      'environment included a default, inherited, hidden or later-added property');
    context.assert(await second.read.call('FOO') === 'peer' &&
      await second.read.call(unicodeName) === unicodeValue && await second.count.call() === 2n,
      'instances shared environment data or non-ASCII names/values did not round-trip as UTF-8');
    const changed = 'one=two\nthree';
    context.assert(await first.set.call('ADDED', changed) === 0n &&
      await first.read.call('ADDED') === changed && await first.count.call() === 3n,
      'C setenv did not update the instance environment');
    context.assert(await first.set.call('EMPTY', 'filled') === 0n &&
      await first.read.call('EMPTY') === 'filled', 'C setenv did not replace an existing value');
    context.assert(await first.unset.call('FOO') === 0n && await first.read.call('FOO') === null &&
      await first.count.call() === 2n, 'C unsetenv did not remove the variable');
    context.assert(await second.read.call('FOO') === 'peer' && await second.read.call('ADDED') === null &&
      await second.read.call(unicodeName) === unicodeValue && await empty.count.call() === 0n,
      'C environment mutation escaped its instance');
  } finally {
    for (const state of states) {
      for (const callable of Object.values(state.callbacks ?? {})) callable.release();
    }
    await Promise.all(states.map(state => state.instance.dispose()));
  }
  context.stdout(new TextEncoder().encode('ENVIRONMENT ' + JSON.stringify({verdict: 'PASS',
    instances: states.length, defaultVariables: 0, utf8: true}) + '\n'));
}
