# PR #79 review: foreign floating `for` step zero

## Finding

The review finding is valid on `feature/ffi-wrapup` at `f274b9d`.

`checkfor` in `titan-compiler/checker.lua` accepts C integer and C floating
controls inside a source-defined `foreign function`.  Its literal-step guard is
currently:

```lua
local literal_step = checker._allocation_integer_literal(node.inc)
if literal_step == 0 then
    checker.typeerror(..., "... requires a nonzero step")
end
```

`checker._allocation_integer_literal` strips only `ExpCast`/`ExpAdjust` and
returns a value only for `Ast.ExpInteger`.  Therefore an `Ast.ExpFloat` holding
`0.0` is never diagnosed.  I reproduced these current results:

* `for i: c.ffi_int = 0, limit, 0 do ... end` -> rejected;
* `for i: c.ffi_double = 0.0, limit, 0.0 do ... end` -> accepted;
* inferred `for i = 0.0, 1.0, -0.0 do ... end` -> accepted.

The consequence is real rather than merely inconsistent validation.
`coder._foreign_raw_stat` lowers the loop to a raw C `for` whose condition is
selected with `step >= 0` and whose increment is `control += step`.  Unlike an
ordinary Titan numeric loop, this raw foreign-body path deliberately has no
Lua/Titan error machinery and no run-time zero check.  If the initial bound is
satisfied, `+0.0` never advances and loops forever.

This also matches the already-documented contract in
`doc/language/foreign-functions.md` and
`doc/implementation/foreign-functions.md`: a *literal* zero is rejected, while
a dynamically computed zero remains a trusted unsafe-C precondition.  No
manual change is needed.

## Signed zero is relevant

`-0.0` must be covered.  It compares equal to zero in both Lua (where the
checker runs) and C; in the generated C, `-0.0 >= 0` is true and adding it does
not advance the control.  The parser represents the spelling as
`Ast.ExpUnop("-", Ast.ExpFloat(0.0))`, so merely adding `Ast.ExpFloat` to the
existing leaf test would still miss it.  The same AST-shaped hole exists for
`-0` in a C-integer loop.

## Exact fix

Add a dedicated literal-zero predicate near
`_allocation_integer_literal`, and use it only for the foreign numeric-loop
guard.  Do **not** broaden `_allocation_integer_literal`: its other callers use
its integer-only return as an allocation/FAM count.

The predicate should recursively strip only the syntax that can still denote a
written numeric literal:

```lua
local function numeric_literal_is_zero(exp)
    if not exp then return false end
    local tag = exp._tag
    if tag == "Ast.ExpCast" or tag == "Ast.ExpAdjust"
       or (tag == "Ast.ExpUnop" and exp.op == "-") then
        return numeric_literal_is_zero(exp.exp)
    end
    return (tag == "Ast.ExpInteger" or tag == "Ast.ExpFloat")
        and exp.value == 0
end
```

Then replace the current value-returning check with:

```lua
if numeric_literal_is_zero(node.inc) then
    checker.typeerror(errors, node.inc.loc,
        "a numeric for loop inside a foreign function requires a nonzero step")
end
```

`exp.value == 0` catches either floating zero sign if a parser ever stores the
sign directly, while the `ExpUnop("-")` recursion handles today's AST.  Keep
the predicate narrow: do not fold binary constant expressions or inspect a
variable initializer.  For example, `local step = 0.0; ... step ...` remains
the documented trusted dynamic precondition.  Do not add a coder-side run-time
guard to the raw foreign function.

## Focused regressions

### Checker: `spec/checker/foreign_functions_spec.lua`

Extend `"diagnoses non-scalar conditions and invalid C numeric loops"` with
separate `assert_rejected` calls, each requiring the existing
`"requires a nonzero step"` diagnostic:

1. A contextual C-double positive zero (the exact review regression):

   ```titan
   foreign function bad(limit: c.ffi_double): ()
       for i: c.ffi_double = 0.0, limit, 0.0 do end
   end
   ```

2. An inferred C-double negative zero, avoiding any unrelated typedef/exact
   match behavior and proving traversal through unary minus:

   ```titan
   foreign function bad(): ()
       for i = 0.0, 1.0, -0.0 do end
   end
   ```

3. Small adjacent coverage for signed integer zero is worthwhile because the
   same predicate fixes that existing hole:

   ```titan
   foreign function bad(): ()
       for i = 0, 1, -0 do end
   end
   ```

Keeping these as separate checks ensures each spelling independently produces
the intended diagnostic rather than merely observing that a multi-function
fixture had some error.

### Coder: `spec/coder/foreign_functions_spec.lua`

Add a focused successful end-to-end case for nonzero C floating loops in both
directions.  This covers the previously unexercised float branch of foreign
numeric-loop lowering and proves that traversing unary minus in the new
predicate does not reject every negative step.  Use exactly representable
binary fractions to avoid a tolerance distraction, for example:

```titan
local c = foreign import "<header defining typedef double ffi_double>"

foreign function float_loops(): c.ffi_double
    local total: c.ffi_double = 0.0
    for up = 0.0, 1.0, 0.25 do
        total = total + up
    end
    for down = 1.0, 0.0, -0.25 do
        total = total + down
    end
    return total
end

function result(): float
    return float_loops() as float
end
```

The Lua assertion is `assert(test.result() == 5.0)`.  I verified this fixture
passes on the current branch.  Literal-zero rejection itself belongs in the
checker suite; a coder run with zero would either be rejected before codegen
after the fix or risk hanging before it.

Suggested focused validation (after reinstalling the edited compiler snapshot):

```sh
busted spec/checker/foreign_functions_spec.lua \
  --filter='invalid C numeric loops'
busted spec/coder/foreign_functions_spec.lua \
  --filter='floating numeric loops'
```

## Adjacent observation (not required for this finding)

With an explicitly typedef-annotated control, a unary negative literal such as
`for i: c.ffi_double = 1.0, 0.0, -0.25` currently reports an exact-type mismatch
(`ffi_double` versus `double`) because `_foreign_literal` is on the inner
`ExpFloat`, not the outer `ExpUnop`.  The inferred-control coder regression
above deliberately avoids conflating that separate contextual-literal issue
with zero detection.  If typed negative steps are addressed later, propagate
foreign literal context through unary minus and add its own checker case.
