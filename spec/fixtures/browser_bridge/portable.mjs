import { portable } from './titan-protobuf.mjs';
import { peerTests } from './portable-peer.mjs';

const prefix = 'browser.portable_tests.';
const bytes = text => Uint8Array.from(text, character => character.charCodeAt(0));
const hex = text => Uint8Array.from(text.match(/../g) ?? [], pair => parseInt(pair, 16));
const write = (context, text) => context.stdout(new TextEncoder().encode(text));
// More than twice browserlink.lua's default `initial_heap` (15 MiB), so one copy
// cannot fit in the image's initial memory. portable_tests.browser.titan builds
// a payload of the same length.
const LARGE_PAYLOAD = 33554433;
const grew = (context, before, after, direction) => context.assert(before < LARGE_PAYLOAD && after >= LARGE_PAYLOAD,
  `${direction} memory did not grow past the payload: ${before} -> ${after}`);

function equal(context, actual, expected, label) {
  if (Object.is(actual, expected)) return;
  context.assert(typeof actual === typeof expected && actual !== null && expected !== null, label);
  if (actual instanceof Uint8Array || expected instanceof Uint8Array) {
    context.equalBytes(actual, expected, label);
  } else if (Array.isArray(actual) || Array.isArray(expected)) {
    context.assert(Array.isArray(actual) && Array.isArray(expected) && actual.length === expected.length, label);
    context.assert(Object.isFrozen(actual) === Object.isFrozen(expected), `${label} constness`);
    for (let index = 0; index < expected.length; index++) equal(context, actual[index], expected[index], `${label}[${index}]`);
  } else {
    context.assert(typeof actual === 'object' && Object.getPrototypeOf(actual) === Object.getPrototypeOf(expected), `${label} class`);
    equal(context, Object.keys(actual), Object.keys(expected), `${label} fields`);
    for (const key of Object.keys(expected)) equal(context, actual[key], expected[key], `${label}.${key}`);
  }
}

function rejects(context, action, code, path) {
  try { action(); } catch (error) {
    context.assert(error instanceof TypeError && error.code === code && error.path === path, `${code} at ${path}: ${error}`);
    return;
  }
  throw new Error(`expected ${code} at ${path}`);
}

async function rejectsTitan(context, action, message) {
  try { await action(); } catch (error) {
    context.assert(error.code === 'TITAN_BROWSER_TITAN', `expected Titan rejection: ${error}`);
    if (message) context.assert(error.message.includes(message), `missing ${message}: ${error}`);
    return;
  }
  throw new Error('expected Titan rejection');
}

function fixture(name, codec) {
  const Point = codec.types[prefix + 'Point'];
  const Choice = codec.types[prefix + 'Choice'];
  const PublicUnion = codec.types[prefix + 'PublicUnion'];
  switch (name) {
    case 'golden': return [-7n, bytes('A\0B'), false, null];
    case 'point': return [new Point(3n, bytes('x'))];
    case 'empty': return [new Choice.variants.empty()];
    case 'integer': case 'closed': return [7n];
    case 'scalars': return [null, false, -(1n << 63n), (1n << 63n) - 1n, 1, -0, bytes('A\0\xffB')];
    case 'unions': return [new Choice.variants.empty(), new Choice.variants.scalar(12n),
      new Choice.variants.pair(new Point(9n, bytes('nine')), null),
      new PublicUnion.variants.shown(5n), new PublicUnion.variants.empty()];
    case 'arrays': return [[1n, null, 3n], Object.freeze([1n, null, 3n]),
      [1n, null, 3n], Object.freeze([1n, null, 3n])];
    case 'values': return [null, false, 7n, 1, bytes('\0\xff'), new Point(4n, bytes('four')),
      new Choice.variants.scalar(6n), [true, null, bytes('bytes')], Object.freeze([true, null, bytes('bytes')])];
    case 'graphs': {
      const Node = codec.types[prefix + 'Node'], Pair = codec.types[prefix + 'Pair'];
      const shared = new Point(2n, bytes('two'));
      return [new Node(new Node(null, 2n), 1n), new Pair(shared, shared)];
    }
    case 'text': {
      const Caption = codec.types[prefix + 'Caption'], Notice = codec.types[prefix + 'Notice'];
      const text = '\uFEFFcaf\u00e9';
      return [text, new Caption(text), new Notice.variants.text(text), [text, null, 'ok']];
    }
    case 'view': return [new (codec.types[prefix + 'PublicView'])(11n)];
    case 'encode_only': return [new (codec.types[prefix + 'EncodeOnly'])(9n)];
    case 'benchmark': return [Array.from({ length: 10000 }, (_, index) => BigInt(index + 1))];
    default: throw new Error(`unexpected native fixture ${name}`);
  }
}

async function withInstance(context, image, action) {
  const records = new Map(), controls = new Map(), wrappers = new Set();
  let output = '', textError, textErrors = 0, textSuccesses = 0;
  const instance = image.create({
    locateFile: image.locateFile,
    stdout(chunk) { output += new TextDecoder().decode(chunk); context.stdout(chunk); },
    stderr: context.stderr,
    bindings: {
      publish(name, description, encoded, receive) {
        context.assert(!records.has(name) && encoded instanceof Uint8Array &&
          receive && typeof receive.call === 'function' && typeof receive.release === 'function', `publish ${name}`);
        wrappers.add(receive);
        records.set(name, { description, encoded, receive });
      },
      control(name, callback) {
        context.assert(!controls.has(name) && callback &&
          typeof callback.call === 'function' && typeof callback.release === 'function', `control ${name}`);
        wrappers.add(callback);
        controls.set(name, callback);
      },
      decode_text(description, encoded) {
        try { portable(description).decode(encoded); } catch (error) {
          context.assert(error.code === 'invalid_utf8' && error.path === '$[1]', `text diagnostic: ${error}`);
          textError = error;
          textErrors++;
          throw error;
        }
        textSuccesses++;
        return true;
      },
      check_text_error(error) {
        return error === textError && error instanceof TypeError && error.code === 'invalid_utf8' && error.path === '$[1]';
      },
      clock: () => performance.now(),
      report_cost(start, finish) {
        write(context, `portable cost Titan encode+decode 10000 integers: ${(finish - start).toFixed(3)} ms\n`);
      },
    },
  });
  try {
    const result = await instance.run([]);
    context.assert(result.kind === 'returned' && result.status === 0, 'native portable tests failed');
    context.assert(/\[  PASSED  \] 17 tests\./.test(output), 'native portable test count');
    context.assert(records.size === 14 && controls.size === 3, 'published portable fixtures');
    context.assert(textErrors === 1 && textSuccesses === 1, 'text error recovery');
    await action(records, controls);
  } finally {
    for (const wrapper of wrappers) wrapper.release();
    await instance.dispose();
  }
}

export async function run(context) {
  const peerAssertions = await peerTests();
  context.assert(peerAssertions > 0, 'standalone peer tests did not run');
  const image = await context.image(context.args[0]);
  const golden = new Map([
    ['golden', '080d12034100421800'], ['point', '0a050806120178'],
    ['empty', '0a020a00'], ['integer', '0a02100e'],
  ]);
  await withInstance(context, image, async (records, controls) => {
    for (const [name, entry] of records) {
      const codec = entry.codec = portable(entry.description);
      const expected = fixture(name, codec), decoded = codec.decode(entry.encoded);
      equal(context, decoded, expected, `${name} Titan to JavaScript`);
      context.equalBytes(codec.encode(...decoded), entry.encoded, `${name} peer re-encode`);
      if (golden.has(name)) context.equalBytes(entry.encoded, hex(golden.get(name)), `${name} Titan golden`);
      if (name === 'graphs') context.assert(decoded[1].left !== decoded[1].right, 'repeated objects must be copied');
      if (name === 'unions') context.assert(!Object.hasOwn(codec.types[prefix + 'PublicUnion'].variants, 'hidden'), 'private arm exposed');
      if (name === 'view') context.assert(!Object.hasOwn(decoded[0], 'secret'), 'local field exposed');
      const encoded = codec.encode(...expected);
      context.equalBytes(encoded, entry.encoded, `${name} JavaScript golden`);
      if (name === 'encode_only') {
        await rejectsTitan(context, () => entry.receive.call(encoded), 'EncodeOnly has no public constructor');
        context.assert(await records.get('point').receive.call(records.get('point').encoded), 'recovery after encode-only decode');
      } else {
        context.assert(await entry.receive.call(encoded) === true, `${name} JavaScript to Titan`);
      }
    }
    const point = records.get('point'), graphs = records.get('graphs'), closed = records.get('closed');
    const shared = portable(point.description, point.codec.types);
    context.assert(shared.types[prefix + 'Point'] === point.codec.types[prefix + 'Point'], 'shared class identity');
    context.equalBytes(shared.encode(...point.codec.decode(point.encoded)), point.encoded, 'shared classes between codecs');
    rejects(context, () => point.codec.encode({ x: 3n, label: bytes('x') }), 'type_mismatch', '$[1]');
    context.assert(await point.receive.call(point.encoded), 'recovery after plain object');
    await rejectsTitan(context, () => point.receive.call(new Uint8Array()));
    context.assert(await point.receive.call(point.encoded), 'recovery after missing required field');
    const Node = graphs.codec.types[prefix + 'Node'], cyclic = new Node(null, 1n);
    cyclic.next = cyclic;
    rejects(context, () => graphs.codec.encode(cyclic, fixture('graphs', graphs.codec)[1]), 'cycle', '$[1]["next"]');
    context.assert(await graphs.receive.call(graphs.encoded), 'recovery after cycle');
    const dynamic = portable(JSON.stringify({ fields: ['value'], nominals: JSON.parse(point.description).nominals }), point.codec.types);
    const unlisted = dynamic.encode(new (point.codec.types[prefix + 'Point'])(3n, bytes('x')));
    rejects(context, () => closed.codec.decode(unlisted), 'unknown_type', '$[1]');
    rejects(context, () => closed.codec.encode(new (point.codec.types[prefix + 'Point'])(3n, bytes('x'))), 'type_mismatch', '$[1]');
    await rejectsTitan(context, () => closed.receive.call(unlisted), 'browser.portable_tests.Point');
    context.assert(await closed.receive.call(closed.encoded), 'recovery after unlisted nominal');

    const benchmark = records.get('benchmark'), integers = fixture('benchmark', benchmark.codec);
    const start = performance.now();
    const encoded = benchmark.codec.encode(...integers);
    const decoded = benchmark.codec.decode(encoded);
    const finish = performance.now();
    equal(context, decoded, integers, 'JavaScript cost fixture');
    write(context, `portable cost JavaScript encode+decode 10000 integers: ${(finish - start).toFixed(3)} ms\n`);

    const before = await controls.get('heap').call();
    const large = await controls.get('grow_out').call();
    const after = await controls.get('heap').call();
    grew(context, before, after, 'Titan to JavaScript');
    const byteCodec = portable(JSON.stringify({ fields: ['bytes'], nominals: {} }));
    const [payload] = byteCodec.decode(large);
    context.assert(payload.length === LARGE_PAYLOAD && payload[0] === 0 && payload[1] === 255 && payload.at(-1) === 65, 'large Titan payload');
    context.equalBytes(byteCodec.encode(payload), large, 'large Titan to JavaScript round trip');
    context.equalBytes(point.encoded, hex(golden.get('point')), 'copied bytes survive memory growth');
    context.assert(await point.receive.call(point.encoded), 'small call after outbound growth');
  });
  await withInstance(context, image, async (records, controls) => {
    const codec = portable(JSON.stringify({ fields: ['bytes'], nominals: {} }));
    const payload = new Uint8Array(LARGE_PAYLOAD);
    for (let index = 0; index < payload.length; index += 3) { payload[index + 1] = 255; payload[index + 2] = 65; }
    const encoded = codec.encode(payload), before = await controls.get('heap').call();
    const returned = await controls.get('grow_in').call(encoded), after = await controls.get('heap').call();
    grew(context, before, after, 'JavaScript to Titan');
    context.equalBytes(returned, encoded, 'large JavaScript to Titan round trip');
    const point = records.get('point');
    context.assert(await point.receive.call(point.encoded), 'small call after inbound growth');
  });
  write(context, `PASS portable bridge (${context.engine}, ${peerAssertions} peer assertions)\n`);
}
