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

local function seed_prior(root, with_shims)
    write_file(root .. "/lib/titan/0.16/titan.so", "prior image\n")
    if with_shims then
        for _, module in ipairs(installer.MODULES) do
            write_file(root .. "/share/lua/5.5/titan/" .. module .. ".lua",
                "prior " .. module .. "\n")
        end
    end
    write_file(root .. "/lib/titan/0.16/titan/uv.so", "stale child\n")
    write_file(root .. "/lib/lua/5.5/titan.so", "old manifest support\n")
    write_file(root .. "/lib/titan/0.15/titan/uv.so", "older ABI\n")
end

local function assert_prior(root, with_shims)
    assert.equal("prior image\n",
        read_file(root .. "/lib/titan/0.16/titan.so"))
    for _, module in ipairs(installer.MODULES) do
        local path = root .. "/share/lua/5.5/titan/" .. module .. ".lua"
        if with_shims then
            assert.equal("prior " .. module .. "\n", read_file(path))
        else
            assert.is_nil(lfs.symlinkattributes(path))
        end
    end
    assert.equal("stale child\n",
        read_file(root .. "/lib/titan/0.16/titan/uv.so"))
    assert.equal("old manifest support\n",
        read_file(root .. "/lib/lua/5.5/titan.so"))
    assert.equal("older ABI\n",
        read_file(root .. "/lib/titan/0.15/titan/uv.so"))
end

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
        seed_prior(root, true)
        write_file(root .. "/lib/titan/0.16/titan.so.dSYM/stale", "stale\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.truthy(ok, err)
        assert.equal("new combined image\n",
            read_file(root .. "/lib/titan/0.16/titan.so"))
        for _, module in ipairs(installer.MODULES) do
            local shim = read_file(
                root .. "/share/lua/5.5/titan/" .. module .. ".lua")
            assert.equal(installer.BANNER,
                shim:sub(1, #installer.BANNER))
        end
        assert.is_nil(lfs.symlinkattributes(
            root .. "/lib/titan/0.16/titan/uv.so"))
        assert.is_nil(lfs.symlinkattributes(root .. "/lib/lua/5.5/titan.so"))
        assert.is_nil(lfs.symlinkattributes(
            root .. "/lib/titan/0.16/titan.so.dSYM"))
        assert.equal("older ABI\n",
            read_file(root .. "/lib/titan/0.15/titan/uv.so"))
    end)

    it("restores a complete prior install after every injected commit failure",
       function()
        local script = workspace .. "/inject.lua"
        write_file(script, [[
package.path = ... .. "/?.lua;" .. ... .. "/?/init.lua;" .. package.path
local installer = require "titan-compiler.stdlib_installer"
local ok, err = installer.publish({
    stage = select(2, ...), root = select(3, ...), platform = "Linux",
    image_validator = function() return true end,
})
if ok then os.exit(2) end
if not tostring(err):find(os.getenv("TITAN_INSTALL_FAIL_AT"), 1, true) then
    io.stderr:write(tostring(err), "\n")
    os.exit(3)
end
os.exit(1)
]])
        local lua = os.getenv("PREFIX") and
            (os.getenv("PREFIX") .. "/bin/lua") or "lua"
        local repo = lfs.currentdir()
        for _, label in ipairs({
            "shim-coroutine", "shim-uv", "shim-async", "shim-timer",
            "shim-fs", "shim-net", "shim-os", "dsym", "dso",
        }) do
            remove_tree(root)
            seed_prior(root, true)
            local command = string.format(
                "TITAN_INSTALL_FAIL_AT=%q %q %q %q %q %q",
                "after:" .. label, lua, script, repo, stage, root)
            local succeeded, why, code = os.execute(command)
            assert.falsy(succeeded, label)
            assert.equal("exit", why, label)
            assert.equal(1, code, label)
            assert_prior(root, true)
        end
    end)

    it("restores the first-install bootstrap without partial new shims",
       function()
        seed_prior(root, false)
        local script = workspace .. "/inject.lua"
        write_file(script, [[
package.path = ... .. "/?.lua;" .. ... .. "/?/init.lua;" .. package.path
local installer = require "titan-compiler.stdlib_installer"
local ok, err = installer.publish({
    stage = select(2, ...), root = select(3, ...), platform = "Linux",
    image_validator = function() return true end,
})
if ok then os.exit(2) end
if not tostring(err):find(os.getenv("TITAN_INSTALL_FAIL_AT"), 1, true) then
    io.stderr:write(tostring(err), "\n")
    os.exit(3)
end
os.exit(1)
]])
        local lua = os.getenv("PREFIX") and
            (os.getenv("PREFIX") .. "/bin/lua") or "lua"
        local repo = lfs.currentdir()
        local command = string.format(
            "TITAN_INSTALL_FAIL_AT=%q %q %q %q %q %q",
            "after:shim-timer", lua, script, repo, stage, root)
        local succeeded, why, code = os.execute(command)
        assert.falsy(succeeded)
        assert.equal("exit", why)
        assert.equal(1, code)
        assert_prior(root, false)
    end)

    it("rejects an incomplete staged shim set without touching public files",
       function()
        seed_prior(root, true)
        write_file(stage .. "/titan/uv.lua", "return 'not generated'\n")
        local ok, err = publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(err:find("is not owned by titanc", 1, true), err)
        assert_prior(root, true)
    end)

    it("rejects an invalid staged image before touching public files",
       function()
        seed_prior(root, true)
        local ok, err = installer.publish({
            stage = stage, root = root, platform = "Linux",
        })
        assert.falsy(ok)
        assert.truthy(tostring(err):find("staged titan.so", 1, true), err)
        assert_prior(root, true)
    end)
end)
