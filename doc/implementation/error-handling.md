# Error handling implementation

This chapter covers two related pieces of the implementation:

* unified Titan/Lua tracebacks, captured on the error path; and
* `raise`/`catch` and the internal `finally` that `defer` lowers to.

The surface language is documented in
[the language reference](../language/error-handling.md) and
[defer](../language/defer.md). This chapter is the canonical home for the trace
model, the error handler, trace pinning, the inline protected boundary, pending
`finally` actions, and scalar recovery storage across `setjmp`. The code lives
in `titan-runtime/titan.c` (`errorhandler` and the trace builder),
`titan-compiler/parser.lua`, the checker, and `titan-compiler/coder/statements.lua`
and `coder/flow.lua`. The `defer`-specific parser lowering is in
[Defer](defer.md).

## Runtime trace model

Every Lua-callable Titan entry wrapper ensures `errorhandler`
(`titan-runtime/titan.c`) is active as `L->errfunc` for the duration of the
call, reusing an outer Titan handler when one is already installed
(`titan_errfunc_is_errorhandler` in `titan-compiler/cpreamble.lua`). When Lua
raises an error, `luaG_errormsg` invokes that handler before the longjmp reaches
either a Lua `pcall` or Titan's inline protected boundary.

The handler stores the raw rendered traceback in
`registry[TITAN_BACKTRACE_KEY]`: frame lines only, with no error message, no
`stack traceback:` header, and no presentation tabs. The error value itself is
not wrapped. After the handler returns, Lua 5.5's `luaG_errormsg` replaces a nil
error object with `"<no error object>"` before throwing. Lua `pcall`, Titan's
catch-local `error`, and any re-raise observe that value; other values,
including false, remain unchanged.

Generated checked failures (`codethrow`, `titan-compiler/coder/values.lua`)
call `luaL_error` at the original Titan source line and then emit `abort()`.
Lua's public declaration returns `int`, so the C99 fallback makes the branch
terminal for the native compiler even without a nonreturning attribute. Lua
always raises first; the fallback is unreachable in normal execution. It
prevents optimized Option forces from retaining an impossible fallthrough with a
zero-initialized nominal result.

### Trace pinning

The registry also contains `TITAN_TRACE_PINNED`, a boolean pin flag. The
handler's rule is:

* if the pin is set, clear the pin and keep the existing traceback;
* otherwise, regenerate the traceback from the current stack.

This prevents stale-trace reuse while still letting an error keep a trace
captured elsewhere. Generated code has one owner of that protocol,
`raise_with_trace` (`titan-compiler/coder/statements.lua`): it copies the trace
string and the error value into C, writes the trace to `TITAN_BACKTRACE_KEY`,
sets the pin, places the error in the single top slot required by Lua's error
ABI, and calls `lua_error`. The handler sees the pin and preserves the given
trace. Three lowerings end there:

* a bare `raise` in a catch passes the catch-local `error` and `traceback`, so
  the original deep trace survives the shallower re-raise site;
* `raise <exp>, <trace>` passes its two operands. `coderaise` stores the error
  value in a traced slot before it evaluates the trace expression, which can
  clear the value's home and collect, and stores the trace in a traced slot
  too, because the registry write can allocate;
* a finally's pending raise passes the error and trace it saved before the
  cleanup ran ([pending actions](#pending-actions-for-finally)).

A fresh `raise <exp>` leaves the pin clear, so the handler captures a new trace
at the new raise site. No `.titan` source writes either registry key: a module
that carries an error and its trace across a boundary (`coroutine`,
`async.Error:raise`, `uv`'s loop rethrow, `thread.Error:raise`) uses
`raise <exp>, <trace>`.

When a boundary catches an error for a `catch` or `finally`, it snapshots the
trace into a reserved stack slot and then clears both the trace slot and the
pin. A fully handled catch therefore leaves `titan.backtrace()` as `nil`; the
handled trace is available only through the catch-local `traceback`.

Recovery must not allocate, because an allocation failure there would raise a
secondary `LUA_ERRMEM` that skips `catch` or `finally` cleanup. Snapshot and
clear therefore access `G(L)->l_registry` through Lua's internal table machinery
(`titan_registry_get_string` and `titan_registry_set_string`), without the Lua
stack, `L->top` changes, or string interning. The keys `TITAN_BACKTRACE_KEY` and
`TITAN_TRACE_PINNED` and the empty-trace fallback `""` are pre-interned
`TString`s held in compiler-private module user values. `recovery_string`
(`coder/statements.lua`) requests a slot only when generated recovery or
re-raise code needs it, and `coder.generate` (`coder/generate.lua`) fills each
one with a back barrier during module initialization, before dependencies are
initialized or any generated code runs; see
[user-value allocation](codegen-overview.md#user-value-allocation) for the slot
order. `luaH_getstr`, the rooted `""` fallback, and short-string `nil` clears in
`luaH_psetshortstr`/`luaH_finishset` never allocate, even after an emergency
collection has swept dead nil-valued registry keys. The lookup tag is checked
before its result: an absent trace (such as `LUA_ERRMEM` raised directly by
`luaD_throw` without calling `L->errfunc`) falls back to the rooted empty
string. A non-nil re-raise insertion can still grow the registry hash when no
free node exists, but only after the enclosing cleanup has already run.
Intervening Lua-frame `__close` handlers can allocate; `luaD_closeprotected`
runs them under its own protection.

Coroutines hand over one more trace, for uncaught errors in a dead coroutine,
through `titan.coroutine`'s module variable `pending_append_trace`, not through
the registry. The coroutine entry stages its own trace there; the
`resume`/`error` side then raises and catches the same payload to capture the
propagation trace in the caller, appends it to the staged trace, and raises
the original payload again with the combined string as its trace
(`raise error, inner .. "\n" .. traceback`). The final handler therefore
preserves the combined trace instead of only the shallow propagation site. The
code is in `titan/coroutine.titan` (see [Coroutines](coroutines.md)). The
non-raising `Coroutine:transfer` instead clears the slot and returns the staged
trace as an ordinary string; the async driver appends its own propagation trace
only for a Task failure that it reports
([coroutine entry](coroutines.md#entry-function)).

### libbacktrace and frame merging

The trace is a single innermost-to-outer stack built from two sources:

* Lua `CallInfo` frames, read with `lua_getstack`/`lua_getinfo`, provide the
  Lua-level activations, including pure Lua functions and genuine Lua C
  functions such as `pcall` (shown as `[C]` from `ar.short_src`).
* libbacktrace provides native frames from compiled Titan code, including
  native-to-native calls that have no Lua `CallInfo` of their own.

Generated Lua entry wrappers contain `titanentry` in their C symbol name. Those
wrapper frames are sentinels, not user-visible frames. The native side drains a
run of Titan frames until the next entry-wrapper sentinel, emitting only the
native Titan function frames and using the sentinel to align that native run
with the corresponding Lua `CallInfo`.

The trace builder also identifies Titan entry-wrapper CallInfos by symbolizing
their `lua_CFunction` pointer and looking for the same `titanentry` tag. Those
CallInfos are hidden; genuine Lua C functions are shown. This keeps
`Lua -> Titan -> Lua -> Titan` chains interleaved in call order.

The native collector (`titan_bt_collect_cb`) keeps only frames whose debug
filename ends in `.titan` plus the entry-wrapper sentinels. It drops
`titan-runtime/*` frames, unsymbolized frames, and Lua core and standard-library
frames matched against a fixed list of Lua 5.5 source filenames
(`titan_is_lua_source`). Dropping the library files keeps a Lua C function such
as `pcall` from appearing twice, once as its `[C]` CallInfo and once as a native
frame. Source filenames accept both Windows path separators.

Alignment is greedy: at each C-level CallInfo the next sentinel-terminated
native Titan run is drained. Strictly alternating Lua/Titan chains align
exactly. In a `Titan -> Lua C function (e.g. pcall) -> Titan` chain an inner
native run can be spliced one C frame early, but no Lua or Titan frame is
dropped.

On macOS libbacktrace needs the `.dSYM` bundle that `driver.lua`
`run_dsymutil` produces after each final link; without it native Titan frames
are unsymbolized and dropped. With `TITAN_NO_LIBBACKTRACE` defined (for example
on musl/Alpine), `errorhandler` falls back to raw Lua traceback lines plus raw
`execinfo` C frames.

#### Trace backends

`titan.c` selects one trace backend at compile time; there is no vtable,
dynamic dispatch, or heap capture:

| Backend | Selected when | Shape |
| --- | --- | --- |
| libbacktrace | the default (`TITAN_HAVE_LIBBACKTRACE`) | the merged trace above |
| fallback | `TITAN_NO_LIBBACKTRACE` is defined | raw Lua lines, then raw native frames |
| browser | `TITAN_TARGET_BROWSER` is defined | the merged trace via `Error.stack` capture, `.wasm.map` symbolization, and registered entry wrappers |

The browser define takes precedence: the browser backend is selected by the
target define, never by `TITAN_NO_LIBBACKTRACE`, and needs neither
`backtrace.h` nor `execinfo.h`.

The merged backends implement a narrow private interface under the shared
merge (`titan_push_unified_trace` and `titan_drain_native_run`):

```c
typedef ... TitanTraceStorage;
static size_t titan_trace_capture(lua_State *L, TitanTraceStorage *storage);
static int titan_trace_frame_is_entry(const TitanTraceStorage *storage, size_t i);
static void titan_trace_format_frame(lua_State *L,
    const TitanTraceStorage *storage, size_t i, char *out, size_t size);
static int titan_trace_cfunction_is_entry(lua_State *L, lua_CFunction fn);
void titan_invalidate_backtrace_state(lua_State *L);  /* exported */
```

* **libbacktrace.** `TitanTraceStorage` is the native frame stack, backed by
  the merge's on-stack `TITAN_MAX_NATIVE` (512) frame array. Capture calls
  `backtrace_full` with skip 1 at the historical call depth; frame and
  CallInfo entry tests symbolize for the `titanentry` tag; formatting
  produces the qualified Titan names; invalidation clears the registry-owned
  state, as described above. The output is unchanged.
* **Browser.** `TitanTraceStorage` is `{ int status; int truncated; }`, backed
  by the static image-local `titan_browser_trace_buffer` (6152 bytes) and
  `titan_browser_trace_in_use` guard in `titan.c`, so the merge puts no
  512 × 520-byte frame array on the browser or coroutine C stack. Capture
  invokes the synchronous JavaScript adapter to read and parse one
  `Error.stack` into compact 12-byte Wasm records and compacts them in place
  using `.wasm.map` symbolization, the `titan.c` and `titan_is_lua_source`
  filters, and `registry[TITAN_NAMES_KEY]`. `titan_trace_frame_is_entry` tests
  the compact record's `TITAN_BROWSER_TRACE_ENTRY` flag;
  `titan_trace_cfunction_is_entry` looks up the light C function in
  `registry[TITAN_ENTRIES_KEY]` without symbolizing a Wasm indirect
  function-table index as a code PC; `titan_trace_format_frame` resolves one
  record at a time into fixed caller buffers; and
  `titan_invalidate_backtrace_state` is a no-op because static browser images
  never `dlopen` providers.

The fallback stays outside this interface so that its raw capture keeps its
exact call depth: `errorhandler` itself calls `backtrace` (POSIX, then
`backtrace_symbols`) or `CaptureStackBackTrace(0, ...)` (Windows, rendered as
`[native address <pointer>]`) into its 255-entry `nbuf`, with the same
truncation. Both fallback branches root the `luaL_traceback` string on the
Lua stack below the `luaL_Buffer` before initializing it, because appending a
long Lua trace can grow the buffer's box, which must stay the topmost stack
value. The stored value is the Lua trace lines (header removed, presentation
tabs stripped) followed by the native frames.

Pinning and clearing, `TITAN_BACKTRACE_KEY`, bare rethrow, fresh raise,
coroutine trace append, and the standalone report format are the same for
every backend; only the frames differ.

#### Browser trace backend

The browser backend (`titan-runtime/titan.c`, private header
`titan-runtime/browser/titan-browser-trace.h`, and Emscripten library
`titan-runtime/browser/titan-browser-trace.js`) gives browser builds the same
unified trace merge as `libbacktrace` while keeping the native preprocessor
branches and call depths unchanged.

**Fixed C/JS adapter interface.** The runtime communicates with
`titan-browser-trace.js` (pinned to Emscripten 6.0.13) through two synchronous
imports and a fixed Wasm32 memory layout (`titan-browser-trace.h`, private to
`titan-runtime/` and not an installed FFI header):

```c
#define TITAN_BROWSER_TRACE_CAPACITY 512u
#define TITAN_BROWSER_TRACE_HEADROOM 128u
#define TITAN_BROWSER_TRACE_FILE_BYTES 256u
#define TITAN_BROWSER_TRACE_SYMBOL_BYTES 256u
#define TITAN_BROWSER_TRACE_TRUNCATED 1u
#define TITAN_BROWSER_TRACE_HAS_PC 1u
#define TITAN_BROWSER_TRACE_HAS_FUNCTION_INDEX 2u
#define TITAN_BROWSER_TRACE_ENTRY 4u

/* Three uint32 words, little-endian Wasm memory, stride 12 bytes. */
typedef struct {
    uint32_t pc;             /* absolute module byte offset, or 0 */
    uint32_t function_index; /* module function index */
    uint32_t flags;
} TitanBrowserTraceRecord;

typedef struct {
    uint32_t count;          /* raw Wasm records, <= capacity */
    uint32_t flags;          /* bit 0: capture truncated */
    TitanBrowserTraceRecord records[TITAN_BROWSER_TRACE_CAPACITY];
} TitanBrowserTraceBuffer;

int titan_browser_trace_capture(TitanBrowserTraceBuffer *out, uint32_t capacity);
int titan_browser_trace_symbolize(const TitanBrowserTraceRecord *record,
    char *base, uint32_t base_bytes, char *symbol, uint32_t symbol_bytes,
    uint32_t *line);
```

* `titan_browser_trace_capture` (import signature `iii`) initializes `count`
  and `flags` before any work and returns `0` (`OK`), `1` (`MAP_UNAVAILABLE`,
  the eager loader's degraded state), or `2` (`CAPTURE_FAILED`). On any error
  it clears `count` and returns failure without letting a JavaScript exception
  escape into Lua's error handler. Header `flags` bit 0 is `TRUNCATED`; all
  other header bits are zero. Each written record represents one WebAssembly
  activation on the current synchronous stack, innermost to outermost, with
  record `flags` bit 0 (`HAS_PC`) and bit 1 (`HAS_FUNCTION_INDEX`) set
  independently; JavaScript frames are never written to `records`.
* `titan_browser_trace_symbolize` (import signature `iiiiiii`) writes
  NUL-terminated UTF-8 strings into the caller-provided `base` and `symbol`
  buffers (truncating cleanly on UTF-8 codepoint boundaries) and sets `*line =
  0` before work. It returns `0` (`UNKNOWN`), `1` (`RESOLVED`, a validated
  in-function mapped location with `*line > 0`), or `2`
  (`SYMBOLIZATION_FAILED`). `UNKNOWN` may still supply a verified function
  symbol and declaring `.titan` basename with `*line = 0` (for example on
  WebKit, where frames carry a function index without a PC, or for an unmapped
  instruction inside a known Titan function). It never calls `malloc` in Wasm
  memory and never replaces the active Lua error.

The adapter parses `Error.stack` directly; it does not use Emscripten's
internal `emscripten_stack_snapshot`, `emscripten_stack_unwind_buffer`,
`emscripten_pc_get_file` (which `malloc`s per call), `EM_LOG_C_STACK`, the
instance-global `UNWIND_CACHE`, or the sanitizer-only `LOAD_SOURCE_MAP`
support.

**Off-stack storage, reentrancy guard, and protected merge.** Each Wasm
instance is single-threaded and owns one static `TitanBrowserTraceBuffer`
(`titan_browser_trace_buffer`, 6152 bytes), one static in-use flag
(`titan_browser_trace_in_use`), and fixed per-frame formatting buffers.
`errorhandler` checks `titan_trace_pinned(L)` before acquiring the buffer. If a
genuine nested trace attempt occurs while `titan_browser_trace_in_use` is
already held (for example across multiple Lua states in the same Wasm instance
or during a custom error path), it passes `capture_status = 2` to the merge and
neither touches `titan_browser_trace_buffer` nor releases the outer attempt's
guard; instead it takes the bounded Lua-only capture-failed fallback. Browser
trace generation (`titan_browser_trace_generate`: `luaL_Buffer` initialization,
`titan_push_unified_trace`, and `registry[TITAN_BACKTRACE_KEY]` publication)
runs inside `luaD_rawrunprotected`: on every return status the outer frame
releases `titan_browser_trace_in_use` (when `!nested`), restores `L->ci`,
`L->allowhook`, and `L->errfunc` following the `titan_unwind_clear_trace`
pattern, and rethrows any non-OK status (such as `LUA_ERRMEM` raised while
growing `luaL_Buffer`) with `luaD_throw`, preserving the native OOM outcome and
leaving the buffer ready for the next capture. While
JavaScript `Error` construction and stack-string parsing allocate in the
JavaScript heap and growing `luaL_Buffer` during the merge uses Lua's protected
allocator, C capture and per-frame symbolization write into preallocated scratch
storage and never call `malloc`.

**Synchronous capture transaction and descriptor preservation.** Capture
executes as one synchronous JavaScript transaction in `titan-browser-trace.js`:

1. Read the own property descriptors of `Error.stackTraceLimit` and
   `Error.prepareStackTrace` with `Object.getOwnPropertyDescriptor`, recording
   when either property is absent. Never read either property through ordinary
   property access and never invoke a getter or setter.
2. Validate that the caller-supplied `capacity` (owned by the C header's
   `TITAN_BROWSER_TRACE_CAPACITY = 512`) is a positive `uint32_t` whose `8 +
   12 * capacity` bytes fit in the current Wasm heap, and configure
   `Error.stackTraceLimit` to at least `capacity + 128` (`640`, leaving `128`
   frames of JS headroom) via `Object.defineProperty`, keeping a larger
   existing finite numeric data-property value. A configurable descriptor
   (including an accessor) is replaced without invoking it; a
   non-configurable, writable data property has only its `value` updated;
   otherwise the descriptor is left untouched and capture runs under the
   engine's current limit.
3. Check `Error.prepareStackTrace`. If it is an accessor (even configurable) or
   a non-configurable, non-writable data property whose value is not
   `undefined`, reading `.stack` could execute host code: abort immediately
   with `CAPTURE_FAILED` without constructing or reading an `Error.stack`.
   Otherwise mask it via `Object.defineProperty` with a safe data descriptor
   whose value is `undefined`, without altering non-configurable attributes.
4. Construct one `new Error()` and read its `.stack` string once.
5. In `finally`, restore both original own descriptors independently with
   `Object.defineProperty`, or `delete` properties that were originally absent.
   Any restoration failure is recorded as `CAPTURE_FAILED` and never thrown.

**Engine stack formats, depth ceilings, and truncation.** The line parser
accepts the WebAssembly frame spellings established by the six-engine survey
([Browser target: stack survey](browser-target.md#webassembly-stack-survey)):

```text
V8 named:       at name (wasm://wasm/IMAGE:wasm-function[N]:0xPC)
V8 stripped:    at http://HOST/IMAGE.wasm:wasm-function[N]:0xPC
SpiderMonkey:   [name]@http://HOST/IMAGE.wasm:wasm-function[N]:0xPC
JSC named:      name@IMAGE.wasm:wasm-function[N]
JSC cold/none:  N@wasm-function[N]
```

The display prefix before `(` or `@` is never trusted for symbolization; the
parser extracts the bracketed decimal function index `N` (never treating JSC's
leading decimal number before `@` as a line) and, on V8 and SpiderMonkey, the
hexadecimal module-relative byte offset `0xPC`. SpiderMonkey may append saved
asynchronous ancestry after a JavaScript frame prefixed by an async cause and
`*`, such as `async*`, `promise callback*`, `VoidFunction*`, or
`setTimeout handler*`. The parser stops before that boundary, excluding both
the saved JavaScript and Wasm frames from capture. It recognizes Wasm frames
first, so an asterisk in an image name is not a boundary; asterisk-bearing URLs
are not cause prefixes either. Parent coroutine traces come exclusively from
the coroutine trace handoff (`pending_append_trace` in `titan.coroutine`).

Header flag `TRUNCATED` is set when more Wasm frames exist beyond `capacity`,
when the synchronous stack reaches the effective `stackTraceLimit` (counting
`at ` frame lines on V8-shaped stacks — so V8's `Error` title line never counts
even when its message contains `@` — and `@`-containing frame lines on
SpiderMonkey/JSC stacks, which have no title line and may include location-free
builtin frames such as `forEach@[native code]`, while excluding SpiderMonkey's
saved asynchronous ancestry), or when Firefox's engine ceiling is reached:

* **V8 (Node, Chromium, Chrome)** honors `Object.defineProperty` on
  `Error.stackTraceLimit` up to the 512-record capacity.
* **SpiderMonkey (Firefox)** enforces a 128-frame synchronous capture ceiling
  regardless of `Error.stackTraceLimit`; captures reaching that ceiling set
  `TRUNCATED`.
* **JavaScriptCore (Playwright WebKit and Safari)** uses the same 512-record
  capacity and effective host limit. Current WebKit captures exceed the
  100-frame ceiling of older surveyed releases; that historical ceiling is not
  inferred from the no-PC frame format. An absent `Error.stackTraceLimit` is
  temporarily installed for capture and removed again on restoration, just as
  on other engines. Any non-string or unreadable `.stack` still follows the
  `CAPTURE_FAILED` path; the engine name alone does not imply capture failure.

When the C merge falls back to Lua-only `CallInfo` enumeration (`st.status !=
0`, under `MAP_UNAVAILABLE` or `CAPTURE_FAILED`), browser enumeration in
`titan_push_unified_trace` is bounded at `TITAN_BROWSER_TRACE_CAPACITY` (512)
`CallInfo` frames and sets `st.truncated = 1` if cut short.

**Eager map loader, extensions, and lookup validation.** During module startup,
`titan-browser-trace.js` (`$TitanBrowserTrace`) constructs its line-parser
`RegExp` table inside `install()` (because Emscripten serializes compile-time
library object properties as JSON, which would turn `RegExp` literals into `{}`)
and registers an `addOnPreRun` hook that adds the run dependency
`titan-trace-map`. It loads `locateFile('{{{ WASM_BINARY_FILE }}}.map')`
(`fetch(path, {credentials: 'same-origin'})` in browsers, `readBinary(path)` in
Node), validates the standard v3 source-map fields (accepting an empty
`sourcesContent: []` array as emitted by Emscripten 6.0.13 with `-sASSERTIONS=0`
or a `sources.length`-matched array of strings/nulls, while retaining no source
content) and Titan's four `x_titan_*` extension keys
([Browser target: source-map extensions](browser-target.md#source-map-extensions-and-image-identity)),
compares `x_titan_image` against the instantiated Wasm export
`UTF8ToString(wasmExports['titan_browser_trace_identity']())`, builds a compact
typed-array index, publishes `Module['titanBrowserTrace']`, and removes
`titan-trace-map` whether initialization succeeded (`state: 'ready'`) or
degraded (`state: 'degraded'`). On a degraded load it logs one console warning
prefixed with `Titan browser trace: ` and never fetches or reparses on the
error path.

The in-memory index (`buildIndex`) walks `map.mappings` in two passes to
populate six typed arrays without allocating one JS object per segment:
`pcs` (`Uint32Array`), `sources` (`Int32Array`), and 1-based `lines`
(`Uint32Array`, retaining 1-field unmapped VLQ segments as explicit
`source = -1, line = 0` markers), along with the defined functions' half-open
code ranges `starts` and `ends` (`Uint32Array`) and each function's first valid
in-function mapped source index `first` (`Int32Array`, which
[function-definition `#line` stamps](codegen-overview.md#mixed-source-line-attribution)
keep on the function's own declaring `.titan` file rather than a preceding
contributor's trailing `#line`), plus the `names` and basename-normalized
`bases` arrays. A line lookup (`lookup`) succeeds
(`RESOLVED`, `line > 0`) only when:

1. `pc` lies within `[start, end)` of a defined function body `j`;
2. if `HAS_FUNCTION_INDEX` is set, `function_index` equals `imports + j`; and
3. the greatest mapping segment with `offset <= pc` inside `[start, end)` exists
   and is not an unmapped marker.

Unlike Emscripten's stock `WasmSourceMap.normalizeOffset`, which extends the
preceding segment across function boundaries and unmapped gaps, this check
never attributes an unmapped `dynCall_*` wrapper or a no-debug Lua C function to
an adjacent Titan function's lines, and never invents a line from a function
index alone. If PC validation fails, symbolization still retains a verified
function name and declaring basename with `line = 0` (`UNKNOWN`).

**Per-frame classification, entry registration (`TITAN_ENTRIES_KEY`), and
rendering.** After `titan_browser_trace_capture` returns, `titan_trace_capture`
compacts the raw records in place, checking symbol identity before the
runtime/Lua basename filter so an entry sentinel or registered Titan symbol is
never discarded by a colliding filename:

* **Entry sentinel:** the resolved C symbol contains `titanentry`
  (`TITAN_ENTRY_TAG`). The record is kept with `TITAN_BROWSER_TRACE_ENTRY` set,
  even when it has no mapped source line.
* **Registered Titan symbol:** the resolved C symbol is present in
  `registry[TITAN_NAMES_KEY]`.
* **Mapped Titan source frame:** after dropping `titan.c` and Lua core/library
  files in `titan_is_lua_source`, a record whose resolved basename ends in
  `.titan` (covering `name.browser.titan` variants) is kept.
* **Dropped:** `titan.c`, `titan_is_lua_source` files, and unmapped non-Titan
  C/Lua/`dynCall_*` helpers that matched neither `titanentry` nor
  `TITAN_NAMES_KEY`. Arbitrary C symbols are not classified as Titan frames
  merely because their name contains `_titan`.

On native targets, `titan_cfunction_is_entry` symbolizes a `CallInfo`'s
`lua_CFunction` pointer through `libbacktrace`. In WebAssembly, a
`lua_CFunction` pointer is an index into the indirect function table (`__indirect_function_table`),
not a module code byte offset, and must never be cast to a PC or looked up in
the source map. Instead, `titan.h` defines a browser-only registry key:

```c
#ifdef TITAN_TARGET_BROWSER
#define TITAN_ENTRIES_KEY "0c6fbc42-27b4-497f-a6f3-3c9e1f4d7b20"
#endif
```

For `--target browser`, each generated module's `_init` lazily creates
`registry[TITAN_ENTRIES_KEY]` (and publishes `registry[TITAN_NAMES_KEY]` at the
same early point, before dependency or user module initializers run) and
registers every actually emitted `titanentry` wrapper deduplicated by C symbol:

```c
lua_pushcfunction(L, WRAPPER_SYMBOL);
lua_pushboolean(L, 1);
lua_rawset(L, -3); /* entries[light C function] = true */
```

The coder records every generated `int(lua_State *)` Lua-callable `titanentry`
wrapper family (top-level `_titanentry_lua` and `_titanentry_strict`, nominal
statics `_titanentry_luastatic` and `_titanentry_strictstatic`, methods
`_titanentry_luamethod`, bound methods `_titanentry_boundlua` and
`_titanentry_boundstrict`, Interface wrappers `_titanentry_interfacelua`,
`_titanentry_interface_boundlua`, and `_titanentry_interface_boundstrict`,
lambda Lua and strict entries, and callable-adjustment strict adapters). The
tagged module initializer (`void(lua_State *, Udata *, CClosure *)`, called
directly while the `luaopen_*` `CallInfo` is active) is not a `lua_CFunction`
and is not registered in `registry[TITAN_ENTRIES_KEY]`: its native frame
remains an entry sentinel by its `titanentry` symbol name, and `luaopen_*`
remains a genuine C `CallInfo`, matching native classification. At trace time
`titan_trace_cfunction_is_entry` pushes `lua_tocfunction` as a light C function
and performs a non-allocating `lua_rawget` in `registry[TITAN_ENTRIES_KEY]`.
Compiled-module ABI versions remain unchanged.

During the merge, `titan_trace_format_frame` formats a resolved record (`line >
0`) as `<basename>:<line>: in <display name>` and an unlocated record (`line ==
0`, including all WebKit Titan frames) as `<basename>: in <display name>`,
calling `titan_qualified_name` to look up `<display name>` in the capturing
state's `registry[TITAN_NAMES_KEY]` and falling back to the raw C symbol (for
example, when a trace captured inside an independent auxiliary `lua_State` sees
outer physical stack frames from a parent runner module that was not
initialized in that auxiliary state) or `?` when no symbol or declaring
basename is known. When capture returned `MAP_UNAVAILABLE` or
`CAPTURE_FAILED`, the trace emits one availability marker line —
`(native Titan frames unavailable: trace map not loaded)` or
`(native Titan frames unavailable: capture failed)` — and when `TRUNCATED` is
set (or bounded Lua-only fallback enumeration is cut short), it appends
`(...native frames truncated...)` once at the end of the trace.

#### Backtrace state invalidation

libbacktrace snapshots the process's loaded objects on its first symbol lookup,
so a newly mapped provider must invalidate it. Every generated module selects
`titan.o` from `libtitan.a` into its own image, so the cache cannot be a C
static: every runtime copy reads the same registry-owned userdata at
`TITAN_BT_STATE_KEY`, whose payload is the cached `backtrace_state *`.
`titan_invalidate_backtrace_state` clears that slot, and the next error lazily
creates a fresh state. The slot is cleared by:

* the run-time provider loader (`titan_path_open_global` in
  `titan-runtime/titan_path.c`, shared by compiled imports' `loadlib` and the
  [Titan package searcher](driver.md#the-titan-package-searcher)), only after
  `dlopen` maps a new image for the state (the cached-handle fast path does
  not invalidate); and
* every generated `luaopen_*` (the postamble in `titan-compiler/coder/module.lua`),
  through `titan_invalidate_backtrace_state`, which covers modules loaded by
  Lua's own `require`.

`titan_path.c` and the Windows loader (`titan-runtime/titan_winloader.h`
`titan_win_load_library`) do not call `titan_invalidate_backtrace_state`: they
clear the same registry slot inline, only when they map a new image, because
the support module that also links them does not link `titan.o`.

The opaque state may retain function pointers into the image whose
libbacktrace copy created it. Titan never `dlclose`s dependency handles during
the process lifetime, and a Lua C-library handle stays mapped until its state
closes.

Windows uses libbacktrace's PE/COFF reader and the LLVM static unwinder. The
Windows dependency patch relocates COFF symbols to each loaded image's actual
base, bounds symbol lookup to that image's extent, and disables the upstream DLL
notification callback, which retains transient callback data and parses images
under the loader lock. Titan's own load/open invalidation refreshes the
snapshot outside that boundary.

### Source lines and display names

Native frames point back to Titan source through the `#line` directives
described in [mixed-source line attribution](codegen-overview.md#mixed-source-line-attribution).
Those include the [function-definition
stamps](codegen-overview.md#mixed-source-line-attribution) that own a
function's signature, GC poll, stack reservation, and argument setup before its
first statement, so a frame whose program counter is still in that prologue
names the function's own declaring `.titan` file and definition line. The
debug-information level that keeps those line records is chosen by
[`driver.compile`](driver.md#compiling-one-module-drivercompile). The trace
builder never inspects variable locations. With line directives disabled, the
debug filename no longer ends in `.titan`, so logical tracebacks may omit
native Titan frames; an entry boundary can remain only as a hidden sentinel or
render as `[C]`.

libbacktrace and the browser trace backend report C symbol names, which cannot
contain Titan punctuation such as `.` or `:`. Each module `_init` contributes a
mapping from native C symbol name to display name in a shared registry table
under `TITAN_NAMES_KEY` (including source `foreign function` definitions with
Titan bodies on both native and browser targets, for both the out-of-line
`_foreign_func_name` and any local `_foreign_inline_name` helper, with `#line`
directives emitted on raw statements by `_foreign_raw_stat`). The runtime
formats frames with those display names:

* `<module>.<function>`
* `<module>.<record>:<method>`
* `<module>.<record>.<static>`
* `anonymous function at <file>.titan:<definition-line>`

Because `registry[TITAN_NAMES_KEY]` is per-`lua_State`, `titan_qualified_name`
(`titan.c`) resolves display names only for modules initialized in the state
capturing the trace; on both native and browser targets, a physical stack frame
from a module initialized only in an outer `lua_State` falls back to its raw C
symbol (or `?` when the symbol itself is unknown).

## Frontend representation

`catch`, `finally`, and `raise` are reserved words. `finally` has no surface
syntax; `Ast.StatTry`'s finally block exists only as the target of `defer`
lowering.

The grammar has no `try` keyword. The `block` production parses a statement
block and then optionally absorbs a `catch` trailer. `defs.trywrap`
(`titan-compiler/parser.lua`) returns the plain `Ast.StatBlock` when there is no
trailer and otherwise builds:

```lua
Ast.StatTry(loc, block, catchblock, nil)
```

`defer` statements lower to `Ast.StatTry(loc, tail, nil, finallyblock)`; see
[Defer](defer.md#parser-lowering).

`raise <exp>`, `raise <exp>, <trace>` and bare `raise` parse as
`Ast.StatRaise(loc, exp, trace)`. A nil `exp` means bare re-raise and a nil
`trace` means that the handler captures one. A comma needs a trace expression
after it (`ExpRaiseTrace`), and a trace needs an error value before it.

The catch clause body is a plain statement list, not a full trailer-consuming
block. Every `case` arm and its optional `else` consume the ordinary full
`block` production, so an arm can carry its own `catch` trailer or `defer`
statements and produces the same `Ast.StatTry` wrapper; there is no
case-specific error-handling form.

## Checker rules

`StatTry` checks its body, catch, and finally in sibling scopes. Catch-local
bindings are synthesized only in the catch scope:

* `error: value`
* `traceback: string`

They are read-only snapshots. The checker marks them as implicit catch locals
and rejects assignment to either name.

Body locals are deliberately invisible in catch/finally, because a body error
may happen before a given local declaration has executed. A `case` payload
binding is visible in that arm's protected body and its clauses; see
[Unions](unions.md#case-checking-and-control-flow).

The checker state counters are declared in `titan-compiler/checker/common.lua`
and saved and reset across nested function bodies
(`checker/declarations.lua`):

* `catch_depth`: bare `raise` is legal only while it is positive, so a lambda
  written inside a catch does not inherit re-raise permission.
* `in_finally`: `return` while positive is a compile-time error.
* `finally_loop_floor`: `break` inside a finally is an error unless its target
  loop was opened inside that finally.

`raise <exp>` checks the expression normally and coerces it to `value`. A
trace operand is checked as a `string` sink. Both forms are allowed in a
finally, because ordinary run-time errors can always occur during cleanup and
must override pending control flow. `StatRaise` is non-fallthrough.

The non-fallthrough rule for a try is:

```text
(finally exists and finally is non-fallthrough)
or
(body is non-fallthrough and (no catch or catch is non-fallthrough))
```

As with `StatBlock`, `StatIf`, and `StatCase`, `checkstat` records that result
on the node as `_always_returns`. Statement-list code generation consumes this
decoration when stopping at a dead tail; see
[non-fallthrough analysis](checker.md#non-fallthrough-analysis).

## Code generator overview

`codetry` (`titan-compiler/coder/statements.lua`) emits catch/finally as
straight-line C inside the native function. It does not allocate thunks or
capture the body into a closure.

A `StatTry` body always gets an inline protected boundary, including
finally-only (`defer`) blocks. A catch gets its own boundary only when a
finally follows it, so an error raised by the catch still runs the finally. A
finally installs no boundary of its own.

The boundary uses Lua 5.5's `lua_longjmp` layout and `TITAN_SETJMP` selector,
vendored into `titan-runtime/titan.h` from `ldo.c`. `boundary_save` and
`boundary_recover_open` mirror the parts of `luaD_rawrunprotected` and
`luaD_pcall` that matter for generated code:

1. save `L->nCcalls`, `L->ci`, `L->allowhook`, `L->errfunc`, and the old top
   offset;
2. link a stack-allocated `lua_longjmp` into `L->errorJmp`;
3. run the protected body under `TITAN_SETJMP`;
4. restore `L->errorJmp` and `L->nCcalls` on every exit from the protected
   block;
5. on error, restore `ci` and `allowhook`, restore the saved `errfunc`, run
   `luaD_closeprotected` (for a try with a finally, under the re-armed boundary
   of [suspension during error recovery](#unwinding-through-finally)), move the
   error object to the saved top with `luaD_seterrorobj`, recompute `_base`
   from `_base_off`, snapshot the error and trace into reserved slots, clear the
   registry trace and pin, restore `L->top.p` to
   `_base + TITAN_RESERVED_NSLOTS`, and reload setjmp-sensitive spills.

The saved `errfunc` is restored before `luaD_closeprotected` because the
longjmp may have skipped an inner Titan Lua-entry wrapper before that wrapper
could restore its own message handler. A Lua `__close` metamethod that raises
during cleanup must be handled by a valid Titan error handler, not by a stale
stack slot belonging to the skipped entry.

The saved error object, saved traceback, pending raise object, and GC-typed
saved return values live in reserved Lua stack slots below the function's
steady-state top; stack slots are roots and need no write barrier. Non-GC
pending return values live in `volatile` C temporaries, because they can be
written before a finally runs and read after a longjmp out of that finally.

A flexible pending return additionally needs a saved actual count, typed
backing for the live tail, and traced slots for every GC-bearing saved element.
The transient `_flexout` descriptor is caller-owned C memory and is not a root;
the pending-action frame preserves the values independently while the finally
body allocates, calls, or raises.

### Pending actions for finally

A try with finally has a discriminator whose values are the Lua string
constants `PA_NONE`, `PA_RETURN`, `PA_BREAK`, `PA_RAISE`, and `PA_UNWIND`
(`"0"`..`"4"`) in `coder/statements.lua`, emitted as C integer literals.
`PA_UNWIND` belongs to [unwinding through finally](#unwinding-through-finally).

Body or catch fallthrough leaves `PA_NONE`. A `return` or `break` inside a
finally-protected body or catch does not use `longjmp`; it saves any return
values, records the pending action, restores any protected boundaries that the
generated `goto` is about to exit, and jumps to the finally label.

After the finally runs, `dispatch_after_finally` emits an if-chain over the
pending action. It is intentionally not a C `switch`, because the `PA_BREAK` arm
must emit a `goto` to the label after the target Titan loop, not a C `break`
that a `switch` could capture. If the finally itself raises, the longjmp skips
the dispatch and overrides the pending action.

Nested finally blocks chain inside-out. During a pending return or break, the
inner dispatch can copy saved return values into an outer finally frame or
route a break through the next enclosing finally before realizing the final
action.

For a flexible return, that inside-out copy carries both the count and the live
tail, respecting the inherited `_flexwant` budget. Normal completion
reconstructs the native output descriptor and resumes the pending return; a
raise from the finally abandons it. The flexible-tail frame owns bounded typed
backing and, for GC-bearing elements, a parallel traced stack range that stays
live throughout the finally body and any inside-out frame copy.

### Unwinding through finally

An abandoned suspended coroutine is unwound by its finalizer
([Coroutines](coroutines.md#unwinding-an-abandoned-coroutine)). For that walk,
`boundary_save` initializes the `lua_longjmp.status` of each boundary of a try
with a finally to `TITAN_STATUS_FINALLY` instead of `LUA_OK`. Those are the body
boundary and the catch boundary `<id>c`. Catch-only boundaries keep `LUA_OK`, and
the walker skips them. On the normal path the only change is the constant, which
`boundary_recover_open` also compares against.

When the walker lands with `TITAN_STATUS_UNWIND`, the recovery arm:

1. restores `ci`, `allowhook` and `errfunc`;
2. closes the Lua frames above the boundary with `titan_unwind_close`, so each
   `__close` gets no error value and each failure becomes one warning;
3. restores `_base`, the reserved top and the setjmp spills;
4. skips any catch and sets `PA_UNWIND`.

The finally body then runs under a guard. The guard reuses the try-scope
`_lj_<id>`, which is already unlinked, through another `TITAN_SETJMP` call
site. If an error escapes the body, `titan_unwind_guard_failed` restores the
boundary state, reports the error, closes the frames the body entered, and
continues the unwind. After a normal finish, the dispatch arm for `PA_UNWIND`
unlinks the guard and calls `titan_unwind`, which never returns.

`titan_unwind`, `titan_unwind_close`, `titan_unwind_report` and
`titan_unwind_guard_failed` are declared `TITAN_COLD`. This marks the unwind arm
of the recovery, the guard failure and the `PA_UNWIND` dispatch unlikely. An
optimized build may then place them outside the normal path's hot instruction
stream; GCC can split them into the function's `.cold` part in `.text.unlikely`.

**Suspension during error recovery.** A `__close` metamethod that the ordinary
error recovery calls may suspend the coroutine with a Titan `yield`: Lua's
`luaD_closeprotected` calls it through `luaD_callnoyield`, which refuses only a
Lua yield. While that close runs, the try's finally has not started yet. So for
a boundary of a try with a finally, the recovery re-arms the boundary first:

1. it keeps the caught status in a `volatile` local and relinks `_lj_<id>` with
   `TITAN_STATUS_FINALLY`;
2. it runs `luaD_closeprotected` under another `TITAN_SETJMP` call site on the
   same buffer, then unlinks the boundary again.

`luaD_closeprotected` catches every error raised by a `__close` itself, so only
the walker can jump to the re-armed boundary. That happens when the coroutine
is abandoned while suspended in the close. The jump arrives with
`TITAN_STATUS_UNWIND` and takes the landing above: the caught error is dropped,
the rest of the close method and the catch never run, and the pending finally
runs exactly once. Only on that jump, the re-arm's `TITAN_SETJMP` arm calls the
cold `titan_unwind_clear_trace`, which clears the registry trace and pin
(`TITAN_BACKTRACE_KEY`, `TITAN_TRACE_PINNED`) as a catch recovery does, so
`titan.backtrace()` does not keep the dropped error's trace. The arm is that one
call, so it adds almost no code to the function. If the coroutine is resumed instead, the close finishes and
the ordinary recovery continues. The coroutine floor re-arms itself the same way
around the close of an error that escaped the entry
([Coroutines](coroutines.md#unwinding-an-abandoned-coroutine)).

Every try with a finally declares its boundary locals at try scope, because the
guard must outlive `$CFINALLY` and `$DISPATCH`. The guard's close level is the
reserved top the landing established, `_base_off + TITAN_RESERVED_NSLOTS`
slots. `_base_off` is written once at function entry, so it is well defined
after the jump. The landings and the re-armed close read only what an error
landing reads, and no code of the enclosing function runs between the
re-arming `TITAN_SETJMP` and a jump to it (only `__close` methods do), so the
setjmp spill analysis below needs no change.

### Boundary restoration on generated `goto`

The main footgun is a `goto` to a finally label that exits the C lexical scope
of one or more inline boundaries. If `L->errorJmp` still points at a
stack-allocated `lua_longjmp` in a scope the goto has left, a later raise from
the finally would longjmp through a dangling pointer.

The coder keeps `ctx.protected_boundary_stack`. Each finally frame records the
stack depth at which it was opened. A return or break routed to that finally
calls `restore_boundaries_to`, which emits restoration for every boundary deeper
than that floor before the `goto`:

```c
L->errorJmp = _lj_N.previous;
L->nCcalls = _oldnC_N;
```

Restoration stops at the finally's floor, so outer still-active boundaries
remain installed and can catch or cascade a raise from the finally.

Loop breaks have a second restoration path. A loop that contains a try saves
its entry `errorJmp`/`nCcalls` (`_loop_errorjmp_<id>`); a direct break that
crosses a try boundary restores that loop-entry state before jumping to the
loop's after-label.

### setjmp-sensitive local/parameter spills

C's `setjmp` rule makes the value of a non-`volatile` automatic variable
indeterminate after a longjmp if it was changed between `setjmp` and the
longjmp and is then read. Titan does not make every local or parameter C auto
`volatile`. Instead, `analyze_try_spills` (`titan-compiler/coder/flow.lua`)
runs a small liveness pass over each function or lambda that contains a
`StatTry`, and `mark_spills` sets `_needs_spill` on a Decl only when all of these
are true:

* the Decl is a Titan local, parameter, or method `self` in the current
  generated C function;
* it is not boxed through a capture cell;
* it is assigned in a protected body whose error path can later read it from a
  catch, finally, or handled post-try path; or it is assigned in a catch that
  has its own protected boundary and its finally can read it. A contextual
  mutable C-address conversion counts as a possible write, including an
  ordinary Titan call that can raise and direct mutable array decay.

GC-typed Decls without a mutable C address use their reserved Lua slots as
stable recovery storage. Assignments keep the slot current, and recovery
reloads the C auto after `_base` and the reserved top have been restored.
Lua's GC is non-moving, so pointers to GC objects remain valid; only pointers
to Lua stack locations are recomputed from saved offsets such as `_base_off`.

Marked non-GC scalar Decls whose address is not exposed get a small C-stack
spill:

```c
lua_Integer _local_n_1;
volatile lua_Integer _spill_local_n_1;
```

`spill_update` refreshes the spill after assignments, and `spill_reload`
reloads the C auto from it in the recovery arm before catch, finally, or
post-try code can read it. `push_spillscope`/`pop_spillscope`
(`coder/statements.lua`) track lexical spill scopes, so a recovery boundary
reloads only spills whose Decls are currently in C scope. Non-address-exposed
C aggregates keep byte spills; see
[longjmp-safe aggregate spills](c-ffi-expressions.md#longjmp-safe-aggregate-spills).

An eligible direct-C local or parameter whose **mutable** address is taken
instead uses **one genuinely volatile automatic object** as its canonical
recovery home, plus a compiler escape barrier at its declaration:

```c
void *volatile _local_raw_1;
__asm__ __volatile__("" : : "r"(&(_local_raw_1)) : "memory");
```

`coder._decl_volatile_home` selects this home for a marked, address-taken,
unboxed direct-C Decl: integers, floating types, enums, pointers, structs,
unions, fixed arrays and automatic FAM backing, including typedef spellings.
`coder._local_cvardecl` qualifies locals and parameters, including lambda
parameters. Automatic arrays retain their real extent rather than undergoing
parameter adjustment. FAM storage gives its aligned backing union a volatile
object type for the C `setjmp` rule, but its existing typed pointer view is
unqualified. The declaration escape barrier and supported nonlocal-exit
toolchain contract preserve writes; the view does not make every FAM access
volatile. No second byte snapshot or recovery reload is emitted. Outgoing
pointer types remove only implementation qualifiers without changing the native
signature or ABI. `spill_decl_init` and `spill_decl_zero` emit the barrier.

Exact Lua `TValue` and `Udata *` out-parameters additionally retain their
existing traced Lua slots. A normal return publishes their current values
immediately. Every longjmp landing publishes the volatile C homes into those
slots **before** closing Lua frames, running `__close` or entering an unwind
helper that can collect. The publication restores the stack base and uses
nonallocating `setslot` stores; it never reloads an older root into the home.
This applies to the initial landing, the re-armed close landing and the unwind
finally guard. Defer-tail predeclarations zero these C homes and reserve their
root slots before an earlier landing can visit them. Foreign writers retain
their existing obligation to root fresh GC objects through the handoff; see
[mutable GC out-parameters](values-and-gc.md#mutable-gc-out-parameters).

Rules for changing this code:

* **Toolchain contract.** This is an implementation guarantee on the supported
  GCC and Clang toolchains (including Windows MSYS2 Clang), not a strictly
  conforming ISO C guarantee: ISO C 6.7.3p6 makes access to an object defined
  volatile through a non-volatile lvalue undefined, and the out-parameter API
  uses unqualified pointers. MSVC is not a supported generated-C toolchain.
* **Why the barrier exists.** Without it, GCC can delete an inlined unqualified
  store through the address when a later checked conversion raises through
  terminal `luaL_error`/`abort` and only nonlocal recovery reads the home.
  Volatility alone does not preserve that indirect store; the barrier's address
  operand and `"memory"` clobber keep the home escaped after inlining, within
  one translation unit or across units under Linux's default
  `-O3 -flto=auto -ffat-lto-objects`.
* **Inlining assumptions.** A function that contains a `catch` exposes a
  `returns_twice` call and stays out of line under
  [GCC's `setjmp` inlining restriction](https://gcc.gnu.org/onlinedocs/gcc/Inline.html)
  and [LLVM's `isInlineViable`](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.8/llvm/lib/Analysis/InlineCost.cpp#L3346-L3350).
  The default Lua build has no LTO IR, so `lua_error` and its nonlocal exit stay
  opaque. Whole-program LTO that exposes Lua's error machinery, or new optimizer
  behavior, requires requalifying this design.
* **Cost and scope.** The escape barrier emits no instruction and runs once per
  declaration, including a redeclaring loop iteration. The home needs no heap
  allocation or per-call aggregate snapshot. GC out-parameters publish into
  already reserved root slots. This does not track retained raw aliases or
  asynchronous C writes.
* **Regressions.** `spec/fixtures/error_handling/scalar_recovery.titan` exercises
  an inlined checked-return failure with no normal-path read. The companion
  `aggregate_recovery.titan` covers structs, unions, arrays and FAMs, scalar
  kinds, parameters and lambdas, plus fresh `TValue`/`Udata *` publication and
  cleared old-root collection during a full GC in `__close`. The owning coder
  specs compile the native fixtures at `-O2` and `-O3`.

Recovery retains the actual writes of a callee that wrote through a tracked
mutable address and then raised; it never restores the caller's pre-call
bytes. An acquired resource therefore remains visible to its cleanup, and a
transferred resource cannot be restored for a second release. Locals without
an exposed mutable C address keep the spill/reload behavior described above.

The variadic descriptor structs follow the same rule. Their C-stack records
contain counts and pointers to GC objects or typed C arrays, not pointers to Lua
stack slots, so the descriptor being on the C stack is not a stack-relocation
hazard.

## ABI and search path

The inline boundary depends on the vendored `lua_longjmp` layout matching the
linked Lua build, and generated recovery depends on the runtime's registry keys
and `titan_registry_*` helpers, so this machinery is part of the
[compiled-module ABI](codegen-overview.md#compiled-module-abi). Errors raised by
adapters, guards, conversions, or downcasts use the same Titan error handler,
and all wrapper roots are ordinary Lua-traced values, so unwinding needs no
resource-specific cleanup path. ABI markers keep the unversioned `.` component
of the default binary [search path](driver.md#module-names-and-the-search-paths)
from silently loading stale build artifacts.

## Tests to keep close

* `spec/coder/backtrace_spec.lua`: unified trace order, source-line
  attribution, standalone top-level error handler.
* `spec/coder/so_trace_names_spec.lua`: dlopened module trace-name
  registration and libbacktrace state invalidation.
* `spec/checker/error_handling_spec.lua`: catch/finally scopes, bare raise
  legality, finally transfer bans, and non-fallthrough analysis.
* `spec/coder/error_handling_spec.lua`: catch, fresh raise versus re-raise,
  `raise <exp>, <trace>` (the given trace caught and uncaught, the one-shot
  pin, the value kept while the trace expression collects),
  trace clearing, pending actions, finally override, nested finally order,
  sustained-OOM catch/defer recovery across functions, closures, and module
  initializers, GC-valued pending returns (including flexible tails),
  standalone uncaught-error reporting, and the generated unwind boundaries
  (the finally marker and no unwind code in a catch-only try).
* `spec/coder/unwind_stdlib_spec.lua`: a grafted catch-plus-finally try
  unwound through its catch boundary under the installed `titan.coroutine`
  (a stdlib compiler spec, run after the full provider is installed).
* The `test_unwind_*` cases of the `coroutine.tests` folder module in
  `spec/stdlib/titan/coroutine/tests/`: `unwind_common.titan` holds the cases
  shared by every target; `unwind_test.native.titan` holds the host cases that
  need a child Lua state, `titan.async`, or `titan.string`, including a
  coroutine abandoned while suspended in an error-recovery `__close`, a
  failing finally inside an immediately invoked lambda, and a module
  initializer suspended inside `require`; and `close.browser.titan` proves
  that the browser's `lua_close` unwinds a retained suspended chain in an
  independently initialized child state.
* `spec/browser_trace_map_spec.lua`, `spec/coder/browser_trace_entries_spec.lua`,
  `spec/browser/trace-adapter.test.mjs`
  (`spec/fixtures/browser_trace_adapter/{stacks.json,degraded.mjs,lifecycle.c,filter.c}`),
  `spec/browser/build-trace.lua`, `spec/browser/trace.test.mjs`,
  `spec/browser/playwright-run.mjs` (`spec/fixtures/browser_trace/`), and
  `spec/coder/browser_fixtures_spec.lua`
  (`spec/fixtures/browser_runtime/{runtime_trace.titan,trace.c,trace.h}`):
  browser post-link source-map extensions and structural validation, browser
  `_init` entry-wrapper registration across all wrapper families with
  byte-identical native codegen, Node unit tests for the V8/SpiderMonkey/JSC
  stack parsers, `Error` descriptor preservation, lookup validation, and
  compiled `lifecycle.c`/`filter.c` C-merge boundaries, and the end-to-end
  browser trace gate (46 native cases in `trace_cases` plus the
  `trace_uncaught` and `trace_async` programs, staged as 98 positive and 8
  `degradedCases` manifest rows across `assertions-2` and `assertions-0`:
  direct and `.browser.titan` contributor locations, mixed Lua/Titan merge
  order, catchable `C stack overflow` past the browser C-call limit,
  pin/rethrow/clear, coroutine append across yield/resume, post-suspension
  traces in `async` Tasks and across entries, a failed async bootstrap `main`
  Task, degraded/capture-failed/truncated markers, held-storage nested
  capture, and merge `LUA_ERRMEM` guard recovery) across Node, Chromium,
  Firefox, and WebKit. `spec/coder/browser_images_spec.lua` also builds
  `titan.c` natively with `TITAN_NO_LIBBACKTRACE` and checks the fallback's
  capture depth, frame order, count, and 255-frame truncation against an
  independent capture; the libbacktrace specs above are unchanged.
* `spec/coder/stack_relocation_spec.lua`: stack relocation through protected
  recovery.
* `spec/abi_spec.lua`: runtime/compiler ABI constants.
