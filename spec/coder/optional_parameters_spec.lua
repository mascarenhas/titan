local h = require 'spec.support.helpers'

local run_coder = h.run_coder

describe("optional function parameter code generation", function()
    it("pads direct function and method calls with nil", function()
        run_coder([[
            record Box
                factor: integer;
            end

            function pick(a: integer?, b: boolean): integer
                local score = 0
                if not a then
                    score = score + 1
                else
                    score = score + (a as integer)
                end
                if not b then
                    score = score + 10
                end
                return score
            end

            function Box:add(a: integer?, b: boolean): integer
                local score = self.factor
                if not a then
                    score = score + 1
                else
                    score = score + (a as integer)
                end
                if not b then
                    score = score + 10
                end
                return score
            end

            function run(): integer
                local box = Box.new(5)
                return pick() + pick(2, true) + box:add() + box:add(3, true)
            end
        ]], [[
            assert(test.run() == 37)
        ]])
    end)

    it("pads exact and generic first-class function calls with nil", function()
        run_coder([[
            function target(a: integer?, b: boolean): integer
                if not a and not b then
                    return 42
                else
                    return 0
                end
            end

            function call_exact(): integer
                local f: (integer?, boolean) -> integer = target
                return f()
            end

            function call_generic(f: (integer?, boolean) -> integer): integer
                return f()
            end
        ]], [[
            local function lua_target(a, b)
                assert(a == nil)
                assert(b == false)
                return 13
            end
            assert(test.call_exact() == 42)
            assert(test.call_generic(lua_target) == 13)
        ]])
    end)

    it("nil-fills a short trailing variadic spread in call arguments", function()
        run_coder([[
            function target(a: integer?, b: boolean): integer
                local score = 0
                if not a then
                    score = score + 1
                else
                    score = score + (a as integer)
                end
                if not b then
                    score = score + 10
                end
                return score
            end

            function spread(...: integer): integer
                return target(...)
            end
        ]], [[
            assert(test.spread() == 11)
            assert(test.spread(5) == 15)
            assert(test.spread(5, 1) == 5)
        ]])
    end)

    it("nil-fills borrowed fixed parameters when forwarding ... to a variadic callee", function()
        run_coder([[
            function target(a: integer?, b: boolean, ...: integer): integer
                local score = 0
                if not a then
                    score = score + 1
                else
                    score = score + (a as integer)
                end
                if not b then
                    score = score + 10
                end
                if #... > 0 then
                    score = score + #... * 100 + ...[1]
                end
                return score
            end

            function spread(...: integer): integer
                return target(...)
            end
        ]], [[
            assert(test.spread() == 11)
            assert(test.spread(5) == 15)
            assert(test.spread(5, 1, 7, 8) == 212)
        ]])
    end)

    it("coerces borrowed fixed parameters before fresh-copying a forwarded variadic tail", function()
        run_coder([[
            function target(a: value, ...: value): integer
                if a ~= 3 then
                    return -1
                end
                local boxed: value = #... as value
                if boxed ~= #... then
                    return -2
                end
                return #...
            end

            function spread(...: integer): integer
                return target(...)
            end
        ]], [[
            assert(test.spread(3) == 0)
            assert(test.spread(3, 4, 5) == 2)
        ]])
    end)

    it("pads the Lua entry point and still rejects surplus Lua arguments", function()
        run_coder([[
            function entry(a: integer?, b: boolean): integer
                local score = 0
                if not a then
                    score = score + 1
                else
                    score = score + (a as integer)
                end
                if not b then
                    score = score + 10
                end
                return score
            end

            function need_int(x: integer): integer
                return x
            end
        ]], [[
            assert(test.entry() == 11)
            assert(test.entry(4) == 14)

            local ok_extra, err_extra = pcall(test.entry, nil, false, nil)
            assert(not ok_extra)
            assert(err_extra:find("expected at most 2", 1, true), err_extra)

            local ok_missing, err_missing = pcall(test.need_int)
            assert(not ok_missing)
            assert(err_missing:find("expected integer but found nil", 1, true), err_missing)
        ]])
    end)
end)
