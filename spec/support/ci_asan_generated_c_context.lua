local script = assert(arg[0]:match("^(.*)/[^/]+$"),
    "diagnostic script path must contain a directory")
local mapper = dofile(script .. "/asan_generated_c_context.lua")

local command = arg[1]
if command == "snapshot" and (#arg >= 4 and #arg <= 6) then
    local count, err = mapper.snapshot(arg[2], arg[3], arg[4], arg[5], arg[6])
    if not count then
        io.stderr:write("could not snapshot sanitizer artifacts: ", err, "\n")
        os.exit(1)
    end
    print(string.format("snapshotted %d generated C/object pairs", count))
elseif command == "report" and #arg == 3 then
    local report, err = mapper.report_logs(arg[2], arg[3])
    if not report then
        io.stderr:write("could not map sanitizer report: ", err, "\n")
        os.exit(1)
    end
    print(report)
else
    io.stderr:write("usage: ", arg[0],
        " snapshot <snapshot-dir> <provider> <generated-root> ",
        "[runtime-provider] [display-root]\n",
        "       ", arg[0], " report <log-dir-or-file> <snapshot-dir>\n")
    os.exit(2)
end
