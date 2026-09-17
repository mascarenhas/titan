local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session

local function run_checker(code)
    return h.run_checker(code, probe_session)
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

local function with_two_headers(first_contents, second_contents, fn)
    local first = os.tmpname() .. ".h"
    local second = os.tmpname() .. ".h"
    local first_file = assert(io.open(first, "w"))
    assert(first_file:write(first_contents))
    assert(first_file:close())
    local second_file = assert(io.open(second, "w"))
    assert(second_file:write(second_contents))
    assert(second_file:close())

    local results = { pcall(fn, first, second) }
    os.remove(first)
    os.remove(second)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local declarations = [[
    typedef unsigned char ffi_uchar;
    typedef unsigned int ffi_uint;
    typedef unsigned long ffi_ulong;
    typedef float ffi_float;
    typedef double ffi_double;
    typedef void ffi_void;

    typedef struct ffi_item { int value; } ffi_item;
    typedef struct ffi_other { int value; } ffi_other;
    typedef struct ffi_bits {
        unsigned int bits : 3;
    } ffi_bits;
    typedef struct ffi_opaque ffi_opaque;
    typedef int (*ffi_callback)(int value);
    typedef volatile ffi_other *ffi_volatile_other_pointer;

    extern int ffi_array[4];
    extern ffi_bits ffi_flags;
]]

local function collect_operators(node, out, seen)
    out = out or {}
    seen = seen or {}
    if type(node) ~= "table" or seen[node] then return out end
    seen[node] = true
    if node._c_operator then table.insert(out, node) end
    for _, child in pairs(node) do
        collect_operators(child, out, seen)
    end
    return out
end

local function resolved_tag(typ)
    return types.resolve_c_typedef(typ)._tag
end

describe("C FFI operator type checking", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("keeps an unsigned macro at unsigned rank without pre-narrowing",
    function()
        with_header([[
            #define FFI_UNSIGNED_MAX 0xffffffffU
        ]], function(header)
            local ok, err, ast = run_checker([[
            foreign import "]] .. header .. [["

            local function exceeds_buffer_limit(length: integer): boolean
                return length > ffi.FFI_UNSIGNED_MAX
            end
            ]])
            assert.truthy(ok, err)
            local operators = collect_operators(ast)
            assert.equal(1, #operators)
            local node = operators[1]
            assert.equal("unsigned int",
                types.resolve_c_typedef(node.rhs._type).spelling)
            assert.equal("long long", node._c_operator.lhs_target.spelling)
            assert.equal("long long", node._c_operator.rhs_target.spelling)
            assert.equal("Type.Boolean", node._type._tag)
        end)
    end)

    it("covers the accepted matrix with complete frozen traits", function()
        with_header(declarations, function(header)
            local ok, err, ast = run_checker([[
                foreign import "]] .. header .. [["

                local function matrix(
                    small: foreign ffi_uchar,
                    wide: foreign ffi_ulong,
                    number: foreign ffi_float,
                    other_number: foreign ffi_double,
                    offset: integer,
                    pointer: foreign *ffi_item,
                    second: foreign const *ffi_item,
                    unrelated: foreign ffi_volatile_other_pointer,
                    callback: foreign ffi_callback,
                    other_callback: foreign ffi_callback
                )
                    local unary_minus = -small
                    local unary_bits = ~small
                    local add = small + offset
                    local subtract = wide - small
                    local multiply = small * wide
                    local divide = wide / small
                    local remainder = wide % small
                    local float_add = number + other_number
                    local less = small < wide
                    local less_equal = number <= other_number
                    local greater = offset > small
                    local greater_equal = wide >= small
                    local equal = small == wide
                    local unequal = small ~= wide
                    local bit_and = small & wide
                    local bit_or = small | wide
                    local bit_xor = small ~ wide
                    local shift_left = small << wide
                    local shift_right = wide >> small
                    local pointer_add = pointer + offset
                    local commuted_add = offset + pointer
                    local pointer_subtract = pointer - offset
                    local pointer_difference = pointer - second
                    local pointer_order = pointer < second
                    local pointer_nil = pointer == nil
                    local nil_pointer = nil ~= pointer
                    local unrelated_equal = pointer == unrelated
                    local function_equal = callback == other_callback
                    local array_decay = ffi.ffi_array + offset
                end
            ]])
            assert.truthy(ok, err)

            local operators = collect_operators(ast)
            assert.equal(29, #operators)
            for _, node in ipairs(operators) do
                local trait = node._c_operator
                assert.is_string(trait.probe_key)
                assert.is_truthy(trait.lhs_target)
                if trait.kind == "binary" then
                    assert.is_truthy(trait.rhs_target)
                end
                assert.equal(node._type, trait.result)

                local comparison = node.op == "<" or node.op == "<="
                    or node.op == ">" or node.op == ">="
                    or node.op == "==" or node.op == "~="
                local lhs_target =
                    types.resolve_c_typedef(trait.lhs_target)
                local rhs_target = trait.rhs_target
                    and types.resolve_c_typedef(trait.rhs_target)
                if comparison then
                    assert.equal("Type.Boolean", trait.result._tag)
                elseif trait.kind == "unary"
                    or node.op == "<<" or node.op == ">>" then
                    assert.equal(trait.lhs_target, trait.result)
                elseif node.op == "-"
                   and lhs_target._tag == "Type.CPointer"
                   and rhs_target._tag == "Type.CPointer" then
                    assert.equal("Type.Integer", trait.result._tag)
                elseif lhs_target._tag == "Type.CPointer" then
                    assert.equal(trait.lhs_target, trait.result)
                elseif rhs_target
                   and rhs_target._tag == "Type.CPointer" then
                    assert.equal(trait.rhs_target, trait.result)
                else
                    assert.equal(trait.lhs_target, trait.result)
                    assert.equal(trait.rhs_target, trait.result)
                    assert.is_true(trait.result._tag == "Type.CInteger"
                        or trait.result._tag == "Type.CFloat")
                end
            end

            local saw = {}
            for _, node in ipairs(operators) do
                local trait = node._c_operator
                if node.op == "~=" then
                    assert.equal("!=", trait.cop)
                    saw.not_equal = true
                elseif node.op == "~" and trait.kind == "binary" then
                    assert.equal("^", trait.cop)
                    saw.xor = true
                end

                if node.op == "+"
                   and resolved_tag(node.lhs._type) == "Type.CInteger"
                   and node.rhs._type._tag == "Type.Integer" then
                    -- unsigned char is promoted first and then combined with
                    -- the configured lua_Integer; it is never narrowed back
                    -- to unsigned char.
                    assert.equal("long long",
                        trait.lhs_target.spelling)
                    assert.equal("long long",
                        trait.rhs_target.spelling)
                    saw.mixed = true
                end
                if node.op == "<<"
                   and types.resolve_c_typedef(
                       node.lhs._type).spelling == "unsigned char" then
                    assert.equal("int", trait.lhs_target.spelling)
                    assert.equal("unsigned long",
                        trait.rhs_target.spelling)
                    assert.equal(trait.lhs_target, trait.result)
                    saw.shift = true
                end
                if node.op == "-"
                   and resolved_tag(trait.lhs_target) == "Type.CPointer"
                   and resolved_tag(trait.rhs_target) == "Type.CPointer" then
                    assert.equal("Type.Integer", trait.result._tag)
                    assert.equal("Type.CInteger",
                        trait.result_source._tag)
                    assert.is_true(trait.result_source.signed)
                    assert.equal(
                        trait.result_source._c_numeric_carriers
                            .ptrdiff_t.spelling,
                        trait.result_source.spelling)
                    saw.pointer_difference = true
                end
                if node.op == "=="
                   and node.rhs._type._tag == "Type.Nil" then
                    assert.is_true(trait.rhs_null)
                    assert.equal(trait.lhs_target, trait.rhs_target)
                    saw.null = true
                end
                if node.op == "=="
                   and resolved_tag(trait.lhs_target) == "Type.CPointer"
                   and types.resolve_c_typedef(
                       trait.lhs_target.pointee)._tag == "Type.CVoid" then
                    assert.same({"volatile"}, trait.lhs_target.quals)
                    assert.same(trait.lhs_target, trait.rhs_target)
                    saw.unrelated = true
                end
                if trait.lhs_decay then
                    assert.equal("Type.CArray",
                        types.resolve_c_typedef(node.lhs._type)._tag)
                    assert.equal("Type.CPointer",
                        resolved_tag(trait.lhs_target))
                    saw.array_decay = true
                end
            end
            assert.same({
                array_decay = true,
                mixed = true,
                not_equal = true,
                null = true,
                pointer_difference = true,
                shift = true,
                unrelated = true,
                xor = true,
            }, saw)
        end)
    end)

    it("rejects every unsupported C operand combination before Titan paths",
    function()
        with_header(declarations, function(header)
            local cases = {
                {
                    body = "local result = number % wide",
                    params = "number: foreign ffi_float, wide: foreign ffi_ulong",
                    detail = "floating remainder",
                },
                {
                    body = "local result = pointer * offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires arithmetic operands",
                },
                {
                    body = "local result = pointer / offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires arithmetic operands",
                },
                {
                    body = "local result = pointer % offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer & offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer | offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer ~ offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer << offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer >> offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "requires C integer operands",
                },
                {
                    body = "local result = pointer == offset",
                    params = "pointer: foreign *ffi_item, offset: integer",
                    detail = "pointer and nil",
                },
                {
                    body = "local result = pointer + offset",
                    params = "pointer: foreign *ffi_opaque, offset: integer",
                    detail = "incomplete or not yet visible",
                },
                {
                    body = "local result = pointer + offset",
                    params = "pointer: foreign *ffi_void, offset: integer",
                    detail = "complete non%-void object",
                },
                {
                    body = "local result = callback < callback",
                    params = "callback: foreign ffi_callback",
                    detail = "function pointers",
                },
                {
                    body = "local result = left == right",
                    params = "left: foreign ffi_item, right: foreign ffi_item",
                    detail = "object pointers",
                },
                {
                    body = "local result = left + right",
                    params = "left: foreign ffi_item, right: foreign ffi_item",
                    detail = "arithmetic pair",
                },
            }

            for _, case in ipairs(cases) do
                local ok, err = run_checker([[
                    foreign import "]] .. header .. [["
                    local function rejected(]] .. case.params .. [[)
                        ]] .. case.body .. [[
                    end
                ]])
                assert.falsy(ok)
                assert.truthy(err:match("C operator")
                    or err:match("C binary operator"))
                assert.match(case.detail, err)
            end
        end)
    end)

    it("requires a cast before operating on a C bit-field", function()
        with_header(declarations, function(header)
            local ok, err = run_checker([[
                foreign import "]] .. header .. [["
                local function rejected()
                    local result = ffi.ffi_flags.bits + 1
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot be applied directly to bit%-field", err)
            assert.match("cast the bit%-field", err)

            local ast
            ok, err, ast = run_checker([[
                foreign import "]] .. header .. [["
                local function accepted()
                    local c_value =
                        (ffi.ffi_flags.bits as foreign ffi_uint) + 1
                    local titan_value =
                        (ffi.ffi_flags.bits as integer) + 1
                end
            ]])
            assert.truthy(ok, err)
            local operators = collect_operators(ast)
            assert.equal(1, #operators)
            assert.equal("Type.CInteger",
                operators[1]._c_operator.result._tag)
        end)
    end)

    it("leaves explicitly excluded syntax on the Titan paths", function()
        with_header(declarations, function(header)
            local ok, err, ast = run_checker([[
                foreign import "]] .. header .. [["
                local function accepted(
                    pointer: foreign *ffi_item,
                    wide: foreign ffi_ulong,
                    exponent: float
                )
                    local truth = not pointer
                    local length = #ffi.ffi_array
                    local floor = (wide as integer) // 2
                    local power = exponent ^ 2.0
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(0, #collect_operators(ast))
        end)
    end)

    it("uses complete module C types in pointer initializers",
    function()
        with_two_headers([[
            typedef struct ffi_late_item ffi_late_item;
            extern ffi_late_item *ffi_late_pointer;
        ]], [[
            struct ffi_late_item {
                int value;
            };
        ]], function(forward_header, definition_header)
            for _, expression in ipairs({
                "ffi.ffi_late_pointer + 1",
                "ffi.ffi_late_pointer - ffi.ffi_late_pointer",
            }) do
                local ok, err = run_checker([[
                    foreign import "]]
                        .. forward_header .. [["
                    local early = ]] .. expression .. [[
                    foreign import "]]
                        .. definition_header .. [["
                ]])
                assert.falsy(ok)
                assert.match("initialization must be constant", err)
                assert.falsy(err:find("incomplete", 1, true))
            end

            local ok, err = run_checker([[
                foreign import "]]
                    .. forward_header .. [["
                foreign import "]]
                    .. definition_header .. [["

                local function body_after_imports(): integer
                    local later = ffi.ffi_late_pointer + 1
                    local ignored = later
                    return ffi.ffi_late_pointer -
                        ffi.ffi_late_pointer
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)
end)
