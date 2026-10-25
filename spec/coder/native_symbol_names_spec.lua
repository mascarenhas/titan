require "titan-compiler.coder.core"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local types = require "titan-compiler.types"

local MODULE = "symbol.case"
local CFILE = "symbol/case.c"
local OFILE = "symbol/case.o"

local function clean()
    os.remove(CFILE)
    os.remove(OFILE)
    os.remove("symbol/case.ffi.h")
    os.remove("symbol/case.priv.h")
    os.remove("symbol/case.parts")
    os.remove("symbol/case.so")
    os.remove("symbol/case.a")
    os.execute("rm -rf symbol/case.so.dSYM")
    os.remove("symbol")
end

local function assert_contains(source, spelling)
    assert.truthy(source:find(spelling, 1, true), spelling)
end

describe("native callable symbol separators", function()
    after_each(clean)

    it("distinguishes source ABI query exports from recovered interface guarantees", function()
        local ok, err, ast, modtype = h.run_checker([[
            state: integer = 0
            local secret: integer = 1
            function identity<|T|>(item: T): T return item end
            local function hidden(): integer return secret end

            record Item
                count: integer
            end
            type ItemAlias = Item
            function Item.make(count: integer): Item return Item.new(count) end
            local function Item.private(): integer return 0 end
            function Item:read(): integer return self.count end

            union Choice
                local hidden()
                ready()
            end
            local record Hidden
            end
            interface Reader
                function read(): integer
            end
        ]])
        assert.truthy(ok, err)
        local recovered = assert(load("return " .. types.serialize(modtype),
            "recovered symbol interface", "t", types))()
        local expected = {
            test_compatibility = "module compatibility entry",
            ["test_\\u2133_state_variable_slot"] = "variable 'test.state' slot",
            ["test_\\u2133_identity_closure_slot"] = "function 'test.identity' closure slot",
            ["test_\\u2133_Item_\\u2131_new_closure_slot"] = "record function 'test.Item.new' closure slot",
            ["test_\\u2133_Item_\\u2131_make_closure_slot"] = "record function 'test.Item.make' closure slot",
            ["test_\\u2133_Choice_\\u2131_ready_closure_slot"] = "union function 'test.Choice.ready' closure slot",
        }
        for _, inventory in ipairs({
            { symbols = coder.external_symbols("test", ast), abi_value = true },
            { symbols = coder.interface_external_symbols("test", recovered),
              abi_value = false },
        }) do
            local actual, seen = {}, {}
            for _, entry in ipairs(inventory.symbols) do
                assert.is_nil(seen[entry.symbol], entry.symbol)
                seen[entry.symbol] = true
                if entry.symbol == "test_abi_value" then
                    assert.equal("module ABI value entry", entry.owner)
                elseif entry.symbol:match("_slot$") or entry.symbol == "test_compatibility" then
                    actual[entry.symbol] = entry.owner
                end
            end
            assert.same(expected, actual)
            assert.equal(inventory.abi_value, seen.test_abi_value == true)
            assert.is_true(seen["test_\\u2133_identity_titan"])
        end
    end)

    it("separates module, nominal owner, member, and metamethod roles", function()
        local csrc, ast = h.compile_and_read_c([[
            record Foo_bar
                n: integer
            end

            function Foo_bar.make(n: integer): Foo_bar
                return Foo_bar.new(n)
            end

            function Foo_bar:touch(): integer
                return self.n
            end

            local function Foo_bar.hidden(): integer
                return 11
            end

            local function Foo_bar:hidden_method(): integer
                return self.n + 1
            end

            record Foo
                n: integer
            end

            function Foo.bar_new(n: integer): Foo
                return Foo.new(n)
            end

            function Foo:bar_touch(): integer
                return self.n
            end

            record Empty
            end

            union Choice
                item(integer)
                empty()
            end

            function Choice:read(): integer
                return 1
            end

            interface Reader
                function read(): integer
            end

            function exercise(): integer
                local first = Foo_bar.make(10)
                local second = Foo.bar_new(20)
                local bound_first = first:touch
                local bound_second = second:bar_touch
                return bound_first() + bound_second()
                    + Foo_bar.hidden() + first:hidden_method()
            end
        ]], MODULE)

        local module_prefix = "symbol_case_\\u2133_"
        local foo_bar = module_prefix .. "Foo_bar_\\u2131_"
        local foo = module_prefix .. "Foo_\\u2131_"
        local empty = module_prefix .. "Empty_\\u2131_"
        local choice = module_prefix .. "Choice_\\u2131_"
        local reader = module_prefix .. "Reader_\\u2131_"

        for _, spelling in ipairs({
            foo_bar .. "new_titanstatic",
            foo_bar .. "make_titanstatic",
            foo_bar .. "make_titanentry_luastatic",
            foo_bar .. "make_titanentry_strictstatic",
            foo_bar .. "touch_titanmethod",
            foo_bar .. "touch_titanentry_luamethod",
            foo_bar .. "touch_boundmethod",
            foo_bar .. "touch_titanentry_boundlua",
            foo_bar .. "touch_titanentry_boundstrict",
            foo_bar .. "hidden_titanstatic",
            foo_bar .. "hidden_method_titanmethod",
            foo .. "new_titanstatic",
            foo .. "bar_new_titanstatic",
            foo .. "bar_touch_titanmethod",
            foo .. "bar_touch_boundmethod",
            empty .. "new_titanstatic",
            empty .. "meta_index",
            empty .. "meta_newindex",
            choice .. "item_titanstatic",
            choice .. "empty_titanstatic",
            choice .. "read_titanmethod",
            reader .. "read_titanentry_interfacelua",
            reader .. "read_interface_boundmethod",
            reader .. "read_titanentry_interface_boundlua",
            reader .. "read_titanentry_interface_boundstrict",
            foo_bar .. "meta_index",
            foo_bar .. "meta_newindex",
            foo .. "meta_index",
            foo .. "meta_newindex",
            choice .. "meta_index",
            choice .. "meta_newindex",
            reader .. "meta_index",
            reader .. "meta_newindex",
            module_prefix .. "meta_index",
            module_prefix .. "meta_newindex",
        }) do
            assert_contains(csrc, spelling)
        end

        assert.falsy(csrc:find("symbol_case_Foo_bar_new_titanstatic", 1, true))
        assert.falsy(csrc:find("symbol_case_Foo_bar_touch_titanmethod", 1, true))
        assert.falsy(csrc:find("ℳ", 1, true))
        assert.falsy(csrc:find("ℱ", 1, true))

        local pipe = assert(io.popen("nm " .. OFILE, "r"))
        local symbols = pipe:read("*a")
        assert.truthy(pipe:close())
        assert_contains(symbols, "symbol_case_ℳ_Foo_bar_ℱ_new_titanstatic")
        assert_contains(symbols, "symbol_case_ℳ_Foo_ℱ_bar_new_titanstatic")
        assert_contains(symbols, "symbol_case_ℳ_Choice_ℱ_item_titanstatic")
        assert.falsy(symbols:find("\\u2133", 1, true))
        assert.falsy(symbols:find("\\u2131", 1, true))
        -- Metamethods are module-mangled; the object neither defines nor
        -- references an unmangled C symbol (Mach-O adds one leading `_`).
        for line in symbols:gmatch("[^\r\n]+") do
            local name = line:match("(%S+)%s*$")
            assert.falsy(name:match("^_?__index$"), line)
            assert.falsy(name:match("^_?__newindex$"), line)
        end

        local source_symbols = coder.external_symbols(MODULE, ast)
        local interface_symbols =
            coder.interface_external_symbols(MODULE, assert(ast._type))
        local function inventory(symbols)
            local seen = {}
            for _, entry in ipairs(symbols) do seen[entry.symbol] = true end
            return seen
        end
        local source_seen = inventory(source_symbols)
        local interface_seen = inventory(interface_symbols)
        for _, symbol in ipairs({
            foo_bar .. "make_titanstatic",
            foo_bar .. "touch_titanmethod",
            foo .. "bar_new_titanstatic",
            foo .. "bar_touch_titanmethod",
            reader .. "read_interface_boundmethod",
        }) do
            assert.is_true(source_seen[symbol], symbol)
            assert.is_true(interface_seen[symbol], symbol)
        end
        assert.is_true(source_seen[foo_bar .. "hidden_titanstatic"])
        assert.is_nil(interface_seen[foo_bar .. "hidden_titanstatic"])
    end)

    it("converts both UCN separators to linkage spellings", function()
        assert.equal("a_ℳ_R_ℱ_f_titanmethod",
            coder_names._linkage_symbol_name(
                "a_\\u2133_R_\\u2131_f_titanmethod"))
    end)
end)
