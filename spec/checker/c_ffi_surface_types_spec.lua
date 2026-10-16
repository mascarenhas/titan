local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session

local function run_checker(code)
    return h.run_checker(code, probe_session)
end

local function with_header(contents, body)
    local path = temporary.name(".h")
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
            { "float", "float", "Type.CFloat" },
            { "double", "double", "Type.CFloat" },
            { "long double", "long double", "Type.CFloat" },
        }
        local declarations = {}
        for index, spelling in ipairs(spellings) do
            declarations[#declarations + 1] =
                "foreign type SurfaceT" .. index .. " = " .. spelling[1]
        end
        local ok, err, ast = run_checker(table.concat(declarations, "\n"))
        assert.truthy(ok, err)
        for index, spelling in ipairs(spellings) do
            local typ = types.resolve_c_typedef(ast[index]._type)
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
                local chars: owned char[] = foreign char.new_array(2)
                local floats: owned float[] =
                    foreign float.new_array(2)
                local words: owned unsigned long[] =
                    foreign unsigned long.new_array(2)
                local fixed = foreign int.new_array(4)
                local wide =
                    foreign unsigned long.new_array(2)
                return foreign bool.sizeof + foreign signed char.alignof
                    + #chars + #floats + #words
                    + fixed[0] as integer + wide[0] as integer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("stores portable function pointers in module TValue slots", function()
        for _, declaration in ipairs({
            "local callback: foreign function (int): int = nil",
            "callback: foreign function (int): int = nil",
        }) do
            local ok, err = run_checker(declaration)
            assert.truthy(ok, err)
        end

        local ok, err = run_checker([[
            pointer: foreign *void = nil

            function read(): foreign *void
                return pointer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps Titan bindings independent from explicit foreign primitives",
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
            local char: integer = 4

            function allocate(): integer
                local chars: owned char[] = foreign char.new_array(2)
                return #chars + char
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker([[
            local type int = string
            function layout(): integer
                return foreign int.sizeof
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker([[
            local type char = integer
            function layout(): integer
                return foreign char.alignof
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("allows C contextual words in the separate Titan nominal namespace",
    function()
        for _, name in ipairs({
            "void", "bool", "char", "signed", "unsigned",
            "short", "int", "long", "double",
        }) do
            local ok, err = run_checker("record " .. name .. " end")
            assert.truthy(ok, name .. ": " .. tostring(err))
        end

        local ok, err = run_checker([[
            union unsigned
                item()
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker([[
            interface long
                function read(): integer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("exports portable recursive graphs and rehydrates numeric traits",
    function()
        local ok, err, imported = h.run_checker_modules({
            provider = [[
                function word(item: foreign unsigned long): foreign unsigned long
                    return item
                end

                function pointer(item: foreign *void): foreign *void
                    return item
                end

                record Box
                    number: foreign int
                end

                function identity(item: foreign int): foreign int
                    return item
                end

                function make(): owned char[]
                    return foreign char.new_array(2)
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function size(): integer
                    return foreign unsigned long.sizeof + foreign unsigned long.alignof
                end

                function use(item: foreign int): foreign int
                    local box = provider.Box.new(item)
                    return provider.identity(box.number)
                end

                function make(): owned char[]
                    return provider.make()
                end

                local function pointer(item: foreign *void): foreign *void
                    return provider.pointer(item)
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)
        local word = imported.provider.type.members.word.type.params[1]
        assert.equal("Type.CInteger", word._tag)
        assert.equal("unsigned long", word.spelling)
        assert.is_table(word._c_numeric)
        assert.equal(word.bits, word._c_numeric.bits)
        assert.is_table(word._c_numeric_carriers)
    end)

    it("exports named header-defined typedef aliases", function()
        with_header("typedef int local_word;\n", function(header)
            local ok, err = run_checker(
                "foreign import \"" .. header .. '"\n' ..
                "foreign type Word = local_word\n" ..
                "function expose(item: foreign Word): foreign Word return item end")
            assert.truthy(ok, err)
        end)
    end)

    it("accepts lua_State as built-in exportable FFI type without foreign import", function()
        local ok, err = run_checker([[
            foreign type StatePtr = *lua_State
            foreign type Callback = function (*lua_State): int

            record StateHolder
                state: foreign *lua_State
            end

            function inspect_state(s: foreign *lua_State): foreign *lua_State
                local cur: foreign *lua_State = L
                return s
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects lua_State by value as incomplete C struct", function()
        local ok, err = run_checker([[
            function test(): integer
                local s: foreign lua_State
                return 0
            end
        ]])
        assert.falsy(ok)
        assert.match("requires complete C struct type 'foreign lua_State'", err)
    end)
end)
