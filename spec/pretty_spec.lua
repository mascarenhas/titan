local pretty = require "titan-compiler.pretty"

describe("Titan pretty-printer", function()
    describe("reindent_c", function()
        it("indents basic blocks", function()
            local input = [[
void foo() {
int x = 1;
}
]]
            local expected = [[
void foo() {
    int x = 1;
}

]]
            assert.same(expected, pretty.reindent_c(input))
        end)

        it("indents nested blocks", function()
            local input = [[
void foo() {
int x = 1;
if (x == 1) {
printf("yes\n");
}
}
]]
            local expected = [[
void foo() {
    int x = 1;
    if (x == 1) {
        printf("yes\n");
    }
}

]]
            assert.same(expected, pretty.reindent_c(input))
        end)

        it("handles blank lines correctly", function()
            local input = [[
void foo() {

int x = 1;

}
]]
            local expected = [[
void foo() {
    int x = 1;
}

]]
            assert.same(expected, pretty.reindent_c(input))
        end)

        it("prevents indentation from becoming negative", function()
            local input = [[
}
}
void foo() {
int x = 1;
}
]]
            local expected = [[
}
}
void foo() {
    int x = 1;
}

]]
            assert.same(expected, pretty.reindent_c(input))
        end)

        it("handles parenthesis correctly", function()
            local input = [[
void foo(
int a,
int b
) {
int x = 1;
}
]]
            local expected = [[
void foo(
    int a,
    int b
) {
    int x = 1;
}

]]
            assert.same(expected, pretty.reindent_c(input))
        end)

        it("removes trailing and leading whitespaces from input lines", function()
            local input = "void foo() {\n  int x = 1;  \n}"
            local expected = "void foo() {\n    int x = 1;\n}\n"
            assert.same(expected, pretty.reindent_c(input))
        end)
    end)
end)
