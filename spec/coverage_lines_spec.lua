local assert = require "luassert"
local lines = require "titan-compiler.coverage_lines"
local util = require "titan-compiler.util"

local function mapped(code)
    local result, err, anchors = lines.convert(code, "generated.c")
    assert.truthy(result, err)
    return result, anchors
end

local function source(code, filename, line)
    return lines.region(code, "source", filename or "owner.titan", line or 7)
end

describe("coverage C source regions", function()
    it("repeats a Titan anchor for every physical C line", function()
        local result, anchors = mapped(source("one();\ntwo();\nthree();"))
        assert.matches('#line 7 "owner.titan"\none%(%)', result)
        assert.matches('#line 7 "owner.titan"\ntwo%(%)', result)
        assert.matches('#line 7 "owner.titan"\nthree%(%)', result)
        assert.same({ ["owner.titan"] = { [7] = true } }, anchors)
        assert.is_nil(result:find("TITAN_COVERAGE_", 1, true))
    end)

    it("restores enclosing anchors and explicitly generated regions", function()
        local result = mapped(source("parent();\n"
            .. source("child();", "child.titan", 13)
            .. lines.region("helper();", "generated") .. "parent_again();"))
        assert.matches('#line 13 "child.titan"\nchild%(%)', result)
        assert.matches('#line %d+ "generated.c"\nhelper%(%)', result)
        assert.matches('#line 7 "owner.titan"\nparent_again%(%)', result)
    end)

    it("preserves authored line progression and nested restoration", function()
        local result = mapped(lines.region("first();\n\n"
            .. lines.begin("source", "owner.titan", 7) .. "child();\n"
            .. lines.finish() .. "third();", "authored", "hand.c", 21))
        assert.matches('#line 21 "hand.c"\nfirst%(%)', result)
        -- The child suspends its authored parent; marker lines are metadata.
        assert.matches('#line 23 "hand.c"\nthird%(%)', result)
    end)

    it("respects actual authored line directives and escaped filenames", function()
        local result = mapped(lines.region(
            '#line 90 "C:\\\\code\\\"name.c"\nfirst();\nsecond();',
            "authored", "hand.c", 1))
        assert.matches('#line 90 "C:\\\\code\\\"name.c"\nfirst%(%)', result)
        assert.matches('#line 91 "C:\\\\code\\\"name.c"\nsecond%(%)', result)
    end)

    it("escapes arbitrary filenames independently of C templates", function()
        local result = mapped(source("run();", 'C:\\space dir\\quote"$name.titan', 3))
        assert.truthy(result:find(
            '#line 3 "C:\\\\space dir\\\\quote\\"\\u0024name.titan"', 1, true))
        local bytes = mapped(source("run();", "caf\195\169.titan", 2))
        assert.truthy(bytes:find('"caf\195\169.titan"', 1, true))
    end)

    it("preserves numeric line controls and decodes octal authored filenames", function()
        local result = mapped(lines.region('# 90 "caf\\303\\251.c"\nrun();\nnext();',
            "authored", "old.c", 1))
        assert.truthy(result:find('#line 90 "caf\195\169.c"\nrun();', 1, true))
        assert.truthy(result:find('#line 91 "caf\195\169.c"\nnext();', 1, true))
    end)

    it("decodes a greedy hexadecimal byte escape in an authored filename", function()
        local result = mapped(lines.region('#line 90 "cash\\x00000000024-line.c"\nrun();\nnext();',
            "authored", "old.c", 1))
        assert.truthy(result:find('#line 91 "cash\\u0024-line.c"\nnext();', 1, true))
    end)

    it("round-trips its own spelling and decodes universal character names", function()
        local name = 'C:\\dir\\b"c ??/ $line \t 文.c'
        local spelled = util.c_line_filename(name)
        local result = mapped(lines.region("#line 90 " .. spelled .. "\nrun();\nnext();",
            "authored", "old.c", 1))
        assert.truthy(result:find("#line 91 " .. spelled .. "\nnext();", 1, true))
        result = mapped(lines.region('#line 90 "a\\u00e9\\U0001F600.c"\nrun();\nnext();',
            "authored", "old.c", 1))
        assert.truthy(result:find('#line 91 "a\195\169\240\159\152\128.c"\nnext();', 1, true))
    end)

    it("keeps unrepresentable authored escapes from changing source ownership", function()
        for _, control in ipairs({ '#line 90 "a\\uD800.c"', '#line 90 "a\\U00110000.c"',
                '#line 90 "a\\777.c"', '#line 90 "a\\x24f.c"', '#line 90 "a\\q.c"',
                '#line 90 "a\\000.c"', '#line 90 "a\\n.c"' }) do
            local result = mapped(lines.region(control .. "\nrun();", "authored", "old.c", 1))
            assert.truthy(result:find(control, 1, true))
            assert.truthy(result:find('#line 2 "old.c"\nrun();', 1, true))
        end
    end)

    it("keeps invalid authored line controls from changing source ownership", function()
        for _, control in ipairs({ '#line 90 "one" "two"', '#line 90 invalid' }) do
            local result = mapped(lines.region(control .. "\nrun();", "authored", "old.c", 1))
            assert.truthy(result:find(control, 1, true))
            assert.truthy(result:find('#line 2 "old.c"\nrun();', 1, true))
        end
    end)

    it("rejects invalid conversion inputs", function()
        for _, input in ipairs({ { false, "generated.c" }, { "run();", false },
            { "run();", "" }, { "run();", "bad\nname.c" } }) do
            local result, err = lines.convert(input[1], input[2])
            assert.is_nil(result)
            assert.equal("invalid coverage conversion input", err)
        end
    end)

    it("does not recognize marker or directive lookalikes in literals", function()
        local result = mapped(source([[
const char *s = "// TITAN_COVERAGE_END #line 8";
int c = '\'';
/* not metadata: // TITAN_COVERAGE_END */
run();]]))
        assert.truthy(result:find('"// TITAN_COVERAGE_END #line 8"', 1, true))
        assert.truthy(result:find('/* not metadata:', 1, true))
        assert.matches('#line 7 "owner.titan"\nrun%(%)', result)
    end)

    it("does not insert directives inside multiline comments", function()
        local result = mapped(source("/* comment\n"
            .. "// TITAN_COVERAGE_END\n#line 999\n*/\nrun();"))
        assert.truthy(result:find("/* comment\n// TITAN_COVERAGE_END\n#line 999\n*/", 1, true))
        assert.matches('#line 7 "owner.titan"\nrun%(%)', result)
    end)

    it("resynchronizes executable code after a multiline comment closes", function()
        local result = mapped(source("/* comment\ncontinued\n*/ run();"))
        assert.matches('%*/\n#line 7 "owner.titan"\n run%(%)', result)
    end)

    it("preserves continued macros, escaped literals and continued comments", function()
        local input = '#define VALUE(x) \\\n    ((x) + \\\n      1)\nconst char *s = "a\\\nb";\n// comment \\\n// TITAN_COVERAGE_END\nrun();'
        local result = mapped(source(input))
        assert.truthy(result:find('#define VALUE(x) \\\n    ((x) + \\\n      1)', 1, true))
        assert.truthy(result:find('"a\\\nb"', 1, true))
        assert.truthy(result:find('// comment \\\n// TITAN_COVERAGE_END', 1, true))
        assert.matches('#line 7 "owner.titan"\nrun%(%)', result)
    end)

    it("handles comment tokens split across escaped newlines", function()
        local result = mapped(source('/\\\n* comment\n// TITAN_COVERAGE_END\n*\\\n/\nrun();'))
        assert.truthy(result:find('/\\\n* comment\n// TITAN_COVERAGE_END\n*\\\n/', 1, true))
        assert.matches('#line 7 "owner.titan"\nrun%(%)', result)
    end)

    it("honors C99 trigraph splicing and digraph authored line controls", function()
        local result = mapped(source('// continued ??/\n// TITAN_COVERAGE_END\nrun();',
            "question??/mark.titan"))
        assert.truthy(result:find('// continued ??/\n// TITAN_COVERAGE_END', 1, true))
        assert.truthy(result:find('#line 7 "question\\?\\?/mark.titan"\nrun();', 1, true))
        result = mapped(lines.region('%:line 71 "hand.c"\nrun();', "authored", "old.c", 1))
        assert.matches('#line 71 "hand.c"\nrun%(%)', result)
    end)

    it("recognizes authored line controls after comments and across continuations", function()
        local input = '/* prefix */ #line \\\n71 "next.c"\nrun();\n/* multiline\n*/ #line 90 "last.c"\nfinish();'
        local result = mapped(lines.region(input, "authored", "old.c", 1))
        assert.truthy(result:find('/* prefix */ #line \\\n71 "next.c"', 1, true))
        assert.matches('#line 71 "next.c"\nrun%(%)', result)
        assert.matches('#line 90 "last.c"\nfinish%(%)', result)
    end)

    it("handles CRLF, blank lines and a missing final newline", function()
        local code = lines.begin("source", "owner.titan", 4)
            .. "\r\nrun();\r\n" .. lines.finish():gsub("\n$", "")
        local result = mapped(code)
        assert.truthy(result:find('#line 4 "owner.titan"\nrun();\r\n', 1, true))
        assert.is_nil(result:find("TITAN_COVERAGE_", 1, true))
        assert.equal('#line 2 "generated.c"\nrun();', mapped("run();"))
    end)

    it("keeps recursively rendered child regions owned by their source", function()
        local rendered = util.render(source("first();\n$CHILD\nlast();"), {
            CHILD = source("$VALUE", "child.titan", 12), VALUE = "child();",
        })
        local result = mapped(rendered)
        assert.matches('#line 12 "child.titan"\nchild%(%)', result)
        assert.matches('#line 7 "owner.titan"\nlast%(%)', result)
    end)

    for name, input in pairs({
        ["unmatched end"] = lines.finish(),
        ["unterminated region"] = lines.begin("source", "owner.titan", 1),
        ["invalid marker kind"] = "// TITAN_COVERAGE_BEGIN bogus 1 61\n",
        ["invalid hex filename"] = "// TITAN_COVERAGE_BEGIN source 1 0\n",
        ["invalid line"] = "// TITAN_COVERAGE_BEGIN source 0 61\n",
        ["unknown reserved marker"] = "// TITAN_COVERAGE_CHANGED\n",
        ["unterminated comment"] = "/* comment",
        ["unterminated literal"] = '"literal',
        ["unterminated continuation"] = "continued \\\n",
    }) do
        it("rejects " .. name, function()
            local result, err = lines.convert(input, "generated.c")
            assert.is_nil(result)
            assert.matches("coverage source regions", err)
        end)
    end
end)
