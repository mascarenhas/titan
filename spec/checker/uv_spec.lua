local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function configure_libuv()
    local cppflags = { "-Ilibuv-v1.52.1/include" }
    local uname = assert(io.popen("uname -s"))
    local host = assert(uname:read("*l"))
    uname:close()
    if host == "Linux" then
        table.insert(cppflags, "-D_GNU_SOURCE")
    end
    checker.configure_foreign_c({
        compiler = os.getenv("CC") or "cc",
        language_mode = "c99",
        cppflags = cppflags,
        compiler_include_dirs = {
            "titan-runtime",
            "lua-5.5.0/src",
        },
    })
end

local COROUTINE_STUB = [[
    function marker(): boolean
        return true
    end
]]

local function check_module(modname, source, modules)
    types.registry = {}
    driver.imported = {}
    local ast, parse_errors = parser.parse(modname .. ".titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, modname .. ".titan"))
    modules = modules or {}
    modules.coroutine = modules.coroutine or COROUTINE_STUB
    local loader = driver.tableloader(modules, {}, {})
    local modtype, errors = checker.check(modname, ast, source,
        modname .. ".titan", loader)
    return modtype, errors, ast
end

local function check_consumer(source)
    return check_module("consumer", source, {
        uv = read_file("stdlib/uv.titan"),
        coroutine = COROUTINE_STUB,
    })
end

describe("uv native owner interface", function()
    setup(configure_libuv)

    teardown(function()
        driver.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("exports only the opaque timer type and Titan-safe functions", function()
        local source = read_file("stdlib/uv.titan")
        local modtype, errors = check_module("uv", source)
        assert.equals(0, #errors, table.concat(errors, "\n"))

        assert.truthy(modtype.members.uv_timer_t)
        assert.truthy(modtype.members._timer_is_closed)
        assert.truthy(modtype.members._timer_is_closing)
        assert.truthy(modtype.members._phase1_probe)
        assert.truthy(modtype.members.version)
        assert.falsy(modtype.members.Runtime)
        assert.falsy(modtype.members.CallbackState)
        assert.falsy(modtype.members.uv_fs_t)
        assert.falsy(modtype.members.Buffer)

        local timer = assert(types.registry["uv.uv_timer_t"])
        assert.equals("Type.Record", timer._tag)
        assert.equals(8, #timer.fields)
        for _, field in ipairs(timer.fields) do
            assert.is_true(field.islocal,
                "callback-owner field must stay local: " .. field.name)
        end

        local serialized = types.serialize(modtype)
        assert.truthy(serialized:find(
            "Record('uv.uv_timer_t',{},{},{},8)", 1, true))
        assert.not_match("uv_loop_t", serialized, 1, true)
        assert.not_match("uv_timer_t %*", serialized)
        assert.not_match("uv_fs_t", serialized, 1, true)
        assert.not_match("CallbackState", serialized, 1, true)
        assert.not_match("dispatcher", serialized, 1, true)
    end)

    it("rejects a public native pointer if an owner field loses local", function()
        local source = read_file("stdlib/uv.titan")
        local changed, count = source:gsub(
            "local handle: %*libuv%.uv_timer_t",
            "handle: *libuv.uv_timer_t", 1)
        assert.equals(1, count)
        local _, errors = check_module("uv", changed)
        assert.is_true(#errors > 0)
        assert.match("cannot export C FFI type 'uv_timer_t %*'",
            table.concat(errors, "\n"))
    end)

    it("does not expose or permit construction of the opaque timer", function()
        local _, new_errors = check_consumer([[
            local uv = import "uv"

            function bad(): uv.uv_timer_t
                return uv.uv_timer_t.new()
            end
        ]])
        assert.is_true(#new_errors > 0)
        assert.match("invalid record function 'new'",
            table.concat(new_errors, "\n"))

        local _, literal_errors = check_consumer([[
            local uv = import "uv"

            function bad(): uv.uv_timer_t
                return {}
            end
        ]])
        assert.is_true(#literal_errors > 0)
        assert.match("cannot construct record type 'uv%.uv_timer_t' outside module 'uv' because it has local fields",
            table.concat(literal_errors, "\n"))
    end)

    it("requires the exact nominal wrapper in middle-layer calls", function()
        local _, errors = check_consumer([[
            local uv = import "uv"

            record Other
            end

            function bad(other: Other): boolean
                return uv._timer_is_closed(other)
            end
        ]])
        assert.is_true(#errors > 0)
        local message = table.concat(errors, "\n")
        assert.match("expected uv%.uv_timer_t", message)
        assert.match("consumer%.Other", message)
    end)
end)
