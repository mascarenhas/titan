-- Remove only the sibling artifacts owned by a valid primary source record.
local source = assert(arg[0]):gsub("\\", "/")
local root = assert(source:match("^(.*)/spec/support/[^/]+$"))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local lfs = require "lfs"
local objectmetadata = require "titan-compiler.objectmetadata"

for path in io.read("a"):gmatch("([^%z]+)%z") do
    if lfs.symlinkattributes(path, "mode") == "file" then
        local file = io.open(path, "rb")
        if file then
            local bytes = file:read("a")
            file:close()
            local ok, entry = pcall(objectmetadata.read, bytes, path)
            local native = ok and entry and entry.object_metadata
            if native and objectmetadata.validate_parts(native) then
                local stem = assert(path:match("^(.*)[.]o$"))
                local outputs = {}
                for _, part in ipairs(native.parts) do
                    outputs[#outputs + 1] = stem .. part.c_suffix
                    outputs[#outputs + 1] = stem .. part.object_suffix
                end
                if native.private_header then
                    outputs[#outputs + 1] = stem .. native.private_header
                end
                -- Suffix validation above forbids paths outside this exact stem.
                for _, output in ipairs(outputs) do
                    local mode = lfs.symlinkattributes(output, "mode")
                    if mode == "file" or mode == "link" then
                        assert(os.remove(output))
                    end
                end
            end
        end
    end
end
