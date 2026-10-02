# Experimental native Windows compiler entry

The Windows-only `Makefile.windows.compiler` fragment is included by
`Makefile.windows`. In the approved MSYS2 CLANG64 environment, `compiler`
prepares the controlled Lua SDK, checksummed compiler prerequisites, native
entry point, and Lua compiler modules. `compiler-check` exercises an isolated
copy. These targets do not change the POSIX Makefile or Lua launcher.

The installed layout is `bin/titanc.exe`, `bin/titanc.lua`, the existing
`bin/lua.exe` and `bin/lua-5.5.1.dll`, compiler Lua modules under
`share/lua/5.5`, and `lfs.dll`/`lpeglabel.dll` under `lib/lua/5.5`.
The Lua CLI source remains the repository's `titanc`; the `.lua` suffix avoids
MSYS2's implicit `.exe` filename handling during installation. Module staging
uses the rockspec's existing compiler module map, with no independent list.

The small native adapter obtains its actual executable path, converts the
Windows UTF-16 arguments to UTF-8, and inserts the absolute sibling
`titanc.lua` filename. It delegates to the configured upstream Lua 5.5.1
interpreter front end, linked to the controlled Lua DLL. It retains upstream
Lua environment initialization, script arguments, traceback and exit behavior.
`arg[-1]` identifies the actual `titanc.exe`; `arg[0]` names `titanc.lua`.
Fresh compiler validation processes must select the installed `bin/lua.exe`
explicitly, rather than treating `arg[-1]` as another Lua interpreter.

The executable manifest opts into UTF-8 and long paths and requires no
elevation. Lua's existing executable-relative module-path expansion locates
the modules. The bootstrap neither changes PATH nor spawns a command shell.
The build-time shell and compiler are MSYS2 tools; the delivered launcher and
its two native Lua prerequisites must import only the controlled Lua DLL and
Windows/UCRT DLLs. The PE check rejects other imports, including toolchain
runtime DLLs, and requires the exact public module openers.

Compiler dependencies use the Linux baseline versions: LPegLabel 1.6.2-1,
argparse 0.7.2, inspect 3.1.3 and LuaFileSystem 1.9.0. Their official tagged
archive URLs and SHA256 digests are pinned in
`vendor/windows-compiler/dependencies.tsv`; notices are installed under
`share/titan/0.6/licenses`. LPegLabel here is the separately installed pristine
compiler dependency. Titan's private namespaced PEG engine is a different
provider payload and is unchanged.

After installing these dependencies, the source build writes
`share/titan/0.6/compiler-dependencies.tsv`. Its UTF-8/LF header is
`source_name`, `source_version`, `source_sha256`, `artifact_path`,
`artifact_sha256`, `notice_path`, `notice_sha256`, separated by tabs.
Each of the five installed artifacts has one row; `lpeglabel.dll` and
`relabel.lua` share LPegLabel's source identity and notice. All paths are
relative to the SDK and use forward slashes. The producer rechecks the pinned
archive and prepared-source stamp, compares installed artifacts with the build
outputs or Lua sources, and hashes the installed artifact and notice bytes.
This receipt describes the source build; it is not LuaRocks installation
metadata or a signed attestation. `scripts/windows_compiler_receipt.pl check
PREFIX` verifies the exact receipt and installed bytes against the source
repository's pinned dependency set, without needing downloaded sources.
Direct compiler restaging and standard-library build, validation, and publication
also require this check before doing their work. If the receipt is absent or
stale, rerun `make -f Makefile.windows compiler-deps` with the matching build
root and SDK prefix; consumer commands do not reconstruct provenance from
installed files. The normal `compiler` target already runs that producer first.

`scripts/check_windows_compiler.sh` preserves a private relocated runtime and
its logs and verifies the receipt before and after relocation. It loads all
prerequisites and the Titan parser with an empty PATH,
compares exact arguments with direct Lua (empty strings, quotes, trailing
backslashes, non-ACP Unicode and shell metacharacters), and checks Lua-init,
exit 37 and error/traceback exit 1. `scripts/check_windows_compiler.ps1`
additionally launches that same fixture through native Windows
`System.Diagnostics.Process`, with no MSYS2 process between caller and EXE.
Its `BuildRoot` parameter is the build directory containing
`compiler-check-runtime.txt`. Run it through an already permitted PowerShell
entry point; a blocked script policy is a stop, not permission to change or
work around policy.

These bootstrap gates do not establish a working whole Windows compiler.
Installed-mode detection, runtime/stdlib publication and fresh-process support
validation depend on the other Windows port slices. Actual `.titan`
compilation and Linux regression gates remain required after integration.
