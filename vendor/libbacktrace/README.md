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

`libbacktrace-0b9b49c-alloc-growth.patch` changes the malloc-backed vector
allocator selected by Windows. After its initial allocation, vector capacity
grows geometrically instead of adding 4 KiB at a time. Large DWARF line tables
therefore require an amortized linear amount of copying when realloc moves
blocks. Checked addition and multiplication prevent capacity wraparound;
allocation failures leave the vector's existing bytes and bookkeeping intact.
The patch also preserves the allocation on a failed shrink, so the caller can
free it, and retains free semantics for zero-used vectors. The Unix mmap
allocator is unchanged.

Source preparation recognizes only the exact original and patched `alloc.c`
digests. A completed archive-only source stamp from an earlier build is
upgraded after its pinned archive identity and existing image patch are checked.
The separate allocator patch is applied and reverse-checked before its source
receipt is published. Already patched sources and matching receipts keep their
bytes and mtimes on repeated preparation. Unknown allocator bytes are rejected;
they are not overwritten or accepted as a new baseline. Other completed native
dependency source trees retain their existing preparation behavior.

The ordinary configure/make build produces a static archive and installs its
matching headers into the selected Lua SDK. `-static-libgcc` selects LLVM's
static unwinder in CLANG64; consumer links use the same policy, avoiding an
additional compiler-runtime DLL. Clean the private build directory before
changing tools, flags, profiles, or source directories. An existing generated
Makefile must resolve to the same physical source directory as the selected
source; a mismatch is rejected before building or publishing a receipt rather
than silently reconfiguring. A verified allocator source receipt owns a
separate build digest: a missing or changed digest invalidates only allocator
objects and the archive, even if the source mtime was restored. The build receipt
is published after a successful archive build and a second source check; failed
builds retain the previous receipt. Delete the acquired source directory and
private build directory before changing the pinned archive or image patch.

The retained Busted cases in `spec/libuv_build_spec.lua`, reached by ordinary
`make test`, exercise source preparation and build receipts in temporary trees.
They also compile the exact verified `alloc.c` with a deterministic moving
allocator at O0 and O2, checking growth/copy bounds, contents, alignment,
zero-size behavior, overflow, and grow/shrink/finish failure cleanup. On Unix
this harness forces the heap backend while the ordinary installed archive
continues to use mmap. These host controls require the canonical prepared Unix
source/configuration; native CLANG64 runs separately prove the actual Windows
allocator with its generated configuration.

Native validation must separately prove PC-to-source and PC-to-symbol results
for relocated executable/DLL images and a provider loaded after an earlier
capture, including a main executable without DWARF and debug-enabled DLLs,
then prove Titan's interleaved Lua/native traceback. Upstream's ANSI
image filenames and `MAX_PATH` buffers remain unchanged by this patch.
