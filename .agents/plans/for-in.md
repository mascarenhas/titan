# Generic `for ... in` loops

## Informal source

This plan expands `/tmp/for-in.md`. The requested surface syntax is:

```lua
for <decllist> in <explist> do
  <block>
end
```

The loop evaluates `<explist>` once into an iterator tuple:

```lua
next, ctx, init, close
```

The loop then repeatedly calls `next`, stops when the first returned value is
`nil` (or `NULL` for a nullable C pointer control), binds the visible
declarations from the returned values, runs the body, and calls `close` exactly
once when a non-nil close function was supplied. A close function may take zero
arguments or the state/context argument.

## Language semantics

### Iterator tuple

`<explist>` is a fixed four-slot context:

1. iterator function, required;
2. state/context value, nil-filled when omitted;
3. initial control value, nil-filled when omitted;
4. close function, nil-filled when omitted.

The last expression in `<explist>` expands if it is a multi-return call, just as
in local declarations and assignments. If fewer than four values are produced,
the missing slots are filled with `nil`. Extra tuple values are a compile-time
arity error.

The iterator expression must resolve to a callable shape: a function type, a
`value` coerced to a synthesized function type, or a compatible C
function-pointer/foreign-function signature. Its return list must contain at
least one value; the first return is the control value used for termination. The
first return must be nil-capable and still have a usable present value: an
option type, `value`, a nullable C pointer, or a raw C `TValue`. A nil-only
first return is rejected because it has no base value from which to type the
first visible loop declaration.

The close slot may be statically `nil` or one of the same callable shapes. A
statically `nil` close slot emits no cleanup code. For a close slot that
originated as `value`, run-time nil means that no close was supplied and skips
the call; every non-nil value uses the ordinary callable path. A non-nil close
function is called once after the iterator tuple has been created and the
protected loop region is entered. The call uses zero arguments when the close
type has no parameters, otherwise it passes the state/context argument. That
protected region includes the initial iterator call, all body executions, and
update iterator calls, so close runs on initial-call failure, update-call
failure, normal exhaustion, `break`, `return`, and `raise`. If close itself
raises, that raise replaces the pending action just like an explicit `finally`
raise.

### Iterator calls

The conceptual Lua-style call is:

```lua
ctrl, extra... = next(ctx, previous_ctrl)
```

Titan function calls are strict about surplus arguments, while the informal spec
also gives a one-argument iterator example:

```lua
local read_console_lines = function (_: nil): string?
for line: string in read_console_lines do ... end
```

To support both the Lua-shaped two-argument iterator and the shorthand example,
the checker calls the iterator with the number of fixed parameters its type
declares, up to two:

- zero parameters: `next()`;
- one parameter: `next(ctx)`;
- two parameters: `next(ctx, ctrl)`;
- more than two fixed parameters: compile-time error.

The second argument is `init` for the initial call and the previous control
value for subsequent calls. The hidden control value remains nil-capable because
it drives termination. After the nil test succeeds, the update call uses a
synthesized force/cast of the current control value to the iterator's second
parameter type. This is what lets an iterator typed
`(State, integer) -> integer?` use a nil-capable sentinel result while receiving
plain `integer` controls on the next step.

### Visible loop variables

The declarations in `<decllist>` are scoped only inside the loop body. They are
read-only loop variables, like numeric `for` control variables. Each iteration
gets fresh visible declaration storage; closures capture the value for that
iteration, not one reused cell that later changes.

The first visible declaration is initialized from the non-nil control value. For
an option control result, an unannotated first declaration infers the option's
base type rather than the option type. For a `value` control result, inference
keeps `value`, since `value` has no narrower base type. A typed first declaration
is checked against the corresponding initializer type.
Additional declarations are initialized from the corresponding iterator return
values. They follow local declaration rules:

- annotated declarations coerce/check against the annotation;
- bare `?` declarations infer and optionize;
- unannotated declarations never infer an option type and force option returns.

If the iterator returns fewer values than the declaration list needs, missing
visible variables are filled with `nil` only when their declaration can accept
nil; otherwise the loop is rejected.

The termination test is "first return is nil", not general truthiness. A
`boolean?` control value may therefore use `false` as a real loop value and `nil`
as the sentinel.

## Implementation plan

### Parser and AST

- Add `Ast.StatForIn = {"loc", "decls", "exps", "block"}` in
  `titan-compiler/ast.lua`.
- Factor the `FOR` statement grammar in `titan-compiler/parser.lua` so numeric
  and generic forms share the `FOR decl` prefix without a labeled numeric failure
  swallowing the generic form.
- Parse:

  ```peg
  forstat <- P FOR decl forrest
  forrest <- ASSIGN exp COMMA exp (COMMA exp)? DO block END -> StatFor
           / forinrest
  forinrest <- decltail IN explist DO block END -> StatForIn
  decltail <- ...
  ```

  The exact grammar helper may differ, but it must preserve labeled errors for
  malformed numeric loops and produce clear labels for malformed generic loops.
- Add syntax labels for generic-specific failures, at least `InFor` and
  `ExpForIn`; reuse or add `DoForIn`/`EndForIn` depending on parser shape.
- Add parser specs for single, typed/multiple, and ambiguity-preserving numeric
  loops, plus malformed generic loops.

### Checker

- Add a `checkforin` helper and a `StatForIn` visitor in `checker.lua`.
- Add an explicit for-in tuple elaboration helper. Ordinary Titan declarations
  still reject short right-hand sides, and ordinary calls only nil-fill missing
  arguments; for-in tuple setup is the new fixed four-slot context required by
  this feature.
- Type `<explist>` as a four-slot iterator tuple:
  - check static expressions left-to-right;
  - expand trailing multi-return calls;
  - adjust trailing `...` through synthesized `ExpDotsIndex` reads, using the
    shared fixed-slot vararg adjustment path;
  - append synthetic `ExpNil` nodes to four slots;
  - reject extra tuple values;
  - coerce/check missing nils only where the target slot type is known.
- Validate the iterator function:
  - must be `Type.Function`, `value`, or a C function pointer/foreign function;
  - fixed parameter count must be 0, 1, or 2;
  - first return must exist and be nil-capable.
- Infer/check state, initial control, and close from the tuple and iterator
  parameter/return types:
  - state must match iterator parameter 1 when present;
  - initial control must match parameter 2 when present;
  - subsequent control uses the non-nil/base control value and must match
    parameter 2 when present;
  - close must be `nil` or a callable accepting zero parameters or the state
    value. Any close return values are discarded, matching Titan's
    statement-position calls.
- Synthesize checked hidden call ASTs for the initial and update iterator calls.
  Reuse the normal `ExpCall`/`ExpExtra` machinery so exact Titan function values,
  generic Lua-callable values, coercions, C function-pointer calls, and
  multi-return storage stay on the existing path.
- Elaborate visible declaration initializers from the iterator return tuple.
  The first declaration forces option controls to their base type, while `value`
  controls stay `value`; other declarations follow local declaration rules.
- Declare visible loop variables only in the loop body scope and mark them
  `_forcontrol = true` so assignments are rejected.
- Increment `loop_depth` while checking the body so `break` is legal.
- Treat the loop as containing an implicit finally when the close slot is not
  statically `nil`; this must be visible to codegen prepasses for spill analysis
  and entry error-jump save emission.
- Hidden iterator tuple locals live outside the protected region so the implicit
  cleanup can reference them. The loop frame must be opened before the implicit
  close-finally frame so `break` targets the loop and still routes through close.

### Code generator

- Add prepass support for `Ast.StatForIn` anywhere `StatFor` is currently known:
  `collect_reads_stat`, `collect_writes_stat`, `analyze_try_spills_block`,
  `stat_contains_try`, and `is_terminator` handling where needed.
- Add `codeforin` in `coder.lua`.
- Evaluate the iterator tuple once into hidden C locals and anchor GC-able hidden
  values in Lua stack slots.
- Emit the initial iterator call before the loop. Store the first return in a
  hidden control variable and extra returns in hidden temps, anchoring GC-able
  results.
- Emit a loop frame with the existing `open_loop`/`close_loop` machinery so
  `break` across protected regions works like it does for `while` and numeric
  `for`.
- When close is present, open the loop frame before the implicit finally frame.
  The protected region starts after tuple evaluation and contains the initial
  iterator call, the loop, and update calls. Hidden tuple locals are declared in
  the surrounding C scope so close can read them.
- Terminate with a nil test on the hidden control value, not `toboolean`.
- At each iteration, declare/update visible loop variables from the hidden
  result tuple using fresh per-iteration storage, then run the body, then call
  the iterator again using the hidden previous control value forced to the update
  parameter type.
- If `close` is statically nil, emit no cleanup wrapper. If close is present,
  run the loop body inside the existing `StatTry`/finally machinery or an
  equivalent code path that preserves the same `return`/`break`/`raise`
  semantics. A non-nil close call must execute once on all exits and must not
  execute before the iterator tuple is fully initialized; a `value` close is
  guarded against exact nil inside that implicit finally.
- Add GC polling after loop iterations when the loop body or iterator calls
  allocate, matching `while` and numeric `for`.

### Tests

Parser:

- `for x in iter do ... end` parses as `Ast.StatForIn`.
- `for k: integer, v: string in next, ctx, init do ... end` records decls/exps.
- Numeric `for i = 1, 10 do ... end` remains `Ast.StatFor`.
- Malformed generic loops produce stable syntax labels.

Checker:

- accepts a one-value tuple and nil-fills state/init/close;
- accepts a four-value tuple with close;
- accepts value and C function-pointer iterators/closers where the synthesized
  or C signature works;
- rejects non-callable iterators;
- rejects iterators with no return value;
- rejects non-nil-capable first returns and nil-only first returns;
- rejects too many iterator fixed parameters;
- rejects mismatched state/init/control types;
- rejects mismatched declaration types and missing non-optional returns;
- rejects assignment to generic-for variables;
- allows `break` inside the body and rejects `break` outside loops as before.

Coder/runtime:

- sums/concatenates values from a simple one-argument iterator;
- supports two-argument state/control iterators;
- stops only on nil, not false;
- close runs on normal exhaustion;
- close runs on initial iterator-call failure;
- close runs on update iterator-call failure;
- close runs on `break`;
- close runs on `return`;
- close runs on `raise` before the error propagates;
- close raise overrides pending `break`, `return`, and body/iterator raises;
- statically nil close emits no runtime close call;
- a missing or explicit nil `value` close skips the call without replacing a
  pending `break`, `return`, or raise;
- a non-nil `value` close retains ordinary callable checks and error override
  behavior;
- zero-parameter close functions work;
- exact Titan function-value iterators and generic Lua-callable iterators both
  work where existing call machinery supports them;
- C function-pointer/foreign-function iterators and closers work where the C
  signature and nullable control result satisfy the checker;
- GC-sensitive tests exercise option/string/record iterator values and close
  under incremental and generational collectors where practical.
- closure tests prove per-iteration captures keep distinct loop values.

### Documentation

- Update `doc/language/statements.md` with a generic `for` section and remove
  stale "there is no `for ... in`" wording.
- Update `doc/language/grammar.md` reserved-word and statement grammar text.
- Update `doc/language/index.md` capability summaries.
- Update `doc/implementation/lexer-parser.md` and
  `doc/implementation/ast-typedecl.md` for the parser/AST addition.
- Update `doc/implementation/checker.md` for iterator tuple elaboration,
  nil-fill, visible-variable narrowing, and implicit close/finally handling.
- Update `doc/implementation/codegen-constructs.md` for `codeforin`, hidden
  locals, nil termination, and close cleanup.

### Verification and delivery

- Run focused parser/checker/coder specs while developing.
- Rebuild/install the current rock before final broad tests.
- Run `make test` as the local gate.
- Run `git diff --check`.
- Use subagents for plan review, code review, and documentation review.
- Commit on a feature branch, push, open a PR, and verify Linux and manually
  dispatched macOS GitHub Actions are green.
