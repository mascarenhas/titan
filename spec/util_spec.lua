local util = require "titan-compiler.util"


describe("Titan utils", function()

     it("returns error when a file doesn't exist", function()

        local filename = "does_not_exist.titan"
        local ok, err = util.get_file_contents(filename)
        assert.falsy(ok)
        assert.matches(filename, err)

     end)

     it("writes a file to disk", function()

        local filename = "a_file.titan"
        local ok = util.set_file_contents(filename, "return {}")
        assert.truthy(ok)
        os.remove(filename)

     end)

     it("preserves exact bytes with explicit binary file modes", function()
         local filename = require("spec.support.temporary").name("-bytes")
         local contents = "line\n\0\26\r\nend"
         local tested, test_error = pcall(function()
             assert.truthy(util.set_file_contents(filename, contents, "wb"))
             local file = assert(io.open(filename, "rb"))
             local bytes = file:read("a")
             assert(file:close())
             assert.equal(contents, bytes)
             assert.equal(contents, util.get_file_contents(filename, "rb"))
         end)
         os.remove(filename)
         if not tested then error(test_error, 0) end
     end)

     it("orders strings by numeric bytes independent of text collation", function()
         local original = os.setlocale(nil, "collate")
         local locales = { "C", "C.UTF-8", "en_US.UTF-8", "pt_BR.UTF-8" }
         local results = {}
         for _, locale in ipairs(locales) do
             if os.setlocale(locale, "collate") then
                 local values = { "\195\169", "z", "aa", "a", "A" }
                 table.sort(values, util.bytewise_less)
                 results[#results + 1] = values
             end
         end
         if original then os.setlocale(original, "collate") end

         assert.is_true(#results > 0)
         for _, values in ipairs(results) do
             assert.same({ "A", "a", "aa", "z", "\195\169" }, values)
         end
         assert.is_true(util.bytewise_less("a", "aa"))
         assert.is_false(util.bytewise_less("aa", "a"))
         assert.is_false(util.bytewise_less("same", "same"))
     end)

     for _, newline in ipairs({ "\n", "\r\n" }) do
         it("normalizes generated directives while preserving line-ending bytes " .. #newline, function()
             local directive = ' \t#line 7 "source.titan"' .. newline
             local statement = "int value;" .. newline .. newline
             local contents = directive .. newline .. " \t" .. newline .. statement
                 .. '#line 8 TITAN_GENERATED_C_FILE' .. newline .. newline .. statement
             local expected = directive .. statement
                 .. '#line 8 TITAN_GENERATED_C_FILE' .. newline .. statement
             assert.equal(expected, util.normalize_line_directives(contents))
             assert.equal(expected, util.normalize_line_directives(expected))
         end)
     end

     it("preserves directive-like literal and comment text byte for byte", function()
         local contents = [=[
const char *text = "#line 7 \"not a directive\"";

const char *continued = "\
#line 9 not_a_directive\
";

/*
#line 11 "comment"

*/
// #line 12 "comment"

int value;
]=]
         assert.equal(contents, util.normalize_line_directives(contents))
     end)

     for _, ending in ipairs({ { "LF", "\n" }, { "CRLF", "\r\n" } }) do
         it("does not let literal comment openers hide real directives with " .. ending[1], function()
             local literal = [=[static const char quote = '"'; static const char glob[] = "src/*.c";]=]
             local newline = ending[2]
             local contents = table.concat({
                 literal,
                 '#line 7 "first.titan"',
                 "",
                 "int first;",
                 "/* a later real comment */",
                 '#line 11 "second.titan"',
                 " \t",
                 "int second;",
                 "",
             }, newline)
             local expected = table.concat({
                 literal,
                 '#line 7 "first.titan"',
                 "int first;",
                 "/* a later real comment */",
                 '#line 11 "second.titan"',
                 "int second;",
                 "",
             }, newline)
             assert.equal(expected, util.normalize_line_directives(contents))
         end)
     end

     it("renders string templates correctly", function()
         local substs = {
             VAR = "value",
             NUM = "123",
         }

         -- Normal placeholder
         assert.equal("this is a value", util.render("this is a $VAR", substs))

         -- Placeholder with braces
         assert.equal("this is a value", util.render("this is a ${VAR}", substs))

         -- Multiple replacements
         assert.equal("value 123", util.render("$VAR $NUM", substs))

         -- Unmatched brace
         assert.has_error(function()
             util.render("unmatched ${VAR", substs)
         end, "unmatched ${ in template")

         -- Missing variable without ignore_missing
         assert.has_error(function()
             util.render("missing $MISSING", substs)
         end, "Internal compiler error: missing template variable MISSING\nmissing $MISSING")

         -- Missing variable with ignore_missing true
         assert.equal("missing $MISSING", util.render("missing $MISSING", substs, true))
     end)

     it("curries a function", function()
         local function add(a, b)
             return a + b
         end
         local add_five = util.curry(add, 5)
         assert.are.equal(15, add_five(10))
         assert.are.equal(7, add_five(2))
     end)

     it("splits strings", function()
         assert.same({ "a", "b", "c" }, util.split_string("a,b,c", ","))
         assert.same({ "abc" }, util.split_string("abc", ","))
         assert.same({ "" }, util.split_string("", ","))
         assert.same({ "a", "", "c" }, util.split_string("a,,c", ","))
         assert.same({ "", "b", "c" }, util.split_string(",b,c", ","))
         assert.same({ "a", "b", "" }, util.split_string("a,b,", ","))
         assert.same({ "", "" }, util.split_string(",", ","))
         assert.same({ "a", "b", "c" }, util.split_string("a;;b;;c", ";;"))
     end)

     it("checks if any element in a list matches a predicate", function()
         local is_even = function(x) return x % 2 == 0 end
         assert.is_true(util.any(is_even, {1, 2, 3}))
         assert.is_false(util.any(is_even, {1, 3, 5}))
         assert.is_false(util.any(is_even, {}))
     end)

     it("converts values and tables to string representation", function()
         assert.equal('"hello"', util.tostring("hello"))
         assert.equal("123", util.tostring(123))
         assert.equal("true", util.tostring(true))
         assert.equal("{}", util.tostring({}))
         assert.equal('{1, 2, "a"}', util.tostring({ 1, 2, "a" }))
         assert.equal('{["a"] = 1, ["b"] = 2}', util.tostring({ b = 2, a = 1 }))
         assert.equal('{1, ["b"] = 2, [5] = "five"}',
             util.tostring({ 1, [5] = "five", b = 2 }))
         assert.equal('{["nested"] = {1, 2}}', util.tostring({ nested = { 1, 2 } }))
     end)

     it("renders keyed entries in one order whatever order pairs yields", function()
         local entries = { type = "struct", id = "sockaddr", op = "sizeof" }
         local function yielding(order)
             return setmetatable({}, { __pairs = function()
                 local index = 0
                 return function()
                     index = index + 1
                     local key = order[index]
                     if key ~= nil then return key, entries[key] end
                 end
             end })
         end
         local expected = '{["id"] = "sockaddr", ["op"] = "sizeof", ["type"] = "struct"}'
         assert.equal(expected, util.tostring(yielding({ "type", "id", "op" })))
         assert.equal(expected, util.tostring(yielding({ "op", "id", "type" })))
     end)
end)
