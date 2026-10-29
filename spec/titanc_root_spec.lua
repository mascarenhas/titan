local argparse = require "argparse"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

local EXIT = {}

-- Run the checkout titanc script in a sandbox. `support` is the value of
-- `require "titan"`, or a string that require raises. The full command line
-- may use only the driver's root query, which returns `root, root_error`.
local function query(arguments, support, root, root_error)
    local stdout, stderr, required = {}, {}, {}
    local status = 0
    local query_driver = setmetatable({
        compiler_root = function() return root, root_error end,
    }, {
        __index = function(_, name)
            error("root query attempted compiler operation: " .. name)
        end,
    })
    local modules = {
        argparse = function(...)
            local parser = argparse(...)
            local parse = parser.parse
            parser.parse = function(self) return parse(self, arguments) end
            return parser
        end,
        ["titan-compiler.driver"] = query_driver,
        ["titan-compiler.platform"] = {
            getenv = function() return nil end,
            windows = false,
        },
    }
    local function stream(output)
        return { write = function(_, ...)
            for index = 1, select("#", ...) do
                output[#output + 1] = tostring(select(index, ...))
            end
        end }
    end
    local sandbox = setmetatable({
        require = function(name)
            required[#required + 1] = name
            if name == "titan" then
                if type(support) == "string" then error(support, 0) end
                return support
            end
            return modules[name] or {}
        end,
        io = { stdout = stream(stdout), stderr = stream(stderr) },
        os = { exit = function(code) status = code; error(EXIT, 0) end },
    }, { __index = _G })
    local ok, failure = pcall(assert(loadfile("titanc", "t", sandbox)),
        table.unpack(arguments))
    if not ok then assert.equal(EXIT, failure) end
    return status, table.concat(stdout), table.concat(stderr), required
end

local function support_root(root, root_error)
    return { _compiler_root = function() return root, root_error end }
end

describe("titanc installation root query", function()
    it("answers the exact root query from native support alone", function()
        local status, stdout, stderr, required = query({ "--print-root" },
            support_root("/SDK with spaces"))
        assert.equal(0, status)
        assert.equal("/SDK with spaces\n", stdout)
        assert.equal("", stderr)
        assert.same({ "titan" }, required)
    end)

    it("reports an unavailable root without stdout or compiler work", function()
        local status, stdout, stderr, required = query({ "--print-root" },
            support_root(nil, "cannot locate executable"))
        assert.equal(1, status)
        assert.equal("", stdout)
        assert.equal("cannot locate the Titan installation root: " ..
            "cannot locate executable\n", stderr)
        assert.same({ "titan" }, required)
    end)

    it("answers from the full command line when native support is unusable",
    function()
        for _, support in ipairs({ "module 'titan' not found", {} }) do
            local status, stdout, stderr, required = query({ "--print-root" },
                support, "/selected/SDK")
            assert.equal(0, status)
            assert.equal("/selected/SDK\n", stdout)
            assert.equal("", stderr)
            assert.truthy(table.concat(required, "\n"):find(
                "titan-compiler.driver", 1, true))

            status, stdout, stderr = query({ "--print-root" }, support,
                nil, "cannot load the Titan support module: missing")
            assert.equal(1, status)
            assert.equal("", stdout)
            assert.equal("cannot locate the Titan installation root: " ..
                "cannot load the Titan support module: missing\n", stderr)
        end
    end)

    it("validates every other spelling through the full command line",
    function()
        local support = support_root("/support/SDK")
        local status, stdout, stderr = query({ "--print-root", "-v" },
            support, "/selected/SDK")
        assert.equal(0, status)
        assert.equal("/selected/SDK\n", stdout)
        assert.equal("", stderr)

        status, stdout, stderr = query({ "--print-root", "-v" }, support,
            nil, "cannot load the Titan support module")
        assert.equal(1, status)
        assert.equal("", stdout)
        assert.matches("cannot locate the Titan installation root: " ..
            "cannot load the Titan support module", stderr, 1, true)

        for _, arguments in ipairs({ { "--print-root", "example" }, {} }) do
            status, stdout, stderr = query(arguments, support, "/selected/SDK")
            assert.equal(1, status)
            assert.equal("", stdout)
            assert.matches("module name", stderr, 1, true)
        end
    end)
end)

describe("titanc installation root in a process", function()
    local prefix = require("spec.support.installed_prefix").active()
    local lua = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")
    local forms = { { "--print-root" }, { "--print-root", "-v" } }

    -- Both forms must load the compiler and support selected by this run.
    -- `prelude` is Lua run before titanc; stderr is merged when requested.
    local function run_titanc(interpreter, arguments, environment, prelude,
                              merge_stderr)
        local argv = { platform.windows and "env.exe" or "env", "-u", "TITAN_ROOT",
            "LUA_PATH_5_5=" .. package.path, "LUA_CPATH_5_5=" .. package.cpath }
        for _, setting in ipairs(environment or {}) do argv[#argv + 1] = setting end
        argv[#argv + 1] = interpreter
        if prelude then
            argv[#argv + 1] = "-e"
            argv[#argv + 1] = prelude
        end
        argv[#argv + 1] = "titanc"
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        return compiler_io.new_sync():run(argv,
            { stderr_to_stdout = merge_stderr == true })
    end

    local function print_root(interpreter, arguments, environment, prelude)
        local result = run_titanc(interpreter, arguments, environment, prelude)
        assert.is_true(result.started and result.ok,
            result.output or result.diagnostic)
        local output = result.output:gsub("\r\n", "\n")
        if platform.windows then
            -- Native and driver spellings may differ only in separators.
            local root = assert(output:match("^(.-)\n$"), output)
            output = assert(driver.installed_paths(root)).root .. "\n"
        end
        return output
    end

    -- The expected spelling of an executable-derived root: the physical prefix.
    local function physical_root(directory)
        if platform.windows then return assert(driver.installed_paths(directory)).root end
        local previous = lfs.currentdir()
        assert(lfs.chdir(directory))
        local resolved = lfs.currentdir()
        assert(lfs.chdir(previous))
        return resolved
    end

    it("derives the root from the running interpreter when TITAN_ROOT is unset or empty",
    function()
        local expected = physical_root(prefix) .. "\n"
        for _, arguments in ipairs(forms) do
            assert.equal(expected, print_root(lua, arguments))
            assert.equal(expected, print_root(lua, arguments, { "TITAN_ROOT=" }))
        end
    end)

    it("prints a non-empty TITAN_ROOT in the driver's normalized form", function()
        for _, root in ipairs({ temporary.name(" selected SDK") .. "//", "spec" }) do
            local expected = assert(driver.installed_paths(root)).root .. "\n"
            for _, arguments in ipairs(forms) do
                assert.equal(expected,
                    print_root(lua, arguments, { "TITAN_ROOT=" .. root }))
            end
        end
    end)

    it("answers from the full command line when native support cannot load",
    function()
        local unloadable = "package.preload.titan = function() " ..
            "error('simulated missing support\\n\\tno file', 0) end"
        local root = temporary.name(" selected SDK")
        local expected = assert(driver.installed_paths(root)).root .. "\n"
        for _, arguments in ipairs(forms) do
            assert.equal(expected, print_root(lua, arguments,
                { "TITAN_ROOT=" .. root }, unloadable))
        end
        local result = run_titanc(lua, { "--print-root" }, nil, unloadable, true)
        assert.is_true(result.started, result.diagnostic)
        assert.is_false(result.ok)
        assert.equal("cannot locate the Titan installation root: " ..
            "cannot load the Titan support module: simulated missing support\n",
            (result.output:gsub("\r\n", "\n")))
    end)

    it("resolves a symlinked interpreter to its physical installation", function()
        if platform.windows then
            pending("POSIX symlinked interpreters; Windows resolves titanc.exe directly")
            return
        end
        local workspace = temporary.name(".interpreter")
        assert(lfs.mkdir(workspace))
        local alias = workspace .. "/lua"
        assert(lfs.link(lua, alias, true))
        local completed, failure = pcall(function()
            local expected = physical_root(prefix) .. "\n"
            for _, arguments in ipairs(forms) do
                assert.equal(expected, print_root(alias, arguments))
            end
        end)
        os.remove(alias)
        lfs.rmdir(workspace)
        assert.truthy(completed, failure)
    end)
end)
