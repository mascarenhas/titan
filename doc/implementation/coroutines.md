# Coroutines

The `coroutine` standard module is split deliberately:

* `titan/coroutine.titan` owns the public API and policy: tag defaults, current
  coroutine lookup, status strings, result-code checks, `resume` versus `error`,
  the success/error payload convention, Lua-thread setup, traceback handoff,
  and the transfer choreography around minicoro. The `Coroutine` record is the
  owner of each coroutine: its fields hold the Lua thread, the entry, the body
  and the pending-transfer root. The module also defines the exact
  `void (*)(mco_coro *)` entry as the source-defined
  [`foreign function`](foreign-functions.md) `coro_entry_trampoline`.
* `titan-runtime/minicoro.c` owns only what genuinely needs one C translation
  unit or a raw Lua-internal operation: it `#define`s `MCO_NO_DEBUG`,
  `MCO_USE_VMEM_ALLOCATOR` (natively), `MCO_TAG_COMPARATOR minicoro_tag_equal`,
  and `MINICORO_IMPL` before including the implementation, and supplies the tag
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
`require "titan.coroutine"`, which the Titan package searcher resolves to the
standard provider `titan.so` before calling `luaopen_titan_coroutine`. The module
keeps its own state and initializer beside the other logical standard modules
in that image, and has no bare `luaopen_coroutine` entry to collide with Lua's
coroutine library.

Coroutine payloads use `value`, so an Array crossing `resume`, `yield`, or
`error` is its canonical proxy Udata; the private backing Table never leaks
through the coroutine boundary
([Dense Arrays](dense-arrays.md#exact-and-generic-call-paths)).

## Public wrapper

`titan/coroutine.titan` imports minicoro's struct layout plus the Lua and
private helper headers, and `titan.gc` for the finalizer:

```titan
foreign import "minicoro.h"
foreign import "lua.h"
foreign import "titan.h"
foreign import "titan/ffi.h"
local gc = import "gc"
```

The exported `Coroutine` record has local fields:

```titan
record Coroutine
  local handle: foreign *mco_coro
  local default_tag: value
  local thread: value
  local entry: function (Coroutine)
  local body: function (value): (value)
  local pending: value
end
```

That keeps the Lua-visible record opaque while it owns everything a coroutine
needs. `handle` is the minicoro allocation; it is nil until `mco_create`
succeeds and again after the finalizer destroys it. `thread` is the
coroutine's Lua thread, `entry` is the module function `coro_entry`, `body` is
the caller's function, and `pending` roots the one pending transfer.
`mco_coro->user_data` points at the record's userdata, and `owner_of` turns
that pointer back into the record (a `*Udata` boxes as its userdata, and the
`as Coroutine` cast checks it), so no operation needs the Lua stack to find
its owner.

`create` registers `coro_gc` on the record with
`gc.finalizable<|value|>(co, coro_gc)` before it calls `mco_create`. A record
whose native stack was never created is finalized as a no-op, and no stack
can exist without a finalizer. `coro_gc` takes `value`, so the canonical
function is stored as it is and `create` allocates no adjustment closure. The
module creates no metatable of its own and writes nothing to the registry.

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
   source owner's `pending` field, pushes `payload=arg` and `ok=true`, and
   calls `mco_resume` with the resolved tag.
2. `Coroutine:error` follows the same path but pushes `ok=false` and
   `payload=err`.
3. `coroutine.yield` reads `runtime.current_co`, pushes `payload=arg` and
   `ok=true`, and calls `mco_yield`.
4. After control returns, the same helper selects the transfer source again,
   because tagged nested yield can change it from the resumed coroutine to the
   deepest stacked coroutine.
5. The helper (`pop_transfer`) pops `ok` and then `payload`. Generated FFI code
   refreshes the payload's Lua stack anchor immediately after the payload pop;
   only then does the helper clear the source owner's `pending` field. Its
   caller `pop_transfer_or_raise` raises for `ok=false`. For `resume`/`error`,
   `ok=false` means the source coroutine died; the caller performs the
   [traceback handoff](#entry-function) and re-raises `payload`. For `yield`,
   `ok=false` is an injected error at a live yield site, and the caller raises
   `payload` directly.

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
`pending` field from before the first `mco_push` until that anchor refresh.
This is the root across the control switch, dead-child stack clearing, and any
GC check in the receiver's generated prologue; same-function placement of the
switch and pops is not itself a GC guarantee.

For tags, the module materializes the effective `value` as a local C `TValue`
and passes its address to minicoro's `void *` tag parameter
(`local ctag: foreign TValue = tag; ffi.mco_resume(co, ctag)`). Minicoro treats
the pointer opaquely and compares it before the control-transfer call returns.

`root_transfer` is one field assignment: it recovers the source's record with
`owner_of` and stores the payload in `pending`, which supplies the write
barrier. It cannot fail and uses no Lua stack. `clear_transfer` calls it with
nil.

The live values are held in ordinary Lua roots:

* the `Coroutine` record's `thread`, `entry` and `body` fields root the child
  Lua thread, the native Titan entry closure and the callback function;
  `handle` is a raw pointer and not a GC root;
* `pending` roots the one pending payload copied through that coroutine's
  minicoro storage, written before the payload push and cleared only after the
  payload has been popped and stack-anchored;
* when the entry finishes, its child-thread frame roots the final
  return/error payload until `push_transfer` installs the `pending` root;
* an error that escapes the entry is delivered by the C floor, which leaves it
  in a slot of the child thread's own stack until the resumer has popped it
  (see [Unwinding an abandoned coroutine](#unwinding-an-abandoned-coroutine));
* `mco_coro->user_data` points back to the record's userdata needed by
  `void (*func)(mco_coro *co)`; minicoro does not trace that raw pointer;
* in-flight arguments, yielded values, errors, tags, and handles stay rooted by
  the callers of the Titan functions whose C stack frames minicoro suspends
  ([calls](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)).

There is no registry pin for coroutine handles. A reachable coroutine stays
alive through ordinary reachability: the record roots the child thread and the
callback. Nested `resume`/`yield` chains keep their outer frames suspended
instead of unwinding them.

### Reachability of a stacked chain

The caller of `Coroutine:resume`, `Coroutine:error` or `Coroutine:transfer`
keeps the receiver reachable until the call returns, wherever it read the
receiver from
([calls](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)).
A receiver read from a mutable field or captured local therefore stays alive
when other code clears that home while the resumer is suspended in a stacked
chain, and the stacked member's Lua thread is not freed under its suspended
frames. The methods keep no root of their own.

So the handler's thread roots the frame that resumed the next member. That
frame roots the next member, and so on down the chain, including through a
resume made on a Lua coroutine thread, because that thread is itself rooted by
its resumer's frame. A stacked member is therefore unreachable only when its
handler's owner is unreachable too.

An unreachable suspended coroutine is unwound by its finalizer, as described
under [Unwinding an abandoned coroutine](#unwinding-an-abandoned-coroutine).
This is cleanup for unreachable coroutines, not cancellation for reachable ones.

### Transfer storage

Transfer uses minicoro storage. `push_transfer` pushes the payload `TValue` and
then the `ok` flag with `mco_push`, spelling the `value -> TValue` copy
explicitly before the contextual address-of conversion to `const void *`. The
receiver pops `ok` first and the payload second. Minicoro copies the struct
bytes and never owns a Lua root for the referenced object, so the selected
source owner's `pending` field is the protocol root for every pending
transfer, including a nested transfer whose source is `stacked_co`. A nil
payload is valid, so nil in that field is not an occupancy signal.

Failure handling: on a failed first push the helper clears the root before
raising the minicoro error. On a failed flag push it verifies that rolling back
the already-pushed payload succeeded and then clears the root. A failed resume
or yield discards and checks both stored values (`discard_transfer`) before
clearing. If a pop or rollback itself fails, the root stays installed because
storage removal has not been established.

## Entry function

`create` makes the Lua thread with `titan_newthread`, which leaves it on the
stack, and builds the record with that thread, `coro_entry`, the callback and
a nil transfer root; the stack transaction that anchors the new thread is the
module's only one. It registers the finalizer, stores the record's userdata in
the descriptor's `user_data` (`co as foreign *void`), assigns
`coro_entry_trampoline` to the descriptor's `func` field, and stores the
pointer that `mco_create` returns in `handle`.

`coro_entry_trampoline` follows the libuv trampolines. It recovers the owner
from `mco_get_user_data`, reads the `thread` and `entry` fields with
`ffi.titan_record_field`, takes the module userdata and the native entry from
the entry closure's upvalues, casts the entry to the exact source alias

```text
foreign function (*lua_State, *Udata, *CClosure, *Udata): void
```

and hands all of it to `titan_coroutine_enter`, which calls the entry with the
owner and a nil `CClosure *`. The trampoline is raw C: it does not enter
through a Lua-stack wrapper on each resume and installs no protected call.
The owner needs no root there: the resumer's caller holds the record, or its
finalizer does. The trusted Titan entry, `coro_entry(owner: Coroutine)`, calls
`owner.body` through the normal function-value call path and contains failure
with its function-level `catch`.

On success, the entry pushes `ok=true` and the result (rooted in the owner's
`pending` field), clears the dead child stack, and returns control. On error,
it stages the catch-local `traceback` in the module variable
`pending_append_trace` (`stash_trace_for_append`) and pushes `(false, error)`
the same way. The receiver clears `pending` only after its successful pop
has anchored the value.

When the wrapper observes `ok=false` after `resume` or `error`,
`raise_with_appended_trace` raises and catches the payload locally to capture
the propagation-side trace, combines it with the staged coroutine trace, and
raises the same payload again with the combined trace
(`raise <exp>, <trace>`; see [Error handling](error-handling.md#trace-pinning)).

The public `Coroutine:transfer(payload, tag, inject_error)` runs the same
finalizer check, tag resolution, receiver root, and
`push_transfer`/`resume_switch`/`pop_transfer` sequence as `resume` and
`error`. It differs only after the pop. On `ok=false` it calls
`pop_trace_for_append`, which takes the staged trace out of
`pending_append_trace`, and then returns `(true, payload, trace)`
instead of raising. On `ok=true` it returns `(false, payload, nil)` without
reading the staged trace, capturing a trace, or allocating. Every `ok=false` that
reaches a resumer comes from `coro_entry`'s catch, which always stages a trace
first, so a returned outcome never leaves a stale trace behind. Errors raised
before or during the switch (tag, state, finalizer, minicoro, stack) propagate
as ordinary raises. The staging and raising helpers stay private to
`titan/coroutine.titan`.

`titan.async` (`titan/async/`) imports `coroutine` through its ordinary public interface
and uses `transfer` to drive Task roots; the report policy that decides whether
to append a driver trace is described in
[Task status](libuv-runtime.md#explicit-suspend-task-status-listeners-and-combinators).

`Coroutine:error` before the first `resume` is handled without calling the
callback: the entry sees the preloaded `ok=false` transfer, returns it as the
final payload, and leaves the value in the owner's pending-transfer root until
the transfer is consumed.

## Current coroutine lookup

`running(): Coroutine?` observes the module-local `runtime.current_co`.
Minicoro updates that pointer during resume, tagged yield, stack restoration,
and entry completion, so no separate registry or module variable is needed.
The current coroutine's user data is its `Coroutine` record, so `running`
boxes that `*Udata` and returns it `as Coroutine?`: Lua and Titan callers
observe the same record identity, and nothing is allocated or pushed. A null
pointer means no Titan coroutine is executing; `mco_get_user_data(NULL)`
returns null, which boxes as nil.

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
* `create` passes `ffi.TITAN_COROUTINE_STACK_SIZE` to `mco_desc_init`, with
  `MCO_USE_VMEM_ALLOCATOR` natively. `titan.h` defines that macro as
  `(2 * 1024 * 1024)` (2 MiB) unless the target already defines it; the
  [browser target](browser-target.md#compile-prefix-and-target-defines)
  defines it as 262144 (256 KiB) in its compile prefix. Natively, 2 MiB leaves
  room for the error handler, whose libbacktrace scratch state exceeds
  minicoro's default 56 KiB stack, while physical memory stays lazy on
  platforms with virtual memory. On WebAssembly, `minicoro.c` does not define
  `MCO_USE_VMEM_ALLOCATOR`, and `minicoro.h` ignores it under `__wasm__`, so
  coroutine stacks come from `calloc`/`free`, committing each stack eagerly and
  returning freed blocks for reuse when the coroutine is destroyed, while the
  grown WebAssembly linear memory never shrinks back to the host, and the
  browser has no libbacktrace, so the smaller size bounds memory per coroutine
  instead. minicoro's own default and minimum stack sizes are not redefined.
* The native ASM, UCONTEXT and Windows Fiber backends are unchanged. The
  WebAssembly (`__wasm__`) branch uses JSPI engine continuations and disjoint
  linear C stacks, not an instrumented stack-copying backend. Each context saves SP
  and stack-limit metadata, one parked gate, one engine-entry lifetime and a
  BACK identity. A dead coroutine's promised engine invocation retires before
  its resumer can free the allocation. Titan's abandoned-coroutine floor and
  transfer-root protocol remain the owners of actual cleanup; dropping a
  promise does not run defers. See [JSPI coroutine
  contexts](browser-target.md#jspi-coroutine-contexts).

## Unwinding an abandoned coroutine

`coro_gc` (`titan/coroutine.titan`) is the finalizer of the `Coroutine`
record. A record without a handle has nothing to destroy: its native stack
was never created, or an earlier finalization destroyed it and the record was
resurrected. A dead coroutine, or one that never started, is destroyed at
once. A started coroutine
whose status is `MCO_SUSPENDED` or `MCO_STACKED` is first **unwound**, as if an
error that nothing can catch were raised where it stopped. "Started" means the
coroutine's Lua thread still has an error-recovery boundary, because the floor
below stays linked while the entry runs.

**Driving a chain.** The handler is the coroutine itself when it is
`SUSPENDED`. Otherwise it is the first `prev_co` ancestor that is `SUSPENDED`.
`coro_gc` pushes the transfer `(nil, TRANSFER_UNWIND)` onto
`transfer_source(handler)` and resumes the handler with a nil tag.

Minicoro switches into the deepest stacked coroutine. Its
`pop_transfer` sees flag 2 and calls `titan_unwind(L)`. Each coroutine
then:

1. runs its finallies, innermost first;
2. reaches its floor, which pushes `(nil, 2)` and returns, so `_mco_main` marks
   it `MCO_DEAD` and jumps out to its resumer;
3. leaves its resumer's `pop_transfer` to pop that flag and unwind its own
   stack in turn.

When the handler finishes, `coro_gc` discards the handler's final transfer,
destroys the finalized coroutine, and sets `Coroutine.handle` to nil. A
resurrected handle then reports `"dead"`, and `resume` raises
`Invalid coroutine`.

`coro_gc` leaves a coroutine mapped, which leaks it, in three cases: when it is
still `RUNNING` or `NORMAL` because the state is closed from inside a
coroutine; when pushing the request raises, for example on allocation failure,
in which case the error leaves `coro_gc` and GCTM reports it as
`error in __gc (...)`; and when the request could not be delivered because the
resume failed. That is safer than freeing live frames.

**Floor.** The restricted trampoline calls `titan_coroutine_enter`
(`titan-runtime/minicoro.c`), a narrow C shim. It links a
`titan_unwind_floor` (`titan-runtime/titan.h`) as the first boundary of the
coroutine's thread. The floor has status `TITAN_STATUS_FLOOR` and records the
real bounds of the minicoro stack. Then the shim calls the generated entry
with the owner record. The shim never reads the record, so it depends on no
record layout.

The landing first unlinks the floor and every abandoned boundary above it
(`T->errorJmp = floor.lj.previous`), so a close method that raises or closes
its own thread cannot follow a dangling chain. It then restores the saved
`nCcalls`, `ci`, `allowhook` and `errfunc`, because the jump removed every
native frame above the floor; cleanup must not inherit their C-call count.

- On an unwind landing, the floor closes the thread's remaining Lua
  to-be-closed variables and pushes `(nil, 2)`.
- Any other landing comes from `luaD_throwbaselevel` or from a real error.
  Lua code on the thread can close it with `coroutine.close()` and no argument
  (`luaB_close` with `COS_RUN`): `lua_closethread` closes every to-be-closed
  variable, and `luaD_throwbaselevel` jumps straight to the floor with the
  close status, skipping the Titan finallies and any unwind guard in between.
  The status is `LUA_OK`, or the last close error.
- If the coroutine is being unwound, the unwind dominates every such status:
  an error status is reported once as a cleanup warning
  (`titan_unwind_report`) and dropped, and the floor takes the unwind branch
  and pushes `(nil, 2)`, so the resumer keeps unwinding and can neither return
  nor catch an error. The mode cannot come from a guard, which the jump
  bypasses: before every landing, `titan_unwind` follows the landing
  boundary's chain to its bottom and, when that is a floor, sets
  `titan_unwind_floor.unwinding` (`titan_unwind_mark_floor`). The flag lives in
  the floor record on the coroutine's own stack, is set again at each landing,
  and is `volatile` because it is read after the `longjmp`. A genuine Lua
  coroutine has no floor: if cleanup that runs on such a thread during a
  crossing closes that thread, `luaD_throwbaselevel` returns through its
  `lua_resume` to the Lua resumer's ordinary code, which Titan cannot
  intercept, so the language manual forbids it.
- Otherwise, on `LUA_OK` (an ordinary self-close) the floor pushes `(nil, 1)`,
  so the coroutine ends dead and its resumer receives nil, as for a Lua
  coroutine that closes itself.
- On any other status outside an unwind, a self-close's close error or a real
  error that escaped `coro_entry`'s catch is delivered. The floor
  closes the frames with that error and delivers it to the resumer as
  `(error, 0)`. `luaD_seterrorobj` puts the error in a slot of the coroutine's
  own thread, and the floor leaves the thread's top above that slot: the
  thread's stack roots the error until the resumer has popped it, because the
  owner record keeps the thread reachable, and the dead thread never runs
  again. The two nil transfers need no root. It runs that close with itself
  re-armed as
  `TITAN_STATUS_FLOOR`, like a finally boundary's
  [error-recovery close](error-handling.md#unwinding-through-finally): if a
  `__close` suspends the coroutine and it is then abandoned, the unwind lands
  on the floor again, the error is dropped, and the coroutine ends unwound.
  That landing also clears the dropped error's registry trace and pin through
  the cold `titan_unwind_clear_trace`, which runs the clears protected because
  `luaS_new` can allocate.

**Walker.** `titan_unwind` (`titan-runtime/titan.c`) follows `L->errorJmp`.
When it finds a boundary whose status is `TITAN_STATUS_FINALLY` or
`TITAN_STATUS_FLOOR`, it sets `TITAN_STATUS_UNWIND` and `longjmp`s there. It
skips everything else: catch-only Titan boundaries, Lua `pcall`/`load`, and
`lua_resume`. Lua writes a boundary's status only in `luaD_throw`, right before
jumping, so the marker is never overwritten while the boundary is live. The
generated landing is described under
[unwinding through finally](error-handling.md#unwinding-through-finally).

A generated module initializer is an ordinary frame for the walker: its
`defer`s land like any other, and a Lua `require` between it and the caller is
only unprotected C frames (`ll_require` uses `lua_call`). `<prefix>_init`
publishes the module under `"Titan module <modname>"` before it runs the
initializer ([the module protocol](codegen-overview.md#the-module-protocol)),
so a module abandoned there stays partially initialized, as after an
initializer error: a later `require` takes the registry hit and returns it.

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
missing floor, or a missing resumer aborts with a diagnostic.

That can only happen when C code breaks the **structured-entry invariant**:
threads of one state enter one another only through `lua_resume` (Lua's
`coroutine.resume` and `coroutine.wrap`, or C) or through protected calls on
their own `lua_State`. C code that re-enters an active ancestor's `lua_State`
with `lua_call` or `lua_pcall`, or runs another thread's code without a resume
boundary, is outside the contract, like other unsafe FFI misuse. Independent
`lua.Lua` states and other OS threads never share a chain.

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
After every failure, and on return, the loop and the reporter restore
`L->errfunc` as `luaD_pcall` does: a failed `__close` may have jumped over a
Titan Lua-entry wrapper that had installed its own message handler in a stack
slot that the next close method reuses.

### Finalizer context

`titan_in_finalizer` (`titan/ffi.h`) tests `G(L)->gcstp & GCSTPGC`. GCTM sets
that bit while it runs a `__gc`, during ordinary collections and during
`lua_close`. The browser bridge sets it as well, around its synchronous
[wrapper-release entry](browser-bridge.md#the-collector-stop), to keep the
collector out. That entry runs none of the program's code and reaches none of
the checks below. Inside a finalizer, including every cleanup an unwind runs:

- `coroutine.yield` raises `cannot yield from a finalizer`;
- `Coroutine:resume` and `Coroutine:error` raise
  `cannot resume a coroutine from a finalizer`;
- `is_yieldable(tag)` returns false.

These checks hold during the unwind too. `coro_gc` itself resumes with
`ffi.mco_resume` directly.

GCTM sets `GCSTPGC` for the whole finalizer, so an unwind takes no ordinary
collector step, and every `lua_gc` request fails: `gc.collect` raises
([direct collector control](gc-library.md#direct-collector-control)) and Lua's
`collectgarbage` returns fail (`nil`). Emergency collections stay enabled:
`GCScallfin` clears `gcstopem` before it calls finalizers, so an allocation
failure during an unwind can run an emergency full collection. Such a cycle
runs no finalizer and shrinks no stack. Under ordinary collection, GCTM runs at
an allocation point of whatever code is running, so an unwind can start inside
unrelated code and must not assume any program state. That is the general Lua
finalizer contract, which cleanup inherits.

Async tests `titan_in_finalizer` in `settle` and `fatal`: settlement from a
finalizer queues delivery instead of resuming the waiting Task (see
[completion waits](libuv-runtime.md#driver-and-registration-trampoline)).
`titan_state_closing` (`G(L)->gcstp & GCSTPCLS`) marks the state-close case:
`run_with_cleanup` gives its cleanup the abandonment reason only then,
`async.run` and `run_with_cleanup` refuse to start a Task, and `new_runtime`
refuses to create a Runtime; see
[Lua-state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime).

### Synchronous callbacks

`titan_no_switch` (`titan/ffi.h`) is true while a browser synchronous C
callback runs: the bridge's callback depth is nonzero
([synchronous C callbacks](browser-bridge.md)). Natively it is the constant 0,
so these checks fold away. Each check is an inline `if` whose branch alone
builds the error, so no helper call or string work remains natively. Inside a
callback:

- `Coroutine:resume`, `Coroutine:error`, `Coroutine:transfer` and
  `coroutine.yield` raise `"coroutine.<operation> is unavailable in a
  synchronous callback"`. The checks come after the finalizer checks and
  before any state changes, so the coroutine stays as it was.
- `running()` returns nil and `is_yieldable(tag)` returns false, which hides
  the coroutine whose binding the callback interrupted.
- `coro_gc` does not unwind a started suspended or stacked coroutine. It
  registers itself on the record again with `gc.finalizable` and returns.
  That call sets the record's metatable again, and setting a metatable inside
  `__gc` marks the object for finalization once more, because
  `udata2finalize` clears `FINALIZEDBIT` and `luaC_checkfinalizer` moves the
  object back to `finobj`. The next collection outside a callback calls
  `coro_gc` again, and it unwinds then. During `lua_close`, `GCSTPCLS` makes
  `luaC_checkfinalizer` ignore a re-arm, so the state close runs a re-armed
  finalizer once and ends. Finalizers run in reverse marking order, so it runs
  before `titan.browser`'s state-record finalizer. Dead and never-started
  coroutines are destroyed at once, as before; `mco_destroy` does not switch
  for them.

`gc.tests` checks the re-arm under the incremental and the generational
collector. `lua.tests` checks that a closed independent state runs a re-armed
finalizer exactly once. The browser scheduler gate (`async.browser_tests`,
`callback_test.browser.titan`) runs callbacks through `browser.call_sync`:
the refused switches and the masking, inside a coroutine as well, and a
coroutine collected inside a callback whose defers run in order at the next
collection.

## Tests

Coroutine behavior tests run against the canonical combined standard provider.
Observable Lua-host GC and API-error behavior is in the module-owned native
suite; generated-C, transfer-rooting, and Lua-API mechanics stay with the
compiler and native harness specs.

Unwinding has three layers:

- The `coroutine.tests` folder module in `spec/stdlib/titan/coroutine/tests/`
  holds the native `test_unwind_*` cases in three contributors.
  `unwind_common.titan` holds the cases shared by every target; they collect
  with `gc.collect()`. `unwind_test.native.titan` holds the host cases that
  need a child Lua state, `titan.async`, or `titan.string`: Lua interleaving
  and crossing cases run their Lua code in a child `lua.Lua` state, once with
  collections and once with `state:close()`. The log and the child's Lua
  warnings go to host-owned buffers through `coroutine.test_support`, and a
  Lua `__gc` observer created before the abandoned coroutine records thread
  statuses after the unwind. The fixture module
  `coroutine.unwind_init_fixture` suspends its initializer when a child state
  requires it inside a coroutine, which covers an initializer abandoned inside
  `require`. `close.browser.titan` is the browser's child-closure proof: a
  test-owned C probe (`browser_close.h`, with
  `spec/fixtures/browser_runtime/close.c`) initializes an independent state
  from the parent's production preload descriptors, retains a suspended
  nested pair there, and checks that the state's `lua_close` runs each defer
  exactly once and no abandoned `catch` or continuation body.
  `spec/coder/browser_fixtures_spec.lua` builds the module, with `gc.tests`,
  for the browser. The three Lua-host cases (`test_lua_host_*` and
  `test_running_lua_host_preserves_identity`) live in the native contributor
  `lua_boundary_test.native.titan`, so the browser selection (the common
  contributors plus `close.browser.titan`) runs in the browser core stdlib
  suite ([browser test owners](browser-target.md#test-owners-and-the-browser-suite))
  on Node and Chromium.
- `spec/coder/error_handling_spec.lua` ("unwind boundaries") checks that a
  finally boundary is initialized with `TITAN_STATUS_FINALLY` and that a
  catch-only try emits no unwind code. `spec/coder/unwind_stdlib_spec.lua`
  unwinds a try that has both a catch and a finally; it needs the installed
  `titan.coroutine`, so it is listed in
  `spec/support/ci_stdlib_compiler_test_files.txt`.
- `spec/minicoro_spec.lua` drives `titan_coroutine_enter` from a C entry: an
  escaped error, an unwind, and an unwind of a coroutine suspended in the
  floor's error-recovery close. Titan code reaches the escaped-error branch
  only when an error is raised inside `coro_entry`'s own catch, for example on
  allocation failure while pushing the error transfer, so the C harness owns
  it. The `LUA_OK` branch is reached from Lua and has the native case
  `test_unwind_floor_ends_self_closed_coroutine`.

Async, thread and transfer consequences are covered by `test_lua_close_*` and
`test_unwind_*` cases in their own owners.
