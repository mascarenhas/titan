local assert = require "luassert"
local lfs = require "lfs"
local installer = require "titan-compiler.stdlib_installer"

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
    write_file(path ..
        "/titan.so.dSYM/Contents/Resources/DWARF/titan.so",
        "new symbols\n")
    for _, module in ipairs(installer.MODULES) do
        write_file(path .. "/titan/" .. module .. ".lua",
            installer.BANNER .. string.format([[
local path = assert(package.searchpath("titan", package.cpath))
local open = assert(require("titan")._loadlibglobal(
    path, "luaopen_titan_%s"))
return open()
]], module))
    end
end

local function publish(options)
    options.image_validator = function() return true end
    return installer.publish(options)
end

local function assert_unique_regular_file(path)
    local direct = assert(lfs.symlinkattributes(path), path)
    assert.equal("file", direct.mode, path)
    local followed = assert(lfs.attributes(path), path)
    assert.equal(1, followed.nlink, path)
end

local function assert_no_active_compatibility_copies(root)
    local abi_dir = root .. "/lib/titan/0.16"
    local lua_cdir = root .. "/lib/lua/5.5"
    for _, module in ipairs(installer.MODULES) do
        for _, path in ipairs({
            abi_dir .. "/titan/" .. module .. ".so",
            abi_dir .. "/" .. module .. ".so",
            lua_cdir .. "/titan/" .. module .. ".so",
            lua_cdir .. "/titan/stdlib_0_16/" .. module .. ".so",
        }) do
            assert.is_nil(lfs.symlinkattributes(path), path)
            assert.is_nil(lfs.symlinkattributes(path .. ".dSYM"),
                path .. ".dSYM")
        end
    end
    for _, path in ipairs({
        lua_cdir .. "/titan.so",
        lua_cdir .. "/titan.so.dSYM",
        lua_cdir .. "/coro.so",
        lua_cdir .. "/coro.so.dSYM",
    }) do
        assert.is_nil(lfs.symlinkattributes(path), path)
    end
end

local function seed_prior_full(root)
    write_file(root .. "/lib/titan/0.16/titan.so", "prior image\n")
    write_file(root ..
        "/lib/titan/0.16/titan.so.dSYM/Contents/Resources/DWARF/titan.so",
        "prior symbols\n")
    for _, module in ipairs(installer.MODULES) do
        write_file(root .. "/share/lua/5.5/titan/" .. module .. ".lua",
            "prior " .. module .. "\n")
    end
    write_file(root .. "/lib/titan/0.16/titan/uv.so", "stale child\n")
    write_file(root .. "/lib/lua/5.5/titan.so", "old manifest support\n")
    write_file(root .. "/lib/titan/0.15/titan/uv.so", "older ABI\n")
end

local function assert_prior_full(root)
    assert.equal("prior image\n",
        read_file(root .. "/lib/titan/0.16/titan.so"))
    for _, module in ipairs(installer.MODULES) do
        local path = root .. "/share/lua/5.5/titan/" .. module .. ".lua"
        assert.equal("prior " .. module .. "\n", read_file(path))
    end
    assert.equal("prior symbols\n", read_file(root ..
        "/lib/titan/0.16/titan.so.dSYM/Contents/Resources/DWARF/titan.so"))
    assert.equal("stale child\n",
        read_file(root .. "/lib/titan/0.16/titan/uv.so"))
    assert.equal("old manifest support\n",
        read_file(root .. "/lib/lua/5.5/titan.so"))
    assert.equal("older ABI\n",
        read_file(root .. "/lib/titan/0.15/titan/uv.so"))
end

local function seed_first_install(root)
    write_file(root .. "/lib/titan/0.16/titan.so", "bootstrap image\n")
    write_file(root .. "/lib/titan/0.15/titan/uv.so", "older ABI\n")
end

local function assert_first_install(root)
    assert.equal("bootstrap image\n",
        read_file(root .. "/lib/titan/0.16/titan.so"))
    assert_unique_regular_file(root .. "/lib/titan/0.16/titan.so")
    for _, module in ipairs(installer.MODULES) do
        assert.is_nil(lfs.symlinkattributes(
            root .. "/share/lua/5.5/titan/" .. module .. ".lua"))
    end
    assert.is_nil(lfs.symlinkattributes(
        root .. "/lib/titan/0.16/titan.so.dSYM"))
    assert_no_active_compatibility_copies(root)
    assert.equal("older ABI\n",
        read_file(root .. "/lib/titan/0.15/titan/uv.so"))
end

local COMMIT_LABELS = {
    "shim-coroutine", "shim-uv", "shim-async", "shim-timer",
    "shim-fs", "shim-net", "shim-os", "dsym", "dso",
}

describe("recoverable standard-library publication", function()
    local workspace
    local stage
    local root
    local old_failpoint

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
        -- Tests set the variable only in child processes below; retain this
        -- guard for callers that arrived with an ambient injection request.
        assert.equal(old_failpoint, os.getenv("TITAN_INSTALL_FAIL_AT"))
        if workspace then remove_tree(workspace) end
    end)

    it("commits seven shims before the DSO and removes only active-ABI debris",
       function()
        seed_prior_full(root)
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.truthy(ok, err)
        assert.equal("new combined image\n",
            read_file(root .. "/lib/titan/0.16/titan.so"))
        assert_unique_regular_file(root .. "/lib/titan/0.16/titan.so")
        for _, module in ipairs(installer.MODULES) do
            local path =
                root .. "/share/lua/5.5/titan/" .. module .. ".lua"
            local shim = read_file(path)
            assert.equal(installer.BANNER,
                shim:sub(1, #installer.BANNER))
            assert_unique_regular_file(path)
        end
        assert.is_nil(lfs.symlinkattributes(
            root .. "/lib/titan/0.16/titan.so.dSYM"))
        assert_no_active_compatibility_copies(root)
        assert.equal("older ABI\n",
            read_file(root .. "/lib/titan/0.15/titan/uv.so"))
    end)

    local function inject_script()
        local script = workspace .. "/inject.lua"
        write_file(script, [[
package.path = ... .. "/?.lua;" .. ... .. "/?/init.lua;" .. package.path
local installer = require "titan-compiler.stdlib_installer"
local ok, err = installer.publish({
    stage = select(2, ...), root = select(3, ...), platform = "Darwin",
    image_validator = function() return true end,
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

    local function assert_every_commit_rolls_back(seed, check)
        local script = inject_script()
        local lua = os.getenv("PREFIX") and
            (os.getenv("PREFIX") .. "/bin/lua") or "lua"
        local repo = lfs.currentdir()
        for _, position in ipairs({ "before", "after" }) do
            for _, label in ipairs(COMMIT_LABELS) do
                remove_tree(root)
                seed(root)
                local failpoint = position .. ":" .. label
                local command = string.format(
                    "TITAN_INSTALL_FAIL_AT=%q %q %q %q %q %q",
                    failpoint, lua, script, repo, stage, root)
                local succeeded, why, code = os.execute(command)
                assert.falsy(succeeded, failpoint)
                assert.equal("exit", why, failpoint)
                assert.equal(1, code, failpoint)
                check(root)
            end
        end
    end

    it("restores a complete prior install around every public commit",
       function()
        assert_every_commit_rolls_back(seed_prior_full, assert_prior_full)
    end)

    it("restores the first-install bootstrap around every public commit",
       function()
        assert_every_commit_rolls_back(seed_first_install,
            assert_first_install)
    end)

    it("rejects an incomplete staged shim set without touching public files",
       function()
        seed_prior_full(root)
        write_file(stage .. "/titan/uv.lua", "return 'not generated'\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(err:find("is not owned by titanc", 1, true), err)
        assert_prior_full(root)
    end)

    it("rejects an invalid staged image before touching public files",
       function()
        seed_prior_full(root)
        local ok, err = installer.publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find("staged titan.so", 1, true), err)
        assert_prior_full(root)
    end)
end)
