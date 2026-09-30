local symtab = require 'titan-compiler.symtab'
local types = require 'titan-compiler.types'

describe("Titan symbol table", function()

    it("can find some symbols", function()
        local st = symtab.new()
        local d_a, d_a2, d_b = 1, 2, 3
        st:with_block(function()
            st:add_symbol("a", d_a)
            assert.are.same(st:find_symbol("a"), d_a)
            st:with_block(function()
                st:add_symbol("a", d_a2)
                st:add_symbol("b", d_b)
                assert.are.same(st:find_symbol("a"), d_a2)
                assert.are.same(st:find_symbol("b"), d_b)
            end)
            assert.are.same(st:find_symbol("a"), d_a)
            assert.are.same(st:find_symbol("b"), nil)
        end)
    end)

    it("applies the module-variable declaration frontier", function()
        local st = symtab.new()
        local early_import = {
            _tag = "Ast.TopLevelImport",
            _toplevel_order = 1,
        }
        local early_var = {
            _tag = "Ast.TopLevelVar",
            _toplevel_order = 2,
        }
        local current_var = {
            _tag = "Ast.TopLevelVar",
            _toplevel_order = 3,
        }
        local late_import = {
            _tag = "Ast.TopLevelImport",
            _toplevel_order = 4,
        }
        local late_var = {
            _tag = "Ast.TopLevelVar",
            _toplevel_order = 5,
        }
        local record = {
            _tag = "Ast.TopLevelRecord",
            _toplevel_order = 6,
        }
        st:add_symbol("early_import", early_import)
        st:add_symbol("early_var", early_var)
        st:add_symbol("current_var", current_var)
        st:add_symbol("late_import", late_import)
        st:add_symbol("late_var", late_var)
        st:add_symbol("record", record)

        st.initializer_order = 3
        assert.equal(early_import, st:find_symbol("early_import"))
        assert.equal(early_var, st:find_symbol("early_var"))
        assert.is_nil(st:find_symbol("current_var"))
        assert.is_nil(st:find_symbol("late_import"))
        assert.is_nil(st:find_symbol("late_var"))
        assert.equal(record, st:find_symbol("record"))
    end)

    it("keeps foreign declaration frontiers and final hoisted macro state",
    function()
        local st = symtab.new()
        local early_type, late_type = {}, {}
        local early_name, late_name = {}, {}
        local early_macro = { "early", ".", "field" }
        local late_macro = { "late", ".", "field" }

        st.current_toplevel_order = 1
        st:add_foreign_type("shared", early_type)
        st:add_foreign_name("shared", early_name)
        st:apply_foreign_macro_changes({}, {
            projected = early_macro,
        })
        st.current_toplevel_order = 4
        st:add_foreign_type("shared", late_type)
        st:add_foreign_name("shared", late_name)
        st:apply_foreign_macro_changes({ projected = true }, {
            projected = late_macro,
        })
        st.current_toplevel_order = nil

        assert.equal(late_type, st:find_foreign_type("shared"))
        assert.equal(late_name, st:find_foreign_name("shared"))
        assert.equal(late_macro,
            (st:find_foreign_macro_definition("projected")))
        st.initializer_order = 2
        assert.equal(early_type, st:find_foreign_type("shared"))
        assert.equal(early_name, st:find_foreign_name("shared"))
        -- C headers are hoisted in generated translation units, so macro
        -- definitions use the final view even at an initializer frontier.
        assert.equal(late_macro,
            (st:find_foreign_macro_definition("projected")))
        st.initializer_order = 0
        assert.is_nil(st:find_foreign_type("shared"))
        assert.is_nil(st:find_foreign_name("shared"))
        assert.equal(late_macro,
            (st:find_foreign_macro_definition("projected")))

        local cached_projection = { name = "projected" }
        st:cache_foreign_field_macro("projected", cached_projection)
        assert.equal(cached_projection,
            (st:find_cached_foreign_field_macro("projected")))
        st:apply_foreign_macro_changes({ projected = true }, {})
        assert.is_nil(st:find_foreign_macro_definition("projected"))
        local _, known =
            st:find_cached_foreign_field_macro("projected")
        assert.is_false(known)
    end)

    it("distinguishes uncomputed, absent, and present macro classifications", function()
        local st = symtab.new()
        local projection, known = st:find_cached_foreign_field_macro("field")
        assert.is_nil(projection)
        assert.is_false(known)
        assert.same({tag="unknown"}, st.foreign_field_macro_cache.field)

        st:cache_foreign_field_macro("field", nil)
        projection, known = st:find_cached_foreign_field_macro("field")
        assert.is_nil(projection)
        assert.is_true(known)
        assert.same({tag="none"}, st.foreign_field_macro_cache.field)

        local classified = {name="field", path={"outer", "inner"}}
        st:cache_foreign_field_macro("field", classified)
        projection, known = st:find_cached_foreign_field_macro("field")
        assert.equal(classified, projection)
        assert.is_true(known)
        assert.same({tag="just",value=classified},
            st.foreign_field_macro_cache.field)

        st:apply_foreign_macro_changes({}, {})
        projection, known = st:find_cached_foreign_field_macro("field")
        assert.is_nil(projection)
        assert.is_false(known)
        assert.same({tag="unknown"}, st.foreign_field_macro_cache.field)
    end)

    it("rejects false macro classification sentinels", function()
        local st = symtab.new()
        assert.has_error(function()
            st:cache_foreign_field_macro("field", false)
        end, "foreign field macro projection must be a table")
        st.foreign_field_macro_cache.field = {tag="just",value=false}
        assert.has_error(function()
            st:find_cached_foreign_field_macro("field")
        end, "cached foreign field macro projection must be a table")
    end)

    describe("ordered C tag registry", function()
        local function provenance(header, order, scope, definition)
            return {
                header = header,
                declaration_order = order,
                scope = scope or "file",
                definition = definition and true or false,
            }
        end

        it("reuses one file tag record and honors the import frontier",
           function()
            local st = symtab.new()
            st.current_toplevel_order = 2
            local first = assert(st:register_c_file_tag(
                "Item", "struct", provenance("first.h", 1)))
            local canonical = types.CStruct(
                nil, "Item", nil, {}, false, false)
            assert.equal(canonical,
                st:set_c_tag_canonical(first, canonical))

            st.current_toplevel_order = 5
            local second = assert(st:register_c_file_tag(
                "Item", "struct",
                provenance("second.h", 4, "file", true)))
            st.current_toplevel_order = nil

            assert.equal(first, second)
            assert.equal(canonical, second.canonical)
            assert.equal(2, #second.provenances)
            assert.equal("first.h", second.header)
            assert.equal(second, st:find_c_file_tag("Item", "struct"))

            st.initializer_order = 1
            assert.is_nil(st:find_c_file_tag("Item", "struct"))
            st.initializer_order = 2
            assert.equal(second, st:find_c_file_tag("Item", "struct"))
        end)

        it("reports cross-import shared-namespace conflicts with both sites",
           function()
            local st = symtab.new()
            assert(st:register_c_file_tag(
                "Conflict", "struct",
                provenance("structs.h", 3)))

            local record, err = st:register_c_enum_tag(
                "Conflict", provenance("enums.h", 7))
            assert.is_nil(record)
            assert.matches("conflicting C tag kinds for 'Conflict'",
                err, 1, true)
            assert.matches("structs.h", err, 1, true)
            assert.matches("declaration 3", err, 1, true)
            assert.matches("enums.h", err, 1, true)
            assert.matches("declaration 7", err, 1, true)
            assert.matches("struct", err, 1, true)
            assert.matches("enum", err, 1, true)
        end)

        it("binds eligible prototype references to a visible file tag",
           function()
            local st = symtab.new()
            local file = assert(st:register_c_file_tag(
                "Prior", "union", provenance("prior.h", 1)))
            local bound = assert(st:bind_c_prototype_tag(
                "Prior", "union", 1,
                provenance("consumer.h", 2, "prototype:1"),
                true))
            assert.equal(file, bound)
            assert.is_nil(st.c_prototype_tags["consumer.h"])
        end)

        it("rejects a wrong-kind prototype reference to a visible file tag",
           function()
            local st = symtab.new()
            assert(st:register_c_file_tag(
                "Prior", "struct", provenance("prior.h", 1)))
            local bound, err = st:bind_c_prototype_tag(
                "Prior", "union", 1,
                provenance("consumer.h", 2, "prototype:1"),
                true)
            assert.is_nil(bound)
            assert.matches("conflicting C tag kinds for 'Prior'",
                err, 1, true)
            assert.matches("prior.h", err, 1, true)
            assert.matches("consumer.h", err, 1, true)
            assert.matches("struct", err, 1, true)
            assert.matches("union", err, 1, true)
        end)

        it("interns prototype tags by header, scope, and base name",
           function()
            local st = symtab.new()
            local a1 = assert(st:bind_c_prototype_tag(
                "Local", "struct", 1,
                provenance("a.h", 2, "prototype:1"), true))
            local a2 = assert(st:bind_c_prototype_tag(
                "Local", "struct", 1,
                provenance("a.h", 2, "prototype:1"), true))
            local b = assert(st:bind_c_prototype_tag(
                "Local", "struct", 1,
                provenance("b.h", 2, "prototype:1"), true))
            local other_scope = assert(st:bind_c_prototype_tag(
                "Local", "struct", 2,
                provenance("a.h", 2, "prototype:2"), true))

            assert.equal(a1, a2)
            assert.not_equal(a1, b)
            assert.not_equal(a1, other_scope)
            assert.is_nil(st:find_c_file_tag("Local"))

            local later = assert(st:register_c_file_tag(
                "Local", "struct", provenance("later.h", 1)))
            assert.not_equal(a1, later)
        end)
    end)
end)
