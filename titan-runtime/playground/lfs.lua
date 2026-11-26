-- The playground compiler has no host filesystem: its compiler I/O strategy
-- (titan-compiler/io.lua, new_memory) owns every file the compiler sees.
-- This stands in for LuaFileSystem in the modules that require it when they
-- load. Every query reports that the path does not exist; every change fails.
local ENOENT = 2

local function absent(path)
    return nil, tostring(path) .. ": No such file or directory", ENOENT
end

return {
    attributes = absent,
    symlinkattributes = absent,
    chdir = absent,
    mkdir = absent,
    rmdir = absent,
    touch = absent,
    currentdir = function() return "/" end,
    dir = function(path) error(tostring(path) .. ": No such file or directory", 2) end,
}
