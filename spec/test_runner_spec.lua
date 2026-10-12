local assert = require "luassert"
local parser = require "titan-compiler.parser"
local test_runner = require "titan-compiler.test_runner"
local types = require "titan-compiler.types"

local function function_type(parameter, options)
    options = options or {}
    return types.Function(
        options.params or { parameter },
        options.rettypes or {},
        options.vararg == true,
        options.varargtype,
        options.flexrettype)
end

local function test_node(name, parameter, options)
    options = options or {}
    local node = {
        _tag = options.tag or "Ast.TopLevelFunc",
        name = name,
        islocal = options.islocal == true,
        _ignore = options.ignore == true,
        _type = function_type(parameter, options),
    }
    if options.missing_type then node._type = nil end
    return node
end

local CONTEXT = types.Nominal(test_runner.CONTEXT_NAME)

describe("Titan test-runner source generation", function()
    it("recognizes the checked callable shape and transparent aliases",
       function()
        assert.is_true(test_runner.is_test_function(
            test_node("test_exact", CONTEXT)))

        local rejected = {
            test_node("helper", CONTEXT),
            test_node("test_local", CONTEXT, { islocal = true }),
            test_node("test_ignored", CONTEXT, { ignore = true }),
            test_node("test_wrong", types.Nominal("other.Context")),
            test_node("test_many", CONTEXT, {
                params = { CONTEXT, CONTEXT },
            }),
            test_node("test_variadic", CONTEXT, {
                varargtype = types.String(),
            }),
            test_node("test_missing", CONTEXT, { missing_type = true }),
            test_node("test_record", CONTEXT, {
                tag = "Ast.TopLevelRecord",
            }),
        }
        for _, node in ipairs(rejected) do
            assert.is_false(test_runner.is_test_function(node), node.name)
        end
    end)

    it("discovers only source modules in requested closures and sorts names",
       function()
        local imported = {
            root_b = { ast = {
                test_node("test_z", CONTEXT),
                test_node("test_a", CONTEXT),
            } },
            root_a = { ast = { test_node("test_root", CONTEXT) } },
            dependency = { ast = { test_node("test_dependency", CONTEXT) } },
            binary = { type = types.Module("binary", {}, {}) },
            unrelated = { ast = { test_node("test_unrelated", CONTEXT) } },
        }
        local closures = {
            root_b = { root_b = true, dependency = true, binary = true },
            root_a = { root_a = true, dependency = true },
        }
        local cases, modules = test_runner.discover(
            { "root_b", "root_a" }, imported,
            function(root) return closures[root] end)
        local names = {}
        for index, case in ipairs(cases) do names[index] = case.full_name end
        assert.same({
            "dependency.test_dependency",
            "root_a.test_root",
            "root_b.test_a",
            "root_b.test_z",
        }, names)
        assert.same({ dependency = true, root_a = true, root_b = true },
            modules)
    end)

    it("renders an ordinary parseable runner and wrappers that discard results",
       function()
        local source, render_err = test_runner.render({
            {
                modname = "example.alpha",
                function_name = "test_one",
                full_name = "example.alpha.test_one",
            },
            {
                modname = "example.alpha",
                function_name = "test_two",
                full_name = "example.alpha.test_two",
            },
            {
                modname = "example.beta",
                function_name = "test_other",
                full_name = "example.beta.test_other",
            },
        })
        assert.truthy(source, render_err)
        local ast, err = parser.parse("generated__test_runner.titan", source)
        assert.truthy(ast, err and parser.error_to_string(err,
            "generated__test_runner.titan") or "generated runner did not parse")
        assert.equal(1, select(2, source:gsub(
            'local test = import "titan.test"', "")))
        assert.falsy(source:find('import "titan.test.titan"', 1, true), source)
        assert.falsy(source:find("foreign import", 1, true), source)
        assert.equal(1, select(2, source:gsub(
            'local test_module_1 = import "example.alpha"', "")))
        assert.equal(1, select(2, source:gsub(
            'local test_module_2 = import "example.beta"', "")))
        assert.truthy(source:find(
            "  test_module_1.test_one(context)\nend", 1, true), source)
        assert.truthy(source:find(
            "function main(args: {string}): integer", 1, true), source)
        assert.truthy(source:find("test.Case.new(", 1, true), source)
        assert.truthy(source:find("return test.run(args, cases)", 1, true), source)
    end)

    it("discovers the same checked cases from source objects without ASTs", function()
        local ast = {
            test_node("test_public", CONTEXT),
            test_node("test_private", CONTEXT, { islocal = true }),
            test_node("test_wrong", types.Integer()),
            test_node("test_variadic", CONTEXT, { varargtype = CONTEXT }),
            test_node("test_returns", CONTEXT, { rettypes = { types.Integer() } }),
        }
        local cached = {
            kind = "source",
            object_metadata = {},
            test_functions = test_runner.function_names(ast),
        }
        local function closure() return { suite = true, binary = true } end
        local cold, cold_modules = test_runner.discover({ "suite" }, {
            suite = { ast = ast }, binary = { test_functions = { "test_hidden" } },
        }, closure)
        local warm, warm_modules = test_runner.discover({ "suite" }, {
            suite = cached, binary = { test_functions = { "test_hidden" } },
        }, closure)
        assert.same(cold, warm)
        assert.same(cold_modules, warm_modules)
        assert.equal(2, #warm)
        assert.equal("suite.test_public", warm[1].full_name)
        assert.equal("suite.test_returns", warm[2].full_name)
    end)

    it("renders a valid zero-test executable and owns adjacent outputs",
       function()
        local source, render_err = test_runner.render({})
        assert.truthy(source, render_err)
        local ast, err = parser.parse("empty__test_runner.titan", source)
        assert.truthy(ast, err and parser.error_to_string(err,
            "empty__test_runner.titan") or "empty runner did not parse")
        local descriptor = test_runner.source_descriptor("path/suite", source)
        assert.equal("generated", descriptor.kind)
        assert.equal("path/suite__test_runner.titan", descriptor.main)
        assert.equal("path/suite", descriptor.program_output)
        assert.equal(source, descriptor.contents[descriptor.main])
    end)
    it("rejects owner names rewritten by standard import shorthand", function()
        local source, message = test_runner.render({{
            modname = "url",
            function_name = "test_example",
            full_name = "url.test_example",
        }})
        assert.is_nil(source)
        assert.matches("test owner module 'url' is reserved", message,
            1, true)
        assert.matches("titan.url", message, 1, true)
    end)

end)
