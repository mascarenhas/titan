local h = require "spec.support.helpers"

local function assert_check(source)
    local ok, err, ast, modtype = h.run_checker(source)
    assert.truthy(ok, err)
    return ast, modtype
end

local function find_toplevel(ast, tag, name)
    for _, node in ipairs(ast) do
        if node._tag == tag and node.name == name then return node end
    end
    error(string.format("missing %s '%s'", tag, name))
end

local function unwrap_cast(exp)
    while exp._tag == "Ast.ExpCast" do exp = exp.exp end
    return exp
end

local function source_graph_entry(root)
    local seen = {}
    local function visit(value, path)
        if type(value) ~= "table" or seen[value] then return nil end
        seen[value] = true
        local tag = value._tag
        if type(tag) == "string"
           and (tag:match("^Ast%.") or tag:match("^Checker%.")) then
            return path .. " (" .. tag .. ")"
        end
        for key, child in pairs(value) do
            local found = visit(key, path .. ".<key>")
                or visit(child, path .. "." .. tostring(key))
            if found then return found end
        end
        return nil
    end
    return visit(root, "module")
end

describe("checker semantic metadata", function()
    it("keeps source bindings out of the detached module interface",
    function()
        local ast, modtype = assert_check([[
            interface Show
                function show(): string
            end
            function identity<|T: Show|>(item: T): T
                return item
            end
        ]])

        assert.is_nil(source_graph_entry(modtype))

        local show = find_toplevel(ast, "Ast.TopLevelInterface", "Show")
        local identity = find_toplevel(
            ast, "Ast.TopLevelFunc", "identity")
        local parameter = identity._surface_typeparams[1]
        assert.is_true(parameter._decl == parameter)
        assert.is_true(parameter.constraint._decl == show)
        assert.is_true(identity.params[1].type._decl == parameter)
        assert.equal("Checker.Parameter", identity.params[1]._decl._tag)

        local published = modtype.members.identity.type
        assert.is_nil(published._parameter_decls)
        assert.is_nil(published.signature.params[1]._decl)
    end)

    it("binds source declarations and selected member occurrences", function()
        local ast = assert_check([[
            record Box<|T|>
                item: T
            end
            union Maybe
                Some(Box<|integer|>)
                None()
            end
            interface View
                item: integer
                function read(): integer
            end
            local type Alias = Box<|integer|>
            function Box:get(): T return self.item end
            function Box:replace<|U|>(item: U): T return self.item end
            function Box.make<|U|>(item: U): Box<|U|>
                return Box<|U|>.new(item)
            end
            function inspect<|T|>(box: Box<|T|>, alias: Alias,
                                maybe: Maybe): T
                local field = box.item
                local bound = box:get
                local got = box:get()
                local replaced = box:replace{item = 1}
                local made: Box<|T|> = { item = field }
                case maybe
                when Some(some) then
                else
                end
                return field
            end
        ]])

        local box = find_toplevel(ast, "Ast.TopLevelRecord", "Box")
        local maybe = find_toplevel(ast, "Ast.TopLevelUnion", "Maybe")
        local view = find_toplevel(ast, "Ast.TopLevelInterface", "View")
        local alias = find_toplevel(ast, "Ast.TopLevelTypeAlias", "Alias")
        local get = find_toplevel(ast, "Ast.TopLevelMethod", "get")
        local replace = find_toplevel(ast, "Ast.TopLevelMethod", "replace")
        local make = find_toplevel(ast, "Ast.TopLevelStatic", "make")
        local inspect = find_toplevel(ast, "Ast.TopLevelFunc", "inspect")

        assert.is_true(box._decl == box)
        assert.is_true(maybe._decl == maybe)
        assert.is_true(view._decl == view)
        assert.is_true(alias._decl == alias)
        assert.is_true(inspect._decl == inspect)

        assert.equal("Type.Field", box.fields[1]._decl._tag)
        assert.is_true(box.fields[1]._decl == box.fields[1]._field)
        assert.equal("test.Box", box.fields[1]._decl.fqtn)
        assert.equal("Type.Variant", maybe.variants[1]._decl._tag)
        assert.is_true(maybe.variants[1]._decl == maybe.variants[1]._type)
        assert.equal("Type.Field", view.fields[1]._decl._tag)
        assert.equal("Type.Method", view.methods[1]._decl._tag)

        assert.is_true(get._owner_decl == box)
        assert.is_true(replace._owner_decl == box)
        assert.is_true(make._owner_decl == box)
        assert.is_true(get._decl == get._type)
        assert.is_true(replace._decl == replace._type)
        assert.is_true(make._decl == make._type)

        -- Runtime lowering erases the public generic lists, but semantic
        -- tooling retains the written syntax through private source edges.
        assert.same({}, box.typeparams)
        assert.equal("T", box._surface_typeparams[1].name)
        assert.is_true(box._surface_typeparams[1]._decl ==
            box._surface_typeparams[1])
        assert.is_true(box.fields[1].type._decl ==
            box._surface_typeparams[1])
        assert.equal("T", inspect._surface_typeparams[1].name)
        assert.is_true(inspect.params[1].type._decl == box)
        assert.is_true(inspect.params[1].type._surface_typeargs[1]._decl ==
            inspect._surface_typeparams[1])
        assert.equal("Type.Parameter",
            inspect.params[1].type._surface_typeargs[1]
                ._resolved_typearg._tag)
        assert.is_true(
            inspect.params[1].type._surface_typeargs[1]
                ._resolved_typearg._decl == inspect._surface_typeparams[1])
        assert.equal("Type.Integer",
            maybe.variants[1].payload._surface_typeargs[1]
                ._resolved_typearg._tag)
        assert.is_true(inspect.params[2].type._decl == alias)
        assert.is_true(inspect.params[3].type._decl == maybe)
        assert.is_true(inspect.rettypes[1]._decl ==
            inspect._surface_typeparams[1])

        local stats = inspect.block.stats
        local field = unwrap_cast(stats[1].exps[1]).var
        assert.equal("Ast.VarDot", field._tag)
        assert.equal("Type.Field", field._decl._tag)
        assert.equal("test.Box", field._decl.fqtn)

        local bound = unwrap_cast(stats[2].exps[1])
        assert.equal("Ast.ExpMethodRef", bound._tag)
        assert.equal("Type.Method", bound._decl._tag)
        assert.equal("get", bound._decl.name)

        local called = unwrap_cast(stats[3].exps[1])
        assert.equal("Ast.ArgsMethod", called.args._tag)
        assert.equal("Type.Method", called.args._decl._tag)
        assert.equal("get", called.args._decl.name)
        assert.equal("Type.Method", called.args._declared_method._tag)
        assert.equal("Type.Parameter",
            called.args._declared_method.rettypes[1]._tag)
        assert.equal("Type.Value", called.args._decl.rettypes[1]._tag)

        local named = unwrap_cast(stats[4].exps[1])
        assert.equal("Ast.ArgsMethod", named.args._tag)
        assert.equal("Type.Method", named.args._decl._tag)
        assert.equal("replace", named.args._decl.name)
        assert.equal("Type.Method", named.args._declared_method._tag)
        assert.truthy(named.args._name_loc)

        local initializer = unwrap_cast(stats[5].exps[1])
        assert.equal("Ast.ExpInitList", initializer._tag)
        assert.equal("Type.Field", initializer.fields[1]._decl._tag)
        assert.is_true(initializer.fields[1]._decl ==
            initializer.fields[1]._field)

        local arm = stats[6].arms[1]
        assert.equal("Type.Variant", arm._decl._tag)
        assert.is_true(arm._decl == arm._variant)
        assert.equal("Some", arm._decl.name)

    end)

    it("binds qualified type members and their module qualifier", function()
        local ok, err, imported = h.run_checker_modules({
            library = [[
                record Item
                    data: integer
                end
                interface Reader
                    function read(): integer
                end
                type Alias = Item
            ]],
            consumer = [[
                local lib = import "library"
                function use(item: lib.Item, alias: lib.Alias,
                             reader: lib.Reader): lib.Item
                    return item
                end
            ]],
        }, "consumer", { interface = "compiled" })
        assert.truthy(ok, err)

        local consumer = imported.consumer.ast
        local import = consumer[1]
        local use = find_toplevel(consumer, "Ast.TopLevelFunc", "use")
        assert.is_true(import._decl == import)

        local refs = {
            { node = use.params[1].type, name = "Item" },
            { node = use.params[2].type, name = "Alias" },
            { node = use.params[3].type, name = "Reader" },
            { node = use.rettypes[1], name = "Item" },
        }
        for _, expected in ipairs(refs) do
            local node = expected.node
            assert.is_true(node._module_decl == import)
            assert.equal("Checker.TypeMember", node._decl._tag)
            assert.equal("library", node._decl.modname)
            assert.equal(expected.name, node._decl.name)
        end
    end)

    it("retains source visibility on qualified type aliases", function()
        local ok, err, imported = h.run_checker_modules({
            provider = [[
                record Box<|T|>
                    item: T
                end
                local type Hidden = integer
                type Public = Hidden
                local type HiddenBox = Box
                type PublicBox = HiddenBox
            ]],
            consumer = [[
                local provider = import "provider.titan"
                local type ForwardHiddenBox = provider.HiddenBox
                type ForwardPublicBox = provider.PublicBox
                function use(number: provider.Hidden): provider.Public
                    local hidden: provider.HiddenBox<|string|> =
                        provider.HiddenBox<|string|>.new("hidden")
                    local public: provider.PublicBox<|string|> = hidden
                    if public.item == "" then return 0 end
                    return number
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)

        local provider = imported.provider.ast
        assert.is_true(find_toplevel(provider,
            "Ast.TopLevelTypeAlias", "Hidden").islocal)
        assert.is_true(find_toplevel(provider,
            "Ast.TopLevelTypeAlias", "HiddenBox").islocal)

        local consumer = imported.consumer.ast
        local forward_hidden = find_toplevel(
            consumer, "Ast.TopLevelTypeAlias", "ForwardHiddenBox")
        local forward_public = find_toplevel(
            consumer, "Ast.TopLevelTypeAlias", "ForwardPublicBox")
        assert.is_true(forward_hidden.type._decl.islocal)
        assert.is_false(forward_public.type._decl.islocal)

        local use = find_toplevel(consumer, "Ast.TopLevelFunc", "use")
        local refs = {
            { node = use.params[1].type, name = "Hidden", islocal = true },
            { node = use.rettypes[1], name = "Public", islocal = false },
            { node = use.block.stats[1].decls[1].type,
              name = "HiddenBox", islocal = true },
            { node = use.block.stats[2].decls[1].type,
              name = "PublicBox", islocal = false },
        }
        for _, expected in ipairs(refs) do
            local declaration = expected.node._decl
            assert.equal("Checker.TypeMember", declaration._tag)
            assert.equal("provider", declaration.modname)
            assert.equal(expected.name, declaration.name)
            assert.equal(expected.islocal, declaration.islocal)
        end

        local constructor = unwrap_cast(use.block.stats[1].exps[1])
        local namespace = constructor.exp.var.exp.var
        assert.equal("HiddenBox", namespace.name)
        assert.equal("Checker.TypeMember", namespace._decl._tag)
        assert.is_true(namespace._decl.islocal)
    end)

    it("retains named labels bound to callable parameters and aliases",
    function()
        local ok, err, imported = h.run_checker_modules({
            library = [[
                record Box
                    amount: integer
                end
                type Alias = Box
                function choose(first: integer, second: integer): integer
                    return first + second
                end
                function Box:add(delta: integer): integer
                    return self.amount + delta
                end
            ]],
            consumer = [[
                local lib = import "library"
                function use(box: lib.Box): integer
                    local chosen = lib.choose { second = 2, first = 1 }
                    local added = box:add { delta = 3 }
                    local aliased: lib.Alias = lib.Alias.new { amount = 4 }
                    return chosen + added + aliased.amount
                end
            ]],
        }, "consumer", { interface = "compiled" })
        assert.truthy(ok, err)

        local library = imported.library.ast
        local choose = find_toplevel(
            library, "Ast.TopLevelFunc", "choose")
        local add = find_toplevel(library, "Ast.TopLevelMethod", "add")
        local consumer = imported.consumer.ast
        local use = find_toplevel(consumer, "Ast.TopLevelFunc", "use")

        local choose_call = unwrap_cast(use.block.stats[1].exps[1])
        assert.equal("Ast.ArgsFunc", choose_call.args._tag)
        assert.equal(2, #choose_call._surface_named_args)
        local second = choose_call._surface_named_args[1]
        local first = choose_call._surface_named_args[2]
        assert.equal("second", second.name)
        assert.equal("Checker.Parameter", second._decl._tag)
        assert.equal("module", second._decl.owner_kind)
        assert.equal("library", second._decl.owner_name)
        assert.equal("choose", second._decl.callable_name)
        assert.equal(2, second._decl.index)
        assert.equal(1, first._decl.index)
        assert.equal("Checker.Parameter", choose.params[1]._decl._tag)
        assert.equal(first._decl.owner_name,
            choose.params[1]._decl.owner_name)
        assert.equal(first._decl.callable_name,
            choose.params[1]._decl.callable_name)
        assert.equal(first._decl.index, choose.params[1]._decl.index)

        local method_call = unwrap_cast(use.block.stats[2].exps[1])
        local delta = method_call._surface_named_args[1]
        assert.equal("member", delta._decl.owner_kind)
        assert.equal("library.Box", delta._decl.owner_name)
        assert.equal("add", delta._decl.callable_name)
        assert.equal(1, delta._decl.index)
        assert.equal(add.params[1]._decl.owner_name,
            delta._decl.owner_name)

        local alias_call = unwrap_cast(use.block.stats[3].exps[1])
        local alias_namespace = alias_call.exp.var.exp.var
        assert.equal("Alias", alias_namespace.name)
        assert.equal("Checker.TypeMember", alias_namespace._decl._tag)
        assert.equal("library", alias_namespace._decl.modname)
        assert.equal("Alias", alias_namespace._decl.name)
        assert.equal("Type.Field",
            alias_call._surface_named_args[1]._decl._tag)
        assert.equal("library.Box",
            alias_call._surface_named_args[1]._decl.fqtn)
        assert.equal("amount", alias_call._surface_named_args[1]._decl.name)
    end)
end)
