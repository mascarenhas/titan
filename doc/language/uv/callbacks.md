# Callback reference

All ordinary aliases below are ordinary Titan callable values, including compatible Lua callables. Binding-owned catches contain errors before native return; this does not mean a per-callback pcall. C-only entries must never access Lua/Titan state.

Ordinary public callback parameters below are Titan values. Native C pointers may be
borrowed only while the binding is copying them; the public copied strings,
stat records, and sockaddr values have ordinary retained-value lifetimes.
Concrete request/handle arguments remain views of their native owner and keep
that owner's explicit completion/close contract.

## uv_after_work_cb

**Disposition:** public ordinary callable alias.

```titan
type after_work_cb = function (work_t, integer): ()
```

**Timing/thread:** owning loop, once for an accepted request when a public after_work callback was supplied, including cancellation.

**Owners and inputs/outputs:** req input; status result; retire old request registration before callback, owner rooted through return; native argument owner can retire only after work terminal.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_alloc_cb

**Disposition:** public ordinary callable alias.

```titan
type alloc_cb = function (handle_t, integer): (buf_t)
```

**Timing/thread:** loop-thread, repeated; Windows TTY can deliver inline inside read_start or tty_set_mode on the owning main Lua thread.

**Owners and inputs/outputs:** handle input; suggested_size input advisory; buf output native descriptor. Return a writable buf_t whose backing bytes remain retained through corresponding read/recv delivery. A zero-length output can produce ENOBUFS. Saved views retain the allocation after native retirement.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_async_cb

**Disposition:** public ordinary callable alias.

```titan
type async_cb = function (async_t): ()
```

**Timing/thread:** owning loop, coalesced repeated.

**Owners and inputs/outputs:** handle input; native send calls can coalesce into one delivery. Ordinary Titan callback never executes in signal/foreign thread.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_calloc_func

**Disposition:** omitted with replace_allocator.

```titan
C-only allocator hook; process-global policy omitted
```

**Timing/thread:** any libuv/native thread, C-only.

**Owners and inputs/outputs:** Native allocator ABI; may run away from owning Lua thread; must be thread-safe and use matching allocator family. Global replacement is a deliberate omission.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_check_cb

**Disposition:** public ordinary callable alias.

```titan
type check_cb = function (check_t): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input at its loop phase; stop/rearm permitted; owner lives until close callback.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_close_cb

**Disposition:** public ordinary callable alias.

```titan
type close_cb = function (handle_t): ()
```

**Timing/thread:** owning loop, once.

**Owners and inputs/outputs:** handle input ending native lifetime; native storage may retire only within/after callback, binding callback frame retains owner through actual return.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_connect_cb

**Disposition:** public ordinary callable alias.

```titan
type connect_cb = function (connect_t, integer): ()
```

**Timing/thread:** owning loop, once on accepted request.

**Owners and inputs/outputs:** req input and status result; retire old registration before supplied callback, keep owner/retained bytes/associated handle rooted through callback actual return. Reuse only after completion.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_connection_cb

**Disposition:** public ordinary callable alias.

```titan
type connection_cb = function (stream_t, integer): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** server input; status result; accept success separately transfers native socket to initialized client owner.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_exit_cb

**Disposition:** public ordinary callable alias.

```titan
type exit_cb = function (process_t, integer, integer): ()
```

**Timing/thread:** owning loop, once after successful spawn.

**Owners and inputs/outputs:** process input; exit_status and term_signal results; close watcher separately; native handle close never substitutes child kill/reap policy.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_free_func

**Disposition:** omitted with replace_allocator.

```titan
C-only allocator hook; process-global policy omitted
```

**Timing/thread:** any libuv/native thread, C-only.

**Owners and inputs/outputs:** Native allocator ABI; may run away from owning Lua thread; must be thread-safe and use matching allocator family. Global replacement is a deliberate omission.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_fs_cb

**Disposition:** public ordinary callable alias.

```titan
type fs_cb = function (fs_t): ()
```

**Timing/thread:** owning loop, once.

**Owners and inputs/outputs:** req input/output complete request with status/result/ptr/path/statbuf. Copy/transfer results, cleanup explicitly, then reuse. Descriptor/directory outputs have separate resource cleanup.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_fs_event_cb

**Disposition:** public ordinary callable alias.

```titan
type fs_event_cb = function (fs_event_t, string?, integer, integer): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input; filename is a copied nullable Titan string which survives callback return; events input bitset; status result.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_fs_poll_cb

**Disposition:** public ordinary callable alias.

```titan
type fs_poll_cb = function (fs_poll_t, integer, stat_t?, stat_t?): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input; status result; prev/curr are independent copied stat_t records on success and nil on a negative status. Retaining those public records across callback return or watcher close is valid.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_getaddrinfo_cb

**Disposition:** public ordinary callable alias.

```titan
type getaddrinfo_cb = function (getaddrinfo_t, integer, addrinfo_result_t?): ()
```

**Timing/thread:** owning loop, once.

**Owners and inputs/outputs:** req input; status result; res independently allocated output on success, nullable on error. freeaddrinfo releases; callback/request lifetime does not automatically release result. Public addrinfo_result_t owns native list separately; entries() returns copies surviving freeaddrinfo.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_getnameinfo_cb

**Disposition:** public ordinary callable alias.

```titan
type getnameinfo_cb = function (getnameinfo_t, integer, string?, string?): ()
```

**Timing/thread:** owning loop, once.

**Owners and inputs/outputs:** req input; status result; hostname/service are copied nullable Titan strings, independent of later request reuse. Read success results only when status succeeds.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_idle_cb

**Disposition:** public ordinary callable alias.

```titan
type idle_cb = function (idle_t): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input at its loop phase; stop/rearm permitted; owner lives until close callback.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_malloc_func

**Disposition:** omitted with replace_allocator.

```titan
C-only allocator hook; process-global policy omitted
```

**Timing/thread:** any libuv/native thread, C-only.

**Owners and inputs/outputs:** Native allocator ABI; may run away from owning Lua thread; must be thread-safe and use matching allocator family. Global replacement is a deliberate omission.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_poll_cb

**Disposition:** public ordinary callable alias.

```titan
type poll_cb = function (poll_t, integer, integer): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input; status result; events combinable bitset; external fd/socket remains caller-owned.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_prepare_cb

**Disposition:** public ordinary callable alias.

```titan
type prepare_cb = function (prepare_t): ()
```

**Timing/thread:** owning loop, repeated.

**Owners and inputs/outputs:** handle input at its loop phase; stop/rearm permitted; owner lives until close callback.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_random_cb

**Disposition:** public ordinary callable alias.

```titan
type random_cb = function (random_t, integer, buf_t, integer): ()
```

**Timing/thread:** owning loop, once.

**Owners and inputs/outputs:** req input; status result; buf/buflen caller-owned output bytes retained through terminal delivery.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_read_cb

**Disposition:** public ordinary callable alias.

```titan
type read_cb = function (stream_t, integer, buf_t?): ()
```

**Timing/thread:** loop-thread, repeated; Windows TTY can deliver inline inside read_start or tty_set_mode on the owning main Lua thread.

**Owners and inputs/outputs:** stream input; nread signed result (0 no data, negative terminal); buf is an optional owner-retaining buf_t view. The native borrow ends after delivery, but retaining the view keeps its backing allocation alive after callback return.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_realloc_func

**Disposition:** omitted with replace_allocator.

```titan
C-only allocator hook; process-global policy omitted
```

**Timing/thread:** any libuv/native thread, C-only.

**Owners and inputs/outputs:** Native allocator ABI; may run away from owning Lua thread; must be thread-safe and use matching allocator family. Global replacement is a deliberate omission.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_shutdown_cb

**Disposition:** public ordinary callable alias.

```titan
type shutdown_cb = function (shutdown_t, integer): ()
```

**Timing/thread:** owning loop, once on accepted request.

**Owners and inputs/outputs:** req input and status result; retire old registration before supplied callback, keep owner/retained bytes/associated handle rooted through callback actual return. Reuse only after completion.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_signal_cb

**Disposition:** public ordinary callable alias.

```titan
type signal_cb = function (signal_t, integer): ()
```

**Timing/thread:** owning loop, repeated or oneshot.

**Owners and inputs/outputs:** handle input; signum input signal identifier; OS signal trampoline does not enter Lua/Titan.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_thread_cb

**Disposition:** inline C-only public structural callback.

```titan
foreign function (*void): void (thread_create/thread_create_ex entry)
```

**Timing/thread:** new native thread, once.

**Owners and inputs/outputs:** arg input native pointer; entry must be C-only. Owner survives execution; join proves completion, detach alone does not.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_timer_cb

**Disposition:** public ordinary callable alias.

```titan
type timer_cb = function (timer_t): ()
```

**Timing/thread:** owning loop, one-shot or repeated.

**Owners and inputs/outputs:** handle input; may stop/rearm; one-shot firing does not end initialized handle lifetime.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_udp_recv_cb

**Disposition:** public ordinary callable alias.

```titan
type udp_recv_cb = function (udp_t, integer, buf_t?, sockaddr_t?, integer): ()
```

**Timing/thread:** loop-thread, repeated.

**Owners and inputs/outputs:** handle input; nread signed result; buf caller-owned allocation; addr is a nullable copied sockaddr_t that survives callback return; an unknown native family may produce an incomplete family-only value. flags input bitset. MMSG_CHUNK retains the allocation for later chunks; MMSG_FREE ends the native batch borrow. Retained buf_t views still retain their own backing storage. Zero bytes with addr is empty packet.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_udp_send_cb

**Disposition:** public ordinary callable alias.

```titan
type udp_send_cb = function (udp_send_t, integer): ()
```

**Timing/thread:** owning loop, once on accepted request.

**Owners and inputs/outputs:** req input and status result; retire old registration before supplied callback, keep owner/retained bytes/associated handle rooted through callback actual return. Reuse only after completion.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_walk_cb

**Disposition:** public ordinary callable alias.

```titan
type walk_cb = function (handle_t, value): ()
```

**Timing/thread:** calling loop thread, synchronous per handle.

**Owners and inputs/outputs:** handle input view retains canonical native owner; arg synchronous input context; no requests. Any error rethrows only after walk returns.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_work_cb

**Disposition:** inline C-only public structural callback.

```titan
foreign function (*void): void (queue_work worker argument)
```

**Timing/thread:** foreign worker, once if not cancelled.

**Owners and inputs/outputs:** arg input is the exact borrowed native pointer passed to queue_work, not a Titan request owner; never recover/access Titan/Lua on a worker. Its complete backing graph remains valid through terminal after-work completion.

**Failure:** C-only; cannot enter Lua/Titan.

## uv_write_cb

**Disposition:** public ordinary callable alias.

```titan
type write_cb = function (write_t, integer): ()
```

**Timing/thread:** owning loop, once on accepted request.

**Owners and inputs/outputs:** req input and status result; retire old registration before supplied callback, keep owner/retained bytes/associated handle rooted through callback actual return. Reuse only after completion.

**Failure:** The binding catch boundary invokes ordinary callable; preserve first error, finish mandatory bookkeeping, stop/rethrow after native outer boundary.

## uv_once callback parameter

**Disposition:** inline C-only public structural callback.

```titan
foreign function (): void (once callback)
```

**Timing/thread:** synchronous once, potentially any native caller thread.

**Owners and inputs/outputs:** C-only callback; UV_ONCE_INIT guard, not assumed zero. Must not enter Lua/Titan.

**Failure:** C-only; cannot enter Lua/Titan.
