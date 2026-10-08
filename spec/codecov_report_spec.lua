local temporary = require "spec.support.temporary"
local assert = require "luassert"

describe("Codecov LuaCov upload report", function()
    local input, output
    local function write(path, contents)
        local file <close> = assert(io.open(path, "wb"))
        assert(file:write(contents))
    end
    local function read(path)
        local file <close> = assert(io.open(path, "rb"))
        return assert(file:read("a"))
    end
    local function prepare()
        local environment = setmetatable({ arg = { input, output } },
            { __index = _G })
        assert(loadfile("spec/support/prepare_codecov_report.lua", "t",
            environment))()
    end

    before_each(function()
        input, output = temporary.name(), temporary.name()
    end)
    after_each(function()
        os.remove(input)
        os.remove(output)
    end)

    -- Model the upstream reader's filename boundary, including the path fix.
    -- Without the alias it attributes the CLI's rows to publication.lua.
    local function coverage_files(report)
        local files, current = {}, nil
        local heading = false
        for line in report:gmatch("([^\n]*)\n") do
            if line:match("^=+$") then
                heading = not heading
            elseif heading then
                if line == "Summary" then
                    current = nil
                elseif line:match("%.lua$") or line:match("%.lisp$") then
                    local name = line == "titanc.lua" and "titanc" or line
                    current = { covered = 0, missed = 0 }
                    files[name] = current
                end
            elseif current then
                if line:match("^%*+0 ") then
                    current.missed = current.missed + 1
                elseif line:match("^%s*%d+ ") then
                    current.covered = current.covered + 1
                end
            end
        end
        return files
    end

    it("keeps CLI counts separate without altering source rows or the original report", function()
        local divider = string.rep("=", 78) .. "\n"
        local publication = divider .. "titan-compiler/publication.lua\n" ..
            divider .. "  9 return publication\n"
        local cli = divider .. "titanc\n" .. divider ..
            "  1 local name = 'ação世界'\n*****0 error(name)\n    titanc\n"
        local summary = divider .. "Summary\n" .. divider ..
            "titanc 1 1 50.00%\n"
        local original = publication .. cli .. summary
        write(input, original)
        prepare()
        local prepared = read(output)
        assert.equal(original, read(input))
        assert.equal(publication .. divider .. "titanc.lua\n" .. divider ..
            "  1 local name = 'ação世界'\n*****0 error(name)\n    titanc\n" ..
            summary, prepared)
        assert.same({
            ["titan-compiler/publication.lua"] = { covered = 1, missed = 0 },
            titanc = { covered = 1, missed = 1 },
        }, coverage_files(prepared))
        assert.is_nil(coverage_files(original).titanc)
    end)

    it("preserves CRLF reports with the CLI as the first section", function()
        local original = "====\r\ntitanc\r\n====\r\n  1 return true\r\n"
        write(input, original)
        prepare()
        assert.equal("====\r\ntitanc.lua\r\n====\r\n  1 return true\r\n",
            read(output))
        assert.equal(original, read(input))
    end)

    it("rejects missing or duplicate CLI sections before replacing the upload", function()
        local section = "====\ntitanc\n====\n  1 return true\n"
        for _, report in ipairs({ "no CLI section\n", section .. section }) do
            write(input, report)
            write(output, "previous upload")
            local ok, err = pcall(prepare)
            assert.is_false(ok)
            assert.matches("expected exactly one titanc section", err, 1, true)
            assert.equal("previous upload", read(output))
        end
    end)
end)
