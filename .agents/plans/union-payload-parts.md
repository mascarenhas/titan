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

Completed implementation and independent review:

- Parser, checker, codegen, generic erasure, import schemas, reflection/JSON,
  regex/process refactors, and both documentation audiences are implemented.
- Independent compiler and runtime reviews found and resolved constructor
  builtin-name collisions, generic case/catch projection placement, integer
  part-index validation, and named omission metadata through generic erasure.
- Independent stdlib review covered retained wrapper ownership, JSON names and
  discriminator collisions, GC-stressed recursive round trips, and Lua opacity.
- Human documentation and agent skills were reviewed separately. The three
  changed skills passed their structural validator, and the programmer skill's
  complete union example parsed and typechecked.
- Focused checks include 269 parser cases, 242 types/interface/union/generic
  cases, 54 completion/cache cases, 37 imported-interface cases, and the generic
  omission and incremental-link regressions. The original reflection native
  compilation failure is resolved.
- Full-suite attempts identified and corrected old metadata test expectations.
  Old untracked `titan.a` and `titan/uv.a` were preserved outside the checkout
  under `/tmp/titan-union-stale-artifacts`; they shadowed the new installation.
- Final canonical `make -j4 test` passed using the fresh prefix with ambient
  root/CPP/line overrides cleared: 144 host/runtime/packaging checks, four
  compiler shards (816 + 894 + 638 + 1156 = 3504 cases), and all 460 native
  cases. Log: `/tmp/titan-union-parts-final-pass.log`.
- Work is recorded in small topic commits on the feature branch. Local work
  and independent reviews are complete. PR publication and Linux CI monitoring
  remain; GitHub CLI authentication needs renewal (HTTP 401), and the maintainer
  has been notified. Git SSH access works. No macOS workflow was dispatched.
