# Titan coroutines implementation spec

Status: finalized implementation spec for the roadmap item "asymmetric,
tagged (nested) coroutines as building block for async IO".

This feature adds a small standard-library module, `coro`, that gives
Titan stackful, asymmetric coroutines with tagged nested yield. The
public API is written in Titan and delegates to private C runtime helpers
through the FFI. It is the control-transfer substrate for later async IO
and green-thread schedulers. It does not add scheduling, timers, libuv
integration, or new syntax.

The implementation is based on a vendored copy of
https://github.com/edubart/minicoro, extended with the tagged nested
semantics of https://github.com/mascarenhas/taggedcoro.

## Public API

Titan code imports the module statically:

```lua
local coro = import "coro"
```

Lua code can load the same module dynamically with `require "coro"`.

The Titan interface is:

```lua
record Coro
  local handle: value
  local default_tag: value
end

function create(func: (value) -> value, default_tag: value): Coro
function Coro:resume(arg: value, tag: value): value
function Coro:error(err: value, tag: value): value
function Coro:status(): string

function yield(arg: value, tag: value): value
function is_yieldable(tag: value): boolean
```

Titan's normal argument adjustment makes the second parameter of
`create`, `resume`, and `error` optional in practice: omitting it passes
`nil`. `nil` means "no tag supplied" and is not itself a legal tag.

`arg`, `err`, and every returned value may be `nil`, because they are
ordinary `value`s. Only tags must be non-nil.

Tags compare with Titan/Lua raw equality, the same equality Titan uses
for `value == value`: numbers compare by Lua numeric equality, strings
by contents, booleans by value, and tables, userdata, threads, and
functions by identity. Tag comparison does not call metamethods.

`default_tag` is only a convenience stored on a `Coro`. When `resume` or
`error` receives `nil` as its explicit tag, it uses `self.default_tag`.
If the effective tag is still `nil`, the method raises in the caller.
`yield` and `is_yieldable` do not use any default tag and require an
explicit non-nil tag.

## User semantics

Coroutines are asymmetric: a caller resumes a target coroutine, and the
target eventually returns control by yielding, returning from its entry
function, or raising an uncaught error. A resumed coroutine can itself
resume another coroutine, creating a dynamic chain.

Each `resume` or `error` call installs a temporary active handler tagged
with the effective tag. A `yield(arg, tag)` transfers control to the
nearest active handler in the dynamic resume chain whose tag is raw-equal
to `tag`.

If the immediate resumer's tag does not match, the implementation walks
outward through the chain. The handler that matched receives the yielded
value, becomes `suspended`, and is the coroutine that must be resumed
later. The inner coroutines between that handler and the yielder become
`stacked`. Later, resuming the suspended handler restores the skipped
stack and eventually resumes the original `yield` call.

This is the core nested behavior:

```text
main resumes A with tag "main"
  A resumes B with tag "a"
    B yields "payload" to tag "main"

main's resume(A) returns "payload"; A is suspended, B is stacked.
main resumes A again; A and B are restored; B's yield returns.
```

### Creating a coroutine

`create(func, default_tag)` creates a coroutine in the `suspended` state.
The function has type `(value) -> value`; the first successful
`resume(arg, tag)` calls `func(arg)` on the coroutine's own Lua thread.

`default_tag` may be omitted or nil. A non-nil default tag is stored and
used only by `Coro:resume` and `Coro:error` when their tag argument is
nil.

### Resuming normally

`co:resume(arg, tag)` computes the effective tag, checks that `co` can be
resumed, installs that tag as the current active handler, and transfers
control into `co`.

When `co` reaches `coro.yield(value, matching_tag)`, the `resume` call
returns `value` and `co` becomes `suspended`. For a nested tagged yield,
the matching handler becomes `suspended` and inner coroutines up to the
yielder become `stacked`.

When `co`'s entry function returns normally, the `resume` call returns
that value and `co` becomes `dead`.

Calling `resume` on a `running`, `normal`, or `dead` coroutine is an
error raised in the caller. Resuming a stacked coroutine is also an
error. Resuming the suspended handler that received the nested yield is
the normal restore path. Calling `resume` on a coroutine from a different
independent Lua state is an error.
Resuming a coroutine created from another thread of the same Lua state is
valid only through the runtime's normal same-state checks.

### Injecting an error

`co:error(err, tag)` has the same routing and state checks as `resume`,
but transfers an error instead of a successful value.

If `co` is suspended at a `yield`, the `yield` call raises `err` at the
yield site. The coroutine may catch that error. If it catches and later
yields or returns, `co:error` returns that yielded or returned value. If
the error is uncaught, `co:error` re-raises it in the caller with the
coroutine's traceback.

If `co:error` is used before the first normal `resume`, the coroutine is
started only far enough to raise `err` before calling the entry function.
That normally makes the coroutine `dead` and re-raises `err` in the
caller.

### Yielding

`coro.yield(arg, tag)` can be called only while running inside a Titan
coroutine. It requires a non-nil tag. If no active handler in the dynamic
resume chain has a raw-equal tag, `yield` raises in the current
coroutine.

When a later `resume` sends a successful value back into the suspended
coroutine, `yield` returns that value. When a later `error` sends an
error back in, `yield` raises that error at the yield site.

Titan coroutine yield is not Lua coroutine yield. It does not call
`lua_yield`, does not set `lua_State.status` to `LUA_YIELD`, and is not
observable through Lua's `coroutine.status`. Lua code running inside a
Titan coroutine must use `coro.yield`; plain `coroutine.yield` remains
subject to Lua's usual C-call-boundary restrictions.

### Testing yieldability

`coro.is_yieldable(tag)` returns whether a `yield` with that non-nil tag
would currently find a matching active handler. It returns `false`
outside Titan coroutines and inside coroutines whose dynamic resume chain
does not contain the tag.

### Status strings

`co:status()` returns one of:

| Status | Meaning |
| --- | --- |
| `"suspended"` | The coroutine is resumable. This includes a newly created coroutine and one stopped at `yield`. |
| `"running"` | The coroutine is the currently executing coroutine. |
| `"normal"` | The coroutine is active in the dynamic chain but has resumed another coroutine. |
| `"stacked"` | The coroutine is inside a skipped chain created by a tagged nested yield; resuming the suspended matching handler restores the skipped stack. |
| `"dead"` | The entry function returned, an uncaught error escaped, or an error was injected before the entry function started. |

`stacked` is observable so schedulers can diagnose nested tagged yields.
Resuming the suspended handler that received the yield restores the
skipped stack; resuming a stacked coroutine is the incorrect
direct-resume case.

## Module shape

`coro` is an ordinary Titan source module installed with the compiler. It
owns the public `Coro` record, default-tag policy, status-string mapping,
and Titan/Lua-facing entry wrappers. Its implementation imports a
compiler-provided private header:

```lua
local mco = foreign import "minicoro.h"
local rt = foreign import "titan/coro.h"
```

The runtime helper functions take the current Lua state through Titan's
existing built-in `L` local. The functions in `coro.titan` that need to
create, resume, yield, or inspect coroutines already have that `L`; no
new language surface is needed to pass the calling state to C.

The private helper interface should be thin. `coro.titan` owns policy:
effective-tag resolution, the difference between `resume` and `error`,
the success/error payload convention, `mco_result` checks, conversion
from runtime status codes to public strings, and the order of transfer
operations around minicoro. The C helpers own only the unsafe pieces:
handle validation, address-taking for `TValue` storage and tags, stack
switching, callback entry, and Lua-internal bookkeeping.

The FFI-facing helper shape exposes a borrowed `mco_coro *` handle and
small shims where Titan cannot yet spell `&value`.
`coro.titan` imports `minicoro.h` directly so it can read simple private
fields such as `stacked_co` without adding C helpers for that policy:

```c
typedef struct mco_coro *titan_coro_ref;

enum {
  TITAN_CORO_SUCCESS = 0,
  TITAN_CORO_STATUS_DEAD = 0,
  TITAN_CORO_STATUS_NORMAL = 1,
  TITAN_CORO_STATUS_RUNNING = 2,
  TITAN_CORO_STATUS_SUSPENDED = 3,
  TITAN_CORO_STATUS_STACKED = 4
};

TValue titan_coro_create(lua_State *L, TValue func);
titan_coro_ref titan_coro_handle(TValue handle);
titan_coro_ref titan_coro_running(void);
int titan_coro_push_value(titan_coro_ref co, TValue payload);
int titan_coro_push_int(titan_coro_ref co, int value);
TValue titan_coro_pop_value(lua_State *L, titan_coro_ref co);
int titan_coro_pop_int(lua_State *L, titan_coro_ref co);
void titan_coro_discard_transfer(titan_coro_ref co);
int titan_coro_resume(titan_coro_ref co, TValue tag);
int titan_coro_yield(titan_coro_ref co, TValue tag);
int titan_coro_is_yieldable(titan_coro_ref co, TValue tag);
int titan_coro_status(titan_coro_ref co);
void titan_coro_clear_dead(lua_State *L, titan_coro_ref source);
void titan_coro_raise(lua_State *L, titan_coro_ref source, TValue payload);
char *titan_coro_result_name(int result);
```

The exact names are not important; the split is. `resume` and `yield`
return an `mco_result`-compatible integer, not the user's payload. The
Titan layer checks it and raises a Titan error with
`titan_coro_result_name` when the control transfer itself failed. Titan
pushes `payload` then `ok`, and pops `ok` then `payload`. On `ok=false`
it delegates only the traceback restoration and actual `lua_error` to C.

`coro.titan` then has the public shape:

```lua
function create(func: (value) -> value, default_tag: value): Coro
  return Coro.new(rt.titan_coro_create(L, func), default_tag)
end

local function effective_tag(default_tag: value, explicit_tag: value): value
  local tag = explicit_tag
  if tag == nil then
    tag = default_tag
  end
  if tag == nil then
    raise "must provide tag argument if no default_tag was provided"
  end
  return tag
end

local function check_result(result: rt.titan_ffi_int)
  if (result as integer) ~= (rt.TITAN_CORO_SUCCESS as integer) then
    raise (rt.titan_coro_result_name(result) as string)
  end
end

local function transfer_source(co: rt.titan_coro_ref): rt.titan_coro_ref
  if co and co.stacked_co then
    return co.stacked_co
  end
  return co
end

function Coro:resume(arg: value, tag: value): value
  local t = effective_tag(self.default_tag, tag)
  local co = rt.titan_coro_handle(self.handle)
  local source = transfer_source(co)
  push_transfer(source, 1, arg)
  resume_checked(co, source, t)
  return pop_transfer_or_raise(transfer_source(co))
end

function Coro:error(err: value, tag: value): value
  local t = effective_tag(self.default_tag, tag)
  local co = rt.titan_coro_handle(self.handle)
  local source = transfer_source(co)
  push_transfer(source, 0, err)
  resume_checked(co, source, t)
  return pop_transfer_or_raise(transfer_source(co))
end

function yield(arg: value, tag: value): value
  if tag == nil then
    raise "must provide non-nil tag argument to coro.yield"
  end
  local co = rt.titan_coro_running()
  push_transfer(co, 1, arg)
  yield_checked(co, tag)
  return pop_transfer_or_raise(co)
end
```

The exact source can be adjusted to local style, but the important point
is that the public API remains Titan code while the unsafe stack switch
and Lua-internal operations stay behind private C helpers.

For uncaught coroutine-body errors, the C pop helper depends on a
runtime-side invariant: before it raises the returned error payload, it
restores the captured coroutine traceback under `TITAN_BACKTRACE_KEY` and
sets Titan's one-shot trace pin. Restoring the registry traceback without
the pin is not enough, because raising the payload is a fresh raise and
would otherwise capture a new shallow traceback at the wrapper site.

The raise in `yield` is different. When `Coro:error` injects an error
into a suspended yield, that error is intentionally raised at the yield
site. If it escapes the callback, the entry boundary then treats it like
any other uncaught coroutine-body error and returns a pinned traceback to
the resumer.

No `TITAN_VER` bump is required if the implementation is confined to
this new module and does not change generated native signatures,
function-value layout, serialized type syntax, or existing runtime
contracts. If any of those change, bump the ABI and update the ABI tests
in the same patch.

## FFI extension for `TValue`

Before implementing `coro.titan`, extend the C FFI so a C function
parameter or return type spelled exactly `TValue` maps to Titan's
dynamic `value` type.

Add `TValue` to the compiler-provided FFI header, alongside
`lua_State`, as a source-nameable Lua-internal type. Generated Titan C
translation units already include Lua's internal headers and `titan.h`
before foreign headers, so the real `TValue` definition is visible to
the C compiler when emitting helper prototypes.

The typechecker/code generator rules are:

* a Titan expression of type `value` is accepted for a C parameter of
  type `TValue`;
* a C function returning `TValue` produces a Titan expression of type
  `value`;
* passing a non-`value` Titan expression to a `TValue` parameter uses the
  normal implicit coercion to `value` first;
* `TValue` is not a general-purpose C data representation in Titan
  interfaces; an imported alias such as `ffi.TValue` behaves as Titan
  `value`, and this spelling is intended for private runtime helper
  boundaries;
* mutable `TValue *`, arrays of `TValue`, and storing raw `TValue *`
  pointers in Titan-visible values are out of scope for this feature.

This conversion does not make C stack temporaries into GC roots. A C
helper may copy `TValue` structs by value, but any collectable object
inside them must remain rooted by the original Titan frame, coroutine
userdata, Lua stack, or another traced Lua object. The coroutine helpers
are allowed to keep by-value copies across a minicoro stack switch only
because the Titan frames that supplied those parameters are not unwound
by `yield`.

The FFI does not need to expose raw `TValue *` values to Titan for this
feature. The FFI-facing helper can receive a tag as `TValue` by value,
take the address of that C-stack copy for the duration of the stackful
`mco_resume`/`mco_yield` call, and pass that address to minicoro as an
opaque `void *`. The collectable objects inside the copied `TValue`
remain rooted by the corresponding Titan formal parameter or field.

## Coroutine object representation

The exported `Coro` record is opaque. Its fields are local to `coro`:

* `handle: value` stores a full userdata whose raw payload is the
  `mco_coro *`.
* `default_tag: value` stores nil or a non-nil default tag.

The handle userdata must have a uservalue that roots:

1. the Lua thread created by `lua_newthread`.

The child thread stack roots the callback function value passed to
`create`. It also temporarily roots a final callback return/error payload
and saved traceback after the entry function has unwound, until the
resumer consumes the final transfer. Ordinary yielded/resumed payloads do
not need a persistent uservalue slot. They remain rooted by the suspended
Titan frames that own the formal parameters.

The raw `mco_coro` user data stores only the child `lua_State *` needed
by `void (*func)(mco_coro *co)`. That cached pointer is not a GC root.
Every collectable Lua object must also be reachable from a Lua stack
slot, userdata uservalue, table, registry entry, or another traced
object.

There is no private registry root for live coroutine handles. A
reachable coroutine stays alive through ordinary Lua ownership: the
user's `Coro` record owns the handle, the handle roots the child Lua
thread, and nested coroutine chains keep their outer Titan frames
suspended rather than unwound.

Create the Lua thread with `lua_newthread(L)`, never with `luaL_newstate`.
The coroutine thread must share the same `global_State` as the creating
state so stack values can be moved or copied through the normal Lua
same-state mechanisms.

## Value and GC discipline

The runtime transfers one `value` at a time in each direction. The
control transfer is stackful: a `yield` switches C stacks without
unwinding the Lua/Titan call stack that called `yield`. Therefore:

* the `arg` formal parameter of `Coro:resume` stays rooted while the
  resumed coroutine runs;
* the `err` formal parameter of `Coro:error` stays rooted while the
  target handles or propagates it;
* the `arg` formal parameter of `coro.yield` stays rooted while the
  yielding coroutine is suspended;
* active non-nil tags are rooted by the suspended `resume`/`error`
  parameter frame, by the `Coro` record's `default_tag` field, or by the
  suspended `yield` parameter frame.

This is the normal Titan calling convention doing useful work: GC-able
formal parameters are already visible to Lua's collector through the
frame's stack slots, and a minicoro yield preserves those frames instead
of unwinding them.

The runtime may copy `TValue` structs by value between these rooted
locations and native return slots. That is safe because copying/returning
a `TValue` does not allocate, and generated callers immediately anchor
GC-able returns in their own stack slots before any later allocation.

The runtime may copy a `TValue` through minicoro storage with
`mco_push`/`mco_pop`, because minicoro copies the struct bytes and the
owning Titan frame remains suspended and rooted. The runtime must not
make minicoro storage, raw C heap memory, or untraced fields the only
root for a collectable payload beyond that stackful suspension.

Each transfer pushes two values into minicoro storage: the payload
`TValue`, followed by the `ok` flag. The receiver's pop helper pops `ok`
first and the payload second. No payload or success flag needs to be
cached in `mco_coro->user_data`.

When storing a collectable value into an old userdata uservalue or record
field, use the existing Lua 5.5 barrier discipline. Public API helpers
that operate through Lua API calls such as `lua_setiuservalue` get that
barrier from Lua. Direct writes into `Udata->uv[]` need
`luaC_barrierback`.

The implementation must be tested in both incremental and generational
GC modes. In particular, an old `Coro` record and handle userdata must
safely keep a young Lua thread reachable, while that child thread stack
keeps the callback closure and any final return/error roots reachable.
The `Coro` record itself keeps the default tag reachable.

## Calling the entry function

The minicoro entry point retrieves the coroutine's Lua thread from
`mco_coro->user_data` and the callback function from the child thread's
first real Lua stack slot. The base `CallInfo` function slot is reserved
by Lua and remains nil; the callback lives above it. The entry calls the
callback on that Lua thread with one `value` argument and expects one
`value` result.

The callback should be invoked through the same generic function-value
path that `codevaluecall` uses for non-fast-path calls: push the boxed
callee and the boxed `value` argument on the coroutine Lua stack, call
through Lua's ordinary call machinery, then read one boxed result. If the
callback is a Titan function value, its Lua entry wrapper recovers
`_mod` and `_fn`, sees captures, checks arguments, and checks the result
exactly as it already does for ordinary indirect calls. Lua closures, Lua
C functions, and `__call` objects likewise use the existing generic
semantics.

The implementation wraps that generic call in a hand-coded protected
boundary equivalent to Lua's `luaD_rawrunprotected`/`luaD_pcall`
recovery, around `luaD_callnoyield`; it does not use `lua_pcall` or
`lua_pcallk`. `coro.yield` is a minicoro stack switch, not a Lua
`lua_yield`, so it is allowed even when the callback is running under
Titan's existing non-yielding generic function value path. The important
rule is that `coro.yield` must not ask Lua to yield across a C-call
boundary.

## Errors and tracebacks

Errors remain ordinary Lua/Titan error values plus Titan's out-of-band
traceback registry entry.

The coroutine entry call must install or reuse Titan's `errorhandler` on
the coroutine Lua thread before invoking the callback. On an uncaught
error:

1. the coroutine becomes `dead`;
2. the original error value is preserved;
3. the coroutine-thread traceback captured under `TITAN_BACKTRACE_KEY` is
   preserved immediately on the child thread stack;
4. the control transfer returns `(false, error)` to the resumer;
5. the resumer's pop helper roots the error payload, restores the saved
   traceback under `TITAN_BACKTRACE_KEY`, sets the existing
   `TITAN_TRACE_PINNED` one-shot trace pin, and raises the same error
   value in the caller.

The pin is required. A helper that only restores the registry traceback
before raising a false payload still loses the traceback: raising the
payload is a fresh raise, so Titan's error handler captures a new shallow
traceback unless the one-shot pin tells it to keep the restored one. This
is the same protocol Titan generated code uses for bare re-raise.

An error injected by `Coro:error` is different from an uncaught callback
error: it is raised at the target `yield` site. If target code catches
it, the coroutine continues. If it escapes, the same uncaught-error rule
above applies.

V1 does not include general cancellation. `mco_destroy` is only reached
from the handle userdata finalizer, so it runs after the coroutine has
become unreachable through ordinary Lua references. A later cancellation
feature can resume a reachable coroutine with an injected error and let
normal unwinding run cleanup.

## Minicoro changes

Vendor `minicoro.h` under `titan-runtime/` with its upstream tests. Put
`#define MINICORO_IMPL` in exactly one C translation unit owned by the
coroutine module.

Stock minicoro has `MCO_NORMAL`, `MCO_RUNNING`, `MCO_SUSPENDED`, and
`MCO_DEAD`; it supports nested resumes, but an attempt to resume a
`normal` coroutine fails. Titan needs a real extension:

* add `MCO_STACKED`;
* make `mco_resume`, `mco_yield`, and `mco_is_yieldable` tag-only
  operations that receive an opaque `void *tag`;
* add an implementation-level `mco_set_tag_comparator` static setting,
  not a per-call comparator argument;
* record the active resume tag for each dynamic resume activation;
* when a yield tag does not match the immediate active handler according
  to the comparator, walk the nested resume chain outward until a
  matching tag is found;
* mark the matching handler `MCO_SUSPENDED`, mark the inner coroutines up
  to the yielder `MCO_STACKED`, and remember the deepest stacked
  coroutine so the existing chain can be restored later;
* allow resume of the suspended matching handler to restore the skipped
  stack, but reject direct resume of stacked coroutines;
* in both yield and resume, traverse the chain once and then perform a
  single context switch;
* never dereference, copy, compare, or free tags inside minicoro itself.

The minicoro extension should remain unaware of Lua and Titan values. The
Titan C shim supplies a comparator equivalent to:

```c
static int titan_coro_tag_equal(void *t1, void *t2) {
  return luaV_equalobj(NULL, (const TValue *)t1, (const TValue *)t2);
}
```

Using `NULL` gives Lua/Titan raw equality: no `__eq` metamethods, and no
need for a `lua_State *` in minicoro. The tag pointers are valid only
while the owning Titan/C frames are suspended and rooted by the stackful
coroutine transfer.

## Build and packaging

Build `coro.titan` as a standard module installed with Titan. The build
should produce a `.so` that Titan's existing source-vs-compiled-module
lookup can import when user code writes `import "coro"`.

Update the rockspec and Makefile so `luarocks make` and `make test`
build the coroutine module, its private helper header
`titan/coro.h`, the helper C object, and its vendored minicoro object.
The driver does not need to link minicoro into every generated module
unless a future design moves coroutine primitives into `titan.o`.

Avoid mutable process-global scheduler state in `titan.o` or generated
modules. Multiple generated `.so`s can each link their own copy of
`titan.o`; coroutine runtime state should live in the `coro` module, the
handle userdata, and each `mco_coro`'s user data.

Titan's vendored minicoro should not include the Binaryen
`MCO_USE_ASYNCIFY` backend: its unwind/rewind model does not implement
the tagged single-switch skip/restore semantics. Local Linux tests should
cover the ASM and UCONTEXT backends, including VMEM and Valgrind hook
builds. `MCO_USE_FIBERS` remains a supported backend for Windows and
Emscripten, but native Linux cannot execute that backend without a
cross/toolchain-specific test environment.

## Required tests

Add the upstream minicoro tests plus Titan-specific tests for the tagged
extension.

Add FFI coverage for the new `TValue` boundary:

* a C helper receiving `TValue` can be called with `value` and with
  expressions implicitly coerced to `value`;
* a C helper returning `TValue` produces a Titan `value`;
* the conversion works for nil, booleans, numbers, strings, records,
  arrays/maps, and function values;
* raw `TValue *` and `TValue[]` interfaces are rejected or left
  unsupported as specified.

Add Titan runtime/coder coverage for:

* create/resume/yield round trips with nil, booleans, integers, floats,
  strings, records, arrays, maps, function values, and Lua closures;
* `coro.titan` resolving default tags, recording resume as success,
  recording error injection as failure, checking `mco_result`, and
  raising a returned failure payload;
* default tag use, explicit tag override, missing effective tag errors,
  and non-nil tag enforcement;
* raw tag equality for strings, numeric equality, table/userdata
  identity, and no `__eq` metamethod calls;
* nested tagged yield, observable `stacked` status, restoration through
  the suspended matching handler, and rejected direct resume of a stacked
  coroutine;
* `is_yieldable` outside a coroutine, inside a coroutine with no matching
  handler, and inside a coroutine with a matching outer handler;
* normal callback return, dead status, and resume/error after dead;
* `Coro:error` into a suspended yield, catch inside the coroutine,
  uncaught injected error, and injected error before first resume;
* uncaught callback errors, preserved coroutine traceback, and
  interaction with `raise`, `catch`, `finally`, and bare re-raise;
* traceback handoff through the C pop helper: restoring
  `TITAN_BACKTRACE_KEY` alone is overwritten by a fresh payload raise,
  while restoring it and setting `TITAN_TRACE_PINNED` preserves the
  coroutine traceback;
* yield before a `finally` block, then later resume, proving the
  suspended stack preserves pending cleanup state;
* Lua interop through `require "coro"`: method calls, bad argument
  counts, bad callback values, bad tags, and non-callable callbacks;
* GC stress in incremental and generational modes, including old
  coroutine userdata rooting young Lua threads, callback closures,
  default tags, record/table payloads, and function-valued payloads;
* `.so`-only import of `coro` from another Titan module and use from a
  standalone executable.

## Feasibility evidence

The review for this spec included scratch C probes against the in-tree
Lua 5.5 runtime and upstream minicoro:

* Lua 5.5 full userdata uservalues root `lua_newthread` threads and
  function values correctly in both incremental and generational GC
  modes, including old-userdata to young-value writes through
  `lua_setiuservalue`.
* A function value copied onto a child `lua_newthread` stack remains
  callable through `luaD_callnoyield` on that child thread.
* Titan's existing `errorhandler` works when installed on a child Lua
  thread and captures a traceback in the shared registry.
* A focused Titan/FFI probe confirmed that raising a payload after only
  restoring `TITAN_BACKTRACE_KEY` captures a fresh wrapper traceback;
  restoring the traceback and setting `TITAN_TRACE_PINNED` preserves the
  restored traceback across the fresh raise.
* Plain Lua `coroutine.yield` is not yieldable under a protected-call
  entry path, confirming that Titan coroutine yield must be minicoro
  backed.
* Stock minicoro nested resume/status behavior works, but there is no
  `MCO_STACKED`; tagged skip/restore behavior is a real extension.

These checks make the design feasible, but they are not substitutes for
the required Titan integration tests above.
