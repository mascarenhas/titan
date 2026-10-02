# Windows serial compiler oracles

These are native Windows integration gates. Linux dispatch/status tests do not
substitute for them. Run against the edited checkout and controlled Lua 5.5.1,
using the approved CLANG64/UCRT compiler. No global PATH or code-page setting
change is part of these tests.

`argv_oracle.c` uses `wmain` and independently converts the received UTF-16 argv
to UTF-8 hex. Compile it with `clang -std=c99 -municode argv_oracle.c -o argv_oracle.exe`.
Place its output under a disposable directory containing spaces and non-ACP
Unicode characters (for example `serial tools 日本語 😀`). From the checkout,
run the controlled Lua with:

```
spec/fixtures/windows_serial/verify_transport.lua <absolute-oracle.exe> <disposable-workdir> <absolute-clang.exe>
```

The transport gate loads the edited `titan-compiler/platform.lua`. It tests both
`io.popen` and `os.execute`, exact argv (including empty strings, spaces, tabs,
Unicode, embedded quotes/backslashes, percent/exclamation expansion attempts,
and shell metacharacters), binary output, merged versus inherited stderr,
diagnostic locale, nonzero statuses, missing-command evidence, and the actual
Clang `NUL` predefined-macro/include-search probes. A failed assertion blocks
integration of the renderer. Save its combined output and tool versions.

`winfs_module.c` includes the exact edited `titan-runtime/ltitan_winfs.h`, allowing
native verification before the rest of the Windows runtime loader is available.
Compile as a shared module against the controlled Lua's public headers/import
library, linking `bcrypt`:

```
clang -D_WIN32_WINNT=0x0a00 -std=c99 -Wall -Wextra -Werror -shared spec/fixtures/windows_serial/winfs_module.c -I<lua-include> <lua-import-library> -lbcrypt -o winfs_test.dll
```

The placeholders are the actual selected SDK paths, not system Lua paths.
With matching LuaFileSystem available, run:

```
lua.exe spec/fixtures/windows_serial/verify_filesystem.lua
```

The script tests real exclusive reservations, file/directory ownership, Unicode
and binary I/O, distinct live reservations, replacement, failure preserving the
previous destination, invalid inputs, and cleanup. After the full support image
is built, pass `titan` as its first argument to repeat against that image. An
optional second argument selects an existing writable test workspace (otherwise
the system temporary directory is used). Run first on guest-local NTFS, then
pass the shared workspace as the second argument. An optional third argument
names an existing writable directory on another volume and enables a cross-volume
failure/preservation test using only newly reserved files. Audit final PE imports for Windows OS DLLs plus the controlled Lua;
no toolchain runtime DLL or libuv dependency should arise from these helpers.

The transport oracle also loads this exact `winfs_test.dll` and the compiler's
`io.lua`. Put the matching controlled `lfs.dll` on its module path. It verifies
native executable lookup, missing/directory/invalid-image failures, and exact
public `Sync:run` exit values. An optional fourth argument names an owned copy
held open by the caller with `FileShare.None`; lookup must preserve error 32.
No file permissions need to change for this test.

Run `verify_metadata.lua winfs_test <owned parent> [existing identity fixture]`
on NTFS and the shared volume. It checks full opaque identities, same-ID rename,
different-ID replacement, exact extended realpath spelling, input rejection and
repeated handle cleanup. The optional read-only fixture supplies exact 100ns
timestamps, a >4GiB sparse file, a hardlink and reparse metadata. It reports
junction-follow error 448 and unsupported shared-filesystem cases separately;
those are not successful traversal or retarget tests. Host cdriver regressions
also prove that changing only a low identity bit invalidates a same-time,
same-content header observation.

`verify_driver.lua <private-sdk> <winfs_test.dll> <clang.exe> <owned-parent>`
loads the installed edited compiler from that SDK, checks prefix/source/import
library discovery and DLL candidates, and exercises the real selected Lua child
with an intentionally missing support symbol. It parses nested Unicode headers
and compiles a real C-probe baseline against matching SDK headers. Use a private
SDK prefix with spaces and non-ACP Unicode and run with NTFS and shared parents.
This does not build a complete Titan program, standard library, or language server.
The transport gate also requires an explicit extended executable spelling to
fail clearly rather than be silently converted into another namespace.
