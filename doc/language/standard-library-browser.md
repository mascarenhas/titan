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

The low-level [drive interface](#driver-interface-low-level) that `async`
uses to run Tasks has its own section, and so do `BrowserPin` and the C entry
for [synchronous C callbacks](#synchronous-c-callbacks).

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

## Copying typed values

Use [`protobuf.portable`](standard-library-protobuf.md#portable-codecs) when
JavaScript needs a copy of structured Titan data rather than an opaque handle.
Pass the codec's `describe()` text and its encoded bytes to a binding. The
SDK's standalone `titan-protobuf.mjs` generates JavaScript classes from that
description; it does not load Titan modules or require a running image.

Save this complete program as `app.titan`:

```titan
local browser = import "browser"
local protobuf = import "protobuf"
local reflect = import "reflect"
foreign import "stdio.h"

local type Value = browser.BrowserValue

record Point
  x: float
  y: float
end

local codec = protobuf.portable({
  reflect.Type.is_named(reflect.NamedType("app.Point")),
  reflect.Type.is_string(),
}, nil, {"2"})

function main(_: {string}): integer
  local target = browser.binding("publish")
  defer target:close()
  local result = target:call(Value.is_string(codec:describe()),
      Value.is_bytes(codec:encode(Point(1.0, 2.0), "origin")))
  case result
  when is_bytes(bytes) then
    local point: Point, label: string = codec:decode(bytes)
    ffi.printf("%g %g\n", point.x, point.y)
    ffi.puts(label)
  else raise "publish must return encoded bytes"
  end
  return 0
end
```

Compile it and copy the peer from your installation, with `PREFIX` set to the
Titan installation root:

```sh
titanc --target browser --tree . -o out --exe out/app.mjs app
cp "$PREFIX/lib/titan-browser/0.6/titan-protobuf.mjs" .
```

Save this page as `index.html` beside `app.titan` and serve the directory over
HTTP with a JSPI-capable browser:

```html
<!doctype html>
<meta charset="utf-8">
<title>Copied Titan values</title>
<pre id="output"></pre>
<script type="module">
  import create from "./out/app.mjs";
  import { portable } from "./titan-protobuf.mjs";

  const output = document.getElementById("output");
  const text = new TextDecoder();
  let codec;
  const instance = create({
    stdout: chunk => { output.textContent += text.decode(chunk); },
    bindings: {
      publish(description, bytes) {
        codec ??= portable(description);
        const [point, label] = codec.decode(bytes);
        const Point = codec.types["app.Point"];
        if (!(point instanceof Point)) throw new TypeError("expected Point");
        return codec.encode(new Point(point.x + 1, point.y), label);
      },
    },
  });
  try { await instance.run([]); }
  finally { await instance.dispose(); }
</script>
```

The root is one anonymous field message, not a JavaScript object: `encode`
takes one argument per declared field, including nil positions, and `decode`
returns an Array in that order.

| Titan value or declared position | JavaScript representation |
| --- | --- |
| Nil or absent Option | `null` |
| Boolean | boolean |
| Integer | signed i64 `BigInt`, including small integers |
| Float | `Number`, including integral floats, NaN, and `-0` |
| Unmarked string | `Uint8Array` of arbitrary bytes |
| String marked as text | string, with strict UTF-8/UTF-16 validation |
| Array | Array; absent slots decode as `null` |
| Public record | instance of `codec.types[qualifiedName]` |
| Public union variant | instance of `codec.types[qualifiedName].variants[variantName]` |

Record constructors take public fields in declaration order. Variant
constructors take their parts in declaration order; an empty variant takes no
arguments, and a single-type shorthand has a part named `value`. The union's
base class is not directly constructible. Missing constructor arguments become
`null`; more arguments than fields or parts throw a `TypeError` with code
`type_mismatch`. Instances are ordinary mutable objects: encoding reads only
the declared public fields or parts, so any other property is ignored and is
not copied. Class identity identifies a nominal: a plain object with the same
properties is not a record or variant. An instance of an application subclass
of a generated class encodes as that class's nominal; decoding always creates
instances of the generated classes themselves.

Each call to `portable(description)` creates its own class table. To share
classes between codecs, pass the first codec's `types` as the second argument:

```javascript
const first = portable(description);
const second = portable(description, first.types);
const values = first.decode(bytes);
const copied = second.encode(...values);
```

An existing nominal entry must have the same description, including its text
marks. Shared classes do not make an otherwise unlisted nominal acceptable.

Const Arrays decode as frozen Arrays; mutable Arrays are not frozen.
Maybe-const Arrays and Arrays in `value` positions preserve the encoded
constness. When encoding those positions, `Object.isFrozen(array)` selects the
flag. A declared mutable or const position instead selects its declared flag.
Freezing is shallow: each nested Array has its own constness.

Strings are bytes unless marked in `portable`'s third argument. Text paths are
root indices such as `"2"`, qualified record fields such as
`"app.Caption.label"`, or union parts such as `"app.Notice.text.value"`.
Options and Arrays may wrap the string leaf. A `value` position cannot be
marked as text, so a dynamic string remains bytes. Text marks change only the
description, not Titan's wire bytes or its own UTF-8 validation policy.

The codec accepts the portable scalar, Option, Array, record, and union graph
described in the [protobuf chapter](standard-library-protobuf.md#portable-codecs).
Repeated acyclic references become independent copies; cycles are rejected.
Records expose only public fields, and unions only public variants. A record
with local storage needs a compatible public `new` for Titan decoding; without
one it is encode-only. All-public records decode without calling `new`.
Transfer hooks, packet resources, Maps, Interfaces, callables, and foreign
types are not portable. Additional nominals used only in `value` positions
must be listed in the codec's `dynamic` argument.

Copies do not convey a live JavaScript capability or a Titan callable. Send
those as separate `Value.is_handle(handle)` or `Value.is_callable(callback)`
arguments beside `Value.is_bytes(bytes)`, not inside the encoded data.

### Copy errors

The peer raises `TypeError` with a `code` and a JSON-style `path`, for example
`invalid_utf8` at `$[1]["label"]`. Other codes include `type_mismatch`,
`integer_range`, `missing_field`, `unknown_type`, `unknown_variant`, `cycle`,
`limit_exceeded`, `malformed_wire`, and `invalid_description`. Invalid UTF-8
text from Titan and unpaired UTF-16 surrogates from JavaScript are rejected,
not replaced.

The peer accepts canonical Titan output but is stricter about non-canonical
input: it rejects protobuf groups, a wrong wire kind in any occurrence of a
repeated scalar, and invalid UTF-8 in a dynamic nominal name. Do not use it as
a general-purpose decoder for every message the native protobuf decoder
accepts.

A peer error thrown by a JavaScript binding reaches Titan as `BrowserError`;
its `thrown` handle retains the original error and its `code` and `path`.
Close that error as usual. A Titan codec error rejects the JavaScript callable
with `TITAN_BROWSER_TITAN`. Neither kind of ordinary failure disposes the
instance: a following valid call can succeed.

Titan codec error messages follow the protobuf chapter's
[error rules](standard-library-protobuf.md#errors): a nested failure can end
with a JSON-style ` at <path>` suffix, and a public `new` or other callback
that raises a message beginning with the reserved `protobuf: ` prefix can
receive a suffix naming a later position.

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
- a live JavaScript wrapper;
- a request or listener that can still deliver to it, including a settled
  one-shot request whose notification is still queued; or
- an open [`BrowserPin`](#synchronous-c-callbacks).

Each holder lets go at a definite point:

| Holder | Lets go when |
| --- | --- |
| JavaScript wrapper | `release()` is called |
| One-shot request (`start`) | its `completion` or `failure` returns or raises, or the request is cancelled or closed |
| Listener (`listen`) | the request is cancelled or closed |
| `BrowserPin` | the pin is closed or collected |

State close lets go of everything that remains. A one-shot whose outcome can
never be delivered (its event cannot be marshalled, and neither can the
failure that replaces it) may keep its callables until the request is closed
or its state closes, so close the requests you keep.

A wrapper's `release()` is synchronous: the wrapper stops working at once,
and Titan drops the wrapper's hold in the same call, leaving the other
holders in place. If the instance cannot be entered then (during disposal,
after an exit, or after an engine failure), that hold lasts until state
close. Exporting the function again after a release gives JavaScript a fresh
wrapper, never the released one.

If a crossing fails before JavaScript receives the callable wrapper (for
example, a later argument raises during marshalling, or a host `call` or
`start` target is not callable), any provisional pin created for that crossing
is rolled back in the same operation. Once a wrapper has been passed into a
host binding function, it remains live even if that binding later throws,
returns an unmarshallable value, or returns an invalid request ownership
form; for a refused `start` or `listen`, only the request's `completion` and
`failure` holds are rolled back.

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

An immediate `instance.call()`, `callTask()` or `drain()` attempted inside an
active import returns a rejected `TITAN_BROWSER_REENTRY` promise. It does not
throw synchronously into the import, and is not automatically propagated into
Titan. Observe the rejection, enqueue a notification, or use a tracked request
instead. While a drive is active, a call made outside any import is queued
for the driver rather than rejected
([calls during a drive](browser-target.md#calls-during-a-drive)).

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
function failure_text(message: BrowserValue, thrown: BrowserValue): string?
```

Both methods invoke the host binding synchronously with the supplied
`BrowserValue` arguments without awaiting host work, and pin `completion` and
`failure` until the request can deliver nothing more ([callables and
pinning](#callables-and-pinning)).
- For a one-shot `start` request, `completion` receives one `BrowserValue`
  argument: the host promise's settled value marshalled by runtime type
  (`undefined` becomes `BrowserValue.is_nil()`).
- For a `listen` request, each `emit(...args)` call passes its arguments
  marshalled by runtime type to `completion`.
- For both, `failure` receives two arguments:
  `(BrowserValue.is_string(message), BrowserValue.is_handle(thrown))`, the
  diagnostic message text and a `BrowserHandle` retaining the exact thrown or
  rejected JavaScript value (even when a primitive was thrown).
- A `start` settlement value or `listen` emission argument that cannot be
  marshalled (for example, an out-of-range `BigInt`, an ill-formed UTF-16
  string with a lone surrogate, or a foreign or released callable wrapper) is
  delivered to `failure` in the same way, with the marshalling error as
  `thrown`. Most such errors are found when the event is queued. One found
  only at delivery, such as a wrapper released in the meantime, joins the
  queue behind the events already waiting, so `failure` runs in a later
  batch.

`failure_text(message, thrown)` consumes the failure's thrown-value handle
when `thrown` is `is_handle`, and returns the message only when `message` is
`is_string`; otherwise it returns nil. Use it when the diagnostic is enough
and the exact thrown value is no longer needed. The caller supplies any
default text and chooses its own error type and operation name.

Because callables are not signature-checked at registration time, type errors
move from registration to call time: if `completion` or `failure` raises when
delivered, that callback failure is reported through `onNotificationError`
(`kind: "callback"`, with `operation: "drain"`, or the operation that contains
the drive). A failure event that itself cannot be marshalled is reported
there too, because no callable is left to receive it. Host promise rejection
is delivered to `failure`, not to `onNotificationError`.

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
request still delivers its queued success or failure notification unless it is
cancelled or closed before delivery.

On an idle instance the host calls `drain()` to deliver one detached FIFO
batch. While a drive is active, the driver delivers the owner state's queued
notifications and request events between its turns instead, in the same FIFO
order and at most once each; `drain()` then rejects with
`TITAN_BROWSER_REENTRY`. Imports which enqueue more work add it to the next
batch. A released target is retired without delivery; a released queued
argument of a plain notification is reported without entering Titan. A request
event instead follows the failure rule above.

Disposal first closes application admission, then permits only physical
retirement, then closes the state. With an active drive or an `async` Runtime
to clean up, the owner state's settlements and listener events keep flowing
to the cleanup until that drive ends, so cleanup that awaits host work
started before `dispose()` receives its outcome. Cleanup cannot start new
host work: after `dispose()`, `start` and `listen` raise a
`browser.BrowserError` whose message is `"browser state is closing"`.
Requests still open when the cleanup ends are cancelled then: listeners
unregister, detachable requests retire at once, and retained requests keep
their owner until they settle.

## Reserved SDK bindings

Binding names that start with `titan:` belong to the SDK: `binding(name)`
resolves them to sources the loader owns, never to a `create({bindings})`
entry, and `create` rejects a `bindings` key with that prefix with
`TypeError`. An unknown `titan:` name raises like any unknown binding.

These sources are SDK-internal. Applications use
[`timer`](standard-library-timer.md#on-the-browser), the
[`os` parent streams](standard-library-os.md#browser-parent-streams),
[`http`](standard-library-http.md#on-the-browser), and
[`websocket`](standard-library-websocket.md#on-the-browser), not the reserved
binding protocol.

| Name | Use | Behavior |
| --- | --- | --- |
| `titan:timeout` | `start(completion, failure, is_float(ms))` | One detachable host timer: `completion` receives `is_nil()` after `ms` milliseconds. `cancel` clears the host timer. A delay outside 0 through 2,147,483,647 ms, or a non-`Number` delay, makes `start` raise a `browser.BrowserError` holding a `TypeError`. |
| `titan:interval` | `listen(tick, failure, is_float(ms))` | One host interval: `tick` receives no arguments every `ms` milliseconds. Unregistering clears the host interval. A non-positive period, a period above 2,147,483,647 ms, or a non-`Number` period makes `listen` raise a `browser.BrowserError` holding a `TypeError`. |
| `titan:driver` | reserved | The registration point for the `async` runtime's Task entry points. Only the instance owner state's registration is used; others are ignored. |
| `titan:stdout` | `start(completion, failure, is_bytes(data))`, or no data argument | One retained output request in stdout's FIFO. Completion receives `is_nil()` after its sink settles. With no argument, calls `stdoutEnd` after earlier entries; a missing hook rejects with `TypeError`. |
| `titan:stderr` | `start(completion, failure, is_bytes(data))`, or no data argument | The same output-request contract for stderr and `stderrEnd`. |
| `titan:stdin` | `start(completion, failure)` | One detachable read from `create({stdin})`. The function is invoked synchronously as a binding is; its result or promise settles through the ordinary runtime-type marshalling path. Chunks may be empty; `null` and `undefined` complete with `is_nil()`. Without the option, this is an unknown binding. |
| `titan:stdio` | `call(is_string(name))`, for `stdin`, `stdout`, or `stderr` | Returns the corresponding declared `*Kind` option unchanged, or `is_nil()` when undeclared. The loader does not validate kinds. |
| `titan:fetch` | an operation name as the first argument: `call` for `has-cache`, `new`, and `close`; `start` for `open` and `read` | One host `fetch` per session. `has-cache` reports whether the host has an HTTP cache: a document or worker host that is not Node. `new` returns a session handle owning an `AbortController`. `open` takes `(session, url, method, body, cache, credentials, mode, redirect)` (the body as bytes or `is_nil()`, the four modes as Fetch strings), then alternating header name and value bytes, and starts `fetch`; it completes with one byte string of NUL-terminated fields: status, `1` or `0` for `redirected`, status text, URL, response type, then each header name and value. `read` completes with the next body chunk as bytes, or `is_nil()` at the end. `close` cancels the body reader and aborts the session's controller. |
| `titan:websocket` | an operation name as the first argument: `listen` for `connect`; `call` for `take`, `buffered`, `send`, and `close` | One host `WebSocket` per connection. `connect` takes the URL and then each offered subprotocol as trailing strings, and emits `open` (the socket handle and selected subprotocol), `text` or `binary` (the message length and a handle to a holder of its bytes), and `close` (code, reason, and `wasClean`); unregistering removes its three listeners and closes the socket. `take(holder)` returns the holder's bytes and clears it. `buffered(socket)` returns `bufferedAmount`, or -1 when the socket is not open. `send(socket, payload)` sends a text (`is_string`) or binary (`is_bytes`) payload only while the socket is open and returns whether it did. `close(socket, code, reason)` closes the socket, with no code or reason when `code` is `is_nil()`. |

Their callbacks are ordinary queued notifications, delivered by `drain()` or
a drive.

Output requests have no host cancel function: cancelling or closing a
request withdraws its callbacks, not bytes already admitted to the stream.
A Titan sink or end-hook failure reaches only that request's failure
callable. A C-stdio sink failure keeps its operation-level reporting and is
also delivered once to the next Titan write on the same stream. See the
[loader's output contract](browser-target.md#the-loader-api).

## Driver interface (low-level)

These members are the primitives of a browser drive, which the `async`
runtime's driver uses to run Tasks. Applications use `async`; a program that
drives the instance itself takes over the same contract.

```text
const RELINQUISH_RESUMED = 0
const RELINQUISH_IDLE = 1
const RELINQUISH_DISPOSING = 2
function is_owner(): boolean
function drive_begin()
function drive_end(exit_code: integer?)
function relinquish(wait: boolean): integer
function deliver()
function wake()
function main_failed(message: string, trace: string)
```

- `is_owner()` is true only in the Lua state the generated launcher created
  for the instance. A state created by C code never owns the instance.
- `drive_begin()` starts the instance's drive. Only the owner state's main
  thread (not a coroutine or Task) may drive, and only one drive runs at a
  time; otherwise it raises `"browser drive requires the instance owner's main
  thread"` or `"browser drive is already active"`. While the drive runs,
  JavaScript calls made outside any binding or sink are queued for it.
- `deliver()` runs the owner state's host items queued when it starts:
  notifications, request settlements and listener events, and queued calls.
  Each runs once, in FIFO order, outside any Task; a failure is reported
  through `onNotificationError` (a notification) or rejects that call's
  promise. Items queued while it runs wait for the next `deliver()`.
- `relinquish(wait)` gives the event loop back. With `wait = false` it resumes
  after one host macrotask (`setImmediate` in Node, a `MessageChannel` message
  in browsers, never a clamped timer) and returns `RELINQUISH_RESUMED`. With
  `wait = true` it returns `RELINQUISH_IDLE` at once when the state has no
  wake source (no queued item, open request or listener, open `BrowserPin`,
  or pending wake);
  otherwise it resumes after a wake source fires, from a macrotask, with
  `RELINQUISH_RESUMED`. While the drive is relinquished, buffered output,
  including C standard I/O, goes to the sinks; an immediate `RELINQUISH_IDLE`
  leaves it buffered for the next relinquish or the end of the operation.
  Once `dispose()` has begun, the first relinquish returns
  `RELINQUISH_DISPOSING` after one macrotask and every later resumed
  relinquish returns `RELINQUISH_DISPOSING`; a wait with no wake source still
  returns `RELINQUISH_IDLE`.
- `drive_end(exit_code)` ends the drive. A present `exit_code` latches the
  instance as exited with its low 32 bits as a signed status: `run()`
  reports `exited` and later entries reject `TITAN_BROWSER_EXITED`. Queued
  calls still running or never delivered reject too; a call that already
  settled keeps its result, including a Task-form call whose Task finished
  before the exit ([loader exit](browser-target.md#exit)).
- `deliver()`, `relinquish()` and `drive_end()` require the driving owner's
  main thread outside a delivered handler and raise `"browser delivery …"`,
  `"browser relinquish …"` or `"browser drive_end requires the driving
  owner's main thread outside delivery"` otherwise.
- `wake()` wakes a relinquished drive. It is harmless from any state, thread
  or handler, and without a drive.
- `main_failed(message, trace)` is how the `async` bootstrap reports a failed
  main Task, whose report the drive already wrote: `run()` resolves
  `{kind: "failed", status: 1}` with these message and trace bytes, unless the
  entry itself failed or a drive latched an exit. Only the owner state may call
  it (`"browser main_failed requires the instance owner state"`), and only a
  pending `run()` records it.

A minimal drive that waits until a delivered callback reports completion:

```titan
local browser = import "browser"

function drive_until(done: function (): boolean)
  browser.drive_begin()
  defer browser.drive_end(nil)
  while not done() do
    browser.deliver()
    if done() or browser.relinquish(true) ~= browser.RELINQUISH_RESUMED then return end
  end
end
```

## Synchronous C callbacks

An Emscripten API that calls C from JavaScript, such as an
`emscripten/html5.h` event callback, runs that C function synchronously, with
JavaScript frames between it and any promising entry. Titan code runs in such
a callback through a pin and the C entry `titan_browser_call_sync`:

```text
record BrowserPin
function pin(callback: function (...: BrowserValue): BrowserValue): BrowserPin
function BrowserPin:identity(): (integer, integer, integer)
function BrowserPin:close()
```

```c
/* titan/browser.h */
typedef struct titan_browser_identity {
  uint32_t state, slot, generation;
} titan_browser_identity;

typedef struct titan_browser_sync_result {   /* the caller zero-initializes it */
  uint32_t status;                           /* the returned titan_browser_status */
  uint32_t reserved;
  titan_browser_value value;                 /* TITAN_BROWSER_OK: the one result */
  const unsigned char *message;              /* a failure's message, malloc-owned */
  uint32_t message_length;
  const unsigned char *trace;                /* TITAN_BROWSER_TITAN_ERROR: raw trace, malloc-owned */
  uint32_t trace_length;
} titan_browser_sync_result;

int titan_browser_call_sync(const titan_browser_identity *callable, uint32_t argc,
    const titan_browser_value *args, titan_browser_sync_result *result);
```

- `pin(fn)` holds `fn` for C: it adds one hold to the function's callable pin,
  the slot its JavaScript wrapper also uses. `identity()` returns the
  `(state, slot, generation)` that C copies into a `titan_browser_identity`
  for the callback's user data. `close()` drops the hold; closing again does
  nothing, and an unreachable pin closes itself. After `close()`,
  `identity()` reports slot 0 with the same state and generation, which names
  no callable. `pin` raises `"browser state is closing"` while its state
  closes.
- Keep the pin and the identity's storage reachable, for example an `owned
  *titan_browser_identity` in a module variable, until the C callback is
  unregistered. Unregister it before closing the pin or releasing anything else
  the callback reaches.
- While a `BrowserPin` of the owner state is open, a drive's `relinquish(true)`
  waits instead of returning `RELINQUISH_IDLE`, because a callback may still
  come. An `async` Task waiting for something only a callback provides keeps
  its Runtime waiting while the pin is open.
- `titan_browser_call_sync` runs the pinned function with `argc` arguments read
  from `args` and decoded by runtime type, as for any call into Titan. HANDLE
  arguments are borrowed: C keeps each slot it passes, and the function
  receives its own `BrowserHandle`, whose `close()` or collection never
  releases C's slot. It stores the status it returns in `result->status`:
  - `TITAN_BROWSER_OK`: `result->value` is the one result. A STRING or BYTES
    result has `malloc`'d bytes. A HANDLE result stays valid while its
    `BrowserHandle` is open, and a CALLABLE result while a `BrowserPin` or a
    live JavaScript wrapper holds the function.
  - `TITAN_BROWSER_TITAN_ERROR`: the function raised; `message` and `trace`
    hold its message and raw traceback. The instance stays usable. A stale
    identity, whose function no pin or wrapper holds any longer, fails this
    way with `"browser callable is released"`.
  - `TITAN_BROWSER_STATE`: refused without running Titan, with a `message`. The
    pin's state is closed or closing, the instance is disposing, exited or
    poisoned, or callbacks nest too deeply.
  - `TITAN_BROWSER_MEMORY`: the callback could not start, or a C-heap copy of
    its result, message or trace, or of a refusal's message, could not be
    allocated. It carries no message, trace or value.

  After any status, the caller frees `message`, `trace` and a STRING or BYTES
  result's bytes with `free`.
- A callback may run whenever the instance is open: idle, while a drive waits
  or between its turns, and nested in a binding that Titan code called,
  including from a Task. It runs on a Lua thread of its own (one per nesting
  depth, reused), so a parked drive's frames stay untouched.
- A callback cannot suspend. Inside it, `coroutine.resume`, `coroutine.yield`
  and the other explicit switches raise, `coroutine.running()` is `nil`, every
  `async` operation behaves as outside a Task, and resumptions it causes wait
  for the drive ([coroutines](coroutines.md#in-a-synchronous-callback),
  [async](async-io.md#synchronous-callbacks)).
- JavaScript that a callback reaches follows the loader's
  [entry rules](browser-target.md#synchronous-c-callbacks). A binding that the
  callback's Titan code calls cannot start another entry: `call()`,
  `callTask()`, `drain()` and `run()` reject `TITAN_BROWSER_REENTRY` there.
  JavaScript outside any binding, such as the code that dispatched the event,
  can, and the entry starts after the callback returns. `notify()` queues, and
  `dispose()` finishes closing after the callback returns.
- A callback whose frames an exception unwinds, so that
  `titan_browser_call_sync` never returns, poisons the instance with
  `TITAN_BROWSER_PROTOCOL`, `"a synchronous C callback ended by an
  exception"`. Authored C that switches stacks inside the callback by calling a
  suspending import does that: the engine throws to the callback's JavaScript
  caller (V8 throws `WebAssembly.SuspendError`).
- A callback's C frames use the linear stack of the code it interrupted: the
  main C stack or, for a callback nested in a binding that a Task called, that
  Task's 256 KiB stack ([limits](browser-target.md#limits)). Deep recursion
  there fails Emscripten's stack check, which poisons the instance.

For example, this program counts clicks on two buttons. Titan imports
`html5.h` directly and registers each button's callback with a pinned
handler's identity as its user data. It calls
`emscripten_set_click_callback_on_thread` because the shorter
`emscripten_set_click_callback` spelling is a function-like macro.

The callback is a [foreign function](foreign-functions.md), whose C type is
html5's `em_mouse_callback_func`. Its result aggregate is a
[zeroed local](foreign-functions.md#zeroed-locals), which
`titan_browser_call_sync` requires. The pinned handlers return nil, so only a
failure's message and trace need freeing; `lmacro_unconst` of `titan/ffi.h`
passes a pointer to const where `free` takes a plain one.

The module keeps each listener's pin and identity until `stop` unregisters
it, and shows the count through the page's `show` binding. A listener is
rooted in `listeners` before C receives its identity, so nothing can fail
after the registration and leave C a dangling pointer, and a failure after a
registration unregisters what was registered:

```titan
local browser = import "browser"
foreign import "emscripten/html5.h"
foreign import "stdio.h"
foreign import "stdlib.h"
foreign import "titan/browser.h"
foreign import "titan/ffi.h"

local type Value = browser.BrowserValue

local count = 0

local function show()
  local label = browser.binding("show")
  defer label:close()
  label:call(Value.is_integer(count))
end

local function increment(...: Value): Value
  count = count + 1
  show()
  return Value.is_nil()
end

local function reset(...: Value): Value
  count = 0
  show()
  return Value.is_nil()
end

local record Listener
  selector: string
  pin: browser.BrowserPin
  identity: owned *titan_browser_identity
end

local listeners: {Listener} = {}

local foreign function counter_click(kind: int, event: const *EmscriptenMouseEvent,
                                     identity: *void): bool
  local result = foreign titan_browser_sync_result.new()
  local status = ffi.titan_browser_call_sync(
    identity as const *titan_browser_identity, 0, nil, result)
  if status ~= ffi.TITAN_BROWSER_OK then
    if result.message ~= nil then
      ffi.fprintf(ffi.stderr, "click handler failed: %.*s\n",
        result.message_length as int, result.message as const *char)
    end
  end
  ffi.free(ffi.lmacro_unconst(result.message))
  ffi.free(ffi.lmacro_unconst(result.trace))
  return false
end

local function listen(selector: string, handler: function (...: Value): Value)
  local pin = browser.pin(handler)
  local identity: owned *titan_browser_identity = foreign titan_browser_identity.new()
  local state, slot, generation = pin:identity()
  identity.state = state
  identity.slot = slot
  identity.generation = generation
  local index = #listeners + 1
  listeners[index] = Listener { selector = selector, pin = pin, identity = identity }
  if ffi.emscripten_set_click_callback_on_thread(
      selector, identity, 0, counter_click,
      ffi.EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD) ~= ffi.EMSCRIPTEN_RESULT_SUCCESS then
    listeners[index] = nil
    pin:close()
    raise "cannot listen for clicks on " .. selector
  end
end

local function stop(...: Value): Value
  for index = #listeners, 1, -1 do
    local listener = listeners[index]
    ffi.emscripten_set_click_callback_on_thread(
      listener.selector, nil, 0, nil, ffi.EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD)
    listener.pin:close()
    listeners[index] = nil
  end
  return Value.is_nil()
end

function main(_args: {string}): integer
  listen("#increment", increment)
  listen("#reset", reset)
  show()
  local ready = browser.binding("ready")
  defer ready:close()
  ready:call(Value.is_callable(stop))
  return 0
catch
  stop()
  raise
end
```

The page supplies `show` and `ready`. Each click runs its handler before
`click()` returns, so the label is already updated. The page calls `stop`
before disposal, which frees what the callbacks reach:

```javascript
import create from './counter.mjs';

const label = document.querySelector('#count');
let stop;
const instance = create({bindings: {
  show: count => { label.textContent = String(count); },
  ready: callable => { stop = callable; },
}});
try {
  await instance.run([]);
  document.querySelector('#increment').click();
  console.log(label.textContent); // "1"
} finally {
  if (stop) await instance.call(stop);
  await instance.dispose();
}
```

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
idempotent handle `close()` remain valid until that invalidation. A wrapper's
`release()` stays valid too; a function released then is let go when the
state finishes closing. New requests, listeners, and reverse application
calls are refused, including for an independent state closing while its
containing instance is not disposing.

An object's earlier-registered finalizer runs after the browser record. Its
`close()` and callable release operations are no-ops; binding lookup and calls
raise. An uncaught raise is reported as a Lua finalizer warning on stderr, not
an invented failed application call.

## C SDK

The installed `titan/browser.h` declares the checked wasm32 scalar/slot,
response, completion, and state-registry boundary. Apart from
`titan_browser_call_sync`, which runs whenever the instance is open
([synchronous C callbacks](#synchronous-c-callbacks)), its API requires the
same instance execution owner as the generated gateway; it is not a raw
`lua_State *` application gateway. `titan_browser_callback_enter` and
`titan_browser_callback_leave` bracket a standard library's hand-written
trampolines and are not an application API. Independent states created by
[`lua.new()`](standard-library-lua.md#independent-lua-states) or C load
`titan.browser` normally; there is no attachment operation or special
bootstrap order. See [the bridge implementation](../implementation/browser-bridge.md)
for layout, ownership, initialization, and close rules. Native SDKs may
install the header, but native providers contain no `titan.browser` or fake
bridge runtime.
