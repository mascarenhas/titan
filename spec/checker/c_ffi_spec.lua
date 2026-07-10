local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local f = assert(io.open(header, "w"))
    f:write(contents)
    f:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

describe("C FFI type checking", function()
    it("imports the compiler-provided C primitive header", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            local function id(x: ffi.titan_ffi_int): ffi.titan_ffi_int
                return x
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("imports lua_State from the compiler-provided FFI header", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            local function state_is_truthy(): boolean
                return L
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("imports bundled Lua headers through the compiler include path", function()
        local ok, err = run_checker([[
            local lua = foreign import "lua.h"
            local lual = foreign import "lauxlib.h"

            local function top(): integer
                return lua.lua_gettop(L)
            end

            local function metatable_created(): integer
                return lual.luaL_newmetatable(L, "titan_ffi_header_test")
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("accepts matching C redeclarations reached through typedef chains", function()
        with_header([[
            typedef long ffi_base;
            typedef ffi_base ffi_alias;
            extern ffi_alias ffi_redeclared(ffi_alias value);
        ]], function(header1)
            with_header([[
                typedef long ffi_alias;
                extern ffi_alias ffi_redeclared(ffi_alias value);
            ]], function(header2)
                local ok, err = run_checker([[
                    local c1 = foreign import "]] .. header1 .. [["
                    local c2 = foreign import "]] .. header2 .. [["

                    local function f(x: c2.ffi_alias): c1.ffi_alias
                        return c1.ffi_redeclared(x)
                    end
                ]])
                assert.truthy(ok, err)
            end)
        end)
    end)

    it("coerces between by-value C TValue and Titan value", function()
        with_header([[
            typedef struct TValue TValue;
            extern TValue ffi_value_echo(TValue value);
            extern int ffi_value_seen(TValue value);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function echo(x: value): value
                    local raw: c.TValue = x
                    return c.ffi_value_echo(raw)
                end

                local function raw(x: value): c.TValue
                    return x
                end

                local function back(x: c.TValue): value
                    return x
                end

                local function implicit_value(): value
                    return c.ffi_value_echo(42)
                end

                local function seen(f: (value) -> value): integer
                    return c.ffi_value_seen(f)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("coerces Titan functions with C pointer parameters to TValue", function()
        with_header([[
            typedef struct ffi_coro ffi_coro;
        ]], function(header)
            local ok, err = run_checker([[
                local ffi = foreign import "titan/ffi.h"
                local c = foreign import "]] .. header .. [["

                local function entry(func: (value) -> value, co: *c.ffi_coro)
                end

                local function store_entry()
                    ffi.lua_pushtvalue(L, entry)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("does not treat an unrelated typedef named TValue as Lua TValue", function()
        with_header([[
            typedef struct ffi_not_lua_value { int x; } TValue;
        ]], function(header)
            local ok = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function bad(v: value): c.TValue
                    return v
                end
            ]])
            assert.falsy(ok)
        end)
    end)

    it("exposes TValue pointer and array forms as C types", function()
        with_header([[
            typedef struct TValue TValue;
            extern int ffi_value_pointer(const TValue *value);
            extern TValue ffi_value_array[2];
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function has_pointer(v: value): integer
                    local raw: c.TValue = v
                    local p: const *c.TValue = raw
                    return (c.ffi_value_pointer(v) as integer)
                        + (c.ffi_value_pointer(raw) as integer)
                        + (c.ffi_value_pointer(p) as integer)
                end

                function array_entry(): value
                    return c.ffi_value_array[0]
                end
            ]])
            assert.truthy(ok, err)
        end)

        with_header([[
            struct TValue;
            extern int ffi_struct_value_pointer(const struct TValue *value);
            extern struct TValue ffi_struct_value_array[2];
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function has_pointer(v: value): integer
                    return c.ffi_struct_value_pointer(v)
                end

                function array_entry(): value
                    return c.ffi_struct_value_array[0]
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("types the built-in L as lua_State pointer for C calls", function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef lua_State *ffi_lua_state;
            extern int ffi_has_state(ffi_lua_state state);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_has_state(L)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("matches built-in L when lua_State typedef and struct spelling mix", function()
        with_header([[
            typedef struct lua_State lua_State;
            extern int ffi_has_state(struct lua_State *state);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_has_state(L)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("matches built-in L against tag-only struct lua_State pointers", function()
        with_header([[
            struct lua_State;
            extern int ffi_has_state(struct lua_State *state);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_has_state(L)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("types the built-in M as Udata pointer for C calls", function()
        with_header([[
            typedef struct Udata Udata;
            typedef Udata *ffi_module_state;
            extern int ffi_has_module(ffi_module_state module);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_has_module(M)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("matches built-in M against tag-only struct Udata pointers", function()
        with_header([[
            struct Udata;
            extern int ffi_has_module(struct Udata *module);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_has_module(M)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("allows imported C typedefs in local type annotations", function()
        with_header("typedef int ffi_count;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function id(x: c.ffi_count): c.ffi_count
                    return x
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("indexes C arrays, C pointers, and counted owned C arrays", function()
        with_header([[
            extern int ffi_values[4];
            extern int *ffi_ptr;
            typedef int ffi_int;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(i: integer): integer
                    local owned = c.ffi_int.new_array(3)
                    return (c.ffi_values[i] as integer)
                        + (c.ffi_ptr[0] as integer)
                        + (owned[1] as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("takes length of C arrays and counted owned C arrays", function()
        with_header([[
            extern int ffi_values[4];
            typedef int ffi_int;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    local owned = c.ffi_int.new_array(3)
                    return #c.ffi_values + #owned
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects indexing and length of C arrays with symbolic extents", function()
        with_header([[
            extern int ffi_values[UNKNOWN + 1];
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(i: integer): integer
                    return c.ffi_values[i] as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("unknown length", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return #c.ffi_values
                end
            ]])
            assert.falsy(ok)
            assert.match("trying to take the length", err)
        end)
    end)

    it("does not take length of bare C pointers or scalar owned C objects", function()
        with_header([[
            extern int *ffi_ptr;
            typedef int ffi_int;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return #c.ffi_ptr
                end
            ]])
            assert.falsy(ok)
            assert.match("trying to take the length", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    local owned = c.ffi_int.new()
                    return #owned
                end
            ]])
            assert.falsy(ok)
            assert.match("trying to take the length", err)
        end)
    end)

    it("keeps anonymous typedef structs distinct", function()
        with_header([[
            typedef struct { int x; } ffi_a;
            typedef struct { int y; } ffi_b;
            extern ffi_b ffi_value;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_value.y as integer
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("reads fields from imported C structs and struct pointers", function()
        with_header([[
            typedef struct ffi_point { int x; int y; } ffi_point;
            extern ffi_point ffi_origin;
            extern ffi_point *ffi_origin_ptr;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return (c.ffi_origin.x as integer)
                        + (c.ffi_origin_ptr.y as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("completes named C structs after forward typedef declarations", function()
        with_header([[
            typedef struct ffi_node ffi_node;
            typedef ffi_node *ffi_node_ref;
            struct ffi_node { int x; ffi_node *next; };
            extern ffi_node *ffi_node_ptr;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function next_node(): c.ffi_node_ref
                    return c.ffi_node_ptr.next
                end

                function f(): integer
                    return (c.ffi_node_ptr.x as integer)
                        + (next_node().x as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("completes forward-declared C structs across foreign imports", function()
        with_header([[
            typedef struct ffi_split ffi_split;
            extern ffi_split *ffi_split_ptr;
        ]], function(forward_header)
            with_header([[
                struct ffi_split { int x; };
            ]], function(definition_header)
                local ok, err = run_checker([[
                    local forward = foreign import "]] .. forward_header .. [["
                    local definition = foreign import "]] .. definition_header .. [["

                    function f(): integer
                        return forward.ffi_split_ptr.x as integer
                    end
                ]])
                assert.truthy(ok, err)
            end)
        end)
    end)

    it("decays C array parameters to pointers", function()
        with_header([[
            typedef int ffi_int;
            extern int sum4(int xs[4]);
            extern int slen(char s[]);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    local xs = c.ffi_int.new_array(4)
                    return (c.sum4(xs) as integer) + (c.slen("abc") as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("uses typedef targets when decaying C arrays to pointer parameters", function()
        with_header([[
            typedef int ffi_int;
            extern ffi_int ffi_values[4];
            extern int sum(int *xs);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.sum(c.ffi_values) as integer
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("offers new and new_array pseudo-functions on primitive C types", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            function f(): integer
                local one = ffi.titan_ffi_int.new()
                local many = ffi.titan_ffi_int.new_array(8)
                return #many
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("offers sizeof and alignof pseudo-members on C types", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            function f(): integer
                return ffi.titan_ffi_int.sizeof + ffi.titan_ffi_int.alignof
                    + ffi.TValue.sizeof + ffi.TValue.alignof
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("allows source-level pointer types over imported C types", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            local function f(p: const *ffi.titan_ffi_int): const *ffi.titan_ffi_void
                return p
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            local function bad(p: *integer)
            end
        ]])
        assert.falsy(ok)
        assert.match("C pointer type can only point to a C FFI type", err)
    end)

    it("coerces by-value C expressions and values to const C pointers", function()
        with_header([[
            typedef int ffi_int;
            extern int ffi_read_const_int(const int *p);
            extern int ffi_has_const_ptr(const void *p);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(v: value): integer
                    local x: c.ffi_int = 41 as c.ffi_int
                    local p: const *c.ffi_int = x
                    return (c.ffi_read_const_int(x) as integer)
                        + (c.ffi_read_const_int(p) as integer)
                        + (c.ffi_has_const_ptr(v) as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("coerces mutable C locals to mutable C pointer arguments", function()
        with_header([[
            typedef int ffi_int;
            typedef struct TValue TValue;
            extern int ffi_write_int(ffi_int *p);
            extern int ffi_write_void(void *p);
            extern int ffi_read_const_int(const ffi_int *p);
            extern int ffi_read_const_void(const void *p);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(v: value): integer
                    local x: c.ffi_int = 0 as c.ffi_int
                    local raw: c.TValue = v
                    return (c.ffi_write_int(x) as integer)
                        + (c.ffi_write_void(x) as integer)
                        + (c.ffi_write_void(raw) as integer)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function bad(): integer
                    return c.ffi_write_int(0 as c.ffi_int) as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("argument 1 of call", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function bad(): integer
                    local x: c.ffi_int = 1 as c.ffi_int
                    local cp: const *c.ffi_int = x
                    return c.ffi_write_int(cp) as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("argument 1 of call", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function bad(): integer
                    local x: c.ffi_int = 1 as c.ffi_int
                    local cp: const *c.ffi_int = x
                    return c.ffi_write_void(cp) as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("argument 1 of call", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function good(): integer
                    local x: c.ffi_int = 1 as c.ffi_int
                    local p: *c.ffi_int = x
                    return (c.ffi_read_const_int(p) as integer)
                        + (c.ffi_read_const_void(p) as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects allocation for C types that are not v1 object allocations", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            function f()
                local v = ffi.titan_ffi_void.new()
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot allocate C void", err)

        with_header([[
            typedef int ffi_array[4];
            typedef struct ffi_incomplete ffi_incomplete;
        ]], function(header)
            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f()
                    local a = c.ffi_array.new()
                end
            ]])
            assert.falsy(ok)
            assert.match("C array typedefs", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f()
                    local p = c.ffi_incomplete.new()
                end
            ]])
            assert.falsy(ok)
            assert.match("incomplete C struct", err)
        end)
    end)

    it("rejects owned allocation for structs with flexible array members", function()
        with_header([[
            typedef struct ffi_packet {
                int len;
                char data[];
            } ffi_packet;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f()
                    local p = c.ffi_packet.new()
                end
            ]])
            assert.falsy(ok)
            assert.match("flexible array member", err)
        end)
    end)

    it("rejects indexing unsized C array fields", function()
        with_header([[
            typedef struct ffi_packet {
                int len;
                char data[];
            } ffi_packet;
            extern ffi_packet ffi_pkt;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return c.ffi_pkt.data[0] as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("unknown length", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    return #c.ffi_pkt.data
                end
            ]])
            assert.falsy(ok)
            assert.match("trying to take the length", err)
        end)
    end)

    it("keeps C value members out of the C type namespace", function()
        with_header("extern int ffi_value;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(x: c.ffi_value): integer
                    return 1
                end
            ]])
            assert.falsy(ok)
            assert.match("C type 'ffi_value' not found", err)
        end)
    end)

    it("allows explicit casts from C object pointers to void pointers", function()
        with_header([[
            typedef int *ffi_iptr;
            typedef void *ffi_vptr;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(p: c.ffi_iptr): c.ffi_vptr
                    return p as c.ffi_vptr
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("allows casts and assignments from void pointers to C object pointers", function()
        with_header([[
            typedef int *ffi_iptr;
            typedef void *ffi_vptr;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function explicit(p: c.ffi_vptr): c.ffi_iptr
                    return p as c.ffi_iptr
                end

                local function implicit(p: c.ffi_vptr): c.ffi_iptr
                    local q: c.ffi_iptr = p
                    return q
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("exposes function pointer typedefs as callable C pointer types", function()
        with_header([[
            typedef int (*ffi_callback)(int);
            extern int ffi_add1(int x);
            extern int call_callback(ffi_callback cb, int x);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function call_local(cb: c.ffi_callback): integer
                    return cb(3) as integer
                end

                function f(): integer
                    local cb: c.ffi_callback = c.ffi_add1
                    return (c.call_callback(c.ffi_add1, 2) as integer)
                        + (c.call_callback(cb, 4) as integer)
                        + call_local(cb)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects incompatible foreign functions as C function pointers", function()
        with_header([[
            typedef double (*ffi_callback)(double);
            extern int ffi_add1(int x);
            extern double call_callback(ffi_callback cb, double x);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): float
                    return c.call_callback(c.ffi_add1, 2.0) as float
                end
            ]])
            assert.falsy(ok)
            assert.match("foreign %(C%) function", err)
        end)
    end)

    it("does not treat C function pointers as C object pointers", function()
        with_header([[
            typedef int (*ffi_callback)(int);
            typedef void *ffi_vptr;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(cb: c.ffi_callback): value
                    return cb as value
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'ffi_callback' to 'value'", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(cb: c.ffi_callback): c.ffi_vptr
                    return cb as c.ffi_vptr
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'ffi_callback' to 'ffi_vptr'", err)
        end)
    end)

    it("rejects C pointer types as Titan variadic parameter elements", function()
        with_header("typedef int *ffi_iptr;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(...: c.ffi_iptr)
                end
            ]])
            assert.falsy(ok)
            assert.match("foreign pointer", err)
        end)
    end)

    it("imports bare enum constants as C integer members", function()
        with_header([[
            enum ffi_choice { FFI_A = 3, FFI_B = 4 };
            typedef enum ffi_result { FFI_OK = 0, FFI_FAIL = 7 } ffi_result;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): integer
                    local result: c.ffi_result = c.FFI_FAIL as c.ffi_result
                    return (c.FFI_A as integer) + (result as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("reports conflicting ordinary C declarations across foreign imports", function()
        with_header("extern int ffi_conflict;\n", function(header1)
            with_header("extern double ffi_conflict;\n", function(header2)
                local ok, err = run_checker([[
                    local c1 = foreign import "]] .. header1 .. [["
                    local c2 = foreign import "]] .. header2 .. [["

                    function f(): integer
                        return 0
                    end
                ]])
                assert.falsy(ok)
                assert.match("conflicting C declaration", err)
            end)
        end)
    end)

    it("rejects C arrays crossing through value", function()
        with_header([[
            typedef int ffi_arr[2];
            extern ffi_arr ffi_values;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): value
                    return c.ffi_values as value
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'ffi_arr' to 'value'", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(v: value): integer
                    local xs = v as c.ffi_arr
                    return xs[0] as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'value' to 'ffi_arr'", err)
        end)
    end)

    it("rejects by-value C aggregates crossing through value", function()
        with_header([[
            typedef struct ffi_point { int x; } ffi_point;
            extern ffi_point ffi_origin;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(): value
                    return c.ffi_origin as value
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'ffi_point' to 'value'", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(v: value): integer
                    local p = v as c.ffi_point
                    return p.x as integer
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot cast 'value' to 'ffi_point'", err)
        end)
    end)

    it("does not treat C modules as first-class values", function()
        with_header("extern int ffi_value;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(): value
                    return c
                end
            ]])
            assert.falsy(ok)
            assert.match("trying to access module 'c' as a first%-class value", err)
        end)
    end)

    it("rejects exported functions that mention C FFI types", function()
        with_header("typedef int ffi_count;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(x: c.ffi_count): integer
                    return 1
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot export C FFI type 'ffi_count'", err)
        end)
    end)

    it("reports exported C FFI types cleanly through source imports", function()
        with_header("typedef int ffi_count;\n", function(header)
            local ok, err = run_checker_modules({
                a = [[
                    local c = foreign import "]] .. header .. [["

                    function f(x: c.ffi_count): integer
                        return 1
                    end
                ]],
                b = [[
                    local a = import "a"
                ]]
            }, "b")
            assert.falsy(ok)
            assert.match("cannot export C FFI type 'ffi_count'", err)
        end)
    end)

    it("rejects record fields that mention C FFI types", function()
        with_header("typedef int ffi_count;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                record R
                    x: c.ffi_count
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot export C FFI type 'ffi_count'", err)
        end)
    end)

    it("allows C FFI types in local record fields", function()
        with_header("typedef struct ffi_handle ffi_handle;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                record Handle
                    local pointer: *c.ffi_handle
                end

                local function use(pointer: *c.ffi_handle): Handle
                    return Handle.new(pointer)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects exported legacy C struct types without crashing", function()
        with_header("typedef struct ffi_point { int x; } ffi_point;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function f(x: c.ffi_point): integer
                    return 1
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot export C FFI type 'ffi_point'", err)
        end)
    end)
end)
