-- Historical issue #174 audit, tied to commit 641aade0 (PR #179). Issue #194
-- replaced the owners/factories measured below. Reproduce in a separate checkout
-- of that revision with its matching installed Lua/SDK, not a current provider.
-- The optional first
-- argument is a new output directory; --prepare-only just writes the replicas,
-- and --audit-only additionally checks existing generated C without compiling.
local lfs = require "lfs"
local cdriver = require "c-parser.cdriver"
local layout = require "titan-compiler.nominallayout"
local prefix = require("spec.support.installed_prefix").active()
local root = assert(lfs.currentdir())
local historical_runtime = io.open(root .. "/titan/uv/runtime.titan", "rb")
assert(historical_runtime,
    "historical allocation audit requires commit 641aade0 and its matching SDK; " ..
    "its pre-issue-194 owner factories are absent from this checkout")
historical_runtime:close()
local prepare_only = arg[1] == "--prepare-only"
local audit_only = arg[1] == "--audit-only"
local directory = arg[(prepare_only or audit_only) and 2 or 1]
if not directory then
    directory = os.tmpname()
    assert(os.remove(directory))
end
assert(directory:sub(1, 1) == "/", "use an absolute output directory")
assert(lfs.mkdir(directory), "output directory must not exist")

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("a"))
    assert(file:close())
    return contents
end
local function run(arguments)
    local quoted = {}
    for i, argument in ipairs(arguments) do
        quoted[i] = assert(cdriver.shell_quote(argument))
    end
    local command = table.concat(quoted, " ")
    local output = assert(io.popen(command .. " 2>&1", "r"))
    local result = assert(output:read("a"))
    local ok = output:close()
    assert(ok, command .. "\n" .. result)
    return result
end

-- These storage-only replicas retain native types, ownership and fresh-tail
-- construction. A value field stands for already-created traced collaborators.
-- Their counts are meaningful; their byte sizes are not whole-owner sizes.
local cases = {
    {"HTTP Parser", "titan.http.Parser", {"llhttp_t", "llhttp_settings_t"}},
    {"Filesystem request", "titan.uv.uv_fs_t", {"uv_fs_t"}},
    {"Stream write", "titan.uv.StreamWriteOwner", {"uv_write_t"}},
    {"DNS request", "titan.uv.uv_getaddrinfo_t", {"uv_getaddrinfo_t"}},
    {"Connect request", "titan.uv.uv_connect_t", {"uv_connect_t"}},
    {"Shutdown request", "titan.uv.uv_shutdown_t", {"uv_shutdown_t"}},
    {"One-shot timer", "titan.uv.TimerOwner", {"uv_timer_t"}},
    {"Repeating timer", "titan.uv.uv_timer_t", {"uv_timer_t"}},
    {"TCP handle", "titan.uv.uv_tcp_t", {"uv_tcp_t"}},
    {"Process handle", "titan.uv.uv_process_t", {"uv_process_t"}},
    {"Signal handle", "titan.uv.uv_signal_t", {"uv_signal_t"}},
    {"Runtime loop", "titan.uv.Runtime", {"uv_loop_t"}},
    {"Realpath request", "titan.fs.RealpathRequest", {"uv_fs_t"}},
    {"Filesystem watcher", "titan.fs.WatchRegistration", {"uv_fs_event_t"}},
    {"Pipe variant", "titan.uv.StdioNative", {"uv_pipe_t"}, variant = "pipe"},
    {"TTY variant", "titan.uv.StdioNative", {"uv_tty_t"}, variant = "tty"},
    {"Filesystem read request + buffer", "titan.uv.uv_fs_t", {"uv_fs_t"},
        tail = "char", count = 16},
    {"Spawn options + stdio", "titan.uv.uv_spawn_config", {"uv_process_options_t"},
        tail = "uv_stdio_container_t", count = 3},
}
local source = {
    'foreign import "uv.h"', 'foreign import "llhttp.h"',
    'foreign import "' .. root .. '/spec/fixtures/nominal_allocation_probe.h"',
    'foreign type AuditPointer = *void',
}
local runner = {
    'local probe = require "nominal_allocation_probe"',
    'print("| Storage group | Owned baseline | Embedded/fused |")',
    'print("| --- | ---: | ---: |")',
}
local function append(text) source[#source + 1] = text end
for index, item in ipairs(cases) do
    for _, mode in ipairs({"before", "after"}) do
        local name = "Owner" .. index .. mode
        local fields, arguments = {}, {}
        for position, native in ipairs(item[3]) do
            fields[#fields + 1] = (mode == "before" and "owned *" or "foreign ") .. native
            arguments[#arguments + 1] = "foreign " .. native .. ".new()"
        end
        if item.tail then
            fields[#fields + 1] = (mode == "before" and "owned " or "foreign ") .. item.tail .. "[]"
            arguments[#arguments + 1] = "foreign " .. item.tail .. ".new_array(" .. item.count .. ")"
        end
        local constructor
        if item.variant then
            append("local union " .. name .. "\n  item(" .. fields[1] .. ")\nend")
            constructor = name .. ".item(" .. arguments[1] .. ")"
        else
            local declaration = {"local record " .. name}
            for position, field in ipairs(fields) do
                declaration[#declaration + 1] = "  local const native" .. position .. ": " .. field
            end
            declaration[#declaration + 1] = "  local collaborator: value\nend"
            append(table.concat(declaration, "\n"))
            arguments[#arguments + 1] = "nil"
            constructor = name .. ".new(" .. table.concat(arguments, ", ") .. ")"
        end
        append("function measure" .. index .. mode .. "(): (value, integer)\n" ..
            "  ffi.nominal_probe_begin(L)\n  local owner = " .. constructor .. "\n" ..
            "  local count = ffi.nominal_probe_end(L)\n  return owner, count\nend")
    end
    local expected = #item[3] + (item.tail and 1 or 0) + 1
    runner[#runner + 1] = string.format([[
collectgarbage("collect")
local before, n_before = probe.measure%dbefore()
local after, n_after = probe.measure%dafter()
assert(before and after and n_before == %d and n_after == 1)
print("| %s | " .. n_before .. " | " .. n_after .. " |")
]], index, index, expected, item[1])
end
append([[
local record OldWorkCall
  local carrier: owned AuditPointer[]
end
local record OldWorkOwner
  local request: owned *uv_work_t
  local carrier: owned AuditPointer[]
  local callback: value
end
local record NewWorkCall
  local f: foreign AuditPointer
  local arg: foreign AuditPointer
end
local record NewWorkOwner
  local request: foreign uv_work_t
  local const carrier: foreign AuditPointer[]
  local callback: value
end
function work_before(): (value, value, integer)
  ffi.nominal_probe_begin(L)
  local call = OldWorkCall.new(foreign AuditPointer.new_array(3))
  local owner = OldWorkOwner.new(foreign uv_work_t.new(), call.carrier, nil)
  local count = ffi.nominal_probe_end(L)
  return call, owner, count
end
function work_after(): (value, value, integer)
  ffi.nominal_probe_begin(L)
  local call = NewWorkCall.new(nil, nil)
  local owner = NewWorkOwner.new(foreign uv_work_t.new(), foreign AuditPointer.new_array(3), nil)
  local count = ffi.nominal_probe_end(L)
  return call, owner, count
end
record NativeIntArray
  const length: integer
  local const array: foreign int[]
end
function NativeIntArray.make(len: integer): NativeIntArray
  return NativeIntArray.new(len, foreign int.new_array(len))
end
function native_array(len: integer): (value, integer, integer)
  ffi.nominal_probe_begin(L)
  local array = NativeIntArray.make(len)
  local count = ffi.nominal_probe_end(L)
  return array, count, ffi.nominal_probe_size()
end
]])
runner[#runner + 1] = [[
local old_call, old_owner, old_count = probe.work_before()
local new_call, new_owner, new_count = probe.work_after()
assert(old_call and old_owner and new_call and new_owner)
assert(old_count == 4 and new_count == 2)
print("| Work Call + carrier + owner + request | " .. old_count .. " | " .. new_count .. " |")
print("\n| NativeIntArray length | Allocations | Requested bytes | UV count |")
print("| ---: | ---: | ---: | ---: |")
for _, length in ipairs({0, 16, 1024}) do
    local array, count, bytes = probe.native_array(length)
    local _, has_uv = debug.getuservalue(array, 1)
    assert(array.length == length and count == 1 and not has_uv)
    print(("| %d | %d | %d | 0 |"):format(length, count, bytes))
end
]]
write(directory .. "/nominal_allocation_probe.titan", table.concat(source, "\n\n"))
write(directory .. "/run.lua", table.concat(runner, "\n"))
print("Probe directory: " .. directory)
if prepare_only then return end

local canonical = {
    ["titan.uv"] = "titan/uv/uv.c", ["titan.http"] = "titan/http/http.c",
    ["titan.fs"] = "titan/fs.c",
}
local canonical_bytes = {}
for module, path in pairs(canonical) do
    canonical_bytes[module] = read(path)
    write(directory .. "/" .. module .. ".canonical.c", canonical_bytes[module])
end
if not audit_only then
assert(lfs.chdir(directory))
write(directory .. "/compile.log", run({"env", "TITAN_RUNTIME_PREBUILT=1",
    "TITAN_PROBE_CACHE_DISABLE=1", "CCACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. prefix,
    "TITAN_EXTRA_CPPFLAGS=" .. (os.getenv("TITAN_EXTRA_CPPFLAGS") or "") .. " -D_GNU_SOURCE",
    prefix .. "/bin/titanc", "--tree", directory, "nominal_allocation_probe"}))
local generated = read(directory .. "/nominal_allocation_probe.c")
local signature = "nominal_allocation_probe_\\u2133_NativeIntArray_\\u2131_make_titanstatic("
local prototype = assert(generated:find(signature, 1, true))
local definition = assert(generated:find(signature, prototype + 1, true))
local body = assert(generated:match("%b{}", definition))
local _, allocations = body:gsub("luaS_newudata", "")
assert(allocations == 1 and not body:find("_backing", 1, true),
    "NativeIntArray.make must allocate only its final userdata")
write(directory .. "/native-array-c.txt", signature .. "...\n" .. body)
local measured = run({prefix .. "/bin/lua", "-E", directory .. "/run.lua"})
write(directory .. "/measurements.md", measured)
assert(lfs.chdir(root))
io.write(measured)
end

-- Retain the canonical generated payload declarations and native initialization
-- lines separately from replica measurements. No generated checkout file changes.
local function definition(bytes, symbol)
    local position = 1
    while true do
        local start = assert(bytes:find(symbol .. "(", position, true), symbol)
        local _, last = assert(bytes:find("%b()", start))
        local opening = bytes:find("%S", last + 1)
        if bytes:sub(opening, opening) == "{" then
            return assert(bytes:match("%b{}", opening)), start
        end
        position = last + 1
    end
end
local function pattern(text) return (text:gsub("([^%w])", "%%%1")) end
local uv_bytes = canonical_bytes["titan.uv"]
local tail_proofs = {}
for _, item in ipairs({
    {"filesystem-read", "new_fs_request_titan", "uv_5ffs_5ft", "char", "f1", 2},
    {"foreign-work", "WorkCall_\\u2131_dispatch_titanmethod", "WorkOwner", "WorkPointer", "f1", 1},
    {"spawn-stdio", "os_spawn_config_new_titan", "uv_5fspawn_5fconfig", "uv_stdio_container_t", "f2", 1},
}) do
    local symbol = "titan_uv_\\u2133_" .. item[2]
    local body, start = definition(uv_bytes, symbol)
    local cname = "_titan_nominal_titan_2euv_2e" .. item[3] .. "_payload"
    local size = assert(body:match("size_t%s+(_nominal_size_%d+)%s*=%s*sizeof%(" .. pattern(cname) .. "%)"))
    local _, allocation_sites = body:gsub("luaS_newudata", "")
    -- The filesystem factory has disjoint read/non-read returns, each with one
    -- owner. Work and spawn each have one path. Callback creation allocates
    -- CClosure, not userdata.
    assert(allocation_sites == item[6], item[1] .. ": extra storage allocation")
    assert(not body:find("_backing", 1, true), item[1] .. ": separate backing allocation")
    assert(body:find("sizeof(" .. item[4] .. ")", 1, true), item[1] .. ": no tail extent")
    local owner = assert(body:match("([%w_]+)%s*=%s*luaS_newudata%(L,%s*" .. size .. ","))
    local tail_line
    for line in body:gmatch("[^\n]+") do
        if line:find(cname, 1, true) and line:find("->" .. item[5] .. " =", 1, true)
            and line:find("+ _nominal_offset_", 1, true) then tail_line = line; break end
    end
    assert(tail_line, item[1] .. ": fresh tail pointer not installed in its owner")
    local receiver = assert(tail_line:match("getudatamem%(([%w_]+)%)"))
    local backing, offset = tail_line:match("getudatamem%(([%w_]+)%) %+ (_nominal_offset_%d+)")
    assert(receiver == owner and backing == owner, item[1] .. ": detached tail storage")
    assert(body:find(size .. " = " .. offset .. " + _nominal_bytes_", 1, true),
        item[1] .. ": tail extent excluded from final allocation")
    assert(body:find("memset(getudatamem(" .. owner .. "), 0, " .. size .. ");", 1, true))
    local _, line = uv_bytes:sub(1, start):gsub("\n", "")
    tail_proofs[#tail_proofs + 1] = canonical["titan.uv"] .. ":" .. (line + 1)
        .. " " .. symbol .. "\n" .. body
end
write(directory .. "/canonical-tail-factories.c.txt", table.concat(tail_proofs, "\n\n"))
local fixed_proofs = {}
for _, site in ipairs({
    {1, "new_parser_titan"}, {3, "submit_stream_write_titan"},
    {4, "GetaddrinfoCall_\\u2131_dispatch_titanmethod"},
    {5, "TcpConnectCall_\\u2131_dispatch_titanmethod"},
    {6, "TcpShutdownCall_\\u2131_dispatch_titanmethod"},
    {7, "start_timer_titan"}, {8, "start_ticker_titan"}, {9, "new_tcp_titan"},
    {10, "new_process_titan", 2}, -- Also constructs the existing ProcessExitResult.
    {11, "SignalWaitCall_\\u2131_dispatch_titanmethod"}, {12, "new_runtime_titan"},
    {13, "realpath_titan", 2}, -- Also constructs the existing ResumeToken.
    {14, "Watcher_\\u2131_new_registration_titanmethod"},
    {15, "new_pipe_stdio_titan"}, {16, "initialize_parent_stdio_titan"},
}) do
    local item = cases[site[1]]
    local module = item[2]:match("^(.*)%.[^.]+$")
    local symbol = module:gsub("%.", "_") .. "_\\u2133_" .. site[2]
    local bytes = canonical_bytes[module]
    local body, start = definition(bytes, symbol)
    local name = item[2] .. (item.variant and "." .. item.variant or "")
    local cname = assert(layout.record({_tag = "Type.Record", name = name,
        fields = {}, nfields = 0})).cname
    assert(body:find("= sizeof(" .. cname .. ");", 1, true), item[1] .. ": no direct owner allocation")
    local _, count = body:gsub("luaS_newudata", "")
    assert(count == (site[3] or 1), item[1] .. ": unexpected storage allocation")
    local _, line = bytes:sub(1, start):gsub("\n", "")
    fixed_proofs[#fixed_proofs + 1] = canonical[module] .. ":" .. (line + 1)
        .. " " .. symbol .. "\n" .. body
end
write(directory .. "/canonical-fixed-factories.c.txt", table.concat(fixed_proofs, "\n\n"))
local excerpts, seen = {}, {}
cases[#cases + 1] = {"Work owner", "titan.uv.WorkOwner", {"uv_work_t"}}
for _, item in ipairs(cases) do
    local module = item[2]:match("^(.*)%.[^.]+$")
    local path = canonical[module]
    local bytes = canonical_bytes[module]
    local name = item[2] .. (item.variant and "." .. item.variant or "")
    local cname = assert(layout.record({_tag = "Type.Record", name = name,
        fields = {}, nfields = 0})).cname
    if not seen[cname] then
        seen[cname] = true
        local close = assert(bytes:find("} " .. cname .. ";", 1, true), cname)
        local open, depth = close, 1
        repeat
            open = open - 1
            local char = bytes:sub(open, open)
            if char == "}" then depth = depth + 1 end
            if char == "{" then depth = depth - 1 end
        until depth == 0 or open == 0
        local declaration = bytes:sub(open, close + #cname + 2)
        for _, native in ipairs(item[3]) do
            assert(declaration:find(native .. " [fp]%d"), "missing embedded " .. native)
        end
        local _, line = bytes:sub(1, open):gsub("\n", "")
        excerpts[#excerpts + 1] = path .. ":" .. (line + 1) .. "\ntypedef struct " .. declaration
        local fixed = "luaS_newudata(L, sizeof(" .. cname .. "),"
        local allocation = assert(bytes:find(fixed, 1, true), "missing native allocation for " .. cname)
        local _, allocation_line = bytes:sub(1, allocation):gsub("\n", "")
        excerpts[#excerpts + 1] = path .. ":" .. (allocation_line + 1) .. ": " ..
            bytes:match("[^\n]+", allocation)
    end
end
for _, module in ipairs({"titan.uv", "titan.http", "titan.fs"}) do
    local path = canonical[module]
    local line = 0
    for text in canonical_bytes[module]:gmatch("[^\n]*\n") do
        line = line + 1
        local interior = text:find("= &", 1, true) and text:find("getudatamem", 1, true)
        local submission = text:match("uv_fs_[%w_]+%(") or text:match("uv_getaddrinfo%(")
            or text:match("uv_tcp_connect%(") or text:match("uv_shutdown%(")
            or text:match("uv_write%(") or text:match("uv_queue_work%(")
            or text:match("uv_spawn%(")
        if interior or submission or text:match("uv_[%w_]+_init%(") or text:match("llhttp_[%w_]*init%(") then
            excerpts[#excerpts + 1] = path .. ":" .. line .. ": " .. text:gsub("^%s+", "")
        end
    end
end
write(directory .. "/canonical-c.txt", table.concat(excerpts, "\n\n"))
print("Canonical generated-C evidence: " .. directory .. "/canonical-c.txt")
