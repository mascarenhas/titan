# JavaScript bindings

`titan.browser` is available only with `--target browser`. The short import is
`import "browser"`. It is the browser-only standard-library exception: native
programs have no placeholder module. The module depends only on the portable
core (`gc`), not on the native async runtime, libuv, workers, or channels.

Use explicit bindings and the `BrowserValue` union to connect an application to
JavaScript. General calls from JavaScript into Titan return promises, even if
the function appears not to yield: an allocation can collect a suspended
coroutine and run its cleanup. This is not a synchronous comparator gateway.
See [browser programs](browser-target.md) for images, lifecycle, output sinks,
and deployment.

## Public surface and marshalling

The host supplies `create({bindings})`; names are not global expressions and
are never evaluated. A JavaScript function needing a particular `this` must be
bound by the host. `binding(name)` returns a `BrowserHandle` for the exact
value, including `false`, `0`, `null`, and `undefined`.

```text
record BrowserHandle
record BrowserRequest
record BrowserError
  const message: string
  const thrown: BrowserHandle
end

union BrowserValue
  is_nil()
  is_boolean(boolean)
  is_integer(integer)
  is_float(float)
  is_string(string)
  is_bytes(string)
  is_handle(BrowserHandle)
  is_callable(function (...: BrowserValue): BrowserValue)
end

function binding(name: string): BrowserHandle
function BrowserHandle:call(...: BrowserValue): BrowserValue
function BrowserHandle:start(
    completion: function (...: BrowserValue): BrowserValue,
    failure: function (...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
function BrowserHandle:listen(
    completion: function (...: BrowserValue): BrowserValue,
    failure: function (...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
function BrowserHandle:close()
function BrowserRequest:cancel()
function BrowserRequest:close()
function BrowserError:close()
```

Values cross the boundary as `BrowserValue` in both directions, marshalled by
runtime type without separate signature descriptors:

| JavaScript | `BrowserValue` | JavaScript, back |
| --- | --- | --- |
| `undefined`, `null` | `is_nil()` | `null` |
| boolean | `is_boolean(boolean)` | boolean |
| `BigInt` (signed i64, range-checked) | `is_integer(integer)` | `BigInt` |
| `Number` | `is_float(float)` | `Number` (NaN, `-0` kept) |
| string (well-formed UTF-16) | `is_string(string)`, UTF-8 encoded | string, UTF-8 decoded |
| `Uint8Array` | `is_bytes(string)`, copied | `Uint8Array` copy |
| the wrapper of a Titan callable | `is_callable(fn)`, the original function | the same wrapper |
| any other value, JS functions included | `is_handle(BrowserHandle)` | the retained value |

Calls into JavaScript are `target:call(...)` with one `BrowserValue` result,
since a JavaScript function returns one value; callers `case` on the returned
`BrowserValue`. A JavaScript Array or plain object crosses as an opaque
`is_handle(BrowserHandle)`, and a Titan callable likewise returns one
`BrowserValue`.

Integer values cross as signed 64-bit integers and JavaScript `BigInt`, even
below $2^{53}$. Write `5n`, not `5`, on the JavaScript side. Neither direction
coerces a `Number` into an integer: a JavaScript `Number` arrives as
`is_float`, so Titan code expecting an integer must receive a `BigInt` or
convert explicitly. Out-of-range `BigInt` values raise `TypeError`. Float
values retain their floating tag, including integral floats, NaN, and negative
zero. Booleans are not numeric truthiness conversions.

`is_string` carries UTF-8 text and crosses as a JavaScript string:
- A JavaScript string must be well-formed UTF-16 (`str.isWellFormed()`); a
  string containing a lone surrogate is rejected with `TypeError` at
  marshalling instead of being silently replaced with U+FFFD.
- `is_string(text)` from Titan is validated as UTF-8 and decoded into a
  JavaScript string; invalid UTF-8 from Titan raises an error.

`is_bytes` carries arbitrary binary bytes and crosses as a copied
`Uint8Array`. Empty data, embedded NUL, `0xFF`, and invalid UTF-8 survive in
`is_bytes`. Memory growth does not invalidate the byte or string contract: the
bridge obtains current memory views after allocations and keeps Titan owners
live while their pointers are borrowed.

A Promise returned by a JavaScript binding arrives as `is_handle(BrowserHandle)`.
Holding the handle does not observe the Promise's rejection; the binding must
attach a rejection handler when appropriate, or the host can report an
unhandled rejection.

## JavaScript values

`BrowserHandle` owns one state-local JavaScript reference unit. Its identity
fields are private. Call `handle:close()` explicitly when finished; repeated
close is safe. An unreachable handle also has an allocation-free reachability
finalizer. State disposal retires all remaining units, including units created
by close-phase finalizers when Lua no longer registers new finalizers.

Closing first validates state admission and only then relinquishes the unit.
If that validation raises, a live `BrowserHandle` or `BrowserRequest` still
owns its reference and can be closed later. An already closed owner remains
inert.

A closed handle cannot be used as a target or queued argument. A handle from
another instance or Lua state is rejected before application entry. Slot
reuse cannot revive a closed handle. `null` and `undefined` in `binding(name)`
or thrown exceptions are ordinary live handle values, not empty-slot sentinels.

## Callables and pinning

A Titan function of type `function (...: BrowserValue): BrowserValue` crosses
into JavaScript as `BrowserValue.is_callable(fn)` (or as the `completion` /
`failure` callback of `start` / `listen`).
A callable is pinned when it first crosses into JavaScript: one slot and one
JavaScript wrapper per function per state, so
the same function always reaches JavaScript as the same wrapper (`w1 === w2`),
and passing that wrapper back to Titan recovers the original function. Two
exported closures sharing a mutable local keep sharing that cell; this is not
closure transfer or a capture snapshot.

A callable stays pinned while any holder needs it:
- a live JavaScript wrapper; or
- an active request or listener (including a settled request whose notification
  is still queued for `drain()`).

Wrapper `release()`, request retirement, and state close drop their holds. A
JavaScript wrapper's `release()` is synchronous and logically invalidates that
wrapper immediately; physical unpinning in Titan occurs at a safe point once no
holder remains. Re-exporting the same callable before a queued wrapper release
is delivered cancels that queued release and issues a fresh live wrapper. If a
crossing fails before JavaScript receives the callable wrapper (for example, a
later argument raises during marshalling, or a host `call` or `start` target is
not callable), any provisional pin created for that crossing is rolled back in
the same operation. Once a wrapper has been passed into a host binding
function, it remains live even if that binding later throws, returns an
unmarshallable value, or returns an invalid request ownership form; for a
refused `start` or `listen`, only the request's `completion` and `failure`
holds are rolled back.

Cross-heap cycles are explicit ownership: a JavaScript object retaining a
Titan callable wrapper which retains a `BrowserHandle` back to that object
requires `release()`, `close()`, or `dispose()`. Neither collector traces the
other heap.

A Titan callable receives `BrowserValue` arguments and decides what it accepts,
raising if it gets an unexpected variant or count; that raise rejects the
JavaScript promise with `TITAN_BROWSER_TITAN`, the error message, and the
captured Titan traceback. Both `instance.call(wrapper, ...args)` and
`wrapper.call(...args)` resolve to the single decoded return value (`null` for
`is_nil()`, `BigInt` for `is_integer`, `Uint8Array` for `is_bytes`, string for
`is_string`, and the underlying JavaScript value for `is_handle`). Because
JavaScript `Promise` resolution adopts any returned thenable, returning a
`BrowserHandle` that wraps a `Promise` or thenable from a callable causes the
user-facing `call()` promise to adopt that `Promise`/thenable; internal bridge
admission and `dispose()` depend only on the Wasm entry's completion, so a
forever-pending returned `Promise` never hangs disposal.

For example, this complete module publishes two closures over one counter:

```titan
local browser = import "browser"
local type Value = browser.BrowserValue
local function expect_integer(v: Value): integer
  case v
  when is_integer(n) then return n
  end
  raise "expected an integer BrowserValue"
end

function main(args: {string}): integer
  local count = 0
  local publish = browser.binding("publish")
  defer publish:close()
  local increment = function(...: Value): Value
    count = count + expect_integer(...[1])
    return Value.is_integer(count)
  end
  local read = function(...: Value): Value
    return Value.is_integer(count)
  end
  publish:call(Value.is_callable(increment), Value.is_callable(read))
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
  const changed = await increment.call(5n);
  const current = await read.call();
  console.log(changed, current); // 5n, 5n: the same capture cell
} finally {
  await instance.dispose();
}
```

Main's defers run when main returns; state finalizers run at explicit
`dispose()`. Callable wrappers remain usable between those events. Always
await disposal in `finally`.

## Errors

`BrowserError` has `message: string` and `thrown: BrowserHandle`, both
read-only. Every potentially throwing binding import catches the JavaScript
exception and returns normally before Titan raises this ordinary error. The
handle retains the exact thrown value, whether it is an `Error` object, string,
`null`, `undefined`, or another value. `BrowserError:close()` closes its
thrown-value handle.

Inside `catch`, test the implicit `error` with `is browser.BrowserError` before
projecting it:

```titan
local browser = import "browser"

function try_announce(message: string): boolean
  local target = browser.binding("announce")
  defer target:close()
  do
    target:call(browser.BrowserValue.is_string(message))
  catch
    if error is browser.BrowserError then
      local failure: browser.BrowserError = error
      failure:close()
      return false
    end
    raise
  end
  return true
end
```

If the bridge cannot create the thrown-value handle, for example at its
handle-identity limit or when memory runs out, it raises an ordinary Titan
error with the diagnostic message instead of a `browser.BrowserError`. It never
fabricates a handle, and the instance stays usable.

A JavaScript-to-Titan failure rejects that call with a `TITAN_BROWSER_TITAN`
error carrying the copied message bytes and the original captured Titan trace
(see the [loader errors](browser-target.md#the-loader-api)). A following valid
call on an intact instance can succeed. Traps, aborts, backend transfer
failures, and completion protocol corruption instead poison the instance;
they are not catchable `browser.BrowserError` values.

The message follows Lua's standalone error-reporting rule: strings keep their
bytes and numbers use Lua's numeric formatting (`2.0` and `-0.0` retain their
float spelling). Other values use `__tostring` only when it returns a string;
otherwise the message is `(error object is a <type> value)`. If conversion
itself fails, the message is `error while reporting browser failure`; the
original error's trace is retained.

An immediate `instance.call()` or `drain()` attempted inside an active import
returns a rejected `TITAN_BROWSER_REENTRY` promise. It does not throw
synchronously into the import, and is not automatically propagated into
Titan. Observe the rejection, enqueue a notification, or use a tracked request
instead.

## Requests and listeners

```text
BrowserHandle:start(
    completion: function (...: BrowserValue): BrowserValue,
    failure: function (...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
BrowserHandle:listen(
    completion: function (...: BrowserValue): BrowserValue,
    failure: function (...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
BrowserRequest:cancel()
BrowserRequest:close()
```

Both methods invoke the host binding synchronously with the supplied
`BrowserValue` arguments without awaiting host work, and pin `completion` and
`failure` for the life of the request.
- For a one-shot `start` request, `completion` receives one `BrowserValue`
  argument: the host promise's settled value marshalled by runtime type
  (`undefined` becomes `BrowserValue.is_nil()`).
- For a `listen` request, each `emit(...args)` call passes its arguments
  marshalled by runtime type to `completion`.
- For both, `failure` receives two arguments:
  `(BrowserValue.is_string(message), BrowserValue.is_handle(thrown))`—the
  diagnostic message text and a `BrowserHandle` retaining the exact
  thrown/rejected JavaScript value (even when a primitive was thrown). If a
  `start` settlement value or `listen` emission argument cannot be marshalled
  (for example, an out-of-range `BigInt`, an ill-formed UTF-16 string with a
  lone surrogate, or a foreign/released callable wrapper), that marshalling
  `TypeError` or bridge handle error is delivered to `failure` in the same way.

Because callables are not signature-checked at registration time, type errors
move from registration to call time: if `completion` or `failure` raises when
delivered in `drain()`, that callback failure is reported through
`onNotificationError` (`kind: "callback", operation: "drain"`). Host promise
rejection itself is delivered to `failure`, not `onNotificationError`.

A start binding returns one of two explicit forms:

- `{kind: 'detachable', promise, cancel?}` for work which might never settle.
  Bridge continuations retain only a detachable mailbox, not a Lua pointer,
  Wasm view, Module, or instance. Cancellation/disposal detaches that mailbox.
- `{kind: 'retained', promise, cancel?}` when the binding guarantees terminal
  settlement and genuinely needs retained native ownership. Disposal can wait
  for physical settlement. Never use this form for forever-pending work.

Duplicate and late settlements retire without entering Lua. Cancellation
signals the host but is not physical retirement and does not free an accepted
borrowed owner early.

A listener binding returns
`{kind: 'listener', subscribe(emit): unregister}`. Its synchronous
`emit(...args)` calls enqueue; they do not enter Titan inline. Events remain
ordered until the request is closed. Unregister is idempotent and stops new
admission before captured owners retire.
Cancelling or closing a listener from one of its callbacks also suppresses its
remaining events in the current detached batch. A normally settled one-shot
request still delivers its queued success or failure notification.

The host explicitly calls `drain()` to deliver one detached FIFO batch.
Imports which enqueue more work add it to the next batch. No implicit timer,
fairness policy, async scheduler, or nested synchronous callback is supplied
here. A released target is retired without delivery; a released queued
argument is reported without entering Lua. Disposal first closes application
admission, then permits only physical retirement, then closes the state.

## State close

`titan.browser` registers its state record for finalization when the module
initializes. A state's handles, callables, and queued notifications are
invalidated exactly once when that record is finalized. This is after the
finalizers of values created after `titan.browser` initialized, including its
handles, callables, requests, and modules that import it.

This holds for explicit close, reachability close, and a later close of a
detached state; detaching a state does not close it. Handles from a closed state
never become valid again, even if a new state reuses its memory.

During close, synchronous binding calls, copied output admission, and
idempotent release remain valid until that invalidation. New requests,
listeners, and reverse application calls are refused, including for an
independent state closing while its containing instance is not disposing.

An object's earlier-registered finalizer runs after the browser record. Its
`close()` and callable release operations are no-ops; binding lookup and calls
raise. An uncaught raise is reported as a Lua finalizer warning on stderr, not
an invented failed application call.

## C SDK

The installed `titan/browser.h` declares the checked wasm32 scalar/slot,
response, completion, and state-registry boundary. Its API requires the same
instance execution owner as the generated gateway; it is not a raw
`lua_State *` application gateway. C-created states load `titan.browser`
normally; there is no attachment operation or special bootstrap order.
`titan.lua` is native-only, so no standard-library API creates independent
browser states. See [the bridge implementation](../implementation/browser-bridge.md)
for layout, ownership, initialization, and close rules. Native SDKs may
install the header, but native providers contain no `titan.browser` or fake
bridge runtime.
