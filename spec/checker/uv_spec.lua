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

local function configure_foreign_headers()
    local cppflags = { "-Ilibuv-v1.52.1/include" }
    local uname = assert(io.popen("uname -s"))
    local host = assert(uname:read("*l"))
    uname:close()
    if host == "Linux" then table.insert(cppflags, "-D_GNU_SOURCE") end
    checker.configure_foreign_c({
        compiler = os.getenv("CC") or "cc",
        language_mode = "c99",
        cppflags = cppflags,
        compiler_include_dirs = { "titan-runtime", "lua-5.5.0/src" },
    })
end

local function check_uv()
    types.registry = {}
    driver.imported = {}
    local modules = {
        uv = read_file("stdlib/uv.titan"),
        coroutine = read_file("stdlib/coroutine.titan"),
    }
    local source = modules.uv
    local ast, parse_errors = parser.parse("stdlib/uv.titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, "stdlib/uv.titan"))
    local modtype, errors = checker.check("uv", ast, source,
        "stdlib/uv.titan", driver.tableloader(modules, {}, {}))
    assert.truthy(modtype)
    assert.equals(0, #errors, table.concat(errors, "\n"))
    return modtype
end

local function signature(modtype, name)
    local member = assert(modtype.members[name], "missing member " .. name)
    return types.tostring(member.type)
end

local function sorted_keys(table_value)
    local keys = {}
    for key in pairs(table_value) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

describe("uv Phase 2 public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("locks the Task, error, loop, and timer middle-layer surface", function()
        local modtype = check_uv()
        assert.same({
            "Cancelled", "Error", "Task", "_sleep", "_ticker",
            "_ticker_close", "_ticker_tick", "_yield", "loop", "run",
            "uv_timer_t", "version",
        }, sorted_keys(modtype.members))

        assert.equals("(() -> value) -> uv.Task", signature(modtype, "run"))
        assert.equals("() -> ()", signature(modtype, "loop"))
        assert.equals("() -> string", signature(modtype, "version"))
        assert.equals("(integer) -> ()", signature(modtype, "_sleep"))
        assert.equals("() -> ()", signature(modtype, "_yield"))
        assert.equals("(integer) -> uv.uv_timer_t",
            signature(modtype, "_ticker"))
        assert.equals("(uv.uv_timer_t) -> boolean",
            signature(modtype, "_ticker_tick"))
        assert.equals("(uv.uv_timer_t) -> ()",
            signature(modtype, "_ticker_close"))
    end)

    it("keeps all native and scheduler controls out of the interface", function()
        local modtype = check_uv()
        for _, name in ipairs({
            "Loop", "Runtime", "TimerControl", "Request", "TickerState",
            "timer_dispatch", "UV_TAG", "active_runtime",
        }) do
            assert.falsy(modtype.members[name], name .. " leaked")
        end

        local task = assert(types.registry["uv.Task"])
        assert.equals(25, task.nfields)
        assert.equals(25, #task.fields)
        for _, field in ipairs(task.fields) do assert.is_true(field.islocal) end
        assert.same({ "cancel", "join", "status" }, sorted_keys(task.methods))

        local owner = assert(types.registry["uv.uv_timer_t"])
        assert.equals(8, owner.nfields)
        assert.equals(8, #owner.fields)
        for _, field in ipairs(owner.fields) do assert.is_true(field.islocal) end

        local err = assert(types.registry["uv.Error"])
        assert.equals(5, err.nfields)
        assert.equals(5, #err.fields)
        for _, field in ipairs(err.fields) do assert.falsy(field.islocal) end

        local cancelled = assert(types.registry["uv.Cancelled"])
        assert.equals(1, cancelled.nfields)
        assert.equals("reason", cancelled.fields[1].name)
        assert.falsy(cancelled.fields[1].islocal)

        local serialized = types.serialize(modtype)
        assert.not_match("uv_loop_t", serialized, 1, true)
        assert.not_match("uv_timer_t %*", serialized)
        assert.not_match("uv_fs_t", serialized, 1, true)
        assert.not_match("TimerControl", serialized, 1, true)
        assert.not_match("Request", serialized, 1, true)
        assert.not_match("dispatcher", serialized, 1, true)
        assert.truthy(serialized:find(
            "Record('uv.Task',{},{", 1, true), serialized)
    end)

    it("permits public error construction but not opaque native/Task forging",
    function()
        local source = read_file("stdlib/uv.titan")
        local coroutine_source = read_file("stdlib/coroutine.titan")
        local function check_consumer(consumer)
            types.registry = {}
            driver.imported = {}
            local _, errors = checker.checkimport("consumer",
                driver.tableloader({
                    consumer = consumer,
                    uv = source,
                    coroutine = coroutine_source,
                }, {}, {}))
            return table.concat(errors, "\n")
        end

        local opaque = check_consumer([[
            local uv = import "uv"
            function bad_task(): uv.Task return uv.Task.new() end
            function bad_owner(): uv.uv_timer_t return uv.uv_timer_t.new() end
        ]])
        assert.match("invalid record function 'new'", opaque)

        local literal = check_consumer([[
            local uv = import "uv"
            function bad(): uv.Task return {} end
        ]])
        assert.match("cannot construct record type 'uv%.Task' outside module 'uv' because it has local fields",
            literal)

        local errors = check_consumer([[
            local uv = import "uv"
            function good(): uv.Error
              return uv.Error.new(-1, "E", "message", "operation", nil)
            end
            function cancelled(): uv.Cancelled
              return uv.Cancelled.new("reason")
            end
        ]])
        assert.equals("", errors)
    end)
end)
