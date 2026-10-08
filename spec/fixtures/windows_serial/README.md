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

`verify_metadata.lua` exercises the compiler's ordinary `compiler_io` strategy
with the selected LuaFileSystem dependency. From the edited checkout, run it
with checkout Lua sources first and a disposable absolute NTFS parent:

```
lua.exe -e "package.path='./?.lua;./?/init.lua;'..package.path" spec/fixtures/windows_serial/verify_metadata.lua <owned-parent>
```

It checks Unicode and binary file I/O, file and directory reservations,
replacement, cleanup, and lexical normalization of existing paths. Windows
metadata comes from LuaFileSystem; its device/inode fields are omitted and its
timestamps have whole-second precision. Windows `realpath` checks existence
and normalizes the supplied spelling without resolving symbolic links. POSIX
physical-path and hardlink-identity assertions remain in `compiler_io_spec.lua`.
The smoke needs no private native helper DLL.

`verify_driver.lua <private-sdk> <clang.exe> <owned-parent>` loads the installed
edited compiler, checks prefix/source/import-library discovery and DLL
candidates, and validates the installed support provider in a fresh Lua process.
It parses nested Unicode headers and compiles a C-probe baseline against matching
SDK headers. Use a private SDK with spaces and Unicode and repeat with NTFS and
shared parents.

`verify_parallel.lua <argv-oracle.exe> <owned-parent>` uses the compiler's stock
luv process adapter. It checks exact argv, binary output, diagnostic locale,
native exit values, and completion order with two children. No private helper
DLL is required.
