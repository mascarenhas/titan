import create from './http.mjs';

const parameters = new URL(location.href).searchParams;
const env = JSON.parse(parameters.get('config'));
const token = parameters.get('token');
const chunks = [], errors = [];
const stdout = new TextDecoder(), stderr = new TextDecoder();
// A missing or foreign trace table fails initialization instead of degrading.
const instance = create({env, requireTrace: true, locateFile: name => new URL(name, import.meta.url).href,
  bindings: {net_publish() {}, net_note() {}},
  stdout(bytes) { chunks.push(stdout.decode(bytes, {stream: true})); },
  stderr(bytes) { chunks.push(stderr.decode(bytes, {stream: true})); },
  onNotificationError(error) { errors.push(error); }});
let ok = false, passed = 0;
try {
  const result = await instance.run(['--filter=^http[.]browser_tests[.]test_same_origin_cache_modes$']);
  const match = chunks.join('').match(/\[  PASSED  \] (\d+) tests?\./);
  passed = match ? Number(match[1]) : 0;
  ok = result.kind === 'returned' && result.status === 0 && passed === 1 && errors.length === 0;
} catch (error) { chunks.push(error.stack || String(error)); }
finally {
  try { await instance.dispose(); } catch (error) { ok = false; chunks.push(String(error)); }
  if (errors.length) { ok = false; chunks.push(JSON.stringify(errors)); }
  chunks.push(stdout.decode(), stderr.decode());
}
parent.postMessage({token, ok, passed, output: chunks.join('')}, parameters.get('parentOrigin'));
