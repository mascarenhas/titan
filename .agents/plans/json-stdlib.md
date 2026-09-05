# JSON standard library (issue #142)

## Scope and delivery

Implement the design in https://github.com/mascarenhas/titan/issues/142 on
`feat/json`, from updated master `b72f5e47`. Complete the module, native tests,
stdlib publication, both manuals, the `titan-json` skill, independent review,
local validation, a PR, and final-head Linux CI. macOS CI is explicitly waived;
do not dispatch it or merge the PR.

## Accepted contracts

- `encode(value, ...EncodeOption): string` and
  `decode(string, reflect.Type?, ...DecodeOption): value`; errors carry stable
  code/message, optional input byte/line/column, and a path.
- Nil maps to null by default. Arrays retain internal holes; decoded trailing
  nulls shorten arrays and null Map entries disappear. Optional nonnil sentinels
  preserve dynamic/value positions; explicit Option/nil targets still use nil.
- Records expose public fields and decode through public synthesized `new`,
  retaining const initialization and explicit argument arity. Private constructors
  fail. Generic erased leaves remain dynamic, without specialization promises.
- Unions use exactly `{"tag":"arm","value":payload}` or `{"tag":"empty"}`.
  Match reflected runtime tags to public variant tags; reject private arms,
  unknown tags, missing/excess payloads and extra envelope fields.
- Use one compiled-once Relabel grammar via public `peg`, anchored to the whole
  document. Use fresh delayed fold accumulators, one Node/Member per reducer
  step, and local zero-result match-time budget guards. No eager child
  materialization, shared mutable accumulator, or per-call stack-setting change.
- Preserve private nonnil parse nodes, source presence/counts and positions until
  conversion. Place committed labels at exact expectations; compute
  `peg.line_column` once on failure. Validate linear recognition/construction,
  wide lists above 32767 children, and a safe depth ceiling under capture and
  matching-stack limits. Select the actual default from measured safe behavior.
- Strict JSON grammar/UTF-8/surrogates; duplicate decoded keys reject. Numeric
  conversion preserves integer range and uses exact decimal normalization for
  integer targets; finite floats format/parse independently of numeric locale.
- New mutable Arrays use value storage and retain its Lua-writer policy;
  later typed reads remain guarded. Const results reject writes.
- Encode active cycles as errors; shared acyclic data is allowed. Enforce
  positive byte/node/depth limits; Map keys are strings and sorted for output.

## Work sequence and ownership

1. Establish shared public/private source contracts, fresh isolated toolchain,
   and focused constructor/fold/numeric/depth probes.
2. Parser owner: PEG/fold parser, exact syntax/Unicode diagnostics, parse tests,
   nesting/wide/scaling evidence. Root owns shared main types and numeric helpers.
3. Decoder owner: reflection-directed/dynamic conversion, constructor/union/
   null/const/generic behavior, mapping tests.
4. Root: writer, options/errors/limits, exact numeric conversion, core tests.
5. Integration owner: shorthand/provider/shim/source/test manifests, installed
   smoke and snapshots, human manuals and skill routing as contracts settle.
6. Create `.agents/skills/titan-json/SKILL.md` for agents, with runnable examples
   and realistic independent evaluations. Keep doc/language human-focused and
   put implementation/complexity mechanics in doc/implementation. Validate
   frontmatter, links, Titan examples, and the routing matrix.
7. Root owns all shared builds. Agents may use private scratch trees against a
   read-only prepared prefix; never overlap checkout-root generated staging.
8. Focused native JSON tests and relevant import/packaging gates, then full
   aggregate stdlib and canonical full mixed suite from the current isolated
   installation. Run standalone/Lua/static smokes and review final source/docs.
9. Commit/push, open PR closing #142 with concrete local evidence, monitor and
   fix all Linux CI checks. Keep the durable session goal active until delivery.

## Validation matrix

- All roots, empty containers, holes/tails/null Maps, sentinels including false,
  typed nullable fields and concrete container holes; source values unchanged.
- Exact error labels/bytes/CR-LF-CRLF columns/EOF; Unicode escapes, control/NUL,
  invalid UTF-8/surrogates, duplicate decoded names and malformed continuations.
- Numeric boundaries, integral fraction/exponents, huge exponents, negative zero,
  nonfinite/overflow/underflow and alternate numeric locale.
- Nested records/unions/const Arrays, public/private/erased boundaries, explicit
  arity with trailing nil, Array Lua-writer behavior, unsupported types.
- Large widths, bounded nesting, warmed doubling-size measurements, fresh folds
  across calls, limit boundaries, cycles versus shared data, GC pressure.
- Exact installed metadata, source/shim inventory, dynamic/static/Lua smoke,
  rollback and relevant sanitizer execution.

## Progress and evidence

- Repository initially clean; switched to master, pulled fast-forward, and
  created `feat/json`. Issue #142 read live and the durable goal created.
- Implementation and local validation are complete; hosted Linux validation follows publication.


### Implementation and focused evidence

- Added the five-source JSON folder module, exact decimal/finite float helpers,
  reflection encoder/decoder, strict labeled PEG folds, and 146 native JSON
  cases. The optimized provider installed successfully; all 146 JSON cases
  passed, including an actual alternate numeric locale.
- Added JSON to the 21-module provider and 25-root aggregate, exact metadata and
  rollback/build inventories, Lua/static production smokes, and focused JSON
  sanitizer gates. Both manuals and the new cartridge/routing are in place.
- Seven separately compiled static examples passed: six manual/cartridge
  examples and one independently generated cartridge-only program.
- Independent numeric oracle: 4,800 cases, zero counterexamples. Integer targets:
  558 successes plus 471 nonintegral and 471 range rejections. Float targets:
  1,156 exact results plus 144 range rejections. Float round trips: 2,000
  bit-identical results, including 254 subnormals and signed zeros.
- Actual public optimized decode, widths 16K/32K/64K/128K: Array no-GC times
  .00878/.01763/.03289/.06888 s and allocations 8151/16279/32535/65047 KiB;
  object no-GC times .0348/.0572/.1179/.2730 s and allocations
  29127/58263/116535/233170 KiB. Late malformed delimiters scaled similarly.
  GC-on object medians .0365/.0806/.2385/.8065 s expose collector overhead;
  do not claim end-to-end timing linearity from the structural parser bound.
- Arrays and objects accept depth 64 and reject 65 with JSON limit_exceeded
  before PEG exhaustion. Default depth is 32, ceiling 64. No PEG stack mutation.
- Canonical `make test` rebuilt the current optimized installation in
  `/tmp/titan-mascarenhas-json`. Its first retained-spec run caught a stale
  sanitizer invocation count (11 rather than 15 after four JSON gates); the
  assertion and exact filter inventory were corrected and passed in isolation.
  A complete unfiltered `luarocks test` then passed: 129 retained build/runtime/
  packaging cases, all four compiler shards (878 + 669 + 740 + 992 = 3,279),
  and 452 aggregate native test entries. No production-source fix was needed.
- The four JSON sanitizer filters select and pass 1/4/1/1 native entries locally;
  actual ASan/UBSan execution remains a hosted Linux gate.
- Bundled production smoke passed, including dynamic Lua, archive/DSO metadata
  parity, static linking with the DSO/shims hidden, and reflected JSON record/
  union reconstruction. The first smoke invocation used regular-file stdout,
  which the OS fixture intentionally rejects; rerunning with pipe output passed.
- Fresh independent final source review found no actionable findings. An
  additional public-provider oracle passed all 1,112,064 Unicode scalar values,
  all 63,488 non-surrogate BMP escapes, 1,024 surrogate pairs, and malformed
  UTF-8 boundary checks for both encoding and decoding.
- Manuals, seven static examples, cartridge schema/links and independent J1/J2
  evaluations passed. The final integration review corrected one stale README
  opener count; `git diff --check` is clean.
- Local work is ready for PR publication. Final-head Linux producer, compiler/
  coverage, and sanitizer checks remain required; macOS is explicitly waived.
