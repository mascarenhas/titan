# Shared native standard-library behavior

Linux, macOS, and native Windows compile the same 29 explicit test roots from
`spec/support/stdlib_test_modules.mk`. Each owner retains its common test bodies
and assertions. Platform differences belong in narrow fixtures or named,
classified skips; there is no separate Windows case allowlist.

## Commands and ownership

From the current source checkout with the installed Unix SDK on `PATH`:

```sh
make titan-stdlib-test-build
make titan-stdlib-test-run
```

From native MSYS2 CLANG64, after publishing a current Windows SDK/provider:

```sh
make -f Makefile.win titan-stdlib-test-build \
  PREFIX=/c/validated-sdk TITAN_TEST_BUILD_DIR=/c/owned-ntfs-work/shared-tests
make -f Makefile.win titan-stdlib-test-run \
  PREFIX=/c/validated-sdk TITAN_TEST_BUILD_DIR=/c/owned-ntfs-work/shared-tests
```

The convenience command `bash spec/support/check_windows_stdlib_behavior.sh
/c/owned-ntfs-work /c/validated-sdk` creates a unique child workspace under an
existing parent and performs both steps. The supplied SDK is copied before
compilation. It must contain the native compiler, complete `titan.dll`, the
`lib/lua/5.5/titan.dll` support module, matching controlled Lua, and native DLL
dependencies/import libraries.
The workspace and its logs remain available for inspection. Test compilation
uses `-O0` by default on Windows; provider optimization is recorded separately.
The aggregate launcher reserves 8 MiB of stack, matching the ordinary Unix
main-thread budget for the unchanged deep-recursion tests at `-O0`. This is a
test resource setting; production launcher defaults remain unchanged.

Both platforms accept `TITAN_FILTER` for focused execution after all owners
compile. An acceptance run has no filter. The output auditor verifies every
named result, totals, classified skip reasons, and complete owner presence;
empty selections and unfinished fixture portability fail the gate. Reports
include selected, passed, skipped, failed, and executed-owner counts.

The ordinary Unix process-group supervisor and native Windows Job Object
supervisor bound execution. The Windows supervisor creates the aggregate
suspended with atomic job assignment and a whitelist of its three standard
handles, then resumes it. Its unnamed job terminates descendants on timeout,
main-process exit, or supervisor exit. PowerShell drains both output pipes,
holds the supervisor handle, and bounds cleanup separately. It preserves the
complete native exit status; a code such as 256 cannot truncate to success at
the Bash boundary. A deadline returns 124 and a supervisor failure returns 125.
The default suite deadline is 300 seconds. No process is found or killed by an
unverified reused PID, and no execution policy or firewall settings change.

Windows scratch directories must be empty after the run. Filesystem, SQLite,
and local watcher assertions execute on local NTFS. Shared-folder notifications
remain best effort and do not satisfy this gate. Network tests use loopback
and checked-in test certificates; the runner does not modify a trust store.

## Earlier Windows baseline

The issue's initial baseline was 44 cases at `25c095ae3f2a9f4e29d8b2c499b388216b8fb66b`.
The merged initial port added nine shell-process cases, bringing the baseline to 53
at `bda3ad10`. That count is historical, not a limit or target for the shared
suite. The common suite retains that coverage as follows:

| Earlier owner | Common owner and retained behavior |
| --- | --- |
| `coroutine.tests`, `timer.tests` | Same owners; values, yields, injection, lifecycle, GC, sleeps, ticks, cancellation |
| `os.windows_process_tests` | `os.process_tests` and `os.tests`; native argv/environment/cwd, Unicode and empty values, binary/merged pipes, repeated waits, UTC calendar, exits 1/126/127/9009 |
| `io.windows_tests` | `os.process_tests` (`shell_test.titan`); fixed native shell, NUL rejection, quoted Unicode arguments, binary duplex, shell operators/redirection, status, close, read/wait cancellation |
| `io.tests` | `io.tests`; Interface conversion, `print`, and owned `lines` iteration |
| `fs.windows_tests` | `fs.tests`; exact binary bytes/append, Unicode paths, stat/lstat, rename/identity, directory entries, canonical file and directory watcher paths |
| `sqlite3.windows_tests` | `sqlite3.tests`; typed row snapshots after close, Unicode persistence, commit/rollback, and recoverable native `SQLITE_BUSY` |
| `net.tests`, `ssl.tests` | Same owners; binary loopback, half-close, pending accept, explicit test CA, hostname verification, truncation, and PEM errors |

Portable math, strings, iteration, GC, reflection, JSON, PEG, URL, HTTP, generic
async, and the full Lua/stdio/process suites now belong to the common inventory.
Native async, SQLite, stdio, print-capture, filesystem, and source-search
fixtures compile before execution on every platform. Fresh compiler/Lua child
probes use `support.command`, which reuses the compiler's existing host argv
transport, resolves the selected SDK's tools, restores cwd/environment, writes
multiline Lua probes to owned files, and preserves native Windows exit bits.
Windows child programs receive byte-for-byte copies of the validated SDK's
runtime DLLs beside their executables. The test provider path keeps the SDK
first and retains the normal executable-relative defaults with `;;`; each
child's existing workspace cleanup also removes its DLL copies.

## Remaining platform boundaries

Every actual skip appears with its full case name and reason in the run log.
The permitted reason classifications are:

- `platform: `: Unix filesystem-FIFO source-open cancellation, Unix USR1/USR2
  delivery, Unix-domain stdio socket semantics, Linux-specific seccomp metadata
  denial, or a Windows exit value outside POSIX's eight-bit range.
- `capability: `: an alternate numeric locale is absent or Windows cannot create
  a symbolic link without Developer Mode or the required privilege.
- `portability: `: an unfinished harness fixture. This is a tracked failure of
  the complete gate, not evidence that the production API is unsupported.

Native traceback assertions run on Windows through libbacktrace, including
source locations, interleaved Lua/native frames, and preserved re-raise traces.

The Windows provider remains DLL-only. SQLite worker tests use the same SQLite
DLL instance as the standard provider; Unix retains the existing static worker
consumer. This does not add static-provider support on Windows. Windows console
stdio uses a private native console fixture, while pipe, regular-file, closed
handle, and leak assertions remain common.

Record each validation's source commit or exact source archive hash, native
OS/architecture, compiler/SDK identity, provider configuration/optimization,
filesystem, relevant capabilities, counts, and named skips. Test both Windows
O0 and O3 providers. Record Intel versus Apple Silicon for macOS; a VM boot,
SDK canary, or extension test cannot substitute for this behavior suite.
