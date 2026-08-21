local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local function shell_command(argv)
    local words = {}
    for index, arg in ipairs(argv) do
        words[index] = assert(cdriver.shell_quote(arg))
    end
    return table.concat(words, " ")
end

local function lua_executable()
    local prefix = os.getenv("PREFIX")
    if prefix then
        local candidate = prefix .. "/bin/lua"
        if lfs.symlinkattributes(candidate, "mode") == "file" then
            return candidate
        end
    end
    if type(arg) == "table" and type(arg[-1]) == "string"
       and lfs.symlinkattributes(arg[-1], "mode") == "file" then
        return arg[-1]
    end
    return "lua"
end

describe("direct-checker target profiles", function()
    it("derives the selected target without loading the compiler driver",
       function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write(
            "#define TITAN_PROFILE_VALUE 0xffffffffU\n"))
        assert(file:close())

        local command = shell_command({
            lua_executable(),
            "spec/support/direct_checker_profile.lua",
            header,
        })
        local pipe = assert(io.popen(command .. " 2>&1", "r"))
        local output = assert(pipe:read("*a"))
        local ok, why, status = pipe:close()
        os.remove(header)

        assert.truthy(ok,
            ("%s (%s %s)"):format(output, tostring(why), tostring(status)))
        assert.matches("direct%-checker%-profile%-ok", output)
    end)

    it("preserves explicit checker-only C language flags", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write(
            "#define TITAN_PROFILE_VALUE 0xffffffffU\n"))
        assert(file:close())

        local ok, failure = xpcall(function()
            for _, mode in ipairs({ "string", "false" }) do
                local command = shell_command({
                    lua_executable(),
                    "spec/support/direct_checker_profile.lua",
                    header,
                    mode,
                })
                local pipe = assert(io.popen(command .. " 2>&1", "r"))
                local output = assert(pipe:read("*a"))
                local succeeded, why, status = pipe:close()
                assert.truthy(succeeded,
                    ("%s (%s %s)"):format(
                        output, tostring(why), tostring(status)))
                assert.matches(
                    "direct%-checker%-language%-flag%-" ..
                        mode .. "%-ok",
                    output)
            end
        end, debug.traceback)

        os.remove(header)
        assert.truthy(ok, failure)
    end)

    it("parses headers with an injected service's exact toolchain",
       function()
        local checker = require "titan-compiler.checker"
        local parser = require "titan-compiler.parser"
        local cprobe = require "titan-compiler.cprobe"
        local driver = require "titan-compiler.driver"

        local context = driver.new_resolver_context()
        local configured, configure_error =
            driver.configure_foreign_c(context)
        assert.truthy(configured, configure_error)
        local base = assert(driver.toolchain_descriptor(context))
        local injected = {}
        for key, value in pairs(base) do injected[key] = value end
        injected.compile_flags = {}
        for _, flag in ipairs(base.compile_flags) do
            injected.compile_flags[#injected.compile_flags + 1] = flag
        end
        injected.compile_flags[#injected.compile_flags + 1] =
            "-DTITAN_INJECTED_PROFILE=2"
        local service = assert(cprobe.new_service({
            toolchain = injected,
            runner = cdriver.capture_command,
        }))

        local global = {}
        for key, value in pairs(base) do global[key] = value end
        global.compile_flags = {}
        for _, flag in ipairs(base.compile_flags) do
            global.compile_flags[#global.compile_flags + 1] = flag
        end
        global.compile_flags[#global.compile_flags + 1] =
            "-DTITAN_INJECTED_PROFILE=1"
        checker.configure_foreign_c({
            compiler = global.compiler_argv,
            compile_flags = global.compile_flags,
            language_mode = global.language_mode,
            language_flag = global.language_flag,
            cppflags = global.cppflags,
            compiler_include_dirs = global.include_dirs,
            profile = global.profile,
            toolchain = global,
        })

        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write([[
            #if TITAN_INJECTED_PROFILE == 2
            #define TITAN_SELECTED_VALUE 0xffffffffU
            #else
            #define TITAN_SELECTED_VALUE 1
            #endif
        ]]))
        assert(file:close())

        local ok, failure = xpcall(function()
            local code =
                'local c = foreign import "' .. header .. '"\n'
            local ast, parse_error =
                parser.parse("injected_profile.titan", code)
            assert(ast, parse_error)
            local _, errors = checker.check(
                "injected_profile", ast, code,
                "injected_profile.titan", nil, {
                    probe_service_provider =
                        function() return service end,
                })
            assert.equal(0, #errors, table.concat(errors, "\n"))
            local selected =
                assert(ast[1]._type.members.TITAN_SELECTED_VALUE)
            assert.equal("unsigned int", selected.type.spelling)
            assert.equal(32, selected.type.bits)
        end, debug.traceback)

        os.remove(header)
        local closed, close_error = service:close()
        local restored, restore_error =
            driver.configure_foreign_c(context)
        local context_closed, context_close_error =
            driver.close_resolver_context(context)
        assert(closed, close_error)
        assert(restored, restore_error)
        assert(context_closed, context_close_error)
        assert.truthy(ok, failure)
    end)
end)
