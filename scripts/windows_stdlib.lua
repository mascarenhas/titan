-- Source-only Windows stdlib validator/publisher. Validation and publication
-- run in separate Lua processes so publication never maps either public DLL.
local mode, stage, prefix, source, bootstrap = ...
assert(package.config:sub(1, 1) == "\\", "native Windows Lua is required")
assert(mode == "validate" or mode == "publish", "unknown stdlib operation")
local modules = { "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "peg", "string", "math", "lua", "iteration", "gc",
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
local function open_support(path)
    local opener = assert(package.loadlib(path, "luaopen_titan"))
    local values = table.pack(opener())
    assert(values.n == 1 and type(values[1]) == "table", "invalid Titan support table")
    for _, name in ipairs({ "_loadlib", "_loadlibglobal", "_abivalue", "_win_tmpname",
        "_win_reserve_sibling", "_win_replace", "_win_stat", "_win_realpath",
        "_win_abspath", "_win_resolve_executable" }) do
        assert(type(values[1][name]) == "function", "missing Titan support helper " .. name)
    end
    return values[1]
end
local canonical = prefix .. "/lib/titan/0.6/titan.dll"
if mode == "validate" then
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
    local previous_names = {}
    for _, name in ipairs(names) do
        if name ~= "titan.websocket" then previous_names[#previous_names + 1] = name end
    end
    local previous_exports = exports_for_names(previous_names)
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
        local allowed = { ["lua-5.5.1.dll"] = true, ["libuv-1.dll"] = true,
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
        local stem = source .. "/titan/" .. name .. (folders[name] and ("/" .. name) or "")
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
    assert(read(stage .. "/test.titan") == read(source .. "/titan/test.titan"),
        "staged compiler test support differs from source")
    -- Bound predecessor states to absent, support-only, the exact 21-module
    -- pre-WebSocket image, or this complete inventory. This deliberate one-step
    -- growth does not admit arbitrary incomplete/older installed providers.
    local old, old_error, old_code = support._win_stat(canonical, false)
    local full = false
    local predecessor_has_websocket = false
    if old then
        assert(old.kind == "file", "canonical provider must be a regular nonlink file")
        local inventory = exported(stage .. "/previous.exports")
        local count = 0; for _ in pairs(inventory) do count = count + 1 end
        full = count ~= 1
        predecessor_has_websocket = inventory.luaopen_titan_websocket == true
        local old_names = predecessor_has_websocket and names or previous_names
        exact_exports(inventory, full and
            (predecessor_has_websocket and expected_exports or previous_exports) or
            { luaopen_titan = true })
        valid_imports(stage .. "/previous.imports")
        if full then assert(driver.library_interface_entries(canonical, old_names)) end
        open_support(canonical)
    else
        assert(old_code == 2 or old_code == 3, old_error)
    end
    for index, name in ipairs(modules) do
        local path = prefix .. "/share/lua/5.5/titan/" .. name .. ".lua"
        local attr, err, code = support._win_stat(path, false)
        if full and (name ~= "websocket" or predecessor_has_websocket) then
            assert(attr and attr.kind == "file", err or ("missing previous shim " .. path))
            assert(read(path) == plans[index].contents, "unrecognized previous shim " .. path)
        else
            assert(not attr and (code == 2 or code == 3), "unexpected shim outside predecessor inventory " .. path)
        end
    end
    local testpath = prefix .. "/share/titan/0.6/src/titan/test.titan"
    local testattr, testerr, testcode = support._win_stat(testpath, false)
    if full then assert(testattr and testattr.kind == "file", testerr)
    else assert(not testattr and (testcode == 2 or testcode == 3), "unexpected compiler test support") end
    print("Validated 22 Windows stdlib protocols, exact PE inventory, shims and predecessor.")
else
    assert(package.loaded.titan == nil and package.loaded["titan-compiler.driver"] == nil,
        "publication must start without the canonical provider or compiler driver")
    local support = open_support(assert(bootstrap))
    local publication = assert(loadfile(source .. "/titan-compiler/windows_publication.lua"))()
    local lfs = require "lfs"
    local function mkdir(relative)
        local path = prefix
        for component in relative:gmatch("[^/]+") do
            path = path .. "/" .. component
            local attr, err, code = support._win_stat(path, false)
            if not attr then
                assert(code == 2 or code == 3, err); assert(lfs.mkdir(path))
                attr = assert(support._win_stat(path, false))
            end
            assert(attr.kind == "directory", "publication parent is not a regular directory: " .. path)
        end
    end
    assert(assert(support._win_stat(prefix, false)).kind == "directory")
    mkdir("share/lua/5.5/titan"); mkdir("share/titan/0.6/src/titan"); mkdir("lib/titan/0.6")
    local entries = {}
    for _, name in ipairs(modules) do
        entries[#entries + 1] = { destination = prefix .. "/share/lua/5.5/titan/" .. name .. ".lua",
            source = stage .. "/" .. name .. ".lua", shim = true }
    end
    entries[#entries + 1] = { destination = prefix .. "/share/titan/0.6/src/titan/test.titan",
        source = stage .. "/test.titan" }
    entries[#entries + 1] = { destination = canonical, source = stage .. "/titan.dll" }
    assert(publication.publish(entries, { stat = function(path) return support._win_stat(path, false) end,
        reserve = support._win_reserve_sibling, replace = support._win_replace, remove = os.remove }, {
        validate_existing = function(entry, existing)
            if existing and entry.shim and read(entry.destination) ~= read(entry.source) then
                return nil, "unrecognized previous generated shim " .. entry.destination
            end
            return true
        end,
        -- Same source-only injection used by the Unix publication regression.
        -- The final DLL commit is the point that must restore every companion,
        -- including a newly introduced shim absent from the old inventory.
        after_commit = function(index)
            if index == #entries and os.getenv("TITAN_INSTALL_FAIL_AT") == "after:dso" then
                return nil, "injected standard-library failure at after:dso"
            end
            return true
        end,
    }))
    assert(package.loaded.titan == nil and package.loaded["titan-compiler.driver"] == nil)
    print("Published the Windows stdlib DLL, 22 shims and compiler test support.")
end
