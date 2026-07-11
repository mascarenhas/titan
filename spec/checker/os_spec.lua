local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
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
    if host == "Linux" then cppflags[#cppflags + 1] = "-D_GNU_SOURCE" end
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
        coroutine = read_file("stdlib/coroutine.titan"),
        uv = read_file("stdlib/uv.titan"),
        os = read_file("stdlib/os.titan"),
    }
    for name, source in pairs(extra or {}) do modules[name] = source end
    local root = extra and "consumer" or "os"
    local source = modules[root]
    local ast, parse_errors = parser.parse(root .. ".titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, root .. ".titan"))
    return checker.check(root, ast, source, root .. ".titan",
        driver.tableloader(modules, {}, {}))
end

local function signature(modtype, name)
    return types.tostring(assert(modtype.members[name], name).type)
end

describe("os Phase 6 public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("exports the portable helper and one-shot signal API", function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.same({
            "chdir", "cwd", "exepath", "getenv", "homedir", "hostname",
            "pid", "ppid", "setenv", "tmpdir", "unsetenv", "wait_signal",
        }, sorted_keys(modtype.members))

        assert.equals("(string) -> string?", signature(modtype, "getenv"))
        assert.equals("(string, string) -> ()",
            signature(modtype, "setenv"))
        assert.equals("(string) -> ()", signature(modtype, "unsetenv"))
        assert.equals("() -> string", signature(modtype, "cwd"))
        assert.equals("(string) -> ()", signature(modtype, "chdir"))
        for _, name in ipairs({ "homedir", "tmpdir", "hostname", "exepath" }) do
            assert.equals("() -> string", signature(modtype, name))
        end
        assert.equals("() -> integer", signature(modtype, "pid"))
        assert.equals("() -> integer", signature(modtype, "ppid"))
        assert.equals("(string) -> string",
            signature(modtype, "wait_signal"))
    end)

    it("keeps the C boundary and uv bridge out of the serialized interface",
    function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        local serialized = types.serialize(modtype)
        for _, hidden in ipairs({
            "_os_", "uv_", "uv%.", "titan_uvshim", "ffi%.",
        }) do
            assert.not_match(hidden, serialized)
        end

        local source = read_file("stdlib/os.titan")
        assert.not_match("foreign%s+import", source)
        assert.match('local uv = import "uv"', source, 1, true)
    end)

    it("enforces the public argument types", function()
        local _, errors = check_modules({ consumer = [[
            local os = import "os"
            function bad_getenv(): string? return os.getenv(17) end
            function bad_setenv() os.setenv("name", false) end
            function bad_chdir() os.chdir({}) end
            function bad_signal(): string return os.wait_signal(9) end
        ]] })
        local message = table.concat(errors, "\n")
        assert.match("expected string but found integer", message)
        assert.match("expected string but found boolean", message)
        assert.match("expected string but found", message)
    end)
end)
