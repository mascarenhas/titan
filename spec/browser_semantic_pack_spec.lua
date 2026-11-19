local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local installed_prefix = require "spec.support.installed_prefix"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"

describe("browser semantic pack transport", function()
    it("runs the offline Python release-pack regressions", function()
        local strategy = compiler_io.new_sync()
        local python = "python3"
        local prefix = installed_prefix.active()
        local directory = driver.installed_paths(prefix, "browser").titan_bin
        local semantic, stat_error = strategy:stat(path.join(directory, "analysis-target"))
        assert.is_nil(stat_error)
        if semantic then assert.equal("file", semantic.kind) end
        -- Compiler shards copy source without Git administration. A full
        -- producer test also needs local commit and submodule objects.
        local git = strategy:stat(".git")
        local full_sdk = semantic and git
        local skip_reason = semantic and "requires a Git root" or "requires a finished browser SDK"
        local argv, options = {}, { stderr_to_stdout = true }
        if platform.windows then
            options.env = { TITAN_PACK_TEST_PREFIX = full_sdk and prefix or false,
                TITAN_PACK_TEST_SKIP = skip_reason }
        else
            argv = { "env", "TITAN_PACK_TEST_PREFIX=" .. (full_sdk and prefix or ""),
                "TITAN_PACK_TEST_SKIP=" .. skip_reason }
        end
        for _, arg in ipairs({ python, "-B", "-m", "unittest", "discover",
                "-s", "spec", "-p", "browser_semantic_pack_test.py", "-v" }) do
            argv[#argv + 1] = arg
        end
        local result = strategy:run(argv, options)
        local output = result.output or result.diagnostic
        assert.is_true(result.ok, output)
        assert.truthy(output:find("Ran 4 tests", 1, true), output)
        assert.equal(not full_sdk, output:find(skip_reason, 1, true) ~= nil)
        io.stdout:write(output)
    end)
end)
