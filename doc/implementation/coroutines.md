# Coroutines

The `coro` standard module is split deliberately:

* `coro.titan` owns the public API and policy: tag defaults, status
  strings, result-code checks, `resume` versus `error`, and the
  success/error payload convention.
* `titan-runtime/titan_coro.c` owns unsafe runtime work: Lua thread
  creation, userdata rooting, `TValue` transport, stack switching, and
  traceback handoff.
* `titan-runtime/minicoro.h` is a vendored copy of minicoro extended with
  tagged nested yield and a `MCO_STACKED` state.

## Public Wrapper

`coro.titan` imports the private helper header:

```lua
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
pass the raw handle to the helper through the FFI. The helper functions
take `lua_State *L`; Titan's built-in `L` local supplies the calling Lua
state.

The helper returns minicoro-compatible integer result codes. The Titan
wrapper checks them and raises `titan_coro_result_name(result)` on
control-transfer failures. User payloads are transported separately:

1. `Coro:resume` pushes `(ok=true, payload=arg)` into the target and calls
   `titan_coro_resume`.
2. `Coro:error` pushes `(ok=false, payload=err)` and calls
   `titan_coro_resume`.
3. `coro.yield` pushes `(ok=true, payload=arg)` into the current
   coroutine and calls `titan_coro_yield`.
4. After control returns, the wrapper pops `(ok, payload)`. `ok=false`
   becomes `raise payload`; `ok=true` returns `payload`.

The explicit `raise payload` is a fresh raise, not a bare re-raise. For
uncaught coroutine-body errors, the C helper must restore the saved
traceback in `TITAN_BACKTRACE_KEY` and set `TITAN_TRACE_PINNED` before
returning control to the wrapper.

## TValue FFI Boundary

The C FFI recognizes exact by-value `TValue` as Titan `value`. Pointers
and arrays of `TValue` remain unsupported. This lets `coro.titan` pass
arbitrary values, function values, tags, and error payloads directly to
the private helper without inventing a second boxing layer.

The helper stores live values in ordinary Lua roots:

* the coroutine handle is full userdata with uservalues for the child Lua
  thread, callback function value, transfer payload, and saved traceback;
* a registry table roots live coroutine handles until the coroutine dies;
* yielded values and tags also remain rooted by the Titan formal
  parameters whose C stack frames are suspended by minicoro.

## Entry Function

Each coroutine handle owns a `lua_newthread` thread. The minicoro entry
function retrieves the callback value from the handle uservalue, pushes
it onto the child thread stack, pushes the first argument, and calls it
with `lua_pcall` using Titan's `errorhandler` as the message handler.

Calling a Titan function value this way goes through its normal Lua entry
wrapper, so `_mod`, `_fn`, captures, argument checks, and result checks
are the same as for any generic function-value call.

On success, the entry stores `(ok=true, payload=result)` and marks the
coroutine dead. On error, it stores `(ok=false, payload=error)`, snapshots
`registry[TITAN_BACKTRACE_KEY]` into the handle, and marks the coroutine
dead. When the resumer later observes `ok=false`, the helper restores
that traceback and sets the one-shot trace pin before `coro.titan`
executes `raise payload`.

`Coro:error` before the first normal `resume` is handled without calling
the callback: the entry sees the preloaded `ok=false` transfer, stores it
as the final payload, and returns dead immediately.

## Tagged Minicoro

The vendored minicoro extension adds:

```c
typedef int (*mco_tag_comparator)(void *t1, void *t2);

mco_result mco_resume_tagged(mco_coro *co, void *tag,
                             mco_tag_comparator comparator);
mco_result mco_yield_tagged(mco_coro *co, void *tag,
                            mco_tag_comparator comparator);
int mco_is_yieldable_tagged(mco_coro *co, void *tag,
                            mco_tag_comparator comparator);
```

Minicoro stores tags as opaque `void *`; it knows nothing about Lua.
`titan_coro.c` passes pointers to rooted `TValue`s and compares them with:

```c
luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2)
```

Using `NULL` gives raw Lua equality: no `__eq` metamethods and no Lua
state dependency in the minicoro extension.

When a coroutine yields to a non-immediate outer tag, each skipped
coroutine is put in `MCO_STACKED`. The extension records
`stacked_child`/`stacked_parent` links so Titan can route transfer
payloads to the deepest suspended child and reject direct resumes of a
child whose parent is still stacked.

The dummy return address at the base of each assembly coroutine stack is
`NULL`, not a poison address. Titan's errorhandler uses libbacktrace; a
poison return address made the native unwinder chase invalid memory when
an error was raised on a minicoro stack.

Titan coroutine stacks are currently created with a 1 MiB stack size.
This leaves room for Titan's errorhandler, whose libbacktrace scratch
state is larger than minicoro's default 56 KiB stack.
