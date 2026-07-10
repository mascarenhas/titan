local assert = require "luassert"
local cdriver = require "c-parser.cdriver"

local PKG_CONFIG = "sh spec/fixtures/libuv/fake-pkg-config.sh"

local function quote(word)
    local quoted = assert(cdriver.shell_quote(word))
    return quoted
end

local function run_make(host, environment)
    local argv = {
        "make", "--no-print-directory", "-s", "LIBUV_MODE=system",
        "HOST_OS=" .. host, "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "libuv-config",
    }
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local command = table.concat(words, " ")
    if environment then command = environment .. " " .. command end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function run_uv_dry_run(mode)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", "stdlib/uv.titan",
        "LIBUV_MODE=" .. mode,
        "HOST_OS=Linux",
        "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "CC=ccache cc",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "uv.so",
    }
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local pipe = assert(io.popen(table.concat(words, " ") .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function run_timer_dry_run(mode)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", "stdlib/timer.titan",
        "LIBUV_MODE=" .. mode,
        "HOST_OS=Linux",
        "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "CC=ccache cc",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "timer.so",
    }
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local pipe = assert(io.popen(table.concat(words, " ") .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

describe("libuv Makefile configuration", function()
    it("preserves complete pkg-config flags and Linux feature macros",
       function()
        local ok, output, why, code = run_make("Linux")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1 " ..
            "-D_GNU_SOURCE", 1, true), output)
        assert.truthy(output:find(
            "LIBUV_LDFLAGS=-L/opt/libuv/lib -luv -pthread -ldl -lrt",
            1, true), output)
    end)

    it("does not add the Linux-only macro on macOS", function()
        local ok, output, why, code = run_make("Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1",
            1, true), output)
        assert.falsy(output:find("-D_GNU_SOURCE", 1, true), output)
    end)

    it("fails early with platform package instructions when libuv is absent",
       function()
        local ok, output = run_make("Linux", "env FAKE_LIBUV_MISSING=1")
        assert.falsy(ok, output)
        assert.truthy(output:find("cannot find the libuv development package",
            1, true), output)
        assert.truthy(output:find("libuv1-dev", 1, true), output)
        assert.truthy(output:find("libuv-devel", 1, true), output)
        assert.truthy(output:find("brew install libuv pkgconf", 1, true),
            output)
    end)

    it("builds uv with one shim, one libuv input, and merged toolchain flags",
       function()
        local ok, output, why, code = run_uv_dry_run("bundled")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local normalized = output:gsub("%s+", " ")
        local command_tail = assert(normalized:match(
            "%-%-lua%-name titan%.uv uv (.+)$"), normalized)
        assert.truthy(command_tail:find(
            "-X titan-runtime/titan_uv.o libuv-build/libuv.a", 1, true),
            command_tail)
        local _, archive_count = command_tail:gsub(
            "libuv%-build/libuv%.a", "")
        assert.equal(1, archive_count, command_tail)
        assert.truthy(normalized:find([[CC='ccache cc']], 1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -Ilibuv-v1.52.1/include -D_GNU_SOURCE']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CFLAGS='-DUSER_C=1 -fno-strict-aliasing']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -ldl -lrt']],
            1, true), normalized)

        ok, output, why, code = run_uv_dry_run("system")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        normalized = output:gsub("%s+", " ")
        command_tail = assert(normalized:match(
            "%-%-lua%-name titan%.uv uv (.+)$"), normalized)
        assert.truthy(command_tail:find(
            "-X titan-runtime/titan_uv.o", 1, true), command_tail)
        assert.falsy(command_tail:find("libuv-build/libuv.a", 1, true),
            command_tail)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -I/opt/libuv/include -DUV_FAKE_PKG=1 -D_GNU_SOURCE']],
            1, true), normalized)
        assert.truthy(normalized:find(
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -L/opt/libuv/lib -luv -pthread -ldl -lrt']],
            1, true), normalized)
    end)

    it("builds timer from binary uv without another libuv input", function()
        for _, mode in ipairs({ "bundled", "system" }) do
            local ok, output, why, code = run_timer_dry_run(mode)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local normalized = output:gsub("%s+", " ")
            local marker = "--lua-name titan.timer timer"
            local marker_start = assert(normalized:find(marker, 1, true),
                normalized)
            local prefix = normalized:sub(1, marker_start)
            local command_start = assert(prefix:match(".*()CC="), normalized)
            local command = normalized:sub(command_start,
                marker_start + #marker - 1)

            assert.truthy(command:find([[CC='ccache cc']], 1, true), command)
            assert.truthy(command:find(
                [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1']], 1, true), command)
            assert.truthy(command:find(
                [[TITAN_EXTRA_CFLAGS='-DUSER_C=1']], 1, true), command)
            assert.truthy(command:find(
                [[TITAN_EXTRA_LDFLAGS='-Wl,user-link']], 1, true), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            assert.falsy(command:find("libuv-build/libuv.a", 1, true),
                command)
            assert.falsy(command:find("-luv", 1, true), command)
            assert.falsy(command:find("-D_GNU_SOURCE", 1, true), command)
            assert.falsy(command:find("-fno-strict-aliasing", 1, true),
                command)
        end
    end)
end)
