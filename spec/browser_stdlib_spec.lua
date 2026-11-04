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
[  FAILED  ] fixture.tests.test_fail
[==========] 1 test ran.
[  PASSED  ] 0 tests.
[  FAILED  ] 1 test.
[  FAILED  ] fixture.tests.test_fail
]]))
        local lua = installed_prefix.active() .. "/bin/lua" .. (platform.windows and ".exe" or "")
        local result = strategy:run({lua, "-E", "scripts/check_browser_stdlib.lua", "output", log, roots, "test_fail"},
            {stderr_to_stdout = true})
        assert.is_false(result.ok)
        assert.truthy(result.output:find("Browser stdlib owner fixture.tests: 1 cases", 1, true), result.output)
        assert.truthy(result.output:find("selected=1 passed=0 skipped=0 failed=1 owners=1/1", 1, true), result.output)
    end)
end)
