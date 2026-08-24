# FFI wrap-up final compiler review

Status: complete on `feature/ffi-wrapup`.

## Scope

Reviewed the parser/checker/coder/driver implementation against
`.agents/plans/ffi-wrapup.md`, with focused attention to raw-C evaluation order,
generated-header ownership and checking-time replay, target-selected automatic
and owned allocation, FAM provenance/copy/spill behavior, and callback-owner
lifetimes in the standard library.

## Finding fixed

The raw foreign assignment lowerer prepared ordinary lvalue expressions with
`_foreign_raw_var`. For an indexed target (and a pointer-based field target),
that left the base/index expression as a later C expression. A right-hand call
could mutate the local or aggregate that selected the target, allowing C's
assignment sequencing to write through the post-call target rather than the
Titan source-order target. `coder._foreign_raw_lvalue` now recursively prepares
pointer bases and index operands before any right-hand value. The regression in
`spec/coder/foreign_functions_spec.lua` mutates both a struct-held pointer and a
struct-held index from the right-hand call and proves the original target is
used.

The complete compiler group initially also exposed a stale pre-wrap-up test that
used `ffi_row.new_array(2)` (where `ffi_row` is a C array typedef). The completed
allocation matrix permits that positive-literal, direct-sink nested automatic
case while continuing to reject `.new()`, dynamic/owned array-typedef payloads,
and all FAM `new_array` cases. Eligibility and documentation were reconciled,
and an end-to-end nested-array regression was added.

## No remaining blocker found

* Restricted foreign declarations remain direct C declarations and source-only
  capabilities; they add no module slot, closure, metadata, or Lua entry.
* Calls, operands, declaration values, assignment targets, and assignment values
  are frozen in Titan source order before C evaluates the final operation.
* Generated dependency headers are replayed in the consumer checker/cprobe
  environment in emitted order; final companions are planned before occupied
  output validation, written before object compilation, and removed only with
  the exact ownership banner.
* Allocation plans are checker-owned and sink-specific. Automatic block storage,
  hidden owner roots, automatic-to-owned copies, FAM count provenance, and
  full-backing longjmp spill/reload stay distinct.
* Long-lived libuv/llhttp/minicoro objects in standard sources use explicit
  owners; callback protocols root their owner and restore the Lua stack.
* Runtime/archive payload and ABI symbol/path assertions match the retired
  callback shims and new `\u2133` entry family.

## Validation after review

* `spec/coder`: 828 passing.
* frontend/checker/parser/types/driver/C-parser group: 1642 passing.
* `spec/support/ci_test_groups.sh compiler`: passing.
* `make stdlib-test`: 186 native tests passing.
* `make test`: passing.
* `git diff --check`: clean.
