local h = require 'spec.support.helpers'
local types = require 'titan-compiler.types'

local probe_session

local function run_checker(code)
    return h.run_checker(code, probe_session)
end

local function run_checker_modules(modules, main)
    return h.run_checker_modules(modules, main)
end

local function check_errs(code)
    return h.check_errs(code, probe_session)
end

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

local FIELD_PROJECTION_HEADER = [[
    typedef struct ffi_projection_inner {
        int leaf;
    } ffi_projection_inner;

    typedef struct ffi_projection_left {
        ffi_projection_inner nested;
        double projected;
    } ffi_projection_left;

    typedef struct ffi_projection_right {
        ffi_projection_inner nested;
        double projected;
    } ffi_projection_right;

    typedef struct ffi_projection_bad {
        int projected;
    } ffi_projection_bad;

    static ffi_projection_left ffi_projection_left_value =
        { { 7 }, 701.0 };
    static ffi_projection_right ffi_projection_right_value =
        { { 11 }, 1101.0 };
    static ffi_projection_right *ffi_projection_right_ptr =
        &ffi_projection_right_value;
    static ffi_projection_bad ffi_projection_bad_value = { 17 };

    static int ffi_projection_physical_sum(void) {
        return (int)(ffi_projection_left_value.projected +
                     ffi_projection_right_value.projected);
    }

    #define projected nested.leaf
]]

local CAST_MACRO_HEADER = [[
    typedef int (*ffi_macro_callback)(int);
    typedef long ffi_macro_long;
    typedef double ffi_macro_double;
    typedef int *ffi_macro_int_ptr;
    typedef int ffi_macro_array[4];

    static int ffi_macro_value = 9;

    static int ffi_macro_add5(int value) {
        return value + 5;
    }

    static int ffi_macro_add7(int value) {
        return value + 7;
    }

    #define FFI_TYPEDEF_CALLBACK \
        ((ffi_macro_callback) ffi_macro_add5)
    #define FFI_DIRECT_CALLBACK \
        ((int (*)(int)) ffi_macro_add7)
    #define FFI_CAST_INT ((long) 41)
    #define FFI_CAST_DOUBLE ((double) 1.5)
    #define FFI_CAST_POINTER ((int *) &ffi_macro_value)
    #define FFI_VOID_CAST ((void) 0)
    #define FFI_ARRAY_CAST ((ffi_macro_array) 0)
]]

describe("C FFI type checking", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("publishes complete, empty, and unavailable parameter-name metadata",
    function()
        with_header([[
            extern int ffi_named(int count, const char *path);
            extern int ffi_zero(void);
            extern int ffi_oldstyle();
        ]], function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["
            ]])
            assert.truthy(ok, err)

            local cmod = ast[1]._type
            assert.equal("Type.CModule", cmod._tag)
            assert.same({ "count", "path" },
                cmod.members.ffi_named.paramnames)
            assert.same({}, cmod.members.ffi_zero.paramnames)
            assert.is_false(cmod.members.ffi_oldstyle.paramnames)
        end)
    end)

    it("keeps Titan keyword spellings usable as contextual C names",
    function()
        with_header([[
            typedef int type;
            typedef struct ffi_keyword_holder {
                int when;
                int interface;
            } ffi_keyword_holder;

            static int repeat = 3;
            static int interface = 4;
            static int when(int repeat, type interface) {
                return repeat + interface;
            }
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function read(h: c.ffi_keyword_holder): c.type
                    return h.when + h.interface
                        + c.when {
                            interface = c.interface,
                            repeat = c.repeat,
                        }
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("rejects contextual C selectors on Titan values and modules",
    function()
        local ok, err = run_checker([[
            record R
                x: integer
            end

            union U
                item
            end

            local function record_keyword(r: R): integer
                return r.when
            end

            local function union_keyword(u: U): integer
                return u.when
            end
        ]])
        assert.falsy(ok)
        local _, selector_errors = err:gsub(
            "Titan keyword 'when' is only contextual for a C member", "")
        assert.equal(2, selector_errors)

        ok, err = run_checker_modules({
            provider = [[
                function ordinary(): integer
                    return 1
                end
            ]],
            consumer = [[
                local m = import "provider"

                local function invalid(): integer
                    return m.when
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match(
            "Titan keyword 'when' is only contextual for a C member", err)
    end)

    it("rejects contextual C type spellings on Titan namespaces",
    function()
        local ok, err = run_checker([[
            record R
                x: integer
            end

            union U
                item
            end

            local function record_type(x: R.when)
            end

            local function union_type(x: U.when)
            end
        ]])
        assert.falsy(ok)
        local _, type_errors = err:gsub(
            "Titan keyword 'when' is only contextual for a C type", "")
        assert.equal(2, type_errors)

        ok, err = run_checker_modules({
            provider = [[
                record Item
                    x: integer
                end
            ]],
            consumer = [[
                local m = import "provider"

                local function invalid(x: m.when)
                end

                local function invalid_cast(x: value): value
                    return x as m.when
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        local _, type_errors = err:gsub(
            "Titan keyword 'when' is only contextual for a C type", "")
        assert.equal(2, type_errors)
    end)

    it("types the built-in Lua state against a canonical declaration", function()
        with_header([[
            typedef struct lua_State lua_State;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function current_state(): *c.lua_State
                    return L
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("compares a returned status with direct libuv-shaped UV_E enumerators", function()
        with_header([[
            #define UV_ERRNO_MAP(XX) \
                XX(EIO, -5) XX(EOF, -4095) XX(ECANCELED, -125)
            #define XX(code, value) UV_ ## code = value,
            typedef enum { UV_ERRNO_MAP(XX) } ffi_uv_errno_t;
            #undef XX
            static int ffi_uv_eio(void) { return UV_EIO; }
        ]], function(header)
            local ok, err = run_checker([[
                local libuv = foreign import "]] .. header .. [["

                local function is_io(): boolean
                    local status = libuv.ffi_uv_eio()
                    return (status as integer) == (libuv.UV_EIO as integer)
                        and (status as integer) ~= (libuv.UV_EOF as integer)
                        and (status as integer)
                            ~= (libuv.UV_ECANCELED as integer)
                end
            ]])
            assert.truthy(ok, err)
        end)
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
            typedef struct TValue TValue;
            typedef struct ffi_coro ffi_coro;
            extern void ffi_accept_value(TValue value);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function entry(func: (value) -> value, co: *c.ffi_coro)
                end

                local function store_entry()
                    c.ffi_accept_value(entry)
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
            extern int ffi_void_pointer(const void *value);
            extern TValue ffi_value_array[2];
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function has_pointer(v: value): integer
                    local raw: c.TValue = v
                    local p: const *c.TValue = raw
                    return (c.ffi_value_pointer(raw) as integer)
                        + (c.ffi_value_pointer(p) as integer)
                        + (c.ffi_void_pointer(raw) as integer)
                end

                function array_entry(): value
                    return c.ffi_value_array[0]
                end
            ]])
            assert.truthy(ok, err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local function bad(v: value): integer
                    return c.ffi_value_pointer(v)
                end
            ]])
            assert.falsy(ok)
            assert.match("do not match", err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local function bad(v: value): integer
                    return c.ffi_void_pointer(v)
                end
            ]])
            assert.falsy(ok)
            assert.match("do not match", err)
        end)

        with_header([[
            struct TValue;
            extern int ffi_struct_value_pointer(const struct TValue *value);
            extern struct TValue ffi_struct_value_array[2];
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function has_pointer(p: const *c.TValue): integer
                    return c.ffi_struct_value_pointer(p)
                end

                function array_entry(): value
                    return c.ffi_struct_value_array[0]
                end
            ]])
            assert.truthy(ok, err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local function bad(v: value): integer
                    return c.ffi_struct_value_pointer(v)
                end
            ]])
            assert.falsy(ok)
            assert.match("do not match", err)
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
                    local owner = c.ffi_int.new_array(3)
                    return (c.ffi_values[i] as integer)
                        + (c.ffi_ptr[0] as integer)
                        + (owner[1] as integer)
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
                    local owner = c.ffi_int.new_array(3)
                    return #c.ffi_values + #owner
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
                    local owner = c.ffi_int.new()
                    return #owner
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

    it("rejects C assignment receivers without persistent storage", function()
        with_header([[
            typedef struct ffi_inner { int x; } ffi_inner;
            typedef union ffi_payload { int x; float y; } ffi_payload;
            typedef struct ffi_outer {
                ffi_inner inner;
                int values[2];
            } ffi_outer;
            extern ffi_outer ffi_make_outer(void);
            extern ffi_payload ffi_make_payload(void);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function from_return(): integer
                    c.ffi_make_outer().inner.x = 1
                    return 0
                end

                local function from_cast(): integer
                    (c.ffi_make_outer() as c.ffi_outer).inner.x = 2
                    return 0
                end

                local function array_from_return(): integer
                    c.ffi_make_outer().values[0] = 3
                    return 0
                end

                local function union_from_return(): integer
                    c.ffi_make_payload().x = 4
                    return 0
                end
            ]])
            assert.falsy(ok)
            local _, count = err:gsub(
                "C assignment receiver must have persistent storage", "")
            assert.equal(4, count, err)
            assert.match(
                "expression of type 'ffi_outer' is a by%-value C aggregate",
                err)
            assert.match(
                "expression of type 'ffi_payload' is a by%-value C aggregate",
                err)
        end)
    end)

    it("accepts persistent nested C assignment receivers", function()
        with_header([[
            typedef struct ffi_inner { int x; } ffi_inner;
            typedef struct ffi_outer {
                ffi_inner inner;
                int values[2];
                ffi_inner *pointer_field;
                ffi_inner *pointer_array[2];
            } ffi_outer;
            extern ffi_outer ffi_global;
            extern ffi_outer ffi_array[2];
            extern ffi_outer *ffi_pointer;
            extern ffi_outer ffi_make_outer(void);
            extern ffi_outer *ffi_make_pointer(void);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function update(): integer
                    local aggregate: c.ffi_outer = c.ffi_make_outer()
                    local owner = c.ffi_outer.new()

                    c.ffi_global.inner.x = 1
                    c.ffi_global.values[0] = 2
                    c.ffi_array[0].inner.x = 3
                    c.ffi_array[1].values[0] = 4
                    c.ffi_pointer.inner.x = 5
                    c.ffi_pointer.values[0] = 6
                    c.ffi_make_pointer().inner.x = 7
                    owner.inner.x = 8
                    owner.values[0] = 9
                    aggregate.inner.x = 10
                    aggregate.values[0] = 11
                    c.ffi_outer.new().inner.x = 12
                    c.ffi_make_outer().pointer_field.x = 13
                    c.ffi_make_outer().pointer_array[0].x = 14
                    return 0
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

    it("types dotted field macros through objects and pointers", function()
        with_header(FIELD_PROJECTION_HEADER, function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                function projected_fields(): integer
                    local left = c.ffi_projection_left_value.projected
                    c.ffi_projection_left_value.projected = 19
                    local right = c.ffi_projection_right_ptr.projected
                    c.ffi_projection_right_ptr.projected = 23
                    return (left as integer) + (right as integer)
                end
            ]])
            assert.truthy(ok, err)

            local stats = ast[2].block.stats
            local fields = {
                stats[1].exps[1].var,
                stats[2].vars[1],
                stats[3].exps[1].var,
                stats[4].vars[1],
            }
            for _, field in ipairs(fields) do
                assert.equal("Type.CField", field._decl._tag)
                assert.equal("Type.CInteger", field._type._tag)
                assert.equal("projected", field._decl.name)
                assert.same({ "nested", "leaf" },
                    field._decl._macro_projection.path)
            end

            -- The macro's integer leaf wins over each physical double field.
            -- The same translation-unit macro is resolved independently
            -- against two distinct, compatible aggregate shapes.
            local left_owner = fields[1]._decl.owner
            local right_owner = fields[3]._decl.owner
            assert.not_equal(left_owner, right_owner)
            assert.equal("Type.CFloat",
                left_owner.fields.projected.type._tag)
            assert.equal("Type.CFloat",
                right_owner.fields.projected.type._tag)
            assert.equal(fields[1]._decl._macro_projection,
                fields[3]._decl._macro_projection)
        end)
    end)

    it("uses a later imported field macro in an earlier closure initializer",
    function()
        with_header([[
            typedef struct ffi_final_inner {
                int leaf;
            } ffi_final_inner;
            typedef struct ffi_final_record {
                ffi_final_inner nested;
                ffi_final_inner projected;
            } ffi_final_record;
            static ffi_final_record ffi_final_value = { { 7 }, { 99 } };
        ]], function(base_header)
            with_header([[
                #define projected nested.leaf
            ]], function(macro_header)
                local ok, err = run_checker([[
                    local base = foreign import "]] .. base_header .. [["
                    local reader = function(): integer
                        return base.ffi_final_value.projected as integer
                    end
                    local macros = foreign import "]] .. macro_header .. [["

                    function read_projected(): integer
                        return reader()
                    end
                ]])
                assert.truthy(ok, err)
            end)
        end)
    end)

    it("removes a projected field after a later imported undefinition",
    function()
        with_header([[
            typedef struct ffi_undef_leaf {
                int value;
            } ffi_undef_leaf;
            typedef struct ffi_undef_nested {
                ffi_undef_leaf leaf;
            } ffi_undef_nested;
            typedef struct ffi_undef_record {
                ffi_undef_nested nested;
                int projected;
            } ffi_undef_record;
            static ffi_undef_record ffi_undef_value = { { { 7 } }, 99 };
        ]], function(base_header)
            with_header([[
                #define projected nested.leaf
            ]], function(macro_header)
                with_header([[
                    #undef projected
                ]], function(undef_header)
                    local ok, err = run_checker([[
                        local base =
                            foreign import "]] .. base_header .. [["
                        local macros =
                            foreign import "]] .. macro_header .. [["
                        local reader = function(): integer
                            return base.ffi_undef_value.projected as integer
                        end
                        local without_macro =
                            foreign import "]] .. undef_header .. [["

                        function read_physical(): integer
                            return reader()
                        end
                    ]])
                    assert.truthy(ok, err)
                end)
            end)
        end)
    end)

    it("rejects an active unsupported object macro before physical lookup",
    function()
        with_header([[
            typedef struct ffi_unsupported_record {
                int projected;
            } ffi_unsupported_record;
            static ffi_unsupported_record ffi_unsupported_value = { 99 };
        ]], function(base_header)
            with_header([[
                #define projected 42
            ]], function(macro_header)
                local ok, err = run_checker([[
                    local base = foreign import "]] .. base_header .. [["
                    local macros = foreign import "]] .. macro_header .. [["

                    function read_physical(): integer
                        return base.ffi_unsupported_value.projected as integer
                    end
                ]])
                assert.falsy(ok)
                assert.match("active object%-like macro", err)
                assert.match("final expansion '42'", err)
                assert.match("not a supported pure dotted field projection",
                    err)
            end)
        end)
    end)

    it("does not fall back to a physical field after an invalid macro path",
    function()
        with_header(FIELD_PROJECTION_HEADER, function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function invalid_projection(): integer
                    return c.ffi_projection_bad_value.projected as integer
                end
            ]])
            assert.falsy(ok)
            assert.match(
                "C field macro 'projected' expands to 'nested%.leaf'", err)
            assert.match("not a valid physical field path", err)
            assert.match(
                "physical field 'nested' is not present in C type "
                    .. "'struct ffi_projection_bad'",
                err)
        end)
    end)

    it("types scalar cast macros and skips unsupported cast targets",
    function()
        with_header(CAST_MACRO_HEADER, function(header)
            local ok, err, ast = run_checker([[
                local c = foreign import "]] .. header .. [["

                function use_cast_macros(): integer
                    local typedef_callback: c.ffi_macro_callback =
                        c.FFI_TYPEDEF_CALLBACK
                    local direct_callback: c.ffi_macro_callback =
                        c.FFI_DIRECT_CALLBACK
                    local count: c.ffi_macro_long = c.FFI_CAST_INT
                    local fraction: c.ffi_macro_double = c.FFI_CAST_DOUBLE
                    local pointer: c.ffi_macro_int_ptr = c.FFI_CAST_POINTER

                    if typedef_callback ~= direct_callback
                       and count == c.FFI_CAST_INT
                       and fraction < 2.0
                       and pointer == c.FFI_CAST_POINTER then
                        return (typedef_callback(1) as integer)
                            + (direct_callback(1) as integer)
                            + (pointer[0] as integer)
                    end
                    return 0
                end
            ]])
            assert.truthy(ok, err)

            local members = ast[1]._type.members
            local typedef_callback =
                assert(members.FFI_TYPEDEF_CALLBACK).type
            assert.equal("Type.CTypedef", typedef_callback._tag)
            assert.equal("ffi_macro_callback", typedef_callback.name)
            assert.equal("Type.CPointer", typedef_callback.target._tag)
            assert.equal("Type.CFunction",
                typedef_callback.target.pointee._tag)

            local direct_callback =
                assert(members.FFI_DIRECT_CALLBACK).type
            assert.equal("Type.CPointer", direct_callback._tag)
            assert.equal("Type.CFunction",
                direct_callback.pointee._tag)
            assert.equal(1, #direct_callback.pointee.params)

            local integer = assert(members.FFI_CAST_INT).type
            assert.equal("Type.CInteger", integer._tag)
            assert.equal("long", integer.spelling)

            local floating = assert(members.FFI_CAST_DOUBLE).type
            assert.equal("Type.CFloat", floating._tag)
            assert.equal("double", floating.spelling)

            local pointer = assert(members.FFI_CAST_POINTER).type
            assert.equal("Type.CPointer", pointer._tag)
            assert.equal("Type.CInteger", pointer.pointee._tag)
            assert.equal("int", pointer.pointee.spelling)

            assert.is_nil(members.FFI_VOID_CAST)
            assert.is_nil(members.FFI_ARRAY_CAST)
        end)
    end)

    it("imports real POSIX signal disposition macros as function pointers",
    function()
        local ok, err, ast = run_checker([[
            local signal = foreign import "signal.h"

            function signal_dispositions_differ(): boolean
                local default_handler = signal.SIG_DFL
                local ignored_handler = signal.SIG_IGN
                return default_handler ~= ignored_handler
            end
        ]])
        assert.truthy(ok, err)

        local function resolved(typ)
            while typ and typ._tag == "Type.CTypedef" do
                typ = typ.target
            end
            return typ
        end

        local members = ast[1]._type.members
        local default_handler =
            resolved(assert(members.SIG_DFL).type)
        local ignored_handler =
            resolved(assert(members.SIG_IGN).type)
        for _, handler in ipairs({
                default_handler, ignored_handler}) do
            assert.equal("Type.CPointer", handler._tag)
            assert.equal("Type.CFunction", handler.pointee._tag)
            assert.equal(1, #handler.pointee.params)
        end
    end)

    it("imports the real POSIX errno accessor macro as an integer expression",
    function()
        local ok, err, ast = run_checker([[
            local cerrno = foreign import "errno.h"

            function current_errno(): integer
                return cerrno.errno
            end
        ]])
        assert.truthy(ok, err)

        local errno_type = assert(ast[1]._type.members.errno).type
        assert.equal("Type.CInteger", errno_type._tag)
        assert.equal("int", errno_type.spelling)
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

    it("allows owned C allocation in sound top-level initializers", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            local one = ffi.titan_ffi_int.new()
            local many = ffi.titan_ffi_int.new_array(8)
            local parenthesized_one = (ffi.titan_ffi_int.new())
            local parenthesized_many = (ffi.titan_ffi_int.new_array(4))

            function count(): integer
                return #many + #parenthesized_many
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects top-level C allocation counts that read module state", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            count = 8
            local many = ffi.titan_ffi_int.new_array(count)
        ]])
        assert.falsy(ok)
        assert.match("top level variable initialization must be constant", err)
    end)

    it("offers sizeof and alignof pseudo-members on C types", function()
        with_header([[
            typedef int ffi_int;
            typedef struct ffi_record { int value; } ffi_record;
        ]], function(header)
            local ok, err, ast = run_checker([[
            local c = foreign import "]] .. header .. [["

            function f(): integer
                return c.ffi_int.sizeof + c.ffi_record.alignof
            end
            ]])
            assert.truthy(ok, err)

            local seen = {}
            local count = 0
            local function visit(node)
                if type(node) ~= "table" or seen[node] then return end
                seen[node] = true
                if node._decl and node._decl._tag == "Type.CPseudoSize" then
                    count = count + 1
                    local source = node._decl.result_source
                    assert.equal("Type.CInteger", source._tag)
                    assert.is_false(source.signed)
                    assert.equal(
                        source._c_numeric_carriers.size_t.spelling,
                        source.spelling)
                end
                for _, child in pairs(node) do visit(child) end
            end
            visit(ast)
            assert.equal(2, count)
        end)
    end)

    it("allows source-level pointer types over imported C types", function()
        with_header([[
            typedef int ffi_int;
            typedef void ffi_void;
        ]], function(header)
            local errors = check_errs([[
            local c = foreign import "]] .. header .. [["

            local function accepted(p: const *c.ffi_int): const *c.ffi_void
                return p
            end

            local function bad(p: *integer)
            end
            ]])
            assert.equal(1, #errors, table.concat(errors, "\n"))
            assert.match("C pointer type can only point to a C FFI type",
                errors[1])
        end)
    end)

    it("coerces by-value C expressions but not values to const C pointers", function()
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
                end
            ]])
            assert.truthy(ok, err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local function bad(v: value): integer
                    return c.ffi_has_const_ptr(v)
                end
            ]])
            assert.falsy(ok)
            assert.match("do not match", err)
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
        with_header([[
            typedef void ffi_void;
            typedef int ffi_array[4];
            typedef struct ffi_incomplete ffi_incomplete;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function bad_void()
                    local v = c.ffi_void.new()
                end
                function bad_array()
                    local a = c.ffi_array.new()
                end
                function bad_incomplete()
                    local p = c.ffi_incomplete.new()
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot allocate C void", err)
            assert.match("C array typedefs", err)
            assert.match("incomplete C struct", err)
        end)
    end)

    it("requires a FAM count and rejects arrays of extended structs", function()
        with_header([[
            typedef struct ffi_packet {
                int len;
                char data[];
            } ffi_packet;
        ]], function(header)
            local prefix = [[
                local c = foreign import "]] .. header .. [["
            ]]
            local ok, err = run_checker(prefix .. [[
                function accepted()
                    local packet = c.ffi_packet.new(3)
                    packet.data[2] = 1
                    local count = #packet.data
                end
            ]])
            assert.truthy(ok, err)

            ok, err = run_checker(prefix .. [[
                function bad()
                    local packet = c.ffi_packet.new()
                end
            ]])
            assert.falsy(ok)
            assert.match("expects 1", err)

            ok, err = run_checker(prefix .. [[
                function bad()
                    local packets = c.ffi_packet.new_array(2)
                end
            ]])
            assert.falsy(ok)
            assert.match("new_array.-unavailable.-flexible array member", err)
        end)
    end)

    it("keeps later C definitions behind the module-variable frontier",
       function()
        with_header([[
            typedef struct ffi_split ffi_split;
            extern ffi_split *ffi_split_ptr;
        ]], function(forward_header)
            with_header([[
                struct ffi_split { int x; };
            ]], function(definition_header)
                local prefix = [[
                    local forward = foreign import "]] ..
                    forward_header .. [["
                ]]
                local definition = [[
                    local definition = foreign import "]] ..
                    definition_header .. [["
                ]]

                local ok, err = run_checker(prefix .. [[
                    local owner = forward.ffi_split.new()
                ]] .. definition)
                assert.falsy(ok)
                assert.match("cannot allocate incomplete C struct", err)

                ok, err = run_checker(prefix .. [[
                    local read = function(): integer
                        return forward.ffi_split_ptr.x as integer
                    end
                ]] .. definition)
                assert.falsy(ok)
                assert.match("field 'x' not found in C type", err)

                ok, err = run_checker(prefix .. definition .. [[
                    local owner = forward.ffi_split.new()
                ]])
                assert.truthy(ok, err)

                ok, err = run_checker(prefix .. [[
                    function read(): integer
                        local owner = forward.ffi_split.new()
                        return owner.x as integer
                    end
                ]] .. definition)
                assert.truthy(ok, err)
            end)
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
            local ok, err, tree = run_checker([[
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
            local members = tree[1]._type.members
            assert.equal("Type.CFunction", members.ffi_add1.type._tag)
            assert.equal("Type.CFunction", members.call_callback.type._tag)
            local callback = types.resolve_c_typedef(
                tree[2].params[1]._type)
            assert.equal("Type.CPointer", callback._tag)
            assert.equal("Type.CFunction", callback.pointee._tag)

            local calls, seen = {}, {}
            local function collect(value)
                if type(value) ~= "table" or seen[value] then return end
                seen[value] = true
                if value._tag == "Ast.ExpCall" then
                    calls[#calls + 1] = value
                end
                for key, child in pairs(value) do
                    if type(key) == "number"
                       or (type(key) == "string"
                           and key:sub(1, 1) ~= "_") then
                        collect(child)
                    end
                end
            end
            collect(tree)
            local c_calls, pointer_calls = 0, 0
            for _, call in ipairs(calls) do
                if call._callee_type
                   and call._callee_type._tag == "Type.CFunction" then
                    c_calls = c_calls + 1
                    if call._c_pointer_call then
                        pointer_calls = pointer_calls + 1
                        assert.equal(call._callee_type,
                            call._c_pointer_call)
                    else
                        assert.equal(call._callee_type,
                            call.exp._type)
                    end
                end
            end
            assert.equal(3, c_calls)
            assert.equal(1, pointer_calls)
        end)
    end)

    it("rejects direct C declarations in every Titan value context", function()
        with_header("extern int ffi_call(int value);\n", function(header)
            local prefix =
                'local c = foreign import "' .. header .. '"\n'
            local function assert_rejected(source)
                local ok, err = run_checker(prefix .. source)
                assert.falsy(ok)
                assert.match(
                    "a foreign %(C%) function cannot be used as a first%-class value",
                    err)
            end

            for _, body in ipairs({
                "local f = c.ffi_call",
                "local f: (integer) -> integer = c.ffi_call",
                "local v: value = c.ffi_call",
                "local fs: {(integer) -> integer} = { c.ffi_call }",
            }) do
                assert_rejected(
                    "function run(): nil\n" .. body ..
                    "\nreturn nil\nend\n")
            end

            assert_rejected([[
                local function take(f: (integer) -> integer): nil
                    return nil
                end
                function run(): nil
                    take(c.ffi_call)
                    return nil
                end
            ]])
            assert_rejected([[
                local function produce(): value
                    return c.ffi_call
                end
                function run(): nil
                    produce()
                    return nil
                end
            ]])
        end)
    end)

    it("keeps C allocation pseudo-members out of callable values", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"

            function run(): value
                return ffi.titan_ffi_int.new_array
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "C allocation pseudo%-member 'new_array' can only be called directly",
            err)
    end)

    it("keeps function-pointer and pseudo-constructor positional arity strict",
    function()
        with_header([[
            typedef int ffi_int;
            typedef int (*ffi_callback)(int, int);
        ]], function(header)
            local errs = check_errs([[
                local c = foreign import "]] .. header .. [["

                local function use(cb: c.ffi_callback): nil
                    cb(1)
                    cb(1, 2, 3)
                    local one = c.ffi_int.new(1)
                    local many = c.ffi_int.new_array()
                    local too_many = c.ffi_int.new_array(1, 2)
                    return nil
                end
            ]])
            local all = table.concat(errs, "\n")
            assert.same(5, #errs)
            assert.match("function pointer 'cb' called with 1 arguments but expects 2",
                all)
            assert.match("function pointer 'cb' called with 3 arguments but expects 2",
                all)
            assert.match("ffi_int%.new' called with 1 arguments but expects 0", all)
            assert.match("ffi_int%.new_array' called with 0 arguments but expects 1",
                all)
            assert.match("ffi_int%.new_array' called with 2 arguments but expects 1",
                all)
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

    it("keeps C function pointers boxed out of value but permits explicit void casts", function()
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
            assert.truthy(ok, err)

            ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function f(cb: c.ffi_callback): c.ffi_vptr
                    return cb
                end
            ]])
            assert.falsy(ok)
            assert.match("types in return do not match", err)
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

    it("rejects only used enums whose compiler carrier exceeds " ..
       "lua_Integer", function()
        with_header([[
            typedef enum { FFI_SAFE_ZERO = 0,
                           FFI_SAFE_HIGH = 0xffffffffU } ffi_safe_enum;
            typedef enum { FFI_WIDE_ZERO = 0,
                           FFI_WIDE_HIGH = 0x8000000000000000ULL }
                ffi_wide_enum;
            enum ffi_named_wide_enum {
                FFI_NAMED_WIDE_ZERO = 0,
                FFI_NAMED_WIDE_HIGH = 0x8000000000000000ULL
            };
            static enum { FFI_OBJECT_ZERO = 0,
                          FFI_OBJECT_ONE = 1 } ffi_enum_object;
            static ffi_safe_enum ffi_safe_take(ffi_safe_enum value) {
                return value;
            }
            static ffi_wide_enum ffi_wide_take(ffi_wide_enum value) {
                return value;
            }
            typedef ffi_wide_enum (*ffi_wide_callback)(void);
            static ffi_wide_enum ffi_wide_result(void) {
                return FFI_WIDE_HIGH;
            }
            static ffi_wide_callback ffi_wide_pointer(void) {
                return ffi_wide_result;
            }
        ]], function(header)
            local accepted_ok, accepted_err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function safe(): integer
                    return c.ffi_safe_take(c.FFI_SAFE_HIGH) as integer
                end

                local function wide_zero(): integer
                    return c.FFI_WIDE_ZERO as integer
                end

                local function named_zero(): integer
                    return c.FFI_NAMED_WIDE_ZERO as integer
                end

                local function object_value(): integer
                    return c.ffi_enum_object as integer
                end

                local function address_only(): integer
                    local callback: c.ffi_wide_callback = c.ffi_wide_result
                    local returned_callback = c.ffi_wide_pointer()
                    return 1
                end
            ]])
            assert.truthy(accepted_ok, accepted_err)

            local rejected_ok, rejected_err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function high(): integer
                    return c.FFI_WIDE_HIGH as integer
                end

                local function named_high(): integer
                    return c.FFI_NAMED_WIDE_HIGH as integer
                end

                local function wide_value(): integer
                    return c.ffi_wide_take(c.FFI_WIDE_ZERO) as integer
                end

                local function address_call(): integer
                    local callback: c.ffi_wide_callback = c.ffi_wide_result
                    return callback() as integer
                end

                local function pointer_call(): integer
                    local callback = c.ffi_wide_pointer()
                    return callback() as integer
                end
            ]])
            assert.falsy(rejected_ok)
            assert.truthy(rejected_err:find(
                "C enumerator 'FFI_WIDE_HIGH' is outside the range of " ..
                    "lua_Integer", 1, true), rejected_err)
            assert.truthy(rejected_err:find(
                "C enumerator 'FFI_NAMED_WIDE_HIGH' is outside the range " ..
                    "of lua_Integer", 1, true), rejected_err)
            local _, wide_carrier_errors = rejected_err:gsub(
                "full range fits in lua_Integer", "")
            assert.equal(3, wide_carrier_errors)
            assert.falsy(rejected_err:find("cannot cast", 1, true),
                rejected_err)
        end)
    end)

    it("validates enum carriers at the exact value and declarator boundary",
    function()
        with_header([[
            typedef enum { FFI_PTR_ZERO = 0,
                           FFI_PTR_WIDE = 0x8000000000000000ULL }
                ffi_pointer_wide_enum;
            typedef enum { FFI_OWNER_A = 1 } ffi_owner_a;
            typedef enum { FFI_OWNER_B = 2 } ffi_owner_b;
            static ffi_owner_b ffi_take_b(ffi_owner_b value) {
                return value;
            }
            static int ffi_take_int(int value) { return value; }
            static int ffi_prototype_pointer(enum ffi_local_tag *value) {
                return value == 0;
            }
            typedef int (*ffi_prototype_callback)(
                enum ffi_callback_local_tag *value);
            static ffi_prototype_callback ffi_get_prototype_callback(void) {
                return 0;
            }
        ]], function(header)
            local pointer_ok, pointer_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local type Wide = c.ffi_pointer_wide_enum
                local type DirectWidePointer = *c.ffi_pointer_wide_enum
                local type AliasWidePointer = *Wide
                local type OptionalWide = Wide?
                local type ArrayWide = {Wide}
                local type MapWide = {string: Wide}
                local type FunctionWide = (Wide) -> integer
            ]])
            assert.truthy(pointer_ok, pointer_err)

            local unused_alias_ok, unused_alias_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local type UnusedWide = c.ffi_pointer_wide_enum
                function f(): integer return 1 end
            ]])
            assert.truthy(unused_alias_ok, unused_alias_err)

            for _, composite in ipairs({
                [[
                    local type Composite = {Wide}
                    function f(): integer
                        local items: Composite = { c.FFI_PTR_ZERO }
                        return #items
                    end
                ]],
                [[
                    local type Composite = {string: Wide}
                    function f(): integer
                        local items: Composite = {
                            ["item"] = c.FFI_PTR_ZERO,
                        }
                        return 1
                    end
                ]],
            }) do
                local composite_ok, composite_err = run_checker(
                    "local c = foreign import " .. string.format("%q", header)
                    .. "\nlocal type Wide = c.ffi_pointer_wide_enum\n"
                    .. composite)
                assert.falsy(composite_ok)
                assert.truthy(composite_err:find(
                    "full range fits in lua_Integer", 1, true),
                    composite_err)
            end

            local option_value_ok, option_value_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local type Wide = c.ffi_pointer_wide_enum
                local type OptionalWide = Wide?
                function f(): integer
                    local item: OptionalWide = nil
                    return 1
                end
            ]])
            assert.falsy(option_value_ok)
            assert.truthy(option_value_err:find(
                "full range fits in lua_Integer", 1, true), option_value_err)

            local alias_value_ok, alias_value_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                local type Wide = c.ffi_pointer_wide_enum
                function f(): integer
                    local item: Wide = c.FFI_PTR_ZERO
                    return item as integer
                end
            ]])
            assert.falsy(alias_value_ok)
            assert.truthy(alias_value_err:find(
                "full range fits in lua_Integer", 1, true), alias_value_err)

            local direct_ok, direct_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                function f(): integer
                    return c.ffi_prototype_pointer(nil) as integer
                end
            ]])
            assert.falsy(direct_ok)
            assert.truthy(direct_err:find(
                "has no usable declaration spelling", 1, true), direct_err)

            local callback_ok, callback_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                function f(): integer
                    local callback = c.ffi_get_prototype_callback()
                    return callback(nil) as integer
                end
            ]])
            assert.falsy(callback_ok)
            assert.truthy(callback_err:find(
                "has no usable declaration spelling", 1, true), callback_err)

            local owner_ok, owner_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                function f(): integer
                    return c.ffi_take_b(c.FFI_OWNER_A) as integer
                end
            ]])
            assert.falsy(owner_ok)
            assert.truthy(owner_err:find(
                "types in argument 1", 1, true), owner_err)

            local integer_ok, integer_err = run_checker([[
                local c = foreign import "]] .. header .. [["
                function f(): integer
                    return c.ffi_take_int(c.FFI_OWNER_A) as integer
                end
            ]])
            assert.falsy(integer_ok)
            assert.truthy(integer_err:find(
                "types in argument 1", 1, true), integer_err)
        end)
    end)

    it("completes a forward enum in a later ordered header", function()
        with_header([[
            #ifndef FFI_FORWARD_ENUM_HEADER
            #define FFI_FORWARD_ENUM_HEADER
            enum ffi_forward_enum;
            typedef enum ffi_forward_enum ffi_forward_enum;
            #endif
        ]], function(forward_header)
            with_header([[
                enum ffi_forward_enum {
                    FFI_FORWARD_ZERO = 0,
                    FFI_FORWARD_ONE = 1
                };
                typedef enum ffi_forward_enum ffi_forward_enum;
                static ffi_forward_enum ffi_forward_take(
                    ffi_forward_enum value) {
                    return value;
                }
            ]], function(definition_header)
                local ok, err = run_checker([[
                    local prior = foreign import "]] .. forward_header .. [["
                    local complete = foreign import "]] .. definition_header .. [["
                    function f(): integer
                        local item: prior.ffi_forward_enum =
                            complete.FFI_FORWARD_ONE
                        return complete.ffi_forward_take(item) as integer
                    end
                ]])
                assert.truthy(ok, err)
            end)
        end)
    end)

    it("checks enum carrier spelling in the final direct-header context",
    function()
        with_header([[
            enum ffi_context_tag { FFI_CONTEXT_VALUE = 7 };
            typedef enum ffi_context_tag ffi_context_typedef;
            static ffi_context_typedef ffi_context_typedef_value(void) {
                return FFI_CONTEXT_VALUE;
            }
            static enum ffi_context_tag ffi_context_tag_value(void) {
                return FFI_CONTEXT_VALUE;
            }
        ]], function(enum_header)
            with_header([[
                #define ffi_context_tag ffi_context_shadow
            ]], function(shadow_header)
                local typedef_ok, typedef_err = run_checker([[
                    local c = foreign import "]] .. enum_header .. [["
                    local shadow = foreign import "]] .. shadow_header .. [["
                    function f(): integer
                        return c.ffi_context_typedef_value() as integer
                    end
                ]])
                assert.truthy(typedef_ok, typedef_err)

                local tag_ok, tag_err = run_checker([[
                    local c = foreign import "]] .. enum_header .. [["
                    local shadow = foreign import "]] .. shadow_header .. [["
                    function f(): integer
                        return c.ffi_context_tag_value() as integer
                    end
                ]])
                assert.falsy(tag_ok)
                assert.truthy(tag_err:find(
                    "C enum type", 1, true), tag_err)
            end)
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

    it("matches decimal and hexadecimal C limit macro ranks", function()
        with_header([[
            #define FFI_LONG_MAX 0x7fffffffffffffffL
            #define FFI_LONG_MIN (-0x7fffffffffffffffL - 1)
            #define FFI_LLONG_MAX 0x7fffffffffffffffLL
            #define FFI_LLONG_MIN (-0x7fffffffffffffffLL - 1)
            #define FFI_ULONG_MAX 0xffffffffffffffffUL
            #define FFI_ULLONG_MAX 0xffffffffffffffffULL
        ]], function(header1)
            with_header([[
                #define FFI_LONG_MAX 9223372036854775807L
                #define FFI_LONG_MIN (-9223372036854775807L - 1)
                #define FFI_LLONG_MAX 9223372036854775807LL
                #define FFI_LLONG_MIN (-9223372036854775807LL - 1)
                #define FFI_ULONG_MAX 18446744073709551615UL
                #define FFI_ULLONG_MAX 18446744073709551615ULL
            ]], function(header2)
                local ok, err = run_checker([[
                    local c1 = foreign import "]] .. header1 .. [["
                    local c2 = foreign import "]] .. header2 .. [["

                    local function limits(): integer
                        return (c1.FFI_LONG_MAX as integer) +
                               (c2.FFI_LLONG_MIN as integer)
                    end
                ]])
                assert.truthy(ok, err)
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

    it("uses one TValue-slot representation rule for records and unions",
    function()
        with_header([[
            typedef struct ffi_struct { int value; } ffi_struct;
            typedef union ffi_union {
                int integer_value;
                double number;
            } ffi_union;
            typedef int ffi_values[2];
            typedef int (*ffi_callback)(int);
        ]], function(header)
            -- Bare C function typedefs are deliberately omitted by the C
            -- parser; the direct Type.CFunction predicate branch is covered
            -- in types_spec.lua.
            local errs = check_errs([[
                local c = foreign import "]] .. header .. [["

                local record RecordSlots
                    structure: c.ffi_struct
                    aggregate: c.ffi_union
                    values: c.ffi_values
                    callback: c.ffi_callback
                end

                local union UnionSlots
                    structure: c.ffi_struct
                    aggregate: c.ffi_union
                    values: c.ffi_values
                    callback: c.ffi_callback
                end
            ]])
            assert.same(8, #errs)
            local all = table.concat(errs, "\n")
            for _, member in ipairs({
                "structure", "aggregate", "values", "callback",
            }) do
                assert.match(
                    "record field '" .. member ..
                        "'.-has no TValue representation", all)
                assert.match(
                    "union variant '" .. member ..
                        "'.-has no TValue representation", all)
            end
        end)
    end)

    it("accepts boxable C payloads and hides local C union variants",
    function()
        with_header([[
            typedef int ffi_count;
            typedef struct ffi_handle { int value; } ffi_handle;
            typedef struct TValue TValue;
            typedef struct Udata Udata;
        ]], function(header)
            local ok, err, _, modtype = run_checker([[
                local c = foreign import "]] .. header .. [["

                record Slots
                    local count: c.ffi_count
                    local handle: *c.ffi_handle
                    local raw: c.TValue
                    local userdata: *c.Udata
                    local owner: owned *c.ffi_handle
                end

                union Message
                    visible: integer
                    local count: c.ffi_count
                    local handle: *c.ffi_handle
                    local raw: c.TValue
                    local userdata: *c.Udata
                    local owner: owned *c.ffi_handle
                end
            ]])
            assert.truthy(ok, err)
            local union = modtype.members.Message.type
            assert.equal(6, union.nvariants)
            for _, name in ipairs({
                "count", "handle", "raw", "userdata", "owner",
            }) do
                assert.truthy(union.variants[name].islocal)
            end
        end)
    end)

    it("rejects C FFI types exposed by public union variants", function()
        with_header("typedef int ffi_count;\n", function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                union Message
                    count: c.ffi_count
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot export C FFI type 'ffi_count'", err)
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
