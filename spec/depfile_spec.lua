local depfile = require "titan-compiler.depfile"

describe("native dependency files", function()
    it("preserves prerequisite order across rules and ignores phony targets", function()
        assert.same({ "main.c", "one.h", "two.h" }, assert(depfile.parse(
            "main.o main.d: main.c one.h\nother.o: one.h two.h\none.h:\ntwo.h:\n")))
    end)

    it("decodes escaped whitespace hashes dollars colons and backslashes", function()
        assert.same({ "source file.c", "tab\tname.h", "hash#name.h", "cash$name.h",
            "colon:name.h", "back\\slash.h" }, assert(depfile.parse(
            "target\\ name.o: source\\ file.c tab\\\tname.h hash\\#name.h " ..
            "cash$$name.h colon\\:name.h back\\\\slash.h # ignored\n")))
    end)

    it("folds LF and CRLF continuations including adjacent words", function()
        assert.same({ "a.c", "b.h", "c.h", "d.h" }, assert(depfile.parse(
            "a.o: a.c\\\n b.h \\\r\n\tc.h\\\n d.h\r\n")))
    end)

    it("retains drive prefixes and native Windows separators", function()
        assert.same({ "C:/src/main.c", "D:\\SDK\\include\\file.h", "C:/Program Files/a.h" },
            assert(depfile.parse("C:/out/main.o: C:/src/main.c " ..
                "D:\\SDK\\include\\file.h C:/Program\\ Files/a.h\r\n")))
    end)

    it("retains escaped drive colons and UNC paths", function()
        assert.same({ "C:/src/a.c", "\\\\server\\share\\a.h" }, assert(depfile.parse(
            "a.o: C\\:/src/a.c \\\\\\\\server\\share\\a.h\n")))
    end)

    it("accepts empty prerequisite lists and final lines without newline", function()
        assert.same({}, assert(depfile.parse("file.h:")))
        assert.same({ "a.c" }, assert(depfile.parse("a.o: a.c")))
    end)

    it("uses the exact TU and preserves an included slash-spelled twin", function()
        local source = "/main\\dir/unit.c"
        local report = "target: forced\\ \\#$$.h \\\r\n" ..
            " /main/dir/unit.c /main/dir/unit.c\r\n" ..
            "forced\\ \\#$$.h:\r\n/main/dir/unit.c:\r\n"
        local files = assert(depfile.compiler_inputs(report, source))
        assert.same({ source, "forced #$.h", "/main/dir/unit.c" }, files)
        assert.same(files, assert(depfile.parse(assert(depfile.render("target", files)))))
    end)

    it("accepts a primary compiler rule without phony headers", function()
        assert.same({ "lit\\eral/main.c" },
            assert(depfile.compiler_inputs("target: lit/eral/main.c\n", "lit\\eral/main.c")))
    end)

    it("rejects collapsed or incomplete phony inventories", function()
        local source = "lit\\eral/main.c"
        local report = "target: lit/eral/main.c twin.h twin.h\n"
        local files, err = depfile.compiler_inputs(report .. "twin.h:\ntwin.h:\n", source)
        assert.is_nil(files)
        assert.equal("ambiguous dependency spelling: twin.h", err)
        files, err = depfile.compiler_inputs(report .. "twin.h:\n", source)
        assert.is_nil(files)
        assert.equal("incomplete phony dependency inventory", err)
    end)

    it("deduplicates GCC phony headers when the reported main kept a literal backslash", function()
        local source = "lit\\eral/main.c"
        local report = "target: " .. source .. " same.h same.h\nsame.h:\nsame.h:\n"
        assert.same({ source, "same.h" }, assert(depfile.compiler_inputs(report, source)))
    end)

    it("writes Make escaping for exceptional native source provenance", function()
        local inputs = { "dir\\name \\ space\ttab#$:main.c", "headers/common.h" }
        assert.same(inputs, assert(depfile.parse(assert(depfile.render("target", inputs)))))
        assert.is_nil(depfile.render("target", { "unrepresentable\npath" }))
    end)

    for _, case in ipairs({
        { "missing separator", "a.o a.c" },
        { "missing target", ": a.c" },
        { "variable expansion", "a.o: $(INPUT)" },
        { "single dollar", "a.o: $input" },
        { "unescaped colon", "a.o: name:part.h" },
        { "terminal escape", "a.o: a.c\\" },
        { "no rules", " # comment only\n" },
        { "embedded NUL", "a.o: a\0.c" },
    }) do
        it("rejects " .. case[1], function()
            local result, err = depfile.parse(case[2])
            assert.is_nil(result)
            assert.is_string(err)
        end)
    end
end)
