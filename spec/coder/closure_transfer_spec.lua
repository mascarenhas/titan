local h = require "spec.support.helpers"
local temporary = require "spec.support.temporary"

describe("closure transfer metadata generation", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".lua" }) do
            os.remove("test" .. suffix)
        end
    end)

    it("publishes one module manifest with typed scalar and traced capture boxes", function()
        local c = h.compile_and_read_c([[
            function make(start: integer): function(): integer
                local number = start
                local text = "saved"
                return function(): integer
                    number = number + #text
                    text = text .. "!"
                    return number
                end
            end
        ]])
        local _, manifests = c:gsub("static const TitanTransferModule ", "")
        assert.equal(1, manifests)
        assert.truthy(c:find("TITAN_TRANSFER_MANIFEST_SYMBOL", 1, true))
        assert.truthy(c:find("TITAN_TRANSFER_SOURCE", 1, true))
        assert.truthy(c:find("_boxed[] = { 1, 1 }", 1, true))
        assert.truthy(c:find("(*((lua_Integer *)getudatamem", 1, true)
            or c:find("(*(lua_Integer *)getudatamem", 1, true))
        assert.truthy(c:find("luaC_barrierback(L, obj2gco(_box)", 1, true))
        assert.truthy(c:find("setclCvalue(L, s2v(L->top.p), _closure)", 1, true))
    end)

    it("rebuilds callable adjustments from their immediate source closure", function()
        local c = h.compile_and_read_c([[
            function make(): function(integer, value): value
                local increment = 2
                return function(input: integer): integer
                    return input + increment
                end
            end
        ]])
        assert.truthy(c:find("TITAN_TRANSFER_ADAPTER", 1, true))
        assert.truthy(c:find("_fn->upvalue[_fn->nupvalues - 2]", 1, true))
        assert.truthy(c:find("_closure->f = _source->f", 1, true))
        assert.truthy(c:find("&_closure->upvalue[_i], &_source->upvalue[_i]", 1, true))
        assert.truthy(c:find("invalid source closure for transferred adjustment", 1, true))
    end)

    it("refreshes reconstruction plans after erasing generic captures", function()
        h.run_coder([[
            function make<|T|>(item: T): function(): T
                return function(): T
                    item = item
                    return item
                end
            end
            function run(): integer
                local callback = make(42)
                return callback()
            end
        ]], [[ assert(test.run() == 42) ]])
    end)

    it("rejects managed C pointer captures while preserving absent optionals", function()
        local header = temporary.name(".h")
        local file = assert(io.open(header, "w"))
        file:write("typedef struct Udata Udata;\ntypedef Udata *managed_pointer;\n")
        file:close()
        local ok, c = pcall(h.compile_and_read_c, [[
            foreign import "]] .. header .. [["
            function direct(): function(): value
                local item = M as foreign *Udata
                return function(): value item = item return item end
            end
            function optional(present: boolean): function(): value
                local item: (foreign managed_pointer)? = nil
                if present then item = M as foreign managed_pointer end
                return function(): value item = item return item end
            end
        ]])
        os.remove(header)
        assert.is_true(ok, c)
        local _, guards = c:gsub("cannot transfer a captured Lua%-managed C pointer", "")
        assert.equal(4, guards)
        assert.truthy(c:find("else { lua_pushnil(L); }", 1, true))
        assert.truthy(c:find("if (ttisnil(&_value))", 1, true))
    end)
end)
