import {encode, makeHost, observe, rejection, settledMarker, until} from './support.mjs';

// These are test-owned host capabilities: copied-byte observations and held
// sink/source/end promises. No private loader or scheduler state is inspected.
function hold(host, queue) {
  return new Promise(resolve => { queue.push(resolve); host.releaseOnClose.push(resolve); });
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the OS stream image');
  const image = await context.image(context.args[0]);
  const cases = [];
  const failures = [];
  const originalPrompt = globalThis.prompt;
  let dialogs = 0;
  globalThis.prompt = () => { dialogs++; throw new Error('stdin opened a dialog'); };
  const bytes = (actual, expected, label) => context.assert(
    actual.length === expected.length && expected.every((byte, index) => actual[index] === byte),
    `${label}: ${JSON.stringify([...actual])} != ${JSON.stringify(expected)}`);
  const chunks = (actual, expected, label) => {
    context.assert(actual.length === expected.length, `${label}: wrong chunk count ${actual.length}`);
    expected.forEach((value, index) => bytes(actual[index], value, `${label} chunk ${index}`));
  };
  const joined = list => list.flatMap(chunk => [...chunk]);
  const ascii = text => [...encode(text)];
  async function check(name, options, action) {
    const host = makeHost(context, image, options);
    host.releaseOnClose = [];
    context.assert(!cases.includes(name), `duplicate case ${name}`);
    cases.push(name);
    try {
      await host.instance.initialize();
      await action(host);
      context.assert(host.notificationErrors.length === 0, `${name}: unexpected cleanup notification`);
      context.assert(dialogs === 0, `${name}: stdin opened a dialog`);
    } catch (error) {
      failures.push(`${name}: ${error.message}`);
    } finally {
      for (const resolve of host.releaseOnClose) resolve();
      host.settleHeld();
      for (const callable of host.callables.values()) callable.release();
      await host.instance.dispose();
    }
  }
  const task = async (host, name, args = []) => {
    context.assert(await host.task(name, args) === true, `${name}: missing successful Titan assertion result`);
  };
  try {
    await check('print-conversion-bytes-and-late-stdout', {}, async host => {
      await task(host, 'printing');
      chunks(host.stdout, [[65, 0, 128, 255, 9, 66, 10], [10],
        [...ascii('survivor'), 0, 255, 10], ascii('restored\n')], 'print stdout');
      chunks(host.stderr, [[...ascii('redirected'), 0, 128, 10]], 'redirected print');
    });

    for (const stream of ['stdout', 'stderr']) {
      await check(`write-fifo-and-own-settlement:${stream}`, {}, async host => {
        const sinks = [];
        host.hooks[stream] = () => hold(host, sinks);
        const operation = host.task('write_three', [stream]);
        const marker = settledMarker(operation);
        for (let index = 0; index < 3; index++) {
          await until(context, () => sinks.length === index + 1, 'write did not reach its sink');
          context.assert(!marker.settled && !host.notes.includes(`after-${index + 1}`),
            'write returned before its own sink settled');
          context.assert(index === 0 || host.notes.includes(`after-${index}`), 'writes reordered');
          sinks[index]();
        }
        context.assert(await operation === true, 'three writes did not return');
        chunks(host[stream], [ascii('W1'), ascii('W2'), ascii('W3')], 'FIFO writes');
        context.assert(host.notes.join('|') === 'before-1|after-1|before-2|after-2|before-3|after-3',
          'write completion order changed');
      });
      for (const failure of ['reject', 'throw']) {
        await check(`write-${failure}-and-recovery:${stream}`, {}, async host => {
          let calls = 0;
          host.hooks[stream] = () => {
            if (++calls !== 1) return;
            const error = new Error(`write-${failure}-failure`);
            if (failure === 'throw') throw error;
            return Promise.reject(error);
          };
          const message = await host.task('write_recovery', [stream]);
          context.assert(message.includes(`write-${failure}-failure`), 'write lost its host diagnostic');
          chunks(host[stream], [ascii('rejected'), ascii('survivor')], 'write recovery');
          context.assert(host.notes.join('|') === 'write-error', 'write error escaped Titan');
        });
      }
      await check(`admitted-write-cancellation:${stream}`, {}, async host => {
        const sinks = [];
        host.hooks[stream] = () => hold(host, sinks);
        const controller = new AbortController();
        const operation = host.task('cancelled_write', [stream], {signal: controller.signal});
        const marker = settledMarker(operation);
        await until(context, () => sinks.length === 1, 'write was not admitted');
        controller.abort('cancel admitted write');
        await context.tick();
        context.assert(!marker.settled && !host.notes.includes('write-cancelled'),
          'admitted write observed cancellation before its sink settled');
        sinks[0]();
        const error = await rejection(context, operation, 'CANCELLED');
        context.assert(error.reason === 'cancel admitted write', 'write lost its cancellation reason');
        chunks(host[stream], [[...ascii('accepted'), 0, 255]], 'cancelled write');
        context.assert(host.notes.includes('write-cancelled') && host.notes.includes('write-cleanup') &&
          !host.notes.includes('write-returned'), 'cancelled write did not unwind after settlement');
      });
    }

    await check('exit-drains-every-accepted-write', {}, async host => {
      const sinks = [];
      host.hooks.stdout = () => hold(host, sinks);
      const operation = host.task('queued_exit');
      const marker = settledMarker(operation);
      await until(context, () => host.notes.includes('queued-before-3') && host.held.length === 1 &&
        sinks.length === 1, 'queued writes or exit gate did not start');
      host.settleHeld();
      await context.tick();
      context.assert(!marker.settled, 'exit abandoned an accepted write');
      for (let index = 0; index < 3; index++) {
        await until(context, () => sinks.length === index + 1, 'exit did not drain a queued write');
        context.assert(!marker.settled, 'exit settled before the last sink');
        sinks[index]();
      }
      const error = await rejection(context, operation, 'EXITED');
      context.assert(error.status === 9, 'queued exit lost its status');
      chunks(host.stdout, [ascii('Q1'), ascii('Q2'), ascii('Q3')], 'exit FIFO');
      for (let index = 1; index <= 3; index++)
        context.assert(host.notes.includes(`queued-cleanup-${index}`), 'exit skipped writer cleanup');
    });

    await check('dispose-rejects-queued-inflight-and-cleanup-writes', {}, async host => {
      const sinks = [];
      let pendingSink;
      host.hooks.stdout = () => pendingSink = hold(host, sinks);
      const operation = host.task('queued_disposal');
      await until(context, () => host.notes.includes('queued-before-3') && sinks.length === 1,
        'disposal writes were not queued');
      const sinkMarker = settledMarker(pendingSink);
      await host.instance.dispose();
      context.assert(!sinkMarker.settled, 'dispose waited for the held host sink');
      await rejection(context, operation, 'DISPOSED');
      chunks(host.stdout, [ascii('Q1')], 'disposal must not call a later sink');
      for (let index = 1; index <= 3; index++) {
        context.assert(host.notes.includes(`disposed-write-${index}:instance disposed`),
          `writer ${index} lost its nominal disposal cancellation: ${JSON.stringify(host.notes)}`);
        context.assert(host.notes.includes(`disposed-writer-cleanup-${index}:instance disposed`),
          `writer ${index}'s cleanup lost its nominal disposal cancellation`);
        context.assert(host.notes.includes(`queued-cleanup-${index}`), 'disposal skipped writer cleanup');
      }
      context.assert(host.notes.includes('disposed-cleanup:instance disposed'),
        'the owner cleanup write lost its nominal disposal cancellation');
    });

    await check('c-and-titan-order-exact-bytes-and-fflush-tail', {}, async host => {
      await task(host, 'c_interleave');
      bytes(joined(host.stdout), [84, 0, 255, ...ascii('C-prefix'), 0, 128, 255,
        ...ascii('tail'), 90, 0, 128], 'C/Titan ordering');
      chunks(host.stderr, [[69, 0, 255]], 'C/Titan stderr');
    });
    for (const entry of ['task', 'main']) {
      await check(`c-return-flush:${entry}`, {}, async host => {
        const sinks = [];
        host.hooks.stdout = () => hold(host, sinks);
        const operation = observe(entry === 'task' ? host.task('c_return') : host.instance.run(['return-c']));
        const marker = settledMarker(operation);
        await until(context, () => sinks.length > 0, 'return did not flush the C tail');
        context.assert(!marker.settled, 'return settled before its C output');
        for (const settle of sinks) settle();
        const result = await operation;
        if (entry === 'task') context.assert(result === true, 'C Task did not return');
        else context.assert(result.kind === 'returned' && result.status === 0 && result.bytes.length === 0,
          'normal main did not return');
        bytes(joined(host.stdout), [...ascii(entry), 0, 128, 255, ...ascii('tail')], 'C return bytes');
      });
    }
    await check('c-failure-latches-once-and-remains-operation-failure', {}, async host => {
      let calls = 0;
      host.hooks.stdout = () => { if (++calls === 1) return Promise.reject(new Error('C sink failure')); };
      const failure = await rejection(context, host.task('c_latch'), 'SINK');
      bytes(joined(host.stdout), ascii('C-failurelatchedafter-latch'), 'C failure output');
      context.assert(host.notes.length === 2 && host.notes[0] === `c-latch:${failure.message}` &&
        host.notes[1] === 'c-latch-recovered',
        `the C failure was not delivered once and recovered: ${JSON.stringify(host.notes)}`);
    });
    await check('c-stdio-does-not-yield-a-task-turn', {}, async host => {
      await task(host, 'c_no_yield');
      bytes(joined(host.stdout), ascii('no-yield'), 'non-yielding C output');
    });

    for (const kind of ['tty', 'pipe', 'file', 'tcp']) {
      await check(`declared-kinds-and-tty:${kind}`,
        {stdinKind: kind, stdoutKind: kind, stderrKind: kind}, async host => {
          context.assert(await host.task('declared_kinds', [kind]) === kind, 'declared kind changed');
        });
    }
    await check('undeclared-kinds-are-enosys-not-tty', {}, host => task(host, 'undeclared_kinds'));
    for (const option of ['stdinKind', 'stdoutKind', 'stderrKind']) {
      await check(`invalid-kind-names-option:${option}`, {[option]: 'invalid'}, async host => {
        const message = await host.task('invalid_kind', [option]);
        context.assert(message.includes(option), 'invalid kind error did not name its option');
      });
    }
    for (const kind of [undefined, 'tty', 'pipe', 'file']) {
      for (const stream of ['stdout', 'stderr']) {
        await check(`unsupported-shutdown-keeps-open:${stream}:${kind ?? 'undeclared'}`,
          {[`${stream}Kind`]: kind}, async host => {
            await task(host, 'unsupported_shutdown', [stream]);
            chunks(host[stream], [ascii('still-open')], 'unsupported shutdown');
          });
      }
    }
    for (const stream of ['stdout', 'stderr']) {
      for (const cancel of [false, true]) {
        let endHost;
        const ends = [];
        await check(`tcp-shutdown-order-repeat-epipe:${stream}:${cancel ? 'cancel' : 'complete'}`,
          {[`${stream}Kind`]: 'tcp', [`${stream}End`]: () => hold(endHost, ends)}, async host => {
            endHost = host;
            const sinks = [];
            host.hooks[stream] = () => hold(host, sinks);
            const controller = new AbortController();
            const operation = host.task('tcp_shutdown', [stream], {signal: controller.signal});
            const marker = settledMarker(operation);
            await until(context, () => host.notes.includes('shutdown-repeated') && sinks.length === 1,
              'repeat shutdown did not return while the first was pending');
            context.assert(ends.length === 0, 'end overtook accepted writes');
            for (let index = 0; index < 2; index++) {
              await until(context, () => sinks.length === index + 1, 'TCP write did not drain');
              context.assert(ends.length === 0 && !marker.settled, 'shutdown overtook a sink');
              sinks[index]();
            }
            await until(context, () => ends.length === 1, 'TCP end hook was not called');
            context.assert(!marker.settled, 'shutdown ignored the end promise');
            if (cancel) {
              controller.abort('cancel admitted shutdown');
              await context.tick();
              context.assert(!marker.settled && !host.notes.includes('shutdown-cancelled'),
                'shutdown cancelled before its hook settled');
            }
            ends[0]();
            if (cancel) {
              await rejection(context, operation, 'CANCELLED');
              context.assert(host.notes.includes('shutdown-cancelled') &&
                !host.notes.includes('shutdown-returned'), 'shutdown did not deliver cancellation last');
            } else context.assert(await operation === true, 'shutdown did not finish');
            context.assert(ends.length === 1, 'repeated shutdown sent another end');
            chunks(host[stream], [ascii('tcp-first'), ascii('tcp-second')], 'TCP FIFO');
          });
      }
      for (const failure of ['reject', 'missing']) {
        const options = {[`${stream}Kind`]: 'tcp'};
        if (failure === 'reject') options[`${stream}End`] = () => Promise.reject(new Error('end failure'));
        await check(`tcp-shutdown-${failure}:${stream}`, options, async host => {
          const message = await host.task('failed_shutdown', [stream]);
          context.assert(message.length > 0 &&
            (failure === 'missing' || message.includes('end failure')), 'shutdown lost its hook failure');
          context.assert(host[stream].length === 0, 'EPIPE write reached the sink');
        });
      }
    }
    await check('stream-operations-require-runtime', {}, async host => {
      context.assert(await host.call('outside_task') === 12n, 'outside-Runtime matrix was incomplete');
    });
    await check('stream-operations-require-task', {}, async host => {
      context.assert(await host.task('registration_context') === 12n, 'outside-Task matrix was incomplete');
    });

    const lineChunks = ['first', '\n', '\nsec', '', 'ond\ntail'].map(encode);
    await check('stdin-chunks-empty-and-sticky-eof', {stdin: (() => {
      const source = [new Uint8Array([65, 0, 255]), new Uint8Array(), encode('Z'), null];
      return () => source.shift();
    })()}, host => task(host, 'read_chunks'));
    await check('io-lines-real-parent-empty-lines-and-tail',
      {stdin: (() => { const source = [...lineChunks, null]; return () => source.shift(); })()},
      host => task(host, 'lines'));
    for (const mode of ['normal', 'break', 'body-error', 'read-error', 'return']) {
      let reads = 0;
      await check(`io-lines-closes:${mode}`, {stdin: () => {
        reads++;
        if (mode === 'read-error' && reads === 2) return Promise.reject(new Error('line read failure'));
        return reads === 1 ? encode('first\n') : reads === 2 ? encode('second\n') : null;
      }}, host => task(host, 'tracked_lines', [mode]));
    }
    await check('stdin-split-multibyte-delimiter-retains-excess', {stdin: (() => {
      const source = ['ab<', '->cd<', '->tail'].map(encode);
      return () => source.shift();
    })()}, host => task(host, 'read_delimiter'));
    for (const failure of ['reject', 'throw', 'bad-value']) {
      let reads = 0;
      await check(`stdin-sticky-${failure}`, {stdin: () => {
        reads++;
        if (failure === 'bad-value') return 'not bytes';
        if (failure === 'throw') throw new Error('source throw');
        return Promise.reject(new Error('source reject'));
      }}, async host => {
        const message = await host.task('sticky_read_error');
        context.assert(message.length > 0 && reads === 1, 'stdin failure was not sticky');
        if (failure !== 'bad-value') context.assert(message.includes(`source ${failure}`),
          'stdin lost its source diagnostic');
      });
    }
    {
      let inputHost, reads = 0;
      const pending = [];
      await check('stdin-cancelled-reader-retains-arriving-chunk', {stdin: () => {
        reads++;
        return reads === 1 ? hold(inputHost, pending) : null;
      }}, async host => {
        inputHost = host;
        const operation = host.task('cancelled_reader_handoff');
        await until(context, () => pending.length === 1 && host.held.length === 1, 'reader did not wait');
        host.settleHeld();
        await until(context, () => host.notes.includes('reader-retired'), 'reader cancellation did not retire');
        context.assert(reads === 1, 'successor started a second source request');
        pending[0](new Uint8Array([...ascii('late'), 0, 255]));
        context.assert(await operation === true && reads === 2, 'successor lost the retained chunk');
      });
    }
    {
      let inputHost, reads = 0;
      const pending = [];
      await check('stdin-second-reader-is-rejected', {stdin: () => {
        reads++;
        return hold(inputHost, pending);
      }}, async host => {
        inputHost = host;
        const operation = host.task('contending_readers');
        await until(context, () => host.notes.includes('second-reader-rejected') && pending.length === 1,
          'second reader was not rejected');
        pending[0](encode('one'));
        context.assert(await operation === true && reads === 1, 'read contention changed the first request');
      });
    }
    {
      let reads = 0;
      await check('stdin-new-runtime-resets-eof', {stdin: () => {
        reads++;
        return reads === 2 ? encode('again') : null;
      }}, async host => {
        await task(host, 'read_eof');
        context.assert(reads === 1, 'EOF was not sticky in the first Runtime');
        await task(host, 'read_again');
        context.assert(reads === 3, 'new Runtime did not read again');
      });
    }
    await check('stdin-missing-source-is-unavailable-not-eof', {}, host => task(host, 'missing_input'));
    for (const supplied of [false, true]) {
      let reads = 0;
      await check(`c-stdin-errors-without-prompt:${supplied ? 'source' : 'absent'}`,
        supplied ? {stdin: () => { reads++; return encode('not C stdin'); }} : {}, async host => {
          await task(host, 'c_read_error');
          context.assert(reads === 0, 'C stdio unexpectedly consumed the SDK source');
        });
    }

    await check('run-exit7-cleans-peers-latches-and-keeps-host-alive', {}, async host => {
      const result = await host.instance.run(['exit']);
      context.assert(result.kind === 'exited' && result.status === 7 && result.bytes.length === 0,
        'run did not report exit 7 with empty bytes');
      context.assert(host.notes.join('|') === 'exit-peer-ready|exit-peer-cleanup', 'exit skipped peer cleanup');
      await rejection(context, host.call('outside_exit'), 'EXITED');
      await rejection(context, host.task('wall_time'), 'EXITED');
      await rejection(context, host.instance.drain(), 'EXITED');
      await rejection(context, host.instance.run(['return-c']), 'EXITED');
      await context.tick();
      await host.instance.dispose();
    });
    await check('plain-call-exit-refused-instance-still-usable', {}, async host => {
      context.assert(await host.call('outside_exit') === true, 'plain exit was not refused');
      context.assert(typeof await host.task('wall_time') === 'bigint', 'plain exit poisoned the instance');
    });
    await check('wall-time-matches-host-clock', {}, async host => {
      const before = Math.floor(Date.now() / 1000);
      const actual = Number(await host.task('wall_time'));
      const after = Math.floor(Date.now() / 1000);
      context.assert(actual >= before - 1 && actual <= after + 1, 'wall clock differs from the host');
    });
    const date = new Date(1700000000 * 1000);
    const local = [date.getFullYear(), date.getMonth() + 1, date.getDate(), date.getHours(),
      date.getMinutes(), date.getSeconds()].join(',');
    const utc = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(), date.getUTCHours(),
      date.getUTCMinutes(), date.getUTCSeconds()].join(',');
    for (const [format, expected] of [['*t', local], ['!*t', utc]]) {
      await check(`calendar-host-fields:${format}`, {}, async host => {
        context.assert(await host.task('calendar', [format]) === expected, 'calendar differs from host Date');
      });
    }
    await check('environment-c-getenv-sees-titan-mutations', {env: {FOO: 'bar', TZ: 'Asia/Tokyo'}},
      host => task(host, 'environment'));
    await check('environment-tz-does-not-change-host-calendar', {env: {FOO: 'bar', TZ: 'Asia/Tokyo'}},
      async host => {
        context.assert(await host.task('calendar', ['*t']) === local, 'TZ changed the host calendar');
      });
    context.assert(cases.length === 66 && dialogs === 0, 'embedding acceptance matrix is incomplete');
    context.assert(failures.length === 0, failures.join('\n'));
    context.stdout(encode('OS-STREAMS ' + JSON.stringify({verdict: 'PASS', cases: cases.length,
      dialogs, names: cases}) + '\n'));
  } finally {
    if (originalPrompt === undefined) delete globalThis.prompt;
    else globalThis.prompt = originalPrompt;
  }
}
