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
