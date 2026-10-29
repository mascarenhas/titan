-- Discover the standalone Titan prefix used by native integration specs.
-- Explicit test configuration wins; plain `luarocks test` falls back to the
-- active compiler root (TITAN_ROOT, else the parent of the running
-- interpreter's directory), available even when PREFIX and ROCKS_TREE are
-- intentionally unset.
local M = {}
local platform = require "titan-compiler.platform"
local driver = require "titan-compiler.driver"

local function normalize_root(root)
    if platform.windows then return platform.path.normalize(root) end
    return root == "/" and root or root:gsub("/+$", "")
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
    root = root or driver.compiler_root()
    assert(root and platform.is_absolute(root),
        "native Titan specs require an absolute PREFIX/TITAN_TEST_PREFIX " ..
        "or a Titan compiler root")
    return normalize_root(root)
end

return M
