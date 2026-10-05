# Native API coverage

The public reference maps the pinned libuv 1.52.1 header to Titan declarations.
The complete [function table](function-dispositions.tsv) contains 318 distinct
native functions: 305 canonical exported wrappers, eight unavailable direct
wrappers, and five native frees performed internally after public results are
copied. It records exact signatures, parameter and native-pointer roles,
return/ownership rules, callback timing/thread, cancellation, cleanup, platform
conditions, and links to the pinned native declarations. Its `native_pointer_roles`
column describes the underlying C ABI for binding maintainers. The
`public_parameter_roles` and cleanup columns describe what a Titan caller
actually supplies or receives; native pointer borrowing does not shorten the
lifetime of an independently copied public value.

The public API also has 205 [supplemental declarations](supplemental-public-signatures.tsv):
constructors, owner views, result/data accessors, C-only bridge entries,
`has_api`, and `setup_process_args`. These are documented in
[types](types.md) and [supplemental APIs](supplemental.md); they are not counted
as additional native C functions.

## Unavailable direct wrappers

These omissions preserve explicit ownership rather than exposing unsafe native
pointers or process-global policy as ordinary module operations.

| Native function | Reason and public alternative |
| --- | --- |
| `uv_default_loop` | Process-global loop and its reserved data slot cannot be independently owned by multiple Lua states. Construct loop_t and call loop_init explicitly; do not claim replacement default-loop semantics. |
| `uv_library_shutdown` | Once-only terminal process-global shutdown forbids every later libuv call; a reusable module cannot prove all libuv users are quiescent. |
| `uv_loop_delete` | Deprecated heap deletion helper does not own Titan packed loop storage. loop_close retires native state; GC later reclaims the Titan owner. |
| `uv_loop_new` | Deprecated heap allocation helper conflicts with final packed Titan loop_t ownership. loop_t() followed by loop_init is the explicit public path. |
| `uv_print_active_handles` | Diagnostic FILE* API has no approved public FILE owner. walk plus is_active supplies typed inspection without inventing FILE* ownership. |
| `uv_print_all_handles` | Diagnostic FILE* API has no approved public FILE owner. walk supplies typed handle inspection without inventing FILE* ownership. |
| `uv_replace_allocator` | Process-global before-first-use or globally quiescent allocator policy and thread-safe C-only hooks need ownership outside a reusable Lua-state module. |
| `uv_setup_args` | Requires true process-start argv/title memory and once-only global setup. An Array of copied Titan strings does not satisfy that memory contract. The separate `setup_process_args()` helper uses only the generated entrypoint's original argc/argv and returns false in a Lua host. |

## Internal native cleanup

The binding copies CPU information, interface addresses, environment entries,
passwd information, and group information into ordinary Titan records/Arrays.
It calls `uv_free_cpu_info`, `uv_free_interface_addresses`, `uv_os_free_environ`,
`uv_os_free_passwd`, or `uv_os_free_group` before returning those copies. There
is no public native allocation left for the caller to free, so these five
functions are not exported. This differs from `freeaddrinfo`, whose explicit
`addrinfo_result_t` lifetime remains public.

## Types, fields, callbacks, constants, and macros

| Inventory | Coverage |
| --- | --- |
| [Nonfunction dispositions](nonfunction-dispositions.tsv) | All 542 native inventory rows, including platform variants, enum values, and C-only layout/export machinery. |
| [Value fields](public-field-dispositions.tsv) | All 117 native field obligations across 24 value types, represented as copied public fields, accessors, or Array order/length. |
| [Documented native members](documented-member-dispositions.tsv) | All 44 documented handle/request/options members; reserved native data has separate traced public data access. |
| [All public fields](all-public-fields.tsv) | The exact exported record fields, including copied address bytes. |
| [Callbacks](callback-dispositions.tsv) | 25 ordinary aliases, three C-only work/thread/once contracts, and four allocator hooks associated with the allocator omission. |
| [Macros](macro-dispositions.tsv) | Usable constants and constructor semantics distinguished from C macro/export/layout mechanisms. |
| [External vocabulary](external-vocabulary-dispositions.tsv) | Header-free socket, DNS, descriptor, mode, access, and signal constants. |

Native enum alternatives use distinct Titan tagged types where documented;
combinable flags remain integers. Platform constants are nil only when the
selected native platform has no definition. Pinned constants with optional
source annotations are initialized immutable values, not runtime capability
queries. `has_api` accepts only canonical native-wrapper names without `uv_`;
it returns false for the eight omissions, five internal frees, unknown names,
and supplemental helper names.

This inventory describes API coverage and representation. Individual platform
results remain the native contract; a mapped function or field is not a claim
that every platform/backend combination has been executed. See
[ownership](CONTRACT-NOTES.md), [process policy](PROCESS-POLICY.md), and the
[implementation guide](../../implementation/libuv-extension-guide.md) for the
lifecycle rules that accompany the declarations.

## Runnable family examples

The [example guide](examples/README.md) gives build/run commands and platform
conditions for eleven complete public-import programs. This is representative
lifecycle coverage of all 28 reference families, not execution of every API
operation or every platform. The legacy-helper family demonstrates its explicit
public alternative because those deprecated native wrappers are unavailable.

| Family | Complete program | Covered lifecycle |
| --- | --- | --- |
| [loop](functions/loop.md) | [loop_phases](examples/loop_phases.titan) | Explicit init, drive, close-callback drain and loop close. |
| [handle](functions/handle.md) | [loop_phases](examples/loop_phases.titan) | Public handle data and walk-based close of initialized handles. |
| [request](functions/request.md) | [work_random](examples/work_random.titan) | Accepted work/random requests and distinct traced public request data. |
| [timer](functions/timer.md) | [timer_example](examples/timer_example.titan) | One-shot callback and explicit close retirement. |
| [prepare](functions/prepare.md) | [loop_phases](examples/loop_phases.titan) | A callback before polling. |
| [check](functions/check.md) | [loop_phases](examples/loop_phases.titan) | A callback after polling. |
| [idle](functions/idle.md) | [loop_phases](examples/loop_phases.titan) | A callback that keeps the loop active. |
| [async](functions/async.md) | [loop_phases](examples/loop_phases.titan) | Coalesced notifications and explicit handle close. |
| [signal](functions/signal.md) | [signal_poll_tty](examples/signal_poll_tty.titan) | Process-local signal delivery, stop and close when supported. |
| [poll](functions/poll.md) | [signal_poll_tty](examples/signal_poll_tty.titan) | Readiness on a borrowed descriptor; descriptor close remains separate. |
| [stream](functions/stream.md) | [dns_tcp](examples/dns_tcp.titan) | Accept, allocation/read callbacks and accepted writes. |
| [tcp](functions/tcp.md) | [dns_tcp](examples/dns_tcp.titan) | Loopback listener, connection and peer retirement. |
| [pipe](functions/pipe.md) | [pipe_process](examples/pipe_process.titan) | A CREATE_PIPE stdout stream and EOF ownership. |
| [tty](functions/tty.md) | [signal_poll_tty](examples/signal_poll_tty.titan) | Variant-based descriptor detection and window-size query on a terminal. |
| [udp](functions/udp.md) | [udp_loopback](examples/udp_loopback.titan) | Send/receive and retained public receive buffer/address. |
| [dns](functions/dns.md) | [dns_tcp](examples/dns_tcp.titan) | Address lookup and explicit result-list free after copying entries. |
| [fs](functions/fs.md) | [fs_watch](examples/fs_watch.titan) | Descriptor/path ownership, request cleanup and copied stat results. |
| [fs_event](functions/fs_event.md) | [fs_watch](examples/fs_watch.titan) | A real scratch-file change and event-handle retirement. |
| [fs_poll](functions/fs_poll.md) | [fs_watch](examples/fs_watch.titan) | A real metadata change and polling-handle retirement. |
| [process](functions/process.md) | [pipe_process](examples/pipe_process.titan) | Spawn acceptance, child stdout, exit and process-handle close. |
| [threadpool](functions/threadpool.md) | [work_random](examples/work_random.titan) | C-only work plus retained argument graph and loop-thread completion. |
| [threading](functions/threading.md) | [threading_sync](examples/threading_sync.titan) | Native thread/join and explicit synchronization/TLS lifetimes. |
| [dll](functions/dll.md) | [dll_misc](examples/dll_misc.titan) | Open, known-signature symbol use and explicit close. |
| [misc](functions/misc.md) | [dll_misc](examples/dll_misc.titan) | Copied system snapshots, clocks and encoding; work_random also demonstrates random. |
| [metrics](functions/metrics.md) | [loop_phases](examples/loop_phases.titan) | Inspect activity after loop driving. |
| [errors](functions/errors.md) | [loop_phases](examples/loop_phases.titan) | Interpret negative operation statuses with copied error text. |
| [version](functions/version.md) | [loop_phases](examples/loop_phases.titan) | Inspect the bundled version value and string. |
| [undocumented](functions/undocumented.md) | [loop_phases](examples/loop_phases.titan) | Verify omitted heap-loop helpers and use the public owned-loop alternative. |
