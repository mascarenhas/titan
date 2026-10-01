-- Run on Windows with the actual helper, never a simulated Windows backend.
-- argv[1] optionally selects another module (for example "titan").
-- argv[2] optionally selects the existing writable test workspace.
-- argv[3] optionally selects a writable directory on another volume.
assert(package.config:sub(1, 1) == "\\", "this test requires Windows")
local native = require(arg[1] or "winfs_test")
local lfs = require "lfs"
local files, directories = {}, {}

local function reserve(destination, directory)
    local path, message, code = native._win_reserve_sibling(destination, directory)
    assert(path, tostring(message) .. " (" .. tostring(code) .. ")")
    local owned = directory and directories or files
    owned[#owned + 1] = path
    assert(lfs.attributes(path, "mode") == (directory and "directory" or "file"))
    return path
end

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local bytes = assert(file:read("a"))
    assert(file:close())
    return bytes
end

local function rejects(fn, ...)
    local result, message, code = fn(...)
    assert(result == nil)
    assert(type(message) == "string" and #message > 0)
    assert(type(code) == "number" and code > 0)
end

local function run()
    local temporary = assert(native._win_tmpname())
    files[#files + 1] = temporary
    assert(lfs.attributes(temporary, "mode") == "file")
    assert(lfs.attributes(temporary, "size") == 0)
    write(temporary, "A\0B\r\n")
    assert(read(temporary) == "A\0B\r\n")

    local parent_target = arg[2] and (arg[2] .. "/titan-winfs-oracle")
        or (temporary .. ".stage")
    local root = reserve(parent_target, true)
    local unicode = root .. "/unicode-\u{03bb}-\u{1f600}"
    assert(lfs.mkdir(unicode))
    directories[#directories + 1] = unicode
    local destination = unicode .. "/result-\u{65e5}\u{672c}.bin"
    files[#files + 1] = destination
    write(destination, "original")

    -- Distinct live reservations, directly inside the requested directory.
    local seen = {}
    for _ = 1, 64 do
        local path = reserve(destination)
        assert(path:match("^(.*)[/\\]") == unicode)
        assert(not seen[path], "duplicate live reservation")
        seen[path] = true
    end

    for index = 1, 3 do
        local source = reserve(destination)
        local bytes = "replacement " .. index .. "\0\r\n"
        write(source, bytes)
        assert(native._win_replace(source, destination))
        assert(lfs.attributes(source) == nil)
        assert(read(destination) == bytes)
    end

    -- Absent source and invalid input preserve existing destination bytes.
    local before = read(destination)
    rejects(native._win_replace, root .. "/never-created", destination)
    assert(read(destination) == before)
    rejects(native._win_replace, destination .. "\0hidden", destination)
    assert(read(destination) == before)

    -- Replacing an existing directory must fail without removing either side.
    local source = reserve(destination)
    write(source, "keep source")
    local blocked = reserve(destination, true)
    rejects(native._win_replace, source, blocked)
    assert(read(source) == "keep source")
    assert(lfs.attributes(blocked, "mode") == "directory")

    -- Missing parent must not be created or redirected to another directory.
    rejects(native._win_reserve_sibling, root .. "/absent/output.bin")
    rejects(native._win_reserve_sibling, "")
    rejects(native._win_reserve_sibling, "bad\0path")
    rejects(native._win_reserve_sibling, "bad\255path")
    rejects(native._win_reserve_sibling, root .. "/")
    rejects(native._win_reserve_sibling, 123)
    rejects(native._win_reserve_sibling, destination, "directory")
    rejects(native._win_replace, "bad\255path", destination)
    rejects(native._win_replace, destination, "bad\255path")
    assert(read(destination) == before)

    -- Both separator spellings and a basename relative to cwd are supported.
    local backslash = reserve((destination:gsub("/", "\\")))
    assert(backslash:find("\\", 1, true))
    local old_cwd = assert(lfs.currentdir())
    assert(lfs.chdir(unicode))
    local okay, problem = pcall(function()
        local path = assert(native._win_reserve_sibling("relative.bin"))
        files[#files + 1] = unicode .. "/" .. path
        assert(not path:find("[/\\]"))
        assert(lfs.attributes(path, "mode") == "file")
    end)
    assert(lfs.chdir(old_cwd))
    assert(okay, problem)

    -- Optional argv[3] is an existing writable directory on ANOTHER volume.
    -- Both paths are this test's own exclusive reservations.
    if arg[3] then
        local other = reserve(arg[3] .. "/cross-volume-target.bin")
        write(other, "other volume original")
        local source = reserve(destination)
        write(source, "cross-volume source")
        rejects(native._win_replace, source, other)
        assert(read(source) == "cross-volume source")
        assert(read(other) == "other volume original")
    end
end

local okay, problem = xpcall(run, debug.traceback)
local cleanup_errors = {}
for index = #files, 1, -1 do
    local path = files[index]
    if lfs.attributes(path) then
        local removed, message = os.remove(path)
        if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
    end
end
for index = #directories, 1, -1 do
    local removed, message = lfs.rmdir(directories[index])
    if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
end
assert(#cleanup_errors == 0, table.concat(cleanup_errors, "\n"))
assert(okay, problem)
print("Windows native filesystem helper tests passed")
