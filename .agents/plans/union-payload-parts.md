# Named union payload parts

## Agreed contract

- Preserve `variant(T)` as sugar for `variant(value: T)`. Select named declarations
  with positive `AnyName COLON` lookahead; accept reserved part names, reject
  flextails and mixed named/unnamed lists, and commit diagnostic labels.
- Direct constructors accept positional or named arguments through ordinary
  argument adjustment, including omitted nil values and implicit conversions.
- Parenthesized case binders select a prefix. Curly binders select arbitrary
  parts; `alias = part` puts the local alias on the left. Locals use Name,
  selected parts use AnyName; unknown parts are checker errors and repeated
  selected parts are syntax errors. Any part may be omitted from matching.
- Store the tag in direct Udata `uv[0].uv` and part i in `uv[i].uv`; use existing
  internal conversion/rooting/barrier machinery, never Lua API uservalue access.
- Extend reflection descriptors and indexed part inspection. Remove stdlib
  variant-wrapper records where they have no independent semantic ownership;
  retain reused types and records owning methods or mutable state.
- JSON encoding and decoding use a flat discriminator-plus-named-parts object.
  Legacy unnamed values naturally retain the `value` field. Add encoder and
  decoder `tag_field(name)` options, default `tag`, so callers can avoid payload
  name collisions; collisions with the selected discriminator are errors.
- Keep Titan compiler version, ABI, and language-server API marker unchanged.
- Update language/implementation manuals and agent skills for their audiences.
- Work on `feature/union-payload-parts`; finish local validation and independent
  code/documentation review, open a PR, and monitor Linux CI. Never dispatch
  macOS CI; do not merge the review PR.

## Implementation and validation

1. Parser/AST, checker/types/import serialization, direct runtime access and
   generic lowering; focused parser/checker/coder/metadata regressions.
2. Reflection/JSON migrations and native tests; regex and process wrapper audit.
3. Human/agent docs, stale-contract sweep, independent implementation and
   audience-aware documentation reviews.
4. Fresh `/tmp/titan-union-parts-20260917` prefix; canonical full `make test`
   with no ambient root/CPP/line overrides; production-provider validation.
5. Commit, push, PR, Linux CI monitor/fix loop; final report with evidence.

Initial focused checks: parser 269 passed; checker/named/generics 99 passed
before new cases; additional union checker cases pass; types/interface 155 passed;
all 19 coder-union cases verified across full and focused runs. Canonical full
validation and independent reviews remain required.
