local h = require "spec.support.helpers"

local MODULE = "ffi_operators"

local function clean_module()
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua",
        "__entrypoint.c", "__entrypoint.o",
    }) do
        os.remove(MODULE .. suffix)
    end
    os.execute("rm -rf " .. MODULE .. ".so.dSYM")
    os.execute("rm -rf " .. MODULE .. ".dSYM")
end

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function native_body(csrc, name)
    return assert(csrc:match(
        "[^\n]*ffi_operators_" .. name .. "_titan%b()%s*(%b{})"))
end

local declarations = [[
    typedef unsigned char ffi_uchar;
    typedef unsigned int ffi_uint;
    typedef unsigned long ffi_ulong;
    typedef float ffi_float;

    #define FFI_UINT_MAX 0xffffffffU

    static int ffi_neg_seven(void) { return -7; }
    static int ffi_three(void) { return 3; }
    static ffi_uint ffi_uint_max(void) { return FFI_UINT_MAX; }
    static ffi_uint ffi_uint_one(void) { return 1U; }
    static ffi_uint ffi_uint_zero(void) { return 0U; }
    static ffi_uchar ffi_uchar_max(void) { return 255U; }
    static ffi_uchar ffi_uchar_one(void) { return 1U; }
    static ffi_ulong ffi_ulong_three(void) { return 3UL; }
    static ffi_float ffi_float_one(void) { return 1.0f; }
    static ffi_uint ffi_bits_a(void) { return 0xf0U; }
    static ffi_uint ffi_bits_b(void) { return 0xaaU; }
    static ffi_uint ffi_bits_low(void) { return 0x0fU; }

    static int ffi_values[4] = { 11, 22, 33, 44 };
    static int ffi_read_int(const int *value) { return *value; }
    static int *ffi_begin(void) { return ffi_values; }
    static int *ffi_end(void) { return ffi_values + 4; }
    static int *ffi_null(void) { return (int *)0; }

    typedef struct ffi_item { int value; } ffi_item;
    typedef struct ffi_other { int value; } ffi_other;
    static union {
        ffi_item item;
        ffi_other other;
    } ffi_shared;
    static ffi_item *ffi_as_item(void) { return &ffi_shared.item; }
    static ffi_other *ffi_as_other(void) { return &ffi_shared.other; }

    typedef int (*ffi_callback)(int value);
    static int ffi_callback_impl(int value) { return value + 1; }
    static ffi_callback ffi_callback_a(void) {
        return ffi_callback_impl;
    }
    static ffi_callback ffi_callback_b(void) {
        return ffi_callback_impl;
    }

    static int ffi_evaluation_log;
    static void ffi_reset_log(void) { ffi_evaluation_log = 0; }
    static int ffi_left(void) {
        ffi_evaluation_log = ffi_evaluation_log * 10 + 1;
        return 1;
    }
    static int ffi_right(void) {
        ffi_evaluation_log = ffi_evaluation_log * 10 + 2;
        return 2;
    }
    static int ffi_get_log(void) { return ffi_evaluation_log; }
]]

describe("C FFI operator code generation", function()
    after_each(function()
        if not h.verbose then clean_module() end
    end)

    it("executes raw C arithmetic, comparison, and pointer semantics",
    function()
        with_header(declarations, function(header)
            local source = [[
                local c = foreign import "]] .. header .. [["

                local nil_effects: integer = 0

                local function effectful_nil(): nil
                    nil_effects = nil_effects + 1
                    return nil
                end

                function trunc_division(): integer
                    return (c.ffi_neg_seven() / c.ffi_three()) as integer
                end

                function unary_minus(): integer
                    return (-c.ffi_three()) as integer
                end

                function unary_complement(): integer
                    return (~c.ffi_bits_low()) as integer
                end

                function signed_remainder(): integer
                    return (c.ffi_neg_seven() % c.ffi_three()) as integer
                end

                function unsigned_wrap(): boolean
                    return c.ffi_uint_max() + c.ffi_uint_one()
                        == c.ffi_uint_zero()
                end

                function mixed_small(offset: integer): integer
                    return (c.ffi_uchar_max() + offset) as integer
                end

                function exceeds_uint(length: integer): boolean
                    return length > c.FFI_UINT_MAX
                end

                function floating_half(): float
                    return (c.ffi_float_one() / 2.0) as float
                end

                function bitwise(): integer
                    return ((c.ffi_bits_a() & c.ffi_bits_b())
                        | c.ffi_bits_low()) as integer
                end

                function xor_value(): integer
                    return (c.ffi_bits_a() ~ c.ffi_bits_b()) as integer
                end

                function shifted(): integer
                    return (c.ffi_uchar_one()
                        << c.ffi_ulong_three()) as integer
                end

                function shifted_right(): integer
                    return (c.ffi_bits_a()
                        >> c.ffi_uchar_one()) as integer
                end

                function not_equal(): boolean
                    return c.ffi_uint_max() ~= c.ffi_uint_zero()
                end

                function array_value(): integer
                    return c.ffi_read_int(c.ffi_values + 2) as integer
                end

                function pointer_difference(): integer
                    return c.ffi_end() - c.ffi_begin()
                end

                function pointer_nil(): boolean
                    return c.ffi_null() == nil
                end

                function unrelated_pointer_equality(): boolean
                    return c.ffi_as_item() == c.ffi_as_other()
                end

                function function_pointer_equality(): boolean
                    return c.ffi_callback_a() == c.ffi_callback_b()
                end

                function evaluation_order(): integer
                    c.ffi_reset_log()
                    local sum = c.ffi_left() + c.ffi_right()
                    return (sum as integer) * 100
                        + (c.ffi_get_log() as integer)
                end

                function effectful_nil_equality(): integer
                    nil_effects = 0
                    local equal =
                        c.ffi_begin() == effectful_nil()
                    if equal then
                        return -1
                    end
                    return nil_effects
                end
            ]]

            local csrc = h.compile_and_read_c(source, MODULE)
            local ok, err = h.call(MODULE, [[
                assert(ffi_operators.trunc_division() == -2)
                assert(ffi_operators.unary_minus() == -3)
                assert(ffi_operators.unary_complement() == 0xfffffff0)
                assert(ffi_operators.signed_remainder() == -1)
                assert(ffi_operators.unsigned_wrap())
                assert(ffi_operators.mixed_small(5) == 260)
                assert(ffi_operators.exceeds_uint(0x100000000))
                assert(not ffi_operators.exceeds_uint(7))
                assert(ffi_operators.floating_half() == 0.5)
                assert(ffi_operators.bitwise() == 0xaf)
                assert(ffi_operators.xor_value() == 0x5a)
                assert(ffi_operators.shifted() == 8)
                assert(ffi_operators.shifted_right() == 0x78)
                assert(ffi_operators.not_equal())
                assert(ffi_operators.array_value() == 33)
                assert(ffi_operators.pointer_difference() == 4)
                assert(ffi_operators.pointer_nil())
                assert(ffi_operators.unrelated_pointer_equality())
                assert(ffi_operators.function_pointer_equality())
                assert(ffi_operators.evaluation_order() == 312)
                assert(ffi_operators.effectful_nil_equality() == 1)
            ]])
            assert.truthy(ok, err)

            -- These functions contain only C-mode versions of the respective
            -- operators.  Their generated paths must not pick any Lua/Titan
            -- helper semantics.
            local div_body = native_body(csrc, "trunc_division")
            local unary_minus_body = native_body(csrc, "unary_minus")
            local unary_complement_body =
                native_body(csrc, "unary_complement")
            local mod_body = native_body(csrc, "signed_remainder")
            local xor_body = native_body(csrc, "xor_value")
            local shift_body = native_body(csrc, "shifted")
            local shift_right_body = native_body(csrc, "shifted_right")
            assert.not_match("intop", div_body)
            assert.not_match("divide by zero", div_body, 1, true)
            assert.not_match("intop", unary_minus_body)
            assert.not_match("intop", unary_complement_body)
            assert.not_match("intop", mod_body)
            assert.not_match("%% by zero", mod_body)
            assert.not_match("intop", xor_body)
            assert.not_match("intop", shift_body)
            assert.not_match("TITAN_LIKELY", shift_body)
            assert.not_match("intop", shift_right_body)
            assert.not_match("TITAN_LIKELY", shift_right_body)
            assert.match("%(-_tmp_%d+%)", csrc)
            assert.match("%(~_tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ / _tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ %% _tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ %^ _tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ << _tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ >> _tmp_%d+%)", csrc)
            assert.match("%(_tmp_%d+ != _tmp_%d+%)", csrc)
            assert.match("%(%(double%)%(2%.0%)%)", csrc)
            assert.not_match("((lua_Integer)FFI_UINT_MAX)",
                csrc, 1, true)
            assert.match("((long long)(FFI_UINT_MAX))",
                csrc, 1, true)
        end)
    end)
end)
