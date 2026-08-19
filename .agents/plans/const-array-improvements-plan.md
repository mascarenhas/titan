# Implementation Plan: Const Array Improvements (`const?` Arrays & Linear Return Analysis)

This plan details the design and implementation for two complementary const array features in Titan:
1. **`const? <type>` Arrays (Maybe-Const Arrays)**: A lightweight polymorphism mechanism allowing functions to accept either mutable or const arrays without mutation, with zero-cost structural assignment and strict runtime-checked casts.
2. **`linear` Flag & Return Escape Analysis**: Escape analysis on first-order function return values that tags unaliased returned mutable arrays with `linear = true`, allowing callers expecting `const` arrays to freeze them in-place with zero memory allocation.

---

## User Feedback & Requirements

> [!IMPORTANT]
> - **Option Propagation**: `({T})?` and `(const {T})?` must be assignable to `(const? {T})?` (and `Option(Array(T, "maybe"))`) up to gradual consistency of the element types.
> - **Generics / Parametric Polymorphism**: Generic functions (such as `map<A,B>(array: const? {<A>}, f: (A, integer) -> B): {B}`) must be thoroughly tested in both checker and coder specs, including type inference for `const? {<A>}` and in-place freezing for generic linear return values.
> - **Zero-Cost Representation**: `const? {T}` shares the exact same native C representation (`Table*`) as `{T}` and `const {T}`. Passing `{T}` or `const {T}` to `const? {T}` involves zero conversions, zero runtime checks, and zero allocations.
> - **Sound Qualifier Barrier**: A `const? {T}` cannot be implicitly converted to `{T}` or `const {T}`. Explicit `as {T}` and `as const {T}` generate runtime metatable checks and raise if the actual runtime qualifier does not match.
> - **Dynamic Coercion**: Casts from `value` to `const? {T}` accept either the mutable or const array metatable via `titan_array_try_backing_either`.

---

## Proposed Architecture & Changes

### 1. AST & Parser (`titan-compiler/`)

#### [MODIFY] [titan-compiler/ast.lua](file:///home/mascarenhas/Code/titan/titan-compiler/ast.lua)
- `ast.TypeArray`: `isconst` field accepts `false` (mutable), `true` (const), or `"maybe"` (`const?`).

#### [MODIFY] [titan-compiler/parser.lua](file:///home/mascarenhas/Code/titan/titan-compiler/parser.lua)
- Add grammar rule in `constarray`:
  ```peg
  constarray <- (P  CONST OPT LCURLY
                    type^TypeConstArray
                    (!COLON / %{ConstMap})
                    RCURLY^RCurlyType) -> maybeconstarraytype
              / (P  CONST LCURLY
                    type^TypeConstArray
                    (!COLON / %{ConstMap})
                    RCURLY^RCurlyType) -> constarraytype
  ```
- Define `defs.maybeconstarraytype(pos, subtype)` returning `ast.TypeArray(pos, subtype, "maybe")`.

---

### 2. Type System & Semantics (`titan-compiler/types.lua`)

#### [MODIFY] [titan-compiler/types.lua](file:///home/mascarenhas/Code/titan/titan-compiler/types.lua)

- **`types.Array(elem, isconst)`**:
  - Accept `isconst == false`, `true`, or `"maybe"`.
  - Support optional internal `linear` flag on mutable array instances (`isconst == false`).
- **`types.canonical_array(elem, isconst)`**:
  - Normalize element type and preserve `isconst` (`false`, `true`, `"maybe"`).
- **`types.equals(t1, t2)`**:
  - `t1.isconst == t2.isconst and types.equals(t1.elem, t2.elem)`.
- **`types.consistent(t1, t2)`**:
  - `t1.isconst == t2.isconst and types.consistent(t1.elem, t2.elem)`.
- **`types.assignment_adjustment(source, target, policy)`**:
  - If `source._tag == "Type.Array"` and `target._tag == "Type.Array"`:
    - When `target.isconst == "maybe"` and `(source.isconst == false or source.isconst == true or source.isconst == "maybe")`:
      - If `types.consistent(source.elem, target.elem)`:
        - If `types.equals(source.elem, target.elem)`: return identity plan (`plan("identity", ...)`).
        - Else: return gradual view plan.
    - When `target.isconst ~= "maybe"` and `source.isconst == "maybe"`:
      - Return `false` (implicit conversion from `const?` to mutable/const is disallowed).
    - When `source.isconst == false and source.linear == true` and `target.isconst == true`:
      - When elements are equal or consistent: return in-place freeze plan (`op = "array_freeze", mode = "freeze"`).
  - If `source._tag == "Type.Option"` and `target._tag == "Type.Option"`:
    - `types.assignment_adjustment(source.base, target.base)` correctly delegates, ensuring `Option(Array(T, false))` and `Option(Array(T, true))` are assignable to `Option(Array(T, "maybe"))`.
- **`types.written_cast(source, target)`** (Explicit `as`):
  - From `source` with `isconst == "maybe"` to `target` with `isconst == false`:
    - Produce `op = "maybe_array_cast_mutable"` (runtime check for mutable metatable).
  - From `source` with `isconst == "maybe"` to `target` with `isconst == true`:
    - Produce `op = "maybe_array_cast_const"` (runtime check for const metatable).
  - From `source` with `isconst == false` or `true` to `target` with `isconst == "maybe"`:
    - Produce identity or element view plan.
- **Dynamic Coercion (`types.dynamic_coercion` & `dynamic_plan`)**:
  - For `Type.Array(elem, "maybe")`:
    - Dynamic coercion plan accepts either mutable or const array metatable (`titan_array_try_backing_either`).
- **`types.tostring(t)`**:
  - If `t.isconst == "maybe"`: return `"const? { " .. types.tostring(t.elem) .. " }"`.
- **`types.serialize(t)`**:
  - Serialize `isconst` as `false`, `true`, or `"\"maybe\""`.

---

### 3. Checker & Linear Escape Analysis (`titan-compiler/checker/`)

#### [MODIFY] [titan-compiler/checker/type_syntax.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/type_syntax.lua)
- Update `Ast.TypeArray` handler to forward `node.isconst` (`"maybe"`, `true`, `false`).

#### [MODIFY] [titan-compiler/checker/statements.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/statements.lua)
- **Array element assignment**:
  - In `Ast.StatAssign`: if `var.exp1._type.isconst` (`true` or `"maybe"`), reject with compile error (`"cannot assign to element of const array"` / `"cannot assign to element of const? array"`).
- **Return statement checking**:
  - Propagate `linear` flag when returning a linear mutable array expression.

#### [MODIFY] [titan-compiler/checker/linear.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/linear.lua)
- Extend escape analysis to function declarations (`Ast.TopLevelFunc`, `Ast.TopLevelMethod`, `Ast.TopLevelStatic`):
  - For each returned expression in `StatReturn`:
    - A returned value is unaliased/linear if it originates from:
      1. An inline constructor `{ ... }`, or
      2. A local declaration initialized to a fresh constructor `{ ... }` or a direct call to a linear-returning function, whose references in the function are all non-escaping builder operations (indexing, length `#`), with no closure captures, and whose sole escaping point is the `return` statement, or
      3. An expression with `linear == true`.
    - If all return paths for return slot `i` return a linear value, tag return slot `i` in the function's declaration signature with `linear = true`.
  - When converting a function declaration to a first-class function value (`Type.Function`), strip `linear = true` from its return types.

#### [MODIFY] [titan-compiler/checker/expressions.lua](file:///home/mascarenhas/Code/titan/titan-compiler/checker/expressions.lua)
- **Direct call instantiation (`generic_instantiate_direct_call` & `annotate_call_results`)**:
  - Direct calls to first-order functions preserve `linear = true` on the call's synthesized return types.
- **Explicit casts (`Ast.ExpCast`)**:
  - Support `maybe_array_cast_mutable` and `maybe_array_cast_const`.

---

### 4. Runtime Header (`titan-runtime/titan.h`)

#### [MODIFY] [titan-runtime/titan.h](file:///home/mascarenhas/Code/titan/titan-runtime/titan.h)
- Add inlined helper `titan_array_try_backing_either`:
  ```c
  static l_inline Table *titan_array_try_backing_either(
      const TValue *value, Table *mutable_metatable, Table *const_metatable)
  {
      if (ttisfulluserdata(value)) {
          Udata *proxy = uvalue(value);
          if (TITAN_LIKELY(proxy->metatable == mutable_metatable ||
                           proxy->metatable == const_metatable)) {
              return hvalue(&proxy->uv[0].uv);
          }
      }
      return NULL;
  }
  ```

---

### 5. Code Generator (`titan-compiler/coder/`)

#### [MODIFY] [titan-compiler/coder/values.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/values.lua)
- **`setboxed` / `copyboxed`**:
  - For `Type.Array` with `isconst == "maybe"`, boxing extracts the canonical proxy via `titan_array_require_proxy(backing)` (identical to mutable and const arrays).
- **`convert_dynamic`**:
  - For `Type.Array(elem, "maybe")`, generate check with `titan_array_try_backing_either`.
- **`_code_written_cast` / `coder._code_array_freeze`**:
  - Handle `mode == "freeze"` for expressions with `linear == true`.
  - Handle `maybe_array_cast_mutable` (check `titan_array_try_proxy(backing, mutable_metatable) != NULL`, throw if fail).
  - Handle `maybe_array_cast_const` (check `titan_array_try_proxy(backing, const_metatable) != NULL`, throw if fail).

#### [MODIFY] [titan-compiler/coder/expressions.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/expressions.lua)
- In `codeindexarray`, allow reading from `const?` array backing directly via `arr2obj` / `farr2val`.

---

### 6. Documentation Updates (`doc/`)

#### [MODIFY] [doc/language/arrays-maps.md](file:///home/mascarenhas/Code/titan/doc/language/arrays-maps.md)
- Add section explaining `const? {T}` maybe-const arrays:
  - Motivation: polymorphic traversals over const and mutable arrays without mutation.
  - Subtyping rules, assignment rules, explicit casts, Option propagation.
- Add section explaining linear return values and in-place freezing.

#### [MODIFY] [doc/implementation/dense-arrays.md](file:///home/mascarenhas/Code/titan/doc/implementation/dense-arrays.md)
- Document the three Array qualification states: mutable (`false`), const (`true`), and maybe-const (`"maybe"`).
- Document `titan_array_try_backing_either` and dynamic coercion for `const?`.
- Document linear escape analysis for returned arrays and in-place freezing.

---

## Implementation Status & Notes

All phases of this plan have been **COMPLETED** and verified:

1. **AST & Parser**:
   - Implemented `ast.TypeArray` with `isconst == "maybe"` and `defs.maybeconstarraytype` in `titan-compiler/parser.lua`.
   - Updated grammar pattern `constarray` to parse `const? { T }`.
   - Added unit tests in `spec/parser_spec.lua` (174 parser tests passing).

2. **Type System & Semantics**:
   - `types.Array(elem, isconst)` and `types.canonical_array` handle `isconst == "maybe"`.
   - `types.assignment_adjustment`:
     - Allows mutable, const, and maybe-const arrays to assign to `const?` target (identity or gradual view plan).
     - Allows Option versions (`({T})?`, `(const {T})?`, `(const? {T})?`) to assign to `(const? {T})?` through recursive Option base adjustment.
     - Disallows implicit conversion from `const? {T}` to mutable or const array targets.
     - Recognizes `linear == true` mutable arrays and creates in-place freeze adjustment (`op = "array_freeze", mode = "freeze"`).
   - `types.written_cast`:
     - Generates `maybe_array_cast_mutable` (cast `const? {T}` to `{T}`), `maybe_array_cast_const` (cast `const? {T}` to `const {T}`), and `maybe_array_cast_upcast`.
   - `types.serialize` and `types.tostring`: format and serialize `const? { T }`.
   - Added unit tests in `spec/types_spec.lua` (116 tests passing).

3. **Checker & Escape Analysis**:
   - `trycoerce` in `type_syntax.lua`: wraps `written_cast` adjustments in `ast.ExpCast` with `_written_cast` and `_implicit_coercion = true`.
   - `statements.lua`: indexed assignments `a[i] = v` reject `a` of type `const? { T }`.
   - `linear.lua`:
     - Implemented `annotate_linear_function_returns(node)` to inspect all return statements across functions/methods/static methods.
     - Unaliased/fresh mutable array returns are tagged with `linear = true` on the signature return types.
     - Builder analysis skips return statements when checking for escaping references.
   - `declarations.lua`: calls `annotate_linear_function_returns` during `checkfuncbody`.
   - `expressions.lua`: strips `linear` flag when functions are referenced as first-class values.
   - `calls.lua`: `check_explicit_cast_relation` handles `maybe_array_cast_*` ops.
   - `lowering.lua`: generic lowering reclassifies `Ast.ExpCast` adjustments when generic calls are erased to `{ value }` while preserving linear freeze optimization.
   - Added comprehensive tests in `spec/checker/dense_arrays_spec.lua` (1157 checker tests passing).

4. **Runtime Header & Coder**:
   - `titan.h`: added `titan_array_try_backing_either(value, mutable_meta, const_meta)` for $O(1)$ unboxing of both mutable and const arrays.
   - `coder/values.lua`:
     - Updated dynamic conversions and gradual guards to allow `isconst == "maybe"`.
     - Updated `_checked_identity_plan` to allow assignment from mutable, const, or maybe-const to `const?`.
     - Handled `written_cast` in `_checked_adjustment_plan_impl`.
     - Added validation branches for `maybe_array_cast_mutable`, `maybe_array_cast_const`, and `maybe_array_cast_upcast` in `_checked_written_cast_plan`.
   - `coder/expressions.lua`: added `_code_maybe_array_cast` for runtime unboxing and type assertions on explicit casts.
   - Added coder tests in `spec/coder/dense_arrays_spec.lua` verifying runtime execution of `const?` arrays, generic `map<A,B>`, explicit casts, and in-place freezing (using `titan_array_freeze` and not `titan_array_shallow_copy`).

5. **Documentation**:
   - Updated `doc/language/types.md` and `doc/language/const-values.md`.

6. **Verification**:
   - Ran `make titan-stdlib-test`: 197 native tests passing.
   - Ran `busted spec/parser_spec.lua spec/types_spec.lua spec/checker/dense_arrays_spec.lua spec/coder/dense_arrays_spec.lua`: all tests passing.
