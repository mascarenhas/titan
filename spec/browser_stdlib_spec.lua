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

    local function image_plan(overrides)
        local file = temporary.name("-browser-images.mk")
        scratch[#scratch + 1] = file
        assert(strategy:write_file(file, [[
include spec/support/stdlib_test_modules.mk
.PHONY: plan
plan:
	@$(strip $(TITAN_STDLIB_BROWSER_TEST_PLAN_CHECK)) printf '%s\n' 'budget=$(TITAN_STDLIB_BROWSER_TEST_IMAGE_MAX_BYTES)' 'roots=$(TITAN_STDLIB_BROWSER_TEST_ROOTS)' $(foreach image,$(TITAN_STDLIB_BROWSER_TEST_IMAGES),'image=$(image):$(strip $(TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_$(image)))')
]]))
        local argv = {"env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
            "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "make", "--no-print-directory", "-f", file, "plan"}
        for _, option in ipairs(overrides or {}) do argv[#argv + 1] = option end
        return strategy:run(argv, {stderr_to_stdout = true})
    end

    it("declares an exact owner partition and byte budget in the browser manifest", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        local result = image_plan()
        assert.is_true(result.ok, result.output)
        assert.truthy(result.output:find("budget=32000000", 1, true),
            "D14 deliberately pins the 32,000,000-byte browser image budget; do not loosen it to fit an oversized image")
        local roots = {}
        for root in assert(result.output:match("roots=([^\r\n]+)")):gmatch("%S+") do roots[root] = true end
        local owners, images = {}, 0
        for line in result.output:gmatch("[^\r\n]+") do
            local image, members = line:match("^image=([%w_-]+):(.*)$")
            if image then
                images = images + 1
                for owner in members:gmatch("%S+") do
                    assert.is_true(roots[owner], owner)
                    assert.is_nil(owners[owner], owner .. " occurs in two images")
                    owners[owner] = image
                end
            end
        end
        local count = 0
        for owner in pairs(roots) do assert.truthy(owners[owner], owner); count = count + 1 end
        assert.equal(15, count, "the audited browser inventory has 15 owners; change this deliberately")
        assert.is_true(images >= 2)
    end)

    it("rejects incomplete, duplicate, empty and unknown browser image assignments", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        local base = {
            "TITAN_STDLIB_BROWSER_TEST_ROOTS=first.tests second.tests",
            "TITAN_STDLIB_BROWSER_TEST_IMAGES=first second",
            "TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_first=first.tests",
            "TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_second=second.tests",
        }
        assert.is_true(image_plan(base).ok)
        for _, case in ipairs({
            {2, "TITAN_STDLIB_BROWSER_TEST_IMAGES=", "image manifest is empty"},
            {2, "TITAN_STDLIB_BROWSER_TEST_IMAGES=first first", "duplicate browser stdlib image"},
            {2, "TITAN_STDLIB_BROWSER_TEST_IMAGES=first", "unassigned browser stdlib owner"},
            {4, "TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_second=", "has no owners"},
            {4, "TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_second=first.tests", "assigned more than once"},
            {4, "TITAN_STDLIB_BROWSER_TEST_IMAGE_ROOTS_second=third.tests", "unknown browser stdlib owner"},
            {1, "TITAN_STDLIB_BROWSER_TEST_ROOTS=first.tests first.tests", "duplicate browser stdlib owner inventory"},
        }) do
            local options = {table.unpack(base)}
            options[case[1]] = case[2]
            local rejected = image_plan(options)
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find(case[3], 1, true), rejected.output)
        end
    end)

    it("rejects malformed image budgets before build setup or linking", function()
        if platform.windows then pending("browser suite Make target is Unix-only"); return end
        -- A regular file cannot become the output directory: a regressed
        -- preflight fails promptly at mkdir rather than starting a real link.
        local guard = temporary.name("-browser-budget-preflight")
        scratch[#scratch + 1] = guard
        local sentinel = "image budget validation must run before build setup\n"
        assert(strategy:write_file(guard, sentinel))
        for _, budget in ipairs({"", "0", "01", "-1", "abc", "32.0e6", "100000000"}) do
            local rejected = strategy:run({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
                "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "make", "--no-print-directory",
                "-f", "Makefile", "titan-stdlib-browser-test",
                "TITAN_BROWSER_TEST_BUILD_DIR=" .. guard,
                "TITAN_STDLIB_BROWSER_TEST_IMAGE_MAX_BYTES=" .. budget,
            }, {stderr_to_stdout = true})
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find(
                "browser stdlib image byte budget must be a positive decimal integer", 1, true),
                rejected.output)
            assert.equal(sentinel, assert(strategy:read_file(guard)))
        end
    end)

    it("enforces the supplied image byte budget at its exact boundary", function()
        assert.is_true(checks.check_image_size(32, 32, "fixture.wasm"))
        local ok, err = checks.check_image_size(33, 32, "fixture.wasm")
        assert.is_nil(ok)
        assert.truthy(err:find("fixture.wasm is 33 bytes", 1, true), err)
        assert.truthy(err:find("manifest budget of 32 bytes", 1, true), err)
        assert.is_nil(checks.check_image_size(1, 0, "fixture.wasm"))
        assert.is_nil(checks.check_image_size(1, 1.5, "fixture.wasm"))
        local path = temporary.name("-browser-budget.wasm")
        scratch[#scratch + 1] = path
        assert(strategy:write_file(path, string.rep("x", 33)))
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local rejected = strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua",
            "size", path, "32"}, {stderr_to_stdout = true})
        assert.is_false(rejected.ok)
        assert.truthy(rejected.output:find("exceeds manifest budget", 1, true), rejected.output)
        local directory = strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua",
            "size", ".", "32"}, {stderr_to_stdout = true})
        assert.is_false(directory.ok)
        assert.truthy(directory.output:find("must be a regular file", 1, true), directory.output)
    end)

    it("keeps partitioned image and per-engine evidence in the CI failure artifact", function()
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
            roots, "test_fail", "fixture", log, roots},
            {stderr_to_stdout = true})
        assert.is_false(result.ok)
        assert.truthy(result.output:find("Browser stdlib owner fixture.tests: 1 cases", 1, true), result.output)
        assert.truthy(result.output:find("selected=1 passed=0 skipped=0 failed=1 owners=1/1", 1, true), result.output)
        assert.truthy(result.output:find(
            "Browser stdlib owner fixture.tests: 1 cases (1.25 ms total)", 1, true), result.output)
        assert.truthy(result.output:find(
            "Browser stdlib image fixture: 1 cases (1.50 ms total)", 1, true), result.output)
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
            "output", roots, "", "fixture", log, roots}, {stderr_to_stdout = true})
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

    it("audits the union of image reports and fails when any image fails", function()
        local function file(suffix, contents)
            local path = temporary.name(suffix)
            scratch[#scratch + 1] = path
            assert(strategy:write_file(path, contents))
            return path
        end
        local function report(owner, failed)
            return "[==========] Running Titan tests.\n[ RUN      ] " .. owner .. ".test_case\n" ..
                (failed and "[  FAILED  ] " or "[       OK ] ") .. owner .. ".test_case (1.25 ms)\n" ..
                "[----------] " .. owner .. " (1.25 ms total)\n" ..
                "[==========] 1 test ran. (1.50 ms total)\n[  PASSED  ] " .. (failed and "0 tests.\n" or "1 test.\n") ..
                (failed and "[  FAILED  ] 1 test.\n[  FAILED  ] " .. owner .. ".test_case\n" or "")
        end
        local roots = file("-browser-roots.txt", "first.tests\nsecond.tests\n")
        local first = file("-browser-first.log", report("first.tests", false))
        local second = file("-browser-second.log", report("second.tests", false))
        local first_roots = file("-browser-first.txt", "first.tests\n")
        local second_roots = file("-browser-second.txt", "second.tests\n")
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local argv = {lua, "-E", "scripts/check_browser_stdlib.lua", "output", roots, "",
            "first", first, first_roots, "second", second, second_roots}
        local passed = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_true(passed.ok, passed.output)
        assert.truthy(passed.output:find("selected=2 passed=2 skipped=0 failed=0 owners=2/2 images=2", 1, true),
            passed.output)
        assert.truthy(passed.output:find(
            "Browser stdlib image first: 1 cases (1.50 ms total)", 1, true), passed.output)
        assert.truthy(passed.output:find(
            "Browser stdlib image second: 1 cases (1.50 ms total)", 1, true), passed.output)
        assert.truthy(passed.output:find(
            "Browser stdlib owner first.tests: 1 cases (1.25 ms total)", 1, true), passed.output)
        assert.truthy(passed.output:find(
            "Browser stdlib owner second.tests: 1 cases (1.25 ms total)", 1, true), passed.output)

        for _, suffix in ipairs({
            "", " (-1.25 ms)", " (1.2 ms)", " (1.250 ms)", " (nan ms)",
            " (inf ms)", " (1e2 ms)", " (1,25 ms)", " (1.25 ms total)",
        }) do
            local malformed = report("second.tests", false):gsub(
                "(%[       OK %] second.tests.test_case) %(1%.25 ms%)",
                function(prefix) return prefix .. suffix end)
            assert(strategy:write_file(second, malformed))
            local rejected = strategy:run(argv, {stderr_to_stdout = true})
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find("malformed native case timing", 1, true), rejected.output)
        end
        for _, replacement in ipairs({
            {"%[----------%] second.tests %(1%.25 ms total%)\n", "", "missing native owner timing"},
            {"%[----------%] second.tests %(1%.25 ms total%)", "[----------] second.tests (1.26 ms total)", "owner timing differs"},
            {"ran%. %(1%.50 ms total%)", "ran.", "malformed native run timing"},
            {"ran%. %(1%.50 ms total%)", "ran. (0.00 ms total)", "run timing is shorter"},
        }) do
            assert(strategy:write_file(second,
                (report("second.tests", false):gsub(replacement[1], replacement[2]))))
            local rejected = strategy:run(argv, {stderr_to_stdout = true})
            assert.is_false(rejected.ok, rejected.output)
            assert.truthy(rejected.output:find(replacement[3], 1, true), rejected.output)
        end
        assert(strategy:write_file(second, report("second.tests", false) ..
            "[       OK ] second.tests.test_case (1.25 ms)\n"))
        local duplicate = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_false(duplicate.ok, duplicate.output)
        assert.truthy(duplicate.output:find("duplicate native result", 1, true), duplicate.output)

        assert(strategy:write_file(second, report("first.tests", false)))
        local foreign_case = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_false(foreign_case.ok, foreign_case.output)
        assert.truthy(foreign_case.output:find(
            "group second: result outside native root inventory", 1, true), foreign_case.output)

        assert(strategy:write_file(second, report("second.tests", true)))
        local failed = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_false(failed.ok, failed.output)
        assert.truthy(failed.output:find("selected=2 passed=1 skipped=0 failed=1 owners=2/2 images=2", 1, true),
            failed.output)
        assert.truthy(failed.output:find("group second: native test failure", 1, true), failed.output)

        local empty = "[==========] Running Titan tests.\n[==========] 0 tests ran. (0.00 ms total)\n[  PASSED  ] 0 tests.\n"
        assert(strategy:write_file(second, empty))
        argv[6] = "^first[.]"
        local filtered = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_true(filtered.ok, filtered.output)
        assert.truthy(filtered.output:find("selected=1 passed=1 skipped=0 failed=0 owners=1/2 images=2 (filtered)", 1, true),
            filtered.output)
        assert(strategy:write_file(first, empty))
        local none = strategy:run(argv, {stderr_to_stdout = true})
        assert.is_false(none.ok, none.output)
        assert.truthy(none.output:find("selected no cases", 1, true), none.output)
    end)
end)
