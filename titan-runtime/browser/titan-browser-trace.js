// Private adapter pinned to Emscripten 6.0.13. No capture-time I/O or Wasm allocation.
addToLibrary({
  $TitanBrowserTrace__deps: ['$addOnPreRun', '$addRunDependency', '$removeRunDependency',
    '$UTF8ToString', '$stringToUTF8', 'titan_browser_trace_identity'],
  $TitanBrowserTrace__postset: 'TitanBrowserTrace.install();',
  $TitanBrowserTrace: {
    index: null,
    patterns: null,

    u32(value) { return Number.isInteger(value) && value >= 0 && value <= 0xffffffff; },
    upper(array, value) {
      var lo = 0, hi = array.length;
      while (lo < hi) {
        var mid = lo + Math.floor((hi - lo) / 2);
        if (array[mid] <= value) lo = mid + 1;
        else hi = mid;
      }
      return lo - 1;
    },

    // The compiler validates the map and writes `<stem>.wasm.trace`; this
    // checks only what the bytes could get wrong: the header, the image, the
    // counts and every index. Layout: doc/implementation/browser-target.md#the-trace-table
    readTable(data, identity) {
      var invalid = function() { return new Error('invalid trace table'); };
      if (data.byteOffset % 4) data = new Uint8Array(data);
      if (data.byteLength < 92) throw invalid();
      var view = new DataView(data.buffer, data.byteOffset, data.byteLength);
      var word = function(at) { return view.getUint32(at, true); };
      if (String.fromCharCode(data[0], data[1], data[2], data[3]) !== 'TTRC' || word(4) !== 1) throw invalid();
      if (String.fromCharCode.apply(null, data.subarray(8, 72)) !== identity) {
        throw new Error('trace table image does not match');
      }
      var imports = word(72), count = word(76), rows = word(80), bases = word(84), text = word(88);
      var strings = bases + imports + count + 1;
      if (92 + 4 * (2 * count + 2 * rows + strings) + 2 * (rows + count) + text !== data.byteLength) throw invalid();
      var at = data.byteOffset + 92;
      var array = function(Type, length) {
        var result = new Type(data.buffer, at, length);
        at += result.byteLength;
        return result;
      };
      var gaps = array(Uint32Array, count), lengths = array(Uint32Array, count);
      var pcDeltas = array(Uint32Array, rows), lineDeltas = array(Uint32Array, rows);
      var offsets = array(Uint32Array, strings), sources = array(Int16Array, rows), first = array(Int16Array, count);
      var bytes = array(Uint8Array, text);
      var starts = new Uint32Array(count), ends = new Uint32Array(count), end = 0;
      for (var i = 0; i < count; ++i) {
        var start = end + gaps[i];
        end = start + lengths[i];
        if (!lengths[i] || end > 0xffffffff || first[i] < -1 || first[i] >= bases) throw invalid();
        starts[i] = start; ends[i] = end;
      }
      var pcs = new Uint32Array(rows), lines = new Uint32Array(rows), pc = 0, line = 0;
      for (var r = 0; r < rows; ++r) {
        pc += pcDeltas[r];
        line = (line + lineDeltas[r]) >>> 0;
        // Rows strictly ascend, and a `.titan` row names a line.
        if (pc > 0xffffffff || (r > 0 && !pcDeltas[r]) || sources[r] < -1 || sources[r] >= bases ||
            (sources[r] >= 0 && line === 0)) throw invalid();
        pcs[r] = pc; lines[r] = line;
      }
      if (offsets[0] !== 0 || offsets[strings - 1] !== text) throw invalid();
      for (var s = 1; s < strings; ++s) if (offsets[s] < offsets[s - 1]) throw invalid();
      var decoder = new TextDecoder();
      var string = function(index) { return decoder.decode(bytes.subarray(offsets[index], offsets[index + 1])); };
      var names = [];
      for (var b = 0; b < bases; ++b) names.push(string(b));
      return {pcs, sources, lines, starts, ends, first, imports, count: imports + count, bases: names,
        // Decoded on demand: only traced frames need their function names.
        name: function(index) { return string(bases + index); },
        bytes: data.byteLength + pcs.byteLength + lines.byteLength + starts.byteLength + ends.byteLength};
    },

    lookup(pc, index, flags) {
      var self = TitanBrowserTrace, map = self.index;
      var body = -1, known = -1;
      if ((flags & 2) && self.u32(index) && index < map.count) known = index;
      if ((flags & 1) && self.u32(pc)) {
        body = self.upper(map.starts, pc);
        if (body < 0 || pc >= map.ends[body]) body = -1;
      }
      if (known < 0 && body >= 0 && !(flags & 2)) known = map.imports + body;
      var declared = known - map.imports;
      var base = declared >= 0 && declared < map.first.length && map.first[declared] >= 0
        ? map.bases[map.first[declared]] : '?';
      var symbol = known >= 0 ? map.name(known) || '?' : '?';
      var line = 0;
      if (body >= 0 && (!(flags & 2) || index === map.imports + body)) {
        var segment = self.upper(map.pcs, pc);
        // Only a `.titan` row locates the frame. A PC in a gap, such as C
        // inlined into the body, keeps the declaring basename and no line.
        if (segment >= 0 && map.pcs[segment] >= map.starts[body] &&
            map.pcs[segment] < map.ends[body] && map.sources[segment] >= 0) {
          base = map.bases[map.sources[segment]]; line = map.lines[segment];
        }
      }
      return {base, symbol, line};
    },

    parse(stack, capacity, limit) {
      if (typeof stack !== 'string') throw 'stack is not text';
      var self = TitanBrowserTrace, records = [], frames = 0, engine = -1, truncated = false;
      var v8 = /^[ \t]*at[ \t]/m.test(stack);
      for (var text of stack.split('\n')) {
        if (!text.trim()) continue;
        var frame = v8 ? /^[ \t]*at[ \t]/.test(text)
          : text.includes('@');
        if (!frame) continue; // Count frame shapes, never V8's Error title.
        for (var kind = 0; kind < self.patterns.length; ++kind) {
          var match = self.patterns[kind].exec(text);
          if (!match) continue;
          if (engine < 0) engine = kind;
          var index = Number(match[1]), pc = match[2] === undefined ? 0 : Number.parseInt(match[2], 16);
          if (!self.u32(index) || !self.u32(pc)) throw 'invalid Wasm frame';
          if (records.length < capacity) records.push([pc, index, match[2] === undefined ? 2 : 3]);
          else truncated = true;
          break;
        }
        // SpiderMonkey prefixes saved JS parents with an arbitrary async cause
        // and '*'. Match before '@', after recognizing Wasm: image names may
        // themselves contain '*'. Saved parents are not active ancestry.
        if (engine === 1 && kind === self.patterns.length && /^[^@]+\*[^@]*@/.test(text)) break;
        ++frames;
      }
      // Firefox still caps synchronous capture at 128 frames. Current JSC does
      // not have the historical 100-frame ceiling; use its effective limit.
      var ceiling = engine === 1 ? 128 : Infinity;
      if (frames >= Math.min(limit, ceiling)) truncated = true;
      return {records, truncated};
    },

    capture(out, capacity) {
      var self = TitanBrowserTrace;
      try {
        HEAPU32[out >>> 2] = 0; HEAPU32[(out + 4) >>> 2] = 0;
        if (!self.index) return 1;
        // C owns the record capacity. Validate its declared storage against the
        // current heap, rather than duplicating the private header's constant.
        if (!self.u32(capacity) || capacity === 0 ||
            capacity > Math.floor((HEAPU32.byteLength - (out >>> 0) - 8) / 12)) return 2;
        var limitDescriptor, prepareDescriptor, changedLimit = false, changedPrepare = false;
        var failed = false, stack, limit = capacity + 128;
        try {
          limitDescriptor = Object.getOwnPropertyDescriptor(Error, 'stackTraceLimit');
          prepareDescriptor = Object.getOwnPropertyDescriptor(Error, 'prepareStackTrace');
          if (limitDescriptor && 'value' in limitDescriptor && Number.isFinite(limitDescriptor.value) && limitDescriptor.value > limit) limit = limitDescriptor.value;
          if (!limitDescriptor || limitDescriptor.configurable) {
            Object.defineProperty(Error, 'stackTraceLimit', {value: limit, writable: true, enumerable: false, configurable: true});
            changedLimit = true;
          } else if ('value' in limitDescriptor && limitDescriptor.writable) {
            Object.defineProperty(Error, 'stackTraceLimit', {value: limit}); changedLimit = true;
          } else {
            limit = limitDescriptor && 'value' in limitDescriptor && Number.isFinite(limitDescriptor.value)
              ? Math.max(0, limitDescriptor.value) : Infinity;
          }
          if (prepareDescriptor && (!('value' in prepareDescriptor) ||
              (!prepareDescriptor.configurable && !prepareDescriptor.writable && prepareDescriptor.value !== undefined))) {
            throw 'unsafe prepareStackTrace descriptor';
          }
          if (!prepareDescriptor || prepareDescriptor.configurable) {
            Object.defineProperty(Error, 'prepareStackTrace', {value: undefined, writable: true, enumerable: false, configurable: true});
            changedPrepare = true;
          } else if (prepareDescriptor.writable) {
            Object.defineProperty(Error, 'prepareStackTrace', {value: undefined}); changedPrepare = true;
          }
          stack = new Error().stack; // Exactly one construction and one read.
        } catch (_) { failed = true; }
        finally {
          try {
            if (changedPrepare) {
              if (prepareDescriptor) Object.defineProperty(Error, 'prepareStackTrace', prepareDescriptor);
              else if (!delete Error.prepareStackTrace) failed = true;
            }
          } catch (_) { failed = true; }
          try {
            if (changedLimit) {
              if (limitDescriptor) Object.defineProperty(Error, 'stackTraceLimit', limitDescriptor);
              else if (!delete Error.stackTraceLimit) failed = true;
            }
          } catch (_) { failed = true; }
        }
        if (failed) return 2;
        var parsed = self.parse(stack, capacity, limit);
        for (var i = 0; i < parsed.records.length; ++i) {
          var address = (out + 8 + i * 12) >>> 2, record = parsed.records[i];
          HEAPU32[address] = record[0]; HEAPU32[address + 1] = record[1]; HEAPU32[address + 2] = record[2];
        }
        HEAPU32[(out + 4) >>> 2] = parsed.truncated ? 1 : 0;
        HEAPU32[out >>> 2] = parsed.records.length;
        return 0;
      } catch (_) {
        try { HEAPU32[out >>> 2] = 0; HEAPU32[(out + 4) >>> 2] = 0; } catch (_) {}
        return 2;
      }
    },

    symbolize(record, base, baseBytes, symbol, symbolBytes, line) {
      try {
        HEAPU32[line >>> 2] = 0;
        if (baseBytes) stringToUTF8('?', base, baseBytes);
        if (symbolBytes) stringToUTF8('?', symbol, symbolBytes);
        if (!TitanBrowserTrace.index) return 0;
        var at = record >>> 2;
        var found = TitanBrowserTrace.lookup(HEAPU32[at], HEAPU32[at + 1], HEAPU32[at + 2]);
        if (baseBytes) stringToUTF8(found.base, base, baseBytes);
        if (symbolBytes) stringToUTF8(found.symbol, symbol, symbolBytes);
        HEAPU32[line >>> 2] = found.line;
        return found.line ? 1 : 0;
      } catch (_) {
        try {
          HEAPU32[line >>> 2] = 0;
          if (baseBytes) stringToUTF8('?', base, baseBytes);
          if (symbolBytes) stringToUTF8('?', symbol, symbolBytes);
        } catch (_) {}
        return 2;
      }
    },

    install() {
      // Emscripten serializes library object data as JSON. RegExp literals must
      // be constructed in a function, not stored in that compile-time object.
      // Survey330: V8, SpiderMonkey, then cold/warm JSC.
      TitanBrowserTrace.patterns = [
        /^\s*at .*?wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)\)?\s*$/,
        /^.*?@.*?wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)\s*$/,
        /^.*?@.*?wasm-function\[(\d+)\]\s*$/,
      ];
      addOnPreRun(function() {
        addRunDependency('titan-trace-table');
        var start = performance.now(), bytes = 0;
        Promise.resolve().then(async function() {
          var path = locateFile('{{{ WASM_BINARY_FILE }}}.trace');
          var data;
          if (ENVIRONMENT_IS_NODE) data = readBinary(path);
          else {
            var response = await fetch(path, {credentials: 'same-origin'});
            if (!response.ok) throw new Error('trace table request failed (' + response.status + ')');
            data = new Uint8Array(await response.arrayBuffer());
          }
          bytes = data.byteLength;
          var identity = UTF8ToString(wasmExports['titan_browser_trace_identity']());
          TitanBrowserTrace.index = TitanBrowserTrace.readTable(data, identity);
          Module['titanBrowserTrace'] = {state: 'ready', reason: null, traceBytes: bytes,
            loadMilliseconds: performance.now() - start, indexBytes: TitanBrowserTrace.index.bytes};
        }).catch(function(cause) {
          TitanBrowserTrace.index = null;
          var reason = cause instanceof Error ? cause.message : String(cause);
          Module['titanBrowserTrace'] = {state: 'degraded', reason, traceBytes: bytes,
            loadMilliseconds: performance.now() - start, indexBytes: 0};
          console.warn('Titan browser trace: ' + reason);
        }).finally(function() { removeRunDependency('titan-trace-table'); });
      });
    },
  },
  titan_browser_trace_capture__deps: ['$TitanBrowserTrace'],
  titan_browser_trace_capture__sig: 'iii',
  titan_browser_trace_capture: (out, capacity) => TitanBrowserTrace.capture(out, capacity),
  titan_browser_trace_symbolize__deps: ['$TitanBrowserTrace'],
  titan_browser_trace_symbolize__sig: 'iiiiiii',
  titan_browser_trace_symbolize: (record, base, baseBytes, symbol, symbolBytes, line) =>
    TitanBrowserTrace.symbolize(record, base, baseBytes, symbol, symbolBytes, line),
});
