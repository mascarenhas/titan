-- Abandoned-coroutine unwinding of generated code that needs the installed
-- standard provider (titan.coroutine). Listed in
-- spec/support/ci_stdlib_compiler_test_files.txt, so CI runs it after the full
-- provider is installed; the generated-C-only unwind checks stay in
-- error_handling_spec.lua. See doc/implementation/error-handling.md
-- #unwinding-through-finally.
local h = require 'spec.support.helpers'
local ast = require 'titan-compiler.ast'
local checker = require 'titan-compiler.checker'
local coder_names = require 'titan-compiler.coder.names'

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM test test__entrypoint.c")
    if not h.verbose then os.execute("rm -f *.c *.ffi.h *.titan.h") end
end

local function native_body(csrc, name)
    local symbol = coder_names._function_prefix("test", name) .. "_titan"
    return assert(csrc:match(
        "[^\n]*" .. symbol .. "%b()%s*(%b{})"), symbol)
end

describe("unwind boundaries with the standard provider", function()
    after_each(clean)

    -- The surface language has no try with both catch and finally; codetry
    -- supports it, so graft a finally onto a parsed catch try.
    local function graft_finally(node)
        if type(node) ~= "table" then return false end
        if node.stats then
            for index, stat in ipairs(node.stats) do
                if stat._tag == "Ast.StatTry" and stat.catchblock and
                        not stat.finallyblock then
                    local after = table.remove(node.stats, index + 1)
                    stat.finallyblock = ast.StatBlock(after.loc, { after })
                    return true
                end
            end
        end
        for _, child in pairs(node) do
            if graft_finally(child) then return true end
        end
        return false
    end

    it("unwinds a try with both catch and finally through its catch boundary", function()
        local source = [[
            log: string = ""

            function add(text: string)
                log = log .. text
            end

            function reset()
                log = ""
            end

            function run(pause: function (): ()): string
                do
                    add("body;")
                    raise "boom"
                catch
                    add("catch;")
                    pause()
                    add("after-pause;")
                end
                add("finally;")
                return log
            end
        ]]
        h.reset()
        local tree, perr = h.parse(source, "test.titan")
        assert.truthy(tree, perr)
        assert.truthy(graft_finally(tree), "no catch try to graft onto")
        local _, errs = checker.check("test", tree, source, "test.titan")
        assert.equal(0, #errs, table.concat(errs, "\n"))
        local ok, err = h.compile("test", tree)
        assert.truthy(ok, err)
        local file = assert(io.open("test.c", "r"))
        local body = native_body(file:read("*a"), "run")
        file:close()
        -- The catch boundary is marked too; both landings guard the finally
        -- with the try-scope body boundary.
        assert.truthy(body:find("_lj_1c.status = TITAN_STATUS_FINALLY;", 1, true), body)
        local _, guards = body:gsub("titan_unwind_guard_failed%(L, &_lj_1,", "")
        assert.equal(2, guards)
        local called, out = h.call("test", [==[
            assert(test.run(function() end) == "body;catch;after-pause;finally;")
            test.reset()
            local coroutine = require "titan.coroutine"
            local co = coroutine.create(function(_)
                return test.run(function() coroutine.yield("paused", "tag") end)
            end, "tag")
            assert(co:resume(nil) == "paused")
            co = nil
            collectgarbage("collect")
            collectgarbage("collect")
            assert(test.log == "body;catch;finally;", test.log)
        ]==])
        assert.truthy(called, out)
    end)
end)
