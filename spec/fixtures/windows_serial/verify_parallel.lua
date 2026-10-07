-- Native Windows compiler process adapter probe.
-- lua.exe verify_parallel.lua <argv-oracle.exe> <owned-parent>
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
package.path = "./?.lua;./?/init.lua;" .. package.path
local path = require "titan-compiler.path"
local lfs = require "lfs"
local process = require "titan-compiler.process"
local oracle, parent = assert(arg[1]), assert(arg[2])
local root = path.join(parent, "parallel probe 日本語 😀")
assert(lfs.mkdir(root), "probe workspace must be newly owned")
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
    batch.probes[index] = assert(batch:spawn(argv, out, err, index))
    return out, err
end
local function finish(batch, index, status)
    local ok, why, code = batch.probes[index]:wait()
    assert(why == "exit" and code == status, tostring(why) .. ":" .. tostring(code))
    assert((ok == true) == (status == 0), "exit success differs")
end
local function with_batch(body)
    local batch = assert(process.new_batch())
    batch.probes = {}
    local result = table.pack(pcall(body, batch))
    assert(batch:close())
    assert(result[1], result[2])
    return table.unpack(result, 2, result.n)
end
local function single(arguments, status)
    return with_batch(function(batch)
        local out, err = spawn(batch, 1, arguments)
        assert(batch:wait() == 1)
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
        assert(batch:wait() == 2, "completion waited in launch order")
        finish(batch, 2, 0)
        local file = assert(io.open(release, "wb")); assert(file:close())
        assert(batch:wait() == 1)
        finish(batch, 1, 0)
    end)
    print("native worker wait-any order 2,1 passed with two running processes")

end, debug.traceback)
collectgarbage("collect"); collectgarbage("collect")
for name in lfs.dir(root) do
    if name ~= "." and name ~= ".." then assert(os.remove(path.join(root, name))) end
end
assert(lfs.rmdir(root))
assert(passed, message)
print("Windows parallel worker oracle passed; maximum two native processes")
