local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local stdlib_checker = require "spec.support.stdlib_checker"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
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

local function check_modules(extra)
    types.registry = {}
    driver.imported = {}
    local modules = {
        timer = read_file("stdlib/timer.titan"),
    }
    for name, source in pairs(extra or {}) do modules[name] = source end
    local root = extra and "consumer" or "timer"
    local source = modules[root]
    local ast, parse_errors = parser.parse(root .. ".titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, root .. ".titan"))
    return checker.check(root, ast, source, root .. ".titan",
        driver.tableloader(modules, stdlib_checker.uv_imported(), {}))
end

describe("timer Phase 2 public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("exports only the direct-style timer API", function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.same({ "Ticker", "sleep", "ticker", "yield" },
            sorted_keys(modtype.members))
        assert.equals("(integer) -> ()",
            types.tostring(modtype.members.sleep.type))
        assert.equals("() -> ()", types.tostring(modtype.members.yield.type))
        assert.equals("(integer) -> timer.Ticker",
            types.tostring(modtype.members.ticker.type))

        local ticker = assert(types.registry["timer.Ticker"])
        assert.equals(1, ticker.nfields)
        assert.equals(1, #ticker.fields)
        assert.is_true(ticker.fields[1].islocal)
        assert.equals("handle", ticker.fields[1].name)
        assert.same({ "close", "tick" }, sorted_keys(ticker.methods))
        assert.not_match("uv%.uv_timer_t", types.serialize(modtype))
    end)

    it("rejects construction and substitution of an opaque Ticker", function()
        local _, errors = check_modules({ consumer = [[
            local timer = import "timer"
            local uv = import "uv"
            record Other end
            function bad_new(): timer.Ticker return timer.Ticker.new() end
            function bad_literal(): timer.Ticker return {} end
            function bad_substitute(other: Other): boolean
              return timer.Ticker.tick(other)
            end
        ]] })
        local message = table.concat(errors, "\n")
        assert.match("invalid record function 'new'", message)
        assert.match("cannot construct record type 'timer%.Ticker' outside module 'timer' because it has local fields",
            message)
        assert.match("expected timer%.Ticker", message)
    end)
end)
