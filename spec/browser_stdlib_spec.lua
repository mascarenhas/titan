local assert = require "luassert"
local checks = dofile("scripts/browser_stdlib.lua")
local types = require "titan-compiler.types"
local strategy = require("titan-compiler.io").new_sync()

describe("browser core stdlib build checks", function()
    it("keeps the provider native payload and include policy lpeglabel-only", function()
        local makefile = assert(strategy:read_file("Makefile"))
        local environment = assert(makefile:match("\nBROWSER_SDK_ENV = (.-)\n\nbrowser%-sdk:"))
        assert.truthy(environment:find("CPPFLAGS= TITAN_EXTRA_CPPFLAGS=$(call make_shell_quote,$(LPEGLABEL_CPPFLAGS))", 1, true))
        local recipe = assert(makefile:match("\nbrowser%-sdk:[^\n]*\n(.-)\n\n"))
        local payloads = {}
        for payload in recipe:gmatch("%-X ([^\n]+)") do payloads[#payloads + 1] = payload end
        assert.same({ "$(call make_shell_quote,$(TITAN_INSTALL_TREE)/lib/titan-browser/$(TITAN_LIBRARY_VERSION)/libtitan-lpeglabel.a) \\" }, payloads)
        for _, forbidden in ipairs({ "STDLIB_EXTRA_OBJECTS", "LIBUV_", "OPENSSL_", "LLHTTP_", "SQLITE3_" }) do
            assert.is_nil((environment .. recipe):find(forbidden, 1, true), forbidden)
        end
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
end)
