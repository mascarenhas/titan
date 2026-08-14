local lfs = require "lfs"

local source_inventory = {}

local function collect_lua_files(path, files)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local mode = assert(lfs.attributes(child, "mode"))
            if mode == "directory" then
                collect_lua_files(child, files)
            elseif mode == "file" and name:match("%.lua$") then
                files[#files + 1] = child
            end
        end
    end
end

function source_inventory.lua_files(path)
    local files = {}
    collect_lua_files(path, files)
    table.sort(files)
    return files
end

return source_inventory
