local function run_suite(name)
    local command = "bash spec/support/run_titan_stdlib_tests.sh " .. name
    local ok, reason, status = os.execute(command)
    assert.is_true(ok, string.format(
        "native Titan suite %s failed (%s %s)",
        name, tostring(reason), tostring(status)))
end

describe("native synchronous Titan standard-library tests", function()
    it("runs iter, GC, and synchronous Lua behavior", function()
        run_suite("pure")
    end)

    it("runs math behavior", function()
        run_suite("math")
    end)

    it("runs Lua and PEG ownership behavior", function()
        run_suite("lua-peg")
    end)

    it("runs PEG and relabel behavior", function()
        run_suite("peg")
    end)

    it("runs string and regex behavior", function()
        run_suite("string")
    end)
end)
