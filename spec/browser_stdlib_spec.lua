local assert = require "luassert"
local checks = dofile("scripts/browser_stdlib.lua")
local types = require "titan-compiler.types"
local strategy = require("titan-compiler.io").new_sync()
local temporary = require "spec.support.temporary"
local installed_prefix = require "spec.support.installed_prefix"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local files = require "spec.fixtures.target_selection.support"
local parser = require "titan-compiler.parser"
local driver = require "titan-compiler.driver"
local browser_fixtures = require "spec.support.browser_fixtures"
local h = require "spec.support.helpers"

describe("browser core stdlib build checks", function()
    local scratch = {}
    after_each(function()
        for _, path in ipairs(scratch) do files.remove(path) end
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

    local function source_fixture()
        local root = temporary.name("-browser-source-closure")
        scratch[#scratch + 1] = root
        files.mkdir(root .. "/titan")
        return root
    end

    local function source_check(root)
        -- Restore a validated descriptor exactly as a worker does: source
        -- resolution needs no wasi-sdk discovery or compiler invocation.
        local descriptor = assert(driver._browser_target.import(browser_fixtures.descriptor()))
        local context = driver._new_resolver_context({ io = strategy, target = "browser" }, descriptor)
        local called, ok, err = pcall(checks.check_sources, context, root)
        local closed, close_error = driver.close_resolver_context(context)
        assert.is_true(called, ok)
        assert.is_true(closed, close_error)
        return ok, err
    end

    -- The tree-relative files a passing source audit selected, in its order.
    local function selected_sources(root)
        local selected, err = source_check(root)
        assert.is_table(selected, err)
        local prefix, relative = paths.to_slash(root) .. "/", {}
        for index, file in ipairs(selected) do
            local slashed = paths.to_slash(file)
            assert.equal(prefix, slashed:sub(1, #prefix), slashed)
            relative[index] = slashed:sub(#prefix + 1)
        end
        return relative
    end

    it("keeps all twenty-three portable owners in the single-image root inventory", function()
        local result = root_plan()
        assert.is_true(result.ok, result.output)
        local roots, count = {}, 0
        for root in assert(result.output:match("roots=([^\r\n]+)")):gmatch("%S+") do
            assert.is_nil(roots[root], root)
            roots[root], count = true, count + 1
        end
        assert.equal(23, count, "the audited browser inventory has 23 owners; change this deliberately")
        assert.is_true(roots["transfer.tests"])
        assert.is_true(roots["protobuf.tests"])
        assert.is_true(roots["protobuf.portable_tests"])
        assert.is_true(roots["async.tests"])
        assert.is_true(roots["timer.tests"])
        assert.is_true(roots["os.tests"])
        assert.is_true(roots["io.tests"])
        assert.is_true(roots["lua.tests"])
        assert.is_true(roots["http.tests"])
        assert.is_true(roots["websocket.tests"])
    end)

    it("rejects empty and duplicate owner inventories before build setup", function()
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
                "-f", platform.windows and "Makefile.win" or "Makefile", "titan-stdlib-browser-test",
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
            if step:find("name: browser-stdlib-${{ matrix.shard }}-failure", 1, true) then
                assert.is_nil(artifact, "duplicate browser stdlib failure artifact")
                artifact = step
            end
        end
        assert.truthy(suite, "browser-stdlib must run the browser stdlib target")
        assert.truthy(suite:find("if: matrix.stdlib-suite", 1, true), suite)
        assert.truthy(suite:find("set -euo pipefail", 1, true), suite)
        assert.truthy(suite:find('tee "$RUNNER_TEMP/browser-stdlib.log"', 1, true), suite)
        assert.truthy(artifact, "browser-stdlib must retain its own failure evidence")
        for _, contract in ipairs({
            "if: failure()", "uses: actions/upload-artifact@v7", "retention-days: 7",
            "${{ runner.temp }}/browser-*.log",
            "out/browser-stdlib/*.log", "out/browser-stdlib/images/*.mjs",
            "out/browser-stdlib/images/*.wasm", "out/browser-stdlib/images/*.wasm.map",
            "out/browser-stdlib/images/*.wasm.trace",
            "out/browser-stdlib/*roots.txt", "out/browser-stdlib/members.md",
        }) do
            assert.truthy(artifact:find(contract, 1, true), contract)
        end
        assert.is_nil(artifact:find("out/browser-stdlib/\n", 1, true))
    end)

    it("keeps native stdlib dependencies out of the browser provider recipe", function()
        local makefile = assert(strategy:read_file("scripts/browser.mk"))
        local environment = assert(makefile:match("\nBROWSER_SDK_ENV%s*[:?+]?=%s*(.-)\n\nbrowser%-sdk:"))
        local recipe = assert(makefile:match("\nbrowser%-sdk:[^\n]*\n(.-)\n\n"))
        local sources = { environment, recipe, assert(strategy:read_file("scripts/build_browser_sdk.sh")) }
        for _, filename in ipairs({ "Makefile", "Makefile.win" }) do
            local host = assert(strategy:read_file(filename)):gsub("\\\r?\n", " ")
            for _, variable in ipairs({ "BROWSER_LPEGLABEL_CPPFLAGS", "BROWSER_LPEGLABEL_SOURCES",
                    "LPEGLABEL_CPPFLAGS", "LPEGLABEL_SOURCES", "TITAN_RUNTIME_SOURCES" }) do
                local assignment = host:match("\n" .. variable .. "%s*[:?+]?=%s*([^\r\n]+)")
                if assignment then sources[#sources + 1] = assignment end
            end
        end
        local sdk = table.concat(sources, "\n")
        for _, forbidden in ipairs({ "STDLIB_EXTRA_OBJECTS", "LIBUV_", "OPENSSL_", "LLHTTP_", "SQLITE3_" }) do
            assert.is_nil(sdk:find(forbidden, 1, true), forbidden)
        end
        -- The real SDK spec builds with poisoned ambient CPPFLAGS and checks
        -- the exact native archive members instead of pinning recipe spelling.
    end)

    it("keeps every initializer fixture and child-state root equal to the browser Make inventory", function()
        local roots = assert(checks.browser_roots(strategy))
        local wanted = {}
        for _, root in ipairs(roots) do
            assert.is_nil(wanted[root], "duplicate browser root " .. root)
            wanted[root] = true
        end
        local function imports(module)
            local filename = "spec/fixtures/browser_stdlib/" .. module .. ".titan"
            local seen = {}
            for _, import in ipairs(assert(parser.scan_imports(assert(strategy:read_file(filename))))) do
                assert.is_false(import.source_required, filename)
                assert.is_nil(seen[import.name], filename .. ": duplicate import")
                seen[import.name] = true
            end
            return seen
        end
        for _, root in ipairs(roots) do
            assert.same({ ["titan.test"] = true, [root] = true }, imports("init_" .. root:sub(7)))
        end
        -- The directory holds no initializer fixture that the gate would skip.
        local expected, present = { init_subset = true, init_lua_states = true }, {}
        for _, root in ipairs(roots) do expected["init_" .. root:sub(7)] = true end
        for _, name in ipairs(assert(strategy:list("spec/fixtures/browser_stdlib"))) do
            local fixture = name:match("^(init_[%w_]+)%.titan$")
            if fixture then present[fixture] = true end
        end
        assert.same(expected, present)
        assert.same(wanted, imports("init_subset"))
        assert.same(wanted, imports("init_lua_states"))
        local filename = "spec/fixtures/browser_stdlib/init_lua_states.titan"
        local nodes = assert(parser.parse(filename, assert(strategy:read_file(filename))))
        local list
        for _, node in ipairs(nodes) do
            if node._tag == "Ast.TopLevelFunc" and node.name == "test_initializers_in_independent_states" then
                for _, statement in ipairs(node.block.stats) do
                    if statement._tag == "Ast.StatDecl" and statement.decls[1].name == "modules" then
                        assert.is_nil(list, "duplicate child-state root list")
                        list = statement.exps[1]
                    end
                end
            end
        end
        assert.truthy(list, "missing child-state root list")
        assert.equal("Ast.ExpInitList", list._tag)
        local seen = {}
        for _, field in ipairs(list.fields) do
            assert.equal("Ast.ExpString", field.exp._tag)
            assert.is_nil(seen[field.exp.value], "duplicate child-state root")
            seen[field.exp.value] = true
        end
        assert.same(wanted, seen)
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
        for _, header in ipairs({ "time.h", "locale.h", "stdlib.h", "errno.h" }) do
            assert(checks.check_headers({ c_header_dependencies = { { path = "/libc/" .. header } } }))
        end
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

    -- A final image whose only content is its import section: `imports` rows
    -- are { module, name, params, results } functions, { module, name,
    -- "table" | "memory" | "global" }, or { module, name, "tag", params }.
    local function import_image(imports)
        local function leb(value)
            local bytes = {}
            repeat
                local digit = value & 127
                value = value >> 7
                bytes[#bytes + 1] = string.char(digit | (value > 0 and 128 or 0))
            until value == 0
            return table.concat(bytes)
        end
        local function text(value) return leb(#value) .. value end
        local function section(id, bytes) return string.char(id) .. leb(#bytes) .. bytes end
        local codes = { i32 = "\127", i64 = "\126", f64 = "\124" }
        local function vector(names)
            local bytes = {}
            for index, name in ipairs(names) do bytes[index] = codes[name] end
            return leb(#names) .. table.concat(bytes)
        end
        local types, entries = {}, {}
        for index, row in ipairs(imports) do
            if row[3] == "table" then
                entries[index] = text(row[1]) .. text(row[2]) .. "\1\112\0\0"
            elseif row[3] == "memory" then
                entries[index] = text(row[1]) .. text(row[2]) .. "\2\0\1"
            elseif row[3] == "global" then
                entries[index] = text(row[1]) .. text(row[2]) .. "\3\127\0"
            elseif row[3] == "tag" then
                types[#types + 1] = "\96" .. vector(row[4]) .. vector({})
                entries[index] = text(row[1]) .. text(row[2]) .. "\4\0" .. leb(#types - 1)
            else
                types[#types + 1] = "\96" .. vector(row[3]) .. vector(row[4])
                entries[index] = text(row[1]) .. text(row[2]) .. "\0" .. leb(#types - 1)
            end
        end
        return "\0asm\1\0\0\0" .. section(1, leb(#types) .. table.concat(types)) ..
            section(2, leb(#entries) .. table.concat(entries))
    end
    local completion = { "env", "titan_browser_complete", { "i32" }, {} }
    local clock = { "wasi_snapshot_preview1", "clock_time_get", { "i32", "i64", "i32" }, { "i32" } }
    local fixture_sleep = { "env", "fixture_sleep", { "i32" }, {} }
    local fixture_click = { "env", "titan_test_set_click_callback", { "i32", "i32", "i32" }, { "i32" } }

    it("accepts an image whose imports the reviewed allowlist lists for its classes", function()
        assert.is_true(checks.check_imports(import_image({ completion, clock }), "entry.wasm", { "entry" }))
        assert.is_true(checks.check_imports(import_image({ completion, fixture_sleep }), "test.wasm",
            { "entry", "fixture:trace" }))
    end)

    it("rejects an injected unlisted import, a changed signature and every unlisted import kind", function()
        local ok, err = checks.check_imports(import_image({ completion,
            { "env", "titan_injected", { "i32" }, {} } }), "injected.wasm", { "entry" })
        assert.is_nil(ok)
        assert.equal("injected.wasm: unlisted browser import env.titan_injected (i32)->() (classes entry)\n" ..
            "add a reviewed row for each to scripts/browser_imports.lua", err)
        ok, err = checks.check_imports(import_image({ { "env", "titan_browser_complete", { "i64" }, {} },
            { "env", "__indirect_function_table", "table" }, { "env", "memory", "memory" },
            { "env", "__stack_pointer", "global" }, { "env", "__cpp_exception", "tag", { "i32" } } }),
            "changed.wasm", { "entry" })
        assert.is_nil(ok)
        assert.equal("changed.wasm: unlisted browser import env.titan_browser_complete (i64)->() (classes entry)\n" ..
            "changed.wasm: unlisted browser import env.__indirect_function_table table (classes entry)\n" ..
            "changed.wasm: unlisted browser import env.memory memory (classes entry)\n" ..
            "changed.wasm: unlisted browser import env.__stack_pointer global (classes entry)\n" ..
            "changed.wasm: unlisted browser import env.__cpp_exception tag (i32)->() (classes entry)\n" ..
            "add a reviewed row for each to scripts/browser_imports.lua", err)
    end)

    it("keeps a test fixture's imports out of entry images and other fixtures' images", function()
        local ok, err = checks.check_imports(import_image({ completion, fixture_sleep }), "program.wasm", { "entry" })
        assert.is_nil(ok)
        assert.truthy(err:find("unlisted browser import env.fixture_sleep (i32)->() (classes entry)", 1, true), err)
        ok, err = checks.check_imports(import_image({ completion, fixture_click }), "trace.wasm",
            { "entry", "fixture:trace" })
        assert.is_nil(ok)
        assert.truthy(err:find("unlisted browser import env.titan_test_set_click_callback " ..
            "(i32,i32,i32)->(i32) (classes entry,fixture:trace)", 1, true), err)
        assert.is_true(checks.check_imports(import_image({ completion, fixture_click }), "counter.wasm",
            { "entry", "fixture:click" }))
    end)

    it("rejects an empty or unknown class list and malformed or duplicate allowlist rows", function()
        local row = { "entry", "env", "f", "()->()", provider = "titan-wasm-factory.mjs", reason = "test" }
        local function allowlist(rows) return { classes = { entry = "every image" }, imports = rows } end
        local image = import_image({})
        local ok, err = checks.check_imports(image, "x.wasm", {}, allowlist({ row }))
        assert.is_nil(ok)
        assert.equal("no browser import classes", err)
        ok, err = checks.check_imports(image, "x.wasm", { "other" }, allowlist({ row }))
        assert.is_nil(ok)
        assert.equal("unknown browser import class other", err)
        for _, malformed in ipairs({
            { "fixture", "env", "f", "()->()", provider = "p", reason = "r" },
            { "entry", "env", "f", provider = "p", reason = "r" },
            { "entry", "env", "f", "()->()", reason = "r" },
            { "entry", "env", "f", "()->()", provider = "p", reason = "" },
        }) do
            ok, err = checks.check_imports(image, "x.wasm", { "entry" }, allowlist({ row, malformed }))
            assert.is_nil(ok)
            assert.equal("malformed browser import allowlist row 2", err)
        end
        ok, err = checks.check_imports(image, "x.wasm", { "entry" }, allowlist({ row, row }))
        assert.is_nil(ok)
        assert.equal("duplicate browser import allowlist row entry env.f", err)
    end)

    it("rejects every absent import only from compiler-selected browser files", function()
        for _, module in ipairs(checks.absent_modules) do
            local bad = "local missing = import " .. string.format("%q", module:sub(7)) .. "\n"
            local good = "function value(): integer return 1 end\n"
            local root = source_fixture()
            files.write(root .. "/titan/intruder.titan", bad)
            local function rejected(tree)
                local ok, err = source_check(tree)
                assert.is_nil(ok, module)
                assert.truthy(err:find(module, 1, true), err)
            end
            rejected(root)
            files.write(root .. "/titan/intruder.browser.titan", good)
            files.write(root .. "/titan/intruder.native.titan", bad)
            assert.same({ "titan/intruder.browser.titan" }, selected_sources(root))
            files.write(root .. "/titan/intruder.browser.titan", bad)
            rejected(root)

            local folder = source_fixture()
            files.write(folder .. "/titan/owner/owner.native.titan", good)
            files.write(folder .. "/titan/owner/member.titan", bad)
            assert.same({}, selected_sources(folder))
            files.write(folder .. "/titan/owner/owner.browser.titan", good)
            rejected(folder)
            files.write(folder .. "/titan/owner/member.browser.titan", good)
            assert.same({ "titan/owner/member.browser.titan", "titan/owner/owner.browser.titan" },
                selected_sources(folder))
            -- A bare native.titan is an unlabeled contributor, not a variant.
            files.write(folder .. "/titan/owner/native.titan", bad)
            rejected(folder)
        end
    end)

    it("uses folder-before-flat and inactive-main fallback in the source audit", function()
        local root = source_fixture()
        files.write(root .. "/titan/owner.titan", 'local missing = import "fs"\n')
        files.write(root .. "/titan/owner/owner.titan", "function value(): integer return 1 end\n")
        assert.same({ "titan/owner/owner.titan" }, selected_sources(root))
        assert(os.rename(root .. "/titan/owner/owner.titan", root .. "/titan/owner/owner.native.titan"))
        local ok, err = source_check(root)
        assert.is_nil(ok)
        assert.truthy(err:find("titan.fs", 1, true), err)
    end)

    it("rejects absent-module artifacts and metadata even under neutral archive member names", function()
        for _, module in ipairs(checks.absent_modules) do
            local ok, err = checks.check_archive("provider.a", { members = {
                { display_name = "neutral.o", bytes = "", object = { metadata = { module = module } } },
            } })
            assert.is_nil(ok)
            assert.truthy(err:find(module, 1, true), err)
            -- Physical basenames do not confer the titan namespace.
            assert(checks.check_archive("provider.a", { members = {
                { display_name = module:sub(7) .. ".o", bytes = "",
                    object = { metadata = { module = "app." .. module:sub(7) } } },
            } }))
        end
        assert(checks.check_archive("provider.a", { members = {
            { display_name = "portable.o", bytes = "", object = { metadata = { module = "titan.math" } } },
        } }))
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

    it("inventories Interface members once despite their ordered and named views", function()
        local function provider(parameter)
            local owner = "fixture.View"
            local view = types.Interface(owner, {
                types.Field(owner, "size", types.Integer(), 0, true),
            }, {
                types.Method(owner, "read", {}, {types.String()}, nil, nil, {}),
                types.Method(owner, "write", {parameter}, {}, nil, nil, {"data"}),
            })
            local modtype = types.Module("fixture", {}, {View = view})
            return { key_order = {"fixture"},
                entries = { fixture = {types = types.serialize(modtype)} } }
        end
        local rows = assert(checks.inventory(provider(types.String()), provider(types.String())))
        local members = {}
        for _, row in ipairs(rows) do members[row.name] = row.kind end
        assert.equal(4, #rows)
        assert.equal("interface", members.View)
        assert.equal("field", members["View.size"])
        assert.equal("method", members["View:read"])
        assert.equal("method", members["View:write"])
        local ok, err = checks.inventory(provider(types.String()), provider(types.Integer()))
        assert.is_nil(ok)
        assert.truthy(err:find("View:write", 1, true), err)
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

    it("accepts exactly the recorded omissions, including omitted methods of a kept record", function()
        local function provider(browser)
            local members = {
                types.ModuleMember("fixture", "shared", types.Function({}, {}, false, nil, nil), {}),
                types.ModuleMember("fixture", "Kept", types.Record("fixture.Kept", {}, {},
                    browser and {} or { close = types.Method("fixture.Kept", "close", {}, {}, nil, nil, {}) },
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
        local function recorded(omitted)
            return { fixture = { omitted = omitted } }
        end
        local rows, modules, differences = checks.inventory(provider(false), provider(true),
            recorded({ "gone", "Gone", "Kept:close" }))
        assert.equal(1, modules)
        assert.same({ "Kept", "shared" }, { rows[1].name, rows[2].name, rows[3] })
        local kinds = {}
        for _, row in ipairs(differences) do kinds[#kinds + 1] = row.name .. "=" .. row.difference end
        assert.same({ "gone=omitted", "Gone=omitted", "Kept:close=omitted" }, kinds)
        local text = checks.member_table(rows, differences)
        assert.truthy(text:find("## Absent browser members", 1, true), text)
        assert.truthy(text:find("| `fixture` | `Kept:close` | omitted | method |", 1, true), text)
        for _, case in ipairs({
            { recorded({ "Gone", "Kept:close" }), "fixture.gone: native=" },
            { recorded({ "gone", "Gone", "Kept:close", "shared" }),
                "fixture.shared: recorded omission is in the browser interface" },
            { recorded({ "gone", "Gone", "Kept:close", "absent" }),
                "fixture.absent: recorded omission is not a native member" },
            { recorded({ "gone", "Gone" }), "fixture.Kept:close: native=" },
            { recorded({ "gone", "Gone" }), "fixture.Kept: native=fixture.Kept; browser=fixture.Kept " ..
                "(semantic declaration differs)" },
        }) do
            local ok, err = checks.inventory(provider(false), provider(true), case[1])
            assert.is_nil(ok)
            assert.truthy(err:find(case[2], 1, true), err)
        end
    end)

    it("drops the omitted Lua methods but compares the owner and every retained method", function()
        assert.same({ omitted = { "Lua:run_async", "Lua:run_async_from_loader", "dofile" } },
            checks.omissions(checks.status_inventory)["titan.lua"])
        local retained = { "close", "detach", "run", "run_from_loader" }
        local function provider(browser, changed)
            local owner, methods = "titan.lua.Lua", {}
            for _, name in ipairs(retained) do
                methods[name] = types.Method(owner, name, {},
                    name == changed and {types.String()} or {}, nil, nil, {})
            end
            if not browser then
                for _, name in ipairs({ "run_async", "run_async_from_loader" }) do
                    methods[name] = types.Method(owner, name, {}, {}, nil, nil, {})
                end
            end
            local members = {
                types.ModuleMember("titan.lua", "Lua", types.Record(owner, {}, {}, methods, 2), nil),
            }
            if not browser then
                members[#members + 1] = types.ModuleMember("titan.lua", "dofile",
                    types.Function({}, {}, false, nil, nil), {})
            end
            return { key_order = { "titan.lua" }, entries = {
                ["titan.lua"] = { types = types.serialize(types.Module("titan.lua", members, {})) },
            } }
        end
        local rows, modules, differences = checks.inventory(provider(false), provider(true))
        assert.equal(1, modules)
        assert.equal(#retained + 1, #rows)
        assert.equal(3, #differences)
        for _, name in ipairs(retained) do
            local ok, err = checks.inventory(provider(false), provider(true, name))
            assert.is_nil(ok)
            assert.truthy(err:find("titan.lua.Lua:" .. name, 1, true), err)
        end
    end)

    -- Drift detection over fixture modules checked from source: the native
    -- and browser compositions of one module are compared through the same
    -- serialized interfaces that installed providers carry.
    local function checked(source)
        local ok, err, _, modtype = h.run_checker(source)
        assert.truthy(ok, err)
        return { key_order = { "test" }, entries = { test = { types = types.serialize(modtype) } } }
    end
    local function compare(native_source, browser_source, omitted)
        return checks.inventory(checked(native_source), checked(browser_source),
            { test = { omitted = omitted } })
    end
    local differs = " (semantic declaration differs)"

    it("rejects every public-shape drift that normalization keeps", function()
        local literal = "record P\n  x: integer\nend\n"
        local opaque = "record R\n  x: integer\n  local handle: integer\nend\n"
        local closer = "record R\n  local handle: integer\nend\nfunction R:close() end\n"
        for _, case in ipairs({
            { "renamed parameter", "function f(a: integer): integer return a end\n",
                "function f(b: integer): integer return b end\n", "test.f: native=" },
            { "changed generic parameter", "function id<|T|>(item: T): T return item end\n",
                "function id<|U|>(item: U): U return item end\n", "test.id: native=" },
            { "changed generic constraint",
                "interface Named\n  name: string\nend\nfunction show<|T: Named|>(item: T): T return item end\n",
                "interface Named\n  name: string\nend\nfunction show<|T|>(item: T): T return item end\n",
                "test.show: native=" },
            { "changed alias target", "type Id = integer\n", "type Id = string\n",
                "test.Id: native=integer; browser=string" },
            { "changed public field type", literal, "record P\n  x: string\nend\n",
                "test.P.x: native=integer; browser=string" },
            { "changed public field order", "record P\n  x: integer\n  y: string\nend\n",
                "record P\n  y: string\n  x: integer\nend\n", "test.P: native=test.P; browser=test.P" .. differs },
            { "changed public field constness", literal, "record P\n  const x: integer\nend\n",
                "test.P.x: native=integer; browser=integer (readonly)" },
            { "hidden field added to a literal-constructible record", literal,
                "record P\n  x: integer\n  local secret: integer\nend\n",
                "test.P: native=test.P; browser=test.P" .. differs },
            { "hidden variant added to an exhaustively matchable union", "union U\n  a()\n  b()\nend\n",
                "union U\n  a()\n  b()\n  local c()\nend\n", "test.U: native=test.U; browser=test.U" .. differs },
            { "opaque browser record without a private field", opaque, "record R\n  x: integer\nend\n",
                "test.R: native=test.R; browser=test.R" .. differs },
            { "added custom constructor", literal,
                literal .. "function P.new(x: integer): P return { x = x } end\n",
                "test.P: native=test.P; browser=test.P" .. differs },
            { "changed module-variable constness", "limit: integer = 1\n", "const limit: integer = 1\n",
                "test.limit: native=integer; browser=integer (const)" },
            { "browser-only member in a native module", "function f() end\n",
                "function f() end\nfunction extra() end\n", "test.extra: native=<absent>" },
            { "unlisted owner-method absence", closer, "record R\n  local handle: integer\nend\n",
                "test.R:close: native=" },
        }) do
            local rows, err = compare(case[2], case[3])
            assert.is_nil(rows, case[1])
            assert.truthy(err:find(case[4], 1, true), case[1] .. "\n" .. err)
        end
    end)

    it("accepts private layout, listed owner absences, local members, order and documentation", function()
        for _, case in ipairs({
            { "private fields inserted before a public field of a non-literal record",
                "record R\n  local a: integer\n  x: integer\nend\n",
                "record R\n  local b: string\n  local c: boolean\n  x: integer\nend\n" },
            { "hidden variant inserted before a public one of a non-exhaustive union",
                "union U\n  a()\n  local h()\nend\n", "union U\n  local z()\n  a()\n  local h()\nend\n" },
            { "listed owner-method absence",
                "record R\n  local handle: integer\nend\nfunction R:close() end\n" ..
                    "function R:read(): integer return 1 end\n",
                "record R\n  local handle: string\nend\nfunction R:read(): integer return 2 end\n",
                { "R:close" } },
            { "local method changes", "record P\n  x: integer\nend\n",
                "record P\n  x: integer\nend\nlocal function P:twice(): integer return self.x * 2 end\n" },
            { "member reordering", "function a() end\nfunction b() end\nrecord P\n  x: integer\nend\n",
                "record P\n  x: integer\nend\nfunction b() end\nfunction a() end\n" },
            { "documentation changes", "function f(): integer return 1 end\n",
                "--- Return one.\n-- @return The integer one.\nfunction f(): integer return 1 end\n" },
        }) do
            local rows, err = compare(case[2], case[3], case[4])
            assert.truthy(rows, case[1] .. "\n" .. tostring(err))
        end
    end)

    it("normalizes to a valid interface that keeps capabilities and ignores declaration order", function()
        local function decoded(source)
            local ok, err, _, modtype = h.run_checker(source)
            assert.truthy(ok, err)
            return assert(driver.decode_module_interface(types.serialize(modtype), "test", "fixture interface"))
        end
        local declarations = {
            "record Literal\n  x: integer\n  y: string\nend\n",
            "record Hidden\n  local a: integer\n  x: integer\nend\n",
            "union Closed\n  a()\n  b(value: integer)\nend\n",
            "union Open\n  local z()\n  a()\nend\n",
            "function f(): integer return 1 end\n",
        }
        local text = types.serialize_semantic(checks.normalize(decoded(table.concat(declarations))))
        local again = assert(driver.decode_module_interface(text, "test", "normalized interface"))
        assert.equal(text, types.serialize_semantic(checks.normalize(again)))
        local members = again.members
        assert.equal(#members.Literal.type.fields, members.Literal.type.nfields)
        assert.equal(#members.Hidden.type.fields + 1, members.Hidden.type.nfields)
        assert.equal(#members.Closed.type.variants, members.Closed.type.nvariants)
        assert.equal(#members.Open.type.variants + 1, members.Open.type.nvariants)
        local reversed = {}
        for index = #declarations, 1, -1 do reversed[#reversed + 1] = declarations[index] end
        assert.equal(text, types.serialize_semantic(checks.normalize(decoded(table.concat(reversed)))))
    end)

    -- No ABI-width exception exists (titan#336): a C width that differs
    -- between targets fails like a changed spelling or signedness.
    it("compares every C fact of a raw export exactly", function()
        local function provider(spelling, signed, rank, bits)
            local modtype = types.Module("fixture", {
                types.ModuleMember("fixture", "raw",
                    types.CFunction({ types.CInteger(spelling, signed, rank, bits) }, types.CVoid(), false, nil), nil),
            }, {})
            return { key_order = { "fixture" }, entries = { fixture = { types = types.serialize(modtype) } } }
        end
        for _, case in ipairs({
            { provider("int", true, 3, 32), provider("unsigned int", false, 3, 32) },
            { provider("int", true, 3, 32), provider("long long", true, 5, 64) },
            { provider("char", true, 1, 8), provider("char", false, 1, 8) },
            { provider("long", true, 4, 64), provider("long", true, 4, 32) },
        }) do
            assert(checks.inventory(case[1], case[1]))
            local rows, err = checks.inventory(case[1], case[2])
            assert.is_nil(rows)
            assert.truthy(err:find("fixture.raw: native=", 1, true), err)
        end
    end)

    it("checks every module and member row against both interfaces", function()
        local function entry(modname, members)
            return { types = types.serialize(types.Module(modname, members, {})) }
        end
        local function fn(name, results)
            return types.ModuleMember("fixture", name, types.Function({}, results or {}, false, nil, nil), {})
        end
        local handle = types.Nominal("titan.gone.Handle")
        local function box(methods)
            local result = {}
            for _, name in ipairs(methods) do result[name] = types.Method("fixture.Box", name, {}, {}, nil, nil, {}) end
            return types.ModuleMember("fixture", "Box", types.Record("fixture.Box", {}, {}, result, 1), nil)
        end
        local raw = types.ModuleMember("fixture", "raw", types.CFunction({}, types.CVoid(), false, nil), nil)
        local wrap = types.ModuleMember("fixture", "Wrap", types.Record("fixture.Wrap", {
            types.Field("fixture.Wrap", "handle", handle, 0, false),
        }, {}, { size = types.Method("fixture.Wrap", "size", {}, { types.Integer() }, nil, nil, {}) }, 2), nil)
        -- A type-only owner with an instance method and a static, and an
        -- absent native-only owner with one method typed by the absent module.
        local opaque = types.ModuleMember("fixture", "O", types.Record("fixture.O", {}, {
            helper = types.StaticMethod("fixture.O", "helper", {}, { types.Integer() }, nil, nil, {}),
        }, { close = types.Method("fixture.O", "close", {}, {}, nil, nil, {}) }, 1), nil)
        local server = types.ModuleMember("fixture", "Server", types.Record("fixture.Server", {}, {}, {
            accept_raw = types.Method("fixture.Server", "accept_raw", {}, { handle }, nil, nil, {}),
            stop = types.Method("fixture.Server", "stop", {}, {}, nil, nil, {}),
        }, 1), nil)
        local native = { key_order = { "fixture", "titan.gone" }, entries = {
            fixture = entry("fixture", { fn("keep"), fn("typed", { handle }), fn("host"), box({ "run", "stop" }), raw,
                wrap, opaque, server }),
            ["titan.gone"] = entry("titan.gone", {
                types.ModuleMember("titan.gone", "Handle", types.Record("titan.gone.Handle", {}, {}, {}, 1), nil),
            }),
        } }
        local function browser_provider(bind_results)
            return { key_order = { "fixture", "titan.web" }, entries = {
                fixture = entry("fixture", { fn("keep"), box({ "run" }), raw, opaque }),
                ["titan.web"] = entry("titan.web", { types.ModuleMember("titan.web", "bind",
                    types.Function({}, bind_results, false, nil, nil), {}) }),
            } }
        end
        local browser = browser_provider({})
        local function inventory(change)
            local result = {
                modules = {
                    { "fixture", "present", test = "fixture.tests" },
                    { "titan.gone", "absent", reason = "requires a host" },
                    { "titan.web", "browser-only" },
                },
                members = { fixture = {
                    { "Box", "implemented", "fixture.tests.test_box" },
                    { "Box:run", "implemented", "fixture.tests.test_box" },
                    { "Box:stop", "absent:native-only" },
                    { "Wrap", "absent:typed" },
                    { "Wrap:size", "absent:typed" },
                    { "host", "absent:native-only" },
                    { "keep", "implemented", "fixture.tests.test_keep" },
                    { "raw", "implemented", "fixture.tests.test_raw" },
                    { "typed", "absent:typed" },
                    { "O", "type-only" },
                    { "O.helper", "implemented", "fixture.tests.test_helper" },
                    { "O:close", "type-only" },
                    { "Server", "absent:native-only" },
                    { "Server:accept_raw", "absent:typed" },
                    { "Server:stop", "absent:native-only" },
                } },
                stock_lua = { { "os.clock", "raise", "lua.tests.test_stock.clock" } },
            }
            if change then change(result, result.members.fixture) end
            return result
        end
        local function row(rows, name)
            for _, candidate in ipairs(rows) do if candidate[1] == name then return candidate end end
        end
        assert(checks.check_status(native, browser, inventory()))
        assert(checks.check_status(native, browser, inventory(function(result, rows)
            result.modules[1].core = true
            row(rows, "keep")[3] = "fixture.tests"
        end)))
        for _, case in ipairs({
            { function(result) table.remove(result.modules, 2) end, "titan.gone: module has no status row" },
            { function(result) result.modules[2][2] = "present" end,
                "titan.gone: present module is missing from a provider" },
            { function(result) result.modules[3][2] = "absent"; result.modules[3].reason = "x" end,
                "titan.web: absent module is not native-only" },
            { function(result) result.modules[2].reason = nil end, "titan.gone: absent module has no reason" },
            { function(result) result.modules[1].test = "fixture.tests.test_keep" end,
                "fixture: present module names no test owner" },
            { function(result) result.members["titan.gone"] = {} end,
                "titan.gone: member rows for a module that is not present" },
            { function(_, rows) table.remove(rows, 7) end, "fixture.keep: native member has no status row" },
            { function(_, rows) rows[#rows + 1] = { "Wrap.handle", "absent:typed" } end,
                "fixture.Wrap.handle: status row is not a native callable, type or variable" },
            { function(_, rows) rows[#rows + 1] = { "keep", "implemented", "fixture.tests.test_keep" } end,
                "fixture.keep: duplicate status row" },
            { function(_, rows) row(rows, "keep")[2] = "maybe" end, "fixture.keep: unknown status maybe" },
            { function(_, rows) row(rows, "typed")[2] = "absent:native-only" end,
                "fixture.typed: absence is absent:typed, not absent:native-only" },
            { function(_, rows) row(rows, "host")[2] = "absent:typed" end,
                "fixture.host: absence is absent:native-only, not absent:typed" },
            { function(_, rows) row(rows, "Wrap:size")[2] = "absent:native-only" end,
                "fixture.Wrap:size: absence is absent:typed, not absent:native-only" },
            { function(_, rows) row(rows, "keep")[2] = "absent:native-only"; row(rows, "keep")[3] = nil end,
                "fixture.keep: absent member is in the browser interface" },
            { function(_, rows) row(rows, "host")[3] = "fixture.tests.test_host" end,
                "fixture.host: absent member names a test" },
            { function(_, rows) row(rows, "Box:stop")[2] = "implemented"; row(rows, "Box:stop")[3] = "fixture.tests.x" end,
                "fixture.Box:stop: implemented member is missing from the browser" },
            { function(_, rows) row(rows, "keep")[3] = nil end, "fixture.keep: implemented member names no test" },
            { function(_, rows) row(rows, "keep")[3] = "fixture.tests" end,
                "fixture.keep: only implemented members of a core module may name a whole test owner" },
            { function(result, rows) result.modules[1].core = true; row(rows, "keep")[2] = "raise"
                row(rows, "keep")[3] = "fixture.tests" end,
                "fixture.keep: only implemented members of a core module may name a whole test owner" },
            { function(_, rows) row(rows, "raw")[2] = "raise" end,
                "fixture.raw: a raw foreign function is implemented or absent" },
            { function(result) result.stock_lua[1][2] = "absent" end, "stock Lua os.clock: unknown status absent" },
            { function(result) result.stock_lua[1][3] = "lua.tests" end, "stock Lua os.clock: names no exact test case" },
            { function(_, rows) row(rows, "O.helper")[2] = "type-only"; row(rows, "O.helper")[3] = nil end,
                "fixture.O.helper: only instance methods of a type-only owner are type-only" },
            { function(_, rows) row(rows, "Server:accept_raw")[2] = "absent:native-only" end,
                "fixture.Server:accept_raw: absence is absent:typed, not absent:native-only" },
            { function(_, rows) row(rows, "Server:stop")[2] = "absent:typed" end,
                "fixture.Server:stop: absence is absent:native-only, not absent:typed" },
        }) do
            local ok, err = checks.check_status(native, browser, inventory(case[1]))
            assert.is_nil(ok, case[2])
            assert.truthy(err:find(case[2], 1, true), case[2] .. "\n" .. err)
        end
        -- Another browser module, even a browser-only one, must not produce a
        -- value of a type-only owner either.
        local ok, err = checks.check_status(native, browser_provider({ types.Nominal("fixture.O") }), inventory())
        assert.is_nil(ok)
        assert.truthy(err:find("fixture.O: type-only owner is reachable through titan.web.bind", 1, true), err)
    end)

    it("names tests as runner cases, OS harness cases or whole owners", function()
        for test, kind in pairs({
            ["json.tests"] = "owner", ["string.core_test"] = "owner",
            ["os.tests.test_browser_stdio_requires_a_runtime_and_task"] = "case",
            ["lua.tests.test_lua_browser_stock_filesystem_failures.clock"] = "case",
            ["os.browser_tests:stock-owner-task-exit:3"] = "harness",
        }) do
            assert.equal(kind, checks.test_reference(test), test)
        end
        for _, test in ipairs({ "tests", "json..tests", ".json.tests", "json.tests.", "os.tests:case", 7 }) do
            assert.is_nil(checks.test_reference(test), tostring(test))
        end
    end)

    -- The inventory tests that the browser test sources do not define, as
    -- `<label>: <test>` lines. A case is a public top-level `test_*` function
    -- with one named parameter, as the runner discovers it, and each subtest
    -- segment after it is a string literal of the owner's sources; a whole
    -- owner needs one case. An OS stream harness name is an exact
    -- `check('<name>'` registration of the harness, or matches a
    -- ``check(`<template>` `` registration in which every `${...}` segment
    -- is a quoted literal of the harness. `owner_sources(owner)` returns the
    -- owner's `{ filename, text }` sources.
    local function undefined_tests(references, owners, owner_sources, harness)
        local exact, templates = {}, {}
        for name in harness:gmatch("check%('([^']+)'") do exact[name] = true end
        for template in harness:gmatch("check%(`([^`]+)`") do
            local marked, count = template:gsub("%${.-}", "\1")
            if count == 0 then
                exact[template] = true
            else
                templates[#templates + 1] = "^" .. marked:gsub("%p", "%%%0"):gsub("\1", "([^:]+)") .. "$"
            end
        end
        local function registered(name)
            if exact[name] then return true end
            for _, pattern in ipairs(templates) do
                local segments = { name:match(pattern) }
                local quoted = #segments > 0
                for _, segment in ipairs(segments) do
                    quoted = quoted and harness:find("'" .. segment .. "'", 1, true) ~= nil
                end
                if quoted then return true end
            end
            return false
        end
        local loaded = {}
        local function owner_tests(owner)
            if loaded[owner] then return loaded[owner] end
            local cases, strings = {}, {}
            local function collect(node)
                if node._tag == "Ast.ExpString" then strings[node.value] = true end
                for _, child in pairs(node) do
                    if type(child) == "table" then collect(child) end
                end
            end
            for _, source in ipairs(owner_sources(owner)) do
                local ast = assert(parser.parse(source.filename, source.text))
                for _, node in ipairs(ast) do
                    if node._tag == "Ast.TopLevelFunc" and not node.islocal and node.name:match("^test_")
                        and #node.params == 1 and node.params[1].name ~= nil then
                        cases[node.name] = true
                    end
                end
                collect(ast)
            end
            loaded[owner] = { cases = cases, strings = strings }
            return loaded[owner]
        end
        local missing = {}
        for _, reference in ipairs(references) do
            local test, owner = reference.test, reference.owner
            local defined
            if not owners[owner] then
                missing[#missing + 1] = reference.label .. ": " .. owner .. " is not a browser test owner"
                defined = true
            elseif reference.kind == "harness" then
                defined = registered(test:sub(#"os.browser_tests:" + 1))
            elseif reference.kind == "owner" then
                defined = next(owner_tests(owner).cases) ~= nil
            else
                local found = owner_tests(owner)
                local path = test:sub(#owner + 2)
                local case = assert(path:match("^[^.]+"))
                defined = found.cases[case] == true
                for segment in path:sub(#case + 1):gmatch("%.([^.]+)") do
                    defined = defined and found.strings[segment] == true
                end
            end
            if not defined then missing[#missing + 1] = reference.label .. ": " .. test end
        end
        table.sort(missing)
        return missing
    end

    it("rejects inventory tests that the browser test sources do not define", function()
        local harness = assert(strategy:read_file("spec/fixtures/browser_scheduler/os-streams.mjs"))
        local sources = {
            ["fake.tests"] = { { filename = "fake.titan", text = [[
function test_one(context: test.Context)
  context:run("child", function (_: test.Context) end)
end
function test_helper()
end
function test_pair(_: test.Context, _extra: integer)
end
function test_rest(...: test.Context)
end
local function test_local(_: test.Context)
end
]] } },
            ["empty.tests"] = { { filename = "empty.titan", text = "local function helper()\nend\n" } },
        }
        local tests = {
            ["fake.tests.test_one"] = true, ["fake.tests.test_one.child"] = true, ["fake.tests"] = true,
            ["os.browser_tests:stdin-chunks-empty-and-sticky-eof"] = true,
            ["os.browser_tests:declared-kinds-and-tty:tty"] = true,
            ["os.browser_tests:unsupported-shutdown-keeps-open:stdout:undeclared"] = true,
            ["os.browser_tests:tcp-shutdown-order-repeat-epipe:stderr:cancel"] = true,
            ["os.browser_tests:stock-owner-task-exit:3"] = true,
            ["other.tests.test_one"] = "other.tests is not a browser test owner",
            ["fake.tests.test_missing"] = false, ["fake.tests.test_helper"] = false,
            ["fake.tests.test_pair"] = false, ["fake.tests.test_rest"] = false,
            ["fake.tests.test_local"] = false, ["fake.tests.test_one.chlid"] = false,
            ["fake.tests.test_one.child.stale"] = false, ["empty.tests"] = false,
            ["os.browser_tests:stdin"] = false, ["os.browser_tests:stdin-chunks"] = false,
            ["os.browser_tests:stdin-chunks-empty-and-sticky-eof:stale"] = false,
            ["os.browser_tests:declared-kinds-and-tty:ttty"] = false,
            ["os.browser_tests:declared-kinds-and-tty"] = false,
            ["os.browser_tests:unsupported-shutdown-keeps-open:stdout"] = false,
        }
        local rows, expected = {}, {}
        for test, defined in pairs(tests) do
            rows[#rows + 1] = { test, "implemented", test }
            if defined ~= true then
                expected[#expected + 1] = "titan.fake." .. test .. ": " .. (defined or test)
            end
        end
        table.sort(expected)
        local references = checks.test_references({ modules = {}, members = { ["titan.fake"] = rows } })
        assert.equal(#rows, #references)
        assert.same(expected, undefined_tests(references,
            { ["fake.tests"] = true, ["empty.tests"] = true, ["os.browser_tests"] = true },
            function(owner) return assert(sources[owner], owner) end, harness))
    end)

    -- Each named test must exist before the browser lane runs it: an image or
    -- harness owner's compiler-selected browser sources define the case, an
    -- OS stream harness case is registered by its driver, and every harness
    -- gate runs in one of the browser-stdlib matrix shards.
    it("names only tests that exist in the browser test sources", function()
        local plan = root_plan()
        assert.is_true(plan.ok, plan.output)
        local owners = {}
        for root in assert(plan.output:match("roots=([^\r\n]*)")):gmatch("%S+") do owners[root] = true end
        for owner in pairs(checks.harness_owners) do owners[owner] = true end
        local ci = assert(strategy:read_file(".github/workflows/ci.yml"))
        local gate = assert(ci:match("\n  browser%-stdlib:\n(.-)\n  [%w_-]+:\n"))
        local shards = assert(gate:match("\n    strategy:\n(.-)\n    permissions:"))
        assert.truthy(gate:find("TITAN_BROWSER_GATE_SPECS: ${{ matrix.gate-specs }}", 1, true))
        for owner, spec in pairs(checks.harness_owners) do
            assert.truthy(shards:find(spec, 1, true), spec .. " is not a browser-stdlib gate spec")
            local text = assert(strategy:read_file(spec))
            assert.truthy(text:find("require_evidence", 1, true) and text:find('["' .. owner .. '"] = true', 1, true),
                spec .. " does not check the evidence of " .. owner)
        end
        local harness = assert(strategy:read_file("spec/fixtures/browser_scheduler/os-streams.mjs"))
        local descriptor = assert(driver._browser_target.import(browser_fixtures.descriptor()))
        local context = driver._new_resolver_context({ io = strategy, target = "browser" }, descriptor)
        local function owner_sources(owner)
            local source = assert(driver.resolve_source(context, owner, "spec/stdlib/titan"), owner)
            local result = {}
            for _, filename in ipairs(source.files or { source.main }) do
                result[#result + 1] = { filename = filename, text = assert(strategy:read_file(filename)) }
            end
            return result
        end
        local called, missing = pcall(undefined_tests, checks.test_references(checks.status_inventory),
            owners, owner_sources, harness)
        local closed, close_error = driver.close_resolver_context(context)
        assert.is_true(called, missing)
        assert.is_true(closed, close_error)
        assert.same({}, missing)
    end)

    it("renders the browser type fixture with collision-free long brackets", function()
        local scanned = { key_order = { "titan.alpha", "titan.beta" }, entries = {
            ["titan.alpha"] = { types = "Module('titan.alpha',{},{})" },
            ["titan.beta"] = { types = "x]=]y]==]z" },
        } }
        local text = checks.type_fixture(scanned)
        assert.truthy(text:find("\n    alpha = [=[Module('titan.alpha',{},{})]=],\n", 1, true), text)
        assert.truthy(text:find("\n    beta = [===[x]=]y]==]z]===],\n", 1, true), text)
        assert.same({ alpha = "Module('titan.alpha',{},{})", beta = "x]=]y]==]z" }, assert(load(text))())
        -- A trailing `]=*` joins the closing bracket, and long brackets cannot
        -- carry a leading newline or a carriage return.
        for value, literal in pairs({
            ["x]"] = "[=[x]]=]", ["x]="] = "[==[x]=]==]", ["x]=="] = "[=[x]==]=]",
            ["x]=]y]=="] = "[===[x]=]y]==]===]", ["]=]"] = "[==[]=]]==]",
            ["\nleading"] = '"\\\nleading"', ["a\r\nb"] = '"a\\13\\\nb"',
        }) do
            local rendered = checks.type_fixture({ key_order = { "titan.value" },
                entries = { ["titan.value"] = { types = value } } })
            assert.truthy(rendered:find("\n    value = " .. literal .. ",\n", 1, true), rendered)
            assert.same({ value = value }, assert(load(rendered))())
        end
    end)

    it("checks in a browser type fixture for every browser provider module", function()
        local expected = {}
        for _, row in ipairs(checks.status_inventory.modules) do
            if row[2] ~= "absent" then expected[row[1]:gsub("^titan%.", "")] = "string" end
        end
        local fixture = assert(loadfile("spec/fixtures/stdlib/titan_stdlib_browser_types.lua", "t", {}))()
        local found = {}
        for name, value in pairs(fixture) do found[name] = type(value) end
        assert.same(expected, found)
    end)

    it("requires every covered inventory test to have passed in a run", function()
        local inventory = {
            modules = { { "titan.core", "present", test = "core.tests", core = true } },
            members = { ["titan.core"] = {
                { "one", "implemented", "core.tests" },
                { "two", "implemented", "mixed.tests.test_two" },
                { "three", "implemented", "mixed.tests.test_three.child" },
            } },
            stock_lua = { { "os.exit", "implemented", "os.browser_tests:exit:3" } },
        }
        local owners = { ["core.tests"] = true, ["mixed.tests"] = true, ["os.browser_tests"] = true }
        local complete = table.concat({
            "[       OK ] core.tests.test_any (0.10 ms)",
            "[       OK ] mixed.tests.test_two (0.20 ms)",
            "[       OK ] mixed.tests.test_three.child (0.30 ms)",
            'OS-STREAMS {"verdict":"PASS","cases":1,"dialogs":0,"names":["exit:3"]}',
        }, "\n")
        assert(checks.require_evidence(inventory, complete, owners))
        -- A sibling's skipped case leaves a parent's own evidence intact.
        assert(checks.require_evidence(inventory, complete:gsub("(%[       OK %] mixed.tests.test_two )",
            "[  SKIPPED ] mixed.tests.test_two_more (capability: fixture) (0.10 ms)\n%1"), owners))
        assert(checks.require_evidence(inventory, "", {}))
        for _, case in ipairs({
            { complete:gsub("%[       OK %] core", "[  SKIPPED ] core"), "titan.core: core.tests" },
            { complete:gsub("test_two", "test_other"), "titan.core.two: mixed.tests.test_two" },
            { complete:gsub("%[       OK %] mixed.tests.test_three.child", "[  FAILED  ] mixed.tests.test_three.child"),
                "titan.core.three: mixed.tests.test_three.child" },
            { complete:gsub('"exit:3"', '"exit:4"'), "stock Lua os.exit: os.browser_tests:exit:3" },
            { complete:gsub('"verdict":"PASS"', '"verdict":"FAIL"'), "stock Lua os.exit: os.browser_tests:exit:3" },
            -- A parent reports OK after a skipped or failed subtest.
            { complete:gsub("(%[       OK %] mixed.tests.test_two )",
                "[  SKIPPED ] mixed.tests.test_two.child (capability: fixture) (0.10 ms)\n%1"),
                "titan.core.two: mixed.tests.test_two" },
            { complete:gsub("(%[       OK %] core)", "[  FAILED  ] core.tests.test_any.child (0.05 ms)\n%1"),
                "titan.core: core.tests" },
        }) do
            local ok, err = checks.require_evidence(inventory, case[1], owners)
            assert.is_nil(ok, case[2])
            assert.truthy(err:find(case[2], 1, true), case[2] .. "\n" .. err)
        end
    end)

    it("keeps type-only owners unreachable except through raise members", function()
        local function status(source, statuses)
            local provider = checked(source)
            local declared = checks.members(assert(driver.decode_module_interface(provider.entries.test.types, "test",
                "fixture interface")))
            local rows = {}
            for name in pairs(checks.status_scope(declared)) do
                local state = statuses[name] or "implemented"
                rows[#rows + 1] = { name, state, (state == "implemented" or state == "raise") and "test.tests.test_case" or nil }
            end
            return checks.check_status(provider, provider,
                { modules = { { "test", "present", test = "test.tests" } }, members = { test = rows } })
        end
        local opaque = "record O\n  local handle: integer\nend\n"
        local owner = { O = "type-only" }
        assert(status(opaque .. "function take(o: O?) end\nfunction O:close() end\n",
            { O = "type-only", ["O:close"] = "type-only" }))
        assert(status(opaque .. "function O.make(): O return { handle = 1 } end\n",
            { O = "type-only", ["O.make"] = "raise" }))
        for _, case in ipairs({
            { opaque .. "function O.make(): O return { handle = 1 } end\n", owner,
                "test.O: type-only owner is reachable through test.O.make" },
            { opaque .. "function fill(out: {O}) end\n", owner, "test.O: type-only owner is reachable through test.fill" },
            { opaque .. "record Box<|T|>\n  item: T\nend\nfunction boxed(): Box<|O|> raise \"unavailable\" end\n", owner,
                "test.O: type-only owner is reachable through test.boxed" },
            { opaque .. "function each(visit: function (O)) end\n", owner,
                "test.O: type-only owner is reachable through test.each" },
            { opaque .. "current: O?\n", owner, "test.O: type-only owner is reachable through test.current" },
            { opaque .. "record Holder\n  item: O?\nend\n", owner,
                "test.O: type-only owner is reachable through test.Holder" },
            { "record O\n  x: integer\nend\n", owner, "test.O: type-only owner can be built from a record literal" },
            { "union O\n  a()\nend\n", owner, "test.O: type-only owner has public variants" },
            { "record P\n  x: integer\nend\nfunction P:get(): integer return self.x end\n", { ["P:get"] = "type-only" },
                "test.P:get: type-only member of an owner that is not type-only" },
        }) do
            local ok, err = status(case[1], case[2])
            assert.is_nil(ok, case[3])
            assert.truthy(err:find(case[3], 1, true), case[3] .. "\n" .. err)
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
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local function canonical(text) return (text:gsub("\r\n", "\n")) end
        local captured = strategy:run({"bash", "scripts/run_browser_stdlib.sh",
            log, diagnostics, lua, producer}, {stderr_to_stdout = true})
        assert.is_true(captured.ok, captured.output)
        assert.equal(report, canonical(assert(strategy:read_file(log))))
        assert.equal(warning, canonical(assert(strategy:read_file(diagnostics))))
        assert.truthy(canonical(captured.output):find(warning, 1, true), captured.output)
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
        assert.equal(report, canonical(assert(strategy:read_file(log))))
        assert.equal(warning, canonical(assert(strategy:read_file(diagnostics))))
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

    it("requires every named image test of the status inventory to pass in a complete run", function()
        local owner, named, cases = "timer.tests", {}, {}
        for _, reference in ipairs(checks.test_references(checks.status_inventory)) do
            if reference.owner == owner and reference.kind == "case" and not named[reference.test] then
                assert.is_nil(reference.test:sub(#owner + 2):find(".", 1, true), reference.test)
                named[reference.test] = true
                cases[#cases + 1] = reference.test
            end
        end
        table.sort(cases)
        assert.is_true(#cases > 1, owner .. " should name more than one inventory case")
        local function report(selected, skipped)
            local rows, passed = { "[==========] Running Titan tests." }, 0
            for _, name in ipairs(selected) do
                rows[#rows + 1] = "[ RUN      ] " .. name
                if name == skipped then
                    rows[#rows + 1] = "[  SKIPPED ] " .. name .. " (capability: fixture) (0.25 ms)"
                else
                    rows[#rows + 1] = "[       OK ] " .. name .. " (0.25 ms)"
                    passed = passed + 1
                end
            end
            rows[#rows + 1] = string.format("[----------] %s (%.2f ms total)", owner, #selected * 0.25)
            rows[#rows + 1] = string.format("[==========] %d tests ran. (%.2f ms total)", #selected, #selected * 0.25 + 1)
            rows[#rows + 1] = "[  PASSED  ] " .. passed .. " tests."
            if skipped then rows[#rows + 1] = "[  SKIPPED ] 1 tests." end
            return table.concat(rows, "\n") .. "\n"
        end
        local roots, log = temporary.name("-browser-roots.txt"), temporary.name("-browser-stdlib.log")
        scratch = { roots, log }
        assert(strategy:write_file(roots, owner .. "\n"))
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local function audit(contents, filter)
            assert(strategy:write_file(log, contents))
            return strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua", "output",
                roots, filter or "", log}, {stderr_to_stdout = true})
        end
        local evidence = "Browser stdlib inventory evidence: every named image test passed."
        local complete = audit(report(cases))
        assert.is_true(complete.ok, complete.output)
        assert.truthy(complete.output:find(evidence, 1, true), complete.output)
        -- A classified skip passes the runner audit but is not evidence.
        local skipped = audit(report(cases, cases[1]))
        assert.is_false(skipped.ok, skipped.output)
        assert.truthy(skipped.output:find("skipped=1 failed=0", 1, true), skipped.output)
        assert.truthy(skipped.output:find("inventory tests that did not pass", 1, true), skipped.output)
        assert.truthy(skipped.output:find(": " .. cases[1], 1, true), skipped.output)
        -- A filtered run may leave named cases unselected.
        local filtered = audit(report({ cases[1] }), "^" .. (cases[1]:gsub("%.", "[.]")) .. "$")
        assert.is_true(filtered.ok, filtered.output)
        assert.truthy(filtered.output:find("(filtered)", 1, true), filtered.output)
        assert.falsy(filtered.output:find(evidence, 1, true), filtered.output)
    end)
end)
