local path, search_error = package.searchpath("titan.uv", package.cpath)
if not path then error(search_error, 0) end

local loaded, load_error = package.loadlib(path, "*")
if not loaded then error(load_error, 0) end

local open, open_error = package.loadlib(path, "luaopen_titan_uv")
if not open then error(open_error, 0) end

return open()
