local assert = require "luassert"
local lfs = require "lfs"

local INSTALLER_SCRIPT =
    lfs.currentdir() .. "/scripts/stdlib_installer.lua"
local installer = assert(loadfile(INSTALLER_SCRIPT))()
local NEW_TEST_SOURCE = "new titan.test support source\n"
local PRIOR_TEST_SOURCE = "prior titan.test support source\n"
local TEST_SOURCE_RELATIVE = "share/titan/0.6/src/titan/test.titan"
local RUNTIME_ARCHIVE_RELATIVE = "lib/titan/0.6/libtitan.a"
local RUNTIME_ARCHIVE_CONTENTS = "installed runtime SDK archive\n"

local function make_directory(path)
    if lfs.symlinkattributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), path)
end

local function write_file(path, contents)
    make_directory(assert(path:match("^(.*)/[^/]+$")))
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function set_file_metadata(path, permissions, modification)
    local ok, why, code = os.execute(
        "chmod " .. permissions .. " " .. shell_quote(path))
    assert.truthy(ok, path .. ": " .. tostring(why) .. ":" .. tostring(code))
    assert.truthy(lfs.touch(path, modification, modification), path)
end

local function snapshot_path(path)
    if not lfs.symlinkattributes(path) then return false end
    local entries = {}
    local function visit(current, relative)
        local attr = assert(lfs.symlinkattributes(current), current)
        local entry = {
            path = relative,
            mode = attr.mode,
            permissions = attr.permissions,
            modification = attr.modification,
            size = attr.size,
        }
        if attr.mode == "file" then entry.contents = read_file(current) end
        entries[#entries + 1] = entry
        if attr.mode == "directory" then
            local names = {}
            for name in lfs.dir(current) do
                if name ~= "." and name ~= ".." then
                    names[#names + 1] = name
                end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                visit(current .. "/" .. name,
                    relative == "" and name or relative .. "/" .. name)
            end
        end
    end
    visit(path, "")
    return entries
end

local predecessor_states = {}

local function predecessor_paths(root)
    local paths = {
        root .. "/" .. RUNTIME_ARCHIVE_RELATIVE,
        root .. "/lib/titan/0.6/titan.so",
        root .. "/lib/titan/0.6/titan.a",
        root .. "/lib/titan/0.6/titan.so.dSYM",
        root .. "/" .. TEST_SOURCE_RELATIVE,
        root .. "/lib/titan/0.6/titan/uv.so",
        root .. "/lib/lua/5.5/titan.so",
    }
    for _, module in ipairs(installer.MODULES) do
        paths[#paths + 1] =
            root .. "/share/lua/5.5/titan/" .. module .. ".lua"
    end
    return paths
end

local function capture_predecessor(root)
    local states = {}
    for _, path in ipairs(predecessor_paths(root)) do
        states[path] = snapshot_path(path)
    end
    predecessor_states[root] = states
end

local function assert_predecessor_exact(root)
    local states = assert(predecessor_states[root], root)
    for _, path in ipairs(predecessor_paths(root)) do
        assert.same(states[path], snapshot_path(path), path)
    end
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function make_stage(path)
    write_file(path .. "/titan.so", "new combined image\n")
    write_file(path .. "/titan.a", "new combined archive\n")
    write_file(path ..
        "/titan.so.dSYM/Contents/Resources/DWARF/titan.so",
        "new symbols\n")
    for _, module in ipairs(installer.MODULES) do
        write_file(path .. "/titan/" .. module .. ".lua",
            installer.shim_contents("titan." .. module))
    end
    write_file(path .. "/titan/test.titan", NEW_TEST_SOURCE)
end

local function fake_entries(extra)
    local entries = {}
    for _, name in ipairs(installer.MODULE_NAMES) do
        entries[name] = {
            abi = "2",
            types = "types:" .. name,
        }
    end
    if extra then
        for name, entry in pairs(extra) do entries[name] = entry end
    end
    return entries
end

local function clone_entries(entries)
    local clone = {}
    for name, entry in pairs(entries) do
        clone[name] = {
            abi = entry.abi,
            types = entry.types,
        }
    end
    return clone
end

local function fake_prior_archive_scanner(path)
    local contents = read_file(path)
    local entries = fake_entries()
    if contents == "seventeen-key prior archive\n" then
        entries["titan.test"] = nil
    elseif contents == "prior archive with retired key\n" then
        entries["titan.retired"] = {
            abi = "2",
            types = "types:titan.retired",
        }
    end
    return { entries = entries }
end

local function publish(options)
    options.image_validator = function() return true end
    options.prior_archive_scanner = fake_prior_archive_scanner
    return installer.publish(options)
end

local function assert_unique_regular_file(path)
    local direct = assert(lfs.symlinkattributes(path), path)
    assert.equal("file", direct.mode, path)
    local followed = assert(lfs.attributes(path), path)
    assert.equal(1, followed.nlink, path)
end

local function assert_no_active_compatibility_copies(root)
    local library_dir = root .. "/lib/titan/0.6"
    local lua_cdir = root .. "/lib/lua/5.5"
    for _, module in ipairs(installer.MODULES) do
        for _, path in ipairs({
            library_dir .. "/titan/" .. module .. ".so",
            library_dir .. "/" .. module .. ".so",
            lua_cdir .. "/titan/" .. module .. ".so",
            lua_cdir .. "/titan/stdlib_0_6/" .. module .. ".so",
        }) do
            assert.is_nil(lfs.symlinkattributes(path), path)
            assert.is_nil(lfs.symlinkattributes(path .. ".dSYM"),
                path .. ".dSYM")
        end
    end
    assert.is_nil(lfs.symlinkattributes(lua_cdir .. "/titan.so"))
    assert.is_nil(lfs.symlinkattributes(lua_cdir .. "/titan.so.dSYM"))
end

local function seed_active_debris(root)
    write_file(root .. "/lib/titan/0.6/titan/uv.so", "stale child\n")
    write_file(root .. "/lib/lua/5.5/titan.so", "old manifest support\n")
end

local function seed_runtime_archive(root)
    local path = root .. "/" .. RUNTIME_ARCHIVE_RELATIVE
    write_file(path, RUNTIME_ARCHIVE_CONTENTS)
    set_file_metadata(path, "0640", 1009843200)
end

local function assert_runtime_archive_untouched(root)
    local path = root .. "/" .. RUNTIME_ARCHIVE_RELATIVE
    local states = assert(predecessor_states[root], root)
    assert.same(states[path], snapshot_path(path), path)
    assert_unique_regular_file(path)
end

local function seed_bootstrap(root)
    seed_runtime_archive(root)
    write_file(root .. "/lib/titan/0.6/titan.so", "bootstrap image\n")
    set_file_metadata(
        root .. "/lib/titan/0.6/titan.so", "0750", 1009843201)
    capture_predecessor(root)
end

local function seed_complete_pair(root)
    seed_runtime_archive(root)
    write_file(root .. "/lib/titan/0.6/titan.so", "prior image\n")
    write_file(root ..
        "/lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so",
        "prior symbols\n")
    for _, module in ipairs(installer.MODULES) do
        write_file(root .. "/share/lua/5.5/titan/" .. module .. ".lua",
            installer.shim_contents("titan." .. module))
    end
    write_file(root .. "/" .. TEST_SOURCE_RELATIVE, PRIOR_TEST_SOURCE)
    seed_active_debris(root)
    write_file(root .. "/lib/titan/0.6/titan.a", "prior archive\n")
    set_file_metadata(
        root .. "/lib/titan/0.6/titan.so", "0750", 1009843210)
    set_file_metadata(root ..
        "/lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so",
        "0600", 1009843211)
    for index, module in ipairs(installer.MODULES) do
        set_file_metadata(root .. "/share/lua/5.5/titan/" ..
            module .. ".lua", "0640", 1009843220 + index)
    end
    set_file_metadata(root .. "/" .. TEST_SOURCE_RELATIVE,
        "0640", 1009843239)
    set_file_metadata(
        root .. "/lib/titan/0.6/titan/uv.so", "0644", 1009843230)
    set_file_metadata(
        root .. "/lib/lua/5.5/titan.so", "0644", 1009843231)
    set_file_metadata(
        root .. "/lib/titan/0.6/titan.a", "0640", 1009843240)
    capture_predecessor(root)
end

local function seed_seventeen_key_pair(root)
    seed_complete_pair(root)
    os.remove(root .. "/share/lua/5.5/titan/test.lua")
    os.remove(root .. "/" .. TEST_SOURCE_RELATIVE)
    write_file(root .. "/lib/titan/0.6/titan.a",
        "seventeen-key prior archive\n")
    capture_predecessor(root)
end

local function assert_seventeen_key_pair(root)
    assert.equal("prior image\n",
        read_file(root .. "/lib/titan/0.6/titan.so"))
    assert.equal("seventeen-key prior archive\n",
        read_file(root .. "/lib/titan/0.6/titan.a"))
    assert.is_nil(lfs.symlinkattributes(
        root .. "/share/lua/5.5/titan/test.lua"))
    assert.is_nil(lfs.symlinkattributes(
        root .. "/" .. TEST_SOURCE_RELATIVE))
end

local function assert_bootstrap(root)
    assert_runtime_archive_untouched(root)
    assert.equal("bootstrap image\n",
        read_file(root .. "/lib/titan/0.6/titan.so"))
    assert_unique_regular_file(root .. "/lib/titan/0.6/titan.so")
    assert.is_nil(lfs.symlinkattributes(root .. "/lib/titan/0.6/titan.a"))
    assert.is_nil(lfs.symlinkattributes(
        root .. "/lib/titan/0.6/titan.so.dSYM"))
    for _, module in ipairs(installer.MODULES) do
        assert.is_nil(lfs.symlinkattributes(
            root .. "/share/lua/5.5/titan/" .. module .. ".lua"))
    end
    assert.is_nil(lfs.symlinkattributes(
        root .. "/" .. TEST_SOURCE_RELATIVE))
    assert_no_active_compatibility_copies(root)
end

local function assert_complete_pair(root)
    assert_runtime_archive_untouched(root)
    assert.equal("prior image\n",
        read_file(root .. "/lib/titan/0.6/titan.so"))
    assert.equal("prior symbols\n", read_file(root ..
        "/lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so"))
    for _, module in ipairs(installer.MODULES) do
        assert.equal(installer.shim_contents("titan." .. module),
            read_file(root ..
                "/share/lua/5.5/titan/" .. module .. ".lua"))
    end
    assert.equal("stale child\n",
        read_file(root .. "/lib/titan/0.6/titan/uv.so"))
    assert.equal("old manifest support\n",
        read_file(root .. "/lib/lua/5.5/titan.so"))
    assert.equal("prior archive\n",
        read_file(root .. "/lib/titan/0.6/titan.a"))
    assert.equal(PRIOR_TEST_SOURCE,
        read_file(root .. "/" .. TEST_SOURCE_RELATIVE))
end

local function assert_no_transaction_residue(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode ~= "directory" then return end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            assert.falsy(name:find(".titan-install-", 1, true),
                path .. "/" .. name)
            assert_no_transaction_residue(path .. "/" .. name)
        end
    end
end

local function assert_new_install(root, darwin)
    assert_runtime_archive_untouched(root)
    assert.equal("new combined image\n",
        read_file(root .. "/lib/titan/0.6/titan.so"))
    assert.equal("new combined archive\n",
        read_file(root .. "/lib/titan/0.6/titan.a"))
    assert_unique_regular_file(root .. "/lib/titan/0.6/titan.so")
    assert_unique_regular_file(root .. "/lib/titan/0.6/titan.a")
    for _, module in ipairs(installer.MODULES) do
        local path = root .. "/share/lua/5.5/titan/" .. module .. ".lua"
        assert.equal(installer.shim_contents("titan." .. module),
            read_file(path))
        assert_unique_regular_file(path)
    end
    local test_source = root .. "/" .. TEST_SOURCE_RELATIVE
    assert.equal(NEW_TEST_SOURCE, read_file(test_source))
    assert_unique_regular_file(test_source)
    local dsym = root .. "/lib/titan/0.6/titan.so.dSYM"
    if darwin then
        assert.equal("new symbols\n",
            read_file(dsym .. "/Contents/Resources/DWARF/titan.so"))
    else
        assert.is_nil(lfs.symlinkattributes(dsym))
    end
    assert_no_active_compatibility_copies(root)
    assert_no_transaction_residue(root)
end

describe("recoverable paired standard-library publication", function()
    local workspace
    local stage
    local root
    local old_failpoint

    it("owns the exact current eighteen-module public layout", function()
        assert.same({
            "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
            "url", "http", "os", "peg", "string", "math", "lua", "iteration",
            "gc", "test",
        }, installer.MODULES)
        assert.same({
            "titan.coroutine", "titan.uv", "titan.async", "titan.timer",
            "titan.io", "titan.fs", "titan.net", "titan.ssl", "titan.url",
            "titan.http", "titan.os", "titan.peg", "titan.string",
            "titan.math", "titan.lua", "titan.iteration", "titan.gc",
            "titan.test",
        }, installer.MODULE_NAMES)
    end)

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        stage = workspace .. "/stage"
        root = workspace .. "/root"
        make_stage(stage)
        old_failpoint = os.getenv("TITAN_INSTALL_FAIL_AT")
    end)

    after_each(function()
        assert.equal(old_failpoint, os.getenv("TITAN_INSTALL_FAIL_AT"))
        if workspace then remove_tree(workspace) end
    end)

    for _, predecessor in ipairs({
        { "bootstrap-only first install", seed_bootstrap },
        { "seventeen-key current-library upgrade", seed_seventeen_key_pair },
        { "complete-pair upgrade", seed_complete_pair },
    }) do
        it("publishes the pair over a " .. predecessor[1], function()
            predecessor[2](root)
            local ok, err = publish({
                stage = stage, root = root, platform = "Linux",
            })
            assert.truthy(ok, err)
            assert_new_install(root, false)
        end)
    end

    it("repeats a complete publication and retires current-layout debris",
       function()
        seed_complete_pair(root)
        local ok, err = publish({
            stage = stage, root = root, platform = "Darwin",
        })
        assert.truthy(ok, err)
        assert_new_install(root, true)

        -- A repeated source installation publishes the same complete set over
        -- its own predecessor. Reintroduced active-layout debris is retired.
        seed_active_debris(root)
        ok, err = publish({
            stage = stage, root = root, platform = "Darwin",
        })
        assert.truthy(ok, err)
        assert_new_install(root, true)
    end)

    it("publishes archive before the DSO with stable public permissions",
       function()
        seed_complete_pair(root)
        local ok, err = publish({
            stage = stage, root = root, platform = "Darwin",
        })
        assert.truthy(ok, err)
        assert_new_install(root, true)
        assert.equal("rwxr-xr-x",
            lfs.attributes(root .. "/lib/titan/0.6/titan.so").permissions)
        assert.equal("rw-r--r--",
            lfs.attributes(root .. "/lib/titan/0.6/titan.a").permissions)
        for _, module in ipairs(installer.MODULES) do
            assert.equal("rw-r--r--", lfs.attributes(root ..
                "/share/lua/5.5/titan/" .. module .. ".lua").permissions)
        end
        assert.equal("rw-r--r--", lfs.attributes(
            root .. "/" .. TEST_SOURCE_RELATIVE).permissions)
    end)

    it("retires only exact generated shims named by the old archive",
       function()
        seed_complete_pair(root)
        write_file(root .. "/lib/titan/0.6/titan.a",
            "prior archive with retired key\n")
        write_file(root .. "/share/lua/5.5/titan/retired.lua",
            installer.shim_contents("titan.retired"))
        write_file(root .. "/share/lua/5.5/titan/user.lua",
            "return 'user-owned'\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.truthy(ok, err)
        assert.is_nil(lfs.symlinkattributes(
            root .. "/share/lua/5.5/titan/retired.lua"))
        assert.equal("return 'user-owned'\n",
            read_file(root .. "/share/lua/5.5/titan/user.lua"))
    end)

    it("does not infer stale shim ownership from a bootstrap-only predecessor",
       function()
        seed_bootstrap(root)
        write_file(root .. "/share/lua/5.5/titan/retired.lua",
            installer.shim_contents("titan.retired"))
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.truthy(ok, err)
        assert.equal(installer.shim_contents("titan.retired"),
            read_file(root .. "/share/lua/5.5/titan/retired.lua"))
    end)

    it("refuses to retire an old-key shim with a different exact template",
       function()
        seed_complete_pair(root)
        write_file(root .. "/lib/titan/0.6/titan.a",
            "prior archive with retired key\n")
        write_file(root .. "/share/lua/5.5/titan/retired.lua",
            installer.BANNER .. "return 'not the old generated shim'\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "refusing to overwrite unrecognized Lua file", 1, true), err)
        assert.equal("prior image\n",
            read_file(root .. "/lib/titan/0.6/titan.so"))
        assert.equal("prior archive with retired key\n",
            read_file(root .. "/lib/titan/0.6/titan.a"))
    end)

    local function inject_script()
        local script = workspace .. "/inject.lua"
        write_file(script, [[
local installer_script, stage, root = ...
local source_root = assert(installer_script:match(
    "^(.*)/scripts/stdlib_installer[.]lua$"))
package.path = source_root .. "/?.lua;" .. source_root .. "/?/init.lua;" ..
    package.path
local installer = assert(loadfile(installer_script))()
local entries = {}
for _, name in ipairs(installer.MODULE_NAMES) do
    entries[name] = { abi = "2", types = "types:" .. name }
end
local function prior_archive_scanner()
    local prior = {}
    for name, entry in pairs(entries) do prior[name] = entry end
    return { entries = prior }
end
local ok, err = installer.publish({
    stage = stage,
    root = root,
    platform = "Darwin",
    image_validator = function() return true end,
    prior_archive_scanner = prior_archive_scanner,
})
if ok then os.exit(2) end
if not tostring(err):find(os.getenv("TITAN_INSTALL_FAIL_AT"), 1, true) then
    io.stderr:write(tostring(err), "\n")
    os.exit(3)
end
os.exit(1)
]])
        return script
    end

    local function lua_executable()
        if os.getenv("PREFIX") and
           lfs.symlinkattributes(os.getenv("PREFIX") .. "/bin/lua", "mode") ==
               "file" then
            return os.getenv("PREFIX") .. "/bin/lua"
        end
        if type(arg) == "table" and type(arg[-1]) == "string" and
           lfs.symlinkattributes(arg[-1], "mode") == "file" then
            return arg[-1]
        end
        return "lua"
    end

    local function assert_native_failpoints_restore(seed, check)
        local script = inject_script()
        for _, position in ipairs({ "before", "after" }) do
            for _, label in ipairs({ "titan.a", "titan.so" }) do
                remove_tree(root)
                seed(root)
                local failpoint = position .. ":" .. label
                local command =
                    "TITAN_INSTALL_FAIL_AT=" .. shell_quote(failpoint) ..
                    " " .. shell_quote(lua_executable()) ..
                    " " .. shell_quote(script) ..
                    " " .. shell_quote(INSTALLER_SCRIPT) ..
                    " " .. shell_quote(stage) ..
                    " " .. shell_quote(root)
                local succeeded, why, code = os.execute(command)
                assert.falsy(succeeded, failpoint)
                assert.equal("exit", why, failpoint)
                assert.equal(1, code, failpoint)
                check(root)
                assert_predecessor_exact(root)
                assert_no_transaction_residue(root)
            end
        end
    end

    it("restores the exact bootstrap state at archive/DSO failpoints",
       function()
        assert_native_failpoints_restore(seed_bootstrap, assert_bootstrap)
    end)

    it("restores the exact complete pair at archive/DSO failpoints",
       function()
        assert_native_failpoints_restore(
            seed_complete_pair, assert_complete_pair)
    end)

    it("restores the exact seventeen-key pair at archive/DSO failpoints",
       function()
        assert_native_failpoints_restore(
            seed_seventeen_key_pair, assert_seventeen_key_pair)
    end)

    it("rejects missing and nonregular staged archives before publication",
       function()
        seed_complete_pair(root)
        remove_tree(stage .. "/titan.a")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find("no regular titan.a", 1, true), err)
        assert_complete_pair(root)

        make_directory(stage .. "/titan.a")
        ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find("no regular titan.a", 1, true), err)
        assert_complete_pair(root)
    end)

    it("rejects missing and nonregular staged test support source",
       function()
        seed_complete_pair(root)
        remove_tree(stage .. "/titan/test.titan")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "no regular titan.test support source", 1, true), err)
        assert_complete_pair(root)

        make_directory(stage .. "/titan/test.titan")
        ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "no regular titan.test support source", 1, true), err)
        assert_complete_pair(root)
    end)

    it("rejects a nonregular public archive destination", function()
        seed_bootstrap(root)
        make_directory(root .. "/lib/titan/0.6/titan.a")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "is not a regular nonlink file", 1, true), err)
        assert.equal("bootstrap image\n",
            read_file(root .. "/lib/titan/0.6/titan.so"))
        assert.equal("directory",
            lfs.symlinkattributes(root ..
                "/lib/titan/0.6/titan.a", "mode"))
    end)

    it("rejects a nonregular public test support source destination",
       function()
        seed_bootstrap(root)
        local destination = root .. "/" .. TEST_SOURCE_RELATIVE
        make_directory(destination)
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "is not a regular nonlink file", 1, true), err)
        assert.equal("bootstrap image\n",
            read_file(root .. "/lib/titan/0.6/titan.so"))
        assert.equal("directory",
            lfs.symlinkattributes(destination, "mode"))
    end)

    it("rejects a staged shim with a nonexact provider/entry template",
       function()
        seed_complete_pair(root)
        write_file(stage .. "/titan/uv.lua",
            installer.BANNER ..
            "return require('titan')._loadlibglobal('wrong', 'wrong')\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find(
            "does not match titanc's generated", 1, true), err)
        assert_complete_pair(root)
    end)

    local function validation_options(configuration)
        configuration = configuration or {}
        local embedded = configuration.embedded or fake_entries()
        local dso = configuration.dso or clone_entries(embedded)
        local archive_callables =
            configuration.archive_callables or clone_entries(embedded)
        local validation_output
        return {
            native_image_inspector = function(image)
                if configuration.inspect_error and
                   image:sub(-#"titan.so") == "titan.so" then
                    return nil, configuration.inspect_error
                end
                if validation_output and image == validation_output then
                    if configuration.archive_inspect_error then
                        return nil, configuration.archive_inspect_error
                    end
                    return archive_callables
                end
                return dso
            end,
            staged_archive_scanner = function()
                if configuration.scan_error then
                    return nil, configuration.scan_error
                end
                return { entries = embedded }
            end,
            archive_validation_builder =
                function(output, archive, link, verbose)
                    validation_output = output
                    if configuration.builder_error then
                        return nil, configuration.builder_error, 19
                    end
                    assert.equal(stage .. "/titan.a", archive)
                    assert.is_nil(link)
                    assert.is_false(verbose)
                    write_file(output, "private validation image\n")
                    write_file(output ..
                        ".dSYM/Contents/Resources/DWARF/validation",
                        "private symbols\n")
                    return true
                end,
            validation_output = function() return validation_output end,
        }
    end

    local function publish_with_native_configuration(configuration)
        local injected = validation_options(configuration)
        local ok, err = installer.publish({
            stage = stage,
            root = root,
            platform = "Linux",
            native_image_inspector = injected.native_image_inspector,
            staged_archive_scanner = injected.staged_archive_scanner,
            archive_validation_builder =
                injected.archive_validation_builder,
            prior_archive_scanner = fake_prior_archive_scanner,
        })
        return ok, err, injected
    end

    for _, rejection in ipairs({
        {
            "corrupt archive",
            { scan_error = "malformed archive bytes" },
            "cannot inspect staged titan.a",
        },
        {
            "missing logical archive key",
            (function()
                local entries = fake_entries()
                entries["titan.uv"] = nil
                return { embedded = entries }
            end)(),
            "is missing logical key",
        },
        {
            "extra logical archive key",
            {
                embedded = fake_entries({
                    ["titan.extra"] = {
                        abi = "2", types = "types:titan.extra",
                    },
                }),
            },
            "has unexpected logical key",
        },
        {
            "wrong embedded ABI",
            (function()
                local entries = fake_entries()
                entries["titan.uv"].abi = "1"
                return { embedded = entries, dso = fake_entries() }
            end)(),
            "ABI for module 'titan.uv' differs",
        },
        {
            "wrong embedded serialized types",
            { scan_error = "invalid serialized types for titan.uv" },
            "invalid serialized types",
        },
        {
            "embedded/DSO metadata mismatch",
            (function()
                local dso = fake_entries()
                dso["titan.fs"].types = "different DSO types"
                return { dso = dso }
            end)(),
            "type metadata for module 'titan.fs' differs",
        },
        {
            "embedded/archive-callable mismatch",
            (function()
                local callables = fake_entries()
                callables["titan.timer"].types =
                    "different archive callable types"
                return { archive_callables = callables }
            end)(),
            "type metadata for module 'titan.timer' differs",
        },
        {
            "missing logical native protocol",
            { inspect_error = "image is missing titan_uv_init" },
            "missing titan_uv_init",
        },
        {
            "invalid luaopen_titan support",
            {
                inspect_error =
                    "luaopen_titan does not return the required native support table",
            },
            "required native support table",
        },
        {
            "archive-backed link failure",
            { builder_error = "sentinel linker failure" },
            "sentinel linker failure",
        },
        {
            "archive-backed image inspection failure",
            { archive_inspect_error = "missing archive callable protocol" },
            "missing archive callable protocol",
        },
    }) do
        it("rejects " .. rejection[1] .. " before touching public files",
           function()
            seed_complete_pair(root)
            local ok, err, injected =
                publish_with_native_configuration(rejection[2])
            assert.falsy(ok)
            assert.truthy(tostring(err):find(rejection[3], 1, true), err)
            assert_complete_pair(root)
            local validation_output = injected.validation_output()
            if validation_output then
                assert.is_nil(lfs.symlinkattributes(validation_output))
                assert.is_nil(lfs.symlinkattributes(
                    validation_output .. ".dSYM"))
            end
            assert_no_transaction_residue(stage)
            assert_no_transaction_residue(root)
        end)
    end

    it("preserves the compiler environment for archive-backed validation",
       function()
        seed_bootstrap(root)
        local script = workspace .. "/environment.lua"
        write_file(script, [[
local installer_script, stage, root = ...
local source_root = assert(installer_script:match(
    "^(.*)/scripts/stdlib_installer[.]lua$"))
package.path = source_root .. "/?.lua;" .. source_root .. "/?/init.lua;" ..
    package.path
local installer = assert(loadfile(installer_script))()
local entries = {}
for _, name in ipairs(installer.MODULE_NAMES) do
    entries[name] = { abi = "2", types = "types:" .. name }
end
local validation_image
local ok, err = installer.publish({
    stage = stage,
    root = root,
    platform = "Linux",
    native_image_inspector = function(image)
        return entries
    end,
    staged_archive_scanner = function()
        return { entries = entries }
    end,
    archive_validation_builder = function(output, archive, link, verbose)
        assert(os.getenv("CC") == "sentinel-cc --driver")
        assert(os.getenv("AR") == "sentinel-ar --deterministic")
        assert(os.getenv("RANLIB") == "sentinel-ranlib --deterministic")
        assert(os.getenv("TITAN_EXTRA_CPPFLAGS") == "-DSENTINEL_CPP=1")
        assert(os.getenv("TITAN_EXTRA_CFLAGS") == "-DSENTINEL_C=1")
        assert(os.getenv("TITAN_EXTRA_LDFLAGS") == "-Wl,--sentinel-link")
        assert(os.getenv("TITAN_ROCKS_ROOT") == root)
        assert(os.getenv("TITAN_RUNTIME_PREBUILT") == "1")
        assert(archive == stage .. "/titan.a")
        assert(link == nil and verbose == false)
        validation_image = output
        local file = assert(io.open(output, "wb"))
        file:write("validation")
        file:close()
        return true
    end,
})
if not ok then error(err, 0) end
assert(validation_image and not require("lfs").symlinkattributes(validation_image))
]])
        local command = table.concat({
            "CC=" .. shell_quote("sentinel-cc --driver"),
            "AR=" .. shell_quote("sentinel-ar --deterministic"),
            "RANLIB=" .. shell_quote("sentinel-ranlib --deterministic"),
            "TITAN_EXTRA_CPPFLAGS=" .. shell_quote("-DSENTINEL_CPP=1"),
            "TITAN_EXTRA_CFLAGS=" .. shell_quote("-DSENTINEL_C=1"),
            "TITAN_EXTRA_LDFLAGS=" ..
                shell_quote("-Wl,--sentinel-link"),
            "TITAN_ROCKS_ROOT=" .. shell_quote(root),
            "TITAN_RUNTIME_PREBUILT=1",
            shell_quote(lua_executable()),
            shell_quote(script),
            shell_quote(INSTALLER_SCRIPT),
            shell_quote(stage),
            shell_quote(root),
        }, " ")
        local ok, why, code = os.execute(command)
        assert.truthy(ok, tostring(why) .. ":" .. tostring(code))
        assert_new_install(root, false)
    end)
end)
