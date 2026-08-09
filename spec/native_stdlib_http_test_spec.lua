local FILTERS = {
    "test_server_idle_keep_alive_eof_is_clean",
    "test_server_buffered_empty_lines_eof_is_malformed",
    "test_server_partial_keep_alive_eof_is_malformed",
    "test_server_partial_empty_line_eof_is_malformed",
    "test_plain_http_header_idle_timeout_protocol",
    "test_https_header_idle_timeout_protocol",
}

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

local function filter_section(output, filter)
    local marker = "===== TITAN FILTER " .. filter .. " =====\n"
    local marker_start, marker_end = output:find(marker, 1, true)
    assert.truthy(marker_start, output)
    local next_start = output:find("\n===== TITAN FILTER ",
        marker_end + 1, true)
    if next_start then
        return output:sub(marker_end + 1, next_start - 1)
    else
        return output:sub(marker_end + 1)
    end
end

local function run_http_suite()
    local command = "bash spec/support/run_titan_stdlib_tests.sh http" ..
        " --also-each-filter " .. table.concat(FILTERS, " ") .. " 2>&1"
    local pipe = assert(io.popen(command, "r"))
    local output = pipe:read("*a")
    local ok, reason, status = pipe:close()
    assert.is_true(ok, string.format(
        "native Titan HTTP suite failed (%s %s):\n%s",
        tostring(reason), tostring(status), output))
    return output
end

describe("native Titan HTTP standard-library tests", function()
    it("runs behavior directly and supervises expected Task diagnostics", function()
        local output = run_http_suite()
        local first_marker = assert(output:find(
            "\n===== TITAN FILTER ", 1, true))
        local full_run = output:sub(1, first_marker - 1)
        assert.equal(14, count_occurrences(
            full_run, "uncaught error in async Task:"), full_run)

        local clean_eof = filter_section(output, FILTERS[1])
        assert.equal(0, count_occurrences(
            clean_eof, "uncaught error in async Task:"), clean_eof)

        local buffered_empty = filter_section(output, FILTERS[2])
        assert.equal(1, count_occurrences(
            buffered_empty, "uncaught error in async Task:"), buffered_empty)
        assert.truthy(buffered_empty:find(
            "HTTP message ended before it was complete", 1, true),
            buffered_empty)

        local partial = filter_section(output, FILTERS[3])
        assert.equal(1, count_occurrences(
            partial, "uncaught error in async Task:"), partial)
        assert.truthy(partial:find("HPE_INVALID_EOF_STATE", 1, true), partial)

        local partial_empty = filter_section(output, FILTERS[4])
        assert.equal(1, count_occurrences(
            partial_empty, "uncaught error in async Task:"), partial_empty)
        assert.truthy(partial_empty:find(
            "HTTP message ended before it was complete", 1, true),
            partial_empty)

        local plain_timeout = filter_section(output, FILTERS[5])
        assert.equal(1, count_occurrences(
            plain_timeout, "uncaught error in async Task:"), plain_timeout)
        assert.truthy(plain_timeout:find("HTTP parse error", 1, true),
            plain_timeout)

        local https_timeout = filter_section(output, FILTERS[6])
        assert.equal(0, count_occurrences(
            https_timeout, "uncaught error in async Task:"), https_timeout)
    end)
end)
