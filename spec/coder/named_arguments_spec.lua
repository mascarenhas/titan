local temporary = require "spec.support.temporary"
local h = require 'spec.support.helpers'

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    file:write(contents)
    file:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

local generated_modules = {
    "test",
    "na_provider",
    "na_consumer",
}

local function clean_generated_modules()
    for _, name in ipairs(generated_modules) do
        os.remove(name .. ".c")
        os.remove(name .. ".o")
        os.remove(name .. ".so")
        os.execute("rm -rf " .. name .. ".so.dSYM")
    end
end

describe("named arguments (code generation)", function()
    after_each(clean_generated_modules)

    it("maps functions, record statics, methods, and synthesized new calls",
    function()
        h.run_coder([[
            record Point
                x: integer
                y: integer
            end

            function encode(a: integer, b: integer, c: integer): integer
                return a * 100 + b * 10 + c
            end

            function Point.make(x: integer, y: integer): Point
                return Point.new { y = y, x = x }
            end

            function Point:encode(multiplier: integer, bias: integer): integer
                return self.x * 1000 + self.y * 100
                    + multiplier * 10 + bias
            end

            function mapping(): integer
                local direct = Point.new { y = 2, x = 1 }
                local static = Point.make { y = 4, x = 3 }
                return encode { c = 6, a = 5, b = 4 }
                    + direct:encode { bias = 8, multiplier = 7 }
                    + static:encode { multiplier = 9, bias = 0 }
            end
        ]], [[
            assert(test.mapping() == 5314)
        ]])
    end)

    it("evaluates explicit fields lexically before assembling formal order",
    function()
        h.run_coder([[
            order_trace: integer = 0

            function mark(digit: integer): integer
                order_trace = order_trace * 10 + digit
                return digit
            end

            function pack(first: integer, second: integer,
                          third: integer): integer
                return first * 100 + second * 10 + third
            end

            function lexical_order(): integer
                order_trace = 0
                local packed = pack {
                    third = mark(1),
                    first = mark(2),
                    second = mark(3),
                }
                return order_trace * 1000 + packed
            end
        ]], [[
            assert(test.lexical_order() == 123231)
        ]])
    end)

    it("evaluates an option/chained receiver once before named fields", function()
        h.run_coder([[
            record Receiver
                tag: integer
            end

            receiver_count: integer = 0
            receiver_trace: integer = 0

            function mark_receiver(): Receiver?
                receiver_count = receiver_count + 1
                receiver_trace = receiver_trace * 10 + 1
                return Receiver.new { tag = 7 }
            end

            function mark_field(digit: integer): integer
                receiver_trace = receiver_trace * 10 + digit
                return digit
            end

            function Receiver:pack(first: integer, second: integer): integer
                return self.tag * 100 + first * 10 + second
            end

            function receiver_order(): integer
                receiver_count = 0
                receiver_trace = 0
                local result = mark_receiver():pack {
                    second = mark_field(2),
                    first = mark_field(3),
                }
                return receiver_count * 1000000
                    + receiver_trace * 1000 + result
            end
        ]], [[
            assert(test.receiver_order() == 1123732)
        ]])
    end)

    it("reorders named native inputs with C-only lexical freezes", function()
        local csrc = h.compile_and_read_c([[
            local function sink(
                first: string,
                second: string
            ): integer
                return #first + #second
            end

            function named(first: string, second: string): integer
                return sink { second = second, first = first }
            end
        ]])
        local declaration = assert(csrc:find(
            "lua_Integer test_\\u2133_named_titan(", 1, true))
        local first = assert(csrc:find(
            "lua_Integer test_\\u2133_named_titan(", declaration + 1, true))
        local last = assert(csrc:find(
            "TITAN_MODULE_PRIVATE int test_\\u2133_named_titanentry_lua", first, true))
        local body = csrc:sub(first, last - 1)
        local second_freeze = assert(body:find(
            "_tmp_1 = _param_second;", 1, true))
        local first_freeze = assert(body:find(
            "_tmp_2 = _param_first;", second_freeze, true))
        local call = assert(body:find(
            "_titan(L, _mod, NULL, _tmp_2, _tmp_1);",
            first_freeze, true))
        assert.falsy(body:sub(second_freeze, call):find(
            "setsvalue(L", 1, true), body)
        assert.is_true(second_freeze < first_freeze and first_freeze < call)
    end)

    it("retains reordered native results across later collections",
    function()
        with_header([[
            typedef struct lua_State lua_State;
            static void ffi_collect(lua_State *state) {
                lua_gc(state, LUA_GCCOLLECT, 0);
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                record Box
                    text: string
                end

                function increment(x: integer): integer
                    return x + 1
                end

                function make_text(n: integer): string
                    return "alive" .. n
                end

                function make_box(): Box
                    ffi.ffi_collect(L)
                    return Box.new { text = "boxed" }
                end

                function make_callback(): function (integer): (integer)
                    ffi.ffi_collect(L)
                    return increment
                end

                function verify(callback: function (integer): (integer),
                                text: string, box: Box): integer
                    ffi.ffi_collect(L)
                    if text ~= "alive42" or box.text ~= "boxed" then
                        return -1
                    end
                    return callback(41)
                end

                function gc_arguments(): integer
                    return verify {
                        text = make_text(42),
                        box = make_box(),
                        callback = make_callback(),
                    }
                end
            ]], [[
                assert(test.gc_arguments() == 42)
            ]])
        end)
    end)

    it("implements empty and partial nil semantics, including empty records",
    function()
        h.run_coder([[
            record Empty end

            record Defaults
                maybe: integer?
                enabled: boolean
                payload: value
            end

            record Duplicate
                note: string?
                enabled: boolean
            end

            function zero(): integer
                return 5
            end

            function score(maybe: integer?, enabled: boolean,
                           payload: value): integer
                local result = 0
                if not maybe then
                    result = result + 1
                else
                    result = result + (maybe as integer)
                end
                if not enabled then
                    result = result + 10
                end
                if payload == nil then
                    result = result + 100
                end
                return result
            end

            function omissions(): integer
                local empty_literal: Empty = {}
                local empty_new = Empty.new {}
                local defaults_literal: Defaults = {}
                local defaults_new = Defaults.new {}
                local duplicate: Duplicate = {
                    note = "first",
                    note = "last",
                }
                if defaults_literal.maybe or defaults_literal.enabled
                   or defaults_literal.payload ~= nil
                   or defaults_new.maybe or defaults_new.enabled
                   or defaults_new.payload ~= nil
                   or duplicate.note ~= "last"
                   or duplicate.enabled then
                    return -1
                end
                return score {} * 1000 + score { maybe = 4 } + zero {}
            end
        ]], [[
            assert(test.omissions() == 111119)
        ]])
    end)

    it("uses only the first return value for a named slot", function()
        h.run_coder([[
            function pair(): (integer, integer)
                return 7, 99
            end

            function pack(first: integer, second: integer): integer
                return first * 10 + second
            end

            function first_result_only(): integer
                return pack { second = 5, first = pair() }
            end
        ]], [[
            assert(test.first_result_only() == 75)
        ]])
    end)

    it("preserves FFI lexical order, conversions, NULL omission, and void calls",
    function()
        with_header([[
            struct ffi_node;
            typedef int type;
            typedef struct ffi_keyword_holder {
                type when;
            } ffi_keyword_holder;
            static int ffi_trace_value = 0;
            static type repeat = 7;

            static void ffi_reset(void) {
                ffi_trace_value = 0;
            }

            static int ffi_mark(int digit) {
                ffi_trace_value = ffi_trace_value * 10 + digit;
                return digit;
            }

            static int ffi_trace(void) {
                return ffi_trace_value;
            }

            static int ffi_pack(int first, int second, int third) {
                return first * 100 + second * 10 + third;
            }

            static double ffi_convert(double floating, int integral) {
                return floating * 100.0 + integral;
            }

            static int ffi_zero(void) {
                return 7;
            }

            static int ffi_when(int when) {
                return when + 1;
            }

            static type when(type when) {
                return when;
            }

            static int ffi_nullable(struct ffi_node *optional, int required) {
                return optional == 0 ? required : -1;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function ffi_order(): integer
                    ffi.ffi_reset {}
                    local packed: integer = ffi.ffi_pack {
                        third = ffi.ffi_mark { digit = 1 },
                        first = ffi.ffi_mark { digit = 2 },
                        second = ffi.ffi_mark { digit = 3 },
                    }
                    local trace: integer = ffi.ffi_trace {}
                    return trace * 1000 + packed
                end

                function ffi_conversion(): float
                    return ffi.ffi_convert { integral = 2, floating = 3 }
                end

                function ffi_defaults(): integer
                    local zero: integer = ffi.ffi_zero {}
                    local nullable: integer = ffi.ffi_nullable { required = 9 }
                    local keyword: integer = ffi.ffi_when { when = 5 }
                    return zero + nullable + keyword
                end

                function ffi_contextual_keywords(): integer
                    local holder = foreign ffi_keyword_holder.new()
                    holder.when = 5
                    local result: foreign type = ffi.when { when = holder.when }
                    return result + ffi.repeat
                end
            ]], [[
                assert(test.ffi_order() == 123231)
                assert(test.ffi_conversion() == 302.0)
                assert(test.ffi_defaults() == 22)
                assert(test.ffi_contextual_keywords() == 12)
            ]])
        end)
    end)

    it("retains mutable-address copyback after FFI name reordering", function()
        with_header([[
            typedef int ffi_int;
            static void ffi_write(ffi_int *out, int new_value) {
                *out = new_value;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function ffi_copyback(): integer
                    local out: foreign ffi_int = 0 as foreign ffi_int
                    ffi.ffi_write { new_value = 42, out = out }
                    return out as integer
                end
            ]], [[
                assert(test.ffi_copyback() == 42)
            ]])
        end)
    end)

    it("anchors named GC TValue out-parameters after reordered FFI calls",
    function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct TValue TValue;

            static int ffi_named_outparam_finalized = 0;

            static int ffi_named_outparam_gc(lua_State *state) {
                (void)state;
                ffi_named_outparam_finalized = 1;
                return 0;
            }

            static void ffi_named_reset_outparam_finalized(void) {
                ffi_named_outparam_finalized = 0;
            }

            static int ffi_named_was_outparam_finalized(void) {
                return ffi_named_outparam_finalized;
            }

            static void ffi_named_write_gc_value(lua_State *state, void *out) {
                lua_newuserdatauv(state, 0, 0);
                if (luaL_newmetatable(state, "titan_named_outparam_anchor")) {
                    lua_pushcfunction(state, ffi_named_outparam_gc);
                    lua_setfield(state, -2, "__gc");
                }
                lua_setmetatable(state, -2);
                setuvalue(state, (TValue *)out,
                    uvalue(s2v(state->top.p - 1)));
                lua_pop(state, 1);
            }

            static void ffi_named_collect(lua_State *state) {
                lua_gc(state, LUA_GCCOLLECT, 0);
            }

            static int ffi_named_is_userdata(TValue value) {
                return ttisfulluserdata(&value);
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function ffi_named_gc_copyback(): integer
                    local raw: foreign TValue = nil
                    ffi.ffi_named_reset_outparam_finalized {}
                    ffi.ffi_named_write_gc_value { out = raw, state = L }
                    ffi.ffi_named_collect { state = L }
                    if (ffi.ffi_named_was_outparam_finalized {} as integer) ~= 0 then
                        return -1
                    end
                    if (ffi.ffi_named_is_userdata { value = raw } as integer) == 0 then
                        return -2
                    end
                    return 1
                end
            ]], [[
                assert(test.ffi_named_gc_copyback() == 1)
            ]])
        end)
    end)

    it("executes named calls through source-imported declarations", function()
        local ok, err = h.generate_modules({
            na_provider = [[
                record Pair
                    left: integer
                    right: integer
                end

                record Empty end

                function build(left: integer, right: integer): Pair
                    return Pair.new { right = right, left = left }
                end

                function Pair:code(multiplier: integer,
                                   bias: integer): integer
                    return self.left * 1000 + self.right * 100
                        + multiplier * 10 + bias
                end

                function zero(): integer
                    return 5
                end
            ]],
            na_consumer = [[
                local p = import "na_provider"

                function run(): integer
                    local built = p.build { right = 2, left = 1 }
                    local direct = p.Pair.new { right = 4, left = 3 }
                    local empty = p.Empty.new {}
                    local empty_literal: p.Empty = {}
                    return built:code { bias = 4, multiplier = 3 }
                        + direct.left * 10 + direct.right + p.zero {}
                end
            ]],
        }, "na_consumer")
        assert.truthy(ok, err)

        local called, out = h.call("na_consumer", [[
            assert(na_consumer.run() == 1273)
        ]])
        assert.truthy(called, out)
    end)

    it("keeps Lua table calls positional at the generated Lua entry", function()
        h.run_coder([[
            function echo(payload: value): value
                return payload
            end
        ]], [[
            local payload = { x = 1, nested = { 2, 3 } }
            assert(rawequal(test.echo(payload), payload))
            assert(test.echo(payload).nested[2] == 3)
        ]])
    end)
end)
