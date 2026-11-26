# JavaScript bindings (`titan.browser`)

`titan.browser` connects WebAssembly programs compiled with `--target browser`
to host JavaScript bindings, `BrowserValue` marshalling, pinned callbacks,
asynchronous requests and listeners, and synchronous C callbacks.
See [WebAssembly and the Browser Target](browser-target.md) (and its
[complete application](browser-target.md#a-complete-application)) for image
lifecycle, loader options, output sinks, and deployment.

- **Import:** `local browser = import "browser"` (Titan) · `require "titan.browser"` (Lua)
- **Targets:** Browser only (`--target browser`; depends only on `gc`, with no libuv requirement)

## Quick example

Look up explicit host bindings with `browser.binding`, call JavaScript with
`BrowserValue` arguments, and export a stateful Titan closure that JavaScript
invokes later:

```titan
local browser = import "browser"

local type Value = browser.BrowserValue

local function expect_integer(v: Value): integer
  case v
  when is_integer(n) then return n
  end
  raise "expected an integer BrowserValue"
end

function main(_args: {string}): integer
  local count = 0
  local set_text = browser.binding("set_text")
  defer set_text:close()
  local register = browser.binding("on_increment")
  defer register:close()

  set_text:call(Value.is_string("Count: 0"))

  local increment = function(...: Value): Value
    count = count + expect_integer(...[1])
    local label = browser.binding("set_text")
    defer label:close()
    label:call(Value.is_string("Count: " .. count))
    return Value.is_integer(count)
  end
  register:call(Value.is_callable(increment))
  return 0
end
```

The host page supplies `bindings` to `create(options)` and invokes the exported
callable as an async operation (general JavaScript calls into Titan always
return Promises, because allocation can run finalizers or coroutine cleanup):

```javascript
import create from "./out/counter.mjs";

const label = document.querySelector("#count");
let increment;
const instance = create({
  bindings: {
    set_text(text) { label.textContent = text; },
    on_increment(fn) { increment = fn; },
  },
});
try {
  await instance.run([]);
  await increment.call(1n); // Count: 1
  await increment.call(4n); // Count: 5
} finally {
  await instance.dispose();
}
```

Always await `instance.dispose()` in `finally` to release pinned handles and
run state finalizers.

## Public surface and marshalling

```text
record BrowserHandle
record BrowserRequest
record BrowserError
  const message: string
  const thrown: BrowserHandle
end

union BrowserValue
  is_nil()
  is_boolean(value: boolean)
  is_integer(value: integer)
  is_float(value: float)
  is_string(value: string)
  is_bytes(value: string)
  is_handle(value: BrowserHandle)
  is_callable(value: function(...: BrowserValue): BrowserValue)
end

function binding(name: string): BrowserHandle
function BrowserHandle:call(...: BrowserValue): BrowserValue
function BrowserHandle:close()
function BrowserError:close()
```

Host bindings come strictly from `create({ bindings })`; names are looked up
literally rather than evaluated as global expressions, and methods needing a
specific `this` receiver must be bound by the host. `binding(name)` returns a
`BrowserHandle` for the exact supplied value (including `false`, `0`, `null`,
and `undefined`).

Values cross the JavaScript boundary as `BrowserValue` by runtime type:

| JavaScript | `BrowserValue` | JavaScript (returned) |
| --- | --- | --- |
| `undefined`, `null` | `is_nil()` | `null` |
| `boolean` | `is_boolean(boolean)` | `boolean` |
| `BigInt` (signed 64-bit, range checked) | `is_integer(integer)` | `BigInt` |
| `Number` | `is_float(float)` | `Number` (`NaN` and `-0` preserved) |
| `string` (well-formed UTF-16) | `is_string(string)` (UTF-8) | `string` (UTF-8 decoded) |
| `Uint8Array` | `is_bytes(string)` (copied) | `Uint8Array` (copied) |
| Titan callable wrapper | `is_callable(fn)` (original function) | Same wrapper |
| Any other value (objects, Arrays, JS functions, Promises) | `is_handle(BrowserHandle)` | Underlying JS value |

Marshalling rules:

- `target:call(...)` returns one `BrowserValue`; inspect it with `case`.
- Integers cross strictly as signed 64-bit `BigInt` (even below 2^53: write
  `5n` in JavaScript). A JavaScript `Number` always arrives as `is_float`, and
  out-of-range `BigInt` values raise `TypeError`.
- `is_string` requires well-formed UTF-16 from JavaScript (`isWellFormed()`;
  lone surrogates raise `TypeError`) and valid UTF-8 from Titan.
- `is_bytes` copies arbitrary binary bytes (including empty buffers, embedded
  NULs, and non-UTF-8 bytes) to and from `Uint8Array`.
- A JavaScript `Promise` returned by a binding arrives as `is_handle`. Holding
  the handle does not observe rejections; attach rejection handling on the host
  side when needed.

## Copying typed values

Use [`protobuf.portable`](standard-library-protobuf.md#portable-codecs) when
JavaScript needs typed copies of Titan records, unions, and Arrays instead of
opaque handles. Pass `codec:describe()` and `codec:encode(...)` bytes to a
binding; the SDK's standalone `titan-protobuf.mjs` generates matching
JavaScript classes without loading Titan modules.

Save this program as `app.titan`:

```titan
local browser = import "browser"
local protobuf = import "protobuf"
local reflect = import "reflect"
local io = import "io"

local type Value = browser.BrowserValue

record Point
  x: float
  y: float
end

local codec = protobuf.portable({
  reflect.Type.is_named(reflect.NamedType("app.Point")),
  reflect.Type.is_string(),
}, nil, {"2"})

function main(_args: {string}): integer
  local target = browser.binding("publish")
  defer target:close()
  local result = target:call(Value.is_string(codec:describe()),
    Value.is_bytes(codec:encode(Point(1.0, 2.0), "origin")))
  case result
  when is_bytes(bytes) then
    local point: Point, label: string = codec:decode(bytes)
    io.print(point.x, point.y)
    io.print(label)
  else
    raise "publish must return encoded bytes"
  end
  return 0
end
```

Build and copy the peer from `$PREFIX`:

```sh
titanc --target browser --tree . -o out --exe out/app.mjs app
cp "$PREFIX/lib/titan-browser/0.6/titan-protobuf.mjs" .
```

Host page (`index.html`, served over HTTP to a JSPI-capable browser):

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

`encode` takes one argument per declared root field and `decode` returns a
JavaScript Array in field order:

| Titan value / declared type | JavaScript representation |
| --- | --- |
| `nil` or absent Option | `null` |
| `boolean` | `boolean` |
| `integer` | Signed 64-bit `BigInt` |
| `float` | `Number` (`NaN` and `-0` preserved) |
| Unmarked `string` | `Uint8Array` |
| `string` marked in `text` | `string` (strict UTF-8/UTF-16 checked) |
| Array | `Array` (holes decode as `null`; `const` Arrays are `Object.freeze`'d) |
| Public record | Instance of `codec.types[qualifiedName]` |
| Public union variant | Instance of `codec.types[qualifiedName].variants[variantName]` |

Record and variant constructors take fields or parts in declaration order
(missing arguments default to `null`; extra arguments throw `TypeError` with
code `type_mismatch`). Plain objects are not accepted as nominals; subclasses
of generated classes encode as their base nominal. Share class tables across
codecs by passing `first.types` as the second argument to
`portable(description, first.types)` when descriptions match identically.

Send live JavaScript handles or Titan callables as separate `is_handle` /
`is_callable` arguments alongside `is_bytes(bytes)` rather than inside encoded
data.

### Copy errors

`titan-protobuf.mjs` throws `TypeError` with `code` (`invalid_utf8`,
`type_mismatch`, `integer_range`, `missing_field`, `unknown_type`,
`unknown_variant`, `cycle`, `limit_exceeded`, `malformed_wire`,
`invalid_description`) and a JSON-style `path` (for example `$[1]["label"]`).
The JavaScript peer accepts canonical Titan output and strictly rejects
protobuf groups, mismatched wire types in repeated scalars, and invalid UTF-8
in dynamic nominal names.

Peer errors thrown in a binding reach Titan as catchable `BrowserError` values
(keeping `code` and `path` on `thrown`), and Titan codec errors reject the
JavaScript call with `TITAN_BROWSER_TITAN` (with [protobuf error
paths](standard-library-protobuf.md#errors)) without poisoning the instance.

## JavaScript values

Each `BrowserHandle` owns one state-local JavaScript reference. Call
`handle:close()` explicitly with `defer` (closing an already-closed handle is a
no-op); unreachable handles also release via a reachability finalizer, and
state close retires all remaining handles.

A closed handle cannot be called or passed as an argument, handles from another
instance or Lua state are rejected, and slot reuse never revives a closed
handle. `null` and `undefined` returned by `binding(name)` or thrown as
exceptions are ordinary live handles.

## Callables and pinning

A Titan `function(...: BrowserValue): BrowserValue` crosses to JavaScript via
`BrowserValue.is_callable(fn)` (or as `start`/`listen` callbacks). Each
exported function receives one pin slot and one JavaScript wrapper per Lua
state (`w1 === w2`), and passing that wrapper back to Titan recovers the
original function—preserving shared mutable capture cells without copying.

A callable stays pinned while any holder is active:

| Holder | Released when |
| --- | --- |
| JavaScript wrapper | `wrapper.release()` is called (synchronously via `release_callable`) |
| One-shot request (`start`) | `completion`/`failure` returns or raises, or the request cancels/closes |
| Listener (`listen`) | The request cancels or closes |
| [`BrowserPin`](#synchronous-c-callbacks) | The pin closes or is collected |

State close releases all remaining holds. `wrapper.release()` invalidates the
wrapper immediately and drops its hold synchronously via the bridge's
`release_callable` entry without disturbing other holders; exporting the same
function again creates a fresh wrapper. If a binding call fails during argument
marshalling before entering JavaScript, provisional pins created for that call
roll back automatically.

Because JavaScript and Lua garbage collectors do not trace across heaps, break
cross-heap reference cycles explicitly with `wrapper.release()`, `handle:close()`,
or `instance.dispose()`.

Calling `instance.call(wrapper, ...args)` or `wrapper.call(...args)` resolves
to the single decoded `BrowserValue` (adopting any returned Promise/thenable
handle, while bridge admission and `dispose()` depend only on the Wasm call's
return). A Titan raise rejects the Promise with `TITAN_BROWSER_TITAN`, the
error message, and the captured Titan traceback.

## Errors

`BrowserError` carries read-only `message: string` and `thrown: BrowserHandle`
retaining the exact thrown JavaScript value (`Error`, string, `null`,
`undefined`, etc.). Call `failure:close()` when finished with `thrown`:

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

If handle creation itself fails (such as out of memory or handle-identity
exhaustion), Titan raises a plain diagnostic string and keeps the instance
usable. Uncaught Titan raises reject JavaScript calls with
`TITAN_BROWSER_TITAN` ([loader API](browser-target.md#the-loader-api)). Traps,
aborts, and protocol errors poison the instance instead.

Calling `instance.call()`, `callTask()`, or `drain()` synchronously inside an
active binding import returns a rejected `TITAN_BROWSER_REENTRY` Promise.
Outside any import while a drive is active, calls queue for the driver
([calls during a drive](browser-target.md#calls-during-a-drive)).

## Requests and listeners

```text
function BrowserHandle:start(
    completion: function(...: BrowserValue): BrowserValue,
    failure: function(...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
function BrowserHandle:listen(
    completion: function(...: BrowserValue): BrowserValue,
    failure: function(...: BrowserValue): BrowserValue,
    ...: BrowserValue): BrowserRequest
function BrowserRequest:cancel()
function BrowserRequest:close()
function failure_text(message: BrowserValue, thrown: BrowserValue): string?
```

`start` and `listen` invoke the host binding synchronously and pin `completion`
and `failure` until the request retires:

- **`start` (one-shot):** The binding returns either
  `{ kind: "detachable", promise, cancel? }` (for work that may stay pending
  past disposal) or `{ kind: "retained", promise, cancel? }` (for work
  guaranteed to settle that requires retained ownership until settlement).
  `completion` receives the single settled `BrowserValue`; `failure` receives
  `(is_string(message), is_handle(thrown))`.
- **`listen` (multi-event):** The binding returns
  `{ kind: "listener", subscribe(emit): unregister }`. Each `emit(...args)`
  enqueues arguments for `completion` in FIFO order without entering Titan
  inline; `unregister` is idempotent. Cancelling or closing a listener inside a
  callback suppresses remaining events in the current batch.
- **Marshalling failures and `failure_text`:** Unmarshallable settlement or
  emission values route to `failure` with the marshalling `TypeError` as
  `thrown`. `failure_text(message, thrown)` closes `thrown` if it is a handle
  and returns `message` if it is a string (otherwise `nil`). Exceptions thrown
  by `completion`/`failure` themselves route to `onNotificationError`.

On an idle instance, `instance.drain()` delivers one FIFO batch; during an
active drive, the driver delivers queued events between turns. After
`instance.dispose()` begins, in-flight events keep delivering while Runtime
cleanup runs, while new `start`/`listen` calls raise `BrowserError` with
`"browser state is closing"`.

## Reserved SDK bindings

Binding names starting with `titan:` are reserved for the browser SDK (passing
a `titan:` key in `create({ bindings })` throws `TypeError`). Application code
should use [`timer`](standard-library-timer.md#on-the-browser),
[`os`](standard-library-os.md#browser-parent-streams),
[`http`](standard-library-http.md#on-the-browser), and
[`websocket`](standard-library-websocket.md#on-the-browser) directly.

| Name | Form | Behavior |
| --- | --- | --- |
| `titan:timeout` | `start(ok, fail, is_float(ms))` | Detachable host timer (`0..2,147,483,647` ms); completes with `is_nil()`. |
| `titan:interval` | `listen(tick, fail, is_float(ms))` | Host interval (`1..2,147,483,647` ms); emits no arguments per tick. |
| `titan:driver` | reserved | Registers the owner state's `async` Task entry points. |
| `titan:stdout`, `titan:stderr` | `start(ok, fail, is_bytes(data)?)` | Retained FIFO output request; omitting `data` invokes `stdoutEnd`/`stderrEnd`. |
| `titan:stdin` | `start(ok, fail)` | Detachable read from `create({ stdin })`; completes with chunk or `is_nil()`. |
| `titan:stdio` | `call(is_string(name))` | Returns declared `stdinKind`/`stdoutKind`/`stderrKind`, or `is_nil()`. |
| `titan:fetch` | `call` (`has-cache`, `new`, `close`); `start` (`open`, `read`) | Host `fetch` session with `AbortController`, NUL-delimited header pack, and streamed body chunks. |
| `titan:websocket` | `listen` (`connect`); `call` (`take`, `buffered`, `send`, `close`) | Host `WebSocket` lifecycle (`open`, `text`, `binary`, `close`), message extraction, and send/close. |

Output requests have no host cancellation: cancelling or closing withdraws
callbacks without cancelling already-admitted bytes
([loader API](browser-target.md#the-loader-api)).

## Driver interface (low-level)

These primitives implement the browser event-loop drive used by `titan.async`:

```text
const RELINQUISH_RESUMED: integer = 0
const RELINQUISH_IDLE: integer = 1
const RELINQUISH_DISPOSING: integer = 2

function is_owner(): boolean
function drive_begin()
function drive_end(exit_code: integer?)
function relinquish(wait: boolean): integer
function deliver()
function wake()
function main_failed(message: string, trace: string)
```

- `is_owner()` is `true` only in the launcher's primary Lua state.
- `drive_begin()` starts the sole active drive on the owner state's main thread
  (queuing external JS calls while active).
- `deliver()` runs one FIFO batch of queued notifications, request events, and
  queued JS calls outside any Task.
- `relinquish(wait)` yields control to the host event loop via a macrotask
  (`setImmediate` / `MessageChannel`) and flushes buffered output. With
  `wait = false`, it resumes after one macrotask (`RELINQUISH_RESUMED`). With
  `wait = true`, it returns `RELINQUISH_IDLE` immediately when no wake source
  exists (no queued item, open request/listener, open `BrowserPin`, or pending
  wake); otherwise it sleeps until woken. Once `dispose()` starts, resumed
  relinquishes return `RELINQUISH_DISPOSING`.
- `drive_end(exit_code)` ends the drive; a non-nil `exit_code` latches exit
  status on the instance ([loader exit](browser-target.md#exit)).
- `wake()` wakes a waiting drive safely from any state or handler.
- `main_failed(message, trace)` records a failed main Task for `run()`.

```titan
local browser = import "browser"

function drive_until(done: function(): boolean)
  browser.drive_begin()
  defer browser.drive_end(nil)
  while not done() do
    browser.deliver()
    if done() or browser.relinquish(true) ~= browser.RELINQUISH_RESUMED then
      return
    end
  end
end
```

## Synchronous C callbacks

Host WebAssembly imports (supplied through `create({ imports })`) can invoke C
function pointers synchronously from JavaScript via `context.table`. Pin a
Titan callable with `browser.pin` and invoke it from C via
`titan_browser_call_sync`:

```text
record BrowserPin

function pin(callback: function(...: BrowserValue): BrowserValue): BrowserPin
function BrowserPin:identity(): (integer, integer, integer)
function BrowserPin:close()
```

```c
/* titan/browser.h */
typedef struct titan_browser_identity {
  uint32_t state, slot, generation;
} titan_browser_identity;

typedef struct titan_browser_sync_result {   /* caller zero-initializes */
  uint32_t status;                           /* titan_browser_status */
  uint32_t reserved;
  titan_browser_value value;                 /* TITAN_BROWSER_OK result */
  const unsigned char *message;              /* malloc-owned on error */
  uint32_t message_length;
  const unsigned char *trace;                /* malloc-owned on TITAN_ERROR */
  uint32_t trace_length;
} titan_browser_sync_result;

int titan_browser_call_sync(const titan_browser_identity *callable, uint32_t argc,
    const titan_browser_value *args, titan_browser_sync_result *result);
```

- `pin(fn)` adds a hold to `fn`'s pin slot and exposes `(state, slot, generation)`
  through `identity()`. Keep both the `BrowserPin` and the C
  `titan_browser_identity` storage rooted until the C callback is unregistered,
  then unregister before calling `pin:close()` (after close, `identity()`
  reports slot `0`). While any owner-state `BrowserPin` is open,
  `relinquish(true)` waits rather than returning `RELINQUISH_IDLE`.
- `titan_browser_call_sync` runs the pinned function on a dedicated reusable
  callback Lua thread with `args` decoded by runtime type (handle arguments are
  borrowed) and stores the status in `result->status`:
  - `TITAN_BROWSER_OK`: `result->value` carries the result (`free` any returned
    `STRING`/`BYTES` buffer).
  - `TITAN_BROWSER_TITAN_ERROR`: the function raised (or the pin was released),
    populating `message` and `trace`; the instance stays usable.
  - `TITAN_BROWSER_STATE`: refused (closed/disposing/exited/poisoned state or
    excessive callback nesting) with `message`.
  - `TITAN_BROWSER_MEMORY`: allocation failure (`message`, `trace`, and `value`
    empty).
  Always `free(result->message)`, `free(result->trace)`, and any `STRING`/`BYTES`
  result buffer.
- Synchronous callbacks cannot suspend: `coroutine.yield`/`resume` and `async`
  waits raise, `coroutine.running()` is `nil`, and Tasks resumed by a callback
  wait for the drive ([coroutines](coroutines.md), [async I/O](async-io.md)).
  Calls use the interrupted linear stack ([limits](browser-target.md#limits)),
  and unwinding out of `titan_browser_call_sync` via a JS/Wasm exception
  poisons the instance ([synchronous callbacks](browser-target.md#synchronous-c-callbacks)).

This complete browser module wires two HTML buttons through a tiny C import
header (`click_host.h`), using a [`foreign function`](foreign-functions.md)
callback with a [zeroed local](foreign-functions.md#zeroed-locals) result
struct:

```c
/* click_host.h */
#include <stdbool.h>
#include "titan/browser.h"

typedef bool (*click_callback)(void *userdata);

TITAN_WASM_IMPORT("set_click_callback")
int set_click_callback(const char *selector, void *userdata, click_callback cb);
```

```titan
local browser = import "browser"
foreign import "click_host.h"
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

local foreign function counter_click(identity: *void): bool
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

local function listen(selector: string, handler: function(...: Value): Value)
  local pin = browser.pin(handler)
  local identity: owned *titan_browser_identity = foreign titan_browser_identity.new()
  local state, slot, generation = pin:identity()
  identity.state = state
  identity.slot = slot
  identity.generation = generation
  local index = #listeners + 1
  listeners[index] = Listener { selector = selector, pin = pin, identity = identity }
  if ffi.set_click_callback(selector, identity, counter_click) ~= 0 then
    listeners[index] = nil
    pin:close()
    raise "cannot listen for clicks on " .. selector
  end
end

local function stop(...: Value): Value
  for index = #listeners, 1, -1 do
    local listener = listeners[index]
    ffi.set_click_callback(listener.selector, nil, nil)
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

On the host page, pass `imports` to `create` to attach DOM click listeners and
invoke the C function pointer through `context.table`:

```javascript
const registered = new Map();
const instance = create({
  bindings: { show, ready },
  imports: (context) => ({
    env: {
      set_click_callback(selectorPtr, userdata, fnPtr) {
        const selector = context.readCString(selectorPtr);
        const element = document.querySelector(selector);
        if (!element) return -1;
        const prev = registered.get(selector);
        if (prev) {
          element.removeEventListener("click", prev);
          registered.delete(selector);
        }
        if (fnPtr !== 0) {
          const fn = context.table.get(fnPtr);
          const onClick = () => fn(userdata);
          element.addEventListener("click", onClick);
          registered.set(selector, onClick);
        }
        return 0;
      },
    },
  }),
});
```

Host page wiring:

```javascript
import create from "./counter.mjs";

const label = document.querySelector("#count");
let stop;
const instance = create({
  bindings: {
    show: count => { label.textContent = String(count); },
    ready: callable => { stop = callable; },
  },
});
try {
  await instance.run([]);
  document.querySelector("#increment").click();
  console.log(label.textContent); // "1"
} finally {
  if (stop) await instance.call(stop);
  await instance.dispose();
}
```

## State close and C SDK

### State close

`titan.browser` registers a state-lifetime record when initialized. On explicit
close, GC close, or later close of a detached state, that record invalidates
all handles, callables, and queued notifications once—after finalizers of
objects created after `titan.browser` initialized. During close, synchronous
binding calls, output admission, idempotent `close()`, and `wrapper.release()`
stay valid until invalidation, while new requests, listeners, and reverse calls
are refused.

### C SDK and bridge entries

The installed `titan/browser.h` header declares the wasm32 bridge boundary.
`titan.browser` exports five C-ABI foreign entries used by the loader, standard
library trampolines, and synchronous C callbacks:

```text
foreign function call_sync(raw_identity: const *void,
                           raw_argc: unsigned int,
                           raw_args: const *void,
                           raw_result: *void): int
foreign function invoke(raw_id: unsigned long long,
                        raw_token: unsigned int,
                        raw_slot: unsigned int,
                        raw_generation: unsigned int,
                        raw_argc: unsigned int,
                        raw_args: const *void): int
foreign function release_callable(raw_token: unsigned int,
                                  raw_slot: unsigned int,
                                  raw_generation: unsigned int): int
foreign function callback_enter(raw_state: unsigned int,
                                raw_frame: *void): int
foreign function callback_leave(raw_frame: *void)
```

- `call_sync` backs `titan_browser_call_sync` for synchronous C callbacks from
  authored C code and host WebAssembly imports.
- `invoke` is the loader's entry for invoking a pinned callable from JavaScript
  (`instance.call` / `wrapper.call` / notification delivery).
- `release_callable` is the loader's synchronous trampoline for
  `wrapper.release()`: it enters a callback thread for `(raw_token, raw_slot, raw_generation)`
  with garbage collection paused, drops the JavaScript wrapper's hold on that
  callable pin, and returns a `titan_browser_status` integer without emitting
  an async completion.
- `callback_enter` and `callback_leave` bracket hand-written standard-library
  callback trampolines.

Independent states created with
[`lua.new()`](standard-library-lua.md#independent-lua-states) or C load
`titan.browser` normally without special bootstrap steps. See
[Browser bridge implementation](../implementation/browser-bridge.md) for layout
and ownership internals.
