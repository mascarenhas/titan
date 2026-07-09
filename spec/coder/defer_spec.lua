-- End-to-end coverage for `defer <statement>`.
local h = require 'spec.support.helpers'

local compile_and_run = h.compile_and_run

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("defer statement (code generator)", function()
    setup(function() os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("runs a deferred statement when the surrounding block falls through", function()
        local out = compile_and_run([[
            log: string = ""
            function add(s: string)
                log = log .. s
            end
            function run(): string
                do
                    defer add("cleanup;")
                    add("body;")
                end
                return log
            end
        ]], [==[
            assert(test.run() == "body;cleanup;")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs multiple defers in last-in-first-out order", function()
        local out = compile_and_run([[
            log: string = ""
            function add(s: string)
                log = log .. s
            end
            function run(): string
                do
                    defer add("first;")
                    defer add("second;")
                    add("body;")
                end
                return log
            end
        ]], [==[
            assert(test.run() == "body;second;first;")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs deferred statements before returning the body value", function()
        local out = compile_and_run([[
            seen: boolean = false
            function mark()
                seen = true
            end
            function run(): string
                defer mark()
                return "value"
            end
            function marked(): boolean
                return seen
            end
        ]], [==[
            assert(test.run() == "value")
            assert(test.marked() == true)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs a multi-statement `defer do ... end` cleanup", function()
        local out = compile_and_run([[
            log: string = ""
            function add(s: string)
                log = log .. s
            end
            function run(): string
                do
                    defer do
                        add("a;")
                        add("b;")
                    end
                    add("body;")
                end
                return log
            end
        ]], [==[
            assert(test.run() == "body;a;b;")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs a deferred statement before a propagated raise", function()
        local out = compile_and_run([[
            ran: boolean = false
            function mark()
                ran = true
            end
            function boom()
                defer mark()
                raise "boom"
            end
            function marked(): boolean
                return ran
            end
        ]], [==[
            local ok, err = pcall(test.boom)
            assert(not ok)
            assert(err == "boom")
            assert(test.marked() == true)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)
end)
