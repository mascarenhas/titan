local foreigntypes = require "titan-compiler.foreigntypes"
local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local cdefines = require "c-parser.cdefines"
local csemantics = require "titan-compiler.csemantics"

local function target_profile(with_int128)
    local macros = {
        __CHAR_BIT__ = "8",
        __CHAR_UNSIGNED__ = "1",
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
    }
    if with_int128 then macros.__SIZEOF_INT128__ = "16" end
    return assert(csemantics.build_profile(
        macros, "long long", "double"))
end

describe("foreign C type conversion", function()
    it("canonicalizes an unqualified short int", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local converted, err = foreigntypes.convert(scope, {
            type = { "short", "int" },
        })

        assert.is_nil(err)
        assert.same(types.CInteger("short", true, 2, nil), converted)
    end)

    it("instantiates primitives and macro literals from the target profile",
       function()
        local st = symtab.new()
        st.c_profile = target_profile(true)

        local char = assert(foreigntypes.convert(st, {
            type = { "char" },
        }))
        assert.is_false(char.signed)
        assert.equal(8, char.bits)

        local wide = assert(foreigntypes.convert(st, {
            type = { "unsigned", "__int128" },
        }))
        assert.equal("unsigned __int128", wide.spelling)
        assert.equal(128, wide.bits)

        local registered = {}
        cdefines.register_define(
            registered, "UINT_MAX", "0xffffffffU", {})
        local uint = assert(foreigntypes.convert(
            st, registered.UINT_MAX))
        assert.equal("unsigned int", uint.spelling)
        assert.equal("4294967295",
            registered.UINT_MAX._macro_evaluation.value)
    end)

    it("preserves array element qualifiers at the exact declarator level",
       function()
        local st = symtab.new()
        st.c_profile = target_profile(true)

        local const_array = assert(foreigntypes.convert(st, {
            type = {"const", "int", {idx = 3}},
        }))
        assert.equal("Type.CArray", const_array._tag)
        assert.same({"const"}, const_array.quals)

        local const_pointer_elements =
            assert(foreigntypes.convert(st, {
                type = {"int", "*", "const", {idx = 2}},
            }))
        assert.same({"const"}, const_pointer_elements.quals)
        assert.equal("Type.CPointer",
            const_pointer_elements.elem._tag)
        assert.same({}, const_pointer_elements.elem.quals)

        local pointers_to_const =
            assert(foreigntypes.convert(st, {
                type = {"const", "int", "*", {idx = 2}},
            }))
        assert.same({}, pointers_to_const.quals)
        assert.same({"const"}, pointers_to_const.elem.quals)
    end)

    it("retains qualifiers hidden by scalar typedef spellings", function()
        local st = symtab.new()
        st.c_profile = target_profile(true)
        local const_int = assert(foreigntypes.convert(st, {
            type = "typedef",
            name = "ffi_const_int",
            def = {"const", "int"},
        }))
        assert.equal("Type.CTypedef", const_int._tag)
        assert.same({"const"}, const_int.quals)
        assert.equal("int",
            types.resolve_c_typedef(const_int).spelling)
    end)

    it("canonicalizes every explicit signed spelling to profile keys",
       function()
        local st = symtab.new()
        st.c_profile = target_profile(true)
        local cases = {
            { expected = "int", tokens = {"signed"} },
            { expected = "int", tokens = {"signed", "int"} },
            { expected = "int", tokens = {"int", "signed"} },
            { expected = "short", tokens = {"signed", "short"} },
            { expected = "short", tokens = {"short", "signed", "int"} },
            { expected = "short", tokens = {"int", "short", "signed"} },
            { expected = "long", tokens = {"signed", "long"} },
            { expected = "long", tokens = {"long", "signed", "int"} },
            { expected = "long long",
              tokens = {"signed", "long", "long"} },
            { expected = "long long",
              tokens = {"long", "signed", "long", "int"} },
        }

        for _, case in ipairs(cases) do
            local converted, err = foreigntypes.convert(st, {
                type = case.tokens,
            })
            assert.is_nil(err)
            assert.equal(case.expected, converted.spelling,
                table.concat(case.tokens, " "))
            assert.equal(
                st.c_profile.integers[case.expected].type,
                converted)
        end
    end)

    it("does not invent an extension integer absent from the target",
       function()
        local st = symtab.new()
        st.c_profile = target_profile(false)
        local converted, err = foreigntypes.convert(st, {
            type = { "__int128" },
        })
        assert.is_nil(converted)
        assert.matches("unsupported C type", err, 1, true)
    end)

    it("keeps direct declaration names out of structural function types", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local function raw(paramname)
            return {
                type = "function",
                params = {{name = paramname, type = {"int"}}},
                paramnames = {paramname},
                paramnames_state = "complete",
                ret = {type = {"int"}},
                vararg = false,
            }
        end

        local left = assert(foreigntypes.convert(scope, raw("left")))
        local right = assert(foreigntypes.convert(scope, raw("right")))

        assert.truthy(types.equals(left, right))
        assert.equal(types.tostring(left), types.tostring(right))
        assert.is_nil(left.paramnames)
    end)

    it("keeps callback names out of structural C function types", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local function raw(paramname)
            return {
                type = "functionptr",
                name = "callback",
                params = {{name = paramname, type = {"int"}}},
                paramnames = {paramname},
                paramnames_state = "complete",
                ret = {type = {"void"}},
                vararg = false,
                pointer = {"*"},
            }
        end

        local left = assert(foreigntypes.convert(scope, raw("event")))
        local right = assert(foreigntypes.convert(scope, raw("value")))
        local left_function = types.resolve_c_typedef(left.pointee)

        assert.truthy(types.equals(left, right))
        assert.equal(types.tostring(left), types.tostring(right))
        assert.equal("Type.CFunction", left_function._tag)
        assert.is_nil(left_function.paramnames)
    end)

    it("preserves old-style metadata and forms prototype composites",
    function()
        local st = symtab.new()
        st.c_profile = target_profile(true)

        local oldstyle = assert(foreigntypes.convert(st, {
            type = "function",
            name = "ffi_legacy",
            params = {},
            ret = {
                type = {"int"},
                _declarator_base = {"int"},
                _declarator_ops = {},
            },
            vararg = false,
            _paramstyle = "oldstyle",
        }))
        local prototype = assert(foreigntypes.convert(st, {
            type = "function",
            name = "ffi_legacy",
            params = {{
                name = "value",
                type = {"int"},
                _declarator_base = {"int"},
                _declarator_ops = {},
            }},
            ret = {
                type = {"int"},
                _declarator_base = {"int"},
                _declarator_ops = {},
            },
            vararg = false,
            _paramstyle = "prototype",
        }))

        assert.equal("oldstyle", oldstyle._paramstyle)
        assert.equal("oldstyle", oldstyle._c_function._paramstyle)
        assert.equal("prototype", prototype._paramstyle)
        assert.equal("conditional",
            foreigntypes.declaration_compatibility(
                oldstyle, prototype))
        local canonical =
            foreigntypes.merge_declaration_composite(
                oldstyle, prototype)
        assert.equal(oldstyle, canonical)
        assert.equal("prototype", canonical._paramstyle)
        assert.equal("prototype",
            canonical._c_function._paramstyle)
        assert.equal(1, #canonical.params)

        local reverse_oldstyle =
            assert(foreigntypes.convert(st, {
                type = "function",
                name = "ffi_legacy_reverse",
                params = {},
                ret = {
                    type = {"int"},
                    _declarator_base = {"int"},
                    _declarator_ops = {},
                },
                vararg = false,
                _paramstyle = "oldstyle",
            }))
        local reverse =
            foreigntypes.merge_declaration_composite(
                prototype, reverse_oldstyle)
        assert.equal(prototype, reverse)
        assert.equal("prototype", reverse._paramstyle)
        assert.equal(1, #reverse.params)
    end)

    it("retains parameter style through declaration array views", function()
        local st = symtab.new()
        st.c_profile = target_profile(true)
        local converted = assert(foreigntypes.convert(st, {
            type = "function",
            name = "ffi_array_callback",
            params = {{
                name = "values",
                type = {"int", "*"},
                _declarator_base = {"int"},
                _declarator_ops = {{idx = 7}, "*"},
            }},
            ret = {
                type = {"void"},
                _declarator_base = {"void"},
                _declarator_ops = {},
            },
            vararg = false,
            _paramstyle = "prototype",
        }))

        assert.equal("prototype", converted._paramstyle)
        assert.equal("prototype",
            converted._c_function._paramstyle)
        assert.equal("Type.CArray",
            converted.params[1].pointee._tag)
    end)

    it("leaves compatible ordinary-declaration reuse to the checker",
    function()
        local st = symtab.new()
        st.c_profile = target_profile(true)

        local long = st.c_profile.integers.long.type
        local internal = types.CTypedef("__ffi_offset_t", long)
        local public = types.CTypedef("ffi_offset_t", internal)
        st:add_foreign_type("__ffi_offset_t", internal)
        st:add_foreign_type("ffi_offset_t", public)

        local function lock_type(offset_name)
            return {
                type = "function",
                name = "ffi_lock",
                params = {
                    { name = "fd", type = { "int" } },
                    { name = "command", type = { "int" } },
                    { name = "offset", type = { offset_name } },
                },
                ret = { type = { "int" } },
                vararg = false,
            }
        end

        local first = assert(foreigntypes.convert(
            st, lock_type("ffi_offset_t")))
        st:add_foreign_name("ffi_lock", {
            header = "public.h",
            type = first,
        })
        local repeated = assert(foreigntypes.convert(
            st, lock_type("__ffi_offset_t")))

        assert.not_equal(first, repeated)
        assert.equal("exact",
            foreigntypes.declaration_compatibility(first, repeated))
        assert.equal(first,
            foreigntypes.merge_declaration_composite(first, repeated))
        assert.equal("__ffi_offset_t", repeated.params[3].name)

        local first_object = assert(foreigntypes.convert(st, {
            type = { "ffi_offset_t" },
            name = "ffi_cursor",
        }))
        st:add_foreign_name("ffi_cursor", {
            header = "public.h",
            type = first_object,
        })
        local repeated_object = assert(foreigntypes.convert(st, {
            type = { "__ffi_offset_t" },
            name = "ffi_cursor",
        }))
        assert.not_equal(first_object, repeated_object)
        assert.equal("exact",
            foreigntypes.declaration_compatibility(
                first_object, repeated_object))
    end)

    it("does not reuse incompatible declarations or nominal tag identities",
    function()
        local st = symtab.new()
        st.c_profile = target_profile(true)

        local long_alias = types.CTypedef(
            "ffi_long_offset_t", st.c_profile.integers.long.type)
        local int_alias = types.CTypedef(
            "ffi_int_offset_t", st.c_profile.integers.int.type)
        st:add_foreign_type("ffi_long_offset_t", long_alias)
        st:add_foreign_type("ffi_int_offset_t", int_alias)

        local function value_type(alias)
            return {
                type = "function",
                name = "ffi_value",
                params = {{ name = "value", type = { alias } }},
                ret = { type = { "int" } },
                vararg = false,
            }
        end

        local first = assert(foreigntypes.convert(
            st, value_type("ffi_long_offset_t")))
        st:add_foreign_name("ffi_value", {
            header = "long.h",
            type = first,
        })
        local conflicting = assert(foreigntypes.convert(
            st, value_type("ffi_int_offset_t")))
        assert.not_equal(first, conflicting)
        assert.falsy(foreigntypes.declarations_compatible(
            first, conflicting))

        local first_tag = types.CStruct(
            nil, "Local", nil, {}, false, false)
        local second_tag = types.CStruct(
            nil, "Local", nil, {}, false, false)
        local int = st.c_profile.integers.int.type
        local first_prototype = types.Function({
            types.CPointer(first_tag, {}),
        }, {int}, false, false, false)
        local second_prototype = types.Function({
            types.CPointer(second_tag, {}),
        }, {int}, false, false, false)
        local repeated_prototype = types.Function({
            types.CPointer(first_tag, {}),
        }, {int}, false, false, false)

        assert.falsy(foreigntypes.declarations_compatible(
            first_prototype, second_prototype))
        assert.truthy(foreigntypes.declarations_compatible(
            first_prototype, repeated_prototype))
    end)

    describe("ordered C tag binding", function()
        local function provenance(header, order, scope, definition)
            return {
                header = header,
                declaration_order = order,
                scope = scope or "file",
                definition = definition and true or false,
            }
        end

        local function file_tag(kind, name, header, order, fields)
            return {
                type = kind,
                name = name,
                fields = fields,
                _file_scope_tag = true,
                _tag_provenance = provenance(
                    header, order, "file", fields ~= nil),
            }
        end

        local function prototype_tag(kind, name, header, scope_id,
                                     allow_outer)
            return {
                type = kind,
                name = name,
                pointer = {"*"},
                _prototype_scope_id = scope_id,
                _allow_outer_binding = allow_outer,
                _tag_provenance = provenance(
                    header, 1, "prototype:" .. scope_id),
            }
        end

        it("reuses and atomically completes one aggregate across imports",
           function()
            local st = symtab.new()
            st.current_toplevel_order = 1
            local forward = assert(foreigntypes.convert(
                st, file_tag("struct", "Item", "forward.h", 1)))
            assert.is_false(forward.complete)
            assert.equal(forward, st:find_foreign_type("struct@Item"))

            st.current_toplevel_order = 4
            local complete = assert(foreigntypes.convert(st,
                file_tag("struct", "Item", "definition.h", 2, {
                    {
                        name = "value",
                        type = {"int"},
                    },
                })))
            st.current_toplevel_order = nil

            assert.equal(forward, complete)
            assert.is_true(complete.complete)
            assert.equal("value", complete.fields[1].name)
            assert.equal(4, complete._definition_order)
            assert.equal(complete,
                st:find_c_file_tag("Item", "struct").canonical)

            st.initializer_order = 3
            assert.is_false(st:foreign_definition_visible(complete))
            st.initializer_order = 4
            assert.is_true(st:foreign_definition_visible(complete))
        end)

        it("uses one registry owner for a same-header view and raw definition",
           function()
            local st = symtab.new()
            st.current_toplevel_order = 2
            local raw = file_tag("union", "Cell", "cell.h", 3, {
                {
                    name = "integer",
                    type = {"int"},
                },
            })
            local view = file_tag("union", "Cell", "cell.h", 1)
            view._canonical_tag = raw

            local incomplete = assert(foreigntypes.convert(st, view))
            assert.is_false(incomplete.complete)
            local completed = assert(foreigntypes.convert(st, raw))

            assert.equal(incomplete, completed)
            assert.is_true(completed.complete)
            assert.equal("integer", completed.fields[1].name)
            assert.equal(completed,
                st:find_foreign_type("union@Cell"))
        end)

        it("returns an explicit cross-kind conflict from conversion",
           function()
            local st = symtab.new()
            assert(foreigntypes.convert(st,
                file_tag("struct", "Conflict", "one.h", 2)))
            local converted, err = foreigntypes.convert(st,
                file_tag("union", "Conflict", "two.h", 5))

            assert.is_nil(converted)
            assert.matches("conflicting C tag kinds for 'Conflict'",
                err, 1, true)
            assert.matches("one.h", err, 1, true)
            assert.matches("declaration 2", err, 1, true)
            assert.matches("two.h", err, 1, true)
            assert.matches("declaration 5", err, 1, true)
        end)

        it("binds an eligible prototype reference to a prior file tag",
           function()
            local st = symtab.new()
            local prior = assert(foreigntypes.convert(st,
                file_tag("struct", "Prior", "prior.h", 1)))
            local pointer = assert(foreigntypes.convert(st,
                prototype_tag("struct", "Prior", "consumer.h", 1, true)))

            assert.equal("Type.CPointer", pointer._tag)
            assert.equal(prior, pointer.pointee)
        end)

        it("keeps repeated prototype-local tags out of global foreign types",
           function()
            local st = symtab.new()
            local first = assert(foreigntypes.convert(st,
                prototype_tag("struct", "Later", "consumer.h", 7, true)))
            local second = assert(foreigntypes.convert(st,
                prototype_tag("struct", "Later", "consumer.h", 7, true)))

            assert.equal(first.pointee, second.pointee)
            assert.is_nil(st:find_foreign_type("struct@Later"))
            assert.is_nil(st:find_c_file_tag("Later"))

            local later = assert(foreigntypes.convert(st,
                file_tag("struct", "Later", "later.h", 1, {
                    {
                        name = "value",
                        type = {"int"},
                    },
                })))
            assert.not_equal(first.pointee, later)
            assert.equal(later, st:find_foreign_type("struct@Later"))
        end)

        it("does not outer-bind a prototype definition", function()
            local st = symtab.new()
            local prior = assert(foreigntypes.convert(st,
                file_tag("struct", "Shadow", "prior.h", 1)))
            local local_definition = prototype_tag(
                "struct", "Shadow", "consumer.h", 3, false)
            local_definition.fields = {
                {
                    name = "local_value",
                    type = {"int"},
                },
            }

            local pointer = assert(
                foreigntypes.convert(st, local_definition))
            assert.not_equal(prior, pointer.pointee)
            assert.is_true(pointer.pointee.complete)
            assert.is_nil(st.c_prototype_tags["prior.h"])
        end)
    end)
end)
