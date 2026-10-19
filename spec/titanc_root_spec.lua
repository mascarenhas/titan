local argparse = require "argparse"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"

local EXIT = {}

local function query(arguments, cpath, environment, windows)
    local stdout, stderr = {}, {}
    local status = 0
    local query_driver = setmetatable({
        resolve_installation_root = driver.resolve_installation_root,
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
            getenv = function(name) return (environment or {})[name] end,
            windows = windows,
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
        require = function(name) return modules[name] or {} end,
        package = { cpath = cpath },
        io = { stdout = stream(stdout), stderr = stream(stderr) },
        os = { exit = function(code) status = code; error(EXIT, 0) end },
    }, { __index = _G })
    local previous_windows, previous_native = platform.windows, platform.native
    platform.windows = windows or false
    platform.native = function() error("root query loaded native support") end
    local ok, failure = pcall(assert(loadfile("titanc", "t", sandbox)))
    platform.windows, platform.native = previous_windows, previous_native
    if not ok then assert.equal(EXIT, failure) end
    return status, table.concat(stdout), table.concat(stderr)
end

describe("titanc installation root query", function()
    it("provides the standalone discovery root query", function()
        local status, stdout, stderr = query({ "--print-root" },
            "/SDK/lib/titan/0.6/?.so")
        assert.equal(0, status)
        assert.equal("/SDK\n", stdout)
        assert.equal("", stderr)
    end)

    it("prefers the current Titan SDK over the LuaRocks user tree", function()
        local status, stdout, stderr = query({ "--print-root" },
            "/home/dev/.luarocks/lib/lua/5.5/?.so;" ..
            "/SDK with spaces/lib/titan/0.6/?.so;" ..
            "/SDK with spaces/lib/lua/5.5/?.so")
        assert.equal(0, status)
        assert.equal("/SDK with spaces\n", stdout)
        assert.equal("", stderr)
    end)

    it("retains the installation override and ignores the probe-cache prefix",
    function()
        local status, stdout, stderr = query({ "--print-root" },
            "/SDK/lib/titan/0.6/?.so", {
                TITAN_ROCKS_ROOT = "/selected/SDK///",
                TITAN_PREFIX = "/unrelated/cache",
                TITAN_JOBS = "invalid",
            })
        assert.equal(0, status)
        assert.equal("/selected/SDK\n", stdout)
        assert.equal("", stderr)
        status, stdout = query({ "--print-root", "--jobs", "invalid" },
            "/SDK/lib/lua/5.5/?.so", {
                TITAN_ROCKS_ROOT = "", TITAN_PREFIX = "/unrelated/cache",
            })
        assert.equal(0, status)
        assert.equal("/SDK\n", stdout)
    end)

    it("reports a missing installation without stdout or compiler work", function()
        local status, stdout, stderr = query({ "--print-root" }, "./?.so")
        assert.equal(1, status)
        assert.equal("", stdout)
        assert.matches("cannot locate the Titan installation root", stderr, 1, true)
    end)

    it("rejects module names with the query and still requires build modules",
    function()
        for _, arguments in ipairs({ { "--print-root", "example" }, {} }) do
            local status, stdout, stderr = query(arguments,
                "/SDK/lib/titan/0.6/?.so")
            assert.equal(1, status)
            assert.equal("", stdout)
            assert.matches("module name", stderr, 1, true)
        end
    end)

    it("discovers Windows drive, UNC, and extended roots without native tools",
    function()
        for _, case in ipairs({
            { [[C:\SDK 雪\bin\..\lib\titan\0.6\?.dll]], "C:/SDK 雪" },
            { [[\\server\share\SDK\lib\lua\5.5\?.dll]], "//server/share/SDK" },
            { [[\\?\C:\SDK 雪\lib\titan\0.6\?.dll]], [[\\?\C:\SDK 雪]] },
            { [[C:\lib\lua\5.5\?.dll]], "C:/" },
        }) do
            local status, stdout, stderr = query({ "--print-root" },
                case[1], nil, true)
            assert.equal(0, status)
            assert.equal(case[2] .. "\n", stdout)
            assert.equal("", stderr)
        end
    end)
end)
