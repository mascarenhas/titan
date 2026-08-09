local function run_suite(name)
    local command = "bash spec/support/run_titan_stdlib_tests.sh " .. name ..
        " 2>&1"
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a")
    local ok, reason, status = pipe:close()
    assert.is_true(ok, string.format(
        "native Titan suite %s failed (%s %s):\n%s",
        name, tostring(reason), tostring(status), output))
    return output
end

local function count_occurrences(subject, needle)
    local count = 0
    local position = 1
    while true do
        local found = subject:find(needle, position, true)
        if not found then return count end
        count = count + 1
        position = found + #needle
    end
end

describe("native asynchronous Titan standard-library tests", function()
    it("runs channels, combinators, and Task primitives", function()
        local output = run_suite("async")
        assert.equal(7, count_occurrences(
            output, "uncaught error in async Task:"), output)
        for _, message in ipairs({
            "all-live-logged-failure",
            "all-logged-failure",
            "combinator-logged-failure",
            "any-live-logged-failure",
            "join-logged-failure",
            "race-logged-failure",
        }) do
            assert.truthy(output:find(message, 1, true), output)
        end
        assert.falsy(output:find("swallowed-listener-error", 1, true), output)
    end)

    it("runs Task continuation and cancellation behavior", function()
        local output = run_suite("uv-tasks")
        assert.equal(1, count_occurrences(
            output, "uncaught error in async Task:"), output)
        assert.truthy(output:find("task-status-boom", 1, true), output)
        assert.truthy(output:find(
            "in uv_tasks_native.failed_origin", 1, true), output)
    end)

    it("runs I/O, process, filesystem, and timer behavior", function()
        local output = run_suite("io-fs-timer")
        assert.falsy(output:find("uncaught error in async Task:", 1, true),
            output)
    end)
end)
