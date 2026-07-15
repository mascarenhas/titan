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

    it("models parenthesized function names as functions, not function pointers", function()
        local ftypes = parse_header([[
            extern int (ffi_parenthesized)(int);
            extern void *(ffi_parenthesized_ptr)(int);
            extern int (*ffi_pointer)(int);
            extern void *(*ffi_pointer_retptr)(int);
            typedef struct ffi_holder {
                void (*cb)(int);
                void *(*retptr)(int);
            } ffi_holder;
            typedef int (ffi_function_type)(int);
        ]])

        assert.equal("function", ftypes.ffi_parenthesized.type)
        assert.same({ "int" }, ftypes.ffi_parenthesized.ret.type)
        assert.same({ "int" }, ftypes.ffi_parenthesized.params[1].type)

        assert.equal("function", ftypes.ffi_parenthesized_ptr.type)
        assert.same({ "void", "*" }, ftypes.ffi_parenthesized_ptr.ret.type)

        assert.equal("functionptr", ftypes.ffi_pointer.type)
        assert.same({ "*" }, ftypes.ffi_pointer.pointer)
        assert.same({ "int" }, ftypes.ffi_pointer.ret.type)

        assert.equal("functionptr", ftypes.ffi_pointer_retptr.type)
        assert.same({ "*" }, ftypes.ffi_pointer_retptr.pointer)
        assert.same({ "void", "*" }, ftypes.ffi_pointer_retptr.ret.type)

        local holder = ftypes.ffi_holder.def[1]
        assert.equal("functionptr", holder.fields[1].type)
        assert.same({ "*" }, holder.fields[1].pointer)
        assert.equal("functionptr", holder.fields[2].type)
        assert.same({ "void", "*" }, holder.fields[2].ret.type)
        assert.is_nil(ftypes.ffi_function_type)
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

    it("preserves complete parameter names across declaration forms", function()
        local ftypes = parse_header([[
            extern int ffi_named(int count, const char *path);
            extern int (ffi_parenthesized_named)(int value);
            static inline int ffi_static_named(int input) { return input; }
            extern int ffi_keyword(int repeat);
            extern int ffi_variadic(const char *format, ...);
        ]])

        assert.same({ "count", "path" }, ftypes.ffi_named.paramnames)
        assert.equal("complete", ftypes.ffi_named.paramnames_state)
        assert.same({ "value" },
            ftypes.ffi_parenthesized_named.paramnames)
        assert.same({ "input" }, ftypes.ffi_static_named.paramnames)
        assert.same({ "repeat" }, ftypes.ffi_keyword.paramnames)
        assert.same({ "format" }, ftypes.ffi_variadic.paramnames)
        assert.is_true(ftypes.ffi_variadic.vararg)
    end)

    it("distinguishes old-style and true zero-parameter prototypes", function()
        local ftypes = parse_header([[
            extern int ffi_oldstyle();
            extern int ffi_zero(void);
        ]])

        assert.is_false(ftypes.ffi_oldstyle.paramnames)
        assert.equal("unknown", ftypes.ffi_oldstyle.paramnames_state)
        assert.same({}, ftypes.ffi_zero.paramnames)
        assert.equal("complete", ftypes.ffi_zero.paramnames_state)
    end)

    it("marks incomplete and ambiguous parameter lists unavailable", function()
        local ftypes = parse_header([[
            extern int ffi_unnamed(int, const char *);
            extern int ffi_partial(int count, const char *);
            extern int ffi_duplicate(int item, int item);
        ]])

        assert.is_false(ftypes.ffi_unnamed.paramnames)
        assert.is_false(ftypes.ffi_partial.paramnames)
        assert.is_false(ftypes.ffi_duplicate.paramnames)
        assert.equal("unknown", ftypes.ffi_unnamed.paramnames_state)
        assert.equal("unknown", ftypes.ffi_partial.paramnames_state)
        assert.equal("unknown", ftypes.ffi_duplicate.paramnames_state)
    end)

    it("preserves names on array and callback declarators", function()
        local ftypes = parse_header([[
            extern int ffi_apply(
                int values[4],
                void (*callback)(int event));
            extern int (*ffi_callback_value)(int event);
            extern int ffi_abstract(int, const char *);
        ]])

        assert.same({ "values", "callback" }, ftypes.ffi_apply.paramnames)
        assert.equal("functionptr", ftypes.ffi_apply.params[2].type)
        assert.same({ "event" },
            ftypes.ffi_apply.params[2].paramnames)
        assert.same({ "event" }, ftypes.ffi_callback_value.paramnames)
        assert.is_false(ftypes.ffi_abstract.paramnames)
    end)

    it("forms consensus without letting incomplete declarations erase names", function()
        local ftypes = parse_header([[
            extern int ffi_consensus(int);
            extern int ffi_consensus(int value);
            extern int ffi_consensus(int);
            extern int ffi_consensus(int value);

            extern int ffi_zero_consensus();
            extern int ffi_zero_consensus(void);
            extern int ffi_zero_consensus();
        ]])

        assert.same({ "value" }, ftypes.ffi_consensus.paramnames)
        assert.equal("complete", ftypes.ffi_consensus.paramnames_state)
        assert.same({}, ftypes.ffi_zero_consensus.paramnames)
        assert.equal("complete", ftypes.ffi_zero_consensus.paramnames_state)
    end)

    it("permanently poisons conflicting complete name lists", function()
        local ftypes = parse_header([[
            extern int ffi_poison_xyx(int x);
            extern int ffi_poison_xyx(int y);
            extern int ffi_poison_xyx(int x);

            extern int ffi_poison_yxx(int y);
            extern int ffi_poison_yxx(int x);
            extern int ffi_poison_yxx(int x);

            extern int ffi_poison_xyy(int x);
            extern int ffi_poison_xyy(int y);
            extern int ffi_poison_xyy(int y);
        ]])

        for _, name in ipairs({
            "ffi_poison_xyx", "ffi_poison_yxx", "ffi_poison_xyy",
        }) do
            assert.is_false(ftypes[name].paramnames)
            assert.equal("conflicting", ftypes[name].paramnames_state)
        end
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

    it("preserves typedef enum constant values", function()
        local ftypes = parse_header([[
            typedef enum ffi_choice {
                FFI_A,
                FFI_B = 4,
                FFI_C
            } ffi_choice;
        ]])

        local choice = assert(ftypes["enum@ffi_choice"])
        assert.equal(0, choice.values[1].value)
        assert.equal(4, choice.values[2].value)
        assert.equal(5, choice.values[3].value)
    end)
end)
