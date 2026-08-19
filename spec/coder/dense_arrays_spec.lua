local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function clean_module(name)
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", "__entrypoint.c",
        "__entrypoint.o",
    }) do
        os.remove(name .. suffix)
    end
    os.execute("rm -rf " .. name .. ".dSYM")
end

local function generate(source)
    h.reset(true)
    local ast, perr = h.parse(source, "test.titan")
    assert.truthy(ast, perr)
    local _, errors = checker.check(
        "test", ast, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", ast, {}, driver.TITAN_VER)
end

local function generated_function(csrc, marker)
    local search = 1
    while true do
        local start = assert(csrc:find(marker, search, true),
            "generated C function not found: " .. marker)
        local line_end = csrc:find("\n", start, true) or (#csrc + 1)
        local brace = csrc:find("{", start, true)
        if brace and brace < line_end then
            local depth = 0
            for i = brace, #csrc do
                local byte = csrc:sub(i, i)
                if byte == "{" then
                    depth = depth + 1
                elseif byte == "}" then
                    depth = depth - 1
                    if depth == 0 then return csrc:sub(start, i) end
                end
            end
            error("unterminated generated C function: " .. marker)
        end
        search = line_end + 1
    end
end

local function count_matches(text, pattern)
    local _, count = text:gsub(pattern, "")
    return count
end

describe("dense Array code generation and boundaries", function()
    after_each(function()
        clean_module("test")
        clean_module("dense_array_args")
    end)

    it("keeps exact Array signatures raw and lowers dense operations directly",
    function()
        local csrc = generate([[
            record Holder
                items: {integer}
            end

            stored: {integer} = { 1 }

            function exact(a: {integer}): {integer}
                return a
            end

            function first(...: {integer}): {integer}?
                return ...[1]
            end

            function length(a: {integer}): integer
                return #a
            end

            function mutate(a: {integer}, i: integer, v: integer?): nil
                a[i] = v
                return nil
            end

            function mutate_value(a: {value}, i: integer, v: value): nil
                a[i] = v
                return nil
            end

            function holder(a: {integer}): Holder
                return Holder.new(a)
            end

            function holder_get(h: Holder): {integer}
                return h.items
            end

            function as_value(a: {integer}): value
                return a
            end

            function map_value(a: {integer}): {string: {integer}}
                return { ["array"] = a }
            end

            function nested(a: {{integer}}): {integer}?
                return a[1]
            end
        ]])

        assert.match(
            "Table%* test_\\u2133_exact_titan%(lua_State %*L, Udata %*_mod, " ..
            "CClosure %*_fn, Table%* _param_a%)", csrc)
        assert.match("TitanVargArrayOrMap %*_varargs", csrc)
        assert.not_match(
            "Udata %*test_\\u2133_exact_titan%(lua_State", csrc)

        local exact = generated_function(
            csrc, "test_\\u2133_exact_titan(lua_State *L")
        local exact_entry = generated_function(
            csrc, "test_\\u2133_exact_titanentry_lua(lua_State *L")
        local first_entry = generated_function(
            csrc, "test_\\u2133_first_titanentry_lua(lua_State *L")
        local length = generated_function(
            csrc, "test_\\u2133_length_titan(lua_State *L")
        local mutate = generated_function(
            csrc, "test_\\u2133_mutate_value_titan(lua_State *L")
        local holder_new = generated_function(
            csrc, "test_\\u2133_Holder_\\u2131_new_titanstatic(lua_State *L")
        local as_value = generated_function(
            csrc, "test_\\u2133_as_value_titan(lua_State *L")
        local map_value = generated_function(
            csrc, "test_\\u2133_map_value_titan(lua_State *L")
        local nested = generated_function(
            csrc, "test_\\u2133_nested_titan(lua_State *L")

        -- Exact and compiler-owned typed slots retain raw backing Tables.
        assert.match("sethvalue", exact)
        assert.not_match("titan_array_require_proxy", exact)
        assert.match("sethvalue", holder_new)
        assert.truthy(holder_new:find("->uv[0].uv", 1, true))
        assert.not_match("titan_array_require_proxy", holder_new)

        -- The shared Array/Map descriptor remains Table **. Array wrappers
        -- select the Array-specific unbox adapter semantically.
        assert.match("sizeof%(Table%*%)", first_entry)
        assert.match("Table%* %*_varargs_args", first_entry)
        assert.not_match("Udata%* %*_varargs_args", first_entry)
        assert.match("TitanVargArrayOrMap %*_varargs", first_entry)
        assert.match("titan_array_try_backing", first_entry)

        -- Lua and value boundaries unbox/box through the cached metatable,
        -- without consulting the registry for an Array tag.
        assert.match("titan_array_try_backing", exact_entry)
        assert.match("titan_array_require_proxy", exact_entry)
        assert.not_match("LUA_REGISTRYINDEX", exact_entry)
        assert.match("titan_array_require_proxy", as_value)
        assert.match("setuvalue", as_value)
        assert.not_match("LUA_REGISTRYINDEX", as_value)
        assert.match("titan_array_require_proxy", map_value)
        assert.match("luaH_set", map_value)
        assert.not_match("LUA_REGISTRYINDEX", map_value)

        assert.match("titan_array_length%(_param_a%)", length)
        assert.not_match("luaH_getn", length)

        -- The guard precedes signed-to-unsigned conversion and every store.
        local guard = assert(mutate:find("_k < 1", 1, true))
        local unsigned = assert(mutate:find("l_castS2U(_k)", 1, true))
        local store = assert(mutate:find("obj2arr", 1, true))
        assert.is_true(guard < unsigned)
        assert.is_true(guard < store)
        assert.match("titan_array_resize", mutate)
        assert.not_match("luaH_resizearray", mutate)
        assert.not_match("luaH_setint", mutate)
        assert.not_match("titan_array_require_proxy", mutate)
        assert.not_match("titan_array_try_backing", mutate)
        assert.not_match("metatable", mutate)
        assert.not_match("LUA_REGISTRYINDEX", mutate)
        assert.match("obj2arr%(_t,", mutate)
        assert.match(
            "obj2arr%(_t,[^\n]+\n%s*luaC_barrierback" ..
            "%(L, obj2gco%(_t%), &_vv%);", mutate)
        assert.match("getArrTag%(_t,", mutate)

        -- Outer typed slot addressing is raw. Only the post-load conversion
        -- accepts either an internal backing or a Lua-written proxy.
        local structural = assert(nested:find("if (ttistable(_s))", 1, true))
        local outer_read = nested:sub(1, structural - 1)
        assert.match("arr2obj", outer_read)
        assert.not_match("titan_array_", outer_read)
        assert.not_match("metatable", outer_read)
        local raw_probe = assert(nested:find(
            "titan_array_try_proxy", structural, true))
        local boxed_probe = assert(nested:find(
            "titan_array_try_backing", raw_probe, true))
        assert.is_true(structural < raw_probe)
        assert.is_true(raw_probe < boxed_probe)
        assert.not_match("LUA_REGISTRYINDEX", nested)

        local registry_anchor = assert(csrc:find(
            "lua_setfield(L, LUA_REGISTRYINDEX", 1, true))
        local cache_init = assert(csrc:find(
            "titan_array_metatables(", 1, true))
        assert.is_true(registry_anchor < cache_init)
    end)

    it("passes exact fixed and open produced counts to Array construction",
    function()
        local source = [[
            function fixed(): {value}
                return { 1, nil, 3, nil }
            end

            function opened(f: value): {value}
                return { 1, f() }
            end
        ]]
        local csrc = generate(source)
        local fixed = generated_function(
            csrc, "test_\\u2133_fixed_titan(lua_State *L")
        local opened = generated_function(
            csrc, "test_\\u2133_opened_titan(lua_State *L")
        local fixed_flat = fixed:gsub("%s+", " ")
        local opened_flat = opened:gsub("%s+", " ")
        local backscan =
            "while %(_array_length > 0 && " ..
            "tagisempty%(%*getArrTag%([^,]+, " ..
            "_array_length%)%)%) _array_length%-%-;"

        -- Fixed constructors pass their exact positional count, not a rounded
        -- growth capacity, carry their module-local Lua writer, then backscan
        -- trailing nils for the final length.
        assert.match(
            "titan_array_new%(%s*L, [^,]+, 4, " ..
            "&_mod%->uv%[%d+%]%.uv, " ..
            "%(restorestack%(L, _base_off%) %+ %d+%)%);", fixed_flat)
        assert.match(backscan, fixed_flat)
        assert.match(
            "unsigned _array_length = 4; .*" ..
            "titan_array_set_length%([^,]+, _array_length%);",
            fixed_flat)

        -- Runtime-open constructors add the actual result count to the fixed
        -- prefix in lua_Unsigned before allocation, then compute length from
        -- that same produced run rather than blindly recording its count.
        assert.match(
            "titan_array_new%(%s*L, [^,]+, " ..
            "%(%(lua_Unsigned%)1 %+ %(lua_Unsigned%)_vacount%)%s*, " ..
            "&_mod%->uv%[%d+%]%.uv, " ..
            "%(restorestack%(L, _base_off%) %+ %d+%)%);",
            opened_flat)
        assert.match(backscan, opened_flat)
        assert.match(
            "unsigned _array_length = cast_uint%(1 %+ _vacount%); .*" ..
            "titan_array_set_length%([^,]+, _array_length%);",
            opened_flat)

        h.run_coder(source, [[
            local fixed = test.fixed()
            assert(#fixed == 3)
            assert(fixed[1] == 1 and fixed[2] == nil
                and fixed[3] == 3 and fixed[4] == nil)

            local opened = test.opened(function()
                return 2, nil, 4, nil
            end)
            assert(#opened == 4)
            assert(opened[1] == 1 and opened[2] == 2
                and opened[3] == nil and opened[4] == 4
                and opened[5] == nil)
        ]])
    end)

    it("carries one module-local writer per constructed element type",
    function()
        local csrc = generate([[
            function ints_one(): {integer}
                return { 1 }
            end

            function ints_two(): {integer}
                return { 2 }
            end

            function values(): {value}
                return { 3 }
            end

            function booleans(): {boolean}
                return { false }
            end

            function words(): {string}
                return { "word" }
            end

            function nested(): {{value}}
                local inner: {value} = { 4 }
                return { inner }
            end
        ]])
        local flat = csrc:gsub("%s+", " ")

        -- Five distinct element types are constructed: integer, value,
        -- boolean, string, and {value}. Repeated integer/value constructors
        -- reuse their module-local closure and slot.
        assert.equal(5, count_matches(flat,
            "static int test_array_writer_%d+%(lua_State %*L%) %{"))
        assert.equal(5, count_matches(flat,
            "lua_pushcclosure%(L, test_array_writer_%d+, 1%);"))

        local writer_slots = {}
        local writer_count = 0
        for _, slot in flat:gmatch(
            "lua_pushcclosure%(L, test_array_writer_(%d+), 1%); " ..
            "setobj2t%(L, &_mod%->uv%[(%d+)%]%.uv")
        do
            writer_count = writer_count + 1
            assert.is_nil(writer_slots[slot])
            writer_slots[slot] = true
        end
        assert.equal(5, writer_count)

        local call_counts = {}
        local call_count = 0
        for call in flat:gmatch("titan_array_new%b()") do
            local slot = assert(call:match(
                ", &_mod%->uv%[(%d+)%]%.uv, " ..
                "%(restorestack%(L, _base_off%) %+ %d+%)%)$"))
            assert.is_true(writer_slots[slot])
            call_counts[slot] = (call_counts[slot] or 0) + 1
            call_count = call_count + 1
        end
        assert.equal(7, call_count)

        local counts = {}
        for _, count in pairs(call_counts) do
            table.insert(counts, count)
        end
        table.sort(counts)
        assert.same({ 1, 1, 1, 2, 2 }, counts)

        local function constructor_writer(marker)
            local body = generated_function(csrc, marker):gsub("%s+", " ")
            local call = assert(body:match("titan_array_new%b()"))
            return assert(call:match(
                ", &_mod%->uv%[(%d+)%]%.uv, " ..
                "%(restorestack%(L, _base_off%) %+ %d+%)%)$"))
        end
        assert.equal(
            constructor_writer("test_\\u2133_ints_one_titan(lua_State *L"),
            constructor_writer("test_\\u2133_ints_two_titan(lua_State *L"))
        assert.not_equal(
            constructor_writer("test_\\u2133_ints_one_titan(lua_State *L"),
            constructor_writer("test_\\u2133_values_titan(lua_State *L"))
    end)

    it("applies carried writers only at genuine Lua Array writes", function()
        h.run_coder([[
            function integers(): {integer}
                return { 10, 20 }
            end

            function booleans(): {boolean}
                return { false, false }
            end

            function integer_at(
                values: {integer},
                index: integer
            ): integer
                return values[index]
            end

            function boolean_at(
                values: {boolean},
                index: integer
            ): boolean
                return values[index]
            end

            function widened_integer(): {value}
                local concrete: {integer} = { 11 }
                local view: {value} = concrete
                return view
            end

            function projected_value(): {integer}
                local concrete: {value} = { 31 }
                local view: {integer} = concrete
                return view
            end

            function nested(): {{value}}
                local concrete: {integer} = { 41 }
                local view: {value} = concrete
                return { view }
            end

            function nested_integer_at(
                values: {{integer}},
                index: integer
            ): integer
                local inner: {integer} = values[index]
                return inner[1]
            end
        ]], [[
            local function fails(f, text)
                local ok, err = pcall(f)
                assert(not ok)
                assert(tostring(err):find(text, 1, true), tostring(err))
            end

            local integers = test.integers()
            assert(math.type(12.0) == "float")
            integers[2] = 12.0
            assert(math.type(integers[2]) == "integer")
            assert(test.integer_at(integers, 2) == 12)

            -- Writer failure precedes both replacement and growth.
            fails(function() integers[2] = "wrong" end,
                "expected integer")
            assert(#integers == 2)
            assert(integers[2] == 12)
            fails(function() integers[3] = "wrong" end,
                "expected integer")
            assert(#integers == 2)
            assert(integers[3] == nil)

            -- Nil is deletion, not an element conversion.
            integers[2] = nil
            assert(#integers == 1)
            assert(integers[2] == nil)
            integers[100] = nil
            assert(#integers == 1)

            local booleans = test.booleans()
            booleans[1] = "truthy"
            booleans[2] = 0
            assert(test.boolean_at(booleans, 1))
            assert(test.boolean_at(booleans, 2))
            booleans[2] = false
            assert(not test.boolean_at(booleans, 2))

            -- A view change does not replace the writer selected where the
            -- backing was constructed.
            local widened = test.widened_integer()
            widened[1] = 21.0
            assert(math.type(widened[1]) == "integer")
            assert(widened[1] == 21)
            fails(function() widened[2] = "wrong" end,
                "expected integer")
            assert(#widened == 1 and widened[2] == nil)

            local projected = test.projected_value()
            projected[1] = 32.0
            assert(math.type(projected[1]) == "float")
            fails(function()
                return test.integer_at(projected, 1)
            end, "expected integer")

            -- Outer and inner Arrays use the same shared metatable even when
            -- their writers were selected under different element views.
            local outer = test.nested()
            local inner = outer[1]
            assert(getmetatable(outer) == "Titan array metatable")
            assert(getmetatable(inner) == getmetatable(outer))
            inner[1] = 42.0
            assert(math.type(inner[1]) == "integer")
            outer[2] = widened
            assert(outer[2] == widened)
            assert(test.nested_integer_at(outer, 1) == 42)
            assert(test.nested_integer_at(outer, 2) == 21)
        ]])
    end)

    it("maintains highest-present length and canonical Lua identity", function()
        h.run_coder([[
            stored: {value} = { 10, nil, 30, nil }

            function make(): {value}
                return { 10, nil, 30, nil }
            end

            function make_int(): {integer}
                return { 1, 2, 3 }
            end

            function all_nil(): {value}
                return { nil, nil, nil }
            end

            function set(a: {value}, i: integer, v: value): nil
                a[i] = v
                return nil
            end

            function at(a: {value}, i: integer): value
                return a[i]
            end

            function int_at(a: {integer}, i: integer): integer?
                return a[i]
            end

            function echo(a: {value}): {value}
                return a
            end

            function as_value(a: {value}): value
                return a
            end

            function from_value(v: value): {value}
                return v as {value}
            end

            function map_length(m: {integer: value}): integer
                return #m
            end
        ]], [[
            local function fails(f, text)
                local ok, err = pcall(f)
                assert(not ok)
                assert(tostring(err):find(text, 1, true), tostring(err))
            end

            local a = test.make()
            assert(type(a) == "userdata")
            assert(getmetatable(a) == "Titan array metatable")
            assert(#a == 3)
            assert(a[1] == 10 and a[2] == nil and a[3] == 30)
            assert(a[0] == nil and a[-1] == nil)
            assert(test.echo(a) == a)
            assert(test.as_value(a) == a)
            assert(test.from_value(test.as_value(a)) == a)
            assert(test.stored == test.stored)

            local nils = test.all_nil()
            assert(type(nils) == "userdata")
            assert(#nils == 0)
            assert(nils[1] == nil and nils[2] == nil and nils[3] == nil)

            test.set(a, 5, "five")
            assert(#a == 5 and a[5] == "five")
            test.set(a, 4, nil)
            assert(#a == 5)
            test.set(a, 5, nil)
            assert(#a == 3)
            test.set(a, 3, nil)
            assert(#a == 1)
            test.set(a, 100, nil)
            assert(#a == 1)
            a[4] = "four"
            assert(#a == 4 and test.at(a, 4) == "four")
            a[4] = nil
            assert(#a == 1)

            fails(function() test.set(a, 0, 9) end,
                  "array index must be positive")
            fails(function() a[-1] = 9 end,
                  "Titan array index must be positive")
            fails(function() return a[1.5] end,
                  "Titan array index must be an integer")
            fails(function() a["1"] = 9 end,
                  "Titan array index must be an integer")
            assert(#a == 1 and a[1] == 10 and a[0] == nil)

            assert(not pcall(rawget, a, 1))
            assert(not pcall(rawset, a, 1, 2))
            assert(not pcall(rawlen, a))

            fails(function() test.echo({1, 2, 3}) end,
                  "expected array")
            assert(test.map_length({10, 20, 30}) == 3)

            local ints = test.make_int()
            local ok, err = pcall(function() ints[2] = "wrong" end)
            assert(not ok)
            assert(tostring(err):find("expected integer", 1, true),
                tostring(err))
            assert(#ints == 3)
            assert(test.int_at(ints, 2) == 2)
        ]])
    end)

    it("rejects an Array proxy carried by value where a Map is required",
    function()
        h.run_coder([[
            function array_value(): value
                local a: {value} = { 1 }
                return a
            end

            function map_value(): value
                local m: {integer: value} = { [1] = "one" }
                return m
            end

            function require_map(v: value): {integer: value}
                return v as {integer: value}
            end
        ]], [[
            local function fails(f, text)
                local ok, err = pcall(f)
                assert(not ok)
                assert(tostring(err):find(text, 1, true), tostring(err))
            end

            local array = test.array_value()
            assert(type(array) == "userdata")
            fails(function() test.require_map(array) end,
                  "type error, expected table")

            local map = test.map_value()
            assert(type(map) == "table")
            assert(test.require_map(map) == map)

            local plain = { [1] = "plain" }
            assert(test.require_map(plain) == plain)
        ]])
    end)

    -- A Titan Array is table-like but not a Lua table. Stock Lua 5.5 routes
    -- table-library operations through __len/__index/__newindex, while its
    -- raw functions reject the userdata proxy.
    it("uses stock-Lua table-library behavior for table-like Array proxies",
    function()
        h.run_coder([[
            function words(): {string}
                return { "a", "c" }
            end
        ]], [[
            local words = test.words()
            table.insert(words, 2, "b")
            assert(#words == 3)
            assert(table.concat(words, ",") == "a,b,c")
            assert(table.remove(words, 2) == "b")
            assert(#words == 2)
            assert(words[1] == "a" and words[2] == "c")
        ]])
    end)

    it("boxes nested Arrays in Maps, values, records, and Lua accessors",
    function()
        h.run_coder([[
            record Holder
                items: {value}
            end

            function leaf(n: integer): {value}
                return { n }
            end

            function holder(a: {value}): Holder
                return Holder.new(a)
            end

            function outer(a: {value}): {{value}}
                return { a }
            end

            function first(a: {{value}}): {value}?
                return a[1]
            end

            function positional_map(a: {value}): {integer: {value}}
                return { a }
            end

            function keyed_map(a: {value}): {integer: {value}}
                return { [1] = a }
            end

            function key_map(a: {value}): {{value}: integer}
                return { [a] = 7 }
            end

            function lookup(
                m: {{value}: integer},
                a: {value}
            ): integer?
                return m[a]
            end

            function value_array(
                a: {value},
                m: {integer: value}
            ): {value}
                return { a, m }
            end
        ]], [[
            local a = test.leaf(1)
            local b = test.leaf(2)

            local holder = test.holder(a)
            assert(holder.items == a)
            holder.items = b
            assert(holder.items == b)

            local outer = test.outer(a)
            assert(type(outer) == "userdata")
            assert(outer[1] == a)
            outer[1] = b
            assert(test.first(outer) == b)

            local positional = test.positional_map(a)
            local keyed = test.keyed_map(a)
            assert(type(positional) == "table")
            assert(type(keyed) == "table")
            assert(positional[1] == a)
            assert(keyed[1] == a)

            local by_array = test.key_map(a)
            assert(by_array[a] == 7)
            assert(test.lookup(by_array, a) == 7)
            assert(test.lookup(by_array, b) == nil)

            local ordinary = { [0] = "unrelated", [1] = "map" }
            local values = test.value_array(a, ordinary)
            assert(values[1] == a)
            assert(values[2] == ordinary)
            assert(values[2][0] == "unrelated")
        ]])
    end)

    it("builds positional integer Maps as raw tables with open results",
    function()
        local csrc = generate([[
            function fixed(): {integer: value}
                return { 10, nil, 30 }
            end
        ]])
        assert.match(
            "luaH_resizearray%(L, [^,]+, cast_uint%(3%)%)", csrc)
        assert.not_match("titan_array_new%(L", csrc)

        h.run_coder([[
            trace: integer = 0

            local function mark(n: integer): integer
                trace = trace * 10 + n
                return n
            end

            function fixed(): {integer: value}
                return { "first", nil, "third" }
            end

            function open_values(f: value): {integer: value}
                return { "head", f() }
            end

            function open_floats(f: value): {integer: float}
                return { 0, f() }
            end

            function ordered(f: value): {integer: float}
                trace = 0
                return { mark(1), f(), mark(3) }
            end

            function length(m: {integer: value}): integer
                return #m
            end
        ]], [[
            local fixed = test.fixed()
            assert(type(fixed) == "table")
            assert(fixed[1] == "first")
            assert(fixed[2] == nil)
            assert(fixed[3] == "third")

            local open = test.open_values(function()
                return "one", nil, "three"
            end)
            assert(type(open) == "table")
            assert(open[1] == "head")
            assert(open[2] == "one")
            assert(open[3] == nil)
            assert(open[4] == "three")

            local floats = test.open_floats(function()
                return 1, 2, 3
            end)
            assert(floats[1] == 0.0)
            assert(floats[2] == 1.0)
            assert(floats[3] == 2.0)
            assert(floats[4] == 3.0)

            local calls = 0
            local ok, err = pcall(test.ordered, function()
                calls = calls + 1
                return "not a float"
            end)
            assert(not ok)
            assert(tostring(err):find("expected float", 1, true), err)
            assert(calls == 1)
            assert(test.trace == 1)

            local with_len = setmetatable({ 10, 20 }, {
                __len = function() return 999 end,
            })
            assert(#with_len == 999)
            assert(test.length(with_len) == 999)

            local holed = { [1] = "first", [3] = "third" }
            local border = test.length(holed)
            assert(border == 1 or border == 3)
            assert(holed[border] ~= nil and holed[border + 1] == nil)
        ]])
    end)

    it("dispatches Array, Map, and optional descriptors by semantic type",
    function()
        local source = [[
            function make(n: integer): {integer}
                return { n }
            end

            function identity(a: {integer}): {integer}
                return a
            end

            function exact_call(a: {integer}): {integer}
                local f: ({integer}) -> {integer} = identity
                return f(a)
            end

            function generic_call(f: value, a: {integer}): {integer}
                return f(a)
            end

            function collect(...: {integer}): {{integer}}
                return { ... }
            end

            function flexible(a: {integer}): (...: {integer})
                return a, a
            end

            function array_variadic(...: {integer}): {integer}?
                return ...[1]
            end

            function map_variadic(
                ...: {string: integer}
            ): {string: integer}?
                return ...[1]
            end

            function option_variadic(...: {integer}?): {integer}?
                return ...[1]
            end

            function array_flexible(
                a: {integer}
            ): (...: {integer})
                return a, a
            end

            function map_flexible(
                m: {string: integer}
            ): (...: {string: integer})
                return m, m
            end

            function option_flexible(
                a: {integer}?
            ): (...: {integer}?)
                return a, nil, a
            end

            function call_array_variadic(
                f: (...: {integer}) -> {integer}?,
                a: {integer},
                b: {integer}
            ): {integer}?
                return f(a, b)
            end

            function call_map_variadic(
                f: (...: {string: integer}) -> {string: integer}?,
                a: {string: integer},
                b: {string: integer}
            ): {string: integer}?
                return f(a, b)
            end

            function call_option_variadic(
                f: (...: {integer}?) -> {integer}?,
                a: {integer}?,
                b: {integer}?
            ): {integer}?
                return f(a, b)
            end

            function call_array_flexible(
                f: ({integer}) -> (...: {integer}),
                a: {integer}
            ): (...: {integer})
                return f(a)
            end

            function call_map_flexible(
                f: ({string: integer}) -> (...: {string: integer}),
                m: {string: integer}
            ): (...: {string: integer})
                return f(m)
            end

            function call_option_flexible(
                f: ({integer}?) -> (...: {integer}?),
                a: {integer}?
            ): (...: {integer}?)
                return f(a)
            end

            function optional(
                a: {integer}?,
                present: boolean
            ): {integer}?
                if present then return a end
                return nil
            end
        ]]

        local csrc = generate(source)
        local array_variadic = generated_function(
            csrc, "test_\\u2133_array_variadic_titan(lua_State *L")
        local map_variadic = generated_function(
            csrc, "test_\\u2133_map_variadic_titan(lua_State *L")
        local option_variadic = generated_function(
            csrc, "test_\\u2133_option_variadic_titan(lua_State *L")
        local array_variadic_entry = generated_function(
            csrc, "test_\\u2133_array_variadic_titanentry_lua(lua_State *L")
        local map_variadic_entry = generated_function(
            csrc, "test_\\u2133_map_variadic_titanentry_lua(lua_State *L")
        local option_variadic_entry = generated_function(
            csrc, "test_\\u2133_option_variadic_titanentry_lua(lua_State *L")
        local array_flexible = generated_function(
            csrc, "test_\\u2133_array_flexible_titan(lua_State *L")
        local map_flexible = generated_function(
            csrc, "test_\\u2133_map_flexible_titan(lua_State *L")
        local option_flexible = generated_function(
            csrc, "test_\\u2133_option_flexible_titan(lua_State *L")
        local array_flexible_entry = generated_function(
            csrc, "test_\\u2133_array_flexible_titanentry_lua(lua_State *L")
        local map_flexible_entry = generated_function(
            csrc, "test_\\u2133_map_flexible_titanentry_lua(lua_State *L")
        local option_flexible_entry = generated_function(
            csrc, "test_\\u2133_option_flexible_titanentry_lua(lua_State *L")
        local call_array_variadic = generated_function(
            csrc, "test_\\u2133_call_array_variadic_titan(lua_State *L")
        local call_map_variadic = generated_function(
            csrc, "test_\\u2133_call_map_variadic_titan(lua_State *L")
        local call_option_variadic = generated_function(
            csrc, "test_\\u2133_call_option_variadic_titan(lua_State *L")
        local call_array_flexible = generated_function(
            csrc, "test_\\u2133_call_array_flexible_titan(lua_State *L")
        local call_map_flexible = generated_function(
            csrc, "test_\\u2133_call_map_flexible_titan(lua_State *L")
        local call_option_flexible = generated_function(
            csrc, "test_\\u2133_call_option_flexible_titan(lua_State *L")

        -- Array and Map deliberately share Table ** exact descriptors.
        assert.match("TitanVargArrayOrMap %*_varargs", array_variadic)
        assert.match("TitanVargArrayOrMap %*_varargs", map_variadic)
        assert.match("TitanVargArrayOrMap %*_flexout", array_flexible)
        assert.match("TitanVargArrayOrMap %*_flexout", map_flexible)
        assert.match("Table%* %*_varargs_args", array_variadic_entry)
        assert.match("Table%* %*_varargs_args", map_variadic_entry)

        -- Their Lua/generic adapters differ semantically: Arrays box and
        -- validate proxies; Maps remain ordinary Tables.
        assert.match("titan_array_try_backing", array_variadic_entry)
        assert.match("titan_array_require_proxy", array_variadic_entry)
        assert.not_match("titan_array_", map_variadic_entry)
        assert.match("titan_array_require_proxy", array_flexible_entry)
        assert.not_match("titan_array_", map_flexible_entry)
        assert.match("titan_array_require_proxy", call_array_variadic)
        assert.match("titan_array_try_backing", call_array_variadic)
        assert.not_match("titan_array_", call_map_variadic)
        assert.match("titan_array_require_proxy", call_array_flexible)
        assert.match("titan_array_try_backing", call_array_flexible)
        assert.not_match("titan_array_", call_map_flexible)

        -- Option(Array) shares TValue * descriptors with other boxed values,
        -- but keeps raw backing Tables inside the exact descriptors.
        assert.match("TitanVargValue %*_varargs", option_variadic)
        assert.match("TitanVargValue %*_flexout", option_flexible)
        assert.match("TValue %*_varargs_args", option_variadic_entry)
        assert.match("titan_array_try_backing", option_variadic_entry)
        assert.match("sethvalue", option_variadic_entry)
        assert.match("titan_array_require_proxy", option_variadic_entry)
        assert.match("titan_array_try_backing", option_flexible_entry)
        assert.match("titan_array_require_proxy", option_flexible_entry)
        assert.match("TitanVargValue %*_varargs", call_option_variadic)
        assert.match("titan_array_require_proxy", call_option_variadic)
        assert.match("titan_array_try_backing", call_option_variadic)
        assert.match("TitanVargValue %*_flexout", call_option_flexible)
        assert.match("titan_array_require_proxy", call_option_flexible)
        assert.match("titan_array_try_backing", call_option_flexible)

        h.run_coder(source, [[
            local a = test.make(11)
            local b = test.make(22)
            local ma = { a = 1 }
            local mb = { b = 2 }
            assert(test.exact_call(a) == a)
            local seen
            assert(test.generic_call(function(x)
                seen = x
                return x
            end, a) == a)
            assert(seen == a)

            local collected = test.collect(a, b)
            assert(type(collected) == "userdata")
            assert(#collected == 2)
            assert(collected[1] == a and collected[2] == b)

            local x, y = test.flexible(a)
            assert(x == a and y == a)
            assert(test.optional(a, true) == a)
            assert(test.optional(nil, false) == nil)

            assert(test.array_variadic(a, b) == a)
            assert(test.map_variadic(ma, mb) == ma)
            assert(test.option_variadic(a, nil) == a)
            assert(test.option_variadic(nil, a) == nil)

            local ax, ay = test.array_flexible(a)
            assert(ax == a and ay == a)
            local mx, my = test.map_flexible(ma)
            assert(mx == ma and my == ma)
            local direct_option = table.pack(test.option_flexible(a))
            assert(direct_option.n == 3)
            assert(direct_option[1] == a and direct_option[2] == nil
                and direct_option[3] == a)
            local nil_option = table.pack(test.option_flexible(nil))
            assert(nil_option.n == 3)
            assert(nil_option[1] == nil and nil_option[2] == nil
                and nil_option[3] == nil)

            local array_seen
            assert(test.call_array_variadic(function(...)
                array_seen = table.pack(...)
                return select(2, ...)
            end, a, b) == b)
            assert(array_seen.n == 2)
            assert(array_seen[1] == a and array_seen[2] == b)

            local map_seen
            assert(test.call_map_variadic(function(...)
                map_seen = table.pack(...)
                return select(2, ...)
            end, ma, mb) == mb)
            assert(map_seen.n == 2)
            assert(map_seen[1] == ma and map_seen[2] == mb)

            local option_seen
            assert(test.call_option_variadic(function(...)
                option_seen = table.pack(...)
                return select(2, ...)
            end, nil, a) == a)
            assert(option_seen.n == 2)
            assert(option_seen[1] == nil and option_seen[2] == a)

            local gax, gay = test.call_array_flexible(
                function(v) return v, b end, a)
            assert(gax == a and gay == b)
            local gmx, gmy = test.call_map_flexible(
                function(v) return v, mb end, ma)
            assert(gmx == ma and gmy == mb)
            local generic_option = table.pack(
                test.call_option_flexible(
                    function(v) return v, nil, a end, a))
            assert(generic_option.n == 3)
            assert(generic_option[1] == a and generic_option[2] == nil
                and generic_option[3] == a)
        ]])
    end)

    it("keeps collectable elements alive when an Array is their sole owner",
    function()
        h.run_coder([[
            record Owned
                n: integer
            end

            local function fresh(): string
                local s: string = ""
                local i: integer = 1
                while i <= 256 do
                    s = s .. "x"
                    i = i + 1
                end
                return s .. "!"
            end

            function retained(): (
                {string},
                {{string: integer}},
                {Owned},
                {{integer}},
                {() -> integer},
                {value}
            )
                local s: string = fresh()
                local m: {string: integer} = { ["answer"] = 42 }
                local r: Owned = Owned.new(43)
                local inner: {integer} = { 44 }
                local f: () -> integer =
                    function(): integer return 45 end
                local vr: Owned = Owned.new(46)
                local v: value = vr
                return { s }, { m }, { r }, { inner }, { f }, { v }
            end
        ]], [[
            for _, mode in ipairs({ "incremental", "generational" }) do
                collectgarbage(mode)
                local strings, maps, records, arrays, closures, values =
                    test.retained()

                -- Observe the collectable elements weakly. Their outer Array
                -- remains the only strong root once the call frame is gone.
                local weak = setmetatable({}, { __mode = "v" })
                weak[1] = maps[1]
                weak[2] = records[1]
                weak[3] = arrays[1]
                weak[4] = closures[1]
                weak[5] = values[1]

                for i = 1, 2000 do local _ = { i, i + 1 } end
                collectgarbage("collect")
                collectgarbage("collect")

                assert(#strings[1] == 257)
                assert(maps[1].answer == 42)
                assert(records[1].n == 43)
                assert(arrays[1][1] == 44)
                assert(closures[1]() == 45)
                assert(values[1].n == 46)
                assert(weak[1] == maps[1])
                assert(weak[2] == records[1])
                assert(weak[3] == arrays[1])
                assert(weak[4] == closures[1])
                assert(weak[5] == values[1])
            end
        ]])
    end)

    it("preserves Array-indexed-assignment evaluation and failure order",
    function()
        h.run_coder([[
            seen: integer = 0
            current: {value} = { 41 }
            other: {value} = { 51 }

            local function base(): {value}
                seen = seen * 10 + 1
                return current
            end

            local function index(): integer
                seen = seen * 10 + 2
                return 1
            end

            local function rhs(): value
                seen = seen * 10 + 3
                return 99
            end

            local function multi_base1(): {value}
                seen = seen * 10 + 1
                return current
            end

            local function multi_index1(): integer
                seen = seen * 10 + 2
                return 1
            end

            local function multi_base2(): {value}
                seen = seen * 10 + 3
                return other
            end

            local function multi_index2(good: boolean): integer
                seen = seen * 10 + 4
                if good then return 1 end
                return 0
            end

            local function multi_rhs1(): value
                seen = seen * 10 + 5
                return 101
            end

            local function multi_rhs2(): value
                seen = seen * 10 + 6
                return 202
            end

            local function bad_multi_rhs1(): value
                seen = seen * 10 + 5
                return 303
            end

            local function bad_multi_rhs2(): value
                seen = seen * 10 + 6
                return 404
            end

            function run(): integer
                seen = 0
                base()[index()] = rhs()
                return seen
            end

            function bad(): nil
                seen = 0
                base()[0] = rhs()
                return nil
            end

            function run_multi(): integer
                seen = 0
                multi_base1()[multi_index1()],
                    multi_base2()[multi_index2(true)] =
                    multi_rhs1(), multi_rhs2()
                return seen
            end

            function bad_multi(): nil
                seen = 0
                multi_base1()[multi_index1()],
                    multi_base2()[multi_index2(false)] =
                    bad_multi_rhs1(), bad_multi_rhs2()
                return nil
            end

            function observed(): integer
                return seen
            end

            function observed_value(): value
                return current[1]
            end

            function observed_other(): value
                return other[1]
            end
        ]], [[
            assert(test.run() == 123)
            assert(test.observed_value() == 99)
            local ok = pcall(test.bad)
            assert(not ok)
            assert(test.observed() == 13)
            assert(test.observed_value() == 99)
            assert(test.current[0] == nil)

            assert(test.run_multi() == 123456)
            assert(test.observed_value() == 101)
            assert(test.observed_other() == 202)

            local bad_multi = pcall(test.bad_multi)
            assert(not bad_multi)
            assert(test.observed() == 123456)
            -- Stores happen left to right after every lvalue and RHS has
            -- been evaluated: the first succeeds before the second rejects 0.
            assert(test.observed_value() == 303)
            assert(test.observed_other() == 202)
            assert(test.other[0] == nil)
        ]])
    end)

    it("prepares mixed multi-assignment lvalues before RHS and stores left to right",
    function()
        h.run_coder([[
            record Cell
                item: integer
            end

            seen: integer = 0
            mapping: {string: integer} = { ["slot"] = 41 }
            cell: Cell = Cell.new(51)
            array: {integer} = { 61 }

            local function map_base(): {string: integer}
                seen = seen * 10 + 1
                return mapping
            end

            local function map_key(): string
                seen = seen * 10 + 2
                return "slot"
            end

            local function record_base(): Cell
                seen = seen * 10 + 3
                return cell
            end

            local function array_base(): {integer}
                seen = seen * 10 + 4
                return array
            end

            local function array_index(good: boolean): integer
                seen = seen * 10 + 5
                if good then return 1 end
                return 0
            end

            local function rhs1(v: integer): integer
                seen = seen * 10 + 6
                return v
            end

            local function rhs2(v: integer): integer
                seen = seen * 10 + 7
                return v
            end

            local function rhs3(v: integer): integer
                seen = seen * 10 + 8
                return v
            end

            local function single_map_rhs(v: integer): integer
                seen = seen * 10 + 3
                return v
            end

            local function single_record_rhs(v: integer): integer
                seen = seen * 10 + 4
                return v
            end

            function run_single_map(): integer
                seen = 0
                map_base()[map_key()] = single_map_rhs(707)
                return seen
            end

            function run_single_record(): integer
                seen = 0
                record_base().item = single_record_rhs(808)
                return seen
            end

            function run_mixed(): integer
                seen = 0
                map_base()[map_key()], record_base().item,
                    array_base()[array_index(true)] =
                    rhs1(101), rhs2(202), rhs3(303)
                return seen
            end

            function fail_mixed(): nil
                seen = 0
                map_base()[map_key()], record_base().item,
                    array_base()[array_index(false)] =
                    rhs1(404), rhs2(505), rhs3(606)
                return nil
            end

            function map_value(): integer
                return mapping["slot"]
            end

            function record_value(): integer
                return cell.item
            end

            function array_value(): integer
                return array[1]
            end

            function observed(): integer
                return seen
            end
        ]], [[
            -- Every effectful target operand is evaluated in lexical LHS
            -- order before any RHS expression.
            assert(test.run_mixed() == 12345678)
            assert(test.map_value() == 101)
            assert(test.record_value() == 202)
            assert(test.array_value() == 303)

            local ok, err = pcall(test.fail_mixed)
            assert(not ok)
            assert(tostring(err):find(
                "array index must be positive", 1, true), tostring(err))
            assert(test.observed() == 12345678)

            -- Stores proceed left to right after all target and RHS
            -- evaluation. The Map and record stores therefore commit before
            -- the later Array target rejects zero; the Array remains intact.
            assert(test.map_value() == 404)
            assert(test.record_value() == 505)
            assert(test.array_value() == 303)
            assert(test.array[0] == nil)

            -- Single assignments use the same target-preparation path: the
            -- complete Map target and record receiver precede their RHS.
            assert(test.run_single_map() == 123)
            assert(test.map_value() == 707)
            assert(test.run_single_record() == 34)
            assert(test.record_value() == 808)
        ]])
    end)

    it("passes only positive user arguments to standalone main", function()
        local source = [[
            function main(args: {string}): integer
                if args[0] then return 11 end
                if args[-1] then return 12 end
                if #args == 0 then return 0 end
                if #args ~= 2 then return 10 end
                if args[1] ~= "one" then return 13 end
                if args[2] ~= "two" then return 14 end
                return 0
            end
        ]]
        h.reset(true)
        local ast, perr = h.parse(source, "dense_array_args.titan")
        assert.truthy(ast, perr)
        local _, errors = checker.check(
            "dense_array_args", ast, source, "dense_array_args.titan")
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local ok, err = h.compile_app("dense_array_args", ast)
        assert.truthy(ok, err)

        local entrypoint_file = assert(io.open(
            "dense_array_args__entrypoint.c", "r"))
        local entrypoint = entrypoint_file:read("*a"):gsub("%s+", " ")
        entrypoint_file:close()
        assert.match(
            "static int titan_main_string_array_writer" ..
            "%(lua_State %*L%)", entrypoint)
        assert.match(
            "if %(lua_type%(L, 1%) != LUA_TSTRING%)", entrypoint)
        assert.match(
            "lua_pushcclosure%(L, titan_main_string_array_writer, 1%);",
            entrypoint)
        assert.match("writer = lua_totvalue%(L, %-1%);", entrypoint)
        assert.match("lua_pushnil%(L%); /%* traced constructor result slot %*/",
            entrypoint)
        assert.match(
            "arguments = titan_array_new%(%s*" ..
            "L, array_metatable, nargs, &writer, L%->top%.p %- 1%);",
            entrypoint)
        assert.match(
            "lua_remove%(L, %-2%); /%* discard writer, keep backing %*/",
            entrypoint)

        local empty, empty_why, empty_status =
            h.call_app("./dense_array_args")
        assert.truthy(empty, empty_why)
        assert.equal(0, empty_status)
        -- call_app removes the executable after each run, so relink the same
        -- checked program before exercising the nonempty branch.
        local relinked, relink_err =
            h.compile_app("dense_array_args", ast)
        assert.truthy(relinked, relink_err)
        local ran, why, status = h.call_app(
            "./dense_array_args", "one", "two")
        assert.truthy(ran, why)
        assert.equal(0, status)
    end)

    it("keeps the standalone argument Array's string writer active", function()
        with_header([[
            #include <lua.h>
            typedef struct TValue TValue;

            static void titan_test_write_integer(
                    lua_State *L, TValue array) {
                lua_pushtvalue(L, array);
                lua_pushinteger(L, 17);
                lua_seti(L, -2, 1);
                lua_pop(L, 1);
            }

            static void titan_test_write_string(
                    lua_State *L, TValue array) {
                lua_pushtvalue(L, array);
                lua_pushstring(L, "written through the carried writer");
                lua_seti(L, -2, 1);
                lua_pop(L, 1);
            }
        ]], function(header)
            h.run_coder_app(
                'local c = foreign import "' .. header .. '"',
                [[
                    local rejected = false
                    do
                        c.titan_test_write_integer(L, args)
                    catch
                        rejected = true
                    end
                    if not rejected or #args ~= 0 then return 1 end

                    c.titan_test_write_string(L, args)
                    if #args ~= 1 then return 2 end
                    if args[1] ~= "written through the carried writer" then
                        return 3
                    end
                    return 0
                ]], 0)
        end)
    end)

    it("uses distinct const tags and lowers copy and linear freeze casts",
    function()
        local source = [[
            function mutable_with_inner(): {value}
                local inner: {integer} = { 7 }
                return { 1, inner, nil, 4 }
            end

            function copied(source: {value}): const {value}
                return source as const {value}
            end

            function linear(): const {value}
                local linear_value: {value} = { 5, nil, 6 }
                return linear_value as const {value}
            end

            local function increment(number: integer): integer
                return number + 1
            end

            function builder(count: integer): const {integer}
                local items: {integer} = {}
                for index = 1, count do
                    items[#items + 1] = increment(index)
                end
                local delta = count - count
                local unrelated: () -> integer = function(): integer
                    return delta
                end
                if #items ~= count + unrelated() then
                    raise "builder length mismatch"
                end
                return items as const {integer}
            end

            function direct(): const {value}
                return { 8, nil, 9 }
            end

            function admitted(source: {value}): boolean
                return source is const {value}
            end

            function mutable_as_value(source: {value}): value
                return source
            end

            function const_as_value(source: const {value}): value
                return source
            end

            function mutable_from_value(source: value): {value}
                return source as {value}
            end

            function const_from_value(source: value): const {value}
                return source as const {value}
            end
        ]]
        local csrc = generate(source)
        local copied = generated_function(
            csrc, "test_\\u2133_copied_titan(lua_State *L")
        local linear = generated_function(
            csrc, "test_\\u2133_linear_titan(lua_State *L")
        local builder = generated_function(
            csrc, "test_\\u2133_builder_titan(lua_State *L")
        local direct = generated_function(
            csrc, "test_\\u2133_direct_titan(lua_State *L")
        local admitted = generated_function(
            csrc, "test_\\u2133_admitted_titan(lua_State *L")

        assert.match("titan_array_shallow_copy", copied)
        assert.not_match("titan_array_freeze", copied)
        assert.match("titan_array_freeze", linear)
        assert.not_match("titan_array_shallow_copy", linear)
        assert.match("titan_array_freeze", builder)
        assert.not_match("titan_array_shallow_copy", builder)
        assert.match("titan_const_array_new", direct)
        assert.not_match("titan_array_new", direct)
        assert.not_match("titan_array_shallow_copy", admitted)
        assert.not_match("titan_array_freeze", admitted)
        assert.match("titan_array_metatables", csrc)
        assert.match("_const_array_metatable", csrc)

        h.run_coder(source, [[
            local function fails(f)
                local ok = pcall(f)
                assert(not ok)
            end

            local mutable = test.mutable_with_inner()
            local copied = test.copied(mutable)
            assert(getmetatable(mutable) == "Titan array metatable")
            assert(getmetatable(copied) == "Titan const array metatable")
            assert(copied ~= mutable)
            assert(#copied == 4 and copied[3] == nil)
            assert(copied[1] == 1 and copied[4] == 4)
            assert(copied[2] == mutable[2])
            mutable[1] = 11
            assert(mutable[1] == 11 and copied[1] == 1)
            mutable[2][1] = 12
            assert(copied[2][1] == 12)
            fails(function() copied[1] = 13 end)

            local linear = test.linear()
            local builder = test.builder(3)
            local direct = test.direct()
            assert(getmetatable(linear) == "Titan const array metatable")
            assert(getmetatable(builder) == "Titan const array metatable")
            assert(getmetatable(direct) == "Titan const array metatable")
            fails(function() linear[1] = 14 end)
            assert(#builder == 3)
            assert(builder[1] == 2 and builder[2] == 3
                   and builder[3] == 4)
            fails(function() builder[1] = 15 end)
            fails(function() direct[1] = 15 end)
            assert(test.admitted(mutable))

            assert(test.const_from_value(
                test.const_as_value(copied)) == copied)
            assert(test.mutable_from_value(
                test.mutable_as_value(mutable)) == mutable)
            fails(function()
                return test.mutable_from_value(
                    test.const_as_value(copied))
            end)
            fails(function()
                return test.const_from_value(
                    test.mutable_as_value(mutable))
            end)
        ]])
    end)
end)
