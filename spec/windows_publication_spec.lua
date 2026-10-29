local temporary = require "spec.support.temporary"
local assert = require "luassert"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local publication = require "titan-compiler.windows_publication"
local util = require "titan-compiler.util"

local compiler_io = require "titan-compiler.io"
local function replace(from, to)
    return compiler_io.new_sync():rename(from, to)
end

describe("Windows file publication transaction", function()
    local root, fs, source, companion_source, companion, image
    local function write(path, bytes) assert(util.set_file_contents(path, bytes)) end
    local function read(path) return assert(util.get_file_contents(path)) end
    local function entries()
        return { { destination = companion, source = companion_source },
            { destination = image, source = source } }
    end
    local function filenames()
        local files = {}
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then files[#files + 1] = name end
        end
        table.sort(files)
        return files
    end
    local function unchanged()
        assert.equal("old companion", read(companion))
        assert.equal("old DLL", read(image))
        assert.same({ "companion-source.dll", "companion.dll", "provider.dll", "source.dll" }, filenames())
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        source, image = root .. "/source.dll", root .. "/provider.dll"
        companion_source, companion = root .. "/companion-source.dll", root .. "/companion.dll"
        write(source, "new DLL"); write(image, "old DLL")
        write(companion_source, "new companion"); write(companion, "old companion")
        local sequence = 0
        fs = {
            stat = function(path)
                local attr, err = compiler_io.new_sync():lstat(path)
                return attr, err, not attr and not err and 2 or nil
            end,
            reserve = function(path)
                sequence = sequence + 1
                local reserved = path .. ".reserved." .. sequence
                write(reserved, "")
                return reserved
            end,
            replace = replace,
            remove = os.remove,
        }
    end)
    after_each(function()
        for name in lfs.dir(root) do
            if name ~= "." and name ~= ".." then assert(os.remove(root .. "/" .. name)) end
        end
        assert(lfs.rmdir(root))
    end)

    it("commits the companion before the final image", function()
        assert(publication.publish(entries(), fs, { after_commit = function(index)
            assert.equal("new companion", read(companion))
            assert.equal(index == 1 and "old DLL" or "new DLL", read(image))
            return true
        end }))
        assert.equal("new DLL", read(image))
    end)

    it("preserves unchanged files and mtimes without replacing a mapped DLL", function()
        write(source, "old DLL"); write(companion_source, "old companion")
        local old = os.time() - 60
        assert(lfs.touch(companion, old, old))
        assert(lfs.touch(image, old, old))
        fs.replace = function() return nil, "DLL is in use" end
        assert(publication.publish({
            { destination = companion, source = companion_source },
            { destination = image, source = source },
        }, fs, { after_commit = function()
            error("unchanged files must not be committed")
        end }))
        assert.equal(old, lfs.attributes(companion, "modification"))
        assert.equal(old, lfs.attributes(image, "modification"))
        unchanged()
    end)

    it("publishes a changed companion while preserving an identical mapped DLL", function()
        write(source, "old DLL")
        local old = os.time() - 60
        assert(lfs.touch(image, old, old))
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            return replace(from, to)
        end
        local commits = {}
        assert(publication.publish(entries(), fs, { after_commit = function(index)
            commits[#commits + 1] = index
            return true
        end }))
        assert.same({ 1 }, commits)
        assert.equal("new companion", read(companion))
        assert.equal("old DLL", read(image))
        assert.equal(old, lfs.attributes(image, "modification"))
        assert.same({ "companion-source.dll", "companion.dll", "provider.dll", "source.dll" }, filenames())
    end)

    it("retains an unchanged companion when a changed DLL cannot be replaced", function()
        write(companion_source, "old companion")
        local old = os.time() - 60
        assert(lfs.touch(companion, old, old))
        fs.replace = function(from, to)
            assert.equal(image, to)
            return nil, "DLL is in use"
        end
        local ok, err = publication.publish({
            { destination = companion, source = companion_source },
            { destination = image, source = source },
        }, fs)
        assert.is_nil(ok)
        assert.matches("DLL is in use", err, 1, true)
        assert.equal(old, lfs.attributes(companion, "modification"))
        unchanged()
    end)

    it("restores exact previous bytes after a caught commit failure", function()
        local ok, err = publication.publish(entries(), fs, { after_commit = function(index)
            if index == 2 then return nil, "injected final failure" end
            return true
        end })
        assert.is_nil(ok); assert.matches("injected final failure", err, 1, true)
        unchanged()
    end)

    it("restores the predecessor when deletion succeeds but replacement fails", function()
        local attempted = false
        fs.replace = function(from, to)
            if to == image and not attempted then
                attempted = true
                assert(fs.remove(to))
                return nil, "injected rename failure after deletion"
            end
            return replace(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok)
        assert.matches("injected rename failure after deletion", err, 1, true)
        unchanged()
    end)

    for _, operation in ipairs({ "read", "write" }) do
        it("closes copy streams and removes partial stages after a " .. operation .. " failure", function()
            local original_open, original_reserve = io.open, fs.reserve
            local copy_target, input, output
            local reads, writes, input_closes, output_closes = 0, 0, 0, 0
            local failure = "injected copy " .. operation .. " failure"
            fs.reserve = function(path)
                local reserved = original_reserve(path)
                if path == image then copy_target = reserved end
                return reserved
            end
            io.open = function(path, mode)
                local file, err = original_open(path, mode)
                if not file then return nil, err end
                if path == source and mode == "rb" then
                    input = file
                    return {
                        read = function()
                            reads = reads + 1
                            if operation == "read" and reads == 2 then return nil, failure end
                            return file:read(3)
                        end,
                        close = function()
                            input_closes = input_closes + 1
                            return file:close()
                        end,
                    }
                elseif path == copy_target and mode == "wb" then
                    output = file
                    return {
                        write = function(_, bytes)
                            writes = writes + 1
                            if operation == "write" and writes == 2 then return nil, failure end
                            return file:write(bytes)
                        end,
                        close = function()
                            output_closes = output_closes + 1
                            return file:close()
                        end,
                    }
                end
                return file
            end
            local called, ok, err = pcall(publication.publish, entries(), fs)
            io.open = original_open
            assert.is_true(called, ok)
            assert.is_nil(ok)
            assert.matches(failure, err, 1, true)
            assert.equal(2, reads)
            assert.equal(operation == "read" and 1 or 2, writes)
            assert.equal(1, input_closes)
            assert.equal(1, output_closes)
            assert.equal("closed file", io.type(input))
            assert.equal("closed file", io.type(output))
            unchanged()
        end)
    end

    it("removes a newly created companion when the later provider commit fails", function()
        assert(os.remove(companion))
        fs.replace = function(from, to)
            if to == image then
                assert.equal("new companion", read(companion))
                return nil, "DLL is in use"
            end
            return replace(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok)
        assert.matches("DLL is in use", err, 1, true)
        assert.is_nil(lfs.symlinkattributes(companion))
        assert.equal("old DLL", read(image))
        assert.same({ "companion-source.dll", "provider.dll", "source.dll" }, filenames())
    end)

    it("rolls back companions when the existing DLL cannot be replaced", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            return replace(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok); assert.matches("DLL is in use", err, 1, true)
        unchanged()
    end)

    it("reports cleanup failure for an unused backup copy", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            return replace(from, to)
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
        assert.equal("old companion", read(companion))
        assert.equal("old DLL", read(image))
        assert.equal("old DLL", read(image .. ".reserved.4"))
    end)

    it("preserves destinations when a source disappears during preparation", function()
        local plans = entries(); plans[2].source = root .. "/missing.dll"
        assert.is_nil(publication.publish(plans, fs))
        unchanged()
    end)

    it("rejects source aliases and entries without a staged source", function()
        local plans = entries(); plans[2].source = image
        local ok, err = publication.publish(plans, fs)
        assert.is_nil(ok); assert.matches("aliases destination", err, 1, true)
        unchanged()
        plans = entries(); plans[1].source = nil
        ok, err = publication.publish(plans, fs)
        assert.is_nil(ok); assert.matches("missing publication source", err, 1, true)
        unchanged()
    end)

    it("reports incomplete rollback instead of claiming restoration", function()
        fs.replace = function(from, to)
            if to == image then return nil, "DLL is in use" end
            if to == companion and from:match("reserved.3$") then
                return nil, "cannot restore previous companion"
            end
            return replace(from, to)
        end
        local ok, err = publication.publish(entries(), fs)
        assert.is_nil(ok)
        assert.matches("publication cleanup", err, 1, true)
        assert.matches("cannot restore previous companion", err, 1, true)
        assert.equal("old DLL", read(image))
    end)
end)
