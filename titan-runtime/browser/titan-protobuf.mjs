// JavaScript values only: no loader, Wasm memory, or state shared between calls.
const LIMIT = 2 ** 31;
const utf8 = new TextEncoder();
const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const byteTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;
const isBytes = value => byteTag.call(value) === 'Uint8Array';
const number = ordinal => ordinal < 19000 ? ordinal : ordinal + 1000;
const ordinal = field => field >= 19000 && field < 20000 ? 0 : field >= 20000 ? field - 1000 : field;
const fail = (path, message) => { throw new TypeError(`titan protobuf: ${path}: ${message}`); };
const depthCheck = (depth, path) => { if (depth > 128) fail(path, 'nesting exceeds 128 levels'); };
const own = (object, key) => Object.hasOwn(object, key) ? object[key] : undefined;
const put = (object, key, value) => Object.defineProperty(object, key, { value, enumerable: true, writable: true, configurable: true });
// Keep nominal object spelling independent of the byte traversal.
const nominalType = value => value && typeof value === 'object' ? own(value, '$type') : undefined;
const nominalVariant = value => own(value, '$variant');
const partKey = (name, index) => name ?? String(index + 1);
const nominalObject = (name, variant) => variant === undefined ? { $type: name } : { $type: name, $variant: variant };
const matches = (entries, field) => entries.filter(entry => entry[0] === field);
const wire = (entry, kind, path) => { if (entry[1] !== kind) fail(path, 'unexpected wire type'); };

class Writer {
  constructor() { this.bytes = new Uint8Array(64); this.length = 0; this.active = new Set(); }
  reserve(count, path) {
    const needed = this.length + count;
    if (needed >= LIMIT) fail(path, 'message exceeds size limit');
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

// Entries retain bounded input views only until decode returns. Merged messages
// parse occurrences in encounter order without copying their payload bytes.
function message(chunks, path) {
  const entries = [];
  for (const chunk of chunks) {
    wire(chunk, 2, path);
    const bytes = chunk[2]; let position = 0;
    const varint = () => {
      let result = 0n;
      for (let i = 0; i < 10; i++) {
        if (position === bytes.length) fail(path, 'truncated varint');
        const byte = bytes[position++];
        if (i === 9 && byte > 1) fail(path, 'varint overflow');
        result |= BigInt(byte & 127) << BigInt(i * 7);
        if (byte < 128) return result;
      }
      fail(path, 'varint overflow');
    };
    while (position < bytes.length) {
      const key = varint();
      if (key > 0xffffffffn || key < 8n) fail(path, 'invalid field key');
      const field = Number(key >> 3n), kind = Number(key & 7n);
      let value;
      if (kind === 0) value = varint();
      else {
        let size;
        if (kind === 1) size = 8;
        else if (kind === 5) size = 4;
        else if (kind === 2) {
          const length = varint();
          if (length >= BigInt(LIMIT)) fail(path, 'invalid byte length');
          size = Number(length);
        } else fail(path, 'invalid wire type (groups are unsupported)');
        if (size > bytes.length - position) fail(path, 'truncated field');
        value = bytes.subarray(position, position + size); position += size;
      }
      entries.push([field, kind, value]);
    }
  }
  return entries;
}

export function portable(description) {
  let schema;
  try { if (typeof description !== 'string') throw 0; schema = JSON.parse(description); }
  catch { fail('description', 'expected JSON text'); }
  if (!schema || !Array.isArray(schema.fields) || !schema.nominals || typeof schema.nominals !== 'object' || Array.isArray(schema.nominals))
    fail('description', 'expected fields and nominals');
  const nominals = schema.nominals;
  function validate(type, path) {
    if (['nil', 'boolean', 'integer', 'float', 'bytes', 'text', 'value'].includes(type)) return;
    if (Array.isArray(type)) {
      if (type[0] === 'option' && type.length === 2) return validate(type[1], path);
      if (type[0] === 'array' && type.length === 3 && ['mutable', 'const', 'maybe'].includes(type[1])) return validate(type[2], path);
      if (type[0] === 'nominal' && type.length === 2 && typeof type[1] === 'string' && Object.hasOwn(nominals, type[1])) return;
    }
    fail(path, 'unknown type or missing nominal');
  }
  function validateParts(parts, path, unnamed) {
    if (!Array.isArray(parts)) fail(path, 'expected a field list');
    for (const part of parts) {
      if (!Array.isArray(part) || part.length !== 2 || !(typeof part[0] === 'string' || unnamed && part[0] === null)) fail(path, 'invalid field');
      validate(part[1], path);
    }
  }
  schema.fields.forEach((type, i) => validate(type, `description field ${i + 1}`));
  for (const [name, entry] of Object.entries(nominals)) {
    if (!entry || typeof entry.module !== 'string') fail(`description ${name}`, 'expected module');
    if (entry.opaque === true) continue;
    if (entry.record) validateParts(entry.record, `description ${name}`, false);
    else if (Array.isArray(entry.union)) {
      for (const variant of entry.union) {
        if (!Array.isArray(variant) || variant.length !== 2 || typeof variant[0] !== 'string') fail(`description ${name}`, 'invalid variant');
        validateParts(variant[1], `description ${name}.${variant[0]}`, true);
      }
    } else fail(`description ${name}`, 'expected record, union or opaque');
  }
  function encode(writer, field, type, value, depth, path) {
    depthCheck(depth, path);
    const kind = Array.isArray(type) ? type[0] : type;
    if (kind === 'option') { if (value != null) encode(writer, field, type[1], value, depth, path); return; }
    if (kind === 'nil' || kind === 'value' && value == null) {
      if (value != null) fail(path, 'expected nil');
      return;
    }
    switch (kind) {
      case 'boolean': case 'integer': {
        if (typeof value !== (kind === 'integer' ? 'bigint' : 'boolean')) fail(path, kind === 'integer' ? 'expected a bigint' : 'expected a boolean');
        if (kind === 'integer' && (value < -(1n << 63n) || value >= 1n << 63n)) fail(path, 'integer out of range');
        writer.key(field, 0, path);
        writer.varint(kind === 'boolean' ? (value ? 1n : 0n) : (value << 1n) ^ (value >> 63n), path); return;
      }
      case 'float': {
        if (typeof value !== 'number') fail(path, 'expected a number');
        writer.key(field, 1, path); writer.reserve(8, path);
        new DataView(writer.bytes.buffer).setFloat64(writer.length, value, true); writer.length += 8; return;
      }
      case 'bytes': case 'text': {
        if (kind === 'text') {
          if (typeof value !== 'string' || !value.isWellFormed()) fail(path, 'expected well-formed text');
          value = utf8.encode(value);
        } else if (!isBytes(value)) fail(path, 'expected a Uint8Array');
        writer.key(field, 2, path); writer.varint(BigInt(value.length), path); writer.raw(value, path); return;
      }
      case 'value': {
        let arm, armType;
        if (typeof value === 'boolean') [arm, armType] = [1, 'boolean'];
        else if (typeof value === 'bigint') [arm, armType] = [2, 'integer'];
        else if (typeof value === 'number') [arm, armType] = [3, 'float'];
        else if (isBytes(value)) [arm, armType] = [4, 'bytes'];
        else if (Array.isArray(value)) [arm, armType] = [6, ['array', 'maybe', 'value']];
        else if (value && typeof value === 'object' && Object.hasOwn(nominals, nominalType(value))) [arm, armType] = [5, ['nominal', nominalType(value)]];
        else fail(path, 'unsupported dynamic value or unlisted nominal');
        writer.nested(field, path, () => {
          if (arm !== 5) encode(writer, arm, armType, value, depth, path);
          else writer.nested(5, path, () => {
            encode(writer, 1, 'text', nominals[nominalType(value)].module, depth, path);
            encode(writer, 2, 'text', nominalType(value), depth, path);
            encode(writer, 3, armType, value, depth, path);
          });
        }); return;
      }
      case 'array': case 'nominal': {
        if (kind === 'array') {
          if (!Array.isArray(value)) fail(path, 'expected an array');
        } else if (nominalType(value) !== type[1]) fail(path, `expected nominal ${type[1]}`);
        if (writer.active.has(value)) fail(path, 'cyclic object graph');
        writer.active.add(value);
        try {
          const entry = kind === 'nominal' ? nominals[type[1]] : null;
          if (entry?.opaque) { encode(writer, field, 'bytes', own(value, 'bytes'), depth, `${path}.bytes`); return; }
          writer.nested(field, path, () => {
            if (kind === 'array') {
              let length = value.length;
              while (length && value[length - 1] == null) length--;
              for (let i = 0; i < length; i++) writer.nested(1, `${path}[${i + 1}]`, () => {
                if (value[i] != null) encode(writer, 1, type[2], value[i], depth + 1, `${path}[${i + 1}]`);
              });
              encode(writer, 2, 'boolean', type[1] === 'const' || type[1] === 'maybe' && Object.isFrozen(value), depth, path);
            } else {
              let parts = entry.record;
              if (!parts) {
                const index = entry.union.findIndex(variant => variant[0] === nominalVariant(value));
                if (index < 0) fail(path, 'unknown $variant');
                parts = entry.union[index][1];
                writer.nested(number(index + 1), path, () => encodeParts(parts));
              } else encodeParts(parts);
              function encodeParts(fields) {
                fields.forEach(([name, item], i) => encode(writer, number(i + 1), item, own(value, partKey(name, i)), depth + 1, `${path}.${partKey(name, i)}`));
              }
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
    if (kind === 'option') return last ? decode(type[1], chunks, depth, path) : undefined;
    if (kind === 'nil') { message(chunks, path); return undefined; }
    if (!last) { if (kind === 'value') return undefined; fail(path, 'missing required field'); }
    const expected = kind === 'integer' || kind === 'boolean' ? 0 : kind === 'float' ? 1 : 2;
    for (const chunk of chunks) wire(chunk, expected, path);
    const value = last[2];
    switch (kind) {
      case 'boolean': if (value !== 0n && value !== 1n) fail(path, 'invalid boolean'); return value === 1n;
      case 'integer': return (value >> 1n) ^ -(value & 1n);
      case 'float': return new DataView(value.buffer, value.byteOffset, 8).getFloat64(0, true);
      case 'bytes': return Uint8Array.prototype.slice.call(value);
      case 'text': try { return text.decode(value); } catch { fail(path, 'invalid UTF-8 text'); }
      case 'value': {
        const entries = message(chunks, path), selected = entries.findLast(entry => entry[0] >= 1 && entry[0] <= 6)?.[0];
        if (!selected) return undefined;
        if (selected !== 5) return decode([null, 'boolean', 'integer', 'float', 'bytes', null, ['array', 'maybe', 'value']][selected], matches(entries, selected), depth, path);
        const nominal = message(matches(entries, 5), path);
        decode('bytes', matches(nominal, 1), depth, `${path}.$module`);
        const name = decode('text', matches(nominal, 2), depth, `${path}.$type`);
        if (!Object.hasOwn(nominals, name)) fail(path, `unlisted nominal ${name}`);
        return decode(['nominal', name], matches(nominal, 3), depth, path);
      }
      case 'array': {
        const entries = message(chunks, path), result = []; let frozen = false, count = 0;
        for (const entry of entries) {
          if (entry[0] === 1) {
            const slot = message([entry], `${path}[${++count}]`), fields = matches(slot, 1);
            if (fields.length) {
              const item = decode(type[2], fields, depth + 1, `${path}[${count}]`);
              if (item !== undefined) result[count - 1] = item;
            }
          } else if (entry[0] === 2) frozen = decode('boolean', [entry], depth, path);
        }
        return frozen ? Object.freeze(result) : result;
      }
      case 'nominal': {
        const name = type[1], entry = nominals[name]; let result = nominalObject(name);
        if (entry.opaque) { result.bytes = decode('bytes', chunks, depth, `${path}.bytes`); return result; }
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
          if (!selected) fail(path, 'union has no recognized variant');
          const variant = entry.union[selected - 1];
          result = nominalObject(name, variant[0]); parts = variant[1]; entries = message(payloads, path);
        }
        parts.forEach(([name, item], i) => put(result, partKey(name, i), decode(item, matches(entries, number(i + 1)), depth + 1, `${path}.${partKey(name, i)}`)));
        return result;
      }
    }
  }
  return {
    encode(...values) {
      if (values.length !== schema.fields.length) fail('fields', 'field count mismatch');
      const writer = new Writer();
      schema.fields.forEach((type, i) => encode(writer, number(i + 1), type, values[i], 2, `field ${i + 1}`));
      return writer.bytes.slice(0, writer.length);
    },
    decode(bytes) {
      if (!isBytes(bytes)) fail('input', 'expected a Uint8Array');
      if (bytes.length >= LIMIT) fail('input', 'message exceeds size limit');
      const entries = message([[0, 2, bytes]], 'input');
      return schema.fields.map((type, i) => decode(type, matches(entries, number(i + 1)), 2, `field ${i + 1}`));
    },
  };
}
