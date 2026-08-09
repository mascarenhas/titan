local function run_suite(name, options)
    local command = "bash spec/support/run_titan_stdlib_tests.sh " .. name
    if options then command = command .. " " .. options end
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, reason, status = pipe:close()
    assert.is_true(ok, string.format(
        "native Titan suite %s failed (%s %s):\n%s",
        name, tostring(reason), tostring(status), output))
    assert.falsy(output:find("uncaught error in async Task:", 1, true),
        output)
    return output
end

describe("native OS standard-library tests", function()
    it("runs network and TLS behavior", function()
        run_suite("net-ssl")
    end)

    it("runs isolated signal, stream, and native-lifetime behavior", function()
        run_suite("os-uv", table.concat({
            "--each-filter-only",
            "test_signal_watcher_validation_delivery_cancellation_and_replacement",
            "test_stream_facades_capture_merge_inheritance_options_and_interfaces",
            "test_stream_facade_close_wakes_pending_reader",
            "test_runtime_shutdown_closes_native_handles_but_not_files",
        }, " "))
    end)

    it("runs URL behavior", function()
        run_suite("url")
    end)

    it("runs OS helper and time behavior", function()
        run_suite("os")
    end)
end)
