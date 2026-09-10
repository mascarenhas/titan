package.path = "./?.lua;./?/init.lua;" .. package.path

assert(package.loaded["titan-compiler.driver"] == nil,
    "compiler driver was loaded before direct-checker test")

local parser = require "titan-compiler.parser"
local checker = require "titan-compiler.checker"
local cprobe = require "titan-compiler.cprobe"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"

assert(package.loaded["titan-compiler.driver"] == nil,
    "requiring the checker loaded the compiler driver")

local language_flag_mode = arg[2]
local check_language_flag = language_flag_mode ~= nil
    and language_flag_mode ~= "io"
    and language_flag_mode ~= "toolchain-io"
local check_io_strategy = language_flag_mode == "io"
    or language_flag_mode == "toolchain-io"
local expected_language_flag
local expected_io_strategy
local compile_flags = {}
if language_flag_mode == "string" then
    expected_language_flag = "-std=c99"
    compile_flags[1] = "-DTITAN_DIRECT_LANGUAGE_FLAG=1"
elseif language_flag_mode == "false" then
    expected_language_flag = false
elseif language_flag_mode == "io" or
       language_flag_mode == "toolchain-io" then
    expected_io_strategy = compiler_io.new_sync()
elseif language_flag_mode ~= nil then
    error("unknown language-flag mode: " .. tostring(language_flag_mode))
end

local original_target_profile_inputs = cdriver.target_profile_inputs
local target_profile_checks = 0
if check_language_flag or check_io_strategy then
    cdriver.target_profile_inputs = function(options)
        target_profile_checks = target_profile_checks + 1
        if check_language_flag then
            assert(options.language_flag == expected_language_flag,
                "direct checker did not preserve the explicit language flag "
                    .. "for target-profile acquisition")
        end
        if check_io_strategy then
            assert(options.io == expected_io_strategy,
                "direct checker did not preserve the configured compiler " ..
                    "I/O strategy for target-profile acquisition")
        end
        return original_target_profile_inputs(options)
    end
    local configured = {
        compiler = os.getenv("CC") or "cc",
        compile_flags = compile_flags,
        language_mode = "c99",
        language_flag = expected_language_flag,
    }
    if language_flag_mode == "toolchain-io" then
        configured.toolchain = {
            compiler = configured.compiler,
            compile_flags = configured.compile_flags,
            language_mode = configured.language_mode,
            language_flag = configured.language_flag,
            cppflags = {},
            cflags = {},
            include_dirs = assert(cdriver.resolve_compiler_include_dirs(
                {}, expected_io_strategy)),
            io = expected_io_strategy,
        }
    else
        configured.io = expected_io_strategy
    end
    checker.configure_foreign_c(configured)
end

local original_new_service = cprobe.new_service
local close_calls = 0
local service_language_flag_checks = 0
local service_io_strategy_checks = 0
cprobe.new_service = function(options)
    if check_language_flag then
        service_language_flag_checks =
            service_language_flag_checks + 1
        assert(options.toolchain.language_flag == expected_language_flag,
            "direct checker did not preserve the explicit language flag "
                .. "for its probe service")
    end
    if check_io_strategy then
        service_io_strategy_checks = service_io_strategy_checks + 1
        assert(options.io == expected_io_strategy,
            "direct checker did not preserve the configured compiler " ..
                "I/O strategy for its probe service")
    end
    local service, err = original_new_service(options)
    if not service then return nil, err end
    local original_close = service.close
    service.close = function(self)
        close_calls = close_calls + 1
        return original_close(self)
    end
    return service
end

local header = assert(arg[1], "missing test header")
local code = "foreign import \"" .. header .. '"\n'
local ast, parse_error =
    parser.parse("direct_checker_profile.titan", code)
assert(ast, parse_error)
local _, errors = checker.check(
    "direct_checker_profile", ast, code,
    "direct_checker_profile.titan")
cprobe.new_service = original_new_service
cdriver.target_profile_inputs = original_target_profile_inputs

assert(#errors == 0, table.concat(errors, "\n"))
local constant = assert(ast._ffi_namespace._type.members.TITAN_PROFILE_VALUE)
assert(constant.type.spelling == "unsigned int",
    tostring(constant.type.spelling))
assert(constant.type.bits == 32, tostring(constant.type.bits))
assert(close_calls == 1,
    "direct checker did not close its owned probe service exactly once")
if check_language_flag or check_io_strategy then
    assert(target_profile_checks == 1,
        "direct checker did not acquire exactly one target profile")
end
if check_language_flag then
    assert(service_language_flag_checks == 1,
        "direct checker did not create exactly one checked probe service")
end
if check_io_strategy then
    assert(service_io_strategy_checks == 1,
        "direct checker did not create exactly one strategy-checked probe " ..
            "service")
end
assert(package.loaded["titan-compiler.driver"] == nil,
    "direct-checker run loaded the compiler driver")
if check_io_strategy then
    print("direct-checker-io-strategy-ok")
elseif check_language_flag then
    print("direct-checker-language-flag-" ..
        language_flag_mode .. "-ok")
else
    print("direct-checker-profile-ok")
end
