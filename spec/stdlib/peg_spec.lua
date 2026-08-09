-- Public titan.peg behavior is a standard-library integration suite and runs
-- outside LuaCov. The private native engine itself has a separate upstream
-- harness in spec/lpeglabel_build_spec.lua.
local assert = require "luassert"
local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"

local REPO = async_stdlib.repo
local LPEGLABEL_ARCHIVE =
    REPO .. "/lpeglabel-build/libtitan-lpeglabel.a"
local LPEGLABEL_CPPFLAGS = "-I" .. REPO .. "/vendor/lpeglabel"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local prefix = os.getenv("PREFIX")
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

local PROBE_SOURCE = [[
local peg = import "peg"

local function runtime_callback(
    subject: string, position: integer,
    whole: string): (integer, string, string, string)
  return position + 1, "titan-runtime", whole, subject
end

local function delayed_callback(
    first: value, ...: value): (string, value, ...: value)
  return "titan-function", first, ...
end

local function fold_callback(
    accumulator: value, ...: value): value
  local total = accumulator as integer
  local index = 1
  while index <= #... do
    total = total + (...[index] as integer)
    index = index + 1
  end
  return total
end

local function no_results(): ()
end

local function first_only(first: value): value
  return first
end

function recursive(): peg.Pattern
  local rules: {peg.Rule} = {
    peg.rule("S", peg.sequence(
      peg.literal("a"),
      peg.optional(peg.variable("S")))),
  }
  return peg.grammar("S", rules)
end

function rule_array(...: peg.Rule): {peg.Rule}
  return {...}
end

function grammar_with_rule_count(count: integer): peg.Pattern
  local rules: {peg.Rule} = {}
  local index = 1
  while index <= count do
    rules[index] = peg.rule(
      "rule" .. index,
      index == 1 and peg.succeed() or peg.fail())
    index = index + 1
  end
  return peg.grammar("rule1", rules)
end

function runtime_pattern(): peg.Pattern
  return peg.runtime(runtime_callback)
end

function function_pattern(): peg.Pattern
  return peg.function_capture(
    peg.capture(peg.literal("x")), delayed_callback)
end

function fold_pattern(): peg.Pattern
  return peg.fold_capture(
    peg.sequence(
      peg.constant(10),
      peg.constant(20, 3),
      peg.constant(7)),
    fold_callback)
end

function zero_runtime_pattern(): peg.Pattern
  return peg.runtime(no_results)
end

function zero_match_time_pattern(): peg.Pattern
  return peg.match_time(peg.succeed(), no_results)
end

function zero_function_pattern(): peg.Pattern
  return peg.function_capture(peg.succeed(), no_results)
end

function fixed_function_pattern(): peg.Pattern
  return peg.function_capture(
    peg.constant("first", "ignored"), first_only)
end
]]

describe("titan.peg", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before titan.peg specs")
        workspace = async_stdlib.workspace("peg")
        for _, name in ipairs({
            "peg", "native", "combinators",
            "relabel", "relabel_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.peg." .. name,
                async_stdlib.read("titan/peg/" .. name .. ".titan"))
        end
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.prepare_gc(workspace, layout)
        async_stdlib.compile(workspace, "titan.peg", {
            layout = layout,
            cppflags = LPEGLABEL_CPPFLAGS,
            extra_objects = { LPEGLABEL_ARCHIVE },
        })
        async_stdlib.register_exact_provider(layout, "titan.peg")

        async_stdlib.write_source(
            workspace, "peg_core_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "peg_core_probe", {
            layout = layout,
            cppflags = "",
        })
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so;;"
        local command = table.concat({
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_22=" .. quote(workspace),
            "TITAN_PATH=",
            "LUA_PATH=" .. quote(lua_path),
            "LUA_PATH_5_5=" .. quote(lua_path),
            "LUA_CPATH=" .. quote(cpath),
            "LUA_CPATH_5_5=" .. quote(cpath),
            quote(LUA) .. " -e " .. quote(source),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("GC roots patterns and callbacks across repeated collections",
    function()
        run([[
            local peg = require "titan.peg"
            collectgarbage("collect")
            collectgarbage("generational")

            local weak = setmetatable({}, { __mode = "v" })
            local function build()
                local callback = function(value)
                    return value .. "!"
                end
                local lookup = setmetatable({}, {
                    __index = function(_, key) return key .. "?" end,
                })
                weak.callback = callback
                weak.lookup = lookup
                local delayed = peg.function_capture(
                    peg.capture(peg.literal("a")), callback)
                local queried = peg.query_capture(
                    peg.capture(peg.literal("b")), lookup)
                return peg.choice(delayed, queried)
            end

            local pattern = build()
            for index = 1, 100 do
                if index % 2 == 0 then
                    collectgarbage("collect")
                else
                    collectgarbage("step", 0)
                end
                assert(pattern:match("a") == "a!")
                assert(pattern:match("b") == "b?")
            end
            assert(weak.callback and weak.lookup)

            local record_weak = setmetatable(
                { pattern = pattern }, { __mode = "v" })
            pattern = nil
            collectgarbage("collect")
            collectgarbage("collect")
            assert(record_weak.pattern == nil)
            assert(weak.callback == nil and weak.lookup == nil)
        ]])
    end)

    it("keeps private and external LPegLabel engines isolated", function()
        local function exercise(load_private_first)
            local prefix = load_private_first and [[
                package.loaded.lpeglabel = nil
                local peg = require "titan.peg"
                assert(package.loaded.lpeglabel == nil)
                local external = require "lpeglabel"
                local private_has_larger_stack = true
            ]] or [[
                package.loaded.lpeglabel = nil
                local external = require "lpeglabel"
                local peg = require "titan.peg"
                assert(package.loaded.lpeglabel == external)
                local private_has_larger_stack = false
            ]]
            run(prefix .. [[
                local probe = require "peg_core_probe"
                local private_pattern = peg.literal("a")
                local external_pattern = external.P("a")
                assert(private_pattern:match("a") == 2)
                assert(external.match(external_pattern, "a") == 2)
                assert(not pcall(peg.sequence, external_pattern))
                assert(not pcall(
                    external.match, private_pattern, "a"))

                local private_recursive = peg.grammar(
                    "S", probe.rule_array(
                    peg.rule("S", peg.choice(
                        peg.sequence(
                            peg.literal("0"), peg.variable("S")),
                        peg.literal("0")))
                ))
                local external_recursive = external.P({
                    "0" * external.V(1) + "0",
                })
                local subject = string.rep("0", 300)

                if private_has_larger_stack then
                    peg.set_max_stack(1000)
                    external.setmaxstack(500)
                    assert(private_recursive:match(subject) == 301)
                    assert(not pcall(
                        external.match, external_recursive, subject))
                else
                    external.setmaxstack(1000)
                    peg.set_max_stack(500)
                    assert(external.match(
                        external_recursive, subject) == 301)
                    assert(not pcall(function()
                        return private_recursive:match(subject)
                    end))
                end
                peg.set_max_stack(400)
                external.setmaxstack(400)
            ]])
        end

        exercise(true)
        exercise(false)
    end)
end)
