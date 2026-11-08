-- Build only: the same staged gate is consumed by Node and all page engines.
local lfs = require "lfs"
local process = require "titan-compiler.process"
local path = require "titan-compiler.path"
local repository = assert(lfs.currentdir())
local output = assert(arg[1], "usage: lua -E spec/browser/build-trace.lua OUTPUT")
assert(not arg[2], "build-trace.lua accepts exactly one output directory")
if not path.is_absolute(output) then output = path.join(repository, output) end
local prefix = assert(os.getenv("TITAN_ROOT") or os.getenv("PREFIX"), "TITAN_ROOT or PREFIX is required")
local fixture = path.join(repository, "spec/fixtures/browser_trace")

local cases = {
  "test_direct_locations", "test_selected_contributor_locations",
  "test_mixed_merge_order", "test_lua_tail_call_marker", "test_method_entry",
  "test_bound_method_entry", "test_interface_entry", "test_bound_interface_entry",
  "test_static_entry", "test_callable_adjustment_entry", "test_lambda_entry",
  "test_immediate_literal_single_frame", "test_unmapped_adjacent_c_function",
  "test_bare_rethrow", "test_fresh_raise", "test_public_backtrace_and_pin",
  "test_caught_trace_clearing", "test_defer_failure", "test_independent_lua_states",
  "test_state_close", "test_merge_allocation_limit", "test_nested_capture",
  "test_locations_before_after_yield", "test_coroutine_propagation_append",
  "test_recursion_beyond_ten", "test_recursion_near_capacity",
  "test_recursion_capacity_truncation", "test_mixed_recursion_headroom",
  "test_mixed_recursion_overflow", "test_pcall_recursion_overflow",
  -- Post-suspension traces in async Tasks (titan#334, tasks.browser.titan).
  "test_task_trace_after_turn", "test_task_trace_after_timer",
  "test_task_trace_after_request", "test_task_trace_after_channel",
  "test_delivered_handler_trace", "test_task_error_raise_handoff",
  "test_task_rethrow_and_fresh_raise_across_await", "test_task_coroutine_append",
  "test_task_cleanup_trace_during_cancellation",
}
-- Cases with their own rows rather than one row per case; the gate's
-- JavaScript calls the targets test_task_entry_targets publishes.
local special = { "test_host_capture_ready", "test_host_capture_failed", "test_host_lua_fallback_capacity",
  "test_degraded_map", "test_degraded_lua_capacity", "test_missing_symbols", "test_task_entry_targets" }
local function mkdir(directory)
  if lfs.attributes(directory, "mode") == "directory" then return end
  local parent = path.dirname(directory)
  if parent ~= directory and parent ~= "." then mkdir(parent) end
  assert(lfs.mkdir(directory))
end
local function read(file)
  local handle = assert(io.open(file, "rb")); local bytes = assert(handle:read("a")); assert(handle:close()); return bytes
end
local function write(file, bytes)
  mkdir(path.dirname(file)); local handle = assert(io.open(file, "wb")); assert(handle:write(bytes)); assert(handle:close())
end
local function json(value)
  if type(value) == "string" then
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
      return string.format('\\u%04x', c:byte())
    end) .. '"'
  elseif type(value) == "number" then return tostring(value)
  elseif type(value) == "boolean" then return value and "true" or "false"
  elseif type(value) == "table" then
    local rows = {}; for _, item in ipairs(value) do rows[#rows + 1] = json(item) end
    return "[" .. table.concat(rows, ",") .. "]"
  end
  error("unsupported manifest value")
end
local all = {}; for _, name in ipairs(cases) do all[#all + 1] = "trace_cases." .. name end
for _, name in ipairs(special) do all[#all + 1] = "trace_cases." .. name end
table.sort(all)
mkdir(output)
-- The installation profile decides what a program image's trace may show
-- (D21/D28). The gate builds and reports it; it never selects it.
local profile = os.getenv("TITAN_BUILD_PROFILE") or "production"
assert(profile == "production" or profile == "validation",
  "TITAN_BUILD_PROFILE must be production or validation")

for _, assertions in ipairs({2, 0}) do
  local root = path.join(output, "assertions-" .. assertions)
  mkdir(root)
  for _, target in ipairs({{name="runtime", owner="trace_cases", testing=true},
                           {name="uncaught", owner="trace_uncaught"},
                           -- Without --no-uv-bootstrap: main runs as the async
                           -- bootstrap Task (titan#334, D14).
                           {name="async", owner="trace_async", bootstrap=true}}) do
    -- LUA_INIT runs the *installed* compiler's ordinary CLI. The profile is
    -- the existing test-profile control; the link purpose distinguishes a
    -- test image from a program image. Discovery checks checked cases, never
    -- a source-text approximation.
    local init = path.join(root, "profile-" .. target.name .. ".lua")
    local expected = {}; for _, name in ipairs(all) do expected[#expected + 1] = string.format("%q", name) end
    write(init, string.format([[
package.path = %q .. ";" .. %q .. ";" .. package.path
local driver = require "titan-compiler.driver"
driver.browser_link_options = {purpose=%q, assertions=%d}
local runner = require "titan-compiler.test_runner"
local discover = runner.discover
runner.discover = function(...)
  local found, modules = discover(...)
  local expected = {%s}
  assert(#found == #expected, "trace fixture discovered " .. #found .. " cases; expected " .. #expected)
  for index, name in ipairs(expected) do
    assert(found[index].full_name == name, "missing trace fixture case " .. name)
  end
  io.stdout:write("TRACE-DISCOVERED " .. #found .. " native cases\n")
  return found, modules
end
]], path.join(prefix, "share/lua/5.5/?.lua"), path.join(prefix, "share/lua/5.5/?/init.lua"),
      target.testing and "test" or "program", assertions, table.concat(expected, ",")))
    local image = path.join(root, target.name .. ".mjs")
    local argv = {prefix .. "/bin/titanc", "-q", "--incremental", "--target", "browser",
      "--tree", fixture, "--output", path.join(root, "objects"),
      "--exe", image, "--c-source", path.join(fixture, "trace_support.c")}
    if not target.bootstrap then argv[#argv + 1] = "--no-uv-bootstrap" end
    if target.testing then argv[#argv + 1] = "--test" end
    argv[#argv + 1] = target.owner
    local result = process.capture(argv, {env = {
      TITAN_ROOT=prefix, TITAN_TARGET="", TITAN_PATH_0_6="",
      TITAN_EXTRA_CPPFLAGS="", TITAN_EXTRA_CFLAGS="", TITAN_EXTRA_LDFLAGS="",
      LUA_INIT_5_5="@" .. init, LUA_INIT="", CCACHE_DISABLE="1",
    }})
    io.stdout:write(result.output or result.diagnostic or ""); io.stdout:flush()
    assert(result.ok, "trace fixture build failed: " .. image .. " (" .. tostring(result.status) .. ")")
    assert(lfs.attributes(image, "mode") == "file", "missing built image " .. image)
    io.stdout:write("TRACE-IMAGE " .. image .. " nativeCases=" .. (target.testing and #all or 0) .. "\n")
  end
end

local manifest = {profile=profile, cases={}, degradedCases={}}
local function row(list, name, image, test_name, count, kind, status, stderr, program)
  local args = {}
  if type(test_name) == "string" then test_name = {test_name} end
  for _, name in ipairs(test_name or {}) do args[#args + 1] = "--filter=^trace_cases%." .. name .. "$" end
  list[#list + 1] = {name=name, image=image, args=args, program=program == true,
    kind=kind or "returned", status=status or 0, testCount=count, stderrContains=stderr or {}}
end
for _, assertions in ipairs({2, 0}) do
  local mode = "assertions-" .. assertions
  local base = path.join(output, mode)
  for _, name in ipairs(cases) do
    row(manifest.cases, mode .. "." .. name, mode .. "/runtime.mjs", name, 1, nil, nil,
      name == "test_state_close" and {"Lua warning: error in coroutine cleanup (trace-defer)"} or {})
  end
  for _, host in ipairs({"limit_small", "limit_absent", "limit_accessor", "prepare_callback", "prepare_accessor"}) do
    row(manifest.cases, mode .. ".host_" .. host, mode .. "/runtime.mjs",
      host == "prepare_accessor" and "test_host_capture_failed" or "test_host_capture_ready", 1)
  end
  row(manifest.cases, mode .. ".host_lua_fallback_capacity", mode .. "/runtime.mjs", "test_host_lua_fallback_capacity", 1)
  -- A program image reports the original error and its cleanup exactly. Its
  -- Titan frames are the profile's business: production inlining may drop
  -- them, and the JS gate then requires the survivors to be an ordered
  -- subsequence of the exact frames (D28).
  local uncaught = {"trace-uncaught-original", "TRACE uncaught cleanup=1"}
  if profile == "validation" then
    table.insert(uncaught, 2, "trace_uncaught.uncaught_middle")
    table.insert(uncaught, 2, "trace_uncaught.uncaught_leaf")
  end
  row(manifest.cases, mode .. ".uncaught", mode .. "/uncaught.mjs", nil, 0, "failed", 1, uncaught, true)
  -- A main Task that fails after a resume: stderr has only the uncaught-Task
  -- report, whose trace run() also returns (D14).
  local async_report = {"uncaught error in async Task: trace-async-original\nstack traceback:\n"}
  if profile == "validation" then
    async_report[#async_report + 1] = "trace_async.async_middle"
    async_report[#async_report + 1] = "trace_async.async_leaf"
  end
  row(manifest.cases, mode .. ".async_uncaught", mode .. "/async.mjs", nil, 0, "failed", 1, async_report, true)
  row(manifest.cases, mode .. ".task_entries", mode .. "/runtime.mjs", "test_task_entry_targets", 1)
  local map = read(path.join(base, "runtime.wasm.map"))
  assert(map:find('"x_titan_image"%s*:%s*"%x%x'), "runtime map lacks Titan image identity")
  for _, variant in ipairs({"missing", "malformed", "wrong_image", "extension_free", "missing_symbols"}) do
    local directory = path.join(base, variant)
    mkdir(directory)
    for _, ext in ipairs({"mjs", "wasm"}) do write(path.join(directory, "runtime." .. ext), read(path.join(base, "runtime." .. ext))) end
    local changed
    if variant == "malformed" then changed = '{"version":3,"mappings":'
    elseif variant == "wrong_image" then
      changed = map:gsub('("x_titan_image"%s*:%s*")(%x)', function(before, first)
        return before .. (first == "0" and "1" or "0")
      end, 1)
    elseif variant == "extension_free" then
      -- Remove all extensions by replacing their names with optional unknown
      -- keys. Standard fields and mapped locations remain byte-for-byte intact.
      changed = map:gsub('"x_titan_', '"x_fixture_')
    elseif variant == "missing_symbols" then
      changed = map:gsub('("x_titan_function_names"%s*:%s*%[)(.-)(%])', function(before, names, after)
        return before .. names:gsub('"[^"]*"', "null") .. after
      end, 1)
    end
    local destination = path.join(directory, "runtime.wasm.map")
    if changed then write(destination, changed)
    elseif lfs.attributes(destination) then assert(os.remove(destination)) end
    if variant == "missing_symbols" then
      row(manifest.cases, mode .. ".missing_symbols", mode .. "/" .. variant .. "/runtime.mjs",
        "test_missing_symbols", 1)
    else row(manifest.degradedCases, mode .. "." .. variant, mode .. "/" .. variant .. "/runtime.mjs",
      {"test_degraded_map", "test_degraded_lua_capacity"}, 2) end
  end
end

local function rows(values)
  local encoded = {}
  for _, entry in ipairs(values) do
    encoded[#encoded + 1] = "{" .. table.concat({
      '"name":' .. json(entry.name), '"image":' .. json(entry.image), '"args":' .. json(entry.args),
      '"kind":' .. json(entry.kind), '"status":' .. entry.status,
      '"program":' .. json(entry.program),
      '"testCount":' .. entry.testCount, '"stderrContains":' .. json(entry.stderrContains)}, ",") .. "}"
  end
  return "[\n" .. table.concat(encoded, ",\n") .. "\n]"
end
write(path.join(output, "manifest.json"), '{"profile":' .. json(manifest.profile) ..
  ',"cases":' .. rows(manifest.cases) .. ',"degradedCases":' .. rows(manifest.degradedCases) .. '}\n')
write(path.join(output, "trace.test.mjs"), read(path.join(repository, "spec/browser/trace.test.mjs")))
io.stdout:write(string.format("TRACE-GATE %s cases=%d degradedCases=%d nativeCases=%d\n",
  output, #manifest.cases, #manifest.degradedCases, #all))
