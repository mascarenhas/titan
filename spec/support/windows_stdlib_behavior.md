# Experimental Windows standard-library subset

From a native MSYS2 CLANG64 shell, after building and validating the complete
Windows SDK and standard provider:

```sh
bash scripts/check_windows_stdlib_behavior.sh /c/owned-ntfs-work /c/validated-sdk
```

Both arguments name existing directories. The runner creates a fresh workspace
under the first and copies the second before compiling anything. It preserves
that workspace, build log, and stdout/stderr logs for inspection; it never
publishes into the supplied SDK. The first directory must be on local NTFS.
The SDK must contain the installed native compiler, full `titan.dll`, generated
stdlib shims, matching Lua, and the controlled native DLL dependencies in `bin`.
The script compiles disposable tests at `-O0` by default; caller-supplied
`TITAN_EXTRA_CFLAGS` may select another test build optimization.

This is **53 named public-behavior cases**, listed in
`windows_stdlib_cases.txt`, not the complete native aggregate. The runner checks
the exact successful case names and count, rejects skips, enforces a 180-second
native execution deadline, and requires the cases' scratch directory to be
empty afterward. A small native test supervisor creates the subset suspended
with Windows 11's atomic Job Object assignment and an explicit list of its three
standard handles, then resumes it. The unnamed job terminates all descendants
on timeout, after the main test exits, or when the supervisor itself exits.
There is no interval in which the child can run outside that job, and unrelated
inheritable handles are excluded. An ordinary inline PowerShell process drains
both output pipes, holds the supervisor process handle, and bounds supervisor
cleanup with a separate 195-second watchdog. It never enumerates or kills a
process by a possibly reused PID, and makes no execution-policy or OS setting
changes. The supervisor preserves native argument values and the main test's
exit code; a child deadline returns 124, while harness failures return 125.
The PowerShell-to-Bash boundary reports the full native failure code and
returns shell status 1 for every nonzero code, so values such as 256 cannot
truncate to success. These codes do not change the public process API or
compiler spawn behavior.

Coverage:

- Fifteen existing coroutine cases cover values, tags, nested yields, error
  injection, lifecycle, and collection. Four timer cases exercise Task yields,
  sleeps, ticks, close/cancellation, and callback-owner collection.
- A native C child independently observes UTF-16 Windows argv/environment/cwd
  and returns length-prefixed UTF-8. Public `os.spawn` cases check quoted and
  empty arguments, supplementary Unicode, inherited cwd, child-only environment
  replacement, case-insensitive names, absent/empty values, binary captured
  pipes, merged output, repeated waits, and native exits 1/126/127/9009. Calendar
  checks use an explicit UTC date and do not alter timezone or locale.
- Nine `io.popen` cases cover fixed system `cmd.exe` selection, quoted paths
  containing spaces and Unicode, binary duplex and merged output, shell
  operators/pipelines/redirection, exit status and repeated waits, idempotent
  close of a running shell, NUL rejection, and cancelling reads or waits
  without terminating the child.
- Four filesystem cases check binary streams, Unicode paths, stat/lstat,
  rename/identity, directory entries, and bounded local NTFS file/directory
  watcher events and retirement. The watcher asserts canonical returned paths;
  shared-folder notifications are outside this gate and remain best effort.
- Three SQLite cases check scalar/blob values and row ownership, persistent
  transactions/rollback, and recovery from an actual competing connection's
  `SQLITE_BUSY` result.
- Existing TCP and TLS cases use loopback only, including binary records,
  half-close, pending accepts, explicit test-CA verification, wrong-host
  rejection, TLS truncation, and PEM errors. The only copied key is the
  repository's checked-in TLS test fixture. No system trust store is modified.

The four shared roots (`coroutine.tests`, `timer.tests`, `net.tests`, and
`ssl.tests`) plus the four Windows roots in `windows_stdlib_modules.tsv` are
compiled with `--no-uv-bootstrap`; their
existing repository support helper owns and drains a Runtime per async case.
Runtime filters select the intended cases but do not isolate compilation: the
coroutine folder still compiles its existing contributors. None requires the
POSIX aggregate's socket/stdio/filesystem C fixtures. The process child keeps
its original Unix implementation unchanged behind an `#else` branch. The
Windows inventory owns the four extra source modules independently of the Unix
aggregate; the repository completeness gate checks their union without adding
Windows-only cases to the Unix object graph. The runner validates each inventory
entry and requires at least one selected case for each extra root.

Excluded boundaries include the POSIX shell-based Lua coroutine fixtures,
exact native source-line traceback attribution, HTTP, the complete generic
async suite, GUI/console inheritance, and shared
folder notification guarantees. This runner neither accepts a firewall prompt
nor changes firewall policy; a blocked loopback operation fails with its actual
diagnostic. Passing this subset is not a complete Windows test or release claim;
the complete Windows standard-library gate remains tracked in
[issue #187](https://github.com/mascarenhas/titan/issues/187).
