# Bundled libuv corrections

## Unix process close

`libuv-1.53.0-spawn-close.patch` removes the redundant Unix process-handle queue
removal on `uv_spawn`'s error path. Libuv initializes the process handle before
that path; its documented contract requires `uv_close` after both success and
failure. Normal close completion owns removal from the loop's handle queue.
Removing the node twice can corrupt the queue when another handle is initialized
between the failed spawn and close completion.

The patch leaves the process queue, file descriptors, child handling and native
status unchanged. Windows source is unchanged. It applies to the pinned official
1.53.0 release archive after checksum verification. A versioned extraction stamp
and build/cache profiles prevent reuse of the older unpatched source or archive.

As checked on 2026-10-03, libuv 1.53.0 and development commit
`49b1c064714b412d7f7a2f5e7146c977554e57f9` still contain the redundant removal.
Titan always builds the pinned source with this correction. System libuv is
not a supported dependency policy.

Sources:

- [Required spawn cleanup](https://github.com/libuv/libuv/blob/v1.53.0/docs/src/process.rst#L260-L272)
- [Cleanup clarification](https://github.com/libuv/libuv/pull/5055)
- [Change that introduced the redundant removal](https://github.com/libuv/libuv/pull/4980)
- [Native close completion](https://github.com/libuv/libuv/blob/v1.53.0/src/unix/core.c#L359-L364)

## Windows callback-time pipe writes

`libuv-1.53.0-windows-write-reentry.patch` fixes successive writes to synchronous
Windows pipes when a write callback submits the next write. In the pinned
1.53.0 source, completion clears the active worker slot and dispatches any
already queued write before calling the completed request's callback. The
pending-write count is decremented only after that callback returns. A callback
that submits another write to an otherwise idle pipe therefore queues it with
no worker: the pending count is still one, so the submission path does not
dispatch it. The subsequent decrement leaves the successor pending forever.

The patch tests the active worker slot when deciding whether to dispatch a new
write. It preserves the existing request-count, callback, cancellation, shutdown
and close ordering. Synchronous pipes allow exactly one active write; completion
clears that slot before user callbacks, and queued cancellation removes its
request without occupying the slot. The existing native
`test_io_print_formats_left_to_right_and_is_atomic` case exercises this boundary
through a captured Windows stdout pipe and consecutive asynchronous writes.

Windows source preparation verifies the official release archive with SHA-256
`cb0d6dd2128d5a95bd242c6cc982a24fe608fa93da57b6b4ec763b0018c53e64`, then checks
and applies this patch with `git apply`. Its existing source stamp includes the
patch digest, so an older prepared tree is replaced before the normal native
build. Unix preparation and its process-close correction are unchanged.

Sources:

- [Write submission and worker dispatch](https://github.com/libuv/libuv/blob/v1.53.0/src/win/pipe.c#L1711-L1727)
- [Pending-count dispatch check](https://github.com/libuv/libuv/blob/v1.53.0/src/win/pipe.c#L1845-L1858)
- [Write completion and callback ordering](https://github.com/libuv/libuv/blob/v1.53.0/src/win/pipe.c#L2380-L2440)
- [Non-overlapped cancellation](https://github.com/libuv/libuv/blob/v1.53.0/src/win/pipe.c#L1174-L1218)
