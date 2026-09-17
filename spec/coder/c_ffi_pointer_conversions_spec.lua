local h = require "spec.support.helpers"

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function count_matches(text, pattern)
    local _, count = text:gsub(pattern, "")
    return count
end

describe("unsafe C object-pointer conversion code generation", function()
    after_each(function()
        os.remove("test.o")
        os.remove("test.so")
        os.remove("test.a")
        if not h.verbose then os.remove("test.c") end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("emits one target cast and composes local aggregate address-taking",
    function()
        with_header([[
            typedef struct ffi_source { int value; } ffi_source;
            typedef struct ffi_target { int value; } ffi_target;

            static ffi_source ffi_make_source(void) {
                ffi_source source = { 77 };
                return source;
            }
            static int ffi_read_target(ffi_target *target) {
                return target->value;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                local function reinterpret(
                    pointer: foreign *ffi_source
                ): foreign *ffi_target
                    return pointer
                end

                function local_address(): integer
                    local object: foreign ffi_source = ffi.ffi_make_source()
                    return ffi.ffi_read_target(object) as integer
                end
            ]])

            assert.matches(
                "((ffi_target *)(_param_pointer))", csrc, 1, true)
            assert.matches(
                "((ffi_target *)((&(_local_object_1))))",
                csrc, 1, true)
            assert.not_matches(
                "ffi_target %*%)%(%(ffi_target %*%)", csrc)

            local ok, err = h.call("test", [[
                assert(test.local_address() == 77)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("decays qualified and unrelated arrays without taking array addresses",
    function()
        with_header([[
            typedef struct ffi_source { int value; } ffi_source;
            typedef struct ffi_target { int value; } ffi_target;
            static ffi_source ffi_sources[2] = {{31}, {37}};
            static const int ffi_const_values[2] = {43, 0};
            static volatile int ffi_volatile_values[2] = {47, 0};

            static int ffi_read_target(ffi_target *value) {
                return value->value;
            }
            static int ffi_read_const(const int *values) {
                return values[0];
            }
            static int ffi_read_volatile(volatile int *values) {
                return values[0];
            }
        ]], function(header)
            local source = [[
                foreign import "]] .. header .. [["

                function arrays(): integer
                    local local_sources =
                        foreign ffi_source.new_array(2)
                    return ffi.ffi_read_target(ffi.ffi_sources) as integer
                        + ffi.ffi_read_target(local_sources) as integer
                        + ffi.ffi_read_const(ffi.ffi_const_values) as integer
                        + ffi.ffi_read_volatile(
                            ffi.ffi_volatile_values) as integer
                end
            ]]
            local csrc = h.compile_and_read_c(source)
            assert.matches(
                "((ffi_target *)(ffi_sources))", csrc, 1, true)
            assert.matches(
                "((ffi_target *)(_local_local_sources_1))",
                csrc, 1, true)
            assert.matches(
                "((const int *)(ffi_const_values))", csrc, 1, true)
            assert.matches(
                "((volatile int *)(ffi_volatile_values))",
                csrc, 1, true)
            assert.not_matches("&%(ffi_sources%)", csrc)
            assert.not_matches("&%(_local_local_sources_1%)", csrc)

            local ok, err = h.call("test", [[
                assert(test.arrays() == 121)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("emits one cast for explicit and typed-vararg conversions",
    function()
        with_header([[
            #include <stdarg.h>
            typedef struct ffi_source { int value; } ffi_source;
            typedef struct ffi_target { int value; } ffi_target;

            static ffi_source ffi_make_source(int value) {
                ffi_source source = { value };
                return source;
            }
            static int ffi_read_target(ffi_target *target) {
                return target->value;
            }
            static int ffi_read_vararg(int tag, ...) {
                va_list args;
                ffi_target *target;
                va_start(args, tag);
                target = va_arg(args, ffi_target *);
                va_end(args);
                return target->value;
            }
        ]], function(header)
            local source = [[
                foreign import "]] .. header .. [["

                local function reinterpret(
                    pointer: foreign *ffi_source
                ): foreign *ffi_target
                    return pointer as foreign *ffi_target
                end

                function explicit(): integer
                    local object: foreign ffi_source =
                        ffi.ffi_make_source(53)
                    local pointer: foreign *ffi_source = object
                    return ffi.ffi_read_target(
                        reinterpret(pointer)) as integer
                end

                function vararg(): integer
                    local object: foreign ffi_source =
                        ffi.ffi_make_source(59)
                    local pointer: foreign *ffi_source = object
                    return ffi.ffi_read_vararg(
                        1, pointer as foreign *ffi_target) as integer
                end
            ]]
            local csrc = h.compile_and_read_c(source)
            assert.equal(1, count_matches(
                csrc, "%(%(ffi_target %*%)%(_param_pointer%)%)"))
            assert.equal(1, count_matches(
                csrc,
                "%(%(ffi_target %*%)%(_local_pointer_%d+%)%)"))
            assert.not_matches(
                "ffi_target %*%)%(%(ffi_target %*%)", csrc)

            local ok, err = h.call("test", [[
                assert(test.explicit() == 53)
                assert(test.vararg() == 59)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("preserves the nested callback-pointer unsafe fallback", function()
        with_header([[
            typedef void (*ffi_mutable_callback)(int *);
            typedef void (*ffi_const_callback)(const int *);
            typedef ffi_mutable_callback *ffi_mutable_callback_pointer;
            typedef ffi_const_callback *ffi_const_callback_pointer;

            static ffi_mutable_callback ffi_mutable_slot = 0;

            static ffi_mutable_callback_pointer
            ffi_get_mutable_pointer(void) {
                return &ffi_mutable_slot;
            }

            static int ffi_accept_const_pointer(
                ffi_const_callback_pointer pointer
            ) {
                return pointer != 0;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                function nested_callback_pointer(): integer
                    return ffi.ffi_accept_const_pointer(
                        ffi.ffi_get_mutable_pointer()) as integer
                end
            ]])

            local pointer_tmp = assert(csrc:match(
                "ffi_mutable_callback_pointer (_tmp_%d+)"
                    .. " = ffi_get_mutable_pointer%(%);"))
            local capture = "ffi_mutable_callback_pointer " .. pointer_tmp
                .. " = ffi_get_mutable_pointer();"
            local capture_at = assert(csrc:find(capture, 1, true))
            local rebase_at = assert(csrc:find(
                "_base = restorestack(L, _base_off);",
                capture_at + #capture, true))
            local converted_call = "ffi_accept_const_pointer("
                .. "((ffi_const_callback_pointer)(" .. pointer_tmp .. ")))"
            assert(csrc:find(converted_call, rebase_at + 1, true))

            local ok, err = h.call("test", [[
                assert(test.nested_callback_pointer() == 1)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("reanchors GC out-values written through an unsafe local address",
    function()
        with_header([[
            typedef struct lua_State lua_State;
            typedef struct TValue TValue;
            typedef struct ffi_unrelated_value {
                unsigned char ignored;
            } ffi_unrelated_value;

#if !defined(lobject_h) || !defined(lstate_h)
            static void ffi_reset_unsafe_outparam_finalized(void) {
            }
            static int ffi_was_unsafe_outparam_finalized(void) {
                return 0;
            }
            static void ffi_write_unsafe_gc_value(
                lua_State *state,
                ffi_unrelated_value *out
            ) {
                (void)state;
                (void)out;
            }
            static void ffi_collect_unsafe_outparam(lua_State *state) {
                (void)state;
            }
            static int ffi_unsafe_outparam_is_userdata(
                const TValue *value
            ) {
                (void)value;
                return 1;
            }
#else
            static int ffi_unsafe_outparam_finalized = 0;

            static int ffi_unsafe_outparam_gc(lua_State *state) {
                (void)state;
                ffi_unsafe_outparam_finalized = 1;
                return 0;
            }

            static void ffi_reset_unsafe_outparam_finalized(void) {
                ffi_unsafe_outparam_finalized = 0;
            }

            static int ffi_was_unsafe_outparam_finalized(void) {
                return ffi_unsafe_outparam_finalized;
            }

            static void ffi_write_unsafe_gc_value(
                lua_State *state,
                ffi_unrelated_value *out
            ) {
                lua_newuserdatauv(state, 0, 0);
                if (luaL_newmetatable(
                        state, "titan_ffi_unsafe_outparam_anchor")) {
                    lua_pushcfunction(state, ffi_unsafe_outparam_gc);
                    lua_setfield(state, -2, "__gc");
                }
                lua_setmetatable(state, -2);
                setuvalue(state, (TValue *)out,
                    uvalue(s2v(state->top.p - 1)));
                lua_pop(state, 1);
            }

            static void ffi_collect_unsafe_outparam(lua_State *state) {
                lua_gc(state, LUA_GCCOLLECT, 0);
            }

            static int ffi_unsafe_outparam_is_userdata(
                const TValue *value
            ) {
                return ttisfulluserdata(value);
            }
#endif
        ]], function(header)
            local source = [[
                foreign import "]] .. header .. [["

                function survives_unsafe_gc_write(): integer
                    local raw: foreign TValue = nil
                    ffi.ffi_reset_unsafe_outparam_finalized()
                    ffi.ffi_write_unsafe_gc_value(
                        L, raw as foreign *TValue)
                    ffi.ffi_collect_unsafe_outparam(L)
                    if (ffi.ffi_was_unsafe_outparam_finalized()
                            as integer) ~= 0 then
                        return -1
                    end
                    if (ffi.ffi_unsafe_outparam_is_userdata(raw)
                            as integer) == 0 then
                        return -2
                    end
                    return 1
                end
            ]]
            local csrc = h.compile_and_read_c(source)
            local normalized_c = csrc:gsub("%s+", " ")
            assert.matches(
                "ffi_write_unsafe_gc_value%(%s*L,%s*.-"
                    .. "ffi_unrelated_value%s*%*.-"
                    .. "_local_raw_%d+",
                normalized_c)
            assert.matches(
                "TValue _titan_v = _local_raw_%d+; "
                    .. "setobj2t",
                normalized_c)

            local ok, err = h.call("test", [[
                assert(test.survives_unsafe_gc_write() == 1)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("emits representative nominal-prefix casts for direct C calls",
    function()
        with_header([[
            typedef struct ffi_handle { void *data; } ffi_handle;
            typedef struct ffi_tcp {
                void *data;
                int tcp_state;
            } ffi_tcp;
            typedef struct ffi_stream { void *data; } ffi_stream;
            typedef struct ffi_pipe {
                void *data;
                int pipe_state;
            } ffi_pipe;
            typedef struct ffi_request { void *data; } ffi_request;
            typedef struct ffi_fs {
                void *data;
                int fs_state;
            } ffi_fs;

            typedef void (*ffi_close_cb)(ffi_handle *);
            static void ffi_close(ffi_handle *handle, ffi_close_cb callback) {
                (void)handle;
                (void)callback;
            }
            static int ffi_cancel(ffi_request *request) {
                (void)request;
                return 0;
            }
        ]], function(header)
            local csrc = h.compile_and_read_c([[
                foreign import "]] .. header .. [["

                local function handle(
                    tcp: foreign *ffi_tcp
                ): foreign *ffi_handle
                    return tcp
                end

                local function stream(
                    pipe: foreign *ffi_pipe
                ): foreign *ffi_stream
                    return pipe
                end

                local function request(
                    fs: foreign *ffi_fs
                ): foreign *ffi_request
                    return fs
                end

                local function direct(): integer
                    local tcp = foreign ffi_tcp.new()
                    local fs = foreign ffi_fs.new()
                    ffi.ffi_close(tcp, nil)
                    return ffi.ffi_cancel(fs) as integer
                end
            ]])

            assert.matches(
                "((ffi_handle *)(_param_tcp))", csrc, 1, true)
            assert.matches(
                "((ffi_stream *)(_param_pipe))", csrc, 1, true)
            assert.matches(
                "((ffi_request *)(_param_fs))", csrc, 1, true)
            assert.matches(
                "ffi_close(((ffi_handle *)((&(_local_tcp_1))))",
                csrc, 1, true)
            assert.matches(
                "ffi_cancel%(%(%(ffi_request %*%).-_local_fs_%d+",
                csrc)
        end)
    end)
end)
