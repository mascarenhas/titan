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

local function count_plain(value, needle)
    local count = 0
    local start = 1
    while true do
        local found = value:find(needle, start, true)
        if not found then return count end
        count = count + 1
        start = found + #needle
    end
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

    it("exports only the portable helper, signal, and process API", function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.same({
            "ExitStatus", "Process", "chdir", "communicate", "cwd",
            "exepath", "getenv", "homedir", "hostname", "pid", "ppid",
            "setenv", "spawn", "tmpdir", "unsetenv", "wait_signal",
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
        assert.equals("(string, { string }) -> os.Process",
            signature(modtype, "spawn"))
        assert.equals(
            "(string, { string }, string?) -> (string, string, os.ExitStatus)",
            signature(modtype, "communicate"))

        local status = assert(types.registry["os.ExitStatus"])
        assert.equals(3, status.nfields)
        assert.same({ "code", "signal", "signal_number" }, (function()
            local names = {}
            for _, field in ipairs(status.fields) do
                assert.falsy(field.islocal)
                names[#names + 1] = field.name
            end
            return names
        end)())
        assert.equals("integer", types.tostring(status.fields[1].type))
        assert.equals("string?", types.tostring(status.fields[2].type))
        assert.equals("integer", types.tostring(status.fields[3].type))

        local process = assert(types.registry["os.Process"])
        assert.equals(1, process.nfields)
        assert.equals("handle", process.fields[1].name)
        assert.is_true(process.fields[1].islocal)
        assert.equals("uv.uv_process_t",
            types.tostring(process.fields[1].type))
        assert.same({
            "close_stdin", "kill", "read_stderr", "read_stdout", "wait",
            "write_stdin",
        }, sorted_keys(process.methods))
        assert.equals("os.Process:wait(): os.ExitStatus",
            types.tostring(process.methods.wait))
        assert.equals("os.Process:kill(string)",
            types.tostring(process.methods.kill))
        assert.equals("os.Process:write_stdin(string)",
            types.tostring(process.methods.write_stdin))
        assert.equals("os.Process:close_stdin()",
            types.tostring(process.methods.close_stdin))
        assert.equals("os.Process:read_stdout(integer): string?",
            types.tostring(process.methods.read_stdout))
        assert.equals("os.Process:read_stderr(integer): string?",
            types.tostring(process.methods.read_stderr))

        -- tableloader serializes and rehydrates imported source modules by
        -- the same interface representation used for .so-only imports. The
        -- native owner retains its fixed slot count, but none of its local
        -- fields or constructor may cross that boundary.
        local native = assert(types.registry["uv.uv_process_t"])
        assert.equals(8, native.nfields)
        assert.equals(0, #native.fields)
        assert.falsy(native.functions.new)
        local serialized = types.serialize(modtype)
        for _, hidden in ipairs({
            "_os_", "uv_", "uv%.", "handle", "titan_uvshim", "ffi%.",
        }) do
            assert.not_match(hidden, serialized)
        end

        local source = read_file("stdlib/os.titan")
        assert.not_match("foreign%s+import", source)
        assert.match('local uv = import "uv"', source, 1, true)
    end)

    it("keeps Process opaque and enforces exact record identities", function()
        local _, errors = check_modules({ consumer = [[
            local os = import "os"
            local uv = import "uv"
            record Other end
            function bad_new(): os.Process return os.Process.new() end
            function bad_literal(): os.Process return {} end
            function bad_native_new(): uv.uv_process_t
              return uv.uv_process_t.new()
            end
            function bad_field(process: os.Process): value
              return process.handle
            end
            local function takes_process(process: os.Process)
              process:wait()
            end
            function bad_receiver(other: Other)
              takes_process(other)
            end
        ]] })
        local message = table.concat(errors, "\n")
        assert.equals(2,
            count_plain(message, "invalid record function 'new'"))
        assert.match("cannot construct record type 'os%.Process' outside module 'os' because it has local fields",
            message)
        assert.match("field 'handle' not found in record 'os%.Process'",
            message)
        assert.match("expected os%.Process", message)
    end)

    it("enforces the public argument types", function()
        local _, errors = check_modules({ consumer = [[
            local os = import "os"
            function bad_getenv(): string? return os.getenv(17) end
            function bad_setenv() os.setenv("name", false) end
            function bad_chdir() os.chdir({}) end
            function bad_signal(): string return os.wait_signal(9) end
            function bad_spawn(): os.Process return os.spawn(9, {}) end
            function bad_args(): os.Process return os.spawn("x", { 1 }) end
            function bad_communicate()
              os.communicate("x", {}, 17)
            end
        ]] })
        local message = table.concat(errors, "\n")
        assert.match("expected string but found integer", message)
        assert.match("expected string but found boolean", message)
        assert.match("expected string but found", message)
    end)
end)
