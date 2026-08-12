# FFI wrap-up documentation final review

Status: **complete** on `feature/ffi-wrapup`.

This was a documentation-only pass. It did not change compiler, runtime,
standard-library, or test implementation files.

## Scope reviewed

The review followed the completed implementation rather than the superseded
draft details. The primary authorities were:

* `titan-compiler/{ast,parser,checker,coder,driver,types}.lua` and `titanc`;
* `titan-runtime/titan/ffi.h`, `titan-runtime/titan_coro.c`, and the deleted
  callback-support paths visible in the feature diff;
* `titan/coroutine.titan`, the six callback-bearing `titan/uv` contributors,
  and `titan/http/native.titan`;
* the foreign-function, allocation, header-lifecycle, ABI, libuv, HTTP,
  packaging, cleanup, and sanitizer specs; and
* the earlier frontend, allocation, callback, naming/header, and docs research
  notes under `.agents/plans/`.

## Documentation delivered

### New implementation chapter

`doc/implementation/foreign-functions.md` now records the complete compiler and
native boundary:

1. `Ast.TypeForeignFunction` and `Ast.TopLevelForeignFunc`, their parser
   productions, and lowering into existing `Type.CPointer(Type.CFunction)` /
   `Type.CFunction` representations;
2. signature staging, the restricted raw-C checker context, the closed
   post-check validation walk, explicit Lua-state requirement, and trusted C
   behavior;
3. direct-only source collaboration through `source_members`, binary isolation,
   and the separation between Titan permission and C declarations;
4. exact raw-C lowering, left-to-right freezing of operands/callees/arguments,
   declaration and multiple-assignment sequencing, and control-flow lowering;
5. temporary checking headers, final invocation-wide `*.titan.h` planning,
   ownership/preflight rules, stale generated-header removal, resolver-context
   cleanup, and exclusion from provider publication/installation;
6. target-directed `.new`/`.new_array` storage plans, automatic/owned/hidden-
   owner selection, FAM host-layout extent and logical-count provenance,
   automatic-to-owned copies, and full-backing longjmp spills;
7. coroutine, thirteen-libuv-callback, and eight-llhttp-callback migrations,
   including the five narrow typed `titan/ffi.h` bridges;
8. the C99 `\u2133` module/member separator, C-source versus UTF-8 linkage
   spelling, symbol collision preflight, and the ABI-0.23 boundary.

The paired `doc/language/foreign-functions.md` describes the user-visible
syntax and semantics and both manuals link to each other.

### Index and related-document corrections

Both manual indexes link the new chapters and describe target-directed C
storage rather than claiming every allocation is a Lua allocation. The language
index and grammar identify the 0.23 prototype and the FFI summary distinguishes
ordinary closures from exact source foreign callbacks.

Closely related documentation was reconciled with the completed feature:

* source-import chapters now distinguish use-driven ordinary C origins from a
  direct producer's generated foreign companion and explain checking-time macro
  replay without granting transitive Titan permission;
* driver/folder/provider/static-provider chapters document final header planning,
  canonical folder-main companions, no contributor header, no published or
  installed companion, and the current 0.23 marker/path;
* coroutine, libuv runtime/networking/extension, and HTTP chapters now describe
  source foreign callbacks rather than `titan_coro_entry`, `titan_uv.c`,
  `titan/uv.h`, or `titan_httpshim` trampolines;
* runtime-SDK and provider descriptions now give exactly `titan.o` plus
  `titan_coro.o`, the sole namespaced `titan/ffi.h` support header, and private
  llhttp without an HTTP adapter object;
* C-FFI chapters now cover direct-local allocation selection, FAM scalar
  `.new(count)`, count provenance, automatic lifetime, copies, and spills, while
  retaining the general function-like-macro limitation outside the five typed
  bridges; and
* generated-C examples use the ABI-0.23 `\u2133` top-level function family.
  Historical 0.22 references remain only where they describe that release or
  the preserved predecessor boundary.

## Final invariants checked

* A foreign declaration has no ordinary closure, Lua/strict entry, module-state
  slot, traceback registration, or serialized descriptor.
* A direct source loader capability grants the Titan name; a header include by
  itself does not. DSO/archive metadata cannot carry or forge the source view.
* All final companions are validated and written before object compilation;
  checking temporaries are resolver-owned and removed on close.
* Required companion paths never overwrite an unowned file/symlink/directory;
  stale removal recognizes only the generated banner.
* Code generation consumes checker-owned call/allocation/provenance plans and
  does not infer permission from endpoint types.
* FAM byte extent comes from host `sizeof`/`offsetof`, while `#field` and bounds
  use the separate allocation count only until a raw-pointer cast erases it.
* The standard provider still has eighteen logical metadata keys and nineteen
  DSO openers; foreign callbacks add neither a logical module nor publication
  artifact.
* ABI 0.23 retains Lua 5.5.1 and the 0.22 serialized/module-state layouts but is
  incompatible at the native callback and top-level symbol boundary.

## Validation

Documentation validation performed:

```text
git diff --check                                            -> clean
all doc/*.md fenced-code-block counts                       -> balanced
all new/changed relative Markdown file targets              -> present
all documentation bytes                                     -> no stray controls
stale callback/header/payload grep                           -> only explicit
                                                               "removed/absent"
                                                               statements
current marker/path/version grep                            -> 0.23
```

The updated manual claims were cross-checked against the implementation and
focused spec inventories. No compiler/runtime tests were run for this pass
because it changes documentation only; the feature's implementation tests are
owned by the main wrap-up validation.

## Final result

No remaining documentation blocker was found. Future edits should preserve the
three separations made explicit here: source permission versus C declaration
plumbing, checker-owned allocation plans versus endpoint-type inference, and C
UCN spelling versus UTF-8 linkage spelling.
