# Native build profiles

Ordinary Titan compilation and installation use the `production` profile. Its
generated C uses `-O3`, with `-flto=auto -ffat-lto-objects` on Linux. Darwin and
Windows retain `-O3` without default LTO.

Set `TITAN_BUILD_PROFILE=validation` for development and validation builds:

```sh
TITAN_BUILD_PROFILE=validation make lua luarocks PREFIX="$PWD/.lua-validation"
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks make --force
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks test
```

The validation profile uses `-O0 -fno-lto` for generated code, the Titan native
runtime and bundled standard-library payloads. Lua and its compiler dependencies
(LPegLabel and Lua filesystem), plus the private LPegLabel payload, stay optimized
at `-O2 -fno-lto`: the Lua-written compiler and its tests execute through them.
Sanitizer builds use `-O1 -fno-lto` for those host/parser components while retaining
all ASan/UBSan instrumentation; Titan code and other native payloads remain O0.

`make luarocks` reconciles the optimized compiler dependencies before Titan is
installed. A receipt records their exact compile/link flags, selected versions,
Lua/tool inputs and native module hashes. It rebuilds stale same-version modules
and preserves unchanged modules. Generic LuaRocks CFLAGS remain O0 for the Titan
rock's runtime build. `COMPILER_DEPS_CFLAGS/LDFLAGS` select host dependency flags,
`LPEGLABEL_ROCK_CFLAGS/LDFLAGS` can specialize the compiler parser, and
`LPEGLABEL_BUILD_CFLAGS` selects the private parser payload. Parser flags follow
generic Titan extras so an O0 fixture setting cannot deoptimize the parser.
Explicit domain overrides remain caller-owned, including sanitizer instrumentation.

Use a separate prefix for each profile. The default repository test commands
select validation and use `.lua-validation` when no `PREFIX` was supplied;
ordinary builds retain existing active-PATH Lua prefix discovery. A discovered
prefix remains caller-owned: select a matching profile or pass an explicit
separate production PREFIX when the active SDK is validation. `make test` prepares
and reinstalls the selected toolchain before running the complete gate. A cold
`make rock-test` prepares its missing validation prefix through `make test`.
Leaf native build/run targets require that selected SDK to be prepared already.

Native Windows Make check and test targets select the same validation profile,
with separate `.windows-sdk-validation` and `windows-build-validation` defaults.
Ordinary Windows Lua, native dependency and runtime builds retain their existing
`-O2` defaults; generated Titan C retains the production `-O3` policy. Explicit
`PREFIX`, `WINDOWS_BUILD_ROOT` and native flags remain caller-owned.

An installed SDK records its selected profile in `etc/titan/build-profile`.
Native outputs remain adjacent to their sources, so builds using the same
checkout must run sequentially even when their installed prefixes differ. Use
separate source copies for concurrent builds.

Only `production` and `validation` are accepted. The profile changes native
build policy without changing the language, ABI, compiler release, or metadata
schema versions. A small compiler smoke continues to test unset production
optimization and cross-module LTO while ordinary validation fixtures stay at
`-O0`.
