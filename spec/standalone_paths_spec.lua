local source = require "titan-compiler.standalone_paths"

local function initialize(environment, commands, windows, cpath)
    local registry, calls = {}, {}
    local package = { path = "original Lua path", cpath = cpath or "original C path",
        config = windows and "\\\n" or "/\n" }
    local sandbox = setmetatable({
        package = package,
        os = { getenv = function(name) return environment[name] end },
        debug = { getregistry = function() return registry end },
        io = { popen = function(command)
            calls[#calls + 1] = command
            local result = commands[#calls]
            if not result then return nil end
            return {
                read = function() return result[1] end,
                close = function() return result[2] end,
            }
        end },
    }, { __index = _G })
    assert(load(source, "@standalone_paths", "t", sandbox))(
        windows and "C:/application" or "/application", "0.6", "root", "path")
    return registry.root, package, calls, registry.path
end

describe("standalone path discovery", function()
    it("prefers titanc and accepts spaces and Unicode", function()
        local root, package, calls = initialize({}, { { "/SDK é with spaces\n", true } })
        assert.equal("/SDK é with spaces", root)
        assert.matches("/SDK é with spaces/share/lua/5.5/?.lua", package.path, 1, true)
        assert.matches("/SDK é with spaces/lib/titan/0.6/?.so", package.cpath, 1, true)
        assert.same({ "titanc --print-root 2>/dev/null" }, calls)
    end)

    it("falls back to Lua and prefers the current Titan tree over user Lua paths", function()
        local root, _, calls = initialize({}, { { "", false }, {
            "/user/lib/lua/5.5/?.so;/SDK/lib/titan/0.6/?.so", true } })
        assert.equal("/SDK", root)
        assert.equal('lua -e "io.write(package.cpath)" 2>/dev/null', calls[2])
    end)

    it("accepts a Lua-only tree and rejects suffix lookalikes", function()
        local root = initialize({}, { { "", false }, {
            "/bad/lib/titan/0.5/?.so;/bad/lib/lua/5.5/?.so.bad;/Lua/lib/lua/5.5/?.so", true } })
        assert.equal("/Lua", root)
    end)

    it("falls back to the executable directory on failed or malformed probes", function()
        for _, first in ipairs({ { "/bad", false }, { "relative", true },
                                { "/one\n/two", true }, { "", true } }) do
            local root, package = initialize({}, { first, { "./?.so", true } })
            assert.equal("/application", root)
            assert.matches("/application/share/lua/5.5/?.lua", package.path, 1, true)
        end
    end)

    it("preserves each explicit Lua path, including empty versioned values", function()
        for _, name in ipairs({ "LUA_PATH", "LUA_PATH_5_5" }) do
            local _, package = initialize({ [name] = "" }, { { "/SDK", true } })
            assert.equal("original Lua path", package.path)
            assert.matches("/SDK/lib/titan", package.cpath, 1, true)
        end
        for _, name in ipairs({ "LUA_CPATH", "LUA_CPATH_5_5" }) do
            local _, package = initialize({ [name] = "" }, { { "/SDK", true } })
            assert.equal("original C path", package.cpath)
        end
    end)

    it("keeps an explicit Lua C-path installation as the runtime root", function()
        local root, package = initialize({ LUA_CPATH_5_5 = "present" },
            { { "/discovered", true } }, false, "/explicit/lib/titan/0.6/?.so")
        assert.equal("/explicit", root)
        assert.equal("/explicit/lib/titan/0.6/?.so", package.cpath)
        assert.matches("/explicit/share/lua/5.5/?.lua", package.path, 1, true)
    end)

    it("does not probe when every path is explicit", function()
        for _, suffixes in ipairs({ { "", "", "" }, { "_5_5", "_5_5", "_0_6" } }) do
            local root, package, calls = initialize({
                ["LUA_PATH" .. suffixes[1]] = "",
                ["LUA_CPATH" .. suffixes[2]] = "",
                ["TITAN_PATH" .. suffixes[3]] = "",
            }, {})
            assert.is_nil(root)
            assert.equal("original Lua path", package.path)
            assert.equal("original C path", package.cpath)
            assert.same({}, calls)
        end
    end)

    it("retains the Windows launcher's adjacent provider tree", function()
        local root, package, _, path = initialize({}, {}, true)
        assert.equal("C:/application", root)
        assert.matches("C:/application/../lib/titan/0.6", path, 1, true)
        assert.matches(";original Lua path", package.path, 1, true)
        assert.matches(";original C path", package.cpath, 1, true)
    end)

    it("expands ;; in an explicit Windows Titan path to the launcher's default", function()
        local adjacent = "C:/application/../lib/titan/0.6"
        for _, name in ipairs({ "TITAN_PATH", "TITAN_PATH_0_6" }) do
            local root, _, _, path = initialize({ [name] = "C:/SDK/lib/titan/0.6;;" },
                { { "C:/SDK\r\n", true } }, true)
            assert.equal("C:/SDK", root)
            assert.equal("C:/SDK/lib/titan/0.6;.;C:/SDK/lib/titan/0.6;" ..
                adjacent .. ";", path)
        end
        -- The default is literal text, the versioned name wins even when empty,
        -- and a path without ";;" replaces the default.
        local _, _, _, path = initialize({ TITAN_PATH = ";;" },
            { { "C:/SDK %1", true } }, true)
        assert.equal(";.;C:/SDK %1/lib/titan/0.6;" .. adjacent .. ";", path)
        _, _, _, path = initialize({ TITAN_PATH_0_6 = "", TITAN_PATH = ";;" }, {}, true)
        assert.equal("", path)
        _, _, _, path = initialize({ TITAN_PATH = "C:/only" }, {}, true)
        assert.equal("C:/only", path)
    end)

    it("leaves Unix ;; expansion to the runtime's root-only default", function()
        local root, _, _, path = initialize({ TITAN_PATH_0_6 = "/extra;;" },
            { { "/SDK\n", true } })
        assert.equal("/SDK", root)
        assert.is_nil(path)
    end)

    it("discovers Windows trees with native separators and CRLF", function()
        local root, package = initialize({}, { { "", false }, {
            [[C:\SDK 雪\lib\titan\0.6\?.dll]] .. "\r\n", true } }, true)
        assert.equal("C:/SDK 雪", root)
        assert.matches("C:/SDK 雪/lib/titan/0.6/?.dll", package.cpath, 1, true)
        root = initialize({}, { { [[\\server\share\SDK]] .. "\r\n", true } }, true)
        assert.equal([[\\server\share\SDK]], root)
    end)
end)
