# Trusted Lua C API boundary

The stack-oriented Lua C API is not a user-facing FFI feature. Importing `lua.h`
yields ordinary C declarations, but the compiler attaches no stack-effect,
rooting, or `longjmp` knowledge to them, so such an import is not a safe
binding. Titan's standard library is the one trusted exception: module-private
code calls a reviewed set of raw operations under the discipline in this
chapter. That exception is an implementation technique, not public API.

The inventory of trusted sites is the code: every `ffi.lua_*` and `ffi.luaL_*`
call under `titan/`. Such calls appear in `titan/{async,coroutine,gc,iteration,reflect,test,transfer}.titan`,
`titan/browser.browser.titan`, `titan/http/parser.native.titan`, `titan/lua/{lua,worker}.titan`,
`titan/peg/native.titan`, `titan/protobuf/protobuf.titan`,
`titan/string/{string,format}.titan`, `titan/thread/{spawn,thread}.titan`, and
several `titan/uv/*.titan` files. Module-specific ledgers live with their
module:

- `titan.gc`: [weak-mode](gc-library.md#weak-mode-stack-ledger) and
  [finalizer](gc-library.md#finalizer-stack-ledger) ledgers.
- `titan.lua`: [independent-state ownership](lua-library.md#independent-state-ownership),
  [protected execution and stack cleanup](lua-library.md#protected-execution-and-stack-cleanup),
  and [worker ownership](lua-library.md#worker-ownership-and-cancellation).
- `titan.transfer`: [consuming raw-slot decode](transfer-library.md#consuming-raw-slot-decode)
  and [closure snapshots](transfer-library.md#closure-snapshots), including the
  source foreign functions `transfer_project` and `transfer_restore` and the
  public `transfer_load_module`.
- `titan.peg`: [LPegLabel embedding](lpeglabel-embedding.md) (`titan_lpeglabel_open`).

## Why the raw API is not a public FFI feature

Generated C already manipulates `TValue`, `Udata`, stack slots, barriers, and
`lua_State` internals directly. The public Lua C API is stack-oriented and
`longjmp`-based. Exposing it through ordinary foreign calls would require the
compiler to know which calls move `L->top.p`, allocate, raise, relocate the
stack, run user code, or need a protected-call boundary. A public binding
would have to settle:

- what API-specific metadata attaches to the builtin `lua_State *L` beyond its
  raw C pointer type;
- whether API calls are ordinary foreign calls or a separate binding layer with
  stack-effect metadata, and how pre- and postconditions are expressed for
  operations that push a variable number of results;
- how GC-able Titan values stay anchored across calls that allocate or raise;
- how `lua_CFunction` values relate to callbacks: a restricted source
  `foreign function` can be pushed with `lua_pushcclosure`, but an ordinary
  Titan closure cannot become a `lua_CFunction`;
- whether every call that can raise must sit behind the error machinery used by
  generated Lua entry points.

A plain header import cannot answer these. A future public surface would need
a compiler-provided binding with per-function stack, allocation, error, and
anchoring metadata enforced by code generation.

Calling an operation that is already a Lua callable needs none of this. A
`value` given a Titan function type is invoked through the generic Lua-stack
call path, which uses `luaD_callnoyield` and accepts Lua closures, C functions,
and `__call` objects (`titan-compiler/coder/calls.lua` `codevaluecall`; see
[calling function values](codegen-overview.md#calling-function-values-codevaluecall)).

## Trusted standard-library discipline

A raw operation is the last resort, not the default. Before adding one, or
any authored runtime C, justify it against the six
[rules for standard-library and runtime C](standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do):
layering, plain C off the Lua stack, protected work in Titan, pinning in module
variables or owner fields, rooting by parameters and frame slots, and
receiver-side checks of tagged values. Every trusted site then
follows these rules:

- Current-state helpers use only the generated function's builtin `L`; they
  never keep it past the current call, return it, or substitute it. A per-call
  owner may carry it to a synchronous native callback that runs before the call
  returns, as the HTTP parser's `callback_state` does. Restricted foreign
  callbacks recover their state explicitly: from such an owner, from their
  owning loop, or as an exclusively owned state. An independent `titan.lua`
  state is owned by `lua.Lua`, never substituted for `L`, and never given
  access to the hosting state's objects or callbacks.
- Snapshot `lua_gettop(L)` before the first push and restore that exact height
  with `lua_settop(L, saved)` on every exit. Put the restore in `defer` whenever
  anything between snapshot and restore can raise. Never balance an exceptional
  path with a guessed series of pops.
- Reserve the maximum temporary stack effect with `lua_checkstack` (or
  `luaL_checkstack` in foreign bodies, which cannot `raise`) before the first
  push, and keep an explicit stack-effect ledger for every path, including
  optional lookup results and zero-result cases.
- A pushed slot is a GC root only while it is below `L->top.p`. A C local
  holding a raw address is never a root. Copy any collectable result that must
  outlive restoration into a traced Titan `value` or another traced owner
  (`ffi.lua_totvalue`) before restoring the top. Push a Titan value only for an
  operation that consumes stack slots, never merely to root a parameter or
  local; their caller and frame slot already do (rule 5).
- Never retain a pointer into a Lua string, userdata, or stack slot across an
  allocation, callback, protected call, metamethod, or anything else that can
  move the stack or run Lua. Keep the traced owner plus an offset and derive the
  pointer again afterwards.
- Call user functions and metamethods only through a non-yieldable path. A
  yield attempt is an ordinary Lua error at this boundary.
- Handle ordinary Titan errors with native `do ... catch` and `defer`. Errors
  from typed Lua callables go through the generated generic-call boundary, not a
  manual `pcall`. A C callback that must run Titan reaches a Titan handler
  through the callback trampoline (rules 1 and 3), and no manual protected call
  wraps a C function that Lua never sees (rule 2). The only manual `lua_pcallk` sites are
  `titan/lua/worker.titan` `lua_state_open` and `lua_state_run` (independent
  state open and execution) and `titan/thread/spawn.titan`
  `thread_worker_main` (thread bootstrap). Each uses a nil continuation and has
  an explicit result ledger and owned cleanup. Restricted foreign bodies have no
  Titan `catch`/`defer` or implicit `L`, and a remote state's error must never
  unwind into the host's jump chain.
- Adding a raw operation requires documenting its stack, allocation, error,
  callback, and borrowed-pointer behavior at the use site and in the ledger
  below. The exception must not grow into an untyped public Lua C API surface.

Current-state C byte-buffer copies use `pointer as string(length)` (or the
existing NUL-terminated `pointer as string`), not a stack transaction. Keep
`lua_pushlstring` only when the bytes are an actual Lua stack argument, key,
or result, including work in an explicitly owned independent state. See
[counted pointer-to-string conversion](c-ffi-expressions.md#counted-pointer-to-string-conversion).

## Operation ledger

The operations used by trusted sites, with their stack effect and obligations.
"Push" means the new slot is a temporary root until the saved top is restored.
`titan/ffi.h` supplies the Titan-specific bridges (`lua_totvalue`,
`lua_pushtvalue`, `lua_pushconstlightuserdata`, `lua_togco`, `titan_newthread`,
and the preload helpers).

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop`, `lua_settop(L, saved)` | Snapshot and authoritative restore of the entry height. |
| `lua_checkstack`, `luaL_checkstack` | Net zero. Reserve the complete maximum temporary effect before the first push. `lua_checkstack` returns 0 on failure and the Titan caller raises; `luaL_checkstack` raises itself. |
| `ffi.lua_pushtvalue` | Push an existing traced Titan value (Map, key, string, closure, and so on); the boundary never manufactures a placeholder. |
| `ffi.lua_totvalue` | Net zero. Copy a slot into Titan's traced `value` representation before cleanup. |
| `lua_pushnil`, `lua_pushboolean`, `lua_pushinteger`, `lua_pushnumber`, `lua_pushlightuserdata`, `ffi.lua_pushconstlightuserdata` | Push one scalar or borrowed native address. Cross-state arguments use lightuserdata, never a GC reference from another state. |
| `lua_pushstring`, `lua_pushlstring`, `lua_concat` | Push one string copied from C bytes (an explicit range for `lstring`) or concatenated from string slots. May allocate and raise. |
| `lua_pushvalue`, `lua_copy`, `lua_absindex`, `lua_pushthread` | Stack shuffles. `lua_pushvalue` and `lua_pushthread` push one; `lua_copy` and `lua_absindex` are net zero. |
| `lua_pushcclosure` | Push one C function. Trusted sites push only restricted source foreign functions with zero upvalues, never an adapted Titan closure. |
| `lua_getglobal`, `lua_getfield` | Push one value. May invoke `__index`, allocate, run user code, or raise. |
| `lua_setfield` | Pop one value. May invoke `__newindex`, allocate, or raise. |
| `lua_rawget`, `lua_rawgeti`, `lua_rawgetp` | Replace the key (`rawget`) or push one value; no metamethods. |
| `lua_rawset` | Pop key and value; no metamethods; applies Lua's write barrier. |
| `lua_rawequal` | Net zero; primitive equality without `__eq`. |
| `lua_next` | Pop the key; on success push the next key and value, on exhaustion push nothing. Raises for an invalid key. Copy surviving results to traced locals before restoring. |
| `lua_getmetatable` | Push the metatable when present, otherwise push nothing; no `__metatable` lookup. |
| `lua_setmetatable` | Pop and install a metatable. Installing a metatable with `__gc` marks the object for finalization. |
| `luaL_testudata` | Net zero; returns NULL when the slot is not userdata with the named registry metatable. |
| `lua_getupvalue`, `lua_setupvalue` | `getupvalue` pushes one value when the upvalue exists, otherwise nothing. `setupvalue` pops and installs (with barrier) when the upvalue exists, otherwise returns NULL and pops nothing, so the caller removes the unused value. |
| `lua_type`, `lua_typename`, `lua_isinteger`, `lua_toboolean`, `lua_tointegerx`, `lua_tonumberx`, `lua_tothread`, `lua_touserdata`, `lua_tocfunction`, `lua_topointer`, `ffi.lua_togco` | Net zero. Check the kind before extracting. Pointer results are borrowed and do not root their source; a `lua_topointer` result is identity-only. |
| `lua_tolstring` | Net zero for a string slot; returns borrowed bytes valid while the slot stays rooted. Converting a number allocates and must be protected. |
| `luaL_tolstring` | Push one string, transiently using two more slots above the converted value (the metatable and event name for `luaL_getmetafield`, or the callable and argument for `luaL_callmeta`). A caller that also pushes the value therefore reserves three slots. May run `__tostring`, allocate, or raise; copy the result to a traced value before restoring. |
| `luaL_loadbufferx`, `luaL_loadstring` | Push one compiled function or one error object. Uses the explicit length for `loadbufferx`. May allocate or raise. |
| `lua_pcallk` | Pop function and arguments; push the requested results or one error. Only the sites listed in the discipline section. |
| `lua_callk` | Pop function and arguments; push results. Only inside an already protected callback, or for the preload loader in `transfer_load_module`; a nil continuation forbids yielding through C. Errors reach the owning state's enclosing protected boundary. |
| `lua_error`, `luaL_error` | Raise into the enclosing protected call of the owning state. Never let this `longjmp` cross a worker entry or reach the hosting state's frames. |
| `luaL_newstate`, `lua_close`, `luaL_openselectedlibs`, `ffi.titan_newthread` | Create or destroy a state, open libraries inside a protected callback, or push a new coroutine thread with a reserved stack. See [`titan.lua`](lua-library.md#independent-state-ownership) and [coroutines](coroutines.md). |
| `lua_getinfo` | With `">"` pops the function; fills the debug record. `titan.reflect` only. |
| `lua_gc` | Net zero; returns a C `int`. `titan.gc` turns the unavailable result `-1` into an error. Do not call from a finalizer. |
| `titan_module_preload_symbols`, `titan_module_preload` | Net zero on success; each reserves four slots internally and may allocate or raise. Never invoke a loader or initialize a module. See [independent-state ownership](lua-library.md#independent-state-ownership). |
