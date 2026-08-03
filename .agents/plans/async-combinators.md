# Async combinators, `uv_check_t`, and HTTP idle timeouts

This is the reviewed implementation plan. The author's original 242-line draft
is preserved byte-for-byte in commit `9fb88c6`; this revision resolves the
type, event-loop, cancellation, and HTTP-composition gaps found by reading the
current runtime and pinned libuv implementation.

## Reviewed semantic corrections

1. Keep the existing `async.Error = uv.Error` I/O error type unchanged. It is
   specifically `{ code, name, message, operation }`, while a Titan Task may
   raise any `value`. A failed Task therefore carries a distinct record:

   ```titan
   record TaskError
     error: value
     traceback: string
   end
   ```

   `error` is the exact raised value, including an `async.Error`, and
   `traceback` is the raw catch-local traceback without presentation headers.

2. Replace the public `Cancelled` record with private cancellation state. A
   Task stores whether cancellation was requested plus its original reason.
   That request is authoritative when the coroutine later raises or returns,
   so catching, transforming, or returning from the injected reason cannot
   turn the Task into failed or succeeded. `async.Cancelled` is removed.

3. Every combinator scans statuses before its first `Waiter:wait()`. A check
   handle runs after polling but does not itself force libuv's poll timeout to
   zero. Waiting first can block forever when all inputs are already terminal
   and the check handle is the only active source.

4. “First” means first observed while scanning arguments from left to right.
   Status polling cannot reconstruct chronology when several Tasks settle
   before the same check phase. Duplicate Tasks therefore select their
   leftmost argument position.

5. Reject an input whose status is `running`. With the non-reentrant runtime,
   that can only be the combinator's current Task; waiting for itself would
   deadlock. All arities validate this before allocating the Waiter.

6. Preserve the runtime's existing failure-reporting rule. A Task failure is
   logged with its traceback when that Task terminates. A later combinator can
   inspect the stored `TaskError`, but does not retroactively mark the failure
   handled or suppress its report; adding observers or joiner lists is outside
   this design.

7. HTTP `idle_timeout` is an absolute deadline for acquiring the next request's
   line and headers, measured from the start of that loop iteration. It does
   not reset on partial bytes and does not cover handler work, request bodies,
   automatic body drain, or response writes.

## Public Task status API

Own these types beside `Task` in `titan.uv` and transparently alias them from
`async`:

```titan
record TaskError
  error: value
  traceback: string
end

union TaskStatus
  ready
  running
  waiting
  succeeded: value
  failed: TaskError
  cancelled: value
end

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, value?)
function TaskStatus:has_failed(): (boolean, TaskError?)
function TaskStatus:has_cancelled(): (boolean, value?)

function Task:status(): TaskStatus
```

The helper predicates return a boolean discriminator plus the payload when
that variant has one. The success payload is the exact value returned by the
Task function; the cancellation payload is the original reason (or the
existing default string when `cancel(nil)` is used).

Store `TaskStatus` directly in the Task. `advance_task` already receives the
dead coroutine's return value and must retain it instead of discarding it. On
failure it constructs `TaskError.new(error, traceback)`. Make requested
cancellation win every user-Task terminal path, including callback-boundary
failure and a coroutine that catches the injected reason and returns.

Remove `async.Cancelled` and the corresponding type test in `titan/lua.titan`.
The Lua loader may contextually wrap the in-flight cancellation value, but the
Task still terminates as `cancelled` with its stored original reason and is not
reported as a failure.

## Low-level `uv_check_t` binding

Classify this as a new persistent multi-shot handle. Add
`titan/uv/check.titan` to `UV_TITAN_SOURCES` with this ordinary Titan owner:

```titan
record uv_check_t
  local handle: owned *libuv.uv_check_t
  local callback: (uv_check_t) -> ()
  local runtime: Runtime
  local waiting: Task?
  local fired: boolean
  local root_index: integer
end
```

Add `CheckWaitCall` and `CheckCloseCall` plus only their variants and dispatch
arms to `task.titan`. Export the private-facade functions `_check()`,
`_check_wait(check)`, and `_check_close(check)`.

Lifecycle:

1. Allocate every Titan/FFI field and root the owner before `uv_check_init`.
2. Call `uv_check_init`, install owner data, and call `uv_check_start` exactly
   once. Both public functions are called directly through the FFI.
3. The callback clears and takes an installed waiter before resuming it;
   without a waiter it sets the single pending `fired` bit. Multiple unwaited
   check phases coalesce.
4. Wait consumes and clears `fired` immediately, rejects a second waiter, or
   installs the current Task and returns to libuv.
5. A cancelled wait must never resume synchronously inside the cancelling
   Task. Detach it and wake it on a later libuv callback. The Waiter remains
   reusable; if sticky cancellation prevents its deferred close from being
   dispatched, ordinary Runtime `uv_walk` cleanup remains the final owner.
6. Close is idempotent, calls `uv_check_stop` directly, wakes any other waiter
   on a later turn, clears the pending bit, and transfers lifetime through
   `close_handle`; the initiating closer resumes only from `close_cb`.
7. Wait on an already closed/cross-Runtime Waiter returns normally, matching
   the authored void-return API. No waiter queue, handle registry, generation
   fence, or reentrant loop call is added.

The only C addition is the exact callback ABI bridge:

- forward-declare `struct uv_check_s` and declare
  `titan_uvshim_check_cb(struct uv_check_s *)` in `titan-runtime/titan/uv.h`;
- implement that callback trampoline in `titan-runtime/titan_uv.c` by
  extracting the owner, loop, primary callback slot, module, and Titan native
  entry point, then releasing the callback context; and
- do not reuse the timer trampoline merely because both Titan callbacks have
  no explicit payload.

There are no forwarding or other non-callback C functions. Directly call
`uv_check_init`, `uv_check_start`, and `uv_check_stop` from Titan.

Update the mechanical inventories in `spec/libuv_build_spec.lua`:

- `titan_uvshim_check_cb` in `DIRECT_CALLBACKS` and
  `PROVIDER_CALLBACK_REFERENCES`;
- `uv_check_init`, `uv_check_start`, and `uv_check_stop` in
  `DIRECT_LIBUV_CALLS`; and
- the explicit `UV_TITAN_SOURCES` assertion for the new contributor.

Refresh the extension-guide coverage snapshot to 7/14 concrete handles,
78/318 public functions, 78/316 nondeprecated functions, Check 3/3,
16/94 concrete-handle functions, and 31 of 78 handle-related functions.

## Public Waiter API

Add to `async`:

```titan
record Waiter
  local handle: uv.uv_check_t
end

function waiter(): Waiter
function Waiter:wait()
function Waiter:close()
```

Creation and waiting require a running Task. There is one pending-bit buffer
and at most one suspended waiter. `close` is idempotent and waits for the
native close callback on its initiating call. A blocked wait awakened by
another Task's close returns normally; later waits on the closed Waiter also
return normally.

## Combinators

Implement arities two through five exactly as fixed public unions/functions:

- `any_two` ... `any_five`, returning `AnyTwoResult` ... `AnyFiveResult` with
  positional success variants plus `none`;
- `race_two` ... `race_five`, returning `RaceTwoResult` ... `RaceFiveResult`
  whose positional variant carries `TaskStatus`;
- `all_two` ... `all_five`, returning success values as multiple results and
  raising `AllTwoError` ... `AllFiveError` whose positional variant carries
  the failed/cancelled `TaskStatus`; and
- `join`, `join_two` ... `join_five`, returning every final `TaskStatus`.

Use small internal helpers over `{Task}` arrays, while keeping the public
fixed-arity result types precise. Each helper validates that no input is
`running`, creates one Waiter with a deferred close, then repeats:

```text
scan left to right
if the combinator's terminal condition is met, return or raise
wait for the next check phase
```

`any` returns on the first observed success or `none` once all inputs are
failed/cancelled. `race` returns the first observed terminal status. `all`
returns only when every Task succeeded and raises on the first observed failed
or cancelled status. `join` returns only once all are terminal. No combinator
cancels unfinished Tasks.

Correct the example deadline to 5000 ms and include `when none`.

## HTTP idle timeout

Add a local `idle_timeout_ms: integer` backing field to `http.Server`; Titan
does not permit a record field and method with the same name. Extend the
constructors with a trailing optional argument to preserve every existing
positional call:

```titan
function listen(host: string, handler: Handler,
                port: integer?, backlog: integer?,
                idle_timeout: integer?): Server

function listen_tls(host: string, certificate_file: string, handler: Handler,
                    private_key_file: string?, port: integer?,
                    backlog: integer?, idle_timeout: integer?): Server

function Server:idle_timeout(timeout: integer?): integer
```

Normalize omitted timeout to 0 and reject a negative value before opening the
plain listener or synchronously reading TLS PEM input. The setter validates
before mutation, sets only for nonnil input, and always returns the previous
value; passing nil therefore returns the current value.

Pass the Server itself to each connection Task. At the start of each request
loop, snapshot `idle_timeout_ms`; changes affect the next request on an
existing keep-alive connection, not a header read already in progress.

At 0, call `read_request` directly. At a positive value:

1. start one Task returning `read_request(parser, encrypted)` and one Task
   sleeping for the snapshot milliseconds;
2. `race_two` them;
3. cancel and `join` the loser before inspecting the winner, so parser,
   transport, timer, and read owners remain live through their terminal
   callbacks;
4. on reader success, continue with its `Request?` result;
5. on timeout success, return silently and let the existing deferred parser
   and transport close run; and
6. on a child failure, avoid re-raising it from the parent connection Task—the
   failed child already logged its exact error/traceback—clean up its peer and
   return.

This iteration does not add body, drain, or write timeouts. `Server:close`
still closes only the listener, not accepted connections. An application that
times out a body read must unwind its handler (and may close the Server to stop
new accepts); merely returning after `Server:close` would still enter the
automatic body drain.

No HTTP C or `uv` reach-through is needed.

## Tests, migrations, and documentation

Add `spec/stdlib/async_combinators_spec.lua` and route `async*_spec.lua` into
the uncovered `library_uv_fs` group. Cover every arity and variant, nil success
values, all-failed/cancelled `any`, success/failure/cancellation races,
left-to-right ties and duplicates, all success/error unions, joins, already
terminal Tasks, real timer/I/O sleeping, self-dependency rejection, and the
rule that failures remain logged.

Extend the focused uv suites for:

- success payload, exact arbitrary failure value plus raw traceback, and
  authoritative cancellation status;
- Waiter direct delivery, buffered/coalesced delivery, competing waiters,
  later-turn cancellation and reuse, close with a waiter, repeated close, and
  shutdown of an unclosed check handle; and
- direct native callback/function/source inventories.

Extend HTTP behavior tests for default/getter/setter/previous values, validation
before listener creation, zero-timeout delayed requests, positive initial and
keep-alive idle closes, partial-header deadlines, buffered next requests,
plain/TLS parity, no handler invocation on timeout, no uncaught timeout log,
and complete loser/check/read/timer cleanup. Keep handler/body/drain/write work
outside this timeout and test that boundary.

Migrate all Task string-status uses in production sources, stdlib specs,
packaging/production smokes, README, and quick tour to `as_string()` or the
new predicates. Do not alter `coroutine.Coro:status()` string call sites.

Update:

- `doc/language/async-io.md` and its index summary;
- `doc/implementation/libuv-runtime.md` and its index summary;
- `doc/implementation/libuv-extension-guide.md` lifecycle language and
  coverage snapshot;
- `doc/language/standard-library-http.md`;
- `doc/implementation/http-library.md`;
- cancellation wording in the Lua/net language and implementation chapters;
- `doc/style-guide.md`, README, and quick tour examples; and
- serialized `titan.uv`, `async`, and `http` interface fixtures, mechanically
  extracted from the rebuilt canonical provider.

## Delivery gates

Run focused checker/build/runtime suites first, then the complete uncovered
library group, isolated bundled/system production smokes, and `make test` from
an environment without ambient provider/build-policy overrides. Perform an
adversarial review after tests are green, commit all code/tests/docs/plan
revisions, push the feature branch, open the PR, and wait for all required
Linux, sanitizer, consumer, and Codecov checks. The user explicitly waived the
manual macOS dispatch for this PR.
