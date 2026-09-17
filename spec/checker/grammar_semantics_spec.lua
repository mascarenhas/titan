local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

describe("simplified grammar semantic boundaries", function()
    local session
    setup(function() session = h.new_checker_probe_session() end)
    teardown(function() h.close_checker_probe_session(session) end)

    it("checks assignment targets and standalone expressions semantically", function()
        for _, source in ipairs({
            "function f() 1 = 2 end",
            "function f() f() = 2 end",
            "function f() local x = 1; (x) = 2 end",
            "function f() local x = 1; x<|integer|> = 2 end",
        }) do
            local tree, parse_error = h.parse(source)
            assert.truthy(tree, parse_error)
            local ok, err = h.run_checker(source)
            assert.falsy(ok)
            assert.matches("not an assignable variable", err, 1, true)
        end
        local ok, err = h.run_checker("function f() 1 end")
        assert.falsy(ok)
        assert.matches("only a function call", err, 1, true)
    end)

    it("initializes typed mutable module variables with nil", function()
        local ok, err, tree = h.run_checker([[
            local pending: integer?
            local label: string?
            do pending = 42 end
        ]])
        assert.truthy(ok, err)
        assert.same(types.Option(types.Integer()), tree[1]._type)
        assert.equal("Ast.ExpCast", tree[1].value._tag)
        assert.is_nil(tree[1]._initializerless_const)
        ok, err = h.run_checker("local count: integer")
        assert.falsy(ok)
        assert.matches("does not accept nil", err, 1, true)
    end)

    it("resolves M members in the module namespace despite local shadowing", function()
        local ok, err, tree = h.run_checker([[
            local count: integer = 17
            local end: integer = 4
            function read(): integer
                local count = 99
                M.count = M.count + 1
                return M.count + M.end
            end
        ]])
        assert.truthy(ok, err)
        local assignment = tree[3].block.stats[2]
        assert.equal("Ast.VarName", assignment.vars[1]._tag)
        assert.equal(tree[1], assignment.vars[1]._decl)
    end)

    it("permits ffi shadowing by locals and parameters", function()
        local ok, err = h.run_checker([[
            function argument(ffi: integer): integer return ffi end
            function local_binding(): integer
                local ffi = 8
                ffi = ffi + 1
                return ffi
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects bare varargs outside a list tail in the checker", function()
        local source = "function f(...: integer): integer local a, b = ..., 1 return b end"
        local tree, parse_error = h.parse(source)
        assert.truthy(tree, parse_error)
        local ok, err = h.run_checker(source)
        assert.falsy(ok)
        assert.matches("can only be used as the last item", err, 1, true)
    end)

    it("rejects a second bare vararg marker as a collection subject", function()
        local ok, err = h.run_checker([[
            function bad(...: integer): (...: integer) return ...... end
        ]])
        assert.falsy(ok)
        assert.matches("cannot use bare '...' as its subject", err, 1, true)
        ok, err = h.run_checker([[
            function collection(...: {integer}): (...: integer)
                return ......[1]
            end
            function tail(...: integer): (...: integer) return ... end
        ]])
        assert.truthy(ok, err)
    end)

    it("selects fixed arrays from target-evaluated integer macros", function()
        local path = os.tmpname()
        local file = assert(io.open(path, "w"))
        file:write([[
            #define COUNT (2U + 3U)
            #define NEGATIVE (-1)
            #define ZERO 0
            #define HUGE 18446744073709551615ULL
            #define TRUNCATED 257U
            static int changing_count;
            #define DYNAMIC changing_count
        ]])
        file:close()
        local ok, err, tree = h.run_checker('foreign import "' .. path .. '"\n' .. [[
            local function use()
                local fixed = foreign int.new_array(ffi.COUNT)
                local owner: owned int[] = foreign int.new_array(ffi.COUNT)
                local zero = foreign int.new_array(ffi.ZERO)
                local dynamic = foreign int.new_array(ffi.DYNAMIC)
                local huge = foreign int.new_array(ffi.HUGE)
                local negative = foreign int.new_array(ffi.NEGATIVE)
                local cast_count = foreign int.new_array(ffi.TRUNCATED as foreign unsigned char)
                local integer_count = foreign int.new_array(ffi.COUNT as integer)
            end
        ]], session)
        os.remove(path)
        assert.truthy(ok, err)
        local stats = tree[2].block.stats
        assert.equal("Type.CArray", stats[1].decls[1]._type._tag)
        assert.equal(5, stats[1].decls[1]._type.len)
        for i = 2, 7 do
            assert.equal("Type.COwned", stats[i].decls[1]._type._tag)
        end
        assert.equal("Type.CArray", stats[8].decls[1]._type._tag)
        assert.equal(5, stats[8].decls[1]._type.len)
    end)

    it("admits only the explicit Udata-pointer cast of the module marker", function()
        local ok, err, tree = h.run_checker([[
            foreign import "titan/ffi.h"
            local function pointer(): foreign *Udata
                return M as foreign *Udata
            end
        ]], session)
        assert.truthy(ok, err)
        assert.equal("current_module", tree[2].block.stats[1].exps[1]._written_cast.op)
        ok, err = h.run_checker([[
            local function bad(): value return M end
        ]], session)
        assert.falsy(ok)
        assert.matches("as a first-class value", err, 1, true)
    end)

    it("rejects owned local storage inside a source foreign function", function()
        local ok, err = h.run_checker([[
            type Buffer = owned int[]
            foreign function invalid(): void
                local storage: Buffer = foreign int.new_array(2)
            end
        ]], session)
        assert.falsy(ok)
        assert.matches("inside a foreign function must have a direct C FFI type", err, 1, true)
    end)
end)
