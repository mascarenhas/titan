# Coroutines

The `coro` standard module is split deliberately:

* `coro.titan` owns the public API and policy: tag defaults, status
  strings, result-code checks, `resume` versus `error`, the
  success/error payload convention, and the transfer choreography around
  minicoro.
* `titan-runtime/titan_coro.c` owns unsafe runtime primitives: Lua thread
  creation, userdata rooting, the minicoro entry callback, tag comparison,
  generic value calls, and traceback handoff.
* `titan-runtime/minicoro.h` is a vendored copy of minicoro extended with
  tagged nested yield and a `MCO_STACKED` state.

## Public Wrapper

`coro.titan` imports minicoro's private struct layout first, then the
private helper header:

```lua
local mco = foreign import "minicoro.h"
local rt = foreign import "titan/coro.h"
```

The exported `Coro` record has local fields:

```lua
record Coro
  local handle: value
  local default_tag: value
end
```

That keeps the Lua-visible record opaque while allowing public methods to
pass the raw handle to the helper through the FFI. The helper exposes the
minicoro handle as a borrowed C pointer typedef, `titan_coro_ref`.
Because `minicoro.h` is imported directly, `coro.titan` can read the
private `mco_coro` fields it needs, such as `stacked_co`, without a C
helper for simple source selection. A `titan_coro_ref` is borrowed from
its owning handle or from `mco_running()`. The C header is a private
standard-library boundary: the Titan type system cannot prevent a module
that imports it directly from storing a stale pointer or violating the
transfer order. Helper functions that need the calling Lua state take
`lua_State *L`; Titan's built-in `L` local supplies that argument.

`coro.titan` calls minicoro directly for storage and control transfer:
`mco_push`, `mco_pop`, `mco_resume`, `mco_yield`, `mco_status`,
`mco_running`, `mco_is_yieldable`, and `mco_result_description`. User
payloads are transported separately:

1. `Coro:resume` converts the private handle to `titan_coro_ref`,
   selects the current transfer source (`co->stacked_co` when present,
   otherwise `co`), pushes `payload=arg` and `ok=true`, and calls
   `mco_resume` with the resolved tag.
2. `Coro:error` follows the same path but pushes `ok=false` and
   `payload=err`.
3. `coro.yield` obtains the current running coroutine, pushes
   `payload=arg` and `ok=true`, and calls `mco_yield`.
4. The same helper that calls `mco_resume` selects the transfer source
   again immediately after control returns. Tagged nested yield can change
   it from the resumed coroutine to the deepest stacked coroutine.
5. The helper pops `ok` and `payload` separately before returning to its
   caller. For `resume`/`error`, `ok=false` means the source coroutine has
   already died; its entry point pinned any coroutine traceback and cleared
   its dead child-thread stack before returning control. The helper raises
   `payload` directly. For `yield`, `ok=false` is an injected error at a
   live yield site, so the helper also just raises `payload`.

## TValue FFI Boundary

The C FFI imports Lua's by-value `TValue` as a distinct C type and has
coercions between Titan `value` and C `TValue`. It also lets Titan form
source-level C pointer types (`*T`, `const *T`), read `T.sizeof`, and
coerce C locals/formals to mutable pointer parameters. This is enough for
`coro.titan` to call minicoro's storage and tag APIs directly:

```lua
local payload: rt.TValue = nil
local ok: rt.titan_ffi_int = 0 as rt.titan_ffi_int
mco.mco_pop(source, ok, rt.titan_ffi_int.sizeof)
mco.mco_pop(source, payload, rt.TValue.sizeof)
```

When a C call mutates a stack-anchored `TValue` local through a mutable
pointer argument, the FFI lowering refreshes that local's Lua stack anchor
immediately after the call. Coroutine result helpers still keep the
control switch and the result pops in the same Titan function, so no
generated helper prologue can run a GC check while a final dead-coroutine
payload exists only in minicoro storage.

For resume/yield tags, `coro.titan` materializes the effective Titan
`value` as a local C `TValue` and passes that local to minicoro's `void *`
tag parameter:

```lua
local ctag: rt.TValue = tag
mco.mco_resume(co, ctag)
```

Minicoro treats that pointer opaquely and compares it before returning
from the control-transfer call.

The helper stores live values in ordinary Lua roots:

* the coroutine handle is full userdata whose raw payload is the
  `mco_coro *`;
* the handle's uservalue roots the child Lua thread;
* the child thread stack roots the callback function value while the
  coroutine is alive; when the entry point finishes, it copies the final
  return/error payload into minicoro storage, pins any captured traceback in
  the registry, and clears the dead child stack before returning control;
* `mco_coro->user_data` stores only the child `lua_State *` needed by
  `void (*func)(mco_coro *co)`;
* in-flight arguments, yielded values, errors, tags, and handles remain
  rooted by the Titan formal parameters whose C stack frames are
  suspended by minicoro.

There is no registry pin for coroutine handles. A reachable coroutine is
kept alive by ordinary Lua reachability: the user's `Coro` record owns
the handle, the handle roots the child Lua thread, and nested
`resume`/`yield` chains keep their outer frames suspended instead of
unwinding them.

Transfer itself uses minicoro storage. `coro.titan` pushes the payload
`TValue` and then the `ok` flag with `mco_push`; the receiver pops `ok`
first and the payload second with `mco_pop`. Minicoro copies the struct
bytes. It never owns a Lua root for the collectable object referenced by
the copied `TValue`; ordinary suspended transfers are rooted by the
owning Lua/Titan frame. Final callback return/error payloads are rooted
on the child stack while the entry copies them, then are popped by the
receiver immediately after the context switch returns, before any
intervening allocation.

## Entry Function

Each coroutine handle owns a `lua_newthread` thread. Creation copies the
callback value onto that child thread's first real Lua stack slot. Lua's
base `CallInfo` function slot is reserved and stays nil. The minicoro
entry function uses the child thread from `mco_coro->user_data`, pushes
the rooted callback and first argument, and calls it through the same
generic value-call path generated Titan code uses:
`luaD_callnoyield` under a protected boundary with Titan's
`errorhandler` installed as `L->errfunc`.

Calling a Titan function value this way goes through its normal Lua entry
wrapper, so `_mod`, `_fn`, captures, argument checks, and result checks
are the same as for any generic function-value call.

On success, the entry records `ok=true`, copies the result `TValue` into
minicoro storage, clears the dead child stack, and returns control. On
error, Titan's `errorhandler` has already stored the coroutine-thread
traceback in `registry[TITAN_BACKTRACE_KEY]`; the entry sets the one-shot
trace pin, copies `(false, error)` into minicoro storage, clears the dead
child stack, and returns control. When the Titan wrapper observes
`ok=false` after `resume` or `error`, it raises the payload directly. The
pin tells the caller's error handler to keep the coroutine traceback rather
than replacing it with a shallow wrapper traceback.

`Coro:error` before the first normal `resume` is handled without calling
the callback: the entry sees the preloaded `ok=false` transfer, returns
it as the final payload, and leaves the value rooted by the caller's
suspended `err` parameter until the transfer is consumed.

## FFI Experiment Notes

This implementation intentionally pushes the C FFI boundary: the Titan
module manipulates borrowed `mco_coro *` values, calls minicoro directly,
moves arbitrary Lua values as by-value `TValue`s, and owns the order of
`mco_push`/`mco_pop` operations. That raw pointer surface is deliberately
private to `coro.titan`; it is not a safe general-purpose coroutine FFI.
The pieces that remain in C are the ones that still require capabilities
outside the current FFI:

* exporting a Titan closure as a C callback with `void (*)(mco_coro *)`
  ABI, for the minicoro entry point or tag comparator;
* installing userdata finalizers, uservalues, metatables, and write
  barriers from Titan code;
* using Lua protected-call internals, `luaD_callnoyield`, `CallInfo`, and
  traceback registry handoff from Titan source.

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

All resumes and yields are tagged. The comparator is a static setting of
the minicoro implementation, not a per-call argument. Minicoro stores
tags as opaque `void *`; it knows nothing about Lua. Titan passes
pointers to in-flight `TValue`s, and the C comparator compares them with:

```c
luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2)
```

Using `NULL` gives raw Lua equality: no `__eq` metamethods and no Lua
state dependency in the minicoro extension.

When a coroutine yields to a non-immediate outer tag, the coroutine whose
`mco_resume` is returning becomes `MCO_SUSPENDED`. The coroutines between
that handler and the yielder become `MCO_STACKED`. The suspended handler
records the deepest stacked coroutine in `stacked_co`; the existing
`prev_co` links describe the rest of the chain. Resuming the suspended
handler reconstructs that chain and performs one context switch to the
deepest stacked coroutine. Directly resuming any stacked coroutine is
rejected with `MCO_NOT_SUSPENDED`.

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
