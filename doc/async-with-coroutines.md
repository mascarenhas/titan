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
  local udata: value
  local handle: *mco.mco_coro
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
coroutine traceback followed by the caller-side propagation traceback.

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
result-code checks, success/error payload convention, Lua-thread/userdata
setup, and Titan/Lua-facing entry wrappers. Its implementation imports
minicoro and private runtime headers:

```lua
local mco = foreign import "minicoro.h"
local lua = foreign import "lua.h"
local lual = foreign import "lauxlib.h"
local ffi = foreign import "titan/ffi.h"
local coro = foreign import "titan/coro.h"
```

The FFI calls that need the current Lua state use Titan's existing
built-in `L` local. The functions in `coro.titan` that create handles
already have that `L`; no new language surface is needed to pass the
calling state to C.

The C helper interface is deliberately tiny. `coro.titan` imports
`minicoro.h` directly, reads the `mco_coro` fields it needs, constructs
the owner userdata and typed handle, and calls the minicoro
storage/control APIs directly.
The C helper surface used by `coro.titan` consists of the entry
trampoline and static tag comparator:

```c
void titan_coro_entry(mco_coro *co);
int titan_coro_tag_equal(void *t1, void *t2);
```

The split is the important point. `mco_resume`, `mco_yield`,
`mco_push`, and `mco_pop` return `mco_result`, not the user's payload.
The Titan layer checks those results and raises a Titan error with
`mco_result_description` when the control transfer itself failed. Titan
pushes `payload` then `ok`, and pops `ok` then `payload`. On `ok=false`
after `resume`/`error`, the dead source entry has staged any traceback and
the caller appends its propagation traceback before re-raising. On
`ok=false` after `yield`, the source is still live and the payload is
simply the injected error.

`coro.titan` then has the public shape:

```lua
function create(func: (value) -> value, default_tag: value): Coro
  -- after creating the owner userdata and letting mco_create fill slot:
  return Coro.new(ffi.lua_totvalue(L, -1), slot[0], default_tag)
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

local function check_mco_result(result: mco.mco_result)
  if (result as integer) ~= (mco.MCO_SUCCESS as integer) then
    raise (mco.mco_result_description(result) as string)
  end
end

local function transfer_source(co: *mco.mco_coro): *mco.mco_coro
  if co and co.stacked_co then
    return co.stacked_co
  end
  return co
end

function Coro:resume(arg: value, tag: value): value
  local t = effective_tag(self.default_tag, tag)
  local co = self.handle
  local source = transfer_source(co)
  push_transfer(source, 1, arg)
  return resume_result_or_raise(co, source, t)
end

function Coro:error(err: value, tag: value): value
  local t = effective_tag(self.default_tag, tag)
  local co = self.handle
  local source = transfer_source(co)
  push_transfer(source, 0, err)
  return resume_result_or_raise(co, source, t)
end

function yield(arg: value, tag: value): value
  if tag == nil then
    raise "must provide non-nil tag argument to coro.yield"
  end
  local co = mco.mco_running()
  push_transfer(co, 1, arg)
  return yield_result_or_raise(co, tag)
end
```

The exact source can be adjusted to local style, but the important point
is that the public API and transfer choreography remain Titan code while
only C-only callbacks and tag comparison stay in `titan_coro.c`.
`resume_result_or_raise` and `yield_result_or_raise` intentionally perform
the `mco_resume`/`mco_yield` and the matching `mco_pop` operations in the
same Titan function: once a dead coroutine entry point has cleared its
child stack, no generated Titan helper prologue may run before the result
payload has been popped into a stack-anchored `TValue` local.

For uncaught coroutine-body errors, the entry point depends on a
runtime-side invariant: before it returns `(false, error)` to the
resumer, it stages the captured coroutine traceback under
`TITAN_TRACE_APPEND_KEY`. The `resume`/`error` wrapper then raises and
catches the returned payload to capture a new propagation traceback,
appends that trace to the staged coroutine trace, writes the combined
string under `TITAN_BACKTRACE_KEY`, sets Titan's one-shot trace pin, and
re-raises the same payload. The pin is still required because that final
raise would otherwise replace the combined traceback.

The raise in `yield` is different. When `Coro:error` injects an error
into a suspended yield, that error is intentionally raised at the yield
site. If it escapes the callback, the entry boundary then treats it like
any other uncaught coroutine-body error and returns a staged traceback to
the resumer.

No `TITAN_VER` bump is required if the implementation is confined to
this new module and does not change generated native signatures,
function-value layout, serialized type syntax, or existing runtime
contracts. If any of those change, bump the ABI and update the ABI tests
in the same patch.

## FFI extensions for `TValue` and C addresses

`TValue` is available from the compiler-provided FFI header as a real C
type, distinct from Titan `value`. The typechecker/code generator rules
then provide coercions:

* a Titan expression of type `value` is accepted for a C parameter of
  type `TValue`;
* a C expression of type `TValue` can be returned or assigned where a
  Titan `value` is expected;
* passing a non-`value` Titan expression to a `TValue` parameter uses the
  normal implicit coercion to `value` first;
* an imported alias such as `ffi.TValue` remains a C type, so Titan code
  can also name `*ffi.TValue`, `const *ffi.TValue`, `ffi.TValue.sizeof`,
  and `ffi.TValue.alignof`.

The FFI also supports source-level C pointer types over imported C
types (`*T`, `const *T`), C `sizeof`/`_Alignof` pseudo-members, and
address coercions for calls:

* non-pointer by-value C expressions, including C `TValue`, can be passed
  to compatible `const *T` or `const void *` parameters;
* mutable non-pointer local/formal C variables can be passed to
  compatible mutable `*T` or `void *` parameters, which covers ordinary C
  out-parameters; if the local/formal is a GC-bearing C `TValue`, the
  generated code refreshes its stack anchor immediately after the C call;
* C function pointers are excluded from object-pointer/value paths.

These conversions do not make arbitrary C helper storage into GC roots. A
local, temporary, or parameter whose C type is `TValue` is stack-anchored like
Titan `value`, but C helpers and minicoro storage may also copy `TValue` structs
by value. Any collectable object inside those helper-owned copies must remain
rooted by the original Titan frame, coroutine userdata, Lua stack, or another
traced Lua object. The coroutine helpers are allowed to keep by-value copies
across a minicoro stack switch because the Titan frames that supplied those
parameters are not unwound by `yield`.

With those rules, `coro.titan` does not need C shims for storage or
tag-only minicoro operations. It can call `mco_push`/`mco_pop` directly
with `TValue` and `int` locals, and it can materialize a tag as a local
C `TValue` before passing it to `mco_resume`, `mco_yield`, or
`mco_is_yieldable`.

## Coroutine object representation

The exported `Coro` record is opaque. Its fields are local to `coro`:

* `udata: value` roots the full owner userdata whose raw payload is an
  `mco_coro *` slot.
* `handle: *mco.mco_coro` caches the pointer from that slot for direct
  use by normal coroutine operations.
* `default_tag: value` stores nil or a non-nil default tag.

Keeping both fields separates lifetime from access: `udata` makes the
owner visible to Lua's collector, while the typed `handle` avoids
unwrapping a `value` for every `resume`, `error`, or `status` call. Only
the owner userdata's `__gc` finalizer pushes its userdata argument,
recovers the pointer with `lua_touserdata`, and calls `mco_destroy`.

The owner userdata has four uservalues that root:

1. the Lua thread created by `lua_newthread`;
2. the coroutine module state;
3. the native Titan entry closure;
4. the callback function value passed to `create`.

The child-thread frame roots a final callback return/error payload while
the entry point copies it into minicoro storage, stages any captured
traceback, and clears the dead child stack before returning control.
Ordinary yielded/resumed payloads do not need a persistent uservalue
slot. They remain rooted by the suspended Titan frames that own the
formal parameters.

The raw `mco_coro` user data points back to the owner userdata needed by
`void (*func)(mco_coro *co)`. That pointer is not a GC root. Every
collectable Lua object must also be reachable from a Lua stack slot,
userdata uservalue, table, registry entry, or another traced object.

There is no private registry root for live coroutine handles. A
reachable coroutine stays alive through ordinary Lua ownership: the
user's `Coro` record roots the owner userdata through `udata`, the
userdata roots the child thread and callback through its uservalues, and
nested coroutine chains keep their outer Titan frames suspended rather
than unwound.

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
`mco_push`/`mco_pop`, because minicoro copies the struct bytes and
ordinary suspended transfers keep the owning Titan frame rooted. For
final callback return/error payloads, the entry copies the payload
immediately before returning control and the receiver pops it immediately
after the context switch returns, before any intervening allocation. The
runtime must not make minicoro storage, raw C heap memory, or untraced
fields the only root for a collectable payload beyond those bounded
transfer windows.

Each transfer pushes two values into minicoro storage: the payload
`TValue`, followed by the `ok` flag. The receiver pops `ok` first and
the payload second. No payload or success flag needs to be cached in
`mco_coro->user_data`.

When storing a collectable value into an old userdata uservalue or record
field, use the existing Lua 5.5 barrier discipline. Public API helpers
that operate through Lua API calls such as `lua_setiuservalue` get that
barrier from Lua. Direct writes into `Udata->uv[]` need
`luaC_barrierback`.

The implementation must be tested in both incremental and generational
GC modes. In particular, an old `Coro` record must safely keep a young
owner userdata reachable, and that userdata's uservalues must keep a
young Lua thread, module state, entry closure, and callback reachable.
The child-thread frame keeps any final return/error root reachable, and
the `Coro` record itself keeps the default tag reachable.

## Calling the entry function

The minicoro entry point retrieves the owner userdata from
`mco_coro->user_data`. Its four uservalues provide the coroutine's Lua
thread, module state, native Titan entry closure, and callback function.
The C trampoline extracts the native pointer from the entry closure and
calls that Titan entry directly with the child thread, module state,
callback, and `mco_coro *`; it does not enter through the Lua wrapper on
every resume. The Titan entry calls the callback with one `value`
argument and expects one `value` result.

The callback uses the same function-value call path as ordinary generated
Titan code. An exact Titan closure with the expected `(value) -> value`
type can take the native fast path. Otherwise the generic path pushes the
boxed callee and argument on the coroutine Lua stack, calls through Lua's
ordinary machinery, and reads one boxed result; this covers other Titan
function values, Lua closures, Lua C functions, and `__call` objects.

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
3. the coroutine-thread traceback is staged under
   `TITAN_TRACE_APPEND_KEY` in the shared registry;
4. the entry copies `(false, error)` into minicoro storage, clears the
   dead child stack, and returns control to the resumer;
5. the resumer pops the error payload immediately, captures its own
   propagation traceback, appends it to the staged coroutine trace, pins
   the combined trace, and re-raises the same value.

The pin is still required. Re-raising the returned payload is a fresh
raise, so Titan's error handler would otherwise replace the combined
traceback with only the shallow propagation site. The coroutine protocol
uses the same one-shot pin mechanism as Titan generated code's bare
re-raise, but the trace string being pinned is the coroutine trace plus
the resume/error propagation trace.

An error injected by `Coro:error` is different from an uncaught callback
error: it is raised at the target `yield` site. If target code catches
it, the coroutine continues. If it escapes, the same uncaught-error rule
above applies.

V1 does not include general cancellation. `mco_destroy` is only reached
from the owner userdata finalizer, so it runs after the coroutine has
become unreachable through ordinary Lua references. A later cancellation
feature can resume a reachable coroutine with an injected error and let
normal unwinding run cleanup.

Finalizing the suspended handler of an unreachable stacked tagged-yield
chain is cleanup, not cancellation. Minicoro abandons that skipped chain
without running user code: it clears the handler's `stacked_co`, marks the
stacked inner coroutines dead, and clears their `prev_co` links so their
own finalizers can destroy them safely.

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
owner userdata, and each `mco_coro`'s user data.

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
* raw `TValue *`, `const TValue *`, and `TValue[]` interfaces import as C
  pointer/array types, and the new address coercions cover the scoped
  pointer arguments used by `coro.titan`.

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
* uncaught callback errors, preserved coroutine traceback plus propagation
  traceback, and
  interaction with `raise`, `catch`, `finally`, and bare re-raise;
* traceback handoff from the coroutine entry point: the entry stages the
  inner traceback, the resume/error side appends its propagation traceback,
  and the final re-raise pins the combined trace;
* yield before a `finally` block, then later resume, proving the
  suspended stack preserves pending cleanup state;
* Lua interop through `require "coro"`: method calls, bad argument
  counts, bad callback values, bad tags, and non-callable callbacks;
* GC stress in incremental and generational modes, including old
  coroutine owner userdata rooting young Lua threads, callback closures,
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
* A focused Titan/FFI probe confirmed that raising a returned payload
  without setting `TITAN_TRACE_PINNED` captures a fresh wrapper traceback;
  this is why coroutine error propagation stages the inner trace, captures
  a fresh propagation trace, then pins the combined trace across the final
  raise.
* Plain Lua `coroutine.yield` is not yieldable under a protected-call
  entry path, confirming that Titan coroutine yield must be minicoro
  backed.
* Stock minicoro nested resume/status behavior works, but there is no
  `MCO_STACKED`; tagged skip/restore behavior is a real extension.

These checks make the design feasible, but they are not substitutes for
the required Titan integration tests above.
