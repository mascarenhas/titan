local assert = require 'luassert'

local function clean_test_artifacts()
    os.execute("rm -rf test.o test.so test.c test.titan test__entrypoint.c test test.dSYM")
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

local function build_coro()
    assert.truthy(exec_ok(
        "env CCACHE_DISABLE=1 cc --std=c99 -O2 -Wall -fPIC -g " ..
        "-fno-optimize-sibling-calls -c titan-runtime/titan_coro.c " ..
        "-I titan-runtime -I lua-5.5.0/src -I libbacktrace " ..
        "-o titan-runtime/titan_coro.o"))
    assert.truthy(exec_ok(
        "env CCACHE_DISABLE=1 TITAN_PATH_0_11=/tmp TITAN_PATH=/tmp ./titanc coro " ..
        "-X titan-runtime/titan_coro.o"))
end

local function compile_and_run(titan_code, lua_code)
    clean_test_artifacts()
    write_file("test.titan", titan_code)
    assert.truthy(exec_ok("env CCACHE_DISABLE=1 ./titanc test"))
    local so = assert(io.open("test.so", "r"))
    so:close()

    local script = os.tmpname()
    write_file(script, lua_code)
    local f = assert(io.popen("./lua -l test " .. script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

describe("coro standard module", function()
    setup(function()
        os.remove("titan-runtime/titan.o")
        build_coro()
    end)

    after_each(clean_test_artifacts)

    it("creates a coroutine and returns a callback result", function()
        local out = compile_and_run([[
            local coro = import "coro"

            function body(arg: value): value
                return arg
            end

            function run(): value
                local co = coro.create(body, "tag")
                return co:resume("hello")
            end
        ]], [==[
            assert(test.run() == "hello")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("yields, resumes, reports status, and checks yieldability", function()
        local out = compile_and_run([[
            local coro = import "coro"

            function body(arg: value): value
                if not coro.is_yieldable("tag") then
                    raise "not yieldable"
                end
                local back = coro.yield(arg, "tag")
                return back
            end

            function outside(): boolean
                return coro.is_yieldable("tag")
            end

            function run(): string
                local co = coro.create(body, "tag")
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

    it("routes a nested tagged yield through a stacked parent", function()
        local out = compile_and_run([[
            local coro = import "coro"

            function run(): string
                local tag_main: value = "main"
                local tag_a: value = "a"
                local b = coro.create(function (arg: value): value
                    coro.yield("from-b", tag_main)
                    return "b-done"
                end, tag_a)
                local a = coro.create(function (arg: value): value
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
            assert(test.run() == "from-b,stacked/suspended,a:b-done,dead/dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves callback traces and injects errors into a suspended yield", function()
        local out = compile_and_run([[
            local coro = import "coro"

            function fail(): value
                raise "boom"
                return nil
            end

            function body(arg: value): value
                return fail()
            end

            function uncaught(): value
                local co = coro.create(body, "tag")
                return co:resume(nil)
            end

            function catcher(arg: value): value
                do
                    coro.yield("ready", "tag")
                catch
                    return "caught:" .. (error as string)
                end
                return "missed"
            end

            function inject(): string
                local co = coro.create(catcher, "tag")
                local first = co:resume(nil)
                local second = co:error("oops")
                return (first as string) .. "," .. (second as string) ..
                    "," .. co:status()
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.uncaught)
            assert(not ok and err == "boom")
            local bt = titan.backtrace()
            assert(bt:find("in test.fail", 1, true),
                   "missing coroutine callback frame\n" .. tostring(bt))
            assert(test.inject() == "ready,caught:oops,dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects missing effective tags in the Titan wrapper", function()
        local out = compile_and_run([[
            local coro = import "coro"

            function body(arg: value): value
                return arg
            end

            function missing(): value
                local co = coro.create(body)
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
            local coro = import "coro"

            seen: boolean = false

            function body(arg: value): value
                seen = true
                return arg
            end

            function before_start(): value
                local co = coro.create(body, "tag")
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
end)
