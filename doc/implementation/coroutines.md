# Coroutines

The `coroutine` standard module is split deliberately:

* `titan/coroutine.titan` owns the public API and policy: tag defaults, status
  strings, result-code checks, `resume` versus `error`, the
  success/error payload convention, Lua-thread/userdata setup, traceback
  handoff, and the transfer choreography around minicoro.
* `titan-runtime/titan_coro.c` owns only the pieces that still need C:
  compiling the single-file minicoro implementation, the Lua raw-equality
  tag comparator, and a tiny minicoro entry trampoline that calls the native
  Titan entry function stored in the owner userdata.
* `titan-runtime/minicoro.h` is a vendored copy of minicoro extended with
  tagged nested yield and a `MCO_STACKED` state.

The source compiles under the qualified Titan identity `titan.coroutine`.
Titan code uses `import "coroutine"`, which the parser desugars to that name;
Lua uses the ordinary `luaopen_titan_coroutine` entry through
`require "titan.coroutine"`. Both paths reach the one installed file at
`<root>/lib/titan/0.14/titan/coroutine.so`. There is no legacy `coro` alias,
parent-level or `lib/lua` copy, or bare `luaopen_coroutine` entry to collide
with Lua's standard coroutine library.

## Public Wrapper

`titan/coroutine.titan` imports minicoro's private struct layout plus
the Lua and private helper headers:

```lua
local mco = foreign import "minicoro.h"
local lua = foreign import "lua.h"
local lual = foreign import "lauxlib.h"
local ffi = foreign import "titan/ffi.h"
local coro_native = foreign import "titan/coro.h"
```

The exported `Coro` record has local fields:

```lua
record Coro
  local udata: value
  local handle: *mco.mco_coro
  local default_tag: value
end
```

That keeps the Lua-visible record opaque while allowing public methods to
keep the raw handle local to the module. `udata` roots the full userdata
that owns the minicoro allocation; the userdata payload is an
`mco_coro *` slot. That owner uses the private `"titan.coroutine"`
metatable whose `__gc` finalizer pushes its owner-userdata argument,
reads the payload through `lua_touserdata`, and passes the recovered
pointer to `mco_destroy`. `handle` caches the pointer with its native C
type, so normal operations use `self.handle` directly.

Because `minicoro.h` is imported directly, Titan can read the private
`mco_coro` fields it needs, such as `stacked_co`, without a C helper for
simple source selection. This is a private standard-library boundary:
the Titan type system cannot prevent a module that imports `minicoro.h`
directly from storing a stale pointer or violating the transfer order.
FFI calls that need the calling Lua state use Titan's built-in `L` local.

`titan/coroutine.titan` calls minicoro directly for storage and control
transfer: `mco_push`, `mco_pop`, `mco_resume`, `mco_yield`,
`mco_status`, `mco_is_yieldable`, and `mco_result_description`. It obtains
the current coroutine directly from the module-local `mco_runtime` object.
That object is allocated by the Titan module initializer and stored in a
GC-traced module slot, so the hot path does not perform a Lua-registry table
lookup. User payloads are transported separately:

1. `Coro:resume` reads its private, typed `mco_coro *` handle directly,
   selects the current transfer source (`co->stacked_co` when present,
   otherwise `co`), pushes `payload=arg` and `ok=true`, and calls
   `mco_resume` with the resolved tag.
2. `Coro:error` follows the same path but pushes `ok=false` and
   `payload=err`.
3. `coroutine.yield` reads `runtime.current_co`, pushes `payload=arg` and
   `ok=true`, and calls `mco_yield`.
4. The same helper that calls `mco_resume` selects the transfer source
   again immediately after control returns. Tagged nested yield can change
   it from the resumed coroutine to the deepest stacked coroutine.
5. The helper pops `ok` and `payload` separately before returning to its
   caller. For `resume`/`error`, `ok=false` means the source coroutine has
   already died; its entry point staged any coroutine-thread traceback and
   cleared its dead child-thread stack before returning control. The helper
   captures a resume/error-side propagation traceback, appends it to the
   staged trace, pins the combined trace, and re-raises `payload`. For
   `yield`, `ok=false` is an injected error at a live yield site, so the
   helper raises `payload` directly.

## TValue FFI Boundary

The C FFI imports Lua's by-value `TValue` as a distinct C type and has
coercions between Titan `value` and C `TValue`. It also lets Titan form
source-level C pointer types (`*T`, `const *T`), read `T.sizeof`, and
coerce C locals/formals to mutable pointer parameters. This is enough for
`titan/coroutine.titan` to call minicoro's storage and tag APIs directly:

```lua
local payload: ffi.TValue = nil
local ok: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
mco.mco_pop(source, ok, ffi.titan_ffi_int.sizeof)
mco.mco_pop(source, payload, ffi.TValue.sizeof)
```

When a C call mutates a stack-anchored `TValue` local through a mutable
pointer argument, the FFI lowering refreshes that local's Lua stack anchor
immediately after the call. Coroutine result helpers still keep the
control switch and the result pops in the same Titan function, so no
generated helper prologue can run a GC check while a final dead-coroutine
payload exists only in minicoro storage.

For resume/yield tags, `titan/coroutine.titan` materializes the
effective Titan `value` as a local C `TValue` and passes that local to
minicoro's `void *` tag parameter:

```lua
local ctag: ffi.TValue = tag
mco.mco_resume(co, ctag)
```

Minicoro treats that pointer opaquely and compares it before returning
from the control-transfer call.

The helper stores live values in ordinary Lua roots:

* `Coro.udata` roots the owner userdata whose raw payload stores the
  `mco_coro *`; `Coro.handle` is the same pointer cached as a native
  field and is not itself a GC root;
* the owner userdata's four uservalues root the child Lua thread, module
  state, native Titan entry closure, and callback function;
* when the entry point finishes, its child-thread frame roots the final
  return/error payload while it copies that payload into minicoro
  storage, stages any captured traceback for the caller-side append step,
  and clears the dead child stack before returning control;
* `mco_coro->user_data` points back to the owner userdata needed by
  `void (*func)(mco_coro *co)`; minicoro does not trace that raw pointer;
* in-flight arguments, yielded values, errors, tags, and handles remain
  rooted by the Titan formal parameters whose C stack frames are
  suspended by minicoro.

There is no registry pin for coroutine handles. A reachable coroutine is
kept alive by ordinary Lua reachability: the user's `Coro` record roots
the owner userdata through `udata`, the userdata roots the child thread
and callback through its uservalues, and nested `resume`/`yield` chains
keep their outer frames suspended instead of unwinding them.

If the suspended handler of a stacked tagged-yield chain becomes
unreachable, its finalizer calls `mco_destroy`. Minicoro then abandons the
skipped chain without running user code: it clears the handler's
`stacked_co`, marks the stacked inner coroutines dead, and unlinks their
raw `prev_co` pointers so their later finalizers can destroy them safely.
This is cleanup for unreachable coroutines, not cancellation for reachable
ones.

Transfer itself uses minicoro storage. `titan/coroutine.titan` pushes
the payload `TValue` and then the `ok` flag with `mco_push`; the receiver
pops `ok` first and the payload second with `mco_pop`. Minicoro copies
the struct bytes. It never owns a Lua root for the collectable object
referenced by the copied `TValue`; ordinary suspended transfers are
rooted by the owning Lua/Titan frame. Final callback return/error
payloads are rooted on the child stack while the entry copies them, then
are popped by the receiver immediately after the context switch returns,
before any intervening allocation.

## Entry Function

Each coroutine owner userdata holds four uservalues: the
`lua_newthread` thread, the owning module state, the native Titan entry
closure, and the callback value. Creation stores the userdata pointer in
`mco_coro->user_data` and installs a minicoro descriptor whose C entry is
`titan_coro_entry`.

The built-in `M` expression is a native `Udata *`. The coder recognizes that
specific Lua-internal pointer type as GC-bearing: converting a non-NULL
`Udata *` to `value` emits a full-userdata `TValue`, while NULL becomes nil.
Creation can therefore store `M` directly in owner slot 2 as the actual module
root. It does not need to recover an equivalent value from a closure upvalue.

The C trampoline recovers those four values from the owner userdata,
reads the native function pointer from the Titan entry closure, and calls
that native Titan entry directly with the child thread, module state,
callback value, and `mco_coro *`. It does not enter through the Lua-stack
wrapper on every resume and does not install a protected call of its own.
The trusted Titan entry calls the callback value using Titan's normal
function-value call path and contains failure with its trailing
function-level `catch`: exact Titan closures can take the native fast
path, while other Lua callables use the generic Lua-stack path.

On success, the entry records `ok=true`, copies the result `TValue` into
minicoro storage, clears the dead child stack, and returns control. On
error, the generated catch gives the Titan source both `error` and the
saved catch-local `traceback`. The entry stores that traceback under
`registry[TITAN_TRACE_APPEND_KEY]`, copies `(false, error)` into minicoro
storage, clears the dead child stack, and returns control.

When the Titan wrapper observes `ok=false` after `resume` or `error`, it
raises and catches the payload locally to capture a new traceback on the
propagation side. If a staged coroutine traceback is present, the wrapper
stores `coroutine_trace .. "\n" .. propagation_trace` under
`registry[TITAN_BACKTRACE_KEY]`, sets the one-shot trace pin, and re-raises
the same error payload. The pin tells the caller's error handler to keep
the combined trace. This preserves frames from the now-dead coroutine and
also records where the error crossed the `resume`/`error` boundary.

`Coro:error` before the first normal `resume` is handled without calling
the callback: the entry sees the preloaded `ok=false` transfer, returns
it as the final payload, and leaves the value rooted by the caller's
suspended `err` parameter until the transfer is consumed.

## FFI Experiment Notes

This implementation intentionally pushes the C FFI boundary: the Titan
module manipulates borrowed `mco_coro *` values, calls minicoro directly,
moves arbitrary Lua values as by-value `TValue`s, and owns the order of
`mco_push`/`mco_pop` operations. That raw pointer surface is deliberately
private to `titan/coroutine.titan`; it is not a safe general-purpose
coroutine FFI.
The pieces that remain in C are the ones that still require capabilities
outside the current FFI or a native callback ABI:

* exposing the trusted native Titan entry through minicoro's
  `void (*)(mco_coro *)` callback ABI;
* defining `MINICORO_IMPL` exactly once while forcing Titan's minicoro
  compile-time options;
* supplying the C tag comparator that compares arbitrary Lua values with
  `luaV_equalobj(NULL, ...)`.

Those are plausible future FFI extensions, but they should be designed as
general facilities rather than coroutine-specific escape hatches.

## Tagged Minicoro

The vendored minicoro extension adds:

```c
typedef int (*mco_tag_comparator)(void *t1, void *t2);

void mco_set_tag_comparator(mco_tag_comparator comparator);
mco_result mco_resume(mco_coro *co, void *tag);
mco_result mco_yield(mco_coro *co, void *tag);
int mco_is_yieldable(mco_coro *co, void *tag);
```

All resumes and yields are tagged. Generic minicoro builds retain the
implementation-level `mco_set_tag_comparator` setting. Titan instead compiles
its image with `MCO_TAG_COMPARATOR=titan_coro_tag_equal`, making the comparator
a fixed implementation constant rather than mutable global state or a
per-call argument. Minicoro stores tags as opaque `void *`; it knows nothing
about Lua. Titan passes pointers to in-flight `TValue`s, and the C comparator
compares them with:

```c
luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2)
```

Using `NULL` gives raw Lua equality: no `__eq` metamethods and no
`lua_State *` dependency in tag comparison.

Each `mco_coro` also points to an `mco_runtime`. That small context contains
the current-coroutine pointer and, under ASan, the main-stack fake-stack token,
bottom, and size used by the fiber-switch API. A generic minicoro descriptor
with no explicit runtime uses the implementation's thread-local default.
Sanitizer detection occurs before these public struct declarations. Ordinary
builds give `mco_runtime` only its current-coroutine pointer and omit all
sanitizer words from `mco_coro`; ASan adds its three main-stack fields and one
per-coroutine fake-stack field, while TSan adds only its two per-coroutine fiber
fields. Every translation unit sharing these layouts must therefore use the
same sanitizer configuration.
Minicoro exposes the complete runtime layout so the Titan module can allocate
one with its ordinary owned-C-object constructor:

```lua
local runtime = mco.mco_runtime.new()
```

The module initializer stores that userdata in a GC-traced local module slot.
Creation assigns `desc.runtime = runtime`, so all nested coroutines belonging
to that module instance share the same dynamic chain and ASan switch
bookkeeping; `yield` and `is_yieldable` read `runtime.current_co` directly.
There is no helper call or registry table access on those hot paths. The
runtime contains only raw execution bookkeeping; coroutine owners still
provide all GC reachability for the coroutines and their values. Titan imports
and Lua requires enter the same canonical DSO, which is the sole native owner,
while every Lua state gets its own module instance and runtime object.

When a coroutine yields to a non-immediate outer tag, the coroutine whose
`mco_resume` is returning becomes `MCO_SUSPENDED`. The coroutines between
that handler and the yielder become `MCO_STACKED`. The suspended handler
records the deepest stacked coroutine in `stacked_co`; the existing
`prev_co` links describe the rest of the chain. Resuming the suspended
handler reconstructs that chain and performs one context switch to the
deepest stacked coroutine. Directly resuming any stacked coroutine is
rejected with `MCO_NOT_SUSPENDED`.

Destroying the suspended handler while such a chain is still stacked
abandons the skipped chain instead of restoring it. The inner coroutines
are marked `MCO_DEAD` and their `prev_co` links are cleared, which avoids
leaving raw links into a finalized handler.

The dummy return address at the base of each assembly coroutine stack is
`NULL`, not a poison address. Titan's errorhandler uses libbacktrace; a
poison return address made the native unwinder chase invalid memory when
an error was raised on a minicoro stack.

Titan compiles minicoro with `MCO_USE_VMEM_ALLOCATOR` and creates
coroutine stacks with a 2 MiB stack size. This leaves room for Titan's
errorhandler, whose libbacktrace scratch state is larger than minicoro's
default 56 KiB stack, while keeping physical memory use lazy on platforms
with virtual memory.

The separate Binaryen `MCO_USE_ASYNCIFY` backend is not supported by
Titan's tagged coroutine semantics and is removed from the vendored
minicoro. Local Linux tests cover the ASM and UCONTEXT backends. The
Fiber backend is still present for Windows and Emscripten, but it is not
exercisable on a native Linux toolchain.
