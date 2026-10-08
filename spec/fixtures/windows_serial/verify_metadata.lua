-- Usage: lua verify_metadata.lua <owned absolute parent>
assert(package.config:sub(1, 1) == "\\", "this test requires Windows")
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local lfs = require "lfs"
local strategy = compiler_io.new_sync()
local parent = assert(arg[1], "supply an existing writable fixture parent")
assert(paths.is_absolute(parent), "fixture parent must be absolute")
local files, directories = {}, {}

local function reserve(destination, directory)
    local path = assert(strategy:reserve_sibling(destination, directory))
    local owned = directory and directories or files
    owned[#owned + 1] = path
    return path
end

local function stat(path, follow)
    local result = assert(follow and strategy:stat(path) or strategy:lstat(path))
    local keys = {}
    for key in pairs(result) do keys[#keys + 1] = key end
    table.sort(keys)
    assert(table.concat(keys, ",") ==
        "kind,mode,modified_nanoseconds,modified_seconds,size")
    assert(result.device == nil and result.inode == nil)
    assert(result.size >= 0 and math.type(result.size) == "integer")
    assert(type(result.modified_seconds) == "number")
    assert(result.modified_nanoseconds == 0, "LFS timestamps are whole seconds")
    assert((result.mode & 0xf000) == ({
        file = 0x8000, directory = 0x4000, symlink = 0xa000,
    })[result.kind])
    return result
end

local function run()
    local root = reserve(paths.join(parent, "metadata-gate"), true)
    assert(stat(root, true).kind == "directory")
    local unicode = paths.join(root, "unicode-\u{03bb}-\u{1f600}")
    assert(strategy:mkdir(unicode))
    directories[#directories + 1] = unicode
    local a = reserve(paths.join(unicode, "a.bin"))
    local b = reserve(paths.join(unicode, "b.bin"))
    local binary = "A\0B\r\n\255"
    assert(strategy:write_file(a, binary))
    assert(strategy:write_file(b, "second"))
    assert(stat(a, true).size == #binary and stat(b, true).size == 6)
    assert(stat(a, false).kind == "file")
    assert(strategy:read_file(a) == binary)
    assert(strategy:realpath(a) == paths.normalize(a))
    local dotted = paths.join(unicode, "..", paths.basename(unicode), paths.basename(a))
    assert(strategy:realpath(dotted) == paths.normalize(a))
    assert(strategy:realpath(unicode) == paths.normalize(unicode))

    local renamed = reserve(paths.join(unicode, "renamed.bin"))
    assert(strategy:rename(a, renamed))
    assert(strategy:read_file(renamed) == binary)
    assert(strategy:stat(a) == nil)
    assert(strategy:rename(b, a))
    assert(strategy:read_file(a) == "second")
    assert(strategy:stat(b) == nil)
    local missing = paths.join(root, "not-created.bin")
    local absent, absent_error = strategy:stat(missing)
    assert(absent == nil and absent_error == nil)
    local canonical, canonical_error = strategy:realpath(missing)
    assert(canonical == nil and type(canonical_error) == "string")
end

local okay, problem = xpcall(run, debug.traceback)
local cleanup_errors = {}
for index = #files, 1, -1 do
    if lfs.attributes(files[index]) then
        local removed, message = strategy:unlink(files[index])
        if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
    end
end
for index = #directories, 1, -1 do
    local removed, message = strategy:rmdir(directories[index])
    if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
end
assert(#cleanup_errors == 0, table.concat(cleanup_errors, "\n"))
assert(okay, problem)
print("Windows compiler I/O and LuaFileSystem metadata checks passed")
