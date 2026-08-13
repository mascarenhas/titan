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
        assert.equal("Type.GenericScope", pair._type.scope._tag)
        assert.equal("owner", pair._type.scope.role)
        assert.equal("record", pair._type.scope.declaration_kind)
        assert.equal(2, #pair._type.typeparams)
        assert.equal("T", pair._type.typeparams[1].name)
        assert.equal("U", pair._type.typeparams[2].name)
        assert.equal("Type.Parameter", pair._type.fields[1].type._tag)
        assert.equal(1, pair._type.fields[1].type.index)
        assert.equal(2, pair._type.fields[2].type.index)
        assert.is_true(types.same_generic_scope(
            pair._type.scope, pair._type.fields[1].type.scope))

        local constructor = ast[2]
        assert.truthy(constructor._record_constructor)
        assert.equal("Type.StaticMethod", constructor._type._tag)
        assert.equal("Type.Parameter", constructor._type.params[1]._tag)
        assert_nominal(constructor._type.rettypes[1], "test.Pair", {"T", "U"})

        local id = toplevel(ast, "Ast.TopLevelFunc", "id")
        assert.equal("Type.FunctionScheme", id._type._tag)
        assert.equal("function", id._type.scope.role)
        assert.equal("Type.Parameter", id._type.signature.params[1]._tag)
        assert.is_true(types.equals(id._type.signature.params[1],
            id._type.signature.rettypes[1]))
        assert.equal("Type.FunctionScheme", modtype.members.id.type._tag)

        local replace = toplevel(ast, "Ast.TopLevelMethod", "replace")
        assert.equal("Type.Method", replace._type._tag)
        assert.equal("method", replace._type.scope.role)
        assert.equal(1, #replace._type.typeparams)
        assert_nominal(replace._self._type, "test.Pair", {"T", "U"})
        assert_nominal(replace._type.rettypes[1],
            "test.Pair", {"V", "U"})

        local from = toplevel(ast, "Ast.TopLevelStatic", "from")
        assert.equal("static", from._type.scope.role)
        assert.equal(1, #from._type.typeparams)
        assert.equal("Type.Parameter", from._type.params[2]._tag)
        assert_nominal(from._type.rettypes[1],
            "test.Pair", {"V", "U"})

        local exercise = toplevel(ast, "Ast.TopLevelFunc", "exercise")
        local copy_call = exercise.block.stats[1].exps[1]
        assert_nominal(copy_call._type,
            "test.Pair", {"integer", "string"})
        assert.same({"integer", "string"}, {
            types.tostring(copy_call._generic_type_arguments[1]),
            types.tostring(copy_call._generic_type_arguments[2]),
        })
        local id_call = exercise.block.stats[2].exps[1]
        assert.equal("integer", types.tostring(id_call._type))
        assert.equal("integer",
            types.tostring(id_call._generic_type_arguments[1]))
        local static_call = exercise.block.stats[3].exps[1]
        assert_nominal(static_call._type,
            "test.Pair", {"boolean", "string"})
        assert.same({"integer", "string", "boolean"}, {
            types.tostring(static_call._generic_type_arguments[1]),
            types.tostring(static_call._generic_type_arguments[2]),
            types.tostring(static_call._generic_type_arguments[3]),
        })
        local method_call = exercise.block.stats[4].exps[1]
        assert_nominal(method_call._type,
            "test.Pair", {"boolean", "string"})
        assert.equal("boolean",
            types.tostring(method_call._generic_type_arguments[1]))
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
            "test.Maybe", {"integer"})
        local read = toplevel(ast, "Ast.TopLevelFunc", "read")
        local case = read.block.stats[1]
        assert.equal("string", types.tostring(case.arms[1].binding._type))
        assert.equal("string", types.tostring(
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
        local binder = display._type.typeparams[1]
        assert.equal("test.Show<integer>",
            types.tostring(binder.constraint))
        local rigid = display._type.signature.params[1]
        assert.equal("Type.Parameter", rigid._tag)
        assert.equal("test.Show<integer>",
            types.tostring(rigid.erased_constraint))
        local call = display.block.stats[1].exps[1]
        assert.truthy(call._rigid_receiver_type)
        assert.equal("string", types.tostring(call._type))

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
        assert.equal("Type.GenericAlias", alias._type._tag)
        assert.equal("test.Pair", alias._type.target_owner_fqtn)
        local private_alias = toplevel(
            ast, "Ast.TopLevelTypeAlias", "PrivateEither")
        assert.equal("Type.GenericAlias", private_alias._type._tag)
        assert.equal("test.Either", private_alias._type.target_alias_fqtn)
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
        assert_nominal(read._type.params[1], "test.Cell", {"value"})
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

    it("round-trips source and compiled module schemes for explicit calls",
    function()
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
                    local number: integer = library.id<integer>(1)
                    return library.Box.new<integer>(number)
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
        assert_nominal(bare._type.params[1],
            "test.Pair", {"value", "value"})
        local make = toplevel(ast, "Ast.TopLevelFunc", "make")
        assert_nominal(make.block.stats[1].exps[1]._type,
            "test.Pair", {"integer", "integer"})
        local public = toplevel(
            ast, "Ast.TopLevelTypeAlias", "Public")
        assert.equal("Type.GenericAlias", public._type._tag)
        assert.is_false(public._type.target_alias_fqtn)

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

    it("smart-reconstructs every explicit owner and callable application",
    function()
        assert_error("type of map key cannot be nil", [[
            record Dictionary<K>
                entries: {K: string}
            end
            function bad(value: Dictionary<nil>) end
        ]])

        assert_error("type of map key cannot be option type", [[
            record Dictionary<K>
                entries: {K: string}
            end
            type Dict = Dictionary
            function bad(value: Dict<integer?>) end
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

    it("diagnoses omitted type arguments until local inference lands",
    function()
        assert_error("requires an explicit complete type argument list", [[
            function id<T>(item: T): T return item end
            function use(): integer return id(1) end
        ]])
    end)

    pending("infers omitted call arguments from arguments and result context")
    pending("instantiates a generic declaration from first-class context")
end)
