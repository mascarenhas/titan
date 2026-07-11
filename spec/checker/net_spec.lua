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
        net = read_file("stdlib/net.titan"),
    }
    for name, source in pairs(extra or {}) do modules[name] = source end
    local root = extra and "consumer" or "net"
    local source = modules[root]
    local ast, parse_errors = parser.parse(root .. ".titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, root .. ".titan"))
    return checker.check(root, ast, source, root .. ".titan",
        driver.tableloader(modules, {}, {}))
end

describe("net Phase 5 public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("exports exactly the direct-style TCP API", function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.same({ "Connection", "Server", "connect", "listen" },
            sorted_keys(modtype.members))

        assert.equals("(string, integer) -> net.Connection",
            types.tostring(modtype.members.connect.type))
        assert.equals("(string, integer, integer) -> net.Server",
            types.tostring(modtype.members.listen.type))

        local connection = assert(types.registry["net.Connection"])
        assert.equals(3, connection.nfields)
        assert.same({ "handle", "excess", "reading" }, (function()
            local names = {}
            for _, field in ipairs(connection.fields) do
                assert.is_true(field.islocal)
                names[#names + 1] = field.name
            end
            return names
        end)())
        assert.equals("uv.uv_tcp_t",
            types.tostring(connection.fields[1].type))
        assert.same({
            "close", "read_exactly", "read_some", "read_until",
            "shutdown", "write",
        }, sorted_keys(connection.methods))
        assert.equals("net.Connection:read_some(integer): string?",
            types.tostring(connection.methods.read_some))
        assert.equals("net.Connection:read_exactly(integer): string",
            types.tostring(connection.methods.read_exactly))
        assert.equals("net.Connection:read_until(string, integer): string",
            types.tostring(connection.methods.read_until))
        assert.equals("net.Connection:write(string)",
            types.tostring(connection.methods.write))
        assert.equals("net.Connection:shutdown()",
            types.tostring(connection.methods.shutdown))
        assert.equals("net.Connection:close()",
            types.tostring(connection.methods.close))

        local server = assert(types.registry["net.Server"])
        assert.equals(1, server.nfields)
        assert.equals("handle", server.fields[1].name)
        assert.is_true(server.fields[1].islocal)
        assert.equals("uv.uv_tcp_t", types.tostring(server.fields[1].type))
        assert.same({ "accept", "close" }, sorted_keys(server.methods))
        assert.equals("net.Server:accept(): net.Connection",
            types.tostring(server.methods.accept))
        assert.equals("net.Server:close()",
            types.tostring(server.methods.close))

        local serialized = types.serialize(modtype)
        for _, hidden in ipairs({
            "uv_tcp_t", "handle", "excess", "reading", "_net_",
            "__test_",
        }) do
            assert.not_match(hidden, serialized, 1, true)
        end
    end)

    it("rejects opaque construction, field access, and wrong receivers",
    function()
        local _, errors = check_modules({ consumer = [[
            local net = import "net"
            local uv = import "uv"
            record Other end
            function bad_connection_new(): net.Connection
              return net.Connection.new()
            end
            function bad_connection_literal(): net.Connection return {} end
            function bad_server_literal(): net.Server return {} end
            function bad_native_new(): uv.uv_tcp_t
              return uv.uv_tcp_t.new()
            end
            function bad_field(connection: net.Connection): value
              return connection.handle
            end
            local function takes_connection(connection: net.Connection)
              connection:close()
            end
            function bad_receiver(other: Other)
              takes_connection(other)
            end
        ]] })
        local message = table.concat(errors, "\n")
        assert.match("invalid record function 'new'", message)
        assert.match("cannot construct record type 'net%.Connection' outside module 'net' because it has local fields",
            message)
        assert.match("cannot construct record type 'net%.Server' outside module 'net' because it has local fields",
            message)
        assert.match("field 'handle' not found in record 'net%.Connection'",
            message)
        assert.match("expected net%.Connection", message)
    end)

    it("keeps the native pointer field local to uv", function()
        local _, errors = check_modules({ consumer = [[
            local uv = import "uv"
            function leak(handle: uv.uv_tcp_t): value
              return handle.handle
            end
        ]] })
        assert.match("field 'handle' not found in record 'uv%.uv_tcp_t'",
            table.concat(errors, "\n"))
    end)
end)
