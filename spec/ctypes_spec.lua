local cdriver = require "c-parser.cdriver"

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

local function parse_header(contents)
    return with_header(contents, function(header)
        local ftypes, err = cdriver.process_file(header)
        assert(ftypes, err)
        return ftypes
    end)
end

describe("C FFI ctype registration", function()
    it("registers standalone structs and preserves field declarators", function()
        local ftypes = parse_header([[
            struct P {
                int x;
                int *p;
                int arr[3];
            };
        ]])

        local point = assert(ftypes["struct@P"])
        assert.equal("struct", point.type)
        assert.equal("P", point.name)

        assert.same({ "int" }, point.fields[1].type)
        assert.equal("x", point.fields[1].name)

        assert.same({ "int", "*" }, point.fields[2].type)
        assert.equal("p", point.fields[2].name)

        assert.same({ "int" }, point.fields[3].type)
        assert.equal("arr", point.fields[3].name)
        assert.same({ 3 }, point.fields[3].idxs)
    end)

    it("preserves bitfield widths and anonymous bitfields", function()
        local ftypes = parse_header([[
            struct Flags {
                unsigned flags:3;
                unsigned :5;
            };
        ]])

        local flags = assert(ftypes["struct@Flags"])
        assert.equal("flags", flags.fields[1].name)
        assert.is_true(flags.fields[1].bitfield)
        assert.equal(3, flags.fields[1].width)

        assert.is_nil(flags.fields[2].name)
        assert.is_true(flags.fields[2].anonymous)
        assert.is_true(flags.fields[2].bitfield)
        assert.equal(5, flags.fields[2].width)
    end)

    it("marks flexible array members explicitly", function()
        local ftypes = parse_header([[
            struct Packet {
                int len;
                char data[];
            };
        ]])

        local packet = assert(ftypes["struct@Packet"])
        assert.equal("data", packet.fields[2].name)
        assert.same({ "" }, packet.fields[2].idxs)
        assert.is_true(packet.fields[2].flexible_array)
    end)

    it("preserves typedef and extern array dimensions", function()
        local ftypes = parse_header([[
            typedef int ffi_int_array[4];
            extern int ffi_values[2];
        ]])

        assert.same({ 4 }, ftypes.ffi_int_array.idxs)
        assert.same({ "int" }, ftypes.ffi_int_array.def)

        assert.same({ 2 }, ftypes.ffi_values.idxs)
        assert.same({ "int" }, ftypes.ffi_values.type)
    end)

    it("parses TValue typedefs, functions, and arrays for the Titan FFI layer", function()
        local ftypes = parse_header([[
            typedef struct TValue TValue;
            extern TValue ffi_value_echo(TValue value);
            extern TValue ffi_value_array[2];
        ]])

        assert.equal("typedef", ftypes.TValue.type)
        assert.same({ "TValue" }, ftypes.ffi_value_echo.ret.type)
        assert.same({ "TValue" }, ftypes.ffi_value_echo.params[1].type)
        assert.same({ "TValue" }, ftypes.ffi_value_array.type)
        assert.same({ 2 }, ftypes.ffi_value_array.idxs)
    end)

    it("models function pointer typedefs as function pointer C types", function()
        local ftypes = parse_header([[
            typedef int (*ffi_callback)(int);
        ]])

        local callback = assert(ftypes.ffi_callback)
        assert.equal("typedef", callback.type)
        assert.equal("functionptr", callback.def.type)
        assert.same({ "*" }, callback.def.pointer)
        assert.same({ "int" }, callback.def.ret.type)
        assert.same({ "int" }, callback.def.params[1].type)
    end)

    it("imports static function definitions from headers", function()
        local ftypes = parse_header([[
            static int ffi_static(int x) { return x + 1; }
        ]])

        local fn = assert(ftypes.ffi_static)
        assert.equal("function", fn.type)
        assert.same({ "int" }, fn.ret.type)
        assert.same({ "int" }, fn.params[1].type)
    end)

    it("preserves simple enum constant values", function()
        local ftypes = parse_header([[
            enum ffi_choice {
                FFI_A,
                FFI_B = 4,
                FFI_C,
                FFI_D = FFI_B + 3
            };
        ]])

        local choice = assert(ftypes["enum@ffi_choice"])
        assert.equal(0, choice.values[1].value)
        assert.equal(4, choice.values[2].value)
        assert.equal(5, choice.values[3].value)
        assert.equal(7, choice.values[4].value)
    end)
end)
