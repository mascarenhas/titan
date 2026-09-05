local types = require "titan-compiler.types"

local csemantics = {}
local evaluate_expression

-- A target profile is an injected, immutable-by-convention table:
--
-- {
--   int = "int",
--   unsigned_int = "unsigned int",
--   lua_integer = "long long",
--   lua_number = "double",
--   size_t = "unsigned long",
--   ptrdiff_t = "long",
--   integers = {
--     ["int"] = {
--       type = types.CInteger("int", true, 3, 32),
--       precision = 31,
--       minimum = "-2147483648",
--       maximum = "2147483647",
--       unsigned = "unsigned int",
--     },
--     ...
--   },
--   floats = {
--     ["float"] = {
--       type = types.CFloat("float"),
--       rank = 1,
--       bits = 32,
--     },
--     ...
--   },
-- }
--
-- precision is the number of value bits: it excludes the sign bit and any
-- padding bits. minimum and maximum are retained as numbers or decimal strings
-- so a profile can compare exact ranges outside the host Lua integer range.
-- Large bounds should therefore be supplied as decimal strings.
--
-- build_profile(options) constructs this schema from an injected predefined-
-- macro table, carrier typedef spellings, and parsed <limits.h> minimum
-- expressions. The macro table may use the cpp representation (an object macro
-- is an array of replacement tokens) or direct replacement strings. No
-- compiler is queried here and no target program is executed. lua_integer and
-- lua_number are the C spellings selected by the configured luaconf.h; size_t
-- and ptrdiff_t are the configured <stddef.h> spellings. Common equivalent
-- spellings such as "signed long int" are canonicalized.
--
-- classify_integer_literal(profile, literal) consumes the metadata preserved
-- by c-parser/cdefines.lua and chooses the first target type in its ordered
-- candidate_classes whose range contains the value.
--
-- evaluate_macro_expression(profile, expression) evaluates the preserved
-- integer expression AST with C integer promotions/usual arithmetic
-- conversions. It returns { kind = "integer", type = Type.CInteger,
-- entry = <profile entry>, value = <exact decimal string> }. The evaluator is
-- intentionally bounded to integer constant expressions; unsupported leaves
-- and target-dependent undefined behavior produce diagnostics instead of
-- borrowing host Lua arithmetic. It covers unary integer operators, ordinary
-- arithmetic, shifts, bitwise/logical/comparison operators, `?:`, and comma.

local function sorted_keys(t)
    local keys = {}
    for key in pairs(t or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function normalized_bound(value)
    if type(value) == "number" then
        if math.type(value) ~= "integer" then return nil end
        value = tostring(value)
    elseif type(value) ~= "string" then
        return nil
    end

    local sign, digits = value:match("^([+-]?)(%d+)$")
    if not digits then return nil end
    digits = digits:gsub("^0+", "")
    if digits == "" then return 0, "0" end
    return sign == "-" and -1 or 1, digits
end

local function compare_bounds(left, right)
    local left_sign, left_digits = normalized_bound(left)
    local right_sign, right_digits = normalized_bound(right)
    if left_sign == nil or right_sign == nil then
        return nil, "target profile contains a non-decimal integer bound"
    end
    if left_sign ~= right_sign then
        return left_sign < right_sign and -1 or 1
    elseif left_sign == 0 then
        return 0
    end

    local magnitude
    if #left_digits ~= #right_digits then
        magnitude = #left_digits < #right_digits and -1 or 1
    elseif left_digits == right_digits then
        magnitude = 0
    else
        magnitude = left_digits < right_digits and -1 or 1
    end
    return left_sign < 0 and -magnitude or magnitude
end

-- Exact decimal integer helpers. These deliberately use only small
-- single-digit host arithmetic; target values can therefore exceed both the
-- host Lua integer and floating-point ranges.
local function normalize_magnitude(value)
    value = tostring(value):gsub("^0+", "")
    return value == "" and "0" or value
end

local function compare_magnitudes(left, right)
    left = normalize_magnitude(left)
    right = normalize_magnitude(right)
    if #left ~= #right then
        return #left < #right and -1 or 1
    elseif left == right then
        return 0
    end
    return left < right and -1 or 1
end

local function add_magnitudes(left, right)
    local out = {}
    local li, ri = #left, #right
    local carry = 0
    while li > 0 or ri > 0 or carry > 0 do
        local l = li > 0 and tonumber(left:sub(li, li)) or 0
        local r = ri > 0 and tonumber(right:sub(ri, ri)) or 0
        local sum = l + r + carry
        out[#out + 1] = tostring(sum % 10)
        carry = math.floor(sum / 10)
        li = li - 1
        ri = ri - 1
    end
    for i = 1, math.floor(#out / 2) do
        out[i], out[#out - i + 1] = out[#out - i + 1], out[i]
    end
    return normalize_magnitude(table.concat(out))
end

local function subtract_magnitudes(left, right)
    -- Precondition: left >= right.
    local out = {}
    local li, ri = #left, #right
    local borrow = 0
    while li > 0 do
        local l = tonumber(left:sub(li, li)) - borrow
        local r = ri > 0 and tonumber(right:sub(ri, ri)) or 0
        if l < r then
            l = l + 10
            borrow = 1
        else
            borrow = 0
        end
        out[#out + 1] = tostring(l - r)
        li = li - 1
        ri = ri - 1
    end
    for i = 1, math.floor(#out / 2) do
        out[i], out[#out - i + 1] = out[#out - i + 1], out[i]
    end
    return normalize_magnitude(table.concat(out))
end

local function multiply_magnitude_small(value, multiplier)
    if multiplier == 0 or value == "0" then return "0" end
    local out = {}
    local carry = 0
    for i = #value, 1, -1 do
        local product = tonumber(value:sub(i, i)) * multiplier + carry
        out[#out + 1] = tostring(product % 10)
        carry = math.floor(product / 10)
    end
    while carry > 0 do
        out[#out + 1] = tostring(carry % 10)
        carry = math.floor(carry / 10)
    end
    for i = 1, math.floor(#out / 2) do
        out[i], out[#out - i + 1] = out[#out - i + 1], out[i]
    end
    return normalize_magnitude(table.concat(out))
end

local function multiply_magnitudes(left, right)
    local result = "0"
    local zeroes = ""
    for i = #right, 1, -1 do
        local digit = tonumber(right:sub(i, i))
        local part = multiply_magnitude_small(left, digit)
        if part ~= "0" then part = part .. zeroes end
        result = add_magnitudes(result, part)
        zeroes = zeroes .. "0"
    end
    return normalize_magnitude(result)
end

local function divide_magnitude_small(value, divisor)
    local out = {}
    local remainder = 0
    for i = 1, #value do
        local current = remainder * 10 + tonumber(value:sub(i, i))
        out[#out + 1] = tostring(math.floor(current / divisor))
        remainder = current % divisor
    end
    return normalize_magnitude(table.concat(out)), remainder
end

local function divide_magnitudes(dividend, divisor)
    dividend = normalize_magnitude(dividend)
    divisor = normalize_magnitude(divisor)
    if divisor == "0" then return nil, nil, "division by zero" end
    if compare_magnitudes(dividend, divisor) < 0 then
        return "0", dividend
    end

    local quotient = {}
    local remainder = "0"
    for i = 1, #dividend do
        remainder = normalize_magnitude(
            (remainder == "0" and "" or remainder) ..
            dividend:sub(i, i))
        local digit = 0
        for candidate = 9, 1, -1 do
            if compare_magnitudes(
                multiply_magnitude_small(divisor, candidate),
                remainder) <= 0 then
                digit = candidate
                break
            end
        end
        quotient[#quotient + 1] = tostring(digit)
        if digit > 0 then
            remainder = subtract_magnitudes(
                remainder, multiply_magnitude_small(divisor, digit))
        end
    end
    return normalize_magnitude(table.concat(quotient)),
        normalize_magnitude(remainder)
end

local function decimal_parts(value)
    local sign, digits = normalized_bound(value)
    if sign == nil then return nil end
    return sign, digits
end

local function decimal_from_parts(sign, magnitude)
    magnitude = normalize_magnitude(magnitude)
    if magnitude == "0" then return "0" end
    return sign < 0 and "-" .. magnitude or magnitude
end

local function negate_decimal(value)
    local sign, magnitude = assert(decimal_parts(value))
    return decimal_from_parts(-sign, magnitude)
end

local function add_decimals(left, right)
    local left_sign, left_magnitude = assert(decimal_parts(left))
    local right_sign, right_magnitude = assert(decimal_parts(right))
    if left_sign == 0 then return decimal_from_parts(right_sign, right_magnitude) end
    if right_sign == 0 then return decimal_from_parts(left_sign, left_magnitude) end
    if left_sign == right_sign then
        return decimal_from_parts(
            left_sign, add_magnitudes(left_magnitude, right_magnitude))
    end
    local order = compare_magnitudes(left_magnitude, right_magnitude)
    if order == 0 then return "0" end
    if order > 0 then
        return decimal_from_parts(left_sign,
            subtract_magnitudes(left_magnitude, right_magnitude))
    end
    return decimal_from_parts(right_sign,
        subtract_magnitudes(right_magnitude, left_magnitude))
end

local function subtract_decimals(left, right)
    return add_decimals(left, negate_decimal(right))
end

local function multiply_decimals(left, right)
    local left_sign, left_magnitude = assert(decimal_parts(left))
    local right_sign, right_magnitude = assert(decimal_parts(right))
    return decimal_from_parts(left_sign * right_sign,
        multiply_magnitudes(left_magnitude, right_magnitude))
end

local function divide_decimals(left, right)
    local left_sign, left_magnitude = assert(decimal_parts(left))
    local right_sign, right_magnitude = assert(decimal_parts(right))
    if right_sign == 0 then return nil, nil, "division by zero" end
    local quotient, remainder =
        divide_magnitudes(left_magnitude, right_magnitude)
    return decimal_from_parts(left_sign * right_sign, quotient),
        decimal_from_parts(left_sign, remainder)
end

-- Profile validation and integer-expression evaluation ask for the same small
-- set of exact powers repeatedly. Cache this pure decimal result by exponent,
-- rather than caching validation of a profile table: externally assembled
-- profiles are still fully revalidated on every public macro-evaluation call.
-- A bounded FIFO retains only modest decimal strings, so synthetic wide
-- profiles and many distinct shift counts cannot grow module-lifetime memory
-- without bound. Larger powers remain exact; they are simply not retained.
local POWER_CACHE_ENTRIES = 64
local POWER_CACHE_MAX_DIGITS = 4096
local powers_of_two = {}
local power_cache_order = {}
local power_cache_count = 0
local power_cache_oldest = 1

local function cache_power_of_two(exponent, value)
    if #value > POWER_CACHE_MAX_DIGITS then return end
    if power_cache_count < POWER_CACHE_ENTRIES then
        power_cache_count = power_cache_count + 1
        power_cache_order[power_cache_count] = exponent
    else
        local evicted = power_cache_order[power_cache_oldest]
        powers_of_two[evicted] = nil
        power_cache_order[power_cache_oldest] = exponent
        power_cache_oldest =
            power_cache_oldest % POWER_CACHE_ENTRIES + 1
    end
    powers_of_two[exponent] = value
end

local function power_of_two(exponent)
    local cached = powers_of_two[exponent]
    if cached then return cached end
    local value = "1"
    for _ = 1, exponent do
        value = multiply_magnitude_small(value, 2)
    end
    cache_power_of_two(exponent, value)
    return value
end

local function radix_to_decimal(digits, radix)
    local value = "0"
    for i = 1, #digits do
        local byte = digits:byte(i)
        local digit
        if byte >= 48 and byte <= 57 then
            digit = byte - 48
        elseif byte >= 65 and byte <= 70 then
            digit = byte - 65 + 10
        elseif byte >= 97 and byte <= 102 then
            digit = byte - 97 + 10
        else
            return nil, "invalid digit in integer constant"
        end
        if digit >= radix then
            return nil, "digit is outside the integer constant's radix"
        end
        value = add_magnitudes(
            multiply_magnitude_small(value, radix), tostring(digit))
    end
    return value
end

local function precision_from_maximum(maximum, storage_bits, spelling)
    local candidate = "0"
    for precision = 1, storage_bits do
        candidate = add_magnitudes(
            multiply_magnitude_small(candidate, 2), "1")
        local order = compare_magnitudes(candidate, maximum)
        if order == 0 then return precision end
        if order > 0 then break end
    end
    return nil, "predefined maximum for '" .. spelling ..
        "' is not a binary signed-integer maximum within its storage width"
end

local function canonical_integer_spelling(spelling)
    if type(spelling) ~= "string" then return nil end
    local words = {}
    for word in spelling:gmatch("%S+") do
        if word ~= "int" then words[#words + 1] = word end
    end
    local joined = table.concat(words, " ")
    local aliases = {
        [""] = "int",
        ["signed"] = "int",
        ["unsigned"] = "unsigned int",
        ["char"] = "char",
        ["signed char"] = "signed char",
        ["unsigned char"] = "unsigned char",
        ["short"] = "short",
        ["signed short"] = "short",
        ["short signed"] = "short",
        ["unsigned short"] = "unsigned short",
        ["short unsigned"] = "unsigned short",
        ["long"] = "long",
        ["signed long"] = "long",
        ["long signed"] = "long",
        ["unsigned long"] = "unsigned long",
        ["long unsigned"] = "unsigned long",
        ["long long"] = "long long",
        ["signed long long"] = "long long",
        ["long long signed"] = "long long",
        ["unsigned long long"] = "unsigned long long",
        ["long long unsigned"] = "unsigned long long",
    }
    return aliases[joined]
end

local function canonical_float_spelling(spelling)
    if type(spelling) ~= "string" then return nil end
    spelling = spelling:gsub("^%s+", ""):gsub("%s+$", "")
        :gsub("%s+", " ")
    if spelling == "float"
       or spelling == "double"
       or spelling == "long double" then
        return spelling
    end
    return nil
end

local function macro_replacement(macros, name, seen)
    local replacement = macros[name]
    if replacement == nil then
        return nil, "target profile is missing required predefined macro '" ..
            name .. "'"
    end
    if type(replacement) == "number" then
        if math.type(replacement) ~= "integer" then
            return nil, "predefined macro '" .. name ..
                "' is not an integer constant"
        end
        return tostring(replacement)
    elseif type(replacement) == "string" then
        replacement = replacement:gsub("^%s+", ""):gsub("%s+$", "")
    elseif type(replacement) == "table" then
        if replacement.args ~= nil then
            return nil, "predefined macro '" .. name ..
                "' is function-like, not an integer trait"
        end
        local tokens = replacement.repl or replacement
        local pieces = {}
        for index = 1, #tokens do
            if type(tokens[index]) ~= "string" then
                return nil, "predefined macro '" .. name ..
                    "' contains a non-token replacement"
            end
            pieces[index] = tokens[index]
        end
        replacement = table.concat(pieces)
    else
        return nil, "predefined macro '" .. name ..
            "' has an unsupported replacement"
    end

    while replacement:match("^%b()$") do
        replacement = replacement:sub(2, -2)
            :gsub("^%s+", ""):gsub("%s+$", "")
    end
    local alias = replacement:match("^[_%a][_%w]*$")
    if alias and macros[alias] ~= nil then
        seen = seen or {}
        if seen[name] then
            return nil, "predefined macro alias cycle while resolving '" ..
                name .. "'"
        end
        seen[name] = true
        return macro_replacement(macros, alias, seen)
    end
    return replacement
end

local function parse_integer_token(token, trait_name)
    token = token:gsub("^%+", "")
    local digits, radix
    digits = token:match("^0[xX]([0-9a-fA-F]+)[uUlL]*$")
    if digits then
        radix = 16
    else
        digits = token:match("^0([0-7]*)[uUlL]*$")
        if digits then
            radix = 8
            if digits == "" then digits = "0" end
        else
            digits = token:match("^([1-9][0-9]*)[uUlL]*$")
            if digits then radix = 10 end
        end
    end
    if not digits then
        return nil, "predefined macro '" .. trait_name ..
            "' is not a single nonnegative integer constant"
    end
    local value, err = radix_to_decimal(digits, radix)
    if not value then
        return nil, "invalid predefined macro '" .. trait_name ..
            "': " .. err
    end
    return value
end

local function required_macro_integer(macros, name)
    local replacement, err = macro_replacement(macros, name)
    if not replacement then return nil, err end
    return parse_integer_token(replacement, name)
end

local function optional_macro_integer(macros, names)
    for _, name in ipairs(names) do
        if macros[name] ~= nil then
            local value, err = required_macro_integer(macros, name)
            return value, name, err
        end
    end
    return nil
end

local function make_profile_integer(
    spelling, signed, rank, bits, precision, minimum, maximum, unsigned)
    return {
        type = types.CInteger(spelling, signed, rank, bits),
        precision = precision,
        minimum = minimum,
        maximum = maximum,
        unsigned = unsigned,
    }
end

local function attach_profile_traits(profile)
    -- Keep the authoritative target traits on the canonical scalar descriptor
    -- objects handed to the foreign-type converter. These fields are
    -- deliberately outside typedecl's structural schema: they are
    -- checker-local lowering metadata, not part of a published Titan type.
    local integer_traits = {}
    for spelling, entry in pairs(profile.integers) do
        integer_traits[spelling] = {
            kind = "integer",
            spelling = spelling,
            signed = entry.type.signed,
            rank = entry.type.rank,
            bits = entry.type.bits,
            precision = entry.precision,
            minimum = entry.minimum,
            maximum = entry.maximum,
            unsigned = entry.unsigned,
        }
    end
    local float_traits = {}
    for spelling, entry in pairs(profile.floats) do
        float_traits[spelling] = {
            kind = "float",
            spelling = spelling,
            rank = entry.rank,
            bits = entry.bits,
            maximum_exponent = entry.maximum_exponent,
            maximum_macro = entry.maximum_macro,
            radix = entry.radix,
            mantissa_digits = entry.mantissa_digits,
        }
    end
    local carrier_traits = {
        identity = profile.identity,
        lua_integer = assert(integer_traits[profile.lua_integer]),
        lua_number = assert(float_traits[profile.lua_number]),
        size_t = assert(integer_traits[profile.size_t]),
        ptrdiff_t = assert(integer_traits[profile.ptrdiff_t]),
        long_double = assert(float_traits["long double"]),
    }
    for spelling, entry in pairs(profile.integers) do
        entry.type._c_numeric = integer_traits[spelling]
        entry.type._c_numeric_carriers = carrier_traits
    end
    for spelling, entry in pairs(profile.floats) do
        entry.type._c_numeric = float_traits[spelling]
        entry.type._c_numeric_carriers = carrier_traits
    end
end

-- Build a canonical target profile from injected compiler traits. This is a
-- pure constructor: callers own acquisition of the macro table and luaconf.h
-- spellings.
function csemantics.build_profile(macros, lua_integer, lua_number)
    local size_t
    local ptrdiff_t
    local signed_minima
    if lua_integer == nil and lua_number == nil
       and type(macros) == "table" and macros.macros ~= nil then
        local options = macros
        macros = options.macros
        lua_integer = options.lua_integer
        lua_number = options.lua_number
        size_t = options.size_t
        ptrdiff_t = options.ptrdiff_t
        signed_minima = options.signed_minima
    end
    if type(macros) ~= "table" then
        return nil, "target profile predefined macros must be a table"
    end

    local canonical_lua_integer =
        canonical_integer_spelling(lua_integer)
    if not canonical_lua_integer then
        return nil, "unsupported lua_Integer C spelling '" ..
            tostring(lua_integer) .. "'"
    end
    local canonical_lua_number = canonical_float_spelling(lua_number)
    if not canonical_lua_number then
        return nil, "unsupported lua_Number C spelling '" ..
            tostring(lua_number) .. "'"
    end
    local canonical_size_t = canonical_integer_spelling(size_t)
    if not canonical_size_t then
        return nil, "unsupported size_t C spelling '" ..
            tostring(size_t) .. "'"
    end
    local canonical_ptrdiff_t = canonical_integer_spelling(ptrdiff_t)
    if not canonical_ptrdiff_t then
        return nil, "unsupported ptrdiff_t C spelling '" ..
            tostring(ptrdiff_t) .. "'"
    end
    if type(signed_minima) ~= "table" then
        return nil, "target profile must provide parsed signed integer minima"
    end

    local char_bit, err = required_macro_integer(macros, "__CHAR_BIT__")
    if not char_bit then return nil, err end
    local char_bit_number = tonumber(char_bit)
    if not char_bit_number or char_bit_number < 1
       or char_bit_number > 1024 then
        return nil, "predefined macro '__CHAR_BIT__' is outside the supported profile range"
    end

    local profile = {
        int = "int",
        unsigned_int = "unsigned int",
        lua_integer = canonical_lua_integer,
        lua_number = canonical_lua_number,
        size_t = canonical_size_t,
        ptrdiff_t = canonical_ptrdiff_t,
        char_bit = char_bit_number,
        char_signed = macros.__CHAR_UNSIGNED__ == nil,
        integers = {},
        floats = {},
    }

    local bool_bytes = "1"
    if macros.__SIZEOF_BOOL__ ~= nil then
        bool_bytes, err =
            required_macro_integer(macros, "__SIZEOF_BOOL__")
        if not bool_bytes then return nil, err end
    end
    local bool_byte_number = tonumber(bool_bytes)
    if not bool_byte_number or bool_byte_number < 1
       or bool_byte_number > 1024 then
        return nil, "predefined storage width for '_Bool' is outside the supported profile range"
    end
    profile.integers._Bool = make_profile_integer(
        "_Bool", false, 0, bool_byte_number * char_bit_number, 1,
        "0", "1")

    local integer_specs = {
        {
            signed = "signed char", unsigned = "unsigned char", rank = 1,
            size = nil, maximum = "__SCHAR_MAX__",
            unsigned_maximum = {"__UCHAR_MAX__"},
        },
        {
            signed = "short", unsigned = "unsigned short", rank = 2,
            size = "__SIZEOF_SHORT__", maximum = "__SHRT_MAX__",
            unsigned_maximum = {"__USHRT_MAX__"},
        },
        {
            signed = "int", unsigned = "unsigned int", rank = 3,
            size = "__SIZEOF_INT__", maximum = "__INT_MAX__",
            unsigned_maximum = {"__UINT_MAX__"},
        },
        {
            signed = "long", unsigned = "unsigned long", rank = 4,
            size = "__SIZEOF_LONG__", maximum = "__LONG_MAX__",
            unsigned_maximum = {"__ULONG_MAX__"},
        },
        {
            signed = "long long", unsigned = "unsigned long long", rank = 5,
            size = "__SIZEOF_LONG_LONG__", maximum = "__LONG_LONG_MAX__",
            unsigned_maximum = {
                "__ULONG_LONG_MAX__", "__ULLONG_MAX__",
            },
        },
    }

    for _, spec in ipairs(integer_specs) do
        local bytes
        if spec.size then
            bytes, err = required_macro_integer(macros, spec.size)
            if not bytes then return nil, err end
        else
            bytes = "1"
        end
        local byte_number = tonumber(bytes)
        if not byte_number or byte_number < 1
           or byte_number > 1024 then
            return nil, "predefined storage width for '" .. spec.signed ..
                "' is outside the supported profile range"
        end
        local bits = byte_number * char_bit_number

        local signed_maximum
        signed_maximum, err =
            required_macro_integer(macros, spec.maximum)
        if not signed_maximum then return nil, err end
        local precision
        precision, err = precision_from_maximum(
            signed_maximum, bits, spec.signed)
        if not precision then return nil, err end

        local signed_minimum = "-" .. power_of_two(precision)
        local unsigned_maximum = subtract_magnitudes(
            power_of_two(precision + 1), "1")
        local advertised, advertised_name, advertised_err =
            optional_macro_integer(macros, spec.unsigned_maximum)
        if advertised_err then
            return nil, advertised_err
        elseif advertised
           and compare_magnitudes(advertised, unsigned_maximum) ~= 0 then
            return nil, "predefined macro '" .. advertised_name ..
                "' disagrees with the corresponding signed maximum"
        end

        profile.integers[spec.signed] = make_profile_integer(
            spec.signed, true, spec.rank, bits, precision,
            signed_minimum, signed_maximum, spec.unsigned)
        profile.integers[spec.unsigned] = make_profile_integer(
            spec.unsigned, false, spec.rank, bits, precision + 1,
            "0", unsigned_maximum)
    end

    -- __int128 is a compiler extension, not a mandatory C99 primitive. Keep it
    -- out of the semantic universe unless the selected target explicitly
    -- advertises storage for it. Its range follows the same binary integer
    -- representation traits used for the standard integer profile.
    if macros.__SIZEOF_INT128__ ~= nil then
        local bytes
        bytes, err =
            required_macro_integer(macros, "__SIZEOF_INT128__")
        if not bytes then return nil, err end
        local byte_number = tonumber(bytes)
        if not byte_number or byte_number < 1
           or byte_number > 1024 then
            return nil, "predefined storage width for '__int128' is outside the supported profile range"
        end
        local bits = byte_number * char_bit_number
        local precision = bits - 1
        local signed_maximum =
            subtract_magnitudes(power_of_two(precision), "1")
        local unsigned_maximum =
            subtract_magnitudes(power_of_two(bits), "1")
        profile.integers["__int128"] = make_profile_integer(
            "__int128", true, 6, bits, precision,
            "-" .. power_of_two(precision), signed_maximum,
            "unsigned __int128")
        profile.integers["unsigned __int128"] =
            make_profile_integer(
                "unsigned __int128", false, 6, bits, bits,
                "0", unsigned_maximum)
    end

    -- The maximum traits determine precision, but they cannot distinguish
    -- two's-complement from one's-complement or sign-magnitude signed ranges.
    -- Evaluate the configured <limits.h> minima exactly, then let profile
    -- validation issue Titan's explicit supported-target diagnostic.
    for _, spelling in ipairs({
        "signed char", "short", "int", "long", "long long",
    }) do
        local source = signed_minima[spelling]
        if source == nil then
            return nil, "target profile is missing the configured minimum for '"
                .. spelling .. "'"
        end
        local minimum
        if type(source) == "string" or type(source) == "number" then
            local sign, magnitude = normalized_bound(source)
            if sign == nil then
                return nil, "configured minimum for '" .. spelling
                    .. "' is not a decimal integer"
            end
            minimum = decimal_from_parts(sign, magnitude)
        elseif type(source) == "table" then
            local evaluated, evaluation_error =
                evaluate_expression(profile, source)
            if not evaluated then
                return nil, "cannot evaluate configured minimum for '"
                    .. spelling .. "': " .. tostring(evaluation_error)
            end
            minimum = evaluated.value
        else
            return nil, "configured minimum for '" .. spelling
                .. "' has an unsupported representation"
        end
        profile.integers[spelling].minimum = minimum
    end

    local char_source = profile.char_signed
        and profile.integers["signed char"]
        or profile.integers["unsigned char"]
    profile.integers.char = make_profile_integer(
        "char", profile.char_signed, 1, char_source.type.bits,
        char_source.precision, char_source.minimum, char_source.maximum,
        profile.char_signed and "unsigned char" or nil)

    local float_radix
    if macros.__FLT_RADIX__ ~= nil then
        float_radix, err =
            required_macro_integer(macros, "__FLT_RADIX__")
        if not float_radix then return nil, err end
        float_radix = tonumber(float_radix)
        if not float_radix or float_radix < 2
           or float_radix > 1000000000 then
            return nil, "predefined floating radix is outside the supported profile range"
        end
    end
    local float_specs = {
        {"float", 1, "__SIZEOF_FLOAT__", "__FLT_MAX_EXP__", "FLT_MAX",
            "__FLT_MANT_DIG__"},
        {"double", 2, "__SIZEOF_DOUBLE__", "__DBL_MAX_EXP__", "DBL_MAX",
            "__DBL_MANT_DIG__"},
        {"long double", 3, "__SIZEOF_LONG_DOUBLE__",
            "__LDBL_MAX_EXP__", "LDBL_MAX", "__LDBL_MANT_DIG__"},
    }
    for _, spec in ipairs(float_specs) do
        local bytes
        bytes, err = required_macro_integer(macros, spec[3])
        if not bytes then return nil, err end
        local byte_number = tonumber(bytes)
        if not byte_number or byte_number < 1
           or byte_number > 1024 then
            return nil, "predefined storage width for '" .. spec[1] ..
                "' is outside the supported profile range"
        end
        local maximum_exponent
        if macros[spec[4]] ~= nil then
            maximum_exponent, err =
                required_macro_integer(macros, spec[4])
            if not maximum_exponent then return nil, err end
            maximum_exponent = tonumber(maximum_exponent)
            if not maximum_exponent or maximum_exponent < 1
               or maximum_exponent > 1000000000 then
                return nil, "predefined maximum exponent for '" .. spec[1]
                    .. "' is outside the supported profile range"
            end
        end
        local mantissa_digits
        if macros[spec[6]] ~= nil then
            mantissa_digits, err =
                required_macro_integer(macros, spec[6])
            if not mantissa_digits then return nil, err end
            mantissa_digits = tonumber(mantissa_digits)
            if not mantissa_digits or mantissa_digits < 1
               or mantissa_digits > 1000000000 then
                return nil, "predefined mantissa width for '" .. spec[1]
                    .. "' is outside the supported profile range"
            end
        end
        profile.floats[spec[1]] = {
            type = types.CFloat(spec[1]),
            rank = spec[2],
            bits = byte_number * char_bit_number,
            maximum_exponent = maximum_exponent,
            maximum_macro = spec[5],
            radix = float_radix,
            mantissa_digits = mantissa_digits,
        }
    end

    local ok
    ok, err = csemantics.validate_profile(profile)
    if not ok then return nil, err end

    profile.identity = assert(csemantics.profile_identity(profile))

    attach_profile_traits(profile)
    return profile
end

-- Compatibility name for integrations that prefer a noun-based constructor.
csemantics.profile_from_macros = csemantics.build_profile

local function profile_integer(profile, spelling)
    local entry = profile and profile.integers
        and profile.integers[spelling]
    if not entry then
        return nil, "C integer type '" .. tostring(spelling) ..
            "' is not described by the target profile; use an explicit cast"
    end
    if not entry.type or entry.type._tag ~= "Type.CInteger"
       or type(entry.type.rank) ~= "number"
       or type(entry.precision) ~= "number" then
        return nil, "target profile has incomplete integer metadata for '" ..
            tostring(spelling) .. "'"
    end
    return entry
end

local function profile_float(profile, spelling)
    local entry = profile and profile.floats and profile.floats[spelling]
    if not entry then
        return nil, "C floating type '" .. tostring(spelling) ..
            "' is not described by the target profile; use an explicit cast"
    end
    if not entry.type or entry.type._tag ~= "Type.CFloat"
       or type(entry.rank) ~= "number" then
        return nil, "target profile has incomplete floating metadata for '" ..
            tostring(spelling) .. "'"
    end
    return entry
end

local function canonical_integer(profile, typ)
    local resolved = types.resolve_c_typedef(typ)
    if not resolved or resolved._tag ~= "Type.CInteger" then
        return nil, "expected a C integer type"
    end

    local entry, err = profile_integer(profile, resolved.spelling)
    if not entry then return nil, err end
    local canonical = entry.type
    if resolved.signed ~= nil and resolved.signed ~= canonical.signed then
        return nil, "C integer type '" .. resolved.spelling ..
            "' disagrees with the target profile's signedness"
    end
    if resolved.rank ~= nil and resolved.rank ~= false
       and resolved.rank ~= canonical.rank then
        return nil, "C integer type '" .. resolved.spelling ..
            "' disagrees with the target profile's rank"
    end
    if resolved.bits ~= nil and resolved.bits ~= false
       and resolved.bits ~= canonical.bits then
        return nil, "C integer type '" .. resolved.spelling ..
            "' disagrees with the target profile's storage width"
    end
    return canonical, entry
end

local function canonical_float(profile, typ)
    local resolved = types.resolve_c_typedef(typ)
    if not resolved or resolved._tag ~= "Type.CFloat" then
        return nil, "expected a C floating type"
    end
    local entry, err = profile_float(profile, resolved.spelling)
    if not entry then return nil, err end
    return entry.type, entry
end

function csemantics.validate_profile(profile)
    if type(profile) ~= "table" then
        return nil, "target profile must be a table"
    end
    if type(profile.integers) ~= "table"
       or type(profile.floats) ~= "table" then
        return nil, "target profile must define integer and floating tables"
    end
    if type(profile.int) ~= "string"
       or type(profile.unsigned_int) ~= "string" then
        return nil, "target profile must name int and unsigned int"
    end
    if type(profile.lua_integer) ~= "string"
       or type(profile.lua_number) ~= "string" then
        return nil, "target profile must name lua_Integer and lua_Number"
    end
    if type(profile.size_t) ~= "string"
       or type(profile.ptrdiff_t) ~= "string" then
        return nil, "target profile must name size_t and ptrdiff_t"
    end

    for _, spelling in ipairs(sorted_keys(profile.integers)) do
        local entry = profile.integers[spelling]
        if type(entry) ~= "table"
           or not entry.type
           or entry.type._tag ~= "Type.CInteger"
           or entry.type.spelling ~= spelling
           or type(entry.type.signed) ~= "boolean"
           or type(entry.type.rank) ~= "number"
           or type(entry.type.bits) ~= "number"
           or entry.type.bits <= 0
           or entry.type.bits % 1 ~= 0
           or type(entry.precision) ~= "number"
           or entry.precision <= 0
           or entry.precision % 1 ~= 0
           or entry.precision +
                (entry.type.signed and 1 or 0) > entry.type.bits
           or normalized_bound(entry.minimum) == nil
           or normalized_bound(entry.maximum) == nil then
            return nil, "invalid target integer profile entry for '" ..
                spelling .. "'"
        end
        local range_order = assert(compare_bounds(
            entry.minimum, entry.maximum))
        if range_order > 0 then
            return nil, "target integer profile has a reversed range for '" ..
                spelling .. "'"
        end
        if entry.type.signed then
            local expected_minimum = "-" .. power_of_two(entry.precision)
            local expected_maximum =
                subtract_magnitudes(power_of_two(entry.precision), "1")
            if assert(compare_bounds(
                    entry.minimum, expected_minimum)) ~= 0
               or assert(compare_bounds(
                    entry.maximum, expected_maximum)) ~= 0 then
                return nil, "unsupported C target profile: Titan requires "
                    .. "two's-complement signed integers, but '" .. spelling
                    .. "' has range " .. tostring(entry.minimum) .. ".."
                    .. tostring(entry.maximum)
            end
        end
    end

    for _, spelling in ipairs(sorted_keys(profile.floats)) do
        local entry = profile.floats[spelling]
        if type(entry) ~= "table"
           or not entry.type
           or entry.type._tag ~= "Type.CFloat"
           or entry.type.spelling ~= spelling
           or type(entry.rank) ~= "number"
           or (entry.bits ~= nil
               and (type(entry.bits) ~= "number"
                    or entry.bits <= 0
                    or entry.bits % 1 ~= 0))
           or (entry.maximum_exponent ~= nil
               and (type(entry.maximum_exponent) ~= "number"
                    or entry.maximum_exponent < 1
                    or entry.maximum_exponent % 1 ~= 0))
           or (entry.maximum_macro ~= nil
               and type(entry.maximum_macro) ~= "string")
           or (entry.radix ~= nil
               and (type(entry.radix) ~= "number"
                    or entry.radix < 2
                    or entry.radix % 1 ~= 0))
           or (entry.mantissa_digits ~= nil
               and (type(entry.mantissa_digits) ~= "number"
                    or entry.mantissa_digits < 1
                    or entry.mantissa_digits % 1 ~= 0)) then
            return nil, "invalid target floating profile entry for '" ..
                spelling .. "'"
        end
    end

    local int_entry, int_err = profile_integer(profile, profile.int)
    if not int_entry then return nil, int_err end
    local uint_entry, uint_err =
        profile_integer(profile, profile.unsigned_int)
    if not uint_entry then return nil, uint_err end
    if not int_entry.type.signed
       or uint_entry.type.signed
       or int_entry.type.rank ~= uint_entry.type.rank then
        return nil, "target profile's int pair has inconsistent ranks or signedness"
    end

    local lua_integer_entry, lua_integer_err =
        profile_integer(profile, profile.lua_integer)
    if not lua_integer_entry then return nil, lua_integer_err end
    if not lua_integer_entry.type.signed then
        return nil, "target profile's lua_Integer type must be signed"
    end
    local size_t_entry, size_t_err =
        profile_integer(profile, profile.size_t)
    if not size_t_entry then return nil, size_t_err end
    if size_t_entry.type.signed then
        return nil, "target profile's size_t type must be unsigned"
    end
    local ptrdiff_t_entry, ptrdiff_t_err =
        profile_integer(profile, profile.ptrdiff_t)
    if not ptrdiff_t_entry then return nil, ptrdiff_t_err end
    if not ptrdiff_t_entry.type.signed then
        return nil, "target profile's ptrdiff_t type must be signed"
    end
    local lua_number_entry, lua_number_err =
        profile_float(profile, profile.lua_number)
    if not lua_number_entry then return nil, lua_number_err end

    for _, spelling in ipairs({"float", "double", "long double"}) do
        local _, err = profile_float(profile, spelling)
        if err then return nil, err end
    end

    for _, spelling in ipairs(sorted_keys(profile.integers)) do
        local entry = profile.integers[spelling]
        if entry.type.signed and entry.type.rank >= int_entry.type.rank then
            if type(entry.unsigned) ~= "string" then
                return nil, "target profile lacks the unsigned counterpart of '" ..
                    spelling .. "'"
            end
            local unsigned, err = profile_integer(profile, entry.unsigned)
            if not unsigned then return nil, err end
            if unsigned.type.signed
               or unsigned.type.rank ~= entry.type.rank then
                return nil, "target profile has an invalid unsigned counterpart for '" ..
                    spelling .. "'"
            end
        end
    end

    return true
end

function csemantics.profile_identity(profile)
    local ok, err = csemantics.validate_profile(profile)
    if not ok then return nil, err end
    local identity = {
        "char_bit=" .. tostring(profile.char_bit or ""),
        "char_signed=" .. tostring(profile.char_signed),
        "lua_Integer=" .. profile.lua_integer,
        "lua_Number=" .. profile.lua_number,
        "size_t=" .. profile.size_t,
        "ptrdiff_t=" .. profile.ptrdiff_t,
    }
    for _, spelling in ipairs(sorted_keys(profile.integers)) do
        local entry = profile.integers[spelling]
        identity[#identity + 1] = table.concat({
            spelling,
            tostring(entry.type.signed),
            tostring(entry.type.rank),
            tostring(entry.type.bits),
            tostring(entry.precision),
            tostring(entry.minimum),
            tostring(entry.maximum),
        }, ":")
    end
    for _, spelling in ipairs(sorted_keys(profile.floats)) do
        local entry = profile.floats[spelling]
        identity[#identity + 1] = table.concat({
            spelling, tostring(entry.rank), tostring(entry.bits),
            tostring(entry.maximum_exponent or ""),
            tostring(entry.maximum_macro or ""),
            tostring(entry.radix or ""),
            tostring(entry.mantissa_digits or ""),
        }, ":")
    end
    return table.concat(identity, "|")
end

-- A semantic host may ship its build target alongside analysis-only module
-- metadata. Keep this wire format declarative: no Type objects, lowering
-- annotations, compiler commands, header paths, or executable Lua are admitted.
local profile_data_fields = {
    version = true, identity = true, char_bit = true, char_signed = true,
    int = true, unsigned_int = true, lua_integer = true, lua_number = true,
    size_t = true, ptrdiff_t = true, integers = true, floats = true,
}
local integer_data_fields = {
    signed = true, rank = true, bits = true, precision = true,
    minimum = true, maximum = true, unsigned = true,
}
local float_data_fields = {
    rank = true, bits = true, maximum_exponent = true, maximum_macro = true,
    radix = true, mantissa_digits = true,
}
local profile_integer_specs = {
    ["_Bool"] = { false, 0 },
    char = { false, 1 }, -- signedness is selected by char_signed
    ["signed char"] = { true, 1, "unsigned char" },
    ["unsigned char"] = { false, 1 },
    short = { true, 2, "unsigned short" },
    ["unsigned short"] = { false, 2 },
    int = { true, 3, "unsigned int" },
    ["unsigned int"] = { false, 3 },
    long = { true, 4, "unsigned long" },
    ["unsigned long"] = { false, 4 },
    ["long long"] = { true, 5, "unsigned long long" },
    ["unsigned long long"] = { false, 5 },
    ["__int128"] = { true, 6, "unsigned __int128" },
    ["unsigned __int128"] = { false, 6 },
}
local profile_float_specs = {
    float = { 1, "FLT_MAX" },
    double = { 2, "DBL_MAX" },
    ["long double"] = { 3, "LDBL_MAX" },
}

local function closed_profile_table(value, fields, label)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return nil, label .. " must be a plain table"
    end
    for key in pairs(value) do
        if not fields[key] then
            return nil, label .. " contains unexpected field " .. tostring(key)
        end
    end
    return true
end

local function bounded_profile_integer(value, lower, upper)
    return type(value) == "number" and value >= lower and value <= upper
        and value % 1 == 0
end

local function canonical_profile_bound(value)
    if type(value) ~= "string" then return false end
    local sign, magnitude = normalized_bound(value)
    return sign ~= nil and decimal_from_parts(sign, magnitude) == value
end

function csemantics.export_profile(profile)
    local identity, err = csemantics.profile_identity(profile)
    if not identity then return nil, err end
    local data = {
        version = 1, identity = identity,
        char_bit = profile.char_bit, char_signed = profile.char_signed,
        int = profile.int, unsigned_int = profile.unsigned_int,
        lua_integer = profile.lua_integer, lua_number = profile.lua_number,
        size_t = profile.size_t, ptrdiff_t = profile.ptrdiff_t,
        integers = {}, floats = {},
    }
    for spelling, entry in pairs(profile.integers) do
        local min_sign, min_magnitude = normalized_bound(entry.minimum)
        local max_sign, max_magnitude = normalized_bound(entry.maximum)
        data.integers[spelling] = {
            signed = entry.type.signed, rank = entry.type.rank,
            bits = entry.type.bits, precision = entry.precision,
            minimum = decimal_from_parts(min_sign, min_magnitude),
            maximum = decimal_from_parts(max_sign, max_magnitude),
            unsigned = entry.unsigned,
        }
    end
    for spelling, entry in pairs(profile.floats) do
        local item = {}
        for field in pairs(float_data_fields) do item[field] = entry[field] end
        data.floats[spelling] = item
    end
    -- Export accepts only the same complete canonical target that import can
    -- reconstruct. Existing partial synthetic profiles remain useful to the
    -- numeric helper tests but are not an authoritative host manifest.
    local imported
    imported, err = csemantics.import_profile(data)
    if not imported then return nil, err end
    return data
end

function csemantics.import_profile(data)
    local ok, err = closed_profile_table(
        data, profile_data_fields, "target profile data")
    if not ok then return nil, err end
    if data.version ~= 1 then
        return nil, "unsupported target profile data version"
    elseif type(data.identity) ~= "string" or data.identity == "" then
        return nil, "target profile data identity must be a nonempty string"
    elseif not bounded_profile_integer(data.char_bit, 1, 1024)
       or type(data.char_signed) ~= "boolean"
       or data.int ~= "int" or data.unsigned_int ~= "unsigned int" then
        return nil, "target profile data has invalid C scalar parameters"
    end
    for _, field in ipairs({
        "lua_integer", "lua_number", "size_t", "ptrdiff_t",
    }) do
        if type(data[field]) ~= "string" then
            return nil, "target profile data must name " .. field
        end
    end
    ok, err = closed_profile_table(
        data.integers, profile_integer_specs, "target profile integer table")
    if not ok then return nil, err end
    ok, err = closed_profile_table(
        data.floats, profile_float_specs, "target profile floating table")
    if not ok then return nil, err end

    local profile = {
        char_bit = data.char_bit, char_signed = data.char_signed,
        int = data.int, unsigned_int = data.unsigned_int,
        lua_integer = data.lua_integer, lua_number = data.lua_number,
        size_t = data.size_t, ptrdiff_t = data.ptrdiff_t,
        integers = {}, floats = {},
    }
    for spelling, spec in pairs(profile_integer_specs) do
        local item = data.integers[spelling]
        local optional = spec[2] == 6
        if item ~= nil or not optional then
            local label = "target profile integer '" .. spelling .. "'"
            ok, err = closed_profile_table(item, integer_data_fields, label)
            if not ok then return nil, err end
            local signed = spelling == "char" and data.char_signed or spec[1]
            local unsigned = spec[3]
            if spelling == "char" and signed then unsigned = "unsigned char" end
            if item.signed ~= signed or item.rank ~= spec[2]
               or item.unsigned ~= unsigned
               or not bounded_profile_integer(item.bits, 1, data.char_bit * 1024)
               or item.bits % data.char_bit ~= 0
               or not bounded_profile_integer(item.precision, 1, item.bits)
               or not canonical_profile_bound(item.minimum)
               or not canonical_profile_bound(item.maximum) then
                return nil, label .. " has invalid canonical fields"
            end
            if not signed and (item.minimum ~= "0"
               or item.maximum ~= subtract_magnitudes(
                    power_of_two(item.precision), "1")) then
                return nil, label .. " has an invalid unsigned range"
            end
            if spelling == "_Bool" and item.precision ~= 1 then
                return nil, label .. " must have exactly one value bit"
            end
            profile.integers[spelling] = make_profile_integer(
                spelling, signed, item.rank, item.bits, item.precision,
                item.minimum, item.maximum, unsigned)
        end
    end
    local wide = profile.integers["__int128"]
    local unsigned_wide = profile.integers["unsigned __int128"]
    if (wide == nil) ~= (unsigned_wide == nil) then
        return nil, "target profile must contain both __int128 scalar entries"
    end
    for spelling, entry in pairs(profile.integers) do
        if entry.unsigned then
            local unsigned = profile.integers[entry.unsigned]
            if unsigned.type.bits ~= entry.type.bits
               or unsigned.precision ~= entry.precision + 1 then
                return nil, "target profile integer pair disagrees for '" ..
                    spelling .. "'"
            end
        end
    end
    local character = profile.integers.char
    local character_base = profile.integers[
        data.char_signed and "signed char" or "unsigned char"]
    if character.type.bits ~= data.char_bit
       or character.type.bits ~= character_base.type.bits
       or character.precision ~= character_base.precision
       or character.minimum ~= character_base.minimum
       or character.maximum ~= character_base.maximum then
        return nil, "target profile char entry disagrees with its representation"
    end
    for spelling, spec in pairs(profile_float_specs) do
        local item = data.floats[spelling]
        local label = "target profile floating type '" .. spelling .. "'"
        ok, err = closed_profile_table(item, float_data_fields, label)
        if not ok then return nil, err end
        if item.rank ~= spec[1] or item.maximum_macro ~= spec[2]
           or not bounded_profile_integer(item.bits, 1, data.char_bit * 1024)
           or item.bits % data.char_bit ~= 0 then
            return nil, label .. " has invalid canonical fields"
        end
        for _, field in ipairs({ "maximum_exponent", "mantissa_digits", "radix" }) do
            if item[field] ~= nil and not bounded_profile_integer(
                    item[field], field == "radix" and 2 or 1, 1000000000) then
                return nil, label .. " has invalid " .. field
            end
        end
        local entry = { type = types.CFloat(spelling) }
        for field in pairs(float_data_fields) do entry[field] = item[field] end
        profile.floats[spelling] = entry
    end
    local identity
    identity, err = csemantics.profile_identity(profile)
    if not identity then return nil, err end
    if identity ~= data.identity then
        return nil, "target profile data identity disagrees with its canonical fields"
    end
    profile.identity = identity
    attach_profile_traits(profile)
    return profile
end

-- Resolve a source type to the category and canonical target type used by C
-- expression semantics. Titan integer and float deliberately enter through
-- the profile's lua_Integer and lua_Number entries.
function csemantics.classify(profile, typ)
    if not typ then return nil, "missing operand type" end
    local resolved = types.resolve_c_typedef(typ)
    local tag = resolved and resolved._tag

    if tag == "Type.Integer" then
        if not profile or type(profile.lua_integer) ~= "string" then
            return nil,
                "target profile does not describe Titan integer's "
                .. "lua_Integer representation"
        end
        local entry, err = profile_integer(profile, profile.lua_integer)
        if not entry then return nil, err end
        return { kind = "integer", type = entry.type, entry = entry,
            titan = true }
    elseif tag == "Type.Float" then
        if not profile or type(profile.lua_number) ~= "string" then
            return nil,
                "target profile does not describe Titan float's "
                .. "lua_Number representation"
        end
        local entry, err = profile_float(profile, profile.lua_number)
        if not entry then return nil, err end
        return { kind = "float", type = entry.type, entry = entry,
            titan = true }
    elseif tag == "Type.CInteger" then
        local canonical, entry = canonical_integer(profile, resolved)
        if not canonical then return nil, entry end
        return { kind = "integer", type = canonical, entry = entry,
            titan = false }
    elseif tag == "Type.CFloat" then
        local canonical, entry = canonical_float(profile, resolved)
        if not canonical then return nil, entry end
        return { kind = "float", type = canonical, entry = entry,
            titan = false }
    elseif tag == "Type.CPointer" then
        return { kind = "pointer", type = resolved, titan = false }
    elseif tag == "Type.CArray" then
        return { kind = "array", type = resolved, titan = false }
    elseif tag == "Type.Nil" then
        return { kind = "nil", type = resolved, titan = true }
    elseif tag == "Type.CVoid" then
        return { kind = "void", type = resolved, titan = false }
    elseif tag == "Type.CFunction" then
        return { kind = "function", type = resolved, titan = false }
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        return { kind = "object", type = resolved, titan = false }
    end

    return nil, "type is not supported by C expression semantics"
end

function csemantics.scalar_category(profile, typ)
    local info, err = csemantics.classify(profile, typ)
    if not info then return nil, err end
    if info.kind ~= "integer"
       and info.kind ~= "float"
       and info.kind ~= "pointer" then
        return nil, "type is not a C scalar operand"
    end
    return info
end

local function copy_numeric_trait(entry)
    if not entry then return nil end
    if entry.type._tag == "Type.CInteger" then
        return {
            kind = "integer",
            spelling = entry.type.spelling,
            signed = entry.type.signed,
            rank = entry.type.rank,
            bits = entry.type.bits,
            precision = entry.precision,
            minimum = entry.minimum,
            maximum = entry.maximum,
            unsigned = entry.unsigned,
        }
    end
    return {
        kind = "float",
        spelling = entry.type.spelling,
        rank = entry.rank,
        bits = entry.bits,
        maximum_exponent = entry.maximum_exponent,
        maximum_macro = entry.maximum_macro,
        radix = entry.radix,
        mantissa_digits = entry.mantissa_digits,
    }
end

-- Return the authoritative scalar traits for a Titan carrier or direct C
-- numeric type. This is intentionally a profile query rather than a spelling
-- table in the coder: integer padding/ranges and the configured lua_Integer /
-- lua_Number spellings belong to the selected target.
function csemantics.numeric_trait(profile, typ)
    local resolved = types.resolve_c_typedef(typ)
    if not resolved then return nil, "missing numeric type" end
    if resolved._tag == "Type.Integer" then
        local entry, err = profile_integer(profile, profile.lua_integer)
        if not entry then return nil, err end
        return copy_numeric_trait(entry)
    elseif resolved._tag == "Type.Float" then
        local entry, err = profile_float(profile, profile.lua_number)
        if not entry then return nil, err end
        return copy_numeric_trait(entry)
    elseif resolved._tag == "Type.CInteger" then
        local canonical, entry = canonical_integer(profile, resolved)
        if not canonical then return nil, entry end
        return copy_numeric_trait(entry)
    elseif resolved._tag == "Type.CFloat" then
        local canonical, entry = canonical_float(profile, resolved)
        if not canonical then return nil, entry end
        return copy_numeric_trait(entry)
    end
    return nil, "type is not a numeric scalar"
end

-- Pure range query used while generating one checked scalar crossing.
function csemantics.integer_range_contains(target, source)
    if not target or target.kind ~= "integer"
       or not source or source.kind ~= "integer" then
        return nil, "integer range containment requires integer traits"
    end
    local minimum_order, minimum_err =
        compare_bounds(target.minimum, source.minimum)
    if minimum_order == nil then return nil, minimum_err end
    local maximum_order, maximum_err =
        compare_bounds(target.maximum, source.maximum)
    if maximum_order == nil then return nil, maximum_err end
    return minimum_order <= 0 and maximum_order >= 0
end

local function can_represent_all(target, source)
    local minimum_order, minimum_err =
        compare_bounds(target.minimum, source.minimum)
    if minimum_order == nil then return nil, minimum_err end
    local maximum_order, maximum_err =
        compare_bounds(target.maximum, source.maximum)
    if maximum_order == nil then return nil, maximum_err end
    return minimum_order <= 0 and maximum_order >= 0
end

function csemantics.integer_promotion(profile, typ)
    local info, err = csemantics.classify(profile, typ)
    if not info then return nil, err end
    if info.kind ~= "integer" then
        return nil, "integer promotion requires an integer operand"
    end

    local int_entry, int_err = profile_integer(profile, profile.int)
    if not int_entry then return nil, int_err end
    if info.entry.type.rank > int_entry.type.rank then
        return info.type
    end
    local representable, representable_err =
        can_represent_all(int_entry, info.entry)
    if representable == nil then return nil, representable_err end
    if representable then
        return int_entry.type
    end

    local uint_entry, uint_err =
        profile_integer(profile, profile.unsigned_int)
    if not uint_entry then return nil, uint_err end
    return uint_entry.type
end

function csemantics.float_precedence(profile, lhs, rhs)
    local left, left_err = csemantics.classify(profile, lhs)
    if not left then return nil, left_err end
    local right, right_err = csemantics.classify(profile, rhs)
    if not right then return nil, right_err end

    local winner
    if left.kind == "float" then winner = left end
    if right.kind == "float"
       and (not winner or right.entry.rank > winner.entry.rank) then
        winner = right
    end
    if not winner then
        return nil, "floating precedence requires a floating operand"
    end
    if (left.kind ~= "integer" and left.kind ~= "float")
       or (right.kind ~= "integer" and right.kind ~= "float") then
        return nil, "usual arithmetic conversion requires arithmetic operands"
    end
    return winner.type
end

local function promoted_info(profile, typ)
    local promoted, err = csemantics.integer_promotion(profile, typ)
    if not promoted then return nil, err end
    local entry, entry_err = profile_integer(profile, promoted.spelling)
    if not entry then return nil, entry_err end
    return { type = promoted, entry = entry }
end

function csemantics.usual_arithmetic_conversion(profile, lhs, rhs)
    local left, left_err = csemantics.classify(profile, lhs)
    if not left then return nil, left_err end
    local right, right_err = csemantics.classify(profile, rhs)
    if not right then return nil, right_err end
    if (left.kind ~= "integer" and left.kind ~= "float")
       or (right.kind ~= "integer" and right.kind ~= "float") then
        return nil, "usual arithmetic conversion requires arithmetic operands"
    end

    if left.kind == "float" or right.kind == "float" then
        return csemantics.float_precedence(profile, left.type, right.type)
    end

    local lp, lp_err = promoted_info(profile, left.type)
    if not lp then return nil, lp_err end
    local rp, rp_err = promoted_info(profile, right.type)
    if not rp then return nil, rp_err end

    if lp.type.spelling == rp.type.spelling then
        return lp.type
    end

    local lsigned = lp.type.signed
    local rsigned = rp.type.signed
    if lsigned == rsigned then
        if lp.type.rank == rp.type.rank then
            return nil, "target profile gives distinct promoted integer types the same rank"
        end
        return lp.type.rank > rp.type.rank and lp.type or rp.type
    end

    local signed = lsigned and lp or rp
    local unsigned = lsigned and rp or lp
    if unsigned.type.rank >= signed.type.rank then
        return unsigned.type
    else
        local representable, representable_err =
            can_represent_all(signed.entry, unsigned.entry)
        if representable == nil then return nil, representable_err end
        if representable then return signed.type end
    end

    local counterpart_name = signed.entry.unsigned
    if not counterpart_name then
        return nil, "target profile lacks the unsigned counterpart of '" ..
            signed.type.spelling .. "'"
    end
    local counterpart, counterpart_err =
        profile_integer(profile, counterpart_name)
    if not counterpart then return nil, counterpart_err end
    return counterpart.type
end

local function unsigned_modulus(entry)
    local _, maximum = assert(decimal_parts(entry.maximum))
    return add_magnitudes(maximum, "1")
end

local function modulo_positive(value, modulus)
    local sign, magnitude = assert(decimal_parts(value))
    local _, remainder = divide_magnitudes(magnitude, modulus)
    if sign < 0 and remainder ~= "0" then
        remainder = subtract_magnitudes(modulus, remainder)
    end
    return remainder
end

local function normalize_integer_value(entry, value, operation)
    local sign = decimal_parts(value)
    if sign == nil then
        return nil, "C integer evaluation produced a non-decimal value"
    end
    if not entry.type.signed then
        return modulo_positive(value, unsigned_modulus(entry))
    end

    local minimum_order, minimum_err =
        compare_bounds(value, entry.minimum)
    if minimum_order == nil then return nil, minimum_err end
    local maximum_order, maximum_err =
        compare_bounds(value, entry.maximum)
    if maximum_order == nil then return nil, maximum_err end
    if minimum_order < 0 or maximum_order > 0 then
        return nil, "signed overflow while evaluating C macro " ..
            (operation or "expression")
    end
    local value_sign, magnitude = assert(decimal_parts(value))
    return decimal_from_parts(value_sign, magnitude)
end

local function integer_result(profile, typ, value, operation)
    local entry, err = profile_integer(profile, typ.spelling)
    if not entry then return nil, err end
    local normalized
    normalized, err = normalize_integer_value(entry, value, operation)
    if not normalized then return nil, err end
    return {
        kind = "integer",
        type = entry.type,
        entry = entry,
        value = normalized,
    }
end

local function convert_integer_result(profile, result, typ, operation)
    return integer_result(profile, typ, result.value, operation)
end

local function candidate_spelling(candidate)
    if type(candidate.spelling) == "string" then
        return candidate.spelling
    end
    local rank = candidate.rank
    if rank == "long_long" then rank = "long long" end
    if rank ~= "int" and rank ~= "long" and rank ~= "long long" then
        return nil
    end
    return candidate.unsigned and "unsigned " .. rank or rank
end

-- Classify cdefines' target-neutral literal metadata under one target profile.
function csemantics.classify_integer_literal(profile, literal)
    if type(literal) ~= "table"
       or type(literal.digits) ~= "string"
       or type(literal.radix) ~= "number"
       or type(literal.candidate_classes) ~= "table" then
        return nil, "invalid preserved C integer-literal metadata"
    end
    local value, err = radix_to_decimal(literal.digits, literal.radix)
    if not value then
        return nil, "invalid C integer literal '" ..
            tostring(literal.token) .. "': " .. err
    end

    for _, candidate in ipairs(literal.candidate_classes) do
        local spelling = candidate_spelling(candidate)
        if not spelling then
            return nil, "C integer literal '" .. tostring(literal.token) ..
                "' has an invalid candidate class"
        end
        local entry
        entry, err = profile_integer(profile, spelling)
        if not entry then return nil, err end
        if candidate.unsigned ~= nil
           and candidate.unsigned == entry.type.signed then
            return nil, "C integer literal candidate '" .. spelling ..
                "' disagrees with the target profile's signedness"
        end
        if compare_bounds(value, entry.maximum) <= 0 then
            return {
                kind = "integer",
                type = entry.type,
                entry = entry,
                value = value,
                literal = literal,
                candidate = candidate,
            }
        end
    end

    return nil, "C integer literal '" .. tostring(literal.token) ..
        "' is not representable by any preserved candidate type"
end

-- Short compatibility name for consumers that already call the cdefines
-- payload a "literal".
csemantics.classify_literal = csemantics.classify_integer_literal

local function decimal_truth(value)
    local sign = assert(decimal_parts(value))
    return sign ~= 0
end

local function decimal_order(left, right)
    return assert(compare_bounds(left, right))
end

local function value_bits(entry, value)
    local width = entry.precision + (entry.type.signed and 1 or 0)
    local magnitude
    if entry.type.signed then
        local sign = assert(decimal_parts(value))
        if sign < 0 then
            magnitude = modulo_positive(value, power_of_two(width))
        else
            magnitude = value
        end
    else
        magnitude = modulo_positive(value, power_of_two(width))
    end

    local bits = {}
    for index = 1, width do
        local quotient, remainder =
            divide_magnitude_small(magnitude, 2)
        bits[index] = remainder
        magnitude = quotient
    end
    return bits, width
end

local function bits_value(entry, bits)
    local magnitude = "0"
    for index = #bits, 1, -1 do
        magnitude = multiply_magnitude_small(magnitude, 2)
        if bits[index] ~= 0 then
            magnitude = add_magnitudes(magnitude, "1")
        end
    end
    if entry.type.signed and bits[#bits] == 1 then
        return subtract_decimals(magnitude, power_of_two(#bits))
    end
    return magnitude
end

local function bitwise_value(entry, left, right, op)
    local left_bits, width = value_bits(entry, left)
    local right_bits = right and value_bits(entry, right) or nil
    local out = {}
    for index = 1, width do
        if op == "~" then
            out[index] = left_bits[index] == 0 and 1 or 0
        elseif op == "&" then
            out[index] =
                left_bits[index] == 1 and right_bits[index] == 1 and 1 or 0
        elseif op == "|" then
            out[index] =
                (left_bits[index] == 1 or right_bits[index] == 1) and 1 or 0
        elseif op == "^" then
            out[index] = left_bits[index] ~= right_bits[index] and 1 or 0
        end
    end
    return bits_value(entry, out)
end

local function promoted_result(profile, result)
    local typ, err = csemantics.integer_promotion(profile, result.type)
    if not typ then return nil, err end
    return convert_integer_result(profile, result, typ, "promotion")
end

local function common_results(profile, left, right)
    local typ, err = csemantics.usual_arithmetic_conversion(
        profile, left.type, right.type)
    if not typ then return nil, nil, nil, err end
    local converted_left
    converted_left, err =
        convert_integer_result(profile, left, typ, "conversion")
    if not converted_left then return nil, nil, nil, err end
    local converted_right
    converted_right, err =
        convert_integer_result(profile, right, typ, "conversion")
    if not converted_right then return nil, nil, nil, err end
    return converted_left, converted_right, typ
end

local function int_boolean(profile, truth)
    local entry, err = profile_integer(profile, profile.int)
    if not entry then return nil, err end
    return {
        kind = "integer",
        type = entry.type,
        entry = entry,
        value = truth and "1" or "0",
    }
end

local arithmetic_operators = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["&"] = true,
    ["|"] = true,
    ["^"] = true,
}

local comparison_operators = {
    ["<"] = true,
    ["<="] = true,
    [">"] = true,
    [">="] = true,
    ["=="] = true,
    ["!="] = true,
}

local expression_integer_type

local function integer_type_result(profile, typ)
    local resolved = types.resolve_c_typedef(typ)
    if not resolved or resolved._tag ~= "Type.CInteger" then
        return nil, "C macro expression does not have an integer type"
    end
    local entry, err = profile_integer(profile, resolved.spelling)
    if not entry then return nil, err end
    return {
        kind = "integer",
        type = entry.type,
        entry = entry,
    }
end

-- Determine the type of an integer constant-expression subtree without
-- evaluating its value. C still applies conversions to unevaluated operands of
-- &&, ||, and ?:, but undefined value operations in those operands (for
-- example division by zero) do not execute.
expression_integer_type = function(profile, expression)
    if type(expression) ~= "table" then
        return nil, "invalid preserved C macro expression"
    end

    local literal = expression.integer_literal
    if not literal and expression.candidate_classes
       and expression.digits then
        literal = expression
    end
    if literal then
        local result, err =
            csemantics.classify_integer_literal(profile, literal)
        if not result then return nil, err end
        result.value = nil
        return result
    end

    local op = expression.op or expression.unop
    if not op then
        local token = #expression == 1 and expression[1] or nil
        return nil, "C macro expression contains unsupported non-integer operand '" ..
            tostring(token) .. "'"
    elseif op == "," then
        if #expression == 0 then
            return nil, "invalid comma C macro expression"
        end
        local result
        for index = 1, #expression do
            local err
            result, err =
                expression_integer_type(profile, expression[index])
            if not result then return nil, err end
        end
        return result
    elseif op == "?" then
        if #expression ~= 3 then
            return nil, "invalid conditional C macro expression"
        end
        local condition, err =
            expression_integer_type(profile, expression[1])
        if not condition then return nil, err end
        local when_true
        when_true, err =
            expression_integer_type(profile, expression[2])
        if not when_true then return nil, err end
        local when_false
        when_false, err =
            expression_integer_type(profile, expression[3])
        if not when_false then return nil, err end
        local typ
        typ, err = csemantics.usual_arithmetic_conversion(
            profile, when_true.type, when_false.type)
        if not typ then return nil, err end
        return integer_type_result(profile, typ)
    end

    local left, err =
        expression_integer_type(profile, expression[1])
    if not left then return nil, err end
    if expression[2] == nil then
        if op == "!" then
            return integer_type_result(
                profile, profile.integers[profile.int].type)
        elseif op ~= "+" and op ~= "-" and op ~= "~" then
            return nil, "unsupported unary operator '" .. tostring(op) ..
                "' in C integer macro expression"
        end
        local typ
        typ, err = csemantics.integer_promotion(profile, left.type)
        if not typ then return nil, err end
        return integer_type_result(profile, typ)
    end

    local right
    right, err = expression_integer_type(profile, expression[2])
    if not right then return nil, err end
    if op == "&&" or op == "||"
       or comparison_operators[op] then
        return integer_type_result(
            profile, profile.integers[profile.int].type)
    elseif op == "<<" or op == ">>" then
        local typ
        typ, err = csemantics.integer_promotion(profile, left.type)
        if not typ then return nil, err end
        return integer_type_result(profile, typ)
    elseif not arithmetic_operators[op] then
        return nil, "unsupported binary operator '" .. tostring(op) ..
            "' in C integer macro expression"
    end

    local typ
    typ, err = csemantics.usual_arithmetic_conversion(
        profile, left.type, right.type)
    if not typ then return nil, err end
    return integer_type_result(profile, typ)
end

local function evaluate_unary(profile, expression, operand)
    local op = expression.op
    if op == "!" then
        return int_boolean(profile, not decimal_truth(operand.value))
    elseif op ~= "+" and op ~= "-" and op ~= "~" then
        return nil, "unsupported unary operator '" .. tostring(op) ..
            "' in C integer macro expression"
    end

    local promoted, err = promoted_result(profile, operand)
    if not promoted then return nil, err end
    if op == "+" then
        return promoted
    elseif op == "-" then
        return integer_result(profile, promoted.type,
            negate_decimal(promoted.value), "unary '-'")
    end
    return integer_result(profile, promoted.type,
        bitwise_value(promoted.entry, promoted.value, nil, "~"), "unary '~'")
end

local function evaluate_shift(profile, left, right, op)
    local promoted_left, err = promoted_result(profile, left)
    if not promoted_left then return nil, err end
    local promoted_right
    promoted_right, err = promoted_result(profile, right)
    if not promoted_right then return nil, err end

    local count_sign, count_magnitude =
        assert(decimal_parts(promoted_right.value))
    local width = promoted_left.entry.precision +
        (promoted_left.type.signed and 1 or 0)
    if count_sign < 0
       or compare_magnitudes(count_magnitude, tostring(width)) >= 0 then
        return nil, "invalid shift count while evaluating C macro expression"
    end
    local count = tonumber(count_magnitude)
    if op == "<<" then
        if promoted_left.type.signed
           and decimal_order(promoted_left.value, "0") < 0 then
            return nil, "left shift of a negative signed value in C macro expression"
        end
        return integer_result(profile, promoted_left.type,
            multiply_decimals(promoted_left.value, power_of_two(count)),
            "left shift")
    end

    if promoted_left.type.signed
       and decimal_order(promoted_left.value, "0") < 0 then
        return nil, "right shift of a negative signed value is target-dependent"
    end
    local quotient = divide_magnitudes(
        assert(select(2, decimal_parts(promoted_left.value))),
        power_of_two(count))
    return integer_result(profile, promoted_left.type, quotient, "right shift")
end

local function evaluate_binary(profile, expression, left, right)
    local op = expression.op
    if op == "<<" or op == ">>" then
        return evaluate_shift(profile, left, right, op)
    elseif op == "&&" or op == "||" then
        local left_truth = decimal_truth(left.value)
        local right_truth = decimal_truth(right.value)
        return int_boolean(profile,
            op == "&&" and left_truth and right_truth
            or op == "||" and (left_truth or right_truth))
    elseif not arithmetic_operators[op]
       and not comparison_operators[op] then
        return nil, "unsupported binary operator '" .. tostring(op) ..
            "' in C integer macro expression"
    end

    local converted_left, converted_right, typ, err =
        common_results(profile, left, right)
    if not converted_left then return nil, err end

    if comparison_operators[op] then
        local order =
            decimal_order(converted_left.value, converted_right.value)
        local truth =
            op == "<" and order < 0
            or op == "<=" and order <= 0
            or op == ">" and order > 0
            or op == ">=" and order >= 0
            or op == "==" and order == 0
            or op == "!=" and order ~= 0
        return int_boolean(profile, truth)
    end

    local value
    if op == "+" then
        value = add_decimals(converted_left.value, converted_right.value)
    elseif op == "-" then
        value = subtract_decimals(
            converted_left.value, converted_right.value)
    elseif op == "*" then
        value = multiply_decimals(
            converted_left.value, converted_right.value)
    elseif op == "/" or op == "%" then
        local quotient, remainder
        quotient, remainder, err = divide_decimals(
            converted_left.value, converted_right.value)
        if not quotient then
            return nil, err .. " while evaluating C macro expression"
        end
        if converted_left.type.signed then
            local valid_quotient
            valid_quotient, err = integer_result(
                profile, typ, quotient, "operator '" .. op .. "'")
            if not valid_quotient then return nil, err end
        end
        value = op == "/" and quotient or remainder
    else
        value = bitwise_value(
            converted_left.entry, converted_left.value,
            converted_right.value, op)
    end
    return integer_result(profile, typ, value, "operator '" .. op .. "'")
end

evaluate_expression = function(profile, expression)
    if type(expression) ~= "table" then
        return nil, "invalid preserved C macro expression"
    end

    local literal = expression.integer_literal
    if not literal and expression.candidate_classes
       and expression.digits then
        literal = expression
    end
    if literal then
        return csemantics.classify_integer_literal(profile, literal)
    end

    local op = expression.op or expression.unop
    if not op then
        local token = #expression == 1 and expression[1] or nil
        return nil, "C macro expression contains unsupported non-integer operand '" ..
            tostring(token) .. "'"
    end

    if op == "," then
        local result
        for index = 1, #expression do
            local err
            result, err = evaluate_expression(profile, expression[index])
            if not result then return nil, err end
        end
        return result
    elseif op == "?" then
        if #expression ~= 3 then
            return nil, "invalid conditional C macro expression"
        end
        local condition, err =
            evaluate_expression(profile, expression[1])
        if not condition then return nil, err end
        local true_type
        true_type, err =
            expression_integer_type(profile, expression[2])
        if not true_type then return nil, err end
        local false_type
        false_type, err =
            expression_integer_type(profile, expression[3])
        if not false_type then return nil, err end
        local typ
        typ, err = csemantics.usual_arithmetic_conversion(
            profile, true_type.type, false_type.type)
        if not typ then return nil, err end
        local selected_expression = decimal_truth(condition.value)
            and expression[2] or expression[3]
        local selected
        selected, err =
            evaluate_expression(profile, selected_expression)
        if not selected then return nil, err end
        return convert_integer_result(
            profile, selected, typ, "conditional")
    end

    local left, err = evaluate_expression(profile, expression[1])
    if not left then return nil, err end
    if expression[2] == nil then
        return evaluate_unary(profile, expression, left)
    end
    if op == "&&" or op == "||" then
        local right_type
        right_type, err =
            expression_integer_type(profile, expression[2])
        if not right_type then return nil, err end
        local left_truth = decimal_truth(left.value)
        if op == "&&" and not left_truth then
            return int_boolean(profile, false)
        elseif op == "||" and left_truth then
            return int_boolean(profile, true)
        end
    end
    local right
    right, err = evaluate_expression(profile, expression[2])
    if not right then return nil, err end
    return evaluate_binary(profile, expression, left, right)
end

function csemantics.evaluate_macro_expression(profile, expression)
    local ok, err = csemantics.validate_profile(profile)
    if not ok then return nil, err end
    return evaluate_expression(profile, expression)
end

csemantics.evaluate_integer_expression =
    csemantics.evaluate_macro_expression
csemantics.evaluate_integer_macro =
    csemantics.evaluate_macro_expression

function csemantics.shift_result(profile, lhs, rhs)
    local left, left_err = csemantics.classify(profile, lhs)
    if not left then return nil, left_err end
    local right, right_err = csemantics.classify(profile, rhs)
    if not right then return nil, right_err end
    if left.kind ~= "integer" or right.kind ~= "integer" then
        return nil, "shift requires integer operands"
    end
    return csemantics.integer_promotion(profile, left.type)
end

function csemantics.decay_array(typ)
    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == "Type.CArray" then
        return types.CPointer(
            resolved.elem, resolved.quals or {}), true
    end
    return resolved, false
end

local function is_complete_object(typ, seen)
    typ = types.resolve_c_typedef(typ)
    if not typ then return false end
    seen = seen or {}
    if seen[typ] then return true end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.CInteger"
       or tag == "Type.CFloat"
       or tag == "Type.CPointer" then
        return true
    elseif tag == "Type.CArray" then
        return typ.len ~= nil and typ.len ~= false
            and is_complete_object(typ.elem, seen)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        return typ.complete == true
    end
    return false
end

function csemantics.is_complete_object(typ)
    return is_complete_object(typ)
end

function csemantics.pointer_arithmetic(profile, pointer_like, integer)
    local pointer, decayed = csemantics.decay_array(pointer_like)
    if not pointer or pointer._tag ~= "Type.CPointer" then
        return nil, "pointer arithmetic requires a C pointer or array"
    end
    local pointee = types.resolve_c_typedef(pointer.pointee)
    if not is_complete_object(pointee) then
        return nil, "pointer arithmetic requires a complete non-void object type"
    end

    local offset, offset_err = csemantics.integer_promotion(profile, integer)
    if not offset then return nil, offset_err end
    return {
        pointer = pointer,
        offset = offset,
        result = pointer,
        pointer_decay = decayed,
    }
end

local qualifier_order = {"const", "volatile"}

local function add_qualifiers(set, quals)
    for _, qual in ipairs(quals or {}) do
        if qual == "const" or qual == "volatile" then
            set[qual] = true
        end
    end
end

local function collect_reachable_qualifiers(typ, set, seen)
    add_qualifiers(set, types.c_type_qualifiers(typ))
    typ = types.resolve_c_typedef(typ)
    if not typ or seen[typ] then return end
    seen[typ] = true
    if typ._tag == "Type.CPointer" then
        add_qualifiers(set, typ.quals)
        collect_reachable_qualifiers(typ.pointee, set, seen)
    elseif typ._tag == "Type.CArray" then
        add_qualifiers(set, typ.quals)
        collect_reachable_qualifiers(typ.elem, set, seen)
    end
end

local function qualifier_union(left, right, reachable)
    local set = {}
    if reachable then
        collect_reachable_qualifiers(left, set, {})
        collect_reachable_qualifiers(right, set, {})
    else
        add_qualifiers(set,
            types.c_pointer_pointee_qualifiers(left))
        add_qualifiers(set,
            types.c_pointer_pointee_qualifiers(right))
    end
    local result = {}
    for _, qual in ipairs(qualifier_order) do
        if set[qual] then result[#result + 1] = qual end
    end
    return result
end

local function pointer_kind(pointer)
    local pointee = types.resolve_c_typedef(pointer.pointee)
    if pointee._tag == "Type.CFunction" then
        return "function", pointee
    elseif pointee._tag == "Type.CVoid" then
        return "void", pointee
    end
    return "object", pointee
end

-- C tag compatibility is nominal even when two declarations happen to have
-- the same spelling and fields.  `types.equals` is intentionally structural
-- for several compiler-internal purposes, so guard every recursively reachable
-- aggregate before using it for the remaining primitive/function shape.
local function same_c_tag_identity(left, right, seen)
    left = types.resolve_c_typedef(left)
    right = types.resolve_c_typedef(right)
    if left == right then return true end
    if not left or not right or left._tag ~= right._tag then
        return true
    end

    local tag = left._tag
    if tag == "Type.CStruct" or tag == "Type.CUnion" then
        return false
    end

    seen = seen or {}
    local prior = seen[left]
    if prior and prior[right] then return true end
    prior = prior or {}
    seen[left] = prior
    prior[right] = true

    if tag == "Type.CPointer" then
        return same_c_tag_identity(left.pointee, right.pointee, seen)
    elseif tag == "Type.CArray" then
        return same_c_tag_identity(left.elem, right.elem, seen)
    elseif tag == "Type.CFunction" then
        if not same_c_tag_identity(left.ret, right.ret, seen)
           or #(left.params or {}) ~= #(right.params or {}) then
            return false
        end
        for index, param in ipairs(left.params or {}) do
            if not same_c_tag_identity(
                    param, right.params[index], seen) then
                return false
            end
        end
    end
    return true
end

local function compatible_c_pointee(left, right)
    return same_c_tag_identity(left, right)
       and types.equals(left, right)
end

local function pointer_decision(lhs, rhs, mode)
    local left, left_decay = csemantics.decay_array(lhs)
    local right, right_decay = csemantics.decay_array(rhs)

    if mode == "equality"
       and left and left._tag == "Type.Nil"
       and right and right._tag == "Type.CPointer" then
        return {
            lhs = right,
            rhs = right,
            common = right,
            result = types.Boolean(),
            lhs_decay = left_decay,
            rhs_decay = right_decay,
            null_side = "lhs",
        }
    elseif mode == "equality"
       and right and right._tag == "Type.Nil"
       and left and left._tag == "Type.CPointer" then
        return {
            lhs = left,
            rhs = left,
            common = left,
            result = types.Boolean(),
            lhs_decay = left_decay,
            rhs_decay = right_decay,
            null_side = "rhs",
        }
    end

    if not left or left._tag ~= "Type.CPointer"
       or not right or right._tag ~= "Type.CPointer" then
        return nil, "pointer comparison requires pointer or array operands"
    end

    local left_kind, left_pointee = pointer_kind(left)
    local right_kind, right_pointee = pointer_kind(right)
    local compatible =
        compatible_c_pointee(left_pointee, right_pointee)
    local common

    if left_kind == "function" or right_kind == "function" then
        if mode ~= "equality"
           or left_kind ~= "function"
           or right_kind ~= "function"
           or not compatible then
            return nil, "only matching function pointers support equality"
        end
        common = types.CPointer(left_pointee,
            qualifier_union(left, right, false))
    elseif mode == "subtraction" then
        if left_kind ~= "object"
           or right_kind ~= "object"
           or not compatible
           or not is_complete_object(left_pointee)
           or not is_complete_object(right_pointee) then
            return nil, "pointer subtraction requires compatible complete non-void object types"
        end
        common = types.CPointer(left_pointee,
            qualifier_union(left, right, false))
    elseif mode == "ordering" then
        if left_kind ~= "object"
           or right_kind ~= "object"
           or not compatible then
            return nil, "pointer ordering requires qualification-compatible object types"
        end
        common = types.CPointer(left_pointee,
            qualifier_union(left, right, false))
    elseif mode == "equality" then
        if compatible then
            common = types.CPointer(left_pointee,
                qualifier_union(left, right, false))
        elseif (left_kind == "void" and right_kind == "object")
            or (left_kind == "object" and right_kind == "void") then
            common = types.CPointer(types.CVoid(),
                qualifier_union(left, right, true))
        elseif left_kind == "object" and right_kind == "object" then
            common = types.CPointer(types.CVoid(),
                qualifier_union(left, right, true))
        else
            return nil, "pointer equality requires object pointers or matching function pointers"
        end
    else
        return nil, "unknown pointer common-type mode '" .. tostring(mode) .. "'"
    end

    return {
        lhs = common,
        rhs = common,
        common = common,
        result = mode == "subtraction" and types.Integer()
            or types.Boolean(),
        lhs_decay = left_decay,
        rhs_decay = right_decay,
    }
end

function csemantics.pointer_common_type(lhs, rhs, mode)
    return pointer_decision(lhs, rhs, mode)
end

function csemantics.pointer_equality_common_type(lhs, rhs)
    return pointer_decision(lhs, rhs, "equality")
end

-- C operator selection is deliberately a pure decision layer.  It does not
-- inspect ASTs, run the compiler, or mutate its operands; the checker can
-- therefore distinguish a language-level rejection from a later probe
-- infrastructure failure.  The returned trait is also complete enough that
-- code generation never has to recompute a promotion or pointer relation.

local unary_c_operators = {
    ["-"] = true,
    ["~"] = true,
}

local binary_c_operators = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["<"] = true,
    ["<="] = true,
    [">"] = true,
    [">="] = true,
    ["=="] = true,
    ["~="] = true,
    ["&"] = true,
    ["|"] = true,
    ["~"] = true,
    ["<<"] = true,
    [">>"] = true,
}

local function is_direct_c_operator_type(typ)
    local resolved = types.resolve_c_typedef(typ)
    if not resolved then return false end
    local tag = resolved._tag
    -- COwned is a Titan userdata wrapper.  It only becomes a C operand after
    -- an explicit adjustment to its payload pointer.
    return tag ~= "Type.COwned"
       and tag ~= "Type.CModule"
       and type(tag) == "string"
       and tag:match("^Type%.C") ~= nil
end

function csemantics.is_unary_operator_candidate(op, operand)
    return unary_c_operators[op] == true
       and is_direct_c_operator_type(operand)
end

function csemantics.is_binary_operator_candidate(op, lhs, rhs)
    return binary_c_operators[op] == true
       and (is_direct_c_operator_type(lhs)
            or is_direct_c_operator_type(rhs))
end

local function operator_name(kind, op)
    return "C " .. kind .. " operator '" .. tostring(op) .. "'"
end

local function operand_source_type(original, classified)
    local tag = original and original._tag
    if tag == "Type.Integer" or tag == "Type.Float" then
        -- Probes must use the configured target representation, never the Lua
        -- process that happens to run the compiler.
        return classified.type
    elseif tag == "Type.Nil" then
        -- nil is emitted as a target-typed null pointer constant and therefore
        -- has no standalone C declaration.
        return nil
    end
    return original
end

local function base_trait(kind, op, lhs, rhs, left, right,
                          lhs_decay, rhs_decay)
    return {
        kind = kind,
        cop = op == "~=" and "!="
            or (kind == "binary" and op == "~" and "^" or op),
        lhs_source = lhs and operand_source_type(lhs, left) or nil,
        rhs_source = rhs and operand_source_type(rhs, right) or nil,
        lhs_decay = lhs_decay == true,
        rhs_decay = rhs_decay == true,
        lhs_null = left and left.kind == "nil" or false,
        rhs_null = right and right.kind == "nil" or false,
    }
end

local function reject_operator(kind, op, detail)
    return nil, operator_name(kind, op) .. " " .. detail, true
end

local function operator_shape(typ)
    local value = csemantics.decay_array(typ)
    local resolved = types.resolve_c_typedef(value)
    local tag = resolved and resolved._tag
    if tag == "Type.Integer" or tag == "Type.CInteger" then
        return {kind = "integer"}
    elseif tag == "Type.Float" or tag == "Type.CFloat" then
        return {kind = "float"}
    elseif tag == "Type.CPointer" then
        return {kind = "pointer"}
    elseif tag == "Type.Nil" then
        return {kind = "nil"}
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        return {kind = "object"}
    elseif tag == "Type.CVoid" then
        return {kind = "void"}
    elseif tag == "Type.CFunction" then
        return {kind = "function"}
    end
    return {kind = "unsupported"}
end

function csemantics.decide_unary_operator(profile, op, operand)
    if not csemantics.is_unary_operator_candidate(op, operand) then
        return nil, nil, false
    end

    local shape = operator_shape(operand)
    if op == "-" and shape.kind ~= "integer"
       and shape.kind ~= "float" then
        return reject_operator("unary", op,
            "requires a C integer or C floating operand, not '"
            .. types.tostring(operand) .. "'")
    elseif op == "~" and shape.kind ~= "integer" then
        return reject_operator("unary", op,
            "requires a C integer operand, not '"
            .. types.tostring(operand) .. "'")
    end

    local decayed, did_decay = csemantics.decay_array(operand)
    local info, err = csemantics.classify(profile, decayed)
    if not info then
        return reject_operator("unary", op,
            "cannot classify operand type '" .. types.tostring(operand)
            .. "': " .. tostring(err))
    end

    local target
    if op == "-" then
        if info.kind == "integer" then
            target, err =
                csemantics.integer_promotion(profile, info.type)
        elseif info.kind == "float" then
            target = info.type
        else
            return reject_operator("unary", op,
                "requires a C integer or C floating operand, not '"
                .. types.tostring(operand) .. "'")
        end
    elseif op == "~" then
        if info.kind ~= "integer" then
            return reject_operator("unary", op,
                "requires a C integer operand, not '"
                .. types.tostring(operand) .. "'")
        end
        target, err = csemantics.integer_promotion(profile, info.type)
    end
    if not target then
        return reject_operator("unary", op,
            "cannot determine its promoted operand type: " .. tostring(err))
    end

    local trait = base_trait(
        "unary", op, operand, nil, info, nil, did_decay, false)
    trait.lhs_target = target
    trait.result = target
    return trait, nil, true
end

local function arithmetic_pair(left, right)
    return (left.kind == "integer" or left.kind == "float")
       and (right.kind == "integer" or right.kind == "float")
end

local function integer_pair(left, right)
    return left.kind == "integer" and right.kind == "integer"
end

local function pointer_arithmetic_shape(pointer_like)
    local pointer = csemantics.decay_array(pointer_like)
    if not pointer or pointer._tag ~= "Type.CPointer" then
        return nil, "pointer arithmetic requires a C pointer or array"
    end
    if not is_complete_object(
            types.resolve_c_typedef(pointer.pointee)) then
        return nil,
            "pointer arithmetic requires a complete non-void object type"
    end
    return true
end

local function binary_shape_error(op, lhs, rhs, left, right)
    if op == "+" then
        if arithmetic_pair(left, right) then return nil end
        if left.kind == "pointer" and right.kind == "integer" then
            local _, err = pointer_arithmetic_shape(lhs)
            return err
        elseif left.kind == "integer" and right.kind == "pointer" then
            local _, err = pointer_arithmetic_shape(rhs)
            return err
        end
        return "requires an arithmetic pair or a complete object "
            .. "pointer/array and an integer"
    elseif op == "-" then
        if arithmetic_pair(left, right) then return nil end
        if left.kind == "pointer" and right.kind == "integer" then
            local _, err = pointer_arithmetic_shape(lhs)
            return err
        elseif left.kind == "pointer" and right.kind == "pointer" then
            local _, err = csemantics.pointer_common_type(
                lhs, rhs, "subtraction")
            return err
        end
        return "requires an arithmetic pair, a complete object "
            .. "pointer/array minus an integer, or compatible complete "
            .. "object pointers"
    elseif op == "*" or op == "/" then
        if arithmetic_pair(left, right) then return nil end
        return "requires arithmetic operands"
    elseif op == "%" then
        if integer_pair(left, right) then return nil end
        return "requires C integer operands; floating remainder is not "
            .. "part of C operator mode"
    elseif op == "&" or op == "|" or op == "~"
        or op == "<<" or op == ">>" then
        if integer_pair(left, right) then return nil end
        return "requires C integer operands"
    elseif op == "<" or op == "<=" or op == ">"
        or op == ">=" then
        if arithmetic_pair(left, right) then return nil end
        if left.kind == "pointer" and right.kind == "pointer" then
            local _, err =
                csemantics.pointer_common_type(lhs, rhs, "ordering")
            return err
        end
        return "requires arithmetic operands or "
            .. "qualification-compatible object pointers"
    elseif op == "==" or op == "~=" then
        if arithmetic_pair(left, right) then return nil end
        if (left.kind == "pointer" or left.kind == "nil")
           and (right.kind == "pointer" or right.kind == "nil") then
            local _, err =
                csemantics.pointer_common_type(lhs, rhs, "equality")
            return err
        end
        return "requires arithmetic operands, object pointers, "
            .. "a pointer and nil, or matching function pointers"
    end
end

local function finish_common_arithmetic(
        profile, trait, lhs, rhs, result)
    local common, err =
        csemantics.usual_arithmetic_conversion(profile, lhs, rhs)
    if not common then return nil, err end
    trait.lhs_target = common
    trait.rhs_target = common
    trait.result = result or common
    return trait
end

local function pointer_arithmetic_trait(
        profile, trait, pointer_type, integer_type, pointer_side)
    local decision, err =
        csemantics.pointer_arithmetic(profile, pointer_type, integer_type)
    if not decision then return nil, err end
    if pointer_side == "lhs" then
        trait.lhs_target = decision.pointer
        trait.rhs_target = decision.offset
    else
        trait.lhs_target = decision.offset
        trait.rhs_target = decision.pointer
    end
    trait.result = decision.result
    return trait
end

local function pointer_pair_trait(profile, trait, decision)
    trait.lhs_target = decision.lhs
    trait.rhs_target = decision.rhs
    trait.result = decision.result
    if decision.result._tag == "Type.Integer" then
        local entry, err = profile_integer(profile, profile.ptrdiff_t)
        if not entry then return nil, err end
        trait.result_source = entry.type
    end
    return trait
end

function csemantics.decide_binary_operator(profile, op, lhs, rhs)
    if not csemantics.is_binary_operator_candidate(op, lhs, rhs) then
        return nil, nil, false
    end

    local left_shape = operator_shape(lhs)
    local right_shape = operator_shape(rhs)
    local shape_error =
        binary_shape_error(op, lhs, rhs, left_shape, right_shape)
    if shape_error then
        return reject_operator("binary", op,
            shape_error .. " (found '" .. types.tostring(lhs)
            .. "' and '" .. types.tostring(rhs) .. "')")
    end

    local lhs_value, lhs_decay = csemantics.decay_array(lhs)
    local rhs_value, rhs_decay = csemantics.decay_array(rhs)
    local left, left_err = csemantics.classify(profile, lhs_value)
    local right, right_err = csemantics.classify(profile, rhs_value)
    if not left then
        return reject_operator("binary", op,
            "cannot classify left operand type '" .. types.tostring(lhs)
            .. "': " .. tostring(left_err))
    elseif not right then
        return reject_operator("binary", op,
            "cannot classify right operand type '" .. types.tostring(rhs)
            .. "': " .. tostring(right_err))
    end

    local trait = base_trait(
        "binary", op, lhs, rhs, left, right, lhs_decay, rhs_decay)
    local decision, err

    if op == "+" then
        if arithmetic_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value)
        elseif left.kind == "pointer" and right.kind == "integer" then
            decision, err = pointer_arithmetic_trait(
                profile, trait, lhs, rhs_value, "lhs")
        elseif left.kind == "integer" and right.kind == "pointer" then
            decision, err = pointer_arithmetic_trait(
                profile, trait, rhs, lhs_value, "rhs")
        else
            err = "requires an arithmetic pair or a complete object "
                .. "pointer/array and an integer"
        end
    elseif op == "-" then
        if arithmetic_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value)
        elseif left.kind == "pointer" and right.kind == "integer" then
            decision, err = pointer_arithmetic_trait(
                profile, trait, lhs, rhs_value, "lhs")
        elseif left.kind == "pointer" and right.kind == "pointer" then
            local pointer_decision
            pointer_decision, err =
                csemantics.pointer_common_type(
                    lhs, rhs, "subtraction")
            if pointer_decision then
                decision, err =
                    pointer_pair_trait(profile, trait, pointer_decision)
            end
        else
            err = "requires an arithmetic pair, a complete object "
                .. "pointer/array minus an integer, or compatible complete "
                .. "object pointers"
        end
    elseif op == "*" or op == "/" then
        if arithmetic_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value)
        else
            err = "requires arithmetic operands"
        end
    elseif op == "%" then
        if integer_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value)
        else
            err = "requires C integer operands; floating remainder is not "
                .. "part of C operator mode"
        end
    elseif op == "&" or op == "|" or op == "~" then
        if integer_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value)
        else
            err = "requires C integer operands"
        end
    elseif op == "<<" or op == ">>" then
        if integer_pair(left, right) then
            local ltarget, lerr =
                csemantics.integer_promotion(profile, lhs_value)
            local rtarget, rerr =
                csemantics.integer_promotion(profile, rhs_value)
            if not ltarget then
                err = lerr
            elseif not rtarget then
                err = rerr
            else
                trait.lhs_target = ltarget
                trait.rhs_target = rtarget
                trait.result = ltarget
                decision = trait
            end
        else
            err = "requires C integer operands"
        end
    elseif op == "<" or op == "<=" or op == ">"
        or op == ">=" then
        if arithmetic_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value, types.Boolean())
        elseif left.kind == "pointer" and right.kind == "pointer" then
            local pointer_decision
            pointer_decision, err =
                csemantics.pointer_common_type(lhs, rhs, "ordering")
            if pointer_decision then
                decision, err =
                    pointer_pair_trait(profile, trait, pointer_decision)
            end
        else
            err = "requires arithmetic operands or "
                .. "qualification-compatible object pointers"
        end
    elseif op == "==" or op == "~=" then
        if arithmetic_pair(left, right) then
            decision, err = finish_common_arithmetic(
                profile, trait, lhs_value, rhs_value, types.Boolean())
        elseif (left.kind == "pointer" or left.kind == "nil")
           and (right.kind == "pointer" or right.kind == "nil") then
            local pointer_decision
            pointer_decision, err =
                csemantics.pointer_common_type(lhs, rhs, "equality")
            if pointer_decision then
                decision, err =
                    pointer_pair_trait(profile, trait, pointer_decision)
            end
        else
            err = "requires arithmetic operands, object pointers, "
                .. "a pointer and nil, or matching function pointers"
        end
    end

    if not decision then
        return reject_operator("binary", op,
            tostring(err or "does not accept these operand types")
            .. " (found '" .. types.tostring(lhs) .. "' and '"
            .. types.tostring(rhs) .. "')")
    end
    return decision, nil, true
end

return csemantics
