-- Lower the whole-file string cap in an isolated fs.titan test variant so the
-- checked-growth guard can be exercised without allocating an enormous file.
local input_path, output_path = assert(arg[1]), assert(arg[2])

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local source = read(input_path)
local needle = "local MAX_STRING_BYTES = 9223372036854775807"
local first = assert(source:find(needle, 1, true),
    "missing whole-file size-limit test anchor")
assert(not source:find(needle, first + #needle, true),
    "duplicate whole-file size-limit test anchor")
source = source:sub(1, first - 1) ..
    "local MAX_STRING_BYTES = 131071 -- isolated test limit" ..
    source:sub(first + #needle)
write(output_path, source)
