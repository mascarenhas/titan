local csemantics = require "titan-compiler.csemantics"
local cdefines = require "c-parser.cdefines"
local types = require "titan-compiler.types"

local function integer(spelling, signed, rank, bits, precision,
                       minimum, maximum, unsigned)
    return {
        type = types.CInteger(spelling, signed, rank, bits),
        precision = precision,
        minimum = minimum,
        maximum = maximum,
        unsigned = unsigned,
    }
end

local function floating(spelling, rank)
    return {
        type = types.CFloat(spelling),
        rank = rank,
    }
end

local function lp64_profile()
    return {
        int = "int",
        unsigned_int = "unsigned int",
        lua_integer = "long long",
        lua_number = "double",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        integers = {
            ["char"] = integer("char", true, 1, 8, 7,
                "-128", "127"),
            ["signed char"] = integer("signed char", true, 1, 8, 7,
                "-128", "127"),
            ["unsigned char"] = integer("unsigned char", false, 1, 8, 8,
                "0", "255"),
            ["short"] = integer("short", true, 2, 16, 15,
                "-32768", "32767"),
            ["unsigned short"] = integer("unsigned short", false, 2, 16, 16,
                "0", "65535"),
            ["int"] = integer("int", true, 3, 32, 31,
                "-2147483648", "2147483647", "unsigned int"),
            ["unsigned int"] = integer("unsigned int", false, 3, 32, 32,
                "0", "4294967295"),
            ["long"] = integer("long", true, 4, 64, 63,
                "-9223372036854775808", "9223372036854775807",
                "unsigned long"),
            ["unsigned long"] = integer("unsigned long", false, 4, 64, 64,
                "0", "18446744073709551615"),
            ["long long"] = integer("long long", true, 5, 64, 63,
                "-9223372036854775808", "9223372036854775807",
                "unsigned long long"),
            ["unsigned long long"] = integer(
                "unsigned long long", false, 5, 64, 64,
                "0", "18446744073709551615"),
        },
        floats = {
            ["float"] = floating("float", 1),
            ["double"] = floating("double", 2),
            ["long double"] = floating("long double", 3),
        },
    }
end

-- A deliberately non-host profile where int and short have the same storage
-- width. unsigned short therefore promotes to unsigned int, and signed long
-- cannot represent all values of unsigned int.
local function narrow_int_profile()
    return {
        int = "int",
        unsigned_int = "unsigned int",
        lua_integer = "long",
        lua_number = "float",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        integers = {
            ["signed char"] = integer("signed char", true, 1, 8, 7,
                "-128", "127"),
            ["unsigned char"] = integer("unsigned char", false, 1, 8, 8,
                "0", "255"),
            ["short"] = integer("short", true, 2, 16, 15,
                "-32768", "32767"),
            ["unsigned short"] = integer("unsigned short", false, 2, 16, 16,
                "0", "65535"),
            ["int"] = integer("int", true, 3, 16, 15,
                "-32768", "32767", "unsigned int"),
            ["unsigned int"] = integer("unsigned int", false, 3, 16, 16,
                "0", "65535"),
            ["long"] = integer("long", true, 4, 32, 31,
                "-2147483648", "2147483647", "unsigned long"),
            ["unsigned long"] = integer("unsigned long", false, 4, 32, 32,
                "0", "4294967295"),
            ["long long"] = integer("long long", true, 5, 64, 63,
                "-9223372036854775808", "9223372036854775807",
                "unsigned long long"),
            ["unsigned long long"] = integer(
                "unsigned long long", false, 5, 64, 64,
                "0", "18446744073709551615"),
        },
        floats = {
            ["float"] = floating("float", 1),
            ["double"] = floating("double", 2),
            ["long double"] = floating("long double", 3),
        },
    }
end

local function ctype(profile, spelling)
    local entry = profile.integers[spelling] or profile.floats[spelling]
    return assert(entry).type
end

local function macro(value)
    return { value }
end

local function lp64_macros()
    return {
        __CHAR_BIT__ = macro("8"),
        __SIZEOF_BOOL__ = macro("1"),
        __SIZEOF_SHORT__ = macro("2"),
        __SIZEOF_INT__ = macro("4"),
        __SIZEOF_LONG__ = macro("8"),
        __SIZEOF_LONG_LONG__ = macro("8"),
        __SIZEOF_FLOAT__ = macro("4"),
        __SIZEOF_DOUBLE__ = macro("8"),
        __SIZEOF_LONG_DOUBLE__ = macro("16"),
        __FLT_RADIX__ = macro("2"),
        __FLT_MAX_EXP__ = macro("128"),
        __DBL_MAX_EXP__ = macro("1024"),
        __LDBL_MAX_EXP__ = macro("16384"),
        __FLT_MANT_DIG__ = macro("24"),
        __DBL_MANT_DIG__ = macro("53"),
        __LDBL_MANT_DIG__ = macro("64"),
        __SIZEOF_INT128__ = macro("16"),
        __SCHAR_MAX__ = macro("0x7f"),
        __UCHAR_MAX__ = macro("0xffU"),
        __SHRT_MAX__ = macro("0x7fff"),
        __USHRT_MAX__ = macro("0xffffU"),
        __INT_MAX__ = macro("0x7fffffff"),
        __UINT_MAX__ = macro("0xffffffffU"),
        __LONG_MAX__ = macro("0x7fffffffffffffffL"),
        __ULONG_MAX__ = macro("0xffffffffffffffffUL"),
        __LONG_LONG_MAX__ = macro("0x7fffffffffffffffLL"),
        __ULONG_LONG_MAX__ = macro("0xffffffffffffffffULL"),
    }
end

local function alternative_macros()
    return {
        __CHAR_BIT__ = "8",
        __CHAR_UNSIGNED__ = "1",
        __SIZEOF_SHORT__ = "2",
        -- Deliberate padding: int has 32 storage bits but only 15 signed
        -- value bits. The maximum macros, not sizeof alone, drive precision.
        __SIZEOF_INT__ = "4",
        __SIZEOF_LONG__ = "4",
        __SIZEOF_LONG_LONG__ = "8",
        __SIZEOF_FLOAT__ = "4",
        __SIZEOF_DOUBLE__ = "8",
        __SIZEOF_LONG_DOUBLE__ = "12",
        __SCHAR_MAX__ = "127",
        __UCHAR_MAX__ = "255U",
        __SHRT_MAX__ = "32767",
        __USHRT_MAX__ = "65535U",
        __INT_MAX__ = "32767",
        __UINT_MAX__ = "65535U",
        __LONG_MAX__ = "2147483647L",
        __ULONG_MAX__ = "4294967295UL",
        __LONG_LONG_MAX__ = "9223372036854775807LL",
        __ULONG_LONG_MAX__ = "18446744073709551615ULL",
    }
end

local lp64_signed_minima = {
    ["signed char"] = "-128",
    short = "-32768",
    int = "-2147483648",
    long = "-9223372036854775808",
    ["long long"] = "-9223372036854775808",
}

local alternative_signed_minima = {
    ["signed char"] = "-128",
    short = "-32768",
    int = "-32768",
    long = "-2147483648",
    ["long long"] = "-9223372036854775808",
}

local function build_lp64(macros)
    return csemantics.build_profile({
        macros = macros or lp64_macros(),
        lua_integer = "long long",
        lua_number = "double",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        signed_minima = lp64_signed_minima,
    })
end

local function build_alternative(macros)
    return csemantics.build_profile({
        macros = macros or alternative_macros(),
        lua_integer = "long",
        lua_number = "float",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        signed_minima = alternative_signed_minima,
    })
end

local function registered_expression(text)
    local registered = {}
    cdefines.register_define(registered, "TEST_MACRO", text, {})
    return assert(registered.TEST_MACRO, "macro was not registered")
        .macro_expression
end

describe("pure C expression semantics", function()
    describe("embedded target profile metadata", function()
        it("round-trips exact target traits as declarative data", function()
            for _, build in ipairs({ build_lp64, build_alternative }) do
                local original = assert(build())
                local data = assert(csemantics.export_profile(original))
                assert.equal(1, data.version)
                assert.equal(original.identity, data.identity)
                assert.equal(original.integers.int.type.bits,
                    data.integers.int.bits)
                assert.equal(original.integers.int.maximum,
                    data.integers.int.maximum)
                assert.is_nil(data.integers.int.type)
                assert.is_nil(data.integers.int._c_numeric)
                assert.is_nil(data.integers.int._c_numeric_carriers)

                local restored = assert(csemantics.import_profile(data))
                assert.is_true(csemantics.validate_profile(restored))
                assert.equal(original.identity, restored.identity)
                assert.equal(original.identity,
                    csemantics.profile_identity(restored))
                assert.same(data,
                    assert(csemantics.export_profile(restored)))
                assert.not_equal(original.integers.int.type,
                    restored.integers.int.type)
                assert.same(original.integers.int.type._c_numeric,
                    restored.integers.int.type._c_numeric)
                assert.same(original.floats.double.type._c_numeric,
                    restored.floats.double.type._c_numeric)

                local carriers =
                    restored.integers.int.type._c_numeric_carriers
                assert.equal(restored.identity, carriers.identity)
                assert.equal(restored.integers[restored.lua_integer]
                    .type._c_numeric, carriers.lua_integer)
                assert.equal(restored.floats[restored.lua_number]
                    .type._c_numeric, carriers.lua_number)
                assert.equal(carriers,
                    restored.floats.double.type._c_numeric_carriers)
                assert.equal(carriers,
                    restored.integers[restored.size_t]
                        .type._c_numeric_carriers)

                local recovered = types.CInteger("int",
                    data.integers.int.signed, data.integers.int.rank,
                    data.integers.int.bits)
                assert.is_true(types.normalize_portable_c_numeric_types(
                    recovered, restored))
                assert.equal(restored.integers.int.type._c_numeric,
                    recovered._c_numeric)
                assert.equal(carriers, recovered._c_numeric_carriers)
            end
        end)

        it("rejects nondeclarative and open profile data at every layer",
        function()
            local function reject(change)
                local data = assert(csemantics.export_profile(
                    assert(build_lp64())))
                local candidate = change(data) or data
                local restored, err = csemantics.import_profile(candidate)
                assert.is_nil(restored)
                assert.is_string(err)
                assert.not_equal("", err)
            end

            reject(function() return "return arbitrary_code()" end)
            reject(function(data) setmetatable(data, {}) end)
            reject(function(data) data.unexpected = true end)
            reject(function(data) setmetatable(data.integers, {}) end)
            reject(function(data) data.integers[1] = {} end)
            reject(function(data)
                setmetatable(data.integers.int, {})
            end)
            reject(function(data)
                data.integers.int._c_numeric = { bits = 64 }
            end)
            reject(function(data)
                data.floats.double.type = types.CFloat("double")
            end)
            reject(function(data)
                data.floats.double.rank = function() return 2 end
            end)
        end)

        it("rejects forged identity and malformed scalar descriptions",
        function()
            local function reject(change)
                local data = assert(csemantics.export_profile(
                    assert(build_lp64())))
                change(data)
                local restored, err = csemantics.import_profile(data)
                assert.is_nil(restored)
                assert.is_string(err)
                assert.not_equal("", err)
            end

            reject(function(data) data.version = 2 end)
            reject(function(data) data.identity = "different target" end)
            reject(function(data) data.lua_integer = "unsigned long" end)
            reject(function(data) data.integers.int.bits = 64 end)
            reject(function(data) data.integers.int.minimum = "-02147483648" end)
            reject(function(data) data.integers.int.maximum = "2147483647.0" end)
            reject(function(data) data.integers.int.precision = 32 end)
            reject(function(data) data.integers["unsigned int"] = nil end)
            reject(function(data) data.floats.double = nil end)
            reject(function(data) data.floats.double.bits = 0 end)
            reject(function(data) data.floats.double.maximum_exponent = 0 end)
        end)

        it("isolates exported data and reconstructed numeric graphs", function()
            local original = assert(build_lp64())
            local data = assert(csemantics.export_profile(original))
            local first = assert(csemantics.import_profile(data))
            local second = assert(csemantics.import_profile(data))
            original.integers.int.maximum = "0"
            original.integers.int.type._c_numeric.bits = 8
            data.integers.int.maximum = "1"
            first.integers.int.type.bits = 16
            first.integers.int.type._c_numeric_carriers.lua_integer.bits = 16

            assert.equal("2147483647", second.integers.int.maximum)
            assert.equal(32, second.integers.int.type.bits)
            assert.equal(32, second.integers.int.type._c_numeric.bits)
            assert.equal(64, second.integers.int.type
                ._c_numeric_carriers.lua_integer.bits)
            assert.not_equal(first.integers.int.type._c_numeric_carriers,
                second.integers.int.type._c_numeric_carriers)
        end)
    end)

    describe("target profiles and categories", function()
        it("extracts only profile facts while preserving alias and rejection behavior", function()
            local macros = lp64_macros()
            macros.__INT_MAX__ = { "(", "TARGET_INT_MAX", ")" }
            macros.TARGET_INT_MAX = { "0x7fffffff" }
            macros.UNRELATED_HEADER_MACRO = { "large", "unused", "replacement" }
            local facts = csemantics.profile_macro_facts(macros)
            assert.is_nil(facts.UNRELATED_HEADER_MACRO)
            assert.equal("0x7fffffff", facts.TARGET_INT_MAX)
            assert.same(assert(build_lp64(macros)), assert(build_lp64(facts)))

            macros.__SIZEOF_INT__ = { args = { "argument" }, repl = { "4" } }
            local _, original_error = build_lp64(macros)
            local _, compact_error = build_lp64(csemantics.profile_macro_facts(macros))
            assert.equal(original_error, compact_error)
            macros.__SIZEOF_INT__ = { "SIZE_ALIAS" }
            macros.SIZE_ALIAS = { "__SIZEOF_INT__" }
            _, original_error = build_lp64(macros)
            _, compact_error = build_lp64(csemantics.profile_macro_facts(macros))
            assert.equal(original_error, compact_error)
        end)

        it("validates an injected LP64 profile without host queries", function()
            assert.is_true(csemantics.validate_profile(lp64_profile()))
            assert.is_true(csemantics.validate_profile(narrow_int_profile()))
        end)

        it("rejects profiles without value ranges", function()
            local profile = lp64_profile()
            profile.integers.int.maximum = nil
            local ok, err = csemantics.validate_profile(profile)
            assert.is_nil(ok)
            assert.matches("invalid target integer profile entry for 'int'",
                err, 1, true)
        end)

        it("rejects non-two's-complement signed target ranges explicitly",
        function()
            local profile = lp64_profile()
            profile.integers.int.minimum = "-2147483647"
            local ok, err = csemantics.validate_profile(profile)
            assert.is_nil(ok)
            assert.matches(
                "Titan requires two's%-complement signed integers", err)
            assert.matches("'int' has range %-2147483647%.%.2147483647",
                err)
        end)

        it("revalidates a mutated profile after warming exact powers",
        function()
            local profile = lp64_profile()
            local expression = registered_expression("1")
            assert(csemantics.evaluate_macro_expression(
                profile, expression))

            profile.integers.int.minimum = "-2147483647"
            local result, err =
                csemantics.evaluate_macro_expression(profile, expression)
            assert.is_nil(result)
            assert.matches(
                "Titan requires two's%-complement signed integers", err)
        end)

        it("builds an exact canonical LP64 profile from injected traits",
        function()
            local profile = assert(build_lp64())

            assert.is_true(csemantics.validate_profile(profile))
            assert.equal("long long", profile.lua_integer)
            assert.equal("double", profile.lua_number)
            assert.equal("unsigned long", profile.size_t)
            assert.equal("long", profile.ptrdiff_t)
            assert.equal(8, profile.char_bit)
            assert.is_true(profile.char_signed)
            assert.equal(32, profile.integers.int.type.bits)
            assert.equal(31, profile.integers.int.precision)
            assert.equal("-2147483648",
                profile.integers.int.minimum)
            assert.equal("4294967295",
                profile.integers["unsigned int"].maximum)
            assert.equal("18446744073709551615",
                profile.integers["unsigned long long"].maximum)
            assert.equal(128, profile.floats["long double"].bits)
            assert.equal(128,
                profile.floats.float.maximum_exponent)
            assert.equal(53,
                profile.floats.double.mantissa_digits)
            assert.equal("LDBL_MAX",
                profile.floats["long double"].maximum_macro)
            assert.equal(8, profile.integers._Bool.type.bits)
            assert.equal("1", profile.integers._Bool.maximum)
            assert.equal(128, profile.integers["__int128"].type.bits)
            assert.equal(127,
                profile.integers["__int128"].precision)
            assert.equal(
                "340282366920938463463374607431768211455",
                profile.integers["unsigned __int128"].maximum)
            assert.matches("lua_Integer=long long",
                profile.identity, 1, true)
            assert.matches("size_t=unsigned long",
                profile.identity, 1, true)
            assert.equal("unsigned long",
                profile.integers[profile.size_t].type
                    ._c_numeric_carriers.size_t.spelling)
            assert.equal("long",
                profile.integers[profile.ptrdiff_t].type
                    ._c_numeric_carriers.ptrdiff_t.spelling)

            local from_options = assert(csemantics.build_profile({
                macros = lp64_macros(),
                lua_integer = "long long",
                lua_number = "double",
                size_t = "unsigned long",
                ptrdiff_t = "long",
                signed_minima = lp64_signed_minima,
            }))
            assert.equal(profile.identity, from_options.identity)

            -- GCC/Clang do not consistently publish unsigned counterparts.
            -- The signed maxima still determine the corresponding C unsigned
            -- range without borrowing the host representation.
            local signed_only = lp64_macros()
            signed_only.__UCHAR_MAX__ = nil
            signed_only.__USHRT_MAX__ = nil
            signed_only.__UINT_MAX__ = nil
            signed_only.__ULONG_MAX__ = nil
            signed_only.__ULONG_LONG_MAX__ = nil
            local derived = assert(build_lp64(signed_only))
            assert.equal("18446744073709551615",
                derived.integers["unsigned long"].maximum)
        end)

        it("exposes target numeric traits and exact integer range order",
        function()
            local profile = assert(build_lp64())
            local titan_integer = assert(csemantics.numeric_trait(
                profile, types.Integer()))
            local target_float = assert(csemantics.numeric_trait(
                profile, profile.floats.float.type))

            assert.equal("integer", titan_integer.kind)
            assert.equal("long long", titan_integer.spelling)
            assert.equal(63, titan_integer.precision)
            assert.equal("float", target_float.kind)
            assert.equal(128, target_float.maximum_exponent)
            assert.equal(24, target_float.mantissa_digits)

            local int = assert(csemantics.numeric_trait(
                profile, profile.integers.int.type))
            local unsigned_int = assert(csemantics.numeric_trait(
                profile, profile.integers["unsigned int"].type))
            assert.is_true(csemantics.integer_range_contains(
                titan_integer, unsigned_int))
            assert.is_false(csemantics.integer_range_contains(
                int, unsigned_int))
        end)

        it("derives a synthetic target and unsigned plain char without host assumptions",
        function()
            local profile = assert(build_alternative())

            assert.equal("long", profile.lua_integer)
            assert.equal("float", profile.lua_number)
            assert.is_false(profile.char_signed)
            assert.is_false(profile.integers.char.type.signed)
            assert.equal("255", profile.integers.char.maximum)
            assert.equal(32, profile.integers.int.type.bits)
            assert.equal(15, profile.integers.int.precision)
            assert.equal(96, profile.floats["long double"].bits)
            assert.is_nil(profile.integers["__int128"])
            local plain_char = assert(csemantics.classify(
                profile, types.CInteger("char", false, 1, 8)))
            assert.equal(profile.integers.char.type, plain_char.type)
        end)

        it("reports the exact missing or inconsistent target trait", function()
            local missing = lp64_macros()
            missing.__LONG_MAX__ = nil
            local profile, err = build_lp64(missing)
            assert.is_nil(profile)
            assert.matches(
                "missing required predefined macro '__LONG_MAX__'",
                err, 1, true)

            local inconsistent = lp64_macros()
            inconsistent.__UINT_MAX__ = macro("65535U")
            profile, err = build_lp64(inconsistent)
            assert.is_nil(profile)
            assert.matches(
                "predefined macro '__UINT_MAX__' disagrees",
                err, 1, true)
        end)

        it("resolves C typedefs and mixed Titan scalars canonically", function()
            local profile = lp64_profile()
            local short_alias =
                types.CTypedef("small", ctype(profile, "short"))

            local short = assert(csemantics.classify(profile, short_alias))
            local tint = assert(csemantics.classify(profile, types.Integer()))
            local tfloat = assert(csemantics.classify(profile, types.Float()))
            local pointer = assert(csemantics.scalar_category(profile,
                types.CPointer(ctype(profile, "int"), {})))

            assert.equal("integer", short.kind)
            assert.equal(ctype(profile, "short"), short.type)
            assert.equal(ctype(profile, "long long"), tint.type)
            assert.is_true(tint.titan)
            assert.equal(ctype(profile, "double"), tfloat.type)
            assert.equal("pointer", pointer.kind)
        end)

        it("reports missing Titan scalar profile mappings without throwing",
        function()
            local integer, integer_error =
                csemantics.classify(nil, types.Integer())
            assert.is_nil(integer)
            assert.matches("does not describe Titan integer", integer_error,
                1, true)

            local number, number_error =
                csemantics.classify({}, types.Float())
            assert.is_nil(number)
            assert.matches("does not describe Titan float", number_error,
                1, true)
        end)
    end)

    describe("integer promotions", function()
        it("accepts nil rank and width as absent profile metadata", function()
            local profile = lp64_profile()
            assert.equal(ctype(profile, "int"),
                csemantics.integer_promotion(profile,
                    types.CInteger("int", true, nil, nil)))
        end)

        it("rejects false rank instead of treating it as absent", function()
            local profile = lp64_profile()
            local promoted, err = csemantics.integer_promotion(profile,
                types.CInteger("int", true, false, 32))
            assert.is_nil(promoted)
            assert.matches("disagrees with the target profile's rank", err, 1, true)
        end)

        it("rejects false width instead of treating it as absent", function()
            local profile = lp64_profile()
            local promoted, err = csemantics.integer_promotion(profile,
                types.CInteger("int", true, 3, false))
            assert.is_nil(promoted)
            assert.matches("disagrees with the target profile's storage width", err, 1, true)
        end)

        it("promotes every representable LP64 small integer to int", function()
            local profile = lp64_profile()
            for _, spelling in ipairs({
                "char", "signed char", "unsigned char",
                "short", "unsigned short",
            }) do
                assert.equal(ctype(profile, "int"),
                    csemantics.integer_promotion(profile,
                        ctype(profile, spelling)))
            end
        end)

        it("uses unsigned int when synthetic int cannot represent the source",
           function()
            local profile = narrow_int_profile()
            assert.equal(ctype(profile, "int"),
                csemantics.integer_promotion(profile,
                    ctype(profile, "signed char")))
            assert.equal(ctype(profile, "unsigned int"),
                csemantics.integer_promotion(profile,
                    ctype(profile, "unsigned short")))
        end)

        it("drops typedef identity during promotion", function()
            local profile = lp64_profile()
            local alias = types.CTypedef(
                "platform_short", ctype(profile, "short"))
            local result =
                assert(csemantics.integer_promotion(profile, alias))
            assert.equal(ctype(profile, "int"), result)
            assert.equal("Type.CInteger", result._tag)
        end)
    end)

    describe("usual arithmetic conversions", function()
        it("handles LP64 signed and unsigned rank crossings", function()
            local profile = lp64_profile()
            local convert = function(left, right)
                return assert(csemantics.usual_arithmetic_conversion(
                    profile, ctype(profile, left), ctype(profile, right)))
            end

            assert.equal(ctype(profile, "unsigned int"),
                convert("int", "unsigned int"))
            assert.equal(ctype(profile, "long"),
                convert("long", "unsigned int"))
            assert.equal(ctype(profile, "unsigned long"),
                convert("long", "unsigned long"))
            assert.equal(ctype(profile, "unsigned long long"),
                convert("long long", "unsigned long"))
        end)

        it("uses the corresponding unsigned type on the alternative profile",
           function()
            local profile = narrow_int_profile()
            assert.equal(ctype(profile, "unsigned long"),
                csemantics.usual_arithmetic_conversion(
                    profile,
                    ctype(profile, "long"),
                    ctype(profile, "unsigned long")))
            assert.equal(ctype(profile, "long"),
                csemantics.usual_arithmetic_conversion(
                    profile,
                    types.Integer(),
                    ctype(profile, "unsigned int")))
        end)

        it("applies float, double, and long-double precedence", function()
            local profile = lp64_profile()
            assert.equal(ctype(profile, "float"),
                csemantics.usual_arithmetic_conversion(
                    profile,
                    ctype(profile, "float"),
                    ctype(profile, "unsigned short")))
            assert.equal(ctype(profile, "double"),
                csemantics.usual_arithmetic_conversion(
                    profile,
                    ctype(profile, "float"),
                    ctype(profile, "double")))
            assert.equal(ctype(profile, "long double"),
                csemantics.usual_arithmetic_conversion(
                    profile,
                    ctype(profile, "double"),
                    ctype(profile, "long double")))
        end)

        it("drops typedef identity in the arithmetic result", function()
            local profile = lp64_profile()
            local size_t = types.CTypedef(
                "size_t", ctype(profile, "unsigned long"))
            local result = assert(csemantics.usual_arithmetic_conversion(
                profile, size_t, ctype(profile, "int")))
            assert.equal(ctype(profile, "unsigned long"), result)
            assert.equal("Type.CInteger", result._tag)
        end)

        it("uses the promoted left operand as the shift result", function()
            local profile = lp64_profile()
            assert.equal(ctype(profile, "int"),
                csemantics.shift_result(
                    profile,
                    ctype(profile, "unsigned char"),
                    ctype(profile, "long long")))
            assert.equal(ctype(profile, "unsigned long"),
                csemantics.shift_result(
                    profile,
                    ctype(profile, "unsigned long"),
                    ctype(profile, "signed char")))
        end)
    end)

    describe("integer macro classification and evaluation", function()
        it("selects candidates by suffix, base, and exact target range",
        function()
            local profile = assert(build_lp64())
            local bases = {"17", "021", "0x11"}
            local suffixes = {
                {"", "int"},
                {"U", "unsigned int"},
                {"L", "long"},
                {"UL", "unsigned long"},
                {"LL", "long long"},
                {"ULL", "unsigned long long"},
            }
            for _, base in ipairs(bases) do
                for _, suffix in ipairs(suffixes) do
                    local token = base .. suffix[1]
                    local result = assert(
                        csemantics.evaluate_macro_expression(
                            profile, registered_expression(token)))
                    assert.equal(suffix[2], result.type.spelling, token)
                    assert.equal("17", result.value, token)
                end
            end

            local cases = {
                {"2147483648", "long", "2147483648"},
                {"0x80000000", "unsigned int", "2147483648"},
                {"037777777777", "unsigned int", "4294967295"},
                {"4294967295U", "unsigned int", "4294967295"},
                {"4294967296UL", "unsigned long", "4294967296"},
                {"9223372036854775807LL", "long long",
                    "9223372036854775807"},
                {"18446744073709551615ULL", "unsigned long long",
                    "18446744073709551615"},
            }

            for _, case in ipairs(cases) do
                local result = assert(csemantics.evaluate_macro_expression(
                    profile, registered_expression(case[1])))
                assert.equal(case[2], result.type.spelling, case[1])
                assert.equal(case[3], result.value, case[1])
            end
        end)

        it("preserves UINT_MAX as an exact unsigned-int constant", function()
            local profile = assert(build_lp64())
            local result = assert(csemantics.evaluate_integer_macro(
                profile, registered_expression("0xffffffffU")))

            assert.equal("unsigned int", result.type.spelling)
            assert.is_false(result.type.signed)
            assert.equal(3, result.type.rank)
            assert.equal("4294967295", result.value)
            assert.equal(profile.integers["unsigned int"], result.entry)

            -- A common limits.h spelling expands UINT_MAX through INT_MAX
            -- instead of publishing one hexadecimal token.
            local compound = assert(csemantics.evaluate_integer_macro(
                profile,
                registered_expression(
                    "( 0x7fffffff * 2U + 1U )")))
            assert.equal("unsigned int", compound.type.spelling)
            assert.equal("4294967295", compound.value)
        end)

        it("uses promotions and usual conversions throughout compound ASTs",
        function()
            local profile = assert(build_lp64())
            local shifted = assert(csemantics.evaluate_macro_expression(
                profile,
                registered_expression("( 1U + 02L ) << 0x3ULL")))
            assert.equal("long", shifted.type.spelling)
            assert.equal("24", shifted.value)

            local crossed = assert(csemantics.evaluate_macro_expression(
                profile,
                registered_expression("0xffffffffU + 1L")))
            assert.equal("long", crossed.type.spelling)
            assert.equal("4294967296", crossed.value)

            local wrapped = assert(csemantics.evaluate_macro_expression(
                profile,
                registered_expression("0xffffffffU + 1U")))
            assert.equal("unsigned int", wrapped.type.spelling)
            assert.equal("0", wrapped.value)
        end)

        it("does not evaluate short-circuited integer subexpressions",
        function()
            local profile = assert(build_lp64())
            local cases = {
                {"0 && ( 1 / 0 )", "int", "0"},
                {"1 || ( 1 / 0 )", "int", "1"},
                {"1 ? 7 : ( 1 / 0 )", "int", "7"},
                {"0 ? ( 1 / 0 ) : 9U", "unsigned int", "9"},
            }
            for _, case in ipairs(cases) do
                local result = assert(csemantics.evaluate_macro_expression(
                    profile, registered_expression(case[1])))
                assert.equal(case[2], result.type.spelling, case[1])
                assert.equal(case[3], result.value, case[1])
            end

            local result, err =
                csemantics.evaluate_macro_expression(
                    profile, registered_expression("1 && ( 1 / 0 )"))
            assert.is_nil(result)
            assert.matches("division by zero", err, 1, true)
        end)

        it("lets a synthetic width change an unsuffixed hexadecimal type",
        function()
            local profile = assert(build_alternative())
            local result = assert(csemantics.evaluate_macro_expression(
                profile, registered_expression("0xffff")))
            assert.equal("unsigned int", result.type.spelling)
            assert.equal("65535", result.value)
        end)
    end)

    describe("array decay and pointer decisions", function()
        local function complete_struct()
            return types.CStruct(
                "struct item", "item", nil, {}, true, false)
        end

        it("requires a present valid extent for complete Array objects", function()
            local int = ctype(lp64_profile(), "int")
            assert.is_false(csemantics.is_complete_object(types.CArray(int, nil)))
            assert.is_false(csemantics.is_complete_object(types.CArray(int, false)))
            assert.is_false(csemantics.is_complete_object(types.CArray(int, "")))
            assert.is_true(csemantics.is_complete_object(types.CArray(int, 4)))
            assert.is_true(csemantics.is_complete_object(types.CArray(int, "N")))
        end)

        it("decays arrays before complete-object pointer arithmetic", function()
            local profile = lp64_profile()
            local int = ctype(profile, "int")
            local decision = assert(csemantics.pointer_arithmetic(
                profile, types.CArray(int, 4),
                ctype(profile, "unsigned char")))

            assert.is_true(decision.pointer_decay)
            assert.same(types.CPointer(int, {}), decision.pointer)
            assert.equal(ctype(profile, "int"), decision.offset)
            assert.equal(decision.pointer, decision.result)
        end)

        it("rejects arithmetic on void, function, and incomplete pointers",
           function()
            local profile = lp64_profile()
            local offset = ctype(profile, "int")
            local incomplete = types.CStruct(
                "struct pending", "pending", nil, {}, false, false)
            local callback = types.CFunction({}, types.CVoid(), false, "cdecl")

            for _, pointer in ipairs({
                types.CPointer(types.CVoid(), {}),
                types.CPointer(incomplete, {}),
                types.CPointer(callback, {}),
            }) do
                local result, err =
                    csemantics.pointer_arithmetic(profile, pointer, offset)
                assert.is_nil(result)
                assert.matches("complete non%-void object", err)
            end
        end)

        it("forms a symmetric qualified common type for compatible pointers",
           function()
            local int = ctype(lp64_profile(), "int")
            local const_int = types.CPointer(int, {"const"})
            local volatile_int = types.CPointer(int, {"volatile"})

            local left = assert(csemantics.pointer_common_type(
                const_int, volatile_int, "ordering"))
            local right = assert(csemantics.pointer_common_type(
                volatile_int, const_int, "ordering"))

            assert.same(
                types.CPointer(int, {"const", "volatile"}), left.common)
            assert.same(left.common, right.common)
            assert.equal("Type.Boolean", left.result._tag)
        end)

        it("uses qualified void pointers only for unrelated object equality",
           function()
            local profile = lp64_profile()
            local int_ptr = types.CPointer(
                types.CPointer(ctype(profile, "int"), {"const"}),
                {"volatile"})
            local item_ptr =
                types.CPointer(complete_struct(), {"const"})

            local equality = assert(
                csemantics.pointer_equality_common_type(int_ptr, item_ptr))
            assert.same(
                types.CPointer(types.CVoid(), {"const", "volatile"}),
                equality.common)

            local ordered, ordered_err = csemantics.pointer_common_type(
                int_ptr, item_ptr, "ordering")
            assert.is_nil(ordered)
            assert.matches("qualification%-compatible", ordered_err)
        end)

        it("permits only compatible complete pointer subtraction", function()
            local profile = lp64_profile()
            local item = complete_struct()
            local first = types.CPointer(item, {"const"})
            local second = types.CArray(item, 3)

            local difference = assert(csemantics.pointer_common_type(
                first, second, "subtraction"))
            assert.is_true(difference.rhs_decay)
            assert.equal("Type.Integer", difference.result._tag)
            assert.same(types.CPointer(item, {"const"}), difference.common)

            local invalid, err = csemantics.pointer_common_type(
                first,
                types.CPointer(ctype(profile, "int"), {}),
                "subtraction")
            assert.is_nil(invalid)
            assert.matches("compatible complete", err)
        end)

        it("keeps same-spelled aggregate tags nominal", function()
            local first = types.CStruct(
                nil, "prototype_tag", nil, {}, true, false)
            local second = types.CStruct(
                nil, "prototype_tag", nil, {}, true, false)
            local first_pointer = types.CPointer(first, {})
            local second_pointer = types.CPointer(second, {})

            -- The general type relation is structural for internal uses, but
            -- C pointer compatibility must retain canonical tag identity.
            assert.is_true(types.equals(first, second))

            local ordered, ordered_err =
                csemantics.pointer_common_type(
                    first_pointer, second_pointer, "ordering")
            assert.is_nil(ordered)
            assert.matches("qualification%-compatible", ordered_err)

            local difference, difference_err =
                csemantics.pointer_common_type(
                    first_pointer, second_pointer, "subtraction")
            assert.is_nil(difference)
            assert.matches("compatible complete", difference_err)

            local equality = assert(
                csemantics.pointer_equality_common_type(
                    first_pointer, second_pointer))
            assert.equal("Type.CVoid",
                types.resolve_c_typedef(
                    equality.common.pointee)._tag)
        end)

        it("target-types nil and accepts only matching function pointers",
           function()
            local profile = lp64_profile()
            local pointer =
                types.CPointer(ctype(profile, "int"), {"const"})
            local nil_decision = assert(
                csemantics.pointer_equality_common_type(
                    types.Nil(), pointer))
            assert.equal("lhs", nil_decision.null_side)
            assert.equal(pointer, nil_decision.common)

            local callback = types.CFunction(
                {ctype(profile, "int")}, types.CVoid(), false, "cdecl")
            local callback_pointer = types.CPointer(callback, {})
            assert(csemantics.pointer_equality_common_type(
                callback_pointer, callback_pointer))

            local other_callback = types.CPointer(types.CFunction(
                {}, types.CVoid(), false, "cdecl"), {})
            local invalid, err =
                csemantics.pointer_equality_common_type(
                    callback_pointer, other_callback)
            assert.is_nil(invalid)
            assert.matches("matching function pointers", err)
        end)

        it("preserves builtin Lua-state identity in recovered callbacks",
           function()
            local state = types.CStruct(
                nil, "lua_State", nil, {}, false, false)
            local state_pointer = types.CPointer(state, {})
            local callback = types.CPointer(types.CFunction(
                {state_pointer}, ctype(lp64_profile(), "int"), false, nil), {})
            local recovered = assert(load(
                "return " .. types.serialize(callback),
                "recovered-callback", "t", types))()

            assert.is_true(types.equals(callback, recovered))
            assert(csemantics.pointer_equality_common_type(
                callback, recovered))
            local state_equality = assert(
                csemantics.pointer_equality_common_type(
                    state_pointer, recovered.pointee.params[1]))
            assert.is_true(types.is_c_lua_state(
                state_equality.common.pointee))

            -- Ordinary opaque C tags remain nominal despite identical fields
            -- and spelling; the exception is the existing builtin identity.
            local function other_callback()
                return types.CPointer(types.CFunction({types.CPointer(
                    types.CStruct(nil, "OtherState", nil, {}, false, false),
                    {})}, types.CVoid(), false, nil), {})
            end
            local invalid, err = csemantics.pointer_equality_common_type(
                other_callback(), other_callback())
            assert.is_nil(invalid)
            assert.matches("matching function pointers", err)
        end)
    end)

    describe("complete C operator decisions", function()
        it("computes unary, mixed, floating, and shift targets", function()
            local profile = lp64_profile()
            local uchar = ctype(profile, "unsigned char")
            local ulong = ctype(profile, "unsigned long")

            local minus = assert(csemantics.decide_unary_operator(
                profile, "-", uchar))
            local complement = assert(csemantics.decide_unary_operator(
                profile, "~", uchar))
            assert.equal(ctype(profile, "int"), minus.result)
            assert.equal(ctype(profile, "int"), complement.result)

            local mixed = assert(csemantics.decide_binary_operator(
                profile, "+", uchar, types.Integer()))
            assert.equal(ctype(profile, "long long"),
                mixed.lhs_target)
            assert.equal(mixed.lhs_target, mixed.rhs_target)
            assert.equal(mixed.lhs_target, mixed.result)

            local floating = assert(csemantics.decide_binary_operator(
                profile, "*", ctype(profile, "float"),
                types.Float()))
            assert.equal(ctype(profile, "double"), floating.result)

            local shift = assert(csemantics.decide_binary_operator(
                profile, "<<", uchar, ulong))
            assert.equal(ctype(profile, "int"), shift.lhs_target)
            assert.equal(ulong, shift.rhs_target)
            assert.equal(shift.lhs_target, shift.result)
        end)

        it("records syntax mappings, decay, null, and pointer difference",
        function()
            local profile = lp64_profile()
            local item = types.CStruct(
                nil, "operator_item", nil, {}, true, false)
            local pointer = types.CPointer(item, {"const"})

            local xor = assert(csemantics.decide_binary_operator(
                profile, "~",
                ctype(profile, "unsigned int"),
                ctype(profile, "unsigned int")))
            local unequal = assert(csemantics.decide_binary_operator(
                profile, "~=", pointer, types.Nil()))
            local decay = assert(csemantics.decide_binary_operator(
                profile, "+", types.CArray(item, 3),
                types.Integer()))
            local difference = assert(
                csemantics.decide_binary_operator(
                    profile, "-", pointer,
                    types.CPointer(item, {"volatile"})))

            assert.equal("^", xor.cop)
            assert.equal("!=", unequal.cop)
            assert.is_true(unequal.rhs_null)
            assert.equal(unequal.lhs_target, unequal.rhs_target)
            assert.is_true(decay.lhs_decay)
            assert.equal("Type.CPointer", decay.result._tag)
            assert.equal("Type.Integer", difference.result._tag)
            assert.same({"const", "volatile"},
                difference.lhs_target.quals)
        end)

        it("rejects intrinsic shape errors without a target profile",
        function()
            local aggregate = types.CStruct(
                nil, "aggregate_operand", nil, {}, true, false)
            local result, err, handled =
                csemantics.decide_binary_operator(
                    nil, "==", aggregate, aggregate)
            assert.is_nil(result)
            assert.is_true(handled)
            assert.matches("C binary operator", err, 1, true)
            assert.matches("object pointers", err, 1, true)
            assert.not_matches("target profile", err, 1, true)
        end)

        it("does not capture explicitly excluded Titan syntax", function()
            local profile = lp64_profile()
            local uint = ctype(profile, "unsigned int")
            for _, op in ipairs({"//", "^", "and", "or"}) do
                local trait, err, handled =
                    csemantics.decide_binary_operator(
                        profile, op, uint, uint)
                assert.is_nil(trait)
                assert.is_nil(err)
                assert.is_false(handled)
            end
            local trait, err, handled =
                csemantics.decide_unary_operator(
                    profile, "not", uint)
            assert.is_nil(trait)
            assert.is_nil(err)
            assert.is_false(handled)
        end)
    end)
end)
