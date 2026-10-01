-- Actual Windows module only. Usage:
-- lua winmeta_native_test.lua winmeta_test <owned parent> [C# fixture root]
assert(package.config:sub(1, 1) == "\\", "this test requires Windows")
local native = require(arg[1] or "winmeta_test")
local lfs = require "lfs"
local parent = assert(arg[2], "supply an existing, approved writable fixture parent")
local files, directories = {}, {}
local function reserve(destination, directory)
    local path = assert(native._win_reserve_sibling(destination, directory))
    local owned = directory and directories or files
    owned[#owned + 1] = path
    return path
end
local function same(a, b)
    return a.device == b.device and a.inode == b.inode
end
local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end
local function stat(path, follow)
    local result = assert(native._win_stat(path, follow))
    local keys = {}
    for key in pairs(result) do keys[#keys + 1] = key end
    table.sort(keys)
    assert(table.concat(keys, ",") ==
        "device,inode,kind,mode,modified_nanoseconds,modified_seconds,size")
    for _, key in ipairs({ "size", "mode", "modified_seconds", "modified_nanoseconds" }) do
        assert(math.type(result[key]) == "integer", key .. " lost integer representation")
    end
    assert(result.size >= 0)
    assert(result.modified_nanoseconds >= 0 and result.modified_nanoseconds < 1000000000)
    assert(result.modified_nanoseconds % 100 == 0)
    assert(result.mode == ({
        file = 0x8000, directory = 0x4000, symlink = 0xa000,
    })[result.kind], "mode contains invented permission bits")
    if result.device:match("^win32%-volume:") then
        assert(result.device:match("^win32%-volume:[0-9a-f]+$") and #result.device == 29)
        assert(result.inode:match("^win32%-file:[0-9a-f]+$") and #result.inode == 43)
    else
        assert(result.device:sub(1, 18) == "win32-volume-guid:")
        assert(result.device:sub(19, 29) == "\\\\?\\Volume{")
        assert(#result.device == 67 and result.device:sub(-2) == "}\\")
        assert(result.inode:match("^win32%-legacy%-file:[0-9a-f]+$") and #result.inode == 34)
    end
    return result
end
local function rejected(fn, expected_code, ...)
    local result, message, code = fn(...)
    assert(result == nil)
    assert(type(message) == "string" and #message > 0)
    assert(type(code) == "number" and code > 0)
    if expected_code then assert(code == expected_code, tostring(code)) end
end
local function run()
    local root = reserve(parent .. "/metadata-gate", true)
    local before = stat(root, true)
    assert(before.kind == "directory")
    local unicode = root .. "/unicode-\u{03bb}-\u{1f600}"
    assert(lfs.mkdir(unicode))
    directories[#directories + 1] = unicode
    local a = reserve(unicode .. "/a.bin")
    local b = reserve(unicode .. "/b.bin")
    write(a, "A\0B\r\n\255")
    write(b, "second")
    local ai, bi = stat(a, true), stat(b, true)
    assert(ai.size == 6 and bi.size == 6 and not same(ai, bi))
    assert(same(ai, stat(a, false)) and same(ai, stat(a, true)))
    local physical = assert(native._win_realpath(a))
    assert(physical:sub(1, 4) == "\\\\?\\", "helper discarded OS extended spelling")
    assert(same(ai, stat(physical, true)))
    assert(same(ai, stat((a:gsub("/", "\\")), true)))
    local final_root = assert(native._win_realpath(unicode))
    assert(same(stat(unicode, true), stat(final_root, true)))

    local renamed = reserve(unicode .. "/renamed.bin")
    assert(native._win_replace(a, renamed))
    assert(same(ai, stat(renamed, true)))
    local absent, _, absent_code = native._win_stat(a, true)
    assert(absent == nil and absent_code == 2)
    assert(native._win_replace(b, a))
    assert(same(bi, stat(a, true)) and not same(ai, stat(a, true)))
    rejected(native._win_stat, 2, root .. "/not-created.bin", true)
    rejected(native._win_realpath, 2, root .. "/not-created.bin")
    local missing_parent, missing_message, missing_code =
        native._win_stat(root .. "/not-created-parent/file.bin", true)
    assert(missing_parent == nil and type(missing_message) == "string")
    assert(missing_code == 2 or missing_code == 3)
    rejected(native._win_stat, 87, a, nil)
    rejected(native._win_stat, 87, a, "follow")
    rejected(native._win_stat, 123, "bad\0path", true)
    rejected(native._win_stat, 1113, "bad\255path", true)
    rejected(native._win_realpath, 123, "bad\0path")
    rejected(native._win_realpath, 1113, "bad\255path")

    -- Repeated actual queries exercise close paths; this is not a handle-count
    -- or allocator-failure proof, which requires a separate native harness.
    for _ = 1, 128 do
        assert(same(ai, stat(renamed, true)))
        assert(native._win_realpath(renamed))
    end

    -- Optional existing C# fixture is read-only. It carries exact timestamp
    -- and large sparse-file values that ordinary Lua APIs cannot establish.
    if arg[3] then
        local fixture = arg[3]
        local original = stat(fixture .. "/renamed.bin", true)
        local other = stat(fixture .. "/Alpha-\u{e9}-\u{96ea}.bin", true)
        assert(not same(original, other))
        assert(original.modified_seconds == 1790816523 and
               original.modified_nanoseconds == 123456700)
        assert(other.modified_seconds == original.modified_seconds and
               other.modified_nanoseconds == original.modified_nanoseconds)
        if original.device:match("^win32%-volume:") then
            assert(stat(fixture .. "/large-sparse.bin", true).size == 4294967419)
            assert(same(original, stat(fixture .. "/hardlink.bin", true)))
            local link = stat(fixture .. "/junction", false)
            assert(link.kind == "symlink")
            local followed, message, code = native._win_stat(fixture .. "/junction", true)
            if followed then
                assert(not same(link, followed))
            else
                -- Error 448 is an accepted experimental environment limit,
                -- not a completed junction/retarget test.
                assert(type(code) == "number" and code > 0)
                assert(code == 448, tostring(message))
                io.stderr:write("Junction follow remains unverified: ", tostring(message), "\n")
            end
        else
            io.stderr:write("VirtIO-FS fixture has no proven sparse, hardlink, or junction gate\n")
        end
    end
end

local okay, problem = xpcall(run, debug.traceback)
local cleanup_errors = {}
for index = #files, 1, -1 do
    if lfs.attributes(files[index]) then
        local removed, message = os.remove(files[index])
        if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
    end
end
for index = #directories, 1, -1 do
    local removed, message = lfs.rmdir(directories[index])
    if not removed then cleanup_errors[#cleanup_errors + 1] = tostring(message) end
end
assert(#cleanup_errors == 0, table.concat(cleanup_errors, "\n"))
assert(okay, problem)
print("Windows native metadata helper checks passed; optional limitations are reported separately")
