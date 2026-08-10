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

function rule_array(...: peg.Rule): {peg.Rule}
  return {...}
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
