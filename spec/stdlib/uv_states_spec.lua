local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local function shell_command(argv)
    local quoted = {}
    for index, word in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(word))
    end
    return table.concat(quoted, " ")
end

local function append(destination, source)
    for _, value in ipairs(source) do destination[#destination + 1] = value end
end

describe("uv multiple Lua states", function()
    local workspace
    local executable

    setup(function()
        workspace = async_stdlib.workspace("two-states")
        executable = workspace .. "/two-states"

        local compiler, split_error = cdriver.split_shell_words(
            os.getenv("CC") or "cc")
        assert.truthy(compiler, split_error)
        local argv = { "env", "CCACHE_DISABLE=1" }
        append(argv, compiler)
        append(argv, {
            "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
            "-I", async_stdlib.repo .. "/lua-5.5.0/src",
        })
        local sanitizer_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS")
        if sanitizer_cflags and #sanitizer_cflags > 0 then
            local flags, flags_error =
                cdriver.split_shell_words(sanitizer_cflags)
            assert.truthy(flags, flags_error)
            append(argv, flags)
        end
        append(argv, {
            async_stdlib.repo ..
                "/spec/fixtures/stdlib/native/two_states.c",
            async_stdlib.repo .. "/lua-5.5.0/src/liblua.a",
            "-ldl", "-lm",
        })
        local sanitizer_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS")
        if sanitizer_ldflags and #sanitizer_ldflags > 0 then
            local flags, flags_error =
                cdriver.split_shell_words(sanitizer_ldflags)
            assert.truthy(flags, flags_error)
            append(argv, flags)
        end
        append(argv, { "-o", executable })
        local ok, _, output = async_stdlib.run(shell_command(argv), workspace)
        assert.truthy(ok, output)
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("runs and closes co-resident states without Runtime or main-L bleed",
    function()
        local layout = async_stdlib.standard_layout()
        local argv = {
            "env",
            "-u", "LUA_PATH",
            "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH_5_5",
            "TITAN_PATH_0_16=" .. layout.abi_root,
            "TITAN_PATH=",
            "LUA_PATH=" .. async_stdlib.canonical_lua_path(layout) .. ";" ..
                async_stdlib.repo .. "/?.lua;" ..
                async_stdlib.repo .. "/?/init.lua;;",
            "LUA_PATH_5_5=" ..
                async_stdlib.canonical_lua_path(layout) .. ";" ..
                async_stdlib.repo .. "/?.lua;" ..
                async_stdlib.repo .. "/?/init.lua;;",
            "LUA_CPATH=" .. async_stdlib.canonical_cpath(layout) .. ";;",
            "LUA_CPATH_5_5=" .. async_stdlib.canonical_cpath(layout) .. ";;",
            executable,
        }
        local ok, status, output = async_stdlib.run(shell_command(argv), workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
