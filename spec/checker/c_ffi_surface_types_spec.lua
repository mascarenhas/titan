local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session

local function run_checker(code)
    return h.run_checker(code, probe_session)
end

local function with_header(contents, body)
    local path = os.tmpname() .. ".h"
    local file = assert(io.open(path, "w"))
    assert(file:write(contents))
    assert(file:close())
    local results = table.pack(xpcall(function()
        return body(path)
    end, debug.traceback))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

describe("surface C99 types", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("resolves every exact spelling through the active target profile",
    function()
        local spellings = {
            { "void", "void", "Type.CVoid" },
            { "bool", "_Bool", "Type.CInteger" },
            { "char", "char", "Type.CInteger" },
            { "signed char", "signed char", "Type.CInteger" },
            { "unsigned char", "unsigned char", "Type.CInteger" },
            { "short", "short", "Type.CInteger" },
            { "unsigned short", "unsigned short", "Type.CInteger" },
            { "int", "int", "Type.CInteger" },
            { "unsigned int", "unsigned int", "Type.CInteger" },
            { "long", "long", "Type.CInteger" },
            { "unsigned long", "unsigned long", "Type.CInteger" },
            { "long long", "long long", "Type.CInteger" },
            { "unsigned long long", "unsigned long long", "Type.CInteger" },
            { "foreign float", "float", "Type.CFloat" },
            { "double", "double", "Type.CFloat" },
            { "long double", "long double", "Type.CFloat" },
        }
        local declarations = {}
        for index, spelling in ipairs(spellings) do
            declarations[#declarations + 1] =
                "local type T" .. index .. " = " .. spelling[1]
        end
        local ok, err, ast = run_checker(table.concat(declarations, "\n"))
        assert.truthy(ok, err)
        for index, spelling in ipairs(spellings) do
            local typ = ast[index]._type
            assert.equal(spelling[3], typ._tag, spelling[1])
            if typ._tag ~= "Type.CVoid" then
                assert.equal(spelling[2], typ.spelling, spelling[1])
            end
            assert.is_true(types.is_portable_c_primitive(typ), spelling[1])
        end
    end)

    it("provides primitive allocation and layout pseudo-members", function()
        local ok, err = run_checker([[
            function exercise(): integer
                local chars: owned char[] = char.new_array(2)
                local floats: owned foreign float[] =
                    foreign float.new_array(2)
                local words: owned unsigned long[] =
                    unsigned long.new_array(2)
                local fixed: int[4] = int.new_array(4)
                local wide: unsigned long[2] =
                    unsigned long.new_array(2)
                return bool.sizeof + signed char.alignof
                    + #chars + #floats + #words
                    + fixed[0] as integer + wide[0] as integer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps function pointers out of module TValue slots", function()
        for _, declaration in ipairs({
            "local callback: Callback = nil",
            "callback: Callback = nil",
        }) do
            local ok, err = run_checker([[
                type Callback = foreign (int) -> int
            ]] .. declaration)
            assert.falsy(ok)
            assert.match("module variable 'callback'.-no TValue representation",
                err)
        end

        local ok, err = run_checker([[
            pointer: *void = nil

            function read(): *void
                return pointer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("preserves value and type-alias precedence for contextual words",
    function()
        local ok, err, ast = run_checker([[
            local char: integer = 4
            local type int = string

            function read(): integer
                return char
            end

            function identity(item: int): int
                return item
            end
        ]])
        assert.truthy(ok, err)
        local returned = ast[3].block.stats[1].exps[1]
        assert.equal("Type.Integer", returned._type._tag)
        assert.equal("Type.String", ast[4].params[1]._type._tag)

        ok, err = run_checker([[
            local type CChar = char
            local char: integer = 4

            function allocate(): integer
                local chars: owned char[] = CChar.new_array(2)
                return #chars + char
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker([[
            local type int = string
            function layout(): integer
                return int.sizeof
            end
        ]])
        assert.falsy(ok)
        assert.match("variable 'int' not declared", err)

        ok, err = run_checker([[
            local type char = integer
            function layout(): integer
                return char.alignof
            end
        ]])
        assert.falsy(ok)
        assert.match("variable 'char' not declared", err)
    end)

    it("reserves every otherwise-named component from nominal definitions",
    function()
        for _, name in ipairs({
            "void", "bool", "char", "signed", "unsigned",
            "short", "int", "long", "double",
        }) do
            local ok, err = run_checker("record " .. name .. " end")
            assert.falsy(ok, name)
            assert.match("cannot define Titan nominal type '" .. name ..
                "'; the name is a contextual C99 type", err)
        end

        local ok, err = run_checker([[
            union unsigned
                item
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot define Titan nominal type 'unsigned'", err)

        ok, err = run_checker([[
            interface long
                function read(): integer
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot define Titan nominal type 'long'", err)
    end)

    it("exports portable recursive graphs and rehydrates numeric traits",
    function()
        local ok, err, imported = h.run_checker_modules({
            provider = [[
                type Void = void
                type VoidPointer = *Void
                type Word = unsigned long

                record Box
                    number: int
                end

                function identity(item: int): int
                    return item
                end

                function make(): owned char[]
                    return char.new_array(2)
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function size(): integer
                    return provider.Word.sizeof + provider.Word.alignof
                end

                function use(item: int): int
                    local box = provider.Box.new(item)
                    return provider.identity(box.number)
                end

                function make(): owned char[]
                    return provider.make()
                end

                local function pointer(item: provider.VoidPointer):
                        provider.VoidPointer
                    return item
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)
        local word = imported.provider.type.type_members.Word
        assert.equal("Type.CInteger", word._tag)
        assert.equal("unsigned long", word.spelling)
        assert.is_table(word._c_numeric)
        assert.equal(word.bits, word._c_numeric.bits)
        assert.is_table(word._c_numeric_carriers)
    end)

    it("keeps header-defined typedef identity module-local", function()
        with_header("typedef int local_word;\n", function(header)
            local ok, err = run_checker(
                'local c = foreign import "' .. header .. '"\n' ..
                "type Word = c.local_word")
            assert.falsy(ok)
            assert.match("cannot export C FFI type '.-local_word'", err)
            assert.match("non%-portable header%-defined type", err)
        end)
    end)

    it("accepts lua_State as built-in exportable FFI type without foreign import", function()
        local ok, err = run_checker([[
            type StatePtr = *lua_State
            type Callback = foreign (*lua_State) -> int

            record StateHolder
                state: *lua_State
            end

            function inspect_state(s: *lua_State): *lua_State
                local cur: *lua_State = L
                return s
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects lua_State by value as incomplete C struct", function()
        local ok, err = run_checker([[
            function test(): integer
                local s: lua_State
                return 0
            end
        ]])
        assert.falsy(ok)
        assert.match("requires complete C struct type 'lua_State'", err)
    end)
end)
