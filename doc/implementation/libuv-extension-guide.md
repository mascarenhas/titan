# Extending the public libuv binding and async adapters

The layers have separate ownership. `titan.uv` exposes native operations through
public Titan owners and callbacks. `titan.async` turns callback completion into
Task continuation through generic waits. Timer, filesystem, network, process,
and database modules own their domain policies and acquired resources. Read the
[public UV reference](../language/standard-library-uv.md) for API contracts and
the [async runtime chapter](libuv-runtime.md) for scheduling and shutdown.

An ordinary library author can add an adapter with compiled imports of `uv` and
`async`. No `uv.titan` source import, per-operation scheduler variant, private
Task field, or compiler change is needed. Extend the UV implementation only when
the native operation itself lacks a suitable public binding.

## Start from the pinned native contract

Titan always builds the pinned, patched libuv 1.53.0 source. Check its header,
upstream documentation, and supported-platform implementations for the exact
lifecycle. The checked-in [native patch](../../vendor/libuv/README.md) repairs
failed Unix spawn close ownership. An unpatched system library or its version
number is not a substitute for this dependency.

For every proposed operation, determine:

- whether it is synchronous, an accepted one-shot request, or persistent;
- whether callbacks can be inline, repeated, cancelled, or omitted on rejection;
- which inputs are copied and which remain borrowed, and for how long;
- which result storage must be copied before native cleanup;
- whether rejection leaves initialized state or separately acquired resources;
- the native result/status channels, units, ranges, nullable arguments and
  platform restrictions; and
- whether it is safe on the Lua thread or is a C-only worker/thread entry.

Use the [complete native coverage map](../language/uv/coverage.md) to update a
specific disposition rather than reporting only a new wrapper count. Keep the
native function, nonfunction, field, callback, constant and macro inventories
consistent with the public declaration. Intentional omissions need individual
ownership explanations.

## Public native owners

A concrete owner contains its final native storage as private fields and the
Titan references needed by its native lifetime. Construct it before calling
native init: moving or copying initialized libuv state is invalid. Public
`handle_t`, `stream_t`, and `req_t` values are typed views that retain that exact
concrete owner, not second native objects. Keep native layouts and `uv.h` types
out of public signatures; use public records, copied values, and portable C-only
function types where the worker boundary requires them.

UV roots initialized handles and accepted requests in their owning `loop_t`.
These roots retain callback closures and borrowed input owners independently of
the caller's suspended stack. Data getters/setters provide a separate traced
Titan `value`; native `.data` remains reserved for callback owner recovery.
Public data must never overwrite that private association.

The concrete `fs_t`, `work_t`, `getaddrinfo_t`, `connect_t`, `write_t`, and
`shutdown_t` data methods directly read or assign that owner's existing
`userdata` field. They share its ordinary tracing and write barrier with the
generic `req_t` methods; no extra slot, request view, or native ownership state
is introduced. Named callbacks can recover their context through the concrete
owner they already receive. Clearing public data never retires pending native
work.

On terminal completion, the bridge retires the old registration before calling
user code while keeping the old owner, callback and borrowed graph rooted
through the complete callback frame. This permits legal callback-time reuse
without allowing the new operation to overwrite storage still needed by the
old native invocation. Close completion similarly retires the old handle
lifetime before a supported reinitialization.

The concrete timer helpers avoid constructing generic handle views for scheduler
data and close. `timer_close` stores an ordinary `timer_cb` separately from the
generic close callback. The terminal handler snapshots and clears both callback
slots before dispatch; typed close passes the existing owner directly, while
generic close retains its existing `handle_t` callback contract. A named exact
`timer_cb` therefore needs neither a forwarding closure nor a union view.

`write_string` stores one `uv_buf_t` inside `write_t` and retains the immutable
string in a separate traced field. It shares the allocation-free
`buf_check_length` check with `buf_init` before acceptance; an adapter may call
that check earlier when its contract validates inputs before async admission.
The foreign write callback pushes the old string onto its Lua
stack before calling the protected Titan handler, alongside the existing vector
owner and descriptor roots. The handler clears the old string field before
calling user code. Consequently callback-time scalar/vector request reuse cannot
erase the old native frame's byte root, including when user code raises after
submitting its successor. Immediate native rejection clears the attempted string
registration. Concrete write data methods read/write the existing public slot;
they do not construct `req_t` views or expose native `.data`.

Init and rejection rules belong to each native API. A simple failed initializer
usually establishes no lifetime, but partial poll initialization can leave a
closeable owner. Native spawn handoff always establishes process-handle close
ownership even when it returns a negative status. Filesystem rejection can
leave request memory needing cleanup. Check explicit owner state where the
public contract provides it; never infer all ownership from a negative result.

## Foreign callback boundary

The UV source ensemble owns the actual libuv callbacks. Restricted foreign
functions recover the final nominal owner, its owning main Lua state, and the
exact callable entry using the existing typed FFI bridges. Owner recovery uses
compiler-owned nominal field information; do not hard-code uservalue indices.
The callback frame pins values that can be unrooted or replaced by user code,
saves/restores the Lua stack top, and calls an ordinary Titan handler whose
catch boundary contains every fallible operation before native return.

The loop boundary preserves the first error and traceback, counts subsequent
callback failures, requests native stop, and rethrows only after the native call
returns. No Lua exception may unwind through libuv. `uv.run` owns the ordinary
asynchronous boundary; synchronous `walk` and Windows inline TTY read/mode
callbacks have explicit corresponding boundaries. Native alloc callbacks must
return the required buffer shape and preserve any failure for their paired
read/receive handling; they cannot throw through C.

Only the owning main Lua thread drives callbacks. C-only worker, thread and
once entries never inspect Titan owners, call Lua/Titan, or use an ordinary
wrapper from a foreign thread. Their raw pointers and code remain externally
valid for the whole native interval; explicit `argument_owner` retains the
associated GC graph when permitted. Native thread detach is unavailable for a
retained GC argument graph, because detach cannot determine its final use.

## One-shot Task adapter

An adapter allocates its request owner and rollback state, then calls one of:

| Wait | Policy |
| --- | --- |
| `async.await_with` / `async.await` | Ordinary operation; pending cancellation skips submission, accepted work finishes before cancellation is delivered. |
| `async.await_cancellable_with` / `async.await_cancellable` | Return the accepted public request view so cancellation can attempt native `uv.cancel`; terminal completion still owns retirement. |
| `async.await_cleanup_with` / `async.await_cleanup` | Ownership retirement proceeds despite pending Task cancellation and during Runtime shutdown. |

The registrar runs outside Task context. Capture Task-only state
before awaiting; use `async.current_loop()` in registration to borrow the active
loop. Prefer a named `_with` registrar taking
`Completion<|Context, Result, Error|>` plus the integer operation number. Every
`_with` registrar returns `uv.req_t?`; ordinary and cleanup may return nil and
never implicitly cancel a returned request. The older facade receives typed
resolve/reject and `fatal(error, traceback)` closures. Inline settlement is valid:
the trampoline resumes the Task only after registration returns.

The Task reuses its Completion storage. Snapshot its exact number and context
at registration, retain them independently through native completion, and pass
the saved number to `context`, `resolve`, `reject`, and `fatal`. Context access
ends at retirement or registration failure. A stale number cannot settle a
successor; stale fatal still reports Runtime failure without treating the
successor's native work as completed. Callback locals or independently owned
rollback state must retain context needed after settlement. An exclusive UV
data slot can carry a per-operation context, but clear its old association
before settlement and never overwrite caller-owned slots. Concurrent requests
need separate owners; no stream-wide completion slot is implied.

Prepare callbacks, view conversions, borrowed-buffer retention, and rollback
before accepting native work. A native rejection with no callback cleans its
request and rejects inline. After acceptance, return normally without allowing
an unrelated exception to abandon the callback owner. There is no implicit
rollback service behind a thrown registration exception.

The terminal callback copies transient results, commits acquired resources to a
lexical/domain owner, performs mandatory native cleanup, and then resolves or
rejects. A descriptor from open belongs to an unpublished File before result
conversion or publication can fail. If cancellation wins delivery, lexical
unwind closes that unpublished descriptor through a cleanup wait.

Unexpected exceptions after the native completion has been consumed need the
operation-local protocol:

```titan
local completed = function (request: uv.fs_t)
  local result = uv.fs_get_result(request)
  uv.fs_req_cleanup(request)
  if result < 0 then reject(result) else resolve(result) end
catch
  uv.fs_req_cleanup(request)
  fatal(error, traceback)
  raise
end
```

This sketch is for a non-resource-producing result. The complete
[File adapter](../language/async-file-example.titan) shows unpublished resource
ownership and preaccept-close restoration. `fatal` is outside typed E and is
legal only outside a running Task after native ownership is safe. It must be
followed by bare rethrow so the outer UV boundary also records the failure.
Never use it to release a still-pending request or as a generic error logger.
The `_with` spelling is `done:fatal(number, error, traceback)` with the captured
number; apply the same protected cleanup/settlement and bare rethrow protocol.

File close demonstrates the acceptance split: consume the published descriptor
before cleanup submission, restore it only when submission was not accepted,
and keep it terminal after accepted completion even if the native close reports
an error. Accepted native work always determines the last borrowed-use boundary.

## Persistent source adapter

Choose the public subscription according to ownership:

- `CoalescingSubscription` keeps only the latest value. Its payload must be
  safely replaceable, because it cannot dispose of an overwritten resource.
- `BufferedSubscription` retains every accepted value in order and can transfer
  an explicit-count batch. Use it for resource-bearing events such as accepted
  connections, with disposal of unread values in the producer's close action.

The producer receives publish/fail/finish and returns prebuilt stop/close
closures. `publish` returning true commits event ownership; false or an
exception leaves ownership with the producer. Its callback must then dispose of
an unaccepted resource before leaving. Error/end follow queued values, while
closed prevents further ordinary delivery immediately. Nil and false payloads
remain data because count/tags, rather than truthiness, identify presence.

One subscription has one reserved reader, including while its wake is queued.
Cancelling that reader detaches only its wait and preserves the source and
queue. `has_waiter()` exposes this reservation for domain admission checks.
Longer classification or mutation guards remain domain-owned; a subscription
reader slot does not cover all later yielding work.

Stop runs the producer stop action once and changes only a live terminal state
to ended. Close marks closed, arms cleanup before fallible stop/wake work, and
passes a drain capability to the producer close action. That action may use
`await_cleanup` and dispose of unread resources. Repeated close does not join
an already running close; coordinate completion separately when another owner
must observe it. Several subscriptions may share one handle, or one subscription
may aggregate several handles. Native close belongs to the actual domain owner.

`drain_if` detaches the whole FIFO only when a nonyielding, nonmutating predicate
matches some item. `wake_batch` notifies only an already pending batch reader,
stores no wake credit, and leaves the queue live. Filesystem watcher retirement
uses these operations to drain complete callback-order batches without retaining
stale per-registration events. Do not build a second generic queue or scheduler.

## Workers, startup and shutdown

Ordinary blocking work can use `async.run_foreign`. A domain cleanup worker uses
public `uv.work_t` and `uv.queue_work` inside `await_cleanup`, retaining its
argument graph explicitly until after-work completion. SQLite's reset/finalize/
close/disposal adapter is one example. Cleanup policy does not permit C workers
to touch Titan or to free an argument still in native use.

`uv.setup_process_args()` configures only the original argc/argv published by a
generated executable entrypoint. It is idempotent and returns false in an
ordinary Lua host. Async initialization calls it, installs the private main
bootstrap hook, and owns the conditional Unix SIGPIPE policy. Low-level UV
initialization itself installs neither async scheduling nor SIGPIPE policy.

Runtime failure cancels Tasks and allows their cleanup waits to finish before
final handle discovery/close. `uv.walk` discovers handles, not descriptors or
other worker-acquired resources. An adapter must own those resources itself.
`async.is_closing()` is a synchronous admission query; it neither requires a
Task nor injects pending Task cancellation. See [runtime shutdown](libuv-runtime.md#shutdown-and-process-control).

## Validation and integration

Behavior belongs in public native Titan tests. Exercise the canonical compiled
provider with ordinary imports: success, immediate rejection, terminal error,
cancellation, GC during native borrows, callback-time reuse, and explicit close.
Use public progress observations and bounded process deadlines. Add a compiler
or FFI test only when the change introduces a compiler-boundary behavior.

Keep source-transforming test providers and scheduler injection hooks out of
ordinary behavior tests. If an ownership boundary cannot be reached through a
public client or a standalone native fixture, inspect the model and align on
that exception before adding instrumentation. A copied example or focused
prototype is not evidence that the final combined provider passed.

Update the explicit source/header/native-input Make manifests when adding a
contributor. Preserve one logical UV object and one canonical provider pair.
Extract exact provider metadata from its exported protocol to update fixtures;
do not synthesize serialized schemas from source text. The defining owners of
Task/error/status types are async; rebuild stale consumers rather than adding
an identity alias to old UV metadata. Keep the prerelease language-server API
at 1 and the generated-code ABI at 2 unless their separate rules require change.

Run focused gates before the complete native/compiler suites and production
packaging checks. Libuv, llhttp and SQLite stay bundled in both supported Unix
OpenSSL policies; system OpenSSL is the default and bundled OpenSSL remains an
explicit build choice. Full local macOS VM validation is a pre-merge gate;
hosted macOS CI is used only when explicitly requested. The repository's
current commands and isolation rules are in [AGENTS.md](../../AGENTS.md).
