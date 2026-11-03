// Private adapter pinned to Emscripten 6.0.13. No capture-time I/O or Wasm allocation.
addToLibrary({
  $TitanBrowserTrace__deps: ['$addOnPreRun', '$addRunDependency', '$removeRunDependency',
    '$UTF8ToString', '$stringToUTF8', 'titan_browser_trace_identity'],
  $TitanBrowserTrace__postset: 'TitanBrowserTrace.install();',
  $TitanBrowserTrace: {
    index: null,
    alphabet: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',
    patterns: null,

    u32(value) { return Number.isInteger(value) && value >= 0 && value <= 0xffffffff; },
    basename(path) { return path.replace(/\\/g, '/').split('/').pop() || '?'; },
    upper(array, value) {
      var lo = 0, hi = array.length;
      while (lo < hi) {
        var mid = lo + Math.floor((hi - lo) / 2);
        if (array[mid] <= value) lo = mid + 1;
        else hi = mid;
      }
      return lo - 1;
    },

    buildIndex(map, identity) {
      var self = TitanBrowserTrace;
      if (!map || map.version !== 3 || !Array.isArray(map.sources) ||
          !map.sources.every(x => typeof x === 'string') || map.sources.length > 0x7fffffff ||
          !Array.isArray(map.names) || !map.names.every(x => typeof x === 'string') ||
          typeof map.mappings !== 'string' || 'sections' in map ||
          (map.file !== undefined && typeof map.file !== 'string') ||
          (map.sourceRoot !== undefined && typeof map.sourceRoot !== 'string') ||
          (map.sourcesContent !== undefined && (!Array.isArray(map.sourcesContent) ||
            (map.sourcesContent.length !== 0 && map.sourcesContent.length !== map.sources.length) ||
            !map.sourcesContent.every(x => x === null || typeof x === 'string')))) {
        throw new Error('invalid standard trace map');
      }
      var ranges = map.x_titan_function_ranges, names = map.x_titan_function_names;
      var imports = map.x_titan_function_imports;
      if (!/^[0-9a-f]{64}$/.test(map.x_titan_image) || map.x_titan_image !== identity ||
          !self.u32(imports) || !Array.isArray(ranges) || !Array.isArray(names) ||
          imports + ranges.length > 0xffffffff || names.length !== imports + ranges.length ||
          !names.every(x => x === null || typeof x === 'string')) {
        throw new Error('trace map image or extensions do not match');
      }
      var starts = new Uint32Array(ranges.length), ends = new Uint32Array(ranges.length);
      var first = new Int32Array(ranges.length); first.fill(-1);
      for (var i = 0; i < ranges.length; ++i) {
        var row = ranges[i];
        if (!Array.isArray(row) || row.length !== 2 || !self.u32(row[0]) ||
            !self.u32(row[1]) || row[0] >= row[1] || (i && row[0] < ends[i - 1])) {
          throw new Error('invalid trace function ranges');
        }
        starts[i] = row[0]; ends[i] = row[1];
      }
      // Two passes: validate/count first, then fill dense typed arrays directly.
      // No object per segment and no source text retained in the resulting index.
      var walk = function(visit) {
        var cursor = 0, pc = 0, source = 0, line = 0, column = 0, name = 0, count = 0;
        var text = map.mappings;
        while (cursor < text.length) {
          if (text[cursor] === ';') {
            // A Wasm source map has one generated line (its columns are byte PCs).
            if (/[^;]/.test(text.slice(cursor))) throw new Error('invalid generated trace line');
            break;
          }
          var values = [];
          while (cursor < text.length && text[cursor] !== ',' && text[cursor] !== ';') {
            var value = 0, factor = 1, digit;
            do {
              if (cursor >= text.length) throw new Error('unfinished trace VLQ');
              digit = self.alphabet.indexOf(text[cursor++]);
              if (digit < 0) throw new Error('invalid trace VLQ');
              value += (digit & 31) * factor;
              if (!Number.isSafeInteger(value) || value > 0x1ffffffff) throw new Error('overflowing trace VLQ');
              factor *= 32;
              if ((digit & 32) && factor > 0x200000000) throw new Error('overflowing trace VLQ');
            } while (digit & 32);
            values.push((value % 2 ? -1 : 1) * Math.floor(value / 2));
            if (values.length > 5) throw new Error('invalid trace segment');
          }
          if (values.length !== 1 && values.length !== 4 && values.length !== 5) throw new Error('invalid trace segment');
          pc += values[0];
          if (values[0] < 0 || !self.u32(pc)) throw new Error('unordered trace offsets');
          var src = -1, original = 0;
          if (values.length > 1) {
            source += values[1]; line += values[2]; column += values[3];
            if (!self.u32(source) || source >= map.sources.length || !self.u32(line) ||
                line === 0xffffffff || !self.u32(column)) throw new Error('invalid trace source location');
            if (values.length === 5) {
              name += values[4];
              if (!self.u32(name) || name >= map.names.length) throw new Error('invalid trace source name');
            }
            src = source; original = line + 1;
          }
          if (visit) visit(count, pc, src, original);
          ++count;
          if (text[cursor] === ',') {
            ++cursor;
            if (cursor === text.length || text[cursor] === ',' || text[cursor] === ';') throw new Error('empty trace segment');
          }
        }
        return count;
      };
      var count = walk(null);
      var pcs = new Uint32Array(count), sources = new Int32Array(count), lines = new Uint32Array(count);
      walk(function(i, pc, source, line) {
        pcs[i] = pc; sources[i] = source; lines[i] = line;
        var body = self.upper(starts, pc);
        if (source >= 0 && body >= 0 && pc < ends[body] && first[body] < 0) first[body] = source;
      });
      return { pcs, sources, lines, starts, ends, first, imports,
        names: names.slice(), bases: map.sources.map(self.basename),
        bytes: pcs.byteLength + sources.byteLength + lines.byteLength + starts.byteLength + ends.byteLength + first.byteLength };
    },

    lookup(pc, index, flags) {
      var self = TitanBrowserTrace, map = self.index;
      var body = -1, known = -1;
      if ((flags & 2) && self.u32(index) && index < map.names.length) known = index;
      if ((flags & 1) && self.u32(pc)) {
        body = self.upper(map.starts, pc);
        if (body < 0 || pc >= map.ends[body]) body = -1;
      }
      if (known < 0 && body >= 0 && !(flags & 2)) known = map.imports + body;
      var declared = known - map.imports;
      var base = declared >= 0 && declared < map.first.length && map.first[declared] >= 0
        ? map.bases[map.first[declared]] : '?';
      var symbol = known >= 0 ? map.names[known] || '?' : '?';
      var line = 0;
      if (body >= 0 && (!(flags & 2) || index === map.imports + body)) {
        var segment = self.upper(map.pcs, pc);
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
        if (/^async\*/.test(text)) break; // SpiderMonkey's saved history is not active ancestry.
        if (!text.trim()) continue;
        var frame = v8 ? /^[ \t]*at[ \t]/.test(text)
          : text.includes('@');
        if (!frame) continue; // Count frame shapes, never V8's Error title.
        ++frames;
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
      }
      // D10/D11: these are observed synchronous ceilings under defineProperty.
      var ceiling = engine === 2 ? 100 : engine === 1 ? 128 : Infinity;
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
        addRunDependency('titan-trace-map');
        var start = performance.now(), bytes = 0;
        Promise.resolve().then(async function() {
          var path = locateFile('{{{ WASM_BINARY_FILE }}}.map');
          var data;
          if (ENVIRONMENT_IS_NODE) data = readBinary(path);
          else {
            var response = await fetch(path, {credentials: 'same-origin'});
            if (!response.ok) throw new Error('trace map request failed (' + response.status + ')');
            data = new Uint8Array(await response.arrayBuffer());
          }
          bytes = data.byteLength;
          var map = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(data));
          var identity = UTF8ToString(wasmExports['titan_browser_trace_identity']());
          TitanBrowserTrace.index = TitanBrowserTrace.buildIndex(map, identity);
          Module['titanBrowserTrace'] = {state: 'ready', reason: null, mapBytes: bytes,
            loadMilliseconds: performance.now() - start, indexBytes: TitanBrowserTrace.index.bytes};
        }).catch(function(cause) {
          TitanBrowserTrace.index = null;
          var reason = cause instanceof Error ? cause.message : String(cause);
          Module['titanBrowserTrace'] = {state: 'degraded', reason, mapBytes: bytes,
            loadMilliseconds: performance.now() - start, indexBytes: 0};
          console.warn('Titan browser trace: ' + reason);
        }).finally(function() { removeRunDependency('titan-trace-map'); });
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
