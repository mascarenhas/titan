-- Explicit Windows stdlib artifact validation; ordinary installation copies files.
local stage, prefix, source, bootstrap, generated, crypto, ssl = ...
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
local modules = { "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "peg", "string", "path", "math", "lua", "iteration", "gc",
    "test", "reflect", "sqlite3", "json", "protobuf", "transfer", "thread" }
-- Each object path follows the module's selected source layout (see
-- spec/support/stdlib_objects.lua), never a hand-kept flat/folder list.
package.path = source .. "/?.lua;" .. package.path
local names = {}
for _, name in ipairs(modules) do names[#names + 1] = "titan." .. name end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("a")); assert(file:close())
    return contents
end
for _, filename in ipairs({ "libuv-LICENSE", "libuv-LICENSE-extra",
        "libuv-tree-LICENSE", "libuv-inet-LICENSE" }) do
    assert(read(prefix .. "/share/titan/LICENSES/" .. filename) ==
           read(source .. "/LICENSES/" .. filename),
           "installed libuv license differs from source: " .. filename)
end
local function open_support(path)
    local opener = assert(package.loadlib(path, "luaopen_titan"))
    local values = table.pack(opener())
    assert(values.n == 1 and type(values[1]) == "table", "invalid Titan support table")
    for _, name in ipairs({ "_loadlib", "_loadlibglobal", "_abivalue",
            "_executable_dir", "_compiler_root", "_expand_titan_path" }) do
        assert(type(values[1][name]) == "function", "missing Titan support helper " .. name)
    end
    return values[1]
end
local support = open_support(assert(bootstrap))
package.loaded.titan = support
local driver = require "titan-compiler.driver"
local objectmetadata = require "titan-compiler.objectmetadata"
local stdlib_objects = require "spec.support.stdlib_objects"
local function exported(path)
    local report, found = read(path), {}
    assert(report:match("Format: COFF%-x86%-64"), "provider is not x64 PE/COFF")
    assert(not report:find("ForwardedTo:", 1, true), "forwarded exports are unsupported")
    local count = 0
    for block in report:gmatch("Export%s*{([^}]*)}") do
        count = count + 1
        local name = block:match("\n%s*Name: ([^\r\n]+)")
        assert(name and name ~= "", "ordinal-only PE exports are unsupported")
        assert(not found[name], "duplicate PE export " .. name)
        found[name] = true
    end
    assert(count > 0, "missing PE export inventory")
    return found
end
local function exact_exports(found, expected)
    for name in pairs(found) do assert(expected[name], "unexpected PE export " .. name) end
    for name in pairs(expected) do assert(found[name], "missing PE export " .. name) end
end
local function valid_imports(path)
    local report, count = read(path), 0
    local allowed = { ["lua55.dll"] = true, ["libuv-1.dll"] = true,
        ["libllhttp-9.4.dll"] = true, ["libsqlite3-0.dll"] = true,
        [crypto:lower()] = true, [ssl:lower()] = true,
        ["kernel32.dll"] = true, ["bcrypt.dll"] = true, ["ws2_32.dll"] = true,
        ["ucrtbase.dll"] = true }
    for name in report:gmatch("\n  Name: ([^\r\n]+)") do
        count = count + 1; local lower = name:lower()
        assert(allowed[lower] or lower:match("^api%-ms%-win%-crt%-[%w%-]+%.dll$"),
            "unexpected stdlib import " .. name)
    end
    assert(count > 0, "missing PE import inventory")
end
local objects, interfaces = {}, {}
local resolver = driver.new_resolver_context({ target = "windows" })
for _, name in ipairs(modules) do
    local filename = stdlib_objects.object(resolver, "titan." .. name, source, assert(generated))
    objects[#objects + 1] = { filename = filename, modname = "titan." .. name }
    -- The provider link reads these same generated-object interfaces, so the
    -- expected export inventory is the producer's, including public raw
    -- foreign entries; never a fixed protocol-only list.
    local entry, err = objectmetadata.read(read(filename), filename)
    assert(entry and entry.type, err or
        ("missing module interface metadata: " .. filename))
    assert(entry.type.name == "titan." .. name,
        "object interface metadata names " .. tostring(entry.type.name) ..
        " instead of titan." .. name)
    interfaces[entry.type.name] = entry.type
end
assert(driver.close_resolver_context(resolver))
local target = assert(driver.derive_target_fingerprint(objects[1].filename, names[1]))
local expected = {}
assert(driver.validate_generated_objects(objects, target, expected))
local _, expected_names = driver.windows_provider_exports(names, interfaces)
local expected_exports = {}
for _, name in ipairs(expected_names) do expected_exports[name] = true end
exact_exports(exported(stage .. "/provider.exports"), expected_exports)
valid_imports(stage .. "/provider.imports")
local callable = assert(driver.library_interface_entries(stage .. "/titan.dll", names))
assert(driver.compare_archive_entries(callable, expected, "Windows stdlib source objects and DLL"))
assert(driver.validate_library_image(stage .. "/titan.dll", names))
print(("Validated %d Windows stdlib protocols and exact PE inventory."):format(#modules))
