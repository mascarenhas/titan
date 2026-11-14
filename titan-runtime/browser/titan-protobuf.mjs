// Standalone JavaScript value conversion: no loader or Wasm memory access.
const LIMIT = 2 ** 31;
const utf8 = new TextEncoder();
const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const shape = Symbol('titan protobuf nominal description');
const byteTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;
const isBytes = value => byteTag.call(value) === 'Uint8Array';
const number = ordinal => ordinal < 19000 ? ordinal : ordinal + 1000;
const ordinal = field => field >= 19000 && field < 20000 ? 0 : field >= 20000 ? field - 1000 : field;
const member = (path, name) => `${path}[${JSON.stringify(name)}]`;
const fail = (path, code, message) => { throw Object.assign(new TypeError(`titan protobuf: ${path}: ${message}`), { code, path }); };
const depthCheck = (depth, path) => { if (depth > 128) fail(path, 'limit_exceeded', 'nesting exceeds 128 levels'); };
const put = (object, key, value) => Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
const matches = (entries, field) => entries.filter(entry => entry[0] === field);
const wire = (entry, kind, path) => { if (entry[1] !== kind) fail(path, 'malformed_wire', 'unexpected wire type'); };

// Records and variants share the same positional, public-data constructor.
function dataClass(name, fields, Base = Object) {
  const Class = class extends Base {
    constructor(...values) {
      super();
      if (values.length > fields.length) fail('$', 'type_mismatch', `too many arguments for ${name}`);
      fields.forEach(([field], i) => put(this, field, values[i] ?? null));
    }
  };
  Object.defineProperty(Class, 'name', { value: name });
  return Class;
}

class Writer {
  constructor() { this.bytes = new Uint8Array(64); this.length = 0; this.active = new Set(); }
  reserve(count, path) {
    const needed = this.length + count;
    if (needed >= LIMIT) fail(path, 'limit_exceeded', 'message exceeds size limit');
    if (needed > this.bytes.length) {
      const bytes = new Uint8Array(Math.min(LIMIT - 1, Math.max(needed, this.bytes.length * 2)));
      bytes.set(this.bytes.subarray(0, this.length)); this.bytes = bytes;
    }
  }
  varint(value, path) {
    do {
      this.reserve(1, path);
      this.bytes[this.length++] = Number(value & 127n) | (value > 127n ? 128 : 0);
      value >>= 7n;
    } while (value);
  }
  key(field, kind, path) { this.varint(BigInt(field) * 8n + BigInt(kind), path); }
  raw(bytes, path) { this.reserve(bytes.length, path); this.bytes.set(bytes, this.length); this.length += bytes.length; }
  nested(field, path, body) {
    this.key(field, 2, path); this.reserve(1, path);
    const mark = this.length++;
    body();
    const length = this.length - mark - 1;
    let count = 1;
    for (let rest = length; rest >= 128; rest = Math.floor(rest / 128)) count++;
    this.reserve(count - 1, path);
    this.bytes.copyWithin(mark + count, mark + 1, this.length); this.length += count - 1;
    let rest = length;
    for (let i = 0; i < count; i++, rest = Math.floor(rest / 128))
      this.bytes[mark + i] = (rest & 127) | (i + 1 < count ? 128 : 0);
  }
}

// Ordered occurrences merge without copying their bounded input views.
function message(chunks, path) {
  const entries = [];
  for (const chunk of chunks) {
    wire(chunk, 2, path);
    const bytes = chunk[2]; let position = 0;
    const varint = () => {
      let result = 0n;
      for (let i = 0; i < 10; i++) {
        if (position === bytes.length) fail(path, 'malformed_wire', 'truncated varint');
        const byte = bytes[position++];
        if (i === 9 && byte > 1) fail(path, 'malformed_wire', 'varint overflow');
        result |= BigInt(byte & 127) << BigInt(i * 7);
        if (byte < 128) return result;
      }
      fail(path, 'malformed_wire', 'varint overflow');
    };
    while (position < bytes.length) {
      const key = varint();
      if (key > 0xffffffffn || key < 8n) fail(path, 'malformed_wire', 'invalid field key');
      const field = Number(key >> 3n), kind = Number(key & 7n);
      let value;
      if (kind === 0) value = varint();
      else {
        let size;
        if (kind === 1) size = 8;
        else if (kind === 5) size = 4;
        else if (kind === 2) {
          const length = varint();
          if (length >= BigInt(LIMIT)) fail(path, 'malformed_wire', 'invalid byte length');
          size = Number(length);
        } else fail(path, 'malformed_wire', 'invalid wire type (groups are unsupported)');
        if (size > bytes.length - position) fail(path, 'malformed_wire', 'truncated field');
        value = bytes.subarray(position, position + size); position += size;
      }
      entries.push([field, kind, value]);
    }
  }
  return entries;
}

export function portable(description, types = Object.create(null)) {
  let schema;
  try { if (typeof description !== 'string') throw 0; schema = JSON.parse(description); }
  catch { fail('$', 'invalid_description', 'expected JSON text'); }
  if (!schema || !Array.isArray(schema.fields) || !schema.nominals || typeof schema.nominals !== 'object' || Array.isArray(schema.nominals))
    fail('$', 'invalid_description', 'expected fields and nominals');
  if (!types || typeof types !== 'object' || Array.isArray(types)) fail('$', 'invalid_description', 'expected a class table');
  const nominals = schema.nominals, prototypes = new Map(), classes = new Map();
  function validate(type, path) {
    if (['nil', 'boolean', 'integer', 'float', 'bytes', 'text', 'value'].includes(type)) return;
    if (Array.isArray(type)) {
      if (type[0] === 'option' && type.length === 2) return validate(type[1], path);
      if (type[0] === 'array' && type.length === 3 && ['mutable', 'const', 'maybe'].includes(type[1])) return validate(type[2], path);
      if (type[0] === 'nominal' && type.length === 2 && typeof type[1] === 'string' && Object.hasOwn(nominals, type[1])) return;
    }
    fail(path, 'invalid_description', 'unknown type or missing nominal');
  }
  function validateParts(parts, path) {
    if (!Array.isArray(parts)) fail(path, 'invalid_description', 'expected a field list');
    for (const part of parts) {
      if (!Array.isArray(part) || part.length !== 2 || typeof part[0] !== 'string') fail(path, 'invalid_description', 'invalid field');
      validate(part[1], member(path, part[0]));
    }
  }
  schema.fields.forEach((type, i) => validate(type, `$[${i + 1}]`));
  for (const [name, entry] of Object.entries(nominals)) {
    const path = member('$', name);
    if (!entry || typeof entry.module !== 'string') fail(path, 'invalid_description', 'expected module');
    if (Array.isArray(entry.record)) validateParts(entry.record, path);
    else if (Array.isArray(entry.union)) {
      for (const variant of entry.union) {
        if (!Array.isArray(variant) || variant.length !== 2 || typeof variant[0] !== 'string') fail(path, 'invalid_description', 'invalid variant');
        validateParts(variant[1], member(path, variant[0]));
      }
    } else fail(path, 'invalid_description', 'expected record or union');
  }
  for (const [name, entry] of Object.entries(nominals)) {
    const description = JSON.stringify(entry), path = member('$', name);
    let Class = Object.hasOwn(types, name) ? types[name] : null;
    if (Class) {
      if (typeof Class !== 'function' || !Object.hasOwn(Class, shape) || Class[shape] !== description)
        fail(path, 'invalid_description', 'conflicting shared nominal class');
    } else {
      if (Object.hasOwn(types, name)) fail(path, 'invalid_description', 'invalid shared nominal class');
      const short = name.split('.').at(-1);
      if (entry.record) Class = dataClass(short, entry.record);
      else {
        Class = class { constructor() { if (new.target === Class) fail('$', 'type_mismatch', `cannot construct union ${name}`); } };
        Object.defineProperty(Class, 'name', { value: short });
        const variants = Object.create(null);
        for (const [variant, parts] of entry.union) put(variants, variant, dataClass(`${short}.${variant}`, parts, Class));
        Object.defineProperty(Class, 'variants', { value: Object.freeze(variants) });
      }
      Object.defineProperty(Class, shape, { value: description });
      try { put(types, name, Class); } catch { fail(path, 'invalid_description', 'cannot extend shared class table'); }
    }
    classes.set(name, Class);
    if (entry.record) prototypes.set(Class.prototype, { name, variant: -1 });
    else entry.union.forEach(([variant], i) => prototypes.set(Class.variants[variant].prototype, { name, variant: i }));
  }
  function identify(value) {
    if (!value || typeof value !== 'object') return;
    for (let prototype = Object.getPrototypeOf(value); prototype; prototype = Object.getPrototypeOf(prototype)) {
      const found = prototypes.get(prototype);
      if (found) return found;
    }
  }
  function encode(writer, field, type, value, depth, path) {
    depthCheck(depth, path);
    const kind = Array.isArray(type) ? type[0] : type;
    if (kind === 'option') { if (value != null) encode(writer, field, type[1], value, depth, path); return; }
    if (kind === 'nil' || kind === 'value' && value == null) {
      if (value != null) fail(path, 'type_mismatch', 'expected nil');
      return;
    }
    if (value == null) fail(path, 'missing_field', 'missing required field');
    switch (kind) {
      case 'boolean': case 'integer': {
        if (typeof value !== (kind === 'integer' ? 'bigint' : 'boolean')) fail(path, 'type_mismatch', kind === 'integer' ? 'expected a bigint' : 'expected a boolean');
        if (kind === 'integer' && (value < -(1n << 63n) || value >= 1n << 63n)) fail(path, 'integer_range', 'integer out of range');
        writer.key(field, 0, path);
        writer.varint(kind === 'boolean' ? (value ? 1n : 0n) : (value << 1n) ^ (value >> 63n), path); return;
      }
      case 'float': {
        if (typeof value !== 'number') fail(path, 'type_mismatch', 'expected a number');
        writer.key(field, 1, path); writer.reserve(8, path);
        new DataView(writer.bytes.buffer).setFloat64(writer.length, value, true); writer.length += 8; return;
      }
      case 'bytes': case 'text': {
        if (kind === 'text') {
          if (typeof value !== 'string') fail(path, 'type_mismatch', 'expected text');
          if (!value.isWellFormed()) fail(path, 'invalid_utf8', 'expected well-formed text');
          value = utf8.encode(value);
        } else if (!isBytes(value)) fail(path, 'type_mismatch', 'expected a Uint8Array');
        writer.key(field, 2, path); writer.varint(BigInt(value.length), path); writer.raw(value, path); return;
      }
      case 'value': {
        let arm, armType, nominal;
        if (typeof value === 'boolean') [arm, armType] = [1, 'boolean'];
        else if (typeof value === 'bigint') [arm, armType] = [2, 'integer'];
        else if (typeof value === 'number') [arm, armType] = [3, 'float'];
        else if (isBytes(value)) [arm, armType] = [4, 'bytes'];
        else if (Array.isArray(value)) [arm, armType] = [6, ['array', 'maybe', 'value']];
        else if ((nominal = identify(value))) [arm, armType] = [5, ['nominal', nominal.name]];
        else fail(path, 'type_mismatch', 'unsupported dynamic value');
        writer.nested(field, path, () => {
          if (arm !== 5) encode(writer, arm, armType, value, depth, path);
          else writer.nested(5, path, () => {
            encode(writer, 1, 'text', nominals[nominal.name].module, depth, path);
            encode(writer, 2, 'text', nominal.name, depth, path);
            encode(writer, 3, armType, value, depth, path);
          });
        }); return;
      }
      case 'array': case 'nominal': {
        const nominal = kind === 'nominal' ? identify(value) : null;
        if (kind === 'array') {
          if (!Array.isArray(value)) fail(path, 'type_mismatch', 'expected an array');
        } else if (nominal?.name !== type[1]) fail(path, 'type_mismatch', `expected an instance of ${type[1]}`);
        if (writer.active.has(value)) fail(path, 'cycle', 'cyclic object graph');
        writer.active.add(value);
        try {
          writer.nested(field, path, () => {
            if (kind === 'array') {
              let length = value.length;
              while (length && value[length - 1] == null) length--;
              for (let i = 0; i < length; i++) writer.nested(1, `${path}[${i + 1}]`, () => {
                if (value[i] != null) encode(writer, 1, type[2], value[i], depth + 1, `${path}[${i + 1}]`);
              });
              encode(writer, 2, 'boolean', type[1] === 'const' || type[1] === 'maybe' && Object.isFrozen(value), depth, path);
            } else {
              const entry = nominals[type[1]];
              const parts = entry.record ?? entry.union[nominal.variant][1];
              const encodeParts = () => parts.forEach(([name, item], i) =>
                encode(writer, number(i + 1), item, value[name], depth + 1, member(path, name)));
              if (entry.record) encodeParts();
              else writer.nested(number(nominal.variant + 1), path, encodeParts);
            }
          });
        } finally { writer.active.delete(value); }
        return;
      }
    }
  }
  function decode(type, chunks, depth, path) {
    depthCheck(depth, path);
    const kind = Array.isArray(type) ? type[0] : type, last = chunks.at(-1);
    if (kind === 'option') return last ? decode(type[1], chunks, depth, path) : null;
    if (kind === 'nil') { message(chunks, path); return null; }
    if (!last) { if (kind === 'value') return null; fail(path, 'missing_field', 'missing required field'); }
    if (kind !== 'value' && kind !== 'array' && kind !== 'nominal') {
      const expected = kind === 'integer' || kind === 'boolean' ? 0 : kind === 'float' ? 1 : 2;
      for (const chunk of chunks) wire(chunk, expected, path);
    }
    const value = last[2];
    switch (kind) {
      case 'boolean': if (value !== 0n && value !== 1n) fail(path, 'malformed_wire', 'invalid boolean'); return value === 1n;
      case 'integer': return (value >> 1n) ^ -(value & 1n);
      case 'float': return new DataView(value.buffer, value.byteOffset, 8).getFloat64(0, true);
      case 'bytes': return Uint8Array.prototype.slice.call(value);
      case 'text': try { return text.decode(value); } catch { fail(path, 'invalid_utf8', 'invalid UTF-8 text'); }
      case 'value': {
        const entries = message(chunks, path), selected = entries.findLast(entry => entry[0] >= 1 && entry[0] <= 6)?.[0];
        if (!selected) return null;
        if (selected !== 5) return decode([null, 'boolean', 'integer', 'float', 'bytes', null, ['array', 'maybe', 'value']][selected], matches(entries, selected), depth, path);
        const nominal = message(matches(entries, 5), path);
        decode('bytes', matches(nominal, 1), depth, `${path}[1]`);
        const name = decode('text', matches(nominal, 2), depth, `${path}[2]`);
        if (!Object.hasOwn(nominals, name)) fail(path, 'unknown_type', `unlisted nominal ${name}`);
        return decode(['nominal', name], matches(nominal, 3), depth, path);
      }
      case 'array': {
        const entries = message(chunks, path), result = []; let frozen = false, count = 0;
        for (const entry of entries) {
          if (entry[0] === 1) {
            const slot = message([entry], `${path}[${++count}]`), fields = matches(slot, 1);
            result.push(fields.length ? decode(type[2], fields, depth + 1, `${path}[${count}]`) : null);
          } else if (entry[0] === 2) frozen = decode('boolean', [entry], depth, path);
        }
        while (result.length && result.at(-1) === null) result.pop();
        return type[1] === 'const' || type[1] === 'maybe' && frozen ? Object.freeze(result) : result;
      }
      case 'nominal': {
        const name = type[1], entry = nominals[name]; let Class = classes.get(name);
        let entries = message(chunks, path), parts = entry.record;
        if (!parts) {
          let selected = 0, payloads = [];
          for (const field of entries) {
            const index = ordinal(field[0]);
            if (index < 1 || index > entry.union.length) continue;
            wire(field, 2, path);
            if (selected !== index) { selected = index; payloads = []; }
            payloads.push(field);
          }
          if (!selected) fail(path, 'unknown_variant', 'union has no recognized variant');
          const variant = entry.union[selected - 1];
          Class = Class.variants[variant[0]]; parts = variant[1]; entries = message(payloads, path);
        }
        return new Class(...parts.map(([name, item], i) =>
          decode(item, matches(entries, number(i + 1)), depth + 1, member(path, name))));
      }
    }
  }
  return {
    types,
    encode(...values) {
      if (values.length !== schema.fields.length) fail('$', 'type_mismatch', 'field count mismatch');
      const writer = new Writer();
      schema.fields.forEach((type, i) => encode(writer, number(i + 1), type, values[i], 2, `$[${i + 1}]`));
      return writer.bytes.slice(0, writer.length);
    },
    decode(bytes) {
      if (!isBytes(bytes)) fail('$', 'type_mismatch', 'expected a Uint8Array');
      if (bytes.length >= LIMIT) fail('$', 'limit_exceeded', 'message exceeds size limit');
      const entries = message([[0, 2, bytes]], '$');
      return schema.fields.map((type, i) => decode(type, matches(entries, number(i + 1)), 2, `$[${i + 1}]`));
    },
  };
}
