# Runnable public UV examples

These complete programs use ordinary `import "titan.uv"`. They show explicit
native lifetimes with public owners, requests, callbacks, and copied results.
They do not import binding internals or C libuv headers. Each program exits
with zero after checking its result; a nonzero exit or raised exception means
the demonstrated operation failed.

With an installed Titan SDK on `PATH`, copy the examples into a scratch
directory and compile the program you want to run:

```sh
mkdir -p /tmp/titan-uv-examples
cp doc/language/uv/examples/*.titan /tmp/titan-uv-examples/
cp doc/language/uv/examples/example_library.c /tmp/titan-uv-examples/
cd /tmp/titan-uv-examples
titanc --no-uv-bootstrap loop_phases
./loop_phases
```

Use the same compile command with any program name below. The explicit
`--no-uv-bootstrap` makes the main-thread driving requirement visible; these
programs import only `uv`, which does not itself install async's bootstrap.
Programs that initialize a loop close their native handles, drain accepted
requests and close callbacks, and then close the loop. Synchronous utilities
and thread primitives do not need a loop.

| Program | Demonstration |
| --- | --- |
| [timer_example](timer_example.titan) | Smallest initialized timer, callback, handle close, and loop close sequence. |
| [fs_stat_example](fs_stat_example.titan) | Synchronous stat, copied result, and request cleanup. Run `./fs_stat_example fs_stat_example.titan`. |
| [loop_phases](loop_phases.titan) | Idle/prepare/check callbacks, coalesced async notifications, public handle data, version, metrics, and the explicit alternative to omitted heap-loop helpers. |
| [work_random](work_random.titan) | A C-only worker with retained argument storage, loop-thread completion, asynchronous random output, and separate request data. |
| [threading_sync](threading_sync.titan) | A C-only native thread with explicit join, mutex/condition/rwlock/semaphore/barrier/once lifetimes, and a borrowed TLS pointer. These are blocking primitives, not cooperative Task waits. |
| [udp_loopback](udp_loopback.titan) | A real loopback datagram, send completion, writable receive allocation, and retaining the returned buffer/address after handle close. |
| [dns_tcp](dns_tcp.titan) | Asynchronous address lookup, explicit address-list disposal, a loopback TCP listener/client, accept, reads and writes, and timeout cleanup. |
| [fs_watch](fs_watch.titan) | A unique scratch directory/file, asynchronous stat, filesystem events and stat polling, mutation, handle retirement, and removal of both scratch objects. |
| [pipe_process](pipe_process.titan) | Spawn this executable in child mode, pass a pipe as child stdout, read to EOF, observe child exit, and retire process and pipe ownership. |
| [dll_misc](dll_misc.titan) | Load the accompanying C fixture, look up a known function signature, keep the library open through its use, and inspect copied system/encoding results. See the extra build step below. |
| [signal_poll_tty](signal_poll_tty.titan) | Borrow a pipe descriptor for readiness polling, deliver a signal to this process, and query terminal dimensions when stdin is a TTY. |

The [family map](../coverage.md#runnable-family-examples) maps all 28 reference
families to these programs. Each program demonstrates selected operations and
their ownership pattern; it is not an exhaustive test of every function in its
families.

## Dynamic-library fixture

`dll_misc` needs the small application-owned [example_library.c](example_library.c)
fixture. The file has no libuv dependency. On Linux:

```sh
cc -std=c99 -Wall -Wextra -fPIC -shared example_library.c -o example_library.so
titanc --no-uv-bootstrap dll_misc
./dll_misc ./example_library.so
```

On macOS, compile that C file with `cc -dynamiclib example_library.c -o example_library.dylib`
and pass `./example_library.dylib`. In the experimental Windows CLANG64
environment, use `clang -shared example_library.c -o example_library.dll` and
pass that DLL's path to the generated program. The symbol's exact C signature
comes from this fixture; `dlsym` cannot validate an arbitrary pointer cast.

## Platform-dependent paths

`signal_poll_tty` reports a `SKIP` line when its selected descriptor/signal
operation is unsupported or stdin is not a terminal. Other initialization
errors remain failures. Run it directly in a terminal to exercise the TTY
path. It matches the `handle_type.tty()` variant returned by `guess_handle`;
`==` on independently constructed nominal union values compares identity.
Pipe polling commonly needs a different descriptor kind on Windows.

The networking examples bind only loopback addresses and select ephemeral
ports. Watcher delivery still depends on the native platform and filesystem;
the example's deadline turns missing delivery into an explicit failure.
Process/pipe descriptor rules and TTY behavior remain platform-specific even
though the public signatures are shared.

All eleven programs were compiled and run on Linux x86_64 for this change.
The conditional signal/poll/TTY program also ran with a controlled pseudo
terminal to exercise its terminal branch. The alternative macOS/Windows
fixture commands are usage instructions, not evidence of platform execution.
