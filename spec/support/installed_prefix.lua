-- Discover the standalone Titan prefix used by native integration specs.
-- Explicit test configuration wins; plain `luarocks test` falls back to the
-- active Lua's ordinary C-module path, which remains available even when
-- PREFIX and ROCKS_TREE are intentionally unset.
local M = {}
local platform = require "titan-compiler.platform"

local LUA_CPATH_SUFFIX = platform.windows and "/lib/lua/5.5/?.dll" or
    "/lib/lua/5.5/?.so"

local function normalize_root(root)
    if platform.windows then return platform.path.normalize(root) end
    return root == "/" and root or root:gsub("/+$", "")
end

function M.from_cpath(cpath)
    for template in ((cpath or "") .. ";"):gmatch("(.-);") do
        local normalized = platform.windows and template:gsub("\\", "/") or template
        local suffix = normalized:sub(-#LUA_CPATH_SUFFIX)
        if (platform.windows and suffix:lower() or suffix) == LUA_CPATH_SUFFIX then
            local root = template:sub(1,
                #template - #LUA_CPATH_SUFFIX + 1)
            -- Keep the directory separator: C:/ is an absolute drive root,
            -- while C: names that drive's current working directory.
            return normalize_root(root)
        end
    end
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
