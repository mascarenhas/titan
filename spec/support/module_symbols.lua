local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local objectmetadata = require "titan-compiler.objectmetadata"
local util = require "titan-compiler.util"

local M = {}

-- The source record, not the Make-facing companion or directory contents,
-- defines the complete ordered native input set for one logical module.
function M.collect(primary, run, nm)
    local bytes = assert(util.get_file_contents(primary))
    local entry = assert(objectmetadata.read(bytes, primary))
    local native = assert(entry.object_metadata)
    assert(objectmetadata.validate_parts(native))
    local stem = assert(primary:match("^(.*)[.]o$"))
    local objects, defined, undefined = {}, {}, {}
    nm = nm or assert(cdriver.split_shell_words(os.getenv("NM") or "nm"))
    run = run or function(argv)
        local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
        return result.ok, result.output or result.diagnostic
    end
    for _, part in ipairs(native.parts) do
        local object = stem .. part.object_suffix
        assert(lfs.symlinkattributes(object, "mode") == "file", object)
        objects[#objects + 1] = object
        for _, query in ipairs({ { "-U", defined }, { "-u", undefined } }) do
            local argv = { table.unpack(nm) }
            argv[#argv + 1], argv[#argv + 2] = query[1], object
            local ok, output = run(argv)
            assert(ok, output)
            for line in output:gmatch("[^\r\n]+") do
                local symbol = line:match("(%S+)%s*$")
                if symbol then query[2][symbol] = true end
            end
        end
    end
    for symbol in pairs(defined) do undefined[symbol] = nil end
    local function text(set, kind)
        local names = {}
        for symbol in pairs(set) do names[#names + 1] = kind .. " " .. symbol end
        table.sort(names)
        return table.concat(names, "\n")
    end
    return {
        objects = objects, defined = defined, undefined = undefined,
        defined_text = text(defined, "T"), undefined_text = text(undefined, "U"),
    }
end

return M
