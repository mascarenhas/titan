# Bundled libuv correction

`libuv-1.52.1-spawn-close.patch` removes the redundant Unix process-handle queue
removal on `uv_spawn`'s error path. Libuv initializes the process handle before
that path; its documented contract requires `uv_close` after both success and
failure. Normal close completion owns removal from the loop's handle queue.
Removing the node twice can corrupt the queue when another handle is initialized
between the failed spawn and close completion.

The patch leaves the process queue, file descriptors, child handling and native
status unchanged. Windows source is unchanged. It applies to the pinned official
1.52.1 release archive after checksum verification. A versioned extraction stamp
and build/cache profiles prevent reuse of the older unpatched source or archive.

As checked on 2026-10-03, libuv 1.53.0 and development commit
`49b1c064714b412d7f7a2f5e7146c977554e57f9` still contain the redundant removal.
System mode consumes its library unchanged: use an up-to-date system libuv and
check whether its package includes this correction. An up-to-date version alone
does not yet remove the exposure. Bundled mode includes the fix.

Sources:

- [Required spawn cleanup](https://github.com/libuv/libuv/blob/v1.53.0/docs/src/process.rst#L260-L272)
- [Cleanup clarification](https://github.com/libuv/libuv/pull/5055)
- [Change that introduced the redundant removal](https://github.com/libuv/libuv/pull/4980)
- [Native close completion](https://github.com/libuv/libuv/blob/v1.53.0/src/unix/core.c#L359-L364)
