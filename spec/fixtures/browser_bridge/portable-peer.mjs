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
    check(typeof actual === 'object' && Object.getPrototypeOf(actual) === Object.getPrototypeOf(expected), `${label} class`);
    equal(Object.keys(actual), Object.keys(expected), `${label} keys`);
    for (const key of Object.keys(expected)) equal(actual[key], expected[key], `${label}.${key}`);
  }
  function rejects(body, code, path) {
    try { body(); } catch (error) {
      check(error instanceof TypeError && error.message.startsWith(`titan protobuf: ${error.path}: `), `diagnostic: ${error}`);
      check(error.code === code, `expected ${code}, got ${error.code}: ${error}`);
      check(typeof error.path === 'string' && /^\$(?:\[[1-9][0-9]*\]|\["(?:[^"\\]|\\.)*"\])*$/.test(error.path), `path syntax: ${error.path}`);
      if (path !== undefined) check(error.path === path, `expected ${path}, got ${error.path}`);
      return;
    }
    throw new Error(`portable peer: expected ${code}`);
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
  const codec = (fields, nominals = {}, types) => portable(JSON.stringify({ fields, nominals }), types);
  function round(c, values, expected = values) {
    const encoded = c.encode(...values), decoded = c.decode(encoded);
    equal(decoded, expected, 'round trip');
    equal(c.encode(...decoded), encoded, 'canonical bytes');
    return encoded;
  }
  const scalarRound = (type, value, expected = value ?? null) => round(codec([type]), [value], [expected]);

  // These four literals were produced by Titan's portable codec fixture.
  const scalar = codec(['integer', 'bytes', 'boolean', ['option', 'integer']]);
  const scalarValues = [-7n, bytes(65, 0, 66), false, null], scalarGolden = bytes(8, 13, 18, 3, 65, 0, 66, 24, 0);
  equal(round(scalar, scalarValues), scalarGolden, 'Titan scalar golden');
  equal(scalar.decode(scalarGolden), scalarValues, 'Titan scalar golden decode');
  const nominals = {
    'app.Point': { module: 'app', record: [['x', 'integer'], ['label', 'bytes']] },
    'app.Choice': { module: 'app', union: [['empty', []], ['count', [['value', 'integer']]], ['pair', [['left', ['nominal', 'app.Point']], ['right', ['nominal', 'app.Point']]]]] },
    'app.Other': { module: 'app', union: [['count', [['value', 'integer']]]] },
    'app.Names': { module: 'app', union: [['name', []], ['length', []], ['prototype', []]] },
    'app.Twin': { module: 'app', record: [['x', 'integer'], ['label', 'bytes']] },
    'app.Bundle': { module: 'app', record: [['items', ['array', 'maybe', ['nominal', 'app.Point']]]] },
    'app.Link': { module: 'app', record: [['next', ['option', ['nominal', 'app.Link']]], ['value', 'integer']] },
    'app.Text': { module: 'app', record: [['name', 'text']] },
    'app.Box': { module: 'app', union: [['text', [['left', ['nominal', 'app.Text']]]]] },
    'app.Proto': { module: 'app', record: [['__proto__', 'integer']] },
  };
  const pointCodec = codec([['nominal', 'app.Point']], nominals);
  const Point = pointCodec.types['app.Point'], Choice = pointCodec.types['app.Choice'];
  const { empty: Empty, count: Count, pair: Pair } = Choice.variants;
  const point = new Point(3n, bytes(120)), pointGolden = bytes(10, 5, 8, 6, 18, 1, 120);
  equal(round(pointCodec, [point]), pointGolden, 'Titan Point golden');
  const choiceCodec = codec([['nominal', 'app.Choice']], nominals, pointCodec.types);
  equal(round(choiceCodec, [new Empty()]), bytes(10, 2, 10, 0), 'Titan empty Choice golden');
  equal(scalarRound('value', 7n), bytes(10, 2, 16, 14), 'Titan dynamic integer golden');

  check(Point.name === 'Point' && Choice.name === 'Choice' && Count.name === 'Choice.count', 'class names');
  equal(Object.keys(point), ['x', 'label'], 'own public fields');
  equal(new Point(), new Point(null, null), 'missing constructor arguments become null');
  equal(new Point(3n), new Point(3n, null), 'missing trailing constructor argument');
  rejects(() => new Point(3n, bytes(), 1), 'type_mismatch', '$');
  rejects(() => new Choice(), 'type_mismatch', '$');
  rejects(() => new Empty(1), 'type_mismatch', '$');
  check(new Count(7n) instanceof Choice && new Count(7n) instanceof Count, 'variant extends union');
  check(Object.isFrozen(Choice.variants), 'variant table frozen');
  const Names = pointCodec.types['app.Names'];
  equal(Object.keys(Names.variants), ['name', 'length', 'prototype'], 'collision-safe variant names');
  const namesCodec = codec([['nominal', 'app.Names']], nominals, pointCodec.types);
  for (const name of Object.keys(Names.variants)) {
    const Class = Names.variants[name], instance = new Class();
    check(Class.name === `Names.${name}` && instance instanceof Names, `variant ${name} identity`);
    round(namesCodec, [instance]);
  }
  Point.prototype.summary = function () { return this.x + BigInt(this.label.length); };
  const decodedPoint = pointCodec.decode(pointGolden)[0];
  check(decodedPoint instanceof Point && decodedPoint.constructor === Point && decodedPoint.summary() === 4n, 'decoded class and method');
  class ApplicationPoint extends Point {}
  const subclass = new ApplicationPoint(3n, bytes(120));
  equal(pointCodec.encode(subclass), pointGolden, 'application record subclass');
  class ApplicationCount extends Count {}
  equal(choiceCodec.encode(new ApplicationCount(7n)), choiceCodec.encode(new Count(7n)), 'application variant subclass');
  round(choiceCodec, [new Count(7n)]);
  const pair = new Pair(point, point), pairResult = choiceCodec.decode(choiceCodec.encode(pair))[0];
  equal(pairResult, pair, 'repeated reference copied');
  check(pairResult.left !== pairResult.right && pairResult.left !== point, 'decode does not preserve aliases');
  const Proto = pointCodec.types['app.Proto'];
  round(codec([['nominal', 'app.Proto']], nominals, pointCodec.types), [new Proto(1n)]);
  check(Object.hasOwn(new Proto(1n), '__proto__'), 'field named __proto__ is own data');
  for (const value of [{ x: 3n, label: bytes(120) }, new pointCodec.types['app.Twin'](3n, bytes(120)), new (codec([], nominals).types['app.Point'])(3n, bytes(120))])
    rejects(() => pointCodec.encode(value), 'type_mismatch', '$[1]');
  rejects(() => choiceCodec.encode(new pointCodec.types['app.Other'].variants.count(7n)), 'type_mismatch', '$[1]');
  rejects(() => pointCodec.encode(new Point(3n)), 'missing_field', '$[1]["label"]');
  rejects(() => pointCodec.encode(null), 'missing_field', '$[1]');
  rejects(() => pointCodec.decode(hex('0a00')), 'missing_field', '$[1]["x"]');
  const shared = codec([['nominal', 'app.Point']], { ...nominals, 'app.Extra': { module: 'app', record: [] } }, pointCodec.types);
  check(shared.types === pointCodec.types && shared.types['app.Point'] === Point, 'shared table identity');
  equal(shared.encode(decodedPoint), pointGolden, 'shared codec accepts decoded class');
  check(typeof shared.types['app.Extra'] === 'function', 'shared table extended');
  rejects(() => codec([], { 'app.Point': { module: 'app', record: [['x', 'float']] } }, pointCodec.types), 'invalid_description');
  for (const table of [null, [], () => {}, { 'app.Point': class Point {} }, Object.freeze({})])
    rejects(() => codec([], nominals, table), 'invalid_description');

  const dynamicCodec = codec(['value'], nominals, pointCodec.types);
  for (const value of [point, new Empty(), new Count(7n), pair]) round(dynamicCodec, [value]);
  equal(dynamicCodec.encode(subclass), dynamicCodec.encode(point), 'dynamic subclass nominal identity');
  for (const value of ['not bytes', {}, new (class Unknown {})(), new shared.types['app.Extra']()])
    rejects(() => dynamicCodec.encode(value), 'type_mismatch', '$[1]');
  const dynamicPoint = dynamicCodec.encode(point);
  rejects(() => codec(['value']).decode(dynamicPoint), 'unknown_type', '$[1]');
  rejects(() => dynamicCodec.decode(hex('0a0d2a0b12096170702e506f696e74')), 'missing_field', '$[1][1]');
  rejects(() => dynamicCodec.decode(hex('0a122a100a0361707012096170702e506f696e74')), 'missing_field', '$[1]');
  rejects(() => dynamicCodec.decode(hex('0a042a020a00')), 'missing_field', '$[1][2]');

  for (const integer of [0n, -1n, 9007199254740993n, -(1n << 63n), (1n << 63n) - 1n]) scalarRound('integer', integer);
  rejects(() => codec(['integer']).encode(1), 'type_mismatch', '$[1]');
  for (const integer of [1n << 63n, -(1n << 63n) - 1n]) rejects(() => codec(['integer']).encode(integer), 'integer_range', '$[1]');
  for (const float of [1, -0, NaN, Infinity, -Infinity]) scalarRound('float', float);
  rejects(() => codec(['float']).encode(1n), 'type_mismatch');
  for (const flag of [false, true]) scalarRound('boolean', flag);
  rejects(() => codec(['boolean']).encode(0), 'type_mismatch');
  scalarRound('nil', undefined); scalarRound('nil', null);
  scalarRound(['option', 'integer'], undefined); scalarRound(['option', 'integer'], null); scalarRound(['option', 'integer'], 0n);
  rejects(() => codec(['nil']).encode(false), 'type_mismatch');
  for (const value of [bytes(), bytes(0, 255, 195, 40)]) scalarRound('bytes', value);
  for (const value of ['', 'a\0b', '\ufeffstart', '😀']) scalarRound('text', value);
  rejects(() => codec(['text']).encode('\ud800'), 'invalid_utf8');
  rejects(() => codec(['text']).decode(bytes(10, 2, 195, 40)), 'invalid_utf8');
  rejects(() => codec(['text']).encode(bytes()), 'type_mismatch');
  for (const value of [[], new Uint16Array(1), new DataView(new ArrayBuffer(1)), { [Symbol.toStringTag]: 'Uint8Array' }])
    rejects(() => codec(['bytes']).encode(value), 'type_mismatch');
  const original = bytes(1, 2), copied = scalarRound('bytes', original);
  original[0] = 9; check(copied[2] === 1, 'encode copies bytes');
  const input = bytes(10, 2, 1, 2), decodedBytes = codec(['bytes']).decode(input)[0];
  input[2] = 9; check(decodedBytes[0] === 1, 'decode copies bytes');
  equal(codec(['bytes']).decode(bytes(9, 10, 2, 1, 2, 9).subarray(1, 5)), [bytes(1, 2)], 'bounded input view');
  scalarRound('bytes', new Uint8Array(17000)); // Length prefixes wider than two bytes.

  for (const qualifier of ['mutable', 'const', 'maybe']) {
    for (const frozen of [false, true]) {
      const value = frozen ? Object.freeze([1n, undefined, 2n]) : [1n, undefined, 2n];
      const expected = qualifier === 'const' || qualifier === 'maybe' && frozen ? Object.freeze([1n, null, 2n]) : [1n, null, 2n];
      scalarRound(['array', qualifier, 'integer'], value, expected);
    }
  }
  scalarRound(['array', 'maybe', 'integer'], []);
  scalarRound(['array', 'maybe', 'integer'], Object.freeze([]));
  scalarRound(['array', 'mutable', 'integer'], [1n, null, undefined], [1n]);
  const sparse = []; sparse[2] = 1n;
  scalarRound(['array', 'maybe', 'integer'], sparse, [null, null, 1n]);
  const arrayGolden = hex('0a0e0a0208020a000a04088180011001');
  equal(scalarRound(['array', 'maybe', 'integer'], Object.freeze([1n, null, -8193n])), arrayGolden, 'hand-derived array golden');
  equal(codec([['array', 'mutable', 'integer']]).decode(hex('0a021001')), [Object.freeze([])], 'wire constness wins');
  equal(codec([['array', 'const', 'integer']]).decode(hex('0a021000')), [[]], 'wire mutable wins');
  for (const value of [null, false, true, 0n, -1n, 9007199254740993n, 1, -0, NaN, Infinity, -Infinity, bytes(0, 255), [false, null, 2n], Object.freeze([1])]) scalarRound('value', value);
  scalarRound('value', undefined);
  const cyclicArray = []; cyclicArray[0] = cyclicArray;
  rejects(() => dynamicCodec.encode(cyclicArray), 'cycle', '$[1][1]');
  const Link = pointCodec.types['app.Link'], cyclicRecord = new Link(null, 1n); cyclicRecord.next = cyclicRecord;
  rejects(() => dynamicCodec.encode(cyclicRecord), 'cycle', '$[1]["next"]');
  round(dynamicCodec, [1n]); // A failed call must not poison the same codec.

  const Bundle = pointCodec.types['app.Bundle'], Text = pointCodec.types['app.Text'], Box = pointCodec.types['app.Box'];
  rejects(() => codec(['nil', ['nominal', 'app.Bundle']], nominals, pointCodec.types).encode(null, new Bundle([point, point, new Point(3, bytes())])), 'type_mismatch', '$[2]["items"][3]["x"]');
  rejects(() => codec([['nominal', 'app.Box']], nominals, pointCodec.types).encode(new Box.variants.text(new Text('\ud800'))), 'invalid_utf8', '$[1]["left"]["name"]');
  const missingLabel = nested(1, nested(1, concat(nested(1, nested(1, hex('0806120178'))), nested(1, nested(1, hex('0806'))), hex('1000'))));
  rejects(() => codec([['nominal', 'app.Bundle']], nominals, pointCodec.types).decode(missingLabel), 'missing_field', '$[1]["items"][2]["label"]');
  equal(pointCodec.decode(hex('0a0208060a03120178')), [point], 'record messages merge');
  equal(choiceCodec.decode(hex('0a04120208020a0412020804')), [new Count(2n)], 'same variant parts merge');
  equal(choiceCodec.decode(hex('0a04120208020a020a00')), [new Empty()], 'later variant replaces');
  equal(choiceCodec.decode(hex('0a04120208020a020a000a0412020804')), [new Count(2n)], 'returning variant does not retain earlier parts');
  rejects(() => choiceCodec.decode(hex('0a023a00')), 'unknown_variant', '$[1]');
  rejects(() => choiceCodec.decode(hex('0a00')), 'unknown_variant', '$[1]');
  equal(codec(['integer']).decode(hex('08020804900301')), [2n], 'last scalar and unknown varint');
  equal(codec(['integer']).decode(hex('080299030000000000000000a20302ffffad0300000000')), [1n], 'unknown fixed64, bytes and fixed32');
  equal(codec(['value']).decode(hex('0a0408011002')), [1n], 'last dynamic arm');
  equal(codec(['value']).decode(hex('0a023801')), [null], 'no recognized dynamic arm');
  equal(codec(['value']).decode(hex('0a0208010a021002')), [1n], 'dynamic messages merge');
  equal(codec([['array', 'maybe', 'integer']]).decode(hex('0a060a02080210000a060a0208041001')), [Object.freeze([1n, 2n])], 'arrays merge and append');
  equal(codec([['array', 'maybe', 'value']]).decode(hex('0a060a020a001000')), [[]], 'empty dynamic slot does not extend length');

  const linkCodec = codec([['nominal', 'app.Link']], nominals, pointCodec.types);
  function chain(count) {
    let result = null;
    while (count--) result = new Link(result, 1n);
    return result;
  }
  const limitBytes = linkCodec.encode(chain(126));
  equal(linkCodec.decode(limitBytes), [chain(126)], 'root depth two, 126 records accepted');
  rejects(() => linkCodec.encode(chain(127)), 'limit_exceeded');
  function chainBytes(count) {
    let result = hex('1002');
    while (--count) result = concat(nested(1, result), hex('1002'));
    return nested(1, result);
  }
  rejects(() => linkCodec.decode(chainBytes(127)), 'limit_exceeded');
  let arrayType = 'integer', arrayValue = 1n;
  for (let i = 0; i < 126; i++) { arrayType = ['array', 'maybe', arrayType]; arrayValue = [arrayValue]; }
  scalarRound(arrayType, arrayValue); scalarRound('value', arrayValue);
  rejects(() => dynamicCodec.encode([arrayValue]), 'limit_exceeded');
  rejects(() => codec([['array', 'maybe', arrayType]]).encode([arrayValue]), 'limit_exceeded');
  for (const malformed of ['00', '80', '0880', '0a80', '0a0200', '0a01', '0900000000000000', '0b0c', '0f', '8080808010', '08ffffffffffffffffff02', '0a8080808008'])
    rejects(() => codec(['integer']).decode(hex(malformed)), 'malformed_wire', '$');
  rejects(() => codec(['integer']).decode(hex('0a00')), 'malformed_wire', '$[1]');
  rejects(() => codec(['boolean']).decode(hex('0802')), 'malformed_wire');
  rejects(() => codec([['array', 'maybe', 'integer']]).decode(hex('0a0410021000')), 'malformed_wire');
  rejects(() => codec(['integer']).decode(bytes()), 'missing_field', '$[1]');
  rejects(() => codec(['integer']).encode(), 'type_mismatch', '$');
  rejects(() => codec([]).encode(1n), 'type_mismatch', '$');
  rejects(() => codec([]).decode([]), 'type_mismatch', '$');
  const oversized = new Uint8Array(2 ** 31); // Address-space reservation; no payload is touched.
  rejects(() => codec([]).decode(oversized), 'limit_exceeded', '$');
  rejects(() => codec(['bytes']).encode(oversized), 'limit_exceeded', '$[1]');
  for (const source of ['not JSON', 'null', '{}', '{"fields":["unknown"],"nominals":{}}', '{"fields":[["nominal","missing"]],"nominals":{}}', '{"fields":[["array","wrong","integer"]],"nominals":{}}', '{"fields":[],"nominals":{"app.Bad":{"module":"app","union":[["bad",[[null,"integer"]]]]}}}'])
    rejects(() => portable(source), 'invalid_description');
  const reservedFields = Array(19001).fill('nil'); reservedFields[18999] = 'integer';
  const reservedValues = Array(19001).fill(null); reservedValues[18999] = 1n;
  const reserved = codec(reservedFields), reservedBytes = hex('80e20902');
  equal(reserved.encode(...reservedValues), reservedBytes, 'reserved ordinals skipped');
  equal(reserved.decode(reservedBytes), reservedValues, 'reserved ordinal decode');
  return assertions;
}
