local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"

local generated_modules = {
    "test",
    "messages",
    "message_consumer",
    "union_provider",
    "union_consumer",
    "union_so_provider",
    "union_so_consumer",
}

local function clean_generated_modules()
    for _, name in ipairs(generated_modules) do
        os.remove(name .. ".c")
        os.remove(name .. ".o")
        os.remove(name .. ".so")
        os.remove(name .. ".a")
        os.execute("rm -rf " .. name .. ".so.dSYM")
    end
end

describe("unions (end-to-end)", function()
    after_each(clean_generated_modules)

    it("describes public constructor symbols from source and interfaces",
    function()
        local ok, err, ast, modtype = h.run_checker([[
            union Message
                some: integer
            end
        ]])
        assert.truthy(ok, err)

        local expected = {
            symbol = "test_\\u2133_Message_\\u2131_some_titanstatic",
            owner = "union function 'test.Message.some'",
        }
        local source_symbols = coder.external_symbols("test", ast)
        local interface_symbols =
            coder.interface_external_symbols("test", modtype)
        local function find_symbol(symbols)
            for _, entry in ipairs(symbols) do
                if entry.symbol == expected.symbol then return entry end
            end
        end
        assert.same(expected, find_symbol(source_symbols))
        assert.same(expected, find_symbol(interface_symbols))
    end)

    it("constructs empty and payload variants and dispatches without fallthrough",
    function()
        h.run_coder([[
            union Message
                quit
                write: string
                count: integer
            end

            union Other
                item
            end

            surplus_effects: integer = 0

            local function surplus_value(): integer
                surplus_effects = surplus_effects + 1
                return 99
            end

            function describe(message: Message): string
                case message
                when write: text then
                    return "write:" .. text
                when count: n then
                    return "count:" .. n
                when quit then
                    return "quit"
                end
            end

            function unmatched(message: Message): integer
                case message
                when count: n then
                    return n
                end
                return -1
            end

            function make_with_surplus(): Message
                return Message.quit(surplus_value())
            end

            function is_message(boxed: value): boolean
                return boxed is Message
            end

            function cast_message(boxed: value): Message
                return boxed as Message
            end
        ]], [[
            local quit = test.Message.quit()
            assert(test.describe(quit) == "quit")
            assert(test.describe(test.Message.write("hello")) == "write:hello")
            assert(test.describe(test.Message.count(42)) == "count:42")
            assert(test.unmatched(test.Message.write("ignored")) == -1)
            assert(quit == quit)
            assert(quit ~= test.Message.quit())
            assert(test.is_message(quit))
            assert(not test.is_message(test.Other.item()))
            assert(test.cast_message(quit) == quit)
            local ok, err = pcall(test.cast_message, test.Other.item())
            assert(not ok)
            assert(tostring(err):match("test.Message"))
            assert(tostring(err):match("test.Other"))
            assert(test.make_with_surplus())
            assert(test.surplus_effects == 1)
        ]])
    end)

    it("compiles the exact imported positional record-payload example",
    function()
        local ok, err = h.generate_modules({
            messages = [[
                record Delta
                    x: float
                    y: float
                end

                union Message
                    move: Delta
                end
            ]],
            message_consumer = [[
                local m = import "messages"
                local moved = m.Message.move({ x = 1.0, y = 2.0 })

                function total(): float
                    case moved
                    when move: delta then
                        return delta.x + delta.y
                    end
                end
            ]],
        }, "message_consumer")
        assert.truthy(ok, err)
        local rok, out = h.call("message_consumer", [[
            assert(message_consumer.total() == 3.0)
        ]])
        assert.truthy(rok, out)
    end)

    it("forces an optional scrutinee once before any arm handlers", function()
        h.run_coder([[
            union Maybe
                none
                some: integer
            end

            scrutinies: integer = 0
            arm_runs: integer = 0
            catch_runs: integer = 0
            finally_runs: integer = 0
            else_runs: integer = 0

            local function optional(present: boolean): Maybe?
                scrutinies = scrutinies + 1
                if present then
                    return Maybe.some(42)
                end
                return nil
            end

            function inspect(present: boolean): integer
                case optional(present)
                when some: n then
                    defer finally_runs = finally_runs + 1
                    arm_runs = arm_runs + 1
                    return n
                catch
                    catch_runs = catch_runs + 1
                    return -2
                when none then
                    return 0
                else
                    else_runs = else_runs + 1
                    return -1
                end
            end

            function counters():
                    (integer, integer, integer, integer, integer)
                return scrutinies, arm_runs, catch_runs,
                    finally_runs, else_runs
            end
        ]], [[
            assert(test.inspect(true) == 42)
            local s, a, c, f, e = test.counters()
            assert(s == 1 and a == 1 and c == 0 and f == 1 and e == 0)

            local ok, err = pcall(test.inspect, false)
            assert(not ok)
            assert(tostring(err):match("expected test.Maybe but found nil"))
            s, a, c, f, e = test.counters()
            assert(s == 2 and a == 1 and c == 0 and f == 1 and e == 0)
        ]])
    end)

    it("keeps case arms as full blocks with catch, finally, and defer", function()
        h.run_coder([[
            union Message
                write: string
                quit
            end

            cleanup_effects: integer = 0

            function reset_cleanup()
                cleanup_effects = 0
            end

            function protected(message: Message): integer
                local out = 0
                case message
                when write: text then
                    defer out = out + #text + 100
                    do
                        out = #text
                        raise "boom"
                    catch
                        out = out + #text + 10
                    end
                when quit then
                    defer out = out + 1000
                    out = 1
                else
                    out = -1
                end
                return out
            end

            function deferred(message: Message): integer
                local out = 0
                case message
                when write: text then
                    defer out = out + 100
                    out = #text
                when quit then
                    out = 1
                end
                return out
            end

            function cleanup_fallthrough(message: Message): integer
                case message
                when write: text then
                    defer cleanup_effects = cleanup_effects + 10
                    defer cleanup_effects = cleanup_effects + 1
                    cleanup_effects = cleanup_effects + #text
                else
                    defer cleanup_effects = cleanup_effects + 100000
                    do
                        defer cleanup_effects = cleanup_effects + 100
                        cleanup_effects = cleanup_effects + 1000
                        raise "caught else"
                    catch
                        cleanup_effects = cleanup_effects + 10000
                    end
                end
                return cleanup_effects
            end

            function cleanup_return(message: Message): integer
                case message
                when write: text then
                    defer cleanup_effects = cleanup_effects + 10
                    defer cleanup_effects = cleanup_effects + 1
                    return #text
                else
                    defer cleanup_effects = cleanup_effects + 1000
                    defer cleanup_effects = cleanup_effects + 100
                    return -1
                end
            end

            function cleanup_raise(message: Message)
                case message
                when write then
                    defer cleanup_effects = cleanup_effects + 10
                    defer cleanup_effects = cleanup_effects + 1
                    raise "raised arm"
                end
            end

            local function exploding_scrutinee(): Message
                cleanup_effects = cleanup_effects + 1
                raise "raised scrutinee"
            end

            function scrutinee_handler_isolation()
                case exploding_scrutinee()
                when write then
                catch
                    cleanup_effects = cleanup_effects + 100
                else
                catch
                    cleanup_effects = cleanup_effects + 10000
                end
            end
        ]], [[
            assert(test.protected(test.Message.write("abc")) == 119)
            assert(test.protected(test.Message.quit()) == 1001)
            assert(test.deferred(test.Message.write("abc")) == 103)

            test.reset_cleanup()
            assert(test.cleanup_fallthrough(
                test.Message.write("abc")) == 14)
            test.reset_cleanup()
            assert(test.cleanup_fallthrough(
                test.Message.quit()) == 111100)

            test.reset_cleanup()
            assert(test.cleanup_return(test.Message.write("abc")) == 3)
            assert(test.cleanup_effects == 11)
            test.reset_cleanup()
            assert(test.cleanup_return(test.Message.quit()) == -1)
            assert(test.cleanup_effects == 1100)

            test.reset_cleanup()
            local ok, err = pcall(
                test.cleanup_raise, test.Message.write("x"))
            assert(not ok and tostring(err):match("raised arm"))
            assert(test.cleanup_effects == 11)

            test.reset_cleanup()
            ok, err = pcall(test.scrutinee_handler_isolation)
            assert(not ok and tostring(err):match("raised scrutinee"))
            assert(test.cleanup_effects == 1)
        ]])
    end)

    it("matches if-block cleanup for fallthrough, return, raise, and break",
    function()
        h.run_coder([[
            union Branch
                selected: integer
                other: integer
            end

            differential_trace: integer = 0

            function trace_value(): integer
                return differential_trace
            end

            function case_fallthrough(branch: Branch): integer
                differential_trace = 0
                case branch
                when selected: n then
                    defer differential_trace = differential_trace + 10
                    defer differential_trace = differential_trace + 1
                    differential_trace = differential_trace + n
                else
                    defer differential_trace = differential_trace + 10000
                    defer differential_trace = differential_trace + 100
                    differential_trace = differential_trace + 1000
                end
                return differential_trace
            end

            function if_fallthrough(selected: boolean, n: integer): integer
                differential_trace = 0
                if selected then
                    defer differential_trace = differential_trace + 10
                    defer differential_trace = differential_trace + 1
                    differential_trace = differential_trace + n
                else
                    defer differential_trace = differential_trace + 10000
                    defer differential_trace = differential_trace + 100
                    differential_trace = differential_trace + 1000
                end
                return differential_trace
            end

            function case_return(branch: Branch): integer
                differential_trace = 0
                case branch
                when selected: n then
                    defer differential_trace = differential_trace + 10
                    defer differential_trace = differential_trace + 1
                    return n
                else
                    defer differential_trace = differential_trace + 1000
                    defer differential_trace = differential_trace + 100
                    return -1
                end
            end

            function if_return(selected: boolean, n: integer): integer
                differential_trace = 0
                if selected then
                    defer differential_trace = differential_trace + 10
                    defer differential_trace = differential_trace + 1
                    return n
                else
                    defer differential_trace = differential_trace + 1000
                    defer differential_trace = differential_trace + 100
                    return -1
                end
            end

            function case_raise(branch: Branch): integer
                differential_trace = 0
                case branch
                when selected: n then
                    defer differential_trace = differential_trace + 1000
                    do
                        differential_trace = differential_trace + n
                        raise "case"
                    catch
                        differential_trace = differential_trace + 100
                    end
                end
                return differential_trace
            end

            function if_raise(selected: boolean, n: integer): integer
                differential_trace = 0
                if selected then
                    defer differential_trace = differential_trace + 1000
                    do
                        differential_trace = differential_trace + n
                        raise "if"
                    catch
                        differential_trace = differential_trace + 100
                    end
                else
                end
                return differential_trace
            end

            function case_break(branch: Branch): integer
                differential_trace = 0
                while true do
                    case branch
                    when selected: n then
                        defer differential_trace = differential_trace + 10
                        defer differential_trace = differential_trace + 1
                        differential_trace = differential_trace + n
                        break
                    else
                        defer differential_trace = differential_trace + 100
                        break
                    end
                end
                return differential_trace
            end

            function if_break(selected: boolean, n: integer): integer
                differential_trace = 0
                while true do
                    if selected then
                        defer differential_trace = differential_trace + 10
                        defer differential_trace = differential_trace + 1
                        differential_trace = differential_trace + n
                        break
                    else
                        defer differential_trace = differential_trace + 100
                        break
                    end
                end
                return differential_trace
            end
        ]], [[
            local selected = test.Branch.selected(7)
            local other = test.Branch.other(9)
            assert(test.case_fallthrough(selected) ==
                   test.if_fallthrough(true, 7))
            assert(test.case_fallthrough(other) ==
                   test.if_fallthrough(false, 9))

            local case_result = test.case_return(selected)
            local case_trace = test.trace_value()
            local if_result = test.if_return(true, 7)
            local if_trace = test.trace_value()
            assert(case_result == if_result and case_trace == if_trace)
            case_result = test.case_return(other)
            case_trace = test.trace_value()
            if_result = test.if_return(false, 9)
            if_trace = test.trace_value()
            assert(case_result == if_result and case_trace == if_trace)

            assert(test.case_raise(selected) == test.if_raise(true, 7))
            assert(test.case_break(selected) == test.if_break(true, 7))
            assert(test.case_break(other) == test.if_break(false, 9))
        ]])
    end)

    it("lets an arm break its enclosing loop and nests cases safely", function()
        h.run_coder([[
            union Message
                quit
                count: integer
            end

            function iterations(message: Message): integer
                local n = 0
                while true do
                    n = n + 1
                    case message
                    when quit then
                        break
                    when count: limit then
                        if n >= limit then
                            break
                        end
                    end
                end
                return n
            end

            function nested(outer: Message, inner: Message): integer
                case outer
                when quit then
                    return 0
                when count: a then
                    case inner
                    when count: b then
                        return a * 10 + b
                    else
                        return a
                    end
                else
                    return -1
                end
            end

            function break_with_finally(message: Message): integer
                local n = 0
                while true do
                    case message
                    when quit then
                        defer n = n + 10
                        defer n = n + 100
                        n = 1
                        break
                    else
                        break
                    end
                end
                return n
            end

            function loop_inside_arm(message: Message): integer
                case message
                when count: limit then
                    local n = 0
                    while true do
                        n = n + 1
                        if n >= limit then break end
                    end
                    return n
                else
                    return 0
                end
            end

            function terminating_case(message: Message): integer
                case message
                when quit then
                    return 1
                when count: n then
                    return n
                end
                return variable_in_unchecked_dead_tail
            end

            function terminating_if(flag: boolean): integer
                if flag then
                    return 2
                else
                    return 3
                end
                return variable_in_unchecked_dead_tail
            end

            function terminating_do(flag: boolean): integer
                do
                    if flag then
                        return 4
                    else
                        return 5
                    end
                end
                return variable_in_unchecked_dead_tail
            end

            function terminating_try(flag: boolean): integer
                do
                    defer local completed = true
                    if flag then
                        return 6
                    else
                        return 7
                    end
                end
                return variable_in_unchecked_dead_tail
            end

            function fallthrough_compounds(
                    message: Message, flag: boolean): integer
                local out = 0
                do
                    if flag then
                        out = out + 1
                    end
                end
                case message
                when quit then
                    out = out + 10
                else
                    out = out + 20
                end
                do
                    if flag then
                        out = out + 100
                    end
                catch
                    out = -10000
                end
                out = out + 1000
                return out
            end
        ]], [[
            assert(test.iterations(test.Message.quit()) == 1)
            assert(test.iterations(test.Message.count(3)) == 3)
            assert(test.nested(test.Message.count(4),
                               test.Message.count(2)) == 42)
            assert(test.break_with_finally(test.Message.quit()) == 111)
            assert(test.loop_inside_arm(test.Message.count(3)) == 3)
            assert(test.terminating_case(test.Message.quit()) == 1)
            assert(test.terminating_if(true) == 2)
            assert(test.terminating_if(false) == 3)
            assert(test.terminating_do(true) == 4)
            assert(test.terminating_do(false) == 5)
            assert(test.terminating_try(true) == 6)
            assert(test.terminating_try(false) == 7)
            assert(test.fallthrough_compounds(
                test.Message.quit(), true) == 1111)
            assert(test.fallthrough_compounds(
                test.Message.count(1), false) == 1020)
        ]])
    end)

    it("stores Array payloads in their internal representation", function()
        local csrc = h.compile_and_read_c([[
            union Numbers
                none
                nothing: nil
                many: {integer}
            end

            function total(numbers: Numbers): integer
                case numbers
                when many: values then
                    return values[1] + values[2]
                when none then
                    return 0
                else
                    return -1
                end
            end

            function sample(): Numbers
                return Numbers.many({20, 22})
            end

            function typed_nil(): Numbers
                return Numbers.nothing(nil)
            end

            function is_typed_nil(numbers: Numbers): boolean
                case numbers
                when nothing: payload then
                    return payload == nil
                else
                    return false
                end
            end

            function mutate_and_rebind(numbers: Numbers): integer
                case numbers
                when many: values then
                    values[1] = 40
                    values = {1, 2}
                end
                case numbers
                when many: values then
                    return values[1] + values[2]
                else
                    return -1
                end
            end
        ]])

        assert.match(
            "sethvalue%s*%(%s*L,%s*&_tmp_%d+%->uv%[1%]%.uv,%s*", csrc)
        assert.match(
            "hvalue%s*%(%s*&_tmp_%d+%->uv%[1%]%.uv%s*%)", csrc)
        assert.match("luaS_newudata%s*%(%s*L,%s*0,%s*1%s*%)", csrc)
        assert.match("luaS_newudata%s*%(%s*L,%s*0,%s*2%s*%)", csrc)
        assert.not_match("titan_array_require_proxy", csrc)
        assert.match("switch%s*%(%s*_case_%d+_tag%s*%)", csrc)
        assert.match("case%s+2:%s*goto%s+_case_%d+_arm_%d+;", csrc)

        local rok, err = h.call("test", [[
            assert(test.total(test.sample()) == 42)
            assert(test.is_typed_nil(test.typed_nil()))
            assert(test.mutate_and_rebind(test.sample()) == 62)
        ]])
        assert.truthy(rok, err)
    end)

    it("round-trips the full payload matrix across full and minor GC",
    function()
        local csrc = h.compile_and_read_c([[
            local ffi = foreign import "titan/ffi.h"
            local lua = foreign import "lua.h"

            local type Owner = owned ffi.titan_ffi_int[]

            local record Box
                number: integer
            end

            local union Inner
                text: string
            end

            local union Payload
                primitive: integer
                text: string
                array: {Box}
                maybe_array: {Box}?
                map: {string: Box}
                record_item: Box
                nested: Inner
                callback: (integer) -> integer
                boxed: value
                maybe_text: string?
                pointer: *ffi.titan_ffi_int
                owner: Owner
                recursive: Payload?
                raw: ffi.TValue
                udata: *ffi.Udata
            end

            local function select_gc(generational: boolean)
                if generational then
                    lua.lua_gc(L, lua.LUA_GCGEN)
                else
                    lua.lua_gc(L, lua.LUA_GCINC)
                end
                lua.lua_gc(L, lua.LUA_GCCOLLECT)
            end

            local function collect_after_store(generational: boolean)
                if generational then
                    -- In generational mode these are minor collections. Do
                    -- not let this proof collapse to "switch mode, full GC".
                    lua.lua_gc(
                        L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
                    lua.lua_gc(
                        L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
                    lua.lua_gc(
                        L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
                    lua.lua_gc(
                        L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
                else
                    lua.lua_gc(L, lua.LUA_GCCOLLECT)
                end
            end

            -- Each maker returns from its own frame, so constructor argument
            -- temporaries cannot be accidental second roots for the payload.
            local function make_primitive(): Payload
                return Payload.primitive(1)
            end

            local function make_text(): Payload
                local text = "fresh-" .. "text"
                return Payload.text(text)
            end

            local function make_array(): Payload
                return Payload.array({ Box.new(20), Box.new(22) })
            end

            local function make_maybe_array(present: boolean): Payload
                local values: {Box}? = nil
                if present then
                    values = { Box.new(30) }
                end
                return Payload.maybe_array(values)
            end

            local function make_map(): Payload
                return Payload.map({
                    ["left"] = Box.new(3),
                    ["right"] = Box.new(4),
                })
            end

            local function make_record(): Payload
                return Payload.record_item(Box.new(8))
            end

            local function make_nested(): Payload
                return Payload.nested(Inner.text("nested"))
            end

            local function make_callback(): Payload
                local delta = 40
                return Payload.callback(
                    function(input: integer): integer
                        return input + delta
                    end)
            end

            local function make_boxed(): Payload
                local boxed: value = Box.new(9)
                return Payload.boxed(boxed)
            end

            local function make_maybe_text(): Payload
                local text: string? = "option"
                return Payload.maybe_text(text)
            end

            local function make_pointer(owner: Owner): Payload
                local pointer: *ffi.titan_ffi_int = owner
                return Payload.pointer(pointer)
            end

            local function make_owner(): Payload
                local owner: Owner =
                    ffi.titan_ffi_int.new_array(1)
                owner[0] = 12 as ffi.titan_ffi_int
                return Payload.owner(owner)
            end

            local function make_recursive(): Payload
                local child = Payload.primitive(13)
                return Payload.recursive(child)
            end

            local function make_raw(): Payload
                local raw: ffi.TValue = "raw"
                return Payload.raw(raw)
            end

            local function make_udata(): Payload
                local boxed: value = Box.new(15)
                local pointer: *ffi.Udata = boxed as *ffi.Udata
                return Payload.udata(pointer)
            end

            -- Promote the Array backings and their owning unions, then write
            -- fresh records through the extracted raw Table * backings. The
            -- following minor collection needs the Array write barrier.
            local function install_fresh_array_elements(
                    direct: Payload, optional: Payload)
                case direct
                when array: values then
                    values[1] = Box.new(40)
                end
                case optional
                when maybe_array: maybe then
                    local values: {Box} = maybe
                    values[1] = Box.new(31)
                end
            end

            local function payload_value(payload: Payload): integer
                case payload
                when primitive: item then
                    return item
                when text: item then
                    return #item
                when array: values then
                    return values[1].number + values[2].number
                when maybe_array: maybe then
                    if maybe then
                        local values: {Box} = maybe
                        return values[1].number
                    end
                    return 0
                when map: values then
                    return values["left"].number
                        + values["right"].number
                when record_item: item then
                    return item.number
                when nested: inner then
                    case inner
                    when text: item then
                        return #item
                    else
                        return -100
                    end
                when callback: callback then
                    return callback(2)
                when boxed: boxed then
                    local item: Box = boxed as Box
                    return item.number
                when maybe_text: maybe then
                    local item: string = maybe
                    return #item
                when pointer: pointer then
                    return pointer[0] as integer
                when owner: owner then
                    return owner[0] as integer
                when recursive: child then
                    local item: Payload = child
                    return payload_value(item)
                when raw: raw then
                    local boxed: value = raw
                    local item: string = boxed as string
                    return #item
                when udata: pointer then
                    local boxed: value = pointer
                    local item: Box = boxed as Box
                    return item.number
                else
                    return -1000
                end
            end

            function exercise_payloads(generational: boolean): integer
                select_gc(generational)

                local primitive = make_primitive()
                local text = make_text()
                local array = make_array()
                local maybe_array = make_maybe_array(true)
                local nil_array = make_maybe_array(false)
                local map = make_map()
                local record_payload = make_record()
                local nested = make_nested()
                local callback = make_callback()
                local boxed = make_boxed()
                local maybe_text = make_maybe_text()
                local pointer_owner: Owner =
                    ffi.titan_ffi_int.new_array(1)
                pointer_owner[0] = 11 as ffi.titan_ffi_int
                local pointer = make_pointer(pointer_owner)
                local owner = make_owner()
                local recursive = make_recursive()
                local raw = make_raw()
                local udata = make_udata()

                -- Validate every initial union payload store and make the
                -- union/Array owners old before the fresh element stores.
                lua.lua_gc(L, lua.LUA_GCCOLLECT)
                install_fresh_array_elements(array, maybe_array)
                collect_after_store(generational)

                local result =
                    payload_value(primitive)
                    + payload_value(text)
                    + payload_value(array)
                    + payload_value(maybe_array)
                    + payload_value(nil_array)
                    + payload_value(map)
                    + payload_value(record_payload)
                    + payload_value(nested)
                    + payload_value(callback)
                    + payload_value(boxed)
                    + payload_value(maybe_text)
                    + payload_value(pointer)
                    + payload_value(owner)
                    + payload_value(recursive)
                    + payload_value(raw)
                    + payload_value(udata)

                lua.lua_gc(L, lua.LUA_GCINC)
                return result
            end

            function array_option_is_nil(
                    generational: boolean): boolean
                select_gc(generational)
                local payload = make_maybe_array(false)
                collect_after_store(generational)
                local result = false
                case payload
                when maybe_array: maybe then
                    result = not maybe
                end
                lua.lua_gc(L, lua.LUA_GCINC)
                return result
            end
        ]])

        -- Direct Array payloads remain a Table * in uv[1]. Present
        -- Option(Array) values likewise carry that backing in their TValue;
        -- neither construction nor case binding may introduce a proxy.
        assert.match(
            "sethvalue%s*%(%s*L,%s*&_tmp_%d+%->uv%[1%]%.uv,%s*", csrc)
        assert.match(
            "hvalue%s*%(%s*&_tmp_%d+%->uv%[1%]%.uv%s*%)", csrc)
        assert.not_match("titan_array_require_proxy", csrc)
        assert.match(
            "luaC_barrierback%s*%(%s*L,%s*obj2gco%s*%(%s*_tmp_%d+%s*%)"
                .. ",%s*&_tmp_%d+%->uv%[1%]%.uv%s*%)",
            csrc)

        local rok, err = h.call("test", [[
            assert(test.exercise_payloads(false) == 236)
            assert(test.array_option_is_nil(false))
            assert(test.exercise_payloads(true) == 236)
            assert(test.array_option_is_nil(true))
        ]])
        assert.truthy(rok, err)
    end)

    it("keeps payloads and captured binders alive across collections", function()
        h.run_coder([[
            union Message
                text: string
                callback: (integer) -> integer
                empty
            end

            function capture(message: Message): () -> string
                case message
                when text: text_value then
                    return function(): string
                        return text_value
                    end
                else
                    return function(): string
                        return "empty"
                    end
                end
            end

            function make_callback(delta: integer): Message
                return Message.callback(function(input: integer): integer
                    return input + delta
                end)
            end

            function invoke(message: Message, input: integer): integer
                case message
                when callback: callback then
                    return callback(input)
                else
                    return -1
                end
            end
        ]], [[
            collectgarbage("generational")
            local message = test.Message.text("still alive")
            collectgarbage("collect")
            local get = test.capture(message)
            message = nil
            collectgarbage("collect")
            collectgarbage("collect")
            assert(get() == "still alive")

            local callback = test.make_callback(2)
            collectgarbage("collect")
            collectgarbage("collect")
            assert(test.invoke(callback, 40) == 42)
            callback = nil
            collectgarbage("collect")
            collectgarbage("incremental")
        ]])
    end)

    it("isolates sibling-arm binder boxes and setjmp spills", function()
        h.run_coder([[
            union Choice
                left: integer
                right: integer
            end

            function arm_closure(choice: Choice): () -> integer
                case choice
                when left: n then
                    n = n + 10
                    return function(): integer
                        n = n + 1
                        return n
                    end
                when right: n then
                    local observed = 0
                    do
                        n = n + 20
                        raise "observe spill"
                    catch
                        observed = n
                    end
                    return function(): integer
                        observed = observed + 2
                        return observed
                    end
                else
                    return function(): integer
                        return -1
                    end
                end
            end

            function protected_case_scrutinee(input: integer): integer
                local observed = 0
                do
                    case Choice.left(input)
                    when left: n then
                        observed = n
                    else
                        observed = -1
                    end
                    raise "observe case spill"
                catch
                    return observed
                end
            end
        ]], [[
            collectgarbage("generational")
            local left = test.arm_closure(test.Choice.left(1))
            local right = test.arm_closure(test.Choice.right(2))
            assert(test.protected_case_scrutinee(42) == 42)
            collectgarbage("collect")
            collectgarbage("collect")
            assert(left() == 12)
            assert(right() == 24)
            assert(left() == 13)
            assert(right() == 26)
            left, right = nil, nil
            collectgarbage("collect")
            collectgarbage("incremental")
        ]])
    end)

    it("exposes constructors and methods but keeps representation opaque to Lua",
    function()
        h.run_coder([[
            union Message
                quit
                write: string
                local hidden: integer
            end

            function Message:length(): integer
                case self
                when write: text then
                    return #text
                else
                    return 0
                end
            end

            function consume(message: Message): integer
                return message:length()
            end
        ]], [[
            assert(test.Message.write == test.Message.write)
            assert(test.Message.hidden == nil)
            local message = test.Message.write("hello")
            assert(message:length() == 5)
            assert(test.consume(message) == 5)
            assert(getmetatable(message) == "Titan union test.Message")
            assert(not pcall(function() return message.tag end))
            assert(not pcall(function() message.payload = 1 end))
        ]])
    end)

    it("uses one canonical imported constructor closure as a first-class value",
    function()
        local ok, err = h.generate_modules({
            union_provider = [[
                seed: integer = 40

                function increment(n: integer): integer
                    return n + 1
                end

                record Pair
                    first: integer
                    second: integer
                end

                union Message
                    count: integer
                    quit
                end
            ]],
            union_consumer = [[
                local provider = import "union_provider"

                function run(): integer
                    local make: (integer) -> provider.Message =
                        provider.Message.count
                    local message = make(42)
                    case message
                    when count: n then
                        return n
                    else
                        return -1
                    end
                end

                function same(): boolean
                    return provider.Message.count == provider.Message.count
                end

                function direct(): integer
                    local message = provider.Message.count(
                        provider.increment(provider.seed))
                    case message
                    when count: n then
                        return n
                    else
                        return -1
                    end
                end

                function record_static(): integer
                    local make: (integer, integer) -> provider.Pair =
                        provider.Pair.new
                    local pair = make(provider.seed, 2)
                    return pair.first + pair.second
                end
            ]],
        }, "union_consumer")
        assert.truthy(ok, err)
        local rok, out = h.call("union_consumer", [[
            assert(union_consumer.run() == 42)
            assert(union_consumer.same())
            assert(union_consumer.direct() == 41)
            assert(union_consumer.record_static() == 42)
        ]])
        assert.truthy(rok, out)
    end)

    it("reconstructs imported constructor closure slots through a DSO", function()
        local ok, err = h.build_so_chain({
            {
                name = "union_so_provider",
                src = [[
                    seed: integer = 40

                    function increment(n: integer): integer
                        return n + 1
                    end

                    record Pair
                        first: integer
                        second: integer
                    end

                    union Message
                        count: integer
                        local hidden: integer
                        quit
                    end

                    function Message:measure(): integer
                        case self
                        when count: n then
                            return n
                        when quit then
                            return 0
                        else
                            return -1
                        end
                    end

                    function Message.bump(n: integer): Message
                        return Message.count(n + 1)
                    end

                    function hidden_message(): Message
                        return Message.hidden(99)
                    end
                ]],
            },
            {
                name = "union_so_consumer",
                src = [[
                    local provider = import "union_so_provider"

                    function run(): integer
                        local make: (integer) -> provider.Message =
                            provider.Message.count
                        local message = make(42)
                        case message
                        when count: n then
                            return n
                        else
                            return -1
                        end
                    end

                    function same(): boolean
                        return provider.Message.count ==
                            provider.Message.count
                    end

                    function direct(): integer
                        local message = provider.Message.count(
                            provider.increment(provider.seed))
                        case message
                        when count: n then
                            return n
                        else
                            return -1
                        end
                    end

                    function record_static(): integer
                        local make: (integer, integer) -> provider.Pair =
                            provider.Pair.new
                        local pair = make(provider.seed, 2)
                        return pair.first + pair.second
                    end

                    function static_value(): integer
                        local make: (integer) -> provider.Message =
                            provider.Message.bump
                        return make(41):measure()
                    end

                    function bound_value(): integer
                        local message = provider.Message.count(42)
                        local read: () -> integer = message:measure
                        return read()
                    end

                    function hidden_else(): integer
                        case provider.hidden_message()
                        when count: n then
                            return n
                        when quit then
                            return 0
                        else
                            return 99
                        end
                    end
                ]],
            },
        })
        assert.truthy(ok, err)
        local rok, out = h.call(
            "union_so_consumer",
            [[
                assert(union_so_consumer.run() == 42)
                assert(union_so_consumer.same())
                assert(union_so_consumer.direct() == 41)
                assert(union_so_consumer.record_static() == 42)
                assert(union_so_consumer.static_value() == 42)
                assert(union_so_consumer.bound_value() == 42)
                assert(union_so_consumer.hidden_else() == 99)
            ]])
        assert.truthy(rok, out)
    end)
end)
