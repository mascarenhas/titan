# Vendored uwasi

This directory contains the TypeScript sources of the WASI filesystem that
Titan's browser storage runtime is generated from.

- Upstream: <https://github.com/swiftwasm/uwasi>
- Release: `1.6.0`
- Commit: `11b4ebf5fef47d49eb7da8a9d21483cf921e1a6c`
- Commit date: `2026-10-28T07:19:50+09:00`
- License: Apache License 2.0 (`LICENSE`, also `LICENSES/uwasi-LICENSE`)

## Imported upstream files

```text
LICENSE
src/abi.ts
src/options.ts
src/filesystem/backend.ts
src/filesystem/content.ts
src/filesystem/error.ts
src/filesystem/handlers.ts
src/filesystem/index.ts
src/filesystem/namespace.ts
src/filesystem/stdio.ts
src/memory/backend.ts
src/memory/index.ts
src/opfs/backend.ts
src/opfs/format.ts
src/opfs/index.ts
```

No upstream feature provider other than the filesystem is imported: the
image's factory (`titan-runtime/browser/titan-wasm-factory.mjs`) keeps the
clock, environment, random and exit imports, and the storage worker supplies
the few its SQLite service needs.

## Generated JavaScript

`scripts/build_uwasi_bundle.mjs` strips the types with Node's built-in type
stripping, lowers constructor parameter properties (the one construct
stripping refuses), and joins the modules reachable from
`src/filesystem/index.ts` into one function scope. It writes that bundle
between the `uwasi` markers of `titan-runtime/browser/titan-browser-vfs.mjs`,
and the bundle with `src/opfs/index.ts` between those of
`titan-runtime/browser/titan-storage-worker.mjs`. Module names in the output
are POSIX paths below `src/` on every host, so the bytes do not depend on the
path separator. The checked-in files are the build inputs of the browser SDK,
so no TypeScript toolchain, bun or npm runs there. After changing a file here:

```sh
node scripts/build_uwasi_bundle.mjs          # rewrite the generated regions
node scripts/build_uwasi_bundle.mjs --check  # fail when they are stale
```

## Local seams

Each change is marked `Titan seam` in its file.

- `src/filesystem/namespace.ts`: `MemoryFileSystem` takes `NamespaceOptions`.
  `allocateIno` numbers inodes from a caller's sequence, so the guest (even
  numbers) and the storage worker (odd numbers) mirror one tree in which an
  inode number names the same node on both sides; `devices: false` omits
  `/dev` and `/dev/null`, which a durable mount must not show.
- `src/filesystem/handlers.ts`: `bindFSSyscallsWithController` returns the
  syscalls with an `FdController` over their descriptor table: the node a
  descriptor refers to, and `fd_close` for a host that retires a descriptor
  without a guest call. `bindFSSyscalls` keeps its signature.
- `src/filesystem/backend.ts` and `src/filesystem/handlers.ts`: optional
  `FSBackend.setTimes(node, atim, mtim)` hook invoked by `resizeFile`,
  `writeIovecs`, and `applyTimes` with the exact timestamp values assigned by
  the syscall (`undefined` for omitted fields), so `StorageBackend` replicates
  exact timestamps and explicit `utimensat`/`futimens` updates in causal order.
- `src/filesystem/index.ts`: exports `NamespaceOptions`,
  `bindFSSyscallsWithController` and `FdController`.
- `src/opfs/backend.ts`: `ExclusiveOPFSBackend.create` passes a `namespace`
  option to its filesystem, and `flushHandle(node)` flushes one file's sync
  access handle, as `fd_sync` does, for the worker's durability barriers.

## Imported-file SHA-256

The digests of the pristine upstream files, before the seams:

```text
c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4  LICENSE
0457b11227ef6f30d4460463665611bd705970b89fcc2d20e98a2a1260269a4a  src/abi.ts
88d2886f6149174be2583965c765dab1c0c7060a69c5937e2295b31b6f0949ce  src/options.ts
b11cecd8eee78c1e08b911aa0cd41e0603202d1b00d0f28ee40b831193ab75f8  src/filesystem/backend.ts
73395ea01c5ed98316a6250108bf672ea301e8fd5b9ace4fe1484c96842c64ec  src/filesystem/content.ts
8fb3bab2d7ce8f10e0d303a8532e60c8a9a33bde8c05f77cad9161b6f59abe38  src/filesystem/error.ts
9d5e5c590e3c9f3353c1aec762f18524df8ea9c38bd01203171030754956ecd3  src/filesystem/handlers.ts
ad63218d99a695c52a5e7cad8142773e75a325a7a062372a093bb3df0cf6776c  src/filesystem/index.ts
6c455a23a47c41f28bac06bcf474f3f0de69cc6aa98084cdf3462eaf577a2d61  src/filesystem/namespace.ts
de474f8362ac4087c15150c9c35357036deeab73f1684bb63caad10552fdc69b  src/filesystem/stdio.ts
13420f32b481a952a7d93d880df5e9525e3fa430bb63619f9569efe934f2aa18  src/memory/backend.ts
0c37e10f60b59275a5b9c5ac542dbcffbd2c74a718132893d752a9813053d91f  src/memory/index.ts
3b20f33cb66acb052c3e5e25834938189ee2536de2e5637fc652943020f77759  src/opfs/backend.ts
dbac169726d5b7630b73e689f227ea4e888a7edbf611d9b88b69bcfdb2a50bf3  src/opfs/format.ts
984af38bfd7a435b2be8d2d67543cab22606d7b4ed079820aa688e33180e390f  src/opfs/index.ts
```

## Verification

```sh
WASI_SDK_PATH=... node --test spec/browser/vfs-unit.test.mjs
```

The suite checks that the generated regions are current, runs a wasi-sdk C
guest's POSIX checks over the guest filesystem, and drives the storage worker,
its OPFS stores and its SQLite service end to end.
