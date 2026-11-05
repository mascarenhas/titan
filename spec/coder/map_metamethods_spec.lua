-- End-to-end regressions for Lua-compatible Map metamethod lowering. Map
-- operations keep their specialized luaH_* fast paths, entering the VM's
-- finish helpers only when a metatable can affect the result.
local h = require "spec.support.helpers"

local csrc

local function clean_module(name)
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".dll", ".dll.def", ".dylib", ".a",
        ".ffi.h", ".titan.h",
    }) do
        os.remove(name .. suffix)
    end
    os.execute("rm -rf " .. name .. ".so.dSYM " .. name .. ".dylib.dSYM")
end

local function clean()
    clean_module("test")
end

local function generated_function(source, marker)
    local search = 1
    while true do
        local start = assert(source:find(marker, search, true),
            "generated C function not found: " .. marker)
        local line_end = source:find("\n", start, true) or (#source + 1)
        local brace = source:find("{", start, true)
        if brace and brace < line_end then
            local depth = 0
            for i = brace, #source do
                local byte = source:sub(i, i)
                if byte == "{" then
                    depth = depth + 1
                elseif byte == "}" then
                    depth = depth - 1
                    if depth == 0 then return source:sub(start, i) end
                end
            end
            error("unterminated generated C function: " .. marker)
        end
        search = line_end + 1
    end
end

local fixture = [[
    order: integer = 0

    function mark(digit: integer): nil
        order = order * 10 + digit
        return nil
    end

    function read_string(map: {string: integer}, key: string): integer
        return map[key]
    end

    function read_integer(map: {integer: integer}, key: integer): integer
        return map[key]
    end

    function read_float(map: {float: integer}, key: float): integer
        return map[key]
    end

    function read_value(map: {value: integer}, key: value): integer
        return map[key]
    end

    function read_any(map: {string: value}, key: string): value
        return map[key]
    end

    function write_string(
        map: {string: integer}, key: string, item: integer
    ): nil
        map[key] = item
        return nil
    end

    function write_integer(
        map: {integer: integer}, key: integer, item: integer
    ): nil
        map[key] = item
        return nil
    end

    function write_float(
        map: {float: integer}, key: float, item: integer
    ): nil
        map[key] = item
        return nil
    end

    function write_value(
        map: {value: integer}, key: value, item: integer
    ): nil
        map[key] = item
        return nil
    end

    function write_any(map: {string: value}, key: string, item: value): nil
        map[key] = item
        return nil
    end

    function construct(): {string: integer}
        return { ["one"] = 1 }
    end

    function map_length(map: {integer: value}): integer
        return #map
    end

    function maps_equal(
        left: {string: integer}, right: {string: integer}
    ): boolean
        return left == right
    end

    function maps_unequal(
        left: {string: integer}, right: {string: integer}
    ): boolean
        return left ~= right
    end

    function map_value_equal(left: {string: integer}, right: value): boolean
        return left == right
    end

    function map_value_unequal(
        left: {string: integer}, right: value
    ): boolean
        return left ~= right
    end

    function value_map_equal(left: value, right: {string: integer}): boolean
        return left == right
    end

    function value_map_unequal(
        left: value, right: {string: integer}
    ): boolean
        return left ~= right
    end

    function values_equal(left: value, right: value): boolean
        return left == right
    end

    function values_unequal(left: value, right: value): boolean
        return left ~= right
    end

    function arrays_equal(left: {integer}, right: {integer}): boolean
        return left == right
    end

    function make_array(): {integer}
        return { 1 }
    end

    local function read_map_operand(
        map: {string: integer}
    ): {string: integer}
        mark(1)
        return map
    end

    local function read_key_operand(key: string): string
        mark(2)
        return key
    end

    function ordered_read(map: {string: integer}, key: string): integer
        order = 0
        local item = read_map_operand(map)[read_key_operand(key)]
        return order + item - item
    end

    local function write_map_operand(
        map: {string: integer}
    ): {string: integer}
        mark(1)
        return map
    end

    local function write_key_operand(key: string): string
        mark(2)
        return key
    end

    local function write_item_operand(item: integer): integer
        mark(3)
        return item
    end

    function ordered_write(
        map: {string: integer}, key: string, item: integer
    ): integer
        order = 0
        write_map_operand(map)[write_key_operand(key)] =
            write_item_operand(item)
        return order
    end

    local function equal_left_operand(
        map: {string: integer}
    ): {string: integer}
        mark(1)
        return map
    end

    local function equal_right_operand(
        map: {string: integer}
    ): {string: integer}
        mark(2)
        return map
    end

    function ordered_equal(
        left: {string: integer}, right: {string: integer}
    ): integer
        order = 0
        if equal_left_operand(left) == equal_right_operand(right) then
            return order
        else
            return -order
        end
    end

    local function length_map_operand(
        map: {integer: value}
    ): {integer: value}
        mark(1)
        return map
    end

    function ordered_length(map: {integer: value}): integer
        order = 0
        local size = #length_map_operand(map)
        return order + size - size
    end

    function stack_read(map: {string: string}, keep: string): string
        local item = map["missing"]
        return keep .. ":" .. item .. ":" .. keep
    end

    function stack_write(map: {string: string}, keep: string): string
        map["missing"] = keep
        return keep .. ":" .. keep
    end

    function stack_length(map: {integer: value}, keep: string): string
        local size = #map
        return keep .. ":" .. size .. ":" .. keep
    end

    function stack_equal(
        left: {string: integer}, right: {string: integer}, keep: string
    ): string
        local middle = ":different:"
        if left == right then
            middle = ":equal:"
        end
        return keep .. middle .. keep
    end
]]

describe("Map metamethod-aware code generation", function()
    setup(function()
        clean()
        csrc = h.compile_and_read_c(fixture)
    end)

    teardown(clean)

    it("preserves specialized access fast paths and isolates VM slow paths",
    function()
        local read_string = generated_function(
            csrc, "test_\\u2133_read_string_titan(lua_State *L")
        local read_integer = generated_function(
            csrc, "test_\\u2133_read_integer_titan(lua_State *L")
        local read_float = generated_function(
            csrc, "test_\\u2133_read_float_titan(lua_State *L")
        local read_value = generated_function(
            csrc, "test_\\u2133_read_value_titan(lua_State *L")
        local write_string = generated_function(
            csrc, "test_\\u2133_write_string_titan(lua_State *L")
        local write_integer = generated_function(
            csrc, "test_\\u2133_write_integer_titan(lua_State *L")
        local write_float = generated_function(
            csrc, "test_\\u2133_write_float_titan(lua_State *L")
        local write_value = generated_function(
            csrc, "test_\\u2133_write_value_titan(lua_State *L")
        local construct = generated_function(
            csrc, "test_\\u2133_construct_titan(lua_State *L")
        local map_length = generated_function(
            csrc, "test_\\u2133_map_length_titan(lua_State *L")

        assert.match("luaH_getshortstr", read_string)
        assert.match("luaH_getint", read_integer)
        assert.match("luaV_tointeger", read_float)
        assert.match("luaH_getint", read_float)
        assert.match("luaH_get%(", read_float)
        assert.match("luaH_get%(", read_value)

        for _, body in ipairs({
            read_string, read_integer, read_float, read_value,
        }) do
            local raw = assert(body:find("luaH_get", 1, true))
            local finish = assert(body:find("luaV_finishget", 1, true))
            assert.is_true(raw < finish)
            assert.match("TITAN_LIKELY%([^\n]*metatable", body)
            assert.match("checknoTM%([^\n]*TM_INDEX", body)
            assert.falsy(body:find("lua_gettable", 1, true))
        end

        local writes = {
            { body = write_string,
              raw = "luaH_set(L", partial = "luaH_pset" },
            { body = write_integer,
              raw = "luaH_setint(L", partial = "luaH_fastseti" },
            { body = write_float,
              raw = "luaH_setint(L", partial = "luaH_fastseti" },
            { body = write_value,
              raw = "luaH_set(L", partial = "luaH_pset" },
        }
        assert.match("luaV_tointeger", write_float)
        assert.match("luaH_pset", write_float)
        for _, case in ipairs(writes) do
            local check = assert(case.body:find("checknoTM", 1, true))
            local raw = assert(case.body:find(case.raw, check, true))
            local partial = assert(
                case.body:find(case.partial, raw + 1, true))
            local finish = assert(
                case.body:find("luaV_finishset", partial, true))
            assert.is_true(check < raw)
            assert.is_true(raw < partial)
            assert.is_true(partial < finish)
            assert.match("TITAN_LIKELY%([^\n]*metatable", case.body)
            assert.match("checknoTM%([^\n]*TM_NEWINDEX", case.body)
            assert.falsy(case.body:find("lua_settable", 1, true))
        end

        -- A newly allocated literal has no metatable, so construction remains
        -- a raw store and never enters assignment's partial/finish protocol.
        assert.match("luaH_set%(", construct)
        assert.not_match("luaH_pset", construct)
        assert.not_match("luaH_fastseti", construct)
        assert.not_match("luaV_finishset", construct)
        assert.falsy(construct:find("lua_settable", 1, true))

        local no_length_metamethod = assert(
            map_length:find("checknoTM", 1, true))
        local raw_length = assert(map_length:find("luaH_getn", 1, true))
        local metamethod_length = assert(
            map_length:find("luaV_objlen", raw_length, true))
        assert.is_true(no_length_metamethod < raw_length)
        assert.is_true(raw_length < metamethod_length)
        assert.truthy(map_length:find("TM_LEN", 1, true))
        assert.truthy(map_length:find(
            "ttisinteger", metamethod_length, true))
        assert.truthy(map_length:find(
            "_base = restorestack", metamethod_length, true))
        assert.falsy(map_length:find("lua_len", 1, true))
        assert.falsy(map_length:find("lua_rawlen", 1, true))
    end)

    it("follows __index functions, tables, recursive values, and key paths",
    function()
        local ok, err = h.call("test", [[
            local calls = 0
            local direct = setmetatable({ hit = 10 }, {
                __index = function(_, key)
                    calls = calls + 1
                    assert(key == "missing")
                    return 20
                end,
            })
            assert(test.read_string(direct, "hit") == 10)
            assert(calls == 0)
            assert(test.read_string(direct, "missing") == 20)
            assert(calls == 1)

            local redirected = setmetatable({}, {
                __index = { answer = 30 },
            })
            assert(test.read_string(redirected, "answer") == 30)

            local tail = setmetatable({}, {
                __index = function(_, key)
                    assert(key == "deep")
                    return 40
                end,
            })
            local middle = setmetatable({}, { __index = tail })
            local head = setmetatable({}, { __index = middle })
            assert(test.read_string(head, "deep") == 40)

            local proxy = assert(io.tmpfile())
            local oldmeta = debug.getmetatable(proxy)
            debug.setmetatable(proxy, {
                __index = function(_, key)
                    assert(key == "userdata")
                    return 50
                end,
            })
            local through_value = setmetatable({}, { __index = proxy })
            assert(test.read_string(through_value, "userdata") == 50)
            debug.setmetatable(proxy, oldmeta)
            proxy:close()

            local long = string.rep("long-key-", 20)
            local by_string = setmetatable({}, {
                __index = function(_, key)
                    assert(key == long)
                    return 61
                end,
            })
            assert(test.read_string(by_string, long) == 61)

            local by_integer = setmetatable({}, {
                __index = function(_, key)
                    assert(math.type(key) == "integer" and key == 7)
                    return 62
                end,
            })
            assert(test.read_integer(by_integer, 7) == 62)

            local float_keys = {}
            local by_float = setmetatable({}, {
                __index = function(_, key)
                    float_keys[#float_keys + 1] = key
                    return #float_keys == 1 and 63 or 64
                end,
            })
            assert(test.read_float(by_float, 8.0) == 63)
            assert(test.read_float(by_float, 2.5) == 64)
            assert(float_keys[1] == 8.0 and float_keys[2] == 2.5)
            assert(math.type(float_keys[1]) == "float")
            assert(math.type(float_keys[2]) == "float")

            local sentinel = {}
            local by_value = setmetatable({}, {
                __index = function(_, key)
                    assert(rawequal(key, sentinel))
                    return 65
                end,
            })
            assert(test.read_value(by_value, sentinel) == 65)

            assert(test.read_any({}, "absent") == nil)

            local bad = setmetatable({}, {
                __index = function() error("read metamethod exploded") end,
            })
            local success, message = pcall(test.read_string, bad, "x")
            assert(not success and message:find(
                "read metamethod exploded", 1, true))

            local first, second = {}, {}
            setmetatable(first, { __index = second })
            setmetatable(second, { __index = first })
            success, message = pcall(test.read_string, first, "loop")
            assert(not success and message:find("chain too long", 1, true))

            local wrong_float = setmetatable({}, {
                __index = function() return 7.0 end,
            })
            success, message = pcall(
                test.read_string, wrong_float, "wrong")
            assert(not success and message:find(
                "expected integer tag but found number", 1, true))

            local wrong_string = setmetatable({}, {
                __index = function() return "seven" end,
            })
            success, message = pcall(
                test.read_string, wrong_string, "wrong")
            assert(not success and message:find(
                "expected integer tag but found string", 1, true))
        ]])
        assert.truthy(ok, err)
    end)

    it("follows __newindex functions, tables, recursive values, and key paths",
    function()
        local ok, err = h.call("test", [[
            local calls, sink = 0, {}
            local direct = setmetatable({ hit = 10 }, {
                __newindex = function(_, key, value)
                    calls = calls + 1
                    sink[key] = value
                end,
            })
            test.write_string(direct, "hit", 11)
            assert(direct.hit == 11 and calls == 0)
            test.write_string(direct, "missing", 20)
            assert(rawget(direct, "missing") == nil)
            assert(sink.missing == 20 and calls == 1)

            local redirected_target = {}
            local redirected = setmetatable({}, {
                __newindex = redirected_target,
            })
            test.write_string(redirected, "answer", 30)
            assert(rawget(redirected, "answer") == nil)
            assert(redirected_target.answer == 30)

            local recursive_target = {}
            local tail = setmetatable({}, { __newindex = recursive_target })
            local middle = setmetatable({}, { __newindex = tail })
            local head = setmetatable({}, { __newindex = middle })
            test.write_string(head, "deep", 40)
            assert(recursive_target.deep == 40)
            assert(rawget(head, "deep") == nil)

            local proxy = assert(io.tmpfile())
            local oldmeta = debug.getmetatable(proxy)
            local proxy_sink = {}
            debug.setmetatable(proxy, {
                __newindex = function(_, key, value)
                    proxy_sink[key] = value
                end,
            })
            local through_value = setmetatable({}, { __newindex = proxy })
            test.write_string(through_value, "userdata", 50)
            assert(proxy_sink.userdata == 50)
            debug.setmetatable(proxy, oldmeta)
            proxy:close()

            local long = string.rep("long-key-", 20)
            local written = {}
            local by_string = setmetatable({}, {
                __newindex = function(_, key, value)
                    written.string_key, written.string_value = key, value
                end,
            })
            test.write_string(by_string, long, 61)
            assert(written.string_key == long and written.string_value == 61)

            local by_integer = setmetatable({}, {
                __newindex = function(_, key, value)
                    written.integer_key, written.integer_value = key, value
                end,
            })
            test.write_integer(by_integer, 7, 62)
            assert(math.type(written.integer_key) == "integer")
            assert(written.integer_key == 7 and written.integer_value == 62)

            local integer_calls = 0
            local integer_existing = {}
            for i = 1, 8 do integer_existing[i] = i end
            setmetatable(integer_existing, {
                __newindex = function() integer_calls = integer_calls + 1 end,
            })
            test.write_integer(integer_existing, 7, 70)
            assert(integer_existing[7] == 70 and integer_calls == 0)

            local float_keys = {}
            local by_float = setmetatable({}, {
                __newindex = function(_, key, value)
                    float_keys[#float_keys + 1] = { key, value }
                end,
            })
            test.write_float(by_float, 8.0, 63)
            test.write_float(by_float, 2.5, 64)
            assert(float_keys[1][1] == 8.0 and float_keys[1][2] == 63)
            assert(float_keys[2][1] == 2.5 and float_keys[2][2] == 64)
            assert(math.type(float_keys[1][1]) == "float")
            assert(math.type(float_keys[2][1]) == "float")

            local float_calls = 0
            local float_existing = {}
            for i = 1, 8 do float_existing[i] = i end
            float_existing[2.5] = 1
            setmetatable(float_existing, {
                __newindex = function() float_calls = float_calls + 1 end,
            })
            test.write_float(float_existing, 7.0, 71)
            test.write_float(float_existing, 2.5, 25)
            assert(float_existing[7] == 71 and float_existing[2.5] == 25)
            assert(float_calls == 0)

            local sentinel = {}
            local by_value = setmetatable({}, {
                __newindex = function(_, key, value)
                    assert(rawequal(key, sentinel) and value == 65)
                    written.value_key = true
                end,
            })
            test.write_value(by_value, sentinel, 65)
            assert(written.value_key)

            local value_calls = 0
            local value_existing = { [sentinel] = 1 }
            setmetatable(value_existing, {
                __newindex = function() value_calls = value_calls + 1 end,
            })
            test.write_value(value_existing, sentinel, 66)
            assert(value_existing[sentinel] == 66 and value_calls == 0)

            local nil_calls, nil_value = 0, "not called"
            local nil_map = setmetatable({ existing = 1 }, {
                __newindex = function(_, key, value)
                    nil_calls = nil_calls + 1
                    assert(key == "missing")
                    nil_value = value
                end,
            })
            test.write_any(nil_map, "existing", nil)
            assert(rawget(nil_map, "existing") == nil and nil_calls == 0)
            test.write_any(nil_map, "missing", nil)
            assert(nil_calls == 1 and nil_value == nil)

            local bad = setmetatable({}, {
                __newindex = function()
                    error("write metamethod exploded")
                end,
            })
            local success, message = pcall(
                test.write_string, bad, "x", 1)
            assert(not success and message:find(
                "write metamethod exploded", 1, true))

            local first, second = {}, {}
            setmetatable(first, { __newindex = second })
            setmetatable(second, { __newindex = first })
            success, message = pcall(test.write_string, first, "loop", 1)
            assert(not success and message:find("chain too long", 1, true))
        ]])
        assert.truthy(ok, err)
    end)

    it("limits __eq to comparisons with a statically typed Map operand",
    function()
        local ok, err = h.call("test", [[
            local calls = 0
            local same = setmetatable({}, {
                __eq = function()
                    calls = calls + 1
                    return false
                end,
            })
            assert(test.maps_equal(same, same))
            assert(not test.maps_unequal(same, same))
            assert(calls == 0)

            local chosen
            local left = setmetatable({}, {
                __eq = function()
                    chosen = "left"
                    return "truthy"
                end,
            })
            local right = setmetatable({}, {
                __eq = function()
                    chosen = "right"
                    return false
                end,
            })
            assert(test.maps_equal(left, right))
            assert(not test.maps_unequal(left, right))
            assert(chosen == "left")

            chosen = nil
            local no_left = setmetatable({}, {})
            local right_only = setmetatable({}, {
                __eq = function()
                    chosen = "right"
                    return true
                end,
            })
            assert(test.maps_equal(no_left, right_only))
            assert(chosen == "right")

            local no_meta_left, no_meta_right = {}, {}
            assert(not test.maps_equal(no_meta_left, no_meta_right))
            assert(test.maps_unequal(no_meta_left, no_meta_right))

            local false_calls = 0
            local false_left = setmetatable({}, {
                __eq = function()
                    false_calls = false_calls + 1
                    return false
                end,
            })
            assert(not test.maps_equal(false_left, {}))
            assert(test.maps_unequal(false_left, {}))
            assert(false_calls == 2)

            local callable_calls = 0
            local callable = setmetatable({}, {
                __call = function(_, a, b)
                    callable_calls = callable_calls + 1
                    assert(not rawequal(a, b))
                    return true
                end,
            })
            local callable_left = setmetatable({}, { __eq = callable })
            assert(test.maps_equal(callable_left, {}))
            assert(callable_calls == 1)

            local map_value_left = setmetatable({}, {
                __eq = function() return true end,
            })
            assert(test.map_value_equal(map_value_left, {}))
            assert(not test.map_value_unequal(map_value_left, {}))

            local value_map_left = setmetatable({}, {
                __eq = function() return true end,
            })
            assert(test.value_map_equal(value_map_left, {}))
            assert(not test.value_map_unequal(value_map_left, {}))

            calls = 0
            local boxed_same = setmetatable({}, {
                __eq = function()
                    calls = calls + 1
                    return false
                end,
            })
            assert(test.map_value_equal(boxed_same, boxed_same))
            assert(not test.map_value_unequal(boxed_same, boxed_same))
            assert(test.value_map_equal(boxed_same, boxed_same))
            assert(not test.value_map_unequal(boxed_same, boxed_same))
            assert(calls == 0)

            calls = 0
            local table_against_scalar = setmetatable({}, {
                __eq = function()
                    calls = calls + 1
                    return true
                end,
            })
            assert(not test.map_value_equal(
                table_against_scalar, "not a table"))
            assert(test.map_value_unequal(
                table_against_scalar, "not a table"))
            assert(not test.value_map_equal(
                "not a table", table_against_scalar))
            assert(test.value_map_unequal(
                "not a table", table_against_scalar))
            assert(calls == 0)

            -- value/value remains deliberately raw even when both runtime
            -- values are tables with an __eq metamethod.
            calls = 0
            local raw_left = setmetatable({}, {
                __eq = function()
                    calls = calls + 1
                    return true
                end,
            })
            local raw_right = {}
            assert(not test.values_equal(raw_left, raw_right))
            assert(test.values_unequal(raw_left, raw_right))
            assert(test.values_equal(raw_left, raw_left))
            assert(not test.values_unequal(raw_left, raw_left))
            assert(calls == 0)

            local array_left = test.make_array()
            local array_right = test.make_array()
            assert(test.arrays_equal(array_left, array_left))
            assert(not test.arrays_equal(array_left, array_right))

            local bad = setmetatable({}, {
                __eq = function() error("equality metamethod exploded") end,
            })
            local success, message = pcall(test.maps_equal, bad, {})
            assert(not success and message:find(
                "equality metamethod exploded", 1, true))
        ]])
        assert.truthy(ok, err)

        local maps_equal = generated_function(
            csrc, "test_\\u2133_maps_equal_titan(lua_State *L")
        local map_value_equal = generated_function(
            csrc, "test_\\u2133_map_value_equal_titan(lua_State *L")
        local values_equal = generated_function(
            csrc, "test_\\u2133_values_equal_titan(lua_State *L")
        local arrays_equal = generated_function(
            csrc, "test_\\u2133_arrays_equal_titan(lua_State *L")

        assert.match("luaV_equalobj", maps_equal)
        assert.match("luaV_rawequalobj", map_value_equal)
        assert.match("luaV_equalobj", map_value_equal)
        assert.match("luaV_rawequalobj", values_equal)
        assert.not_match("luaV_equalobj%(", values_equal)
        assert.not_match("luaV_equalobj", arrays_equal)

        local identity = assert(maps_equal:find(" == ", 1, true))
        local no_metamethod = assert(
            maps_equal:find("checknoTM", identity, true))
        assert.truthy(maps_equal:find("TM_EQ", no_metamethod, true))
        local slow_equal = assert(
            maps_equal:find("luaV_equalobj", no_metamethod, true))
        assert.is_true(identity < no_metamethod)
        assert.is_true(no_metamethod < slow_equal)

        local raw_equal = assert(
            map_value_equal:find("luaV_rawequalobj", 1, true))
        local tables_only = assert(
            map_value_equal:find("ttistable", raw_equal, true))
        no_metamethod = assert(
            map_value_equal:find("checknoTM", tables_only, true))
        assert.truthy(map_value_equal:find("TM_EQ", no_metamethod, true))
        slow_equal = assert(
            map_value_equal:find("luaV_equalobj", no_metamethod, true))
        assert.is_true(raw_equal < tables_only)
        assert.is_true(tables_only < no_metamethod)
        assert.is_true(no_metamethod < slow_equal)
    end)

    it("uses __len for integer-keyed Maps and strictly checks its result",
    function()
        local ok, err = h.call("test", [[
            local plain = { 10, 20, 30 }
            assert(test.map_length(plain) == 3)

            local calls = 0
            local with_len
            with_len = setmetatable({ 10, 20 }, {
                __len = function(object)
                    calls = calls + 1
                    assert(rawequal(object, with_len))
                    return 999, "ignored"
                end,
            })
            assert(test.map_length(with_len) == 999)
            assert(calls == 1)

            local cached_absence = setmetatable({ 10, 20 }, {})
            assert(test.map_length(cached_absence) == 2)
            assert(test.map_length(cached_absence) == 2)

            local callable_calls = 0
            local callable_map
            local callable = setmetatable({}, {
                __call = function(_, object)
                    callable_calls = callable_calls + 1
                    assert(rawequal(object, callable_map))
                    return 77
                end,
            })
            callable_map = setmetatable({ 10 }, { __len = callable })
            assert(test.map_length(callable_map) == 77)
            assert(callable_calls == 1)

            local bad_float = setmetatable({}, {
                __len = function() return 7.0 end,
            })
            local success, message = pcall(test.map_length, bad_float)
            assert(not success and message:find(
                "expected integer tag but found number", 1, true))

            local bad_string = setmetatable({}, {
                __len = function() return "seven" end,
            })
            success, message = pcall(test.map_length, bad_string)
            assert(not success and message:find(
                "expected integer tag but found string", 1, true))

            local bad = setmetatable({}, {
                __len = function() error("length metamethod exploded") end,
            })
            success, message = pcall(test.map_length, bad)
            assert(not success and message:find(
                "length metamethod exploded", 1, true))
        ]])
        assert.truthy(ok, err)
    end)

    it("evaluates operands once in order and restores relocated stack roots",
    function()
        local ok, err = h.call("test", [[
            local read = setmetatable({}, {
                __index = function()
                    test.mark(3)
                    return 7
                end,
            })
            assert(test.ordered_read(read, "missing") == 123)

            local write = setmetatable({}, {
                __newindex = function(_, key, value)
                    test.mark(4)
                    assert(key == "missing" and value == 7)
                end,
            })
            assert(test.ordered_write(write, "missing", 7) == 1234)

            local left = setmetatable({}, {
                __eq = function()
                    test.mark(3)
                    return true
                end,
            })
            assert(test.ordered_equal(left, {}) == 123)

            local length = setmetatable({}, {
                __len = function()
                    test.mark(2)
                    return 7
                end,
            })
            assert(test.ordered_length(length) == 12)

            local names, values = {}, {}
            for i = 1, 190 do
                names[i] = "slot" .. i
                values[i] = tostring(i)
            end
            local grow = assert(load(
                "return function() local " .. table.concat(names, ",") ..
                " = " .. table.concat(values, ",") ..
                "; return slot190 end"))()

            local read_grow = setmetatable({}, {
                __index = function()
                    assert(grow() == 190)
                    return "tail"
                end,
            })
            assert(test.stack_read(read_grow, "rooted") ==
                "rooted:tail:rooted")

            local write_sink = {}
            local write_grow = setmetatable({}, {
                __newindex = function(_, key, value)
                    assert(grow() == 190)
                    write_sink[key] = value
                end,
            })
            assert(test.stack_write(write_grow, "rooted") ==
                "rooted:rooted")
            assert(write_sink.missing == "rooted")

            local equal_grow = setmetatable({}, {
                __eq = function()
                    assert(grow() == 190)
                    return true
                end,
            })
            assert(test.stack_equal(equal_grow, {}, "rooted") ==
                "rooted:equal:rooted")

            local length_grow = setmetatable({}, {
                __len = function()
                    assert(grow() == 190)
                    return 17
                end,
            })
            assert(test.stack_length(length_grow, "rooted") ==
                "rooted:17:rooted")
        ]])
        assert.truthy(ok, err)
    end)
end)

describe("module initializer implicit Map call exposure", function()
    local provider = "map_initializer_implicit_provider"
    local consumer = "map_initializer_implicit_consumer"
    local provider_source = [[
        registry: {value: value} = {}
        integers: {integer: value} = {}
        maybe_registry: ({value: value})? = ({} as {value: value})
        maybe_integers: ({integer: value})? = ({} as {integer: value})
        dynamic: value = ({} as {value: value})
        callable: value = ({} as {value: value})
    ]]
    local declarations = [[
        local dep = import "map_initializer_implicit_provider"
        local seed: integer?
        record Box number: integer end
        function Box:read(): integer return seed end
    ]]

    after_each(function()
        clean_module(provider)
        clean_module(consumer)
    end)

    local cases = {
        {
            name = "__index keys",
            initializer = "result: integer = dep.registry[Box(1):read]",
            metatable = [[
                __index = function(_, key) return key() end,
            ]],
        },
        {
            name = "__eq operands",
            initializer = [[
                result = dep.registry ==
                    ({["k"] = Box(1):read} as {value: value})
            ]],
            metatable = [[
                __eq = function(_, other) return other.k() == 42 end,
            ]],
        },
    }
    for _, case in ipairs(cases) do
        it("rejects initializer implicit Map exposure through " .. case.name,
           function()
            local ok, err = h.build_so_chain({
                {name = provider, src = provider_source},
                {name = consumer, src = declarations .. case.initializer ..
                    "\ndo seed = 42 end\n"},
            })
            if ok then
                -- Pre-fix reproduction: the real imported Map is initialized,
                -- then Lua installs the metatable before loading the consumer.
                local ran, observed = h.call("string", [[
                    local dep = require "map_initializer_implicit_provider"
                    setmetatable(dep.registry, {
                        ]] .. case.metatable .. [[
                    })
                    local loaded, failure =
                        pcall(require, "map_initializer_implicit_consumer")
                    assert(not loaded, "own callback was not entered during initialization")
                    assert(type(failure) == "string", "missing initialization diagnostic")
                    assert(failure:find("expected integer but found nil", 1, true), failure)
                    return failure
                ]])
                assert.truthy(ran, observed)
                err = "unsafe initializer was accepted and entered its own callback: " ..
                    observed
            end
            assert.falsy(ok, err)
            assert.match("module variable initializer cannot", err)
        end)
    end

    it("executes callback-free imported metamethods without exposing raw equality", function()
        local ok, err = h.build_so_chain({
            {name = provider, src = provider_source},
            {name = consumer, src = declarations .. [[
                local indexed: integer = dep.registry["answer"]
                local length = #dep.integers
                local optional_index: integer = dep.maybe_registry["answer"]
                local optional_length = #dep.maybe_integers
                local optional_spread = {...dep.maybe_integers}
                local called = (dep.callable as function(integer): integer)(41)
                local raw_equal = dep.dynamic ==
                    ({["k"] = Box(1):read} as value)
                local optional_raw_equal = dep.maybe_registry ==
                    ({["k"] = Box(1):read} as {value: value})
                local options_raw_equal = dep.maybe_registry ==
                    (({["k"] = Box(1):read} as {value: value}) as ({value: value})?)
                local fresh_index = ({["k"] = Box(1):read} as {value: value})[
                    function(): integer return seed end]
                local finite = {...dep.integers[1, 2]}
                local open = {...dep.integers}
                local adjusted: integer = (...dep.integers)
                function run(): boolean
                    return indexed == 42 and length == 2 and called == 42
                        and optional_index == 42 and optional_length == 2
                        and #optional_spread == 2 and optional_spread[1] == 41
                        and optional_spread[2] == 42
                        and not optional_raw_equal and not options_raw_equal
                        and not raw_equal and fresh_index == nil and seed == 42
                        and #finite == 2 and finite[1] == 41 and finite[2] == 42
                        and #open == 2 and open[1] == 41 and open[2] == 42
                        and adjusted == 41
                end
                do seed = 42 end
            ]]},
        })
        assert.truthy(ok, err)
        ok, err = h.call("string", [[
            local dep = require "map_initializer_implicit_provider"
            local indexed, measured, called, projected = 0, 0, 0, 0
            setmetatable(dep.registry, {
                __index = function(_, key)
                    assert(key == "answer")
                    indexed = indexed + 1
                    return 42
                end,
                __eq = function() error("raw option equality called __eq") end,
            })
            setmetatable(dep.integers, {
                __len = function()
                    measured = measured + 1
                    return 2
                end,
                __index = function(_, key)
                    assert(key == 1 or key == 2)
                    projected = projected + 1
                    return 40 + key
                end,
            })
            setmetatable(dep.maybe_registry, getmetatable(dep.registry))
            setmetatable(dep.maybe_integers, getmetatable(dep.integers))
            setmetatable(dep.callable, {
                __call = function(_, number)
                    called = called + 1
                    return number + 1
                end,
            })
            setmetatable(dep.dynamic, {
                __eq = function() error("raw value equality called __eq") end,
            })
            local consumer = require "map_initializer_implicit_consumer"
            assert(consumer.run())
            assert(indexed == 2 and measured == 5 and called == 1 and projected == 7)
        ]])
        assert.truthy(ok, err)
    end)

    it("preserves fresh callable-bearing Map operations in native initialization", function()
        local fn = "function(): integer return seed end"
        local map = '({["k"] = ' .. fn .. "} as {value: value})"
        local integers = "({[1] = " .. fn .. "} as {integer: value})"
        local ok, err = h.build_so_chain({
            {name = consumer, src = declarations:gsub(
                'local dep = import "map_initializer_implicit_provider"', "") .. [[
                local equal = ]] .. map .. " == " .. map .. [[
                local unequal = ]] .. map .. " ~= " .. map .. [[
                local boxed = ]] .. map .. " == (" .. map .. [[ as value)
                local selected_and = (true and ]] .. map .. ") == " .. map .. [[
                local selected_or = (nil or ]] .. map .. ") == " .. map .. [[
                local length = #]] .. integers .. [[
                local cast_length = #((]] .. integers .. [[ as value) as {integer: value})
                local selected_length = #(nil or ]] .. integers .. [[)
                local array_length = #{Box(1):read}
                local raw_equal = (]] .. map .. " as value) == (" .. map .. [[ as value)
                local callable_view = ]] .. map .. " == (((" .. map .. [[
                    as value) as function(): integer) as value)
                function run(): boolean
                    return not equal and unequal and not boxed
                        and not selected_and and not selected_or
                        and length == 1 and cast_length == 1 and selected_length == 1
                        and array_length == 1 and not raw_equal and not callable_view
                        and seed == 42
                end
                do seed = 42 end
            ]]},
        })
        assert.truthy(ok, err)
        ok, err = h.call("string", [[
            local consumer = require "map_initializer_implicit_consumer"
            assert(consumer.run())
        ]])
        assert.truthy(ok, err)
    end)
end)
