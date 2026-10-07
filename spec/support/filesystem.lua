local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

local M = {}

-- Symbolic-link creation through the host LuaFileSystem is a fixture capability,
-- not a compiler result. Callers mark only their individual case pending when
-- this probe fails and retain its concrete diagnostic without guessing a cause.
function M.symlink_capability()
    if not platform.windows then return true end
    local root = temporary.name()
    assert(os.remove(root))
    assert(lfs.mkdir(root))
    local target, link = root .. "/target.h", root .. "/link.h"
    local file = assert(io.open(target, "wb"))
    assert(file:write("/* symlink capability probe */\n"))
    assert(file:close())
    local linked, message = lfs.link(target, link, true)
    if linked then assert(os.remove(link)) end
    assert(os.remove(target))
    assert(lfs.rmdir(root))
    if not linked then
        return false, "Windows LuaFileSystem cannot create the required symbolic link: " .. tostring(message)
    end
    return true
end

return M
