-- End-to-end regressions for Lua-stack relocation. Reserved GC roots must be
-- addressed by stable offsets, never cached TValue* pointers.
local h = require 'spec.support.helpers'

local function clean()
    os.remove("test.o")
    os.remove("test.so")
    os.remove("test.a")
    os.remove("test.lua")
    os.execute("rm -rf test.so.dSYM")
    if not h.verbose then os.remove("test.c") end
end

local function fixture_source()
    local decls, uses = {}, {}
    for i = 1, 320 do
        decls[#decls + 1] = 'local s' .. i .. ': string = "x"'
        uses[#uses + 1] = 'total = total + #s' .. i
    end
    return [[
        function growstack(): integer
    ]] .. table.concat(decls, "\n") .. [[
            local total = 0
    ]] .. table.concat(uses, "\n") .. [[
            return total
        end

        function w(p: string): integer
            local keep = p
            local junk: {integer} = {}
            growstack()
            local i = 1
            while i <= 300 do
                junk = {i}
                keep = keep .. "x"
                i = i + 1
            end
            return #keep
        end

        function r(p: string): integer
            local keep = p
            local junk: {integer} = {}
            growstack()
            local i = 1
            repeat
                junk = {i}
                keep = keep .. "x"
                i = i + 1
            until i > 300
            return #keep
        end

        function f(p: string): integer
            local keep = p
            local junk: {integer} = {}
            growstack()
            for i = 1, 300 do
                junk = {i}
                keep = keep .. "x"
            end
            return #keep
        end

        function run(p: string): integer
            local keep = p
            do
                growstack()
                keep = keep .. "!"
                raise {10, 20}
            catch
                local e: {integer} = error as {integer}
                return #keep + e[2]
            finally
                growstack()
            end
        end
    ]]
end

describe("Lua-stack relocation safety", function()
    setup(function()
        clean()
        local ok, err, ast = h.run_checker(fixture_source())
        assert.truthy(ok, err)
        ok, err = h.compile("test", ast)
        assert.truthy(ok, err)
    end)

    teardown(clean)

    it("keeps reassigned GC locals rooted across calls and every loop form", function()
        local ok, err = h.call("test", [[
            collectgarbage("incremental", 1, 1, 1)
            for _ = 1, 100 do
                collectgarbage("step", 1000)
                assert(test.w("a") == 301)
                assert(test.r("a") == 301)
                assert(test.f("a") == 301)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps try recovery slots and enclosing GC locals stable across stack relocation", function()
        local ok, err = h.call("test", [[
            collectgarbage("incremental", 1, 1, 1)
            for _ = 1, 100 do
                collectgarbage("step", 1000)
                assert(test.run("abc") == 24)
            end
        ]])
        assert.truthy(ok, err)
    end)
end)
