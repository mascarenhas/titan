local cdeclarator = require "titan-compiler.cdeclarator"
local types = require "titan-compiler.types"

describe("C declarator rendering", function()
    local function assert_error_matches(pattern, fn)
        local ok, err = pcall(fn)
        assert.is_false(ok)
        assert.matches(pattern, tostring(err))
    end

    local function cint()
        return types.CInteger("int", true, 3, 32)
    end

    local function cchar()
        return types.CInteger("char", true, 1, 8)
    end

    describe("objects and typedefs", function()
        it("renders primitive declarations and type names", function()
            assert.equal("void", cdeclarator.render_type_name(types.CVoid()))
            assert.equal("double value", cdeclarator.render_declaration(
                types.CFloat("double"), "value"))
            assert.equal("unsigned int", cdeclarator.render_type_name(
                types.CInteger("unsigned int", false, 3, 32)))
        end)

        it("preserves typedef spelling instead of expanding its target", function()
            local word = types.CTypedef("ffi_word", cint())
            local words = types.CTypedef(
                "ffi_words", types.CArray(word, 4))

            assert.equal("ffi_word value",
                cdeclarator.render_declaration(word, "value"))
            assert.equal("ffi_word *pointer", cdeclarator.render_declaration(
                types.CPointer(word, {}), "pointer"))
            assert.equal("ffi_words values",
                cdeclarator.render_declaration(words, "values"))

            local const_word =
                types.CTypedef("ffi_const_word", cint(), { "const" })
            assert.equal("ffi_const_word *pointer",
                cdeclarator.render_declaration(
                    types.CPointer(const_word, {}), "pointer"))
        end)

        it("selectively expands private array views with correct precedence",
            function()
                local array = types.CTypedef(
                    "ffi_private_array", types.CArray(cint(), 3))
                array._declaration_array_view = true
                local const_array = types.CTypedef(
                    "ffi_private_const_array", types.CArray(cint(), 3),
                    { "const" })
                const_array._declaration_array_view = true
                local function private_view(typ)
                    return typ._declaration_array_view == true
                end

                assert.equal("ffi_private_array values",
                    cdeclarator.render_declaration(array, "values"))
                assert.equal("int values[3]",
                    cdeclarator.render_declaration(
                        array, "values", nil, private_view))
                assert.equal("int (*pointer)[3]",
                    cdeclarator.render_declaration(
                        types.CPointer(array, {}), "pointer", nil,
                        private_view))
                assert.equal("const int (*pointer)[3]",
                    cdeclarator.render_declaration(
                        types.CPointer(const_array, {}), "pointer", nil,
                        private_view))
                assert.equal("void take(const int [3])",
                    cdeclarator.render_declaration(
                        types.CFunction(
                            { const_array }, types.CVoid(), false, "cdecl"),
                        "take", nil, private_view))
            end)

        it("uses real tag spelling and never invents a typedef for tag aliases",
            function()
                local struct = types.CStruct(
                    nil, "S", "StructAlias", {}, true, false)
                local union = types.CUnion(
                    nil, "U", "UnionAlias", {}, true)

                assert.equal("struct S value",
                    cdeclarator.render_declaration(struct, "value"))
                assert.equal("union U value",
                    cdeclarator.render_declaration(union, "value"))
                assert.equal("struct S *pointer", cdeclarator.render_declaration(
                    types.CPointer(struct, {}), "pointer"))
            end)

        it("uses a real typedef when an anonymous aggregate has no tag", function()
            local struct = types.CStruct(
                nil, nil, "Anonymous", {}, true, false)
            assert.equal("Anonymous value",
                cdeclarator.render_declaration(struct, "value"))
        end)
    end)

    describe("pointers and qualifiers", function()
        it("renders pointee qualifiers at the correct declarator level",
            function()
                assert.equal("const volatile int *pointer",
                    cdeclarator.render_declaration(
                        types.CPointer(cint(), { "const", "volatile" }),
                        "pointer"))

                local const_pointer = types.CPointer(
                    types.CPointer(cint(), {}), { "const" })
                assert.equal("int * const *pointer",
                    cdeclarator.render_declaration(const_pointer, "pointer"))

                local pointer_to_const = types.CPointer(
                    types.CPointer(cint(), { "const" }), {})
                assert.equal("const int **pointer",
                    cdeclarator.render_declaration(pointer_to_const, "pointer"))
            end)

        it("renders abstract pointer type names", function()
            assert.equal("int *", cdeclarator.render_type_name(
                types.CPointer(cint(), {})))
            assert.equal("const char *", cdeclarator.render_type_name(
                types.CPointer(cchar(), { "const" })))
        end)
    end)

    describe("arrays", function()
        it("renders direct, unsized, and nested arrays as arrays", function()
            assert.equal("int values[3]", cdeclarator.render_declaration(
                types.CArray(cint(), 3), "values"))
            assert.equal("int values[]", cdeclarator.render_declaration(
                types.CArray(cint(), nil), "values"))
            assert.equal("int matrix[2][3]", cdeclarator.render_declaration(
                types.CArray(types.CArray(cint(), 3), 2), "matrix"))
            assert.equal("const volatile int values[3]",
                cdeclarator.render_declaration(
                    types.CArray(
                        cint(), 3, { "const", "volatile" }),
                    "values"))
        end)

        it("distinguishes pointer-to-array from array-of-pointers", function()
            assert.equal("int (*pointer)[3]", cdeclarator.render_declaration(
                types.CPointer(types.CArray(cint(), 3), {}), "pointer"))
            assert.equal("int *pointers[3]", cdeclarator.render_declaration(
                types.CArray(types.CPointer(cint(), {}), 3), "pointers"))
            assert.equal("int (*)[3]", cdeclarator.render_type_name(
                types.CPointer(types.CArray(cint(), 3), {})))
        end)

        it("renders nested array and pointer combinations", function()
            local row_pointer = types.CPointer(
                types.CArray(cint(), 5), { "const" })
            assert.equal("const int (*rows[2])[5]",
                cdeclarator.render_declaration(
                    types.CArray(row_pointer, 2), "rows"))

            local matrix_pointer = types.CPointer(
                types.CArray(types.CArray(cint(), 4), 3), {})
            assert.equal("int (*matrix)[3][4]",
                cdeclarator.render_declaration(matrix_pointer, "matrix"))
        end)

        it("rejects direct arrays as expression type names", function()
            assert_error_matches("cannot render a C array", function()
                cdeclarator.render_type_name(types.CArray(cint(), 3))
            end)

            assert_error_matches("cannot render a C array", function()
                cdeclarator.render_type_name(types.CTypedef(
                    "int_array", types.CArray(cint(), 3)))
            end)
        end)

        it("renders symbolic extents without evaluating target C", function()
            assert.equal("int values[(sizeof(int))]",
                cdeclarator.render_declaration(
                    types.CArray(cint(), {
                        { "int" },
                        op = "sizeof",
                    }),
                    "values"))
            assert.equal("int values[(FFI_BOUND + 1)]",
                cdeclarator.render_declaration(
                    types.CArray(cint(), {
                        "FFI_BOUND",
                        1,
                        op = "+",
                    }),
                    "values"))
            assert.equal("int values[((unsigned long)3U)]",
                cdeclarator.render_declaration(
                    types.CArray(cint(), {
                        { "unsigned", "long" },
                        { "3U" },
                    }),
                    "values"))
        end)

        it("preserves abstract-declarator precedence in symbolic extents",
            function()
                local pointer_to_array = {
                    "int",
                    {
                        declarator = { "*" },
                        { idx = { "3" } },
                    },
                }
                local pointer_to_function = {
                    "int",
                    {
                        declarator = { "*" },
                        params = {
                            {
                                param = {
                                    type = { "double" },
                                    id = "",
                                },
                            },
                        },
                        paramstyle = "prototype",
                    },
                }
                local function pointer_to_array_parameter(suffix)
                    return {
                        "int",
                        {
                            declarator = { "*" },
                            params = {
                                {
                                    param = {
                                        type = { "int" },
                                        id = { suffix },
                                    },
                                },
                            },
                            paramstyle = "prototype",
                        },
                    }
                end

                assert.equal("int values[(sizeof(int (*)[3]))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            pointer_to_array,
                            op = "sizeof",
                        }),
                        "values"))
                assert.equal("int values[(sizeof(int (*)(double)))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            pointer_to_function,
                            op = "sizeof",
                        }),
                        "values"))
                assert.equal(
                    "int values[(sizeof(int (*)(int [static const 3])))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            pointer_to_array_parameter({
                                array_static = "static",
                                array_qualifiers = { "const" },
                                idx = { "3" },
                            }),
                            op = "sizeof",
                        }),
                        "values"))
                assert.equal(
                    "int values[(sizeof(int (*)(int [static volatile 4])))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            pointer_to_array_parameter({
                                array_qualifiers = { "volatile" },
                                array_static = "static",
                                idx = { "4" },
                            }),
                            op = "sizeof",
                        }),
                        "values"))
                assert.equal("int values[(sizeof(int (*)(int [*])))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            pointer_to_array_parameter({
                                idx = "*",
                            }),
                            op = "sizeof",
                        }),
                        "values"))
                assert.equal(
                    "int values[(sizeof(int (*)[(FFI_BOUND + 1)]))]",
                    cdeclarator.render_declaration(
                        types.CArray(cint(), {
                            {
                                "int",
                                {
                                    declarator = { "*" },
                                    {
                                        idx = {
                                            "FFI_BOUND",
                                            1,
                                            op = "+",
                                        },
                                    },
                                },
                            },
                            op = "sizeof",
                        }),
                        "values"))
            end)

        it("rejects malformed symbolic extents deterministically", function()
            assert_error_matches("malformed binary array extent", function()
                cdeclarator.render_declaration(
                    types.CArray(cint(), {
                        "UNKNOWN",
                        op = "/",
                    }),
                    "values")
            end)
        end)
    end)

    describe("functions", function()
        it("renders direct functions and zero-argument prototypes", function()
            local function_type = types.CFunction(
                { cint() }, types.CVoid(), false, "cdecl")
            assert.equal("void consume(int)",
                cdeclarator.render_declaration(function_type, "consume"))
            assert.equal("int ready(void)", cdeclarator.render_declaration(
                types.CFunction({}, cint(), false, "cdecl"), "ready"))
        end)

        it("renders empty old-style declarations distinctly", function()
            local oldstyle =
                types.CFunction({}, cint(), false, "cdecl")
            oldstyle._paramstyle = "oldstyle"
            local prototype =
                types.CFunction({}, cint(), false, "cdecl")
            prototype._paramstyle = "prototype"

            assert.equal("int legacy()",
                cdeclarator.render_declaration(
                    oldstyle, "legacy"))
            assert.equal("int exact(void)",
                cdeclarator.render_declaration(
                    prototype, "exact"))
        end)

        it("renders function pointers, varargs, and abstract type names",
            function()
                local handle = types.CStruct(
                    nil, "uv_handle_s", nil, {}, false, false)
                local callback = types.CPointer(types.CFunction({
                    types.CPointer(handle, {}),
                    cint(),
                }, cint(), true, "cdecl"), {})

                assert.equal(
                    "int (*callback)(struct uv_handle_s *, int, ...)",
                    cdeclarator.render_declaration(callback, "callback"))
                assert.equal(
                    "int (*)(struct uv_handle_s *, int, ...)",
                    cdeclarator.render_type_name(callback))

                local const_callback = types.CPointer(
                    types.CFunction({}, cint(), false, "cdecl"), { "const" })
                assert.equal("int (* const callback)(void)",
                    cdeclarator.render_declaration(
                        const_callback, "callback"))
            end)

        it("renders direct function return qualifiers exactly", function()
            local callback =
                types.CFunction({}, cint(), false, "cdecl")
            callback._return_declaration_qualifiers =
            { "const", "volatile" }
            local pointer = types.CPointer(callback, {})

            assert.equal("const volatile int (*callback)(void)",
                cdeclarator.render_declaration(pointer, "callback"))
            assert.equal("const volatile int (*)(void)",
                cdeclarator.render_type_name(pointer))

            local qualified_void =
                types.CFunction({}, types.CVoid(), false, "cdecl")
            qualified_void._return_declaration_qualifiers = { "const" }
            assert.equal("const void finish(void)",
                cdeclarator.render_declaration(
                    qualified_void, "finish"))
        end)

        it("renders arrays of callbacks and callbacks returning pointers",
            function()
                local callback = types.CPointer(
                    types.CFunction({}, cint(), false, "cdecl"), {})
                assert.equal("int (*callbacks[4])(void)",
                    cdeclarator.render_declaration(
                        types.CArray(callback, 4), "callbacks"))

                local returns_pointer = types.CPointer(types.CFunction(
                    {}, types.CPointer(cint(), {}), false, "cdecl"), {})
                assert.equal("int *(*factory)(void)",
                    cdeclarator.render_declaration(
                        returns_pointer, "factory"))
                assert.equal("int (*factory(void))(void)",
                    cdeclarator.render_declaration(
                        callback, "factory(void)"))
            end)

        it("adjusts direct array and function parameter types", function()
            local callback = types.CFunction({}, cint(), false, "cdecl")
            local function_type = types.CFunction({
                types.CArray(cint(), 3),
                callback,
            }, types.CVoid(), false, "cdecl")

            assert.equal("void visit(int *, int (*)(void))",
                cdeclarator.render_declaration(function_type, "visit"))

            local adjusted_array = cdeclarator.adjust_parameter_type(
                types.CArray(cint(), 3))
            assert.equal("Type.CPointer", adjusted_array._tag)
            assert.same(cint(), adjusted_array.pointee)

            local adjusted_const_array =
                cdeclarator.adjust_parameter_type(
                    types.CArray(cint(), 3, { "const" }))
            assert.same({ "const" }, adjusted_const_array.quals)
            assert.equal("const int *",
                cdeclarator.render_type_name(adjusted_const_array))

            local adjusted_function =
                cdeclarator.adjust_parameter_type(callback)
            assert.equal("Type.CPointer", adjusted_function._tag)
            assert.same(callback, adjusted_function.pointee)
            assert.same(cint(),
                cdeclarator.adjust_parameter_type(cint()))
        end)

        it("preserves typedef spellings in parameter declarators",
            function()
                local size = types.CTypedef("size_t", cint())
                local bytes = types.CTypedef(
                    "byte_buffer", types.CArray(cchar(), 32))
                local callback = types.CTypedef("callback_fn",
                    types.CFunction({}, cint(), false, "cdecl"))
                local function_type = types.CFunction(
                    { size, bytes, callback }, types.CVoid(), false, "cdecl")

                assert.equal("void read(size_t, byte_buffer, callback_fn)",
                    cdeclarator.render_declaration(function_type, "read"))
                assert.equal("callback_fn * const callback",
                    cdeclarator.render_declaration(
                        types.CPointer(callback, { "const" }), "callback"))
                assert.equal("char *", cdeclarator.render_type_name(
                    cdeclarator.adjust_parameter_type(bytes)))
                assert.equal("callback_fn *", cdeclarator.render_type_name(
                    cdeclarator.adjust_parameter_type(callback)))
            end)

        it("rejects a direct function as an expression type", function()
            assert_error_matches("cannot render a C function", function()
                cdeclarator.render_type_name(types.CFunction(
                    {}, cint(), false, "cdecl"))
            end)
        end)
    end)
end)
