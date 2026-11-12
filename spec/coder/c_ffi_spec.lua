local temporary = require "spec.support.temporary"
local h = require 'spec.support.helpers'
local driver = require 'titan-compiler.driver'
local platform = require 'titan-compiler.platform'

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local f = assert(io.open(header, "w"))
    f:write(contents)
    f:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

local function c_function_body(csrc, name)
    return assert(csrc:match(
        "[^\n]*" .. name .. "%b()%s*(%b{})"), name)
end

local function native_body(csrc, name)
    return c_function_body(csrc, "test_\\u2133_" .. name .. "_titan")
end

local FIELD_PROJECTION_HEADER = [[
    typedef struct ffi_projection_inner {
        int leaf;
    } ffi_projection_inner;

    typedef struct ffi_projection_left {
        ffi_projection_inner nested;
        double projected;
    } ffi_projection_left;

    typedef struct ffi_projection_right {
        ffi_projection_inner nested;
        double projected;
    } ffi_projection_right;

    static ffi_projection_left ffi_projection_left_value =
        { { 7 }, 701.0 };
    static ffi_projection_right ffi_projection_right_value =
        { { 11 }, 1101.0 };
    static ffi_projection_right *ffi_projection_right_ptr =
        &ffi_projection_right_value;

    static int ffi_projection_physical_sum(void) {
        return (int)(ffi_projection_left_value.projected +
                     ffi_projection_right_value.projected);
    }

    #define projected nested.leaf
]]

local CAST_MACRO_HEADER = [[
    typedef int (*ffi_macro_callback)(int);
    typedef long ffi_macro_long;
    typedef double ffi_macro_double;
    typedef int *ffi_macro_int_ptr;
    typedef int ffi_macro_array[4];

    static int ffi_macro_value = 9;

    static int ffi_macro_add5(int value) {
        return value + 5;
    }

    static int ffi_macro_add7(int value) {
        return value + 7;
    }

    #define FFI_TYPEDEF_CALLBACK \
        ((ffi_macro_callback) ffi_macro_add5)
    #define FFI_DIRECT_CALLBACK \
        ((int (*)(int)) ffi_macro_add7)
    #define FFI_CAST_INT ((long) 41)
    #define FFI_CAST_DOUBLE ((double) 1.5)
    #define FFI_CAST_POINTER ((int *) &ffi_macro_value)
    #define FFI_VOID_CAST ((void) 0)
    #define FFI_ARRAY_CAST ((ffi_macro_array) 0)
]]

describe("C FFI code generation", function()
    after_each(function()
        os.remove("test.o")
        os.remove("test.so")
        os.remove("test.a")
        if not h.verbose then os.remove("test.c") end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("compiles and uses a self-including pragma-once header", function()
        with_header("", function(header)
            local file = assert(io.open(header, "w"))
            assert(file:write('#pragma once\n#include "' ..
                header:gsub("\\", "/") .. '"\n#define CYCLE_MARKER 37\n'))
            assert(file:close())
            h.run_coder(string.format([[
                foreign import "%s"
                function marker(): integer
                    return ffi.CYCLE_MARKER
                end
            ]], header:gsub("\\", "/")), [[
                assert(test.marker() == 37)
            ]])
        end)
    end)

    it("preserves literal format strings under hardened native warnings", function()
        h.with_extra_cflags({ "-O2", "-Wformat", "-Wformat-security", "-Werror" }, function()
            local output = h.compile_and_run([[
                foreign import "stdio.h"
                function direct(): integer
                    return ffi.printf("ok\n")
                end
                local foreign function raw(): int
                    return ffi.printf("ok\n")
                end
                function through_raw(): integer
                    return raw()
                end
            ]], [[
                assert(test.direct() == 3)
                assert(test.through_raw() == 3)
                io.write("LITERAL OK\n")
            ]])
            assert.equal("ok\nok\nLITERAL OK\n", output)
        end)
    end)

    it("preserves literal bytes including NULs, non-ASCII and long foreign arguments", function()
        local bytes = ("\0\255λ??/\\\"\n$VAR"):rep(1024)
        local source = string.format([[
            foreign import "string.h"
            function matches(expected: string): boolean
                return ffi.memcmp(%q, expected, %d) == 0
            end
            local foreign function raw_bytes(expected: const *char): int
                return ffi.memcmp(%q, expected, %d as size_t)
            end
            function raw_matches(expected: string): boolean
                return raw_bytes(expected) == 0
            end
        ]], bytes, #bytes, bytes, #bytes)
        h.run_coder(source, string.format([[
            assert(test.matches(%q))
            assert(test.raw_matches(%q))
        ]], bytes, bytes))
    end)

    it("keeps native adapters for literal pointer round trips", function()
        h.with_extra_cflags({ "-Wpedantic", "-Werror" }, function()
            h.run_coder([[
                foreign import "string.h"
                function matches(expected: string): boolean
                    return ffi.memcmp(
                        (("raw" as foreign const *void) as foreign function(): void) as foreign const *void,
                        expected, 3) == 0
                end
                local foreign function raw_bytes(expected: const *char): int
                    return ffi.memcmp(
                        (("raw" as const *void) as function(): void) as const *void,
                        expected, 3 as size_t)
                end
                function raw_matches(expected: string): boolean
                    return raw_bytes(expected) == 0
                end
            ]], [[
                assert(test.matches("raw"))
                assert(test.raw_matches("raw"))
            ]])
        end)
    end)

    it("keeps effects around literal foreign arguments in written order", function()
        -- The C sink observes argument placement independently of Titan calls.
        with_header([[
            #include <string.h>
            static int ffi_literal_order(int first, const char *middle, int last) {
                return strcmp(middle, "middle") == 0 ? first * 10 + last : -1;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["
                local trace = 0
                local function mark(value: integer): integer
                    trace = trace * 10 + value
                    return value
                end
                function positional(): integer
                    trace = 0
                    local result = ffi.ffi_literal_order(mark(1), "middle", mark(2))
                    return trace * 100 + result
                end
                function named(): integer
                    trace = 0
                    local result = ffi.ffi_literal_order {
                        last = mark(1), middle = "middle", first = mark(2),
                    }
                    return trace * 100 + result
                end
                local function tail(): {integer}
                    return {mark(2)}
                end
                function adjusted(): integer
                    trace = 0
                    local result = ffi.ffi_literal_order(mark(1), "middle", ...tail())
                    return trace * 100 + result
                end
                function indirect(): integer
                    trace = 0
                    local target: foreign function(int, const *char, int): int = ffi.ffi_literal_order
                    local result = target(mark(1), "middle", ...tail())
                    return trace * 100 + result
                end
            ]], [[
                assert(test.positional() == 1212)
                assert(test.named() == 1221)
                assert(test.adjusted() == 1212)
                assert(test.indirect() == 1212)
            ]])
        end)
    end)

    it("passes the built-in Lua state and module pointers to C functions", function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct Udata Udata;
            static int ffi_has_state(lua_State *state) { return state != 0; }
            static int ffi_has_module(Udata *module) { return module != 0; }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function has_state(): integer
                    return ffi.ffi_has_state(L)
                end

                function has_module(): integer
                    return ffi.ffi_has_module(M as foreign *Udata)
                end
            ]], [[
                assert(test.has_state() == 1)
                assert(test.has_module() == 1)
            ]])
        end)
    end)

    it("probes enum carriers under warning-as-error policies", function()
        h.with_extra_cflags({ "-Wall", "-Werror" }, function()
            with_header([[
                typedef enum { FFI_WARN_NEG = -1,
                               FFI_WARN_POS = 1 } ffi_warn_enum;
                enum { FFI_WARN_FIT = 0x7fffffffffffffffULL };
                static const enum { FFI_WARN_CONST_ZERO = 0,
                                    FFI_WARN_CONST_ONE = 1 }
                    ffi_warn_const_object = FFI_WARN_CONST_ONE;
            ]], function(header)
                h.run_coder([[
                    foreign import "]] .. header .. [["
                    function run(input: integer): integer
                        local item: foreign ffi_warn_enum = input as foreign ffi_warn_enum
                        return item as integer
                    end
                    function fit(): integer
                        return ffi.FFI_WARN_FIT as integer
                    end
                    function qualified(): integer
                        return ffi.ffi_warn_const_object as integer
                    end
                ]], [[
                    assert(test.run(-1) == -1)
                    assert(test.fit() == 9223372036854775807)
                    assert(test.qualified() == 1)
                ]])
            end)
        end)
    end)

    it("executes comparisons against direct libuv-shaped UV_E enumerators", function()
        with_header([[
            #define UV_ERRNO_MAP(XX) \
                XX(EIO, -5) XX(EOF, -4095) XX(ECANCELED, -125)
            #define XX(code, value) UV_ ## code = value,
            typedef enum { UV_ERRNO_MAP(XX) } ffi_uv_errno_t;
            #undef XX
            static int ffi_uv_eio(void) { return UV_EIO; }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function errors_match(): boolean
                    local status = ffi.ffi_uv_eio()
                    return (status as integer) == (ffi.UV_EIO as integer)
                        and (status as integer) ~= (ffi.UV_EOF as integer)
                        and (status as integer)
                            ~= (ffi.UV_ECANCELED as integer)
                end
            ]], [[
                assert(test.errors_match())
            ]])
        end)
    end)

    it("uses the compiler-selected enum carrier without wide lowering",
    function()
        with_header([[
            enum ffi_tagged_enum {
                FFI_TAGGED_ZERO = 0,
                FFI_TAGGED_ONE = 1
            };
            typedef enum { FFI_HIGH_ZERO = 0,
                           FFI_HIGH_ONE = 1,
                           FFI_HIGH_VALUE = 0xffffffffU } ffi_high_enum;
            static ffi_high_enum ffi_high_take(ffi_high_enum value) {
                return value;
            }
            static const enum { FFI_CONST_ZERO = 0,
                                FFI_CONST_ONE = 1 }
                ffi_const_enum_object = FFI_CONST_ONE;
            static volatile enum { FFI_VOLATILE_ZERO = 0,
                                   FFI_VOLATILE_ONE = 1 }
                ffi_volatile_enum_object = FFI_VOLATILE_ONE;
            static const enum { FFI_SHARED_A = 1, FFI_SHARED_B = 2 }
                ffi_shared_enum_left = FFI_SHARED_A,
                ffi_shared_enum_right = FFI_SHARED_B;
            typedef enum { FFI_WIDE_ZERO = 0,
                           FFI_WIDE_HIGH = 0x8000000000000000ULL }
                ffi_wide_enum;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["
                function tagged_not(): integer
                    return (~ffi.FFI_TAGGED_ZERO) as integer
                end
                function high(): integer
                    return ffi.ffi_high_take(ffi.FFI_HIGH_VALUE) as integer
                end
                function high_wrap(): integer
                    return (ffi.FFI_HIGH_VALUE + ffi.FFI_HIGH_ONE) as integer
                end
                function qualified_objects(): integer
                    return (ffi.ffi_const_enum_object as integer)
                        + (ffi.ffi_volatile_enum_object as integer)
                end
                function same_anonymous_owner(): integer
                    local item = ffi.ffi_shared_enum_left
                    item = ffi.FFI_SHARED_B
                    item = ffi.ffi_shared_enum_right
                    return item as integer
                end
                function wide_zero(): integer
                    local item = ffi.FFI_WIDE_ZERO
                    item = 7
                    return item as integer
                end
            ]], [[
                assert(test.tagged_not() == -1)
                local high = test.high()
                local high_wrap = test.high_wrap()
                local qualified = test.qualified_objects()
                local same_owner = test.same_anonymous_owner()
                assert(high == 4294967295)
                assert(high_wrap == 0)
                assert(qualified == 2)
                assert(same_owner == 2)
                assert(test.wide_zero() == 7)
            ]])
        end)

        h.with_extra_cflags({ "-fshort-enums", "-Wall", "-Werror" }, function()
            with_header([[
                typedef enum { FFI_SHORT_NEG = -1,
                               FFI_SHORT_MAX = 127 } ffi_short_enum;
                static inline ffi_short_enum ffi_short_take(ffi_short_enum value) {
                    return value;
                }
                typedef ffi_short_enum (*ffi_short_callback)(ffi_short_enum);
                static inline ffi_short_callback ffi_short_pointer(void) {
                    return ffi_short_take;
                }
                typedef enum { FFI_USHORT_ZERO = 0,
                               FFI_USHORT_MAX = 255 } ffi_ushort_enum;
                static inline ffi_ushort_enum ffi_ushort_take(
                    ffi_ushort_enum value) {
                    return value;
                }
            ]], function(header)
                h.run_coder([[
                    foreign import "]] .. header .. [["
                    function short(x: integer): integer
                        local item: foreign ffi_short_enum =
                            x as foreign ffi_short_enum
                        return ffi.ffi_short_take(item) as integer
                    end
                    function short_pointer(x: integer): integer
                        local callback = ffi.ffi_short_pointer()
                        return callback(x as foreign ffi_short_enum) as integer
                    end
                    function ushort(x: integer): integer
                        local item: foreign ffi_ushort_enum =
                            x as foreign ffi_ushort_enum
                        return ffi.ffi_ushort_take(item) as integer
                    end
                ]], [[
                    assert(test.short(-128) == -128)
                    assert(test.short(-1) == -1)
                    assert(test.short(127) == 127)
                    assert(not pcall(test.short, -129))
                    assert(not pcall(test.short, 128))
                    assert(test.short_pointer(-128) == -128)
                    assert(test.short_pointer(127) == 127)
                    assert(not pcall(test.short_pointer, -129))
                    assert(not pcall(test.short_pointer, 128))
                    assert(test.ushort(0) == 0)
                    assert(test.ushort(255) == 255)
                    assert(not pcall(test.ushort, -1))
                    assert(not pcall(test.ushort, 256))
                ]])
            end)
        end)
    end)

    it("retains an enum typedef through a later tag-name macro", function()
        with_header([[
            enum ffi_typedef_context_tag { FFI_TYPEDEF_CONTEXT_VALUE = 17 };
            typedef enum ffi_typedef_context_tag ffi_typedef_context;
            static ffi_typedef_context ffi_typedef_context_get(void) {
                return FFI_TYPEDEF_CONTEXT_VALUE;
            }
            #define ffi_typedef_context_tag ffi_typedef_context_shadow
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["
                function run(): integer
                    return ffi.ffi_typedef_context_get() as integer
                end
            ]], [[
                assert(test.run() == 17)
            ]])
        end)
    end)

    it("uses the active replacement of a macro-shadowed C typedef",
    function()
        with_header([[
            typedef int ffi_public_number;
            typedef double ffi_replacement_number;
            #define ffi_public_number ffi_replacement_number
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function identity(x: float): float
                    local converted =
                        x as foreign ffi_public_number
                    return converted as float
                end
            ]], [[
                assert(test.identity(1.25) == 1.25)
            ]])
        end)
    end)

    it("executes self-referential and non-self object and callable aliases",
    function()
        with_header([[
            #include <stdio.h>
            extern FILE *const s;
            FILE *const s = NULL;
            #define s (s)
            #define stream_alias (s)
            #define stream_chain stream_alias
            static int values[3] = { 7, 11, 13 };
            #define values_alias (values)
            static int add_one(int value) { return value + 1; }
            #define function_alias (add_one)
            static int (*const callback)(int) = add_one;
            #define callback (callback)
            #define callback_alias callback
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function streams_are_null(): boolean
                    local original: foreign *FILE = ffi.s
                    local alias: foreign *FILE = ffi.stream_alias
                    local chain: foreign *FILE = ffi.stream_chain
                    return original == nil and alias == original
                        and chain == original
                end

                function read_aliases(): integer
                    return ffi.function_alias(ffi.values_alias[0])
                        + ffi.callback(ffi.values_alias[1])
                        + ffi.callback_alias(ffi.values_alias[2])
                end
            ]], [[
                assert(test.streams_are_null())
                assert(test.read_aliases() == 34)
            ]])
        end)
    end)

    it("passes host-supported standard stream expressions to fwrite", function()
        local stdout_expression, stderr_expression = "ffi.stdout", "ffi.stderr"
        if platform.windows then
            -- UCRT's call-expression macros are not imported values; their
            -- declared accessor remains an ordinary supported foreign call.
            stdout_expression = "ffi.__acrt_iob_func(1)"
            stderr_expression = "ffi.__acrt_iob_func(2)"
        end
        h.run_coder(string.format([[
            foreign import "stdio.h"

            function write_empty(): boolean
                return ffi.fwrite("", 1, 0, %s) == 0
                    and ffi.fwrite("", 1, 0, %s) == 0
            end
        ]], stdout_expression, stderr_expression), [[ assert(test.write_empty()) ]])
    end)

    it("executes declared UCRT-style stream accessors directly", function()
        with_header([[
            typedef struct ffi_crt_stream { int marker; } ffi_crt_stream;
            static ffi_crt_stream ffi_crt_streams[3] = { { 0 }, { 17 }, { 29 } };
            static ffi_crt_stream *ffi_crt_iob_func(unsigned index) {
                return &ffi_crt_streams[index];
            }
            #define ffi_crt_stdout (ffi_crt_iob_func(1))
            #define ffi_crt_stderr (ffi_crt_iob_func(2))
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function read_streams(): integer
                    return ffi.ffi_crt_iob_func(1).marker
                        + ffi.ffi_crt_iob_func(2).marker
                end
            ]], [[ assert(test.read_streams() == 46) ]])
        end)
    end)

    it("preserves Udata pointers as full-userdata TValues", function()
        with_header([[
            typedef struct Udata Udata;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function module_value(): value
                    return M as foreign *Udata
                end

                function same_module(item: value): boolean
                    local module = item as foreign *Udata
                    return module == (M as foreign *Udata)
                end

                function null_roundtrip(): boolean
                    local module: foreign *Udata = nil
                    local item: value = module
                    return item == nil and (item as foreign *Udata) == nil
                end
            ]], [[
                assert(rawequal(test.module_value(), test))
                assert(test.same_module(test))
                assert(test.null_roundtrip())

                local captured = 1
                local function closure() return captured end
                local light = debug.upvalueid(closure, 1)
                local ok, err = pcall(test.same_module, light)
                assert(not ok)
                assert(tostring(err):match("expected C userdata pointer"))
            ]])
        end)
    end)

    it("keeps top-level owned C state rooted in the module", function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct ffi_state { int count; } ffi_state;
            static int ffi_increment(ffi_state *state) {
                return ++state->count;
            }
            static void ffi_collect(lua_State *L) {
                lua_gc(L, LUA_GCCOLLECT, 0);
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local state = foreign ffi_state.new()

                function state_value(): value
                    return state
                end

                function increment(): integer
                    ffi.ffi_collect(L)
                    return ffi.ffi_increment(state) as integer
                end
            ]], [[
                local weak = setmetatable({ test.state_value() }, {
                    __mode = "v",
                })
                collectgarbage("collect")
                collectgarbage("collect")
                assert(weak[1] ~= nil)
                assert(rawequal(weak[1], test.state_value()))
                assert(test.increment() == 1)
                assert(test.increment() == 2)
            ]])
        end)
    end)

    it("round-trips by-value TValue through C helpers", function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct TString TString;
            typedef struct TValue TValue;
            typedef struct ffi_coro ffi_coro;

            static TValue ffi_value_echo(TValue value) {
                return value;
            }

            static int ffi_value_kind(TValue value) {
                if (ttisnil(&value)) return 1;
                if (ttisboolean(&value)) return 2;
                if (ttisinteger(&value)) return 3;
                if (ttisfloat(&value)) return 4;
                if (ttisstring(&value)) return 5;
                if (ttistable(&value)) return 6;
                if (ttisfunction(&value)) return 7;
                if (ttisfulluserdata(&value)) return 8;
                return 0;
            }

            static int ffi_const_value_kind(const TValue *value) {
                return value ? ffi_value_kind(*value) : 0;
            }

            static void ffi_collect(lua_State *L) {
                lua_gc(L, 2, 0);
            }

            static TValue ffi_make_gc_payload(lua_State *L) {
                TValue value;
                const char *payload = "anchored raw TValue payload";
                TString *str = luaS_newlstr(L, payload, sizeof("anchored raw TValue payload") - 1);
                setsvalue(L, &value, str);
                return value;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                record Box
                    x: integer
                end

                local function echo(x: value): value
                    return x
                end

                local function coro_entry(func: function (value): (value), co: foreign *ffi_coro)
                end

                function nil_rounds(): value
                    return ffi.ffi_value_echo(nil)
                end

                function integer_rounds(): value
                    return ffi.ffi_value_echo(42)
                end

                function string_rounds(): value
                    return ffi.ffi_value_echo("titan")
                end

                function array_kind(): integer
                    local xs = { 1, 2, 3 }
                    return ffi.ffi_value_kind(xs)
                end

                function map_kind(): integer
                    local xs = { ["a"] = 1 }
                    return ffi.ffi_value_kind(xs)
                end

                function record_kind(): integer
                    return ffi.ffi_value_kind(Box.new(17))
                end

                function function_rounds(): value
                    return ffi.ffi_value_echo(echo)
                end

                function c_pointer_function_kind(): integer
                    return ffi.ffi_value_kind(coro_entry)
                end

                function raw_local_kind(): integer
                    local raw: foreign TValue = 42
                    return ffi.ffi_value_kind(raw)
                end

                function raw_pointer_kind(): integer
                    local raw: foreign TValue = "through pointer"
                    local p: foreign const *TValue = raw
                    return (ffi.ffi_const_value_kind(p) as integer)
                        + (ffi.ffi_const_value_kind(raw) as integer)
                        + (ffi.ffi_const_value_kind("direct" as foreign TValue) as integer)
                end

                function raw_back(): value
                    local raw: foreign TValue = "back"
                    return raw
                end

                function raw_gc_survives(): value
                    local raw: foreign TValue = ffi.ffi_make_gc_payload(L)
                    ffi.ffi_collect(L)
                    return raw
                end
            ]], [[
                assert(test.nil_rounds() == nil)
                assert(test.integer_rounds() == 42)
                assert(test.string_rounds() == "titan")
                -- A C TValue is a boxed boundary: Arrays cross it as their
                -- canonical full-userdata proxies, while Maps remain tables.
                assert(test.array_kind() == 8)
                assert(test.map_kind() == 6)
                assert(test.record_kind() == 8)
                assert(test.function_rounds()("ok") == "ok")
                assert(test.c_pointer_function_kind() == 7)
                assert(test.raw_local_kind() == 3)
                assert(test.raw_pointer_kind() == 15)
                assert(test.raw_back() == "back")
                assert(test.raw_gc_survives() == "anchored raw TValue payload")
            ]])
        end)
    end)

    it("indexes C arrays, C pointers, and counted owned C arrays with 0-based indices", function()
        with_header([[
            typedef int ffi_int;
            static int ffi_values[4] = { 10, 20, 30, 40 };
            static int *ffi_ptr = ffi_values;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function sum(): integer
                    local owner = foreign ffi_int.new_array(3)
                    ffi.ffi_values[2] = 12
                    owner[1] = 5
                    return (ffi.ffi_values[2] as integer)
                        + (ffi.ffi_ptr[3] as integer)
                        + (owner[1] as integer)
                        + #ffi.ffi_values
                        + #owner
                end
            ]], [[
                assert(test.sum() == 64)
            ]])
        end)
    end)

    it("prepares mixed C lvalues before RHS and stores them left to right", function()
        with_header([[
            typedef int ffi_int;
            typedef struct ffi_point { int x; } ffi_point;
            typedef struct ffi_inner { int x; } ffi_inner;
            typedef struct ffi_owner {
                ffi_inner inner;
                int values[2];
            } ffi_owner;
            typedef struct ffi_link {
                ffi_point *next;
            } ffi_link;
            typedef struct ffi_outer {
                ffi_point *ptr_field;
            } ffi_outer;
            typedef struct ffi_pointer_array {
                ffi_point *items[2];
            } ffi_pointer_array;
            static int ffi_values[2] = { 10, 20 };
            static ffi_point ffi_point_value = { 30 };
            static ffi_point *ffi_point_ptr = &ffi_point_value;
            static ffi_point *ffi_null_point = 0;
            static ffi_link *ffi_null_link_ptr = 0;
            static int ffi_by_value_trace = 0;
            static void ffi_reset_by_value_trace(void) {
                ffi_by_value_trace = 0;
            }
            static ffi_outer ffi_make_outer(void) {
                ffi_by_value_trace = ffi_by_value_trace * 10 + 1;
                ffi_outer result = { &ffi_point_value };
                return result;
            }
            static int ffi_outer_rhs(void) {
                ffi_by_value_trace = ffi_by_value_trace * 10 + 2;
                return 818;
            }
            static ffi_pointer_array ffi_make_pointer_array(void) {
                ffi_by_value_trace = ffi_by_value_trace * 10 + 1;
                ffi_pointer_array result = {
                    { &ffi_point_value, &ffi_point_value }
                };
                return result;
            }
            static int ffi_pointer_array_index(void) {
                ffi_by_value_trace = ffi_by_value_trace * 10 + 2;
                return 0;
            }
            static int ffi_pointer_array_rhs(void) {
                ffi_by_value_trace = ffi_by_value_trace * 10 + 3;
                return 828;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                seen: integer = 0
                local owner_array = foreign ffi_int.new_array(2)
                local nested_owner = foreign ffi_owner.new()

                local function static_index(): integer
                    seen = seen * 10 + 1
                    return 0
                end

                local function point(good: boolean): foreign *ffi_point
                    seen = seen * 10 + 2
                    if good then return ffi.ffi_point_ptr end
                    return ffi.ffi_null_point
                end

                local function owned_index(): integer
                    seen = seen * 10 + 3
                    return 0
                end

                local function owned_bad_index(): integer
                    seen = seen * 10 + 3
                    return 2
                end

                local function rhs1(v: integer): integer
                    seen = seen * 10 + 4
                    return v
                end

                local function rhs2(v: integer): integer
                    seen = seen * 10 + 5
                    return v
                end

                local function rhs3(v: integer): integer
                    seen = seen * 10 + 6
                    return v
                end

                local function intermediate_null_base(): foreign *ffi_link
                    seen = seen * 10 + 1
                    return ffi.ffi_null_link_ptr
                end

                local function intermediate_rhs(): integer
                    seen = seen * 10 + 2
                    return 808
                end

                local function swap_nested_owner(f: value): integer
                    nested_owner = foreign ffi_owner.new()
                    nested_owner.inner.x = 900
                    nested_owner.values[0] = 901
                    local result: integer = f()
                    return result
                end

                function run_single_c(): integer
                    seen = 0
                    point(true).x = rhs1(808)
                    return seen
                end

                function fail_intermediate_null(): nil
                    seen = 0
                    intermediate_null_base().next.x = intermediate_rhs()
                    return nil
                end

                function run_by_value_outer(): integer
                    ffi.ffi_reset_by_value_trace()
                    ffi.ffi_make_outer().ptr_field.x = ffi.ffi_outer_rhs()
                    return ffi.ffi_by_value_trace as integer
                end

                function run_by_value_pointer_array(): integer
                    ffi.ffi_reset_by_value_trace()
                    ffi.ffi_make_pointer_array().items[
                        ffi.ffi_pointer_array_index()
                    ].x = ffi.ffi_pointer_array_rhs()
                    return ffi.ffi_by_value_trace as integer
                end

                function run_mixed(): integer
                    seen = 0
                    ffi.ffi_values[static_index()], point(true).x,
                        owner_array[owned_index()] =
                        rhs1(101), rhs2(202), rhs3(303)
                    return seen
                end

                function fail_mixed(): nil
                    seen = 0
                    ffi.ffi_values[static_index()], point(false).x,
                        owner_array[owned_index()] =
                        rhs1(404), rhs2(505), rhs3(606)
                    return nil
                end

                function fail_final_bounds(): nil
                    seen = 0
                    ffi.ffi_values[static_index()], point(true).x,
                        owner_array[owned_bad_index()] =
                        rhs1(414), rhs2(515), rhs3(616)
                    return nil
                end

                function static_value(): integer
                    return ffi.ffi_values[0] as integer
                end

                function point_value(): integer
                    return ffi.ffi_point_ptr.x as integer
                end

                function owned_value(): integer
                    return owner_array[0] as integer
                end

                function observed(): integer
                    return seen
                end

                function reset_nested_owner(): nil
                    nested_owner = foreign ffi_owner.new()
                    nested_owner.inner.x = 30
                    nested_owner.values[0] = 40
                    return nil
                end

                function nested_owner_value(): value
                    return nested_owner
                end

                function assign_nested(f: value): nil
                    ffi.ffi_values[1], nested_owner.inner.x =
                        111, swap_nested_owner(f)
                    return nil
                end

                function assign_nested_array(f: value): nil
                    ffi.ffi_values[1], nested_owner.values[0] =
                        112, swap_nested_owner(f)
                    return nil
                end

                function nested_static_value(): integer
                    return ffi.ffi_values[1] as integer
                end

                function current_nested_value(): integer
                    return nested_owner.inner.x as integer
                end

                function current_nested_array_value(): integer
                    return nested_owner.values[0] as integer
                end

                function read_nested_owner(item: value): integer
                    local owner: owned *ffi_owner =
                        foreign ffi_owner.new()
                    owner = item
                    return owner.inner.x as integer
                end

                function read_nested_array(item: value): integer
                    local owner: owned *ffi_owner =
                        foreign ffi_owner.new()
                    owner = item
                    return owner.values[0] as integer
                end
            ]], [[
                -- Static-array index, pointer base, and owned-array index are
                -- evaluated in lexical LHS order before every RHS expression.
                assert(test.run_mixed() == 123456)
                assert(test.static_value() == 101)
                assert(test.point_value() == 202)
                assert(test.owned_value() == 303)

                local ok, err = pcall(test.fail_mixed)
                assert(not ok)
                assert(tostring(err):find(
                    "NULL C pointer", 1, true), tostring(err))
                assert(test.observed() == 123456)

                -- Target validation is delayed until its left-to-right store.
                -- The first store commits before the NULL pointer rejects the
                -- second, while the third target remains unchanged.
                assert(test.static_value() == 404)
                assert(test.point_value() == 202)
                assert(test.owned_value() == 303)

                local bounds_ok, bounds_err =
                    pcall(test.fail_final_bounds)
                assert(not bounds_ok)
                assert(tostring(bounds_err):find(
                    "C index", 1, true), tostring(bounds_err))
                assert(test.observed() == 123456)
                -- The final owned-array bounds check occurs at its store:
                -- both earlier stores commit after every target and RHS ran.
                assert(test.static_value() == 414)
                assert(test.point_value() == 515)
                assert(test.owned_value() == 303)

                -- Single C assignments prepare their complete target before
                -- evaluating the RHS.
                assert(test.run_single_c() == 24)
                assert(test.point_value() == 808)

                -- A NULL dereference needed to reach the final target is an
                -- intermediate LHS read, so it fails during target
                -- preparation and the RHS does not run.
                local intermediate_ok, intermediate_err =
                    pcall(test.fail_intermediate_null)
                assert(not intermediate_ok)
                assert(tostring(intermediate_err):find(
                    "NULL C pointer", 1, true), tostring(intermediate_err))
                assert(test.observed() == 1)

                -- A by-value aggregate may be copied while preparing a nested
                -- target in order to read and freeze the pointer it contains.
                assert(test.run_by_value_outer() == 12)
                assert(test.point_value() == 818)

                -- The same rule composes through a fixed array of pointers:
                -- aggregate creation and index evaluation both precede RHS.
                assert(test.run_by_value_pointer_array() == 123)
                assert(test.point_value() == 828)

                -- A nested target must retain its owning COwned userdata, not
                -- just a C expression that will be re-evaluated at store time.
                test.reset_nested_owner()
                local old = test.nested_owner_value()
                local weak = setmetatable({ old }, { __mode = "v" })
                old = nil
                collectgarbage("collect")
                assert(weak[1] ~= nil)

                local saved
                test.assign_nested(function()
                    collectgarbage("collect")
                    collectgarbage("collect")
                    assert(weak[1] ~= nil,
                        "prepared nested C owner was collected")
                    saved = weak[1]
                    return 707
                end)

                assert(test.nested_static_value() == 111)
                assert(test.read_nested_owner(saved) == 707)
                assert(test.current_nested_value() == 900)

                -- The same owner and address freezing applies when the nested
                -- target is a fixed CArray field rather than a struct field.
                test.reset_nested_owner()
                local old_array_owner = test.nested_owner_value()
                local weak_array = setmetatable(
                    { old_array_owner }, { __mode = "v" })
                old_array_owner = nil
                collectgarbage("collect")
                assert(weak_array[1] ~= nil)

                local saved_array_owner
                test.assign_nested_array(function()
                    collectgarbage("collect")
                    collectgarbage("collect")
                    assert(weak_array[1] ~= nil,
                        "prepared nested CArray owner was collected")
                    saved_array_owner = weak_array[1]
                    return 717
                end)

                assert(test.nested_static_value() == 112)
                assert(test.read_nested_array(saved_array_owner) == 717)
                assert(test.current_nested_array_value() == 901)
            ]])
        end)
    end)

    it("bounds-checks static C arrays", function()
        with_header([[
            static int ffi_values[4] = { 10, 20, 30, 40 };
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function bad(): integer
                    return ffi.ffi_values[4] as integer
                end
            ]], [[
                test.bad()
            ]], "C index")
        end)
    end)

    it("reads C struct fields and fields through C pointers and owned objects", function()
        with_header([[
            typedef struct ffi_point { int x; int y; } ffi_point;
            static ffi_point ffi_origin = { 7, 11 };
            static ffi_point *ffi_origin_ptr = &ffi_origin;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function sum(): integer
                    return (ffi.ffi_origin.x as integer)
                        + (ffi.ffi_origin_ptr.y as integer)
                end

                function zero(): integer
                    local p = foreign ffi_point.new()
                    p.x = 19
                    p.y = 23
                    return (p.x as integer) + (p.y as integer)
                end
            ]], [[
                assert(test.sum() == 18)
                assert(test.zero() == 42)
            ]])
        end)
    end)

    it("emits and executes public dotted field-macro spellings", function()
        with_header(FIELD_PROJECTION_HEADER, function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function read_projected(): integer
                    return (ffi.ffi_projection_left_value.projected as integer)
                        + (ffi.ffi_projection_right_ptr.projected as integer)
                end

                function write_projected(): integer
                    ffi.ffi_projection_left_value.projected = 17
                    ffi.ffi_projection_right_ptr.projected = 23
                    return (ffi.ffi_projection_left_value.projected as integer)
                        + (ffi.ffi_projection_right_ptr.projected as integer)
                end

                function read_physical(): integer
                    return ffi.ffi_projection_physical_sum() as integer
                end
            ]], [[
                assert(test.read_projected() == 18)
                assert(test.read_physical() == 1802)
                assert(test.write_projected() == 40)
                assert(test.read_projected() == 40)
                assert(test.read_physical() == 1802)
            ]])

            local file = assert(io.open("test.c", "r"))
            local generated = file:read("*a")
            file:close()
            assert.truthy(generated:find(".projected", 1, true))
            assert.truthy(generated:find("->projected", 1, true))
            assert.falsy(generated:find(".nested.leaf", 1, true))
            assert.falsy(generated:find("->nested.leaf", 1, true))
        end)
    end)

    it("uses the final hoisted field-macro state across ordered imports",
    function()
        with_header([[
            typedef struct ffi_final_inner {
                int leaf;
            } ffi_final_inner;
            typedef struct ffi_final_record {
                ffi_final_inner nested;
                ffi_final_inner projected;
            } ffi_final_record;
            static ffi_final_record ffi_final_value = { { 7 }, { 99 } };
        ]], function(base_header)
            with_header([[
                #define projected nested.leaf
            ]], function(macro_header)
                h.run_coder([[
                    foreign import "]] .. base_header .. [["
                    local reader = function(): integer
                        return ffi.ffi_final_value.projected as integer
                    end
                    foreign import "]] .. macro_header .. [["

                    function read_projected(): integer
                        return reader()
                    end
                ]], [[
                    assert(test.read_projected() == 7)
                ]])
            end)
        end)
    end)

    it("re-expands field macros after a later dependency redefinition",
    function()
        with_header([[
            typedef struct ffi_rescan_leaf {
                int value;
            } ffi_rescan_leaf;
            typedef struct ffi_rescan_nested {
                ffi_rescan_leaf leaf;
            } ffi_rescan_nested;
            typedef struct ffi_rescan_other {
                int leaf;
            } ffi_rescan_other;
            typedef struct ffi_rescan_record {
                ffi_rescan_nested nested;
                ffi_rescan_other other;
            } ffi_rescan_record;
            static ffi_rescan_record ffi_rescan_value = {
                { { 7 } }, { 23 }
            };
        ]], function(base_header)
            with_header([[
                #define alias nested
                #define projected alias.leaf
            ]], function(macro_header)
                with_header([[
                    #undef alias
                    #define alias other
                ]], function(redefine_header)
                    h.run_coder([[
                        foreign import "]] .. base_header .. [["
                        foreign import "]] .. macro_header .. [["
                        local reader = function(): integer
                            return ffi.ffi_rescan_value.projected as integer
                        end
                        foreign import "]] .. redefine_header .. [["

                        function read_reexpanded(): integer
                            return reader()
                        end
                    ]], [[
                        assert(test.read_reexpanded() == 23)
                    ]])
                end)
            end)
        end)
    end)

    it("uses a physical field after a later imported macro undefinition",
    function()
        with_header([[
            typedef struct ffi_undef_leaf {
                int value;
            } ffi_undef_leaf;
            typedef struct ffi_undef_nested {
                ffi_undef_leaf leaf;
            } ffi_undef_nested;
            typedef struct ffi_undef_record {
                ffi_undef_nested nested;
                int projected;
            } ffi_undef_record;
            static ffi_undef_record ffi_undef_value = { { { 7 } }, 99 };
        ]], function(base_header)
            with_header([[
                #define projected nested.leaf
            ]], function(macro_header)
                with_header([[
                    #undef projected
                ]], function(undef_header)
                    h.run_coder([[
                        foreign import "]] .. base_header .. [["
                        foreign import "]] .. macro_header .. [["
                        local reader = function(): integer
                            return ffi.ffi_undef_value.projected as integer
                        end
                        foreign import "]] .. undef_header .. [["

                        function read_physical(): integer
                            return reader()
                        end
                    ]], [[
                        assert(test.read_physical() == 99)
                    ]])
                end)
            end)
        end)
    end)

    it("emits and executes public scalar cast-macro spellings", function()
        with_header(CAST_MACRO_HEADER, function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function use_cast_macros(): integer
                    local typedef_callback: foreign ffi_macro_callback =
                        ffi.FFI_TYPEDEF_CALLBACK
                    local direct_callback: foreign ffi_macro_callback =
                        ffi.FFI_DIRECT_CALLBACK
                    local count: foreign ffi_macro_long = ffi.FFI_CAST_INT
                    local fraction: foreign ffi_macro_double = ffi.FFI_CAST_DOUBLE
                    local pointer: foreign ffi_macro_int_ptr = ffi.FFI_CAST_POINTER

                    if typedef_callback ~= direct_callback
                       and count == ffi.FFI_CAST_INT
                       and fraction < 2.0
                       and pointer == ffi.FFI_CAST_POINTER then
                        return (typedef_callback(1) as integer)
                            + (direct_callback(1) as integer)
                            + (pointer[0] as integer)
                            + (count as integer)
                    end
                    return 0
                end
            ]], [[
                assert(test.use_cast_macros() == 64)
            ]])

            local file = assert(io.open("test.c", "r"))
            local generated = file:read("*a")
            file:close()
            for _, name in ipairs({
                "FFI_TYPEDEF_CALLBACK",
                "FFI_DIRECT_CALLBACK",
                "FFI_CAST_INT",
                "FFI_CAST_DOUBLE",
                "FFI_CAST_POINTER",
            }) do
                assert.truthy(generated:find(name, 1, true), name)
            end
        end)
    end)

    it("executes floating literal macros and native infinity and NaN constants",
    function()
        with_header([[
            #include <math.h>
            #define FFI_FLOAT_EXP (-1e3F)
            #define FFI_DOUBLE_EXP 1E-3
            #define FFI_LONG_DOUBLE_HEX (+0x1.8p-2L)
            #define FFI_FLOAT_MIXED (3 * 1.5f)
            #define FFI_FLOAT_COMPARISON (1.5f < 3)
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["
                function read(): boolean
                    local infinity = ffi.INFINITY as float
                    local nan = ffi.NAN as float
                    return ffi.FFI_FLOAT_EXP == -1000.0
                        and ffi.FFI_DOUBLE_EXP == 0.001
                        and ffi.FFI_LONG_DOUBLE_HEX == 0.375
                        and ffi.FFI_FLOAT_MIXED == 4.5
                        and ffi.FFI_FLOAT_COMPARISON == 1
                        and infinity > 1e100 and infinity == infinity * 2.0
                        and nan ~= nan
                end
            ]], [[ assert(test.read()) ]])
        end)
    end)

    it("executes real POSIX signal disposition macro values", function()
        h.run_coder([[
            foreign import "signal.h"

            function signal_dispositions_differ(): boolean
                local default_handler = ffi.SIG_DFL
                local ignored_handler = ffi.SIG_IGN
                return default_handler ~= ignored_handler
            end
        ]], [[
            assert(test.signal_dispositions_differ())
        ]])
    end)

    it("executes a read of the real POSIX errno accessor macro", function()
        with_header([[
            #include <errno.h>
            static void ffi_set_errno(int requested) { errno = requested; }
        ]], function(header)
            h.run_coder([[
                foreign import "errno.h"
                foreign import "]] .. header .. [["

                function current_errno(): integer
                    ffi.ffi_set_errno(37)
                    return ffi.errno
                end
            ]], [[
                assert(test.current_errno() == 37)
            ]])
        end)
    end)

    it("generates field access for named C structs completed after forward typedefs", function()
        with_header([[
            typedef struct ffi_node ffi_node;
            typedef ffi_node *ffi_node_ref;
            struct ffi_node { int x; ffi_node *next; };
            static ffi_node ffi_tail = { 5, 0 };
            static ffi_node ffi_head = { 7, &ffi_tail };
            static ffi_node *ffi_head_ptr = &ffi_head;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local function next_node(): foreign ffi_node_ref
                    return ffi.ffi_head_ptr.next
                end

                function sum(): integer
                    return (ffi.ffi_head_ptr.x as integer)
                        + (next_node().x as integer)
                end
            ]], [[
                assert(test.sum() == 12)
            ]])
        end)
    end)

    it("generates sizeof, alignof, source pointer types, and address coercions", function()
        with_header([[
            typedef int ffi_int;
            typedef struct TValue TValue;
            static int ffi_read_const_int(const int *p) { return *p + 1; }
            static ffi_int ffi_make_int(void) { return 18; }
            static int ffi_has_const_ptr(const void *p) { return p != 0; }
            static int ffi_has_const_tvalue(const TValue *p) { return p != 0; }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                local function read_pointer(p: foreign const *ffi_int): integer
                    return ffi.ffi_read_const_int(p) as integer
                end

                function sum(v: value): integer
                    local x: foreign ffi_int = 41 as foreign ffi_int
                    return (foreign ffi_int.sizeof as integer)
                        + (foreign ffi_int.alignof as integer)
                        + (ffi.ffi_read_const_int(x) as integer)
                        + read_pointer(x)
                        + (ffi.ffi_has_const_ptr(x) as integer)
                        + (ffi.ffi_has_const_tvalue(v as foreign TValue) as integer)
                end

                function rvalue_const_pointer(): integer
                    return ffi.ffi_read_const_int(41 as foreign ffi_int) as integer
                end

                function call_result_const_pointer(): integer
                    return ffi.ffi_read_const_int(ffi.ffi_make_int()) as integer
                end
            ]], [[
                local expected = 4 + 4 + 42 + 42 + 1 + 1
                assert(test.sum("rooted") == expected)
                assert(test.rvalue_const_pointer() == 42)
                assert(test.call_result_const_pointer() == 19)
            ]])
        end)
    end)

    it("generates address coercions for mutable C out-parameters", function()
        with_header([[
            typedef int ffi_int;
            typedef struct TValue TValue;
            static int ffi_write_int(ffi_int *p) { *p = 17; return 1; }
            static int ffi_write_void(void *p) { *(ffi_int *)p = 23; return 1; }
            static int ffi_write_value(void *p) {
                setivalue((TValue *)p, 77);
                return 1;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function write_int(): integer
                    local x: foreign ffi_int = 0 as foreign ffi_int
                    ffi.ffi_write_int(x)
                    return x as integer
                end

                function write_void(): integer
                    local x: foreign ffi_int = 0 as foreign ffi_int
                    ffi.ffi_write_void(x)
                    return x as integer
                end

                function write_value(): value
                    local raw: foreign TValue = nil
                    ffi.ffi_write_value(raw)
                    return raw
                end
            ]], [[
                assert(test.write_int() == 17)
                assert(test.write_void() == 23)
                assert(test.write_value() == 77)
            ]])
        end)
    end)

    it("anchors GC TValue out-parameters before later calls can collect", function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct TValue TValue;

            static int ffi_outparam_finalized = 0;

            static int ffi_outparam_gc(lua_State *L) {
                (void)L;
                ffi_outparam_finalized = 1;
                return 0;
            }

            static void ffi_reset_outparam_finalized(void) {
                ffi_outparam_finalized = 0;
            }

            static int ffi_was_outparam_finalized(void) {
                return ffi_outparam_finalized;
            }

            static void ffi_write_gc_value(lua_State *L, void *out) {
                lua_newuserdatauv(L, 0, 0);
                if(luaL_newmetatable(L, "titan_ffi_outparam_anchor")) {
                    lua_pushcfunction(L, ffi_outparam_gc);
                    lua_setfield(L, -2, "__gc");
                }
                lua_setmetatable(L, -2);
                setuvalue(L, (TValue *)out, uvalue(s2v(L->top.p - 1)));
                lua_pop(L, 1);
            }

            static void ffi_collect(lua_State *L) {
                lua_gc(L, 2, 0);
            }

            static int ffi_is_userdata(TValue value) {
                return ttisfulluserdata(&value);
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function survives_gc_check_after_write(): integer
                    local raw: foreign TValue = nil
                    ffi.ffi_reset_outparam_finalized()
                    ffi.ffi_write_gc_value(L, raw)
                    ffi.ffi_collect(L)
                    if (ffi.ffi_was_outparam_finalized() as integer) ~= 0 then
                        return -1
                    end
                    if (ffi.ffi_is_userdata(raw) as integer) == 0 then
                        return -2
                    end
                    return 1
                end
            ]], [[
                assert(test.survives_gc_check_after_write() == 1)
            ]])
        end)
    end)

    it("preserves typedef spelling for owned anonymous C structs", function()
        with_header([[
            typedef struct { int x; int y; } ffi_point;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function sum(): integer
                    local p = foreign ffi_point.new()
                    p.x = 17
                    p.y = 25
                    return (p.x as integer) + (p.y as integer)
                end
            ]], [[
                assert(test.sum() == 42)
            ]])
        end)
    end)

    it("passes owned C arrays and Titan strings to C vararg functions", function()
        with_header([[
            #include <stdarg.h>
            typedef char ffi_char;

            static int ffi_vararg_string_length(int marker, ...) {
                const char *value;
                int length = 0;
                va_list args;
                (void)marker;
                va_start(args, marker);
                value = va_arg(args, const char *);
                va_end(args);
                while (value[length] != '\0') length++;
                return length;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function formatted_len(s: string): integer
                    return ffi.ffi_vararg_string_length(0, s)
                end

                function formatted_owned_len(): integer
                    local msg = foreign ffi_char.new_array(3)
                    msg[0] = 79 as foreign ffi_char
                    msg[1] = 75 as foreign ffi_char
                    msg[2] = 0 as foreign ffi_char
                    return ffi.ffi_vararg_string_length(0, msg)
                end
            ]], [[
                assert(test.formatted_len("abc") == 3)
                assert(test.formatted_len("titan") == 5)
                assert(test.formatted_owned_len() == 2)
            ]])
        end)
    end)

    it("uses runtime truthiness for C pointer typedefs", function()
        with_header([[
            typedef int *ffi_iptr;
            static int ffi_value = 42;
            static ffi_iptr ffi_null = 0;
            static ffi_iptr ffi_ptr = &ffi_value;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function null_and(): integer
                    return (ffi.ffi_null and 99) or 7
                end

                function nonnull_and(): integer
                    return (ffi.ffi_ptr and 99) or 7
                end
            ]], [[
                assert(test.null_and() == 7)
                assert(test.nonnull_and() == 99)
            ]])
        end)
    end)

    it("calls static header functions and C function pointer values", function()
        with_header([[
            typedef int (*ffi_callback)(int);

            static int ffi_add1(int x) {
                return x + 1;
            }

            static int ffi_apply(ffi_callback cb, int x) {
                return cb(x) + 3;
            }

            static ffi_callback ffi_choose(void) {
                return ffi_add1;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function sum(): integer
                    local cb: foreign ffi_callback = ffi.ffi_add1
                    local chosen = ffi.ffi_choose()
                    return (ffi.ffi_add1(1) as integer)
                        + (cb(4) as integer)
                        + (ffi.ffi_apply(ffi.ffi_add1, 5) as integer)
                        + (chosen(6) as integer)
                end
            ]], [[
                assert(test.sum() == 23)
            ]])
        end)
    end)

    it("executes foreign module-variable initializers in declaration order", function()
        h.run_coder([[
            foreign import "limits.h"
            foreign import "spec/fixtures/module_initializers.h"
            const maximum: integer = ffi.LLONG_MAX as integer
            const macro: integer = ffi.INITIALIZER_MACRO
            const enumeration: integer = ffi.INITIALIZER_ENUM
            native_value: integer = ffi.initializer_value
            const field: integer = ffi.initializer_object.number
            const indexed: integer = ffi.initializer_array[1]
            const first: integer = ffi.initializer_mark(1)
            second: integer = (ffi.initializer_pointer(2))
            const trace: integer = ffi.initializer_read_trace()
            local storage = foreign int.new_array(ffi.initializer_count())
            function count(): integer return #storage end
        ]], [[
            assert(test.maximum == math.maxinteger)
            assert(test.macro == 17 and test.enumeration == 9)
            assert(test.native_value == 23 and test.field == 11)
            assert(test.indexed == 5)
            assert(test.first == 1 and test.second == 2 and test.trace == 12)
            collectgarbage("collect")
            assert(test.count() == 3)
            assert(not pcall(function() test.first = 9 end))
            test.second = 9
            assert(test.second == 9 and test.trace == 12)
        ]])
    end)

    it("rebases scalar-only foreign module-variable initializers without root slots",
       function()
        h.run_coder([[
            foreign import "spec/fixtures/module_initializers.h"
            const first: integer = ffi.initializer_mark(1)
            const second: integer = ffi.initializer_pointer(2)
            const trace: integer = ffi.initializer_read_trace()
            const native_values: integer = ffi.initializer_value
                + ffi.initializer_array[0] + ffi.initializer_object.number
        ]], [[
            assert(test.first == 1 and test.second == 2 and test.trace == 12)
            assert(test.native_values == 37)
        ]])
    end)

    it("rebases the Lua stack after direct and pointer foreign calls", function()
        with_header([[
            typedef struct TValue TValue;
            typedef const int ffi_const_int;
            typedef void (*ffi_void_callback)(void);
            typedef ffi_const_int (*ffi_scalar_callback)(void);
            typedef void (*ffi_value_callback)(TValue *);

            static void ffi_direct_void(void) {}
            static ffi_const_int ffi_direct_scalar(void) { return 42; }
            static void ffi_touch_value(TValue *value) { (void)value; }

            static ffi_void_callback ffi_void_pointer = ffi_direct_void;
            static ffi_scalar_callback ffi_scalar_pointer =
                ffi_direct_scalar;
            static ffi_value_callback ffi_value_pointer = ffi_touch_value;
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                direct_init: integer = 0
                pointer_init: integer = 0

                function direct_void(): nil
                    ffi.ffi_direct_void()
                    return nil
                end

                function direct_scalar(): integer
                    return ffi.ffi_direct_scalar() as integer
                end

                function pointer_void(): nil
                    ffi.ffi_void_pointer()
                    return nil
                end

                function pointer_scalar(): integer
                    return ffi.ffi_scalar_pointer() as integer
                end

                function direct_anchor(): value
                    local item: foreign TValue = nil
                    ffi.ffi_touch_value(item)
                    return item
                end

                function pointer_anchor(): value
                    local item: foreign TValue = nil
                    ffi.ffi_value_pointer(item)
                    return item
                end

                do
                    direct_init = ffi.ffi_direct_scalar() as integer
                    pointer_init = ffi.ffi_scalar_pointer() as integer
                end
            ]])

            local rebase = "_base = restorestack(L, _base_off);"
            local function assert_rebased(name, call_pattern)
                local body = native_body(csrc, name)
                local saved = assert(body:find(
                    "ptrdiff_t _base_off = savestack(L, _base);", 1, true),
                    name)
                local call = assert(body:find(call_pattern, saved))
                local restored = assert(body:find(rebase, call, true))
                assert.is_true(saved < call and call < restored, name)
                return body, restored
            end

            assert_rebased("direct_void", "%(ffi_direct_void%)%(%)")
            assert_rebased("direct_scalar", "%(ffi_direct_scalar%)%(%)")
            assert_rebased("pointer_void", "_tmp_%d+%(%);")
            assert_rebased("pointer_scalar", "= _tmp_%d+%(%);")

            for _, case in ipairs({
                { "direct_anchor", "%(ffi_touch_value%)%([^;]*%);" },
                { "pointer_anchor", "_tmp_%d+%([^;]*%);" },
            }) do
                local body, restored = assert_rebased(case[1], case[2])
                local anchored = assert(body:find(
                    "restorestack(L, _base_off)", restored + #rebase, true))
                assert.is_true(restored < anchored, case[1])
            end

            local init = c_function_body(
                csrc, "test_\\u2119_titanentry_module_initializer")
            local base = assert(init:find("StkId _base = L->top.p;", 1, true))
            local baseoff = assert(init:find(
                "ptrdiff_t _base_off = savestack(L, _base);", base, true))
            local direct = assert(init:find("%(ffi_direct_scalar%)%(%)", baseoff))
            local direct_rebase = assert(init:find(rebase, direct, true))
            local pointer = assert(init:find("= _tmp_%d+%(%);", direct_rebase))
            local pointer_rebase = assert(init:find(rebase, pointer, true))
            assert.is_true(base < baseoff and baseoff < direct)
            assert.is_true(direct < direct_rebase and direct_rebase < pointer)
            assert.is_true(pointer < pointer_rebase)
        end)
    end)

    it("executes exact pointer, array, and function declarator shapes",
    function()
        with_header([[
            static int ffi_first = 10;
            static int ffi_second = 20;
            static int ffi_third = 30;
            static int *ffi_pointer_array[3] = {
                &ffi_first, &ffi_second, &ffi_third
            };
            static int ffi_row[3] = { 4, 5, 6 };
            static int (*ffi_array_pointer)[3] = &ffi_row;
            static int ffi_add_two(int value) {
                return value + 2;
            }
            static int (*ffi_callbacks[2])(int) = {
                ffi_add_two, ffi_add_two
            };
            static int (*ffi_row_factory(void))[3] {
                return &ffi_row;
            }
            static int ffi_matrix[1][3] = { { 7, 8, 9 } };
            static int ffi_matrix_sum(int values[][3]) {
                return values[0][0] + values[0][1] + values[0][2];
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function exact_declarators(): integer
                    return (ffi.ffi_pointer_array[1][0] as integer)
                        + (ffi.ffi_array_pointer[0][1] as integer)
                        + (ffi.ffi_callbacks[0](4) as integer)
                        + (ffi.ffi_row_factory()[0][2] as integer)
                        + (ffi.ffi_matrix_sum(ffi.ffi_matrix) as integer)
                end
            ]], [[
                assert(test.exact_declarators() == 61)
            ]])
        end)
    end)

    it("renders qualified callback returns in locals and calls", function()
        with_header([[
            typedef const int (*ffi_qualified_callback)(void);

            static const int ffi_qualified_answer(void) {
                return 42;
            }

            static ffi_qualified_callback ffi_choose_qualified(void) {
                return ffi_qualified_answer;
            }

            static int ffi_apply_qualified(
                    ffi_qualified_callback callback) {
                return callback();
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function qualified_callbacks(): integer
                    local direct: foreign ffi_qualified_callback =
                        ffi.ffi_qualified_answer
                    local chosen = ffi.ffi_choose_qualified()
                    return (direct() as integer)
                        + (ffi.ffi_apply_qualified(direct) as integer)
                        + (chosen() as integer)
                end
            ]], [[
                assert(test.qualified_callbacks() == 126)
            ]])
        end)
    end)

    it("raises on NULL C function pointer calls", function()
        with_header([[
            typedef int (*ffi_callback)(int);
            static ffi_callback ffi_null_cb = 0;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function bad(): integer
                    return ffi.ffi_null_cb(1) as integer
                end
            ]], [[
                test.bad()
            ]], "NULL C function pointer")
        end)
    end)

    it("raises on NULL C pointer field access and indexing", function()
        with_header([[
            typedef struct ffi_point { int x; } ffi_point;
            static ffi_point *ffi_null_point = 0;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function bad_field(): integer
                    return ffi.ffi_null_point.x as integer
                end
            ]], [[
                test.bad_field()
            ]], "NULL C pointer")
        end)

        with_header([[
            static int *ffi_null_int = 0;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                function bad_index(): integer
                    return ffi.ffi_null_int[0] as integer
                end
            ]], [[
                test.bad_index()
            ]], "NULL C pointer")
        end)
    end)

    it("stores C pointers in local record fields", function()
        with_header([[
            typedef int ffi_counter;
            static int ffi_counter_read(ffi_counter *counter) {
                return *counter;
            }
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                record Handle
                    local pointer: foreign *ffi_counter
                end

                function read(): integer
                    local counter: foreign ffi_counter = 42 as foreign ffi_counter
                    local pointer: foreign *ffi_counter = counter
                    local handle = Handle.new(pointer)
                    return ffi.ffi_counter_read(handle.pointer) as integer
                end
            ]], [[
                assert(test.read() == 42)
            ]])
        end)
    end)

    it("checks owned C userdata identity when casting from value", function()
        with_header([[
            typedef struct ffi_point { int x; } ffi_point;
        ]], function(header)
            h.run_coder([[
                foreign import "]] .. header .. [["

                record R
                    x: integer
                end

                function bad(): integer
                    local p: owned *ffi_point = foreign ffi_point.new()
                    local v: value = R.new(7)
                    p = v
                    return p.x as integer
                end
            ]], [[
                test.bad()
            ]], "expected owned")
        end)
    end)

    it("casts C char pointers to Titan strings with a NULL guard", function()
        h.run_coder([[
            foreign import "stdlib.h"

            function path(): string
                return ffi.getenv("PATH") as string
            end
        ]], [[
            local p = test.path()
            assert(type(p) == "string")
            assert(#p > 0)
        ]])
    end)
end)
