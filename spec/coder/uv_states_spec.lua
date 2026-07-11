local cdriver = require "c-parser.cdriver"
local phase2 = require "spec.support.phase2"

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

describe("uv Phase 2 multiple Lua states", function()
    local workspace
    local executable

    setup(function()
        workspace = phase2.workspace("two-states")
        executable = workspace .. "/two-states"

        local compiler, split_error = cdriver.split_shell_words(
            os.getenv("CC") or "cc")
        assert.truthy(compiler, split_error)
        local argv = { "env", "CCACHE_DISABLE=1" }
        append(argv, compiler)
        append(argv, {
            "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
            "-I", phase2.repo .. "/lua-5.5.0/src",
        })
        local sanitizer_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS")
        if sanitizer_cflags and #sanitizer_cflags > 0 then
            local flags, flags_error =
                cdriver.split_shell_words(sanitizer_cflags)
            assert.truthy(flags, flags_error)
            append(argv, flags)
        end
        append(argv, {
            phase2.repo .. "/spec/fixtures/uv/phase2/two_states.c",
            phase2.repo .. "/lua-5.5.0/src/liblua.a",
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
        local ok, _, output = phase2.run(shell_command(argv), workspace)
        assert.truthy(ok, output)
    end)

    teardown(function() phase2.cleanup(workspace) end)

    it("runs and closes co-resident states without Runtime or main-L bleed",
    function()
        local argv = {
            "env",
            "TITAN_STDLIB_PATH=" .. phase2.standard_dir(),
            "LUA_CPATH=" .. phase2.alias_template() .. ";;",
            executable,
        }
        local ok, status, output = phase2.run(shell_command(argv), workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match(
            "RESULT two Lua states kept independent uv Runtimes and main L values",
            output, 1, true)
    end)
end)
