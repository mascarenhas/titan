local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"

local test_runner = {}

test_runner.MODULE_NAME = "titan.test.runner"
test_runner.CONTEXT_NAME = "titan.test.Context"
test_runner.TEST_COMPILE_FLAGS = { "-fno-optimize-sibling-calls" }

local function is_test_function(node)
    if type(node) ~= "table" or node._tag ~= "Ast.TopLevelFunc" or
       node._ignore or node.islocal or type(node.name) ~= "string" or
       not node.name:match("^test_") or type(node._type) ~= "table" or
       node._type.varargtype or #node._type.params ~= 1 then
        return false
    end
    local parameter = types.normalize(node._type.params[1])
    return parameter ~= nil and parameter._tag == "Type.Nominal" and
        parameter.fqtn == test_runner.CONTEXT_NAME
end

test_runner.is_test_function = is_test_function

function test_runner.function_names(ast)
    local names = {}
    for _, node in ipairs(ast) do
        if is_test_function(node) then names[#names + 1] = node.name end
    end
    return names
end

function test_runner.discover(requested_roots, imported, dependency_closure)
    local source_names = {}
    for _, root in ipairs(requested_roots) do
        for name in pairs(dependency_closure(root)) do
            local mod = imported[name]
            if mod and (mod.ast or mod.kind == "source" and mod.object_metadata) then
                source_names[name] = true
            end
        end
    end

    local names = {}
    for name in pairs(source_names) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)

    local cases = {}
    local test_modules = {}
    for _, modname in ipairs(names) do
        local mod = imported[modname]
        local functions = mod.ast and test_runner.function_names(mod.ast)
            or mod.test_functions
        for _, name in ipairs(functions) do
            cases[#cases + 1] = {
                modname = modname,
                function_name = name,
                full_name = modname .. "." .. name,
            }
            test_modules[modname] = true
        end
    end
    table.sort(cases, function(left, right)
        return util.bytewise_less(left.full_name, right.full_name)
    end)
    return cases, test_modules
end

local function quoted(value)
    return string.format("%q", value)
end

function test_runner.source_descriptor(program_output, source)
    local filename = program_output .. "__test_runner.titan"
    return {
        kind = "generated",
        main = filename,
        files = { filename },
        contents = { [filename] = source },
        program_output = program_output,
    }
end

local RUNNER_IMPORTS = [=[local test = import "titan.test"
]=]

local MAIN_PREFIX = [=[
function main(args: {string}): integer
  local cases: {test.Case} = {}
]=]

local MAIN_SUFFIX = [=[
  return test.run(args, cases)
end
]=]

function test_runner.render(cases)
    local imports = { RUNNER_IMPORTS }
    local module_aliases = {}
    local module_order = {}
    for _, case in ipairs(cases) do
        local parsed_name = parser.normalize_import(case.modname)
        if parsed_name ~= case.modname then
            return nil, "test owner module '" .. case.modname ..
                "' is reserved by standard-library import shorthand for '" ..
                parsed_name .. "'; choose a nonreserved test module name"
        end
        if not module_aliases[case.modname] then
            local alias = "test_module_" .. tostring(#module_order + 1)
            module_aliases[case.modname] = alias
            module_order[#module_order + 1] = case.modname
            imports[#imports + 1] = "local " .. alias .. " = import " ..
                quoted(case.modname) .. "\n"
        end
    end

    local wrappers = {}
    local registrations = {}
    for index, case in ipairs(cases) do
        local wrapper = "run_test_" .. tostring(index)
        wrappers[#wrappers + 1] = table.concat({
            "local function " .. wrapper .. "(context: test.Context)",
            "  " .. module_aliases[case.modname] .. "." ..
                case.function_name .. "(context)",
            "end",
        }, "\n")
        registrations[#registrations + 1] =
            "  cases[#cases + 1] = test.Case.new(" ..
            quoted(case.full_name) .. ", " .. quoted(case.modname) ..
            ", " .. wrapper .. ")"
    end

    return table.concat({
        table.concat(imports),
        table.concat(wrappers, "\n\n"),
        MAIN_PREFIX,
        table.concat(registrations, "\n"),
        MAIN_SUFFIX,
    }, "\n")
end

return test_runner
