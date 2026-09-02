-- Phase-A checker coverage for flexible-return schema propagation. Result-list
-- adjustment and code generation are exercised by later feature phases.
local checker = require 'titan-compiler.checker'
local types = require 'titan-compiler.types'
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local check_errs = h.check_errs

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
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

describe("flexible return schemas (typechecker)", function()
    it("resolves tails on functions, record functions, and methods", function()
        local ok, err, tree = run_checker([[
            record Box
                n: integer
            end

            function names(): (...: string)
            end

            function Box.lookup(): (boolean, ...: integer)
                return true
            end

            function Box:items(): (...: value)
            end
        ]])
        assert.truthy(ok, err)

        assert.same(types.String(), tree[3]._type.flexrettype)
        assert.same(types.Integer(), tree[4]._type.flexrettype)
        assert.same(types.Value(), tree[5]._type.flexrettype)
        assert.same(types.Boolean(), tree[4]._type.rettypes[1])
    end)

    it("infers complete results unless explicit `: ()` overrides them", function()
        local ok, err, tree = run_checker([[
            function run(): nil
                local inferred: () -> (boolean, ...: integer) = function()
                    return true
                end
                local explicit: () -> (value, ...: integer) = function(): ()
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local inferred = tree[1].block.stats[1].exps[1]._type
        local explicit_cast = tree[1].block.stats[2].exps[1]
        assert.equal("Ast.ExpCast", explicit_cast._tag)
        assert.equal("callable", explicit_cast._adjustment.kind)
        assert.equal("nil_fill_result",
            explicit_cast._callable_adapter.results[1].kind)
        assert.equal("end_flex",
            explicit_cast._callable_adapter.results[2].kind)
        local explicit = explicit_cast.exp._type
        assert.same(types.Boolean(), inferred.rettypes[1])
        assert.same(types.Integer(), inferred.flexrettype)
        assert.same({}, explicit.rettypes)
        assert.is_false(explicit.flexrettype)
    end)

    it("uses a return-specific diagnostic for an invalid nil tail", function()
        local errs = check_errs([[
            function bad(): (...: nil)
            end
        ]])
        assert.truthy(#errs >= 1)
        assert.match("flexible return cannot have type nil", errs[1])
    end)

    it("locates an unresolved nominal tail at its own annotation", function()
        local errs = check_errs("function bad(): (...: Missing)\nend")
        assert.same(1, #errs)
        assert.match("^%(spec%):1:23: type error: "
            .. "invalid type 'test%.Missing' in type declaration$", errs[1])
    end)

    it("uses return-specific diagnostics for foreign and unmapped tails", function()
        with_header([[
            typedef int ffi_int;
            typedef ffi_int *ffi_int_ptr;
        ]], function(header)
            local errs = check_errs([[
                local c = foreign import "]] .. header .. [["
                function bad_pointer(): (...: c.ffi_int_ptr)
                end
                function bad_scalar(): (...: c.ffi_int)
                end
            ]])
            assert.truthy(#errs >= 2)
            local joined = table.concat(errs, "\n")
            assert.match("flexible return cannot have a foreign pointer type",
                joined)
            assert.match("flexible return cannot use type .-ffi_int",
                joined)
            assert.match("no supported variadic%-value representation",
                joined)
        end)
    end)

    it("accepts Lua TValue through the shared input/output descriptor", function()
        with_header([[
            typedef struct TValue TValue;
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                local function take(...: c.TValue): nil
                    return nil
                end

                local function give(): (...: c.TValue)
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("registers records referenced by recovered record callable tails", function()
        h.reset(true)
        local static_record = types.Record("owner.StaticR", {}, {}, {}, 0)
        local method_record = types.Record("owner.MethodR", {}, {}, {}, 0)
        local owner = types.Module("owner", {
            types.ModuleMember("owner", "StaticR", static_record, false),
            types.ModuleMember("owner", "MethodR", method_record, false),
        }, {})

        local box = types.Record("consumer.Box", {}, {
            make = types.StaticMethod("consumer.Box", "make", {}, {}, false,
                types.Nominal("owner.StaticR"), {}),
        }, {
            get = types.Method("consumer.Box", "get", {}, {}, false,
                types.Nominal("owner.MethodR"), {}),
        }, 0)
        local consumer = types.Module("consumer", {
            types.ModuleMember("consumer", "Box", box, false),
        }, {})
        local modules = { consumer = consumer, owner = owner }
        local loaded = {}
        local function loader(name)
            loaded[name] = (loaded[name] or 0) + 1
            return true, assert(modules[name]), {}
        end

        local typ, errs = checker.checkimport("consumer", loader)
        assert.same(consumer, typ)
        assert.same({}, errs)
        assert.same(1, loaded.owner)
        assert.same(static_record, types.registry["owner.StaticR"])
        assert.same(method_record, types.registry["owner.MethodR"])
    end)

    it("does not treat a flexible-return record function as a constant constructor", function()
        local ok, err = run_checker([[
            record Box
                n: integer
            end

            function Box.make(): (Box, ...: integer)
                return Box.new(1)
            end

            local box = Box.make()
        ]])
        assert.falsy(ok)
        assert.match("top level variable initialization must be constant", err)
    end)

    it("rejects a public flexible tail that exposes a module-local record", function()
        local errs = check_errs([[
            local record Secret
            end

            function leak(): (...: Secret)
            end
        ]])
        assert.truthy(#errs >= 1)
        assert.match("cannot export local record type 'test.Secret'", errs[1])
    end)

    it("keeps foreign generic-for callables on their C signatures", function()
        with_header([[
            typedef int *ffi_int_ptr;
            extern ffi_int_ptr ffi_next(void);
        ]], function(header)
            local ok, err, tree = run_checker([[
                local c = foreign import "]] .. header .. [["

                function run(): nil
                    for n: c.ffi_int_ptr in c.ffi_next, nil, nil do
                    end
                    return nil
                end
            ]])
            assert.truthy(ok, err)
            local loop = tree[2].block.stats[1]
            local pointer = loop.exps[1]._type
            assert.equal("Type.CPointer", pointer._tag)
            local cfunc = types.resolve_c_typedef(pointer.pointee)
            assert.equal("Type.CFunction", cfunc._tag)
            assert.is_nil(cfunc.flexrettype)
            assert.equal(cfunc, loop._init_call._callee_type)
        end)
    end)

    it("does not recognize a flexible-return main as the executable entry", function()
        local ok, err, tree = run_checker([[
            function main(args: {string}): (integer, ...: integer)
                return 0
            end
        ]])
        assert.truthy(ok, err)
        assert.falsy(checker.has_main(tree))
    end)

    it("does not recognize a variadic main as the executable entry", function()
        local ok, err, tree = run_checker([[
            function main(...: {string}): integer
                return 0
            end
        ]])
        assert.truthy(ok, err)
        assert.falsy(checker.has_main(tree))
    end)
end)
