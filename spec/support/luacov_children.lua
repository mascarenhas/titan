-- Real CLI tests use private copies of the frontend. Collect those processes
-- explicitly, then add their verified source identities to the live parent
-- runner. Writing the parent's stats file here would race its exit-time save.
local lfs = require "lfs"

local M = {}

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("a"))
    assert(file:close())
    return contents
end

local function source_key(path)
    return path:gsub("^%.[/\\]", ""):gsub("\\", "/")
end

local function literal_pattern(path)
    return "^" .. source_key(path):gsub("%.lua$", ""):gsub("(%W)", "%%%1") .. "$"
end

local ordinary = {}
function ordinary:init_code() return "" end
function ordinary:collect() return 0 end

function M.new(root, frontend, directory)
    local runner = package.loaded["luacov.runner"]
    if not runner or not runner.initialized then return ordinary end

    local enrolled, includes = {}, {}
    local function enroll(relative, parent)
        local original, copied = root .. "/" .. relative, frontend .. "/" .. relative
        local identity = { original = original, copied = copied, parent = parent,
            bytes = read(original) }
        enrolled[source_key(copied)] = identity
        includes[#includes + 1] = literal_pattern(copied)
    end
    local function modules(relative)
        for entry in lfs.dir(root .. "/" .. relative) do
            if entry ~= "." and entry ~= ".." then
                local path = relative .. "/" .. entry
                if lfs.attributes(root .. "/" .. path, "mode") == "directory" then
                    modules(path)
                elseif path:match("%.lua$") then
                    local name = path:gsub("%.lua$", ""):gsub("/", ".")
                    enroll(path, assert(package.searchpath(name, package.path)))
                end
            end
        end
    end
    modules("titan-compiler")
    -- Other CLI specs load the tracked script as @titanc. It is not a module
    -- resolved through package.path, so enroll that one exact name explicitly.
    enroll("titanc", "titanc")
    assert(lfs.mkdir(directory))

    local collector, collected = {}, {}
    local function verify()
        for _, identity in pairs(enrolled) do
            assert(read(identity.original) == identity.bytes,
                "tracked frontend changed during child coverage: " .. identity.original)
            assert(read(identity.copied) == identity.bytes,
                "copied frontend differs from tracked source: " .. identity.copied)
            local parent = identity.parent == "titanc" and root .. "/titanc" or identity.parent
            assert(read(parent) == identity.bytes,
                "parent frontend differs from tracked source: " .. parent)
        end
    end

    function collector:init_code()
        verify()
        local patterns = {}
        for _, pattern in ipairs(includes) do patterns[#patterns + 1] = string.format("%q", pattern) end
        -- Make invokes its compiler wrapper repeatedly. Atomic mkdir gives
        -- each invocation a separate file even if object jobs run in parallel.
        return "do local lfs = require 'lfs'; local base = " .. string.format("%q", directory)
            .. "; local number = 1; local child; while true do "
            .. "child = base .. '/child-' .. number; if lfs.mkdir(child) then break end; "
            .. "assert(lfs.attributes(child, 'mode') == 'directory', 'cannot create child LuaCov directory'); "
            .. "number = number + 1 end; require('luacov.runner').init({statsfile = child "
            .. ".. '/luacov.stats.out', include = {" .. table.concat(patterns, ",")
            .. "}, runreport = false, tick = false}) end"
    end

    function collector:collect()
        verify()
        local count = 0
        for entry in lfs.dir(directory) do
            if entry ~= "." and entry ~= ".." then
                assert(entry:match("^child%-%d+$"), "unexpected child LuaCov directory: " .. entry)
                local path = directory .. "/" .. entry .. "/luacov.stats.out"
                local contents = read(path)
                if collected[path] then
                    assert(collected[path] == contents, "collected child LuaCov stats changed: " .. path)
                else
                    local data = assert(require("luacov.stats").load(path))
                    assert(next(data), "child LuaCov stats are empty: " .. path)
                    for filename, extra in pairs(data) do
                        local identity = assert(enrolled[source_key(filename)],
                            "unenrolled child LuaCov source: " .. filename)
                        local key = source_key(identity.parent)
                        local destination = runner.data[key]
                        if not destination then
                            destination = { max = 0, max_hits = 0 }
                            runner.data[key] = destination
                        end
                        runner.update_stats(destination, extra)
                    end
                    collected[path], count = contents, count + 1
                end
            end
        end
        return count
    end

    return collector
end

return M
