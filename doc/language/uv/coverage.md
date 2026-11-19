# Native libuv API coverage

`titan.uv` wraps libuv 1.53.0. `uv.has_api(name)` (omitting the `uv_` prefix)
reports whether a canonical libuv wrapper is exported; it returns `false` for
the unavailable functions below, the internally freed snapshot functions, and
the supplemental helpers in [supplemental.md](supplemental.md). See
[CONTRACT-NOTES.md](CONTRACT-NOTES.md), [PROCESS-POLICY.md](PROCESS-POLICY.md),
and [examples/README.md](examples/README.md) for ownership rules and runnable
examples.

## Unavailable direct wrappers

| Native function | Reason and public alternative |
| --- | --- |
| `uv_default_loop` | Process-global loop cannot be independently owned across Lua states. Construct `uv.loop_t()` and call `uv.loop_init`. |
| `uv_library_shutdown` | One-time process-global teardown invalidates all later libuv calls across every Lua state. |
| `uv_loop_delete` | Deprecated heap deletion conflicts with Titan-owned `loop_t` storage. Call `uv.loop_close`. |
| `uv_loop_new` | Deprecated heap allocation conflicts with Titan-owned `loop_t` storage. Construct `uv.loop_t()` and call `uv.loop_init`. |
| `uv_print_active_handles` | Takes `FILE *`, which has no public Titan owner. Inspect handles with `uv.walk` and `uv.is_active`. |
| `uv_print_all_handles` | Takes `FILE *`, which has no public Titan owner. Inspect handles with `uv.walk`. |
| `uv_replace_allocator` | Process-global allocator hooks must be installed before any libuv use outside a reusable Lua-state module. |
| `uv_setup_args` | Requires original process `argv` memory rather than copied Titan strings. Use `uv.setup_process_args()` in standalone executables. |
| `uv_write_nwritten` | No Titan wrapper exposes the write-callback progress count, and `uv.cancel` rejects write requests. |

## Internal native cleanup

`titan.uv` copies CPU info, interface addresses, environment entries, passwd
records, and group records into Titan records and Arrays, then frees libuv's
native buffers immediately via `uv_free_cpu_info`,
`uv_free_interface_addresses`, `uv_os_free_environ`, `uv_os_free_passwd`, and
`uv_os_free_group`. Because no caller-owned native buffer escapes, those five
free functions are not exported (unlike `uv.freeaddrinfo`, whose
`addrinfo_result_t` lifetime is caller-owned).

## Runnable family examples

The [example guide](examples/README.md) provides eleven complete programs
demonstrating lifecycles across all 28 API families listed in the
[libuv reference directory](../standard-library-uv.md#reference-directory).
