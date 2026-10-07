-- Discover the standalone Titan prefix used by native integration specs.
-- Explicit test configuration wins; plain `luarocks test` falls back to the
-- active Lua's Titan provider or ordinary C-module path, available even when
-- PREFIX and ROCKS_TREE are intentionally unset.
local M = {}
local platform = require "titan-compiler.platform"
local driver = require "titan-compiler.driver"

local LUA_CPATH_SUFFIX = platform.windows and "/lib/lua/5.5/?.dll" or
    "/lib/lua/5.5/?.so"

local function normalize_root(root)
    if platform.windows then return platform.path.normalize(root) end
    return root == "/" and root or root:gsub("/+$", "")
end

function M.from_cpath(cpath)
    local root = driver.root_from_package_cpath(cpath)
    return root and normalize_root(root)
end

function M.active()
    local root
    for _, variable in ipairs({ "PREFIX", "TITAN_TEST_PREFIX" }) do
        local value = os.getenv(variable)
        if value and value ~= "" then
            root = value
            break
        end
    end
    root = root or M.from_cpath(package.cpath)
    assert(root and platform.is_absolute(root),
        "native Titan specs require an absolute PREFIX/TITAN_TEST_PREFIX " ..
        "or an active Lua package.cpath containing " .. LUA_CPATH_SUFFIX)
    return normalize_root(root)
end

return M
