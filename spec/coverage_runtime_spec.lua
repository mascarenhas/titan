local assert = require "luassert"
local coverage = require "titan-compiler.coverage_runtime"
local driver = require "titan-compiler.driver"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
local util = require "titan-compiler.util"

local LUA = installed_prefix.active() .. (platform.windows and "/bin/lua.exe" or "/bin/lua")

describe("embedded native coverage collection", function()
    local root, config
    before_each(function()
        root = temporary.name(" coverage's files")
        os.remove(root)
        assert(lfs.mkdir(root))
        local generated, source = root .. "/production.c", root .. "/production.titan"
        config = { files = { generated }, sources = { source }, root = root,
            output = root, working_directory = root, formats = {},
            gcov = { LUA, root .. "/gcov.lua" },
            anchors = { [generated] = { [source] = { 1, 2 } } } }
    end)
    after_each(function() driver.remove_path(root) end)

    local function write(name, contents)
        assert(util.set_file_contents(root .. "/" .. name, contents))
    end

    it("resets only the embedded inventory's counters, retaining notes and unrelated files", function()
        write("production.gcda", "old counters")
        write("production.gcno", "notes")
        write("other.gcda", "another build")
        assert.is_true(coverage.prepare(config))
        assert.is_nil(lfs.attributes(root .. "/production.gcda"))
        assert.equal("notes", util.get_file_contents(root .. "/production.gcno"))
        assert.equal("another build", util.get_file_contents(root .. "/other.gcda"))
        assert.is_true(coverage.prepare(config))
    end)

    it("keeps zero-hit executable lines and filters generated or unowned locations without gcovr", function()
        local native = table.concat({
            "        -:    0:Source:./production.titan",
            "    #####:    1:never called",
            "       7*:    2:covered line",
            "       10:    3:generated setup attributed nearby",
            "        -:    4:comment",
            "        -:    0:Source:" .. root .. "/production.c",
            "       20:   12:generated C",
            "        -:    0:Source:" .. root .. "/unselected.titan",
            "       30:    1:other source",
            "",
        }, "\n")
        write("gcov.lua", "assert(#arg == 3 and arg[1] == '-t' and arg[2] == '-p')\n" ..
            "assert(arg[3] == " .. string.format("%q", root .. "/production.gcno") .. ")\n" ..
            "io.write(" .. string.format("%q", native) .. ")\n")
        local output, original = {}, io.write
        io.write = function(text) output[#output + 1] = text end
        local ok, err = pcall(coverage.finish, config)
        io.write = original
        assert.truthy(ok, err)
        assert.matches("Titan executable lines: 1/2 (50.0%)", table.concat(output), 1, true)
        assert.equal(native, util.get_file_contents(root .. "/coverage.gcov"))
        assert.is_nil(lfs.attributes(root .. "/lines.json"))
        assert.is_nil(lfs.attributes(root .. "/gcovr.cfg"))
    end)

    it("keeps backend failure status and diagnostics", function()
        write("gcov.lua", "io.stderr:write('notes do not match compiler\\n'); os.exit(23)\n")
        local ok, err = pcall(coverage.finish, config)
        assert.is_false(ok)
        assert.matches("exit 23", err, 1, true)
        assert.matches("notes do not match compiler", err, 1, true)
        assert.is_nil(lfs.attributes(root .. "/coverage.gcov"))
    end)
end)
