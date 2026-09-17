local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"

local probe_session

local declarations = [[
    typedef void ffi_void;
    typedef int ffi_int;
    typedef unsigned int ffi_uint;
    typedef double ffi_double;
    typedef char ffi_char;

    typedef struct ffi_item {
        int value;
    } ffi_item;
    typedef struct ffi_incomplete ffi_incomplete;
    typedef int ffi_row[3];
    typedef int (*ffi_callback)(int);

    static int ffi_add(int lhs, int rhs) {
        return lhs + rhs;
    }
    static int ffi_text_present(const char *text) {
        return text != 0;
    }
]]

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

local function check_with_header(header, body)
    return h.run_checker(
        "foreign import \"" .. header .. '"\n' .. body,
        probe_session)
end

local function assert_rejected(header, body, diagnostic)
    local ok, err = check_with_header(header, body)
    assert.falsy(ok)
    assert.match(diagnostic, err)
end

describe("foreign functions (checker)", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("lowers written callback types to C function pointers and declarations to C functions",
    function()
        with_header(declarations, function(header)
            local ok, err, ast, modtype = check_with_header(header, [[
                foreign type EmptyCallback = function (): void
                foreign type Callback = function (*ffi_item, ffi_int): ffi_int
                foreign type HigherOrder = function (Callback): Callback

                foreign function noop(): void
                    return
                end

                foreign function invoke(
                    callback: Callback,
                    item: *ffi_item,
                    input: ffi_int
                ): ffi_int
                    return callback(item, input)
                end
            ]])
            assert.truthy(ok, err)

            local empty = types.resolve_c_typedef(ast[2]._type)
            assert.equal("Type.CPointer", empty._tag)
            assert.equal("Type.CFunction", empty.pointee._tag)
            assert.is_false(empty.pointee.abi)
            assert.is_false(empty.pointee.vararg)
            assert.equal("Type.CVoid",
                types.resolve_c_typedef(empty.pointee.ret)._tag)

            local callback = types.resolve_c_typedef(ast[3]._type)
            assert.equal("Type.CPointer", callback._tag)
            assert.equal("Type.CFunction", callback.pointee._tag)
            assert.equal(2, #callback.pointee.params)
            assert.equal("Type.CInteger",
                types.resolve_c_typedef(callback.pointee.ret)._tag)

            local higher = types.resolve_c_typedef(ast[4]._type)
            assert.equal("Type.CPointer", higher._tag)
            assert.equal("Type.CPointer", types.resolve_c_typedef(higher.pointee.params[1])._tag)
            assert.equal("Type.CPointer", types.resolve_c_typedef(higher.pointee.ret)._tag)

            local noop = ast[5]
            assert.equal("Type.CFunction", noop._type._tag)
            assert.is_false(noop._type.abi)
            assert.equal("Type.CVoid",
                types.resolve_c_typedef(noop._type.ret)._tag)
            assert.equal("Type.CFunction", ast[6]._type._tag)

            assert.is_nil(modtype.members.noop)
            assert.is_nil(modtype.members.invoke)
            assert.is_true(modtype.source_members.noop._foreign_source)
            assert.is_true(modtype.source_members.invoke._foreign_source)
            assert.same({ "callback", "item", "input" },
                modtype.source_members.invoke.paramnames)
        end)
    end)

    it("supports forward calls, named calls, and contextual address decay",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                foreign type Binary = function (ffi_int, ffi_int): ffi_int

                foreign function first(
                    left: ffi_int,
                    right: ffi_int
                ): ffi_int
                    return second { rhs = right, lhs = left }
                end

                foreign function second(
                    lhs: ffi_int,
                    rhs: ffi_int
                ): ffi_int
                    return ffi.ffi_add(lhs, rhs)
                end

                local function address(): foreign Binary
                    return second
                end
            ]])
            assert.truthy(ok, err)

            local call = ast[3].block.stats[1].exps[1]
            assert.same({ source = true, module = "test", name = "second" },
                call._direct_foreign_reference)
            assert.equal("foreign", call._named_call_kind)
            assert.same({ 2, 1 }, call._named_arg_order)

            local address = ast[5].block.stats[1].exps[1]
            assert.same({ source = true, module = "test", name = "second" },
                address._foreign_function_reference)
        end)
    end)

    it("uses raw C literals, scalar conditions, and C numeric for controls",
    function()
        with_header(declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                foreign function flow(
                    item: *ffi_item,
                    callback: ffi_callback,
                    count: ffi_int,
                    limit: ffi_double
                ): ffi_int
                    local total: foreign ffi_int = 0
                    local flag = true
                    local text: foreign const *ffi_char = "ffi"
                    local missing: foreign *ffi_item = nil

                    if item then total = total + 1 end
                    if callback then total = total + 1 end
                    if count then total = total + 1 end
                    if limit then total = total + 1 end
                    if flag then total = total + 1 end

                    while count do
                        total = total + 1
                        break
                    end
                    repeat
                        total = total + 1
                    until item

                    for i: foreign ffi_int = 0, count, 1 do
                        total = total + i
                    end
                    for n: foreign ffi_double = 0.0, limit, 1.0 do
                        if n then break end
                    end
                    return total + ffi.ffi_text_present(text)
                end
            ]])
            assert.truthy(ok, err)

            local fn = ast[2]
            local stats = fn.block.stats
            assert.equal("Type.CInteger",
                types.resolve_c_typedef(stats[1].decls[1]._type)._tag)
            assert.equal("Type.CInteger",
                types.resolve_c_typedef(stats[2].decls[1]._type)._tag)
            assert.equal("Type.CPointer", stats[3].decls[1]._type._tag)
            assert.equal("Type.CPointer", stats[4].decls[1]._type._tag)
            for index = 5, 11 do
                local stat = stats[index]
                local condition = stat._tag == "Ast.StatIf"
                    and stat.thens[1].condition or stat.condition
                assert.is_true(condition._foreign_condition)
            end

            local integer_for = stats[12]
            local floating_for = stats[13]
            assert.equal("Type.CInteger",
                types.resolve_c_typedef(integer_for.decl._type)._tag)
            assert.equal("Type.CFloat",
                types.resolve_c_typedef(floating_for.decl._type)._tag)
            assert.is_true(integer_for.start._foreign_literal)
            assert.is_true(integer_for.inc._foreign_literal)
            assert.is_true(floating_for.start._foreign_literal)
            assert.is_true(floating_for.inc._foreign_literal)
        end)
    end)

    it("keeps size and alignment in the C size_t domain inside foreign bodies",
    function()
        with_header("#include <stddef.h>\n" .. declarations, function(header)
            local ok, err, ast = check_with_header(header, [[
                foreign function layout(): size_t
                    local size = foreign ffi_item.sizeof
                    local alignment = foreign ffi_item.alignof
                    return size + alignment
                end

                function ordinary_size(): integer
                    return foreign ffi_item.sizeof
                end
            ]])
            assert.truthy(ok, err)
            for index = 1, 2 do
                local exp = ast[2].block.stats[index].exps[1]
                assert.is_true(types.equals(exp._type,
                    exp.var._decl.result_source))
                assert.equal("Type.CInteger",
                    types.resolve_c_typedef(exp._type)._tag)
            end
            assert.equal("Type.Integer",
                ast[3].block.stats[1].exps[1]._type._tag)
        end)
    end)

    it("takes exact mutable pointer outputs without discarding pointee const",
    function()
        with_header(declarations .. [[
            void ffi_outputs(ffi_item **item, const char **text);
            void ffi_mutable_text(char **text);
        ]], function(header)
            local ok, err, ast = check_with_header(header, [[
                foreign function outputs()
                    local item: foreign *ffi_item = nil
                    local text: foreign const *char = nil
                    ffi.ffi_outputs(item, text)
                    local erased: foreign *void = item
                end
            ]])
            assert.truthy(ok, err)
            local stats = ast[2].block.stats
            local args = stats[3].callexp.args.args
            for index = 1, 2 do
                assert.equal("mutable_c_address",
                    args[index]._adjustment.coercion.op)
                assert.truthy(stats[index].decls[1]._c_address_taken)
            end
            assert.not_equal("mutable_c_address",
                stats[4].exps[1]._adjustment.coercion.op)

            assert_rejected(header, [[
                foreign function wrong()
                    local text: foreign const *char = nil
                    ffi.ffi_mutable_text(text)
                end
            ]], "would discard const")
            assert_rejected(header, [[
                foreign function immutable()
                    const item: foreign *ffi_item = nil
                    local text: foreign const *char = nil
                    ffi.ffi_outputs(item, text)
                end
            ]], "cannot take a mutable C address")
        end)
    end)

    it("retains written pointer reinterpretations beside implicit outputs",
    function()
        with_header([[
            void *ffi_pointer_source(void);
            void ffi_pointer_sink(void **pointer);
        ]], function(header)
            local ok, err, ast = check_with_header(header, [[
                foreign type Pointer = *void

                foreign function call_pointer(): *Pointer
                    return ffi.ffi_pointer_source() as foreign *Pointer
                end

                foreign function local_pointer()
                    local raw = ffi.ffi_pointer_source()
                    ffi.ffi_pointer_sink(raw as foreign *Pointer)
                end

                foreign function unrelated(pointer: *double): *int
                    return pointer as foreign *int
                end
            ]])
            assert.truthy(ok, err)
            local raw = ast[4].block.stats[1].decls[1]
            assert.is_nil(raw._c_address_taken)
            assert.is_false(ast[4].block.stats[2].callexp._c_mutated_decls)
            assert.is_nil(ast[3].block.stats[1].exps[1]._adjustment)
        end)
    end)

    it("parses one inherited C environment per module without Titan declarations",
    function()
        with_header([[
            #define FFI_REPLAY_FIELD nested.value
            typedef int ffi_replay_int;
        ]], function(provider_header)
            with_header([[
                typedef struct ffi_replay_nested { int value; } ffi_replay_nested;
                typedef struct ffi_replay_item { ffi_replay_nested nested; } ffi_replay_item;
            ]], function(consumer_header)
                local modules = {
                    provider = 'foreign import "' .. provider_header .. [["
                        foreign function callback(input: ffi_replay_int): ffi_replay_int
                            return input
                        end
                    ]],
                    consumer = [[
                        local provider = import "provider.titan"
                        foreign import "]] .. consumer_header .. [["
                        local function observed(item: foreign *ffi_replay_item): integer
                            return item.FFI_REPLAY_FIELD
                        end
                    ]],
                }
                local original, parsed = cdriver.process_module, {}
                cdriver.process_module = function(header, ...)
                    parsed[header.modname] = (parsed[header.modname] or 0) + 1
                    assert.falsy(header.contents:find(".titan.h", 1, true))
                    return original(header, ...)
                end
                local exercised, result = pcall(function()
                    local ok, err, imported = h.run_checker_modules(
                        modules, "consumer", { interface = "source" })
                    assert.truthy(ok, err)
                    return imported
                end)
                cdriver.process_module = original
                assert.truthy(exercised, result)
                assert.same({ provider = 1, consumer = 1 }, parsed)
                local ast = result.consumer.ast
                assert.equal("Type.Integer", ast[3].block.stats[1].exps[1]._type._tag)
                assert.is_table(ast._ffi_namespace._type.type_members.ffi_replay_int)
                assert.is_nil(ast._ffi_namespace._type.members.callback)
                local inputs = {}
                for _, input in ipairs(ast._c_header_dependencies) do
                    inputs[input.path] = true
                    assert.falsy(input.path:match("[.]ffi[.]h$"))
                    assert.falsy(input.path:match("[.]titan[.]h$"))
                end
                assert.is_true(inputs[provider_header])
                assert.is_true(inputs[consumer_header])
            end)
        end)
    end)

    it("seeds a source-only consumer with configured preprocessor macros",
    function()
        local previous_cppflags = driver.EXTRA_CPPFLAGS
        local configured = {}
        for _, flag in ipairs(previous_cppflags or {}) do
            configured[#configured + 1] = flag
        end
        configured[#configured + 1] =
            "-DFFI_CONFIG_FIELD=nested.value"

        local session
        driver.EXTRA_CPPFLAGS = configured
        local exercised, result = xpcall(function()
            session = driver.new_resolver_context()
            with_header([[
                typedef int ffi_config_int;
                typedef struct ffi_config_nested {
                    ffi_config_int value;
                } ffi_config_nested;
                typedef struct ffi_config_item {
                    ffi_config_nested nested;
                } ffi_config_item;
            ]], function(header)
                local provider_code = 'foreign import "' .. header .. [["
                    foreign type Item = *ffi_config_item
                    foreign type Int = ffi_config_int
                    foreign function noop(): void return end
                ]]
                local consumer_code = [[
                    local provider = import "provider.titan"
                    foreign function observed(item: Item): Int
                        return item.FFI_CONFIG_FIELD
                    end
                ]]
                local ok, err, imported = h.run_checker_modules({
                    provider = provider_code, consumer = consumer_code,
                }, "consumer", { interface = "source", context = session })
                assert.truthy(ok, err)
                local projected = imported.consumer.ast[2].block.stats[1].exps[1]
                assert.equal("Type.CInteger", types.resolve_c_typedef(projected._type)._tag)
                assert.same({ "nested", "value" }, projected.var._decl._macro_projection.path)
            end)
            return true
        end, debug.traceback)

        local closed, close_error = true, nil
        if session then
            closed, close_error = driver.close_resolver_context(session)
        end
        driver.EXTRA_CPPFLAGS = previous_cppflags
        local restore_context = driver.new_resolver_context()
        local restored, restore_error =
            driver.configure_foreign_c(restore_context)
        local restore_closed, restore_close_error =
            driver.close_resolver_context(restore_context)
        assert.truthy(closed, close_error)
        assert.truthy(restored, restore_error)
        assert.truthy(restore_closed, restore_close_error)
        assert.truthy(exercised, result)
    end)

    it("retains forced headers for contextual C without foreign imports",
    function()
        with_header("#define FFI_CONTEXTUAL_FORCED_INPUT 1\n", function(header)
            local previous_cppflags = driver.EXTRA_CPPFLAGS
            local configured = {}
            for _, flag in ipairs(previous_cppflags or {}) do
                configured[#configured + 1] = flag
            end
            configured[#configured + 1] = "-include"
            configured[#configured + 1] = header
            driver.EXTRA_CPPFLAGS = configured

            local context = driver.new_resolver_context()
            local configured_ok, configuration_error =
                driver.configure_foreign_c(context)
            local exercised, result = xpcall(function()
                assert.truthy(configured_ok, configuration_error)
                local ok, err, ast = h.run_checker([[
                    foreign function reinterpret(pointer: *int): *double
                        return pointer as foreign *double
                    end
                ]], context)
                assert.truthy(ok, err)
                assert.equal("Ast.TopLevelForeignFunc", ast[1]._tag)
                local saw_header, saw_search = false, false
                for _, input in ipairs(ast._c_header_dependencies or {}) do
                    assert.is_string(input.identity)
                    saw_header = saw_header or
                        (input.kind == "file" and input.path == header)
                    saw_search = saw_search or
                        (input.kind == "search" and input.path == header)
                end
                assert.is_true(saw_header)
                assert.is_true(saw_search)
            end, debug.traceback)

            local closed, close_error = driver.close_resolver_context(context)
            driver.EXTRA_CPPFLAGS = previous_cppflags
            local restore_context = driver.new_resolver_context()
            local restored, restore_error =
                driver.configure_foreign_c(restore_context)
            local restore_closed, restore_close_error =
                driver.close_resolver_context(restore_context)
            assert.truthy(closed, close_error)
            assert.truthy(restored, restore_error)
            assert.truthy(restore_closed, restore_close_error)
            assert.truthy(exercised, result)
        end)
    end)

    it("keeps nested generated include spellings stable across resolvers",
    function()
        local base = os.tmpname()
        os.remove(base)
        local filenames = {
            leaf = base .. "-leaf.titan",
            middle = base .. "-middle.titan",
            root = base .. "-root.titan",
        }
        local sources = {
            leaf = [[
                foreign function leaf(): void
                    return
                end
            ]],
            middle = [[
                local leaf = import "leaf.titan"
                foreign function middle(): void
                    return
                end
            ]],
            root = [[
                local middle = import "middle.titan"
                foreign function ready(): void
                    return
                end
            ]],
        }

        local function analyze()
            types.registry = {}
            driver.imported = {}
            local overrides = {}
            for name, filename in pairs(filenames) do
                overrides[name] = {
                    kind = "flat",
                    main = filename,
                    native_output = filename,
                    files = { filename },
                    contents = { [filename] = sources[name] },
                }
            end
            local context = driver.new_resolver_context()
            local loader = driver.defaultloader({}, {
                context = context,
                source_roots = { root = true },
                source_overrides = overrides,
            })
            local exercised, observed = xpcall(function()
                local ok, _, errors = loader("root")
                assert.truthy(ok)
                assert.equal(0, #errors, table.concat(errors, "\n"))
                local ast = driver.imported.root.ast
                local include = ast._ffi_namespace._include
                assert.is_table(include)
                local service = assert(driver.get_probe_service(context))
                local module_context, context_error =
                    service:module_context({
                        source_dir = base:match("^(.*)/") or ".",
                        includes = { include },
                    })
                assert.truthy(module_context, context_error)
                return {
                    physical = ast._ffi_header.filename,
                    source_key = module_context.baseline_key,
                    header = ast._ffi_header,
                }
            end, debug.traceback)
            local loader_closed, loader_close_error =
                driver.close_loader(loader)
            local context_closed, context_close_error =
                driver.close_resolver_context(context)
            assert.truthy(loader_closed, loader_close_error)
            assert.truthy(context_closed, context_close_error)
            assert.truthy(exercised, observed)
            return observed
        end

        local first = analyze()
        local second = analyze()
        assert.not_equal(first.physical, second.physical)
        assert.is_string(first.source_key)
        assert.equal(first.source_key, second.source_key)
        local function compare(left, right)
            assert.equal(left.contents, right.contents)
            assert.equal(left.identity, right.identity)
            assert.equal(left.digest, right.digest)
            assert.not_equal(left.filename, right.filename)
            assert.equal(#left.dependencies, #right.dependencies)
            for index, dependency in ipairs(left.dependencies) do
                compare(dependency, right.dependencies[index])
            end
        end
        compare(first.header, second.header)
    end)

    it("keeps source foreign members direct-only and out of compiled interfaces",
    function()
        with_header("typedef int ffi_int;\n", function(header)
            local quoted = string.format("%q", header)
            local modules = {
                provider = "foreign import " .. quoted .. [[
                    foreign function increment(
                        input: ffi_int
                    ): ffi_int
                        return input + 1
                    end

                    function ordinary(input: integer): integer
                        return input + 1
                    end
                ]],
                consumer = "foreign import " .. quoted .. [[
                    local provider = import "provider.titan"
                    foreign type Callback = function (ffi_int): ffi_int

                    foreign function through(
                        input: ffi_int
                    ): ffi_int
                        return provider.increment(input)
                    end

                    local function address(): foreign Callback
                        return provider.increment
                    end
                ]],
            }

            local ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.truthy(ok, err)

            modules.consumer = "foreign import " .. quoted .. [[
                local provider = import "provider"
                foreign type Callback = function (ffi_int): ffi_int

                foreign function through(
                    input: ffi_int
                ): ffi_int
                    return provider.increment(input)
                end

                local function address(): foreign Callback
                    return provider.increment
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "compiled" })
            assert.falsy(ok)
            assert.match("member 'increment' not found", err)

            modules.bridge = "foreign import " .. quoted .. [[
                local provider = import "provider.titan"
                foreign function through(
                    input: ffi_int
                ): ffi_int
                    return provider.increment(input)
                end
            ]]
            modules.consumer = "foreign import " .. quoted .. [[
                local bridge = import "bridge.titan"
                local provider = import "provider.titan"

                foreign function transitive_view(
                    input: ffi_int
                ): ffi_int
                    return bridge.increment(input)
                end

                foreign function ordinary_member(
                    input: ffi_int
                ): ffi_int
                    return provider.ordinary(input as integer)
                        as foreign ffi_int
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.falsy(ok)
            assert.match(
                "member 'increment' not found inside module 'bridge'", err)
            assert.match(
                "ordinary Titan member 'provider%.ordinary' is not visible",
                err)
        end)
    end)

    it("diagnoses invalid foreign signatures and result shapes", function()
        with_header(declarations, function(header)
            local rejected = {
                {
                    [[foreign function bad(input: integer): void end]],
                    "foreign type 'integer' is not declared",
                },
                {
                    [[foreign function bad(input: ffi_row): void end]],
                    "must be a direct C FFI type",
                },
                {
                    [[foreign function bad(
                        input: ffi_incomplete
                    ): void end]],
                    "requires complete C struct type",
                },
                {
                    [[foreign function bad(
                        ...
                    ): void end]],
                    "cannot have variadic parameters",
                },
                {
                    [[foreign type Bad = function (ffi_int, ...): void]],
                    "foreign function type cannot have variadic parameters",
                },
                {
                    [[foreign function bad(): ffi_int end]],
                    "function can return nil",
                },
            }
            for _, case in ipairs(rejected) do
                assert_rejected(header, case[1], case[2])
            end
        end)
    end)

    it("diagnoses Titan-only visibility and body constructs", function()
        with_header(declarations, function(header)
            local rejected = {
                {
                    [[local function helper(): integer return 1 end
                      foreign function bad(): ffi_int
                          return helper()
                      end]],
                    "ordinary Titan declaration 'helper' is not visible",
                },
                {
                    [[foreign function bad(): ffi_int
                          local count: integer = 1
                          return 0
                      end]],
                    "inside a foreign function must have a direct C FFI type",
                },
                {
                    [[foreign function bad(): void
                          for item in iterator do end
                      end]],
                    "generic for loops are not available",
                },
                {
                    [[foreign function bad(): void
                          raise "error"
                      end]],
                    "raise statements are not available",
                },
                {
                    [[foreign function bad(): void
                          do catch end
                      end]],
                    "catch/finally blocks are not available",
                },
                {
                    [[foreign function bad(): void
                          defer ffi.ffi_add(1, 2)
                      end]],
                    "defer statements are not available",
                },
                {
                    [[foreign function bad(): void
                          local callback = function() end
                      end]],
                    "anonymous functions are not available",
                },
                {
                    [[foreign function bad(): void
                          local values = {}
                      end]],
                    "Titan constructors are not available",
                },
                {
                    [[foreign function bad(): void
                          local prefix = "a"
                          local text = prefix .. "b"
                      end]],
                    "string concatenation are not available",
                },
                {
                    [[foreign function bad(): void
                          local item = foreign ffi_item.new()
                      end]],
                    "allocation pseudo%-functions are not available",
                },
                {
                    [[foreign function bad(input: ffi_int): ffi_int
                          local boxed = input as value
                          return input
                      end]],
                    "casts between Titan values and C FFI values are not available",
                },
            }
            for _, case in ipairs(rejected) do
                assert_rejected(header, case[1], case[2])
            end
        end)
    end)

    it("diagnoses non-scalar conditions and invalid C numeric loops", function()
        with_header(declarations, function(header)
            assert_rejected(header, [[
                foreign function bad(item: ffi_item): void
                    if item then return end
                end
            ]], "condition must have a C scalar type")

            assert_rejected(header, [[
                foreign function bad(limit: ffi_int): void
                    for i: foreign ffi_int = 0, limit, 0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(limit: ffi_double): void
                    for i: foreign ffi_double = 0.0, limit, 0.0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(): void
                    for i = 0.0, 1.0, -0.0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(): void
                    for i = 0, 1, -0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(item: *ffi_item): void
                    for current: foreign *ffi_item = item, item do end
                end
            ]], "type of for control variable current must be integer or float")
        end)
    end)
end)
