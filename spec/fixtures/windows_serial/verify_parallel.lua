-- Native-only private support probe. No installed SDK module is replaced.
-- lua.exe verify_parallel.lua <private-winfs-test.dll> <argv-oracle.exe> <owned-parent>
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
package.path = "./?.lua;./?/init.lua;" .. package.path
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"
local support = assert(package.loadlib(assert(arg[1]), "luaopen_winfs_test"))()
local oracle, parent = assert(arg[2]), assert(arg[3])
local root = path.join(parent, "parallel probe 日本語 😀")
assert(lfs.mkdir(root), "probe workspace must be newly owned")
local original_native = platform.native
platform.native = function(name, ...) return assert(support[name], name)(...) end
local next_log = 0
local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = assert(file:read("a")); assert(file:close()); return bytes
end
local function spawn(batch, index, arguments)
    next_log = next_log + 1
    local out = path.join(root, tostring(next_log) .. ".stdout")
    local err = path.join(root, tostring(next_log) .. ".stderr")
    local argv = { oracle }
    for _, value in ipairs(arguments) do argv[#argv + 1] = value end
    local command, executable = platform.windows_process_command(argv)
    assert(command, executable)
    assert(support._win_compile_spawn(batch, index, executable, command, out, err))
    return out, err
end
local function finish(batch, index, status)
    local ok, why, code = support._win_compile_finish(batch, index)
    assert(why == "exit" and code == status, tostring(why) .. ":" .. tostring(code))
    assert((ok == true) == (status == 0), "exit success differs")
end
local function with_batch(body)
    local batch = assert(support._win_compile_new())
    local result = table.pack(pcall(body, batch))
    assert(support._win_compile_close(batch))
    assert(result[1], result[2])
    return table.unpack(result, 2, result.n)
end
local function single(arguments, status)
    return with_batch(function(batch)
        local out, err = spawn(batch, 1, arguments)
        assert(support._win_compile_wait(batch) == 1)
        finish(batch, 1, status)
        return read(out), read(err)
    end)
end
local function report(arguments)
    local lines = { tostring(#arguments) }
    for _, value in ipairs(arguments) do
        lines[#lines + 1] = (value:gsub(".", function(byte)
            return string.format("%02x", byte:byte())
        end))
    end
    return table.concat(lines, "\n") .. "\n"
end
local passed, message = xpcall(function()
    local arguments = { "", "simple", "two words", "tab\tseparated", "ação-日本語-😀",
        'quote"inside', [[back\slash]], [[trailing\]], [[two trailing\\]],
        [[slashes-before-quote\\"]], "&|<>()^", "%PATH%", "!PATH!", "a'b",
        "[];,=*?`", [[C:\directory with spaces\]], [[-DSTRING="space & percent%NAME% !NAME!"]] }
    -- Direct CreateProcessW workers do not use cmd.exe's 8191-byte limit.
    arguments[#arguments + 1] = string.rep("x", 9000)
    local request = { "--argv" }
    for _, value in ipairs(arguments) do request[#request + 1] = value end
    local output, errors = single(request, 0)
    assert(output == report(arguments) and errors == "", "native CRT argv differs")
    output, errors = single({ "--bytes" }, 0)
    assert(output == "A\r\nB\0C\26D\255" and errors == "stderr", "binary streams differ")
    output, errors = single({ "--locale" }, 0)
    assert(output == "C|C" and errors == "", "compiler diagnostic locale differs")
    for _, status in ipairs({ 0, 1, 126, 127, 255, 256, 9009 }) do
        single({ "--exit", tostring(status) }, status)
    end
    print("native worker argv/binary/locale/exact exits passed (including 256/9009)")

    with_batch(function(batch)
        local release = path.join(root, "release first worker")
        spawn(batch, 1, { "--wait-file", release })
        spawn(batch, 2, { "--sleep", "10" })
        assert(support._win_compile_wait(batch) == 2, "completion waited in launch order")
        finish(batch, 2, 0)
        local file = assert(io.open(release, "wb")); assert(file:close())
        assert(support._win_compile_wait(batch) == 1)
        finish(batch, 1, 0)
    end)
    print("native worker wait-any order 2,1 passed with two running processes")

    with_batch(function(batch)
        for index = 1, 70 do
            spawn(batch, index, { "--exit", "0" })
            assert(support._win_compile_wait(batch) == index)
            -- Retain all 70 completed process/wait records until the end.
            -- At most one process is running; this tests the handle-count limit.
        end
        for index = 1, 70 do finish(batch, index, 0) end
    end)
    print("native worker 70 retained wait records passed (one running process)")

    for _, mode in ipairs({ "close", "gc" }) do
        local batch = assert(support._win_compile_new())
        local out = spawn(batch, 1, { "--spawn" })
        assert(support._win_compile_wait(batch) == 1)
        finish(batch, 1, 0)
        local pid = assert(read(out):match("^(%d+)\n$"), "missing owned descendant PID")
        single({ "--alive", pid }, 0)
        if mode == "close" then
            assert(support._win_compile_close(batch))
            assert(support._win_compile_close(batch), "close must be idempotent")
        else
            local weak = setmetatable({ batch }, { __mode = "v" })
            batch = nil
            collectgarbage("collect"); collectgarbage("collect")
            assert(weak[1] == nil, "batch was unexpectedly retained")
        end
        single({ "--alive", pid }, 1)
        print("native worker " .. mode .. " reaped owned descendant " .. pid)
    end
end, debug.traceback)
platform.native = original_native
collectgarbage("collect"); collectgarbage("collect")
for name in lfs.dir(root) do
    if name ~= "." and name ~= ".." then assert(os.remove(path.join(root, name))) end
end
assert(lfs.rmdir(root))
assert(passed, message)
print("Windows parallel worker oracle passed; maximum two native processes")
