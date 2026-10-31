-- Shared real-toolchain gate. Pure/synthesized browser specs do not use this.
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local installed_prefix = require "spec.support.installed_prefix"
local M = {}
local cached

local function absolute(strategy, filename)
    return platform.is_absolute(filename) and filename or
        paths.join(assert(strategy:cwd()), filename)
end

local function executable(strategy, filename)
    local attributes = strategy:stat(filename)
    return attributes and attributes.kind == "file" and
        strategy:executable(filename) == true
end

local function discover()
    if platform.windows then
        return nil, "browser builds are supported from Linux and macOS hosts"
    end
    local strategy = compiler_io.new_sync()
    local emsdk = os.getenv("EMSDK")
    local cc
    if emsdk and emsdk ~= "" then
        cc = absolute(strategy, paths.join(emsdk, "upstream/emscripten/emcc"))
        if not executable(strategy, cc) then
            return nil, "emcc not found at " .. string.format("%q", cc)
        end
    else
        for directory in ((os.getenv("PATH") or "") .. ":"):gmatch("(.-):") do
            local candidate = absolute(strategy, paths.join(directory == "" and "." or directory, "emcc"))
            if executable(strategy, candidate) then cc = candidate; break end
        end
        if not cc then return nil, "emcc not found (EMSDK unset; not on PATH)" end
    end
    local result = strategy:run({ cc, "--version" }, { stderr_to_stdout = true })
    local found = result and result.output and
        result.output:match("emcc[^\n]- (%d+%.%d+%.%d+)")
    if not result or not result.ok or found ~= "6.0.13" then
        return nil, string.format("%q reports Emscripten %s, expected 6.0.13", cc, found or "unknown")
    end
    local directory = paths.dirname(cc)
    local tools = { cc = { cc }, ar = { paths.join(directory, "emar") },
        ranlib = { paths.join(directory, "emranlib") },
        clang = { paths.join(paths.dirname(directory), "bin/clang") } }
    for name, argv in pairs(tools) do
        if not executable(strategy, argv[1]) then
            return nil, name .. " not found at " .. string.format("%q", argv[1])
        end
    end
    local prefix = installed_prefix.active()
    local base = paths.join(prefix, "lib/browser")
    for _, relative in ipairs({ "liblua.a", "liblua-config.txt", "include/lua.h",
            "include/luaconf.h", "include/lstate.h" }) do
        local filename = paths.join(base, relative)
        if not strategy:readable(filename) then
            return nil, "browser Lua prerequisite not readable: " .. string.format("%q", filename) ..
                "; run 'make install-browser PREFIX=" .. prefix .. "' in the Lua fork"
        end
    end
    return { prefix = prefix, tools = tools,
        record_path = paths.join(base, "liblua-config.txt") }
end

function M.detect()
    -- A successful discovery can be reused; absence is not cached, so fake
    -- environment unit cases cannot poison a later installed-toolchain case.
    if cached then return cached end
    local info, reason = discover()
    if info then cached = info end
    return info, reason
end

function M.require()
    local info, reason = M.detect()
    if info then return info end
    reason = "browser toolchain unavailable: " .. tostring(reason)
    if os.getenv("TITAN_REQUIRE_BROWSER_TOOLCHAIN") == "1" then
        error(reason, 2)
    end
    return nil, reason
end

return M
