-- Speculative batched acceptance probes against the synchronous path: the same
-- in-memory modules are checked once with one job (synchronous probes) and
-- once with four (body-phase acceptance probes deferred to the module
-- barrier), and every observable result must be identical.
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local types = require "titan-compiler.types"

local ROOT = lfs.currentdir()
if platform.windows then ROOT = assert(platform.path.normalize(ROOT)) end
local FIXTURE = ROOT .. "/spec/fixtures/speculative_probes"
local HEADER = FIXTURE .. "/speculative.h"
local PROBE_CC = FIXTURE .. "/probe_cc.sh"

local function probe_compiler()
    if platform.windows then
        return assert(cdriver.shell_quote("bash")) .. " " ..
            assert(cdriver.shell_quote(PROBE_CC))
    end
    return PROBE_CC
end

local function header_module(body)
    return 'foreign import "' .. HEADER .. '"\n' .. body
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

-- One complete check of `roots` from in-memory sources under a fresh
-- resolver whose probe compiler is the deterministic fixture compiler.
local function check(modules, roots, jobs, options)
    options = options or {}
    types.registry = {}
    driver.imported = {}
    local previous_cc = driver.CC
    driver.CC = probe_compiler()
    local executions, semantics = {}, {}
    local context = driver.new_resolver_context({
        jobs = jobs,
        io = options.io,
        analysis_only = options.analysis_only,
        transient_caches = options.cache_directory == nil,
        c_probe_execution_trace = function(event)
            executions[#executions + 1] = event
        end,
        c_probe_semantic_trace = function(event)
            semantics[#semantics + 1] = event
        end,
    })
    local previous_cache = driver.PROBE_CACHE_DIRECTORY
    if options.cache_directory then driver.PROBE_CACHE_DIRECTORY = options.cache_directory end
    local imported = {}
    local results = { pcall(function()
        local loader = driver.tableloader(modules, imported, {}, {
            context = context, interface = "source",
        })
        local reports = {}
        for _, root in ipairs(roots) do
            local modt, errors = checker.checkimport(root, loader)
            reports[#reports + 1] = root .. ":" ..
                (modt and table.concat(errors, "\n") or tostring(errors))
        end
        return reports
    end) }
    driver.PROBE_CACHE_DIRECTORY = previous_cache
    driver.CC = previous_cc
    local bundle = context.source_ffi_header_bundle
    local outcome = {
        executions = executions,
        semantics = semantics,
        imported = imported,
        bundle = bundle,
        context = context,
    }
    if not results[1] then
        driver.close_resolver_context(context)
        error(results[2], 0)
    end
    outcome.report = table.concat(results[2], "\n")
    return outcome
end

local function close(outcome)
    assert(driver.close_resolver_context(outcome.context))
end

-- Generated C, with the resolver's private header bundle root made stable.
local function generated(outcome, modname)
    local mod = assert(outcome.imported[modname])
    local code = assert(coder.generate(modname, mod.ast, {},
        driver.TITAN_ABI_VERSION, false, {}))
    if type(code) == "table" then code = table.concat(code, "\n/*part*/\n") end
    if outcome.bundle then
        code = code:gsub(outcome.bundle:gsub("%p", "%%%0"), "<bundle>")
    end
    return code
end

local function count(events, predicate)
    local total = 0
    for _, event in ipairs(events) do
        if predicate(event) then total = total + 1 end
    end
    return total
end

local function speculative(event) return event.batch_kind == "speculative" end

local ACCEPTED = header_module([[
local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function widen(a: foreign spec_wide_t, b: foreign spec_ok_t): foreign long
  return a * b
end
local function again(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function view(p: foreign *spec_item): foreign *spec_other
  return p
end
local function flexible(): integer
  local item = foreign spec_fam.new(4)
  return #item.items
end
local record Fixed row: foreign spec_row end
local function fixed(): Fixed
  return Fixed.new(foreign int.new_array(4))
end
function total(): integer
  local value: integer = add(ffi.spec_three(), 1)
  return value + flexible()
end
]])

local MIXED = header_module([[
local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function rejected_op(a: foreign speculative_reject_t, b: foreign speculative_reject_t): integer
  local product = a * b
  return product
end
local function titan_error(): integer
  return "not an integer"
end
local function rejected_view(p: foreign *speculative_reject_item): foreign *spec_other
  return p
end
local function missing(a: foreign speculative_missing_t, b: foreign speculative_missing_t): foreign int
  return a - b
end
local function rejected_flexible()
  local item = foreign speculative_reject_fam.new(4)
end
local record RejectedFixed row: foreign speculative_reject_row end
local function rejected_fixed(): RejectedFixed
  return RejectedFixed.new(foreign int.new_array(4))
end
local function duplicate(a: foreign speculative_reject_t, b: foreign speculative_reject_t): integer
  return a * b
end
local function view(p: foreign *spec_item): foreign *spec_other
  return p
end
]])

describe("speculative batched acceptance probes", function()
    it("accept every deferred verdict with the synchronous AST, C and executions",
    function()
        local modules = { accepted = ACCEPTED }
        local sync = check(modules, { "accepted" }, 1)
        local batched = check(modules, { "accepted" }, 4)
        assert.equal("accepted:", sync.report)
        assert.equal(sync.report, batched.report)
        assert.equal(generated(sync, "accepted"), generated(batched, "accepted"))
        assert.equal(0, count(sync.executions, speculative))
        -- Two operators, a pointer view, a FAM extent and a fixed extent; the
        -- repeated operator is one deferred request.
        assert.equal(5, count(batched.executions, speculative))
        assert.equal(#sync.executions, #batched.executions)
        close(sync)
        close(batched)
    end)

    it("recheck failures with exactly the synchronous diagnostics", function()
        local modules = { mixed = MIXED }
        local sync = check(modules, { "mixed" }, 1)
        local batched = check(modules, { "mixed" }, 4)
        assert.matches("configured C compiler rejected binary operator", sync.report, 1, true)
        assert.matches("configured C compiler rejected conversion", sync.report, 1, true)
        assert.matches("could not be started", sync.report, 1, true)
        assert.matches("exceeds SIZE_MAX", sync.report, 1, true)
        assert.matches("fixed nominal C array extent does not match", sync.report, 1, true)
        assert.matches("expected integer but found string", sync.report, 1, true)
        assert.equal(sync.report, batched.report)
        assert.truthy(count(batched.executions, speculative) > 0)
        -- The recheck answers completed verdicts: no source is compiled twice.
        local seen = {}
        for _, event in ipairs(batched.executions) do
            assert.is_nil(seen[event.key], event.key)
            seen[event.key] = true
        end
        close(sync)
        close(batched)
    end)

    it("keep enum carriers, range checks and top-level probes synchronous",
    function()
        local modules = { colors = header_module([[
local start: foreign int = ffi.spec_three() + 1
local function shade(color: foreign spec_color, step: foreign spec_ok_t): foreign int
  return color + step
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a | b
end
]]) }
        local sync = check(modules, { "colors" }, 1)
        local batched = check(modules, { "colors" }, 4)
        assert.equal(sync.report, batched.report)
        assert.matches("configured C compiler rejected", batched.report, 1, true)
        for _, event in ipairs(batched.executions) do
            if event.probe_kind == "enum_carrier" or
               event.probe_kind == "header_baseline" then
                assert.equal("single", event.batch_kind)
            end
        end
        -- The module-variable operator is checked at top level.
        local top_level = 0
        for _, event in ipairs(batched.executions) do
            if event.probe_kind == "c_operator" and event.batch_kind == "single" then
                top_level = top_level + 1
            end
        end
        assert.equal(1, top_level)
        close(sync)
        close(batched)
    end)

    it("answer persistent cache hits and cached rejections synchronously",
    function()
        local cache = assert(compiler_io.new_sync():tmpname())
        os.remove(cache)
        local ok, err = pcall(function()
            local modules = { mixed = MIXED }
            local first = check(modules, { "mixed" }, 4, { cache_directory = cache })
            local sync = check(modules, { "mixed" }, 1, { cache_directory = cache })
            local batched = check(modules, { "mixed" }, 4, { cache_directory = cache })
            assert.equal(first.report, sync.report)
            assert.equal(sync.report, batched.report)
            -- Every cached verdict is answered synchronously; only the
            -- uncacheable infrastructure failure runs (and is deferred) again.
            assert.truthy(#batched.executions > 0)
            for _, event in ipairs(batched.executions) do
                assert.equal("infrastructure_failure", event.outcome)
            end
            assert.equal(1, count(batched.executions, speculative))
            close(first)
            close(sync)
            close(batched)
        end)
        remove_tree(cache)
        assert(ok, err)
    end)

    it("flush a source import before its importer and replay it exactly",
    function()
        local modules = {
            dep = header_module([[
function scale(a: foreign spec_ok_t): foreign int
  return a * a
end
function broken(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a - b
end
]]),
            consumer = header_module([[
local dep = import "dep.titan"
local function plus(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function rejected(p: foreign *speculative_reject_item): foreign *spec_item
  return p
end
function use(): integer
  return plus(dep.scale(2), 1)
end
]]),
            later = [[
local dep = import "dep"
function value(): integer
  return dep.scale(3)
end
]],
        }
        local roots = { "consumer", "later" }
        local sync = check(modules, roots, 1)
        local batched = check(modules, roots, 4)
        assert.equal(sync.report, batched.report)
        assert.matches("configured C compiler rejected", batched.report, 1, true)
        -- The dependency's own barrier completed before its importer flushed.
        local last_dep, first_consumer
        for index, event in ipairs(batched.executions) do
            if event.batch_kind == "speculative" then
                if event.module == "dep" then last_dep = index end
                if event.module == "consumer" and not first_consumer then
                    first_consumer = index
                end
            end
        end
        assert.truthy(last_dep and first_consumer and last_dep < first_consumer)
        -- Imported interfaces and the importer state left for a later root are
        -- the synchronous ones.
        assert.equal(types.serialize(sync.imported.dep.type),
            types.serialize(batched.imported.dep.type))
        assert.equal(types.serialize(sync.imported.later.type),
            types.serialize(batched.imported.later.type))
        close(sync)
        close(batched)
    end)

    it("leave analysis checks and strategies without run_batch synchronous",
    function()
        local modules = { mixed = MIXED }
        local sync = check(modules, { "mixed" }, 1)
        local analysis = check(modules, { "mixed" }, 4, { analysis_only = true })
        assert.equal(0, count(analysis.executions, speculative))
        local base = compiler_io.new_sync()
        local plain = {}
        for _, name in ipairs({
            "cwd", "absolute", "realpath", "stat", "lstat", "readable",
            "read_file", "write_file", "list", "mkdir", "unlink", "rmdir",
            "rename", "tmpname", "run", "yield",
        }) do
            plain[name] = function(_, ...) return base[name](base, ...) end
        end
        local injected = check(modules, { "mixed" }, 4, { io = plain })
        assert.equal(0, count(injected.executions, speculative))
        assert.equal(sync.report, injected.report)
        close(sync)
        close(analysis)
        close(injected)
    end)
end)

-- The complete titanc path (folder sources, the driver's reparse closure,
-- `Sync:run_batch` and generated-C compilation) with one versus four jobs.
describe("titanc speculative probe batches", function()
    if platform.windows then
        it("are exercised by the POSIX shell fixture", function()
            pending("the fixture compiler is a POSIX shell script")
        end)
        return
    end
    local installed_prefix = require "spec.support.installed_prefix"
    local PREFIX = installed_prefix.active()
    local LUA = PREFIX .. "/bin/lua"
    local workspace

    local function quote(text) return assert(cdriver.shell_quote(text)) end

    local function write(path, contents)
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        assert(file:close())
    end

    local function read(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local contents = assert(file:read("a"))
        file:close()
        return contents
    end

    local function titanc(jobs, output, environment)
        local command = "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS " ..
            (environment or "") ..
            " CC=" .. quote(PROBE_CC) ..
            " TITAN_EXTRA_CPPFLAGS= TITAN_EXTRA_CFLAGS= TITAN_EXTRA_LDFLAGS=" ..
            " TITAN_PROBE_CACHE_DISABLE=1 TITAN_ROCKS_ROOT=" .. quote(PREFIX) ..
            " TITAN_RUNTIME_PREBUILT=1 " .. quote(LUA) .. " -e " ..
            quote("package.path = " .. string.format("%q",
                ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") ..
                " .. package.path") ..
            " " .. quote(ROOT .. "/titanc") .. " --jobs " .. jobs ..
            " -c -o " .. quote(output) .. " --tree " .. quote(workspace .. "/src") ..
            " app 2>&1"
        local pipe = assert(io.popen(command, "r"))
        local text = assert(pipe:read("a"))
        local ok = pipe:close()
        -- Diagnostics name the source tree, never the output tree.
        return ok == true, text
    end

    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        assert(lfs.mkdir(workspace .. "/src"))
        assert(lfs.mkdir(workspace .. "/src/app"))
    end)

    after_each(function() remove_tree(workspace) end)

    local function folder(main, contributor)
        write(workspace .. "/src/app/app.titan", main)
        write(workspace .. "/src/app/extra.titan", contributor)
    end

    it("generate identical C for a folder module whose probes all accept",
    function()
        folder(ACCEPTED, header_module([[
local function extra_sum(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a & b
end
function extra(): integer
  return extra_sum(ffi.spec_three(), 1)
end
]]))
        local sync_ok, sync_output = titanc(1, workspace .. "/out")
        assert.truthy(sync_ok, sync_output)
        local sync_c = assert(read(workspace .. "/out/app/app.c"))
        remove_tree(workspace .. "/out")
        local batched_ok, batched_output = titanc(4, workspace .. "/out")
        assert.truthy(batched_ok, batched_output)
        assert.equal(sync_output, batched_output)
        assert.equal(sync_c, read(workspace .. "/out/app/app.c"))
        assert.truthy(read(workspace .. "/out/app/app.o"))
    end)

    it("report identical diagnostics when a contributor's probe fails",
    function()
        folder(ACCEPTED, header_module([[
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a % b
end
local function wrong(): integer
  return "string"
end
]]))
        local sync_ok, sync_output = titanc(1, workspace .. "/out-1")
        local batched_ok, batched_output = titanc(4, workspace .. "/out-4")
        assert.falsy(sync_ok)
        assert.falsy(batched_ok)
        assert.matches("configured C compiler rejected", sync_output, 1, true)
        assert.matches("extra.titan", sync_output, 1, true)
        assert.equal(sync_output, batched_output)
        assert.falsy(read(workspace .. "/out-4/app/app.c"))
    end)
end)

describe("speculative probe batch policy", function()
    local previous_getenv
    before_each(function() previous_getenv = platform.getenv end)
    after_each(function() platform.getenv = previous_getenv end)

    local function with_makeflags(value)
        platform.getenv = function(name)
            if name == "MAKEFLAGS" then return value end
            return previous_getenv(name)
        end
    end

    it("uses the local cap only for ordinary checks outside a serial Make",
    function()
        with_makeflags(nil)
        assert.equal(1, driver.probe_batch_jobs({}))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 1 }))
        assert.equal(4, driver.probe_batch_jobs({ jobs = 4 }))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 4, analysis_only = true }))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 4, completion = {} }))
        with_makeflags("-j1")
        assert.equal(1, driver.probe_batch_jobs({ jobs = 4 }))
        with_makeflags("-j4 --jobserver-auth=fifo:/tmp/titan-unused-pool")
        assert.equal(4, driver.probe_batch_jobs({ jobs = 4 }))
        assert.error_matches(function()
            driver.new_resolver_context({ jobs = 0 })
        end, "jobs must be a positive integer", 1, true)
    end)
end)
