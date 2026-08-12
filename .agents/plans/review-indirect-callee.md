# PR #79 review: foreign indirect-callee sequencing

## Finding

The review finding is valid and is confined to the raw-C lowering used inside a
source-defined `foreign function`.

`coder._foreign_raw_call` currently distinguishes direct foreign declarations
from calls through a C function-pointer value. For the latter it does this at
`titan-compiler/coder.lua:15519-15521`:

```lua
elseif node._c_pointer_call then
    signature = node._c_pointer_call
    callee_stats, callee = coder._foreign_raw_exp(ctx, node.exp)
```

It then freezes all arguments (`:15527-15556`) and only afterwards interpolates
`callee` into the final C call (`:15557`). `_foreign_raw_exp` / `_foreign_raw_var`
return field and subscript reads as expressions such as
`(_foreign_local_holder_1).callback` or
`(_foreign_local_holder_1).callbacks[0]`; they do **not** materialize the value.
Thus an argument that mutates that field/slot runs before the generated C
expression rereads it.

This violates the explicit contract in
`doc/language/foreign-functions.md:181-184`: operands, callees, and arguments
are evaluated once from left to right. It also contradicts the implementation
manual's claim at `doc/implementation/foreign-functions.md:192-202` that a
call's callee is evaluated once before its arguments.

Direct declaration calls are unaffected: their `callee` is an immutable symbol
name. Ordinary Titan-side C pointer calls use the separate
`codecfunctionptrcall`, which already assigns `node.exp` to a temporary before
lowering arguments (`coder.lua:8849-8866`).

## Exact minimal fix

Use the existing sequencing primitive for the indirect branch:

```diff
 elseif node._c_pointer_call then
     signature = node._c_pointer_call
-    callee_stats, callee = coder._foreign_raw_exp(ctx, node.exp)
+    callee_stats, callee = coder._foreign_freeze(
+        ctx, node.exp, nil, "callee")
 else
```

Passing no target preserves the callee expression's exact typedef/function
pointer type (`node.exp._type`) and avoids any needless cast. `_foreign_freeze`
then renders a correct declarator (including typedefs or pointer-to-function
syntax), evaluates the callee exactly once, and returns the temporary name. It
also naturally preserves any prelude needed to evaluate a compound callee.
No checker, AST, or documentation change is required.

Equivalent explicit spelling with `node.exp._type` as the target also works, but
`nil` is smaller and communicates that this is stabilization rather than a
conversion.

## Regression

Extend the existing end-to-end case
`spec/coder/foreign_functions_spec.lua`, preferably the test named
`"uses raw C scalar conditions, pointer truth, and evaluate-once calls"`.
A mutable struct field is the smallest public-behavior regression and directly
matches the review:

Header additions:

```c
typedef int (*ffi_unary_callback)(int);
static int ffi_old_callback(int value) { return 100 + value; }
static int ffi_new_callback(int value) { return 200 + value; }
typedef struct ffi_callback_holder {
    ffi_unary_callback callback;
} ffi_callback_holder;
static ffi_callback_holder ffi_callback_holder_new(void) {
    ffi_callback_holder holder;
    holder.callback = ffi_old_callback;
    return holder;
}
static int ffi_retarget_callback(ffi_callback_holder *holder) {
    holder->callback = ffi_new_callback;
    return 7;
}
```

Titan additions:

```titan
foreign function prepared_indirect_callee(): c.ffi_int
    local holder = c.ffi_callback_holder_new()
    return holder.callback(c.ffi_retarget_callback(holder))
end

function indirect_callee(): integer
    return prepared_indirect_callee() as integer
end
```

Lua assertion:

```lua
assert(test.indirect_callee() == 107)
```

Why it is discriminating:

* Titan selects `holder.callback` first; it must therefore retain
  `ffi_old_callback`.
* The argument mutates `holder.callback` to `ffi_new_callback` and evaluates to
  `7`.
* Correct result: `100 + 7 == 107`.
* Old lowering emits the mutation before
  `(_foreign_local_holder_N).callback(_foreign_arg_N)` and returns `207`, so the
  assertion fails deterministically.
* Fixed lowering emits an `ffi_unary_callback _foreign_callee_N` assignment
  before the argument setup and returns `107`.

I compiled and ran this shape locally against the working-tree compiler: the
old implementation failed the `107` assertion; the two-line `_foreign_freeze`
change passed it.

### Optional array-slot strengthening

The same bug exists for a callee stored in a C array slot. If broader shape
coverage is desired in the same test, make the holder contain
`ffi_unary_callback callbacks[2]`, call
`holder.callbacks[0](ffi_retarget_callback(holder))`, and have the mutation
replace `callbacks[0]`. It likewise returns `207` before the fix and `107`
after it. This is not necessary for the minimal regression because both field
and subscript callees pass through the same indirect branch and the field case
already proves the sequencing invariant. If adding only one, prefer the field
case for readability.

## Scope / validation

Suggested focused command after installing the edited compiler snapshot (or
with working-tree Lua paths explicitly first):

```sh
busted spec/coder/foreign_functions_spec.lua
```

The regression belongs in the coder end-to-end spec, not checker coverage: the
checker already correctly annotates the call with `_c_pointer_call`; the defect
is solely the ordering of emitted C statements.
