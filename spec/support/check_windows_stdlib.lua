-- Explicit Windows stdlib artifact validation; ordinary installation copies files.
local stage, prefix, source, bootstrap, generated = ...
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
local modules = { "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "peg", "string", "path", "math", "lua", "iteration", "gc",
    "test", "reflect", "sqlite3", "json" }
local folders = { uv = true, http = true, websocket = true, peg = true, string = true,
    sqlite3 = true, json = true }
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
    for _, name in ipairs({ "_loadlib", "_loadlibglobal", "_abivalue" }) do
        assert(type(values[1][name]) == "function", "missing Titan support helper " .. name)
    end
    return values[1]
end
local support = open_support(assert(bootstrap))
package.loaded.titan = support
local driver = require "titan-compiler.driver"
local function exports_for_names(logical_names)
    local exports = { luaopen_titan = true }
    for _, name in ipairs(logical_names) do
        local mangled = driver.mangle_module_name(name)
        exports["luaopen_" .. mangled] = true
        for _, suffix in ipairs({ "abi_value", "abi", "types", "layouts", "compatibility", "init" }) do
            exports[mangled .. "_" .. suffix] = true
        end
    end
    return exports
end
local expected_exports = exports_for_names(names)
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
        ["libssl-3-x64.dll"] = true, ["libcrypto-3-x64.dll"] = true,
        ["kernel32.dll"] = true, ["bcrypt.dll"] = true, ["ws2_32.dll"] = true,
        ["ucrtbase.dll"] = true }
    for name in report:gmatch("\n  Name: ([^\r\n]+)") do
        count = count + 1; local lower = name:lower()
        assert(allowed[lower] or lower:match("^api%-ms%-win%-crt%-[%w%-]+%.dll$"),
            "unexpected stdlib import " .. name)
    end
    assert(count > 0, "missing PE import inventory")
end
local objects = {}
for _, name in ipairs(modules) do
    local stem = assert(generated) .. "/titan/" .. name .. (folders[name] and ("/" .. name) or "")
    objects[#objects + 1] = { filename = stem .. ".o", modname = "titan." .. name }
end
local target = assert(driver.derive_target_fingerprint(objects[1].filename, names[1]))
local expected = {}
assert(driver.validate_generated_objects(objects, target, expected))
exact_exports(exported(stage .. "/provider.exports"), expected_exports)
valid_imports(stage .. "/provider.imports")
local callable = assert(driver.library_interface_entries(stage .. "/titan.dll", names))
assert(driver.compare_archive_entries(callable, expected, "Windows stdlib source objects and DLL"))
assert(driver.validate_library_image(stage .. "/titan.dll", names))
open_support(stage .. "/titan.dll")
local plans = assert(driver.plan_module_shims("titan", names))
for index, plan in ipairs(plans) do
    assert(read(stage .. "/" .. modules[index] .. ".lua") == plan.contents,
        "staged shim does not match its exact logical/physical provider: " .. plan.modname)
end
print(("Validated %d Windows stdlib protocols, exact PE inventory and shims."):format(#modules))
