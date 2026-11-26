#!/usr/bin/env lua
-- #329 size/speed baseline harness. This is a measurement, never a gate.
--
-- Titan cells: the micro-benchmark program at -O1 and -O2 with JSPI,
-- measured under Node and headless Chromium, with image sizes,
-- instantiate/run times, the per-suspension cost, import lists and whether the
-- linker kept the Titan metadata sections.
--
-- Native rows provide scale. Published aggregates are medians of the raw
-- repeats; the raw repeats stay in the receipt.
--
-- Required environment (the slice's validation environment):
--   PREFIX=<prefix>           installed compiler, runtime and browser SDK
--   TITAN_ROOT=<prefix>       the same installed tree
--   WASI_SDK_PATH=<root>       wasi-sdk 34.0
--   BINARYEN_ROOT=<root>       Binaryen version_133 (or WASM_OPT=<wasm-opt>)
--   TITAN_NODE=<node>          Node 26 or newer for the runner and reports
--   TITAN_CHROME=<chrome>      headless Chromium for the Chromium cells
--
-- Usage: lua -E scripts/browser_baseline.lua [--out PATH] [--repeats N]
-- Exit status is nonzero when a cell failed; a receipt is still written.
local lfs = require "lfs"
local repository = assert(lfs.currentdir())
-- Resolve the compiler from the checkout while TITAN_ROOT keeps the installed
-- headers, runtime and browser SDK: the recorded profile must be the exact one
-- that built the images, including its identity inputs.
package.path = repository .. "/?.lua;" .. repository .. "/?/init.lua;" .. package.path

local compiler_io = require "titan-compiler.io"
local browser_target = require "titan-compiler.browsertarget"
local platform = require "titan-compiler.platform"
local version = require "titan-compiler.version"
local sha256 = require "titan-compiler.sha256"
local json = require "spec.support.browser_baseline_json"

local strategy = compiler_io.new_sync()
local fixtures = repository .. "/spec/fixtures/browser_baseline"
local prefix = assert(os.getenv("PREFIX") and os.getenv("PREFIX") ~= "" and
    os.getenv("PREFIX"), "PREFIX must name the validation prefix")
local tools = assert(browser_target.discover_tools({ io = strategy }))
local node = os.getenv("TITAN_NODE")
if not node or node == "" then node = "node" end
local chrome = os.getenv("TITAN_CHROME")
local runner = prefix .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION ..
    "/titan-browser-run"

local options = { out = "out/browser-baseline/receipt.json", repeats = 3 }
local arguments = { ... }
for index = 1, #arguments do
    local name, value = arguments[index]:match("^%-%-(.+)=(.*)$")
    if name == "out" then
        options.out = value
    elseif name == "repeats" then
        local count = assert(tonumber(value), "--repeats needs a positive integer")
        assert(count > 0 and count % 1 == 0, "--repeats needs a positive integer")
        options.repeats = count
    else
        error("unknown argument " .. arguments[index], 0)
    end
end

local function absolute(filename)
    return platform.is_absolute(filename) and filename or
        repository .. "/" .. filename
end

local function mkdirp(directory)
    if lfs.attributes(directory, "mode") == "directory" then return end
    local parent = directory:match("^(.*)/[^/]+$")
    if parent and parent ~= directory and parent ~= "" then mkdirp(parent) end
    lfs.mkdir(directory)
end

local function run(argv)
    local result = strategy:run(argv, { stderr_to_stdout = true })
    if not result or not result.started then
        return nil, "could not start: " .. table.concat(argv, " ") .. ": " ..
            tostring(result and result.diagnostic or "no captured result")
    end
    if not result.ok then
        return nil, table.concat(argv, " ") .. "\n" ..
            tostring(result.output or result.diagnostic)
    end
    return result.output or ""
end

local function must(argv)
    local output, failure = run(argv)
    if not output then error(failure, 0) end
    return output
end

local function trimmed(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function rows(output)
    local values = {}
    for line in tostring(output or ""):gmatch("[^\n]+") do
        local name, value = line:match("^([%w%._%-]+)=(.*)$")
        if name and values[name] == nil then
            values[name] = tonumber(value) or value
        end
    end
    return values
end

local function version_line(argv)
    local output = run(argv)
    if not output then return nil end
    return trimmed(output)
end

local function digest(filename)
    local result = run({ "sha256sum", filename })
    local value = result and result:match("^(%x+)")
    if not value then
        result = run({ "shasum", "-a", "256", filename })
        value = result and result:match("^(%x+)")
    end
    return value
end

local record_fields = {}
do
    local filename = prefix .. "/lib/browser/liblua-config.txt"
    local file = io.open(filename, "rb")
    if file then
        local text = assert(file:read("a")); assert(file:close())
        for line in text:gmatch("[^\n]+") do
            local name, value = line:match("^([%w_]+)=(.*)$")
            if name then record_fields[name] = value end
        end
    else
        record_fields.unavailable = "browser Lua record is missing at " .. filename
    end
end

-- One description of a cell's link configuration: the plan, the certificate
-- and the child build must all use it, or the recorded identity describes a
-- different configuration than the image it claims.
local function cell_options(cell)
    return { purpose = "baseline", optimization = cell.optimization }
end

-- Build selects the cell through the internal measurement seam, exactly as the
-- link-profile contract requires; the harness never duplicates flag lists.
-- The preset is installed while the descriptor is built so its recorded
-- `trace_control` and measurement level are the ones the build certifies.
local function plan_for(cell, out)
    local driver = require "titan-compiler.driver"
    local browserlink = require "titan-compiler.browserlink"
    mkdirp(out)
    local preset = cell_options(cell)
    local saved = driver.browser_link_options
    driver.browser_link_options = preset
    local function finish(value, failure)
        driver.browser_link_options = saved
        return value, failure
    end
    local context = driver.new_resolver_context({
        target = "browser", output_root = out })
    local configured, failure = driver.configure_foreign_c(context)
    if not configured then
        driver.close_resolver_context(context)
        return finish(nil, failure)
    end
    local descriptor, descriptor_error = driver.context_target_descriptor(context)
    if not descriptor then
        driver.close_resolver_context(context)
        return finish(nil, descriptor_error)
    end
    local plan, plan_error = browserlink.profile(descriptor, preset)
    driver.close_resolver_context(context)
    return finish(plan, plan_error)
end

local function preamble(cell)
    local options = cell_options(cell)
    return string.format(
        "package.path=%q..package.path; require('titan-compiler.driver')" ..
        ".browser_link_options={purpose=%q,optimization=%q}",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;",
        options.purpose, options.optimization)
end

local function build_titan_cell(cell, out)
    return must({ prefix .. "/bin/lua", "-E", "-e", preamble(cell),
        repository .. "/titanc", "-q", "--target", "browser",
        "--tree", fixtures, "-o", out, "--exe", out .. "/baseline.mjs",
        "--c-source", fixtures .. "/baseline.c", "baseline" })
end

local metadata_script = [[
const {readFileSync}=require('node:fs');
const [wasm,mjs]=process.argv.slice(1);
const bytes=readFileSync(wasm);
const module_=new WebAssembly.Module(bytes);
const imports=WebAssembly.Module.imports(module_)
  .map(function(entry){return entry.module+"."+entry.name;}).sort();
console.log("wasm_bytes="+bytes.length);
console.log("mjs_bytes="+readFileSync(mjs).length);
for (const name of imports) console.log("import="+name);
function readVaruint(buffer, position) {
  let value = 0, shift = 0, byte;
  do { byte = buffer[position++]; value += (byte & 0x7f) * Math.pow(2, shift); shift += 7; }
  while (byte & 0x80);
  return [value, position];
}
// Section layout, the data segments, and the data-segment names the linker
// keeps. The named payload segments are the metadata measurement; ordinary
// .rodata must never be mistaken for .titan.source.
const sections = [];
let dataPayload = 0;
let position = 8;
while (position < bytes.length) {
  const id = bytes[position++];
  let size; [size, position] = readVaruint(bytes, position);
  sections.push({ id, body: position, size });
  if (id === 11) dataPayload = size;
  position += size;
}
const dataSection = sections.find(entry => entry.id === 11);
const segments = [];
if (dataSection) {
  let cursor = dataSection.body;
  let count; [count, cursor] = readVaruint(bytes, cursor);
  for (let index = 0; index < count; index++) {
    let flags; [flags, cursor] = readVaruint(bytes, cursor);
    if (flags === 2) { let ignored; [ignored, cursor] = readVaruint(bytes, cursor); }
    if (flags === 0 || flags === 2) {
      // Active segment offset expression: i32.const N, end.
      cursor += 1;
      let offset; [offset, cursor] = readVaruint(bytes, cursor);
      cursor += 1;
    }
    let length; [length, cursor] = readVaruint(bytes, cursor);
    segments.push({ index, start: cursor, size: length });
    cursor += length;
  }
}
console.log("data_bytes="+dataPayload);
const named = new Map();
for (const section of sections) {
  if (section.id !== 0) continue;
  let cursor = section.body;
  let nameLength; [nameLength, cursor] = readVaruint(bytes, cursor);
  if (bytes.toString("latin1", cursor, cursor + nameLength) !== "name") continue;
  cursor += nameLength;
  const sectionEnd = section.body + section.size;
  while (cursor < sectionEnd) {
    let subsection; [subsection, cursor] = readVaruint(bytes, cursor);
    let length; [length, cursor] = readVaruint(bytes, cursor);
    const end = cursor + length;
    if (subsection === 9) {
      let count; [count, cursor] = readVaruint(bytes, cursor);
      for (let index = 0; index < count; index++) {
        let segment; [segment, cursor] = readVaruint(bytes, cursor);
        let size; [size, cursor] = readVaruint(bytes, cursor);
        named.set(segment, bytes.toString("latin1", cursor, cursor + size));
        cursor += size;
      }
    }
    cursor = end;
  }
}
for (const segment of segments) {
  const name = named.get(segment.index);
  if (name === undefined) continue;
  if (name === ".rodata") console.log("rodata_bytes=" + segment.size);
  else if (name === ".data") console.log("data_segment_bytes=" + segment.size);
  else if (name.indexOf(".titan.") === 0) {
    console.log("metadata=" + name + ":" + segment.size);
  }
}
]]

local forbidden = { "dlopen", "dlsym", "dlerror", "backtrace" }

local function image_report(out, image)
    local output, failure = run({ node, "-e", metadata_script,
        out .. "/" .. image .. ".wasm", out .. "/" .. image .. ".mjs" })
    if not output then return { error = failure } end
    local report = { imports = {}, metadata_bytes = {} }
    for line in output:gmatch("[^\n]+") do
        local name, value = line:match("^([%w%._%-]+)=(.*)$")
        if name == "import" then
            report.imports[#report.imports + 1] = value
        elseif name == "metadata" then
            local marker, size = value:match("^([^:]+):(%d+)$")
            if marker then report.metadata_bytes[marker] = tonumber(size) end
        elseif name then
            report[name] = tonumber(value) or value
        end
    end
    report.forbidden = {}
    for _, symbol in ipairs(forbidden) do
        for _, name in ipairs(report.imports) do
            if name:find(symbol, 1, true) then
                report.forbidden[#report.forbidden + 1] = name
                break
            end
        end
    end
    return report
end

local function copy(from, to)
    local input = assert(io.open(from, "rb"))
    local bytes = assert(input:read("a")); assert(input:close())
    local output = assert(io.open(to, "wb"))
    assert(output:write(bytes)); assert(output:close())
end

local function engine_run(engine, out, module, image)
    -- The runner imports --js-test and --imports from beneath --root, so the
    -- host modules are copied into the cell's root before every run. The
    -- fixtures' shared imports supply the C helper's suspending sleep.
    copy(fixtures .. "/" .. module, out .. "/" .. module)
    copy(repository .. "/spec/fixtures/browser_runtime/fixture-imports.mjs", out .. "/fixture-imports.mjs")
    local argv = { runner, "--engine", engine, "--timeout", "180000",
        "--grace", "200", "--root", out, "--js-test", out .. "/" .. module,
        "--imports", out .. "/fixture-imports.mjs", "--", image }
    local output, failure = run(argv)
    if not output then return { error = failure } end
    local values = rows(output)
    if values["browser.kind"] ~= "returned" or values["browser.status"] ~= 0 then
        return { error = "unexpected completion: " .. tostring(output) }
    end
    return values
end

local function repeat_runs(count, action)
    local results = {}
    for index = 1, count do
        local value = action(index)
        if not value then return nil end
        results[#results + 1] = value
    end
    return results
end

-- One published statistic for every reported metric: the median of the raw
-- repeats. Raw samples stay in the receipt.
local metric_fields = {
    "browser.instantiate_ms", "browser.run_ms", "browser.total_ms",
    "bench.calls", "bench.closures", "bench.arrays", "bench.strings",
    "bench.coroutine_switch", "bench.suspend_average", "bench.suspend_total",
}

local function metrics(results)
    local summary = {}
    for _, field in ipairs(metric_fields) do
        local values = {}
        for _, result in ipairs(results) do
            if type(result[field]) == "number" then values[#values + 1] = result[field] end
        end
        summary[field] = json.median(values)
    end
    return summary
end

local receipt = {
    format = "titan-browser-baseline-3",
    date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    statistic = "median",
    toolchain = {
        host = version_line({ "uname", "-srm" }),
        commit = version_line({ "git", "-C", repository, "rev-parse", "HEAD" }),
        clang = trimmed(tools.version_output),
        clang_path = tools.cc[1],
        wasi_sdk = tools.version,
        wasm_opt = trimmed(tools.optimizer.version_output),
        wasm_opt_path = tools.optimizer.argv[1],
        node = version_line({ node, "--version" }),
        node_path = node,
        chrome = chrome and version_line({ chrome, "--version" }) or nil,
        chrome_path = chrome,
        chrome_sha256 = chrome and digest(chrome) or nil,
        record = record_fields,
        library_version = version.TITAN_LIBRARY_VERSION,
    },
    cells = {},
    native = {},
    failures = {},
}

local function fail(message)
    receipt.failures[#receipt.failures + 1] = message
    io.stderr:write("baseline: " .. message .. "\n")
end

local out_root = absolute("out/browser-baseline")
local cells = {}
for _, optimization in ipairs({ "O1", "O2" }) do
    cells[#cells + 1] = {
        name = optimization .. "-jspi",
        optimization = optimization,
    }
end

for _, cell in ipairs(cells) do
    local out = out_root .. "/titan/" .. cell.name
    local plan, plan_error = plan_for(cell, out)
    if not plan then
        fail(cell.name .. ": link profile refused: " .. tostring(plan_error))
    else
        local ok, build_failure = pcall(build_titan_cell, cell, out)
        if not ok then
            fail(cell.name .. ": build failed: " .. tostring(build_failure))
        else
            local report = {
                name = cell.name,
                optimization = cell.optimization,
                backend = "jspi",
                compile_flags = plan.compile_flags,
                link_flags = plan.link_flags,
                optimizer_flags = plan.optimizer_flags,
                identity = plan.identity_inputs,
                image = image_report(out, "baseline"),
                engine = {},
            }
            for _, engine in ipairs({ "node", "chromium" }) do
                local results = repeat_runs(options.repeats, function()
                    local values = engine_run(engine, out, "bench.mjs", "baseline.mjs")
                    if values.error then
                        fail(cell.name .. "/" .. engine .. ": " .. values.error)
                        return nil
                    end
                    return values
                end)
                report.engine[engine] = results and {
                    repeats = results, metrics = metrics(results),
                } or { error = "run failed; see failures" }
            end
            receipt.cells[#receipt.cells + 1] = report
        end
    end
end

do
    local out = out_root .. "/native"
    mkdirp(out)
    local built, failure = run({ prefix .. "/bin/titanc", "-q",
        "-o", out, "--tree", fixtures,
        "--exe", out .. "/native_baseline", "native_baseline" })
    if not built then
        fail("native: build failed: " .. tostring(failure))
    else
        local results = repeat_runs(options.repeats, function()
            local output, run_error = run({ out .. "/native_baseline" })
            if not output then
                fail("native: " .. tostring(run_error))
                return nil
            end
            return rows(output)
        end)
        receipt.native = { repeats = results or {}, metrics = results and metrics(results) or {} }
    end
end

mkdirp(options.out:match("^(.*)/[^/]+$") or ".")
local filename = absolute(options.out)
local file = assert(io.open(filename, "wb"))
assert(file:write(json.encode(receipt) .. "\n"))
assert(file:close())
io.stdout:write(filename, "\n")
if #receipt.failures > 0 then os.exit(1) end
