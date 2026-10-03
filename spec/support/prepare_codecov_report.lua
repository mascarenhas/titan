-- Codecov's LuaCov reader recognizes only .lua/.lisp section filenames.
-- Give the extensionless CLI a report-only alias; .codecov.yml maps it back
-- to tracked titanc after the reader has recognized the section boundary.
-- Keep the original LuaCov report and every source line/count unchanged.
local input, output = arg[1], arg[2]
if not input or not output or arg[3] then
    io.stderr:write("usage: prepare_codecov_report.lua INPUT OUTPUT\n")
    os.exit(2)
end

local source <close> = assert(io.open(input, "rb"))
local contents = assert(source:read("a"))
local prepared, count = ("\n" .. contents):gsub(
    "(\n=+\r?\n)titanc(\r?\n=+\r?\n)", "%1titanc.lua%2")
assert(count == 1, "expected exactly one titanc section in LuaCov report")

local destination = assert(io.open(output, "wb"))
assert(destination:write(prepared:sub(2)))
assert(destination:close())
