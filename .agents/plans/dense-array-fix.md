The implementation of Titan arrays (from doc/implementation/dense-arrays.md) is full of performance issues and overly defensive code that should be fixed.

The big issue is that the Udata* proxy for the array is kept in the hash portion, which means there is always an expensive operation to access it, even if the key is a static value. But access to the array part is controlled by Titan, so a better design is to store the proxy in the 0
index of the array part. This means the "C index" corresponding to each Titan index does is not offset by 1 anymore, but that is ok. The `lenhint` that keeps the number of elements in the array does not need to change, since it is not used for bounds checking/growth checking.

With the array Udata* proxy at array index 0, `titan_array_require_proxy` does not need to be a function but can be inlined code. This function is always called in a context where `backing` is a Titan array backing table, so it does not need to check anything (except through lua_assert macro for debug assertions), it can just `*getArrVal(backing, 0)` to get the `Udata*` proxy, so it is a one-liner!

The `titan_array_require_backing` function has a similar overly conservativeness, the array proxy metatables are protected, so Lua
code cannot access the underlying `__index/__newindex/__len` metamethods to be able to call them with a receiver that is not a 
Titan array proxy without using the Lua debug API (or C code), and a **big Titan invariant that is required for performance is that
Titan code does NOT protect against misuse of the debug/C APIs**. So in the contexts where `titan_array_require_backing` is being
used the code should assume that the receiver is a proper proxy, and not even check if it is an userdata, just get the `Udata* proxy` and
access `hvalue(proxy->uv[0].uv)` to get the backing `Table*`, at most with debug `lua_assert` for sanity checking.

In the case of `titan_array_try_proxy`, it *can* be used to check a table that is not a Titan array, but the check to see if
the table is a Titan array should be simply (which is also inlinable):

```
if(TITAN_LIKELY(backing->asize > 0)) {
    Value v;
    arr2obj(backing, 0, &v);
    if (TITAN_LIKELY(ttisfulluserdata(&value))) {
      Udata *maybe_proxy = uvalue(&value);
      if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
        return maybe_proxy;
      }
    }
}
return NULL;
```

Lua code cannot get one of the array proxy metatables to create a "fake backing array" without using the debug/C API.

For `titan_array_try_backing` similar logic applies, the test should be just "is this an userdata and is the metatable the one I expect", since the metatable cannot be forged without the debug/C APIs:

```
if (ttisfulluserdata(value)) {
    Udata *maybe_proxy = uvalue(value);
    if (TITAN_LIKELY(maybe_proxy->metatable == metatable)) {
        return hvalue(maybe_proxy->uv[0].uv);
    }
}
return NULL;
```

Of course the code above is also inlinable.

The functions are lousy with extra **runtime** checks that are not warranted given the limited context they are called from. In the case of `titan_array_growth`, it is always called with a positive integer! So the `if (index < 1)` runtime check is useless! The O(log(n)) loop is also not needed in the targets Titan is being built for (GCC/Clang), as you can use `__builtin_clzll` (`lua_Unsigned` is `unsigned long long` in these targets). The `titan_array_resize` function also has unecessary runtime guards given the contexts it is called from.

Continuing, `titan_array_new_impl` can be simplified and optimized:

1. `luaH_new` does not reallocate the Lua stack, so the `savestack/restorestack` shenanigans are not needed, same with `luaH_resize` and `luaS_newudata`. You can just use the `result` StkId directly for temporary GC rooting.
2. `titan_array_set_length` is also an inlinable function (as ), and it should be just `*lenhint(backing) = cast_uint(length)` (same for titan_array_length).
3. Now that the proxy is going into the element 0 of the backing table the proxy does not need to be put on the stack as GC cannot not run
after the `luaS_newudata` call, this means you do not need to put the backing table on the stack again

And of course `titan_array_new` can be an inline function, since it is just a one-line call to `titan_array_new_impl`.

Moving on, `titan_array_freeze` does not need `titan_array_try_proxy`, if Titan is calling it it knows that `backing` is a Titan array. You can get the proxy directly with `*getArrVal(backing, 0)`.
