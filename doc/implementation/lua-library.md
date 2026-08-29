# Lua-loading library implementation

The user-facing contract is in the
[Lua loading standard-library chapter](../language/standard-library-lua.md).
`titan.lua` is a flat Titan module built against the pinned Lua 5.5 API. It
uses `titan.fs` for cooperative file access, `titan.io` for the Reader
interface, and binary-safe search/slicing helpers from `titan.string`. It
adds no compiler intrinsic or native runtime shim.

## Compiling and rooting a chunk

`load` is a small audited Lua-stack transaction:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 2)` | Reserve the loaded function/error and a possible environment slot before compilation. |
| `luaL_loadbufferx` | Consume no caller-owned stack values and push either one compiled function or one error object. The explicit Titan string length keeps the operation binary-safe. It may allocate or longjmp. |
| `ffi.lua_pushtvalue(env)` | For a nonnil environment, push and root that exact value beside the compiled function. |
| `lua_setupvalue(L, -2, 1)` | On success, pop the environment and install it as the function's first upvalue with Lua's barrier. If no first upvalue exists it returns null and leaves the environment for explicit removal. |
| `ffi.lua_totvalue` | Copy the compiled function into Titan's traced `value` representation before cleanup. |
| deferred `lua_settop` | Restore the entry height on success or any caught load/setup error. |

The load status is checked before the stack error is copied and raised. The
function value remains rooted first by the temporary stack slot and then by the
traced local returned as the flexible callable type. No pointer into the input
string or Lua stack survives an allocating operation.

Omitting `env` adjusts it to nil. That branch deliberately does not touch the
first upvalue, leaving Lua's global environment in place. A nonnil value follows
Lua's first-upvalue rule rather than assuming a table or inspecting the
upvalue's debug name.

## Reader and File ownership

`load_from_reader` uses `Reader:read` directly as a generic-for iterator and
passes every yielded chunk, including `""`, to a synchronous
`string.StringWriter`, the same checked accumulator used by the string
library's formatting, packing, and substitution paths. `Reader:read` owns the
scheduling boundary. Each writer call checks aggregate growth; nonempty inputs
are retained as traced Titan strings, while empty inputs add no storage.
`drain` performs one exact-size allocation and copy after the Reader reports
nil. The result is passed to `load`, with no borrowed Reader buffer or C
pointer retained.

The Reader is borrowed and is never closed. In contrast, `dofile` owns the
`fs.File` it opens and immediately installs a deferred close. That one cleanup
path covers asynchronous read errors, `luaL_loadbufferx` failures, returns, and
errors from the resulting flexible call. The chunk call directly spreads the
incoming flexible tail and returns its flexible results.

## Asynchronous `require`

The module reproduces Lua's require state machine without calling the stock
blocking source searcher:

```text
truthy registry cache
        | miss
        v
same-name loading guard
        |
        v
searcher 1 ---> async package.path pass ---> searchers 3..first nil
        |                 |                         |
        +---------- selected loader + loader data --+
                                  |
                                  v
                  loader result / package.loaded / true
```

In a standalone executable, searcher 1 initially sees only the main loader that
the entrypoint installed. The bootstrap require of that module performs the
existing transitive `_init` recursion before `main`. After each generated
module finishes `_init` successfully, it publishes its own `luaopen_*` function
in `registry[LUA_PRELOAD_TABLE]`, which `package.preload` aliases. Searcher 1
therefore sees every initialized import—including private static imports—by the
time `main` runs. An unused or otherwise uninitialized linked module remains
absent. A later asynchronous require invokes the published loader, recovers the
canonical module value, and then follows the same registry cache rules shown
above without initializing the module again.

The cache is fetched from
`LUA_REGISTRYINDEX[LUA_LOADED_TABLE]`, just as Lua's own `require` does; a
reassigned public `package.loaded` field does not redirect it. `package`,
`package.searchers`, and `package.path` are read for each uncached load and
validated at their dynamic boundary.

The source pass maps dots to slashes, substitutes every literal `?` in each
semicolon-separated path template, and attempts `fs.open`. A filesystem open
error is a candidate miss. Cancellation and non-filesystem errors retain their
own types and propagate. After a candidate has opened, a read or load error is
wrapped with the module and filename and is terminal. A deferred close owns the
opened candidate on every path. Cancellation uses the nominal
`async.CancellationReason` union rather than an exception-wrapper record: even
if the post-open context wrapper transforms the injected union value, the
Task's stored cancellation request remains authoritative and terminalizes it
as `cancelled` with the original reason rather than reporting a load failure.

Literal module-name and `?` substitutions, Reader chunk loading, ordered
source-miss diagnostics, and the final cross-searcher diagnostic accumulation
all use synchronous `string.StringWriter` instances. This removes local
chunk-array joins and incremental concatenation while retaining binary strings
and encounter order. Actual Reader and File operations remain the cooperative
boundaries; pure substitution and diagnostic assembly do not create extra
scheduler turns. The module-level loading guard spans every real I/O yield, so
cancellation still clears it through `defer` and a concurrent same-name
request cannot publish a duplicate load.

Slot 2 is structurally reserved instead of identified by closure identity.
This avoids comparing, capturing, or wrapping Lua's private built-in searcher:
slot 1 and slots 3 onward are the mutable callable policy, while source lookup
always occupies the asynchronous middle pass. Built-in C searchers and custom
searchers are called through the ordinary typed function-value path. That path
uses the generated non-yieldable Lua-call boundary, so it is safe with respect
to Titan native frames but deliberately cannot suspend. Returned loaders use
the same boundary.

Lua source loaders receive their filename as loader data. Preload and C
searchers retain the loader data they produce. A function-valued first result
selects a loader; a string-valued first result contributes a diagnostic; other
results are ignored. Search stops at the first nil searcher slot, matching
Lua's array traversal.

The module-level `{string: boolean}` loading Map is set before any yielding
search and cleared by `defer`. It is not a promise table: a same-name recursive
or concurrent request raises immediately. This keeps cache publication exactly
once without introducing scheduler ownership or waiter cancellation into a
module loader. Different names have independent entries.

After the loader returns, a nonnil result replaces
`package.loaded[modname]`. The table is then reread so a nil-returning loader
can publish its own value; only a still-nil entry becomes true. False remains
false and therefore triggers a fresh load on the next call.

## Raw stack and GC audit

Three small helpers isolate the other raw operations:

* `global_value` saves/restores the stack, pushes one global with
  `lua_getglobal`, and copies it to a traced `value`;
* `registry_map` pushes the registry field, checks that it is a table, and
  transfers it to a traced typed Map before cleanup;
* `is_lua_function` pushes a traced candidate and uses `lua_type` without
  retaining the temporary slot.

Each helper calls `lua_checkstack` before its first push and uses one deferred
`lua_settop` as the authoritative cleanup. Global lookup can run `__index`
on the global table and allocate or raise; the deferred restoration and traced
copy cover those paths. Registry lookup does not invoke a metamethod for the
registry table's ordinary raw layout in the supported Lua state, but is
nevertheless treated as an allocating/error-capable API boundary.

The source/path builder holds only traced Titan strings and integers. Loader,
loader-data, package, searcher, and cache values likewise remain in traced
locals across filesystem yields and Lua calls. There are no borrowed raw
pointers and no stack index is retained across an operation that can reallocate
the stack.

The focused behavior suite is the native `lua.tests` owner under
`spec/stdlib/titan/lua/`, outside LuaCov. It exercises text and binary chunks,
embedded zero handling, Reader ownership, repeated File-error descriptor
accounting, cache states, asynchronous source loads, duplicate-load rejection,
preload/C/Titan/custom loaders, and diagnostics. Its cancellation case reads an
unbounded source candidate, cancels the waiting Task, checks the terminal
cancelled status, and then retries the same module name from a finite source to
prove deferred guard cleanup. Narrow Lua-host access (for example `/dev/fd`
enumeration) is obtained through a test-only Lua C-API helper without moving
ordinary behavior back into a Busted suite.
