local h = require 'spec.support.helpers'

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

describe("C FFI code generation", function()
    it("passes the built-in lua_State pointer L to C functions", function()
        with_header([[
            typedef struct lua_State lua_State;
            static int ffi_has_state(lua_State *state) { return state != 0; }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function has_state(): integer
                    return c.ffi_has_state(L)
                end
            ]], [[
                assert(test.has_state() == 1)
            ]])
        end)
    end)

    it("round-trips by-value TValue through C helpers", function()
        with_header([[
            typedef struct TValue TValue;

            static TValue ffi_value_echo(TValue value) {
                return value;
            }

            static int ffi_value_kind(TValue value) {
                if (ttisnil(&value)) return 1;
                if (ttisboolean(&value)) return 2;
                if (ttisinteger(&value)) return 3;
                if (ttisfloat(&value)) return 4;
                if (ttisstring(&value)) return 5;
                if (ttistable(&value)) return 6;
                if (ttisfunction(&value)) return 7;
                if (ttisfulluserdata(&value)) return 8;
                return 0;
            }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                record Box
                    x: integer
                end

                local function echo(x: value): value
                    return x
                end

                function nil_rounds(): value
                    return c.ffi_value_echo(nil)
                end

                function integer_rounds(): value
                    return c.ffi_value_echo(42)
                end

                function string_rounds(): value
                    return c.ffi_value_echo("titan")
                end

                function array_kind(): integer
                    local xs = { 1, 2, 3 }
                    return c.ffi_value_kind(xs)
                end

                function map_kind(): integer
                    local xs = { ["a"] = 1 }
                    return c.ffi_value_kind(xs)
                end

                function record_kind(): integer
                    return c.ffi_value_kind(Box.new(17))
                end

                function function_rounds(): value
                    return c.ffi_value_echo(echo)
                end
            ]], [[
                assert(test.nil_rounds() == nil)
                assert(test.integer_rounds() == 42)
                assert(test.string_rounds() == "titan")
                assert(test.array_kind() == 6)
                assert(test.map_kind() == 6)
                assert(test.record_kind() == 8)
                assert(test.function_rounds()("ok") == "ok")
            ]])
        end)
    end)

    it("indexes C arrays, C pointers, and counted owned C arrays with 0-based indices", function()
        with_header([[
            typedef int ffi_int;
            static int ffi_values[4] = { 10, 20, 30, 40 };
            static int *ffi_ptr = ffi_values;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function sum(): integer
                    local owned = c.ffi_int.new_array(3)
                    c.ffi_values[2] = 12
                    owned[1] = 5
                    return (c.ffi_values[2] as integer)
                        + (c.ffi_ptr[3] as integer)
                        + (owned[1] as integer)
                        + #c.ffi_values
                        + #owned
                end
            ]], [[
                assert(test.sum() == 64)
            ]])
        end)
    end)

    it("bounds-checks static C arrays", function()
        with_header([[
            static int ffi_values[4] = { 10, 20, 30, 40 };
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function bad(): integer
                    return c.ffi_values[4] as integer
                end
            ]], [[
                test.bad()
            ]], "C index")
        end)
    end)

    it("reads C struct fields and fields through C pointers and owned objects", function()
        with_header([[
            typedef struct ffi_point { int x; int y; } ffi_point;
            static ffi_point ffi_origin = { 7, 11 };
            static ffi_point *ffi_origin_ptr = &ffi_origin;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function sum(): integer
                    return (c.ffi_origin.x as integer)
                        + (c.ffi_origin_ptr.y as integer)
                end

                function zero(): integer
                    local p = c.ffi_point.new()
                    p.x = 19
                    p.y = 23
                    return (p.x as integer) + (p.y as integer)
                end
            ]], [[
                assert(test.sum() == 18)
                assert(test.zero() == 42)
            ]])
        end)
    end)

    it("generates field access for named C structs completed after forward typedefs", function()
        with_header([[
            typedef struct ffi_node ffi_node;
            typedef ffi_node *ffi_node_ref;
            struct ffi_node { int x; ffi_node *next; };
            static ffi_node ffi_tail = { 5, 0 };
            static ffi_node ffi_head = { 7, &ffi_tail };
            static ffi_node *ffi_head_ptr = &ffi_head;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                local function next_node(): c.ffi_node_ref
                    return c.ffi_head_ptr.next
                end

                function sum(): integer
                    return (c.ffi_head_ptr.x as integer)
                        + (next_node().x as integer)
                end
            ]], [[
                assert(test.sum() == 12)
            ]])
        end)
    end)

    it("preserves typedef spelling for owned anonymous C structs", function()
        with_header([[
            typedef struct { int x; int y; } ffi_point;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function sum(): integer
                    local p = c.ffi_point.new()
                    p.x = 17
                    p.y = 25
                    return (p.x as integer) + (p.y as integer)
                end
            ]], [[
                assert(test.sum() == 42)
            ]])
        end)
    end)

    it("passes owned C arrays and Titan strings to C vararg functions", function()
        h.run_coder([[
            local ffi = foreign import "titan/ffi.h"
            local stdio = foreign import "stdio.h"

            function formatted_len(s: string): integer
                local buf = ffi.titan_ffi_char.new_array(32)
                return stdio.snprintf(buf, 32, "%s", s)
            end

            function formatted_owned_len(): integer
                local out = ffi.titan_ffi_char.new_array(32)
                local msg = ffi.titan_ffi_char.new_array(3)
                msg[0] = 79 as ffi.titan_ffi_char
                msg[1] = 75 as ffi.titan_ffi_char
                msg[2] = 0 as ffi.titan_ffi_char
                return stdio.snprintf(out, 32, "%s", msg)
            end
        ]], [[
            assert(test.formatted_len("abc") == 3)
            assert(test.formatted_len("titan") == 5)
            assert(test.formatted_owned_len() == 2)
        ]])
    end)

    it("uses runtime truthiness for C pointer typedefs", function()
        with_header([[
            typedef int *ffi_iptr;
            static int ffi_value = 42;
            static ffi_iptr ffi_null = 0;
            static ffi_iptr ffi_ptr = &ffi_value;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function null_and(): integer
                    return (c.ffi_null and 99) or 7
                end

                function nonnull_and(): integer
                    return (c.ffi_ptr and 99) or 7
                end
            ]], [[
                assert(test.null_and() == 7)
                assert(test.nonnull_and() == 99)
            ]])
        end)
    end)

    it("calls static header functions and C function pointer values", function()
        with_header([[
            typedef int (*ffi_callback)(int);

            static int ffi_add1(int x) {
                return x + 1;
            }

            static int ffi_apply(ffi_callback cb, int x) {
                return cb(x) + 3;
            }

            static ffi_callback ffi_choose(void) {
                return ffi_add1;
            }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function sum(): integer
                    local cb: c.ffi_callback = c.ffi_add1
                    local chosen = c.ffi_choose()
                    return (c.ffi_add1(1) as integer)
                        + (cb(4) as integer)
                        + (c.ffi_apply(c.ffi_add1, 5) as integer)
                        + (chosen(6) as integer)
                end
            ]], [[
                assert(test.sum() == 23)
            ]])
        end)
    end)

    it("raises on NULL C function pointer calls", function()
        with_header([[
            typedef int (*ffi_callback)(int);
            static ffi_callback ffi_null_cb = 0;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function bad(): integer
                    return c.ffi_null_cb(1) as integer
                end
            ]], [[
                test.bad()
            ]], "NULL C function pointer")
        end)
    end)

    it("raises on NULL C pointer field access and indexing", function()
        with_header([[
            typedef struct ffi_point { int x; } ffi_point;
            static ffi_point *ffi_null_point = 0;
            static int *ffi_null_int = 0;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function bad_field(): integer
                    return c.ffi_null_point.x as integer
                end
            ]], [[
                test.bad_field()
            ]], "NULL C pointer")

            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function bad_index(): integer
                    return c.ffi_null_int[0] as integer
                end
            ]], [[
                test.bad_index()
            ]], "NULL C pointer")
        end)
    end)

    it("checks owned C userdata identity when casting from value", function()
        with_header([[
            typedef struct ffi_point { int x; } ffi_point;
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                record R
                    x: integer
                end

                function bad(): integer
                    local p = c.ffi_point.new()
                    local v: value = R.new(7)
                    p = v
                    return p.x as integer
                end
            ]], [[
                test.bad()
            ]], "expected owned")
        end)
    end)

    it("casts C char pointers to Titan strings with a NULL guard", function()
        h.run_coder([[
            local stdlib = foreign import "stdlib.h"

            function path(): string
                return stdlib.getenv("PATH") as string
            end
        ]], [[
            local p = test.path()
            assert(type(p) == "string")
            assert(#p > 0)
        ]])
    end)
end)
