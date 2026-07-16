local symtab = require 'titan-compiler.symtab'

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

    it("recovers the foreign declarations visible at an initializer", function()
        local st = symtab.new()
        local early_type, late_type = {}, {}
        local early_name, late_name = {}, {}

        st.current_toplevel_order = 1
        st:add_foreign_type("shared", early_type)
        st:add_foreign_name("shared", early_name)
        st.current_toplevel_order = 4
        st:add_foreign_type("shared", late_type)
        st:add_foreign_name("shared", late_name)
        st.current_toplevel_order = nil

        assert.equal(late_type, st:find_foreign_type("shared"))
        assert.equal(late_name, st:find_foreign_name("shared"))
        st.initializer_order = 2
        assert.equal(early_type, st:find_foreign_type("shared"))
        assert.equal(early_name, st:find_foreign_name("shared"))
        st.initializer_order = 0
        assert.is_nil(st:find_foreign_type("shared"))
        assert.is_nil(st:find_foreign_name("shared"))
    end)
end)
