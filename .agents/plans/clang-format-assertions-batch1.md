# clang-format assertion batch 1

Updated only the seven assigned coder specs. The generated-C checks now tolerate
clang-format line wrapping, pointer-star placement, and statement indentation
while retaining their substantive checks for:

- GC identity casts and unsafe out-value reanchoring order;
- direct/first-class receiver temporaries before Lua transport;
- finite versus `LUA_MULTRET` call behavior and caller-top repair;
- exact DSO load/symbol ownership, including negative no-reopen checks; and
- union payload representation, tag dispatch, userdata sizes, and GC barriers.

## Validation

Each full spec passed via
`/home/mascarenhas/.local/titan/bin/lua /tmp/busted-working.lua <spec>` with the
checkout module path supplied by the wrapper:

- `c_ffi_owned_types_spec.lua`: 11 successes
- `c_ffi_pointer_conversions_spec.lua`: 6 successes
- `closures_spec.lua`: 42 successes
- `first_class_functions_spec.lua`: 37 successes
- `flexible_returns_spec.lua`: 26 successes
- `so_import_spec.lua`: 20 successes
- `unions_spec.lua`: 14 successes

All had zero failures, errors, or pending cases. Earlier overlapping checkout
runs had poisoned two ccache entries by replacing `test.c` during compilation;
I repaired those entries with a serial `CCACHE_RECACHE=1` pass, then reran all
seven normally with the commands above.
