local tmpname = os.tmpname
local paths = require "titan-compiler.path"

local M = {}

-- Fixture callers can remove this reservation before creating a directory.
-- Lua's Windows os.tmpname() only chooses a name; opening it gives fixture
-- callers a file reservation on both platforms. Forward slashes also keep the
-- resulting path usable in authored Titan foreign-import string literals.
-- A suffix requests an unused path instead, releasing the base reservation.
function M.name(suffix)
    local path = assert(tmpname())
    assert(assert(io.open(path, "wb")):close())
    path = paths.to_slash(path)
    if suffix then
        assert(os.remove(path))
        path = path .. suffix
    end
    return path
end

return M
