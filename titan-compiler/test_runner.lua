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

function test_runner.discover(requested_roots, imported, dependency_closure)
    local source_names = {}
    for _, root in ipairs(requested_roots) do
        for name in pairs(dependency_closure(root)) do
            local mod = imported[name]
            if mod and mod.ast then source_names[name] = true end
        end
    end

    local names = {}
    for name in pairs(source_names) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)

    local cases = {}
    local test_modules = {}
    for _, modname in ipairs(names) do
        local mod = imported[modname]
        for _, node in ipairs(mod.ast) do
            if is_test_function(node) then
                cases[#cases + 1] = {
                    modname = modname,
                    function_name = node.name,
                    full_name = modname .. "." .. node.name,
                }
                test_modules[modname] = true
            end
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

local RUNNER_IMPORTS = [=[local test = import "titan.test.titan"
foreign import "stdio.h"
foreign import "string.h"
]=]

local RUNNER_BODY = [=[
local type TestFunction = (test.Context) -> ()

local record TestCase
  local full_name: string
  local owner_module: string
  local body: TestFunction
end

local record State
  local filters: {string}
  local verbose: boolean
  local run: integer
  local passed: integer
  local skipped: integer
  local failed: integer
  local failed_names: {string}
end

local function copy_interval(subject: string, first: integer,
                             count: integer): string
  if count == 0 then return "" end
  local storage = char.new_array(count)
  local output = storage as *char
  local source = subject as const *char
  ffi.memcpy(output, source + first - 1, count as ffi.size_t)
  return storage as string
end

local function has_prefix(subject: string, prefix: string): boolean
  if #subject < #prefix then return false end
  local left = subject as const *unsigned char
  local right = prefix as const *unsigned char
  for index = 0, #prefix - 1 do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function write(output: string)
  local bytes = output as const *unsigned char
  for index = 0, #output - 1 do
    ffi.putchar(bytes[index] as int)
  end
end

local function writeln(output: string)
  write(output)
  ffi.putchar(10)
  if ffi.fflush(nil) ~= 0 then raise "cannot flush test output" end
end

local function report_log(full_name: string, message: string)
  writeln("[----------] " .. full_name .. ": " .. message)
end

local function test_word(count: integer): string
  if count == 1 then return "test" end
  return "tests"
end

local function count_text(count: integer): string
  return test.runner_error_text(count)
end

local function selected(state: State, full_name: string): boolean
  if #state.filters == 0 then return true end
  for index = 1, #state.filters do
    if test.runner_matches(full_name, state.filters[index]) then return true end
  end
  return false
end

local function print_trace(trace: string)
  writeln("stack traceback:")
  local bytes = trace as const *unsigned char
  local position = 1
  while position <= #trace do
    local ending = position
    while ending <= #trace and bytes[ending - 1] ~= 10 do
      ending = ending + 1
    end
    write("\t")
    writeln(copy_interval(trace, position, ending - position))
    position = ending + 1
  end
end

local function report_skipped(state: State, full_name: string,
                              reason: string)
  state.run = state.run + 1
  state.skipped = state.skipped + 1
  if #reason > 0 then
    writeln("[  SKIPPED ] " .. full_name .. " (" .. reason .. ")")
  else
    writeln("[  SKIPPED ] " .. full_name)
  end
end

local function report_failure(state: State, full_name: string,
                              owner_module: string, message: string,
                              trace: string)
  local file, function_name, line =
    test.runner_trace_location(trace, owner_module)
  writeln(file .. ":" .. count_text(line) .. ": in " .. function_name ..
          ": " .. message)
  if state.verbose then print_trace(trace) end
  writeln("[  FAILED  ] " .. full_name)
  state.failed = state.failed + 1
  state.failed_names[#state.failed_names + 1] = full_name
end

local function skip_registered(state: State,
                               subtests: {test.RegisteredTest},
                               reason: string)
  for index = 1, #subtests do
    local child = subtests[index]
    if selected(state, child.name) then
      report_skipped(state, child.name, reason)
    end
  end
end

local function execute(state: State, full_name: string,
                       owner_module: string, body: TestFunction)
  if not selected(state, full_name) then return end
  state.run = state.run + 1
  writeln("[ RUN      ] " .. full_name)

  local context = test.runner_new_context(full_name)
  local status = 0
  local message = ""
  local failure_trace = ""
  do
    body(context)
  catch
    local was_skip = false
    local reason: string? = nil
    was_skip, reason = test.runner_skip_reason(error)
    failure_trace = traceback
    if was_skip then
      status = 1
      if reason then message = reason as string end
    else
      status = 2
      message = test.runner_error_text(error)
    end
  end
  local subtests = test.runner_take_subtests(context)

  if status == 0 then
    for index = 1, #subtests do
      local child = subtests[index]
      execute(state, child.name, owner_module, child.callback)
    end
  elseif status == 1 then
    local child_reason = "parent skipped"
    if #message > 0 then child_reason = child_reason .. ": " .. message end
    skip_registered(state, subtests, child_reason)
  else
    skip_registered(state, subtests, "parent failed")
  end

  while true do
    local maybe_cleanup: test.Cleanup? = test.runner_take_cleanup(context)
    if not maybe_cleanup then break end
    do
      (maybe_cleanup as test.Cleanup)()
    catch
      if status ~= 2 then
        local cleanup_skip = false
        local cleanup_reason: string? = nil
        cleanup_skip, cleanup_reason = test.runner_skip_reason(error)
        status = 2
        failure_trace = traceback
        if cleanup_skip then
          message = "test.skip cannot be called from cleanup"
          if cleanup_reason then
            message = message .. ": " .. (cleanup_reason as string)
          end
        else
          message = test.runner_error_text(error)
        end
      end
    end
  end

  if status == 0 then
    state.passed = state.passed + 1
    writeln("[       OK ] " .. full_name)
  elseif status == 1 then
    state.skipped = state.skipped + 1
    if #message > 0 then
      writeln("[  SKIPPED ] " .. full_name .. " (" .. message .. ")")
    else
      writeln("[  SKIPPED ] " .. full_name)
    end
  else
    report_failure(state, full_name, owner_module, message, failure_trace)
  end
end

local function usage()
  writeln("Usage: <test-executable> [-h|--help] [-v|--verbose] " ..
          "[-f PATTERN|--filter=PATTERN]...")
end

local function option_error(message: string): (boolean, integer)
  writeln("error: " .. message)
  usage()
  return false, 2
end

local function parse_options(args: {string}, state: State):
    (boolean, integer)
  local index = 1
  while index <= #args do
    local argument = args[index]
    if argument == "-h" or argument == "--help" or argument == "-help" then
      usage()
      return false, 0
    elseif argument == "-v" or argument == "--verbose" then
      state.verbose = true
    elseif argument == "-f" then
      index = index + 1
      if index > #args then return option_error("-f requires a pattern") end
      state.filters[#state.filters + 1] = args[index]
    elseif has_prefix(argument, "--filter=") then
      state.filters[#state.filters + 1] = copy_interval(
        argument, #"--filter=" + 1, #argument - #"--filter=")
    else
      return option_error("unknown option '" .. argument .. "'")
    end
    index = index + 1
  end

  for filter_index = 1, #state.filters do
    do
      test.runner_matches("", state.filters[filter_index])
    catch
      return option_error("invalid Lua pattern '" ..
        state.filters[filter_index] .. "': " ..
        test.runner_error_text(error))
    end
  end
  return true, 0
end

]=]

local MAIN_PREFIX = [=[
function main(args: {string}): integer
  local filters: {string} = {}
  local failed_names: {string} = {}
  local state = State.new(filters, false, 0, 0, 0, 0, failed_names)
  local proceed, status = parse_options(args, state)
  if not proceed then return status end

  local cases: {TestCase} = {}
]=]

local MAIN_SUFFIX = [=[

  test.runner_begin(state.verbose, report_log)
  defer test.runner_end()
  writeln("[==========] Running Titan tests.")
  for index = 1, #cases do
    local test_case = cases[index]
    execute(state, test_case.full_name, test_case.owner_module,
            test_case.body)
  end

  writeln("[==========] " .. count_text(state.run) .. " " ..
          test_word(state.run) .. " ran.")
  writeln("[  PASSED  ] " .. count_text(state.passed) .. " " ..
          test_word(state.passed) .. ".")
  if state.skipped > 0 then
    writeln("[  SKIPPED ] " .. count_text(state.skipped) .. " " ..
            test_word(state.skipped) .. ".")
  end
  if state.failed > 0 then
    writeln("[  FAILED  ] " .. count_text(state.failed) .. " " ..
            test_word(state.failed) .. ".")
    for index = 1, #state.failed_names do
      writeln("[  FAILED  ] " .. state.failed_names[index])
    end
    return 1
  end
  return 0
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
            "  cases[#cases + 1] = TestCase.new(" ..
            quoted(case.full_name) .. ", " .. quoted(case.modname) ..
            ", " .. wrapper .. ")"
    end

    return table.concat({
        table.concat(imports),
        RUNNER_BODY,
        table.concat(wrappers, "\n\n"),
        MAIN_PREFIX,
        table.concat(registrations, "\n"),
        MAIN_SUFFIX,
    }, "\n")
end

return test_runner
