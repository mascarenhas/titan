// The optional URL lets Node and Chromium exercise the same staged SDK module.
export async function peerTests(peerURL = new URL('./titan-protobuf.mjs', import.meta.url)) {
  const { portable } = await import(peerURL);
  let assertions = 0;
  function check(condition, label) {
    assertions++;
    if (!condition) throw new Error(`portable peer: ${label}`);
  }
  function equal(actual, expected, label) {
    if (Object.is(actual, expected)) return;
    check(typeof actual === typeof expected && actual !== null && expected !== null, label);
    if (actual instanceof Uint8Array || expected instanceof Uint8Array) {
      check(actual instanceof Uint8Array && expected instanceof Uint8Array && actual.length === expected.length, label);
      actual.forEach((byte, i) => check(byte === expected[i], `${label}[${i}]`)); return;
    }
    if (Array.isArray(actual) || Array.isArray(expected)) {
      check(Array.isArray(actual) && Array.isArray(expected) && actual.length === expected.length, label);
      check(Object.isFrozen(actual) === Object.isFrozen(expected), `${label} constness`);
      for (let i = 0; i < actual.length; i++) equal(actual[i], expected[i], `${label}[${i}]`);
      return;
    }
    check(typeof actual === 'object', label);
    equal(Object.keys(actual), Object.keys(expected), `${label} keys`);
    for (const key of Object.keys(expected)) equal(actual[key], expected[key], `${label}.${key}`);
  }
  function rejects(body, fragment, label = fragment) {
    try { body(); } catch (error) {
      check(error instanceof TypeError && error.message.startsWith('titan protobuf: ') && error.message.includes(fragment), `${label}: ${error}`);
      return;
    }
    throw new Error(`portable peer: expected rejection: ${label}`);
  }
  const bytes = (...values) => Uint8Array.from(values);
  const hex = source => Uint8Array.from(source.replaceAll(' ', '').match(/../g) ?? [], pair => parseInt(pair, 16));
  const concat = (...parts) => {
    const result = new Uint8Array(parts.reduce((size, part) => size + part.length, 0));
    let offset = 0;
    for (const part of parts) { result.set(part, offset); offset += part.length; }
    return result;
  };
  const varint = value => {
    const result = [];
    do { result.push(Number(value & 127n) | (value > 127n ? 128 : 0)); value >>= 7n; } while (value);
    return Uint8Array.from(result);
  };
  const nested = (field, payload) => concat(varint(BigInt(field * 8 + 2)), varint(BigInt(payload.length)), payload);
  const codec = (fields, nominals = {}) => portable(JSON.stringify({ fields, nominals }));
  function round(type, value, expected = value ?? undefined, nominals = {}) {
    const c = codec([type], nominals), encoded = c.encode(value), decoded = c.decode(encoded);
    equal(decoded, [expected], `${JSON.stringify(type)} round trip`);
    equal(c.encode(...decoded), encoded, 'canonical bytes');
    return encoded;
  }

  // Hand-derived wire literals, provisional until matched against Titan output.
  const scalar = codec(['nil', 'boolean', 'integer', 'float', 'bytes', 'text', ['option', 'integer'], 'value']);
  const scalarValues = [undefined, false, -1n, -0, bytes(0, 255, 195, 40), '\ufeffA', undefined, 9007199254740993n];
  const scalarGolden = hex('10 00 18 01 21 0000000000000080 2a 04 00ffc328 32 04 efbbbf41 42 09 10 8280808080808020');
  equal(scalar.encode(...scalarValues), scalarGolden, 'scalar golden');
  equal(scalar.decode(scalarGolden), scalarValues, 'scalar golden decode');
  equal(scalar.encode(...scalar.decode(scalarGolden)), scalarGolden, 'scalar golden canonical');
  const arrayGolden = hex('0a 0e 0a02 0802 0a00 0a04 08818001 1001');
  equal(round(['array', 'maybe', 'integer'], Object.freeze([1n, undefined, -8193n])), arrayGolden, 'array golden');
  for (const integer of [0n, -1n, 9007199254740993n, -(1n << 63n), (1n << 63n) - 1n]) round('integer', integer);
  rejects(() => codec(['integer']).encode(1), 'field 1: expected a bigint');
  for (const integer of [1n << 63n, -(1n << 63n) - 1n]) rejects(() => codec(['integer']).encode(integer), 'out of range');
  for (const float of [1, -0, NaN, Infinity, -Infinity]) round('float', float);
  rejects(() => codec(['float']).encode(1n), 'expected a number');
  for (const flag of [false, true]) round('boolean', flag);
  rejects(() => codec(['boolean']).encode(0), 'expected a boolean');
  round('nil', undefined); round('nil', null, undefined);
  round(['option', 'integer'], undefined); round(['option', 'integer'], null, undefined); round(['option', 'integer'], 0n);
  rejects(() => codec(['nil']).encode(false), 'expected nil');
  for (const value of [bytes(), bytes(0, 255, 195, 40)]) round('bytes', value);
  for (const value of ['', 'a\0b', '\ufeffstart', '😀']) round('text', value);
  rejects(() => codec(['text']).encode('\ud800'), 'well-formed text');
  rejects(() => codec(['text']).decode(bytes(10, 2, 195, 40)), 'invalid UTF-8');
  for (const value of [[], new Uint16Array(1), new DataView(new ArrayBuffer(1)), { [Symbol.toStringTag]: 'Uint8Array' }])
    rejects(() => codec(['bytes']).encode(value), 'expected a Uint8Array');
  const original = bytes(1, 2), copied = round('bytes', original);
  original[0] = 9; check(copied[2] === 1, 'encode copies bytes');
  const input = bytes(10, 2, 1, 2), decodedBytes = codec(['bytes']).decode(input)[0];
  input[2] = 9; check(decodedBytes[0] === 1, 'decode copies bytes');
  const subarray = bytes(9, 10, 2, 1, 2, 9).subarray(1, 5);
  equal(codec(['bytes']).decode(subarray), [bytes(1, 2)], 'bounded input view');

  for (const qualifier of ['mutable', 'const', 'maybe']) {
    for (const frozen of [false, true]) {
      const value = frozen ? Object.freeze([1n, undefined, 2n]) : [1n, undefined, 2n];
      const expected = qualifier === 'const' || qualifier === 'maybe' && frozen ? Object.freeze([1n, undefined, 2n]) : [1n, undefined, 2n];
      round(['array', qualifier, 'integer'], value, expected);
    }
  }
  round(['array', 'maybe', 'integer'], []);
  round(['array', 'maybe', 'integer'], Object.freeze([]));
  round(['array', 'mutable', 'integer'], [1n, undefined, undefined], [1n]);
  equal(codec([['array', 'mutable', 'integer']]).decode(hex('0a 02 1001')), [Object.freeze([])], 'wire constness wins on decode');
  equal(codec([['array', 'const', 'integer']]).decode(hex('0a 02 1000')), [[]], 'wire mutable wins on decode');
  for (const value of [undefined, false, true, 0n, -1n, 9007199254740993n, 1, -0, NaN, Infinity, -Infinity, bytes(0, 255), [false, undefined, 2n], Object.freeze([1])]) round('value', value);
  round('value', null, undefined);
  rejects(() => codec(['value']).encode('not bytes'), 'unsupported dynamic');
  rejects(() => codec(['value']).encode({ $type: 'unknown.Name' }), 'unlisted nominal');
  const cyclicArray = []; cyclicArray[0] = cyclicArray;
  const dynamicCodec = codec(['value']);
  rejects(() => dynamicCodec.encode(cyclicArray), 'cyclic object graph');
  round('value', [1n]); // A failed call must not poison another call.
  equal(dynamicCodec.decode(dynamicCodec.encode(1n)), [1n], 'failed codec remains usable');
  const holes = codec([['array', 'maybe', 'integer']]).decode(hex('0a0c0a0208020a000a0208041000'))[0];
  check(holes.length === 3 && Object.hasOwn(holes, 1) && holes[1] === undefined, 'interior hole decodes as undefined');

  const record = (name, fields) => ({ $type: name, ...fields });
  const nominals = {
    'app.Point': { module: 'app', record: [['x', 'integer'], ['y', 'float']] },
    'app.Token': { module: 'app', opaque: true },
    'app.Pair': { module: 'app', record: [['left', ['nominal', 'app.Point']], ['right', ['nominal', 'app.Point']]] },
    'app.Proto': { module: 'app', record: [['__proto__', 'integer']] },
  };
  const point = record('app.Point', { x: -1n, y: 1 });
  const pointGolden = hex('0a0b 0801 11000000000000f03f');
  equal(round(['nominal', 'app.Point'], point, point, nominals), pointGolden, 'record golden');
  round('value', point, point, nominals);
  const dynamicPointGolden = hex('0a1f 2a1d 0a03617070 12096170702e506f696e74 1a0b080111000000000000f03f');
  const nominalCodec = codec(['value'], nominals);
  equal(nominalCodec.encode(point), dynamicPointGolden, 'dynamic nominal golden');
  equal(nominalCodec.decode(dynamicPointGolden), [point], 'dynamic nominal golden decode');
  rejects(() => codec(['value']).decode(dynamicPointGolden), 'unlisted nominal');
  rejects(() => nominalCodec.decode(hex('0a0d2a0b12096170702e506f696e74')), '$module: missing required');
  rejects(() => nominalCodec.decode(hex('0a122a100a0361707012096170702e506f696e74')), 'missing required');
  rejects(() => nominalCodec.decode(hex('0a042a020a00')), '$type: missing required');
  const token = record('app.Token', { bytes: bytes(0, 255) });
  equal(round(['nominal', 'app.Token'], token, token, nominals), hex('0a0200ff'), 'opaque golden');
  round('value', token, token, nominals);
  round(['nominal', 'app.Proto'], record('app.Proto', { ['__proto__']: 1n }), undefined, nominals);
  const pointCodec = codec([['nominal', 'app.Point']], nominals);
  rejects(() => pointCodec.encode({ x: 1n, y: 1 }), 'expected nominal');
  rejects(() => pointCodec.encode(record('wrong.Point', { x: 1n, y: 1 })), 'expected nominal');
  rejects(() => pointCodec.encode(record('app.Point', { y: 1 })), 'field 1.x: expected a bigint');
  rejects(() => pointCodec.encode(Object.create(point)), 'expected nominal');
  const inheritedField = record('app.Point', { y: 1 }); Object.setPrototypeOf(inheritedField, { x: 1n });
  rejects(() => pointCodec.encode(inheritedField), 'field 1.x: expected a bigint');
  rejects(() => pointCodec.decode(hex('0a00')), 'missing required');
  const pair = record('app.Pair', { left: point, right: point }), pairCodec = codec([['nominal', 'app.Pair']], nominals);
  const pairResult = pairCodec.decode(pairCodec.encode(pair))[0];
  equal(pairResult, pair, 'repeated reference copied');
  check(pairResult.left !== pairResult.right && pairResult.left !== point, 'decode does not preserve aliases');
  equal(pointCodec.decode(concat(hex('0a020801'), hex('0a0911000000000000f03f'))), [point], 'record messages merge');
  const cyclicRecord = record('app.Link', { value: 1n }); cyclicRecord.next = cyclicRecord;
  rejects(() => codec([['nominal', 'app.Link']], {
    'app.Link': { module: 'app', record: [['next', ['option', ['nominal', 'app.Link']]], ['value', 'integer']] },
  }).encode(cyclicRecord), 'cyclic object graph');
  const largeBytes = new Uint8Array(17000); largeBytes[16999] = 255;
  round(['nominal', 'app.Token'], record('app.Token', { bytes: largeBytes }), undefined, nominals);

  equal(codec(['integer']).decode(hex('0802 0804 900301')), [2n], 'last scalar wins, unknown varint skipped');
  equal(codec(['integer']).decode(hex('0802 9903 0000000000000000 a20302 ffff ad0300000000')), [1n], 'unknown fixed64, bytes and fixed32 skipped');
  equal(codec(['value']).decode(hex('0a 04 0801 1002')), [1n], 'last dynamic arm wins');
  equal(codec(['value']).decode(hex('0a 02 3801')), [undefined], 'no recognized arm');
  equal(codec(['value']).decode(hex('0a02 0801 0a02 1002')), [1n], 'dynamic messages merge');
  equal(codec([['array', 'maybe', 'integer']]).decode(hex('0a06 0a0208021000 0a06 0a0208041001')), [Object.freeze([1n, 2n])], 'array messages merge and append');
  equal(codec([['array', 'maybe', 'value']]).decode(hex('0a06 0a020a001000')), [[]], 'empty dynamic slot does not extend length');
  const recursive = { 'app.Link': { module: 'app', record: [['next', ['option', ['nominal', 'app.Link']]], ['value', 'integer']] } };
  const linkCodec = codec([['nominal', 'app.Link']], recursive);
  function chain(count) {
    let result;
    while (count--) result = { $type: 'app.Link', next: result, value: 1n };
    return result;
  }
  const limitBytes = linkCodec.encode(chain(126));
  equal(linkCodec.decode(limitBytes), [chain(126)], 'root depth starts at two, 126 records accepted');
  rejects(() => linkCodec.encode(chain(127)), 'nesting exceeds 128 levels');
  function chainBytes(count) {
    let result = hex('1002');
    while (--count) result = concat(nested(1, result), hex('1002'));
    return nested(1, result);
  }
  rejects(() => linkCodec.decode(chainBytes(127)), 'nesting exceeds 128 levels');
  // Every container has a boundary check even if its final contents are empty.
  let arrayType = 'integer', arrayValue = 1n;
  for (let i = 0; i < 126; i++) { arrayType = ['array', 'maybe', arrayType]; arrayValue = [arrayValue]; }
  round(arrayType, arrayValue);
  round('value', arrayValue);
  rejects(() => dynamicCodec.encode([arrayValue]), 'nesting exceeds 128 levels');
  rejects(() => codec([['array', 'maybe', arrayType]]).encode([arrayValue]), 'nesting exceeds 128 levels');
  for (const malformed of ['00', '80', '08 80', '0a80', '0a0200', '0a01', '09 00000000000000', '0b0c', '0f', '8080808010', '08 ffffffffffffffffff02', '0a8080808008'])
    rejects(() => codec(['integer']).decode(hex(malformed)), '', `malformed ${malformed}`);
  rejects(() => codec(['integer']).decode(hex('0a00')), 'unexpected wire type');
  rejects(() => codec(['boolean']).decode(hex('0802')), 'invalid boolean');
  rejects(() => codec([['array', 'maybe', 'integer']]).decode(hex('0a0410021000')), 'invalid boolean');
  rejects(() => codec(['integer']).decode(bytes()), 'missing required');
  rejects(() => codec(['integer']).encode(), 'field count');
  rejects(() => codec([]).encode(1n), 'field count');
  rejects(() => codec([]).decode([]), 'input');
  // A zero-filled typed array reserves address space without touching 2 GiB.
  const oversized = new Uint8Array(2 ** 31);
  rejects(() => codec([]).decode(oversized), 'message exceeds size limit');
  rejects(() => codec(['bytes']).encode(oversized), 'message exceeds size limit');
  for (const source of ['not JSON', 'null', '{}', '{"fields":["unknown"],"nominals":{}}', '{"fields":[["nominal","missing"]],"nominals":{}}', '{"fields":[["array","wrong","integer"]],"nominals":{}}'])
    rejects(() => portable(source), 'description');
  // Crossing the reserved field-number interval is observable without 19,000 values.
  const reservedFields = Array(19001).fill('nil'); reservedFields[18999] = 'integer';
  const reservedValues = Array(19001).fill(undefined); reservedValues[18999] = 1n;
  const reserved = codec(reservedFields), reservedBytes = hex('80e20902');
  equal(reserved.encode(...reservedValues), reservedBytes, 'reserved ordinals skipped');
  equal(reserved.decode(reservedBytes), reservedValues, 'reserved ordinal decode');
  return assertions;
}
