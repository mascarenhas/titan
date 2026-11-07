# Titan style guide

This guide records conventions visible in Titan's current language, standard
library, and compiler-facing modules. It complements the normative
[language reference](language/index.md); when a style recommendation and a
language rule seem to disagree, the reference and compiler behavior win.

## Keep types specific

Prefer the narrowest type that describes the operation. Use `value` at a
genuine dynamic boundary, not as a substitute for designing a static API.
Keep a checked conversion close to that boundary so the rest of the function
works with ordinary Titan values.

Use the nominal and structural forms for their distinct purposes:

- a `record` gives fixed nominal data and methods;
- a `union` gives a closed set of tagged alternatives;
- an `Interface` gives a nominal behavioral view satisfied structurally at an
  explicit conversion site;
- an Array `{T}` gives positive integer positions and may contain holes; and
- a Map `{K: V}` gives ordinary key/value lookup.

Do not use an integer-keyed Map merely as an Array with a different spelling.
The containers have different identities, representations, length rules, and
Lua-boundary behavior. An Array's `#` is its highest present positive index,
not an element count; code that permits interior holes must not iterate
`1..#array` and silently assume every read is present.

## Let precise inference speak

Omit a local or generic-`for` type annotation when the initializer or iterator
already infers the same precise type. This makes generic APIs visibly useful
and avoids duplicating a type that can drift from its source:

```titan
local iteration = import "iteration"

function total(scores: {string: integer}): integer
  local result = 0
  for _, score in iteration.pairs(scores) do
    result = result + score
  end
  return result
end
```

A trailing `?` on an inferred name preserves an option without repeating its
base type: write `local name?, score? = iteration.next(scores, nil)` or `for
index, item? in iteration.ipairs(items) do`. Keep a complete annotation when it
supplies information rather than merely restating it: for a public/API
declaration, a `nil` or empty initializer, contextual generic or lambda
instantiation, a flexible or dynamic result demand, an Interface or FFI
conversion, an intentional widening or narrowing, or behavior under test.

Name an intentionally unused local result or loop control `_`, not `_name` or
`_item`. `_` is an ordinary Titan variable, but repeated `_` declarations in
one local-result or loop list are allowed specifically for this convention:

```titan
function visit_holes(values: {value}): integer
  local positions = 0
  for _, _ in iteration.ipairs(values) do
    positions = positions + 1
  end
  return positions
end
```

Omit an unused `case` payload binding unless binding it deliberately exercises
a checked payload projection, and delete an unused declaration when its
initializer need not be evaluated. A private callable with one unused
positional parameter may name it `_`, with its required type retained as in
`function ignore(_: value)`. Function parameters remain annotated, participate
in named-call surfaces, and must be unique: do not rename public parameters as
cleanup, and retain distinct protocol names such as `_request` and `_response`
when several parameters are unused. Retain a semantic name when the binding
documents ownership or keeps a value alive even though it is never read later.

## Make absence visible where it is expected

An indexed Array or Map read returns an option. An ordinary inferred local
forces that option; a name marked with `?` preserves it:

```titan
function required_at(values: {string}, index: integer): string
  local required = values[index] -- raises here if absent
  return required
end

function optional_at(values: {string}, index: integer,
                     default_value: string): string
  local optional? = values[index]
  return optional or default_value
end
```

Use the first form when absence is an invariant violation and the second when
it is part of normal control flow. Prefer `T?` to a sentinel value of type
`T`, and handle the option near the lookup. Option coercions do not lift
through containers or function types, so do not design an API that relies on
`{T}` becoming `{T?}` or `function (): (T)` becoming `function (): (T?)`.

Use `optional == nil` or `optional ~= nil` when presence must remain distinct
from a falsy base value. A plain condition intentionally merges nil with a
present `false` in `boolean?`; it is a presence test only when every present
base value is truthy. Defaulting an optional boolean is therefore explicit:

```titan
local function enabled_by_default(enabled: boolean?): boolean
  if enabled == nil then return true end
  return enabled
end
```

A method receiver is also an automatic unwrap site. After handling the nil
case, call the method on the optional directly instead of adding a cast whose
only purpose is to force the receiver:

```titan
local strings = import "string"

function whole_match(expression: strings.Regex,
                     subject: string): string?
  local found? = expression:match(subject)
  if not found then return nil end
  return found:whole()
end
```

Write `found:whole()`, not `(found as strings.RegexMatch):whole()`. If the
receiver is still nil, the call raises at that receiver boundary; an earlier
guard makes the unwrap known-safe. The option examples in the
[quick tour](quick-tour.md) are the documentation model for this spelling.

## Distinguish fixed calls, variadic inputs, and flexible results

Titan adjusts a fixed call to the declaration's fixed arity:

- omitted positions are filled with nil and then type-checked;
- surplus expressions are still evaluated from left to right, but their
  values are discarded; and
- an optional fixed parameter is written `T?`, not as an untyped default.

Do not add a variadic tail merely to tolerate omitted or surplus arguments.
Use `...: T` only when the callee semantically consumes every supplied tail
value. Likewise, use a flexible return `(...: T)` only when the number of
results is selected at run time.

A finite consumer sees positions projected from a flexible tail as options.
An open sink—the trailing arguments of a variadic call, a flexible return, or
the final expression of a positional Array/integer-Map constructor—preserves
the complete run. Only the final expression in an expression list expands;
parenthesize a call when one result is intended.

Prefer positional calls for short functions whose operands explain
themselves. Use declaration-based named calls when several same-typed
arguments are easy to transpose or when the names carry real meaning. Apply
this to record constructors as well: name long state-initialization lists,
adjacent boolean flags, and runs of zero, nil, or empty-container placeholders.
Use the selected `new` declaration's parameter names, which may differ from
record fields for an override. Preserve expression evaluation order and any
final multi-result adjustment when converting an existing call. Named calls
are unavailable through arbitrary function values and for variadic
functions, so do not make readability depend on names that disappear at the
callable boundary.

## Acquire, then defer the close

Place cleanup immediately after successful acquisition:

```titan
local fs = import "fs"

function first_chunk(path: string): string?
  local file = fs.open(path, "r")
  defer file:close()
  return file:read()
end
```

This keeps the acquisition and its ownership rule together, and it covers
fallthrough, return, break, and error. Multiple defers run last-in-first-out.
Use `defer do ... end` when one logical cleanup has several statements.

The structural `io.Closer` Interface includes one lifetime rule: every later
`close()` call is safe. A successful or terminal close becomes a no-op, while
a pre-commit failure may retry. FIFO behavior, cancellation shielding,
concurrent-call coalescing, and post-close reads or writes belong to the
concrete resource rather than to the Interface.
Close resources explicitly so errors are reported at the relevant call site
and ownership ends predictably. In particular, a File is an operating-system
descriptor rather than a libuv loop handle; async Runtime shutdown does not
close it on the application's behalf.

Use `catch` to recover or add behavior. Use bare `raise` when the original
error and traceback should continue. Remember that an error in a deferred
statement replaces the pending return, break, or error; cleanup is not an
error-suppression mechanism.

A function body, loop body, and existing `do` body are already blocks. Attach a
whole-function `catch` directly to the function body, and let `defer` use the
current body. Do not add a ceremonial `do ... end` merely to gain either
feature. Add a nested block only when its narrower protected region, local
scope, or cleanup lifetime is intentional.

## Return generic iterators in tuple order

The generic-`for` tuple is always:

```text
(iterator, state, initial control, close)
```

Missing positions are nil-filled. The iterator is required; state and initial
control describe its calls; close is optional. The close function runs after
normal exhaustion, `break`, `return`, or an error from the initial iterator
call, a later iteration call, or the body. If it accepts one argument, Titan
passes the state. Factory-expression evaluation happens before the tuple has
supplied a close function and is therefore outside that cleanup region.

Return the whole tuple from an iterator constructor rather than hiding
ownership in an unrelated global. Prefer using the resource itself as state
when the iterator and closer can operate on it directly:

```titan
local fs = import "fs"

local function next_line(file: fs.File): string?
  return file:read_until("\n", true)
end

local function close_file(file: fs.File)
  file:close()
end

function lines(file: fs.File):
    (function (fs.File): (string?), fs.File, nil, function (fs.File): ())
  return next_line, file, nil, close_file
end
```

Use an option, `value`, or another nil-capable type for the iterator's first
result. Generic iteration stops only on nil; false remains a real iteration
value.

Use the same rule for a nil-terminated Reader method. When the loop only calls
`read`, handles each returned string, and stops at nil, write the operation as
the iterator directly:

```titan
for chunk in reader:read do
  output:write(chunk)
end
```

Do not open-code that protocol with a primed optional and a `while` loop.
Empty strings are iteration values and should be passed to the consumer; nil
alone means EOF. Keep an explicit state machine only for state the public
operation actually promises, such as delimiter overlap and bytes retained
after a successful match.

## Reuse the standard string writer

When a module already imports `string`, accumulate a result with
`string.writer()` instead of defining a local chunk array plus a
`join_chunks` helper or repeatedly concatenating a growing result. The writer
centralizes string-size checks and linear-time assembly. It is always
synchronous; use `async.reader_writer_channel` when the communication itself
needs Task synchronization.

The string module's own builder implementation and low-level modules that
cannot import `string` because of the dependency graph are implementation
boundaries, not invitations to duplicate `join_chunks` in higher-level
modules. Do not add cancellation rollback or terminal-tail bookkeeping unless
the public API explicitly promises it.

## Capture parameters directly

Nested functions capture parameters and `self` as ordinary lexical locals.
Use those names directly in the closure; do not create a `rooted_subject`,
`owner`, or similar copy whose only purpose is to keep the same value alive.
The closure environment is already a GC root. Introduce an alias only when it
represents a real snapshot or a different narrowed value, and name that
semantic distinction rather than the rooting mechanism.

## Put behavior and state on their real owner

Prefer `Record(...)`, `Record{...}`, or `Record "text"` when calling a record
constructor. These spellings select `Record.new` with its ordinary visibility,
argument adjustment, and result list. Keep `.new` when referring to the
function as a value or supplying its own explicit generic arguments.

Put custom initialization on `[local] function Record.new(...)` when it is the
record's construction operation. Build the raw object with a context-typed
`{ ... }` inside that module; an override makes raw construction module-private.
Keep existing domain operations such as `fs.open` and `net.connect` named for
what they do.

When a private helper's first argument is one nominal record and the operation
exists to read or mutate that record, write a local method on the record:

```titan
local record Pending
  number: integer
end

local record Event
  number: integer
end

local record Watcher
  pending: {Pending}
end

local function Watcher:map(item: Pending): Event
  return Event(item.number)
end

local function Watcher:drain(): {Event}
  local pending = self.pending
  self.pending = {}
  local events: {Event} = {}
  for index = 1, #pending do
    events[index] = self:map(pending[index])
  end
  return events
end
```

This keeps the receiver, private behavior, and state transition together.
Retain a free helper when it genuinely coordinates several owners, is a typed
adapter reused as a value, or represents another operation whose owner is not
the first record argument.

Use the existing owner and its narrow helper directly. Do not add a facade
alias, forwarding wrapper, duplicate validity check, shadow index, generation,
rollback snapshot, or parallel close flag merely to make that direct
collaboration look indirect. If an API requires callers to serialize all
mutations, do not partially harden one imagined overlap and thereby imply a
broader guarantee. First establish the supported trust and concurrency model;
add state only for a documented operation that the model actually permits.

For a dense one-input/one-output transformation, allocate one result, write
`output[index] = transform(input[index])`, and return it. Do not pass a caller's
output Array into the mapper or manufacture extra public events merely to
encode intermediate implementation phases.

## Use finalizers only for reachability ownership

Use `gc.finalizable` when a table or full userdata truly owns state until it
becomes unreachable. Store per-value state on or inside that owner and use a
uniform callback that reads it; an existing metatable is preserved, but its
raw `__gc` field is shared by every value using that metatable. Clear the
owned pointer or terminal marker before releasing the resource so cleanup is
idempotent.

A finalizer is a reachability fallback, not prompt cleanup and not a substitute
for a public `close` operation. In particular, do not use one to race or
abandon an outstanding libuv request: the callback owner must stay rooted
until libuv reports terminal completion. Keep raw metatable manipulation in
`titan.gc` rather than duplicating its Lua-stack boundary in another module.

## Treat async calls as ownership boundaries

Application code should import the public `async` facade and the high-level
`timer`, `fs`, `net`, `ssl`, `http`, and `os` modules. The synchronous `url`
module is also application-level. The `uv` module is the low-level libuv
binding, meant for library adapters and programs that drive their own loop;
prefer the high-level modules in application code.

`async.run` schedules a Task and returns before its function runs. Observe
spawned Tasks through their structured `status`, the bounded `any`/`race`/
`all`/`join` combinators, or intentional shared state, and give unfinished
Tasks an intentional cancellation policy. A combinator does not cancel its
losers. An uncaught Task error is logged with its traceback and ends only that
Task. `Task:cancel` keeps the first reason private while the status remains in
its current live variant; terminal `cancelled(reason)` publishes it only after
the continuation has received cancellation.

One Task continuation runs until it yields, returns, or raises. Native waits
settle their exact registration; Task startup, yield, peer settlement, and
explicit token-bearing resumes use the Runtime's shared ready queue.
`timer.sleep` owns a dedicated one-shot timer and waits for its native close
through deferred cleanup before returning or finishing cancellation unwind.
Use `async.yield()` when a CPU loop should explicitly cede a turn.

Cancellation is often logical before it is physical. A callback owner and
every GC value or native allocation it hands to libuv must remain rooted until
the terminal callback and cleanup complete, even when the waiting Task has
been cancelled. Do not implement cancellation by dropping the last Titan
reference or by allowing a Lua GC finalizer to race libuv. Keep one traced
request record per one-shot callback, and keep only buffered/latest state plus
one waiter on a multi-shot handle. The callback settles its exact wait or
publishes through the owning subscription, then returns; no callback or Task
may re-enter `uv_run`. Follow the
[async runtime contract](implementation/libuv-runtime.md) for continuation
delivery and native retirement.

Use terminal listeners to compose a bounded group of Tasks:

1. Check each Task's current status first.
2. Create one fresh private `async.ResumeToken` for this invocation.
3. Register a distinct listener on each still-relevant Task. Each listener
   captures the token directly.
4. Call every returned remover in `defer`. The removers are idempotent.
5. Call `async.suspend(token)` once.

The listener that decides the outcome calls `Task:resume(token)`. That call
accepts one coalesced entry in the Runtime's ready queue and never resumes the
target inline. Repeated calls with the correct token coalesce, and a different
token raises in the caller and wakes nothing. The token's `source` text is for
diagnostics only. Cancelling the suspended Task uses the stored token and the
same wake. Tokens authorize only explicit `suspend` and `Task:resume(token)`
coordination; native callbacks resume their Task through their own private
path. Do not collect Tasks of different types in one Array, and do not add a
polling loop, a phase fence, or a separate join protocol.

Low-level contributors must classify a new libuv binding as synchronous,
one-shot, or persistent multi-shot before adding state. Follow
[Extending the libuv binding](implementation/libuv-extension-guide.md) for the
owner, callback-shim, handle-lifecycle, test, and API-coverage checklists.
Preserve the single coroutine tag and outer non-reentrant loop; do not add a
scheduler, parallel or traversed handle inventory, operation queue, generation
fence, or event-kind dispatcher merely to wrap another public `uv_*` function.
Test additions through public behavior or standalone native fixtures; uv tests
must not rewrite the binding's source text without an explicitly justified,
maintainer-approved native-boundary exception.

For shell-command convenience, `os.popen` owns writable stdin and one readable
stream that merges the child's stdout and stderr. Drain that output before
`wait`; when input and output must progress together, schedule both directions
concurrently. Use `os.spawn` instead when the program needs direct executable
and argv control, separate stdout and stderr, or explicit capture/inheritance
options. A full operating-system pipe is a normal backpressure condition, not
a reason to make process I/O blocking.

## Pick the right cross-thread tool

Each thread started with `thread.spawn*` has its own Lua state and event loop.
Nothing is shared, so every value is copied or moved. Choose the tool by what
must survive:

- Use `thread.channel<|T|>` for a stream of messages. It is a bounded FIFO with
  backpressure and drops nothing.
- Use `async.channel<|T|>` between Tasks in the same state. It copies nothing.
- Use `async.Receiver` to wake another state with the latest value. It
  coalesces: a newer value replaces an unread one, and overwritten or closed
  unread packets are disposed natively (including any attached channel
  endpoints).

Observe a thread with `Thread:join()`, or compose `Thread:task()` with the
`async` combinators. Cancelling the proxy Task only requests cancellation of the
thread. Release anything the thread still uses only after the proxy is terminal
or `join()` returns.

Native resources that move by manual handoff, such as `net.Connection`,
`ssl.Connection`, `http.Exchange`, `websocket.Connection`, and `fs.File`, are
not released when a packet is discarded. Adopt each payload exactly once, or
recover it with the type's `discard_transfer_payload` where one exists. The
[shared manual-handoff rules](language/standard-library-transfer.md#shared-manual-handoff-rules)
give the details. Release a `transfer.encode_message` packet with
`transfer.discard_message`, never with `ffi.free`.

The `uv` locks block the OS thread. Do not hold one across a Task suspension;
use channels to coordinate instead.

## Design one logical module before choosing its files

Use a flat `pkg/name.titan` while one source remains coherent. When it becomes
too large, a folder module uses `pkg/name/name.titan` as its canonical main
and immediate sibling `.titan` files as contributors.

Contributors are not submodules. They share one namespace, checker/codegen
pass, initializer, artifact, and module identity. A top-level `local` is
module-private, not file-private. Do not import an immediate contributor or
name one as though it were `pkg.name.helper`.

Keep the main source responsible for the canonical module entry and sole
optional root initializer. Group public and private declarations with their
real responsibility across contributors; the files are an organizational
choice, not additional visibility boundaries. Do not use contributor basename
order as an implicit dependency mechanism. Although the compiler combines
contributors deterministically, function and nominal declarations are
order-independent, while module-variable initializers have a deliberate
earlier-Titan-import/earlier-variable frontier. Put ordinary Titan imports and
prerequisite module variables before a module variable that needs them. Foreign
directives establish the complete `ffi` environment in combined module order;
order those directives for the required C preprocessing behavior.

## Use canonical Titan imports and qualified Lua loads

For the standard modules with parser-provided short-import sugar, Titan source
uses the short canonical spelling:

```titan
local fs = import "fs"
local strings = import "string"
```

Use an alias such as `strings` when the short name is also a type keyword.
The short-name set is `coroutine`, `uv`, `async`, `timer`, `io`, `fs`, `net`,
`ssl`, `url`, `http`, `websocket`, `os`, `path`, `peg`, `string`, `test`, `lua`,
`math`, `gc`, `iteration`, `reflect`, `sqlite3`, `json`, `protobuf`, `transfer`,
`thread`, and the browser-only `browser`. The rule applies inside
standard-library sources too: spelling one of those imports as `"titan.fs"`,
`"titan.ssl"`, or another qualified name is a style violation, not extra
precision.
Lua loads the same logical modules with qualified names:

```lua
local fs = require "titan.fs"
local strings = require "titan.string"
```

This keeps Lua's standard `io`, `os`, `string`, and other global/module names
unchanged.

Do not publish or document an unqualified Lua replacement for a standard Lua
module.

Application modules keep their own dotted identities in both languages:
Titan imports `app.model`, and Lua requires `app.model`.

## Write native tests as ordinary modules

Use a public top-level `test_*` function with one `test.Context` parameter for
a discoverable case. Keep reusable assertions and setup in ordinary local
functions; use `context:run` only when a child schedule and qualified child name
are meaningful. Give subtests short local names because the runner prefixes the
complete parent name.

```titan
local test = import "test"
local subject = import "app.subject"

function test_empty(context: test.Context)
  local resource = subject.open()
  context:cleanup(function() resource:close() end)
  test.assert(resource:size() == 0)
end
```

Use language `defer` for resources that must close as the current body returns.
Use `Context:cleanup` when teardown must happen after registered descendants.
Register cleanup immediately after acquisition, just as with ordinary `defer`.
Do not catch `test.skip` or failed assertions unless the test is explicitly
checking error handling.

Tests of the standard library may import `test` and the module under test, but
fixture construction should not acquire an unrelated Titan standard-library
dependency. Use a narrow reviewed C/Lua FFI helper when the test itself must
create host state. Keep build, loader-promotion, process-supervision, sanitizer,
and source-interposition proofs in their Lua/native harnesses: the native test
runner is not a build system or an external supervisor.

## Keep Lua and C machinery behind narrow audited boundaries

Treat `foreign` calls, source `foreign function` bodies, and raw-pointer handoff
as an explicit unsafe boundary, comparable to Rust's `unsafe`. Titan code that
uses none of them should be well-behaved. The foreign code and its callers
uphold the pointer, lifetime, ownership, ABI, and threading contracts of the
APIs they use. Titan does not contain arbitrary native behavior and does not
check that a raw pointer is usable, so do not add speculative guards against
native misuse. Keep the boundary small, and make the public Titan API behave
correctly for ordinary callers.

Public standard-library APIs should expose ordinary Titan types. Keep Lua API
state, borrowed stack values, raw C pointers, local FFI records, and libuv
controls inside the low-level module that owns their lifetime. Convert to a
public record, union, Interface, Array, Map, option, string, or number before
returning from that boundary.

Standard-library and runtime code that writes C or calls the Lua C API also
follows the six rules in [Write native bindings
Titan-first](#write-native-bindings-titan-first).

When libuv supplies an operation, prefer that reviewed portable API over
either a POSIX-specific shortcut or a lower-level ISO C platform service; use
the latter only where libuv has no equivalent, such as calendar conversion and
locale selection.

Code that calls the raw Lua API must preserve stack balance on every path and
must not let a borrowed Lua pointer outlive its stack/rooting contract. Keep
weak-Map policy behind `titan.gc.weak` and `titan.gc.ephemeron`; even stdlib
modules with other audited Lua calls should not duplicate `__mode` metatable
setup. Keep dynamic Lua execution and conversion centralized rather than
scattering `lua_*` calls through otherwise typed modules. The public
`titan.lua` loader is an escape hatch as powerful as the C FFI for bypassing
static program structure: use it only when run-time Lua compilation or module
discovery is the actual requirement, isolate the returned `value`, and recover
precise Titan types immediately. An explicit Lua environment chooses upvalues;
it is not a security sandbox for untrusted source or bytecode. A boundary that
can allocate, raise, yield, invoke user code, or run a callback deserves
explicit review of its roots and cleanup behavior.

Do not expose a private bundled native dependency as part of an application
ABI. In particular, the bundled libuv and LPegLabel payloads belong to the
combined standard provider; extensions follow the documented provider/import
contract rather than embedding a second native copy.

## Write native bindings Titan-first

Standard-library and runtime code that touches C (authored C, a source
`foreign function` callback, or a `lua_*`/`luaL_*` call) follows six rules. A
review counts the new Lua C API calls and authored C lines in a diff and
justifies each one against a rule; [standard-library
maintenance](implementation/standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do)
pairs each rule with a wrong and a right example.

1. **Layering.** Write the work in Titan; do not add hand-written runtime C
   files for standard-library bindings. Place each piece of a native boundary
   by how C reaches it:
   - *Called through a function pointer* (libuv callbacks, `__gc` and other
     `lua_CFunction`s): a `local foreign function`, address taken.
   - *Called by name where any C symbol works*: a public `foreign function`; C
     callers use the generated `.titan.h` (or the mangled declaration).
   - *Needs an exact unmangled C symbol* (an Emscripten export, a symbol a C
     library looks up): a compiler-generated one-line forward to a public
     `foreign function` (with a weak declaration when the owning module may be
     absent), never a hand-written runtime C wrapper.
   - *Program entry and image lifecycle* (native `main`, browser
     `initialize`/`entry`/`close`): a compiler-generated launcher sharing one
     error-conversion and trace implementation; protected calls live there, not
     in runtime libraries.
   - *Data placement*: per-state roots in module variables or owner fields;
     cross-state maps with the host that already owns the lifetime (such as the
     browser's JavaScript registry), not C statics in runtime code; the Lua
     registry only to anchor an object before any module variable exists,
     explicitly justified.
   - *Struct access and marshalling*: in Titan through `foreign import`; the
     only C in headers is one-line inline macro bridges (`lmacro_*` in
     `titan/ffi.h`) for macros the FFI cannot spell.
   - *Test-only C*: stays in test fixtures.

   ```text
   -- In titan/browser.browser.titan: public foreign function called by the
   -- compiler-generated `titan_browser_invoke` weak forward in browserentry.lua.
   foreign function invoke(
       raw_id: unsigned long long, raw_token: unsigned int,
       raw_slot: unsigned int, raw_generation: unsigned int,
       raw_argc: unsigned int, raw_args: const *void): int
   ```
2. **Plain C stays plain C.** Data that only C uses lives in C locals,
   formals, and return codes, never on the Lua stack. Never `lua_pcall` a C
   function that Lua never sees just to get a protected region; return a
   status from it instead.
3. **Protected work belongs in Titan.** A boundary that must catch raises
   calls a Titan function whose body uses `catch` and `defer`, where `error`
   and `traceback` are available. The native callback trampolines are the
   model: recover the state, owner, handler closure, and entry; push the owner
   when the handler may remove its last other home; call the entry; restore
   the stack top.
4. **Pinning.** Per-state roots live in a module variable (a Map or Array) or
   in an owner record's field, as `loop.handles` does in `titan.uv`, never in
   `luaL_ref` slots, registry tables, or userdata uservalue tables (except a
   justified pre-module lifecycle anchor such as `attach`'s `state_gc`
   userdata).
5. **Rooting.** A Titan parameter is rooted by its caller's provenance, and a
   local by its frame slot, which is refreshed at its declaration and at every
   assignment and is reused by sibling scopes once its block ends ([the
   function frame](implementation/values-and-gc.md#1-the-function-frame-reserved-nil-initialized-stack-slots)
   and [home roots](implementation/values-and-gc.md#2-home-roots-shadow-slots-and-borrowed-c-copies)).
   Declare a value that must outlive an inner block in the outer block, and
   copy an argument into a local before removing its last other home. Never
   `lua_pushtvalue` a parameter or local just to keep it alive.
6. **Don't duplicate checks the receiver makes.** Where the other side of a
   boundary is dynamically typed, marshal by runtime type into one tagged
   union at the boundary and let the receiver decide what it accepts. Do not
   build parallel signature or descriptor machinery that re-checks the same
   thing on both sides.

## Keep examples and documentation exact

Examples should compile as written and use the same module identities that
real programs use. Distinguish binary payloads from text paths, byte indices
from Unicode concepts, direct executable spawning from shell execution, and a
concrete resource's guarantees from an Interface's method shape.

Write the language manual in terms of what a caller can observe. Put mechanism
(private field names, internal state names, the order of private callbacks) in
the implementation chapters. Do not record test status, release gates, issue
numbers, or change history in a manual; state the current behavior. Build
examples with an output directory (`titanc -o out ...`) so generated files stay
out of the source tree.

When a user-visible language feature changes, update both the language and
implementation manuals. When a standard-library API changes, update its
language chapter, relevant implementation chapter, type-schema fixture, and
library tests together. Keep roadmap-only APIs visibly provisional; do not put
guessed signatures in otherwise runnable documentation.
