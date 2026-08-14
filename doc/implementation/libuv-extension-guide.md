# Extending the libuv binding

This chapter is the contributor recipe for extending the private `titan.uv`
folder module. Read the [continuation runtime](libuv-runtime.md) first; the
[DNS and TCP chapter](libuv-networking.md) is the worked example for a
persistent stream handle.

The goal is not a one-for-one public wrapper around libuv. Add only the native
surface needed by a high-level standard module, keep every FFI type inside
`titan.uv`, and preserve the central equivalence:

```text
submit operation(callback)
```

is represented to a Task as:

```text
result = yield operation parameters
-- the callback resumes this continuation with its parameters
```

One refinement matters when extending the implementation: a `Call` variant is
a **Task suspension boundary**, not mechanically one C function or callback
registration. A one-shot request normally has a variant whose dispatcher
submits that request. A persistent callback source may be initialized and
started synchronously; its variants consume buffered events, install a waiter,
or await close. A synchronous libuv function needs no variant, callback owner,
or source-defined foreign callback.

## Start from the pinned source and compatibility floor

`Makefile` is authoritative for both libuv versions:

- `LIBUV_VERSION` selects the audited bundled source, currently 1.52.1; and
- `LIBUV_MIN_VERSION` is the oldest accepted system libuv, currently 1.43.0.

Run `make LIBUV_MODE=bundled libuv`, then read the prospective function in both
`libuv-v1.52.1/include/uv.h` and its chapter under
`libuv-v1.52.1/docs/src/`. The header gives the exact callback typedef and
native ownership surface. Determine the callback cardinality and thread,
submission-failure rule, borrowed-argument interval, result ownership, cleanup
requirement, stop/close behavior, and version-added note. Start with the prose
documentation; where it is silent, inspect the pinned Linux and macOS source
and tests rather than guessing or consulting an arbitrary installed version.

A function newer than the system minimum cannot be called unconditionally
while the current system-mode policy remains. Either use an API available at
the minimum or deliberately raise that minimum and validate both bundled and
system modes. Do not hide an unavailable symbol behind a forwarding shim or a
run-time identity trick.

The supported targets are Linux and macOS. Prefer the public portable libuv
operation to a POSIX alternative. A restricted Titan `foreign function` is the ordinary boundary for a callback
ABI. Hand-written C requires an exceptional gap that neither the imported FFI
nor that raw-C surface can express, such as a function-like macro or a
compile-time portability fact, and its justification must appear in a comment
immediately above the C definition.
Ordinary public struct fields are handled directly through Titan's FFI. When a
native ABI spells borrowed bytes as mutable but promises not to mutate them,
Titan's direct `string`-to-`char *` conversion can initialize the field. For an
asynchronous borrow, the Titan owner must retain the original string through
the terminal callback; this internal lifetime proof does not relax the public
FFI rule against C retaining an otherwise unanchored string pointer.

## Classify the addition before adding state

| Native operation | `Call` variant | Owner | Source foreign entry |
| --- | --- | --- | --- |
| Synchronous function without a callback | No | No persistent owner; automatic storage unless the documented call retains a pointer | No |
| Synchronous function that calls back into Titan before returning | One boundary variant when the callback must not enter a running Task coroutine | One callback owner for the call | Reuse or define the exact protocol |
| One-shot request whose result suspends a Task | One submission variant | One request owner, normally rooted by `Task.pending` | Reuse or define the exact protocol |
| One-shot callback on a newly initialized handle | Usually one submission variant | One rooted handle owner, followed by `uv_close` | Reuse or define the exact protocol |
| Persistent multi-shot callback source | Wait/consume and close variants; start need not be a variant | One rooted handle owner with natural buffered state and one waiter | One exact entry per callback protocol |
| New `uv_handle_t` subtype | As required by its logical operations | One rooted wrapper for the initialized handle | As required by its callbacks |

This classification prevents the old design from growing back. Do not add a
control hierarchy, operation registry, scheduler queue, generation fence,
join protocol, or event-kind dispatcher around a direct libuv contract.

## Trace the whole path before editing

A user-facing addition normally crosses these layers:

```text
public async/fs/net/os/timer/io operation
    -> private titan.uv convenience function
    -> await(Call.variant(payload)) when the Task must suspend
    -> payload:dispatch(Task)
    -> direct uv_* submission
    -> exact source-defined foreign callback
    -> exact ordinary Titan callback handler
    -> buffer persistent state or resume_task_from_callback
```

Purely synchronous convenience functions stop before `await`: validate their
ordinary Titan arguments, call the public `uv_*` function through `foreign
import "uv.h"`, translate a negative status, and return an ordinary Titan
value. Translate a negative status when the API returns one; otherwise
interpret its documented value or void result. Do not add an empty `Call`
variant merely to make the path look like an asynchronous one.

`uv_walk` is the unusual synchronous callback-taking example. Runtime cleanup
yields `CleanupStepCall` first, so the dispatcher invokes `uv_walk` while the
cleanup coroutine is suspended. Its synchronous walk callback selects one
handle; the same dispatch then submits `uv_close`. Do not confuse “synchronous
return” with “no callback boundary.”

Put a new payload record and its dispatch method in the contributor that owns
the operation. Add only the variant and routing arm to `task.titan`. The folder
module shares one namespace, so no helper submodule or exported FFI type is
needed. If a new contributor file is genuinely clearer, add it to
`UV_TITAN_SOURCES` in `Makefile`; folder membership is explicit for the
standard-library build.

Keep the one existing `UV_TAG`. The union payload says which operation was
yielded; adding a second coroutine tag would split one runtime protocol into
unnecessary identities.

## Add an exact source foreign callback when needed

Ordinary libuv functions are called directly from Titan. Never add a C
function whose only job is to forward the same arguments to `uv_*`.

An ordinary Titan closure is not a C function pointer. When a new callback
protocol is needed, define one restricted `foreign function` in the semantic
`titan.uv` contributor that owns it and pass that declaration directly to
libuv. Reuse an existing source callback only when the libuv callback typedef,
owner lookup, loop lookup, callback slot, and Titan handler signature are the
same protocol. Similar parameter counts are not enough. Connect, write, and
shutdown therefore remain separately named even though each native callback
receives a request and status.

Every callback follows the reviewed sequence:

1. recover the owner through the protocol's documented channel, usually
   `uv_req_get_data` or `uv_handle_get_data`, or the explicit `uv_walk`
   argument;
2. recover the main Lua state from the loop;
3. recover the exact stored Titan callback closure, module, and native entry;
4. save the Lua stack top and push the **owner** as full userdata;
5. invoke the exact native Titan entry with its original closure as `_fn`; and
6. restore the stack top before returning to libuv.

Keep filesystem's owner-only Titan protocol: the continuation reads
`uv_fs_get_result` itself. Do not add an event-kind dispatcher, callback
registry, or generic status convention. `foreign function` bodies are trusted
raw C, so their pointer operations and Lua API use receive no implicit Titan
checks or unwind frame. The ordinary Titan handler they enter must contain every
error and return normally; otherwise the saved-stack restoration would be
skipped and a Lua longjmp would escape through libuv.

The compiler-generated `titan/uv/uv.titan.h` includes `uv.h`, the narrow typed
`titan/ffi.h` bridges, and prototypes for all callbacks. It is a source build
intermediate; do not install or hand-edit it. `titan-runtime/libtitan.a` has no
libuv callback object.

## Adding a single-shot callback operation

Use filesystem requests in `file.titan` as the general template,
`uv_getaddrinfo_t` in `tcp.titan` as the borrowed-result template, and
`SignalWaitCall` in `os.titan` as the one-shot-handle template.

### 1. Record the suspension parameters

The payload is only the ordinary input bundle. The current DNS path is an
exact example:

```titan
local record GetaddrinfoCall
  local node: string
  local service: string
end
```

Add the corresponding `Call` variant and one `dispatch_call` case. Keep
validation that can raise before the yield in the private convenience
function. This avoids creating native state for a rejected argument.

If the callback is installed while creating an object that returns
synchronously, a variant for the registration itself may be wrong. `uv_spawn`
installs the process exit callback while returning a Process; the later
`process_wait` variant either consumes the cached exit result or installs one
waiter. The variant belongs to the suspension point, not to `uv_spawn` merely
because its options contain a callback. Its separate
`process_spawn_failure` variant exists only because a failed spawn must run a
synchronous `uv_walk` while the Task is suspended and may then await
`uv_close`; it does not wrap the successful spawn path.

### 2. Allocate the smallest terminal owner

A one-shot request owner contains stable native request storage, its callback,
and only the values libuv still borrows. A closure already retains captured
Titan values, so do not duplicate them in rooting or control fields.
The current DNS owner is:

```titan
local record uv_getaddrinfo_t
  local native: owned *libuv.uv_getaddrinfo_t
  local callback: (uv_getaddrinfo_t, integer,
                   ffi.titan_ffi_void_ptr) -> ()
end
```

Stream and filesystem writes assign immutable strings directly to
`uv_buf_t.base` and retain those original strings while libuv borrows their
payload; libuv copies only the descriptors during submission. Filesystem paths
and DNS text are copied during accepted
submission, so they need no separate owner field afterward. Derive each
interval from the pinned libuv contract; do not generalize one operation's
borrowing rule to another.

Set request data to the owner and assign `task.pending = owner` before libuv
accepts ownership. The Task root is the request's lifetime root until callback
entry; the native context helper then stack-roots the owner while
`resume_task_from_callback` clears `task.pending`. Do not add the request to
the Runtime handle-root set: requests are not handles and `uv_walk` does not
enumerate them.

### 3. Submit once and handle the two outcomes

The dispatch method may do direct synchronous preparation before the one
callback-taking call. Allocate every owner field and build the callback closure
before submission. Then:

- a documented negative submission result means no terminal callback will
  arrive; clear `task.pending`, perform any request-specific cleanup, and
  return an `Immediate` error; or
- an accepted submission returns `nil` from `dispatch`, immediately returning
  control through the current callback to libuv.

Do not resume the Task recursively on rejection and never call `uv_run` from a
dispatcher. `advance_task` can inject an `Immediate` failure and let the same
continuation yield its next operation without event-loop reentry.

Some callback-bearing calls do not return a status. Follow their documented
acceptance rule rather than inventing a status or defensive state. Conversely,
an initialized handle whose later start call fails must be closed
asynchronously; it cannot simply be unrooted like a request that libuv never
accepted.

### 4. Finish ownership before it can be lost

Finish native ownership work before a callback-only resource can be lost or a
continuation can observe an invalid result:

- extract scalar results;
- copy any result memory borrowed only through the callback;
- release a libuv-owned result such as an address chain;
- call a required cleanup function such as `uv_fs_req_cleanup` exactly once;
- dispose of a newly produced descriptor or handle in the callback when no
  continuation owner has received it; and
- only then resume the suspended Task with an ordinary Titan value or
  `async.OperationError`.

Use `catch`/`finally` when release must happen after either successful
conversion or a Titan allocation error. A continuation `finally` is also the
right owner when the resource has already been transferred there, as in TCP
connect cancellation. Wrap the whole handler with
`fail_task_at_callback_boundary` so a conversion or continuation error retires
only the affected Task.

Accepted request storage remains alive until this callback even after logical
cancellation. Do not drop its root, race it with a GC finalizer, or call
`uv_cancel` merely to make the Task look cancelled sooner. `Task:cancel`
privately stores the first reason while the public status remains in its current
live variant. Cancellation is injected when the callback eventually resumes
the continuation, and only terminal `TaskStatus.cancelled(reason)` publishes
the reason.

A one-shot handle differs from an accepted request because closing it can
suppress its event callback. `SignalWaitCall` therefore installs a cancellation
action that calls `close_handle`; the resulting `close_cb` schedules the
continuation through the ordinary callback-deferred one-shot wake. On a real
signal, the signal callback also starts close and resumes only after close
completion. This close
operation is cancellation-insensitive: once issued, cancellation cannot
suppress the callback that releases its native owner. Do not apply the request
rule of waiting for its terminal operation callback to a handle whose close
replaces that callback.

### 5. Verify the one-shot lifecycle

Cover the applicable public lifecycle, not a stock fault-injection matrix:

- success and a synchronous submission rejection when the API has one;
- cancellation after accepted submission;
- disposal of an abandoned resource-producing success when the callback alone
  receives it; and
- the operation's documented cleanup and borrowed-value lifetime.

Add a callback conversion/allocation-failure or full/generational-GC case only
when the binding introduces a new conversion, cleanup, or rooting shape that
existing generic proofs do not cover. Do not add test-only module hooks or
source transformers solely to force such a case.

Keep standard-library behavior tests outside LuaCov. Add a small covered
compiler/FFI test only when a new declaration shape exposes a compiler path
that the language tests did not already exercise.

## Adding a multi-shot callback operation

A multi-shot source belongs to a persistent handle owner, not to a sequence of
request owners. Repeating timers, TCP reads, listeners, and process stdio show
the existing patterns.

### 1. Choose the event semantics first

The buffer is a public-semantics decision, not generic scheduler machinery:

- use one pending bit or latest value when events may legitimately coalesce;
- buffer distinct values only when the high-level API promises that every
  delivered value remains observable;
- keep sticky EOF or error state for a terminal stream; and
- keep exactly one suspended low-level waiter; multiplexing belongs in a
  higher-level library when its public API promises it.

A repeating timer therefore needs a fired bit and one waiter. A stream needs
its callback-paired native buffer, queued chunks, terminal state, and one
reader. A listener needs accepted clients and one accept waiter. These are
natural callback results, not a ready queue or duplicate of libuv's operation
ordering.

Use a union when one handle has disjoint roles. `TcpRole` separates connection
read state from server accept state instead of accumulating optional fields on
one record.

### 2. Build one persistent owner

The owner contains:

- stable owned FFI handle storage;
- callback closures at the exact fields read by the source foreign entries;
- its Runtime and root index;
- one waiter;
- the minimal buffered or terminal state above; and
- callback-paired storage such as a stream allocation buffer.

Root it in `Runtime.handle_roots` before `uv_*_init`, because successful init
links the native handle into the loop and makes later `uv_close` mandatory.
Follow the new-handle failure recipe below rather than assuming every future
initializer has the same partial-failure contract. After successful init, set
the handle's data pointer to the owner.

Start the watcher during construction or lazily on the first wait. Stop and
restart it only if the public semantics require distinct active intervals;
never re-register it merely for each waiter or event. A start operation that
only registers a persistent callback does not need its own `Call` variant
unless starting itself is the Task's asynchronous suspension boundary.

### 3. Separate callback production from Task consumption

The callback first copies or converts its result. It then clears and takes the
current waiter **before** delivering it. An ordinary operation callback resumes
the Task directly. A boundary whose semantics require callback-deferred
delivery, notably close completion and the repeating-ticker continuation, may
instead use the existing Task-owned zero-timer wake. Every such one-shot timer
closes
in `timer_cb` and resumes its Task only from `close_cb`. The continuation may
install the next waiter while the producing callback is still returning, and
the non-reentrant loop guarantees no unrelated libuv callback interleaves.

If there is no waiter, buffer the natural result or update the pending state.
A callback can also fail with no waiter, so the owner must retain a terminal
error or terminalize and log it; it cannot assume a Task is present.

The wait variant's dispatcher runs the inverse order:

1. return an already buffered result or sticky terminal state immediately;
2. reject a second waiter;
3. start the native watcher if it is lazy, using an operation-specific query
   or the start function's documented already-started result; and
4. install the Task plus its cancellation action, then return to libuv.

For streams, preserve libuv's alloc/read pairing. The alloc callback stores
the exact buffer on the owner. If Titan allocation fails, it returns the zero
buffer required to reach the paired read callback and transports the original
exception there. This is a stream-specific exception bridge, not a generic
fallback and not distrust of libuv's callback ordering.

### 4. Detach waiters without closing shared state

Cancelling one wait privately records the reason and detaches only that Task.
Wake it through the Task-owned zero-timer path, so that timer closes and its
close callback delivers cancellation rather than resuming it synchronously
inside another Task. Do not close a shared watcher because one waiter was
cancelled. Cleanup and close `Call` variants must be cancellation-insensitive
when their callbacks own native lifetime completion.

Explicit close uses libuv's active/closing queries, stops the watcher where
the API requires it, settles any waiter on a later callback turn, clears
buffered results that the public close discards, and transfers lifetime to the
common asynchronous `close_handle` path. Do not add a close-waiter queue.

Libuv already orders one-shot stream writes. Keep one `uv_write_t` owner per
write and let libuv provide that queue; the persistent read buffer is not a
reason to mirror write ordering in Titan.

### 5. Verify the multi-shot lifecycle

Cover the applicable public lifecycle:

- an event buffered before a waiter and an event delivered to a waiter;
- two or more distinct events when the API promises buffering;
- rejection of a second waiter;
- callback-deferred cancellation without closing the shared handle;
- terminal EOF/error and an error that arrives without a waiter for sources
  that have terminal callbacks;
- explicit close while a Task is waiting;
- Runtime shutdown through `uv_walk`; and
- any new callback/buffer rooting shape not already covered by the generic GC
  proofs.

Do not recreate a scheduler queue, generation fence, delayed-source variant,
or reentrant `uv_run`; those abstractions are absent from this design. The
public Task terminal-registration Array is the one intentional observation
primitive. Each addition returns an idempotent remover for its fresh
registration. Terminal publication stores the final status, detaches the
current Array as a stable snapshot, installs an empty live list, and clears
snapshot ownership before calling every listener sequentially on the main
thread with each call protected by an empty `catch`. A remover called during
delivery therefore cannot shift the snapshot or skip a later callback. This is
Task-local notification, not a scheduler-owned join protocol or native
operation queue.

The public `async.join*`, `any_*`, `race_*`, and `all_*` functions first scan
their fixed named operands. If the result is not yet decided, they install a
separate listener closure directly on each still-relevant operand, suspend the
current Task once, and let the captured result/counter state decide when to
call `Task:resume()`. Each registration has a deferred remover call so external
cancellation of the suspended combinator cannot leave a stale listener. Do not
collect operands into a `{Task}` helper: keeping each named path expanded
preserves the heterogeneous generic result and cancellation type of every
position.

`Task:resume()` is synchronous from either terminal notification or another
running Task. It coalesces requests and installs a target-owned zero-duration
timer; `timer_cb` initiates close and `close_cb` resumes the target after
releasing the timer owner. The same wake handles cancellation of an explicitly
suspended Task. There is no public Waiter, `uv_check_t`, Runtime `uv_idle_t`,
polling loop, phase fence, or Task Array in this composition. Do not add
test-only module hooks or source transformers merely to run the same ownership
proof through another handle type.

## Adding a new handle type

A new handle type normally combines the preceding lifecycle with one-shot or
multi-shot operations. `SignalWaitCall` is the smallest one-shot/new-handle
example. `new_tcp` plus `TcpRole` is the persistent multi-shot example.

### 1. Keep the FFI handle private

An FFI type cannot appear in an exported module interface. Define one ordinary
Titan wrapper that owns `*libuv.uv_X_t` locally, plus only its callbacks,
Runtime identity, root index, and inherent persistent state. Public facades
hold the wrapper as an opaque `uv` record and expose ordinary Titan records,
unions, Interfaces, strings, numbers, and options.

For a stream subtype, add small local conversions to `*libuv.uv_stream_t` and
`*libuv.uv_handle_t`. For another handle, add only the handle conversion.
Centralizing casts makes generic close and state calls visible without a
parallel kind tag.

### 2. Follow init ownership exactly

The normal order is:

1. allocate every Titan and owned FFI field;
2. root the wrapper in `handle_roots`;
3. call `uv_X_init`;
4. on init failure, apply that API's verified ownership contract;
5. on success, install the wrapper with `uv_handle_set_data`; and
6. configure or start the handle.

For the currently audited simple initializers, failure leaves no live loop
handle, so step 4 clears the root directly. Verify that guarantee for a new API
in the pinned supported-platform source; do not generalize it to a combined or
partially successful initializer. If step 6 fails, use `close_handle`.
Successful init made the loop
authoritative, so dropping Titan's root would leave libuv with dangling native
storage. `close_handle` replaces the handle data with a small close owner whose
closure retains the original wrapper until `close_cb`.

`uv_spawn` is an unusual combined init/start operation whose failure can leave
different native ownership on supported platforms. Its existing path checks
actual loop membership through `ProcessSpawnFailureCall`, with the spawning
Task suspended during the synchronous `uv_walk`, and either closes or
unroots. Do not copy that exception to ordinary init/start APIs without the
same source-grounded platform reason.

### 3. Trust libuv state and shutdown discovery

Use `uv_is_active`, `uv_is_closing`, and handle-specific queries instead of
mirroring the native facts they actually report. `uv_is_active` is a broad
handle predicate, not a query for a particular watcher: a stream can be active
because it is reading, writing, connecting, or listening. Use an
operation-specific query when libuv provides one, or rely on the operation's
documented idempotent/already-started result. Add Titan state only for a
high-level semantic fact libuv does not store, such as a buffered result or
current waiter.

No Runtime registry or linked list is needed. Every successfully initialized
handle is already discoverable through the loop; final cleanup's `uv_walk`
will close the new type automatically. The Runtime root table only keeps the
wrapper alive for C callbacks and is never traversed as a resource inventory.

Remember that `uv_file` is an operating-system descriptor, not a handle. The
high-level File facade stores that raw scalar; each new filesystem operation
copies it into a request owner for the accepted callback lifetime. It does not
join handle shutdown.

### 4. Let operations choose their own shapes

A handle may need both patterns. A future UDP binding, for example, would
naturally have one persistent `uv_udp_t` receive owner with an exact receive
callback and buffered datagrams, plus one one-shot request owner per send.
UDP is not a `uv_stream_t`; do not force it through TCP alloc/read/write
assumptions merely because both carry network bytes.

Keep separate records when operations have genuinely different native
requests, result ownership, or cleanup. Small duplicate-looking request
records are cheaper and clearer than rebuilding a common control hierarchy.

## Testing additions without rewriting the binding

Default to black-box tests against the canonical production modules. Put
module-owned Titan behavior under `spec/stdlib/titan/`, run it through the
unified native executable and `support.runtime`, and exercise the public
`async`, `timer`, `fs`, `net`, `io`, or `os` facade. When process-start state
matters, let the compiled Titan parent launch a focused standalone child through
C99 `system`; have the child report through a temporary result file that the
parent removes with `defer`. There are no Lua files under `spec/stdlib/` and
these behavior tests stay outside LuaCov. A refactor that preserves the public
and native ownership contracts should not require test edits.

Do not make a test depend on the source text of `titan/uv/*.titan`: do not find
an anchor, splice in an extension or probe, rebuild a patched uv provider, or
assert implementation text. The continuation redesign deliberately removed
the old delayed-callback source transformers and their variant-workspace
machinery. New bindings must not recreate that test architecture merely to
repeat a generic cancellation, cleanup, or GC proof.

Choose the narrowest observable boundary:

- use public behavior for success, errors, cancellation, buffering, close, and
  shutdown;
- use a standalone native fixture or interposer when the host must produce a
  specific portable libuv condition, keeping it outside the installed module;
- add a focused compiler/FFI spec only when a new declaration or callback
  shape exercises compiler behavior rather than library behavior; and
- reuse existing rooting and callback-boundary proofs when the new owner has
  the same ownership shape.

If a native lifetime boundary truly cannot be reached through public behavior
or a standalone fixture, stop and align with the maintainer before introducing
an instrumented provider. A source-text transformer is a last-resort design
exception: its test must document the otherwise unreachable invariant and why
less coupled observation is impossible. It must never add hooks to installed
modules or become a general scheduler/fault-injection interface.

The standard-library suite currently has no source-transformer or
interposition-only exception. Coroutine transfer mechanics and checked Lua API
use rely on their existing compiler/native-harness ownership, while native
library tests retain the observable Lua-host GC and API-error behavior. Do not
recreate the removed implementation-level variants as templates for a new
libuv binding.

### Mechanical integration gates

Adding an operation also changes a small amount of reviewed inventory. Update
only the entries that the new binding actually introduces:

- `UV_TITAN_SOURCES` in the Makefile when a new contributor file is added;
- `UV_FOREIGN_CALLBACKS` in `spec/libuv_build_spec.lua` when a new source
  foreign entry or its exact owner/closure protocol is added; and
- `DIRECT_LIBUV_CALLS` there when the generated provider must be proved to
  call a new public libuv function directly.

Those inventories prove both source shape and compiled-symbol ownership: every
reviewed foreign callback must be declared in the expected contributor, use the
expected owner field and exact native entry, appear as a definition in the one
generated `titan.uv` object, and leave no reference to a retired shim. Keep them
aligned with the real callback protocol rather than inferring correctness from
parameter count alone.

After rebuilding the canonical eighteen-root provider, mechanically extract
its exact serialized interface and compare it with
`spec/fixtures/libuv/titan_uv_types.lua`:

```sh
TITAN_UV_PROVIDER="$PREFIX/lib/titan/0.24/titan.so" \
"$PREFIX/bin/lua" -e '
local support = require "titan"
local types = assert(support._loadlib(
    assert(os.getenv("TITAN_UV_PROVIDER")), "titan_uv_types"))
io.write(assert(types()))
' > /tmp/titan_uv_types.raw
wc -c /tmp/titan_uv_types.raw
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum /tmp/titan_uv_types.raw
else
  shasum -a 256 /tmp/titan_uv_types.raw
fi
```

Refresh the fixture payload, byte count, and digest together when the
interface changed. The fixture is derived from the linked provider's exported
`*_types` function; it must not be synthesized by parsing or rewriting the uv
sources. Refresh the corresponding entry in
`spec/fixtures/stdlib/titan_stdlib_types.lua` only if a high-level facade's
interface changed as well.

Run the focused build and behavior gates first. Build the aggregate native
suite once, select `net.tests` and `ssl.tests` in separate fresh processes, and
then run the complete uncovered stdlib surface:

```sh
busted spec/libuv_build_spec.lua
make titan-stdlib-test-build
make titan-stdlib-test-run TITAN_FILTER='^uv[.]task_tests[.]'
make titan-stdlib-test-run TITAN_FILTER='^uv[.]runtime_tests[.]'
make titan-stdlib-test-run TITAN_FILTER='^net[.]tests[.]'
make titan-stdlib-test-run TITAN_FILTER='^ssl[.]tests[.]'
make stdlib-busted-test
make titan-stdlib-test-run
```

The final two commands complete the uncovered stdlib gate without rebuilding
the native executable; `make stdlib-test` performs the complete gate from
scratch. A `TITAN_FILTER` selects cases at run time; it does not rebuild or
narrow the 22-root executable.

The real installation path and both link policies remain release boundaries:

```sh
"$PREFIX/bin/luarocks" make titan-dev-1.rockspec
PREFIX="$PREFIX" bash spec/support/ci_libuv_mode_smoke.sh both
```

The `both` invocation deliberately republishes the isolated prefix in
system-libuv mode after checking bundled mode. Use a throwaway absolute prefix,
not a developer installation that must remain bundled. Pass `bundled` instead
for a quicker check that leaves the prefix unchanged.

## Review checklist

Before committing an extension, verify all of these claims from the pinned
header, docs, implementation, and tests:

- the public facade needs the operation and does not expose an FFI type;
- the function exists at the system-version floor or that floor is deliberately
  raised;
- the operation is correctly classified as synchronous, one-shot, or
  persistent multi-shot;
- one-shot submission rejection cannot later call its callback;
- every borrowed argument and result has an explicit rooted interval;
- request cleanup and native-result release happen exactly once;
- every callback enters Titan only on the loop thread and catches before
  returning through libuv;
- callback closure fields agree between the Titan owner and source foreign body;
- initialized handles remain rooted until `close_cb` and need no registry;
- cancellation does not release accepted native work early or synchronously
  resume another Task;
- when a callback resumes a Task, `advance_task` may consume several
  `Immediate` outcomes but returns after the next accepted callback-bearing
  submission or Task termination, without calling `uv_run`;
- high-level behavior tests run outside LuaCov; and
- bundled and system-libuv production modes remain valid.

## API coverage snapshot

This is **binding breadth**, not line, branch, or behavioral-test coverage.
Importing `uv.h` makes a declaration available to the FFI parser but does not
count as covering it. A function counts only when production `titan.uv`
actually references that public entry point. One function name counts once even
when Titan uses several modes or call sites. Callback typedefs, types, constants,
macros, and `uv__*` internals do not count.

Against bundled libuv 1.52.1:

| Metric | Covered | Total | Coverage |
| --- | ---: | ---: | ---: |
| Concrete handle types | 6 | 14 | 42.9% |
| Public `UV_EXTERN uv_*` functions | 75 | 318 | 23.6% |

The concrete handle denominator is `UV_HANDLE_TYPE_MAP`'s 16 entries minus
the abstract `uv_handle_t` and `uv_stream_t`. Titan owns wrappers for named
pipe, process, signal, TCP, timer, and TTY. `UV_FILE` is outside the map and is
not a handle. Neither `uv_loop_t`, `uv_dir_t`, nor any request
type belongs in the handle denominator. If the two abstract base entries are
mechanically included, Titan uses 8 of 16 map entries, or 50.0%; the concrete
6-of-14 figure is the useful measure of supported handle kinds.
Task composition uses remover-returning terminal registrations and
target-owned timer wakes, so it requires neither callback-identity removal, a
generic Runtime witness, a check-handle wrapper, nor an idle-handle phase
bridge. Runtime-facing Tasks remain the concrete all-`value` application.

The function denominator is the 318 unique public `UV_EXTERN uv_*`
declarations in `include/uv.h`, before host preprocessing. No platform header
adds another `UV_EXTERN` function, so this is stable across Linux and macOS.
It deliberately includes the deprecated `uv_loop_new` and `uv_loop_delete`;
libuv's documentation contains 316 nondeprecated functions, against which the
same numerator is 75 of 316, or 23.7%.

This is name-level breadth. Calling `uv_spawn` does not claim every process
flag or stdio combination, and a zero in the following table does not imply a
design commitment to expose that handle later.

### Per-handle API chapters

For a concrete handle, the denominator is the set of `.. c:function::`
entries in that handle's libuv documentation chapter. This source-grounded
grouping correctly places irregular names such as `uv_spawn`, `uv_pipe`, and
`uv_socketpair`. Generic handle and stream functions are separate rows; do
not add them to every subtype, which would double-count the common API and
give an unsupported subtype artificial nonzero coverage.

| Libuv handle chapter | Wrapped | Used / available | Coverage | Functions used by Titan |
| --- | :---: | ---: | ---: | --- |
| Abstract handle | base | 7 / 15 | 46.7% | `uv_close`, `uv_fileno`, `uv_handle_get_data`, `uv_handle_get_loop`, `uv_handle_set_data`, `uv_is_active`, `uv_is_closing` |
| Abstract stream | base | 8 / 13 | 61.5% | `uv_accept`, `uv_is_writable`, `uv_listen`, `uv_read_start`, `uv_read_stop`, `uv_shutdown`, `uv_stream_set_blocking`, `uv_write` |
| Async | no | 0 / 2 | 0.0% | — |
| Check | no | 0 / 3 | 0.0% | — |
| FS event | no | 0 / 4 | 0.0% | — |
| FS poll | no | 0 / 4 | 0.0% | — |
| Idle | no | 0 / 3 | 0.0% | — |
| Named pipe | yes | 3 / 13 | 23.1% | `uv_pipe`, `uv_pipe_init`, `uv_pipe_open` |
| Poll | no | 0 / 4 | 0.0% | — |
| Prepare | no | 0 / 3 | 0.0% | — |
| Process | yes | 2 / 5 | 40.0% | `uv_process_kill`, `uv_spawn` |
| Signal | yes | 2 / 4 | 50.0% | `uv_signal_init`, `uv_signal_start_oneshot` |
| TCP | yes | 3 / 13 | 23.1% | `uv_tcp_bind`, `uv_tcp_connect`, `uv_tcp_init` |
| Timer | yes | 2 / 7 | 28.6% | `uv_timer_init`, `uv_timer_start` |
| TTY | yes | 1 / 6 | 16.7% | `uv_tty_init` |
| UDP | no | 0 / 23 | 0.0% | — |

The concrete-handle chapters contain 94 functions in total, of which Titan
uses 13 (13.8%). Together with seven abstract-handle and eight abstract-stream
functions, 28 of Titan's 75 referenced functions are in handle-related
chapters. The other 47 cover the loop, requests, filesystem, DNS, errors,
version, and OS/miscellaneous helpers.

### Reproducing the snapshot

Run this Bash fragment from the repository root after
`make LIBUV_MODE=bundled libuv`. It derives the pinned source directory,
intersects public names with production references, discovers concrete owner
candidates, and prints every per-chapter ratio:

```bash
version=$(sed -nE \
  's/^LIBUV_VERSION[[:space:]]*:=[[:space:]]*//p' Makefile)
uvdir="libuv-v$version"

public_functions() {
  rg --pcre2 -o --no-filename \
    '^UV_EXTERN[^;(]*\Kuv_[a-z0-9_]+(?=[[:space:]]*\()' \
    "$uvdir/include/uv.h" |
    sort -u
}

documented_functions() {
  rg --pcre2 -o --no-filename \
    '^\.\. c:function::.*?\Kuv_[a-z0-9_]+(?=[[:space:]]*\()' \
    "$uvdir"/docs/src/*.rst |
    sort -u
}

production_titan_sources() {
  sed -n '/^UV_TITAN_SOURCES :=/,/^[^[:space:]]/p' Makefile |
    rg -o 'titan/uv/[a-z_]+\.titan'
}

used_candidates() {
  {
    while IFS= read -r source; do
      rg -o --no-filename 'libuv\.uv_[a-z0-9_]+' "$source"
    done < <(production_titan_sources) |
      sed 's/^libuv\.//'
  } |
    sort -u
}

used_functions() {
  comm -12 <(public_functions) <(used_candidates)
}

concrete_handles() {
  sed -n '/^#define UV_HANDLE_TYPE_MAP/,/^$/p' \
      "$uvdir/include/uv.h" |
    rg --pcre2 -o 'XX\([^,]+,[[:space:]]*\K[a-z_]+' |
    grep -Ev '^(handle|stream)$' |
    sort -u
}

wrapped_candidates() {
  while IFS= read -r source; do
    rg -o --no-filename \
      'owned[[:space:]]+\*libuv\.uv_[a-z_]+_t' "$source"
  done < <(production_titan_sources) |
    sed -E \
      's/^owned[[:space:]]+\*libuv\.uv_//; s/_t$//' |
    sort -u
}

wrapped_handles() {
  comm -12 <(concrete_handles) <(wrapped_candidates)
}

public_count=$(public_functions | wc -l)
public_lines=$(rg -c '^UV_EXTERN' "$uvdir/include/uv.h")
if [ "$public_count" -ne "$public_lines" ]; then
  echo "public-function parser no longer matches each UV_EXTERN line" >&2
  exit 1
fi

printf 'version=%s public=%s documented=%s used=%s concrete=%s wrapped=%s\n' \
  "$version" \
  "$public_count" \
  "$(documented_functions | wc -l)" \
  "$(used_functions | wc -l)" \
  "$(concrete_handles | wc -l)" \
  "$(wrapped_handles | wc -l)"

printf 'header-only: '
comm -23 <(public_functions) <(documented_functions) | paste -sd, -

printf 'wrapped: '
wrapped_handles | paste -sd, -

for page in \
  handle stream async check fs_event fs_poll idle pipe poll prepare \
  process signal tcp timer tty udp
do
  page_functions() {
    rg --pcre2 -o --no-filename \
      '^\.\. c:function::.*?\Kuv_[a-z0-9_]+(?=[[:space:]]*\()' \
      "$uvdir/docs/src/$page.rst" |
      sort -u
  }

  total=$(page_functions | wc -l)
  used=$(comm -12 <(page_functions) <(used_functions) | wc -l)

  awk -v page="$page" -v used="$used" -v total="$total" \
    'BEGIN {
       printf "%-10s %2d/%-2d %5.1f%%\n",
              page, used, total, 100 * used / total
     }'
done
```

The expected headline is:

```text
version=1.52.1 public=318 documented=316 used=75 concrete=14 wrapped=6
header-only: uv_loop_delete,uv_loop_new
wrapped: pipe,process,signal,tcp,timer,tty
```

The function intersection is lexical, and the wrapped list begins as an owned
pointer-type candidate list. Inspect changed names before updating the table:
exclude a function mentioned only in a comment, and count a handle only when
Titan really owns its persistent wrapper rather than merely using owned
storage for a transient request or value. The source extractor deliberately
uses `UV_TITAN_SOURCES`, not every file in the directory. The current 75
function references and six wrappers have been checked manually.

Refresh this section whenever `LIBUV_VERSION` changes or production
`titan.uv` starts or stops referencing a public libuv function, or a concrete
handle wrapper is added or removed. On a libuv bump, also confirm that each
public function name remains on its `UV_EXTERN` line; the script fails if the
line and extracted-name counts diverge. An arbitrary system installation is
not a stable denominator; the pinned bundled source is the review baseline.
