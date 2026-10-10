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

    local function finish()
        local output, original = {}, io.write
        io.write = function(text) output[#output + 1] = text end
        local ok, result = pcall(coverage.finish, config)
        io.write = original
        return ok, result, table.concat(output)
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
        local ok, err, output = finish()
        assert.truthy(ok, err)
        assert.matches("Titan executable lines: 1/2 (50.0%)", output, 1, true)
        assert.equal(native, util.get_file_contents(root .. "/coverage.gcov"))
        assert.is_nil(lfs.attributes(root .. "/lines.json"))
        assert.is_nil(lfs.attributes(root .. "/gcovr.cfg"))
    end)

    it("adapts rich reports with escaped source names and only executable-line metrics", function()
        -- This source name is report data, not a physical Windows filename.
        local source = root .. '/quoted"\\source\t.titan'
        config.sources = { source }
        config.anchors[config.files[1]] = { [source] = { 2, 5 } }
        config.formats = { "html", "lcov", "cobertura" }
        config.gcovr = { LUA, root .. "/gcovr.lua" }
        local native = "-:0:Source:" .. source .. "\n7*:2:covered\n#####:5:uncalled\n9:8:generated\n"
        write("gcov.lua", "io.write(" .. string.format("%q", native) .. ")\n")
        local lcov = table.concat({
            "TN:", "SF:production.titan", "FN:2,generated", "FNDA:7,generated", "FNF:1", "FNH:1",
            "BRDA:2,0,0,7", "BRF:1", "BRH:1", "DA:2,7,None", "DA:5,0,None",
            "LF:2", "LH:1", "end_of_record", "",
        }, "\r\n")
        write("gcovr.lua", string.format([[
local function write(name, contents)
    local file = assert(io.open(%q .. '/' .. name, 'wb'))
    assert(file:write(contents)); assert(file:close())
end
write('reporter-arguments', table.concat(arg, '\0'))
write('coverage.info', %q)
io.write('rich reporter completed\n')
]], root, lcov))

        local ok, err, output = finish()
        assert.truthy(ok, err)
        assert.is_true(err)
        assert.matches("Titan executable lines: 1/2 (50.0%)", output, 1, true)
        assert.matches("rich reporter completed", output, 1, true)
        local escaped_source = root .. '/quoted\\"\\\\source\\u0009.titan'
        assert.equal('{"gcovr/format_version":"0.14","files":[{"file":"' .. escaped_source ..
            '","functions":[],"lines":[{"line_number":2,"count":7,"branches":[]},' ..
            '{"line_number":5,"count":0,"branches":[]}]}]}\n',
            util.get_file_contents(root .. "/lines.json"))
        local arguments = {}
        for argument in util.get_file_contents(root .. "/reporter-arguments"):gmatch("[^%z]+") do
            arguments[#arguments + 1] = argument
        end
        assert.same({
            "--config", root .. "/gcovr.cfg", "--root", root,
            "--add-tracefile", root .. "/lines.json", "--no-markers", "--no-exclude-noncode-lines",
            "--html-details", root .. "/coverage.html", "--html-single-page", "static",
            "--html-template-dir", root, "--html-title", "Titan executable-line coverage",
            "--lcov", root .. "/coverage.info", "--cobertura", root .. "/coverage.xml",
        }, arguments)
        assert.equal("", util.get_file_contents(root .. "/gcovr.cfg"))
        local template = assert(util.get_file_contents(root .. "/single_page.html"))
        assert.matches("Executable lines", template, 1, true)
        assert.matches("{{row.linecount}}", template, 1, true)
        assert.equal("TN:\nSF:production.titan\nDA:2,7\nDA:5,0\nLF:2\nLH:1\nend_of_record\n",
            util.get_file_contents(root .. "/coverage.info"))
        assert.equal(native, util.get_file_contents(root .. "/coverage.gcov"))
    end)

    it("preserves rich-reporter failure diagnostics after collecting the basic report", function()
        write("gcov.lua", "io.write('-:0:Source:./production.titan\\n1:1:covered\\n')\n")
        write("gcovr.lua", "io.stderr:write('report output is unavailable\\n'); os.exit(19)\n")
        config.formats = { "cobertura" }
        config.gcovr = { LUA, root .. "/gcovr.lua" }
        local ok, err = finish()
        assert.is_false(ok)
        assert.matches("exit 19", err, 1, true)
        assert.matches("report output is unavailable", err, 1, true)
        assert.matches("1:1:covered", assert(util.get_file_contents(root .. "/coverage.gcov")), 1, true)
        assert.is_nil(lfs.attributes(root .. "/coverage.xml"))
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
