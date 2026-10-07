# Build and installation responsibilities

`Makefile` is the Linux/macOS entry point; `Makefile.win` is the Windows entry
point for direct builds and LuaRocks' make backend. LuaRocks owns
compiler dependencies and source-rock deployment on all three platforms.

Lua and LuaRocks preparation check only their installed programs in `PREFIX/bin`.
Callers own the selected native toolchain, prerequisites, prefix, and cleanup
when changing build inputs. Linux defaults to Lua's `linux-readline` target;
provide Readline development files or override `LUA_PLATFORM`.

Ordinary native archives use source/header prerequisites and `ar`/`ranlib`.
Failed output recipes remove unfinished artifacts before an ordinary retry.
CMake owns libuv incrementality; upstream configure/make owns Windows
libbacktrace. Windows runtime compilation is a direct build
of its eight inputs, and OpenSSL uses a binary SDK by default. Versioned source
acquisition retains checksums and the required upstream corrections.

Standard-library installation copies the built provider, shims, test-support
compiler source, licenses, and optional symbols. The initial runtime bootstrap
is copied only when the canonical provider is absent. Installation has no
receipt, predecessor classification, metadata scan, or rollback transaction.
Windows callers must close processes using a destination DLL before replacing it.

The Unix object graph retains parallel module compilation and a shared completion
marker for paired outputs on GNU Make 3.81. It checks missing generated companions
and leaves unchanged outputs alone. `make clean-stdlib` clears that graph before
changing tools, flags, profile, or OpenSSL mode. Clean affected native build
directories too, or use separate source copies and SDKs.

Explicit PE, SDK, compiler, launcher, runtime, provider, and native-suite checks
live in `spec/support` and run through check/test targets. Compiler provider
publication remains a compiler contract with its own regression tests; it is
separate from ordinary stdlib copying. The operational Windows scripts cover
LuaRocks acquisition, native source preparation/building, libbacktrace and
runtime compilation,
stdlib compilation, and profile selection.
