local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local driver = require "titan-compiler.driver"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function assert_check(source)
    local ok, err, ast, modtype = run_checker(source)
    assert.truthy(ok, err)
    return ast, modtype
end

local function assert_error(pattern, source)
    local ok, err = run_checker(source)
    assert.falsy(ok)
    assert.match(pattern, err)
    return err
end

local function toplevel(ast, tag, name)
    for _, node in ipairs(ast) do
        if node._tag == tag and node.name == name then return node end
    end
    error(string.format("missing %s '%s'", tag, name))
end

local function declared_type(node)
    assert.truthy(node._declared_type,
        "declaration is missing its frozen surface type")
    return node._declared_type
end

local function assert_nominal(typ, fqtn, arguments)
    assert.equal("Type.Nominal", typ._tag)
    assert.equal(fqtn, typ.fqtn)
    assert.equal(#arguments, #(typ.args or {}))
    for index, expected in ipairs(arguments) do
        assert.equal(expected, types.tostring(typ.args[index]))
    end
end

describe("generic declarations and explicit calls", function()
    it("reserves owner and callable binders and builds immutable schemes",
    function()
        local ast, modtype = assert_check([[
            record Pair<T, U>
                first: T
                second: U
            end

            function id<T>(item: T): T
                return item
            end

            function Pair:replace<V>(item: V): Pair<V, U>
                return Pair.new<V, U>(item, self.second)
            end

            function Pair.from<V>(item: V, second: U): Pair<V, U>
                return Pair.new<V, U>(item, second)
            end

            function exercise(pair: Pair<integer, string>): Pair<boolean, string>
                local copy: Pair<integer, string> =
                    Pair.new<integer, string>(pair.first, pair.second)
                local number: integer = id<integer>(copy.first)
                local flags: Pair<boolean, string> =
                    Pair.from<integer, string, boolean>(true, pair.second)
                return pair:replace<boolean>(flags.first)
            end
        ]])

        local pair = toplevel(ast, "Ast.TopLevelRecord", "Pair")
        local declared_pair = declared_type(pair)
        assert.is_true(ast._declared_type == modtype)
        assert.equal(modtype.members.Pair.type.name, declared_pair.name)
        assert.not_equal(ast._type, ast._declared_type)
        assert.equal("Type.GenericScope", declared_pair.scope._tag)
        assert.equal("owner", declared_pair.scope.role)
        assert.equal("record", declared_pair.scope.declaration_kind)
        assert.equal(2, #declared_pair.typeparams)
        assert.equal("T", declared_pair.typeparams[1].name)
        assert.equal("U", declared_pair.typeparams[2].name)
        assert.equal("Type.Parameter", declared_pair.fields[1].type._tag)
        assert.equal(1, declared_pair.fields[1].type.index)
        assert.equal(2, declared_pair.fields[2].type.index)
        assert.is_true(types.same_generic_scope(
            declared_pair.scope, declared_pair.fields[1].type.scope))
        assert.not_equal(declared_pair, types.registry["test.Pair"])
        assert.is_false(pair._type.scope)
        assert.equal("value", types.tostring(pair._type.fields[1].type))

        local constructor = ast[2]
        local declared_constructor = declared_type(constructor)
        assert.truthy(constructor._record_constructor)
        assert.equal("Type.StaticMethod", declared_constructor._tag)
        assert.equal("Type.Parameter", declared_constructor.params[1]._tag)
        assert_nominal(declared_constructor.rettypes[1],
            "test.Pair", {"T", "U"})

        local id = toplevel(ast, "Ast.TopLevelFunc", "id")
        local declared_id = declared_type(id)
        assert.equal("Type.FunctionScheme", declared_id._tag)
        assert.equal("function", declared_id.scope.role)
        assert.equal("Type.Parameter", declared_id.signature.params[1]._tag)
        assert.is_true(types.equals(declared_id.signature.params[1],
            declared_id.signature.rettypes[1]))
        assert.is_true(types.same_generic_scope(declared_id.scope,
            declared_type(id.params[1]).scope))
        assert.equal("Type.FunctionScheme", modtype.members.id.type._tag)
        assert.equal("Type.Function", id._type._tag)

        local replace = toplevel(ast, "Ast.TopLevelMethod", "replace")
        local declared_replace = declared_type(replace)
        assert.equal("Type.Method", declared_replace._tag)
        assert.equal("method", declared_replace.scope.role)
        assert.equal(1, #declared_replace.typeparams)
        local declared_self = declared_type(replace._self)
        assert_nominal(declared_self, "test.Pair", {"T", "U"})
        assert.is_true(types.same_generic_scope(declared_pair.scope,
            declared_self.args[1].scope))
        assert_nominal(declared_replace.rettypes[1],
            "test.Pair", {"V", "U"})

        local from = toplevel(ast, "Ast.TopLevelStatic", "from")
        local declared_from = declared_type(from)
        assert.equal("static", declared_from.scope.role)
        assert.equal(1, #declared_from.typeparams)
        assert.equal("Type.Parameter", declared_from.params[2]._tag)
        assert_nominal(declared_from.rettypes[1],
            "test.Pair", {"V", "U"})

        local exercise = toplevel(ast, "Ast.TopLevelFunc", "exercise")
        for _, stat in ipairs(exercise.block.stats) do
            for _, exp in ipairs(stat.exps or {}) do
                if exp._type then types.assert_erased(exp._type) end
                assert.is_nil(exp._generic_type_arguments)
            end
        end
        types.assert_erased(ast._type)
        types.assert_erased(types.registry["test.Pair"])
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(ast._declared_type), "test",
            "erased-core-declared-metadata")
        assert.truthy(decoded, decode_error)
    end)

    it("substitutes generic record fields and union payloads at each use",
    function()
        local ast = assert_check([[
            record Box<T>
                item: T
            end

            union Maybe<T>
                present: T
                absent
            end

            function get(box: Box<integer>): integer
                return box.item
            end

            function make(): Maybe<integer>
                return Maybe.present<integer>(1)
            end

            function read(candidate: Maybe<string>): string
                case candidate
                when present: text then
                    return text
                when absent then
                    return ""
                end
            end
        ]])

        local get = toplevel(ast, "Ast.TopLevelFunc", "get")
        assert.equal("integer", types.tostring(
            get.block.stats[1].exps[1]._type))
        local make = toplevel(ast, "Ast.TopLevelFunc", "make")
        assert_nominal(make.block.stats[1].exps[1]._type,
            "test.Maybe", {})
        local read = toplevel(ast, "Ast.TopLevelFunc", "read")
        local case = read.block.stats[1]
        assert.equal("value", types.tostring(case.arms[1].binding._type))
        local projection = case.arms[1].block.stats[1]
        assert.equal("string", types.tostring(projection.decls[1]._type))
        assert.equal("gradual_view", projection.exps[1]._adjustment.kind)
        assert.equal("value", types.tostring(
            case._union.variants.present.payload))

        assert_error("expected test.Box<string> but found test.Box<integer>", [[
            record Box<T>
                item: T
            end
            function mismatch(box: Box<integer>): Box<string>
                local wrong: Box<string> = box
                return wrong
            end
        ]])

        assert_check([[
            record Box<T>
                item: T
            end
            function shallow(box: Box<{integer}>): Box<value>
                return box
            end
        ]])
        assert_error("expected test.Box<{ value }> but found test.Box<{ integer }>", [[
            record Box<T>
                item: T
            end
            function deep(box: Box<{integer}>): Box<{value}>
                return box
            end
        ]])
        assert_error("cannot cast 'test.Box<integer>' to 'test.Box<string>'", [[
            record Box<T>
                item: T
            end
            function bad(box: Box<integer>): Box<string>
                return box as Box<string>
            end
        ]])
    end)

    it("uses applied Interface constraints as rigid method capabilities",
    function()
        local ast = assert_check([[
            interface Show<A>
                function render(item: A): string
            end

            record IntegerShow
                prefix: string
            end

            function IntegerShow:render(item: integer): string
                return self.prefix
            end

            function display<S: Show<integer>>(subject: S): string
                return subject:render(1)
            end

            function use(show: IntegerShow): string
                return display<IntegerShow>(show)
            end
        ]])

        local display = toplevel(ast, "Ast.TopLevelFunc", "display")
        local declared_display = declared_type(display)
        local binder = declared_display.typeparams[1]
        assert.equal("test.Show<integer>",
            types.tostring(binder.constraint))
        local rigid = declared_display.signature.params[1]
        assert.equal("Type.Parameter", rigid._tag)
        assert.equal("test.Show<integer>",
            types.tostring(rigid.erased_constraint))
        assert_nominal(display._type.params[1], "test.Show", {})
        local call = display.block.stats[1].exps[1]
        assert.equal("string", types.tostring(call._type))
        assert.is_nil(call._rigid_receiver_type)

        assert_error("does not satisfy constraint 'test.Show<integer>'", [[
            interface Show<A>
                function render(item: A): string
            end
            function display<S: Show<integer>>(subject: S): string
                return subject:render(1)
            end
            function bad(): string
                return display<string>("no")
            end
        ]])
    end)

    it("alpha-matches generic Interface methods after owner substitution",
    function()
        assert_check([[
            interface Mapper<A>
                function map<B>(item: A, f: (A) -> B): B
            end

            record IntegerMapper
            end

            function IntegerMapper:map<B>(
                    item: integer, f: (integer) -> B): B
                return f(item)
            end

            function apply<M: Mapper<integer>>(
                    mapper: M): string
                return mapper:map<string>(1,
                    function(x: integer): string return "ok" end)
            end

            function use(mapper: IntegerMapper): string
                return apply<IntegerMapper>(mapper)
            end
        ]])
    end)

    it("allows only rigid transport, options, containers, equality, and casts",
    function()
        assert_check([[
            function transport<T>(item: T, dynamic: value,
                    items: {T}, values: {string: T}):
                    ({T}, T?, value, T, T, T, boolean, integer)
                local made: {T} = { item }
                local maybe: T? = item
                local boxed: value = item
                local restored: T = dynamic
                local from_array: T = items[1]
                local from_map: T = values["item"]
                local same = item == restored
                local projected = item as integer
                return made, maybe, boxed, restored, from_array, from_map,
                    same, projected
            end

            function lookup<K, V>(values: {K: V}, key: K): V
                return values[key]
            end

            function relay<T>(head: T, ...: T): (T, ...: T)
                return head, ...
            end

            function relay_integers(): (integer, ...: integer)
                return relay<integer>(1, 2, 3)
            end
        ]])

        local err = assert_error("operator '%+' is not available for rigid type parameter 'T'", [[
            function bad<T>(left: T, right: T): T
                local sum = left + right
                return left
            end
        ]])
        assert.match("rigid type parameter 'T'", err)

        assert_error("rigid type parameter 'T' cannot be used as a condition", [[
            function bad<T>(item: T)
                if item then return end
            end
        ]])

        assert_error("expected record in receiver of method call but found 'T'", [[
            function bad<T>(item: T)
                item:missing()
            end
        ]])
    end)

    it("pairs exact record and Map finalizer callbacks", function()
        assert_check([[
            function finalizable<T>(v: T, f: (T) -> ()): () end

            record Owner
                marker: integer
            end

            local function finish_owner(owner: Owner): () end
            local function finish_map(map: {string: integer}): () end

            function install(owner: Owner, map: {string: integer})
                finalizable<Owner> { v = owner, f = finish_owner }
                finalizable<{string: integer}>(map, finish_map)
            end
        ]])

        assert_error(
            "expected %(test.Owner%) %-> %(%) but found " ..
                "%(test.Other%) %-> %(%)", [[
                function finalizable<T>(v: T, f: (T) -> ()): () end

                record Owner
                    marker: integer
                end

                record Other
                    marker: integer
                end

                local function finish_other(other: Other): () end

                function install(owner: Owner)
                    finalizable<Owner>(owner, finish_other)
                end
            ]])
    end)

    it("rejects duplicate binders, owner shadowing, and incomplete lists",
    function()
        assert_error("duplicate type parameter 'T'", [[
            function bad<T, T>(item: T): T return item end
        ]])

        assert_error("cannot shadow an active owner type parameter", [[
            record Box<T>
                item: T
            end
            function Box:bad<T>(item: T): T return item end
        ]])

        assert_error("cyclic type parameter constraints involving 'T'", [[
            interface Loop<T: Loop<T>>
                function get(): T
            end
        ]])

        assert_error("does not satisfy constraint 'test.Show'", [[
            interface Show
                function render(): string
            end
            interface Outer<X: Holder<value>>
                function get(): X
            end
            interface Holder<T: Show>
                function get(): T
            end
        ]])

        assert_error("expected 1 type arguments but found 2", [[
            function id<T>(item: T): T return item end
            function bad(): integer
                return id<integer, string>(1)
            end
        ]])

        assert_error("is not generic and cannot receive type arguments", [[
            function id(item: integer): integer return item end
            function bad(): integer return id<string>(1) end
        ]])

        assert_error("has no sound transient round trip", [[
            local c = foreign import "stdint.h"
            local function id<T>(item: T): T return item end
            local function bad(pointer: *c.intptr_t): value
                return id<*c.intptr_t>(pointer)
            end
        ]])
    end)

    it("preserves generic owner applicability through bare aliases", function()
        local ast = assert_check([[
            record Pair<T, U>
                first: T
                second: U
            end
            type Either = Pair
            local type PrivateEither = Either
            function make(): Either<string, integer>
                return Either.new<string, integer>("ok", 1)
            end
            function make_private(): PrivateEither<boolean, string>
                return PrivateEither.new<boolean, string>(true, "yes")
            end
        ]])
        local alias = toplevel(ast, "Ast.TopLevelTypeAlias", "Either")
        assert.equal("Type.GenericAlias", declared_type(alias)._tag)
        assert.equal("test.Pair", declared_type(alias).target_owner_fqtn)
        local private_alias = toplevel(
            ast, "Ast.TopLevelTypeAlias", "PrivateEither")
        assert.equal("Type.GenericAlias", declared_type(private_alias)._tag)
        assert.equal("test.Either", declared_type(private_alias).target_alias_fqtn)
    end)

    it("uses the all-value application for a bare generic owner", function()
        local ast = assert_check([[
            record Cell<T>
                item: T
            end
            function read(cell: Cell): value
                return cell.item
            end
        ]])
        local read = toplevel(ast, "Ast.TopLevelFunc", "read")
        assert_nominal(declared_type(read).params[1],
            "test.Cell", {"value"})
        assert_nominal(read._type.params[1], "test.Cell", {})
        assert.equal("value", types.tostring(
            read.block.stats[1].exps[1]._type))
    end)

    it("serializes canonical generic owner and callable scopes", function()
        local _, modtype = assert_check([[
            interface Show<A>
                function map<T>(item: T): T
            end
            union Result<T>
                ok: T
                none
            end
            record Box<T>
                item: T
            end
            function Box.make<U>(item: U): U return item end
            function Box:get<V>(fallback: V): T return self.item end
            function identity<T: Show<integer>>(item: T): T return item end
            function ordinary(): integer return 1 end
        ]])
        local serialized = types.serialize(modtype)
        local decoded, decode_error = driver.decode_module_interface(
            serialized, "test", "generic-scope-test")
        assert.truthy(decoded, decode_error)
        local layout = types.public_module_prefix_layout(decoded)
        assert.equal("function:identity", layout[1].key)
        assert.equal("function:ordinary", layout[2].key)
    end)

    it("computes forward constraint carriers after every binder resolves", function()
        local _, modtype = assert_check([[
            interface J
                function render(): string
            end
            interface I<A>
                function use(item: A): string
            end
            function forward<T: I<U>, U: J>(left: T, right: U): T
                return left
            end
        ]])
        local member = modtype.members.forward.type
        assert.equal("test.I<test.J>", types.tostring(
            member.signature.params[1].erased_constraint))
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(modtype), "test", "forward-constraint-test")
        assert.truthy(decoded, decode_error)
    end)

    it("round-trips inferred source and compiled module schemes", function()
        local modules = {
            library = [[
                record Box<T>
                    item: T
                end
                function id<T>(item: T): T return item end
            ]],
            consumer = [[
                local library = import "library"
                function use(): library.Box<integer>
                    local number: integer = library.id(1)
                    local text_id: (string) -> string = library.id
                    local text: string = text_id("ok")
                    if text == "" then number = 0 end
                    return library.Box.new(number)
                end
            ]],
        }
        local ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.truthy(ok, err)
    end)

    it("applies forwarding and concrete aliases through decoded modules",
    function()
        local ast, modtype = assert_check([[
            interface Show
                function render(): string
            end
            record Rendered
            end
            function Rendered:render(): string return "ok" end

            record Pair<T, U>
                first: T
                second: U
            end
            record Box<T: Show>
                item: T
            end

            type Either = Pair
            local type Hidden = Either
            type Public = Hidden
            type IntPair = Pair<integer, integer>
            type Crate = Box

            function bare(pair: Either): value return pair.first end
            function make(): IntPair return IntPair.new(1, 2) end
            function pack(item: Rendered): Crate<Rendered>
                return Crate.new<Rendered>(item)
            end
        ]])

        local bare = toplevel(ast, "Ast.TopLevelFunc", "bare")
        assert_nominal(declared_type(bare).params[1],
            "test.Pair", {"value", "value"})
        assert_nominal(bare._type.params[1], "test.Pair", {})
        local make = toplevel(ast, "Ast.TopLevelFunc", "make")
        assert_nominal(make.block.stats[1].exps[1]._type,
            "test.Pair", {})
        local public = toplevel(
            ast, "Ast.TopLevelTypeAlias", "Public")
        assert.equal("Type.GenericAlias", declared_type(public)._tag)
        assert.is_false(declared_type(public).target_alias_fqtn)

        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(modtype), "test", "generic-alias-source")
        assert.truthy(decoded, decode_error)
        assert.equal("Type.GenericAlias",
            decoded.type_members.Public._tag)

        local modules = {
            library = [[
                interface Show
                    function render(): string
                end
                record Rendered
                end
                function Rendered:render(): string return "ok" end
                record Pair<T, U>
                    first: T
                    second: U
                end
                record Box<T: Show>
                    item: T
                end
                type Either = Pair
                type Chain = Either
                type IntPair = Pair<integer, integer>
                type Crate = Box
            ]],
            consumer = [[
                local l = import "library"
                function use(item: l.Rendered):
                        (l.Chain<string, integer>, l.IntPair,
                         l.Crate<l.Rendered>)
                    return l.Chain.new<string, integer>("ok", 1),
                        l.IntPair.new(1, 2),
                        l.Crate.new<l.Rendered>(item)
                end
            ]],
        }
        local ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.truthy(ok, err)

        modules.consumer = [[
            local l = import "library"
            function bad(x: l.IntPair<string, integer>) end
        ]]
        ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.falsy(ok)
        assert.match("not a generic type constructor", err)

        modules.consumer = [[
            local l = import "library"
            function bad(x: l.Crate<string>) end
        ]]
        ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.falsy(ok)
        assert.match("does not satisfy constraint 'library.Show'", err)
    end)

    it("defers structural constraints until every method signature exists",
    function()
        assert_check([[
            interface Show
                function render(): string
            end
            record R
            end
            record Box<T: Show>
                item: T
            end
            record Holder
                early: Box<R>
            end
            function consume(item: Box<R>): string
                return item.item:render()
            end
            function R.wrap(item: Box<R>): Box<R> return item end
            function R:copy(item: Box<R>): Box<R> return item end
            function R:render(): string return "r" end
        ]])

        assert_error("does not satisfy constraint 'test.Show'", [[
            interface Show
                function render(): string
            end
            record Missing
            end
            record Box<T: Show>
                item: T
            end
            function consume(item: Box<Missing>) end
        ]])

        assert_error("public module interface is not recoverable", [[
            interface Show
                function render(): string
            end
            record PrivateOnly
            end
            local function PrivateOnly:render(): string return "hidden" end
            record Box<T: Show>
                item: T
            end
            function exported(item: Box<PrivateOnly>) end
        ]])
    end)

    it("uses declared dependent rigid constraints rather than erased carriers",
    function()
        local _, modtype = assert_check([[
            interface J
                function j(): integer
            end
            interface I<A>
                function i(item: A): integer
            end
            record G<A, B: I<A>>
                first: A
                second: B
            end
            function inner<V: J, W: I<V>>(item: W): W return item end
            function outer<U: J, T: I<U>>(first: U, item: T): T
                local pair: G<U, T> = G.new<U, T>(first, item)
                if pair.first is value then end
                return inner<U, T>(item)
            end
            function inferred<U: J, T: I<U>>(item: T): T
                return inner(item)
            end
        ]])
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(modtype), "test", "dependent-constraint-test")
        assert.truthy(decoded, decode_error)

        assert_error("does not satisfy constraint 'test.I<test.J>'", [[
            interface J
                function j(): integer
            end
            interface I<A>
                function i(item: A): integer
            end
            function inner<W: I<J>>(item: W): W return item end
            function bad<X: J, T: I<X>>(item: T): T
                return inner<T>(item)
            end
        ]])
    end)

    it("smart-reconstructs every explicit owner and callable application",
    function()
        assert_error("type of map key cannot be nil", [[
            record Dictionary<K>
                entries: {K: string}
                count: integer
            end
            type Nil = nil
            function bad(item: Dictionary<Nil>) end
        ]])

        assert_error("type of map key cannot be option type", [[
            record Dictionary<K>
                entries: {K: string}
                count: integer
            end
            type Dict = Dictionary
            type MaybeInteger = integer?
            function bad(item: Dict<MaybeInteger>) end
        ]])

        assert_error("variadic parameter cannot have type nil", [[
            function consume<T>(...: T) end
            function bad() consume<nil>() end
        ]])

        assert_error("flexible return cannot have type nil", [[
            function produce<T>(): (...: T) end
            function bad() produce<nil>() end
        ]])
    end)

    it("infers invariant structural evidence through every Titan shape",
    function()
        local ast = assert_check([[
            record Box<T>
                item: T
            end

            function unwrap<T>(box: Box<T>): T
                return box.item
            end

            function structural<A, B, C, D>(maybe: A?, items: {B},
                    values: {string: C}, callback: (D) -> D, item: D):
                    (A?, B, C, D)
                return maybe, items[1], values["item"], callback(item)
            end

            function use(maybe: integer?, items: {string},
                    values: {string: boolean}):
                    (integer?, string, boolean, float, integer)
                local number = unwrap(Box.new(1))
                local a, b, c, d = structural(maybe, items, values,
                    function(x) return x end, 1.5)
                return a, b, c, d, number
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert.equal("integer", types.tostring(
            declared_type(use.block.stats[1].decls[1])))
        local declarations = use.block.stats[2].decls
        assert.same({"integer", "string", "boolean", "float"}, {
            types.tostring(declared_type(declarations[1])),
            types.tostring(declared_type(declarations[2])),
            types.tostring(declared_type(declarations[3])),
            types.tostring(declared_type(declarations[4])),
        })
        for _, exp in ipairs(use.block.stats[2].exps) do
            assert.is_nil(exp._generic_type_arguments)
            types.assert_erased(exp._type)
        end
    end)

    it("uses fixed, flexible, and open expected-result evidence", function()
        local ast = assert_check([[
            union Maybe<T>
                present: T
                absent
            end

            function make<T>(): T
                return nil as T
            end

            function emit<T>(): (...: T)
            end

            function use(): (string, Maybe<boolean>, ...: integer)
                return make(), Maybe.absent(), emit()
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local exps = use.block.stats[1].exps
        assert.equal("string", types.tostring(exps[1]._type))
        assert_nominal(exps[2]._type, "test.Maybe", {})
        assert.equal("integer",
            types.tostring(declared_type(use).flexrettype))
        assert.is_truthy(exps[3]._open_results)
        for _, exp in ipairs(exps) do
            assert.is_nil(exp._generic_type_arguments)
            types.assert_erased(exp._type)
        end
    end)

    it("closes later argument evidence before checking a contextual lambda",
    function()
        local ast = assert_check([[
            function fold<T, U>(items: {T}, callback: (T, U) -> U,
                    initial: U): U
                return initial
            end

            function apply<T, U>(callback: (T) -> U, item: T): U
                return callback(item)
            end

            function id<T>(item: T): T return item end

            function rigid<T>(): (T) -> T
                return id
            end

            function use(items: {integer}): (string, integer)
                local text = fold(items,
                    function(item, accumulator) return accumulator end, "")
                local number: integer = apply(id, 1)
                return text, number
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert.equal("string", types.tostring(
            declared_type(use.block.stats[1].decls[1])))
        assert.equal("integer", types.tostring(
            declared_type(use.block.stats[2].decls[1])))
        for index = 1, 2 do
            local exp = use.block.stats[index].exps[1]
            assert.is_nil(exp._generic_type_arguments)
            types.assert_erased(exp._type)
        end
    end)

    it("infers constructors, nominal functions, methods, and bound values",
    function()
        local ast = assert_check([[
            record Pair<T, U>
                first: T
                second: U
            end

            function Pair.pick<V>(left: T, right: U, item: V): V
                return item
            end

            function Pair:map<V>(callback: (T) -> V): V
                return callback(self.first)
            end

            function Pair:replace<V>(item: V): V
                return item
            end

            function use(): (boolean, string)
                local pair = Pair.new(1, "one")
                local picked = Pair.pick(1, "one", true)
                local mapped: string =
                    pair:map(function(item) return "ok" end)
                local constructor:
                    (integer, string) -> Pair<integer, string> = Pair.new
                local bound: (string) -> string = pair:replace
                local static: (integer, string, boolean) -> boolean = Pair.pick
                local made = constructor(2, "two")
                if made.first == 0 or bound("") == "never" or
                        static(1, "", false) then
                    return false, ""
                end
                return picked, mapped
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert_nominal(declared_type(use.block.stats[1].decls[1]),
            "test.Pair", {"integer", "string"})
        assert.equal("boolean", types.tostring(
            declared_type(use.block.stats[2].decls[1])))
        assert.equal("string", types.tostring(
            declared_type(use.block.stats[3].decls[1])))
        assert.equal("(integer, string) -> test.Pair<integer, string>",
            types.tostring(declared_type(use.block.stats[4].decls[1])))
        assert.equal("(string) -> string", types.tostring(
            declared_type(use.block.stats[5].decls[1])))
        assert.equal("(integer, string, boolean) -> boolean",
            types.tostring(declared_type(use.block.stats[6].decls[1])))
        assert_nominal(declared_type(use.block.stats[7].decls[1]),
            "test.Pair", {"integer", "string"})
        for index = 1, 7 do
            assert.is_nil(use.block.stats[index].exps[1]
                ._generic_type_arguments)
        end
    end)

    it("infers named, variadic, flexible, and runtime-open call evidence",
    function()
        local ast = assert_check([[
            function named<T>(left: T, right: T): T return left end

            function first<T>(...: T): T return ...[1] end

            function supply(): (integer, ...: integer)
                return 1, 2, 3
            end

            function consume<T>(...: T): T return ...[1] end

            function many<T>(item: T): (T, ...: T)
                return item, item
            end

            function use(): (string, integer, integer, ...: integer)
                local text = named { right = "b", left = "a" }
                local one = first(1, 2, 3)
                local open = consume(supply())
                return text, one, open, many(4)
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        for index = 1, 3 do
            assert.equal(index == 1 and "string" or "integer",
                types.tostring(declared_type(
                    use.block.stats[index].decls[1])))
            assert.is_nil(use.block.stats[index].exps[1]
                ._generic_type_arguments)
        end
        local many = use.block.stats[4].exps[4]
        assert.is_nil(many._generic_type_arguments)
        assert.is_truthy(many.exp._open_results)
        assert.equal("integer",
            types.tostring(declared_type(use).flexrettype))
        types.assert_erased(many._type)
    end)

    it("uses hidden generic-for input, result, and close evidence", function()
        local ast = assert_check([[
            function step<T>(state: {T}, control: integer):
                    (integer?, T?)
                return nil, nil
            end

            function close<T>(state: T)
            end

            function use(items: {string})
                for index: integer, item: string? in
                        step, items, 0, close do
                end
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local loop = use.block.stats[1]
        assert.is_nil(loop.exps[1]._generic_type_arguments)
        assert.is_nil(loop.exps[4]._generic_type_arguments)
        assert.equal("string", types.tostring(
            declared_type(loop._result_decls[2]).base))
        assert.is_truthy(loop._init_call)
        assert.is_truthy(loop._next_call)
        assert.is_truthy(loop._close_call)
        types.assert_erased(loop._init_call._type)
        types.assert_erased(loop._next_call._type)
    end)

    it("validates inferred constraints and transient eligibility", function()
        assert_check([[
            interface Show
                function show(): string
            end
            record Renderable
            end
            function Renderable:show(): string return "ok" end
            function render<T: Show>(item: T): string return item:show() end
            function use(item: Renderable): string return render(item) end
        ]])

        assert_error("does not satisfy constraint 'test.Show'", [[
            interface Show
                function show(): string
            end
            function render<T: Show>(item: T): string return item:show() end
            function bad(): string return render("no") end
        ]])

        assert_error("inferred type argument 'intptr_t %*'.-has no sound transient round trip", [[
            local c = foreign import "stdint.h"
            local function id<T>(item: T): T return item end
            local function bad(pointer: *c.intptr_t)
                local copy = id(pointer)
            end
        ]])
    end)

    it("keeps inference fresh and diagnoses conflicts and unresolved cells",
    function()
        assert_check([[
            function id<T>(item: T): T return item end
            function use(): (integer, string)
                return id(1), id("one")
            end
        ]])

        assert_error("conflicting type evidence for type parameter 'T'", [[
            function same<T>(left: T, right: T): T return left end
            function bad(): integer return same(1, "one") end
        ]])

        assert_error("cannot infer type argument 'T'.-phantom", [[
            function phantom<T>(item: integer): integer return item end
            function bad(): integer return phantom(1) end
        ]])

        assert_error("requires a monomorphic expected function type", [[
            function id<T>(item: T): T return item end
            function bad()
                local polymorphic = id
            end
        ]])
    end)
end)
