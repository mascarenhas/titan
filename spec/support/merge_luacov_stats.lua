local stats = require "luacov.stats"

local output = arg[1]
if not output or not arg[2] then
    io.stderr:write("usage: merge_luacov_stats.lua OUTPUT INPUT...\n")
    os.exit(2)
end

local merged = {}
for index = 2, #arg do
    local input = arg[index]
    local current = stats.load(input)
    if not current or not next(current) then
        io.stderr:write("cannot load nonempty LuaCov stats file: " ..
            input .. "\n")
        os.exit(1)
    end
    for filename, source in pairs(current) do
        local destination = merged[filename]
        if not destination then
            destination = { max = 0, max_hits = 0 }
            merged[filename] = destination
        end
        destination.max = math.max(destination.max, source.max or 0)
        for line = 1, source.max or 0 do
            local hits = source[line] or 0
            destination[line] = (destination[line] or 0) + hits
            destination.max_hits = math.max(
                destination.max_hits, destination[line])
        end
    end
end

local temporary = output .. ".tmp"
local ok, err = pcall(stats.save, temporary, merged)
if not ok then
    os.remove(temporary)
    io.stderr:write("cannot save merged LuaCov stats: " .. tostring(err) .. "\n")
    os.exit(1)
end
local renamed, rename_error = os.rename(temporary, output)
if not renamed then
    os.remove(temporary)
    io.stderr:write("cannot publish merged LuaCov stats: " ..
        tostring(rename_error) .. "\n")
    os.exit(1)
end
