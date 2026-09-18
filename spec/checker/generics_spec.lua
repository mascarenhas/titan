local checker_core = require "titan-compiler.checker.core"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"
local driver = require "titan-compiler.driver"
local checker = require "titan-compiler.checker"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

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

local function assert_runtime_ast_erased(root)
    local seen = {}
    local source_backreference = {
        _decl = true,
        _declared_method = true,
        _declared_type = true,
        _generic_scheme = true,
        _generic_declaration = true,
        _generic_owner = true,
        _resolved_typearg = true,
    }
    local function visit(value, path)
        if type(value) ~= "table" or seen[value] then return nil end
        seen[value] = true
        if value._tag == "Type.Parameter" then return path end
        if value._generic_inference_context
           or value._generic_inference_use
           or value._generic_inference_operation_use then
            return path .. ".inference-marker"
        end
        for key, child in pairs(value) do
            if not source_backreference[key] then
                local found = visit(child, path .. "." .. tostring(key))
                if found then return found end
            end
        end
    end
    local leak = visit(root, "ast")
    assert.falsy(leak, "inference parameter leaked through " .. tostring(leak))
end

describe("generic declarations and explicit calls", function()
    it("reserves owner and callable binders and builds immutable schemes",
    function()
        local ast, modtype = assert_check([[
            record Pair<|T, U|>
                first: T
                second: U
            end

            function id<|T|>(item: T): T
                return item
            end

            function Pair:replace<|V|>(item: V): Pair<|V, U|>
                return Pair<|V, U|>.new(item, self.second)
            end

            function Pair.from<|V|>(item: V, second: U): Pair<|V, U|>
                return Pair<|V, U|>.new(item, second)
            end

            function exercise(pair: Pair<|integer, string|>): Pair<|boolean, string|>
                local copy: Pair<|integer, string|> =
                    Pair<|integer, string|>.new(pair.first, pair.second)
                local number: integer = id<|integer|>(copy.first)
                local flags: Pair<|boolean, string|> =
                    Pair<|integer, string|>.from<|boolean|>(true, pair.second)
                return pair:replace<|boolean|>(flags.first)
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
        assert.not_equal(declared_pair, ast._erased_registry["test.Pair"])
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
        types.assert_erased(ast._erased_registry["test.Pair"])
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(ast._declared_type), "test",
            "erased-core-declared-metadata")
        assert.truthy(decoded, decode_error)
    end)

    it("keeps owner applications on nominal namespaces",
    function()
        assert_error("attach them to the nominal namespace", [[
            record Box<|T|> item: T end
            function bad(): Box<|integer|> return Box.new<|integer|>(1) end
        ]])
        assert_error("expected integer but found string", [[
            record Box<|T|> item: T end
            function bad(): Box<|integer|>
                return Box<|integer|>.new("wrong")
            end
        ]])
        assert_error("concrete type alias namespace 'IntBox' cannot receive type arguments", [[
            record Box<|T|> item: T end
            type IntBox = Box<|integer|>
            function bad(): IntBox
                return IntBox<|string|>.new(1)
            end
        ]])
        assert_error("must provide both the owner and callable type argument lists", [[
            record Box<|T|> item: T end
            function Box.make<|U|>(item: U): Box<|T|>
                return Box.new(item as T)
            end
            function bad(): Box<|integer|>
                return Box<|integer|>.make("mixed")
            end
        ]])
        assert_error("can only be used in a direct call", [[
            record Box<|T|> item: T end
            function bad(): function (integer): (Box<|integer|>)
                return Box<|integer|>.new
            end
        ]])
    end)

    it("substitutes generic record fields and union payloads at each use",
    function()
        local ast = assert_check([[
            record Box<|T|>
                item: T
            end

            union Maybe<|T|>
                present(T)
                absent()
            end

            function get(box: Box<|integer|>): integer
                return box.item
            end

            function make(): Maybe<|integer|>
                return Maybe<|integer|>.present(1)
            end

            function read(candidate: Maybe<|string|>): string
                case candidate
                when present(text) then
                    return text
                when absent() then
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
        assert.equal("value", types.tostring(case.arms[1].bindings[1]._type))
        local projection = case.arms[1].block.stats[1]
        assert.equal("string", types.tostring(projection.decls[1]._type))
        assert.equal("gradual_view", projection.exps[1]._adjustment.kind)
        assert.equal("value", types.tostring(
            case._union.variants.present.parts[1].type))

        assert_error("expected test.Box<|string|> but found test.Box<|integer|>", [[
            record Box<|T|>
                item: T
            end
            function mismatch(box: Box<|integer|>): Box<|string|>
                local wrong: Box<|string|> = box
                return wrong
            end
        ]])

        assert_check([[
            record Box<|T|>
                item: T
            end
            function shallow(box: Box<|{integer}|>): Box<|value|>
                return box
            end
        ]])
        assert_error("expected test.Box<|{ value }|> but found test.Box<|{ integer }|>", [[
            record Box<|T|>
                item: T
            end
            function deep(box: Box<|{integer}|>): Box<|{value}|>
                return box
            end
        ]])
        assert_error("cannot cast 'test.Box<|integer|>' to 'test.Box<|string|>'", [[
            record Box<|T|>
                item: T
            end
            function bad(box: Box<|integer|>): Box<|string|>
                return box as Box<|string|>
            end
        ]])
    end)

    it("uses applied Interface constraints as rigid method capabilities",
    function()
        local ast = assert_check([[
            interface Show<|A|>
                function render(item: A): string
            end

            record IntegerShow
                prefix: string
            end

            function IntegerShow:render(item: integer): string
                return self.prefix
            end

            function display<|S: Show<|integer|>|>(subject: S): string
                return subject:render(1)
            end

            function use(show: IntegerShow): string
                return display<|IntegerShow|>(show)
            end
        ]])

        local display = toplevel(ast, "Ast.TopLevelFunc", "display")
        local declared_display = declared_type(display)
        local binder = declared_display.typeparams[1]
        assert.equal("test.Show<|integer|>",
            types.tostring(binder.constraint))
        local rigid = declared_display.signature.params[1]
        assert.equal("Type.Parameter", rigid._tag)
        assert.equal("test.Show<|integer|>",
            types.tostring(rigid.erased_constraint))
        assert_nominal(display._type.params[1], "test.Show", {})
        local call = display.block.stats[1].exps[1]
        assert.equal("string", types.tostring(call._type))
        assert.is_nil(call._rigid_receiver_type)

        assert_error("does not satisfy constraint 'test.Show<|integer|>'", [[
            interface Show<|A|>
                function render(item: A): string
            end
            function display<|S: Show<|integer|>|>(subject: S): string
                return subject:render(1)
            end
            function bad(): string
                return display<|string|>("no")
            end
        ]])
    end)

    it("alpha-matches generic Interface methods after owner substitution",
    function()
        assert_check([[
            interface Mapper<|A|>
                function map<|B|>(item: A, f: function (A): B): B
            end

            record IntegerMapper
            end

            function IntegerMapper:map<|B|>(
                    item: integer, f: function (integer): B): B
                return f(item)
            end

            function apply<|M: Mapper<|integer|>|>(
                    mapper: M): string
                return mapper:map<|string|>(1,
                    function(x: integer): string return "ok" end)
            end

            function use(mapper: IntegerMapper): string
                return apply<|IntegerMapper|>(mapper)
            end
        ]])
    end)

    it("allows only rigid transport, options, containers, equality, and casts",
    function()
        assert_check([[
            function transport<|T|>(item: T, dynamic: value,
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

            function lookup<|K, V|>(values: {K: V}, key: K): V
                return values[key]
            end

            function relay<|T|>(head: T, ...: T): (T, ...: T)
                return head, ...
            end

            function relay_integers(): (integer, ...: integer)
                return relay<|integer|>(1, 2, 3)
            end
        ]])

        local err = assert_error("operator '%+' is not available for rigid type parameter 'T'", [[
            function bad<|T|>(left: T, right: T): T
                local sum = left + right
                return left
            end
        ]])
        assert.match("rigid type parameter 'T'", err)

        assert_error("rigid type parameter 'T' cannot be used as a condition", [[
            function bad<|T|>(item: T)
                if item then return end
            end
        ]])

        assert_error("expected record in receiver of method call but found 'T'", [[
            function bad<|T|>(item: T)
                item:missing()
            end
        ]])
    end)

    it("pairs exact record and Map finalizer callbacks", function()
        assert_check([[
            function finalizable<|T|>(v: T, f: function (T): ()): () end

            record Owner
                marker: integer
            end

            local function finish_owner(owner: Owner): () end
            local function finish_map(map: {string: integer}): () end

            function install(owner: Owner, map: {string: integer})
                finalizable<|Owner|> { v = owner, f = finish_owner }
                finalizable<|{string: integer}|>(map, finish_map)
            end
        ]])

        assert_error(
            "expected function %(test.Owner%): %(%) but found " ..
                "function %(test.Other%): %(%)", [[
                function finalizable<|T|>(v: T, f: function (T): ()): () end

                record Owner
                    marker: integer
                end

                record Other
                    marker: integer
                end

                local function finish_other(other: Other): () end

                function install(owner: Owner)
                    finalizable<|Owner|>(owner, finish_other)
                end
            ]])
    end)

    it("rejects duplicate binders, owner shadowing, and incomplete lists",
    function()
        local errors = h.check_errs([[
            function duplicate<|T, T|>(item: T): T return item end

            record Box<|T|>
                item: T
            end
            function Box:shadow<|T|>(item: T): T return item end

            interface Loop<|T: Loop<|T|>|>
                function get(): T
            end

            interface Show
                function render(): string
            end
            interface Outer<|X: Holder<|value|>|>
                function get(): X
            end
            interface Holder<|T: Show|>
                function get(): T
            end

            function id<|T|>(item: T): T return item end
            function too_many(): integer
                return id<|integer, string|>(1)
            end

            function plain(item: integer): integer return item end
            function non_generic(): integer return plain<|string|>(1) end
        ]])
        assert.truthy(#errors >= 6)
        local joined = table.concat(errors, "\n")
        assert.match("duplicate type parameter 'T'", joined)
        assert.match("cannot shadow an active owner type parameter", joined)
        assert.match("cyclic type parameter constraints involving 'T'", joined)
        assert.match("does not satisfy constraint 'test.Show'", joined)
        assert.match("expected 1 type arguments but found 2", joined)
        assert.match("is not generic and cannot receive type arguments", joined)

        with_header("typedef long ffi_intptr;\n", function(header)
            assert_error("has no sound transient round trip", [[
            foreign import "]] .. header .. [["
            local function transient_id<|T|>(item: T): T return item end
            local function bad(pointer: foreign *ffi_intptr): value
                return transient_id<|foreign *ffi_intptr|>(pointer)
            end
            ]])
        end)
    end)

    it("preserves generic owner applicability through bare aliases", function()
        local ast = assert_check([[
            record Pair<|T, U|>
                first: T
                second: U
            end
            type Either = Pair
            local type PrivateEither = Either
            function make(): Either<|string, integer|>
                return Either<|string, integer|>.new("ok", 1)
            end
            function make_private(): PrivateEither<|boolean, string|>
                return PrivateEither<|boolean, string|>.new(true, "yes")
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
            record Cell<|T|>
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
            interface Show<|A|>
                function map<|T|>(item: T): T
            end
            union Result<|T|>
                ok(T)
                none()
            end
            record Box<|T|>
                item: T
            end
            function Box.make<|U|>(item: U): U return item end
            function Box:get<|V|>(fallback: V): T return self.item end
            function identity<|T: Show<|integer|>|>(item: T): T return item end
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
            interface I<|A|>
                function use(item: A): string
            end
            function forward<|T: I<|U|>, U: J|>(left: T, right: U): T
                return left
            end
        ]])
        local member = modtype.members.forward.type
        assert.equal("test.I<|test.J|>", types.tostring(
            member.signature.params[1].erased_constraint))
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(modtype), "test", "forward-constraint-test")
        assert.truthy(decoded, decode_error)
    end)

    it("round-trips inferred source and compiled module schemes", function()
        local modules = {
            library = [[
                record Box<|T|>
                    item: T
                end
                function id<|T|>(item: T): T return item end
            ]],
            consumer = [[
                local library = import "library"
                function use(): library.Box<|integer|>
                    local number: integer = library.id(1)
                    local text_id: function (string): string = library.id
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

            record Pair<|T, U|>
                first: T
                second: U
            end
            record Box<|T: Show|>
                item: T
            end

            type Either = Pair
            local type Hidden = Either
            type Public = Hidden
            type IntPair = Pair<|integer, integer|>
            type Crate = Box

            function bare(pair: Either): value return pair.first end
            function make(): IntPair return IntPair.new(1, 2) end
            function pack(item: Rendered): Crate<|Rendered|>
                return Crate<|Rendered|>.new(item)
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
                record Pair<|T, U|>
                    first: T
                    second: U
                end
                record Box<|T: Show|>
                    item: T
                end
                type Either = Pair
                type Chain = Either
                type IntPair = Pair<|integer, integer|>
                type Crate = Box
            ]],
            consumer = [[
                local l = import "library"
                function use(item: l.Rendered):
                        (l.Chain<|string, integer|>, l.IntPair,
                         l.Crate<|l.Rendered|>)
                    return l.Chain<|string, integer|>.new("ok", 1),
                        l.IntPair.new(1, 2),
                        l.Crate<|l.Rendered|>.new(item)
                end
            ]],
        }
        local ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.truthy(ok, err)

        modules.consumer = [[
            local l = import "library"
            function bad(x: l.IntPair<|string, integer|>) end
        ]]
        ok, err = run_checker_modules(
            modules, "consumer", { interface = "compiled" })
        assert.falsy(ok)
        assert.match("not a generic type constructor", err)

        modules.consumer = [[
            local l = import "library"
            function bad(x: l.Crate<|string|>) end
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
            record Box<|T: Show|>
                item: T
            end
            record Holder
                early: Box<|R|>
            end
            function consume(item: Box<|R|>): string
                return item.item:render()
            end
            function R.wrap(item: Box<|R|>): Box<|R|> return item end
            function R:copy(item: Box<|R|>): Box<|R|> return item end
            function R:render(): string return "r" end
        ]])

        assert_error("does not satisfy constraint 'test.Show'", [[
            interface Show
                function render(): string
            end
            record Missing
            end
            record Box<|T: Show|>
                item: T
            end
            function consume(item: Box<|Missing|>) end
        ]])

        assert_error("public module interface is not recoverable", [[
            interface Show
                function render(): string
            end
            record PrivateOnly
            end
            local function PrivateOnly:render(): string return "hidden" end
            record Box<|T: Show|>
                item: T
            end
            function exported(item: Box<|PrivateOnly|>) end
        ]])
    end)

    it("uses declared dependent rigid constraints rather than erased carriers",
    function()
        local _, modtype = assert_check([[
            interface J
                function j(): integer
            end
            interface I<|A|>
                function i(item: A): integer
            end
            record G<|A, B: I<|A|>|>
                first: A
                second: B
            end
            record R<|A: J|>
                marker: A
            end
            function R:m<|B: I<|A|>|>(item: B): B return item end
            function inner<|V: J, W: I<|V|>|>(item: W): W return item end
            function outer<|U: J, T: I<|U|>|>(first: U, item: T): (T, T, T)
                local pair: G<|U, T|> = G<|U, T|>.new(first, item)
                return pair.second, inner<|U, T|>(item), inner(item)
            end
            function nested<|X: J, T: I<|X|>|>(receiver: R<|X|>, item: T): (T, T)
                return receiver:m<|T|>(item), receiver:m(item)
            end
        ]])
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(modtype), "test", "dependent-constraint-test")
        assert.truthy(decoded, decode_error)

        assert_error("does not satisfy constraint 'test.I<|test.J|>'", [[
            interface J
                function j(): integer
            end
            interface I<|A|>
                function i(item: A): integer
            end
            function inner<|W: I<|J|>|>(item: W): W return item end
            function bad<|X: J, T: I<|X|>|>(item: T): T
                return inner<|T|>(item)
            end
        ]])

        -- The local function and public alias deliberately share the same
        -- resolved Box<PrivateRenderable> type graph. A permissive source-view
        -- visit must not memoize constraint success for the public view.
        assert_error("public module interface is not recoverable", [[
            interface Renderable
                function render(): string
            end
            record PrivateRenderable
                marker: integer
            end
            local function PrivateRenderable:render(): string return "ok" end
            record RenderedBox<|T: Renderable|>
                item: T
            end
            local function private_use(item: PublicBox) end
            type PublicBox = RenderedBox<|PrivateRenderable|>
        ]])
    end)

    it("smart-reconstructs every explicit owner and callable application",
    function()
        assert_error("type of map key cannot be nil", [[
            record Dictionary<|K|>
                entries: {K: string}
                count: integer
            end
            type Nil = nil
            function bad(item: Dictionary<|Nil|>) end
        ]])

        assert_error("type of map key cannot be option type", [[
            record Dictionary<|K|>
                entries: {K: string}
                count: integer
            end
            type Dict = Dictionary
            type MaybeInteger = integer?
            function bad(item: Dict<|MaybeInteger|>) end
        ]])

        assert_error("variadic parameter cannot have type nil", [[
            function consume<|T|>(...: T) end
            function bad() consume<|nil|>() end
        ]])

        assert_error("flexible return cannot have type nil", [[
            function produce<|T|>(): (...: T) end
            function bad() produce<|nil|>() end
        ]])
    end)

    it("binds first structural evidence through every Titan shape",
    function()
        local ast = assert_check([[
            record Box<|T|>
                item: T
            end

            function unwrap<|T|>(box: Box<|T|>): T
                return box.item
            end

            function structural<|A, B, C, D|>(maybe: A?, items: {B},
                    values: {string: C}, callback: function (D): D, item: D):
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

    it("binds each cell from its first evaluated scalar evidence",
    function()
        local ast = assert_check([[
            interface Marker function marker(): integer end
            record Mark number: integer end
            function Mark:marker(): integer return self.number end
            function marker(): Marker return Mark.new(1) end
            function mark(): Mark return Mark.new(2) end
            function same<|T|>(left: T, right: T): T return left end
            function use(v: value)
                local value_first = same(v, 42)
                local integer_first = same(42, v)
                local integer_numeric = same(1, 2.0)
                local float_numeric = same(1.0, 2)
                local contextual: integer = same(v, 42)
                local interface_first = same(marker(), mark())
            end
        ]])

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local expected = {
            "value", "integer", "integer", "float", "integer",
            "test.Marker",
        }
        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        local function coercion(exp)
            while exp and exp._tag == "Ast.ExpCast" do
                local adjustment = exp._adjustment
                if adjustment and adjustment.kind == "direct_coercion" then
                    return adjustment.coercion.op
                end
                exp = exp.exp
            end
        end
        local calls = {}
        for index, stat in ipairs(use.block.stats) do
            assert.equal(expected[index],
                types.tostring(declared_type(stat.decls[1])))
            calls[index] = peel(stat.exps[1])
        end

        assert.equal("inject",
            calls[1].args.args[2]._adjustment.op)
        assert.equal("Ast.ExpVar", calls[2].args.args[2]._tag)
        assert.equal("float_to_integer",
            coercion(calls[3].args.args[2]))
        assert.equal("integer_to_float",
            coercion(calls[4].args.args[2]))

        -- The current static precedence is deliberately isolated in
        -- infer_static_result_context: expected result selects integer before
        -- either evaluated argument.
        assert.equal("Ast.ExpVar", calls[5].args.args[1]._tag)
        assert.equal("inject", calls[5].args.args[2]._adjustment.op)
        local interface_edge = calls[6].args.args[2]
        while interface_edge._tag == "Ast.ExpCast"
              and not interface_edge._interface_conversion do
            interface_edge = interface_edge.exp
        end
        assert.equal("interface_conversion",
            interface_edge._interface_conversion.kind)
        assert_runtime_ast_erased(use.block)
    end)

    it("lets an independently typed bound method select before a later function",
    function()
        local errs = h.check_errs([[
            record Box end
            function Box:convert(item: integer): integer return item end
            function float_function(item: float): float return item end
            function same<|T|>(left: T, right: T): T return left end
            function use(box: Box)
                local got = same(box:convert, float_function)
            end
        ]])
        assert.same(1, #errs)
        assert.truthy(errs[1]:find(
            "argument 2 of call to 'same'", 1, true), errs[1])
        assert.truthy(errs[1]:find(
            "expected function (integer): integer but found function (float): float",
            1, true), errs[1])
    end)

    it("propagates constraint equations after each ordered evidence slot",
    function()
        local ast = assert_check([[
            interface Carrier<|T|>
                function get(): T
            end
            function choose<|V, W: Carrier<|V|>|>(owner: W, item: V): V
                return item
            end
            function produce<|V, W: Carrier<|V|>|>(): (W, V)
                return (nil as value) as W, (nil as value) as V
            end
            function choose_callback<|V, W: Carrier<|V|>|>(
                    callback: function (W): W, item: V): V
                return item
            end
            record MethodBox<|T|> end
            function MethodBox:convert<|X|>(item: T): T return item end
            function argument_order<|U: Carrier<|integer|>|>(owner: U): integer
                return choose(owner, 2.5)
            end
            function result_order<|U: Carrier<|integer|>|>(): (U, float)
                return produce()
            end
            function lambda_order<|U: Carrier<|integer|>|>(): integer
                return choose_callback(
                    function(item: U): U return item end, 2.5)
            end
            function method_order<|U: Carrier<|integer|>|>(
                    box: MethodBox<|U|>): integer
                return choose_callback(box:convert, 2.5)
            end
        ]])

        local function has_coercion(value, wanted, seen)
            if type(value) ~= "table" or seen[value] then return false end
            seen[value] = true
            local adjustment = value._adjustment
            if adjustment and adjustment.kind == "direct_coercion"
               and adjustment.coercion.op == wanted then
                return true
            end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner"
                   and has_coercion(child, wanted, seen) then
                    return true
                end
            end
            return false
        end
        local arguments = toplevel(ast, "Ast.TopLevelFunc", "argument_order")
        local results = toplevel(ast, "Ast.TopLevelFunc", "result_order")
        local lambda = toplevel(ast, "Ast.TopLevelFunc", "lambda_order")
        local method = toplevel(ast, "Ast.TopLevelFunc", "method_order")
        assert.is_true(has_coercion(
            arguments.block, "float_to_integer", {}))
        assert.is_true(has_coercion(
            results.block, "integer_to_float", {}))
        assert.is_true(has_coercion(
            lambda.block, "float_to_integer", {}))
        assert.is_true(has_coercion(
            method.block, "float_to_integer", {}))
        assert_runtime_ast_erased(arguments.block)
        assert_runtime_ast_erased(results.block)
        assert_runtime_ast_erased(lambda.block)
        assert_runtime_ast_erased(method.block)
    end)

    it("uses fixed, flexible, and open expected-result evidence", function()
        local ast = assert_check([[
            union Maybe<|T|>
                present(T)
                absent()
            end

            function make<|T|>(): T
                return nil as T
            end

            function emit<|T|>(): (...: T)
            end

            function use(): (string, Maybe<|boolean|>, ...: integer)
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
            function fold<|T, U|>(items: {T}, callback: function (T, U): U,
                    initial: U): U
                return initial
            end

            function apply<|T, U|>(callback: function (T): U, item: T): U
                return callback(item)
            end

            function id<|T|>(item: T): T return item end

            function rigid<|T|>(): function (T): T
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

    it("rejects generic-for annotations that conflict with inferred results",
    function()
        assert_error(
            "types in generic for variable score do not match, " ..
            "expected string but found integer%?", [[
                function next<|K, V|>(map: {K: V}, key: K?): (K?, V?)
                    return nil, nil
                end

                function pairs<|K, V|>(map: {K: V}):
                    (function ({K: V}, K?): (K?, V?), {K: V}, nil, nil)
                    return next, map, nil, nil
                end

                function bad(scores: {string: integer})
                    for _, score: string in pairs(scores) do
                    end
                end
            ]])
    end)

    it("rejects transport between distinct rigid binders", function()
        assert_error(
            "types in return do not match, expected U but found T", [[
                function bad<|T, U|>(item: T): U
                    return item
                end
            ]])
    end)

    it("rejects an argument contradicted by expected-result inference",
    function()
        assert_error(
            "types in argument 1 of call to 'id' do not match, " ..
                "expected string but found integer", [[
                    function id<|T|>(item: T): T return item end
                    function bad(): string
                        return id(42)
                    end
                ]])
    end)

    it("rejects a method argument contradicted by its applied receiver",
    function()
        assert_error(
            "types in argument 1 of call to method 'test%.Box:replace' " ..
                "do not match, expected integer but found string", [[
                    record Box<|T|>
                        item: T
                    end
                    function Box:replace(item: T)
                        self.item = item
                    end
                    function bad(box: Box<|integer|>)
                        box:replace("wrong")
                    end
                ]])
    end)

    it("rejects incompatible expected slots for one repeated result binder",
    function()
        assert_error(
            "types in return do not match, expected string but found integer", [[
                function duplicate<|T|>(item: T): (T, T)
                    return item, item
                end
                function bad(): (integer, string)
                    return duplicate(1)
                end
            ]])
    end)

    it("contextually supplies fixed nil results to generic callbacks", function()
        local ast = assert_check([[
            record Task<|A, B|>
            end

            function run<|A, B|>(callback: function (): A): Task<|A, B|>
                return (nil as value) as Task<|A, B|>
            end

            function missing(): Task<|nil, value|>
                return run<|nil, value|>(function () end)
            end

            function bare(): Task<|nil, value|>
                return run<|nil, value|>(function () return end)
            end

            function inferred(): Task<|nil, value|>
                return run(function () end)
            end

            function annotated()
                local task = run(function (): nil end)
                local _: Task<|nil, value|> = task
            end

            function no_results()
            end

            function pretyped()
                local task = run(no_results)
                local _: Task<|value, value|> = task
            end
        ]])

        for _, name in ipairs({ "missing", "bare", "inferred" }) do
            local fn = toplevel(ast, "Ast.TopLevelFunc", name)
            assert_runtime_ast_erased(fn.block)
            assert_nominal(declared_type(fn).rettypes[1],
                "test.Task", { "nil", "value" })
        end
        local annotated = toplevel(ast, "Ast.TopLevelFunc", "annotated")
        assert_runtime_ast_erased(annotated.block)
        local pretyped = toplevel(ast, "Ast.TopLevelFunc", "pretyped")
        assert_runtime_ast_erased(pretyped.block)
    end)

    it("does not infer nil from an unconstrained lambda fallthrough", function()
        assert_error(
            "function can return nil but return type is not nil", [[
                record Task<|A, B|>
                end

                function run<|A, B|>(callback: function (): A): Task<|A, B|>
                    return (nil as value) as Task<|A, B|>
                end

                function bad()
                    local _ = run(function () end)
                end
            ]])
    end)

    it("infers constructors, nominal functions, methods, and bound values",
    function()
        local ast = assert_check([[
            record Pair<|T, U|>
                first: T
                second: U
            end

            function Pair.pick<|V|>(left: T, right: U, item: V): V
                return item
            end

            function Pair:map<|V|>(callback: function (T): V): V
                return callback(self.first)
            end

            function Pair:replace<|V|>(item: V): V
                return item
            end

            function use(): (boolean, string)
                local pair = Pair.new(1, "one")
                local picked = Pair.pick(1, "one", true)
                local mapped: string =
                    pair:map(function(item) return "ok" end)
                local constructor:
                    function (integer, string): (Pair<|integer, string|>) = Pair.new
                local bound: function (string): string = pair:replace
                local static: function (integer, string, boolean): boolean = Pair.pick
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
        assert.equal("function (integer, string): test.Pair<|integer, string|>",
            types.tostring(declared_type(use.block.stats[4].decls[1])))
        assert.equal("function (string): string", types.tostring(
            declared_type(use.block.stats[5].decls[1])))
        assert.equal("function (integer, string, boolean): boolean",
            types.tostring(declared_type(use.block.stats[6].decls[1])))
        assert_nominal(declared_type(use.block.stats[7].decls[1]),
            "test.Pair", {"integer", "string"})
        for index = 1, 7 do
            assert.is_nil(use.block.stats[index].exps[1]
                ._generic_type_arguments)
        end
    end)

    it("uses an optional result context for nominal constructor inference",
    function()
        local ast = assert_check([[
            union Reason<|B|>
                simple(string)
                complex(B)
            end
            record Task<|T, E|>
            end
            function Task:cancel(reason: Reason<|E|>?) end
            function make_reason<|B|>(): Reason<|B|>? return nil end
            function identity<|B|>(): B return (nil as value) as B end
            function use(task: Task<|string, integer|>)
                task:cancel(Reason.simple("timed out"))
                local reason: Reason<|integer|> = make_reason()
                local optional: Reason<|integer|>? = identity()
            end
        ]])
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local call = use.block.stats[1].callexp
        assert.equal("test.Reason?", types.tostring(call.args.args[1]._type))

        local function inferred_result(pattern, target)
            local scope = types.GenericScope(
                "test", false, "make", "function", "function")
            local parameter = types.Parameter(scope, 1, "B", false)
            local entry = checker_core.generic_inference_scope_entry(scope, {
                types.TypeParameter("B", false),
            }, { parameter })
            local inference = checker_core.generic_new_inference_context(
                "option result", { entry }, false, {}, false)
            checker_core.generic_infer_result_evidence(inference,
                types.Function({}, { pattern(parameter) },
                    false, false, false), { fixed = { target } })
            return entry.cells[1].binding
        end
        local reason = function(parameter)
            return types.Nominal("test.Reason", { parameter })
        end
        assert.equal("integer", types.tostring(inferred_result(
            reason, types.Option(types.Nominal(
                "test.Reason", { types.Integer() })))))
        assert.equal("integer", types.tostring(inferred_result(
            function(parameter) return types.Option(reason(parameter)) end,
            types.Nominal("test.Reason", { types.Integer() }))))
        assert.equal("integer?", types.tostring(inferred_result(
            function(parameter) return parameter end,
            types.Option(types.Integer()))))
    end)

    it("infers named, variadic, flexible, and runtime-open call evidence",
    function()
        local ast = assert_check([[
            function named<|T|>(left: T, right: T): T return left end

            function first<|T|>(...: T): T return ...[1] end

            function supply(): (integer, ...: integer)
                return 1, 2, 3
            end

            function consume<|T|>(...: T): T return ...[1] end

            function many<|T|>(item: T): (T, ...: T)
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
        local result = use.block.stats[4]
        local many = result.exps[4]
        assert.is_nil(many._generic_type_arguments)
        local open = assert(many.exp._open_results)
        assert.equal("value", types.tostring(open.source_type))
        assert.equal("integer", types.tostring(open.target_type))
        assert.equal("gradual_view", open.adjustment.kind)
        assert.equal("value", types.tostring(
            result._result_adjustment.open_type))
        assert.equal("integer", types.tostring(
            result._result_adjustment.open_target))
        assert.equal("gradual_view",
            result._result_adjustment.open_adjustment.kind)
        assert.equal("integer",
            types.tostring(declared_type(use).flexrettype))
        types.assert_erased(many._type)
    end)

    it("consumes constructor components in their written order",
    function()
        local ast = assert_check([[
            record Pair<|T|>
                first: T
                second: T
            end
            function arrays<|T|>(items: {T}): {T} return items end
            function symmetric<|T|>(items: {T: T}): {T: T} return items end
            function pairs<|T|>(item: Pair<|T|>): Pair<|T|> return item end
            function whole<|T|>(item: T): T return item end
            function use()
                local ai = arrays({1, 2.0})
                local af = arrays({1.0, 2})
                local key_first = symmetric({[2.5] = 1, [3] = 4})
                local integer_key = symmetric({[1] = 2.0})
                local pi = pairs({first = 1, second = 2.0})
                local pf = pairs({second = 1.0, first = 2})
                local nested = whole({{1}, {2.5}})
                local omitted = pairs({})
            end
        ]])

        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        local function coercion(exp)
            while exp and exp._tag == "Ast.ExpCast" do
                local adjustment = exp._adjustment
                if adjustment and adjustment.kind == "direct_coercion" then
                    return adjustment.coercion.op
                end
                exp = exp.exp
            end
        end
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert.same({
            "{ integer }", "{ float }", "{ float : float }",
            "{ integer : integer }", "test.Pair<|integer|>",
            "test.Pair<|float|>", "{ { integer } }", "test.Pair<|nil|>",
        }, (function()
            local out = {}
            for index, stat in ipairs(use.block.stats) do
                out[index] = types.tostring(declared_type(stat.decls[1]))
            end
            return out
        end)())

        local constructors = {}
        for index, stat in ipairs(use.block.stats) do
            constructors[index] = peel(stat.exps[1]).args.args[1]
        end
        assert.equal("float_to_integer",
            coercion(constructors[1].fields[2].exp))
        assert.equal("integer_to_float",
            coercion(constructors[2].fields[2].exp))

        -- In a computed field, the key selects before its value; the next field
        -- again contributes key then value.
        assert.equal("integer_to_float",
            coercion(constructors[3].fields[1].exp))
        assert.equal("integer_to_float",
            coercion(constructors[3].fields[2].name))
        assert.equal("integer_to_float",
            coercion(constructors[3].fields[2].exp))
        assert.equal("float_to_integer",
            coercion(constructors[4].fields[1].exp))

        assert.equal("float_to_integer",
            coercion(constructors[5].fields[2].exp))
        assert.equal("second", constructors[6].fields[1].name)
        assert.equal("first", constructors[6].fields[2].name)
        assert.equal("integer_to_float",
            coercion(constructors[6].fields[2].exp))
        assert.equal("float_to_integer",
            coercion(peel(peel(constructors[7]).fields[2].exp).fields[1].exp))
        assert.same(2, #constructors[8].fields)
        assert.same({ "first", "second" }, {
            constructors[8].fields[1].name,
            constructors[8].fields[2].name,
        })
        assert_runtime_ast_erased(use.block)
    end)

    it("uses written named order and delivered multi-result slot order",
    function()
        local ast = assert_check([[
            function same<|T|>(left: T, right: T): T return left end
            function named<|T|>(left: T, right: T): T return left end
            function value_integer(v: value): (value, integer)
                return v, 1
            end
            function integer_value(v: value): (integer, value)
                return 1, v
            end
            function pair<|T|>(): (T, T)
                return (nil as value) as T, (nil as value) as T
            end
            function results(): (integer, float) return pair() end
            function use(v: value)
                local named_float = named { right = 1.0, left = 2 }
                local named_integer = named { right = 1, left = 2.0 }
                local result_value = same(value_integer(v))
                local result_integer = same(integer_value(v))
            end
        ]])

        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        local function coercion(exp)
            while exp and exp._tag == "Ast.ExpCast" do
                local adjustment = exp._adjustment
                if adjustment and adjustment.kind == "direct_coercion" then
                    return adjustment.coercion.op
                end
                exp = exp.exp
            end
        end

        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert.same({ "float", "integer", "value", "integer" }, {
            types.tostring(declared_type(use.block.stats[1].decls[1])),
            types.tostring(declared_type(use.block.stats[2].decls[1])),
            types.tostring(declared_type(use.block.stats[3].decls[1])),
            types.tostring(declared_type(use.block.stats[4].decls[1])),
        })
        local float_call = peel(use.block.stats[1].exps[1])
        local integer_call = peel(use.block.stats[2].exps[1])
        assert.same({ 2, 1 }, float_call._named_arg_order)
        assert.same({ 2, 1 }, integer_call._named_arg_order)
        assert.equal("integer_to_float",
            coercion(float_call.args.args[1]))
        assert.equal("float_to_integer",
            coercion(integer_call.args.args[1]))

        -- One written trailing call delivers its fixed results left-to-right.
        -- The first slot selects T; the second is an ordinary later edge.
        local value_call = peel(use.block.stats[3].exps[1])
        local integer_result_call = peel(use.block.stats[4].exps[1])
        assert.equal("inject",
            value_call.args.args[2]._adjustment.op)
        assert.equal("Ast.ExpExtra",
            integer_result_call.args.args[2]._tag)

        -- Static expected-result slots use the same left-to-right split: the
        -- first selects integer and the second receives integer-to-float.
        local results = toplevel(ast, "Ast.TopLevelFunc", "results")
        local second = results.block.stats[1].exps[2]
        assert.equal("integer_to_float", coercion(second))
        assert_runtime_ast_erased(use.block)
        assert_runtime_ast_erased(results.block)
    end)

    it("reclassifies hidden iterator operations inside generic bodies", function()
        local ast = assert_check([[
            function step<|T|>(state: {T}, control: integer): (integer?, T?)
                return nil, nil
            end
            function copy<|T|>(items: {T})
                for index, item in step, items, 0 do
                end
            end

            function next<|T|>(state: T, control: T): T?
                return nil
            end
            function close<|T|>(state: T?)
            end
            function use<|T|>(state: T)
                local finish: function (T?): () = close
                for item in next, state, state, finish do
                end
            end
        ]])

        local copy = toplevel(ast, "Ast.TopLevelFunc", "copy").block.stats[1]
        -- The second result is T? at the source boundary, but both T? and T
        -- have the value carrier. Its hidden binding must lose option_force.
        assert.equal("Type.Option", declared_type(copy._result_decls[2])._tag)
        assert.equal("Ast.ExpVar", copy._visible_stat.exps[2]._tag)
        assert.equal("value", types.tostring(copy._visible_stat.exps[2]._type))
        assert_runtime_ast_erased(copy)

        local loop = toplevel(ast, "Ast.TopLevelFunc", "use").block.stats[2]
        assert.equal("Ast.ExpVar", loop._visible_stat.exps[1]._tag)
        assert.equal("Ast.ExpVar", loop._next_call.args.args[2]._tag)
        assert.equal("Ast.ExpVar", loop._close_call.args.args[1]._tag)
        for _, call in ipairs({loop._init_call, loop._next_call, loop._close_call}) do
            for _, arg in ipairs(call.args.args) do
                assert.equal("value", types.tostring(arg._type))
            end
            types.assert_erased(call._type)
        end
        assert_runtime_ast_erased(loop)
    end)

    it("uses hidden generic-for input, result, and close evidence", function()
        local ast = assert_check([[
            function step<|T|>(state: {T}, control: integer):
                    (integer?, T?)
                return nil, nil
            end

            function close<|T|>(state: T)
            end

            function use(items: {string})
                for index: integer, item: string? in
                        step, items, 0, close do
                end
            end

            record Box<|T|> item: T end
            function make_box<|U|>(): Box<|U|>
                return Box<|U|>.new((nil as value) as U)
            end
            function step_box<|T|>(state: Box<|T|>, control: integer):
                    (integer?, Box<|T|>?)
                return nil, nil
            end
            function nested()
                for index: integer, item: Box<|integer|>? in
                        step_box, make_box(), 0 do
                end
            end

            function supply(): ({string}, integer)
                return {"item"}, 0
            end
            function multi()
                for index: integer, item: string? in step, supply() do
                end
            end
            function step_dots<|T|>(state: T, control: T): T?
                return nil
            end
            function dots(...: integer)
                for item in step_dots, ... do
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

        local nested = toplevel(ast, "Ast.TopLevelFunc", "nested").block.stats[1]
        assert.equal("test.Box<|integer|>?", types.tostring(
            declared_type(nested._result_decls[2])))
        local multi = toplevel(ast, "Ast.TopLevelFunc", "multi").block.stats[1]
        assert.equal("integer", types.tostring(
            multi._tuple_decls[3]._type))
        local function has_generic_view(value, seen)
            if type(value) ~= "table" or seen[value] then return false end
            seen[value] = true
            if value.generic_view then return true end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner"
                   and has_generic_view(child, seen) then
                    return true
                end
            end
            return false
        end
        assert.falsy(has_generic_view(nested._tuple_adjustment, {}))
        local dots = toplevel(ast, "Ast.TopLevelFunc", "dots").block.stats[1]
        assert.equal("integer?", types.tostring(
            declared_type(dots._result_decls[1])))
        assert_runtime_ast_erased(nested)
        assert_runtime_ast_erased(multi)
        assert_runtime_ast_erased(dots)
    end)

    it("validates inferred constraints and transient eligibility", function()
        assert_check([[
            interface Show
                function show(): string
            end
            record Renderable
            end
            function Renderable:show(): string return "ok" end
            function render<|T: Show|>(item: T): string return item:show() end
            function use(item: Renderable): string return render(item) end
        ]])

        with_header("typedef long ffi_intptr;\n", function(header)
            local errors = h.check_errs([[
                foreign import "]] .. header .. [["

                interface Show
                    function show(): string
                end
                local function render<|T: Show|>(item: T): string
                    return item:show()
                end
                local function bad_constraint(): string
                    return render("no")
                end

                local function id<|T|>(item: T): T return item end
                local function bad_pointer(pointer: foreign *ffi_intptr)
                    local copy = id(pointer)
                end

                local function same<|T|>(left: T, right: T): T return left end
                local function bad_ordered(pointer: foreign *ffi_intptr)
                    local got = same(pointer, 42)
                end

                local function make<|K|>(key: K): {K: string}
                    return {[key] = "x"}
                end
                local function bad_key() local got = make(nil) end

                local function consume<|T|>(...: T) end
                local function bad_variadic() consume(nil) end

                local function produce<|T|>(item: T): (...: T)
                    return item
                end
                local function bad_flexible()
                    local got = produce(nil)
                end
            ]])
            assert.same(7, #errors)
            assert.match("does not satisfy constraint 'test.Show'", errors[1])
            assert.match("has no sound transient round trip", errors[2])
            assert.match("has no sound transient round trip", errors[3])
            assert.match(
                "argument 2.-expected foreign %*.-ffi_intptr but found integer",
                errors[4])
            for index = 5, 7 do
                assert.match("cannot close", errors[index])
            end
            local joined = table.concat(errors, "\n")
            local _, transient = joined:gsub(
                "has no sound transient round trip", "")
            assert.equal(2, transient)
            local _, cannot_close = joined:gsub("cannot close", "")
            assert.equal(3, cannot_close)
        end)
    end)

    it("keeps inference fresh, ordinary-checks later mismatches, and closes free cells",
    function()
        assert_check([[
            function id<|T|>(item: T): T return item end
            function use(): (integer, string)
                return id(1), id("one")
            end
        ]])

        local mismatch_source = [[
            function same<|T|>(left: T, right: T): T return left end
            function bad(): integer return same(1, "one") end
        ]]
        local errs = h.check_errs(mismatch_source)
        assert.same(1, #errs)
        assert.match("argument 2.-expected integer but found string", errs[1])
        assert.falsy(errs[1]:find("conflicting type evidence", 1, true))
        local ok, _, mismatch_ast = run_checker(mismatch_source)
        assert.falsy(ok)
        local mismatch = toplevel(
            mismatch_ast, "Ast.TopLevelFunc", "bad").block.stats[1].exps[1]
        while mismatch._tag == "Ast.ExpCast" do mismatch = mismatch.exp end
        assert.equal("integer", types.tostring(
            mismatch._generic_type_arguments[1]))
        assert.is_nil(mismatch._generic_inference_context)
        assert.is_nil(mismatch._generic_inference_use)
        assert.is_nil(mismatch._generic_inference_operation_use)
        types.assert_erased(mismatch._type)
        types.assert_erased(mismatch._callee_type)
        for _, argument in ipairs(mismatch.args.args) do
            types.assert_erased(argument._type)
        end

        assert_check([[
            interface Container<|T|>
                function get(): T
            end
            function phantom<|T, C: Container<|T|>|>(item: integer): integer
                return item
            end
            function use(): integer return phantom(1) end
        ]])

        assert_check([[
            interface Container<|T|>
                function get(): T
            end
            record Box<|T|> item: T end
            function Box:project<|U|>(item: U): U return item end
            function id<|T|>(item: T): T return item end
            function constrained<|T, C: Container<|T|>|>(item: C): C
                return item
            end
            function take<|U|>(callback: function (U): U): value return nil end
            function take_named<|U|>(callback: function (U): U): value return nil end
            function relay<|V, W: Container<|V|>|>(item: V): integer return 1 end
            function relay_outer<|U|>(item: U): integer return relay(item) end
            function apply<|T, U|>(callback: function (T): U, item: T): U
                return callback(item)
            end
            function constrained_outer<|U, C: Container<|U|>|>(item: C): C
                return take_pair(item, id)
            end
            function take_pair<|V, W: Container<|V|>|>(
                item: W, callback: function (V): V
            ): W
                return item
            end
            function contextual(box: Box<|integer|>): integer
                return apply(box:project, 1)
            end
            function use()
                local identity = id
                local boxed_identity: value = id
                local constrained_identity = constrained
                local deferred: value = take(constrained)
                local named_deferred: value = take_named { callback = constrained }
                local constructor = Box.new
                local box: Box = constructor("seed")
                local bound = box:project
                local same: value = identity("ok")
                local projected: value = bound("ok")
            end
        ]])
    end)

    it("shares one AST-owned inference context across nested generic uses",
    function()
        assert_check([[
            interface I
                function marker(): integer
            end

            function id<|T|>(item: T): T return item end
            function constrained<|T: I|>(item: T): T return item end
            function take<|U: I|>(left: function (U): U, right: function (U): U): value
                return nil
            end

            record Box<|T|>
                item: T
            end
            function Box:integer_identity(item: T): T return item end
            function pair<|U|>(left: function (U): U, right: function (U): U): value
                return nil
            end

            union Maybe<|T|>
                none()
                some(T)
            end
            function consume<|T|>(left: T, right: T): value return nil end
            function make<|T|>(): T return (nil as value) as T end
            function pass<|T|>(item: T): T return item end

            function use(box: Box<|integer|>)
                local positional_left: value = take(id, constrained)
                local positional_right: value = take(constrained, id)
                local named_left: value =
                    take { left = id, right = constrained }
                local named_right: value =
                    take { right = constrained, left = id }
                local bound_left: value =
                    pair(id, box:integer_identity)
                local bound_right: value =
                    pair(box:integer_identity, id)

                consume(Maybe.none(), Maybe.some(42))
                consume(Maybe.some(42), Maybe.none())
                consume(make(), 42)
                consume(42, make())
                consume(pass(make()), 42)
                consume(42, pass(make()))
            end
        ]])
    end)

    it("finalizes dependent container and record constructors in source order",
    function()
        local checked = assert_check([[
            record Plain<|T|>
                item: T
            end
            record Pair<|T|>
                first: T
                second: T
            end
            record Nested<|T|>
                inner: Plain<|T|>
                item: T
            end

            function make<|T|>(): T return (nil as value) as T end
            function key<|T|>(): T return (nil as value) as T end
            function array_left<|T|>(items: {T}, item: T): integer return 0 end
            function array_right<|T|>(item: T, items: {T}): integer return 0 end
            function array_only<|T|>(items: {T}): integer return 0 end
            function map_left<|T|>(items: {string: T}, item: T): integer return 0 end
            function map_right<|T|>(item: T, items: {string: T}): integer return 0 end
            function map_only<|T|>(items: {string: T}): integer return 0 end
            function plain_left<|T|>(box: Plain<|T|>, item: T): integer return 0 end
            function plain_right<|T|>(item: T, box: Plain<|T|>): integer return 0 end
            function plain_pair<|T|>(left: Plain<|T|>, right: Plain<|T|>): integer
                return 0
            end
            function pair_only<|T|>(box: Pair<|T|>): integer return 0 end
            function nested_only<|T|>(box: Nested<|T|>): integer return 0 end

            function use_array_left(): integer
                return array_left({make()}, 42)
            end
            function use_array_right(): integer
                return array_right(42, {make()})
            end
            function use_array_internal_left(): integer
                return array_only({make(), 42})
            end
            function use_array_internal_right(): integer
                return array_only({42, make()})
            end
            function use_map_left(): integer
                return map_left({[key()] = make()}, 42)
            end
            function use_map_right(): integer
                return map_right(42, {[key()] = make()})
            end
            function use_map_internal_left(): integer
                return map_only({[key()] = make(), ["right"] = 42})
            end
            function use_map_internal_right(): integer
                return map_only({["left"] = 42, [key()] = make()})
            end
            function use_named_left(): integer
                return plain_left({item = make()}, 42)
            end
            function use_named_right(): integer
                return plain_right(42, {item = make()})
            end
            function use_named_pair(): integer
                return plain_pair({item = make()}, {item = 42})
            end
            function use_named_fields_left(): integer
                return pair_only({first = make(), second = 42})
            end
            function use_named_fields_right(): integer
                return pair_only({second = 42, first = make()})
            end
            function use_named_nested_left(): integer
                return nested_only({inner = {item = make()}, item = 42})
            end
            function use_named_nested_right(): integer
                return nested_only({item = 42, inner = {item = make()}})
            end
            function use_positional_left(): integer
                return plain_left(Plain.new(make()), 42)
            end
            function use_positional_right(): integer
                return plain_right(42, Plain.new(make()))
            end
        ]])

        -- Runtime-facing annotations must contain only closed applications.
        -- Original declaration/scheme backreferences legitimately retain their
        -- rigid declaration parameters, so do not follow those source links.
        local source_backreference = {
            _decl = true,
            _generic_scheme = true,
            _generic_declaration = true,
            _generic_owner = true,
        }
        local function find_parameter(value, path, seen)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._tag == "Type.Parameter" then return path end
            for key, child in pairs(value) do
                if not source_backreference[key] then
                    local found = find_parameter(
                        child, path .. "." .. tostring(key), seen)
                    if found then return found end
                end
            end
            return nil
        end
        for _, name in ipairs({
            "use_array_left", "use_array_right",
            "use_array_internal_left", "use_array_internal_right",
            "use_map_left", "use_map_right",
            "use_map_internal_left", "use_map_internal_right",
            "use_named_left", "use_named_right", "use_named_pair",
            "use_named_fields_left", "use_named_fields_right",
            "use_named_nested_left", "use_named_nested_right",
            "use_positional_left", "use_positional_right",
        }) do
            local func = toplevel(checked, "Ast.TopLevelFunc", name)
            local leak = find_parameter(func.block, name, {})
            assert.falsy(leak, "inference parameter leaked through " .. tostring(leak))
        end
    end)


    it("finalizes ordinary calls through inferred generic function results",
    function()
        assert_check([[
            function agree<|T|>(left: T, right: T): T return left end
            function id<|T|>(item: T): T return item end
            function make_identity<|T|>(): function (T): T
                return function(item: T): T return item end
            end

            function through_generic_function(): integer
                return agree(id(id)(41), 41)
            end
            function through_ordinary_function(): integer
                return agree(make_identity()(42), 42)
            end
        ]])
    end)

    it("finalizes ordinary methods on inferred record and Interface receivers",
    function()
        assert_check([[
            function agree<|T|>(left: T, right: T): T return left end

            interface View<|T|>
                function get(): T
                function pick<|U|>(fallback: U): T
                function replace(item: T): T
            end
            record Box<|T|>
                item: T
            end
            function Box:get(): T return self.item end
            function Box:pick<|U|>(fallback: U): T return self.item end
            function Box:replace(item: T): T return item end

            function make_box<|T|>(): Box<|T|>
                return Box<|T|>.new((nil as value) as T)
            end
            function make_view<|T|>(): View<|T|>
                return make_box<|T|>() as View<|T|>
            end

            function record_method(): integer
                return agree(make_box():get(), 42)
            end
            function generic_record_method(): integer
                return agree(make_box():pick("unused"), 42)
            end
            function interface_method(): integer
                return agree(make_view():get(), 42)
            end
            function generic_interface_method(): integer
                return agree(make_view():pick("unused"), 42)
            end
            function named_interface_method(): integer
                return agree(make_view():replace { item = 42 }, 42)
            end
        ]])
    end)

    it("refreshes finalized child projections before closing parent arguments",
    function()
        local ast = assert_check([[
            function make<|T|>(): T return (42 as value) as T end

            function duo<|T|>(): (integer, {T})
                return 1, {make()}
            end

            function spread<|T|>(): (integer, ...: {T})
                return 1, {make()}, {make()}
            end

            function consume_fixed<|T|>(first: T, second: {T}): integer
                return #second
            end

            function consume_open<|T|>(first: T, ...: {T}): integer
                local left: {T} = ...[1]
                local right: {T} = ...[2]
                return #left + #right
            end

            function fixed_projection(): integer
                return consume_fixed(duo())
            end

            function open_projection(): integer
                return consume_open(spread())
            end
        ]])

        local fixed = toplevel(ast, "Ast.TopLevelFunc", "fixed_projection")
            .block.stats[1].exps[1]
        assert.equal("Ast.ExpExtra", fixed.args.args[2]._tag)
        types.assert_erased(fixed.args.args[2]._type)

        local open = toplevel(ast, "Ast.TopLevelFunc", "open_projection")
            .block.stats[1].exps[1]
        assert.truthy(open._arg_adjustment.open_source)
        types.assert_erased(open._arg_adjustment.open_type)
    end)

    it("finalizes ambient derived projections before parent arguments",
    function()
        local ast = assert_check([[
            record Box<|T|>
                item: T
            end
            function Box:id(): T return self.item end

            record Plain
                item: integer
            end

            function make<|T|>(): Box<|T|>
                return Box<|T|>.new((nil as value) as T)
            end
            function make_array<|T|>(): {T}
                return {((nil as value) as T)}
            end
            function make_map<|K, V|>(): {K: V} return {} end
            function make_item<|T|>(): T return (nil as value) as T end
            function agree<|T|>(left: T, right: T): T return left end
            function consume<|T|>(left: T?, right: T): value return nil end
            function take<|T|>(left: function (): T, right: T): T return left() end
            function take_reversed<|T|>(left: T, right: function (): T): T
                return right()
            end

            function field_left(): integer
                return agree(make().item, 42)
            end
            function field_right(): integer
                return agree(42, make().item)
            end
            function index_left(): value
                return consume(make_array()[1], 42)
            end
            function index_right(): value
                return consume(42, make_array()[1])
            end
            function map_index_left(): value
                return consume(make_map()["item"], 42)
            end
            function map_index_right(): value
                return consume(42, make_map()["item"])
            end
            function record_left()
                local got = agree({item = make_item()}, Plain.new(42))
            end
            function record_right()
                local got = agree(Plain.new(42), {item = make_item()})
            end
            function bound_left(): integer
                return take(make():id, 42)
            end
            function bound_right(): integer
                return take_reversed(42, make():id)
            end
            function parenthesized(): integer
                return agree((make_item()), 42)
            end
        ]])

        for _, name in ipairs({
            "field_left", "field_right", "index_left", "index_right",
            "map_index_left", "map_index_right", "record_left", "record_right",
            "bound_left", "bound_right",
            "parenthesized",
        }) do
            assert_runtime_ast_erased(
                toplevel(ast, "Ast.TopLevelFunc", name).block)
        end
    end)

    it("closes direct computed calls and option-backed record owners",
    function()
        local ast = assert_check([[
            record FnBox<|T|>
                callback: function (): T
            end
            record Box<|T|>
                item: T
            end
            function Box:get(): T return self.item end
            record Holder<|T|>
                box: Box<|T|>
            end
            record Plain
                item: integer
            end

            function make<|T|>(): FnBox<|T|>
                return FnBox<|T|>.new(function(): T
                    return (42 as value) as T
                end)
            end
            function make_callbacks<|T|>(): {function (): T}
                return {function(): T return (42 as value) as T end}
            end
            function make_boxes<|T|>(): {Box<|T|>}
                return {Box<|T|>.new((42 as value) as T)}
            end
            function make_holder<|T|>(): Holder<|T|>
                return Holder<|T|>.new(Box<|T|>.new((42 as value) as T))
            end
            function maybe(): Plain? return Plain.new(42) end
            function agree<|T|>(left: T, right: T): T return left end

            function direct_field(): integer
                return agree(make().callback(), 42)
            end
            function direct_bracket(): integer
                return agree(make_callbacks()[1](), 42)
            end
            function direct_method_receiver(): integer
                return agree(make_holder().box:get(), 42)
            end
            function direct_bracket_method(): integer
                return agree(make_boxes()[1]:get(), 42)
            end
            function option_record()
                local got = agree({item = 42}, maybe())
            end
        ]])

        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        for _, name in ipairs({ "direct_field", "direct_bracket" }) do
            local outer = peel(toplevel(ast, "Ast.TopLevelFunc", name)
                .block.stats[1].exps[1])
            local inner = peel(outer.args.args[1])
            assert.equal("Ast.ExpCall", inner._tag)
            assert.same(types.Integer(), inner._type)
            assert.same(types.Function({}, { types.Integer() },
                false, false, false), inner._callee_type)
        end

        local seen = {}
        local function find_constructor(value)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._tag == "Ast.ExpInitList" then return value end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner" then
                    local found = find_constructor(child)
                    if found then return found end
                end
            end
        end
        local constructor = assert(find_constructor(
            toplevel(ast, "Ast.TopLevelFunc", "option_record").block))
        assert_nominal(constructor._type, "test.Plain", {})

        for _, name in ipairs({
            "direct_field", "direct_bracket", "direct_method_receiver",
            "direct_bracket_method", "option_record",
        }) do
            assert_runtime_ast_erased(
                toplevel(ast, "Ast.TopLevelFunc", name).block)
        end
    end)

    it("settles nested constructor and generic-value defaults inside-out",
    function()
        local ast = assert_check([[
            function id<|T|>(item: T): T return item end
            record Receiver end
            function Receiver:method<|T|>(item: T): T return item end
            function use(receiver: Receiver)
                local nested_empty = id({{}})
                local generic_value = id({id})
                local generic_method = id({receiver:method})
                local computed_key = id({[id] = 1})
                local computed_value = id({[1] = id})
                local empty_key = id({[{}] = 1})
                local empty_value = id({[1] = {}})
                local nested_computed = id({{[id] = 1}})
            end
        ]])
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local got = {}
        for index, stat in ipairs(use.block.stats) do
            got[index] = types.tostring(declared_type(stat.decls[1]))
        end
        assert.same({
            "{ { integer } }",
            "{ function (value): value }",
            "{ function (value): value }",
            "{ function (value): value : integer }",
            "{ integer : function (value): value }",
            "{ { integer } : integer }",
            "{ integer : { integer } }",
            "{ { function (value): value : integer } }",
        }, got)
        assert_runtime_ast_erased(use.block)

        local errs = h.check_errs([[
            function id<|T|>(item: T): T return item end
            function bad()
                local got = id({function(item) return item end})
            end
        ]])
        assert.same(1, #errs)
        assert.match("cannot infer type of parameter 'item'", errs[1])

        local computed_errors = h.check_errs([[
            record Box end
            function id<|T|>(item: T): T return item end
            function bad(box: Box)
                local got = id({{[box.missing] = 1}})
            end
        ]])
        assert.same(1, #computed_errors)
        assert.match("field 'missing' not found", computed_errors[1])
    end)

    it("preserves a deferred contextual call's complete open constructor run",
    function()
        local direct_open = 0
        local original = checker_core.generic_check_direct_positional_constructor
        checker_core.generic_check_direct_positional_constructor = function(node, ...)
            if node.fields[1]
               and node.fields[1].exp._tag == "Ast.ExpCall" then
                direct_open = direct_open + 1
            end
            return original(node, ...)
        end
        local result = table.pack(pcall(assert_check, [[
            function agree<|T|>(left: T, right: T): T return left end
            function strings(): {string} return {"witness"} end
            record CallbackBox
                callback: value
                callbacks: {value}
            end
            function callbacks(): {{function (integer): integer}}
                return {{function(x: integer): integer return x end}}
            end
            function use(callback: value): {string}
                local inferred = agree({callback()}, strings())
                return inferred
            end
            function field(box: CallbackBox): {string}
                local inferred = agree({box.callback()}, strings())
                return inferred
            end
            function indexed(box: CallbackBox): {string}
                local inferred = agree({box.callbacks[1]()}, strings())
                return inferred
            end
            function nested(): {{function (integer): integer}}
                return agree({{function(x) return x end}}, callbacks())
            end
        ]]))
        checker_core.generic_check_direct_positional_constructor = original
        assert.truthy(result[1], result[2])
        local ast = result[2]
        assert.equal(3, direct_open)
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        local seen = {}
        local contextual
        local function visit(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            if value._tag == "Ast.ExpCall"
               and value._contextual_value_call then
                contextual = value
            end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner" then
                    visit(child)
                end
            end
        end
        visit(use.block)
        assert.truthy(contextual)
        assert.truthy(contextual._open_results)
        assert.equal("string", types.tostring(
            contextual._open_results.source_type))
        assert_runtime_ast_erased(use.block)
        assert_runtime_ast_erased(
            toplevel(ast, "Ast.TopLevelFunc", "field").block)
        assert_runtime_ast_erased(
            toplevel(ast, "Ast.TopLevelFunc", "indexed").block)
        assert_runtime_ast_erased(
            toplevel(ast, "Ast.TopLevelFunc", "nested").block)
    end)

    it("defers only context-only constructor work and closes it exactly once",
    function()
        local source = [[
            function agree<|T|>(left: T, right: T): T return left end
            function make<|U|>(): U return (nil as value) as U end
            function integers(): {integer: string} return {[1] = "one"} end
            function typed(item: integer): value return item end
            function identity<|T|>(item: T): T return item end
            record CallbackBox callback: function (integer): integer end
            function callback_box(): CallbackBox
                return CallbackBox.new(
                    function(x: integer): integer return x + 1 end)
            end
            type Callback = function (integer): integer
            function callback_map(): {Callback: integer}
                return {[function(x: integer): integer return x end] = 1}
            end
            function left<|T|>(items: {T}, witness: T) end
            function right<|T|>(witness: T, items: {T}) end
            function use()
                local empty_left = agree({}, integers())
                local empty_right = agree(integers(), {})
                local contextual = agree({make()}, integers())
                local named_contextual = agree({callback = function(item)
                    return item + 2
                end}, callback_box())
                local named_generic = agree({callback = identity},
                    callback_box())
                local computed_contextual = agree({[function(item)
                    return item
                end] = 1}, callback_map())
                left({function(item): integer return item end}, typed)
                right(typed, {function(item): integer return item end})
            end
        ]]
        local operation_counts = {}
        local original = checker_core.generic_with_inference_operation
        checker_core.generic_with_inference_operation = function(node, ...)
            operation_counts[node] = (operation_counts[node] or 0) + 1
            return original(node, ...)
        end
        local result = table.pack(pcall(assert_check, source))
        checker_core.generic_with_inference_operation = original
        assert.truthy(result[1], result[2])
        local ast = result[2]
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        for index = 1, 3 do
            assert.equal("{ integer : string }", types.tostring(
                declared_type(use.block.stats[index].decls[1])))
        end
        for index = 4, 5 do
            assert_nominal(declared_type(use.block.stats[index].decls[1]),
                "test.CallbackBox", {})
        end
        assert.equal("{ function (integer): integer : integer }", types.tostring(
            declared_type(use.block.stats[6].decls[1])))
        for node, count in pairs(operation_counts) do
            assert.equal(1, count,
                "redispatched " .. tostring(node._tag) .. " operation")
        end

        local function callable_adjustment(value, seen)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._adjustment
               and value._adjustment.kind == "callable" then
                return value
            end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner" then
                    local found = callable_adjustment(child, seen)
                    if found then return found end
                end
            end
        end
        for index = 7, 8 do
            local adjusted = callable_adjustment(use.block.stats[index], {})
            assert.truthy(adjusted)
            assert.truthy(adjusted._callable_adapter)
        end
        assert_runtime_ast_erased(use.block)

        local errs = h.check_errs([[
            function typed(item: integer): value return item end
            function left<|T|>(items: {T}, witness: T) end
            function right<|T|>(witness: T, items: {T}) end
            function bad()
                left({function(item): integer
                    local number: integer = "bad"
                    return item
                end}, typed)
                right(typed, {function(item): integer
                    local number: integer = "bad"
                    return item
                end})
            end
        ]])
        assert.same(2, #errs)
        for _, err in ipairs(errs) do
            assert.match("expected integer but found string", err)
            assert.falsy(err:find("conflicting type evidence", 1, true))
        end

        local recovery_ok, recovery_error, recovery_ast = run_checker([[
            record Plain item: integer end
            function plain(): Plain return Plain.new(1) end
            function make<|U|>(): U return (nil as value) as U end
            function agree<|T|>(left: T, right: T): T return left end
            function bad() local got = agree({make()}, plain()) end
        ]])
        assert.falsy(recovery_ok)
        assert.match("missing field in initializer", recovery_error)
        assert.match("field 'item'.-cannot be omitted", recovery_error)
        local recovery = toplevel(
            recovery_ast, "Ast.TopLevelFunc", "bad").block.stats[1].exps[1]
        while recovery._tag == "Ast.ExpCast" do recovery = recovery.exp end
        local constructor = recovery.args.args[1]
        assert.equal("Ast.ExpInitList", constructor._tag)
        assert_nominal(constructor._type, "test.Plain", {})
        assert.is_nil(constructor._generic_inference_context)
        assert.is_nil(constructor._generic_inference_use)
        assert.is_nil(constructor._generic_inference_operation_use)
        for _, field in ipairs(constructor.fields) do
            types.assert_erased(field.exp._type)
        end

        local invalid_errors = h.check_errs([[
            record Box item: integer end
            function id<|T|>(item: T): T return item end
            function bad(box: Box) local got = id({box.missing}) end
        ]])
        assert.same(1, #invalid_errors)
        assert.match("field 'missing' not found", invalid_errors[1])
        assert.falsy(invalid_errors[1]:find("array initializer", 1, true))

        local ownerless_errors = h.check_errs([[
            function id<|T|>(item: T): T return item end
            function bad() local got = id({item = 1}) end
        ]])
        assert.same(1, #ownerless_errors)
        assert.match("no context to provide type for record constructor",
            ownerless_errors[1])
    end)

    it("checks positional and named computed arguments exactly once",
    function()
        local cases = {
            {
                name = "positional",
                call = [[agree(make()["bad"], 42)]],
            },
            {
                name = "named",
                call = [[agree { a = make()["bad"], b = 42 }]],
            },
        }
        for _, case in ipairs(cases) do
            local source = ([=[
                function make<|T|>(): {T} return {} end
                function agree<|T|>(a: T?, b: T): T return b end
                function use(): integer return %s end
            ]=]):format(case.call)
            local operation_counts = {}
            local original = checker_core.generic_with_inference_operation
            checker_core.generic_with_inference_operation = function(node, ...)
                operation_counts[node] = (operation_counts[node] or 0) + 1
                return original(node, ...)
            end
            local result = table.pack(pcall(run_checker, source))
            checker_core.generic_with_inference_operation = original
            assert.truthy(result[1], result[2])

            local ok, err, ast = table.unpack(result, 2, result.n)
            assert.falsy(ok, case.name)
            local _, mismatches = err:gsub(
                "types in array indexing do not match", "")
            assert.equal(1, mismatches, case.name .. ": " .. err)
            assert.falsy(err:find("\n", 1, true),
                case.name .. " produced an extra diagnostic: " .. err)

            local use = toplevel(ast, "Ast.TopLevelFunc", "use")
            local call = use.block.stats[1].exps[1]
            local computed = call.args.args[1]
            assert.equal("Ast.ExpVar", computed._tag)
            assert.equal("Ast.VarBracket", computed.var._tag)
            assert.equal(1, operation_counts[computed.var], case.name)
            assert.equal(1, operation_counts[computed.var.exp1], case.name)
            types.assert_erased(computed._type)
            types.assert_erased(computed.var._type)
            types.assert_erased(computed.var.exp1._type)
            assert.is_nil(computed._generic_inference_operation_use)
            assert.is_nil(computed.var.exp1._generic_inference_operation_use)
        end
    end)

    it("preserves computed argument context after generic eligibility probes",
    function()
        local operation_counts = {}
        local original = checker_core.generic_with_inference_operation
        checker_core.generic_with_inference_operation = function(node, ...)
            operation_counts[node] = (operation_counts[node] or 0) + 1
            return original(node, ...)
        end
        local result = table.pack(pcall(assert_check, [[
            record Holder
                callback: function (integer): integer
            end
            function holders(): {Holder} return {} end
            function callbacks(): {function (integer): integer} return {} end
            function apply<|T|>(callback: function (T): T, item: T): T
                return callback(item)
            end

            function use(): integer
                local a = apply(holders()[1].callback, 1)
                local b = apply(callbacks()[1], a)
                local c = apply {
                    callback = holders()[1].callback,
                    item = b,
                }
                local d = apply {
                    callback = callbacks()[1],
                    item = c,
                }
                return d
            end
        ]]))
        checker_core.generic_with_inference_operation = original
        assert.truthy(result[1], result[2])
        local ast = result[2]
        for node, count in pairs(operation_counts) do
            assert.equal(1, count,
                "redispatched " .. tostring(node._tag) .. " operation")
        end
        assert_runtime_ast_erased(
            toplevel(ast, "Ast.TopLevelFunc", "use").block)
    end)

    it("preserves C function references after generic eligibility probes",
    function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write([[
            typedef int ffi_int;
            typedef enum ffi_wide {
                FFI_WIDE = 18446744073709551615ULL
            } ffi_wide;
            typedef ffi_wide (*ffi_callback)(ffi_wide);
            static ffi_wide ffi_identity(ffi_wide value) { return value; }
            static ffi_int ffi_add1(ffi_int value) { return value + 1; }
        ]]))
        file:close()

        local result = table.pack(pcall(assert_check, ([=[
            foreign import "%s"
            local function keep<|T|>(callback: foreign ffi_callback, item: T): T
                return item
            end
            function contextual(): integer return keep(ffi.ffi_identity, 42) end
            function contextual_named(): integer
                return keep { callback = ffi.ffi_identity, item = 42 }
            end
            function direct(): integer return ffi.ffi_add1(41) as integer end
        ]=]):format(header)))
        os.remove(header)
        assert.truthy(result[1], result[2])
    end)

    it("defers option-backed contextual record initializers in either placement",
    function()
        local ast = assert_check([[
            record Plain
                item: integer
            end
            function maybe(): Plain? return Plain.new(42) end
            function agree<|T|>(left: T, right: T): T return left end

            function inferred_left(): integer
                local got = agree({item = 42}, maybe())
                return got.item
            end
            function inferred_right(): integer
                local got = agree(maybe(), {item = 42})
                return got.item
            end
            function result_left(): Plain?
                return agree({item = 42}, maybe())
            end
            function result_right(): Plain?
                return agree(maybe(), {item = 42})
            end
        ]])

        local function find_wrapped_constructor(value, seen)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._tag == "Ast.ExpCast" and value.exp
               and value.exp._tag == "Ast.ExpInitList" then
                return value.exp, value
            end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner" then
                    local constructor, wrapper =
                        find_wrapped_constructor(child, seen)
                    if constructor then return constructor, wrapper end
                end
            end
        end

        for _, name in ipairs({
            "inferred_left", "inferred_right",
            "result_left", "result_right",
        }) do
            local block = toplevel(ast, "Ast.TopLevelFunc", name).block
            local constructor, wrapper =
                find_wrapped_constructor(block, {})
            assert.truthy(constructor, name)
            assert_nominal(constructor._type, "test.Plain", {})
            assert.equal("Type.Option", wrapper._type._tag)
            assert_nominal(wrapper._type.base, "test.Plain", {})
            assert.equal("option_wrap", wrapper._adjustment.coercion.op)
            assert_runtime_ast_erased(block)
        end
    end)

    it("ordinary-adjusts later Option evidence in the selected direction",
    function()
        local ast = assert_check([[
            record Plain item: integer end
            function maybe(present: boolean): Plain?
                if present then return Plain.new(42) end
                return nil
            end
            function same<|T|>(left: T, right: T): T return left end
            function use()
                local opt? = same(maybe(true), Plain.new(42))
                local base = same(Plain.new(42), maybe(true))
            end
        ]])
        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        local function coercion(exp)
            while exp and exp._tag == "Ast.ExpCast" do
                local adjustment = exp._adjustment
                if adjustment and adjustment.kind == "direct_coercion" then
                    return adjustment.coercion.op
                end
                exp = exp.exp
            end
        end
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        assert.equal("test.Plain?", types.tostring(
            declared_type(use.block.stats[1].decls[1])))
        assert.equal("test.Plain", types.tostring(
            declared_type(use.block.stats[2].decls[1])))
        assert.equal("option_wrap", coercion(
            peel(use.block.stats[1].exps[1]).args.args[2]))
        assert.equal("option_force", coercion(
            peel(use.block.stats[2].exps[1]).args.args[2]))
        assert_runtime_ast_erased(use.block)
    end)

    it("infers structured argument components through an outer Option", function()
        local ast = assert_check([[
            record Box<|T|> item: T end
            function map<|K,V|>(items: {K:V}): integer return 0 end
            function array<|T|>(items: {T}): integer return 0 end
            function box<|T|>(item: Box<|T|>): integer return 0 end
            function callable<|T|>(f: function (T): T): integer return 0 end
            function optional<|T|>(items: {T}?): integer return 0 end
            function variadic<|T|>(...: {T}): integer return 0 end
            function use<|T|>(m: {string: T}?, a: {T}?,
                            b: Box<|T|>?, f: (function (T): T)?, raw: {T}, runs: {{T}})
                map(m)
                map { items = m }
                array(a)
                box(b)
                callable(f)
                optional(raw)
                variadic(a)
                array(...runs)
            end
        ]])
        assert_runtime_ast_erased(
            toplevel(ast, "Ast.TopLevelFunc", "use").block)
    end)

    it("preserves optional Array constructor context through generic erasure",
    function()
        local ast = assert_check([[
            function first<|T|>(items: {T}?): T?
                if items == nil then return nil end
                local present: {T} = items
                return present[1]
            end
            function ordinary(items: {integer}?): integer?
                if items == nil then return nil end
                local present: {integer} = items
                return present[1]
            end
            function use(typed: {integer}, optional: {integer}?)
                local inferred? = first({1})
                local explicit? = first<|integer|>({2})
                local from_typed? = first(typed)
                local from_optional? = first(optional)
                local empty? = first({})
                local explicit_empty? = first<|integer|>({})
                local absent? = first<|integer|>(nil)
                local default_absent? = first(nil)
                local ordinary_literal? = ordinary({3})
                local ordinary_empty? = ordinary({})
                local ordinary_absent? = ordinary(nil)
            end
        ]])
        local use = toplevel(ast, "Ast.TopLevelFunc", "use")
        for index, statement in ipairs(use.block.stats) do
            local selected = declared_type(statement.decls[1])
            assert.equal((index == 5 or index == 8) and "value" or "integer?",
                types.tostring(selected), statement.decls[1].name)
        end
        assert_runtime_ast_erased(use.block)
    end)

    it("diagnoses incompatible optional Array elements without lifting conversions",
    function()
        local errs = h.check_errs([[
            function first<|T|>(items: {T}?): integer return 0 end
            function ordinary(items: {integer}?): integer return 0 end
            function bad(strings: {string}, numbers: {float}?)
                first<|integer|>({"wrong"})
                ordinary({"wrong"})
                first<|integer|>(strings)
                first<|integer|>(numbers)
            end
        ]])
        assert.equal(4, #errs)
        for _, err in ipairs(errs) do
            assert.truthy(err:find("integer", 1, true), err)
        end
        assert.truthy(errs[3]:find(
            "argument 1 of call to function 'first'", 1, true), errs[3])
        assert.truthy(errs[4]:find(
            "argument 1 of call to function 'first'", 1, true), errs[4])
    end)

    it("keeps complete optional evidence for a direct generic binder", function()
        local ast = assert_check([[
            function identity<|T|>(item: T): T return item end
            function use(item: {string: integer}?)
                local selected? = identity(item)
            end
        ]])
        local selected = toplevel(ast, "Ast.TopLevelFunc", "use")
            .block.stats[1].decls[1]
        assert.equal("{ string : integer }?",
            types.tostring(declared_type(selected)))
    end)

    it("keeps nested shapes and later optional argument evidence invariant", function()
        local errs = h.check_errs([[
            record Box<|T|> item: T end
            function nested<|T|>(item: Box<|{string: T}|>): integer return 0 end
            function pair<|T|>(left: {string:T}, right: {string:T}): integer
                return 0
            end
            function bad_nested(item: Box<|{string: integer}?|>): integer
                return nested(item)
            end
            function bad_later(left: {string: integer}?,
                               right: {string: float}?): integer
                return pair(left, right)
            end
        ]])
        assert.equal(2, #errs)
        assert.truthy(errs[1]:find("argument 1 of call to 'nested'", 1, true))
        assert.truthy(errs[2]:find(
            "expected { string : integer } but found { string : float }?", 1, true))
    end)

    it("preserves invariance for independently built generic containers",
    function()
        local errs = h.check_errs([[
            record Box<|T|> item: T end
            function ia(): {integer} return {1} end
            function fa(): {float} return {1.0} end
            function im(): {string: integer} return {["x"] = 1} end
            function fm(): {string: float} return {["x"] = 1.0} end
            function ib(): Box<|integer|> return Box<|integer|>.new(1) end
            function fb(): Box<|float|> return Box<|float|>.new(1.0) end
            function array_pair<|T|>(left: {T}, right: {T}) end
            function map_pair<|T|>(left: {string: T}, right: {string: T}) end
            function box_pair<|T|>(left: Box<|T|>, right: Box<|T|>) end
            function bad()
                array_pair(ia(), fa()); array_pair(fa(), ia())
                map_pair(im(), fm()); map_pair(fm(), im())
                box_pair(ib(), fb()); box_pair(fb(), ib())
            end
        ]])
        assert.same(6, #errs)
        local directions = {
            { "{ integer }", "{ float }" },
            { "{ float }", "{ integer }" },
            { "{ string : integer }", "{ string : float }" },
            { "{ string : float }", "{ string : integer }" },
            { "test.Box<|integer|>", "test.Box<|float|>" },
            { "test.Box<|float|>", "test.Box<|integer|>" },
        }
        for index, direction in ipairs(directions) do
            assert.truthy(errs[index]:find(
                "expected " .. direction[1] .. " but found " .. direction[2],
                1, true), errs[index])
            assert.falsy(errs[index]:find(
                "conflicting type evidence", 1, true))
        end
    end)

    it("reports complete record diagnostics in deferred and closed paths",
    function()
        local prelude = table.concat({
            "record Plain",
            "    item: integer",
            "end",
            "function maybe(): Plain? return Plain.new(42) end",
            "function agree<|T|>(left: T, right: T): T return left end",
            "function accept(item: Plain): Plain return item end",
        }, "\n")
        local function source(expression)
            return prelude .. "\nfunction bad()\n    local got = "
                .. expression .. "\nend"
        end
        local cases = {
            {
                name = "deferred left",
                expression = "agree({missing = 42}, maybe())",
                errors = {
                    "(spec):8:24: type error: field 'missing' not found in record type 'test.Plain'",
                    "(spec):8:23: type error: field 'item' of record 'test.Plain' cannot be omitted because its type integer does not accept nil",
                },
            },
            {
                name = "preclosed right",
                expression = "agree(maybe(), {missing = 42})",
                errors = {
                    "(spec):8:33: type error: field 'missing' not found in record type 'test.Plain'",
                    "(spec):8:32: type error: field 'item' of record 'test.Plain' cannot be omitted because its type integer does not accept nil",
                },
            },
            {
                name = "ordinary",
                expression = "accept({missing = 42})",
                errors = {
                    "(spec):8:25: type error: field 'missing' not found in record type 'test.Plain'",
                    "(spec):8:24: type error: field 'item' of record 'test.Plain' cannot be omitted because its type integer does not accept nil",
                },
            },
        }
        for _, case in ipairs(cases) do
            local errors = h.check_errs(source(case.expression))
            assert.same(#case.errors, #errors, case.name)
            for index, expected in ipairs(case.errors) do
                assert.equal(expected, errors[index], case.name)
            end
        end

        local ok, _, ast = run_checker(source(cases[1].expression))
        assert.falsy(ok)
        local bad = toplevel(ast, "Ast.TopLevelFunc", "bad")
        local function find_constructor(value, seen)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._tag == "Ast.ExpInitList" then return value end
            for key, child in pairs(value) do
                if key ~= "_decl" and key ~= "_declared_type"
                   and key ~= "_generic_scheme"
                   and key ~= "_generic_declaration"
                   and key ~= "_generic_owner" then
                    local found = find_constructor(child, seen)
                    if found then return found end
                end
            end
        end
        local constructor = assert(find_constructor(bad.block, {}))
        assert_nominal(constructor._type, "test.Plain", {})
        assert.same(0, #constructor.fields)
        assert.is_nil(constructor._generic_inference_context)
        assert.is_nil(constructor._generic_inference_use)
        assert.is_nil(constructor._generic_inference_operation_use)
    end)

    it("drains equated constraint records in lexical registration order",
    function()
        local declarations = [[
            interface Carrier<|T|>
                function marker(item: T): T
            end
            function scalar<|V, W: Carrier<|V|>|>(): function (W): V
                return function(owner: W): V
                    return (nil as value) as V
                end
            end
            function array<|V, W: Carrier<|{V}|>|>(): function (W): V
                return function(owner: W): V
                    return (nil as value) as V
                end
            end
            function combine<|P, Q|>(
                    first: function (P): Q, second: function (P): Q, owner: P): Q
                return first(owner)
            end
        ]]
        local function diagnose(arguments)
            local errs = h.check_errs(declarations .. ([=[
                function ordered<|Z: Carrier<|{integer}|>|>(owner: Z)
                    local got = combine(%s, owner)
                end
            ]=]):format(arguments))
            assert.same(1, #errs)
            return errs[1]
        end
        -- Both child W cells enter one equivalence class before `owner` binds
        -- it. The first queued constraint selects their shared V cell; reversing
        -- the written children must reverse which later constraint is rejected.
        assert.match("call to 'array'.-Carrier<|{ { integer } }|>",
            diagnose("scalar(), array()"))
        assert.match("call to 'scalar'.-Carrier<|integer|>",
            diagnose("array(), scalar()"))
    end)

    it("propagates constrained sibling evidence with bounded solver work",
    function()
        local count = 40
        local params, args = {}, {}
        for index = 1, count do
            params[index] = "x" .. index .. ": T"
            args[index] = "identity(x)"
        end
        local source = ([=[
            interface Marker
                function marker(): integer
            end
            function identity<|U: Marker|>(item: U): U return item end
            function many<|T: Marker|>(%s): T return x1 end
            function outer<|X: Marker|>(x: X): X
                local inferred = many(%s)
                return inferred
            end
        ]=]):format(table.concat(params, ", "), table.concat(args, ", "))

        local substitutions = 0
        local original = types.substitute_inference
        types.substitute_inference = function(...)
            substitutions = substitutions + 1
            return original(...)
        end
        local result = table.pack(pcall(assert_check, source))
        types.substitute_inference = original
        assert.truthy(result[1], result[2])
        -- A dirty-root constraint worklist and reachable-scope substitution are
        -- linear in these independent siblings. The former global rescan grows
        -- cubically and exceeds this bound by orders of magnitude.
        assert.is_true(substitutions <= 25 * count,
            ("expected at most %d substitutions, performed %d")
                :format(25 * count, substitutions))
        assert_runtime_ast_erased(result[2])
    end)

    it("rejects recursive cross-use inference equations without expansion",
    function()
        local diagnostic = "cannot infer a recursive type for type parameter "
            .. "'T' in call to 'take' from argument 1"

        local function check(source, instruction_budget)
            local result
            if instruction_budget then
                local prior_hook, prior_mask, prior_count = debug.gethook()
                local interval = 10000
                local remaining = math.ceil(instruction_budget / interval)
                debug.sethook(function()
                    remaining = remaining - 1
                    if remaining <= 0 then
                        error("generic occurs check exceeded its instruction budget", 2)
                    end
                end, "", interval)
                result = table.pack(pcall(run_checker, source))
                if prior_hook then
                    debug.sethook(prior_hook, prior_mask, prior_count)
                else
                    debug.sethook()
                end
                assert.truthy(result[1], result[2])
                result = table.pack(table.unpack(result, 2, result.n))
            else
                result = table.pack(run_checker(source))
            end

            local ok, err, ast = table.unpack(result, 1, result.n)
            assert.falsy(ok)
            assert.truthy(err:find(diagnostic, 1, true), err)
            local _, count = err:gsub("cannot infer a recursive type", "")
            assert.equal(1, count)
            assert.is_true(#err < 256)

            -- Error recovery closes both sides to their finite erased carriers;
            -- it must never retain the rejected T = Pair<T, T> equation.
            local bad = toplevel(ast, "Ast.TopLevelFunc", "bad")
            local call = bad.block.stats[1].exps[1]
            assert.equal(1, #call._generic_type_arguments)
            assert.equal("value", types.tostring(
                call._generic_type_arguments[1]))
        end

        check([[
            record Pair<|T, U|>
                first: T
                second: U
            end
            function dup<|U|>(item: U): Pair<|U, U|>
                return Pair<|U, U|>.new(item, item)
            end
            function take<|T|>(callback: function (T): T): value return nil end
            function bad(): value return take(dup) end
        ]])

        check([[
            function optionize<|U|>(item: U): U? return item end
            function take<|T|>(callback: function (T): T): value return nil end
            function bad(): value return take(optionize) end
        ]])

        -- Unrelated free binders increase the old fixed-point pass count. Keep
        -- this larger scope under a generous VM-instruction bound so a future
        -- self-expanding substitution fails instead of hanging the checker job.
        check([[
            record Pair<|T, U|>
                first: T
                second: U
            end
            function dup<|A, B, C, D, E, F, G, H, I, J,
                         K, L, M, N, O, P, Q, R, S, U|>(item: U): Pair<|U, U|>
                return Pair<|U, U|>.new(item, item)
            end
            function take<|T|>(callback: function (T): T): value return nil end
            function bad(): value return take(dup) end
        ]], 20000000)

    end)

    it("does not erase a cached source interface through imported annotations",
    function()
        local previous_registry = types.registry
        local previous_imported = driver.imported
        local ok, failure = pcall(function()
            types.registry = {}
            driver.imported = {}
            local imported = {}
            local modules = {
                provider = [[
                    record Box<|T|>
                        item: T
                    end
                    local function boxed(): Box<|string|>
                        return Box<|string|>.new("ok")
                    end
                ]],
                first = [[
                    local provider = import "provider.titan"
                    function use(): provider.Box<|string|>
                        return provider.boxed()
                    end
                ]],
                second = [[
                    local provider = import "provider"
                    function use(): integer return 42 end
                ]],
            }
            local loader = driver.tableloader(
                modules, imported, nil, { interface = "source" })
            driver.with_loader(loader, function(active_loader)
                for _, name in ipairs({ "provider", "first", "second" }) do
                    local module, errors =
                        checker.checkimport(name, active_loader)
                    assert.truthy(module, errors)
                    assert.equal(0, #errors)
                end
            end)
            local result = imported.provider.source_type
                .source_members.boxed.type.rettypes[1]
            assert_nominal(result, "provider.Box", { "string" })
        end)
        types.registry = previous_registry
        driver.imported = previous_imported
        assert.truthy(ok, failure)
    end)

end)

describe("analysis-only checked source ASTs", function()
    local source = [[
        union Packet<|T|>
            moved(x: T, text: string)
            empty()
        end
        type IntPacket = Packet<|integer|>
        function create(): Packet<|integer|>
            return Packet<|integer|>.moved {x = 1, text = "ready"}
        end
        function generic_create<|T|>(item: T): Packet<|T|>
            return Packet<|T|>.moved(item, "ready")
        end
        function alias_create(): Packet<|integer|>
            return IntPacket.moved(1, "ready")
        end
        function project<|T|>(packet: Packet<|integer|>, fallback: T): integer
            case packet
            when moved{x} then return x
            when empty() then return 0
            end
        end
    ]]

    local function check(analysis_only, input)
        h.reset(true)
        input = input or source
        local ast = assert(h.parse(input, "test.titan"))
        local modtype, errors = checker.check("test", ast, input,
            "test.titan", nil, { analysis_only = analysis_only })
        return ast, modtype, errors
    end

    local function returned_constructor(ast, name)
        local fn = toplevel(ast, "Ast.TopLevelFunc", name)
        return fn.block.stats[1].exps[1].exp.var
    end

    it("preserves applied constructor signatures and original generic case binders", function()
        local ast, modtype, errors = check(true)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_true(ast._analysis_only)
        assert.is_nil(ast._erased_registry)
        local owner = toplevel(ast, "Ast.TopLevelUnion", "Packet")
        assert.equal(1, #owner.typeparams)
        assert.equal("Type.Parameter", owner._type.variants.moved.parts[1].type._tag)
        local create = toplevel(ast, "Ast.TopLevelFunc", "create")
        assert_nominal(create._type.rettypes[1], "test.Packet", {"integer"})
        assert.equal("Ast.TypeInteger", create.rettypes[1].typeargs[1]._tag)
        for _, name in ipairs({"create", "alias_create"}) do
            local selector = returned_constructor(ast, name)
            assert.equal("integer", types.tostring(selector._type.params[1]))
            assert.equal("integer", types.tostring(
                selector._closed_generic_declaration.params[1]))
            assert.same({"x", "text"}, selector._closed_generic_declaration.paramnames)
            assert.equal("Type.Parameter", selector._decl.params[1]._tag)
            assert_nominal(selector._type.rettypes[1], "test.Packet", {"integer"})
        end
        local explicit = returned_constructor(ast, "create")
        assert.equal("Ast.TypeInteger", explicit.exp._nominal_typeargs[1]._tag)
        local generic = returned_constructor(ast, "generic_create")
        assert.equal("Type.Parameter", generic._type.params[1]._tag)
        assert_nominal(generic._type.rettypes[1], "test.Packet", {"T"})
        local project = toplevel(ast, "Ast.TopLevelFunc", "project")
        assert.equal("Type.FunctionScheme", project._type._tag)
        assert.equal(1, #project.typeparams)
        local arm = project.block.stats[1].arms[1]
        assert.equal("x", arm.bindings[1].name)
        assert.equal("integer", types.tostring(arm.bindings[1]._type))
        assert.equal("Ast.StatReturn", arm.block.stats[1]._tag)
        assert.equal(arm.bindings[1], arm.block.stats[1].exps[1].var._decl)
        assert.equal(modtype, ast._declared_type)
        assert.not_equal(ast._type, modtype)
        assert.not_equal(types.registry["test.Packet"], ast._declared_registry["test.Packet"])
        assert.equal(modtype.members.Packet.type, ast._declared_registry["test.Packet"])
        assert.is_nil(modtype.members.create._decl)
        assert.is_nil(ast._declared_registry["test.Packet"]._decl)
    end)

    it("retains ordinary runtime lowering and identical declared module interfaces", function()
        local analysis, analysis_type, errors = check(true)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local serialized = types.serialize(analysis_type)
        local ast, native_type, native_errors = check(false)
        assert.equal(0, #native_errors, table.concat(native_errors, "\n"))
        assert.is_nil(ast._analysis_only)
        assert.is_table(ast._erased_registry)
        local project = toplevel(ast, "Ast.TopLevelFunc", "project")
        assert.equal("Type.Function", project._type._tag)
        assert.equal(0, #project.typeparams)
        assert.not_equal("x", project.block.stats[1].arms[1].bindings[1].name)
        assert.equal(serialized, types.serialize(native_type))
        assert.equal(analysis_type.members.Packet.type.name, native_type.members.Packet.type.name)
        assert_runtime_ast_erased(project.block)
    end)

    it("runs the same source diagnostics before choosing the result representation", function()
        local invalid = source:gsub('x = 1', 'x = "wrong"', 1)
        local _, _, analysis_errors = check(true, invalid)
        local _, _, native_errors = check(false, invalid)
        assert.is_true(#analysis_errors > 0)
        assert.same(native_errors, analysis_errors)
    end)

    it("keeps failed analysis entries out of native caches and rechecks their diagnostics", function()
        h.reset(true)
        local invalid = source:gsub('x = 1', 'x = "wrong"', 1)
        local entries = {}
        local loader = driver.tableloader({ test = invalid }, entries, {}, { analysis_only = true })
        local ok, result, errors = loader("test")
        assert.is_true(ok, tostring(result))
        assert.is_true(#errors > 0)
        assert.is_true(entries.test.ast._analysis_only)
        assert.is_true(driver.close_loader(loader))
        loader = driver.tableloader({}, entries)
        local native_ok, native_error = loader("test")
        assert.is_false(native_ok)
        assert.matches("requires an analysis-only resolver", native_error, 1, true)
        assert.is_true(driver.close_loader(loader))
        loader = driver.tableloader({ test = invalid }, entries)
        local checked, _, native_errors = loader("test")
        assert.is_true(checked)
        assert.same(errors, native_errors)
        assert.is_nil(entries.test.ast._analysis_only)
        assert.is_true(driver.close_loader(loader))
    end)

    it("forwards analysis through tableloader and reparses cached analysis for native checking", function()
        h.reset(true)
        local entries = {}
        local loader = driver.tableloader({ test = source }, entries, {},
            { analysis_only = true, interface = "source" })
        local ok, result, errors = loader("test")
        assert.is_true(ok, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_true(driver.close_loader(loader))
        local analyzed = entries.test
        assert.is_true(analyzed.ast._analysis_only)
        loader = driver.tableloader({}, entries)
        local native_ok, native_error = loader("test")
        assert.is_false(native_ok)
        assert.matches("requires an analysis-only resolver", native_error, 1, true)
        assert.is_true(driver.close_loader(loader))
        loader = driver.tableloader({ test = source }, entries)
        ok, result, errors = loader("test")
        assert.is_true(ok, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_true(driver.close_loader(loader))
        assert.not_equal(analyzed, entries.test)
        assert.is_nil(entries.test.ast._analysis_only)
        assert.is_table(entries.test.ast._erased_registry)
    end)
end)
