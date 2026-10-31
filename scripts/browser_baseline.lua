#!/usr/bin/env lua
-- #329 size/speed baseline harness. This is a measurement, never a gate.
--
-- It builds the same micro-benchmark program at -O1 and -O2, each with and
-- without Asyncify, records image sizes, instantiate/run times under Node and
-- headless Chromium, the per-suspension cost, the final import lists and whether
-- the linker kept the Titan metadata segments, then records native and
-- fork-interpreter reference rows.
--
-- Required environment (the slice's validation environment):
--   TITAN_ROOT=<prefix>       installed compiler, runtime and browser SDK
--   EMSDK=<emsdk root>         Emscripten 6.0.13
--   TITAN_NODE=<node>          Node 24 for the runner and the metadata report
--   TITAN_CHROME=<chrome>      headless Chromium for the Chromium cells
--
-- Usage: lua -E scripts/browser_baseline.lua [--out PATH] [--repeats N]
-- Exit status is nonzero when a cell failed; a receipt is still written.
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local version = require "titan-compiler.version"
local lfs = require "lfs"

local strategy = compiler_io.new_sync()
local repository = assert(lfs.currentdir())
local fixtures = repository .. "/spec/fixtures/browser_baseline"
local prefix = assert(os.getenv("PREFIX") and os.getenv("PREFIX") ~= "" and
    os.getenv("PREFIX"), "PREFIX must name the validation prefix")
local emsdk = assert(os.getenv("EMSDK") and os.getenv("EMSDK") ~= "" and
    os.getenv("EMSDK"), "EMSDK must name the Emscripten SDK root")
local node = os.getenv("TITAN_NODE")
if not node or node == "" then node = "node" end
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
    return (output:match("^%s*(.-)%s*$"))
end

local function read_record()
    local filename = prefix .. "/lib/browser/liblua-config.txt"
    local file = io.open(filename, "rb")
    if not file then return nil, "browser Lua record is missing at " .. filename end
    local text = assert(file:read("a")); assert(file:close())
    return text
end

local record_fields = {}
do
    local text, failure = read_record()
    if text then
        for line in text:gmatch("[^\n]+") do
            local name, value = line:match("^([%w_]+)=(.*)$")
            if name then record_fields[name] = value end
        end
    else
        record_fields.unavailable = failure
    end
end

-- The build selects the cell through the internal measurement seam, exactly as
-- the link-profile contract requires; the harness never duplicates flag lists.
local function build_cell(cell, out)
    local preamble = string.format(
        "package.path=%q..package.path; require('titan-compiler.driver')" ..
        ".browser_link_options={purpose='baseline',assertions=2," ..
        "optimization=%q,asyncify=%s}",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;",
        cell.optimization, tostring(cell.asyncify))
    return must({ prefix .. "/bin/lua", "-E", "-e", preamble,
        repository .. "/titanc", "-q", "--target", "browser",
        "--tree", fixtures, "-o", out, "--exe", out .. "/baseline.mjs",
        "--c-source", fixtures .. "/baseline.c", "baseline" })
end

local function identity(descriptor_plan)
    return descriptor_plan and descriptor_plan.identity_inputs or nil
end

local function profile_plan(cell, out)
    local driver = require "titan-compiler.driver"
    local browserlink = require "titan-compiler.browserlink"
    mkdirp(out)
    local context = driver.new_resolver_context({
        target = "browser", output_root = out })
    local configured, failure = driver.configure_foreign_c(context)
    if not configured then
        driver.close_resolver_context(context)
        return nil, failure
    end
    local descriptor, descriptor_error = driver.context_target_descriptor(context)
    if not descriptor then
        driver.close_resolver_context(context)
        return nil, descriptor_error
    end
    local plan, plan_error = browserlink.profile(descriptor, {
        purpose = "baseline", assertions = 2,
        optimization = cell.optimization, asyncify = cell.asyncify })
    driver.close_resolver_context(context)
    return plan, plan_error
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
const text=bytes.toString("latin1");
for (const marker of [".titan.meta",".titan.source",".titan.cprobe"])
  if (text.indexOf(marker)>=0) console.log("metadata="+marker);
]]

local forbidden = { "dlopen", "dlsym", "dlerror", "backtrace" }

local function image_report(out)
    local output, failure = run({ node, "-e", metadata_script,
        out .. "/baseline.wasm", out .. "/baseline.mjs" })
    if not output then return { error = failure } end
    local report = { imports = {} }
    for line in output:gmatch("[^\n]+") do
        local name, value = line:match("^([%w%._%-]+)=(.*)$")
        if name == "import" then
            report.imports[#report.imports + 1] = value
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

local function engine_run(engine, out, asyncify)
    -- The runner imports --js-test from beneath --root, so the portable host
    -- module is copied into the cell's root before every run.
    copy(fixtures .. "/bench.mjs", out .. "/bench.mjs")
    local argv = { runner, "--engine", engine, "--timeout", "180000",
        "--grace", "200", "--root", out, "--js-test", out .. "/bench.mjs",
        "--", "baseline.mjs" }
    if asyncify then argv[#argv + 1] = "asyncify" end
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

local function minimum(results, name)
    local best
    for _, result in ipairs(results) do
        local value = result[name]
        if type(value) == "number" and (not best or value < best) then best = value end
    end
    return best
end

local receipt = {
    format = "titan-browser-baseline-1",
    date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    toolchain = {
        emscripten = version_line({ emsdk .. "/upstream/emscripten/emcc", "--version" }),
        node = version_line({ node, "--version" }),
        chrome = os.getenv("TITAN_CHROME") and
            version_line({ os.getenv("TITAN_CHROME"), "--version" }) or nil,
        record = record_fields,
        library_version = version.TITAN_LIBRARY_VERSION,
    },
    cells = {},
    native = {},
    lua = {},
    failures = {},
}

local function fail(message)
    receipt.failures[#receipt.failures + 1] = message
    io.stderr:write("baseline: " .. message .. "\n")
end

local out_root = absolute("out/browser-baseline")
local cells = {}
for _, optimization in ipairs({ "O1", "O2" }) do
    for _, asyncify in ipairs({ true, false }) do
        cells[#cells + 1] = {
            name = optimization .. (asyncify and "-asyncify" or "-no-asyncify"),
            optimization = optimization,
            asyncify = asyncify,
        }
    end
end

for _, cell in ipairs(cells) do
    local out = out_root .. "/" .. cell.name
    mkdirp(out)
    local plan, plan_error = profile_plan(cell, out)
    if not plan then
        fail(cell.name .. ": link profile refused: " .. tostring(plan_error))
    else
        local ok, build_failure = pcall(build_cell, cell, out)
        if not ok then
            fail(cell.name .. ": build failed: " .. tostring(build_failure))
        else
            local image = image_report(out)
            local report = {
                name = cell.name,
                optimization = cell.optimization,
                asyncify = cell.asyncify,
                compile_flags = plan.compile_flags,
                link_flags = plan.link_flags,
                identity = identity(plan),
                image = image,
                engine = {},
            }
            for _, engine in ipairs({ "node", "chromium" }) do
                local results = repeat_runs(options.repeats, function()
                    local values = engine_run(engine, out, cell.asyncify)
                    if values.error then
                        fail(cell.name .. "/" .. engine .. ": " .. values.error)
                        return nil
                    end
                    return values
                end)
                if results then
                    report.engine[engine] = {
                        repeats = results,
                        instantiate_ms = minimum(results, "browser.instantiate_ms"),
                        run_ms = minimum(results, "browser.run_ms"),
                        suspension_ms = minimum(results, "bench.suspend_average") and
                            minimum(results, "bench.suspend_average") * 1000 or nil,
                    }
                else
                    report.engine[engine] = { error = "run failed; see failures" }
                end
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
        receipt.native = {
            repeats = results or {},
            calls = results and minimum(results, "bench.calls") or nil,
        }
    end
end

do
    local script = repository .. "/lua-5.5.1/src/browser/lua.js"
    if lfs.attributes(script, "mode") ~= "file" then
        local path = emsdk .. "/upstream/emscripten:" .. (os.getenv("PATH") or "")
        local built, failure = run({ "env", "PATH=" .. path, "make",
            "-C", repository .. "/lua-5.5.1/src", "browser-js" })
        if not built then fail("lua: browser-js build failed: " .. tostring(failure)) end
    end
    if lfs.attributes(script, "mode") == "file" then
        local results = repeat_runs(options.repeats, function()
            local source = assert(io.open(fixtures .. "/bench.lua", "rb"))
            local code = assert(source:read("a")); assert(source:close())
            -- The standalone interpreter parses any argument that starts with
            -- "-" as another option, so a leading newline keeps a comment-first
            -- benchmark chunk out of its option scan.
            local output, run_error = run({ node, script, "-e", "\n" .. code })
            if not output then
                fail("lua: " .. tostring(run_error))
                return nil
            end
            return rows(output)
        end)
        receipt.lua = {
            interpreter = "lua-5.5.1/src/browser/lua.js",
            repeats = results or {},
            calls = results and minimum(results, "lua.calls") or nil,
        }
    end
end

-- Receipt writer: closed tables only, so a tiny encoder is enough.
local function quote(text)
    local escaped = tostring(text):gsub('[%z\1-\31\\"]', function(char)
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        if char == "\n" then return "\\n" end
        if char == "\r" then return "\\r" end
        if char == "\t" then return "\\t" end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end

local function encode(value, indent)
    local kind = type(value)
    indent = indent or ""
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return string.format("%.9g", value)
    elseif kind == "string" then
        return quote(value)
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "table" then
        local keys = {}
        local count = #value
        local array = count > 0
        for key in pairs(value) do
            if type(key) ~= "number" then array = false end
            keys[#keys + 1] = key
        end
        table.sort(keys, function(left, right)
            return tostring(left) < tostring(right)
        end)
        if #keys == 0 then return "{}" end
        local inner = indent .. "  "
        local parts = {}
        for _, key in ipairs(keys) do
            local rendered = encode(value[key], inner)
            if array then
                parts[#parts + 1] = inner .. rendered
            else
                parts[#parts + 1] = inner .. quote(tostring(key)) .. ": " .. rendered
            end
        end
        local brackets = array and { "[", "]" } or { "{", "}" }
        return brackets[1] .. "\n" .. table.concat(parts, ",\n") .. "\n" ..
            indent .. brackets[2]
    end
    return "null"
end

mkdirp(options.out:match("^(.*)/[^/]+$") or ".")
local filename = absolute(options.out)
local file = assert(io.open(filename, "wb"))
assert(file:write(encode(receipt) .. "\n"))
assert(file:close())
io.stdout:write(filename, "\n")
if #receipt.failures > 0 then os.exit(1) end
