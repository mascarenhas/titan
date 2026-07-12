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
        timer = read_file("stdlib/timer.titan"),
        fs = read_file("stdlib/fs.titan"),
    }
    for name, source in pairs(extra or {}) do modules[name] = source end
    local root = extra and "consumer" or "fs"
    local source = modules[root]
    local ast, parse_errors = parser.parse(root .. ".titan", source)
    assert.truthy(ast, parse_errors and
        parser.error_to_string(parse_errors, root .. ".titan"))
    return checker.check(root, ast, source, root .. ".titan",
        driver.tableloader(modules, {}, {}))
end

describe("fs Phase 3 public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("exports exactly the direct-style file and path API", function()
        local modtype, errors = check_modules()
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.same({
            "File", "Stat", "list", "mkdir", "open", "read_file",
            "rename", "rmdir", "stat", "unlink", "write_file",
        }, sorted_keys(modtype.members))

        local expected = {
            open = "(string, string) -> fs.File",
            read_file = "(string) -> string",
            write_file = "(string, string) -> ()",
            stat = "(string) -> fs.Stat",
            mkdir = "(string) -> ()",
            unlink = "(string) -> ()",
            rmdir = "(string) -> ()",
            rename = "(string, string) -> ()",
            list = "(string) -> { string }",
        }
        for name, signature in pairs(expected) do
            local member = assert(modtype.members[name], "missing " .. name)
            assert.truthy(member.type, name .. " has no type")
            assert.equals(signature, types.tostring(member.type), name)
        end

        local file = assert(types.registry["fs.File"])
        assert.equals(1, file.nfields)
        assert.equals(1, #file.fields)
        assert.equals("handle", file.fields[1].name)
        assert.is_true(file.fields[1].islocal)
        assert.equals("uv.uv_file", types.tostring(file.fields[1].type))
        assert.same({ "close", "flush", "is_closed", "read", "write" },
            sorted_keys(file.methods))
        assert.equals("fs.File:read(integer): string?",
            types.tostring(file.methods.read))
        assert.equals("fs.File:write(string): integer",
            types.tostring(file.methods.write))
        assert.equals("fs.File:flush()", types.tostring(file.methods.flush))
        assert.equals("fs.File:close()", types.tostring(file.methods.close))
        assert.equals("fs.File:is_closed(): boolean",
            types.tostring(file.methods.is_closed))

        local stat = assert(types.registry["fs.Stat"])
        assert.equals(5, stat.nfields)
        assert.same({
            "size", "kind", "mode", "modified_seconds",
            "modified_nanoseconds",
        }, (function()
            local names = {}
            for _, field in ipairs(stat.fields) do
                assert.falsy(field.islocal)
                names[#names + 1] = field.name
            end
            return names
        end)())

        local serialized = types.serialize(modtype)
        assert.not_match("uv_file", serialized, 1, true)
        assert.not_match("uv_fs_t", serialized, 1, true)
        assert.not_match("handle", serialized, 1, true)
        assert.not_match("__test_", serialized, 1, true)
    end)

    it("rejects opaque File construction, fields, and wrong identities",
    function()
        local _, errors = check_modules({ consumer = [[
            local fs = import "fs"
            local uv = import "uv"
            record Other end
            function bad_new(): fs.File return fs.File.new() end
            function bad_literal(): fs.File return {} end
            function bad_uv_new(): uv.uv_file return uv.uv_file.new() end
            function bad_receiver(other: Other): boolean
              return fs.File.is_closed(other)
            end
            function leak(file: uv.uv_file): integer
              return file.handle as integer
            end
        ]] })
        local message = table.concat(errors, "\n")
        assert.match("invalid record function 'new'", message)
        assert.match("cannot construct record type 'fs%.File' outside module 'fs' because it has local fields",
            message)
        assert.match("expected fs%.File", message)
        assert.match("field 'handle' not found in record 'uv%.uv_file'",
            message)
    end)
end)
