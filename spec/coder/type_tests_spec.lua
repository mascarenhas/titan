local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"

local function clean()
    for _, path in ipairs({
        "test.c",
        "test.o",
        "test.so",
        "test.a",
        "test.lua",
    }) do
        os.remove(path)
    end
    os.execute("rm -rf test.so.dSYM")
end

local function with_header(contents, body)
    local path = temporary.name(".h")
    local file = assert(io.open(path, "w"))
    file:write(contents)
    file:close()

    local results = table.pack(pcall(body, path))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

describe("type-test expressions (code generator)", function()
    after_each(clean)

    it("tests boxed values, exact identities, and option unwraps", function()
        h.run_coder([[
            record First
                n: integer
            end
            record Second
                n: integer
            end
            type IntFunction = function (integer): integer

            calls: integer = 0
            certain: boolean = 1 is integer

            local function next_value(v: value): value
                calls = calls + 1
                return v
            end
            local function fail(): value
                raise "operand failed"
            end

            function is_integer(v: value): boolean
                return v is integer
            end
            function is_float(v: value): boolean
                return v is float
            end
            function is_boolean(v: value): boolean
                return v is boolean
            end
            function is_function(v: value): boolean
                return v is function (integer): integer
            end
            function is_nil(v: value): boolean
                return v is nil
            end
            function is_string(v: value): boolean
                return v is string
            end
            function is_array(v: value): boolean
                return v is {integer}
            end
            function is_map(v: value): boolean
                return v is {integer: integer}
            end
            function is_first(v: value): boolean
                return v is First
            end
            function is_optional_integer(v: value): boolean
                return v is integer?
            end
            function is_optional_boolean(v: value): boolean
                return v is boolean?
            end
            function as_optional_boolean(v: value): boolean?
                return v as boolean?
            end
            function is_optional_function(v: value): boolean
                return v is IntFunction?
            end
            function identity(i: integer): boolean
                return i is integer
            end
            function constant_test(): boolean
                return certain
            end
            function optional(i: integer?): boolean
                return i is integer
            end
            function once(v: value): (boolean, integer)
                calls = 0
                local result = next_value(v) is integer
                return result, calls
            end
            function propagates_operand_error(): boolean
                return fail() is integer
            end
            function array(): {integer}
                return {1, 2}
            end
            function first(): First
                return First.new(1)
            end
            function second(): Second
                return Second.new(2)
            end
        ]], [[
            assert(test.is_integer(42))
            assert(test.is_integer(42.0))
            assert(not test.is_integer(42.5))
            assert(not test.is_integer(math.huge))
            assert(not test.is_integer(0 / 0))
            assert(not test.is_integer(math.maxinteger + 0.0))
            assert(not test.is_integer("42"))

            assert(test.is_float(42))
            assert(test.is_float(42.5))
            assert(not test.is_float("42"))

            -- These casts perform no dynamic validation. Function-typed
            -- values defer callability errors until an actual invocation.
            assert(test.is_boolean(nil))
            assert(test.is_boolean({}))
            assert(test.is_function(nil))
            assert(test.is_function("not callable"))
            assert(test.is_function({}))

            assert(test.is_nil(nil))
            assert(not test.is_nil(false))
            assert(test.is_string("text"))
            assert(not test.is_string({}))

            local array = test.array()
            assert(test.is_array(array))
            assert(not test.is_array({1, 2}))
            assert(test.is_map({[1] = 2}))
            assert(not test.is_map(array))

            local first = test.first()
            assert(test.is_first(first))
            assert(not test.is_first(test.second()))
            assert(not test.is_first(io.stdout))

            assert(test.is_optional_integer(nil))
            assert(test.is_optional_integer(42))
            assert(test.is_optional_integer(42.0))
            assert(not test.is_optional_integer(42.5))

            -- Option delegates its present arm to the same target-directed
            -- dynamic conversion as the non-optional target.
            assert(test.is_optional_boolean(nil))
            assert(test.is_optional_boolean(false))
            assert(test.is_optional_boolean(1))
            assert(test.is_optional_boolean("truthy"))
            assert(test.as_optional_boolean(nil) == nil)
            assert(test.as_optional_boolean(false) == false)
            assert(test.as_optional_boolean(1) == true)
            assert(test.as_optional_boolean("truthy") == true)
            -- Function slots remain deliberately unchecked.
            assert(test.is_optional_function(nil))
            assert(test.is_optional_function("not callable"))

            assert(test.identity(1))
            assert(test.constant_test())
            assert(test.optional(1))
            assert(not test.optional(nil))

            local yes, yes_calls = test.once(42)
            local no, no_calls = test.once("42")
            assert(yes and yes_calls == 1)
            assert(not no and no_calls == 1)

            local ok, err = pcall(test.propagates_operand_error)
            assert(not ok)
            assert(tostring(err):find("operand failed", 1, true))
        ]])
    end)

    it("mirrors boxed C checks and nullable pointer-to-string casts", function()
        with_header([[
            typedef int test_integer;
            typedef double test_float;
            typedef void *test_pointer;
            typedef struct TValue TValue;
            typedef struct Udata Udata;

            static char *test_maybe_string(int present) {
                return present ? (char *)"present" : (char *)0;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function is_c_integer(v: value): boolean
                    return v is foreign test_integer
                end
                function is_c_float(v: value): boolean
                    return v is foreign test_float
                end
                function is_c_pointer(v: value): boolean
                    return v is foreign test_pointer
                end
                function as_c_pointer(v: value): boolean
                    local pointer = v as foreign test_pointer
                    return pointer ~= nil
                end
                function is_c_userdata(v: value): boolean
                    return v is foreign *Udata
                end
                function is_c_tvalue(v: value): boolean
                    return v is foreign TValue
                end
                function has_string(present: integer): boolean
                    return ffi.test_maybe_string(present as foreign test_integer)
                        is string
                end
            ]], [[
                assert(test.is_c_integer(42))
                assert(test.is_c_integer(42.0))
                assert(not test.is_c_integer(42.5))
                assert(not test.is_c_integer("42"))

                assert(test.is_c_float(42))
                assert(test.is_c_float(42.5))
                assert(not test.is_c_float("42"))

                local captured = 1
                local function capture() return captured end
                local pointer_value = debug.upvalueid(capture, 1)
                assert(test.is_c_pointer(nil))
                assert(test.is_c_pointer(pointer_value))
                assert(not test.is_c_pointer("pointer"))
                assert(not test.as_c_pointer(nil))
                assert(test.as_c_pointer(pointer_value))

                assert(test.is_c_userdata(nil))
                assert(test.is_c_userdata(test))
                assert(test.is_c_userdata(io.stdout))
                assert(not test.is_c_userdata({}))

                assert(test.is_c_tvalue(nil))
                assert(test.is_c_tvalue("anything"))
                assert(test.is_c_tvalue({}))

                assert(test.has_string(1))
                assert(not test.has_string(0))
            ]])
        end)
    end)

    it("materializes by-value C aggregates without scalar initialization", function()
        with_header([[
            typedef struct test_pair {
                int first;
                int second;
            } test_pair;

            typedef union test_number {
                int integer;
                double floating;
            } test_number;

            static test_pair test_pair_value(void) {
                test_pair pair = { 1, 2 };
                return pair;
            }

            static test_number test_number_value(void) {
                test_number number;
                number.integer = 3;
                return number;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function is_pair(): boolean
                    return ffi.test_pair_value() is foreign test_pair
                end

                function is_number(): boolean
                    return ffi.test_number_value() is foreign test_number
                end
            ]], [[
                assert(test.is_pair())
                assert(test.is_number())
            ]])
        end)
    end)
end)
