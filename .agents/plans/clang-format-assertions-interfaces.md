# Clang-format assertion update: `interfaces_spec.lua`

## Changes

- Added a local generated-C whitespace normalizer that collapses runs of whitespace and canonicalizes spacing around C punctuation.
- Applied it only to the six formatter-sensitive Interface cases (formerly starting near lines 74, 752, 938, 1034, 1152, and 1193).
- Retained every semantic assertion: adapter poll/reservation/allocation order, variadic root capacity, no premature native roots, deterministic pair/slot ordering, fresh-wrapper-only rooting, ownership-edge construction order, payload checks, initialization order, and fast-tag runtime behavior.
- Updated the affected literal fragments and Lua patterns to query the canonicalized C text rather than clang-format's line wrapping or pointer spacing.

## Validation

Command:

```sh
/home/mascarenhas/.local/titan/bin/lua /tmp/busted-working.lua spec/coder/interfaces_spec.lua
```

Result: **16 successes / 0 failures / 0 errors / 0 pending**.
