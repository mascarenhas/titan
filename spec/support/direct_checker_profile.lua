package.path = "./?.lua;./?/init.lua;" .. package.path

assert(package.loaded["titan-compiler.driver"] == nil,
    "compiler driver was loaded before direct-checker test")

local parser = require "titan-compiler.parser"
local checker = require "titan-compiler.checker"
local cprobe = require "titan-compiler.cprobe"
local cdriver = require "c-parser.cdriver"

assert(package.loaded["titan-compiler.driver"] == nil,
    "requiring the checker loaded the compiler driver")

local language_flag_mode = arg[2]
local check_language_flag = language_flag_mode ~= nil
local expected_language_flag
local compile_flags = {}
if language_flag_mode == "string" then
    expected_language_flag = "-std=c99"
    compile_flags[1] = "-DTITAN_DIRECT_LANGUAGE_FLAG=1"
elseif language_flag_mode == "false" then
    expected_language_flag = false
elseif language_flag_mode ~= nil then
    error("unknown language-flag mode: " .. tostring(language_flag_mode))
end

local original_target_profile_inputs = cdriver.target_profile_inputs
local target_profile_checks = 0
if check_language_flag then
    cdriver.target_profile_inputs = function(options)
        target_profile_checks = target_profile_checks + 1
        assert(options.language_flag == expected_language_flag,
            "direct checker did not preserve the explicit language flag "
                .. "for target-profile acquisition")
        return original_target_profile_inputs(options)
    end
    checker.configure_foreign_c({
        compiler = os.getenv("CC") or "cc",
        compile_flags = compile_flags,
        language_mode = "c99",
        language_flag = expected_language_flag,
    })
end

local original_new_service = cprobe.new_service
local close_calls = 0
local service_language_flag_checks = 0
cprobe.new_service = function(options)
    if check_language_flag then
        service_language_flag_checks =
            service_language_flag_checks + 1
        assert(options.toolchain.language_flag == expected_language_flag,
            "direct checker did not preserve the explicit language flag "
                .. "for its probe service")
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
local code = 'local c = foreign import "' .. header .. '"\n'
local ast, parse_error =
    parser.parse("direct_checker_profile.titan", code)
assert(ast, parse_error)
local _, errors = checker.check(
    "direct_checker_profile", ast, code,
    "direct_checker_profile.titan")
cprobe.new_service = original_new_service
cdriver.target_profile_inputs = original_target_profile_inputs

assert(#errors == 0, table.concat(errors, "\n"))
local constant = assert(ast[1]._type.members.TITAN_PROFILE_VALUE)
assert(constant.type.spelling == "unsigned int",
    tostring(constant.type.spelling))
assert(constant.type.bits == 32, tostring(constant.type.bits))
assert(close_calls == 1,
    "direct checker did not close its owned probe service exactly once")
if check_language_flag then
    assert(target_profile_checks == 1,
        "direct checker did not acquire exactly one target profile")
    assert(service_language_flag_checks == 1,
        "direct checker did not create exactly one checked probe service")
end
assert(package.loaded["titan-compiler.driver"] == nil,
    "direct-checker run loaded the compiler driver")
if check_language_flag then
    print("direct-checker-language-flag-" ..
        language_flag_mode .. "-ok")
else
    print("direct-checker-profile-ok")
end
