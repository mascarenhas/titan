-- Typechecker tests for the `.so`-only import path. Importing a module that is
-- available only as a compiled shared library forces the checker to *rehydrate*
-- that module's interface from its serialized `<mangled>_types` symbol (rather
-- than re-checking source). These tests verify that the rehydrated types --
-- functions, higher-order/first-class function types, records (incl. methods
-- and transitively-referenced records), and module variables -- are recovered
-- faithfully: correct uses type-check, and wrong uses are rejected using the
-- recovered signatures.
--
-- Each dependency is compiled to a `.so` straight from its AST (so its `.titan`
-- source never reaches the source path); only then is the TYPE CHECKER run on
-- the importer. No importer code is generated or executed here -- the end-to-end
-- run-time behaviour of the same path lives in spec/coder/so_import_spec.lua.
local h = require 'spec.support.helpers'
local lfs = require 'lfs'
local checker = require 'titan-compiler.checker'
local types = require 'titan-compiler.types'
local generated_modules = {}

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function clean_generated_modules()
    for name in pairs(generated_modules) do
        remove_tree(name .. ".c")
        remove_tree(name .. ".o")
        remove_tree(name .. ".so")
        remove_tree(name .. ".a")
        remove_tree(name .. ".so.dSYM")
    end
    generated_modules = {}
end

local function so_check(deps, ...)
    for _, dep in ipairs(deps) do
        generated_modules[dep.name] = true
    end
    return h.check_against_so(deps, ...)
end

describe("typechecker rehydration of .so-only imports", function()
    after_each(clean_generated_modules)

    it("rehydrates a function signature and checks calls against it", function ()
        local dep = { name = "rhfoo", src = [[
            function add(a: integer, b: integer): integer return a + b end
        ]] }
        local good = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2, 3) end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2) end   -- missing nil cannot fill integer
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found nil", table.concat(bad, "\n"))

        local badty = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2, "x") end  -- wrong arg type
        ]])
        assert.truthy(#badty >= 1)
        assert.match("expected integer but found string", table.concat(badty, "\n"))
    end)

    it("rehydrates declaration names for named calls", function ()
        local dep = { name = "namedrhfoo", src = [[
            record Empty end

            record Box
                primary: integer
                extra: integer?
            end

            function Box.make(primary: integer, extra: integer?): Box
                return Box.new(primary, extra)
            end

            function Box:shift(delta: integer, spare: integer?): integer
                return self.primary + delta
            end

            function choose(left: integer, right: integer): integer
                return left * 100 + right
            end

            function zero(): integer
                return 9
            end
        ]] }

        local good = so_check({ dep }, "namedrhbar", [[
            local f = import "namedrhfoo"

            function run(): integer
                local empty: f.Empty = f.Empty.new {}
                local box = f.Box.make { extra = 2, primary = 3 }
                local direct = f.Box.new { primary = 4 }
                return f.choose { right = 2, left = 4 }
                    + box:shift { delta = 5 }
                    + direct:shift { delta = 6 }
                    + f.zero {}
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local box = assert(types.registry["namedrhfoo.Box"])
        assert.same({ "primary", "extra" }, box.functions.new.paramnames)
        assert.same({ "primary", "extra" }, box.functions.make.paramnames)
        assert.same({ "delta", "spare" }, box.methods.shift.paramnames)
        local empty = assert(types.registry["namedrhfoo.Empty"])
        assert.same({}, empty.functions.new.paramnames)

        local bad = so_check({ dep }, "namedrhbar", [[
            local f = import "namedrhfoo"
            function run(): integer
                return f.choose { left = 1, unknown = 2 }
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("function 'f%.choose' has no parameter named 'unknown'",
            table.concat(bad, "\n"))
    end)

    it("rehydrates a higher-order / first-class function signature", function ()
        local dep = { name = "hofoo", src = [[
            function inc(x: integer): integer return x + 1 end
            function apply(f: function (integer): integer, x: integer): integer
                return f(x)
            end
            function adder(): function (integer): integer
                return inc  -- a function value of the rehydrated return type
            end
        ]] }
        -- the rehydrated `(integer) -> integer` parameter accepts a local fn
        local good = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function inc(x: integer): integer return x + 1 end
            function bar(): integer return f.apply(inc, 10) end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        -- a function-typed return value rehydrates and is assignable
        local good2 = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function bar(): integer
                local g: function (function (integer): integer, integer): integer = f.apply
                return g(f.adder(), 5)
            end
        ]])
        assert.equal(0, #good2, table.concat(good2, "\n"))

        -- passing a non-function where a function is expected is rejected
        local bad = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function bar(): integer return f.apply(3, 10) end
        ]])
        assert.truthy(#bad >= 1)
    end)

    it("rehydrates a record type, its fields and methods", function ()
        local dep = { name = "recfoo", src = [[
            record Point
              x: float
              y: float
            end
            function Point:move(dx: float, dy: float): Point
                self.x, self.y = self.x + dx, self.y + dy
                return self
            end
        ]] }
        local good = so_check({ dep }, "recbar", [[
            local f = import "recfoo"
            function bar(): float
                local p: f.Point = f.Point.new(1.0, 2.0)
                p:move(3.0, 4.0)
                return p.x + p.y
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        -- a wrong field type in a constructor is caught against the recovered record
        local bad = so_check({ dep }, "recbar", [[
            local f = import "recfoo"
            function bar(): f.Point
                return f.Point.new("a", "b")
            end
        ]])
        assert.truthy(#bad >= 1)
    end)

    it("rehydrates const module, record, and Interface fields", function()
        local dep = { name = "const_rh_owner", src = [[
            const answer = 42

            record Box
                const label: string
                count: integer
            end

            interface View
                label: string
                function total(): integer
            end

            function Box:total(): integer
                return self.count
            end

            function make(): Box
                return Box.new("fixed", 3)
            end

            function view(box: Box): View
                return box
            end
        ]] }

        local good = so_check({ dep }, "const_rh_consumer", [[
            local owner = import "const_rh_owner"

            function read(): integer
                local box = owner.make()
                local view = owner.view(box)
                if box.label == view.label then
                    return owner.answer + view:total()
                end
                return 0
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local record = assert(types.registry["const_rh_owner.Box"])
        assert.equal("label", record.fields[1].name)
        assert.is_true(record.fields[1].isconst)
        local interface = assert(types.registry["const_rh_owner.View"])
        assert.equal("label", interface.fields[1].name)
        assert.is_true(interface.fields[1].isconst)

        local bad = so_check({ dep }, "const_rh_consumer", [[
            local owner = import "const_rh_owner"

            function overwrite(): nil
                local box = owner.make()
                local view = owner.view(box)
                owner.answer = 0
                box.label = "changed"
                view.label = "changed"
                return nil
            end
        ]])
        assert.equal(3, #bad, table.concat(bad, "\n"))
        local message = table.concat(bad, "\n")
        assert.match("cannot assign to const module variable 'answer'", message)
        assert.match("cannot assign to const field 'label'", message)
    end)

    it("rehydrates only the public surface of records with local members", function ()
        local dep = { name = "lrecfoo", src = [[
            record Box
              local hidden: integer
              shown: integer
            end
            local function Box:secret(): integer
                return self.hidden
            end
            function Box:shown_twice(): integer
                return self.shown * 2
            end
            function make(hidden: integer, shown: integer): Box
                return Box.new(hidden, shown)
            end
            function Box.make(shown: integer): Box
                return Box.new(5, shown)
            end
            local function Box.secret_box(hidden: integer): Box
                return Box.new(hidden, 0)
            end
            function reveal(b: Box): integer
                return b.hidden + b:secret()
            end
        ]] }
        local good = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                local c = f.Box.make(13)
                return b.shown + b:shown_twice() + f.reveal(b) + c.shown
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local rec = assert(types.registry["lrecfoo.Box"])
        assert.equal(2, rec.nfields)
        assert.equal(1, #rec.fields)
        assert.equal("shown", rec.fields[1].name)
        assert.equal(1, rec.fields[1].index)
        assert.falsy(rec.functions.new)
        assert.truthy(rec.functions.make)
        assert.falsy(rec.functions.secret_box)
        assert.falsy(rec.methods.secret)
        assert.truthy(rec.methods.shown_twice)

        local hidden = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                return b.hidden
            end
        ]])
        assert.truthy(#hidden >= 1)
        assert.match("field 'hidden' not found in record 'lrecfoo%.Box'",
            table.concat(hidden, "\n"))

        local method = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                return b:secret()
            end
        ]])
        assert.truthy(#method >= 1)
        assert.match("method 'secret' not found in record 'lrecfoo%.Box'",
            table.concat(method, "\n"))

        local func = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                return f.Box.secret_box(3).shown
            end
        ]])
        assert.truthy(#func >= 1)
        assert.match("trying to access invalid record function 'secret_box'",
            table.concat(func, "\n"))

        local constructor = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): f.Box
                return { shown = 11 }
            end
        ]])
        assert.truthy(#constructor >= 1)
        assert.match("cannot construct record type 'lrecfoo%.Box' outside module 'lrecfoo' because it has local fields",
            table.concat(constructor, "\n"))
    end)

    it("rehydrates unions with hidden tag holes and transitive payload owners",
    function()
        local deps = {
            { name = "rhunionpoint", src = [[
                record Delta
                    x: float
                    y: float
                end

                function make_delta(x: float, y: float): Delta
                    return { x = x, y = y }
                end
            ]] },
            { name = "rhunionapi", src = [[
                local point = import "rhunionpoint"

                union Message
                    quit()
                    local hidden(integer)
                    move(point.Delta)
                end

                function hidden_message(): Message
                    return Message.hidden(17)
                end

                function delta(x: float, y: float): point.Delta
                    return point.make_delta(x, y)
                end
            ]] },
        }
        local good = so_check(deps, "rhunionconsumer", [[
            local api = import "rhunionapi"

            function total(): float
                local make = api.Message.move
                local message = make(api.delta(1.0, 2.0))
                case message
                when move(delta) then
                    return delta.x + delta.y
                when quit() then
                    return 0.0
                else
                    return -1.0
                end
            end

            function hidden_falls_through(): integer
                case api.hidden_message()
                when quit() then
                    return 0
                when move(delta) then
                    return 1
                else
                    return 17
                end
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local union = assert(types.registry["rhunionapi.Message"])
        assert.equal("Type.Union", union._tag)
        assert.equal(3, union.nvariants)
        assert.equal(2, #union.variants)
        assert.equal(0, union.variants.quit.index)
        assert.equal(2, union.variants.move.index)
        assert.is_nil(union.variants.hidden)
        assert.is_nil(union.functions.hidden)
        assert.same({"value"}, union.functions.move.paramnames)
        assert.equal("rhunionpoint.Delta",
            union.variants.move.parts[1].type.fqtn)
        assert.truthy(types.registry["rhunionpoint.Delta"],
            "variant payload owner should be recovered through the DSO chain")
    end)

    it("rehydrates ordered Interfaces and their transitive nominal owners",
       function()
        local deps = {
            { name = "rhinterfacemodel", src = [[
                record Point
                    x: integer
                end
            ]] },
            { name = "rhinterfaceapi", src = [[
                local model = import "rhinterfacemodel"

                interface Incrementer
                    function step(delta: integer): integer
                end

                interface Maker
                    function make(x: integer): model.Point
                end

                interface Left
                    function right(): Right
                end

                interface Right
                    function left(): Left
                end
            ]] },
            { name = "rhinterfaceprovider", src = [[
                record Box
                    n: integer
                end

                function Box:step(delta: integer): integer
                    return self.n + delta
                end
            ]] },
        }

        local good = so_check(deps, "rhinterfaceconsumer", [[
            local api = import "rhinterfaceapi"
            local provider = import "rhinterfaceprovider"

            function use_provider(): integer
                local incrementer: api.Incrementer =
                    provider.Box.new(3)
                return incrementer:step(4)
            end

            function use_transitive(maker: api.Maker): integer
                return maker:make(7).x
            end

            function use_mutual(left: api.Left): api.Left
                return left:right():left()
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local incrementer =
            assert(types.registry["rhinterfaceapi.Incrementer"])
        assert.equal("Type.Interface", incrementer._tag)
        assert.equal(1, #incrementer.methods)
        assert.is_true(
            incrementer.methods[1] == incrementer.methods.step)
        assert.same({ "delta" },
            incrementer.methods.step.paramnames)
        assert.truthy(types.registry["rhinterfacemodel.Point"],
            "the Interface signature's transitive nominal owner should " ..
            "be recovered")
        assert.truthy(types.registry["rhinterfaceapi.Left"])
        assert.truthy(types.registry["rhinterfaceapi.Right"])
    end)

    it("rehydrates a module variable's type", function ()
        local dep = { name = "varfoo", src = [[ count: integer = 0 ]] }
        local good = so_check({ dep }, "varbar", [[
            local f = import "varfoo"
            function bar(): integer
                f.count = 5
                return f.count
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "varbar", [[
            local f = import "varfoo"
            function bar(): integer
                f.count = "nope"   -- wrong type
                return f.count
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)

    it("rehydrates a record referenced transitively through an option", function ()
        -- recpoint defines Point; recwrap (a .so) returns a Point? but does not
        -- re-export it; rectop imports only recwrap. The checker must descend
        -- through the option and recover Point so the nominal type resolves.
        local good = so_check({
            { name = "recpoint", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]] },
            { name = "recwrap", src = [[
                local p = import "recpoint"
                function make(x: float, y: float): p.Point?
                    return { x = x, y = y }
                end
            ]] },
        }, "rectop", [[
            local w = import "recwrap"
            function bar(): float
                local pt = w.make(2.0, 3.0)
                pt:move(1.0, 1.0)
                return pt.x + pt.y
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
        assert.truthy(types.registry["recpoint.Point"],
            "recpoint.Point should be registered through the option type")
    end)

    it("rehydrates a record referenced only through an exported type alias", function ()
        local good = so_check({
            { name = "aliasrecord", src = [[
                record Error
                  code: integer
                end
            ]] },
            { name = "aliasfacade", src = [[
                local source = import "aliasrecord"
                type Error = source.Error
            ]] },
        }, "aliastop", [[
            local facade = import "aliasfacade"
            function code(error: facade.Error): integer
                return error.code
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
        assert.truthy(types.registry["aliasrecord.Error"],
            "aliasrecord.Error should be registered through the alias table")
    end)

    it("recovers a record referenced ONLY as a vararg element type through a .so chain", function ()
        -- vrec defines Box; vrecwrap (a .so) exports a function whose ONLY
        -- reference to Box is as the `...` element type (`...: vrec.Box`), and does
        -- not re-export Box; vrectop imports only vrecwrap. The transitive
        -- record-recovery walker must descend into the Function type's
        -- `varargtype` (not just params/rettypes) to recover Box from vrec's .so,
        -- so the `vrec.Box` nominal resolves and the variadic call type-checks.
        local good = so_check({
            { name = "vrec", src = [[
                record Box
                  v: integer
                end
            ]] },
            { name = "vrecwrap", src = [[
                local r = import "vrec"
                function take(...: r.Box): integer
                    return #...
                end
            ]] },
        }, "vrectop", [[
            local w = import "vrecwrap"
            -- vrectop does NOT import vrec directly: the `vrec.Box` nominal in
            -- `take`'s recovered signature can only resolve if the recovery walker
            -- descended into the Function's varargtype. The empty-vararg call
            -- needs no Box value yet still type-checks against the recovered type.
            function bar(): integer
                return w.take()
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
        -- The record reached solely via the vararg element type must be registered
        -- (it would be nil before the varargtype arm was added to the walker).
        assert.truthy(types.registry["vrec.Box"],
            "vrec.Box should be registered via the varargtype recovery walker")
    end)

    it("rehydrates a variadic function's varargtype through <mangled>_types", function ()
        -- The exported `sum` is `(...: integer) -> integer`; its serialized
        -- interface must carry the `varargtype` so the importer recovers the
        -- vararg element type. A correct variadic call (any count, integer
        -- elements) type-checks; passing a non-integer element is rejected against
        -- the recovered element type, and forwarding `...` from a caller whose own
        -- `...` element type is incompatible is rejected.
        local dep = { name = "vrhfoo", src = [[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
        ]] }
        local good = so_check({ dep }, "vrhbar", [[
            local f = import "vrhfoo"
            function bar(): integer return f.sum(1, 2, 3) end
            function empty(): integer return f.sum() end
            function asvalue(): integer
                local g: function (...: integer): integer = f.sum  -- recovered varargtype
                return g(4, 5)
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "vrhbar", [[
            local f = import "vrhfoo"
            function bar(): integer return f.sum(1, "x", 3) end  -- non-integer element
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)

    it("rehydrates a variadic method's varargtype through <mangled>_types", function ()
        -- A variadic METHOD's varargtype must survive serialization too; a correct
        -- method call against the recovered signature type-checks.
        local dep = { name = "vmrhfoo", src = [[
            record Acc
              base: integer
            end
            function Acc:total(...: integer): integer
                local s = self.base
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function make(b: integer): Acc return { base = b } end
        ]] }
        local good = so_check({ dep }, "vmrhbar", [[
            local f = import "vmrhfoo"
            function bar(): integer
                local a = f.make(10)
                return a:total(1, 2, 3)
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "vmrhbar", [[
            local f = import "vmrhfoo"
            function bar(): integer
                local a = f.make(10)
                return a:total(1, "x")   -- non-integer element against recovered type
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)

    it("recovers generic owners and forwarding aliases before arity checks",
    function()
        h.reset(true)

        local owner_scope = types.GenericScope(
            "generic_owner", "generic_owner.Box", false,
            "owner", "record")
        local owner_parameter = types.Parameter(
            owner_scope, 1, "T", false)
        local owner = types.Record("generic_owner.Box", {
            types.Field(
                "generic_owner.Box", "item", owner_parameter, 0, false),
        }, {
            new = types.StaticMethod("generic_owner.Box", "new",
                {owner_parameter}, {
                    types.Nominal("generic_owner.Box", {owner_parameter}),
                }, false, false, {"item"}),
        }, {}, 1, owner_scope, {types.TypeParameter("T", false)})
        local owner_module = types.Module("generic_owner", {
            types.ModuleMember("generic_owner", "Box", owner, false),
        })

        local alias = types.GenericAlias(
            "generic_facade", "Crate", false, "generic_owner.Box", false,
            owner_scope, {types.TypeParameter("T", false)})
        local choice = types.GenericAlias(
            "generic_facade", "Choice", false, "generic_owner.Box",
            "generic_facade.Crate", owner_scope,
            {types.TypeParameter("T", false)})
        local facade = types.Module("generic_facade", {
            types.ModuleMember("generic_facade", "make",
                types.Function({}, {
                    types.Nominal("generic_owner.Box", {types.Integer()}),
                }, false, false, false), {}),
        }, {Crate = alias, Choice = choice})

        local requests = {}
        local function loader(modname, request)
            requests[#requests + 1] = {
                modname, request and request.kind or false,
            }
            if modname == "generic_facade" then
                return true, facade, {}, {kind = "compiled"}
            elseif modname == "generic_owner" then
                return true, owner_module, {}, {kind = "compiled"}
            end
            return false, "unexpected module '" .. modname .. "'"
        end

        local imported, errors = checker.checkimport(
            "generic_facade", loader)
        assert.equal(facade, imported)
        assert.same({}, errors)
        assert.equal(owner, types.registry["generic_owner.Box"])
        assert.same({
            {"generic_facade", false},
            {"generic_owner", "nominal-owner"},
        }, requests)
    end)

    it("rejects recovered generic nominal and alias projection mismatches",
    function()
        h.reset(true)

        local owner_scope = types.GenericScope(
            "generic_bad_owner", "generic_bad_owner.Box", false,
            "owner", "record")
        local parameter = types.Parameter(owner_scope, 1, "T", false)
        local owner = types.Record("generic_bad_owner.Box", {
            types.Field(
                "generic_bad_owner.Box", "item", parameter, 0, false),
        }, {
            new = types.StaticMethod("generic_bad_owner.Box", "new",
                {parameter}, {
                    types.Nominal("generic_bad_owner.Box", {parameter}),
                }, false, false, {"item"}),
        }, {}, 1, owner_scope, {types.TypeParameter("T", false)})
        local owner_module = types.Module("generic_bad_owner", {
            types.ModuleMember("generic_bad_owner", "Box", owner, false),
        })

        local facade = types.Module("generic_bad_facade", {
            types.ModuleMember("generic_bad_facade", "make",
                types.Function({}, {
                    types.Nominal("generic_bad_owner.Box", {}),
                }, false, false, false), {}),
        })
        local function loader(modname)
            if modname == "generic_bad_facade" then
                return true, facade, {}, {kind = "compiled"}
            elseif modname == "generic_bad_owner" then
                return true, owner_module, {}, {kind = "compiled"}
            end
            return false, "missing"
        end
        local imported, err = checker.checkimport(
            "generic_bad_facade", loader)
        assert.falsy(imported)
        assert.match("expects 1 type arguments but found 0", err)

        h.reset(true)
        local bad_alias = types.GenericAlias(
            "generic_bad_facade", "Crate", false,
            "generic_bad_owner.Box", false,
            types.GenericScope("generic_bad_owner", "generic_bad_owner.Box",
                false, "owner", "union"),
            {types.TypeParameter("T", false)})
        facade = types.Module("generic_bad_facade", {}, {
            Crate = bad_alias,
        })
        imported, err = checker.checkimport(
            "generic_bad_facade", loader)
        assert.falsy(imported)
        assert.match("GenericAlias projection does not match owner", err)
    end)

    it("rehydrates flexible tails for functions, statics, and methods", function ()
        local dep = { name = "frhfoo", src = [[
            record Box
              n: integer
            end

            function produce(): (integer, ...: string)
                return 1, "top"
            end

            function Box.collect(): (...: integer)
                return 2, 3
            end

            function Box:items(): (...: string)
                return "method"
            end
        ]] }

        local good = so_check({ dep }, "frhbar", [[
            local f = import "frhfoo"

            function use(): integer
                local fixed: integer, tail: string? = f.produce()
                local first: integer? = f.Box.collect()
                local box = f.Box.new(4)
                local item: string? = box:items()
                if tail and first and item then
                    return fixed + first + box.n
                else
                    return 0
                end
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
        local box = assert(types.registry["frhfoo.Box"])
        assert.same(types.Integer(), box.functions.collect.flexrettype)
        assert.same(types.String(), box.methods.items.flexrettype)

        local bad = so_check({ dep }, "frhbar", [[
            local f = import "frhfoo"
            function use(): integer
                local bad: string? = f.Box.collect()
                return 0
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected string%? but found integer%?",
            table.concat(bad, "\n"))
    end)
end)
