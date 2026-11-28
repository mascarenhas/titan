// The instance host of the real-browser durable storage gate
// (spec/browser/vfs-durable.test.mjs), shared by its page (page.mjs) and by
// the gate itself under Node. Each function takes and returns structured-
// clone values only, so the gate calls it through any engine's evaluation
// channel; instances a step keeps for a later step stay here, by key.
const held = new Map();

function failure(error) {
  return {name: error?.name ?? typeof error, code: error?.code ?? null, message: String(error?.message ?? error)};
}

async function settled(promise) {
  try {
    await promise;
    return null;
  } catch (error) {
    return failure(error);
  }
}

// One instance of the image at `url` whose output this host keeps as text.
async function instantiate(url, options) {
  const {default: create} = await import(url);
  const output = {stdout: '', stderr: ''}, decoders = {stdout: new TextDecoder(), stderr: new TextDecoder()};
  const sink = name => bytes => { output[name] += decoders[name].decode(bytes, {stream: true}); };
  const instance = create({...options, stdout: sink('stdout'), stderr: sink('stderr')});
  return {instance, output};
}

/**
 * Run main once with `args`, then dispose the instance: `disposal` is
 * "clean", "force" (dispose({force: true})) or "keep", which holds it under
 * `key` for dispose(). The report has main's result and output, and the
 * disposal's failure (null when it succeeded).
 */
export async function run(url, args, {vfs, disposal = 'clean', key} = {}) {
  const {instance, output} = await instantiate(url, vfs === undefined ? {} : {vfs});
  let result, error = null;
  try {
    result = await instance.run(args);
  } catch (cause) {
    error = failure(cause);
  }
  const report = {kind: result?.kind ?? null, status: result?.status ?? null,
    bytes: result?.bytes ? new TextDecoder().decode(result.bytes) : '', error, disposal: null};
  if (disposal === 'keep') held.set(key, {instance, output});
  else report.disposal = await settled(instance.dispose(disposal === 'force' ? {force: true} : undefined));
  return {...report, ...output};
}

/**
 * Initialize an instance and hold it under `key`. When initialization fails
 * the instance is disposed at once; the report has both failures.
 */
export async function initialize(url, key, {vfs} = {}) {
  const {instance, output} = await instantiate(url, vfs === undefined ? {} : {vfs});
  const error = await settled(instance.initialize());
  if (!error) {
    held.set(key, {instance, output});
    return {error, disposal: null};
  }
  return {error, disposal: await settled(instance.dispose())};
}

/** Dispose the instance held under `key`, by force if `force`. */
export async function dispose(key, {force = false} = {}) {
  const entry = held.get(key);
  if (!entry) throw new Error(`no instance is held as ${key}`);
  held.delete(key);
  const disposal = await settled(entry.instance.dispose(force ? {force: true} : undefined));
  return {disposal, ...entry.output};
}

/** The failure create(options) throws for the image at `url`, or null. */
export async function refusal(url, options) {
  const {default: create} = await import(url);
  try {
    await create(options).dispose();
    return null;
  } catch (error) {
    return failure(error);
  }
}
