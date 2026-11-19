# Transfer policies

The `transfer` module defines how Titan values, closures, and native resources move between isolated Lua states and OS threads. Import it in Titan with `local transfer = import "transfer"` or load it in Lua with `require "titan.transfer"`; `async.TransferValue` is a transparent alias of `transfer.TransferValue`.

**Target availability:** Native & Browser (full API on both targets; cross-thread transports such as `thread.channel` and `async.Receiver` are native-only).

## Example

A public record with private fields can opt into cross-state transfer by defining `to_transfer_payload` and `from_transfer_payload`:

```titan
local io = import "io"
local strings = import "string"
local transfer = import "transfer"

record AuthToken
  local issuer: string
  local expiry: integer
end

function AuthToken.new(issuer: string, expiry: integer): AuthToken
  return { issuer = issuer, expiry = expiry }
end

function AuthToken:summary(): string
  return self.issuer .. "@" .. self.expiry
end

function AuthToken:to_transfer_payload(): string
  return strings.pack("<i8s4", self.expiry, self.issuer)
end

function AuthToken.from_transfer_payload(payload: string): AuthToken
  local expiry: integer, issuer: string = strings.unpack("<i8s4", payload)
  return AuthToken(issuer, expiry)
end

function main(args: {string}): integer
  local policy = transfer.TransferValue.from_value(AuthToken("api", 3600))
  local restored: AuthToken = policy:to_value()
  io.print(restored:summary())
  return 0
end
```

## Core concepts

`transfer` separates **value policy** (`TransferValue`) from **native message packets** (`encode_message` / `decode_message`). The module neither creates an `async` Runtime nor delivers messages on its own; `thread.channel`, `thread.spawn*`, `async.Receiver`, and `lua.Lua:run*` build on it.

Native resources transferred across states fall into two ownership categories:

- **Packet-scoped reference-counted resources** (in the standard library, `thread.Sender<|T|>` and `thread.Receiver<|T|>`) attach to a packet's native resource table and are released automatically in C if an undelivered packet is discarded.
- **Manual-handoff resources** (such as `net.Connection`, `ssl.Connection`, `fs.File`, `sqlite3.Connection`, and `http`/`websocket`/`os` handles, plus custom hooks that do not attach packet resources) detach ownership into opaque byte payloads that the caller must adopt once or explicitly dispose.

## Transfer values and policies

```text
union TransferValue
  is_nil()
  is_boolean(value: boolean)
  is_integer(value: integer)
  is_float(value: float)
  is_string(value: string)
  is_lua_state(value: foreign *lua_State)
  is_function(value: foreign function (*lua_State): int)
  is_pointer(value: foreign *void)
  is_record(module: string, name: string, data: string)
  is_union(module: string, name: string, data: string)
  is_closure(module: string, entry: foreign const *void, data: string)
  is_record_payload(module: string, name: string, data: string)
end

function TransferValue.from_value(candidate: value): TransferValue
function TransferValue.from_closure_payload(module: string, entry: value,
                                            data: string): TransferValue
function TransferValue:to_value(): value
```

- **`TransferValue.from_value(candidate)`** returns an existing `TransferValue` unchanged, and otherwise classifies `candidate` into a scalar, copied byte string, borrowed pointer (`is_lua_state`, `is_function`, `is_pointer`), protobuf-serialized public `record`/`union`, closure snapshot (`is_closure`), or custom payload (`is_record_payload`). Unsupported values—Lua closures, C closures with upvalues, top-level Arrays and Maps, Interfaces, owned foreign storage, and NULL C functions—raise.
- **`TransferValue.from_closure_payload(module, entry, data)`** wraps already-copied closure fields from a trusted Lua or native transport into an `is_closure` policy. It checks that `entry` is a valid raw pointer (`foreign const *void`) at the boundary, deferring manifest validation and capture decoding to `to_value()` in the destination state. Ordinary Titan code uses `TransferValue.from_value(callback)`.
- **`TransferValue:to_value()`** reconstructs the semantic value in the current state, loading the defining module on demand when needed for records, unions, closures, or custom-hook payloads.

See [Transfer values](async-io.md#transfer-values) for the complete type-by-type conversion rules and closure-snapshot behavior.

## Opaque payloads

A public record opts into custom transfer by declaring two public members with these exact signatures:

```text
function Record:to_transfer_payload(): string
function Record.from_transfer_payload(payload: string): Record
```

Both hooks must be synchronous and must not yield. The hook chooses its own byte format; `transfer` records the defining module, qualified nominal name, and returned bytes, while native transports copy and free those strings without interpreting nested resources.

[Protocol Buffers field codecs](standard-library-protobuf.md) (`protobuf.serialize_fields` / `protobuf.deserialize_fields`) let a hook serialize an ordered list of typed fields selected from a private record without declaring an extra public record type. Raw pointers encode as fixed64 addresses under the same-process lifetime contract.

## Native resource handoff

Transfer hooks fall into two ownership categories:

1. **Packet-scoped reference-counted resources**, registered in a native packet's resource table with `attach_resource` and claimed with `claim_resource`. In the standard library these are only [`thread.Sender<|T|>` and `thread.Receiver<|T|>`](standard-library-thread.md#closing-cloning-and-transferring-endpoints). Each encoded occurrence retains its own native reference in the packet and writes a four-byte little-endian packet-local slot index. Decoding claims each slot into a destination wrapper whose finalizer is already registered. Every reference is held either by a live wrapper or by an undelivered packet: claiming moves it, and disposing of a packet via `discard_message` releases all unclaimed references in C without entering Lua, loading modules, running user decoders, or needing an active Runtime. Closing an endpoint changes channel state without releasing its reference.
2. **Manual-handoff resources**, consisting of the specific types in the [inventory below](#manual-handoff-api-inventory) and user hooks that do not call `attach_resource`. Moving an owned resource detaches ownership at encode time and transfers it at adoption time without adding a packet disposer.

Packet attachments use native reference counts rather than a cycle collector. Queued endpoints can keep one another alive outside Lua GC; retain a reachable receiver and call `Receiver:close()` to drain and break cycles before dropping the last handle (see [endpoint lifetime rules](standard-library-thread.md#closing-cloning-and-transferring-endpoints)).

**Native packet discard never decodes payloads or calls `from_transfer_payload`.** Discarding an undelivered packet—through `discard_message`, a rejected `Sender:try_send`, a cancelled `Sender:send`, `thread.Receiver:close()`, `async.Receiver` overwrite or close, or an abandoned `Thread` result—releases only packet-table attachments. Sending a manual-handoff resource over a channel or `async.Receiver` is not transactional: a failed send does not undo detachment, and discarding unread bytes does not close the detached socket, TLS engine, HTTP exchange, WebSocket, file descriptor, or database handle. Recover rejected payloads or dispose of them explicitly, and drain unread manual-handoff payloads before closing a receiver.

An [`async.Receiver`](async-io.md#cross-state-receivers) stores native packets (`encode_message` / `decode_message` / `discard_message`), so it can carry `thread` endpoints; `lua.Lua:run` and `run_async` copy policies over a separate carrier with no resource table and cannot. Standalone `TransferValue.from_value` and `protobuf.serialize` calls open no packet scope, so converting an endpoint outside a packet scope raises. Inside an enclosing packet scope they reuse that packet, and the packet's resource table—not the returned index bytes—owns the attachment. Because `async.Receiver` is lossy and coalescing, keep manual-handoff ownership outside it unless an application protocol guarantees exactly-once adoption or disposal.

Preflight rejection and failed native duplication preserve source ownership (for `os.InputOutputStream`, if duplicating the second pipe fails, the source retains the first pipe's detached payload for later retry or close). If serializing an enclosing composite fails after a built-in hook has detached its resource, built-in hooks dispose of the detached resource before raising; there is no whole-operation rollback.

UV-backed destinations require an existing active, non-closing `async` Runtime; reconstruction never creates or drives one implicitly. Process lifetime stays in the creating Runtime while communication streams can move independently; HTTP request and response endpoints move together as one `http.Exchange`.

### Manual-handoff API inventory

Each type below defines `:to_transfer_payload(): string` and static `.from_transfer_payload(payload: string)` returning that type. Types not listed here (such as listeners, filesystem watchers, `os.Process`, individual HTTP requests/responses, and SQLite statements/cursors) do not implement transfer hooks.

| Owning API | Supported handoff and recovery |
| --- | --- |
| [`uv.tcp_t`, `uv.pipe_t`](standard-library-uv.md#native-resource-handoff) | Eligible connected endpoints only, subject to pending-request and platform guards. Exports `discard_transfer_payload(payload): integer`. |
| [`net.Connection`](standard-library-net.md#transferring-connections), [`ssl.Connection`](standard-library-ssl.md#transferring-connections) | Idle connected transport plus buffered TCP/TLS state. Exports `discard_transfer_payload(payload): integer`. |
| [`http.Exchange`, `http.UpgradedStream`](standard-library-http.md#resource-handoff), [`websocket.Connection`](standard-library-websocket.md#transferring-connections) | Eligible exchange/session state plus child transport. Exports `discard_transfer_payload(payload): integer`. |
| [`fs.File`](standard-library-fs.md#transferring-files) | Open idle descriptor plus retained read bytes, with no pending operation. No `discard_transfer_payload`: recover with `File.from_transfer_payload` and close the result. |
| [`os.InputStream`, `os.OutputStream`](standard-library-os.md#transferring-process-streams) | Eligible captured pipes plus buffered/terminal state; unused standard-stream facades carry stable descriptor identity. Exports `discard_transfer_payload(payload): integer` (no-op for standard-stream identities). |
| [`os.InputOutputStream`](standard-library-os.md#transferring-shell-streams) | Both shell communication pipes (not child-process ownership). No `discard_transfer_payload`: recover with `InputOutputStream.from_transfer_payload` and close the result. |
| [`sqlite3.Connection`](standard-library-sqlite3.md#transferring-connections) | Idle database handle with no open Statement or Cursor. No `discard_transfer_payload`: recover with `Connection.from_transfer_payload` (or a retained policy's `to_value`) and close it. |

### Shared manual-handoff rules

These five rules govern every type in the inventory above and every user hook without packet-registered disposal. Individual module chapters document only their type-specific exceptions.

1. **Detach before delivery.** Encoding detaches the source. Source aliases then behave as closed or detached, and closing them does not affect the destination's resource (unused `os.stdin`, `os.stdout`, and `os.stderr` facades are the exception and stay usable).
2. **One owner, one adoption.** A payload is a process-local, manually owned capability, not a persistence format. Deliver and adopt it exactly once: adopting or discarding it twice can double-close or use freed memory, copying the string does not duplicate the resource, and dropping it leaks the resource.
3. **Recover failed delivery yourself.** When delivery fails, adopt the payload locally and close it, or call the type's `discard_transfer_payload(payload)` where available. `discard_transfer_payload` is an ordinary Titan function requiring a live Lua state (no Runtime or Task), validates the payload type before touching native state, and returns the native close status. It consumes ownership even when that status reports an error—never adopt or discard the same bytes again.
4. **Serialization failure after detachment.** When serializing an enclosing composite fails after a built-in hook detaches a resource, the built-in hook closes the detached resource and leaves the source detached (`os.InputOutputStream` documents one exception for a failed second pipe).
5. **Runtime and Task requirements.** Both hooks are synchronous and need no running Task. Higher-level UV adapters (`net`, `ssl`, `http`, `websocket`, and captured process/shell streams) require an active, non-closing Runtime for both hooks; raw `uv.tcp_t` and `uv.pipe_t` require an initialized owner loop on encode and an active, non-closing Runtime on decode. Later I/O on the adopted resource retains its usual Task requirements.

## Native message packets

`transfer` encodes values into heap-allocated native packets with per-packet resource tables. Cross-thread channels, thread spawn/results, and [cross-state receivers](async-io.md#cross-state-receivers) transport these packets.

```text
function encode_message(candidate: value): foreign *void
function decode_message(slot: foreign *(*void)): value
foreign function discard_message(raw: *void): void
foreign function copy_message(raw: const *void): *void

function attach_resource(resource: foreign *void,
                         retain: foreign function (*void): void,
                         release: foreign function (*void): void): string
function claim_resource(index_bytes: string,
                        expected_release: foreign function (*void): void): foreign *void
function claim_registered_resource(
    context: value,
    data: foreign const *void,
    length: integer,
    expected_release: foreign function (*void): void): foreign *void
function register_resource(
    candidate: value,
    get: function (value): (foreign *void),
    retain: foreign function (*void): void,
    release: foreign function (*void): void,
    construct: function (value, foreign const *void, integer): (value))
```

### Raw packet encoding, decoding, copying, and disposal

- **`encode_message(candidate)`** encodes any transferable value or explicit `TransferValue` into a newly owned packet and returns its raw pointer. Scalars, strings, borrowed pointers, C functions, and explicit policies encode without opening a packet scope and never invoke hooks. Records, unions, Titan closures, and endpoints encode inside an encode scope so nested hooks and captures can attach resources. Records and unions use the protobuf wire format and its 128-level [nesting limit](standard-library-protobuf.md#wire-mapping) (127 chained records under a nominal root).
- **`decode_message(slot)`** is a Titan function for trusted native integrations (not callable from Lua because its raw C pointer parameter has no Lua coercion). Pass a caller-owned `foreign *void` local holding one uniquely owned packet—which converts contextually to `foreign *(*void)` (see [casts and coercions](ffi.md#casts-and-coercions))—or an explicit `foreign *(*void)` slot address. Immediately guard the local with `defer transfer.discard_message(raw)` and pass that exact local directly to `decode_message` in the owning function:

```text
local raw = transfer.encode_message(v)
defer transfer.discard_message(raw)
return transfer.decode_message(raw)
```

Once its body runs, `decode_message` consumes the packet and clears the caller's slot before returning or propagating any error (including module-load, decoder, or partial-claim errors), so the deferred guard sees `nil` and does not double-free. This holds even if `raw` was assigned inside an earlier `catch` region ([C storage after a caught error](ffi.md#c-storage-after-a-caught-error)). Only a function-entry memory or stack failure leaves the packet in the slot for the deferred guard to release. Passing a nil `slot` raises `"transfer: invalid packet owner slot"`, and an empty slot raises `"transfer: cannot decode a NULL packet"`.

- **`discard_message(raw)`** is a C-ABI `foreign function` that releases all unclaimed packet resource-table entries and frees the packet (`nil` is a no-op). Dispose of unconsumed packets with `discard_message` once—never with `ffi.free`, and never pass the same packet to a second consuming call.
- **`copy_message(raw)`** is a C-ABI `foreign function` that duplicates a packet only when it has no resource attachments, returning `nil` if `raw` is `nil`, has any resource entry, or fails to allocate.

### Scoped resource attachments and packet-local indexes

Encoding or decoding a record, union, closure, or endpoint installs a packet scope on the current Lua thread. Scopes nest cleanly and restore the enclosing scope on normal or error exit after disposing of any unfinished packet state.

- **Authority:** `attach_resource` succeeds only when the current execution's innermost scope is an encode scope (`"transfer: resource attachment requires an encode scope"` otherwise), and `claim_resource` only when it is a decode scope (`"transfer: resource claim requires a decode scope"` otherwise). Enclosing scopes, other Tasks, and child `coroutine.Coroutine`s never lend packet authority.
- **Nested and standalone calls:** Custom hooks, nested protobuf messages, and closure-capture snapshots invoked inside a packet share its scope. Standalone `protobuf.serialize`, `protobuf.deserialize`, `protobuf.deserialize_nominal_buffer`, `TransferValue.from_value`, and `TransferValue:to_value` create no scope and reject endpoint hooks outside an enclosing packet; inside one, the enclosing packet—not the returned index bytes—owns every attachment.
- **Attachment (`attach_resource`):** Rejects a nil `resource`, `retain`, or `release` (`"transfer: invalid native resource attachment"`), reserves table capacity before calling `retain(resource)` (`"transfer: out of memory reserving resource attachment"`), records `(resource, release)`, and returns the slot index as a four-byte little-endian string (`0` through `0xfffffffe`; `0xffffffff` is reserved invalid). Each occurrence adds its own entry and retain. `retain` and `release` must be C-only callbacks safe without a Lua state or Runtime. If encoding raises later, unwinding releases every attachment of the unfinished packet.
- **Claim (`claim_resource`):** Validates in order: exact four-byte width (`"transfer: invalid resource attachment index width"`), in-bounds index distinct from `0xffffffff` (`"transfer: resource attachment index is out of bounds"`), non-nil `expected_release` matching the entry's `release` callback (`"transfer: resource attachment kind mismatch"`), and unclaimed state (`"transfer: resource attachment was already claimed"`). It then marks the slot claimed and returns the pointer without allocating or yielding.
- **Finalizer-first adoption:** A `from_transfer_payload` hook must allocate its destination wrapper with an inert `nil` native pointer and register its GC finalizer *before* claiming the slot, then store the returned pointer immediately with no fallible call in between.
- **Registered resources:** `register_resource(candidate, get, retain, release, construct)` and `claim_registered_resource` allow compiled modules (such as `titan.thread`) to register a record type across all generic applications so encoding and decoding bypass reflective hook dispatch. A non-record `candidate` raises `"transfer: registered resource must be a record"`. `construct(context, data, length)` must follow finalizer-first order and pass its transient `context` to `claim_registered_resource` without storing `context` past return.
- **Packet-local index guarantee:** Slot indexes are meaningful only within the active packet's resource table; they prevent forging raw pointers, crossing resource kinds, or claiming one slot twice, without acting as global cross-packet replay tokens.

## Raw module loader

```text
foreign function transfer_load_module(state: *lua_State,
                                      name: const *char,
                                      length: unsigned long long): void
```

`transfer_load_module` supports trusted Lua C API integrations (such as `titan.lua` and `titan.thread`). Call it only inside a protected boundary on an exclusively owned `state`, with `name` valid for `length` bytes. It raises `"transfer module name exceeds native size"` if `length` exceeds `SIZE_MAX`, reserves three temporary stack slots, invokes the preload loader for `name` with zero arguments, verifies that the returned module matches the generated module's canonical registry entry, and leaves that module above the entry stack top. Because it allocates, runs Lua code, and may raise, it requires a live Lua state and caller-provided error protection.
