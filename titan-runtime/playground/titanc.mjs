// The browser playground compiler adapter: instantiates titanc.wasm (the
// Titan compiler in one Lua state, see titanc.c), supplies the few WASI
// imports a reactor without files or processes needs, and converts between
// the page's 0-based UTF-16 offsets and the compiler's UTF-8 byte positions.
// The wire format and the C exports are private to this pair.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// WASI errno values the imports report.
const EBADF = 8;
const ENOSYS = 52;

// Exactly the imports titanc.wasm declares. The compiler has no files,
// environment or processes: only standard output and error (diagnostic
// prints) and the clocks exist.
function wasiImports(memory, output) {
  const view = () => new DataView(memory().buffer);
  return {
    environ_get: () => 0,
    environ_sizes_get(countPtr, sizePtr) {
      view().setUint32(countPtr, 0, true);
      view().setUint32(sizePtr, 0, true);
      return 0;
    },
    clock_time_get(id, _precision, resultPtr) {
      const nanoseconds = id === 0 ? BigInt(Date.now()) * 1000000n :
        BigInt(Math.round(performance.now() * 1e6));
      view().setBigUint64(resultPtr, nanoseconds, true);
      return 0;
    },
    fd_write(fd, iovs, count, writtenPtr) {
      if (fd !== 1 && fd !== 2) return EBADF;
      let total = 0;
      for (let index = 0; index < count; index++) {
        const base = view().getUint32(iovs + index * 8, true);
        const length = view().getUint32(iovs + index * 8 + 4, true);
        output(fd, new Uint8Array(memory().buffer, base, length).slice());
        total += length;
      }
      view().setUint32(writtenPtr, total, true);
      return 0;
    },
    fd_read: () => EBADF,
    fd_close: () => EBADF,
    fd_seek: () => EBADF,
    fd_fdstat_get: () => EBADF,
    fd_fdstat_set_flags: () => EBADF,
    fd_prestat_get: () => EBADF,
    fd_prestat_dir_name: () => EBADF,
    fd_renumber: () => EBADF,
    path_open: () => ENOSYS,
    path_remove_directory: () => ENOSYS,
    path_rename: () => ENOSYS,
    path_unlink_file: () => ENOSYS,
    proc_exit(code) {
      throw new Error(`titanc.wasm exited with status ${code}`);
    },
  };
}

function encodeMessage(parts) {
  const chunks = parts.map(part => typeof part === 'string' ? encoder.encode(part) : part);
  const size = chunks.reduce((sum, chunk) => sum + 4 + chunk.length, 4);
  const message = new Uint8Array(size);
  const view = new DataView(message.buffer);
  view.setUint32(0, chunks.length, true);
  let offset = 4;
  for (const chunk of chunks) {
    view.setUint32(offset, chunk.length, true);
    message.set(chunk, offset + 4);
    offset += 4 + chunk.length;
  }
  return message;
}

function decodeMessage(message) {
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  const parts = [];
  let offset = 4;
  for (let index = view.getUint32(0, true); index > 0; index--) {
    const length = view.getUint32(offset, true);
    parts.push(message.subarray(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  return parts;
}

// Offsets of one file's text in both encodings.
class Text {
  constructor(text) {
    this.text = text;
    this.bytes = encoder.encode(text);
  }
  byteOffset(offset) {
    return encoder.encode(this.text.slice(0, offset)).length;
  }
  utf16Offset(byteOffset) {
    return decoder.decode(this.bytes.subarray(0, byteOffset)).length;
  }
  // A 1-based line and byte column.
  lineOffset(line, column) {
    let start = 0;
    for (let current = 1; current < line; current++) {
      const newline = this.bytes.indexOf(10, start);
      if (newline < 0) return null;
      start = newline + 1;
    }
    return this.utf16Offset(start + column - 1);
  }
}

// Path and UTF-8 contents pairs, reusing each Text's one encoding.
function fileArguments(texts) {
  const parts = [];
  for (const [path, text] of texts) parts.push(path, text.bytes);
  return parts;
}

export async function openCompiler({wasm, catalog, analysisTarget, absentModules}) {
  let memory;
  // Diagnostic prints from the compiler, one decoder and partial line per stream.
  const streams = {1: {decoder: new TextDecoder(), line: ''}, 2: {decoder: new TextDecoder(), line: ''}};
  const output = (fd, chunk) => {
    const stream = streams[fd];
    const lines = (stream.line + stream.decoder.decode(chunk, {stream: true})).split('\n');
    stream.line = lines.pop();
    for (const line of lines) (fd === 1 ? console.log : console.error)(`titanc: ${line}`);
  };
  const {instance} = await WebAssembly.instantiate(wasm,
    {wasi_snapshot_preview1: wasiImports(() => memory, output)});
  let exports = instance.exports;
  memory = exports.memory;
  // Dropping the instance releases the Lua state and all of its memory.
  const retire = () => {
    exports = undefined;
    memory = undefined;
  };
  let cells;

  function reply(status) {
    const view = new DataView(memory.buffer);
    const pointer = view.getUint32(cells, true);
    const length = view.getUint32(cells + 4, true);
    const bytes = new Uint8Array(memory.buffer, pointer, length).slice();
    if (status !== 0) throw new Error(decoder.decode(bytes));
    return bytes;
  }

  // A trap leaves the reactor's state undefined, so the instance is retired
  // and every later operation is refused before it allocates.
  function call(parts) {
    if (!exports) throw new Error('the playground compiler is disposed');
    const message = encodeMessage(parts);
    let pointer = 0;
    let bytes;
    try {
      pointer = exports.titanc_alloc(message.length);
      if (!pointer) throw new Error('titanc.wasm is out of memory');
      new Uint8Array(memory.buffer).set(message, pointer);
      bytes = reply(exports.titanc_call(pointer, message.length, cells, cells + 4));
    } catch (error) {
      if (error instanceof WebAssembly.RuntimeError) retire();
      else if (pointer) exports.titanc_free(pointer);
      throw error;
    }
    exports.titanc_free(pointer);
    const [status, payload, ...rest] = decodeMessage(bytes);
    if (decoder.decode(status) !== 'ok') throw new Error(decoder.decode(payload));
    return {value: JSON.parse(decoder.decode(payload)), rest};
  }

  try {
    exports._initialize();
    cells = exports.titanc_alloc(8);
    if (!cells) throw new Error('titanc.wasm is out of memory');
    reply(exports.titanc_open(cells, cells + 4));
    call(['open', catalog, analysisTarget, absentModules]);
  } catch (error) {
    retire();
    throw error;
  }

  const texts = files => {
    const result = new Map();
    for (const [path, contents] of Object.entries(files)) {
      if (typeof contents !== 'string') throw new TypeError(`project file ${path} is not text`);
      result.set(path, new Text(contents));
    }
    return result;
  };
  const span = (texts, value) => value && texts.has(value.path) ? {path: value.path,
    from: texts.get(value.path).utf16Offset(value.from), to: texts.get(value.path).utf16Offset(value.to)} :
    undefined;
  const diagnostic = (texts, value) => {
    const result = {message: value.message, severity: value.severity};
    const text = value.path !== undefined && texts.get(value.path);
    const offset = text && text.lineOffset(value.line, value.col);
    if (offset !== null && offset !== undefined && offset !== false) {
      result.at = {path: value.path, from: offset, to: offset};
    }
    return result;
  };
  const cursorArguments = (texts, at) => {
    const text = texts.get(at.path);
    if (!text) throw new TypeError(`no project file ${at.path}`);
    return [at.path, String(text.byteOffset(at.offset))];
  };

  return {
    check(files) {
      const known = texts(files);
      return call(['check', ...fileArguments(known)]).value.map(value => diagnostic(known, value));
    },
    hover(files, at) {
      const known = texts(files);
      const value = call(['hover', ...cursorArguments(known, at), ...fileArguments(known)]).value;
      if (!value) return null;
      const result = {at: span(known, value.at), signature: value.signature};
      if (value.summary !== undefined) result.summary = value.summary;
      const declaration = span(known, value.declaration);
      if (declaration) result.declaration = declaration;
      return result;
    },
    complete(files, at) {
      const known = texts(files);
      const value = call(['complete', ...cursorArguments(known, at), ...fileArguments(known)]).value;
      if (!value) return null;
      return {replace: span(known, value.replace), items: value.items.map(item => {
        const result = {label: item.label, kind: item.kind};
        if (item.detail !== undefined) result.detail = item.detail;
        if (item.summary !== undefined) result.summary = item.summary;
        return result;
      })};
    },
    emit_c(files, identity) {
      const known = texts(files);
      const value = call(['emit_c', identity, ...fileArguments(known)]).value;
      return {files: value.files, units: value.units, entry: value.entry,
        diagnostics: value.diagnostics.map(item => diagnostic(known, item))};
    },
    build_trace({linked, identity, factory, loader}) {
      const [mjs, wasmBytes, trace, map] = call(['build_trace', linked, identity, factory, loader]).rest;
      return {mjs: decoder.decode(mjs), wasm: wasmBytes.slice(), trace: trace.slice(), map: decoder.decode(map)};
    },
    dispose: retire,
  };
}
