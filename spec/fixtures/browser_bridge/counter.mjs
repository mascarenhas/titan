// The html5 click counter on a real page: each button's Emscripten click
// callback calls a pinned Titan handler synchronously, so the label already
// shows the new count when click() returns.
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
  const decoder = new TextDecoder();
  let stderr = '';
  let stop;
  const instance = image.create({locateFile: image.locateFile,
    stderr: bytes => { stderr += decoder.decode(bytes); },
    bindings: {
      show: count => { label.textContent = String(count); },
      ready: callable => { stop = callable; },
    }});
  const shown = [];
  const click = button => { button.click(); shown.push(label.textContent); };
  try {
    const result = await instance.run([]);
    context.assert(result.kind === 'returned' && result.status === 0, `main returned ${result.kind}/${result.status}`);
    context.assert(label.textContent === '0' && stop !== undefined, 'main did not show 0 and publish stop');
    click(increment);
    click(increment);
    click(increment);
    click(reset);
    click(increment);
    context.assert(shown.join(',') === '1,2,3,0,1', `the clicks showed ${shown.join(',')}`);
    await instance.call(stop);
    click(increment);
    context.assert(label.textContent === '1', 'a click after stop reached the handler');
    context.assert(stderr === '', `a click handler failed: ${stderr}`);
  } finally {
    await instance.dispose();
    page.remove();
  }
  context.stdout(new TextEncoder().encode(`COUNTER {"verdict":"PASS","shown":"${shown.join(',')}"}\n`));
}
