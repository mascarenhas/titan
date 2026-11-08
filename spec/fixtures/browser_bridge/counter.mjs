// The html5 click counter on a real page: each button's Emscripten click
// callback calls a pinned Titan handler synchronously, so the label already
// shows the new count when click() returns. A failed second registration
// unregisters the first before main fails, so no callback outlives setup.
function counter(image, label) {
  const decoder = new TextDecoder();
  const host = {stderr: '', stop: undefined};
  host.instance = image.create({locateFile: image.locateFile,
    stderr: bytes => { host.stderr += decoder.decode(bytes); },
    bindings: {
      show: count => { label.textContent = String(count); },
      ready: callable => { host.stop = callable; },
    }});
  return host;
}

export async function run(context) {
  context.assert(context.args.length === 1, 'pass the counter image');
  context.assert(typeof document === 'object', 'the counter needs a page with a DOM');
  const image = await context.image(context.args[0]);
  const page = document.createElement('div');
  page.innerHTML = '<button id="increment">+</button><button id="reset">reset</button><output id="count"></output>';
  document.body.append(page);
  const label = page.querySelector('#count');
  const increment = page.querySelector('#increment');
  const reset = page.querySelector('#reset');
  const shown = [];
  const click = button => { button.click(); shown.push(label.textContent); };
  try {
    const failed = counter(image, label);
    try {
      const result = await failed.instance.run(['#missing']);
      context.assert(result.kind === 'failed' && result.status === 1 &&
        new TextDecoder().decode(result.bytes) === 'cannot listen for clicks on #missing',
        `a failed registration gave ${result.kind}/${result.status}`);
      increment.click();
      context.assert(label.textContent === '' && !failed.stderr.includes('click handler failed'),
        'a listener registered before the failed one survived it');
    } finally {
      await failed.instance.dispose();
    }

    const host = counter(image, label);
    try {
      const result = await host.instance.run([]);
      context.assert(result.kind === 'returned' && result.status === 0, `main returned ${result.kind}/${result.status}`);
      context.assert(label.textContent === '0' && host.stop !== undefined, 'main did not show 0 and publish stop');
      click(increment);
      click(increment);
      click(increment);
      click(reset);
      click(increment);
      context.assert(shown.join(',') === '1,2,3,0,1', `the clicks showed ${shown.join(',')}`);
      await host.instance.call(host.stop);
      host.stop = undefined;
      click(increment);
      context.assert(label.textContent === '1', 'a click after stop reached the handler');
      context.assert(host.stderr === '', `a click handler failed: ${host.stderr}`);
    } finally {
      // Unregister before disposal frees what the callbacks reach.
      if (host.stop) await host.instance.call(host.stop);
      await host.instance.dispose();
    }
  } finally {
    page.remove();
  }
  context.stdout(new TextEncoder().encode(`COUNTER {"verdict":"PASS","shown":"${shown.join(',')}"}\n`));
}
