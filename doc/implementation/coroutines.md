# Coroutines

The `coroutine` standard module is split deliberately:

* `titan/coroutine.titan` owns the public API and policy: tag defaults, current
  coroutine lookup, status strings, result-code checks, `resume` versus `error`,
  the success/error payload convention, Lua-thread/userdata setup, traceback
  handoff, and the transfer choreography around minicoro. It also defines the
  exact `void (*)(mco_coro *)` entry as the source-defined
  [`foreign function`](foreign-functions.md) `coro_entry_trampoline`, and
  installs and clears pending-transfer roots through public Lua stack and
  uservalue APIs plus the `lua_pushtvalue` bridge.
* `titan-runtime/minicoro.c` owns only what genuinely needs one C translation
  unit or a raw Lua-internal operation: it `#define`s `MCO_NO_DEBUG`,
  `MCO_USE_VMEM_ALLOCATOR`, `MCO_TAG_COMPARATOR minicoro_tag_equal`, and
  `MINICORO_IMPL` before including the implementation, and supplies the tag
  comparator `minicoro_tag_equal`.
* `titan-runtime/minicoro.h` is a vendored copy of minicoro extended with
  tagged nested yield and a `MCO_STACKED` state.

The Titan module deliberately pushes the C FFI boundary: it manipulates
borrowed `mco_coro *` values, calls minicoro directly, moves arbitrary Lua
values as by-value `TValue`s, and owns the order of `mco_push`/`mco_pop`
operations. That raw pointer surface is private to `titan/coroutine.titan`; it
is not a safe general-purpose coroutine FFI, and the type system cannot stop
another module that imports `minicoro.h` from storing a stale pointer or
violating the transfer order.

The source compiles under the qualified identity `titan.coroutine`. Titan code
uses `import "coroutine"`, which the parser desugars to that name; Lua uses
`require "titan.coroutine"`, whose generated shim maps the standard provider
through `titan._loadlibglobal` and calls `luaopen_titan_coroutine`. The module
keeps its own state and initializer beside the other logical standard modules
in that image, and has no bare `luaopen_coroutine` entry to collide with Lua's
coroutine library.

Coroutine payloads use `value`, so an Array crossing `resume`, `yield`, or
`error` is its canonical proxy Udata; the private backing Table never leaks
through the coroutine boundary
([Dense Arrays](dense-arrays.md#exact-and-generic-call-paths)).

## Public wrapper

`titan/coroutine.titan` imports minicoro's struct layout plus the Lua and
private helper headers:

```titan
foreign import "minicoro.h"
foreign import "lua.h"
foreign import "lauxlib.h"
foreign import "titan/ffi.h"
```

The exported `Coroutine` record has local fields:

```titan
record Coroutine
  local udata: value
  local handle: foreign *mco_coro
  local default_tag: value
end
```

That keeps the Lua-visible record opaque while letting the module keep the raw
handle. `udata` roots the full userdata that owns the minicoro allocation; its
payload is an `mco_coro *` slot. The owner uses the private `"titan.coroutine"`
metatable whose `__gc` finalizer (`coro_gc`) reads the payload through
`lua_touserdata` and passes the pointer to `mco_destroy`. `handle` caches the
pointer with its native C type, so normal operations use `self.handle`
directly.

The module initializer builds that metatable off-registry, installs `__gc`, and
only then publishes it under `"titan.coroutine"`, so an allocation failure
during initialization never leaves a partially initialized canonical table in
the registry. A pre-existing non-table entry is rejected.

Because `minicoro.h` is imported directly, Titan reads the `mco_coro` fields it
needs, such as `stacked_co`, without a C helper. FFI calls that need the calling
Lua state use Titan's built-in `L`.

The module calls minicoro directly for storage and control transfer:
`mco_push`, `mco_pop`, `mco_resume`, `mco_yield`, `mco_status`,
`mco_is_yieldable`, and `mco_result_description`. It obtains the current
coroutine from the module-local `mco_runtime` object (see
[Tagged minicoro](#tagged-minicoro)). User payloads are transported as follows:

1. `Coroutine:resume` selects the current transfer source (`co->stacked_co`
   when present, otherwise `co`; `transfer_source`), roots `payload=arg` in that
   source owner's fifth uservalue, pushes `payload=arg` and `ok=true`, and calls
   `mco_resume` with the resolved tag.
2. `Coroutine:error` follows the same path but pushes `ok=false` and
   `payload=err`.
3. `coroutine.yield` reads `runtime.current_co`, pushes `payload=arg` and
   `ok=true`, and calls `mco_yield`.
4. After control returns, the same helper selects the transfer source again,
   because tagged nested yield can change it from the resumed coroutine to the
   deepest stacked coroutine.
5. The helper (`pop_transfer_or_raise`) pops `ok` and then `payload`. Generated
   FFI code refreshes the payload's Lua stack anchor immediately after the
   payload pop; only then does the helper clear the source owner's fifth
   uservalue. For `resume`/`error`, `ok=false` means the source coroutine died;
   the helper performs the [traceback handoff](#entry-function) and re-raises
   `payload`. For `yield`, `ok=false` is an injected error at a live yield
   site, and the helper raises `payload` directly.

## TValue FFI boundary

The C FFI imports Lua's by-value `TValue` as a distinct C type, converts
between Titan `value` and `TValue`, and supports source-level pointer types,
`T.sizeof`, and contextual address-of conversion to pointer parameters. That is
enough to call minicoro's storage and tag APIs directly:

```titan
local payload: foreign TValue = nil
local ok: foreign int = 0 as foreign int
ffi.mco_pop(source, ok, foreign int.sizeof)
ffi.mco_pop(source, payload, foreign TValue.sizeof)
```

When a C call mutates a stack-anchored `TValue` local through a mutable pointer
argument, the FFI lowering refreshes that local's Lua stack anchor immediately
after the call. A pending payload is also held in the exact source owner's
fifth uservalue from before the first `mco_push` until that anchor refresh. This
is the root across the control switch, dead-child stack clearing, and any GC
check in the receiver's generated prologue; same-function placement of the
switch and pops is not itself a GC guarantee.

For tags, the module materializes the effective `value` as a local C `TValue`
and passes its address to minicoro's `void *` tag parameter
(`local ctag: foreign TValue = tag; ffi.mco_resume(co, ctag)`). Minicoro treats
the pointer opaquely and compares it before the control-transfer call returns.

`root_transfer` implements the uservalue update in Titan. It recovers the exact
owner userdata from `mco_get_user_data` into a `*Udata` local, saves
`lua_gettop(L)` and restores it with `defer`, requires two stack slots with
`lua_checkstack`, pushes the owner and payload with `lua_pushtvalue`, and sets
owner uservalue 5 with `lua_setiuservalue`, which supplies Lua's backward GC
barrier. `clear_transfer` calls it with nil, so installing and clearing share
the checked ordering and stack-balance contract.

The live values are held in ordinary Lua roots:

* `Coroutine.udata` roots the owner userdata whose payload stores the
  `mco_coro *`; `Coroutine.handle` is the same pointer and is not a GC root;
* owner uservalues 1–4 root the child Lua thread, module state, native Titan
  entry closure, and callback function;
* uservalue 5 roots the one pending payload copied through that coroutine's
  minicoro storage, written before the payload push and cleared only after the
  payload has been popped and stack-anchored;
* uservalue 6 roots the public `Coroutine` record so `running()` can recover
  that exact handle. The record and owner form an ordinary traced cycle;
* when the entry finishes, its child-thread frame roots the final
  return/error payload until `push_transfer` installs the uservalue-5 root;
* `mco_coro->user_data` points back to the owner userdata needed by
  `void (*func)(mco_coro *co)`; minicoro does not trace that raw pointer;
* in-flight arguments, yielded values, errors, tags, and handles stay rooted by
  the Titan formal parameters whose C stack frames minicoro suspends.

There is no registry pin for coroutine handles. A reachable coroutine stays
alive through ordinary reachability. The `Coroutine` record roots the owner, and
the owner roots the child thread and callback. Nested `resume`/`yield` chains
keep their outer frames suspended instead of unwinding them.

### Reachability of a stacked chain

`Coroutine:resume` and `Coroutine:error` copy `self` into a GC-typed local
(`resumed`) before the switch and clear it afterwards. That local occupies a
reserved slot of the resuming frame. `self` itself is an unanchored native
formal ([values and GC](values-and-gc.md#2-home-roots-shadow-slots-and-borrowed-c-copies)).
Without the local, a receiver read from a mutable field or captured local
could be cleared by other code while the resumer is suspended in a stacked
chain, and the stacked member's Lua thread would then be freed under its
suspended frames.

With the local, the handler's thread roots its resume frame. That frame roots
the next member, and so on down the chain, including through a resume made on
a Lua coroutine thread, because that thread is itself rooted by its resumer's
frame. A stacked member is therefore unreachable only when its handler's owner
is unreachable too.

An unreachable suspended coroutine is unwound by its finalizer, as described
under [Unwinding an abandoned coroutine](#unwinding-an-abandoned-coroutine).
This is cleanup for unreachable coroutines, not cancellation for reachable ones.

### Transfer storage

Transfer uses minicoro storage. `push_transfer` pushes the payload `TValue` and
then the `ok` flag with `mco_push`, spelling the `value -> TValue` copy
explicitly before the contextual address-of conversion to `const void *`. The
receiver pops `ok` first and the payload second. Minicoro copies the struct
bytes and never owns a Lua root for the referenced object, so the selected
source owner's fifth uservalue is the protocol root for every pending transfer,
including a nested transfer whose source is `stacked_co`. A nil payload is
valid, so nil in that slot is not an occupancy signal.

Failure handling: on a failed first push the helper clears the root before
raising the minicoro error. On a failed flag push it verifies that rolling back
the already-pushed payload succeeded and then clears the root. A failed resume
or yield discards and checks both stored values (`discard_transfer`) before
clearing. If a pop or rollback itself fails, the root stays installed because
storage removal has not been established.

## Entry function

Each owner userdata holds six uservalues, selected by the
`TITAN_CORO_*_USERVALUE` constants: the `lua_newthread` thread, the owning
module state, the native Titan entry closure, the callback value, the pending
transfer root, and the public `Coroutine` record. `create` stores the owner
pointer in `mco_coro->user_data` and assigns `coro_entry_trampoline` directly to
the descriptor's `func` field. The module slot holds `M as foreign *Udata`, the
actual module userdata, so no closure-upvalue lookup is needed to recover it.

`coro_entry_trampoline` recovers the first four values from the owner with the
typed Lua-internal bridges in `titan/ffi.h` (zero-based `uv[]` indices), reads
the native entry from the entry closure's native-pointer upvalue, casts it to
the exact source alias

```text
foreign function (*lua_State, *Udata, *CClosure, TValue, *mco_coro): void
```

and calls it directly with a nil `CClosure *`. The trampoline is raw C: it
does not enter through a Lua-stack wrapper on each resume and installs no
protected call. The trusted Titan entry, `coro_entry`, calls the callback
through the normal function-value call path and contains failure with its
function-level `catch`.

On success, the entry pushes `ok=true` and the result (rooted in uservalue 5),
clears the dead child stack, and returns control. On error, it stages the
catch-local `traceback` under `registry[TITAN_TRACE_APPEND_KEY]`
(`stash_trace_for_append`) and pushes `(false, error)` the same way. The
receiver clears uservalue 5 only after its successful pop has anchored the
value.

When the wrapper observes `ok=false` after `resume` or `error`,
`raise_with_appended_trace` raises and catches the payload locally to capture
the propagation-side trace, combines it with the staged coroutine trace, pins
it, and re-raises the same payload. The registry protocol is canonical in
[Error handling](error-handling.md#trace-pinning).

`Coroutine:error` before the first `resume` is handled without calling the
callback: the entry sees the preloaded `ok=false` transfer, returns it as the
final payload, and leaves the value in the owner's pending-transfer root until
the transfer is consumed.

## Current coroutine lookup

`running(): Coroutine?` observes the module-local `runtime.current_co`.
Minicoro updates that pointer during resume, tagged yield, stack restoration,
and entry completion, so no separate registry or module variable is needed. A
null pointer means no Titan coroutine is executing; `mco_get_user_data(NULL)`
returns null and the result is nil.

`create` stores the new `Coroutine` record in the owner's sixth uservalue with
`lua_setiuservalue`, which supplies the GC write barrier. It reserves two
temporary stack slots and restores the saved entry top with `defer`; an
absolute owner index stays valid across record allocation and stack
relocation. `running` recovers the owner with `mco_get_user_data`, pushes it,
reads the sixth uservalue with `lua_getiuservalue`, and copies the result into a
traced return value before restoring the saved top. It neither allocates a
replacement record nor returns the private owner userdata, so Lua and Titan
callers observe the same record identity.

## Tagged minicoro

The vendored minicoro extension adds:

```c
typedef int (*mco_tag_comparator)(void *t1, void *t2);

void mco_set_tag_comparator(mco_tag_comparator comparator);
mco_result mco_resume(mco_coro *co, void *tag);
mco_result mco_yield(mco_coro *co, void *tag);
int mco_is_yieldable(mco_coro *co, void *tag);
```

All resumes and yields are tagged. Generic minicoro builds keep the runtime
`mco_set_tag_comparator` setting; Titan's `minicoro.c` defines
`MCO_TAG_COMPARATOR`, making the comparator a fixed implementation constant
rather than mutable global state. Minicoro stores tags as opaque `void *`.
Titan passes pointers to in-flight `TValue`s, and `minicoro_tag_equal` compares
them with `luaV_equalobj(NULL, t1, t2)`. The `NULL` state gives raw Lua
equality: no `__eq` metamethods and no `lua_State *` dependency.

Each `mco_coro` points to an `mco_runtime`, which holds the current-coroutine
pointer and, under ASan, the main-stack fake-stack token, bottom, and size used
by the fiber-switch API. A descriptor with no explicit runtime uses the
implementation's thread-local default. Sanitizer detection happens before these
struct declarations: ordinary builds have no sanitizer words, ASan adds three
main-stack fields to `mco_runtime` and one fake-stack field to `mco_coro`, and
TSan adds two per-coroutine fiber fields. Every translation unit sharing these
layouts must use the same sanitizer configuration.

The module allocates one runtime with its ordinary owned-C-object constructor
(`local runtime = foreign mco_runtime.new()`) and keeps it in a GC-traced module
slot. `create` assigns `desc.runtime = runtime`, so all coroutines of that
module instance share the same dynamic chain and ASan switch bookkeeping, and
`yield` and `is_yieldable` read `runtime.current_co` without a helper call or
registry access. The runtime holds only raw execution bookkeeping; coroutine
owners provide all GC reachability. Every Lua state gets its own module
instance and runtime object.

When a coroutine yields to a non-immediate outer tag, the coroutine whose
`mco_resume` is returning becomes `MCO_SUSPENDED`, and the coroutines between
that handler and the yielder become `MCO_STACKED`. The suspended handler
records the deepest stacked coroutine in `stacked_co`; the `prev_co` links
describe the rest of the chain. Resuming the suspended handler reconstructs that
chain and performs one context switch to the deepest stacked coroutine.
Directly resuming a stacked coroutine is rejected with `MCO_NOT_SUSPENDED`.
Destroying the suspended handler while a chain is stacked abandons it as
described above.

### Stacks and backends

* The dummy return address at the high end of each assembly coroutine stack
  (`stack_high_ptr[0]` in `minicoro.h`) is `NULL`, not a poison address. The
  error handler uses libbacktrace, and a poison return address made the native
  unwinder chase invalid memory when an error was raised on a minicoro stack.
* `create` uses `STACK_SIZE` (2 MiB) in `titan/coroutine.titan`, with
  `MCO_USE_VMEM_ALLOCATOR`. This leaves room for the error handler, whose
  libbacktrace scratch state exceeds minicoro's default 56 KiB stack, while
  physical memory stays lazy on platforms with virtual memory.
* The Binaryen `MCO_USE_ASYNCIFY` backend cannot express Titan's tagged
  semantics and is removed from the vendored copy. Local Linux tests cover the
  ASM and UCONTEXT backends; the Fiber backend remains for Windows and
  Emscripten but cannot be exercised on a native Linux toolchain.

## Unwinding an abandoned coroutine

`coro_gc` (`titan/coroutine.titan`) is the coroutine owner's `__gc`. A dead
coroutine, or one that never started, is destroyed at once. A started coroutine
whose status is `MCO_SUSPENDED` or `MCO_STACKED` is first **unwound**, as if an
error that nothing can catch were raised where it stopped. "Started" means the
coroutine's Lua thread still has an error-recovery boundary, because the floor
below stays linked while the entry runs.

**Driving a chain.** The handler is the coroutine itself when it is
`SUSPENDED`. Otherwise it is the first `prev_co` ancestor that is `SUSPENDED`.
`coro_gc` pushes the transfer `(nil, TRANSFER_UNWIND)` onto
`transfer_source(handler)` and resumes the handler with a nil tag.

Minicoro switches into the deepest stacked coroutine. Its
`pop_transfer_or_raise` sees flag 2 and calls `titan_unwind(L)`. Each coroutine
then:

1. runs its finallies, innermost first;
2. reaches its floor, which pushes `(nil, 2)` and returns, so `_mco_main` marks
   it `MCO_DEAD` and jumps out to its resumer;
3. leaves its resumer's `resume_result_or_raise` to pop that flag and unwind
   its own stack in turn.

When the handler finishes, `coro_gc` discards the handler's final transfer,
destroys the finalized coroutine, and clears both the payload slot and
`Coroutine.handle` (owner uservalue 6). A resurrected handle then reports
`"dead"`, and `resume` raises `Invalid coroutine`.

`coro_gc` leaves a coroutine mapped, which leaks it, in two cases: when it is
still `RUNNING` or `NORMAL` because the state is closed from inside a
coroutine, and when the request could not be delivered. That is safer than
freeing live frames.

**Floor.** The restricted trampoline calls `titan_coroutine_enter`
(`titan-runtime/minicoro.c`), a narrow C shim. It links a
`titan_unwind_floor` (`titan-runtime/titan.h`) as the first boundary of the
coroutine's thread. The floor has status `TITAN_STATUS_FLOOR` and records the
real bounds of the minicoro stack. Then the shim calls the generated entry.

- On an unwind landing, the floor closes the thread's remaining Lua
  to-be-closed variables and pushes `(nil, 2)`.
- On any other status, a real error escaped `coro_entry`'s catch. The floor
  closes the frames with that error and delivers it to the resumer as
  `(error, 0)`.

**Walker.** `titan_unwind` (`titan-runtime/titan.c`) follows `L->errorJmp`.
When it finds a boundary whose status is `TITAN_STATUS_FINALLY` or
`TITAN_STATUS_FLOOR`, it sets `TITAN_STATUS_UNWIND` and `longjmp`s there. It
skips everything else: catch-only Titan boundaries, Lua `pcall`/`load`, and
`lua_resume`. Lua writes a boundary's status only in `luaD_throw`, right before
jumping, so the marker is never overwritten while the boundary is live. The
generated landing is described under
[unwinding through finally](error-handling.md#unwinding-through-finally).

**Crossings.** A thread whose chain holds no landing point is a genuine Lua
coroutine resumed on this stack. `titan_unwind_cross` handles it in four steps:

1. Select the floor whose recorded range contains the real-stack key of the
   thread's outermost boundary. It scans `G(L)->allgc`, which also links the
   main thread.
2. Choose the resumer: the thread whose head has the nearest key above that
   position, inside the floor's range.
3. Close the exhausted thread as dead. This mirrors `resetCI`, closes every
   remaining `<close>` variable, empties the stack, and resets `nCcalls`.
4. Continue walking the resumer's chain.

Each crossing repeats this, so any chain of nested `lua_resume` calls unwinds
innermost first.

Keys are `uintptr_t` addresses, never compared C pointers. Under ASan they are
normalized with `__asan_addr_is_in_fake_stack`, because GCC can place frames
that call `setjmp` on the use-after-return fake stack. A missing boundary, a
missing floor, or a missing resumer aborts with a diagnostic. That can only
happen when C code breaks the structured-entry invariant, for example by
re-entering an active ancestor's `lua_State` without `lua_resume`.

The crossing assumes downward-growing stacks with contiguous, disjoint
coroutine mappings. The supported builds select minicoro's ASM backend, or
UCONTEXT on request. With `MCO_USE_FIBERS`, the recorded bounds come from
minicoro's reverse-engineered Fiber layout and from the requested stack size.
That backend is not validated.

**Errors.** Every unwind close site uses `titan_unwind_close`:

- landings;
- the floor;
- crossings;
- the guard of a finally body.

It is `luaD_closeprotected`'s loop, with the status kept at `LUA_OK` and each
error reported before the retry: one Lua warning,
`error in coroutine cleanup (<msg>)`, and the error is then dropped.
`L->top` drops to the close level only after the loop succeeds, so the open
upvalues and pending `<close>` slots of a failed handler stay below the top.

### Finalizer context

`titan_in_finalizer` (`titan/ffi.h`) tests `G(L)->gcstp & GCSTPGC`. That bit is
set exactly while GCTM runs a `__gc`, during ordinary collections and during
`lua_close`. Inside a finalizer, including every cleanup an unwind runs:

- `coroutine.yield` raises `cannot yield from a finalizer`;
- `Coroutine:resume` and `Coroutine:error` raise
  `cannot resume a coroutine from a finalizer`;
- `is_yieldable` returns false.

`coro_gc` itself resumes with `ffi.mco_resume` directly.

Async uses the same test in `run_with_cleanup`. Task code runs in a finalizer
only while it is unwound at Lua-state close; see
[Lua-state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime).

## Tests

Coroutine behavior tests run against the canonical combined standard provider.
Observable Lua-host GC and API-error behavior is in the module-owned native
suite; generated-C, transfer-rooting, and Lua-API mechanics stay with the
compiler and native harness specs.
