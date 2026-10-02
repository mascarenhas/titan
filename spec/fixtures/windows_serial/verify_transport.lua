-- Run from the edited checkout with the controlled native Windows Lua:
-- lua.exe spec/fixtures/windows_serial/verify_transport.lua <oracle.exe> <workdir> <clang.exe>
-- The caller must create a disposable workdir and put a copy of the oracle
-- beneath a directory containing spaces and non-ACP Unicode characters.
-- This is a real Windows gate, not a host simulation or a Busted unit test.
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded.titan = require "winfs_test"
local platform = require "titan-compiler.platform"
local oracle = assert(arg[1], "argv oracle executable is required")
local workdir = assert(arg[2], "disposable work directory is required")
local clang = assert(arg[3], "selected native Clang executable is required")
local merged = "A\r\nB\0C\26D\255stderr"
local plain = "A\r\nB\0C\26D\255"

local function command(argv, merge)
    return assert(platform.windows_command(argv, merge))
end

local function capture(argv, merge)
    local pipe = assert(io.popen(command(argv, merge), "rb"))
    local output = assert(pipe:read("*a"))
    local ok, why, status = pipe:close()
    return output, ok, why, status
end

local function report(arguments)
    local lines = { tostring(#arguments) }
    for _, argument in ipairs(arguments) do
        lines[#lines + 1] = (argument:gsub(".", function(character)
            return string.format("%02x", string.byte(character))
        end))
    end
    return table.concat(lines, "\n") .. "\n"
end

local arguments = {
    "", "simple", "two words", "tab\tseparated", "ação-日本語-😀",
    'quote"inside', [[back\slash]], [[trailing\]], [[two trailing\\]],
    [[slashes-before-quote\\"]], "&|<>()^", "%PATH%", "!PATH!", "a'b",
    "[];,=*?`", [[C:\directory with spaces\]],
    [[-DSTRING="space & percent%NAME% !NAME!"]],
}
local argv = { oracle, "--argv" }
for _, value in ipairs(arguments) do argv[#argv + 1] = value end
local output, ok, why, status = capture(argv, true)
assert(ok == true and why == "exit" and status == 0,
    tostring(why) .. ":" .. tostring(status) .. "\n" .. output)
assert(output == report(arguments), "native argv report differs\n" .. output)

-- Executable path parsing has different shell/CRT rules from later arguments.
-- Exercise actual native files with shell metacharacters in their directory.
local lfs = require "lfs"
local odd_directory = workdir .. "/tools & (%PATH%) !PATH! ^"
assert(lfs.mkdir(odd_directory))
local copied_oracle = odd_directory .. "/native tool.exe"
local original = assert(io.open(oracle, "rb"))
local image = assert(original:read("a")); assert(original:close())
local copy = assert(io.open(copied_oracle, "wb"))
assert(copy:write(image)); assert(copy:close())
local captured, capture_error = pcall(function()
    for _, executable in ipairs({ copied_oracle, copied_oracle:sub(1, -5),
            (copied_oracle:gsub("/", "\\")) }) do
        local actual, succeeded = capture({ executable, "--argv", "path gate" }, true)
        assert(succeeded and actual == report({ "path gate" }), actual)
    end
end)
assert(os.remove(copied_oracle)); assert(lfs.rmdir(odd_directory))
assert(captured, capture_error)

-- Exercise os.execute independently of _popen, including an output filename
-- containing spaces and Unicode. No shell redirection handles this pathname.
local recorded = workdir .. "/recorded ação-日本語-😀.txt"
local record_args = { oracle, "--record", recorded }
for _, value in ipairs(arguments) do record_args[#record_args + 1] = value end
ok, why, status = os.execute(command(record_args, false))
assert(ok == true and why == "exit" and status == 0, "os.execute failed")
local file = assert(io.open(recorded, "rb"))
assert(file:read("*a") == report(arguments), "os.execute argv report differs")
assert(file:close())
assert(os.remove(recorded))

output, ok = capture({ oracle, "--bytes" }, true)
assert(ok == true and output == merged, "merged binary output differs")
output, ok = capture({ oracle, "--bytes" }, false)
assert(ok == true and output == plain, "stdout-only binary output differs")
output, ok = capture({ oracle, "--locale" }, true)
assert(ok == true and output == "C|C", "diagnostic locale differs")
for _, code in ipairs({ 1, 7, 126, 127, 143, 255, 9009 }) do
    output, ok, why, status = capture({ oracle, "--exit", tostring(code) }, true)
    assert(not ok and why == "exit" and status == code,
        "capture changed native exit " .. code .. " to " .. tostring(status))
    ok, why, status = os.execute(command({ oracle, "--exit", tostring(code) }, false))
    assert(not ok and why == "exit" and status == code,
        "execute changed native exit " .. code .. " to " .. tostring(status))
end
-- Distinguish lookup failures from real child exit codes at the public I/O seam.
local sync = require("titan-compiler.io").new_sync()
local cwd = assert(sync:cwd())
local drive_relative = cwd:sub(1, 2) .. "relative-name"
assert(platform.path.normalize(assert(sync:absolute(drive_relative))) ==
    platform.path.normalize(cwd .. "/relative-name"))
assert(platform.absolute(drive_relative, cwd, sync) == sync:absolute(drive_relative))
local injected, injected_error = platform.absolute(drive_relative, cwd, {})
assert(injected == nil and injected_error:find("per-drive", 1, true))
for _, code in ipairs({ 1, 126, 127, 9009 }) do
    local result = sync:run({ oracle, "--exit", tostring(code) })
    assert(result.started and not result.ok and result.status == code)
end
local result = sync:run({ workdir .. "/does-not-exist.exe" })
assert(not result.started and not result.ok and result.status == nil)
local directory = workdir .. "/directory.exe"
assert(lfs.mkdir(directory))
result = sync:run({ directory })
assert(lfs.rmdir(directory))
assert(not result.started and result.diagnostic:find("directory", 1, true))
local invalid = workdir .. "/invalid.exe"
local invalid_file = assert(io.open(invalid, "wb"))
assert(invalid_file:write("not an executable")); assert(invalid_file:close())
result = sync:run({ invalid })
assert(os.remove(invalid))
assert(not result.started and result.diagnostic:find("executable image", 1, true))
-- The caller can hold an owned copy open with FileShare.None. Lookup must
-- preserve that access failure instead of misreporting an absent executable.
if arg[4] then
    local lookup, lookup_error, lookup_code =
        package.loaded.titan._win_resolve_executable(arg[4])
    assert(lookup == nil and lookup_code == 32,
        tostring(lookup_code) .. ": " .. tostring(lookup_error))
end
local absent, absent_error = platform.windows_command({ workdir .. "/does-not-exist.exe" }, true)
assert(absent == nil and absent_error:find("Windows error 2", 1, true), absent_error)
local extended, extended_error = platform.windows_command({
    "\\\\?\\" .. oracle:gsub("/", "\\"), "--argv",
}, true)
assert(extended == nil and extended_error:find("extended executable paths are unsupported", 1, true))

output, ok, why, status = capture({ clang, "-dM", "-E", "-x", "c", "NUL" }, false)
assert(ok == true and output:find("#define _WIN32 1", 1, true),
    "Clang NUL macro probe failed: " .. tostring(status) .. "\n" .. output)
output, ok, why, status = capture({ clang, "-E", "-v", "-x", "c", "NUL", "-o", "NUL" }, true)
assert(ok == true and output:find("End of search list.", 1, true),
    "Clang NUL include probe failed: " .. tostring(status) .. "\n" .. output)
print("Windows serial transport oracle passed")
