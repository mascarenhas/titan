local cdriver = require "c-parser.cdriver"
local ctypes = require "c-parser.ctypes"

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

local function parse_header_error(contents)
    return with_header(contents, function(header)
        local ftypes, err = cdriver.process_file(header)
        assert.is_nil(ftypes)
        return err, header
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

    it("adjusts function parameters to function pointers", function()
        local ftypes = parse_header([[
            extern int ffi_callback_adjustment(int callback(void));
            extern int ffi_callback_adjustment(
                int (*callback)(void));
        ]])

        local callback =
            ftypes.ffi_callback_adjustment.params[1]
        assert.equal("functionptr", callback.type)
        assert.same({ "*" }, callback.pointer)
        assert.same({}, callback.params)
        assert.same({ "int" }, callback.ret.type)
    end)

    it("imports static function definitions from headers", function()
        local ftypes = parse_header([[
            static int ffi_static(int x) { return x + 1; }
            struct ffi_opaque;
            static struct ffi_opaque *ffi_identity(
                struct ffi_opaque *pointer) { return pointer; }
        ]])

        local fn = assert(ftypes.ffi_static)
        assert.equal("function", fn.type)
        assert.same({ "int" }, fn.ret.type)
        assert.same({ "int" }, fn.params[1].type)

        local identity = assert(ftypes.ffi_identity)
        assert.equal("function", identity.type)
        assert.equal("*", identity.ret.type[2])
        assert.equal("*", identity.params[1].type[2])
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

        assert.equal("oldstyle", ftypes.ffi_oldstyle._paramstyle)
        assert.is_false(ftypes.ffi_oldstyle.paramnames)
        assert.equal("unknown", ftypes.ffi_oldstyle.paramnames_state)
        assert.equal("prototype", ftypes.ffi_zero._paramstyle)
        assert.same({}, ftypes.ffi_zero.paramnames)
        assert.equal("complete", ftypes.ffi_zero.paramnames_state)
    end)

    it("forms an informative prototype composite with old-style declarations",
    function()
        local ftypes = parse_header([[
            extern int ffi_oldstyle_first();
            extern int ffi_oldstyle_first(int value);
            extern int ffi_prototype_first(int value);
            extern int ffi_prototype_first();
        ]])

        assert.equal(0, ctypes.skipped)
        for _, name in ipairs({
            "ffi_oldstyle_first",
            "ffi_prototype_first",
        }) do
            local fn = ftypes[name]
            assert.equal("prototype", fn._paramstyle)
            assert.equal(1, #fn.params)
            assert.same({"int"}, fn.params[1]._declarator_base)
            assert.same({"value"}, fn.paramnames)
            assert.equal("complete", fn.paramnames_state)
        end
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

    it("preserves the exact ordered pointer, array, and function path",
    function()
        local ftypes = parse_header([[
            extern int *ffi_pointer_array[3];
            extern int (*ffi_array_pointer)[3];
            extern int * volatile ffi_volatile_pointer;
            extern int (*ffi_callbacks[2])(int);
            extern int (*ffi_row_factory(void))[3];
            extern int ffi_matrix_a(int values[][3]);
            extern int ffi_matrix_b(int (*values)[3]);
        ]])

        assert.same(
            { "*", { idx = 3 } },
            ftypes.ffi_pointer_array._declarator_ops)
        assert.same(
            { { idx = 3 }, "*" },
            ftypes.ffi_array_pointer._declarator_ops)
        assert.same(
            { "*", "volatile" },
            ftypes.ffi_volatile_pointer._declarator_ops)

        assert.equal("functionptr", ftypes.ffi_callbacks.type)
        assert.same(
            { "*", { idx = 2 } },
            ftypes.ffi_callbacks._declarator_ops)

        assert.equal("function", ftypes.ffi_row_factory.type)
        assert.same(
            { { idx = 3 }, "*" },
            ftypes.ffi_row_factory.ret._declarator_ops)

        assert.same(
            { { idx = 3 }, { idx = "" } },
            ftypes.ffi_matrix_a.params[1]._declarator_ops)
        assert.same(
            { { idx = 3 }, "*" },
            ftypes.ffi_matrix_b.params[1]._declarator_ops)
    end)

    it("models named and unnamed parameter declarators identically", function()
        local ftypes = parse_header([[
            extern int ffi_named_array(int value[7]);
            extern int ffi_unnamed_array(int [7]);
            extern int ffi_named_callback(int (*callback)(double));
            extern int ffi_unnamed_callback(int (*)(double));
            extern int ffi_named_array_pointer(int (*values)[7]);
            extern int ffi_unnamed_array_pointer(int (*)[7]);
        ]])

        local function same_parameter_shape(named, unnamed)
            local left = ftypes[named].params[1]
            local right = ftypes[unnamed].params[1]
            assert.same(left._declarator_ops, right._declarator_ops)
            assert.same(left.type, right.type)
            assert.same(left.ret, right.ret)
            assert.same(left.params, right.params)
        end

        same_parameter_shape("ffi_named_array", "ffi_unnamed_array")
        same_parameter_shape("ffi_named_callback", "ffi_unnamed_callback")
        same_parameter_shape(
            "ffi_named_array_pointer",
            "ffi_unnamed_array_pointer")

        assert.same(
            {{idx = 7}},
            ftypes.ffi_unnamed_array.params[1]._declarator_ops)
        assert.equal(
            "functionptr",
            ftypes.ffi_unnamed_callback.params[1].type)
        assert.same(
            {{idx = 7}, "*"},
            ftypes.ffi_unnamed_array_pointer.params[1]._declarator_ops)
    end)

    it("skips incompatible exact declarator paths in one header", function()
        local ftypes = parse_header([[
            extern int *ffi_shape[3];
            extern int (*ffi_shape)[3];
        ]])

        assert.same(
            { "*", { idx = 3 } },
            ftypes.ffi_shape._declarator_ops)
        assert.is_true(ctypes.skipped >= 1)
    end)

    it("accepts reordered pointer qualifiers and array completion", function()
        for _, declarations in ipairs({
            "extern int ffi_values[];\n"
                .. "extern int ffi_values[4];\n",
            "extern int ffi_values[4];\n"
                .. "extern int ffi_values[];\n",
        }) do
            local ftypes = parse_header([[
                extern int * const volatile ffi_pointer;
                extern int * volatile const ffi_pointer;
            ]] .. declarations)

            assert.same(
                { "*", "volatile", "const" },
                ftypes.ffi_pointer._declarator_ops)
            assert.same(
                { { idx = 4 } },
                ftypes.ffi_values._declarator_ops)
        end
    end)

    it("forms declaration-owned composites through array typedefs",
    function()
        local ftypes = parse_header([[
            typedef int ffi_composite_array[];

            extern ffi_composite_array ffi_alias_first;
            extern int ffi_alias_first[7];
            extern int ffi_direct_first[7];
            extern ffi_composite_array ffi_direct_first;

            extern ffi_composite_array *ffi_nested_alias_first;
            extern int (*ffi_nested_alias_first)[7];
            extern int (*ffi_nested_direct_first)[7];
            extern ffi_composite_array *ffi_nested_direct_first;

            extern void ffi_function_alias_first(
                ffi_composite_array *values);
            extern void ffi_function_alias_first(
                int (*values)[7]);
            extern void ffi_function_direct_first(
                int (*values)[7]);
            extern void ffi_function_direct_first(
                ffi_composite_array *values);

            extern ffi_composite_array ffi_composite_untouched;
        ]])

        assert.equal(0, ctypes.skipped)
        assert.same(
            {{idx = ""}},
            ftypes.ffi_composite_array._declarator_ops)
        assert.same(
            {"ffi_composite_array"},
            ftypes.ffi_composite_untouched._declarator_base)

        for _, name in ipairs({
            "ffi_alias_first",
            "ffi_direct_first",
        }) do
            assert.same({"int"}, ftypes[name]._declarator_base)
            assert.same(
                {{idx = 7}},
                ftypes[name]._declarator_ops)
        end

        for _, name in ipairs({
            "ffi_nested_alias_first",
            "ffi_nested_direct_first",
        }) do
            assert.same({"int"}, ftypes[name]._declarator_base)
            assert.same(
                {{idx = 7}, "*"},
                ftypes[name]._declarator_ops)
        end

        for _, name in ipairs({
            "ffi_function_alias_first",
            "ffi_function_direct_first",
        }) do
            assert.equal("function", ftypes[name].type)
            assert.same(
                {{idx = 7}, "*"},
                ftypes[name].params[1]._declarator_ops)
            assert.equal(
                "values",
                ftypes[name].params[1].name)
        end
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

    it("calculates parenthesized negative enum constant values", function()
        local ftypes = parse_header([[
            typedef enum ffi_error {
                FFI_EIO = (-(5)),
                FFI_EOF = (-4095),
                FFI_ERRNO_MAX = (-4095) - 1
            } ffi_error;
        ]])

        local errors = assert(ftypes["enum@ffi_error"])
        assert.equal(-5, errors.values[1].value)
        assert.equal(-4095, errors.values[2].value)
        assert.equal(-4096, errors.values[3].value)
        assert.equal(-5, ftypes.FFI_EIO.values[1].value)
        assert.equal(-4095, ftypes.FFI_EOF.values[2].value)
    end)

    describe("file-scope C tag metadata", function()
        it("reserves every syntactic typedef and records eligible tags", function()
            local ftypes = parse_header([[
                typedef double _Complex Reserved;
                struct Item;
                union Cell { int integer; double number; };
                enum Choice { CHOICE_A };
            ]])

            assert.is_true(ftypes.typedef_names.Reserved)
            assert.equal("struct", ftypes.file_scope_tags.Item.kind)
            assert.equal("struct@Item",
                ftypes.file_scope_tags.Item.raw_key)
            assert.is_false(ftypes.file_scope_tags.Item.defined)
            assert.equal("union", ftypes.file_scope_tags.Cell.kind)
            assert.is_true(ftypes.file_scope_tags.Cell.defined)
            assert.equal("enum", ftypes.file_scope_tags.Choice.kind)
            assert.is_true(ftypes.file_scope_tags.Choice.defined)
            assert.is_nil(ftypes.file_scope_tags.Reserved)
        end)

        it("retains one canonical raw tag through typedefs and objects", function()
            local ftypes = parse_header([[
                typedef struct Item ItemRef;
                struct Item *item_pointer;
                struct Item { int value; };
            ]])

            local raw = assert(ftypes["struct@Item"])
            assert.equal(raw,
                ftypes.ItemRef.def[1]._canonical_tag)
            assert.equal(raw,
                ftypes.item_pointer.type[1]._canonical_tag)
            assert.equal("value", raw.fields[1].name)
            assert.equal(raw,
                ftypes.file_scope_tags.Item.raw_type)
            assert.is_true(ftypes.typedef_names.ItemRef)
            assert.is_nil(ftypes.typedef_names.Item)
        end)

        it("records file-scope tags introduced by aggregate members", function()
            local ftypes = parse_header([[
                struct Outer {
                    struct Inner *pointer;
                };
                struct Inner {
                    int value;
                };
            ]])

            local outer = assert(ftypes["struct@Outer"])
            local inner = assert(ftypes["struct@Inner"])
            assert.equal("struct", ftypes.file_scope_tags.Inner.kind)
            assert.is_true(ftypes.file_scope_tags.Inner.defined)
            assert.equal(inner,
                outer.fields[1].type[1]._canonical_tag)
            assert.equal("value", inner.fields[1].name)
        end)

        it("binds a prior file tag but keeps a later tag separate", function()
            local ftypes = parse_header([[
                struct Prior;
                extern int prior_use(
                    struct Prior *left,
                    struct Prior *right);
                extern int local_use(
                    struct Later *left,
                    struct Later *right);
                struct Later { int value; };
            ]])

            local prior = assert(ftypes["struct@Prior"])
            assert.equal(prior,
                ftypes.prior_use.params[1].type[1]._canonical_tag)
            assert.equal(prior,
                ftypes.prior_use.params[2].type[1]._canonical_tag)

            local later = assert(ftypes["struct@Later"])
            local local_left = ftypes.local_use.params[1].type[1]
            local local_right = ftypes.local_use.params[2].type[1]
            assert.equal(local_left, local_right)
            assert.not_equal(later, local_left)
            assert.equal(2, local_left._prototype_scope_id)
            assert.is_true(local_left._allow_outer_binding)
            assert.equal("prototype:2",
                local_left._tag_provenance.scope)
        end)

        it("does not promote prototype-only tags into file metadata", function()
            local ftypes = parse_header([[
                extern int consume(
                    union Local *left,
                    union Local *right);
            ]])

            assert.is_nil(ftypes.file_scope_tags.Local)
            assert.is_nil(ftypes["union@Local"])
            local left = ftypes.consume.params[1].type[1]
            assert.equal(left, ftypes.consume.params[2].type[1])
            assert.equal("union", left.type)
            assert.equal("Local", left.name)
        end)

        for _, conflict in ipairs({
            {
                first = "struct Conflict;",
                second = "union Conflict;",
                first_kind = "struct",
                second_kind = "union",
            },
            {
                first = "enum Conflict { CONFLICT_A };",
                second = "struct Conflict;",
                first_kind = "enum",
                second_kind = "struct",
            },
        }) do
            it(("rejects a file-scope %s/%s tag-kind conflict")
                :format(conflict.first_kind, conflict.second_kind),
            function()
                local err, header = parse_header_error(
                    conflict.first .. "\n" .. conflict.second)
                assert.matches("conflicting C tag kinds for 'Conflict'",
                    err, 1, true)
                assert.matches(header, err, 1, true)
                assert.matches(conflict.first_kind .. " declaration",
                    err, 1, true)
                assert.matches(conflict.second_kind .. " declaration",
                    err, 1, true)
            end)
        end

        it("rejects conflicting kinds within one prototype scope", function()
            local err = parse_header_error([[
                extern int bad(
                    struct Conflict *left,
                    union Conflict *right);
            ]])
            assert.matches(
                "conflicting C tag kinds for 'Conflict' in prototype scope",
                err, 1, true)
        end)

        it("rejects a wrong-kind reference to a prior file tag", function()
            local err = parse_header_error([[
                struct Clash;
                extern void bad(union Clash *value);
            ]])
            assert.matches(
                "conflicting C tag kinds for 'Clash' in prototype scope",
                err, 1, true)
            assert.matches("struct conflicts with union", err, 1, true)
        end)

        it("reuses an outer prototype tag in a nested callback", function()
            local ftypes = parse_header([[
                extern void consume(
                    struct Local *value,
                    void (*callback)(struct Local *));
            ]])

            local outer = ftypes.consume.params[1].type[1]
            local nested =
                ftypes.consume.params[2].params[1].type[1]
            assert.equal(outer, nested)
            assert.equal(1, outer._prototype_scope_id)
            assert.equal(1, nested._prototype_scope_id)
            assert.is_nil(ftypes.file_scope_tags.Local)
            assert.is_nil(ftypes["struct@Local"])
        end)

        it("rejects a wrong-kind nested callback reference", function()
            local err = parse_header_error([[
                extern void bad(
                    struct Local *value,
                    void (*callback)(union Local *));
            ]])
            assert.matches(
                "conflicting C tag kinds for 'Local' in prototype scope",
                err, 1, true)
            assert.matches("struct conflicts with union", err, 1, true)
        end)

        it("keeps aggregate-member callback prototype tags isolated",
           function()
            local ftypes = parse_header([[
                struct Outer {
                    void (*one)(struct Local *);
                    void (*two)(union Local *);
                };
            ]])

            local outer = assert(ftypes["struct@Outer"])
            local one = outer.fields[1].params[1].type[1]
            local two = outer.fields[2].params[1].type[1]
            assert.equal("struct", one.type)
            assert.equal("union", two.type)
            assert.not_equal(one._prototype_scope_id,
                two._prototype_scope_id)
            assert.is_nil(ftypes.file_scope_tags.Local)
            assert.is_nil(ftypes["struct@Local"])
            assert.is_nil(ftypes["union@Local"])
        end)
    end)
end)
