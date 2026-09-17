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

local function direct_checker_command(header, mode)
    local driver = require "titan-compiler.driver"
    local context = driver.new_resolver_context()
    local argv = {
        lua_executable(),
        lfs.currentdir() .. "/spec/support/direct_checker_profile.lua",
        header, mode or "", lfs.currentdir(),
    }
    for _, directory in ipairs(driver.foreign_include_dirs()) do
        argv[#argv + 1] = directory
    end
    assert(driver.close_resolver_context(context))
    return shell_command(argv)
end

local function native_target_profile()
    local driver = require "titan-compiler.driver"
    local context = driver.new_resolver_context()
    local profile, err = driver.get_target_profile(context)
    assert(driver.close_resolver_context(context))
    return assert(profile, err)
end

local function check_profile_source(code, options, body)
    local parser = require "titan-compiler.parser"
    local checker = require "titan-compiler.checker"
    local types = require "titan-compiler.types"
    local previous_registry = types.registry
    types.registry = {}
    local ran, failure = xpcall(function()
        local ast = assert(parser.parse("profile_only.titan", code))
        local _, errors = checker.check(
            "profile_only", ast, code, "profile_only.titan", nil, options)
        body(ast, errors)
    end, debug.traceback)
    types.registry = previous_registry
    assert.truthy(ran, failure)
end

describe("direct-checker target profiles", function()
    it("checks contextual scalars and callback results with only a semantic profile",
    function()
        local profile = native_target_profile()
        local profile_calls = 0
        local probe_calls = 0
        check_profile_source([[
            function identity(number: foreign int): foreign int return number end
            function answer(callback: foreign function (*lua_State): int): integer
                return callback(L)
            end
        ]], {
            target_profile_provider = function()
                profile_calls = profile_calls + 1
                return profile
            end,
            probe_service_provider = function()
                probe_calls = probe_calls + 1
                return nil, "unexpected native probe"
            end,
        }, function(ast, errors)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            assert.equal(1, profile_calls)
            assert.equal(0, probe_calls)
            local integer = ast[1].params[1]._type
            assert.equal(profile.identity, integer._c_numeric_carriers.identity)
            assert.same(profile.integers.int.type._c_numeric,
                integer._c_numeric)
            assert.not_equal(profile.integers.int.type, integer)
            local result = ast[2].block.stats[1].exps[1]
            assert.equal("c_integer_to_integer", result._adjustment.coercion.op)
            assert.equal(profile.identity,
                result.exp._c_pointer_call.ret._c_numeric_carriers.identity)
        end)
    end)

    it("reports an unavailable semantic profile without a native fallback",
    function()
        local profile_calls = 0
        local probe_calls = 0
        check_profile_source([[
            function identity(number: foreign int): foreign int return number end
        ]], {
            target_profile_provider = function()
                profile_calls = profile_calls + 1
                return nil, "fixture semantic profile unavailable"
            end,
            probe_service_provider = function()
                probe_calls = probe_calls + 1
                return nil, "unexpected native fallback"
            end,
        }, function(_, errors)
            assert.is_true(#errors > 0)
            assert.matches("fixture semantic profile unavailable",
                table.concat(errors, "\n"), 1, true)
            assert.equal(1, profile_calls)
            assert.equal(0, probe_calls)
        end)
    end)

    it("rejects native service disagreement before probing an operator",
    function()
        local csemantics = require "titan-compiler.csemantics"
        local types = require "titan-compiler.types"
        local native = native_target_profile()
        local semantic = types.clone_graph(native)
        semantic.floats.double.mantissa_digits =
            semantic.floats.double.mantissa_digits - 1
        semantic.identity = assert(csemantics.profile_identity(semantic))
        semantic = assert(csemantics.import_profile(
            assert(csemantics.export_profile(semantic))))
        local probe_calls = 0
        check_profile_source([[
            function add(left: foreign int, right: foreign int): foreign int
                return left + right
            end
        ]], {
            target_profile_provider = function() return semantic end,
            probe_service_provider = function()
                probe_calls = probe_calls + 1
                return { profile = native }
            end,
        }, function(_, errors)
            assert.is_true(#errors > 0)
            assert.matches(
                "native C target profile disagrees with semantic target profile",
                table.concat(errors, "\n"), 1, true)
            assert.equal(1, probe_calls)
        end)
    end)

    it("uses explicit SDK roots outside the checkout without loading the driver",
       function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write(
            "#define TITAN_PROFILE_VALUE 0xffffffffU\n"))
        assert(file:close())

        local workdir = os.tmpname()
        assert(os.remove(workdir))
        assert(lfs.mkdir(workdir))
        local command = direct_checker_command(header)
        local pipe = assert(io.popen("cd " .. assert(cdriver.shell_quote(workdir)) ..
            " && " .. command .. " 2>&1", "r"))
        local output = assert(pipe:read("*a"))
        local ok, why, status = pipe:close()
        os.remove(header)
        assert(lfs.rmdir(workdir))

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
                local command = direct_checker_command(header, mode)
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

    it("preserves checker- and toolchain-owned I/O strategies", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        assert(file:write(
            "#define TITAN_PROFILE_VALUE 0xffffffffU\n"))
        assert(file:close())

        local failure
        for _, mode in ipairs({ "io", "toolchain-io" }) do
            local command = direct_checker_command(header, mode)
            local pipe = assert(io.popen(command .. " 2>&1", "r"))
            local output = assert(pipe:read("*a"))
            local ok, why, status = pipe:close()
            if not ok then
                failure = ("%s (%s %s)"):format(
                    output, tostring(why), tostring(status))
                break
            end
            assert.matches("direct%-checker%-io%-strategy%-ok", output)
        end
        os.remove(header)

        assert.is_nil(failure, failure)
    end)

    it("forwards an injected runner to a direct checker probe service",
       function()
        local checker = require "titan-compiler.checker"
        local core = require "titan-compiler.checker.core"

        local runner = function() end
        local captured
        local service = { profile = { identity = "test-profile" } }
        local original_options = core.foreign_c_options
        local original_config_error = core.foreign_c_config_error
        local original_new_service = core.cprobe.new_service
        local ok, failure = xpcall(function()
            checker.configure_foreign_c({
                toolchain = {
                    profile = service.profile,
                    profile_identity = "runner-forwarding-profile",
                },
                probe_runner = runner,
            })
            core.cprobe.new_service = function(options)
                captured = options
                return service
            end

            assert.equal(service, core.new_direct_probe_service())
            assert.equal(runner, captured.runner)
        end, debug.traceback)

        core.cprobe.new_service = original_new_service
        checker.configure_foreign_c(
            original_options, original_config_error)
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
                "foreign import \"" .. header .. '"\n'
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
                assert(ast._ffi_namespace._type.members.TITAN_SELECTED_VALUE)
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
