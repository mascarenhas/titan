local temporary = require "spec.support.temporary"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local installed_prefix = require "spec.support.installed_prefix"
local platform = require "titan-compiler.platform"

local function append_flags(argv, name)
    local value = os.getenv(name)
    if value and value ~= "" then
        local flags, err = cdriver.split_shell_words(value)
        assert.truthy(flags, "cannot parse " .. name .. ": " .. tostring(err))
        for _, flag in ipairs(flags) do argv[#argv + 1] = flag end
    end
end

describe("closure transfer native ownership", function()
    it("cleans partial graphs and rebuilds rooted captures after origin retirement", function()
        local executable = assert(temporary.name()) .. "-transfer-runtime" ..
            (platform.windows and ".exe" or "")
        local prefix = installed_prefix.active()
        local io_client = compiler_io.new_sync()
        local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
        for _, flag in ipairs({
            "-std=c99", "-O0", "-fno-lto", "-g", "-Wall", "-Wextra", "-Werror",
            "-I.", "-Ititan-runtime", "-I" .. prefix .. "/src/lua-5.5.1",
        }) do argv[#argv + 1] = flag end
        append_flags(argv, "TITAN_TEST_EXTRA_CFLAGS")
        for _, flag in ipairs({
            "spec/fixtures/transfer_graph_runtime.c",
            prefix .. (platform.windows and "/lib/liblua55.a" or "/lib/liblua.a"),
            "-o", executable,
        }) do argv[#argv + 1] = flag end
        append_flags(argv, "TITAN_TEST_EXTRA_LDFLAGS")
        if not platform.windows then
            local host = io_client:run({ "uname", "-s" })
            assert.truthy(host.ok, host.output or host.diagnostic)
            argv[#argv + 1] = "-lm"
            if not host.output:find("Darwin", 1, true) then
                argv[#argv + 1] = "-ldl"
            end
            argv[#argv + 1] = "-pthread"
        end
        local compiled = io_client:run(argv)
        if not compiled.ok then
            os.remove(executable)
            assert.truthy(compiled.ok, compiled.output or compiled.diagnostic)
        end
        local result = io_client:run({ executable })
        os.remove(executable)
        assert.truthy(result.ok, result.output or result.diagnostic)
        assert.matches("closure transfer runtime ok", result.output, 1, true)
    end)
end)
