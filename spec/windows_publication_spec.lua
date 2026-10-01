local assert = require "luassert"
local lfs = require "lfs"
local publication = require "titan-compiler.windows_publication"
local util = require "titan-compiler.util"

describe("Windows file publication transaction", function()
    local root, fs, source, shim, image
    local function write(path, bytes) assert(util.set_file_contents(path, bytes)) end
    local function read(path) return assert(util.get_file_contents(path)) end
    local function entries()
        return { { destination = shim, contents = "new shim" },
            { destination = image, source = source } }
    end
    local function unchanged()
        assert.equal("old shim", read(shim))
        assert.equal("old DLL", read(image))
        local files = {}
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then files[#files + 1] = name end
        end
        table.sort(files)
        assert.same({ "module.lua", "provider.dll", "source.dll" }, files)
    end
    before_each(function()
        root = os.tmpname(); assert(os.remove(root)); assert(lfs.mkdir(root))
        source, shim, image = root .. "/source.dll", root .. "/module.lua", root .. "/provider.dll"
        write(source, "new DLL"); write(shim, "old shim"); write(image, "old DLL")
        local sequence = 0
        fs = {
            stat = function(path)
                local attr, err, code = lfs.symlinkattributes(path)
                if not attr then return nil, err, code end
                return { kind = attr.mode, device = attr.dev, inode = attr.ino }
            end,
            reserve = function(path)
                sequence = sequence + 1
                local reserved = path .. ".reserved." .. sequence
                write(reserved, "")
                return reserved
            end,
            replace = os.rename,
            remove = os.remove,
        }
    end)
    after_each(function()
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then assert(os.remove(root .. "/" .. name)) end
        end
        assert(lfs.rmdir(root))
    end)

    it("commits companion files before the provider", function()
        assert(publication.publish(entries(), fs, { after_commit = function(index)
            assert.equal("new shim", read(shim))
            assert.equal(index == 1 and "old DLL" or "new DLL", read(image))
            return true
        end }))
        assert.equal("new DLL", read(image))
    end)

    it("restores exact previous bytes after a caught commit failure", function()
        local ok, err = publication.publish(entries(), fs, { after_commit = function(index)
            if index == 2 then return nil, "injected final failure" end
            return true
        end })
        assert.is_nil(ok); assert.matches("injected final failure", err, 1, true)
        unchanged()
    end)

    it("rolls back companions when the existing DLL cannot be replaced", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            return os.rename(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok); assert.matches("DLL is in use", err, 1, true)
        unchanged()
    end)

    it("reports cleanup failure for an unused backup copy", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            return os.rename(from, to)
        end
        fs.remove = function(path)
            if path == image .. ".reserved.4" then
                return nil, "cannot remove unused backup copy"
            end
            return os.remove(path)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok)
        assert.matches("DLL is in use", err, 1, true)
        assert.matches("cannot remove unused backup copy", err, 1, true)
        assert.equal("old shim", read(shim))
        assert.equal("old DLL", read(image))
        assert.equal("old DLL", read(image .. ".reserved.4"))
    end)

    it("preserves destinations when a source disappears during preparation", function()
        local plans = entries(); plans[2].source = root .. "/missing.dll"
        assert.is_nil(publication.publish(plans, fs))
        unchanged()
    end)

    it("rejects source aliases and unrecognized companion ownership", function()
        local plans = entries(); plans[2].source = image
        local ok, err = publication.publish(plans, fs)
        assert.is_nil(ok); assert.matches("aliases destination", err, 1, true)
        unchanged()
        ok, err = publication.publish(entries(), fs, { validate_existing = function()
            return nil, "unrecognized generated shim"
        end })
        assert.is_nil(ok); assert.matches("unrecognized generated shim", err, 1, true)
        unchanged()
    end)

    it("reports incomplete rollback instead of claiming restoration", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            if to == shim and from:match("reserved.3$") then
                return nil, "cannot restore previous shim"
            end
            return os.rename(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok)
        assert.matches("publication cleanup", err, 1, true)
        assert.matches("cannot restore previous shim", err, 1, true)
        assert.equal("old DLL", read(image))
    end)
end)
