local assert = require "luassert"
local checks = dofile("scripts/browser_stdlib.lua")
local types = require "titan-compiler.types"
local strategy = require("titan-compiler.io").new_sync()
local temporary = require "spec.support.temporary"
local installed_prefix = require "spec.support.installed_prefix"
local platform = require "titan-compiler.platform"

describe("browser core stdlib build checks", function()
    local scratch = {}
    after_each(function()
        for _, path in ipairs(scratch) do os.remove(path) end
        scratch = {}
    end)

    local function root_plan(overrides)
        local file = temporary.name("-browser-roots.mk")
        scratch[#scratch + 1] = file
        assert(strategy:write_file(file, [[
include spec/support/stdlib_test_modules.mk
.PHONY: plan
plan:
	@$(strip $(TITAN_STDLIB_BROWSER_TEST_ROOTS_CHECK)) printf '%s\n' 'roots=$(TITAN_STDLIB_BROWSER_TEST_ROOTS)'
]]))
        local argv = {"env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
            "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "make", "--no-print-directory", "-f", file, "plan"}
        for _, option in ipairs(overrides or {}) do argv[#argv + 1] = option end
        return strategy:run(argv, {stderr_to_stdout = true})
    end

    it("keeps all seventeen portable owners in the single-image root inventory", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        local result = root_plan()
        assert.is_true(result.ok, result.output)
        local roots, count = {}, 0
        for root in assert(result.output:match("roots=([^\r\n]+)")):gmatch("%S+") do
            assert.is_nil(roots[root], root)
            roots[root], count = true, count + 1
        end
        assert.equal(17, count, "the audited browser inventory has 17 owners; change this deliberately")
        assert.is_true(roots["transfer.tests"])
        assert.is_true(roots["protobuf.tests"])
        assert.is_true(roots["async.tests"])
        assert.is_true(roots["timer.tests"])
    end)

    it("rejects empty and duplicate owner inventories before build setup", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        assert.is_true(root_plan({"TITAN_STDLIB_BROWSER_TEST_ROOTS=first.tests second.tests"}).ok)
        local guard = temporary.name("-browser-root-preflight")
        scratch[#scratch + 1] = guard
        local sentinel = "owner validation must precede build setup\n"
        assert(strategy:write_file(guard, sentinel))
        for _, case in ipairs({
            { "", "browser stdlib owner inventory is empty" },
            { "first.tests first.tests", "duplicate browser stdlib owner inventory" },
        }) do
            local rejected = strategy:run({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
                "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "make", "--no-print-directory",
                "-f", "Makefile", "titan-stdlib-browser-test",
                "TITAN_BROWSER_TEST_BUILD_DIR=" .. guard,
                "TITAN_STDLIB_BROWSER_TEST_ROOTS=" .. case[1],
            }, {stderr_to_stdout = true})
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find(case[2], 1, true), rejected.output)
            assert.equal(sentinel, assert(strategy:read_file(guard)))
        end
    end)

    it("keeps the image and per-engine evidence in the CI failure artifact", function()
        local complete = assert(strategy:read_file(".github/workflows/ci.yml"))
        local function job(name)
            local marker = "\n  " .. name .. ":\n"
            local first = assert(complete:find(marker, 1, true), name)
            local finish = complete:find("\n  [%w_-]+:%s*\n", first + #marker)
                or (#complete + 1)
            return complete:sub(first, finish - 1)
        end
        local workflow = job("browser-stdlib")
        assert.is_nil(job("browser-toolchain"):find("make titan-stdlib-browser-test", 1, true))
        local suite, artifact
        for first in workflow:gmatch("()\n      %- [^\n]*\n") do
            local finish = workflow:find("\n      - ", first + 1, true) or (#workflow + 1)
            local step = workflow:sub(first, finish - 1)
            if step:find("make titan-stdlib-browser-test", 1, true) then
                assert.is_nil(suite, "duplicate browser stdlib suite step")
                suite = step
            end
            if step:find("name: browser-stdlib-failure", 1, true) then
                assert.is_nil(artifact, "duplicate browser stdlib failure artifact")
                artifact = step
            end
        end
        assert.truthy(suite, "browser-stdlib must run the browser stdlib target")
        assert.truthy(suite:find("set -euo pipefail", 1, true), suite)
        assert.truthy(suite:find('tee "$RUNNER_TEMP/browser-stdlib.log"', 1, true), suite)
        assert.truthy(artifact, "browser-stdlib must retain its own failure evidence")
        for _, contract in ipairs({
            "if: failure()", "uses: actions/upload-artifact@v7", "retention-days: 7",
            "${{ runner.temp }}/browser-*.log",
            "out/browser-stdlib/*.log", "out/browser-stdlib/images/*.mjs",
            "out/browser-stdlib/images/*.wasm", "out/browser-stdlib/images/*.wasm.map",
            "out/browser-stdlib/*roots.txt", "out/browser-stdlib/members.md",
        }) do
            assert.truthy(artifact:find(contract, 1, true), contract)
        end
        assert.is_nil(artifact:find("out/browser-stdlib/\n", 1, true))
    end)

    it("keeps native stdlib dependencies out of the browser provider recipe", function()
        local makefile = assert(strategy:read_file("Makefile"))
        local environment = assert(makefile:match("\nBROWSER_SDK_ENV%s*[:?+]?=%s*(.-)\n\nbrowser%-sdk:"))
        local recipe = assert(makefile:match("\nbrowser%-sdk:[^\n]*\n(.-)\n\n"))
        for _, forbidden in ipairs({ "STDLIB_EXTRA_OBJECTS", "LIBUV_", "OPENSSL_", "LLHTTP_", "SQLITE3_" }) do
            assert.is_nil((environment .. recipe):find(forbidden, 1, true), forbidden)
        end
        -- The real SDK spec builds with poisoned ambient CPPFLAGS and checks
        -- the exact native archive members instead of pinning recipe spelling.
    end)

    it("rejects forbidden header and archive dependencies including injected libuv headers", function()
        for _, path in ipairs({ "/fixture/uv.h", "/fixture/uv/unix.h", "/fixture/openssl/ssl.h",
            "/fixture/llhttp.h", "/fixture/sqlite3.h", "/fixture/sqlite3ext.h",
            "/fixture/libuv.a", "/fixture/libssl.a", "/fixture/libcrypto.a",
            "/fixture/libllhttp.a", "/fixture/libsqlite3.a",
            "/fixture/libtitan-llhttp.a", "/fixture/libtitan-sqlite3.a" }) do
            local ok, err = checks.check_path(path)
            assert.is_nil(ok, path)
            assert.truthy(err:find("forbidden browser stdlib dependency", 1, true), err)
        end
        for _, stem in ipairs({ "libuv", "libssl", "libcrypto", "libopenssl",
            "libllhttp", "libsqlite3", "libtitan-llhttp", "libtitan-sqlite3" }) do
            for _, suffix in ipairs({ ".a", "_a.a", "_1.48.a", "-static.a", ".1.a" }) do
                local path = "/fixture/" .. stem .. suffix
                local ok, err = checks.check_path(path)
                assert.is_nil(ok, path)
                assert.truthy(err:find(path, 1, true), err)
            end
        end
        local ok, err = checks.check_headers({ c_header_dependencies = {
            { kind = "file", path = "/injected/libuv/include/uv.h", identity = "fixture" },
        } })
        assert.is_nil(ok)
        assert.truthy(err:find("/injected/libuv/include/uv.h", 1, true))
        assert(checks.check_path("/vendor/lpeglabel/titan_lpeglabel.h"))
        assert(checks.check_path("/sdk/libtitan-lpeglabel.a"))
    end)

    it("rejects defined and undefined symbols from every excluded C library", function()
        for _, name in ipairs({ "uv_run", "SSL_new", "OPENSSL_init_crypto", "llhttp_init", "sqlite3_open" }) do
            for _, defined in ipairs({ true, false }) do
                local ok, err = checks.check_archive("provider.a", { members = {
                    { display_name = "intruder.o", bytes = "", object = { symbols = {
                        { name = name, defined = defined },
                    } } },
                } })
                assert.is_nil(ok)
                assert.truthy(err:find(name, 1, true), err)
            end
        end
    end)

    it("audits internal image names independently of optimizer retention", function()
        local function section(id, bytes)
            assert.is_true(#bytes < 128)
            return string.char(id, #bytes) .. bytes
        end
        local function image(name)
            local function_names = "\1\0" .. string.char(#name) .. name
            return "\0asm\1\0\0\0" ..
                section(1, "\1\96\0\0") ..
                section(3, "\1\0") ..
                section(10, "\1\2\0\11") ..
                section(0, "\4name" .. section(1, function_names))
        end
        assert(checks.check_image(image("portable_entry"), "control.wasm"))
        local ok, err = checks.check_image(image("uv_closure_intruder"), "intruder.wasm")
        assert.is_nil(ok)
        assert.equal("intruder.wasm: forbidden browser stdlib symbol uv_closure_intruder", err)
    end)

    it("derives raw foreign entries and fails on any unrecorded member change", function()
        local function provider(raw_name)
            local modtype = types.Module("fixture", {
                types.ModuleMember("fixture", raw_name,
                    types.CFunction({ types.CInteger("int", true, 3, 32) }, types.CVoid(), false, nil), nil),
            }, {})
            return { key_order = { "fixture" }, entries = { fixture = { types = types.serialize(modtype) } } }
        end
        local rows = assert(checks.inventory(provider("raw_entry"), provider("raw_entry")))
        assert.equal(1, #rows)
        assert.equal("raw_entry", rows[1].name)
        assert.equal("raw foreign function", rows[1].kind)
        assert.truthy(checks.member_table(rows):find("raw_entry", 1, true))
        local ok, err = checks.inventory(provider("raw_entry"), provider("different_entry"))
        assert.is_nil(ok)
        assert.truthy(err:find("unrecorded public interface differences", 1, true))
    end)

    it("compares every shared module and only exempts the browser-only bridge module", function()
        local function entry(modname, member)
            local modtype = types.Module(modname, {
                types.ModuleMember(modname, member,
                    types.Function({ types.Integer() }, { types.Integer() }, false, nil, nil), { "value" }),
            }, {})
            return { types = types.serialize(modtype) }
        end
        local native = { key_order = { "fixture" }, entries = { fixture = entry("fixture", "shared") } }
        local rows, modules = checks.inventory(native, { key_order = { "fixture", "titan.browser" },
            entries = { fixture = entry("fixture", "shared"), ["titan.browser"] = entry("titan.browser", "binding") } })
        assert.equal(1, modules)
        assert.equal(1, #rows)
        assert.equal("fixture", rows[1].module)
        local ok, err = checks.inventory(native, { key_order = { "fixture", "titan.other" },
            entries = { fixture = entry("fixture", "shared"), ["titan.other"] = entry("titan.other", "binding") } })
        assert.is_nil(ok)
        assert.equal("missing native module titan.other", err)
    end)

    it("includes public nominal fields, statics and methods from ordinary module members", function()
        local owner = "fixture.Box"
        local record = types.Record(owner, {
            types.Field(owner, "item", types.Integer(), 0, true),
        }, {
            new = types.StaticMethod(owner, "new", {}, {types.Nominal(owner)}, nil, nil, {}),
        }, {
            get = types.Method(owner, "get", {}, {types.Integer()}, nil, nil, {}),
        }, 1)
        local members = checks.members(types.Module("fixture", {
            types.ModuleMember("fixture", "Box", record, nil),
        }, {}))
        assert.equal("record", members.Box.kind)
        assert.equal("field", members["Box.item"].kind)
        assert.equal("integer (readonly)", members["Box.item"].signature)
        assert.equal("static function", members["Box.new"].kind)
        assert.equal("method", members["Box:get"].kind)
    end)

    it("compares named-call parameter metadata as well as rendered function types", function()
        local function provider(parameter_name)
            local modtype = types.Module("fixture", {
                types.ModuleMember("fixture", "f", types.Function({types.Integer()}, {types.Integer()}, false, nil, nil),
                    {parameter_name}),
            }, {})
            return { key_order = {"fixture"}, entries = { fixture = { types = types.serialize(modtype) } } }
        end
        local rows, err = checks.inventory(provider("left"), provider("right"))
        assert.is_nil(rows)
        assert.truthy(err:find("semantic declaration differs", 1, true), err)
    end)

    it("accepts exactly the recorded omissions and opaque records", function()
        local function provider(browser)
            local members = {
                types.ModuleMember("fixture", "shared", types.Function({}, {}, false, nil, nil), {}),
                types.ModuleMember("fixture", "Opaque", types.Record("fixture.Opaque", {}, {},
                    browser and {} or { close = types.Method("fixture.Opaque", "close", {}, {}, nil, nil, {}) },
                    browser and 1 or 3), nil),
            }
            if not browser then
                members[#members + 1] = types.ModuleMember("fixture", "gone", types.Function({}, {}, false, nil, nil), {})
                members[#members + 1] = types.ModuleMember("fixture", "Gone", types.Record("fixture.Gone", {}, {},
                    { run = types.Method("fixture.Gone", "run", {}, {}, nil, nil, {}) }, 1), nil)
            end
            return { key_order = { "fixture" },
                entries = { fixture = { types = types.serialize(types.Module("fixture", members, {})) } } }
        end
        local function recorded(omitted, opaque)
            return { fixture = { omitted = omitted, opaque = opaque } }
        end
        local rows, modules, differences = checks.inventory(provider(false), provider(true),
            recorded({ "gone", "Gone", "Opaque:close" }, { "Opaque" }))
        assert.equal(1, modules)
        assert.same({ "shared" }, { rows[1].name, rows[2] })
        local kinds = {}
        for _, row in ipairs(differences) do kinds[#kinds + 1] = row.name .. "=" .. row.difference end
        assert.same({ "gone=omitted", "Gone=omitted", "Opaque:close=omitted", "Opaque=opaque" }, kinds)
        local text = checks.member_table(rows, differences)
        assert.truthy(text:find("## Recorded browser differences", 1, true), text)
        assert.truthy(text:find("| `fixture` | `Opaque` | opaque | record |", 1, true), text)
        for _, case in ipairs({
            { recorded({ "Gone", "Opaque:close" }, { "Opaque" }), "fixture.gone: native=" },
            { recorded({ "gone", "Gone", "Opaque:close", "shared" }, { "Opaque" }),
                "fixture.shared: recorded omission is in the browser interface" },
            { recorded({ "gone", "Gone", "Opaque:close", "absent" }, { "Opaque" }),
                "fixture.absent: recorded omission is not a native member" },
            { recorded({ "gone", "Gone", "Opaque:close" }, { "shared" }),
                "fixture.shared: recorded opaque record is not the same record in both interfaces" },
            { recorded({ "gone", "Gone", "Opaque:close" }, {}), "(semantic declaration differs)" },
        }) do
            local ok, err = checks.inventory(provider(false), provider(true), case[1])
            assert.is_nil(ok)
            assert.truthy(err:find(case[2], 1, true), err)
        end
    end)

    it("prints the per-owner audit and failure counts before rejecting a failed run", function()
        local log, roots = temporary.name("-browser-failed.log"), temporary.name("-browser-roots.txt")
        scratch = {log, roots}
        assert(strategy:write_file(roots, "fixture.tests\n"))
        assert(strategy:write_file(log, [[
[==========] Running Titan tests.
[ RUN      ] fixture.tests.test_fail
[  FAILED  ] fixture.tests.test_fail (1.25 ms)
[----------] fixture.tests (1.25 ms total)
[==========] 1 test ran. (1.50 ms total)
[  PASSED  ] 0 tests.
[  FAILED  ] 1 test.
[  FAILED  ] fixture.tests.test_fail
]]))
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local result = strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua", "output",
            roots, "test_fail", log},
            {stderr_to_stdout = true})
        assert.is_false(result.ok)
        assert.truthy(result.output:find("Browser stdlib owner fixture.tests: 1 cases", 1, true), result.output)
        assert.truthy(result.output:find("selected=1 passed=0 skipped=0 failed=1 owners=1/1", 1, true), result.output)
        assert.truthy(result.output:find(
            "Browser stdlib owner fixture.tests: 1 cases (1.25 ms total)", 1, true), result.output)
        assert.truthy(result.output:find(
            "Browser stdlib image stdlib: 1 cases (1.50 ms total)", 1, true), result.output)
    end)

    it("audits a case emitting stderr in the middle of a report line from stdout alone", function()
        if platform.windows then
            pending("browser suite shell wrapper is Unix-only")
            return
        end
        local log = temporary.name("-browser-stdout.log")
        local diagnostics = temporary.name("-browser-stderr.log")
        local roots = temporary.name("-browser-roots.txt")
        local producer = temporary.name("-browser-report.lua")
        scratch = {log, diagnostics, roots, producer}
        assert(strategy:write_file(roots, "fixture.tests\n"))
        local report = [[
[==========] Running Titan tests.
[ RUN      ] fixture.tests.test_stderr
[       OK ] fixture.tests.test_stderr (1.25 ms)
[----------] fixture.tests (1.25 ms total)
[==========] 1 test ran. (1.50 ms total)
[  PASSED  ] 1 test.
]]
        local warning = "Lua warning: error in coroutine cleanup (expected fixture warning)\n"
        assert(strategy:write_file(producer, string.format([[
io.stdout:setvbuf("no")
io.stdout:write("[==========] Running Titan tests.\n[ RUN      ] fixture.tests.")
io.stderr:write(%q)
io.stderr:flush()
io.stdout:write("test_stderr\n[       OK ] fixture.tests.test_stderr (1.25 ms)\n[----------] fixture.tests (1.25 ms total)\n[==========] 1 test ran. (1.50 ms total)\n[  PASSED  ] 1 test.\n")
if arg[1] == "fail" then os.exit(7) end
]], warning)))
        local lua = installed_prefix.active() .. "/bin/lua"
        local captured = strategy:run({"bash", "scripts/run_browser_stdlib.sh",
            log, diagnostics, lua, producer}, {stderr_to_stdout = true})
        assert.is_true(captured.ok, captured.output)
        assert.equal(report, assert(strategy:read_file(log)))
        assert.equal(warning, assert(strategy:read_file(diagnostics)))
        assert.truthy(captured.output:find(warning, 1, true), captured.output)
        local audited = strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua",
            "output", roots, "", log}, {stderr_to_stdout = true})
        assert.is_true(audited.ok, audited.output)
        assert.truthy(audited.output:find("Browser stdlib owner fixture.tests: 1 cases", 1, true),
            audited.output)
        assert.truthy(audited.output:find("selected=1 passed=1 skipped=0 failed=0 owners=1/1", 1, true),
            audited.output)
        local failed = strategy:run({"bash", "scripts/run_browser_stdlib.sh",
            log, diagnostics, lua, producer, "fail"}, {stderr_to_stdout = true})
        assert.is_false(failed.ok, "a positive report must not hide a nonzero image status")
        assert.equal(report, assert(strategy:read_file(log)))
        assert.equal(warning, assert(strategy:read_file(diagnostics)))
    end)

    it("audits one complete image with strict timing, owner, failure, skip and filter accounting", function()
        local function file(suffix, contents)
            local path = temporary.name(suffix)
            scratch[#scratch + 1] = path
            assert(strategy:write_file(path, contents))
            return path
        end
        local function report(owners, outcome)
            local rows = { "[==========] Running Titan tests." }
            local failed, skipped = 0, 0
            for index, owner in ipairs(owners) do
                local name = owner .. ".test_case"
                rows[#rows + 1] = "[ RUN      ] " .. name
                if outcome == "failed" and index == #owners then
                    rows[#rows + 1] = "[  FAILED  ] " .. name .. " (0.25 ms)"
                    failed = failed + 1
                elseif outcome == "skipped" and index == #owners then
                    rows[#rows + 1] = "[  SKIPPED ] " .. name .. " (capability: fixture) (0.25 ms)"
                    skipped = skipped + 1
                else
                    rows[#rows + 1] = "[       OK ] " .. name .. " (0.25 ms)"
                end
                rows[#rows + 1] = "[----------] " .. owner .. " (0.25 ms total)"
            end
            rows[#rows + 1] = "[==========] " .. #owners .. " tests ran. (1.00 ms total)"
            rows[#rows + 1] = "[  PASSED  ] " .. (#owners - failed - skipped) .. " tests."
            if skipped > 0 then rows[#rows + 1] = "[  SKIPPED ] " .. skipped .. " tests." end
            if failed > 0 then
                rows[#rows + 1] = "[  FAILED  ] " .. failed .. " tests."
                rows[#rows + 1] = "[  FAILED  ] " .. owners[#owners] .. ".test_case"
            end
            return table.concat(rows, "\n") .. "\n"
        end
        local roots = file("-browser-roots.txt", "first.tests\nsecond.tests\n")
        local log = file("-browser-stdlib.log", "")
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local function audit(contents, filter)
            assert(strategy:write_file(log, contents))
            return strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua", "output",
                roots, filter or "", log}, {stderr_to_stdout = true})
        end
        local complete = report({ "first.tests", "second.tests" })
        for _, contents in ipairs({ complete, (complete:gsub("\n", "\r\n")) }) do
            local passed = audit(contents)
            assert.is_true(passed.ok, passed.output)
            for _, expected in ipairs({
                "Browser stdlib image stdlib: 2 cases (1.00 ms total)",
                "Browser stdlib owner first.tests: 1 cases (0.25 ms total)",
                "Browser stdlib owner second.tests: 1 cases (0.25 ms total)",
                "selected=2 passed=2 skipped=0 failed=0 owners=2/2 images=1",
            }) do assert.truthy(passed.output:find(expected, 1, true), passed.output) end
        end
        local failed = audit(report({ "first.tests", "second.tests" }, "failed"))
        assert.is_false(failed.ok, failed.output)
        assert.truthy(failed.output:find("selected=2 passed=1 skipped=0 failed=1 owners=2/2 images=1", 1, true), failed.output)
        local skipped = audit(report({ "first.tests", "second.tests" }, "skipped"))
        assert.is_true(skipped.ok, skipped.output)
        assert.truthy(skipped.output:find("selected=2 passed=1 skipped=1 failed=0", 1, true), skipped.output)
        local filtered = audit(report({ "first.tests" }), "^first[.]")
        assert.is_true(filtered.ok, filtered.output)
        assert.truthy(filtered.output:find("owners=1/2 images=1 (filtered)", 1, true), filtered.output)
        for _, case in ipairs({
            { report({}), "selected no cases", "^none$" },
            { report({ "first.tests" }), "did not execute" },
            { report({ "foreign.tests", "second.tests" }), "outside native root inventory" },
            { report({ "first.tests", "first.tests" }), "duplicate" },
            { complete:gsub("0%.25 ms%)", "0.2 ms)"), "malformed native case timing" },
            { complete:gsub("%[----------%] second.tests %(0%.25 ms total%)\n", ""), "missing native owner timing" },
            { complete:gsub("second.tests %(0%.25 ms total%)", "second.tests (0.25 ms total)\n[----------] second.tests (0.25 ms total)"), "duplicate native owner timing" },
            { complete:gsub("second.tests %(0%.25 ms total%)", "foreign.tests (0.25 ms total)"), "timing outside native root inventory" },
            { complete:gsub("0%.25 ms total", "9.00 ms total"), "differs from top-level cases" },
            { complete:gsub("1%.00 ms total", "0.00 ms total"), "shorter than owner intervals" },
            { complete .. "[       OK ] second.tests.test_case (0.25 ms)\n", "duplicate native result" },
            { complete:gsub("%[       OK %] second.tests.test_case %(0%.25 ms%)\n", ""), "did not finish" },
            { complete:gsub("ran%. %(1%.00 ms total%)", "ran."), "malformed native run timing" },
        }) do
            local rejected = audit(case[1], case[3])
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find(case[2], 1, true), rejected.output)
        end
        for _, malformed in ipairs({
            (complete:gsub("\n", "\r\r\n")),
            (complete:gsub("0%.25 ms%)", "0.2\r5 ms)")),
            (complete:gsub("\n$", "\r")),
            (complete:gsub("\n", "\r")),
        }) do
            local rejected = audit(malformed)
            assert.is_false(rejected.ok, rejected.output)
        end
        for _, suffix in ipairs({
            "", " (-0.25 ms)", " (0.2 ms)", " (0.250 ms)", " (nan ms)",
            " (inf ms)", " (1e2 ms)", " (0,25 ms)", " (0.25 ms total)",
        }) do
            local malformed = complete:gsub("(%[       OK %] second.tests.test_case) %(0%.25 ms%)",
                function(prefix) return prefix .. suffix end)
            local rejected = audit(malformed)
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find("malformed native case timing", 1, true), rejected.output)
        end
    end)
end)
