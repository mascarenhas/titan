-- Discover the standalone Titan prefix used by native integration specs.
-- Explicit test configuration wins; plain `luarocks test` falls back to the
-- active Lua's ordinary C-module path, which remains available even when
-- PREFIX and ROCKS_TREE are intentionally unset.
local M = {}

local LUA_CPATH_SUFFIX = "/lib/lua/5.5/?.so"

function M.from_cpath(cpath)
    for template in ((cpath or "") .. ";"):gmatch("(.-);") do
        if template:sub(-#LUA_CPATH_SUFFIX) == LUA_CPATH_SUFFIX then
            local root = template:sub(1,
                #template - #LUA_CPATH_SUFFIX)
            return root == "" and "/" or root:gsub("/+$", "")
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
    assert(root and root:sub(1, 1) == "/",
        "native Titan specs require an absolute PREFIX/TITAN_TEST_PREFIX " ..
        "or an active Lua package.cpath containing " .. LUA_CPATH_SUFFIX)
    if root ~= "/" then root = root:gsub("/+$", "") end
    return root
end

return M
