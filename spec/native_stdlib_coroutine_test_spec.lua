local function run_suite()
    local command =
        "bash spec/support/run_titan_stdlib_tests.sh coroutine 2>&1"
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a")
    local ok, reason, status = pipe:close()
    assert.is_true(ok, string.format(
        "native Titan coroutine suite failed (%s %s):\n%s",
        tostring(reason), tostring(status), output))
    assert.falsy(output:find("uncaught error in async Task:", 1, true),
        output)
end

describe("native Titan coroutine standard-library tests", function()
    it("runs direct coroutine behavior", run_suite)
end)
