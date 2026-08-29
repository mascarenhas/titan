# Coroutines

The `coroutine` standard module is split deliberately:

* `titan/coroutine.titan` owns the public API and policy: tag defaults, status
  strings, result-code checks, `resume` versus `error`, the
  success/error payload convention, Lua-thread/userdata setup, traceback
  handoff, and the transfer choreography around minicoro.
* `titan-runtime/minicoro.c` owns only the pieces that still need C:
  compiling the single-file minicoro implementation and the Lua raw-equality
  tag comparator. The exact `void (*)(mco_coro *)` entry is now the
  source-defined `foreign function coro_entry_trampoline` in
  `titan/coroutine.titan`. The Titan module also installs and clears
  pending-transfer roots through public Lua stack and uservalue APIs plus
  Titan's existing raw-`TValue` push bridge.
* `titan-runtime/minicoro.h` is a vendored copy of minicoro extended with
  tagged nested yield and a `MCO_STACKED` state.

The source compiles under the qualified Titan identity `titan.coroutine`.
Titan code uses `import "coroutine"`, which the parser desugars to that name;
Lua uses the ordinary `luaopen_titan_coroutine` entry through
`require "titan.coroutine"`. Titan prefix lookup claims that logical module
from `<root>/lib/titan/0.6/titan.so`; Lua finds the generated
`<root>/share/lua/5.5/titan/coroutine.lua` shim, promotes/maps the same provider
through `titan._loadlibglobal`, and invokes `luaopen_titan_coroutine`. The
module keeps its own state and initializer beside the other logical standard
modules in that image. There is no legacy `coro` alias, child DSO, parent-level
or `lib/lua` copy, or bare `luaopen_coroutine` entry to collide with Lua's
standard coroutine library.

Coroutine payloads use `value`, so an Array crossing `resume`, `yield`, or
`error` remains its canonical proxy Udata; the private backing Table never
leaks through the coroutine boundary. Exact typed Array paths elsewhere still
use backing `Table *`. This internal/boxed distinction is part of ABI 2; see
[Dense Arrays](dense-arrays.md#exact-and-generic-call-paths).

## Public Wrapper

`titan/coroutine.titan` imports minicoro's private struct layout plus
the Lua and private helper headers:

```lua
local mco = foreign import "minicoro.h"
local lua = foreign import "lua.h"
local lual = foreign import "lauxlib.h"
local ffi = foreign import "titan/ffi.h"
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

The module initializer constructs this private metatable off-registry, installs
`__gc`, and only then publishes it under `"titan.coroutine"`. If an allocating
initialization step raises, the registry therefore does not retain a partially
initialized canonical table. A pre-existing non-table entry is rejected
explicitly. This narrow metatable rule does not change the generated module
initializer's broader caching and transaction model.

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
   otherwise `co`), stores `payload=arg` in that source owner's fifth
   uservalue, pushes `payload=arg` and `ok=true`, and calls `mco_resume`
   with the resolved tag.
2. `Coro:error` follows the same path but pushes `ok=false` and
   `payload=err`.
3. `coroutine.yield` reads `runtime.current_co`, pushes `payload=arg` and
   `ok=true`, and calls `mco_yield`.
4. The same helper that calls `mco_resume` selects the transfer source
   again immediately after control returns. Tagged nested yield can change
   it from the resumed coroutine to the deepest stacked coroutine.
5. The helper pops `ok` and `payload` separately before returning to its
   caller. Generated FFI code refreshes the payload's Lua stack anchor
   immediately after the payload pop; only then does the helper clear the
   source owner's fifth uservalue. For `resume`/`error`, `ok=false` means the
   source coroutine has
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
local ok: int = 0 as int
mco.mco_pop(source, ok, int.sizeof)
mco.mco_pop(source, payload, ffi.TValue.sizeof)
```

When a C call mutates a stack-anchored `TValue` local through a mutable
pointer argument, the FFI lowering refreshes that local's Lua stack anchor
immediately after the call. A pending payload is also held in the exact
source owner's fifth uservalue from before the first `mco_push` until that
anchor refresh has happened. This is the root across the control switch,
dead-child stack clearing, and any GC check in the receiver's generated
prologue; same-function placement of the switch and pops is not itself a GC
guarantee.

For resume/yield tags, `titan/coroutine.titan` materializes the
effective Titan `value` as a local C `TValue` and passes that local to
minicoro's `void *` tag parameter:

```lua
local ctag: ffi.TValue = tag
mco.mco_resume(co, ctag)
```

Minicoro treats that pointer opaquely and compares it before returning
from the control-transfer call.

`root_transfer` implements the uservalue update in Titan. It first recovers
the exact owner userdata from `mco_get_user_data` and assigns that `Udata *`
to a local, which gives generated code a Lua-stack anchor for the owner. It
then saves `lua_gettop(L)`, requires two stack slots with
`lua_checkstack(L, 2)`, pushes the owner and payload with
`lua_pushtvalue`, and assigns owner uservalue 5 with
`lua_setiuservalue`. The public setter supplies Lua's backward GC barrier.
Both checked failures restore the saved top before raising, and the success
path restores the same top before returning. `clear_transfer` invokes that
same path with nil, so installing and clearing the root share the checked
ordering and stack-balance contract. There is no private C root/clear helper.

The helper stores live values in ordinary Lua roots:

* `Coro.udata` roots the owner userdata whose raw payload stores the
  `mco_coro *`; `Coro.handle` is the same pointer cached as a native
  field and is not itself a GC root;
* the owner userdata's first four uservalues root the child Lua thread,
  module state, native Titan entry closure, and callback function;
* its fifth uservalue roots the one pending payload copied through that
  coroutine's minicoro storage. The helper writes it before the payload push
  and clears it only after the payload has been removed and stack-anchored;
* when the entry point finishes, its child-thread frame roots the final
  return/error payload until `push_transfer` installs that fifth-userdata
  root. It may then stage any captured traceback and clear the dead child
  stack before returning control;
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
the payload `TValue` and then the `ok` flag with `mco_push`; it spells the
`value -> ffi.TValue` copy explicitly before the ordinary contextual
address-of conversion to minicoro's `const void *`. A raw `value` no longer
implicitly establishes any C pointer type. The receiver
pops `ok` first and the payload second with `mco_pop`. Minicoro copies
the struct bytes and never owns a Lua root for the collectable object
referenced by the copied `TValue`. The selected source owner's fifth
uservalue is therefore the protocol root for every pending transfer,
including a nested transfer whose exact source is `stacked_co`. It remains
set across the context switch and is cleared only after a successful payload
pop has refreshed the generated stack anchor. A nil payload is valid, so nil
in that slot is not used as an occupancy signal.

On a failed first push, the helper clears the root before raising the
minicoro error. On a failed flag push, it verifies that rolling back the
already-pushed payload succeeded and then clears the root. Failed resume or
yield discards and checks both stored values before clearing. If a pop or
rollback itself fails, the root remains installed because storage removal has
not been established.

## Entry Function

Each coroutine owner userdata holds five uservalues: the `lua_newthread`
thread, the owning module state, the native Titan entry closure, the callback
value, and the pending transfer root. Creation stores the userdata pointer in
`mco_coro->user_data` and assigns the source-defined
`coro_entry_trampoline` foreign function directly to the minicoro descriptor's
`void (*)(mco_coro *)` field.

The built-in `M` expression is a native `Udata *`. The coder recognizes that
specific Lua-internal pointer type as GC-bearing: converting a non-NULL
`Udata *` to `value` emits a full-userdata `TValue`, while NULL becomes nil.
Creation can therefore store `M` directly in owner slot 2 as the actual module
root. It does not need to recover an equivalent value from a closure upvalue.

The foreign trampoline recovers the first four values from the owner userdata
with the typed Lua-internal bridges in `titan/ffi.h`: the child thread, module
state, Titan entry closure, and callback value. It reads the native entry from
the closure's fixed native-pointer upvalue, casts it to the exact source alias

```titan
foreign (*ffi.lua_State, *ffi.Udata, *ffi.CClosure,
         ffi.TValue, *mco.mco_coro) -> ()
```

and calls it directly with `_fn = nil`. The trampoline is emitted as raw C: it
does not enter through a Lua-stack wrapper on every resume and does not install
a protected call of its own. The trusted Titan entry calls the callback value
using Titan's normal function-value call path and contains failure with its
trailing function-level `catch`: exact Titan closures can take the native fast
path, while other Lua callables use the generic Lua-stack path.

On success, the entry records `ok=true`, roots the result in owner slot 5,
copies the result `TValue` into minicoro storage, clears the dead child stack,
and returns control. On error, the generated catch gives the Titan source
both `error` and the saved catch-local `traceback`. The entry stores that
traceback under
`registry[TITAN_TRACE_APPEND_KEY]`, roots the error in owner slot 5, copies
`(false, error)` into minicoro storage, clears the dead child stack, and
returns control. The receiver clears slot 5 only after its successful pop has
anchored the value.

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
it as the final payload, and leaves the value in the owner's pending-transfer
root until the transfer is consumed.

## FFI Experiment Notes

This implementation intentionally pushes the C FFI boundary: the Titan
module manipulates borrowed `mco_coro *` values, calls minicoro directly,
moves arbitrary Lua values as by-value `TValue`s, and owns the order of
`mco_push`/`mco_pop` operations. That raw pointer surface is deliberately
private to `titan/coroutine.titan`; it is not a safe general-purpose
coroutine FFI.
The callback ABI itself no longer requires hand-written C:
`coro_entry_trampoline` uses the restricted
[`foreign function`](foreign-functions.md) body and an exact
`foreign (*mco.mco_coro) -> ()`-compatible signature. The two pieces that remain
in `minicoro.c` are the ones that genuinely require a single implementation
translation unit or a raw Lua-internal operation:

* defining `MINICORO_IMPL` exactly once while forcing Titan's minicoro
  compile-time options; and
* supplying the C tag comparator that compares arbitrary Lua values with
  `luaV_equalobj(NULL, ...)`.

The pending-transfer update likewise does not belong to that C surface:
`titan/coroutine.titan` uses public `lua_checkstack`, `lua_setiuservalue`, and
`lua_settop` directly, with Titan's existing `lua_pushtvalue` support bridge
for raw `TValue` pushes. The runtime header and archive therefore export neither
`titan_coro_root_transfer` nor `titan_coro_clear_transfer`.

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
its image with `MCO_TAG_COMPARATOR=minicoro_tag_equal`, making the comparator
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

Coroutine behavior tests use the canonical combined provider. Observable
Lua-host GC and API-error behavior runs from the module-owned native suite;
generated-C, transfer-rooting, and Lua-API implementation mechanics remain with
existing compiler/native harness coverage. The suite does not rebuild an exact
`coroutine.so` variant or source-rewrite the production implementation.

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
