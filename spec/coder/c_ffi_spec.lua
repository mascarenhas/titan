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
