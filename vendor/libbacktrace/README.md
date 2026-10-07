# Windows libbacktrace

The Windows source build uses upstream libbacktrace revision
`0b9b49cf4a2c9229fc052d6716e1528b2f23e91a`, with the exact archive and SHA-256
recorded in `dependencies.tsv`. The archive includes upstream's generated
`configure`; no regeneration or handwritten configuration header is used.
The Unix acquisition route is independent.

`libbacktrace-0b9b49c-windows-images.patch` changes only the PE/COFF backend:

- COFF symbols are RVAs, so their addresses use the actual loaded image base.
  DWARF addresses keep upstream's preferred-to-loaded relocation delta.
- Each module's final symbol range ends at that image's section extent. An
  executable's last function must not match arbitrary addresses in later DLLs.
- A successfully read DLL with DWARF supplies the shared file/line dispatcher
  even when the main executable has no debug data. Modules without DWARF never
  replace that dispatcher. Upstream otherwise leaves a stripped Lua host's
  `coff_nodebug` dispatcher active despite having read its Titan DLLs' DWARF.
- Persistent DLL-loader notification registration is removed. Upstream's
  callback parses files while the Windows loader is notifying modules, retains
  a caller's transient callback data, and discards its registration cookie.
  Titan instead invalidates its shared snapshot after ordinary provider loads;
  the next capture enumerates the current modules outside that callback.

Microsoft's [loader notification contract](https://learn.microsoft.com/en-us/windows/win32/devnotes/ldrdllnotification)
forbids calls into other modules from the notification callback. The original
[PE implementation](https://github.com/ianlancetaylor/libbacktrace/blob/0b9b49cf4a2c9229fc052d6716e1528b2f23e91a/pecoff.c)
contains the affected symbol ranges, image-base selection, and notification
registration. Toolhelp module enumeration remains unchanged.

The ordinary configure/make build produces a static archive and installs its
matching headers into the selected Lua SDK. `-static-libgcc` selects LLVM's
static unwinder in CLANG64; consumer links use the same policy, avoiding an
additional compiler-runtime DLL. Clean the private build directory before
changing tools, flags, or profiles. Delete the acquired source directory before
changing the pinned archive or patch.

Native validation must separately prove PC-to-source and PC-to-symbol results
for relocated executable/DLL images and a provider loaded after an earlier
capture, including a main executable without DWARF and debug-enabled DLLs,
then prove Titan's interleaved Lua/native traceback. Upstream's ANSI
image filenames and `MAX_PATH` buffers remain unchanged by this patch.
