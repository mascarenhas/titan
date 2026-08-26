local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local checker = require "titan-compiler.checker"
local checker_core = require "titan-compiler.checker.core"
local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"

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
        'local c = foreign import "' .. header .. '"\n' .. body,
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
                local type EmptyCallback = foreign () -> ()
                local type Callback =
                    foreign (*c.ffi_item, c.ffi_int) -> c.ffi_int
                local type HigherOrder = foreign (Callback) -> Callback

                foreign function noop(): ()
                    return
                end

                foreign function invoke(
                    callback: Callback,
                    item: *c.ffi_item,
                    input: c.ffi_int
                ): c.ffi_int
                    return callback(item, input)
                end
            ]])
            assert.truthy(ok, err)

            local empty = ast[2]._type
            assert.equal("Type.CPointer", empty._tag)
            assert.equal("Type.CFunction", empty.pointee._tag)
            assert.is_false(empty.pointee.abi)
            assert.is_false(empty.pointee.vararg)
            assert.equal("Type.CVoid",
                types.resolve_c_typedef(empty.pointee.ret)._tag)

            local callback = ast[3]._type
            assert.equal("Type.CPointer", callback._tag)
            assert.equal("Type.CFunction", callback.pointee._tag)
            assert.equal(2, #callback.pointee.params)
            assert.equal("Type.CInteger",
                types.resolve_c_typedef(callback.pointee.ret)._tag)

            local higher = ast[4]._type
            assert.equal("Type.CPointer", higher._tag)
            assert.equal("Type.CPointer", higher.pointee.params[1]._tag)
            assert.equal("Type.CPointer", higher.pointee.ret._tag)

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
                local type Binary =
                    foreign (c.ffi_int, c.ffi_int) -> c.ffi_int

                foreign function first(
                    left: c.ffi_int,
                    right: c.ffi_int
                ): c.ffi_int
                    return second { rhs = right, lhs = left }
                end

                foreign function second(
                    lhs: c.ffi_int,
                    rhs: c.ffi_int
                ): c.ffi_int
                    return c.ffi_add(lhs, rhs)
                end

                local function address(): Binary
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
                    item: *c.ffi_item,
                    callback: c.ffi_callback,
                    count: c.ffi_int,
                    limit: c.ffi_double
                ): c.ffi_int
                    local total: c.ffi_int = 0
                    local flag = true
                    local text: const *c.ffi_char = "ffi"
                    local missing: *c.ffi_item = nil

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

                    for i: c.ffi_int = 0, count, 1 do
                        total = total + i
                    end
                    for n: c.ffi_double = 0.0, limit, 1.0 do
                        if n then break end
                    end
                    return total + c.ffi_text_present(text)
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

    it("replays source C context without parsing the generated companion",
    function()
        with_header([[
            #define FFI_REPLAY_FIELD nested.value
            typedef int ffi_replay_int;
        ]], function(provider_header)
            with_header([[
                typedef struct ffi_replay_nested {
                    int value;
                } ffi_replay_nested;
                typedef struct ffi_replay_item {
                    ffi_replay_nested nested;
                } ffi_replay_item;
            ]], function(consumer_header)
                local provider_code =
                    'local c = foreign import "' .. provider_header .. [["
                    foreign function callback(
                        input: c.ffi_replay_int
                    ): c.ffi_replay_int
                        return input
                    end
                ]]
                local provider_ok, provider_error, _, provider =
                    h.run_checker(provider_code, probe_session)
                assert.truthy(provider_ok, provider_error)
                assert.is_table(provider._source_c_context)
                assert.is_true(
                    provider._source_c_context.macro_changes.FFI_REPLAY_FIELD)

                with_header('#include "' .. provider_header .. '"\n',
                function(companion)
                    local code = [[
                        local provider = import "provider.titan"
                        local c = foreign import "]] .. consumer_header .. [["
                        local function observed(
                            item: *c.ffi_replay_item
                        ): integer
                            return item.FFI_REPLAY_FIELD
                        end
                    ]]
                    local ast = assert(h.parse(code))
                    local loader = function(name)
                        assert.equal("provider", name)
                        return true, provider, {}, {
                            kind = "source",
                            foreign_header = companion,
                            foreign_header_for_check = true,
                            foreign_header_probe_identity =
                                provider_header .. ".titan.h",
                        }
                    end
                    local original_process_file = cdriver.process_file
                    local original_source_foreign_include_alias =
                        cprobe.source_foreign_include_alias
                    local parsed_companion = false
                    local aliases = {}
                    cdriver.process_file = function(filename, ...)
                        if filename == companion then
                            parsed_companion = true
                            error("generated companion reached cdriver")
                        end
                        return original_process_file(filename, ...)
                    end
                    cprobe.source_foreign_include_alias = function(...)
                        local include, include_error =
                            original_source_foreign_include_alias(...)
                        if include then aliases[#aliases + 1] = include end
                        return include, include_error
                    end
                    local exercised, result = pcall(function()
                        local function check(checked_ast)
                            types.registry = {}
                            driver.imported = {}
                            local modtype, errors = checker.check(
                                "consumer", checked_ast, code,
                                "consumer.titan", loader, {
                                    probe_service_provider = function()
                                        return driver.get_probe_service(
                                            probe_session)
                                    end,
                                })
                            assert.equal(0, #errors,
                                table.concat(errors, "\n"))
                            return modtype
                        end

                        local modtype = check(ast)
                        local first_alias = aliases[#aliases]
                        assert.is_table(first_alias)
                        local changed = assert(io.open(companion, "a"))
                        assert(changed:write(
                            "/* changed generated bytes */\n"))
                        assert(changed:close())
                        aliases = {}
                        local changed_ast = assert(h.parse(code))
                        local changed_modtype = check(changed_ast)
                        local second_alias = aliases[#aliases]
                        assert.is_table(second_alias)

                        local service = assert(
                            driver.get_probe_service(probe_session))
                        local first_context, first_context_error =
                            service:module_context({
                                source_dir = ".",
                                includes = { first_alias },
                            })
                        assert.truthy(first_context, first_context_error)
                        local second_context, second_context_error =
                            service:module_context({
                                source_dir = ".",
                                includes = { second_alias },
                            })
                        assert.truthy(second_context, second_context_error)
                        return {
                            modtype = modtype,
                            changed_ast = changed_ast,
                            changed_modtype = changed_modtype,
                            first_alias = first_alias,
                            second_alias = second_alias,
                            first_header_key = first_context.header_key,
                            second_header_key = second_context.header_key,
                        }
                    end)
                    cdriver.process_file = original_process_file
                    cprobe.source_foreign_include_alias =
                        original_source_foreign_include_alias
                    assert.truthy(exercised, result)
                    assert.is_table(result.modtype)
                    assert.is_table(result.changed_modtype)
                    assert.is_false(parsed_companion)
                    assert.is_string(result.first_header_key)
                    assert.is_string(result.second_header_key)
                    assert.not_equal(result.first_header_key,
                        result.second_header_key)
                    assert.equal("Type.Integer",
                        ast[3].block.stats[1].exps[1]._type._tag)
                    assert.is_true(ast[1]._foreign_header_for_check)
                    assert.equal(provider_header .. ".titan.h",
                        ast[1]._foreign_header_probe_identity)
                    local inputs = {}
                    for _, input in ipairs(ast._c_header_dependencies) do
                        inputs[input.path] = true
                    end
                    assert.is_true(inputs[provider_header])
                    assert.is_true(inputs[consumer_header])
                    assert.is_nil(inputs[companion])
                    local first_generated =
                        result.first_alias.c_header_dependencies[1]
                    local second_generated =
                        result.second_alias.c_header_dependencies[1]
                    assert.equal(provider_header .. ".titan.h",
                        first_generated.path)
                    assert.is_false(first_generated.restat)
                    assert.match("^c%-header%-generated%-v1:sha256:[0-9a-f]+$",
                        first_generated.identity)
                    assert.not_equal(first_generated.identity,
                        second_generated.identity)
                end)
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
                local provider_code =
                    'local c = foreign import "' .. header .. [["
                    local type Item = *c.ffi_config_item
                    local type Int = c.ffi_config_int
                    foreign function noop(): ()
                        return
                    end
                ]]
                local provider_ok, provider_error, _, provider =
                    h.run_checker(provider_code, session)
                assert.truthy(provider_ok, provider_error)
                assert.is_nil(
                    provider._source_c_context.macro_changes.FFI_CONFIG_FIELD)
                assert.is_table(
                    provider._source_c_context.macro_definitions.FFI_CONFIG_FIELD)

                with_header('#include "' .. header .. '"\n',
                function(companion)
                    local code = [[
                        local provider = import "provider.titan"
                        foreign function observed(
                            item: provider.Item
                        ): provider.Int
                            return item.FFI_CONFIG_FIELD
                        end
                    ]]
                    local ast = assert(h.parse(code))
                    local loader = function(name)
                        assert.equal("provider", name)
                        return true, provider, {}, {
                            kind = "source",
                            foreign_header = companion,
                            foreign_header_for_check = true,
                            foreign_header_probe_identity =
                                header .. ".titan.h",
                        }
                    end
                    types.registry = {}
                    driver.imported = {}
                    local _, errors = checker.check(
                        "consumer", ast, code, "consumer.titan", loader, {
                            probe_service_provider = function()
                                return driver.get_probe_service(session)
                            end,
                        })
                    assert.equal(0, #errors, table.concat(errors, "\n"))
                    local projected = ast[2].block.stats[1].exps[1]
                    assert.equal("Type.CInteger",
                        types.resolve_c_typedef(projected._type)._tag)
                    assert.same({ "nested", "value" },
                        projected.var._decl._macro_projection.path)
                end)
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

    it("stabilizes nested generated header identities across resolvers",
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
                foreign function leaf(): ()
                    return
                end
            ]],
            middle = [[
                local leaf = import "leaf.titan"
                foreign function middle(): ()
                    return
                end
            ]],
            root = [[
                local middle = import "middle.titan"
                foreign function ready(): ()
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
                local import = driver.imported.root.ast[1]
                local include = import._source_foreign_include
                assert.is_table(include)
                local generated = include.c_header_dependencies[1]
                assert.is_table(generated)
                local service = assert(driver.get_probe_service(context))
                local module_context, context_error =
                    service:module_context({
                        source_dir = base:match("^(.*)/") or ".",
                        includes = { include },
                    })
                assert.truthy(module_context, context_error)
                return {
                    physical = import._foreign_header,
                    identity = generated.identity,
                    header_key = module_context.header_key,
                    diagnostic_aliases =
                        module_context.probe_diagnostic_aliases,
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
        assert.match("^c%-header%-generated%-v1:sha256:[0-9a-f]+$",
            first.identity)
        assert.equal(first.identity, second.identity)
        assert.equal(first.header_key, second.header_key)
        assert.equal(2, #first.diagnostic_aliases)
        assert.equal(2, #second.diagnostic_aliases)
        for index = 1, 2 do
            assert.is_string(first.diagnostic_aliases[index].physical_path)
            assert.is_string(first.diagnostic_aliases[index].public_path)
            assert.not_equal(
                first.diagnostic_aliases[index].physical_path,
                second.diagnostic_aliases[index].physical_path)
            assert.equal(
                first.diagnostic_aliases[index].public_path,
                second.diagnostic_aliases[index].public_path)
        end
    end)

    it("ignores malformed transitive generated-header aliases", function()
        local modast = {
            {
                _tag = "Ast.TopLevelForeignFunc",
                name = "published",
                _type = types.Function({}, {}, false, false, false),
                _paramnames = {},
            },
            {
                _tag = "Ast.TopLevelImport",
                _source_import = true,
                _foreign_header_probe_identity = "dependency.titan.h",
                _source_foreign_generated_identity =
                    "c-header-generated-v1:sha256:dependency",
                _foreign_header = false,
                _source_c_context = {
                    diagnostic_aliases = {
                        {
                            physical_path = "/private/dependency.titan.h",
                            public_path = "dependency.titan.h",
                        },
                        {
                            physical_path = "/private/malformed.titan.h",
                            public_path = false,
                        },
                    },
                },
            },
        }
        modast._c_header_dependencies = {}
        local st = {
            foreign_macro_changes = {},
            foreign_macro_environment = function() return {} end,
        }

        local modtype = checker_core.makemoduletype(
            "test", modast, st)
        assert.same({
            {
                physical_path = "/private/dependency.titan.h",
                public_path = "dependency.titan.h",
            },
        }, modtype._source_c_context.diagnostic_aliases)
    end)

    it("keeps source foreign members direct-only and out of compiled interfaces",
    function()
        with_header(declarations, function(header)
            local quoted = string.format("%q", header)
            local modules = {
                provider = 'local c = foreign import ' .. quoted .. [[
                    foreign function increment(
                        input: c.ffi_int
                    ): c.ffi_int
                        return input + 1
                    end

                    function ordinary(input: integer): integer
                        return input + 1
                    end
                ]],
                consumer = 'local c = foreign import ' .. quoted .. [[
                    local provider = import "provider.titan"
                    local type Callback =
                        foreign (c.ffi_int) -> c.ffi_int

                    foreign function through(
                        input: c.ffi_int
                    ): c.ffi_int
                        return provider.increment(input)
                    end

                    local function address(): Callback
                        return provider.increment
                    end
                ]],
            }

            local ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.truthy(ok, err)

            modules.consumer = 'local c = foreign import ' .. quoted .. [[
                local provider = import "provider"
                local type Callback =
                    foreign (c.ffi_int) -> c.ffi_int

                foreign function through(
                    input: c.ffi_int
                ): c.ffi_int
                    return provider.increment(input)
                end

                local function address(): Callback
                    return provider.increment
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "compiled" })
            assert.falsy(ok)
            assert.match("member 'increment' not found", err)

            modules.bridge = 'local c = foreign import ' .. quoted .. [[
                local provider = import "provider.titan"
                foreign function through(
                    input: c.ffi_int
                ): c.ffi_int
                    return provider.increment(input)
                end
            ]]
            modules.consumer = 'local c = foreign import ' .. quoted .. [[
                local bridge = import "bridge.titan"
                foreign function bad(
                    input: c.ffi_int
                ): c.ffi_int
                    return bridge.increment(input)
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.falsy(ok)
            assert.match("member 'increment' not found inside module 'bridge'", err)

            modules.consumer = 'local c = foreign import ' .. quoted .. [[
                local bridge = import "bridge.titan"
                local provider = import "provider.titan"
                foreign function direct(
                    input: c.ffi_int
                ): c.ffi_int
                    return bridge.through(input) + provider.increment(input)
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.truthy(ok, err)

            modules.consumer = 'local c = foreign import ' .. quoted .. [[
                local provider = import "provider.titan"
                foreign function bad(
                    input: c.ffi_int
                ): c.ffi_int
                    return provider.ordinary(input as integer)
                        as c.ffi_int
                end
            ]]
            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.falsy(ok)
            assert.match("ordinary Titan member 'provider%.ordinary' is not visible", err)
        end)
    end)

    it("diagnoses invalid foreign signatures and result shapes", function()
        with_header(declarations, function(header)
            local rejected = {
                {
                    [[foreign function bad(input: integer): () end]],
                    "must be a direct C FFI type",
                },
                {
                    [[foreign function bad(
                        input: owned *c.ffi_item
                    ): () end]],
                    "must be a direct C FFI type",
                },
                {
                    [[foreign function bad(input: c.ffi_row): () end]],
                    "must be a direct C FFI type",
                },
                {
                    [[foreign function bad(
                        input: c.ffi_incomplete
                    ): () end]],
                    "requires complete C struct type",
                },
                {
                    [[foreign function bad(
                        ...: c.ffi_int
                    ): () end]],
                    "cannot have variadic parameters",
                },
                {
                    [[foreign function bad():
                        (c.ffi_int, c.ffi_int)
                        return 1, 2
                    end]],
                    "can return at most one value",
                },
                {
                    [[foreign function bad():
                        (...: c.ffi_int)
                    end]],
                    "cannot have flexible returns",
                },
                {
                    [[local type Bad =
                        foreign (c.ffi_int, ...: c.ffi_int) -> ()]],
                    "foreign function type cannot have variadic parameters",
                },
                {
                    [[foreign function bad(): c.ffi_int end]],
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
                      foreign function bad(): c.ffi_int
                          return helper()
                      end]],
                    "ordinary Titan declaration 'helper' is not visible",
                },
                {
                    [[foreign function bad(): c.ffi_int
                          local count: integer = 1
                          return 0
                      end]],
                    "inside a foreign function must have a direct C FFI type",
                },
                {
                    [[foreign function bad(): ()
                          for item in iterator do end
                      end]],
                    "generic for loops are not available",
                },
                {
                    [[foreign function bad(): ()
                          raise "error"
                      end]],
                    "raise statements are not available",
                },
                {
                    [[foreign function bad(): ()
                          do catch end
                      end]],
                    "catch/finally blocks are not available",
                },
                {
                    [[foreign function bad(): ()
                          defer c.ffi_add(1, 2)
                      end]],
                    "defer statements are not available",
                },
                {
                    [[foreign function bad(): ()
                          local callback = function() end
                      end]],
                    "anonymous functions are not available",
                },
                {
                    [[foreign function bad(): ()
                          local values = {}
                      end]],
                    "Titan constructors are not available",
                },
                {
                    [[foreign function bad(): ()
                          local prefix = "a"
                          local text = prefix .. "b"
                      end]],
                    "string concatenation are not available",
                },
                {
                    [[foreign function bad(): ()
                          local item = c.ffi_item.new()
                      end]],
                    "allocation pseudo%-functions are not available",
                },
                {
                    [[foreign function bad(input: c.ffi_int): c.ffi_int
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
                foreign function bad(item: c.ffi_item): ()
                    if item then return end
                end
            ]], "condition must have a C scalar type")

            assert_rejected(header, [[
                foreign function bad(limit: c.ffi_int): ()
                    for i: c.ffi_int = 0, limit, 0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(limit: c.ffi_double): ()
                    for i: c.ffi_double = 0.0, limit, 0.0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(): ()
                    for i = 0.0, 1.0, -0.0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(): ()
                    for i = 0, 1, -0 do end
                end
            ]], "requires a nonzero step")

            assert_rejected(header, [[
                foreign function bad(item: *c.ffi_item): ()
                    for current: *c.ffi_item = item, item do end
                end
            ]], "type of for control variable current must be integer or float")
        end)
    end)
end)
