# Titan libuv async I/O standard library

Status: implementation in progress. Phases 0 through 5 are implemented and
covered by the normal, deterministic fault, packaging, and sanitizer suites;
Phase 6 and the final Phase 7 audit remain. The design below is based on the
current repository checkout, the sketch in `/tmp/uv-io.md`, the implemented
`coroutine`/`uv` standard modules, focused Titan and libuv prototypes, and the
public libuv 1.x contracts.

## Executive decision

The sketch is feasible. Its central callback-to-coroutine continuation model is
the selected design; the remaining work is to make rooting, error containment,
multi-shot handles, loop bootstrap, and shutdown contracts explicit.

Keep the proposed four layers:

1. Public libuv calls through Titan's C FFI.
2. A small C shim for the fixed libuv callback ABIs and operations that cannot
   be expressed safely in Titan alone.
3. A coroutine continuation pump in which each callback resumes its task and
   arms the next yielded request before returning.
4. Synchronous-looking `fs`, `net`, `os`, and `timer` modules.

Use these concrete decisions for v1:

- Titan source uses the canonical module names `coroutine`, `uv`, `timer`,
  `fs`, `net`, and `os`. Lua loads every standard module through its `titan.*`
  alias: `require "titan.coroutine"`, `require "titan.uv"`,
  `require "titan.os"`, and so on. Titan's standard-library search root and
  Lua-facing entry aliases provide the two lookup names without replacing
  Lua's own `coroutine`, `os`, `math`, or `string` modules.
- `uv` owns one private `uv_loop_t` per active bootstrap/loop session, not per
  task and not `uv_default_loop()`.
- Public `uv.run` is nonblocking: it creates and roots a task coroutine, arms a
  zero-timeout start callback, and returns a Task without resuming it. Calls
  from another UV task are valid and schedule an independent task.
- The `uv` module instance creates one fresh, private identity-valued `UV_TAG`
  per Lua state. Every UV Task and sequential loop session in that state shares
  it. The tag names the async scheduling abstraction; operation owners/task
  pointers identify the particular continuation to resume.
- A task yields an internal Request with `UV_TAG`. The callback whose
  `root:resume` receives that Request allocates/roots/submits the next libuv
  operation and then returns.
- Libuv callbacks enter one fixed module-local Titan dispatcher through the
  native Titan function pointer, following `titan_coro_entry`; they do not use
  the generated Lua entry wrapper.
- The native dispatcher extracts and cleans the completed result, directly
  resumes/errors the captured task, runs user code until its next UV yield or
  completion, and arms the returned Request. Running the continuation inside
  the callback is intentional and mirrors an ordinary callback chain.
- The fixed C trampoline calls the trusted Titan dispatcher directly, matching
  `titan_coro_entry`; it does not add a second C protected-call layer. The
  dispatcher uses a trailing function-level Titan `catch` around its controlled
  body, records either a Task failure or fatal Runtime state, requests loop stop
  when needed, and returns normally. No Lua/Titan longjmp may cross a libuv
  frame.
- Lua userdata allocated from Titan owns loop, request, handle, and fixed-buffer
  storage wherever possible. Size it with `uv.<type>.sizeof`, cast the aligned
  payload pointer to the imported C pointer type, and keep the userdata rooted
  until libuv's terminal callback says it is safe to reclaim.
- Carry a native object across Titan module/API boundaries in one nominal
  wrapper record with a local typed native-handle field (a pointer for libuv
  struct handles/requests). The declaring module alone can construct or unwrap
  it; ordinary calls read the typed pointer field directly and never coerce the
  pointer to `value` and back. Allocate the wrapper once per native object, not
  once per handle use.
- A pointer allocated by libuv or the shim is a fallback. Store it in a rooted
  userdata and release it with the matching library deallocator; a `__gc`
  fallback may reclaim passive memory, but it never replaces required
  `uv_close`, request cleanup, or loop draining.
- Use only public, portable libuv APIs for runtime behavior. Platform-specific
  code is limited to build/link details and isolated mappings for concepts that
  libuv still represents with host constants, such as signal numbers.
- The default developer/CI build uses a pinned static libuv 1.52.1 built by the
  Makefile. A system `pkg-config` mode is optional.
- The standalone bootstrap wraps an async program's `main` in nonblocking
  `uv.run`, then enters the primary C `uv_run(loop, UV_RUN_DEFAULT)` from
  outside callbacks. Any later shutdown-drain invocation happens only after
  that call has returned. Lua embedding gets a distinctly named loop-driving
  API; it is never confused with task-starting `uv.run`.

This design does not require general Titan-function-to-C callback support,
`CAdopted`, tagged variants, new syntax, or a Titan module ABI bump.

## Scope

### In scope

- Reproducible libuv availability and build integration on Linux and macOS.
- A private loop and direct callback/coroutine continuation pump built on the
  `coroutine` standard module (renamed from the original `coro` prototype).
- Fixed native C-to-Titan callback trampolines.
- Timers, recurring ticks, and next-turn yielding.
- Asynchronous filesystem I/O.
- TCP sockets and asynchronous DNS.
- Portable OS helpers, signals, child processes, and `popen`-style convenience.
- Cancellation, errors, traceback preservation, deterministic shutdown, GC
  rooting, packaging, tests, and documentation.

### Out of scope for this plan

- Windows support. The runtime design must not prevent it, but Linux and macOS
  are the supported/tested targets for this iteration.
- UDP, TTYs, filesystem watching, named-pipe IPC, arbitrary `uv_poll_t`, and
  `uv_queue_work` as public APIs.
- General Titan closures as arbitrary C function pointers.
- Cross-thread use of one loop or task; v1 runs callbacks and task
  continuations serially on the loop thread.
- Automatic source-level resource finalizers that start asynchronous work from
  Lua GC.
- Replacing Lua's own `io`, `os`, `math`, or `string` tables.
- Detailed plans for the separate Titan `math`, `string`, and `lua` modules.
  Their Lua-facing names should reuse the `titan.*` alias packaging described
  here.

## Evidence from the current repository

The current architecture already supplies the necessary substrate:

- `stdlib/coroutine.titan` owns coroutine policy while
  `titan-runtime/titan_coro.c` owns a small native trampoline
  (`doc/implementation/coroutines.md:3-14`).
- The trampoline recovers a rooted module and entry `CClosure`, reads the native
  pointer from `upvalue[2]`, and calls it directly with `_fn == NULL`
  (`titan-runtime/titan_coro.c:16-27`).
- A hidden identity tag can route a yield out through nested coroutines. The
  matching root becomes `suspended`, inner coroutines become `stacked`, and
  resuming the root restores the chain (`doc/language/coroutines.md:77-88`).
- `stdlib/coroutine.titan` selects `stacked_co` when transferring values, so
  the callback only needs to own and resume the task root.
- Minicoro searches the active dynamic `prev_co` chain for a matching tag; it
  does not search unrelated suspended roots (`titan-runtime/minicoro.h:1854-1864`).
  One hidden tag can therefore be shared safely by all independent UV tasks.
- C FFI types may be used locally but may not appear in exported Titan
  interfaces (`doc/language/ffi.md:102-118`). The public libraries therefore
  expose only Titan records, scalars, strings, arrays/maps, and functions. An
  exported record's local field may hold a C pointer because that field is
  omitted from the compiled public interface. A record with any local field has
  no externally callable `new`, and outside constructor expressions are
  rejected (`doc/language/records.md:141-145,183-186,262-275`). This is the
  preferred opaque-native-handle boundary.
- The FFI supports imported function names decaying to compatible C function
  pointers (`doc/language/ffi.md:250-270`). Fixed shim callbacks can therefore
  be passed directly to `uv_timer_start`, `uv_fs_*`, `uv_read_start`, and other
  public libuv APIs.
- The FFI supports `<module>.<type>.sizeof` and `.alignof`, exact `TValue`
  transfer, the built-in current `L`, mutable C out parameters, owned C
  userdata, pointer indexing, and explicit C pointer casts.
- Titan strings are binary values, but the generic FFI `char * -> string` cast
  stops at NUL and a generic `string -> char *` borrow is documented as
  call-duration-only (`doc/language/ffi.md:280-300`). Async buffers therefore
  need an explicit length and an operation-owned root/copy.
- The standalone launcher currently evaluates
  `require('<module>').main(arg)` directly (`titan-compiler/driver.lua:326-343`).
  Async wrapping is therefore a concrete compiler/entrypoint bootstrap change,
  not an overload of the public `uv.run` implementation.
- Source dependencies are statically linked while binary-only modules are
  dynamically loaded (`doc/language/modules.md:327-347`). The build must produce
  canonical `uv.so` first and make higher-level standard modules import that
  binary, so the shim and libuv archive are linked exactly once. Packaging also
  exposes a single-image Lua alias at `titan/uv.so` with
  `luaopen_titan_uv`.
- Module state is per Lua state (`doc/implementation/codegen-overview.md:483-490`).
  Libuv state must also be per Lua state/bootstrap session; no process-global
  default loop or task table is acceptable.

## Feasibility experiments and what they proved

All spike artifacts were kept under `/tmp`; none are production files.

### Environment and header pipeline

- The host runtime reports libuv `1.51.0`, but it has no `uv.h`, `libuv.pc`, or
  unversioned `libuv.so`. `pkg-config --modversion libuv` and ordinary `-luv`
  linking fail. A runtime SONAME is not a development dependency.
- Official libuv 1.43.0 and 1.52.1 headers both passed simple imports through
  Titan's real `cpp.parse_file -> c99 -> ctypes` pipeline. Generated modules
  called `uv_version_string` and emitted `sizeof(uv_loop_t)`,
  `sizeof(uv_timer_t)`, and `sizeof(uv_fs_t)` successfully.
- Some libuv structs remain incomplete in Titan's parsed type model on current
  headers, so `uv.Type.new()` is not a dependable production mechanism.
  `uv.Type.sizeof` still emits the C compiler's correct size.
- A current-header probe allocated a Lua userdata with
  `lua_newuserdatauv(L, uv.uv_loop_t.sizeof, ...)`, explicitly cast the returned
  `void *` to `*uv.uv_loop_t`, then ran `uv_loop_init` and `uv_loop_close`.
  It returned `0`. This is the preferred storage technique.
- With Titan's strict `--std=c99`, including current `uv.h` on Linux fails to
  expose `pthread_rwlock_t`/`addrinfo`. Adding the platform feature flags before
  all includes (`-D_GNU_SOURCE` on Linux) fixes it. `titanc` therefore needs
  standard-library-specific extra C flags or an equivalent driver hook.

### Libuv lifetime probe

A standalone public-libuv C probe ran this chain:

```text
zero timer -> async open -> write -> read -> close -> unlink
```

It intentionally checked loop closure before drain, cleaned every `uv_fs_t`,
freed the timer only from its close callback, then drained and closed the loop.
The observed summary was:

```text
version=1.51.0 busy=EBUSY run=0 close=0
stage=5 timer_closed=1 callbacks=7 read='async-ok'
```

This pins the two different libuv lifetime families:

- requests finish at their completion callback; filesystem requests also need
  `uv_fs_req_cleanup`;
- handles finish only after `uv_close` invokes the close callback.

### Direct native callback and continuation probes

- A zero timer stored a Lua userdata owner in `handle->data`. Its uservalues
  rooted the main Lua thread, module Udata, and a module-local Titan dispatcher
  closure. The C callback recovered `pvalue(&dispatcher->upvalue[2])` and called
  the native Titan function directly. The success path returned `true`.
- A forced dispatcher error was caught inside that native Titan dispatcher. The
  libuv callback returned normally and the captured trace named both the
  dispatcher and task driver; no error crossed libuv.
- Timer and async filesystem callbacks directly resumed Titan coroutines under
  generational GC with a forced full collection between submission and
  completion. The operation owner, coroutine, buffers, module, and dispatcher
  survived.
- The end-to-end `/tmp/uv-probes/uv_nested_titan_probe` exercised the selected
  continuation path: a native timer callback resumed a task; that task submitted
  asynchronous filesystem work and yielded its Request; the current callback
  armed the FS operation and returned; the native FS callback later resumed the
  same task with the bytes. It exited `0`.
- A queued post-`uv_run` prototype also worked, but it proves only that a more
  elaborate alternative is possible. It is not needed by libuv's contracts and
  is not the selected design.
- Existing coroutine tests cover nested tagged routing, injected errors,
  stacked-resume rejection, traceback preservation, and generational rooting
  (`spec/coder/coro_spec.lua:295-428,647-733`).

### Shared-tag probe and prior art

A focused current-runtime probe used two independent roots with one identity
tag, interleaved them, and routed a yield through a differently tagged nested
coroutine. It observed:

```text
shared-independent-ok nested-skip-ok nearest-same-tag-confirmed
```

The first two results prove the intended design. The third deliberately resumes
an inline child with the same tag and demonstrates the dynamically nearest
handler rule; `UV_TAG` therefore stays private, and `uv.run` schedules a new
independent root instead of resuming it inline.

This is the model used by taggedcoro's `fortag`/`make` and lua-coronest's
`coroutine.make`: one tag-specialized coroutine API per abstraction (scheduler,
iterator, exception layer), not one tag per coroutine instance.

### Nonblocking run, nested scheduling, and recurring-tick probe

`/tmp/direct-model-probe/direct_model` exercised the corrected control flow.
`run(A)` returned with `A-started=false`; A's first callback directly ran A; A
called nested `run(B)`, which scheduled but did not execute B; A then completed
three callback -> resume -> `tick()` yield -> arm-next-tick -> callback-return
cycles. Selected trace points were:

```text
schedule:A run-depth=0
after-run:A-started=false
uv-run-enter depth=1
cb-enter:A:1 run-depth=1
schedule:B run-depth=1
A:yield-tick:1
arm-tick:A in-callback=1
cb-return:A:1
cb-enter:B:1 run-depth=1
...
loop-close=0 max-run-depth=1 tick-callbacks=3
RESULT ok direct=true nested=true ticks=3 max-run-depth=1
```

This directly proves that nested public `run` does not re-enter C `uv_run`,
that user code intentionally runs inside callbacks, and that a repeating timer
can use the coroutine itself as its continuation across ticks. It is a control-
flow proof, not the production main-state proof: the implementation test must
additionally call nested `uv.run` from child state `T` and assert that its start
callback dispatches on `Runtime.main_thread` `L`, as specified below.

### Experiment-driven constraints

1. The callback state is the loop's main Lua state, never the child Lua
   state whose native stack is suspended inside minicoro.
2. A raw `Udata *`, `CClosure *`, `lua_State *`, or buffer pointer in libuv data
   is navigation only; it is not a GC root.
3. The completed operation owner stays rooted through result extraction,
   request cleanup, direct task execution, and the handoff. Root the next owner
   before removing the old pending root.
4. Copy/extract callback-owned result data and perform mandatory request cleanup
   before resumed user code can observe the result.
5. The C trampoline calls the native Titan dispatcher directly. That dispatcher
   is library code under Titan's control. Its inner Task catch records Task
   terminal state; its trailing function-level catch contains all remaining
   throwing work, records Runtime-fatal state, and returns normally to libuv
   without a second C protected-call layer.
6. Only C `uv_run` is non-reentrant. Directly resuming a coroutine and starting
   a new libuv operation from a callback are part of the selected model and do
   not call `uv_run` recursively.
7. `uv_stop` only makes the outer `uv_run` return. It does not close handles, finish
   requests, or make `uv_loop_close` succeed.
8. Libuv worker threads never call Titan. Filesystem completion callbacks return
   on the loop thread. If `uv_queue_work` is added later, only its
   `after_work_cb` may dispatch to Titan.

## Review of `/tmp/uv-io.md`

### Parts to keep

- A thin C shim rather than general callback support.
- A hidden coroutine tag and direct-style `yield`/resume boundary.
- A synchronous-looking high-level API.
- Separate filesystem, network, OS/process, and timer modules.
- Pausing stream reads and retaining excess bytes in the connection.
- Fixed C trampolines that recover a Titan module dispatcher.

### Clarifications and required corrections

| Sketch point | Final design |
| --- | --- |
| One hidden module string tag | Keep one module-wide tag, but make it a fresh private identity object rather than a guessable string. Tags distinguish coroutine abstractions, not tasks. |
| Start each task with a zero timer | Keep this. `uv.run` arms the zero timer and returns without executing the task; its callback performs the first resume on the next loop iteration. |
| Callback resumes and interprets the next request inline | Keep this. The coroutine is the continuation an ordinary callback API would pass explicitly. The Titan dispatcher arms the next yielded Request before the callback returns. |
| Raw L/module/closure/coroutine tuple in `data` | `data` points to the opaque Titan wrapper-record Udata rooted in `Runtime.pending` or `Runtime.resources`; its local fields root the distinct native-storage userdata plus every Titan value. |
| Print traceback from a callback | Save `{error, traceback}`, mark the Runtime fatal, request `uv_stop`, and return through libuv. The outer bootstrap then initiates cancel/close, drains, reinstalls/pins the trace, and reports the failure. |
| Default/global event loop implied | Use one private loop per bootstrap session so state remains per Lua state, while all `uv.run` tasks in that session share it. |
| Callback owns scheduling policy | Keep policy and the trailing function-level error boundary in the native Titan dispatcher; the C trampoline only normalizes callback ABI, recovers trusted rooted fields, and calls the native entry directly. |
| Main is automatically wrapped | Keep automatic standalone bootstrap: schedule `main` with public `uv.run`, then drive C `uv_run` outside all callbacks. |
| Titan imports `fs`, `net`, `os`, `timer` | Keep these canonical Titan names. Install Lua-facing aliases as `titan.fs`, `titan.net`, `titan.os`, and `titan.timer` so Lua's existing modules remain untouched. |

## Module and file layout

Add these production files:

```text
stdlib/
  coroutine.titan          existing coro.titan policy module, moved and renamed
  uv.titan                 public task API + private continuation pump
  timer.titan              timers and cooperative yield
  fs.titan                 files and path operations
  net.titan                DNS and TCP
  os.titan                 portable OS/process/signal operations
titan-runtime/
  titan_uv.c               fixed native libuv callbacks and narrow helpers
  titan/uv.h               parser-friendly callback/helper declarations
```

`uv` is the only Titan module that imports C types. Its exported surface
contains no publicly visible C FFI type, but it exports nominal opaque wrapper
records whose local fields hold the native pointers. Higher-level modules
dynamically import those record types and use reserved underscore-prefixed
middle-layer functions such as `_fs_open`, `_tcp_read`, and `_spawn`. Titan has
no package-private visibility, so those names are technically public; document
them as unstable. Exact record parameters make their handles unforgeable from
Titan, and generated Lua entries enforce record/metatable identity. Runtime
checks remain for legitimate-but-closed handles and handles from an older
Runtime generation, not for arbitrary `value` forgery.

Use the symbol prefix `titan_uvshim_` for C helpers. The generated module name
`uv_*` occupies the logical-module prefix.

### Canonical Titan names and Lua aliases

Add the `stdlib` origin to Titan's default import resolution, including when
`--tree` selects an application root. Reserve the canonical names `coroutine`,
`uv`, `timer`, `fs`, `net`, and `os` for this standard library and resolve them
from a pinned standard-library source/binary origin before ordinary application
lookup.
Diagnose an application module that attempts to claim one of those names.
This stronger rule is necessary because Titan's source dependency graph,
binary rehydration cache, and generated `loadlib("uv.so")` calls all key the
module by its short canonical identity: merely appending a source path would
allow an application `uv.titan` or `uv.so` to become the private dependency of
standard `fs`; the same rule prevents a local `coroutine` from capturing `uv`'s
coroutine dependency. It also makes `import "coroutine"` and `import "os"`
reliably resolve the standard modules while leaving Lua's loader and Lua's own
`coroutine` and `os` tables out of Titan import resolution entirely.

Pinning must survive code generation. Mark a resolved dependency as
standard-origin metadata and make `titan-compiler/coder.lua` emit a distinct
runtime `loadstdlib` path for it. `titan-runtime/titan.c` implements that path
from a dedicated standard-library directory configured by the Makefile/install
(`TITAN_STDLIB_PATH`, with an installed ABI-directory default); it never searches
`.` or ordinary application `TITAN_PATH` entries. Generated ordinary imports
continue to use `loadlib`. An application source chain importing `fs` and a
binary-only `fs` must therefore reach the same canonical `uv.so`, and `uv` must
reach canonical `coroutine.so`, even when the application supplies fake local
`uv`/`coroutine` sources and binaries.
Custom-prefix installation instructions and
`make help` must show how the standard path is selected rather than relying on
the developer's environment.

Ordinary application compilation always consumes a reserved standard module as
that pinned canonical binary, even when the repository's `stdlib/*.titan`
sources are visible; it never recursively source-links a second
`coroutine`/`uv` or
emits an accidental `luaopen_os`. Standard sources are roots only in an explicit
Makefile/driver `--stdlib-build` mode. That mode builds one canonical root at a
time, attaches its Lua alias metadata to that root, and still resolves all
reserved standard dependencies through already built canonical binaries. The
build order is therefore `coroutine` first, then `uv`, then the higher modules.
This is the same single-implementation rule for static executables and DSOs,
not only an install-layout rule.

Move and rename the existing repository-root `coro.titan` to
`stdlib/coroutine.titan` as part of introducing this layout; do not leave a
duplicate or forwarding source at the root. Rename its focused spec to
`spec/coder/coroutine_spec.lua`, and update the Makefile input, LuaRocks
source/install packaging, test build helper, and every documentation path and
module-name reference in the same change. The new canonical Titan import is
`import "coroutine"`, and its only Lua-facing name is
`require "titan.coroutine"`. Do not install a legacy `coro.so`, `require "coro"`
alias, or bare `luaopen_coroutine` entry.

Compile each module under its canonical Titan name (`os`, `uv`, and so on), and
install the canonical binary as `<Titan ABI path>/os.so`. Lua also gets an alias
at `<Lua C path>/titan/os.so`. Because Lua's C loader asks that path for
`luaopen_titan_os`, add a general driver/build option that separates the
Lua-facing require name from the canonical Titan module name, for example:

```text
titanc --stdlib-build --tree stdlib --lua-name titan.os os
titanc --stdlib-build --tree stdlib --lua-name titan.coroutine coroutine
```

This emits `os_init`/`os_abi`/`os_types` for Titan import and
`luaopen_titan_os` for Lua require. It deliberately does not emit
`luaopen_os`, avoiding a C-symbol collision with Lua's standard `os` library.
The option changes only the requested non-main root module's generated
`luaopen_*` postamble: it must not change the canonical module name, registry
key, native symbol prefix, serialized interface, or recursively compiled
dependencies. Applying one alias to several roots is rejected as ambiguous.
`require "titan.os"` and `import "os"` therefore initialize the same canonical
module Udata, while `require "os"` still returns Lua's table. Likewise,
`coroutine_init`/`coroutine_abi`/`coroutine_types` coexist with
`luaopen_titan_coroutine`; no `luaopen_coroutine` is emitted, and
`require "coroutine"` still returns Lua's standard table. Apply the same mapping
to `math`, `string`, and `lua` when those modules are added.

The canonical path and Lua alias must resolve to one mapped DSO image, not two
byte-for-byte copies. This matters especially for `uv.so`: two independently
loaded images would contain two statically linked libuv instances even if both
entry functions recover the same registry Udata. Prefer a relative symbolic
link to the canonical binary and verify loader coalescing on Linux and macOS;
if the package layout cannot preserve that link, install a tiny forwarding
alias DSO that contains no Titan module or libuv objects and opens/calls the
canonical entry. Require-first and import-first tests inspect constructor/load
counters and native symbol addresses to prove exactly one canonical image and
one Runtime implementation are active.

A scratch binary proof must be promoted into tests: an aliased `os.so` exports
`luaopen_titan_os` plus `os_init`/`os_abi`/`os_types`, does not export
`luaopen_os`, preserves `package.loaded.os`, and returns the same registry Udata
and mutable module state through Lua `require "titan.os"` and a separately
compiled Titan consumer's `import "os"`. This requires no module ABI bump.
Also link a standalone against Lua's built-in `luaopen_os` and the distinct
`luaopen_titan_os` to prove both symbols coexist.
Repeat the identity/symbol proof for canonical `coroutine.so` and its
`titan/coroutine.so` alias: `import "coroutine"` and
`require "titan.coroutine"` share one module Udata, `package.loaded.coroutine`
is unchanged, and Lua's built-in `luaopen_coroutine` coexists with the distinct
`luaopen_titan_coroutine`.

## Callback continuation runtime design

### Runtime ownership

The `uv` module Udata owns one `UV_TAG` for its Lua state and an
`active_runtime` slot. Each active loop/bootstrap session references that tag
and owns this Lua-traced graph:

```text
uv module Udata ------------> one private UV_TAG identity
  |
  +-- active_runtime -------> Runtime

Runtime (module-local record + opaque loop-wrapper record)
  |
  +-- main thread value
  +-- loop wrapper ----------> local `*uv_loop_t` pointer
  |                              +-- rooted native-storage userdata
  +-- shared UV_TAG reference
  +-- tasks map ----------> Task ----------> root coroutine.Coro
  |                           |                  +-- coroutine handle userdata
  |                           +-- state/result   +-- child Lua thread
  |                           +-- operation epoch+-- entry closure/function
  |                           +-- current op
  +-- pending map --------> opaque operation-owner record userdata
  |                           +-- local typed native pointer
  |                           +-- rooted native-storage userdata
  |                           +-- main thread / module / dispatcher uservalues
  |                           +-- Task / Request / input/output roots
  +-- resources map ------> opaque timer/file/TCP/process wrapper records
  +-- main Task/result ----> standalone exit result
  +-- first failure ------> exact error value + copied traceback string
```

Every arrow that reaches a Lua/Titan value is visible to the Lua collector.
Libuv `data` pointers point back into this graph but do not create it.
An async API may be called while Titan is running on the Task's child
`lua_State *T`; it may allocate there, but every callback owner stores
`Runtime.main_thread` in its main-thread uservalue, never the call's current
`L`. Native callbacks always recover and dispatch on that main `lua_State *`.
This is especially important for nested `uv.run`, whose caller state and later
start-callback state are deliberately different.

`active_runtime` is a module Udata slot, so it is per Lua state. Any number of
public `uv.run` tasks share it. Only a second loop driver/bootstrap is rejected
while C `uv_run` is active. After complete shutdown and `uv_loop_close == 0`,
clear it so a later sequential session can create a fresh loop. `uv.run`
lazily creates an idle session when Lua embedding schedules before `uv.loop`;
it still does not drive or resume anything.

### Task state

An opaque `Task` contains:

- root `coroutine.Coro`;
- operation epoch/generation number;
- state: `new`, `ready`, `running`, `waiting`, `succeeded`, `failed`, or
  `cancelled`;
- current operation owner;
- final error/trace when failed;
- joiners;
- sticky cancellation reason and a synchronously set cancellation epoch;
- cleanup-shield depth/state used only by library-owned terminal cleanup.

Only the fixed start/operation/resource callback dispatchers call
`root:resume` or `root:error`. `uv.run` itself never does. Because current
`coroutine.create` accepts `(value) -> value` while public `run` accepts
`() -> value`, `run` creates a private adapter
`function(_ignored: value): value return func() end`, roots the adapter and its
captured `func` in the Task, passes the adapter to `coroutine.create`, and arms
a zero timer. The start callback resumes it with `nil`; the public function
still has no synthetic argument.

Every `_await` calls `coroutine.yield(request, UV_TAG)` explicitly; `yield` does
not consult a coroutine's default tag. In a user-created nested coroutine
belonging to another abstraction, the UV yield walks outward until the UV task
root's active resume. That root becomes `suspended`, intermediate coroutines
become `stacked`, and the next callback resumes the exact root captured in its
owner. `Runtime.running_task` may still support join/ownership diagnostics, but
it is not used to choose the coroutine tag.

`Task:join()` returns immediately for an already terminal Task. Otherwise it
yields a Join Request with `UV_TAG`; target completion arms a zero-timer wakeup
for each joiner rather than inline-resuming an independent root from the
target's callback. This keeps nested `uv.run` Tasks dynamically independent and
bounds fan-out per callback.

### Request flow

Use one private `Request` record in `uv`. It has an integer operation kind,
ordinary Titan/value arguments, and a generation. No tagged-variant language
feature is required.

The selected flow is:

1. `uv.run(func)` creates and roots the private `(value) -> value` adapter,
   creates `coroutine.create(adapter, UV_TAG)`, roots the Task, allocates a
   GC-owned zero timer, and arms its one-shot start callback. `func` has not run
   when `uv.run` returns. Failure to create the Runtime/loop before a Task exists
   raises synchronously. A timer init/start failure after Task creation marks
   and returns that Task failed without running `func`; init failure has no live
   handle, while start failure initiates `uv_close` and keeps its owner rooted
   for the later close callback. The next `uv.loop`/standalone bootstrap drains
   that cleanup and applies normal observed/unobserved Task policy.
   Whether called from Lua's main thread or a running child Task, the start
   owner records the Runtime's main thread for its native callback.
2. The start or operation callback retrieves its exact Task owner and directly
   calls the native Titan dispatcher on the main Lua state.
3. For a completed operation, the dispatcher first copies/converts all borrowed
   result data and performs mandatory request cleanup. Arbitrary user code never
   sees request-owned pointers.
4. The dispatcher calls `root:resume(result, UV_TAG)` or
   `root:error(error, UV_TAG)`. User code now runs synchronously on the loop
   thread until it finishes or an async API calls
   `coroutine.yield(request, UV_TAG)`.
5. When the call returns, inspect `root:status()`:
   - `suspended`: the returned value must be the private Request and its epoch
     must match the Task;
   - `dead`: store the task result, wake joiners through their own callbacks,
     and retire the Task after physical owner cleanup;
   - anything else: record an internal invariant failure.
6. For a yielded Request, allocate its native-storage/buffer userdata, capture
   those roots in a new opaque operation-wrapper record, insert that record in
   `pending`, associate the record Udata through public libuv data APIs, and
   submit the operation. Root this new wrapper before releasing the completed
   owner's logical root.
7. A successful asynchronous submission leaves the Task waiting; the current
   callback restores the main Lua stack and returns to libuv.
8. A negative immediate return means no completion callback will arrive. Apply
   the lifecycle-matrix cleanup arm and iteratively call `root:error` with that
   error in the same dispatcher. Do not recurse and do not wait for a nonexistent
   callback. Cap consecutive immediate iterations and defer through a zero timer
   if needed to preserve loop responsiveness.
9. An error or the library-injected `Cancelled` escaping the root drive is a
   normal Task terminal outcome: store its exact value/trace, wake registered
   joiners, and apply the observed/unobserved Task policy below. It is not itself
   a broken dispatcher. A separate trailing function-level catch treats
   malformed private Requests and pump/library invariant failures as fatal
   Runtime errors. Both Titan boundaries return normally through the direct C
   callback.

For `uv_fs_t`, use public `uv_fs_get_result`, `uv_fs_get_ptr`,
`uv_fs_get_statbuf`, `uv_fs_get_path`, and `uv_fs_scandir_next` as appropriate.
Copy all request-owned data before calling `uv_fs_req_cleanup` exactly once.
The immediate-submission-error arm also runs its operation-specific cleanup;
it is not a shortcut around this state machine.

### Loop bootstrap and callback scheduling

Public `uv.run` is not the libuv loop runner. Use these distinct layers:

```text
public uv.run(f)             create/root task + arm zero timer + return Task
private uv._bootstrap(main)  uv.run(main) + drive the session + report result
C uv_run(loop, mode)         poll and invoke callbacks; never called in callback
public uv.loop()             explicit loop driver for Lua embedding/non-main use
```

The standalone hook and public `uv.loop()` may drive only from the Lua main
thread, where the outer protected entry/`errfunc` and callback stack contract
are installed; `uv.loop()` called from a Lua/Titan child coroutine is rejected
before C `uv_run`. This restriction does not apply to task-starting `uv.run`,
which remains valid inside a running UV Task or another nested coroutine.

The generated standalone entrypoint first loads the main module, which
initializes its transitive imports, and retrieves the main callable. Only then
does it read a private main-bootstrap hook from the Lua registry. If that hook
is present, the entrypoint passes the main callable and arguments to it under
the existing outer `lua_pcall`; otherwise it preserves today's direct
synchronous call. Put the shared registry-key definition in both `titan.h` and
`titan/ffi.h`. The hook creates the private session, schedules main through
ordinary `uv.run`, and then invokes C `uv_run(loop, UV_RUN_DEFAULT)` from
outside all callbacks. This registry hook makes source-linked and binary-only
application source chains and binary-only async dependencies behave the same
and does not link libuv into programs that never import `uv`.
Registration is idempotent for the same canonical `uv` module and rejects a
different bootstrap provider instead of silently changing main semantics.

C `uv_run` depth is always one. A callback may resume arbitrary Titan code and
start requests/handles, but it never calls `uv_run`, `uv_loop_close`, or a
second bootstrap. `timer.yield()` explicitly cedes to a zero timer on the next
turn. CPU-heavy code that does not yield blocks the loop just as CPU-heavy code
inside a conventional libuv callback would; this is documented cooperative
scheduling, not a hidden fairness queue.

When the final live Task becomes terminal, begin normal session cleanup of all
remaining session-owned resources. This closes both active leftovers (for
example, a Ticker whose last waiter was cancelled) and passive leftovers (for
example, an idle File or connected TCP handle) that cannot be used once no Task
remains. It also means normal exit does not depend on passive handles keeping
`uv_run(UV_RUN_DEFAULT)` alive. If that C call returns while Tasks remain
logically waiting but the loop is not alive, report a deadlock with their
Task/Request kinds. Normal or failure cleanup may call `uv_run` again to drain
request/close callbacks only after the active invocation has returned.

## Low-level FFI and C shim contract

### Titan-owned storage first

For a loop, request, or handle:

1. Read the exact C size and alignment from `uv.<type>.sizeof` and `.alignof`.
2. Save the Lua API stack top, then call `lua_newuserdatauv` from `uv` for the
   native byte storage. The call returns the payload pointer and pushes its
   owning full userdata.
3. While that userdata is stack-anchored, capture the already created value
   once with `ffi.lua_totvalue(L, -1)` into a GC-visible `storage` local. This
   is not native-handle-to-`value` coercion and allocates no second userdata.
4. Cast the returned `void *` payload to the source-level pointer type such as
   `*uv.uv_loop_t`, `*uv.uv_fs_t`, or `*uv.uv_timer_t`.
5. Construct the object's nominal Titan wrapper once. Its local typed-pointer
   field stores the pointer directly and its local `storage` field takes the
   captured value. Only after both fields are installed may code restore the
   saved Lua API stack top.
6. Keep the wrapper/owner in `pending`/`resources` before a call that can make
   it visible to libuv.
7. Use public `uv_loop_set_data`, `uv_req_set_data`, or `uv_handle_set_data` to
   associate the wrapper record Udata as the callback owner, not the separate
   native-storage userdata; avoid depending on macro-expanded struct fields in
   Titan's parsed type model.
8. Remove the final root only after the operation's terminal callback or the
   handle close callback returns and all required cleanup is complete.

This works even when Titan considers the imported libuv struct incomplete:
`.sizeof` and the pointer cast are emitted for the C compiler, which sees the
real definition. Phase 0 must assert for every allocated libuv type that the
returned userdata payload satisfies its imported alignment. If a future
platform has an over-aligned type, use the rooted pointer-owner fallback for
that type rather than assuming alignment.

Titan currently rejects libuv's implicit concrete-to-base pointer conversions
such as `uv_timer_t * -> uv_handle_t *`. Keep tiny concrete typed wrappers in
the shim for set/get-data, `uv_close`, `uv_is_closing`, and similar base-handle
calls; each wrapper performs only the cast and calls the corresponding public
libuv API. Do not read private fields or expand this into POSIX wrappers.

Import `uv.h` once and keep the private shim header narrow. The spike found
false `stdin`/`stdout`/`stderr` declaration conflicts when `stdio.h` was also
foreign-imported independently; avoid redundant broad system-header imports
and add a parser regression before introducing one.

Use library/shim allocation only when an API allocates and returns its own
object or when callback-driven variable storage cannot practically be created
in Titan. The fallback mirrors `stdlib/coroutine.titan`: one pointer-owner full userdata is
captured in the wrapper's local `storage` field, the matching library cleanup is
explicit, and `__gc` is a last-resort passive memory release. Never free an
initialized libuv handle from `__gc` before its close callback.

### Opaque native wrapper records

Do not transport a native pointer through `value`. Define a nominal record in
`uv` with a local typed-pointer field instead, exporting that record when it
must cross into a higher-level module. The minimal exported pattern is:

```titan
local uv = foreign import "uv.h"

record uv_fs_t
  local handle: *uv.uv_fs_t
end
```

Only `uv` can call this record's synthesized local constructor or write/read
`handle`. Titan code outside the module cannot forge a `uv_fs_t`, and a
non-optional variable/parameter of that record type is guaranteed to contain an
instance of that exact record. Generated Lua entries likewise check its record
metatable identity. Middle-layer functions therefore accept the exact wrapper
type and use `wrapper.handle` directly, with no native-pointer-to-`value`
coercion, dynamic cast, or unwrap allocation.

This is a material cost distinction, not only a type-safety preference: the
FFI's native-pointer-to-`value` coercion allocates a userdata each time the
coercion occurs. A local pointer field is stored once in the record and read as
the native pointer type on every later call.

The `uv_fs_t` snippet illustrates the exported form. If filesystem request
objects remain entirely inside `uv`'s continuation pump, declare that wrapper
as `local record uv_fs_t` instead; only persistent file/resource wrappers used
by `fs` need an exported nominal type.

The production owner record adds only private lifetime metadata required by the
object family, for example:

```titan
record uv_fs_t
  local handle: *uv.uv_fs_t
  local storage: value
  local runtime_generation: integer
end
```

`storage` is the one-time GC root for the already allocated native payload
userdata; it is not a boxed representation of `handle` and is never recreated
on calls. Every long-lived wrapper also carries Runtime generation and explicit
lifecycle state; watcher/stream wrappers carry their waiter/epoch as required.
Before reading `handle`, every middle-layer entry validates the exact record,
matching active Runtime generation, and a state in which that operation is
legal. Request wrappers keep their operation roots and state bits until the
terminal callback. Terminal cleanup marks a reachable wrapper closed/cleaned
before releasing Runtime roots; if it clears `storage`, it also nulls a pointer
handle so even an internal missed state check cannot use reclaimed bytes.
Scalar `uv_file` wrappers use their state plus an invalid descriptor sentinel
and need no separate native-storage userdata.

Thus each native object pays for one Titan record wrapper and, for
struct-backed families, one native-storage allocation, while repeated
method/middle-layer calls pass the record and read the C pointer without
allocating another userdata.

Nominal unforgeability proves what kind of handle arrived; it does not prove
that the handle is still live. The lifecycle/generation checks above remain
mandatory.

The Titan wrapper record instance is also the callback owner: libuv `data`
stores its stable `Udata *`, while `Runtime.pending`/`resources` keeps that
record alive. The wrapper's local `storage` field in turn keeps the native byte
payload alive. The storage userdata is never used as the callback identity.

Export wrapper record types for each family that crosses from a higher module
into `uv` (file, timer/ticker, TCP stream/server, pipe, process, and any
request/resource token that is actually exposed). Keep purely internal request
types local. The higher-level `File`, `Ticker`, `Connection`, `Server`, and
`Process` records each have a local field of the corresponding `uv` wrapper
type, making their own constructors local as well. `value` remains appropriate
for genuinely dynamic Task results/cancellation reasons and for one-time Lua GC
roots such as `storage`; it is not the native-handle representation.

Concretely, the first exported wrapper set is `uv_timer_t` with
`*uv.uv_timer_t`, `uv_file` with scalar `uv.uv_file`, `uv_tcp_t` with
`*uv.uv_tcp_t`, `uv_pipe_t` with `*uv.uv_pipe_t`, and `uv_process_t` with
`*uv.uv_process_t`. Request records such as `uv_fs_t`, `uv_connect_t`, and
`uv_write_t` stay local unless a later API genuinely needs to expose them.

### Uservalue layout

Give every callback owner a documented fixed slot layout. A representative
layout is:

| Slot | Private field/role |
| --- | --- |
| 1 | local typed native-pointer field (navigation, not a GC root) |
| 2 | local native-storage userdata root |
| 3 | loop/bootstrap main Lua thread |
| 4 | `uv` module Udata |
| 5 | fixed module-local native dispatcher CClosure |
| 6 | Task/root coroutine |
| 7 | private Request/operation metadata |
| 8 | input/output buffer or distinct resource owner |

These are the opaque record's local fields/uservalues; not every family needs
every slot, but a family must have one stable contract covered by a C layout
test. Lua's uservalue API numbers these slots from one; the corresponding
`Udata.uv` indices in the C shim are zero-based. Define both sets of named
constants together and assert the mapping in that layout test.

### Native callback path

`titan-runtime/titan_uv.c` follows the current coroutine pattern:

```c
typedef void (*titan_uv_dispatch_func)(lua_State *L, Udata *_mod,
                                       CClosure *_fn, Udata *owner,
                                       lua_Integer event_kind,
                                       lua_Integer result,
                                       size_t size,
                                       void *pointer);

/* Public libuv accessors and trusted raw owner fields do not allocate. */
Udata *owner = uv_req_get_data((uv_req_t *)req);
lua_State *L = titan_uv_owner_main_thread(owner);
Udata *M = titan_uv_owner_module(owner);
CClosure *dispatcher = titan_uv_owner_dispatcher(owner);
titan_uv_dispatch_func dispatch =
    titan_cast_func(titan_uv_dispatch_func,
                    pvalue(&dispatcher->upvalue[2]));

/* Direct native Titan entry, exactly like titan_coro_entry. */
dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
```

The owner remains strongly rooted by `Runtime.pending` or `Runtime.resources`
for the entire callback. Its fixed uservalues supply `Runtime.main_thread`, the
module Udata, and the dispatcher closure; the C trampoline only reads those
trusted fields, normalizes the particular libuv callback ABI, and transfers
primitive result values plus one fixed pointer payload. That payload is `NULL`
except when a callback supplies borrowed native result storage, such as DNS's
`addrinfo` list; the dispatcher copies and releases such storage before it can
drive user code. Request/handle families use the corresponding public libuv
data getter.

The dispatcher is a fixed module-local top-level function with no captures, so
`_fn == NULL` matches `titan_coro_entry`. Do not route through its Lua wrapper;
these callbacks are frequent and their arguments are already trusted by the
private shim.

There is deliberately no `titan_uv_callprotected` layer. The dispatcher is
trusted library code, not an arbitrary user callback, and follows the same
direct native-entry contract as `stdlib/coroutine.titan`/`titan_coro_entry`. Its entire
controlled body is followed by a trailing function-level Titan `catch`. The
catch arm uses the still-rooted owner to store the exact `error` and `traceback`
in the Runtime, marks it fatal, calls public `uv_stop`, and returns. Because a
trailing catch arm is not itself protected, keep it inline and non-raising:
existing-field assignments, scalar state changes, and `uv_stop` only—no
allocation, formatting, potentially raising Titan helper call, or user code.
The outer bootstrap performs phased cleanup and reporting only after C `uv_run`
has returned.

The loop driver, not each callback, owns the active Titan `errfunc`. The
standalone outer `lua_pcall` or generated Lua entry for `uv.loop()` keeps the
Titan error handler installed for the complete C `uv_run` invocation. Reject a
loop-driving path that bypasses both entries; do not install or restore an
error handler per callback.

The Titan dispatcher has an inner Task-drive boundary and an outer invariant
boundary:

- normal path: validate owner epoch/state, copy/extract the completed result,
  perform mandatory request cleanup, directly resume/error the exact Task, and
  arm the next yielded Request before returning;
- Task boundary: an error or `Cancelled` escaping `root:resume`/`root:error` is
  stored as that Task's terminal outcome, joiners are scheduled, and only an
  unobserved failure applies the session-failure policy;
- invariant boundary: a dispatcher bug saves the exact `error` and `traceback`,
  marks the Runtime fatal, requests `uv_stop`, and returns; the outer bootstrap
  begins phased shutdown after C `uv_run` returns;
- it never re-raises while the C callback is active.

The outer bootstrap regains control from C `uv_run`, drains orderly shutdown,
and only then reinstalls/pins the saved trace and reports the error.

### Initial fixed callbacks

Declare only the callback shapes actually needed:

- timer;
- handle close;
- filesystem request;
- stream allocation/read;
- connect;
- write;
- incoming connection;
- getaddrinfo/getnameinfo;
- process exit;
- signal.

Imported shim function names decay to libuv's callback pointer typedefs. The C
functions contain only ABI conversion and trusted raw owner/entry recovery; the
native Titan dispatcher owns stack discipline, both Titan catch levels, and the
direct request pump.

### Binary buffers

V1 uses explicit-length buffers throughout.

- Known-size filesystem reads: allocate a Lua userdata byte buffer before
  submission and root it in the operation owner.
- Filesystem/stream writes: copy the Titan string into a GC-owned byte userdata
  and root both the owner and length until `uv_write_cb`/`uv_fs_cb`. A later
  proven optimization may pin the immutable `TString` and write directly.
- Stream reads: when a waiter starts reading, associate a preallocated
  GC-owned buffer with the stream owner. The C alloc callback returns that
  buffer without entering Titan. For `nread > 0`, copy exactly those bytes into
  a Titan string before resuming the waiter. Libuv serializes callbacks on this
  loop, so the buffer cannot be overwritten while the callback and resumed
  continuation are executing. If the continuation yields another read Request
  for the same Connection, keep/restart reading; if it yields a different
  operation, completes, or closes, call public `uv_read_stop` before returning.
- `nread == 0` is not EOF; resume nothing and keep reading.
- Before resuming arbitrary code for any `nread < 0`, stop the read side and
  persist its terminal state on the Connection. `UV_EOF` makes this and all
  later reads return `nil` without another `uv_read_start`; another negative
  result stores a `uv.Error` which later reads re-raise without restarting.
  Libuv documents another read after a negative read callback as undefined.
- Higher-level methods retain excess bytes in the Connection before they yield
  again. `uv_read_stop` is idempotent and documented to always succeed. Its
  platform-specific nonzero Windows TTY result means resource release is still
  pending, not failure; do not turn it into an invariant error.

No NUL-terminated cast is used for file/socket payloads.

Paths, host/service names, environment names/values, and process arguments are
text rather than payloads. Reject embedded NUL bytes before crossing the FFI,
and keep an operation-owned NUL-terminated copy whenever libuv may retain the
pointer beyond the submission call. Tests must distinguish accepted binary
file/socket data from rejected NUL-containing text arguments.

### Multi-shot callback continuations

Long-lived handle owners carry at most one current waiter plus an epoch; this is
resource state, not a global completion queue.

- `Ticker:tick()` always yields a wait Request. The repeating timer callback
  clears the waiter and directly resumes it. If the continuation reaches
  `tick()` again on the same Ticker, the yielded Request reinstalls the waiter
  and the current callback returns; the next timer callback makes `tick()`
  return. With no waiter, ticks are dropped rather than accumulated. A Ticker
  is an independently shareable resource with one waiter: cancelling that
  waiter clears only the waiter/epoch and does not implicitly close the Ticker;
  `Ticker:close()` or final session cleanup owns stop-and-close.
- A stream owner follows the read behavior above. Only one reader may wait;
  surplus bytes live in the Connection buffer, not in extra callbacks.
- A Server directly satisfies one waiting `accept`; without a waiter it stores
  accepted clients in its bounded resource-local queue.
- Signal/timer/listener callbacks compare the waiter epoch before resuming.
  A one-shot timer or signal callback first clears its waiter, records
  `fired/stopped`, and initiates its exactly-once `uv_close`; only then may it
  resume arbitrary Titan code. Repeating Ticker state is reinstalled after the
  direct drive only when the resource is still open and the new waiter epoch
  matches. Cancellation or a stale event performs physical cleanup only and
  never resumes the Task twice.

Because loop callbacks are serial, no second callback fires while the current
callback's Titan continuation is executing. User code must nevertheless yield
cooperatively; a long computation delays all other callbacks exactly as it
would in a hand-written callback API.

## Errors and traceback preservation

Expose:

```titan
record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end

record Cancelled
  reason: value
end
```

Negative libuv statuses are converted with public `uv_err_name` and
`uv_strerror`. Copy both strings before releasing the request/context. EOF is a
normal optional read result, and cancellation is a distinct semantic value.

There are two error-injection paths and two nested Titan catch levels:

1. Immediate submission failure: clean the failed arm and iteratively inject
   `Error` with `root:error` from the current dispatcher; no callback is awaited.
2. Async operation failure: its callback copies/cleans the result and directly
   injects `Error` with `root:error` at the suspended `_await` site.
3. Task/user catch: the inner Task-drive boundary catches the error or
   library-injected `Cancelled` escaping `root:resume`/`root:error`, copies the
   catch-local `traceback`, and marks only that Task terminal before applying the
   observed/unobserved policy.
4. Runtime-fatal catch: the dispatcher's trailing function-level `catch` handles
   a malformed private Request or pump/library invariant, stores its catch-local
   `error` and `traceback`, marks/stops the Runtime, and returns normally to the
   direct C callback. It never re-raises while libuv is on the stack.

Do not depend on `registry[TITAN_BACKTRACE_KEY]` retaining a task failure while
other callbacks run. Store the traceback string in the Task/Runtime immediately.

Before `Task:join` or the outer bootstrap re-raises a stored error, reinstall
the saved trace and set `TITAN_TRACE_PINNED`, following
`stdlib/coroutine.titan` and
`doc/implementation/error-handling.md:27-49`. Joining a failed child appends a
join-site propagation trace so both the child failure and observer are visible.

The library never prints errors. Standalone/Lua callers retain control over
presentation.

## Task completion and cancellation

### Public task policy

V1 tracks every Task created by nonblocking `uv.run`:

- a Task with an already waiting joiner delivers its stored failure to the
  joiner; `Task:join` re-raises it with its saved trace and the joiner may catch
  it;
- a Task that fails with no waiting joiner is unobserved and fails the loop
  session; the dispatcher records/promotes it, requests `uv_stop`, and returns
  through libuv. The outer bootstrap then initiates cancellation/close, drains,
  and reports it;
- decide “unobserved” with a per-Task next-turn zero-timer check after control
  has returned to the Task's creator. This lets `uv.run` return an immediately
  failed start Task and lets an already running/scheduled observer register
  `join` before promotion; the timer is only an observation deadline, not a
  global ready/completion queue;
- a pending observation check prevents the Runtime from declaring the final
  Task set settled and entering normal cleanup. The check either finds an
  observer or promotes the failure; main-Task failures bypass this grace;
- every non-success terminal outcome of the standalone main Task, including
  `Cancelled`, is reported by the bootstrap instead of inventing an integer
  exit result. For non-main Tasks, an explicitly requested `Cancelled` outcome
  is not promoted merely because no one joins it; a joiner still receives and
  may catch that `Cancelled` value;
- joining self is rejected; a cycle among joiners is reported by the
  loop-deadlock diagnostic rather than hanging;
- completion of the standalone main Task stores its integer result but does not
  cancel independently scheduled `uv.run` Tasks. Once the final Task is
  terminal, normal session cleanup closes any leftover active or passive
  resources and drains their callbacks before returning;
- cancellation is cooperative and cannot preempt CPU-bound Titan code;
- cancellation is sticky: catching it permits cleanup, but a later `_await`
  observes it again, and returning without another await still leaves the Task
  terminally `cancelled`, so `join` raises its `Cancelled` value.

Classify a Task as `cancelled` only when its sticky cancellation state is set
and the escaping value is the library's corresponding injected cancellation;
a user-created/lookalike `Cancelled` raised without that state is an ordinary
Task failure.

Library combinators that need helper Tasks use a private observed-task
constructor which installs their parent/observer before the zero-timer start is
armed. They never create an unobserved helper and hope to join it later.

### Logical versus physical cancellation

`Task:cancel(reason)` synchronously sets the sticky cancellation flag/reason and
increments the Task epoch before it returns. That mark is the linearization
point: cancellation wins over any operation result not already delivered to
the coroutine. The method then schedules injection of `Cancelled(reason)`
through `root:error` at the next safe point and requests operation-specific
physical cancellation:

- cancellation requested by another Task never inline-resumes the target from
  the caller's callback. Arm a zero-timer cancellation callback for the exact
  target, preserving independent dynamic chains and bounding callback work;
- every ordinary `_await` checks the sticky flag before allocating, rooting, or
  submitting new work. If cancellation was marked while the Task was running,
  the yielded Request is rejected by the current dispatcher and cancellation
  is injected iteratively instead;
- every completion callback checks the sticky flag and epoch after mandatory
  result extraction/cleanup but before delivering a result or submitting a
  continuation Request. If cancellation won, normal result delivery is
  suppressed; the scheduled cancellation timer becomes a stale cleanup-only
  callback;
- library-owned cleanup awaits are shielded from the ordinary reject-new-work
  rule. `File:close`, handle close/drain, and process cleanup must reach their
  terminal callbacks. A cleanup completion may resume the shielded cleanup
  code, but the sticky cancellation remains pending and is reinjected at the
  next ordinary await (or determines the Task's terminal state on return), so a
  `finally` block is not interrupted at its first asynchronous close;

- non-cleanup request families supported by `uv_cancel`: call it, but keep the
  owner rooted until the completion callback, including when cancellation
  succeeds;
- never physically cancel `uv_fs_close` or another request whose purpose is
  required cleanup. Cancellation is logical only and is delivered after its
  callback and request cleanup. If a logically cancelled `uv_fs_open`
  nevertheless completes with a valid file descriptor, immediately schedule
  an uncancellable close and retain ownership until that close completes;
- timers: `uv_timer_stop`, then `uv_close`, free only after close callback;
- a cancelled Ticker wait clears that waiter/epoch but leaves the independently
  shareable Ticker open; explicit close or final session cleanup stops it;
- reads: `uv_read_stop`; clear only the waiter and keep the independently
  shareable Connection storage and late event handling valid;
- an in-flight connect owns an unpublished `uv_tcp_t`; close that handle on
  cancellation so libuv completes the connect request asynchronously, and keep
  both request and handle owners rooted through their terminal callbacks;
- a write uses an already published, potentially shared Connection, so do not
  close it merely to cancel one waiter; consume the eventual write callback;
- process wait: cancel the waiter without implicitly killing the child;
- explicit `Process:kill` controls process termination.

Any resource-producing operation that wins a race after logical cancellation
must dispose of the acquired resource instead of returning it or leaving it
idle: a successful late connect closes its stream handle, just as a successful
late open schedules the uncancellable file close above.

Generation and terminal-state checks make completion/cancellation exactly once.
A late callback after logical cancellation performs physical cleanup and is not
allowed to resume the task again.

Files, Connections, Servers, Processes, and Tickers are Runtime-owned resources
which may be shared among Tasks; they are not implicitly owned by their creator.
Cancelling a waiter therefore does not close a published resource. A newly
acquired resource becomes publishable only when its creating await returns;
until then, cancellation/abandonment owns and closes it. When no live Task
remains, the Runtime closes every still-registered resource because no future
continuation can use it. This rule prevents both shared-resource surprises and
active/passive leftovers rooted forever.

Dropping a coroutine is not cancellation. Current minicoro collection abandons
stacked frames without running user code, so it would skip `finally` blocks.

### Operation lifecycle matrix

Every owner carries an explicit state and separate logical-completion and
physical-cleanup bits. Requests normally progress `allocated -> submitted ->
callback_seen -> extracted -> cleaned -> unrooted`; handles progress
`allocated -> initialized -> closing -> close_callback_seen -> unrooted`.
Exactly-once assertions guard every transition. In particular, a cancellation
path must never wait for a callback that the public libuv operation does not
promise.

| Family | Immediate/start failure | Logical/physical cancellation | Terminal event and extraction | Final unroot point |
| --- | --- | --- | --- | --- |
| Private loop | Failed `uv_loop_init` leaves no live loop and releases its owner | Runtime shutdown drains all other families; `uv_stop` is only a wakeup | `uv_loop_close == 0` | After successful loop close |
| One-shot timer or signal wait | Init failure releases immediately; start failure after successful init injects the error iteratively and calls `uv_close` | `uv_timer_stop`/`uv_signal_stop`, clear waiter/epoch, then exactly-once `uv_close`; a cancellation callback injects at its safe point | Before arbitrary user code: mark fired/stopped, clear waiter, initiate close, then directly resume once | Only after close callback and after direct drive no longer needs the owner |
| Repeating Ticker | Same init/start split | Cancelling `tick` clears only its waiter/epoch. Explicit/resource-shutdown close stops and closes the Ticker and wakes a waiter with the applicable outcome | Callback clears and resumes the current waiter; reinstall a newly yielded `tick` only if still open and its epoch matches; with no waiter drop the tick | Close callback after no active drive/waiter references it |
| `uv_fs_t` including open/read/write/stat/path/scandir/close | A negative submit return follows the wrapper's cleanup arm and is injected iteratively; no callback is assumed | Call `uv_cancel` only for non-cleanup operations where supported. Never physically cancel `uv_fs_close`; logical cancellation waits for close callback + cleanup. A cancelled open that returns a valid fd is converted immediately into an uncancellable close | Callback/dispatcher copies buffer/stat/path/scandir entries through public accessors, calls `uv_fs_req_cleanup` exactly once, then directly resumes/errors the Task; cleanup-close status is consumed before delivering cancellation | After extraction, cleanup, and direct drive; any acquired `uv_file` remains owned until its close request completes |
| DNS (`uv_getaddrinfo`/`uv_getnameinfo`) | Negative submit return has no callback and releases request inputs | `uv_cancel` success still ends in completion callback; too-late/failure leaves normal callback path | Copy normalized addresses/names, free each non-null `getaddrinfo` result, then directly drive the Task | After callback drive and any address list free |
| Connect, write, and `uv_shutdown_t` requests | Negative submit return has no callback; release request/buffer roots and inject iteratively, while any initialized stream handle follows handle-close policy | Cancel an unpublished connect by closing its private TCP handle and consume both connect/close callbacks. Do not close a published shared Connection merely to cancel a write; consume that callback. A late successful connect is never delivered and stays on the close path | Callback copies status and directly drives only if cancellation did not win; write buffer remains rooted through callback; shutdown closes only the write side | After callback drive; a published stream remains registered until explicit/session close, an unpublished one until close callback |
| Stream read waiter | Negative `uv_read_start` has no callback and retires/errors the waiter in the current drive | `uv_read_stop` promises no terminal read callback: clear/retire the waiter and inject cancellation separately while retaining the stream owner; its documented nonzero Windows TTY return is not failure | `nread > 0`: copy bytes and directly resume; another same-stream read Request keeps reading, otherwise stop before return. `nread == 0` is ignored. Before any `nread < 0` drive, persist EOF or stored-error read-terminal state; never start reading again | Per-wait roots after direct drive/handoff; stream handle only at close callback |
| Published passive File/Connection | Acquisition failure follows its request row; a partially acquired object is never published | Cancelling a Task/waiter does not close a shared object. Explicit close serializes after its in-flight operations; final session cleanup does the same | Idle files and connected handles need not keep `uv_run` alive, so Runtime registration—not loop liveness—controls cleanup | File after close request cleanup; Connection after close callback |
| Listener and accepted TCP handles | Listen failure after successful handle init initiates close | Closing the server uses `uv_close`; no nonexistent listen-stop API is assumed | Each connection notification performs `uv_accept` into a new GC-owned handle and directly resumes an accept waiter, or queues locally; a full queue closes that new client | Each handle's own close callback |
| Spawned process and stdio pipes | `uv_spawn` initializes the process handle on both success and failure. On a negative return, `uv_close` that handle and close/drain every initialized pipe; no exit callback is expected | Cancelling a waiter does not kill. Session cleanup uses `uv_process_kill` for a live child, observes its exit callback, and only then closes the process handle; pipe requests follow their own rows | Exit callback records status and directly resumes a waiter. A successfully spawned live process handle is never closed before exit is observed, avoiding an unreapable child on Unix | Process close callback after spawn failure or observed exit, plus all pipe request/close callbacks |

Wrapper tests fault each transition, including init failure, start/submit failure,
cancel-before-complete, complete-before-cancel, too-late cancellation, and close
while a callback is directly driving its continuation.

## Deterministic shutdown

Normal main completion only records the exit result and lets independently
scheduled Tasks continue. The transition to session cleanup occurs when the
last Task becomes terminal, even if active or passive resources remain. An
unobserved Task failure, explicit session cancellation, or internal dispatcher
failure enters the same cleanup machine in fatal mode while Tasks are still
live.

Shutdown is phased; it is not a blanket `uv_walk` + `uv_close` pass:

1. Enter `quiescing`. Reject `uv.run` and ordinary new operations, preserve the
   first fatal error/trace if any, but explicitly permit library-owned
   cleanup-shield operations. Mark internal cancellation wakeups and process
   grace timers as shutdown infrastructure so later handle closing cannot
   remove them prematurely.
2. In fatal mode, synchronously mark every live Task cancelled and arm its own
   cancellation callback; never resume an independent Task inline from the
   failing callback. Request operation-specific cancellation at the same time,
   but retain every owner until the callback promised by its lifecycle row.
   Completion callbacks that lose to cancellation perform cleanup and inject
   cancellation rather than deliver their result.
3. Continue dispatching until all Task `finally` paths have run and Tasks are
   terminal. Cleanup-shielded close/drain operations may be submitted in this
   phase. Do not close a handle or file descriptor while a request still uses
   it; serialize each File's close after its in-flight request and wait for
   every submitted request's terminal callback/cleanup.
4. Close remaining published Files asynchronously and drain their `uv_fs_t`
   callbacks. Stop resource waiters/watchers, but retain handle storage and any
   shutdown infrastructure still needed by later phases.
5. For each non-detached live child owned by the session, close/drain its stdio
   streams as their request states permit, send the documented graceful
   termination signal (`SIGTERM` on Linux/macOS), wait up to a five-second
   grace timer, then send `SIGKILL` if needed. Observe the exit callback before
   calling `uv_close` on a successfully spawned process handle. A spawn-failed
   initialized handle may be closed immediately because no exit callback will
   arrive. Task cancellation alone never kills a process while the session
   remains active.
6. Now stop and close every remaining Server, Connection, Ticker, signal,
   timer, process, pipe, and internal shutdown handle exactly once. Drain every
   close callback; an unpublished cancelled connect remains rooted until both
   its connect and handle-close terminal events have occurred.
7. A callback may request `uv_stop` so the outer bootstrap regains control, but
   no callback calls C `uv_run` recursively. After the current
   `uv_run(UV_RUN_DEFAULT)` returns, the bootstrap invokes nonblocking/default
   drain iterations as required until the phase machine and loop liveness both
   report empty.
8. Call `uv_loop_close`. Treat `UV_EBUSY` as an implementation bug; in a debug
   build, enumerate remaining handles with `uv_walk` for the diagnostic.
9. Clear `active_runtime`, release the loop-owner root, and either return the
   main result or reinstall/pin and re-raise the preserved failure.

No control-owner finalizer starts async close after the loop may already be
gone. A live libuv handle requires a strong Runtime root, so that same owner
cannot detect user abandonment through `__gc`. If earlier automatic
abandonment is added, use a separate user-facing finalizable proxy that marks
the rooted control owner for closure on the loop thread. V1 correctness rests
on explicit resource `close` plus automatic final-session cleanup; Lua GC
reclaims Titan-owned storage only after legal terminal cleanup.

## Public APIs

The public callable forms below passed a checker-only probe; committed checker
and binary-interface tests will lock the exact surface during implementation.
The snippets now show one representative local ownership field on each opaque
record; the implementation may add further local state, none of which appears
in the compiled public interface.

### `uv` (Lua: `titan.uv`)

```titan
record Task
  local root: coroutine.Coro
end

record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end

record Cancelled
  reason: value
end

function run(func: () -> value): Task
function loop()
function Task:join(): value
function Task:cancel(reason: value)
function Task:status(): string
```

`run` schedules; it never executes `func` before returning. `loop` is the
explicit loop driver for Lua embedding or a Titan host without standalone
bootstrap and raises if called from a Lua child thread, callback, or active loop
invocation. Embedding `loop` returns normally after successful/cancelled
non-main Tasks and final cleanup, but re-raises an unobserved Task failure or
Runtime-fatal error with its preserved trace.

Ordinary standalone Titan code needs no wrapper:

```titan
local fs = import "fs"

function main(args: {string}): integer
  local data = fs.read_file(args[1])
  return #data
end
```

Import initialization installs the UV bootstrap hook, so generated entry code
schedules `main` through `run` and drives the loop. For Lua:

```lua
local uv = require "titan.uv"
local task = uv.run(function() return "done" end)
uv.loop()
assert(task:join() == "done")
```

Every async operation outside a running UV Task raises a clear usage error
using `coroutine.is_yieldable(UV_TAG)`. A live Task or resource from an older
session is rejected; a completed Task retains immutable status/result/error so
`status` and an already-resolved `join` remain usable after `loop` returns. The
dynamic `value` result keeps task functions useful without adding generics;
callers cast a joined result back to the application type.

### `timer` (Lua: `titan.timer`)

Initial API:

```titan
function sleep(milliseconds: integer)
function yield()

record Ticker
  local handle: uv.uv_timer_t
end

function ticker(milliseconds: integer): Ticker
function Ticker:tick(): boolean
function Ticker:close()
```

- `sleep` rejects negative durations and permits zero for a next-turn yield;
  `ticker` requires a strictly positive interval so its repeating libuv timer
  cannot silently become a one-shot timer.
- `sleep(0)`/`yield()` cede through a zero timer and therefore reach another
  event-loop turn.
- `Ticker:tick` yields for the next callback and returns false after close.
- Ticks with no active waiter are dropped; they do not create a backlog. A later
  `tick()` waits for a later firing.
- Close is idempotent and callbacks after close are cleanup-only.

### `fs` (Lua: `titan.fs`)

Initial API:

```titan
record File
  local handle: uv.uv_file
end

function open(path: string, mode: string): File
function read_file(path: string): string
function write_file(path: string, data: string)

function File:read(max_bytes: integer): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean
```

Second filesystem slice:

```titan
record Stat
  size: integer
  kind: string
  mode: integer
  modified_seconds: integer
  modified_nanoseconds: integer
end

function stat(path: string): Stat
function mkdir(path: string)
function unlink(path: string)
function rmdir(path: string)
function rename(from: string, to: string)
function list(path: string): {string}
```

Contracts:

- Mode strings are `r`, `w`, `a`, `r+`, `w+`, `a+`, with an optional `b`
  accepted for familiarity. Translate them in Titan to public `UV_FS_O_*`
  constants; do not expose host `O_*` numbers.
- `File:read(n)` requires `n > 0`, returns up to `n` binary bytes, and returns
  `nil` only at EOF.
- `File:write` loops over partial writes and returns the full byte count on
  success.
- File operations are serialized in a FIFO with one active libuv request.
  Calling `close` immediately marks the File `closing`, rejects all later
  operations, lets operations already ahead of close finish in order, then
  submits exactly one close request. Cancelling a waiter removes an operation
  that has not been submitted; an active operation follows the lifecycle
  matrix. Cancellation of the task awaiting `close` does not abandon physical
  close; cleanup finishes before the cancellation is delivered.
- Offset `-1` uses the file's current position. Random-access methods can be a
  follow-up.
- Every filesystem request calls `uv_fs_req_cleanup` exactly once on success,
  failure, or cancellation.
- `close` is idempotent. Any other method after close raises a use-after-close
  error.
- `mkdir` passes mode `0777` to public `uv_fs_mkdir`, subject to the process
  umask on Linux/macOS; an explicit permission API is a follow-up. `unlink`
  removes files/symlinks through `uv_fs_unlink`; `rmdir` removes only an empty
  directory through `uv_fs_rmdir`. Neither guesses based on a failed POSIX
  operation.
- Whole-file helpers cap growth against integer/size overflow and stream rather
  than trusting `stat.size` alone.

### `net` (Lua: `titan.net`)

Initial API:

```titan
record Connection
  local handle: uv.uv_tcp_t
end

record Server
  local handle: uv.uv_tcp_t
end

function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer): Server

function Connection:read_some(max_bytes: integer): string?
function Connection:read_exactly(bytes: integer): string
function Connection:read_until(delimiter: string,
                               max_bytes: integer): string
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

Contracts:

- Resolve through `uv_getaddrinfo`; try compatible returned addresses in order
  and always call `uv_freeaddrinfo`.
- Use `uv_tcp_t`, `uv_tcp_connect`, `uv_listen`, and `uv_accept`; no raw sockets.
- Exactly one reader may wait on a Connection. `read_some` starts libuv reading
  only when needed and stops it as soon as data/EOF/error satisfies the waiter.
- `read_exactly` and `read_until` loop over `read_some` and retain excess bytes
  in the Connection. Premature EOF in `read_exactly` raises
  `uv.Error` with libuv's `UV_EOF` and includes the requested and partial
  byte counts in `message`/`subject`; it never returns a short string.
  `read_until` enforces `max_bytes` and raises without discarding already
  buffered bytes.
- Writes are ordered FIFO. Each write buffer remains rooted until its callback.
- `Connection:shutdown` queues `uv_shutdown` after earlier writes, permanently
  closes only the write side, and leaves reads active until EOF/error or
  `close`. Later writes are rejected as soon as shutdown is requested. `close`
  closes both directions and remains idempotent.
- EOF is `nil`; reset and other errors raise `uv.Error`.
- `listen` requires `backlog > 0` and uses it both for `uv_listen` and as the
  accepted-connection queue capacity. Libuv exposes no public listen-stop
  operation, so every connection notification calls `uv_accept` into a fresh
  GC-owned client handle. Deliver directly to an existing accept waiter;
  otherwise enqueue it, or, when that queue is full, immediately `uv_close` the
  new client while keeping the listening handle active. No private/POSIX pause
  and no unbounded queue.
- Client, server, and requests must belong to the same Runtime generation.

UDP and Unix-domain/named pipes are follow-ups.

### `os` (Lua: `titan.os`)

Portable synchronous helpers use public `uv_os_*`/utility functions:

```titan
function getenv(name: string): string?
function setenv(name: string, value: string)
function unsetenv(name: string)
function cwd(): string
function chdir(path: string)
function homedir(): string
function tmpdir(): string
function hostname(): string
function exepath(): string
function pid(): integer
function ppid(): integer
```

Buffer-sized helpers retry on `UV_ENOBUFS` with checked growth. If a public
libuv operation returns `UV_ENOSYS`, expose that Error; do not add a hidden
POSIX fallback.

Processes and signals:

```titan
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

record Process
  local handle: uv.uv_process_t
end

function spawn(file: string, args: {string}): Process
function Process:wait(): ExitStatus
function Process:kill(signal: string)
function Process:write_stdin(data: string)
function Process:close_stdin()
function Process:read_stdout(max_bytes: integer): string?
function Process:read_stderr(max_bytes: integer): string?

function communicate(file: string, args: {string},
                     input: string?): (string, string, ExitStatus)
function wait_signal(name: string): string
```

- Use `uv_spawn`, `uv_process_t`, and `uv_pipe_t`; no `fork`, `pipe`, or
  `waitpid` fallback.
- `file` is the executable and `args` contains only arguments after `argv[0]`.
  The shim builds a GC-owned, NUL-terminated vector `[file, args..., NULL]` and
  roots every copied string/vector through the return of `uv_spawn`; the child
  inherits the current environment and working directory in v1.
- The process owner remains rooted through the exit callback, the process
  handle's later close callback, and every pipe request/close callback. On
  spawn failure it remains rooted through the required process close callback
  even though no exit callback will arrive.
- `communicate` drains stdout and stderr concurrently while optionally writing
  stdin, so it cannot deadlock on a full child pipe.
- `communicate` creates its reader/writer helpers through a private observed-task
  path: register the parent/join relationship before arming each helper start
  callback. A helper failure therefore propagates to the parent, cancels/drains
  its siblings and process resources, and never trips the unobserved-task policy
  first.
- `Process:wait` may be cancelled without killing the child. `Process:kill` is
  explicit.
- Signal names map to the common Linux/macOS subset inside the shim. Numeric
  signal values are not accepted as public inputs; `signal_number` is
  diagnostic output preserving an unknown termination signal.
- Canonical input/output names are lowercase `hup`, `int`, `quit`, `term`,
  `usr1`, and `usr2`; `Process:kill` additionally accepts `kill`, while
  `wait_signal` rejects the uncatchable `kill`. Unknown names raise before any
  libuv call.
- Process exit status and terminating signal are retained independently.
  `signal_number` is zero on normal exit and preserves an unknown host signal;
  `signal` is its canonical lowercase name when it belongs to the documented
  Linux/macOS subset, otherwise `nil`.
- `communicate` is the v1 argv-based, popen-style convenience. Do not add an
  implicit shell-string `popen`; callers that intentionally need a shell must
  spawn it explicitly with an argument array.

## Portable libuv acquisition and build

### Default: pinned bundled static libuv

Mirror the existing Lua/libbacktrace dependency workflow:

```make
LIBUV_VERSION := 1.52.1
LIBUV_TARBALL := libuv-v$(LIBUV_VERSION).tar.gz
LIBUV_URL := https://dist.libuv.org/dist/v$(LIBUV_VERSION)/$(LIBUV_TARBALL)
LIBUV_SHA256 := 66d511b9e6e334c0e62279eb234fbfb2b3110b1479c09b95b44c7afca8cff9e7
```

`make libuv` must:

1. Download the exact release tarball.
2. Verify SHA-256 using `sha256sum` or macOS `shasum -a 256`.
3. Extract into a versioned ignored directory.
4. Fail early with actionable instructions if CMake is unavailable.
5. Configure a PIC static build:

   ```sh
   cmake -S libuv-v1.52.1 -B libuv-build \
     -DLIBUV_BUILD_SHARED=OFF \
     -DBUILD_TESTING=OFF \
     -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
     -DCMAKE_BUILD_TYPE=Release
   cmake --build libuv-build --target uv_a
   ```

6. Expose the archive and include directory to the standard-module build.

Reuse the Makefile's existing `curl`-then-`wget` download fallback and emit a
specific missing-tool error. The documented clean-checkout path is:

```sh
# Ubuntu/Debian prerequisites for the bundled default
sudo apt-get install build-essential cmake curl
make libuv

# Fedora prerequisites for the bundled default
sudo dnf install gcc make cmake curl
make libuv

# macOS prerequisites for the bundled default
xcode-select --install                 # if command-line tools are absent
brew install cmake                     # or install CMake by another supported route
make libuv
```

`make help` must explain that `make all`/`make stdlib` build the bundled copy
automatically, while `make libuv` is the focused dependency target. A missing
compiler, downloader, checksum tool, CMake, or archive tool must fail before a
partial standard-module link and print the corresponding Linux/macOS remedy.

Add `clean-libuv` and include it in `distclean`. Add libuv source/build/tarball
paths to `.gitignore`. Cache by OS, architecture, version, and build flags in
CI. Preserve libuv's license/attribution in source and binary distribution
artifacts that contain the statically linked library.

Linux links the static archive with `pthread`, `dl`, and `rt` (the driver already
adds `dl`); macOS links `pthread` and must not add Linux-only `rt`. Keep this
conditional in the Makefile, not in Titan runtime code.

Build the generated canonical `uv` translation unit and shim with
`-fno-strict-aliasing`, as upstream recommends for libuv's public base-handle
casts. On Linux also put `_GNU_SOURCE` in compiler flags before all headers.

After linking, assert that canonical `uv.so` and its Lua-facing installed alias
have no dynamic libuv dependency:

- Linux: inspect `readelf -d` or `ldd`;
- macOS: inspect `otool -L`.

### Optional: system libuv

Support `LIBUV_MODE=system` only through full `pkg-config` output, never by
guessing `/usr/local`:

```sh
pkg-config --atleast-version=1.43.0 libuv
pkg-config --cflags libuv
pkg-config --libs libuv
```

Phase 0 must audit every selected symbol against 1.43.0 and raise the minimum if
needed. The bundled version remains the release/CI authority.

User setup hints:

```sh
# Ubuntu/Debian
sudo apt-get install libuv1-dev pkg-config

# Fedora
sudo dnf install libuv-devel pkgconf-pkg-config

# macOS
brew install libuv pkgconf
```

Homebrew's prefix may be outside compiler defaults; always consume pkg-config's
include/library paths. Do not tell users to set an unversioned runtime SONAME
manually.

### Required Titan build plumbing

Current `titanc` only accepts bare `-l` names and extra objects, and the FFI
parser independently probes bare `cpp`/`gcc`. Add narrowly scoped, generic
plumbing before the standard module:

- append-only `TITAN_EXTRA_CPPFLAGS` for `-I`/`-D` flags that must affect both
  FFI header discovery/predefined macros and every generated/runtime C compile;
- append-only `TITAN_EXTRA_CFLAGS` for compilation-only flags;
- append-only `TITAN_EXTRA_LDFLAGS` for final links;
- preserve existing defaults rather than replacing them;
- honor `CC`, `CPATH`, and `LIBRARY_PATH`, but do not rely on ambient variables
  for the reproducible bundled mode;
- print all effective flags under `-v`;
- add pinned source/binary resolution for the reserved standard-library names
  and diagnose a conflicting application source or local binary;
- add standard-origin dependency metadata plus a runtime `loadstdlib` which
  uses only the ABI-qualified `TITAN_STDLIB_PATH`/installed default, never `.` or
  ordinary `TITAN_PATH` precedence;
- add `--lua-name <qualified-name>` so a canonical Titan module may export a
  distinct Lua entry name without changing its Titan ABI symbols;
- add `--stdlib-build` for one explicit standard source root at a time; ordinary
  application imports of reserved names must remain pinned binary imports and
  standard-build dependencies must never recurse into source;
- add the generic registry-based standalone main-bootstrap hook described
  above, preserving the current direct path when no hook is installed.

This requires a real FFI-preprocessor change, not only driver link plumbing:

1. `c-parser/cdriver.lua` obtains the configured compiler and parsed
   `TITAN_EXTRA_CPPFLAGS` from its options.
2. Both include-search discovery and predefined-macro discovery run with the
   exact effective compiler, preprocessing-relevant language standard, and CPP
   flags used for generated C (currently `CC -std=c99 ...`), not a hard-coded
   `gnu11` probe. Cache their results by compiler, language mode, and complete
   relevant flag string, not process-globally.
3. `cdriver` passes the resulting include directories and macro table into
   `cpp.parse_file`; recursive includes share that context.
4. `titan-compiler/checker.lua` supplies the configuration for every `foreign
   import`, while `driver.lua` puts the same CPP flags before CFLAGS on generated
   C, runtime, and entrypoint compilation commands.
5. Avoid shell-word guessing inside the parser: centralize validated flag
   splitting/quoting in the driver utility and test paths containing spaces.

The bundled build sets `TITAN_EXTRA_CPPFLAGS=-I<versioned include> -D_GNU_SOURCE`
on Linux (only the include flag on macOS), passes `libuv.a` through existing
`-X`, and uses existing `-l` for platform support libraries. System mode splits
`pkg-config --cflags` into the shared CPP channel and sends the complete ordered
`pkg-config --libs` output to the link channel. Add parser/driver tests proving
that a header visible only through these flags is parsed with the same macro
branches the C compiler sees, compile-only flags do not leak into the link-only
phase, and link flags retain order.

### Makefile and LuaRocks packaging

Extend the build graph:

```text
lua + libbacktrace + libuv
  -> titan.o + titan_coro.o + titan_uv.o
  -> coroutine.so
  -> uv.so
  -> timer.so, fs.so, net.so, os.so
  -> single-image Lua aliases: titan/{coroutine,uv,timer,fs,net,os}.so
```

Build `coroutine.so` and canonical `uv.so` before higher-level modules and force
those dependencies down the compiled-module path, so `titan_uv.o`/`libuv.a` are
not duplicated into every library. The `coroutine.so` rule consumes
`stdlib/coroutine.titan` through `--stdlib-build --tree stdlib`, not a
root-level source or an ambient `TITAN_PATH` entry.

Replace the rockspec's single `coro.so` copy hook with an `install-stdlib`
target. Install canonical `{coroutine,uv,timer,fs,net,os}.so` in Titan's
ABI-versioned binary root and expose every module under `titan/*.so` in Lua's
`LIBDIR`, all through the single-image alias mechanism above; never install an
independent copy. The coroutine module exports `luaopen_titan_coroutine`, not
the old `luaopen_coro` or Lua's reserved `luaopen_coroutine`. Installed `uv`
imports canonical binary `coroutine` through `loadstdlib`, and installed
high-level modules do the same for canonical `uv`, so they need no libuv headers
at user compile time.

Do not add LuaRocks `external_dependencies.UV` in bundled mode: that would
incorrectly require a system developer package. In system mode, its
`UV_INCDIR`/`UV_LIBDIR` mechanism may be enabled by a separate rockspec variant
or build variable.

## Implementation phases

Each phase ends with focused tests, current-source rebuild, and
`git diff --check`. Do not begin the high-level breadth until the preceding
lifetime gate is green.

### Phase 0 - lock dependency and proof fixtures

Status: complete.

Files:

- `Makefile`
- `coro.titan` -> `stdlib/coroutine.titan` (move and rename)
- `titan-dev-1.rockspec`
- `.gitignore`
- `.github/workflows/ci.yml`
- `c-parser/cpp.lua`
- `c-parser/cdriver.lua`
- `titan-compiler/checker.lua`
- `titan-compiler/coder.lua`
- `titan-compiler/driver.lua`
- `titan-runtime/titan.c`
- `titan-runtime/titan.h`
- `titan-runtime/titan/ffi.h`
- `spec/cdriver_spec.lua`
- `spec/cpp_spec.lua`
- `spec/coder/coder_spec.lua`
- `spec/coder/coro_spec.lua` -> `spec/coder/coroutine_spec.lua` (rename)
- `doc/async-with-coroutines.md`
- `doc/language/coroutines.md`
- `doc/language/index.md`
- `doc/implementation/coroutines.md`
- `doc/implementation/driver.md`
- `doc/implementation/index.md`
- optional `spec/fixtures/uv/`

Work:

- Add pinned `make libuv`, checksum verification, cleanup, help text, and cache
  inputs.
- Record and package the upstream libuv license for static redistribution.
- Add Linux/macOS platform link variables.
- Add `TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS`/`TITAN_EXTRA_LDFLAGS`
  plumbing across `c-parser/cpp.lua`, `c-parser/cdriver.lua`, the checker, and
  `titan-compiler/driver.lua`, plus `doc/implementation/driver.md`.
- Add pinned resolution for reserved standard modules, `--stdlib-build`,
  `--lua-name`, the
  single-image canonical/Lua alias install layout, and the registry-based
  main-bootstrap hook with driver and `.so`-rehydration tests.
- Move and rename `coro.titan` to `stdlib/coroutine.titan`, rename its focused
  spec, and update the Makefile, rockspec packaging, test helper, and
  language/implementation documentation and index references together. Build
  it as canonical module `coroutine` with Lua alias `titan.coroutine` from the
  pinned standard source root, with no duplicate source or legacy `coro` alias
  left.
- Replace every `import "coro"`/`require "coro"` in the renamed spec and every
  public old-name string in the moved source, including the `coro.yield`
  diagnostic and `titan.coro` owner-userdata metatable key. Private C helper
  filenames and symbols such as `titan_coro.c`, `titan/coro.h`, and
  `titan_coro_entry` may retain their established internal names.
- Carry standard-origin dependency metadata into code generation and emit the
  dedicated runtime `loadstdlib` path; configure its ABI-qualified installed
  root and prove local source/binary names plus ordinary `TITAN_PATH` cannot
  capture a standard module's internal dependency.
- Define the bootstrap registry key in both public runtime headers; require and
  retrieve `main` before hook lookup, and invoke either path under the existing
  outer protected call.
- Turn the native timer, FS, GC, loop-lifetime, and consolidated
  callback-resume-yield-arm-return plus nested-run/recurring-tick spikes into
  small repeatable fixtures/spec helpers.
- Assert `.sizeof`/`.alignof` + `lua_newuserdatauv` + pointer cast for every
  allocated libuv type on both supported platforms.

Exit criteria:

- A clean checkout with no system libuv can run `make libuv` on Linux and macOS.
- The archive is PIC and a trivial linked module has no dynamic libuv dependency.
- System mode fails early with useful package/prefix instructions when absent.
- A foreign header found only through `TITAN_EXTRA_CPPFLAGS` takes the same
  feature-macro branch in Titan's parser and in generated C compilation.
- `import "os"` resolves the pinned standard module and diagnoses a conflicting
  application/local `os`; `require "titan.os"` loads the same canonical image
  and module Udata without changing Lua's `package.loaded.os`.
- Require-first/import-first and static-link tests prove one DSO/libuv instance,
  shared module state, and coexistence of `luaopen_os`/`luaopen_titan_os`.
- An ordinary application build with `stdlib` sources visible still imports the
  pinned binary and emits no standard-module `luaopen_*` or duplicate libuv
  implementation; `--stdlib-build` compiles exactly one requested root with its
  intended Lua entry and binary-only reserved dependencies.
- `stdlib/coroutine.titan` is the sole coroutine standard-module source;
  clean-checkout Makefile, LuaRocks, renamed focused coroutine spec, all current
  coroutine documents, indexes, and driver documentation use the new path and
  names. `import "coroutine"` and
  `require "titan.coroutine"` share the canonical module, while Lua's
  `require "coroutine"` remains unchanged and no old `coro` alias is installed.
- Clean-install tests exercise only the new Titan/Lua names and prove the
  install tree contains no root `coro.so` and no installed DSO exports
  `luaopen_coro`; source/runtime checks prove there is no old `titan.coro` owner
  metatable key or `coro.yield` diagnostic.
- A synchronous standalone retains today's direct entry path, while importing
  `uv` installs and selects the generic async bootstrap.
- Binary-only standard `uv`/`fs` import canonical `coroutine`/`uv` through
  `loadstdlib` even with fake local sources,
  `./coroutine.so`/`./uv.so`, and application `TITAN_PATH` entries; a custom
  installed prefix works through the documented standard-path setting.

### Phase 1 - GC-owned low-level objects and native callbacks

Status: complete for the callback/storage families required through Phase 5;
Phase 6 adds its process, pipe, and signal shapes on the same fixed boundary.

Files:

- `stdlib/uv.titan`
- `titan-runtime/titan_uv.c`
- `titan-runtime/titan/uv.h`
- `spec/checker/uv_spec.lua`
- `spec/libuv_shim_spec.lua`
- `spec/coder/uv_spec.lua`

Work:

- Import public `uv.h`, Lua headers, `titan/ffi.h`, private shim header, and
  canonical `coroutine`.
- Implement loop/operation native-storage userdata allocation in Titan with
  imported `.sizeof`, plus the separate wrapper record Udata used as callback
  owner and GC root.
- Define nominal opaque wrapper records with local typed native-handle,
  storage-root, lifecycle, and Runtime-generation fields. Use exact wrapper
  types—not `value`—on every middle-layer handle parameter/return.
- Implement fixed uservalue layouts and data association through public libuv
  getters/setters.
- Add concrete typed shim wrappers only where Titan rejects a libuv
  concrete-to-base handle cast; assert that each wrapper delegates to a public
  libuv API and contains no field access.
- Implement native trampoline pointer recovery and the catch-all dispatcher.
- Call the trusted dispatcher through its native Titan entry exactly as
  `titan_coro_entry` does, with no C protected-call wrapper. Put all dispatcher
  body work under its trailing function-level Titan `catch`; its non-raising
  failure arm stores `error`/`traceback`, marks Runtime fatal, calls `uv_stop`,
  and returns.
- Test an observed Task failure followed by another live timer callback, an
  injected library failure at the first dispatcher body operation, and a
  failure in the Task-error handler itself. Prove the inner and trailing catches
  classify them correctly and return through every native callback shape
  without a longjmp or Lua entry-wrapper call.
- Implement timer, close, FS, read/alloc, connect/write, DNS, process, and signal
  callback shapes incrementally; begin with timer + FS only.
- Add exact-length buffer helpers.
- Lock the public declarations in checker tests, reject publicly visible C
  types, verify local C-pointer fields are omitted from the serialized
  interface, and verify the same canonical wrapper identities rehydrate from
  binary-only `uv.so` and load through Lua's `titan.uv` alias.

Exit criteria:

- Native path counters prove no callback uses a Lua entry wrapper.
- The direct path proves callback A extracts/cleans, resumes user code, receives
  Request B, roots/arms B, and only then returns; later callback B resumes the
  same Task.
- Owner survives incremental and generational GC, including old owner -> young
  Task/buffer stores.
- External Titan code cannot call an opaque wrapper's `new`, use a constructor
  expression, or substitute another record; Lua entry checks reject a table or
  wrong-record userdata. Repeated calls through one wrapper allocate no
  pointer-boxing userdata.
- An observed Task error is stored and a later callback still fires; a
  Task-handler error reaches the Runtime-fatal catch. Neither unwinds through
  libuv; separate coverage proves an unobserved failure stops the session.
- Its trailing function-level catch saves the exact error/trace in already
  rooted Runtime fields, marks fatal, requests `uv_stop`, and returns;
  formatting, cleanup, and reporting wait until bootstrap control.
- Main-stack top is unchanged after dispatch, and standalone plus Lua
  `uv.loop()` failure tests retain a nonempty Titan traceback, proving the loop
  entry keeps `errfunc` active throughout C `uv_run`.
- Request/handle roots are released after, and only after, terminal cleanup.

### Phase 2 - continuation pump, bootstrap, tasks, errors, and timers

Status: complete.

Files:

- `stdlib/uv.titan`
- `stdlib/timer.titan`
- `spec/coder/uv_spec.lua`
- `spec/coder/timer_spec.lua`

Work:

- Implement the module-instance private `UV_TAG`, Runtime reference, Task,
  Request, operation epochs, pending/resources maps, and the iterative direct
  `drive` pump. There is no Completion/ready queue.
- Implement nonblocking `run`, `join`, cancel/status, public embedding `loop`,
  and automatic standalone bootstrap. Remove the redundant `spawn`/`run_main`
  split.
- Adapt public `() -> value` functions to `coroutine.create`'s
  `(value) -> value` entry and lock timer init/start
  failure semantics.
- Implement immediate failure, async failure, trace copying/reinstallation, and
  first-error policy.
- Implement close/cancel/drain and `UV_EBUSY` diagnostics.
- Implement sleep, zero-turn yield, and repeating `Ticker:tick` continuation
  handoff.
- Give public `Task` and `Ticker` records local root/control and `uv_timer_t`
  wrapper fields so neither can be constructed outside its declaring module.

Exit criteria:

- Out-of-order timers wake the correct task exactly once.
- Many roots share exact `UV_TAG`; an async yield crosses differently tagged
  nested coroutines and restores their stacked chain.
- `run` never executes synchronously; nested `run` schedules an independent
  zero-timer task and maximum C `uv_run` depth remains one.
- A nested `run` called on child state `T` stores the Runtime main state `L` in
  its owner and its start callback dispatches on `L`; `loop` rejects child-state
  callers while nested `run` remains legal.
- Three or more `tick()` cycles prove callback -> resume -> tick yield -> arm ->
  callback return.
- `ticker(0)` is rejected while `sleep(0)` and `yield()` still cede one turn.
- Task/join errors preserve both task and propagation traces.
- Next-turn observation lets a scheduled joiner catch a child start/task
  failure; the same failure without an observer is promoted. A cancelled main
  is reported, while an unjoined cancelled non-main Task is not session-fatal.
- Repeated bootstrap/loop sessions end with `uv_loop_close == 0` and no retained
  owners.

### Phase 3 - filesystem core

Status: complete.

Files:

- `stdlib/fs.titan`
- `spec/coder/fs_spec.lua`

Work:

- Implement mode translation using `UV_FS_O_*`.
- Implement File state/serialization, open/read/write/flush/close.
- Store the exact `uv.uv_file` wrapper in a local `File` field; no file method
  converts a descriptor/pointer through `value`.
- Implement whole-file helpers with checked chunk growth.
- Then implement stat/path operations and list.

Exit criteria:

- Success, missing path, permission/error, EOF, short read/write, empty file,
  embedded NUL, payload larger than one chunk, cancel, and close races pass.
- Cleanup counters prove one `uv_fs_req_cleanup` per request.
- No operation runs after close; double close is harmless.

### Phase 4 - task races and cancellation hardening

Status: complete for the timer, filesystem, and networking families currently
implemented; the same matrix remains an exit gate for Phase 6 resources.

Before sockets/processes multiply handle types, complete the race matrix:

- completion before cancellation;
- cancellation before completion;
- synchronous cancellation-mark versus completion-callback linearization, with
  normal result suppression even when the cancellation timer has not run;
- sticky cancellation before an ordinary await (no allocation/submission) and
  cleanup shielding across multiple asynchronous close/drain operations;
- `uv_cancel` success and failure/too-late cases;
- late callback after logical task death;
- callback after resource close request;
- main completion with independently scheduled live Tasks;
- final-Task completion with leaked active and passive resources, proving
  automatic session cleanup rather than reliance on loop liveness;
- cancelled Ticker/read wait preserves a resource shared with another Task;
- one Task error while another callback is directly driving a different Task;
- generational GC with old Runtime/owner and young Task, buffer, error, and the
  shared tag.

Add an ASan/UBSan CI job for the shim and focused library specs. Local sanitizer
availability is not assumed; CI is the release gate.

### Phase 5 - TCP and DNS

Status: complete.

Files:

- `stdlib/net.titan`
- `spec/coder/net_spec.lua`

Work:

- Implement getaddrinfo ownership/cleanup.
- Implement TCP connect, binary stream read/write, shutdown, close.
- Implement server listen/accept and bounded accept queue.
- Store exact `uv.uv_tcp_t` wrappers in local `Connection`/`Server` fields.
- Implement excess buffering and one-reader policy.
- Persist EOF/error read-terminal state before continuation drive and reject any
  later `uv_read_start`; close unpublished connect handles on cancellation.

Exit criteria:

- Loopback-only client/server tests cover IPv4 and available IPv6.
- Partial reads, read stop/restart, EOF, reset, failed connect, ordered writes,
  embedded NUL, and write-buffer GC stress pass.
- All handles close and the loop drains after both success and failure.

### Phase 6 - OS helpers, signals, and processes

Files:

- `stdlib/os.titan`
- `spec/coder/os_spec.lua`

Work:

- Implement portable `uv_os_*` helpers and checked resizing.
- Implement common signal-name mapping and one-shot wait.
- Implement Process + pipe ownership, wait/kill, and communicate/popen.
- Store the exact `uv.uv_process_t` wrapper (which privately roots its pipe
  wrappers) in a local `Process` field.
- Implement phased runtime shutdown for live processes, including spawn-failure
  handle close and exit-before-close ordering for successfully spawned children.

Exit criteria:

- Tests use only owned child fixtures and temporary directories.
- stdout/stderr are drained concurrently; large dual-stream output cannot
  deadlock.
- Reader/writer helpers are observed before start; a forced helper failure is
  reported through `communicate` after sibling/process cleanup, never as an
  unrelated unobserved Task.
- exit code/signal, spawn failure, stdin close, cancellation, and forced runtime
  shutdown pass on Linux and macOS.
- Fault tests prove a failed `uv_spawn` handle is closed, a successful live
  process handle is never closed before its exit callback, and all pipe/process
  close callbacks drain without zombies.

### Phase 7 - packaging and documentation

Files:

- `titan-dev-1.rockspec`
- `Makefile`
- `README.md`
- `CLAUDE.md`
- `doc/language/index.md`
- new `doc/language/async-io.md`
- new `doc/language/standard-library-{timer,fs,net,os}.md`
- `doc/language/coroutines.md`
- `doc/language/modules.md`
- `doc/language/lua-interop.md`
- `doc/implementation/index.md`
- new `doc/implementation/libuv-runtime.md`
- `doc/implementation/coroutines.md`
- `doc/implementation/ffi-internals.md`
- `doc/implementation/driver.md`
- `doc/implementation/lua-interop-internals.md`
- `doc/implementation/codegen-overview.md`

Work:

- Install canonical Titan modules plus Lua `titan.*` aliases and document both
  bundled/system libuv modes.
- Document synchronous appearance, cooperative scheduling, cancellation points,
  direct callback execution, nonblocking `uv.run`, shared-tag semantics,
  automatic standalone bootstrap, local-field opaque native wrappers and their
  one-allocation cost model, explicit close, errors, task policy, and unsupported
  operations.
- Keep coroutine implementation prose aligned with the renamed module/path and
  its typed native-handle plus owner-uservalue shape.
- Update the roadmap only when shipped behavior and tests justify it.

## Verification plan

### Focused suites

Add topical suites instead of growing catch-all files:

- `spec/libuv_shim_spec.lua`
- `spec/checker/uv_spec.lua`
- `spec/coder/uv_spec.lua`
- `spec/coder/timer_spec.lua`
- `spec/coder/fs_spec.lua`
- `spec/coder/net_spec.lua`
- `spec/coder/os_spec.lua`

Extend `spec/support/helpers.lua` once for native archives/objects, standard
module build order, environment flags, and standalone execution.

### Required behavioral coverage

- private loop and sequential bootstrap sessions;
- `uv.run` returns before its function starts; nested `uv.run` schedules a new
  start callback without re-entering C `uv_run`;
- public run-entry adapter and zero-timer init/start failure arms;
- nested `uv.run` allocates from a child state but every callback dispatches on
  Runtime main `L`; `uv.loop` rejects child-thread callers;
- two independent Lua states in one process;
- one exact module-instance `UV_TAG` across many roots and sequential Runtime
  sessions, plus differently tagged nested `stacked` routes and restoration;
- native callback directly resumes user code, receives/arms its next Request,
  and returns with C `uv_run` depth still one;
- three or more repeating `Ticker:tick` callback/continuation cycles;
- direct native callback entry with no Lua wrapper or additional shim-level
  protected call, a trailing function-level Titan catch, Task versus
  Runtime-fatal classification, and trace preservation;
- an observed Task raise returns normally and a later timer callback still runs;
  failure in the Task-error arm reaches the trailing Runtime-fatal catch, while
  an unobserved Task failure stops the session;
- callback dispatch preserves the main stack top, and both standalone and Lua
  `uv.loop()` paths retain a nonempty Titan traceback across `uv_run`;
- immediate versus asynchronous error;
- incremental and generational GC;
- pending/resource root release verified with weak references;
- request cleanup and handle close order;
- cancellation linearization, sticky ordinary-await rejection,
  cleanup-shielding, and late callback matrix;
- observed versus unobserved Task failure deadline, internal helper pre-observe,
  and standalone-main cancellation;
- final-Task cleanup of leaked active/passive resources and shared-resource
  waiter cancellation;
- binary strings, NUL, empty buffers, overflow/negative lengths;
- filesystem temp-directory cases;
- loopback networking only;
- permanent EOF/read-error terminal state and cancelled unpublished connect;
- owned subprocess fixtures and common signals;
- failed-spawn close, observed-exit-before-process-close, and zombie-free
  forced shutdown;
- explicit one-root standard source builds, ordinary pinned-binary imports from
  application source chains, binary-only installed imports, Lua `require`, and
  standalone executable paths;
- Titan `import "os"` versus Lua `require "titan.os"`, preserving Lua's
  existing `require "os"`; Titan `import "coroutine"` versus Lua
  `require "titan.coroutine"`, preserving Lua's existing
  `require "coroutine"`; reserved-name diagnostics and pinned standard
  source/binary resolution that local `coroutine`/`uv` sources or binaries
  cannot capture;
- both alias load orders map one canonical DSO and one statically linked libuv
  instance while sharing the registry Udata;
- checker acceptance of local C-pointer fields without interface leakage;
  rejection of external opaque-record construction, wrong record identities,
  and publicly visible C fields; source/`.so`/Lua identity checks for the same
  wrappers;
- allocation counters proving repeated wrapper method/middle-layer calls do not
  allocate pointer-boxing userdata; runtime rejection of closed wrappers and
  wrappers/resources from another Runtime generation;
- bundled static and optional system libuv modes;
- Linux and macOS.

### CI and release gates

Linux push CI:

1. Install/verify CMake explicitly.
2. Build/cache pinned libuv.
3. Build/install the rock and standard modules.
4. Run focused sanitizer/lifetime job.
5. Run full coverage suite.

Manual macOS pre-merge CI:

1. Build the same pinned libuv, not an undeclared Homebrew runtime.
2. Run focused stdlib tests and full suite.
3. Verify `otool -L uv.so` and the Lua alias have no dynamic libuv dependency,
   and the alias/load-order test maps one canonical DSO image.

Final local gate:

```sh
CCACHE_DISABLE=1 make libuv
CCACHE_DISABLE=1 ./luarocks make
CCACHE_DISABLE=1 busted \
  spec/libuv_shim_spec.lua \
  spec/checker/uv_spec.lua \
  spec/coder/uv_spec.lua \
  spec/coder/timer_spec.lua \
  spec/coder/fs_spec.lua \
  spec/coder/net_spec.lua \
  spec/coder/os_spec.lua
CCACHE_DISABLE=1 make test
git diff --check
```

The full `make test` remains authoritative because an installed compiler
snapshot can otherwise shadow source edits.

## Completion checklist for the implementation

- [ ] Pinned libuv builds from a clean checkout on Linux and macOS.
- [ ] Optional system mode has tested discovery and useful failure messages.
- [ ] Runtime behavior uses public libuv APIs; no hidden POSIX I/O/process path.
- [ ] Loop/request/handle storage is Lua-GC-owned by default using imported
      `.sizeof`.
- [ ] Every native object crossing a Titan module/API boundary uses one exact
      wrapper record with a local typed native-handle field and, when needed,
      one rooted storage owner; native pointers are never transported by
      `value` coercion.
- [ ] Opaque wrapper/high-level resource constructors are inaccessible outside
      their declaring modules, and repeated handle use performs no wrapper or
      pointer-boxing allocation.
- [ ] All libuv data pointers refer to independently rooted opaque wrapper
      record userdata, never the separate native-storage userdata.
- [ ] Native callbacks use Titan native entry pointers directly, with neither a
      Lua wrapper nor an additional shim-level protected-call wrapper.
- [ ] The trusted dispatcher's controlled body is covered by a trailing
      function-level Titan catch whose failure arm records state and returns
      without re-raising; no error can unwind through libuv.
- [ ] Standalone and Lua loop entries keep Titan `errfunc` active for the whole
      `uv_run`; callbacks do not install or restore it individually.
- [ ] Each callback copies/cleans its result, directly drives the captured Task,
      arms the next yielded Request, and returns without nesting C `uv_run`.
- [ ] One private shared `UV_TAG` routes through differently tagged nested
      coroutines; task/operation identity is kept separately.
- [ ] Public `uv.run` is nonblocking and nested calls schedule independent
      zero-timer starts; standalone bootstrap drives the loop automatically.
- [ ] Nested starts recover Runtime main `L`; only the loop driver is restricted
      to the Lua main thread.
- [ ] Cancellation has a synchronous winning mark, runs shielded Titan cleanup,
      and tolerates late libuv callbacks without delivering stale results.
- [ ] Every request/handle/loop reaches its documented terminal cleanup.
- [ ] Final-Task session cleanup closes leftover active and passive resources;
      process handles close only after failure or observed child exit.
- [ ] Binary buffers preserve length and embedded NUL.
- [ ] Timer, file, TCP/DNS, OS/process/signal APIs match documented contracts.
- [ ] Canonical modules work as Titan `import "coroutine"`/`import "os"`/etc.;
      Lua aliases work as `require "titan.coroutine"`/`require "titan.os"`/etc.
      without replacing Lua standard modules.
- [ ] The existing coroutine source is moved and renamed to
      `stdlib/coroutine.titan`; no root duplicate or legacy `coro` alias remains,
      and Makefile, rockspec, renamed tests, and documentation all consume or
      name the new source/module path.
- [ ] Reserved standard identities cannot be captured by local source/binaries,
      and canonical/Lua paths map one DSO/libuv instance in either load order.
- [ ] Source, `.so`-only, and standalone paths are covered.
- [ ] Incremental, generational, sanitizer, Linux, and macOS gates pass.
- [ ] Both language and implementation manuals, README, CLAUDE, Makefile,
      rockspec, and CI are updated in the same change.

## Authoritative external contracts

- Libuv design overview: <https://docs.libuv.org/en/v1.x/design.html>
- Event loop and C `uv_run` non-reentrancy: <https://docs.libuv.org/en/v1.x/loop.html>
- Handle close lifetime: <https://docs.libuv.org/en/v1.x/handle.html>
- Request and cancellation lifetime: <https://docs.libuv.org/en/v1.x/request.html>
- Filesystem requests and cleanup: <https://docs.libuv.org/en/v1.x/fs.html>
- Streams and buffer lifetime: <https://docs.libuv.org/en/v1.x/stream.html>
- Processes: <https://docs.libuv.org/en/v1.x/process.html>
- Official source/build/version policy: <https://github.com/libuv/libuv>
- Tagged-coroutine prior art: <https://github.com/mascarenhas/taggedcoro>
- Nested-coroutine prior art: <https://github.com/saucisson/lua-coronest>
- Current Homebrew formula/setup alternative:
  <https://formulae.brew.sh/formula/libuv.html>
