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
-- On POSIX the Busted runners use nested serial Make (MAKEFLAGS=-j1), which
-- keeps titanc synchronous. Each check here models a run without parent Make;
-- Windows always applies only the local cap.
local function check(modules, roots, jobs, options)
    options = options or {}
    types.registry = {}
    driver.imported = {}
    local previous_cc = driver.CC
    driver.CC = probe_compiler()
    local previous_getenv = platform.getenv
    platform.getenv = function(name)
        if name == "MAKEFLAGS" or name == "MFLAGS" or name == "MAKELEVEL" then
            return nil
        end
        return previous_getenv(name)
    end
    local executions, semantics = {}, {}
    local context = driver.new_resolver_context({
        jobs = jobs,
        io = options.io,
        analysis_only = options.analysis_only,
        completion = options.completion,
        output_root = options.output_root,
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
    platform.getenv = previous_getenv
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

-- Each `FILE:LINE:COL: type error:` diagnostic of a report as "LINE:kind",
-- in report order, with its kind reduced to a stable keyword.
local function diagnostics(report)
    local found = {}
    for line in report:gmatch("[^\n]+") do
        local row, message = line:match("[^:]+%.titan:(%d+):%d+: type error: (.*)")
        if row then
            local kind = message:find("transient failure", 1, true) and "transient"
                or message:find("configured C compiler rejected", 1, true) and "rejected"
                or message
            found[#found + 1] = row .. ":" .. kind
        end
    end
    return found
end

-- Temporarily replace fields of `target` around `body`.
local function with_fields(target, replacements, body)
    local saved = {}
    for name, replacement in pairs(replacements) do
        saved[name] = target[name]
        target[name] = replacement
    end
    local results = table.pack(pcall(body))
    for name in pairs(replacements) do target[name] = saved[name] end
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

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

    it("keep enum carriers and top-level probes synchronous",
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

    -- A fail-once/recover compiler: the synchronous path reports a failed
    -- run once and retries the next request of the same source. The recheck
    -- replays each recorded failure exactly once, in order, before a verdict
    -- the speculative pass published later can answer that source.
    it("replay each recorded probe failure once, like the synchronous retry",
    function()
        local returned = "types in return do not match, expected foreign int " ..
            "but found invalid type"
        local cases = {
            -- Two deferred uses of one source, deduplicated into one run.
            { root = "flaky", expected = { "3:transient", "3:" .. returned },
              source = header_module([[
local function first(a: foreign speculative_flaky_t, b: foreign speculative_flaky_t): foreign int
  return a + b
end
local function second(a: foreign speculative_flaky_t, b: foreign speculative_flaky_t): foreign int
  return a + b
end
]]) },
            -- A top-level use fails; a later deferred use of the same source
            -- succeeds while another deferred probe rejects.
            { root = "flaky", top_level = true, expected = {
                "2:transient",
                "2:types in declaration of module variable seed do not match, " ..
                    "expected foreign int but found invalid type",
                "7:rejected", "7:" .. returned,
              }, source = header_module([[
local seed: foreign int = ffi.spec_flaky_value() + ffi.spec_flaky_value()
local function again(): foreign int
  return ffi.spec_flaky_value() + ffi.spec_flaky_value()
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]]) },
            -- The module's header baseline (its probes include the module's
            -- generated FFI header) fails once, then recovers. A baseline
            -- failure is reported at the module's foreign import.
            { root = "speculative_flaky_baseline", expected = {
                "1:transient", "9:rejected", "9:" .. returned,
              }, source = header_module([[
local function first(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function second(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a - b
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]]) },
        }
        for _, case in ipairs(cases) do
            local modules = { [case.root] = case.source }
            local sync = check(modules, { case.root }, 1)
            local batched = check(modules, { case.root }, 4)
            assert.same(case.expected, diagnostics(sync.report))
            assert.equal(sync.report, batched.report)
            assert.truthy(count(batched.executions, speculative) > 0)
            if case.top_level then
                -- The top-level and the deferred request are one source.
                local failed, recovered
                for _, event in ipairs(batched.executions) do
                    if event.probe_kind == "c_operator" then
                        if event.batch_kind == "single" then failed = event
                        elseif event.outcome == "success" then recovered = event end
                    end
                end
                assert.equal("infrastructure_failure", failed.outcome)
                assert.equal(failed.key, recovered.key)
            end
            close(sync)
            close(batched)
        end
    end)

    local invalid_return = "types in return do not match, expected foreign int " ..
        "but found invalid type"

    local function baseline_chronology(source, failures, expected, candidates, retries)
        local root = "speculative_flaky_baseline_" .. failures
        local modules = { [root] = header_module(source) }
        local sync = check(modules, { root }, 1)
        local batched = check(modules, { root }, 4)
        assert.same(expected, diagnostics(sync.report))
        -- Compare every byte: diagnostic text, file/line/column, order,
        -- multiplicity, and the dependent Invalid-type return errors.
        assert.equal(sync.report, batched.report)
        for _, outcome in ipairs({ sync, batched }) do
            assert.equal(failures + 1, count(outcome.executions, function(event)
                return event.probe_kind == "header_baseline"
            end))
            assert.equal(failures, count(outcome.executions, function(event)
                return event.probe_kind == "header_baseline" and
                    event.outcome == "infrastructure_failure"
            end))
            assert.equal(candidates, count(outcome.executions, function(event)
                return event.probe_kind == "c_operator"
            end))
        end
        assert.equal(0, count(sync.executions, speculative))
        assert.equal(candidates - (retries or 0),
            count(batched.executions, speculative))
        assert.equal(1, count(batched.executions, function(event)
            return speculative(event) and event.outcome == "compiler_rejection"
        end))
        close(sync)
        close(batched)
    end

    it("replays a candidate's baseline failure before a later same-source success",
    function()
        baseline_chronology([[
local function first(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function second(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]], 2, {
            "1:transient", "3:transient", "3:" .. invalid_return,
            "9:rejected", "9:" .. invalid_return,
        }, 2)
    end)

    it("consumes the nested baseline before a later uncached distinct candidate",
    function()
        baseline_chronology([[
local function first(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function second(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function distinct(a: foreign speculative_flaky_t, b: foreign speculative_flaky_t): foreign int
  return a - b
end
local function retry_distinct(a: foreign speculative_flaky_t, b: foreign speculative_flaky_t): foreign int
  return a - b
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]], 2, {
            "1:transient", "3:transient", "3:" .. invalid_return,
            "9:transient", "9:" .. invalid_return,
            "15:rejected", "15:" .. invalid_return,
        }, 4, 1)
    end)

    it("preserves multiple baseline-gated candidate failures in occurrence order",
    function()
        baseline_chronology([[
local function first(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function second(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function third(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function fourth(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function distinct(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a - b
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]], 4, {
            "1:transient", "3:transient", "3:" .. invalid_return,
            "6:transient", "6:" .. invalid_return,
            "9:transient", "9:" .. invalid_return,
            "18:rejected", "18:" .. invalid_return,
        }, 3)
    end)

    it("keep a wide enumerator's range check synchronous", function()
        local modules = { wide = header_module([[
local function zero(): integer
  return ffi.SPEC_WIDE_ZERO as integer
end
local function high(): integer
  return ffi.SPEC_WIDE_HIGH as integer
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a | b
end
]]) }
        local sync = check(modules, { "wide" }, 1)
        local batched = check(modules, { "wide" }, 4)
        assert.equal(sync.report, batched.report)
        assert.matches("C enumerator 'SPEC_WIDE_HIGH' is outside the range of lua_Integer",
            sync.report, 1, true)
        assert.falsy(sync.report:find("SPEC_WIDE_ZERO", 1, true))
        assert.truthy(count(batched.executions, speculative) > 0)
        -- One accepted and one rejected range check, both at their use.
        for _, outcome in ipairs({ sync, batched }) do
            local range_checks = 0
            for _, event in ipairs(outcome.executions) do
                if event.probe_kind == "declaration_compatibility" then
                    range_checks = range_checks + 1
                    assert.equal("single", event.batch_kind)
                end
            end
            assert.equal(2, range_checks)
        end
        close(sync)
        close(batched)
    end)

    it("report failing baselines and unrenderable conversions synchronously",
    function()
        local modules = {
            -- Its probes include `speculative_broken_baseline.ffi.h`, whose
            -- baseline the fixture compiler always rejects.
            speculative_broken_baseline = header_module([[
local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function view(p: foreign *spec_item): foreign *spec_other
  return p
end
]]),
            anonymous = 'foreign import "' .. FIXTURE ..
                '/speculative_anonymous.h"\n' .. [[
local function anonymous(): foreign *spec_other
  return ffi.spec_anonymous_first()
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]],
        }
        local roots = { "speculative_broken_baseline", "anonymous" }
        local sync = check(modules, roots, 1)
        local batched = check(modules, roots, 4)
        assert.equal(sync.report, batched.report)
        local _, baseline_failures = sync.report:gsub(
            "foreign header baseline failed", "")
        assert.equal(2, baseline_failures)
        assert.matches("cannot render anonymous C struct", sync.report, 1, true)
        -- Nothing of the broken context is deferred; the other module's
        -- rejection is, and its recheck renders the conversion again.
        for _, event in ipairs(batched.executions) do
            if event.batch_kind == "speculative" then
                assert.equal("anonymous", event.module)
            end
        end
        assert.truthy(count(batched.executions, speculative) > 0)
        close(sync)
        close(batched)
    end)

    it("follow ordered header contexts and header changes between invocations",
    function()
        local directory = assert(compiler_io.new_sync():tmpname())
        if platform.windows then
            directory = assert(platform.path.normalize(directory))
        end
        os.remove(directory)
        assert(lfs.mkdir(directory))
        local first_header = directory .. "/speculative_first.h"
        local second_header = directory .. "/speculative_second.h"
        local function write_header(path, contents)
            local file = assert(io.open(path, "wb"))
            assert(file:write(contents))
            assert(file:close())
        end
        local ok, err = pcall(function()
            local function guarded(name, body)
                return "#ifndef " .. name .. "\n#define " .. name .. "\n" ..
                    body .. "#endif\n"
            end
            write_header(first_header, guarded("SPECULATIVE_FIRST_H",
                '#include "' .. HEADER .. '"\ntypedef int spec_changing_t;\n'))
            write_header(second_header, guarded("SPECULATIVE_SECOND_H",
                '#include "' .. first_header .. '"\n' ..
                "typedef spec_changing_t spec_second_t;\n"))
            local modules = { changing = 'foreign import "' .. first_header ..
                '"\nforeign import "' .. second_header .. '"\n' .. [[
local function add(a: foreign spec_changing_t, b: foreign spec_second_t): foreign int
  return a + b
end
local function view(p: foreign *spec_item): foreign *spec_other
  return p
end
local function rejected(a: foreign speculative_reject_t, b: foreign speculative_reject_t): foreign int
  return a * b
end
]] }
            local before_sync = check(modules, { "changing" }, 1)
            local before_batched = check(modules, { "changing" }, 4)
            assert.equal(before_sync.report, before_batched.report)
            assert.same({ "10:rejected", "10:types in return do not match, " ..
                "expected foreign int but found invalid type" },
                diagnostics(before_sync.report))
            close(before_sync)
            close(before_batched)
            -- Physically change the first header between invocations.
            write_header(first_header, guarded("SPECULATIVE_FIRST_H",
                '#include "' .. HEADER .. '"\n' ..
                "typedef struct spec_item spec_changing_t;\n"))
            local after_sync = check(modules, { "changing" }, 1)
            local after_batched = check(modules, { "changing" }, 4)
            assert.equal(after_sync.report, after_batched.report)
            assert.not_equal(before_sync.report, after_sync.report)
            assert.truthy(count(after_batched.executions, speculative) > 0)
            close(after_sync)
            close(after_batched)
        end)
        remove_tree(directory)
        assert(ok, err)
    end)

    -- A deferred rejection changes later checking of the consumer: the
    -- abandoned pass types a pointer and reads a field of dep's untagged
    -- paint struct, which selects the carrier of dep's own enum in place.
    -- The synchronous check never reaches that read. The recheck restores
    -- the journaled carrier, so imported graphs, interfaces and a later
    -- root's generated C are the synchronous ones.
    it("leave a source-imported dependency's graph as the synchronous check does",
    function()
        local modules = {
            dep = header_module([[
record Point
  x: integer
  y: integer
end
function Point:area(): integer
  return self.x * self.y
end
interface Shape
  function area(): integer
end
record Box<|T|>
  item: T
end
function boxed<|T|>(item: T): Box<|T|>
  return Box.new(item)
end
function shape(point: Point): Shape
  return point
end
local function first_paint(): foreign *speculative_reject_paint
  return ffi.spec_first_paint()
end
]]),
            consumer = header_module([[
local dep = import "dep.titan"
local function area_of(shape: dep.Shape): integer
  return shape:area()
end
function use(): integer
  local box = dep.boxed(dep.Point.new(2, 3))
  local next = dep.first_paint() + 1
  return area_of(dep.shape(box.item)) + (next.color as integer)
end
]]),
            later = [[
local dep = import "dep.titan"
function total(): integer
  local box = dep.boxed(dep.Point.new(4, 5))
  local shape: dep.Shape = box.item
  return shape:area()
end
]],
        }
        -- The carrier state of dep's `spec_color`: the type of the `color`
        -- field of the paint struct that dep's source-visible `first_paint`
        -- returns.
        local function color_state(outcome)
            local seen, paint = {}, nil
            local function visit(value)
                if type(value) ~= "table" or seen[value] or paint then return end
                seen[value] = true
                if value._tag == "Type.CStruct" and type(value.fields) == "table" then
                    for _, field in ipairs(value.fields) do
                        if field.name == "color" then paint = value; return end
                    end
                end
                for _, child in pairs(value) do visit(child) end
            end
            visit({ outcome.imported.dep.type, outcome.imported.dep.ast })
            assert(paint, "dep exposes no paint struct")
            local color
            for _, field in ipairs(paint.fields) do
                if field.name == "color" then color = types.resolve_c_typedef(field.type) end
            end
            assert.equal("Type.CInteger", color._tag)
            return {
                spelling = color.spelling, signed = color.signed,
                rank = color.rank, bits = color.bits,
                validated = color._c_enum_validated,
            }
        end
        local roots = { "consumer", "later" }
        local sync = check(modules, roots, 1)
        local batched = check(modules, roots, 4)
        assert.equal(sync.report, batched.report)
        assert.matches("consumer:", sync.report, 1, true)
        assert.matches("configured C compiler rejected", sync.report, 1, true)
        assert.matches("later:$", sync.report)
        assert.truthy(count(batched.executions, function(event)
            return event.batch_kind == "speculative" and event.module == "consumer"
        end) > 0)
        -- The synchronous check never selects that enum's carrier; the
        -- abandoned pass did, and the journal restored it.
        assert.is_nil(color_state(sync).validated)
        assert.same(color_state(sync), color_state(batched))
        for _, name in ipairs({ "dep", "later" }) do
            assert.equal(types.serialize(sync.imported[name].type),
                types.serialize(batched.imported[name].type))
        end
        assert.equal(generated(sync, "later"), generated(batched, "later"))
        close(sync)
        close(batched)
    end)

    it("keep strategies that override run synchronous at four jobs", function()
        local jobs = require "titan-compiler.jobs"
        local modules = { mixed = MIXED }
        local sync = check(modules, { "mixed" }, 1)
        local entered = {}
        local refused = {}
        for _, name in ipairs({ "open_slots", "open_channel", "launch", "drive" }) do
            refused[name] = function()
                entered[#entered + 1] = name
                error("native process transport entered: " .. name)
            end
        end
        local cancellation = setmetatable({}, {
            __tostring = function() return "injected runner cancellation" end,
        })
        local function is_probe(argv)
            for _, argument in ipairs(argv) do
                if argument:match("%d%d%d%d%d%d%-[%w%-]+%.c$") then return true end
            end
            return false
        end
        with_fields(jobs, refused, function()
            for _, shape in ipairs({ "instance", "delegated" }) do
                for _, cancel in ipairs({ false, true }) do
                    local probes = 0
                    local base = compiler_io.new_sync()
                    local function run(_, argv, options)
                        if is_probe(argv) then
                            probes = probes + 1
                            -- The first candidate after the header baseline.
                            if cancel and probes == 2 then error(cancellation) end
                        end
                        return base:run(argv, options)
                    end
                    local strategy
                    if shape == "instance" then
                        strategy = compiler_io.new_sync()
                        strategy.run = run
                    else
                        local overriding = compiler_io.new_sync()
                        overriding.run = run
                        strategy = setmetatable({}, { __index = overriding })
                    end
                    if cancel then
                        local called, raised = pcall(check, modules, { "mixed" }, 4,
                            { io = strategy })
                        assert.is_false(called)
                        assert.equal(cancellation, raised)
                        assert.equal(2, probes)
                    else
                        local outcome = check(modules, { "mixed" }, 4, { io = strategy })
                        assert.equal(0, count(outcome.executions, speculative))
                        assert.equal(sync.report, outcome.report)
                        -- The overriding runner answered every compilation.
                        assert.equal(#sync.executions, probes)
                        close(outcome)
                    end
                end
            end
        end)
        assert.same({}, entered)
        close(sync)

        -- The driver's output-root wrapper overrides only `tmpname`, so the
        -- stock runner still batches through it.
        local output = assert(compiler_io.new_sync():tmpname())
        os.remove(output)
        assert(lfs.mkdir(output))
        local ok, err = pcall(function()
            local wrapped = check(modules, { "mixed" }, 4, { output_root = output })
            assert.truthy(count(wrapped.executions, speculative) > 0)
            assert.equal(sync.report, wrapped.report)
            close(wrapped)
        end)
        remove_tree(output)
        assert(ok, err)
    end)

    it("never defer the probes of a completion check", function()
        local completion = require "titan-compiler.completion"
        local source = ACCEPTED .. "function hole(): integer\n  return @\nend\n"
        local caret = assert(source:find("@", 1, true)) - 1
        local prepared = assert(completion.prepare("./accepted.titan",
            source:sub(1, caret) .. source:sub(caret + 2), caret))
        local outcome = check({ accepted = prepared.text }, { "accepted" }, 4,
            { completion = prepared.request })
        assert.truthy(#outcome.executions > 0)
        assert.equal(0, count(outcome.executions, speculative))
        assert.truthy(outcome.imported.accepted.completion)
        close(outcome)
    end)

    -- A ledger, channel or log-cleanup failure after every child launched
    -- still fails the whole batch: each deferred probe reports it, and no
    -- verdict of that batch is published.
    it("keep batch transport and cleanup failures visible and unpublished",
    function()
        local jobs = require "titan-compiler.jobs"
        local one = header_module([[
local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
]])
        local two = header_module([[
local function add(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a + b
end
local function sub(a: foreign spec_ok_t, b: foreign spec_ok_t): foreign int
  return a - b
end
]])
        local function faulted(fault, source, expected)
            local overrides = {}
            if fault == "release" or fault == "close" then
                local open_slots = jobs.open_slots
                overrides.open_slots = function(...)
                    local slots, err = open_slots(...)
                    if not slots then return nil, err end
                    local method = slots[fault]
                    slots[fault] = function(self)
                        method(self)
                        return nil, "injected " .. fault .. " failure"
                    end
                    return slots
                end
            elseif fault == "channel" then
                local close_channel = jobs.close_channel
                overrides.close_channel = function(channel)
                    close_channel(channel)
                    return nil, "injected channel failure"
                end
            else
                local protected_remove = jobs.protected_remove
                overrides.protected_remove = function(path)
                    local removed, err = protected_remove(path)
                    if not removed then return removed, err end
                    return nil, "injected log failure"
                end
            end
            local outcome = with_fields(jobs, overrides, function()
                return check({ faulty = source }, { "faulty" }, 4)
            end)
            local service = outcome.context.probe_service
            local keys = {}
            for _, event in ipairs(outcome.executions) do
                if event.batch_kind == "speculative" then
                    assert.equal("infrastructure_failure", event.outcome, fault)
                    assert.is_true(event.started, fault)
                    assert.is_nil(service.result_cache[event.key], fault)
                    keys[#keys + 1] = event.key
                end
            end
            assert.equal(expected, #keys, fault)
            local _, reported = outcome.report:gsub(
                "the native C probe batch failed: [^\n]*injected " .. fault ..
                    " failure", "")
            assert.equal(expected, reported, outcome.report)
            close(outcome)
        end
        for _, fault in ipairs({ "release", "close", "channel", "log" }) do
            faulted(fault, two, 2)
        end
        -- One deferred probe takes the one-command branch.
        faulted("close", one, 1)
    end)
end)

-- The complete titanc path (folder sources, the driver's reparse closure,
-- `Sync:run_batch` and generated-C compilation) with one versus four jobs,
-- launched through the compiler I/O process transport on every platform.
describe("titanc speculative probe batches", function()
    local installed_prefix = require "spec.support.installed_prefix"
    local PREFIX = installed_prefix.active()
    local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
    local workspace

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

    local function count_lines(path)
        local _, lines = (read(path) or ""):gsub("\n", "")
        return lines
    end

    -- One titanc run without a parent Make. Diagnostics name the source
    -- tree, never the output tree.
    local function titanc(jobs, output, options)
        options = options or {}
        local argv = {
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
            "-u", "TITAN_JOBS",
        }
        for _, assignment in ipairs(options.environment or {}) do
            argv[#argv + 1] = assignment
        end
        for _, argument in ipairs({
            "CC=" .. probe_compiler(),
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROOT=" .. PREFIX,
            "TITAN_RUNTIME_PREBUILT=1", LUA, "-e",
            "package.path = " .. string.format("%q",
                ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") .. " .. package.path",
            ROOT .. "/titanc", "-q", "--jobs", tostring(jobs), "-c", "-o", output,
            "--tree", workspace .. "/src",
        }) do
            argv[#argv + 1] = argument
        end
        for _, argument in ipairs(options.arguments or {}) do
            argv[#argv + 1] = argument
        end
        for _, root in ipairs(options.roots or { "app" }) do
            argv[#argv + 1] = root
        end
        local result = compiler_io.new_sync():run(argv)
        local text = result.output or result.diagnostic or ""
        if platform.windows then text = text:gsub("\r\n", "\n") end
        return result.ok == true, text
    end

    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        if platform.windows then
            workspace = assert(platform.path.normalize(workspace))
        end
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

    it("reuse a valid dependency object without any new probe", function()
        local state = workspace .. "/state"
        assert(lfs.mkdir(state))
        write(workspace .. "/src/dep.titan", ACCEPTED)
        write(workspace .. "/src/app/app.titan", [[
local dep = import "dep"
function value(): integer
  return dep.total()
end
]])
        local environment = { "SPECULATIVE_PROBE_STATE=" .. state }
        local built, built_output = titanc(4, workspace .. "/out",
            { environment = environment, roots = { "dep" } })
        assert.truthy(built, built_output)
        local probes = count_lines(state .. "/probes")
        assert.truthy(probes > 0)
        local outputs = {}
        for _, jobs in ipairs({ 1, 4 }) do
            local ok, output = titanc(jobs, workspace .. "/out", {
                environment = environment, arguments = { "--incremental" },
            })
            assert.truthy(ok, output)
            assert.equal(probes, count_lines(state .. "/probes"), output)
            outputs[#outputs + 1] = output
        end
        assert.equal(outputs[1], outputs[2])
        assert.truthy(read(workspace .. "/out/app/app.o"))
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

    it("uses the local cap for ordinary checks except under a serial POSIX Make",
    function()
        with_makeflags(nil)
        assert.equal(1, driver.probe_batch_jobs({}))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 1 }))
        assert.equal(4, driver.probe_batch_jobs({ jobs = 4 }))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 4, analysis_only = true }))
        assert.equal(1, driver.probe_batch_jobs({ jobs = 4, completion = {} }))
        with_makeflags("-j1")
        for _, windows in ipairs({ false, true }) do
            with_fields(platform, { windows = windows }, function()
                assert.equal(windows and 4 or 1,
                    driver.probe_batch_jobs({ jobs = 4 }))
                assert.equal(1, driver.probe_batch_jobs({ jobs = 1 }))
                assert.equal(1, driver.probe_batch_jobs({
                    jobs = 4, analysis_only = true,
                }))
                assert.equal(1, driver.probe_batch_jobs({
                    jobs = 4, completion = {},
                }))
            end)
        end
        with_makeflags("-j4 --jobserver-auth=fifo:/tmp/titan-unused-pool")
        assert.equal(4, driver.probe_batch_jobs({ jobs = 4 }))
        assert.error_matches(function()
            driver.new_resolver_context({ jobs = 0 })
        end, "jobs must be a positive integer", 1, true)
    end)
end)
