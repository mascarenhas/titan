local checker = require "titan-compiler.checker"
local cprobe = require "titan-compiler.cprobe"
local csemantics = require "titan-compiler.csemantics"
local cdriver = require "c-parser.cdriver"
local h = require "spec.support.helpers"
local installed_prefix = require "spec.support.installed_prefix"

local profile
local function test_profile()
    if profile then return profile end
    profile = assert(csemantics.build_profile({
        macros = {
            __CHAR_BIT__ = "8",
            __SIZEOF_BOOL__ = "1",
            __SIZEOF_SHORT__ = "2",
            __SIZEOF_INT__ = "4",
            __SIZEOF_LONG__ = "8",
            __SIZEOF_LONG_LONG__ = "8",
            __SIZEOF_FLOAT__ = "4",
            __SIZEOF_DOUBLE__ = "8",
            __SIZEOF_LONG_DOUBLE__ = "16",
            __SCHAR_MAX__ = "127",
            __SHRT_MAX__ = "32767",
            __INT_MAX__ = "2147483647",
            __LONG_MAX__ = "9223372036854775807L",
            __LONG_LONG_MAX__ = "9223372036854775807LL",
        },
        lua_integer = "long long",
        lua_number = "double",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        signed_minima = {
            ["signed char"] = "-128",
            short = "-32768",
            int = "-2147483648",
            long = "-9223372036854775808",
            ["long long"] = "-9223372036854775808",
        },
    }))
    return profile
end

local function test_process_options()
    return {
        compiler = os.getenv("CC") or "cc",
        language_mode = "c99",
        compile_flags = {},
        cppflags = {},
        compiler_include_dirs =
            assert(cdriver.resolve_compiler_include_dirs()),
    }
end

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

local function fake_check(header, body, answer, options)
    local calls = {}
    local service = assert(cprobe.new_service({
        profile = test_profile(),
        include_dirs = options and options.include_dirs or nil,
        runner = function(_, metadata)
            calls[#calls + 1] = metadata
            if metadata.stage == "candidate" and answer == "reject" then
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = "probe.c:8: error: rejected by test compiler",
                }
            end
            return {
                started = true,
                ok = true,
                status = 0,
                diagnostic = "",
            }
        end,
    }))
    local code = 'local c = foreign import "' .. header .. '"\n' .. body
    local ast, parse_error = h.parse(code)
    assert(ast, parse_error)
    local _, errors = checker.check(
        "test", ast, code, "test.titan", nil, {
            probe_service_provider = function() return service end,
        })
    assert(service:close())
    return #errors == 0, table.concat(errors, "\n"), ast, calls
end

local function collect_conversions(node, out, seen)
    out = out or {}
    seen = seen or {}
    if type(node) ~= "table" or seen[node] then return out end
    seen[node] = true
    if node._c_conversion then table.insert(out, node) end
    for _, child in pairs(node) do
        collect_conversions(child, out, seen)
    end
    return out
end

local function collect_marked(node, marker, out, seen)
    out = out or {}
    seen = seen or {}
    if type(node) ~= "table" or seen[node] then return out end
    seen[node] = true
    if node[marker] then table.insert(out, node) end
    for _, child in pairs(node) do
        collect_marked(child, marker, out, seen)
    end
    return out
end

describe("contextual unsafe C object-pointer conversions", function()
    local declarations = [[
        typedef struct ffi_source { int source; } ffi_source;
        typedef struct ffi_target { int target; } ffi_target;
        typedef void (*ffi_callback)(void);
        typedef void (*ffi_accept_fn)(ffi_target *value);
        extern void ffi_take(ffi_target *value);
        extern void ffi_take_named(ffi_target *value);
        extern void ffi_take_volatile(volatile ffi_target *value);
        extern void ffi_take_callback(ffi_callback value);
    ]]

    it("shares one directional probe across every expression sink", function()
        with_header(declarations, function(header)
            local ok, err, _, calls = fake_check(header, [[
                local function convert(
                    p: *c.ffi_source,
                    accept: c.ffi_accept_fn
                ): *c.ffi_target
                    local q: *c.ffi_target = p
                    q = p
                    c.ffi_take(p)
                    c.ffi_take_named { value = p }
                    accept(p)
                    return p
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.equal("candidate", calls[2].stage)
            assert.match("extern ffi_source %*titan_probe_s_%x+;",
                calls[2].source)
            assert.match("ffi_target %*titan_probe_t_%x+",
                calls[2].source)
        end)
    end)

    it("adjusts every value in a typed multi-local declaration", function()
        with_header(declarations, function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function convert(p: *c.ffi_source)
                    local first: *c.ffi_target,
                          second: *c.ffi_target = p, p
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)

            local conversions = collect_conversions(ast)
            assert.equal(2, #conversions)
            for _, conversion in ipairs(conversions) do
                assert.equal("unsafe_object_pointer",
                    conversion._c_conversion.kind)
                assert.equal(calls[2].key,
                    conversion._c_conversion.probe_key)
            end
        end)
    end)

    it("adjusts a C aggregate field assignment", function()
        with_header(declarations .. [[
            typedef struct ffi_holder {
                ffi_target *pointer;
            } ffi_holder;
        ]], function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function convert(p: *c.ffi_source)
                    local holder = c.ffi_holder.new()
                    holder.pointer = p
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)

            local conversions = collect_conversions(ast)
            assert.equal(1, #conversions)
            assert.equal("unsafe_object_pointer",
                conversions[1]._c_conversion.kind)
            assert.equal(calls[2].key,
                conversions[1]._c_conversion.probe_key)
        end)
    end)

    it("synthesizes omitted and explicit nil pointer arguments without probing",
    function()
        with_header(declarations, function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function nil_arguments()
                    c.ffi_take_named {}
                    c.ffi_take_named { value = nil }
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(1, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.equal(0, #collect_conversions(ast))

            local omitted = collect_marked(ast, "_named_omitted")
            assert.equal(1, #omitted)
            assert.equal("Ast.ExpCast", omitted[1]._tag)
            assert.equal("Ast.ExpNil", omitted[1].exp._tag)
        end)
    end)

    it("adjusts the fixed prefix of a C variadic call", function()
        with_header(declarations .. [[
            extern void ffi_variadic_target(ffi_target *value, ...);
        ]], function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function convert(p: *c.ffi_source)
                    c.ffi_variadic_target(p)
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)

            local conversions = collect_conversions(ast)
            assert.equal(1, #conversions)
            assert.equal("unsafe_object_pointer",
                conversions[1]._c_conversion.kind)
            assert.equal(calls[2].key,
                conversions[1]._c_conversion.probe_key)
        end)
    end)

    it("keeps pointer operator adjustment symmetric and probe-distinct",
    function()
        with_header(declarations, function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function equal(
                    source: *c.ffi_source,
                    target: *c.ffi_target
                ): boolean
                    return source == target
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)
            assert.equal(0, #collect_conversions(ast))

            local operators = collect_marked(ast, "_c_operator")
            assert.equal(1, #operators)
            local trait = operators[1]._c_operator
            assert.equal(trait.lhs_target, trait.rhs_target)
            assert.equal(calls[2].key, trait.probe_key)
            assert.truthy(calls[2].key:find("c_operator", 1, true))
        end)
    end)

    it("adjusts generic-for state at its C callable slot", function()
        with_header(declarations .. [[
            typedef ffi_target *ffi_target_ptr;
            typedef ffi_target_ptr (*ffi_next_fn)(ffi_target *state);
        ]], function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function iterate(
                    next_value: c.ffi_next_fn,
                    state: *c.ffi_source
                )
                    for item: c.ffi_target_ptr in next_value, state do
                    end
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)

            local conversions = collect_conversions(ast)
            assert.equal(1, #conversions)
            assert.equal("unsafe_object_pointer",
                conversions[1]._c_conversion.kind)
            assert.equal(calls[2].key,
                conversions[1]._c_conversion.probe_key)
        end)
    end)

    it("keeps conversion direction in the cache identity", function()
        with_header(declarations, function(header)
            local ok, err, _, calls = fake_check(header, [[
                local function forward(
                    p: *c.ffi_source
                ): *c.ffi_target
                    return p
                end

                local function reverse(
                    p: *c.ffi_target
                ): *c.ffi_source
                    return p
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(3, #calls)
            assert.equal("baseline", calls[1].stage)
            assert.equal("candidate", calls[2].stage)
            assert.equal("candidate", calls[3].stage)
            assert.not_equal(calls[2].key, calls[3].key)
        end)
    end)

    it("adds qualifiers but rejects recursive const and volatile loss",
    function()
        with_header(declarations .. [[
            extern volatile ffi_source *ffi_volatile_source(void);
            extern void ffi_take_pointer_pointer(ffi_target **value);
            extern const ffi_source **ffi_const_nested(void);
        ]], function(header)
            local ok, err = fake_check(header, [[
                local function add(p: *c.ffi_source)
                    c.ffi_take_volatile(p)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = fake_check(header, [[
                local function remove_volatile()
                    c.ffi_take(c.ffi_volatile_source())
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard volatile", err)
            assert.match("argument 1 of call", err)

            ok, err = fake_check(header, [[
                local function remove_nested_const()
                    c.ffi_take_pointer_pointer(c.ffi_const_nested())
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard const", err)
        end)
    end)

    it("rejects object/function category crossings before probing", function()
        with_header(declarations, function(header)
            local ok, err, _, calls = fake_check(header, [[
                local function bad(p: *c.ffi_source)
                    c.ffi_take_callback(p)
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot convert object pointer", err)
            assert.match("to function pointer", err)
            assert.equal(1, #calls)
            assert.equal("baseline", calls[1].stage)
        end)
    end)

    it("distinguishes compiler rejection from a broken header baseline",
    function()
        with_header(declarations, function(header)
            local ok, err = fake_check(header, [[
                local function bad(
                    p: *c.ffi_source
                ): *c.ffi_target
                    return p
                end
            ]], "reject")
            assert.falsy(ok)
            assert.match("configured C compiler rejected conversion", err)
            assert.match("rejected by test compiler", err)
        end)

        with_header([[
            typedef struct ffi_source ffi_source;
            typedef struct ffi_target ffi_target;
            extern ffi_source invalid_incomplete_array[2];
        ]], function(header)
            local ok, err = h.run_checker([[
                local c = foreign import "]] .. header .. [["
                local function bad(
                    p: *c.ffi_source
                ): *c.ffi_target
                    return p
                end
            ]])
            assert.falsy(ok)
            assert.match("foreign header baseline failed", err)
        end)
    end)

    it("records address-then-reinterpretation for a local aggregate",
    function()
        with_header(declarations .. [[
            extern ffi_source ffi_make_source(void);
        ]], function(header)
            local ok, err, ast = fake_check(header, [[
                local function use_local()
                    local object: c.ffi_source = c.ffi_make_source()
                    c.ffi_take(object)
                end
            ]])
            assert.truthy(ok, err)

            local function find(node, seen)
                if type(node) ~= "table" or seen[node] then return end
                seen[node] = true
                if node._c_conversion then return node end
                for _, child in pairs(node) do
                    local found = find(child, seen)
                    if found then return found end
                end
            end
            local conversion = assert(find(ast, {}))
            assert.equal("address_then_unsafe_object_pointer",
                conversion._c_conversion.kind)
            assert.is_true(conversion.exp.var._decl._assigned)
            assert.truthy(conversion.exp.var._decl._c_address_taken)
        end)
    end)

    it("rejects a written mutable address of a C rvalue", function()
        with_header(declarations .. [[
            extern ffi_source ffi_make_source(void);
        ]], function(header)
            local ok, err = fake_check(header, [[
                local function bad(): *c.ffi_source
                    return c.ffi_make_source() as *c.ffi_source
                end
            ]])
            assert.falsy(ok)
            assert.match("cannot take a mutable C address", err, 1, true)
            assert.match(
                "non-addressable expression of type 'ffi_source'",
                err, 1, true)
        end)
    end)

    it("keeps inline C storage of a const local read-only", function()
        with_header([[
            typedef int ffi_int;
            typedef struct ffi_box {
                int field;
                int *pointer;
            } ffi_box;
            extern ffi_box ffi_make_box(void);
            extern void ffi_observe_box(const ffi_box *box);
            extern void ffi_mutate_box(ffi_box *box);
            extern void ffi_observe_ints(const int *items);
            extern void ffi_mutate_ints(int *items);
        ]], function(header)
            local ok, err = h.run_checker([[
                local c = foreign import "]] .. header .. [["

                local function accepted()
                    const box: c.ffi_box = c.ffi_make_box()
                    c.ffi_observe_box(box)
                    box.pointer[0] = 7

                    const items: c.ffi_int[2] =
                        c.ffi_int.new_array(2)
                    c.ffi_observe_ints(items)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = h.run_checker([[
                local c = foreign import "]] .. header .. [["

                local function rejected()
                    const box: c.ffi_box = c.ffi_make_box()
                    box.field = 1
                    c.ffi_mutate_box(box)

                    const items: c.ffi_int[2] =
                        c.ffi_int.new_array(2)
                    items[0] = 1
                    c.ffi_mutate_ints(items)
                end
            ]])
            assert.falsy(ok)
            assert.match(
                "cannot mutate inline C storage of const local 'box'", err)
            assert.match(
                "cannot take a mutable C address of inline storage from const local 'box'",
                err)
            assert.match(
                "cannot mutate inline C storage of const local 'items'", err)
            assert.match(
                "cannot take a mutable C address of inline storage from const local 'items'",
                err)
        end)
    end)

    it("retains const and volatile array qualification through decay",
    function()
        with_header([[
            typedef const int ffi_const_int;
            typedef volatile int ffi_volatile_int;
            extern const int ffi_const_values[3];
            extern volatile int ffi_volatile_values[3];
            extern ffi_const_int ffi_typedef_const_values[3];
            extern ffi_volatile_int ffi_typedef_volatile_values[3];
            extern void ffi_take(int *values);
            extern void ffi_take_const(const int *values);
            extern void ffi_take_volatile(volatile int *values);
        ]], function(header)
            local ok, err = fake_check(header, [[
                local function accepted()
                    c.ffi_take_const(c.ffi_const_values)
                    c.ffi_take_volatile(c.ffi_volatile_values)
                    c.ffi_take_const(
                        c.ffi_typedef_const_values)
                    c.ffi_take_volatile(
                        c.ffi_typedef_volatile_values)
                end
            ]])
            assert.truthy(ok, err)

            ok, err = fake_check(header, [[
                local function bad_const()
                    c.ffi_take(c.ffi_const_values)
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard const", err)

            ok, err = fake_check(header, [[
                local function bad_volatile()
                    c.ffi_take(c.ffi_volatile_values)
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard volatile", err)

            ok, err = fake_check(header, [[
                local function bad_typedef_const()
                    c.ffi_take(c.ffi_typedef_const_values)
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard const", err)

            ok, err = fake_check(header, [[
                local function bad_typedef_volatile()
                    c.ffi_take(c.ffi_typedef_volatile_values)
                end
            ]])
            assert.falsy(ok)
            assert.match("would discard volatile", err)
        end)
    end)

    it("decays imported and local arrays before unsafe probing",
    function()
        with_header(declarations .. [[
            extern ffi_source ffi_sources[2];
        ]], function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function arrays()
                    c.ffi_take(c.ffi_sources)
                    local local_sources = c.ffi_source.new_array(2)
                    c.ffi_take(local_sources)
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)
            local conversions = collect_conversions(ast)
            assert.equal(2, #conversions)
            for _, conversion in ipairs(conversions) do
                assert.equal("unsafe_object_pointer",
                    conversion._c_conversion.kind)
            end
        end)
    end)

    it("probes explicit casts in returns and typed C varargs in place",
    function()
        with_header(declarations .. [[
            extern void ffi_variadic(int tag, ...);
        ]], function(header)
            local ok, err, ast, calls = fake_check(header, [[
                local function explicit(
                    pointer: *c.ffi_source
                ): *c.ffi_target
                    return pointer as *c.ffi_target
                end

                local function typed_vararg(
                    pointer: *c.ffi_source
                )
                    c.ffi_variadic(
                        1, pointer as *c.ffi_target)
                end
            ]])
            assert.truthy(ok, err)
            assert.equal(2, #calls)
            local conversions = collect_conversions(ast)
            assert.equal(2, #conversions)
            for _, conversion in ipairs(conversions) do
                assert.equal("unsafe_object_pointer",
                    conversion._c_conversion.kind)
                assert.equal(calls[2].key,
                    conversion._c_conversion.probe_key)
                assert.equal("explicit",
                    conversion._written_cast.op)
                assert.equal(conversion._c_conversion,
                    conversion._written_cast.conversion)
                assert.equal("unsafe_object_pointer",
                    conversion._written_cast.conversion.kind)
                assert.equal(calls[2].key,
                    conversion._written_cast.conversion.probe_key)
            end
        end)
    end)

    it("proves pinned libuv nominal-prefix relations and direct calls",
    function()
        local prefix = installed_prefix.active()
        local include_dirs = {prefix .. "/include"}
        for _, directory in ipairs(
                assert(cdriver.resolve_compiler_include_dirs())) do
            table.insert(include_dirs, directory)
        end
        with_header(
            '#include <uv.h>\n',
            function(header)
                local ok, err, _, calls = fake_check(header, [[
                    local function prefixes(
                        tcp: *c.uv_tcp_t,
                        pipe: *c.uv_pipe_t,
                        fs: *c.uv_fs_t
                    ): integer
                        local handle: *c.uv_handle_t = tcp
                        local stream: *c.uv_stream_t = pipe
                        local request: *c.uv_req_t = fs
                        return 0
                    end

                    local function direct()
                        local tcp = c.uv_tcp_t.new()
                        local request = c.uv_fs_t.new()
                        c.uv_close(tcp, nil)
                        c.uv_cancel(request)
                    end
                ]], nil, {include_dirs = include_dirs})
                assert.truthy(ok, err)
                assert.equal(4, #calls)
                local joined = {}
                for _, call in ipairs(calls) do
                    joined[#joined + 1] = call.source
                end
                joined = table.concat(joined, "\n")
                assert.match(
                    "extern uv_tcp_t %*titan_probe_s_%x+;",
                    joined)
                assert.match(
                    "uv_handle_t %*titan_probe_t_%x+", joined)
                assert.match(
                    "extern uv_pipe_t %*titan_probe_s_%x+;",
                    joined)
                assert.match(
                    "uv_stream_t %*titan_probe_t_%x+", joined)
                assert.match(
                    "extern uv_fs_t %*titan_probe_s_%x+;",
                    joined)
                assert.match(
                    "uv_req_t %*titan_probe_t_%x+", joined)
            end)
    end)

    it("closes an owned probe service when checker internals throw",
    function()
        with_header(declarations, function(header)
            local original_new_service = cprobe.new_service
            local close_calls = 0
            cprobe.new_service = function()
                return {
                    profile = test_profile(),
                    cdriver_process_options = test_process_options,
                    module_context = function()
                        return {
                            probe_unsafe_object_pointer = function()
                                error("injected probe failure")
                            end,
                        }
                    end,
                    close = function()
                        close_calls = close_calls + 1
                        return true
                    end,
                }
            end

            local code = 'local c = foreign import "' .. header .. [["
                local function convert(
                    p: *c.ffi_source
                ): *c.ffi_target
                    return p
                end
            ]]
            local ast = assert(h.parse(code))
            local ok, err = pcall(
                checker.check, "test", ast, code, "test.titan")
            cprobe.new_service = original_new_service

            assert.falsy(ok)
            assert.match("injected probe failure", tostring(err), 1, true)
            assert.equal(1, close_calls)
        end)
    end)

    it("restores the outer active checker after a nested checker throw",
    function()
        with_header(declarations, function(header)
            local original_new_service = cprobe.new_service
            local unexpected_direct_service = 0
            cprobe.new_service = function()
                unexpected_direct_service =
                    unexpected_direct_service + 1
                error("unexpected direct probe service")
            end

            local probe_calls = 0
            local service = {
                profile = test_profile(),
                cdriver_process_options = test_process_options,
                module_context = function()
                    return {
                        validate_baseline = function()
                            return { status = "success" }
                        end,
                        probe_unsafe_object_pointer = function()
                            probe_calls = probe_calls + 1
                            return {
                                status = "success",
                                key = tostring(probe_calls),
                            }
                        end,
                    }
                end,
            }
            local provider_calls = 0
            local function provider()
                provider_calls = provider_calls + 1
                if provider_calls == 1 then
                    local nested_ok = pcall(
                        checker.check, "nested",
                        { { _tag = "Ast.DeliberateFailure" } },
                        "", "nested.titan")
                    assert.falsy(nested_ok)
                end
                return service
            end

            local code = 'local c = foreign import "' .. header .. [["
                local function forward(
                    p: *c.ffi_source
                ): *c.ffi_target
                    return p
                end

                local function reverse(
                    p: *c.ffi_target
                ): *c.ffi_source
                    return p
                end
            ]]
            local ast = assert(h.parse(code))
            local ok, result, errors = pcall(
                checker.check, "test", ast, code, "test.titan", nil, {
                    probe_service_provider = provider,
                })
            cprobe.new_service = original_new_service

            assert.truthy(ok, result)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            assert.equal(1, provider_calls)
            assert.equal(2, probe_calls)
            assert.equal(0, unexpected_direct_service)
        end)
    end)
end)
