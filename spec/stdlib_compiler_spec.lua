local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local assert = require "luassert"
local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"
local platform = require "titan-compiler.platform"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("installed standard-provider compiler integration", function()
    it("preserves selected native support for fresh-process library validation", function()
        if platform.windows then
            pending("the isolated Lua launcher fixture uses a POSIX shell")
            return
        end
        local installed = assert(driver.INSTALL_PATHS)
        local lua = installed.root .. "/bin/lua"
        local image = installed.root .. "/lib/titan/0.6/titan.so"
        local names = { "titan.math" }
        local entries = assert(driver.library_interface_entries(image, names))
        local workspace = temporary.name()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local previous_cpath, previous_support = package.cpath, package.loaded.titan
        local completed, failure = xpcall(function()
            assert(lfs.mkdir(workspace .. "/bin"))
            -- The child has no native search path of its own. It must receive
            -- the parent's explicitly selected support path, without sharing
            -- the poisoned support table already loaded in this process.
            write_file(workspace .. "/bin/lua", "#!/bin/sh\nexec " ..
                cdriver.shell_quote(lua) ..
                " -E -e 'package.cpath=\"\"' \"$@\"\n")
            assert(os.execute("chmod +x " .. cdriver.shell_quote(workspace .. "/bin/lua")))
            driver.INSTALL_PATHS = { root = workspace }
            package.cpath = installed.root .. "/lib/lua/5.5/?.so"
            package.loaded.titan = { _loadlib = function()
                error("fresh validation reused parent support")
            end }
            local valid, validation_error =
                driver.validate_library_image_fresh(image, entries, names)
            assert.truthy(valid, validation_error)
        end, debug.traceback)
        driver.INSTALL_PATHS = installed
        package.cpath, package.loaded.titan = previous_cpath, previous_support
        remove_tree(workspace)
        assert.truthy(completed, failure)
    end)
end)
