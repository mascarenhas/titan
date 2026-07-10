local assert = require 'luassert'

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local LUA = file_exists("./lua") and "./lua" or ".lua/bin/lua"
local TITANC = LUA ..
    [[ -e 'package.path="./?.lua;./?/init.lua;" .. package.path' ./titanc]]
local TEST_ENV = "env CCACHE_DISABLE=1 TITAN_STDLIB_PATH=. "

local function clean_test_artifacts()
    os.execute("rm -rf test.o test.so test.c test.titan " ..
        "test__entrypoint.c test test.dSYM coroutine_standalone app " ..
        "app__entrypoint.c app.dSYM")
end

local function exec_ok(cmd)
    local ok, _, code = os.execute(cmd)
    return ok == true or ok == 0 or code == 0
end

local function write_file(path, contents)
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
end

local function build_coroutine()
    assert.truthy(exec_ok(
        "env CCACHE_DISABLE=1 cc --std=c99 -O2 -Wall -fPIC -g " ..
        "-fno-optimize-sibling-calls -c titan-runtime/titan_coro.c " ..
        "-I titan-runtime -I lua-5.5.0/src -I libbacktrace " ..
        "-o titan-runtime/titan_coro.o"))
    assert.truthy(exec_ok(
        TEST_ENV .. "TITAN_PATH_0_11= TITAN_PATH= " ..
        TITANC .. " --stdlib-build --tree stdlib " ..
        "--lua-name titan.coroutine coroutine " ..
        "-X titan-runtime/titan_coro.o"))
    assert.truthy(exec_ok("mkdir -p titan"))
    os.remove("titan/coroutine.so")
    assert.truthy(exec_ok("ln -s ../coroutine.so titan/coroutine.so"))
end

local function clean_coroutine_artifacts()
    os.remove("titan/coroutine.so")
    os.execute("rmdir titan 2>/dev/null")
    os.remove("coroutine.so")
    os.remove("stdlib/coroutine.c")
    os.remove("stdlib/coroutine.o")
end

local function compile_and_run(titan_code, lua_code)
    clean_test_artifacts()
    write_file("test.titan", titan_code)
    assert.truthy(exec_ok(TEST_ENV .. TITANC .. " test"))
    local so = assert(io.open("test.so", "r"))
    so:close()

    local script = os.tmpname()
    write_file(script, lua_code)
    local f = assert(io.popen(TEST_ENV .. LUA .. " -l test " ..
        script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function compile_and_run_require_first(titan_code, lua_code)
    clean_test_artifacts()
    write_file("test.titan", titan_code)
    assert.truthy(exec_ok(TEST_ENV .. TITANC .. " test"))
    local so = assert(io.open("test.so", "r"))
    so:close()

    local script = os.tmpname()
    write_file(script, lua_code)
    local f = assert(io.popen(TEST_ENV .. LUA .. " " .. script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function compile_and_run_app(titan_code)
    clean_test_artifacts()
    write_file("test.titan", titan_code)
    assert.truthy(exec_ok(TEST_ENV .. TITANC .. " test"))

    local f = assert(io.popen(TEST_ENV .. "./test 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    assert.truthy(ok, "program failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function run_lua(lua_code)
    local script = os.tmpname()
    write_file(script, lua_code)
    local f = assert(io.popen(TEST_ENV .. LUA .. " " .. script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function compile_and_run_standalone_import()
    clean_test_artifacts()
    assert.truthy(exec_ok("mkdir -p coroutine_standalone"))
    write_file("coroutine_standalone/app.titan", [[
        local coroutine = import "coroutine"

        function body(arg: value): value
            return arg
        end

        function main(args: {string}): integer
            local co = coroutine.create(body, "tag")
            if co:resume("ok") == "ok" then
                return 0
            end
            return 1
        end
    ]])
    assert.truthy(exec_ok(TEST_ENV .. TITANC ..
        " --tree coroutine_standalone app"))

    local f = assert(io.popen(TEST_ENV .. "./app 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    assert.truthy(ok, "program failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

describe("coroutine standard module", function()
    setup(function()
        os.remove("titan-runtime/titan.o")
        build_coroutine()
    end)

    after_each(clean_test_artifacts)
    teardown(function()
        clean_coroutine_artifacts()
    end)

    it("creates a coroutine and returns a callback result", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                return arg
            end

            function run(): value
                local co = coroutine.create(body, "tag")
                return co:resume("hello")
            end
        ]], [==[
            assert(test.run() == "hello")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("shares the canonical module when Titan imports before Lua requires", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                return arg
            end

            function make(): coroutine.Coro
                return coroutine.create(body, "tag")
            end
        ]], [==[
            local lua_coroutine = require "coroutine"
            local from_titan = test.make()
            local titan_coroutine = require "titan.coroutine"
            local from_lua = titan_coroutine.create(function(arg)
                return arg
            end, "tag")

            assert(type(titan_coroutine) == "userdata")
            assert(require "coroutine" == lua_coroutine)
            assert(package.loaded.coroutine == lua_coroutine)
            assert(debug.getmetatable(from_titan) ==
                   debug.getmetatable(from_lua))
            assert(debug.getregistry()["titan.coroutine"] ~= nil)
            assert(debug.getregistry()["titan.coro"] == nil)
            local open = assert(package.loadlib(
                "./coroutine.so", "luaopen_titan_coroutine"))
            assert(open() == titan_coroutine)
            assert(package.loadlib(
                "./coroutine.so", "luaopen_coroutine") == nil)
            assert(package.loadlib(
                "./coroutine.so", "luaopen_coro") == nil)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("shares the canonical module when Lua requires before Titan imports", function()
        local out = compile_and_run_require_first([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                return arg
            end

            function make(): coroutine.Coro
                return coroutine.create(body, "tag")
            end
        ]], [==[
            local lua_coroutine = require "coroutine"
            local titan_coroutine = require "titan.coroutine"
            local from_lua = titan_coroutine.create(function(arg)
                return arg
            end, "tag")
            local test = require "test"
            local from_titan = test.make()

            assert(type(titan_coroutine) == "userdata")
            assert(require "coroutine" == lua_coroutine)
            assert(package.loaded.coroutine == lua_coroutine)
            assert(debug.getmetatable(from_titan) ==
                   debug.getmetatable(from_lua))
            local open = assert(package.loadlib(
                "./coroutine.so", "luaopen_titan_coroutine"))
            assert(open() == titan_coroutine)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("yields, resumes, reports status, and checks yieldability", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                if not coroutine.is_yieldable("tag") then
                    raise "not yieldable"
                end
                if coroutine.is_yieldable("other") then
                    raise "wrong tag yieldable"
                end
                local back = coroutine.yield(arg, "tag")
                return back
            end

            function outside(): boolean
                return coroutine.is_yieldable("tag")
            end

            function run(): string
                local co = coroutine.create(body, "tag")
                local s0 = co:status()
                local first = co:resume("out")
                local s1 = co:status()
                local second = co:resume("in")
                local s2 = co:status()
                return s0 .. ":" .. (first as string) .. ":" .. s1 ..
                    ":" .. (second as string) .. ":" .. s2
            end
        ]], [==[
            assert(test.outside() == false)
            assert(test.run() == "suspended:out:suspended:in:dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("uses default tags, explicit overrides, and explicit nil fallback", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function default_resume(): string
                local co = coroutine.create(function (arg: value): value
                    local got = coroutine.yield(arg, "default")
                    return got
                end, "default")
                local first = co:resume("out", nil)
                local second = co:resume("in", nil)
                return (first as string) .. ":" .. (second as string)
            end

            function override_resume(): string
                local co = coroutine.create(function (arg: value): value
                    local got = coroutine.yield(arg, "override")
                    return got
                end, "default")
                local first = co:resume("out", "override")
                local second = co:resume("in", "override")
                return (first as string) .. ":" .. (second as string)
            end

            function default_error(): string
                local co = coroutine.create(function (arg: value): value
                    do
                        coroutine.yield("ready", "default")
                    catch
                        return "caught:" .. (error as string)
                    end
                    return "missed"
                end, "default")
                local first = co:resume(nil, nil)
                local second = co:error("oops", nil)
                return (first as string) .. ":" .. (second as string)
            end

            function override_error(): string
                local co = coroutine.create(function (arg: value): value
                    do
                        coroutine.yield("ready", "override")
                    catch
                        return "caught:" .. (error as string)
                    end
                    return "missed"
                end, "default")
                local first = co:resume(nil, "override")
                local second = co:error("oops", "override")
                return (first as string) .. ":" .. (second as string)
            end
        ]], [==[
            assert(test.default_resume() == "out:in")
            assert(test.override_resume() == "out:in")
            assert(test.default_error() == "ready:caught:oops")
            assert(test.override_error() == "ready:caught:oops")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("reports running and normal statuses through the Titan wrapper", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local a
            local b
            b = coroutine.create(function()
                assert(a:status() == "normal")
                assert(b:status() == "running")
                return "ok"
            end, "b")
            a = coroutine.create(function()
                return b:resume(nil, "b")
            end, "a")

            assert(a:resume(nil, "a") == "ok")
            assert(a:status() == "dead")
            assert(b:status() == "dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects unmatched raw tags without calling __eq", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local calls = 0
            local mt = {
                __eq = function()
                    calls = calls + 1
                    return true
                end
            }
            local resume_tag = setmetatable({}, mt)
            local yield_tag = setmetatable({}, mt)
            local co = coroutine.create(function()
                return coroutine.yield("unmatched", yield_tag)
            end, resume_tag)

            local ok, err = pcall(function()
                co:resume(nil, resume_tag)
            end)
            assert(not ok, "raw-unequal tags should not match")
            assert(tostring(err):find("Invalid operation", 1, true),
                   tostring(err))
            assert(calls == 0, "__eq comparator was called")
            assert(co:status() == "dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("routes a nested tagged yield through a suspended outer handler", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function run(): string
                local tag_main: value = "main"
                local tag_a: value = "a"
                local b = coroutine.create(function (arg: value): value
                    coroutine.yield("from-b", tag_main)
                    return "b-done"
                end, tag_a)
                local a = coroutine.create(function (arg: value): value
                    local got = b:resume("to-b")
                    return "a:" .. (got as string)
                end, tag_main)
                local first = a:resume("start", tag_main)
                local middle = a:status() .. "/" .. b:status()
                local second = a:resume("again", tag_main)
                return (first as string) .. "," .. middle .. "," ..
                    (second as string) .. "," .. a:status() .. "/" .. b:status()
            end
        ]], [==[
            assert(test.run() == "from-b,suspended/stacked,a:b-done,dead/dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("injects errors through a nested stacked yield", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function run(): string
                local tag_main: value = "main"
                local tag_a: value = "a"
                local b = coroutine.create(function (arg: value): value
                    do
                        coroutine.yield("from-b", tag_main)
                    catch
                        return "b-caught:" .. (error as string)
                    end
                    return "b-missed"
                end, tag_a)
                local a = coroutine.create(function (arg: value): value
                    local got = b:resume("to-b")
                    return "a:" .. (got as string)
                end, tag_main)
                local first = a:resume("start", tag_main)
                local second = a:error("oops", tag_main)
                return (first as string) .. "," .. (second as string) ..
                    "," .. a:status() .. "/" .. b:status()
            end
        ]], [==[
            assert(test.run() == "from-b,a:b-caught:oops,dead/dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves traces for uncaught errors through a nested stacked yield", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            nested_main_tag: value = nil
            nested_a_tag: value = nil

            function nested_fail_body(arg: value): value
                coroutine.yield("from-b", nested_main_tag)
                return "missed"
            end

            function nested_uncaught(): value
                nested_main_tag = "main"
                nested_a_tag = "a"
                local b = coroutine.create(nested_fail_body, nested_a_tag)
                local a = coroutine.create(function (arg: value): value
                    local got = b:resume("to-b")
                    return "a:" .. (got as string)
                end, nested_main_tag)
                local first = a:resume("start", nested_main_tag)
                if (first as string) ~= "from-b" then
                    raise "bad first"
                end
                return a:error("oops", nested_main_tag)
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.nested_uncaught)
            assert(not ok and err == "oops")
            local bt = titan.backtrace()
            assert(bt:find("in test.nested_fail_body", 1, true),
                   "missing nested coroutine frame\n" .. tostring(bt))
            assert(bt:find("in test.nested_uncaught", 1, true),
                   "missing propagation frame\n" .. tostring(bt))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects direct resume of a stacked coroutine at the Titan wrapper", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function run(): string
                local tag_main: value = "main"
                local tag_a: value = "a"
                local b = coroutine.create(function (arg: value): value
                    coroutine.yield("from-b", tag_main)
                    return "b-done"
                end, tag_a)
                local a = coroutine.create(function (arg: value): value
                    local got = b:resume("to-b")
                    return "a:" .. (got as string)
                end, tag_main)
                local first = a:resume("start", tag_main)
                local stacked = a:status() .. "/" .. b:status()
                local rejected: string = "missed"
                do
                    b:resume("direct", tag_a)
                catch
                    rejected = error as string
                end
                local restored = a:resume("again", tag_main)
                return (first as string) .. "," .. stacked .. "," ..
                    rejected .. "," .. (restored as string)
            end
        ]], [==[
            local text = test.run()
            assert(text:find("^from%-b,suspended/stacked,", 1), text)
            assert(text:find("Coroutine not suspended", 1, true), text)
            assert(text:find(",a:b%-done$", 1), text)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("round-trips nil yield, resume, and return payloads", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function run(): boolean
                local co = coroutine.create(function (arg: value): value
                    if arg ~= nil then
                        raise "initial arg was not nil"
                    end
                    local got = coroutine.yield(nil, "tag")
                    if got ~= nil then
                        raise "resume arg was not nil"
                    end
                    return nil
                end, "tag")
                local first = co:resume(nil)
                local second = co:resume(nil)
                return first == nil and second == nil and co:status() == "dead"
            end
        ]], [==[
            assert(test.run() == true)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves callback traces and injects errors into a suspended yield", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function fail(): value
                raise "boom"
                return nil
            end

            function fresh_fail(): value
                raise "fresh"
                return nil
            end

            function body(arg: value): value
                return fail()
            end

            function uncaught(): value
                local co = coroutine.create(body, "tag")
                return co:resume(nil)
            end

            injected_trace: value = nil

            function catcher(arg: value): value
                do
                    coroutine.yield("ready", "tag")
                catch
                    injected_trace = traceback
                    return "caught:" .. (error as string)
                end
                return "missed"
            end

            function inject(): string
                local co = coroutine.create(catcher, "tag")
                local first = co:resume(nil)
                local second = co:error("oops")
                return (first as string) .. "," .. (second as string) ..
                    "," .. co:status()
            end

            function injected_backtrace(): value
                return injected_trace
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.uncaught)
            assert(not ok and err == "boom")
            local bt = titan.backtrace()
            assert(bt:find("in test.fail", 1, true),
                   "missing coroutine callback frame\n" .. tostring(bt))
            assert(bt:find("in test.uncaught", 1, true),
                   "missing propagation frame\n" .. tostring(bt))
            assert(test.inject() == "ready,caught:oops,dead")
            local injected = test.injected_backtrace()
            assert(injected:find("in test.catcher", 1, true),
                   "missing injected yield frame\n" .. tostring(injected))
            assert(not injected:find("in test.inject", 1, true),
                   "yield-side injected error should not append caller propagation\n" ..
                   tostring(injected))
            ok, err = pcall(test.fresh_fail)
            assert(not ok and err == "fresh")
            local fresh = titan.backtrace()
            assert(fresh:find("in test.fresh_fail", 1, true),
                   "fresh trace missing fresh raise\n" .. tostring(fresh))
            assert(not fresh:find("in test.fail", 1, true),
                   "fresh trace retained dead coroutine frame\n" .. tostring(fresh))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves finally state across yield and later resume", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            log: string = ""

            function body(arg: value): value
                do
                    log = log .. "body;"
                    coroutine.yield("pause", "tag")
                    log = log .. "after;"
                finally
                    log = log .. "finally;"
                end
                return log
            end

            function run(): string
                local co = coroutine.create(body, "tag")
                local first = co:resume(nil)
                local mid = log
                local second = co:resume(nil)
                return (first as string) .. ":" .. mid .. ":" ..
                    (second as string)
            end
        ]], [==[
            assert(test.run() == "pause:body;:body;after;finally;")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects resume and error after a coroutine is dead", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                return arg
            end

            function after_dead(): string
                local co = coroutine.create(body, "tag")
                local got = co:resume("done")
                local status = co:status()
                do
                    co:resume("again")
                catch
                    local resume_error = error as string
                    do
                        co:error("oops")
                    catch
                        return (got as string) .. ":" .. status .. ":" ..
                            resume_error .. ":" .. (error as string)
                    end
                end
                return "missed"
            end
        ]], [==[
            local text = test.after_dead()
            assert(text:find("done:dead:", 1, true), text)
            assert(text:find("Coroutine not suspended", 1, true), text)
            print("OK")
        ]==])
        assert.falsy(out:find("attempt to resume", 1, true), out)
        assert.match("OK", out)
    end)

    it("rejects missing effective tags in the Titan wrapper", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            function body(arg: value): value
                return arg
            end

            function missing(): value
                local co = coroutine.create(body)
                return co:resume(nil)
            end
        ]], [==[
            local ok, err = pcall(test.missing)
            assert(not ok)
            assert(tostring(err):find("must provide tag argument", 1, true))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("injects an error before first resume without calling the entry function", function()
        local out = compile_and_run([[
            local coroutine = import "coroutine"

            seen: boolean = false

            function body(arg: value): value
                seen = true
                return arg
            end

            function before_start(): value
                local co = coroutine.create(body, "tag")
                return co:error("pre-start")
            end

            function was_seen(): boolean
                return seen
            end
        ]], [==[
            local ok, err = pcall(test.before_start)
            assert(not ok and err == "pre-start")
            assert(test.was_seen() == false)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("roots nested stacked payloads and tags across generational GC", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"
            collectgarbage("generational")

            local weak = setmetatable({}, { __mode = "v" })
            local tag_main = {}
            local tag_a = {}
            local payload = { name = "payload" }
            local marker = function(x) return x.name end
            weak.tag_main = tag_main
            weak.tag_a = tag_a
            weak.payload = payload
            weak.marker = marker

            local b = coroutine.create(function(arg)
                assert(arg == weak.payload)
                local got = coroutine.yield(weak.marker, weak.tag_main)
                return got
            end, tag_a)
            local a = coroutine.create(function(arg)
                return b:resume(arg, weak.tag_a)
            end, tag_main)

            assert(a:resume(payload, tag_main) == marker)
            tag_main = nil
            tag_a = nil
            payload = nil
            marker = nil

            for _ = 1, 80 do collectgarbage("step") end
            assert(weak.tag_main ~= nil)
            assert(weak.tag_a ~= nil)
            assert(weak.payload ~= nil)
            assert(weak.marker ~= nil)
            assert(a:status() == "suspended")
            assert(b:status() == "stacked")

            local response = { name = "response" }
            assert(a:resume(response, weak.tag_main) == response)
            assert(a:status() == "dead")
            assert(b:status() == "dead")

            collectgarbage("incremental")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("abandons stacked coroutines when their suspended handler is collected", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"
            collectgarbage("generational")

            local tag_main = {}
            local tag_b = {}
            local stacked

            do
                local a = coroutine.create(function()
                    local b = coroutine.create(function()
                        return coroutine.yield("from-b", tag_main)
                    end, tag_b)
                    stacked = b
                    return b:resume(nil, tag_b)
                end, tag_main)

                assert(a:resume(nil, tag_main) == "from-b")
                assert(a:status() == "suspended")
                assert(stacked:status() == "stacked")
                a = nil
            end

            for _ = 1, 4 do collectgarbage("collect") end
            assert(stacked:status() == "dead", stacked:status())
            local ok, err = pcall(function()
                stacked:resume(nil, tag_b)
            end)
            assert(not ok, "abandoned stacked coroutine should not resume")
            assert(tostring(err):find("Coroutine not suspended", 1, true),
                   tostring(err))

            collectgarbage("incremental")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("loads from Lua and roots value payloads and identity tags across GC", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"
            collectgarbage("generational")

            local tag = {}
            local payload
            local marker
            local co = coroutine.create(function(arg)
                assert(arg == payload)
                collectgarbage("step")
                local got = coroutine.yield(marker, tag)
                assert(got == payload)
                return marker(got)
            end, tag)

            collectgarbage("collect")
            payload = { answer = 41 }
            marker = function(x) return x.answer + 1 end
            assert(co:status() == "suspended")
            assert(co:resume(payload, tag) == marker)
            payload.extra = {}
            for _ = 1, 50 do collectgarbage("step") end
            assert(co:resume(payload, tag) == 42)
            assert(co:status() == "dead")

            local nco = coroutine.create(function(arg)
                local back = coroutine.yield("numeric", 1.0)
                return back
            end, 1)
            assert(nco:resume(nil, 1) == "numeric")
            assert(nco:resume("done", 1.0) == "done")

            collectgarbage("incremental")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("reports Lua call errors for bad coroutine API use", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local function fails(fn, needle)
                local ok, err = pcall(fn)
                assert(not ok, "expected API call to fail")
                if needle then
                    assert(tostring(err):find(needle, 1, true),
                           tostring(err))
                end
            end

            local bad_callback = coroutine.create("not callable", "tag")
            fails(function()
                bad_callback:resume(nil)
            end)

            fails(function()
                coroutine.yield("payload")
            end, "must provide non-nil tag argument to coroutine.yield")

            fails(function()
                coroutine.yield("payload", "tag")
            end, "Invalid coroutine")

            local co = coroutine.create(function()
                return "done"
            end, "tag")
            assert(co:resume(nil) == "done")
            fails(function()
                co:resume(nil)
            end, "Coroutine not suspended")

            local missing = coroutine.create(function(arg)
                return arg
            end)
            fails(function()
                missing:resume(nil)
            end, "must provide tag argument")

            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("imports coroutine from a compiled module in a standalone executable", function()
        local out = compile_and_run_standalone_import()
        assert.same("", out)
    end)
end)
