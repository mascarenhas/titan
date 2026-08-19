# Implementation Plan: Optimize Titan Dense Array Representation

Refactor and optimize the implementation of Titan dense arrays by moving the canonical `Udata*` proxy to array index 0 in the backing table, eliminating hash part allocations entirely, aligning Titan 1-based indices directly with C array indices, inlining fast-path array helpers, and replacing defensive runtime checks and loops with optimized invariants.

## User Feedback & Deviations Recorded

> [!NOTE]
> - **Omission of `backing != NULL`**: Per maintainer guidance, `backing != NULL` is guaranteed by Titan invariants and was omitted from `titan_array_try_proxy`.
> - **Single Error Check in `titan_array_growth`**: Instead of checking both before and after computing the power-of-two capacity, `titan_array_growth` computes the next power of two via `__builtin_clzll` and performs a single bounds check against `TITAN_ARRAY_MAX_CAPACITY`.
> - **Trust in Proxy Receiver in `titan_array_require_backing`**: Array proxy metatables are protected from Lua code, so `titan_array_require_backing` directly accesses `hvalue(&uvalue(value)->uv[0].uv)` without defensive runtime type checks.
> - **Test Suite Alignment**: `spec/dense_array_runtime_spec.lua` was updated so `assert_shape` checks `backing->asize == expected_asize`, reflecting that freshly created arrays have `asize = capacity + 1` (slot 0 for proxy) and dynamically grown arrays have power-of-two `asize`.

## Implemented Changes

### 1. Runtime Header and Source (`titan-runtime/`)

#### [titan-runtime/titan.h](file:///home/mascarenhas/Code/titan/titan-runtime/titan.h)
- Inlined `titan_array_length`:
  ```c
  static l_inline lua_Unsigned titan_array_length(const Table *backing) {
    return *lenhint(backing);
  }
  ```
- Inlined `titan_array_set_length`:
  ```c
  static l_inline void titan_array_set_length(Table *backing, lua_Unsigned length) {
    *lenhint(backing) = cast_uint(length);
  }
  ```
- Inlined `titan_array_require_proxy`:
  ```c
  static l_inline Udata *titan_array_require_proxy(Table *backing) {
    lua_assert(backing != NULL && backing->asize > 0);
    lua_assert(*getArrTag(backing, 0) == ctb(LUA_VUSERDATA));
    return gco2u(getArrVal(backing, 0)->gc);
  }
  ```
- Inlined `titan_array_try_proxy`:
  ```c
  static l_inline Udata *titan_array_try_proxy(Table *backing, Table *metatable) {
    if (TITAN_LIKELY(backing->asize > 0)) {
      TValue value;
      arr2obj(backing, 0, &value);
      if (TITAN_LIKELY(ttisfulluserdata(&value))) {
        Udata *maybe_proxy = uvalue(&value);
        if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
          return maybe_proxy;
        }
      }
    }
    return NULL;
  }
  ```
- Inlined `titan_array_try_backing`:
  ```c
  static l_inline Table *titan_array_try_backing(const TValue *value, Table *metatable) {
    if (ttisfulluserdata(value)) {
      Udata *maybe_proxy = uvalue(value);
      if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
        return hvalue(&maybe_proxy->uv[0].uv);
      }
    }
    return NULL;
  }
  ```
- Inlined `titan_array_require_backing`:
  ```c
  static l_inline Table *titan_array_require_backing(const TValue *value) {
    lua_assert(ttisfulluserdata(value));
    return hvalue(&uvalue(value)->uv[0].uv);
  }
  ```
- Inlined `titan_array_new`:
  ```c
  static l_inline Table *titan_array_new(lua_State *L, Table *metatable,
                                         lua_Unsigned capacity,
                                         const TValue *writer, StkId result) {
    return titan_array_new_impl(L, metatable, capacity, writer, 1, result);
  }
  ```
- Inlined `titan_const_array_new` calling `titan_array_new_impl(L, metatable, capacity, NULL, 0, result)`.

#### [titan-runtime/titan.c](file:///home/mascarenhas/Code/titan/titan-runtime/titan.c)
- **`titan_array_growth`**: Compute next power of 2 strictly greater than `index` in $O(1)$ via `__builtin_clzll`:
  ```c
  unsigned titan_array_growth(lua_State *L, lua_Unsigned index) {
      int clz = __builtin_clzll(index);
      unsigned capacity = (clz >= 33) ? (1u << (64 - clz)) : (TITAN_ARRAY_MAX_CAPACITY + 1u);
      if (TITAN_UNLIKELY(capacity > TITAN_ARRAY_MAX_CAPACITY))
          luaL_error(L, "array index too large");
      return capacity;
  }
  ```
- **`titan_array_resize`**: Streamlined without redundant defensive checks:
  ```c
  void titan_array_resize(lua_State *L, Table *backing, lua_Unsigned capacity) {
      lua_Unsigned length;
      lua_assert(capacity <= TITAN_ARRAY_MAX_CAPACITY);
      lua_assert(capacity >= backing->asize);
      if (capacity == backing->asize)
          return;
      length = titan_array_length(backing);
      luaH_resizearray(L, backing, cast_uint(capacity));
      titan_array_set_length(backing, length);
  }
  ```
- **`titan_array_new_impl`**:
  - `luaH_resize(L, backing, cast_uint(capacity + 1u), 0)` (hash size 0).
  - Proxy installed at array slot 0 via `obj2arr(backing, 0, &proxy_value)` and barriered.
  - Eliminated `savestack`/`restorestack` churn around non-stack-reallocating object allocations.
- **`titan_array_get`**: Direct 1-based indexing:
  ```c
  logical_index = l_castS2U(index);
  if (logical_index >= backing->asize) { setnilvalue(result); return LUA_VNIL; }
  tag = *getArrTag(backing, cast_uint(logical_index));
  if (tagisempty(tag)) { setnilvalue(result); return LUA_VNIL; }
  farr2val(backing, cast_uint(logical_index), tag, result);
  ```
- **`titan_array_set_stack`**: Direct 1-based indexing, resize check `logical_index >= backing->asize`, store at `obj2arr(backing, cast_uint(logical_index), &value)`, and nil backscan on `tagisempty(*getArrTag(backing, cast_uint(length)))`.
- **`titan_array_lua_index` / `titan_array_lua_newindex` / `titan_array_lua_len`**: Simplified to use `titan_array_require_backing(&receiver)`.
- **`titan_array_shallow_copy`**: Direct loop `for (i = 1; i <= length; i++)` copying element slots 1..length.
- **`titan_array_freeze`**: Direct proxy retrieval via `gco2u(getArrVal(backing, 0)->gc)` in $O(1)$.

---

### 2. Compiler Code Generator (`titan-compiler/coder/`)

#### [titan-compiler/coder/expressions.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/expressions.lua)
- **`codeindexarray`**: `lua_Unsigned _actual_i = l_castS2U(_k);` and `arr2obj(_t, cast_uint(_actual_i), &_av);`.
- **`_codepositionalarray` (Constructors)**:
  - Prefix stores: `obj2arr($TMPNAME, $INDEX, $SLOT)` with `$INDEX` from 1 to `nstored`.
  - Vararg loop: `obj2arr($TMPNAME, $NPREFIX + 1 + _vj, &$VSLOT)`.
  - Length scan: `while (_array_length > 0 && tagisempty(*getArrTag($TMPNAME, _array_length))) _array_length--;`.

#### [titan-compiler/coder/statements.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/statements.lua)
- **Array write lowering**:
  - `lua_Unsigned _actual_i = l_castS2U(_k);`
  - In-capacity store: `obj2arr(_t, cast_uint(_actual_i), &_vv);`
  - Nil backscan: `while (_length > 0 && tagisempty(*getArrTag(_t, _length))) _length--;`
  - Growth branch: `unsigned _newasize = titan_array_growth(L, _actual_i);` and `obj2arr(_t, cast_uint(_actual_i), &_vv);`.

#### [titan-compiler/coder/values.lua](file:///home/mascarenhas/Code/titan/titan-compiler/coder/values.lua)
- Updated `setboxed` and `copyboxed` to call `titan_array_require_proxy($SRC)` / `titan_array_require_proxy(hvalue($SRC))`.

#### [titan-compiler/driver.lua](file:///home/mascarenhas/Code/titan/titan-compiler/driver.lua)
- Updated standalone main `arguments` array construction to use `titan_array_require_proxy(arguments)`.

---

### 3. Documentation (`doc/implementation/`)

#### [doc/implementation/dense-arrays.md](file:///home/mascarenhas/Code/titan/doc/implementation/dense-arrays.md)
- Updated diagrams and documentation:
  - Proxy `Udata*` is stored in `backing->array[0]` (array slot 0).
  - Backing table hash part is empty (`nhsize = 0`).
  - Titan 1-based index $k$ maps directly to C array index $k$.
  - Inlined proxy/backing resolution and $O(1)$ growth via `__builtin_clzll`.

---

### 4. Tests and Verification

#### [spec/dense_array_runtime_spec.lua](file:///home/mascarenhas/Code/titan/spec/dense_array_runtime_spec.lua)
- Updated `assert_shape` and `assert_const_shape`:
  - `assert(backing->asize == capacity);`
  - `assert(allocsizenode(backing) == 0 || isdummy(backing));`
  - `assert(live_hash_entries(backing) == 0);`
  - `arr2obj(backing, 0, &cycle); assert(ttisfulluserdata(&cycle)); assert(uvalue(&cycle) == proxy);`
- Updated shape checks across tests for slot-0 proxy and 1-based indexing.

## Verification Results

1. **Dense Array Runtime Spec**:
   - `busted spec/dense_array_runtime_spec.lua`: **3/3 passed** (0 failures, 0 errors).
2. **Dense Array Checker & Coder Specs**:
   - `busted spec/checker/dense_arrays_spec.lua spec/coder/dense_arrays_spec.lua`: **34/34 passed** (0 failures, 0 errors).
3. **Native Standard Library Test Suite**:
   - `make titan-stdlib-test-run`: **197/197 passed** (0 failures, 0 errors).
4. **Checker Spec Suite**:
   - `busted spec/checker`: **1183/1183 passed** (0 failures, 0 errors).
5. **Coder Spec Suite**:
   - `busted spec/coder`: **917/917 passed** (0 failures, 0 errors).
