# JavaScript bindings

`titan.browser` is available only with `--target browser`. The short import is
`import "browser"`. It is the browser-only standard-library exception: native
programs have no placeholder module. The module depends only on the portable
core, not on the native async runtime, libuv, workers, or channels.

Use explicit bindings and typed byte/scalar calls to connect an application to
JavaScript. General calls from JavaScript into Titan return promises, even if
the function appears not to yield: an allocation can collect a suspended
coroutine and run its cleanup. This is not a synchronous comparator gateway.
See [browser programs](browser-target.md) for images, lifecycle, output sinks,
and deployment.

## Typed bindings

The host supplies `create({bindings})`; names are not global expressions and
are never evaluated. A JavaScript function needing a particular `this` must be
bound by the host. `binding(name)` returns a `JSHandle` for the exact value,
including `false`, `0`, `null`, and `undefined`.

| Titan operation | Required JavaScript result |
| --- | --- |
| `binding(name): JSHandle` | The explicitly supplied binding value |
| `call_boolean(target, arguments): boolean` | An actual boolean |
| `call_integer(target, arguments): integer` | A signed-i64 `BigInt` |
| `call_float(target, arguments): float` | A `Number`, including NaN and -0 |
| `call_bytes(target, arguments): string` | Counted copied bytes |
| `call_handle(target, arguments): JSHandle` | Any opaque JavaScript value |
| `call_void(target, arguments)` | No result (`undefined`) |

Every call takes a `JSHandle` target and an Array of `Argument`. The variants
are `is_nil()`, `is_boolean(boolean)`, `is_integer(integer)`,
`is_float(float)`, `is_bytes(string)`, `is_handle(JSHandle)`, and
`is_callable(Callable)`. This is an in-process carrier, not a JSON, protobuf,
transfer-packet, or arbitrary-record codec.

Integer values cross as signed 64-bit integers and JavaScript `BigInt`, even
below 2^53. Write `5n`, not `5`, on the JavaScript side. Neither direction
coerces a Number into an integer. Float values retain their floating tag,
including integral floats, NaN, and negative zero. Booleans are not numeric
truthiness conversions.

Strings here are bytes. A JavaScript byte result is a `Uint8Array`, or a
counted `{bytes: Uint8Array, length}` source. The length must be an integer in
`0..bytes.byteLength`; only that prefix is copied. Empty data, embedded NUL,
0xFF, and invalid UTF-8 survive. Only binding names and diagnostic messages
have a text interpretation. Memory growth does not invalidate the byte
contract: the bridge obtains current memory views after allocations and keeps
Titan owners live while their pointers are borrowed.

A Promise is a valid opaque `call_handle` result; it is not a valid
boolean/integer/float/bytes/void result. A handle does not observe a Promise's
rejection. The binding must attach a rejection handler when appropriate, or
the host can report an unhandled rejection.

## JavaScript values

`JSHandle` owns one state-local JavaScript reference unit. Its identity fields
are private. Call `handle:close()` explicitly when finished; repeated close is
safe. An unreachable handle also has an allocation-free reachability
finalizer. State disposal retires all remaining units, including units created
by close-phase finalizers when Lua no longer registers new finalizers.

A closed handle cannot be used as a target or queued argument. A handle from
another instance or Lua state is rejected before application entry. Slot
reuse cannot revive a closed handle. `null` and `undefined` are ordinary live
values, not empty-slot sentinels.

## Original closures

`callable(callback: value): Callable` checks the actual original Titan
function. It does not first coerce it to a generic variadic function. The
function must have fixed parameters and results made of nil, boolean, integer,
float, byte string, `JSHandle`, or `Callable`. Lua functions, raw C functions,
Options, open input/result tails, arbitrary `value`, Arrays, Maps, and other
nominals are rejected before user invocation.

The bridge roots the original closure and its original capture cells in its
Lua state's registry. Two exported closures sharing a mutable local keep
sharing that cell; this is not closure transfer or a capture snapshot. The
roots survive collection of transient Titan `Callable` wrappers. Use
`Callable:close()`, JavaScript wrapper `release()`, or instance disposal to end
the root's lifetime. A JavaScript wrapper's `call(...args)` returns a promise;
its `release()` is synchronous and logically invalidates it immediately.
Physical Lua-root removal occurs later under a protected entry.

For example, this complete module publishes two closures over one counter:

```titan
local browser = import "browser"

function main(_: {string}): integer
  local count = 0
  local publish = browser.binding("publish")
  defer publish:close()
  local increment = browser.callable(function(delta: integer): integer
    count = count + delta
    return count
  end)
  local read = browser.callable(function(): integer return count end)
  browser.call_void(publish, {browser.Argument.is_callable(increment),
                             browser.Argument.is_callable(read)})
  return 0
end
```

A page using the generated `counter.mjs` supplies only its bindings and sinks:

```javascript
import create from './counter.mjs';

let increment, read;
const instance = create({
  bindings: {
    publish(next, current) { increment = next; read = current; },
  },
  stdout(bytes) { console.log(new TextDecoder().decode(bytes)); },
  stderr(bytes) { console.error(new TextDecoder().decode(bytes)); },
});
try {
  await instance.initialize();
  await instance.run([]);
  console.log(await increment.call(5n)); // 5n
  console.log(await read.call());       // 5n: the same capture cell
} finally {
  await instance.dispose();
}
```

Main's defers run when main returns; state finalizers run at explicit
`dispose()`. Callable handles remain usable between those events. Always
await disposal in `finally`.

Callback arity and kinds are exact. Nil arguments are JavaScript `null`, not
missing arguments. Zero results produce `undefined`, one nil result produces
`null`, one byte string produces one `Uint8Array`, and multiple results
produce a dense Array preserving every trailing nil. A `JSHandle` result
unwraps the underlying JavaScript value; a `Callable` result becomes a branded
instance/state-bound wrapper. A `JSHandle` parameter accepts an ordinary raw
JavaScript value and creates a new state-owned unit; a `Callable` parameter
requires the correct live branded wrapper.

Cross-heap cycles are explicit ownership: a JavaScript object retaining a
Titan callable which retains a `JSHandle` back to that object requires release
or disposal. Neither collector is promised to discover that cycle.

## Errors

`Error` has `message: string` and `thrown: JSHandle`, both read-only. Every
potentially throwing binding import catches the JavaScript exception and
returns normally before Titan raises this ordinary error. The handle retains
the exact thrown value, whether it is an Error object, string, null, undefined,
or another value. `Error:close()` closes its thrown-value handle.

A JavaScript-to-Titan failure rejects that call with copied message bytes and
the original captured Titan trace. A following valid call on an intact
instance can succeed. Traps, aborts, backend transfer failures, and completion
protocol corruption instead poison the instance; they are not catchable
`browser.Error` values.

An immediate `instance.call()` or `drain()` attempted inside an active import
returns a rejected `TITAN_BROWSER_REENTRY` promise. It does not throw
synchronously into the import, and is not automatically propagated into
Titan. Observe the rejection, enqueue a notification, or use a tracked request
instead.

## Requests and listeners

```text
start(target: JSHandle, arguments: {Argument},
      completion: Callable, failure: Callable): Request
listen(target: JSHandle, arguments: {Argument},
       completion: Callable, failure: Callable): Request
Request:cancel()
Request:close()
```

Both calls invoke the host binding synchronously without awaiting host work.
The success callable has the exact fixed arguments of the host's result. The
mandatory failure callable has the exact signature
`function(string, JSHandle): ()`: copied diagnostic message plus the exact
thrown/rejected JavaScript value. Each live one-shot settlement becomes one
queued success or failure notification under a protected entry. Host rejection
is not `onNotificationError`; that observer reports a notification callback
which itself failed.

A start binding returns one of two explicit forms:

- `{kind: 'detachable', promise, cancel?}` for work which might never settle.
  Bridge continuations retain only a detachable mailbox, not a Lua pointer,
  Wasm view, Module, or instance. Cancellation/disposal detaches that mailbox.
- `{kind: 'retained', promise, cancel?}` when the binding guarantees terminal
  settlement and genuinely needs retained native ownership. Disposal can wait
  for physical settlement. Never use this form for forever-pending work.

For zero success arguments the promise resolves `undefined`; for one it
resolves the value; for several it resolves a dense Array. Duplicate and late
settlements retire without entering Lua. Cancellation signals the host but is
not physical retirement and does not free an accepted borrowed owner early.

A listener binding returns
`{kind: 'listener', subscribe(emit): unregister}`. Its synchronous
`emit(...args)` calls enqueue; they do not enter Titan inline. Events remain
ordered until the request is closed. Unregister is idempotent and stops new
admission before captured owners retire.

The host explicitly calls `drain()` to deliver one detached FIFO batch.
Imports which enqueue more work add it to the next batch. No implicit timer,
fairness policy, async scheduler, or nested synchronous callback is supplied
here. A released target is retired without delivery; a released queued
argument is reported without entering Lua. Disposal first closes application
admission, then permits only physical retirement, then closes the state.

## State close

Each Lua state has an earliest-created C registry, installed before libraries
or module initializers. It invalidates last at close, after coroutine unwinding
and other finalizers. Detaching a state does not close it. Explicit close,
reachability close, and a later close of a detached state invalidate its
handles once; a reused native address never revives an old state token.

During close, synchronous binding calls, copied output admission, and
idempotent release remain valid until that last invalidation. New requests,
listeners, and reverse application calls are closed, including for an
independently owned state when its containing instance is not disposing.
Warnings from Lua finalizers are stderr bytes, not an invented failed call.

## C SDK

The installed `titan/browser.h` declares the checked wasm32 scalar/slot,
signature, completion, state-registry, and byte-I/O boundary. Its API requires
the same instance execution owner as the generated gateway; it is not a raw
`lua_State *` application gateway. See
[the bridge implementation](../implementation/browser-bridge.md) for exact
layout, ownership, initialization, and close rules. Native SDKs may install the
header, but native providers do not contain `titan.browser` or a fake bridge
runtime.
