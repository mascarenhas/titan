local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"

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

    it("replays a direct source foreign header before consumer checking",
    function()
        with_header([[
            #define FFI_REPLAY_VALUE 9
            typedef int ffi_replay_int;
        ]], function(header)
            local cfunc = types.CFunction({},
                types.CInteger("int", true, 3, 32), false, false)
            local member = types.ModuleMember(
                "provider", "callback", cfunc, {})
            member._foreign_source = true
            member.islocal = true
            local provider = types.Module("provider", {})
            provider._source = true
            provider.source_members = { member }
            provider.source_members.callback = member
            provider.source_type_members = {}

            local code = [[
                local provider = import "provider"
                local c = foreign import "]] .. header .. [["
                function observed(): integer return c.FFI_REPLAY_VALUE end
            ]]
            local ast = assert(h.parse(code))
            local loader = function(name)
                assert.equal("provider", name)
                return true, provider, {}, {
                    kind = "source",
                    foreign_header = header,
                    foreign_header_for_check = true,
                }
            end
            types.registry = {}
            driver.imported = {}
            local _, errors = checker.check(
                "consumer", ast, code, "consumer.titan", loader)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            assert.equal("Type.Integer", ast[3].block.stats[1].exps[1]._type._tag)
            assert.is_true(ast[1]._foreign_header_for_check)
        end)
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
                ]],
            }

            local ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "source" })
            assert.truthy(ok, err)

            ok, err = h.run_checker_modules(
                modules, "consumer", { interface = "compiled" })
            assert.falsy(ok)
            assert.match("member 'increment' not found", err)

            modules.bridge = 'local c = foreign import ' .. quoted .. [[
                local provider = import "provider"
                foreign function through(
                    input: c.ffi_int
                ): c.ffi_int
                    return provider.increment(input)
                end
            ]]
            modules.consumer = 'local c = foreign import ' .. quoted .. [[
                local bridge = import "bridge"
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
                local bridge = import "bridge"
                local provider = import "provider"
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
                local provider = import "provider"
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
