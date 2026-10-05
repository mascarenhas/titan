# Process pipe eligibility and native failure policy

Process creation crosses several native ownership boundaries. The rules below apply to the public `uv` process and pipe owners on every supported platform.

## CREATE_PIPE uses a fresh pipe lifetime

For each CREATE_PIPE stdio entry, construct a `pipe_t`, successfully call `pipe_init` on the spawn loop, and use its `stream_t` view in the options. The pipe must still be initialized, not closing, on that same loop, and eligible for CREATE_PIPE. A pipe owner may appear in only one CREATE_PIPE entry in that spawn. These are binding preconditions on every platform, including Unix platforms whose native implementation may accept more permissive sequences.

Successful `pipe_init` makes the new lifetime eligible. The following operations consume eligibility when they pass binding validation and hand the pipe to the native operation. Consumption remains in force even when the native operation returns an error, performs no useful work, or later reports failure through a callback.

| Operation | Pipe whose eligibility is consumed |
| --- | --- |
| `pipe_open`, `pipe_bind`, `pipe_bind2` | The pipe argument |
| `pipe_connect`, `pipe_connect2` | The connecting pipe |
| `pipe_pending_instances`, `pipe_chmod` | The pipe argument |
| `listen` | The pipe server |
| `accept` | Each pipe used as server or client |
| `read_start`, `read_stop` | The pipe stream |
| `stream_set_blocking` | The pipe stream |
| `write`, `write2`, `try_write`, `try_write2` | The destination pipe stream |
| `shutdown` | The pipe stream |
| `spawn` with CREATE_PIPE | Every selected CREATE_PIPE pipe, after the whole binding preflight succeeds and immediately before native spawn |

Binding-side validation failures preserve eligibility. Examples include a busy request, mismatched owner kind or loop, closing handle, invalid binding-checked name length, incompatible accept pair, and checked conversion failure before native entry. A negative status by itself does not reveal whether a native operation was attempted: follow the particular operation's preflight contract.

For spawn, all selected CREATE_PIPE owners are checked for eligibility and duplicates before any is consumed. A later invalid stdio entry therefore leaves earlier selected pipes eligible. Once native spawn is attempted, all selected pipes remain ineligible regardless of the native status. A failed spawn does not restore them for another CREATE_PIPE attempt.

Queries and owner views do not consume eligibility. Neither do public userdata access, `ref`/`unref`, `send_buffer_size`/`recv_buffer_size`, or using a pipe only as an INHERIT_STREAM stdio source. A pipe borrowed only as `send_handle` for `write2`/`try_write2` keeps its own eligibility; the destination's rule still applies. These operations keep their ordinary native validity requirements.

Closing makes the old lifetime unavailable for spawn; close retirement clears its eligibility. After close completion, a new successful `pipe_init` establishes a new eligible lifetime. There is no public field, setter, or reset operation for eligibility. For straightforward setup, initialize each CREATE_PIPE owner and submit spawn before using that pipe for other native I/O.

## try_write2 borrowed-source validation

On Unix, a nonnil `send_handle` is checked with native `fileno` before `try_write2` hands the destination to native writing. A negative descriptor-query status is returned unchanged. This preflight leaves the destination's CREATE_PIPE eligibility intact and does not consume eligibility from the borrowed source. A fresh initialized but descriptor-less pipe can therefore fail this check without losing its eligibility.

Windows preserves native `try_write2` transfer rejection with EAGAIN; it does not add the Unix descriptor check. Once the Windows destination is handed to native `try_write2`, its pipe eligibility is consumed even when that native EAGAIN is returned. Both platforms still apply the existing owner-kind, initialized/closing, and buffer validation before native writing.

## Failed spawn with the pinned native dependency

A failure before binding handoff creates no process-handle close obligation. After native spawn is called, the public process owner is initialized and must eventually close whether spawn returns success or a negative status. A negative spawn result alone does not prove that no child was started. Closing a process handle does not kill a running child, and child exit does not close the process handle.

For a fresh caller-owned spawn attempt, inspect the public handle view after
the call: `is_initialized()` identifies a native close obligation, and
`uv.is_active(handle)` identifies an outstanding process watcher. When aborting
with an active watcher before its exit callback, signal through `process_kill`
and keep the watcher open until the actual exit callback arrives. A negative
spawn result does not skip that step. An initialized inactive failed owner can
be closed directly. This recipe assumes the caller has not already closed or
reused that process lifetime; the [complete process/pipe example](examples/pipe_process.titan)
shows the ownership sequence without inferring child existence from the result
sign or a saved PID.

The approved bundled Unix libuv fix keeps failed-spawn handle registration consistent with the required later close. It is a native dependency repair, not a binding rule that skips close or infers ownership from a particular error number. The patch removes the premature error-path handle-queue removal so normal uv_close owns the single removal. A libuv version number alone does not identify this local bundled repair.

Titan supports only its pinned, patched libuv 1.53.0 dependency. There is no
system libuv mode. The checked-in patch is
[`libuv-1.53.0-spawn-close.patch`](../../../vendor/libuv/libuv-1.53.0-spawn-close.patch)
and the build verifies the expected source before applying it. A version number
alone does not identify that repair. Ordinary close behavior applies after
native spawn handoff, including a failed spawn.
