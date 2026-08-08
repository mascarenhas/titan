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
end)
