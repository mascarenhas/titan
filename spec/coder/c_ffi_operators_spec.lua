local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local csemantics = require "titan-compiler.csemantics"
local driver = require "titan-compiler.driver"

local MODULE = "ffi_operators"

local function clean_module()
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", ".titan.h",
        "__entrypoint.c", "__entrypoint.o",
    }) do
        os.remove(MODULE .. suffix)
    end
    os.execute("rm -rf " .. MODULE .. ".so.dSYM")
    os.execute("rm -rf " .. MODULE .. ".dSYM")
end

local function with_header(contents, fn)
    local header = temporary.name(".h")
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
        "[^\n]*ffi_operators_\\u2133_" .. name .. "_titan%b()%s*(%b{})"))
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

local function narrow_lua_integer_profile()
    return assert(csemantics.build_profile({
        macros = {
            __CHAR_BIT__ = "8",
            __SIZEOF_BOOL__ = "1",
            __SIZEOF_SHORT__ = "2",
            __SIZEOF_INT__ = "4",
            __SIZEOF_LONG__ = "8",
            __SIZEOF_LONG_LONG__ = "8",
            __SIZEOF_FLOAT__ = "4",
            __SIZEOF_DOUBLE__ = "8",
            __SIZEOF_LONG_DOUBLE__ = "16",
            __SCHAR_MAX__ = "127",
            __SHRT_MAX__ = "32767",
            __INT_MAX__ = "2147483647",
            __LONG_MAX__ = "9223372036854775807L",
            __LONG_LONG_MAX__ = "9223372036854775807LL",
        },
        lua_integer = "int",
        lua_number = "double",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        signed_minima = {
            ["signed char"] = "-128",
            short = "-32768",
            int = "-2147483648",
            long = "-9223372036854775808",
            ["long long"] = "-9223372036854775808",
        },
    }))
end

local function generate_with_profile(source, profile)
    local service = assert(cprobe.new_service({
        profile = profile,
        include_dirs = driver.foreign_include_dirs(),
    }))
    h.reset(true)
    local ast, parse_error = h.parse(source)
    assert(ast, parse_error)
    local _, errors = checker.check(
        MODULE, ast, source, MODULE .. ".titan", nil, {
            probe_service_provider = function() return service end,
        })
    local close_ok, close_error = service:close()
    assert.truthy(close_ok, close_error)
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION)
end

describe("C FFI operator code generation", function()
    after_each(function()
        if not h.verbose then clean_module() end
    end)

    it("covers C arithmetic, bitwise, comparison, and pointer lowering once",
    function()
        with_header([[
            typedef unsigned int ffi_uint;
            typedef unsigned char ffi_uchar;

            static int ffi_neg(void) { return -7; }
            static int ffi_three(void) { return 3; }
            static ffi_uint ffi_bits(void) { return 0xf0U; }
            static ffi_uint ffi_mask(void) { return 0xaaU; }
            static ffi_uchar ffi_one(void) { return 1U; }
            static ffi_uint ffi_max(void) { return 0xffffffffU; }

            static int ffi_values[3] = { 11, 22, 33 };
            static int *ffi_begin(void) { return ffi_values; }
            static int *ffi_end(void) { return ffi_values + 3; }
            static int *ffi_null(void) { return (int *)0; }

            typedef struct ffi_left { int value; } ffi_left;
            typedef struct ffi_right { int value; } ffi_right;
            static union {
                ffi_left left;
                ffi_right right;
            } ffi_shared;
            static ffi_left *ffi_left_pointer(void) {
                return &ffi_shared.left;
            }
            static ffi_right *ffi_right_pointer(void) {
                return &ffi_shared.right;
            }

            typedef int (*ffi_callback)(int);
            static int ffi_increment(int value) { return value + 1; }
            static ffi_callback ffi_get_callback(void) {
                return ffi_increment;
            }

            static int ffi_log;
            static void ffi_reset_log(void) { ffi_log = 0; }
            static int ffi_first(void) {
                ffi_log = ffi_log * 10 + 1;
                return 1;
            }
            static int ffi_second(void) {
                ffi_log = ffi_log * 10 + 2;
                return 2;
            }
            static int ffi_get_log(void) { return ffi_log; }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function arithmetic(): integer
                    return (ffi.ffi_neg() / ffi.ffi_three()) as integer
                        + (ffi.ffi_neg() % ffi.ffi_three()) as integer
                        + (-ffi.ffi_three()) as integer
                end

                function bitwise(): integer
                    local mixed =
                        (ffi.ffi_bits() & ffi.ffi_mask())
                        | (~ffi.ffi_mask())
                    return ((mixed ~ ffi.ffi_bits())
                        >> ffi.ffi_one()) as integer
                        + (ffi.ffi_one() << ffi.ffi_one()) as integer
                end

                function comparisons(): boolean
                    return ffi.ffi_max() ~= ffi.ffi_one()
                        and ffi.ffi_end() - ffi.ffi_begin() == 3
                        and ffi.ffi_null() == nil
                        and ffi.ffi_left_pointer()
                            == ffi.ffi_right_pointer()
                        and ffi.ffi_get_callback()
                            == ffi.ffi_get_callback()
                end

                function evaluation_order(): integer
                    ffi.ffi_reset_log()
                    local sum = ffi.ffi_first() + ffi.ffi_second()
                    return (sum as integer) * 100
                        + (ffi.ffi_get_log() as integer)
                end
            ]], [[
                assert(test.arithmetic() == -6)
                assert(math.type(test.bitwise()) == "integer")
                assert(test.comparisons())
                assert(test.evaluation_order() == 312)
            ]])
        end)
    end)

    it("executes raw C arithmetic, comparison, and pointer semantics #stress",
    function()
        with_header(declarations, function(header)
            local source = [[
                foreign import "]] .. header .. [["

                local nil_effects: integer = 0

                local function effectful_nil(): nil
                    nil_effects = nil_effects + 1
                    return nil
                end

                function trunc_division(): integer
                    return (ffi.ffi_neg_seven() / ffi.ffi_three()) as integer
                end

                function unary_minus(): integer
                    return (-ffi.ffi_three()) as integer
                end

                function unary_complement(): integer
                    return (~ffi.ffi_bits_low()) as integer
                end

                function signed_remainder(): integer
                    return (ffi.ffi_neg_seven() % ffi.ffi_three()) as integer
                end

                function unsigned_wrap(): boolean
                    return ffi.ffi_uint_max() + ffi.ffi_uint_one()
                        == ffi.ffi_uint_zero()
                end

                function mixed_small(offset: integer): integer
                    return (ffi.ffi_uchar_max() + offset) as integer
                end

                function exceeds_uint(length: integer): boolean
                    return length > ffi.FFI_UINT_MAX
                end

                function floating_half(): float
                    return (ffi.ffi_float_one() / 2.0) as float
                end

                function bitwise(): integer
                    return ((ffi.ffi_bits_a() & ffi.ffi_bits_b())
                        | ffi.ffi_bits_low()) as integer
                end

                function xor_value(): integer
                    return (ffi.ffi_bits_a() ~ ffi.ffi_bits_b()) as integer
                end

                function shifted(): integer
                    return (ffi.ffi_uchar_one()
                        << ffi.ffi_ulong_three()) as integer
                end

                function shifted_right(): integer
                    return (ffi.ffi_bits_a()
                        >> ffi.ffi_uchar_one()) as integer
                end

                function not_equal(): boolean
                    return ffi.ffi_uint_max() ~= ffi.ffi_uint_zero()
                end

                function array_value(): integer
                    return ffi.ffi_read_int(ffi.ffi_values + 2) as integer
                end

                function pointer_difference(): integer
                    return ffi.ffi_end() - ffi.ffi_begin()
                end

                function pointer_nil(): boolean
                    return ffi.ffi_null() == nil
                end

                function unrelated_pointer_equality(): boolean
                    return ffi.ffi_as_item() == ffi.ffi_as_other()
                end

                function function_pointer_equality(): boolean
                    return ffi.ffi_callback_a() == ffi.ffi_callback_b()
                end

                function evaluation_order(): integer
                    ffi.ffi_reset_log()
                    local sum = ffi.ffi_left() + ffi.ffi_right()
                    return (sum as integer) * 100
                        + (ffi.ffi_get_log() as integer)
                end

                function effectful_nil_equality(): integer
                    nil_effects = 0
                    local equal =
                        ffi.ffi_begin() == effectful_nil()
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
            local floating_body = native_body(csrc, "floating_half")
            local exceeds_body = native_body(csrc, "exceeds_uint")
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
            assert.match("%(%(double%)_tmp_%d+%)", floating_body)
            assert.not_match("((lua_Integer)FFI_UINT_MAX)",
                csrc, 1, true)
            assert.match("FFI_UINT_MAX", exceeds_body, 1, true)
            assert.match("%(%(long long%)_tmp_%d+%)", exceeds_body)
        end)
    end)

    it("checks size_t and ptrdiff_t before a narrow Titan integer carrier",
    function()
        with_header(declarations, function(header)
            local source = [[
                foreign import "]] .. header .. [["

                function checked_sizeof(): integer
                    return foreign ffi_item.sizeof
                end

                function checked_alignof(): integer
                    return foreign ffi_item.alignof
                end

                function checked_difference(): integer
                    return ffi.ffi_end() - ffi.ffi_begin()
                end
            ]]
            local csrc = generate_with_profile(
                source, narrow_lua_integer_profile())
            local size_body = native_body(csrc, "checked_sizeof")
            local align_body = native_body(csrc, "checked_alignof")
            local difference_body =
                native_body(csrc, "checked_difference")

            assert.not_match("%(%(lua_Integer%)sizeof", size_body)
            assert.not_match("%(%(lua_Integer%)_Alignof", align_body)
            assert.not_match("%(%(lua_Integer%)%([^)]*%-[^)]*%)%)",
                difference_body)
            assert.match("sizeof%(", size_body)
            assert.match("_Alignof%(", align_body)
            assert.match("unsigned long%s+_tmp_%d+", size_body)
            assert.match("unsigned long%s+_tmp_%d+", align_body)
            assert.match("long%s+_tmp_%d+", difference_body)
            assert.match("numeric value is outside the range of %s",
                size_body, 1, true)
            assert.match('"integer"', size_body, 1, true)
            assert.match("numeric value is outside the range of %s",
                align_body, 1, true)
            assert.match('"integer"', align_body, 1, true)
            assert.match("numeric value is outside the range of %s",
                difference_body, 1, true)
            assert.match('"integer"', difference_body, 1, true)
            assert.match(">=", difference_body, 1, true)
            assert.match("<=", difference_body, 1, true)
        end)
    end)
end)
