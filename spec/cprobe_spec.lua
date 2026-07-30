local cprobe = require "titan-compiler.cprobe"
local cpreamble = require "titan-compiler.cpreamble"
local csemantics = require "titan-compiler.csemantics"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local function cstruct(name)
    return types.CStruct(nil, name, nil, {}, true, false)
end

local function cpointer(name, qualifiers)
    return types.CPointer(cstruct(name), qualifiers or {})
end

local function fake_environment(run)
    local state = {
        created = 0,
        cleaned = 0,
        calls = {},
        files = {},
        writes = {},
        removes = {},
    }

    local function temp_provider()
        state.created = state.created + 1
        local workspace = {
            root = "/fake/titan probe " .. state.created,
        }

        function workspace:write(name, contents)
            state.files[name] = contents
            state.writes[#state.writes + 1] = {
                name = name,
                contents = contents,
            }
            return true
        end

        function workspace:remove(name)
            state.files[name] = nil
            state.removes[#state.removes + 1] = name
            return true
        end

        function workspace:cleanup()
            state.cleaned = state.cleaned + 1
            assert.same({}, state.files)
            return true
        end

        return workspace
    end

    local function runner(argv, metadata)
        state.calls[#state.calls + 1] = {
            argv = argv,
            metadata = metadata,
        }
        if run then
            return run(#state.calls, argv, metadata, state)
        end
        return {
            started = true,
            ok = true,
            status = 0,
            diagnostic = "",
        }
    end

    return state, runner, temp_provider
end

local function new_fake_service(options, run)
    options = options or {}
    local state, runner, temp_provider = fake_environment(run)
    options.runner = runner
    options.temp_provider = temp_provider
    local service, err = cprobe.new_service(options)
    assert(service, err)
    return service, state
end

local function temporary_directory()
    local path = assert(os.tmpname()) .. "-cprobe-spec"
    os.remove(path)
    assert(lfs.mkdir(path))
    return path
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function target_profile()
    return assert(csemantics.build_profile({
        macros = {
            __CHAR_BIT__ = "8",
            __SIZEOF_BOOL__ = "1",
            __SIZEOF_SHORT__ = "2",
            __SIZEOF_INT__ = "4",
            __SIZEOF_LONG__ = "8",
            __SIZEOF_LONG_LONG__ = "8",
            __SIZEOF_FLOAT__ = "4",
            __SIZEOF_DOUBLE__ = "8",
            __SIZEOF_LONG_DOUBLE__ = "16",
            __SCHAR_MAX__ = "127",
            __SHRT_MAX__ = "32767",
            __INT_MAX__ = "2147483647",
            __LONG_MAX__ = "9223372036854775807L",
            __LONG_LONG_MAX__ = "9223372036854775807LL",
        },
        lua_integer = "long long",
        lua_number = "double",
        size_t = "unsigned long",
        ptrdiff_t = "long",
        signed_minima = {
            ["signed char"] = "-128",
            short = "-32768",
            int = "-2147483648",
            long = "-9223372036854775808",
            ["long long"] = "-9223372036854775808",
        },
    }))
end

describe("session-scoped C probe service", function()
    it("owns a validated profile and derives its cache identity", function()
        local profile = target_profile()
        local service = new_fake_service({ profile = profile })

        assert.not_equal(profile, service.profile)
        assert.equal(profile.identity, service.profile_identity)
        assert.equal(profile.identity, service.profile.identity)
        profile.integers.int.type.bits = 7
        assert.equal(32, service.profile.integers.int.type.bits)
        assert.is_true(service:close())

        local rejected, err = cprobe.new_service({
            profile = target_profile(),
            profile_identity = "wrong identity",
        })
        assert.is_nil(rejected)
        assert.matches(
            "profile_identity disagrees with the target profile",
            err, 1, true)
    end)

    it("exposes one authoritative cdriver process context", function()
        local profile = target_profile()
        local service = new_fake_service({
            compiler_argv = { "wrapper", "configured cc" },
            compile_flags = { "--target=fake" },
            cppflags = { "-DCPP=1" },
            language_mode = "c11",
            cflags = { "-Wall" },
            include_dirs = { "/sdk/first", "/sdk/second" },
            profile = profile,
        })

        local options = assert(service:cdriver_process_options())
        assert.same({ "wrapper", "configured cc" }, options.compiler)
        assert.same({
            "--target=fake",
            "-DCPP=1",
            "-std=c11",
            "-Wall",
        }, options.compile_flags)
        assert.same({}, options.cppflags)
        assert.is_false(options.language_flag)
        assert.same({
            "/sdk/first", "/sdk/second",
        }, options.compiler_include_dirs)
        assert.same(options.compiler_include_dirs,
            options.fixed_include_dirs)
        assert.equal(profile.identity, options.profile_identity)
        assert.not_equal(service.profile, options.profile)
        assert.is_true(service:close())

        local discovered = assert(
            cdriver.resolve_compiler_include_dirs(nil))
        local default_service = new_fake_service()
        local defaults =
            assert(default_service:cdriver_process_options())
        assert.same(discovered, defaults.compiler_include_dirs)
        assert.is_true(default_service:close())

        local mixed_service = new_fake_service({
            include_dirs = {
                "/ordinary",
                { kind = "quote", path = "/quoted" },
                { kind = "system", path = "/system" },
            },
        })
        local mixed = assert(mixed_service:cdriver_process_options())
        assert.same({
            "-std=c99",
            "-I", "/ordinary",
            "-iquote", "/quoted",
            "-isystem", "/system",
        }, mixed.compile_flags)
        assert.same({}, mixed.compiler_include_dirs)
        assert.is_true(mixed_service:close())
    end)

    it("is lazy and builds exact header, declarator, and command inputs",
    function()
        local service, state = new_fake_service({
            compiler_argv = { "cache wrapper", "configured cc" },
            compile_flags = { "--target=fake-target" },
            language_mode = "c11",
            cppflags = { "-DCPP_SIDE=1" },
            cflags = { "-Wall", "-Werror" },
            include_dirs = {
                "/sdk include",
                { kind = "quote", path = "/quote headers" },
            },
        })
        local module = assert(service:module_context({
            cwd = "/project",
            source_dir = "module",
            includes = {
                {
                    original = "local.h",
                    include_kind = "quote",
                    include_name = "local.h",
                },
                {
                    original = "api.h",
                    resolved = "/usr/include/api.h",
                    include_kind = "angle",
                    include_name = "api.h",
                },
                {
                    original = "api.h",
                    resolved = "/usr/include/api.h",
                    include_kind = "angle",
                    include_name = "api.h",
                },
            },
        }))

        assert.equal(0, state.created)
        assert.equal(0, #state.calls)
        assert.equal(cpreamble.fixed_prefix .. "\n\n" .. [[
#include "/project/module/local.h"
#include <api.h>
#include <api.h>

]] .. cpreamble.after_foreign_imports, module.header_preamble)

        local result = module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))

        assert.equal("success", result.status)
        assert.is_true(result.ok)
        assert.is_true(result.accepted)
        assert.is_false(result.cached)
        assert.equal(1, state.created)
        assert.equal(2, #state.calls)
        assert.equal("baseline", state.calls[1].metadata.stage)
        assert.equal("candidate", state.calls[2].metadata.stage)
        assert.same({
            "cache wrapper",
            "configured cc",
            "--target=fake-target",
            "-DCPP_SIDE=1",
            "-std=c11",
            "-Wall",
            "-Werror",
            "-I",
            "/sdk include",
            "-iquote",
            "/quote headers",
            "-c",
            "/fake/titan probe 1/000001-baseline.c",
            "-o",
            "/fake/titan probe 1/000001-baseline.o",
        }, state.calls[1].argv)
        assert.same({
            "cache wrapper",
            "configured cc",
            "--target=fake-target",
            "-DCPP_SIDE=1",
            "-std=c11",
            "-Wall",
            "-Werror",
            "-I",
            "/sdk include",
            "-iquote",
            "/quote headers",
            "-c",
            "/fake/titan probe 1/000002-unsafe-object-pointer.c",
            "-o",
            "/fake/titan probe 1/000002-unsafe-object-pointer.o",
        }, state.calls[2].argv)

        local baseline_source = state.calls[1].metadata.source
        assert.truthy(baseline_source:find(
            "static TITAN_UNUSED inline int " ..
                "titan_errfunc_is_errorhandler",
            1, true))
        assert.matches([[
#include "/project/module/local%.h"
#include <api%.h>
#include <api%.h>]], baseline_source)
        assert.matches(
            "void titan_probe_b_%x+%(void%) {\n    %(void%)0;\n}",
            baseline_source)

        local candidate_source = state.calls[2].metadata.source
        local source_name = assert(candidate_source:match(
            "extern struct source_s %*(titan_probe_s_%x+);"))
        local target_name = assert(candidate_source:match(
            "struct target_s %*(titan_probe_t_%x+) ="))
        local function_name = assert(candidate_source:match(
            "void (titan_probe_f_%x+)%(void%);"))
        assert.matches(
            "void " .. function_name .. "%(void%) {",
            candidate_source)
        assert.matches(
            "%(struct target_s %*%)" .. source_name .. ";",
            candidate_source)
        assert.matches(
            "%(void%)" .. target_name .. ";",
            candidate_source)

        assert.same({}, state.files)
        assert.same({}, service.evidence)
        assert.is_true(service:close())
        assert.equal(1, state.cleaned)
        assert.is_true(service:close())
        assert.equal(1, state.cleaned)
    end)

    it("caches successful and rejected candidates separately from baselines",
    function()
        local candidate_count = 0
        local service, state = new_fake_service({}, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            candidate_count = candidate_count + 1
            if candidate_count == 1 then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "probe.c:9: error: rejected candidate\nmore detail",
            }
        end)
        local module = assert(service:module_context())
        local source = cpointer("source_s")
        local accepted_target = cpointer("accepted_s")
        local rejected_target = cpointer("rejected_s")

        local first = module:probe_unsafe_object_pointer(
            source, accepted_target)
        local cached_first = module:probe_unsafe_object_pointer(
            source, accepted_target)
        local rejected = module:probe_unsafe_object_pointer(
            source, rejected_target)
        local cached_rejected = module:probe_unsafe_object_pointer(
            source, rejected_target)

        assert.equal("success", first.status)
        assert.is_false(first.cached)
        assert.equal("success", cached_first.status)
        assert.is_true(cached_first.cached)
        assert.equal(first.key, cached_first.key)
        assert.equal("rejected", rejected.status)
        assert.is_false(rejected.accepted)
        assert.is_true(rejected.baseline_cached)
        assert.matches("configured C compiler rejected conversion", rejected.message)
        assert.matches("rejected candidate", rejected.message)
        assert.equal("rejected", cached_rejected.status)
        assert.is_true(cached_rejected.cached)
        assert.equal(rejected.key, cached_rejected.key)
        assert.equal(3, #state.calls)
        assert.equal(2, candidate_count)

        assert.is_true(service:close())
    end)

    it("renders and caches complete C operator probes", function()
        local profile = target_profile()
        local service, state = new_fake_service({
            profile = profile,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            elseif metadata.source:find(" / ", 1, true) then
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic =
                        "probe.c:7: error: rejected operator candidate",
                }
            end
            return { started = true, ok = true, status = 0 }
        end)
        local module = assert(service:module_context())
        local uchar = profile.integers["unsigned char"].type
        local uint = profile.integers["unsigned int"].type

        local add = assert(csemantics.decide_binary_operator(
            profile, "+", uchar, types.Integer()))
        local accepted = module:probe_operator(add)
        local accepted_cached = module:probe_operator(add)

        assert.equal("success", accepted.status)
        assert.is_false(accepted.cached)
        assert.equal("success", accepted_cached.status)
        assert.is_true(accepted_cached.cached)
        assert.equal(accepted.key, accepted_cached.key)
        local lhs = assert(accepted.source:match(
            "extern unsigned char (titan_probe_l_%x+);"))
        local rhs = assert(accepted.source:match(
            "extern long long (titan_probe_r_%x+);"))
        assert.matches(
            "%(void%)%(%(%(long long%)%(" .. lhs
                .. "%)%) %+ %(%(long long%)%(" .. rhs .. "%)%)%);",
            accepted.source)
        assert.matches("c%-operator%.c$",
            accepted.source_path)

        local divide = assert(csemantics.decide_binary_operator(
            profile, "/", uint, uint))
        local rejected = module:probe_operator(divide)
        local rejected_cached = module:probe_operator(divide)
        assert.equal("rejected", rejected.status)
        assert.is_false(rejected.accepted)
        assert.matches("rejected binary operator expression",
            rejected.message, 1, true)
        assert.matches("rejected operator candidate",
            rejected.message, 1, true)
        assert.equal("rejected", rejected_cached.status)
        assert.is_true(rejected_cached.cached)
        assert.not_equal(accepted.key, rejected.key)
        assert.equal(3, #state.calls)

        local pointer =
            types.CPointer(profile.integers.int.type, {"const"})
        local equality = assert(csemantics.decide_binary_operator(
            profile, "==", types.Nil(), pointer))
        local nil_probe = module:probe_operator(equality)
        assert.equal("success", nil_probe.status)
        assert.not_matches("titan_probe_l_",
            nil_probe.source)
        assert.matches(
            "%(%(const int %*%)%(0%)%) == "
                .. "%(%(const int %*%)%(titan_probe_r_%x+%)%)",
            nil_probe.source)
        assert.equal(4, #state.calls)
        assert.is_true(service:close())
    end)

    it("keeps baseline infrastructure failure distinct and separately cached",
    function()
        local service, state = new_fake_service({}, function(_, _, metadata)
            assert.equal("baseline", metadata.stage)
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "broken.h:3: error: unknown type name 'broken'\nfull",
            }
        end)
        local module = assert(service:module_context({
            includes = { "broken.h" },
        }))

        local first = module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        local second = module:probe_unsafe_object_pointer(
            cpointer("other_source_s"), cpointer("other_target_s"))

        assert.equal("infrastructure_failure", first.status)
        assert.equal("baseline", first.stage)
        assert.is_nil(first.accepted)
        assert.matches("foreign header baseline failed", first.message)
        assert.matches("broken%.h:3", first.message)
        assert.equal("infrastructure_failure", second.status)
        assert.is_true(second.baseline_cached)
        assert.not_equal(first.key, second.key)
        assert.equal(1, #state.calls)
        assert.is_true(service:close())

        local rejection_service = new_fake_service({},
            function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = "candidate.c:8: error: candidate only",
                }
            end)
        local rejection_module =
            assert(rejection_service:module_context({
                includes = { "working.h" },
            }))
        local rejection =
            rejection_module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))
        assert.equal("rejected", rejection.status)
        assert.equal("compiler_rejection", rejection.reason)
        assert.is_false(rejection.accepted)
        assert.is_true(rejection_service:close())
    end)

    it("validates the final ordered header baseline directly", function()
        local success_service, success_state = new_fake_service()
        local success_module = assert(success_service:module_context({
            includes = { "first.h", "second.h" },
        }))
        local success = success_module:validate_baseline()
        local success_cached = success_module:validate_baseline()
        assert.equal("success", success.status)
        assert.is_true(success.accepted)
        assert.is_true(success_cached.cached)
        assert.equal(1, #success_state.calls)
        assert.is_true(success_service:close())

        local rejection_service, rejection_state =
            new_fake_service({}, function()
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic =
                        "second.h:4: error: conflicting declarations",
                }
            end)
        local rejection_module =
            assert(rejection_service:module_context({
                includes = { "first.h", "second.h" },
            }))
        local rejection = rejection_module:validate_baseline()
        local rejection_cached = rejection_module:validate_baseline()
        assert.equal("rejected", rejection.status)
        assert.equal("compiler_rejection", rejection.reason)
        assert.is_false(rejection.accepted)
        assert.matches(
            "rejected the final ordered foreign header context",
            rejection.message, 1, true)
        assert.is_true(rejection_cached.cached)
        assert.equal(1, #rejection_state.calls)
        assert.is_true(rejection_service:close())

        local infrastructure_service, infrastructure_state =
            new_fake_service({}, function()
                return nil, "configured compiler is unavailable"
            end)
        local infrastructure_module =
            assert(infrastructure_service:module_context())
        local infrastructure =
            infrastructure_module:validate_baseline()
        local retried = infrastructure_module:validate_baseline()
        assert.equal("infrastructure_failure", infrastructure.status)
        assert.is_nil(infrastructure.accepted)
        assert.matches(
            "probe infrastructure failed",
            infrastructure.message, 1, true)
        assert.equal("infrastructure_failure", retried.status)
        assert.equal(2, #infrastructure_state.calls)
        assert.is_true(infrastructure_service:close())
    end)

    it("validates and caches exact C declaration pairs", function()
        local service, state = new_fake_service({}, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            elseif metadata.source:find(
                "ffi_incompatible_alias", 1, true) then
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic =
                        "probe.c:4: error: conflicting types for probe",
                }
            end
            return { started = true, ok = true, status = 0 }
        end)
        local module = assert(service:module_context({
            includes = { "declarations.h" },
        }))
        local left = types.CTypedef(
            "ffi_left_alias", cstruct("left_record"))
        local right = types.CTypedef(
            "ffi_right_alias", cstruct("right_record"))
        local incompatible = types.CTypedef(
            "ffi_incompatible_alias", cstruct("other_record"))

        local accepted = module:validate_declaration_compatibility(
            left, right, { qualifiers = { "const" } },
            { qualifiers = { "const" } })
        local accepted_cached =
            module:validate_declaration_compatibility(
                left, right, { qualifiers = { "const" } },
                { qualifiers = { "const" } })
        local rejected = module:validate_declaration_compatibility(
            left, incompatible)
        local rejected_cached =
            module:validate_declaration_compatibility(
                left, incompatible)

        assert.equal("success", accepted.status)
        assert.is_false(accepted.cached)
        assert.is_false(accepted.baseline_cached)
        local declaration_name = assert(accepted.source:match(
            "extern const ffi_left_alias (titan_probe_d_%x+);"))
        assert.matches(
            "extern const ffi_right_alias "
                .. declaration_name .. ";",
            accepted.source, 1, true)
        assert.equal("success", accepted_cached.status)
        assert.is_true(accepted_cached.cached)
        assert.equal(accepted.key, accepted_cached.key)

        assert.equal("rejected", rejected.status)
        assert.is_false(rejected.accepted)
        assert.matches(
            "rejected the declaration compatibility candidate",
            rejected.message, 1, true)
        assert.matches("conflicting types", rejected.message, 1, true)
        assert.equal("rejected", rejected_cached.status)
        assert.is_true(rejected_cached.cached)
        assert.equal(rejected.key, rejected_cached.key)
        assert.equal(3, #state.calls)
        assert.is_true(service:close())
    end)

    it("submits symbolic array bounds to the configured compiler", function()
        local service, state = new_fake_service()
        local module = assert(service:module_context({
            includes = { "symbolic-bounds.h" },
        }))
        local int = target_profile().integers.int.type
        local symbolic = types.CArray(int, {
            "FFI_BOUND",
            1,
            op = "+",
        })
        local numeric = types.CArray(int, 4)

        local accepted = module:validate_declaration_compatibility(
            symbolic, numeric)
        local accepted_cached =
            module:validate_declaration_compatibility(symbolic, numeric)

        assert.equal("success", accepted.status)
        assert.is_true(accepted.accepted)
        assert.is_false(accepted.cached)
        local declaration_name = assert(accepted.source:match(
            "extern int (titan_probe_d_%x+)%[%("
                .. "FFI_BOUND %+ 1%)%];"))
        assert.matches(
            "extern int " .. declaration_name .. "%[4%];",
            accepted.source)
        assert.equal("success", accepted_cached.status)
        assert.is_true(accepted_cached.cached)
        assert.equal(accepted.key, accepted_cached.key)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())
    end)

    it("conservatively rejects unspellable anonymous declaration pairs",
    function()
        local service, state = new_fake_service()
        local module = assert(service:module_context())
        local anonymous = types.CStruct(nil, nil, nil, {}, true, false)
        local result = module:validate_declaration_compatibility(
            anonymous, anonymous)
        assert.equal("rejected", result.status)
        assert.equal("unrenderable_declaration", result.reason)
        assert.matches(
            "cannot render anonymous C struct without a typedef",
            result.message, 1, true)
        assert.equal(0, #state.calls)
        assert.is_true(service:close())
    end)

    it("does not turn spawn errors or interruptions into rejections",
    function()
        local baseline_service, baseline_state = new_fake_service({},
            function()
                return nil, "configured compiler executable was not found"
            end)
        local baseline_module = assert(baseline_service:module_context())
        local baseline_failure =
            baseline_module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", baseline_failure.status)
        assert.equal("baseline", baseline_failure.stage)
        assert.matches("could not be started", baseline_failure.message)
        assert.matches("not found", baseline_failure.diagnostic)
        assert.equal(1, #baseline_state.calls)
        assert.same({}, baseline_state.files)
        assert.is_true(baseline_service:close())

        local candidate_service, candidate_state = new_fake_service({},
            function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                error("runner exploded")
            end)
        local candidate_module = assert(candidate_service:module_context())
        local candidate_failure =
            candidate_module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", candidate_failure.status)
        assert.equal("spawn", candidate_failure.reason)
        assert.matches("runner exploded", candidate_failure.diagnostic)
        -- Infrastructure failures are retried; they are never negative-cache
        -- entries. The already-valid baseline remains cached.
        candidate_module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.equal(3, #candidate_state.calls)
        assert.same({}, candidate_state.files)
        assert.is_true(candidate_service:close())

        local interrupted_service = new_fake_service({},
            function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    interrupted = true,
                    status = 2,
                    diagnostic = "terminated by signal",
                }
            end)
        local interrupted_module = assert(interrupted_service:module_context())
        local interrupted =
            interrupted_module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", interrupted.status)
        assert.equal("interrupted", interrupted.reason)
        assert.matches("interrupted", interrupted.message)
        assert.is_true(interrupted_service:close())
    end)

    it("retries a real shell-signalled compiler instead of caching it",
    function()
        local service, state = new_fake_service({},
            function()
                return cdriver.capture_command({
                    "/bin/sh", "-c", "kill -TERM $$",
                })
            end)
        local module = assert(service:module_context())
        local source = cpointer("source_s")
        local target = cpointer("target_s")

        local first =
            module:probe_unsafe_object_pointer(source, target)
        local second =
            module:probe_unsafe_object_pointer(source, target)

        assert.equal("infrastructure_failure", first.status)
        assert.equal("baseline", first.stage)
        assert.is_true(first.interrupted)
        assert.matches("interrupted", first.message)
        assert.equal("infrastructure_failure", second.status)
        assert.is_true(second.interrupted)
        assert.is_false(second.baseline_cached)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())
    end)

    it("uses portable private-object compilation by default", function()
        local root = temporary_directory()
        local fake_compiler = root .. "/fake-compiler.sh"
        write_file(fake_compiler, [[
seen_compile=false
for argument do
    case "$argument" in
        -fsyntax-only) exit 97 ;;
        -c) seen_compile=true ;;
    esac
done
test "$seen_compile" = true || exit 98
exit 0
]])

        local service = assert(cprobe.new_service({
            compiler_argv = { "/bin/sh", fake_compiler },
        }))
        local module = assert(service:module_context())
        local result = module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))

        assert.equal("success", result.status, result.message)
        local saw_compile, saw_output, saw_syntax_only = false, false, false
        for _, argument in ipairs(result.argv) do
            saw_compile = saw_compile or argument == "-c"
            saw_output = saw_output or argument == "-o"
            saw_syntax_only =
                saw_syntax_only or argument == "-fsyntax-only"
        end
        assert.is_true(saw_compile)
        assert.is_true(saw_output)
        assert.is_false(saw_syntax_only)
        assert.is_true(service:close())
        assert(os.remove(fake_compiler))
        assert(lfs.rmdir(root))
    end)

    it("removes source and object artifacts on every runner outcome",
    function()
        local cases = {
            {
                name = "success",
                result = { started = true, ok = true, status = 0 },
                expected = "success",
            },
            {
                name = "rejection",
                result = {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = "rejected",
                },
                expected = "rejected",
            },
            {
                name = "spawn",
                result = {
                    started = false,
                    ok = false,
                    diagnostic = "not started",
                },
                expected = "infrastructure_failure",
            },
            {
                name = "interruption",
                result = {
                    started = true,
                    ok = false,
                    interrupted = true,
                    diagnostic = "interrupted",
                },
                expected = "infrastructure_failure",
            },
        }

        for _, case in ipairs(cases) do
            local service, state = new_fake_service({
                syntax_only = false,
            }, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return case.result
            end)
            local module = assert(service:module_context())
            local result = module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))

            assert.equal(case.expected, result.status, case.name)
            assert.same({}, state.files, case.name)
            assert.same({
                "000001-baseline.c",
                "000001-baseline.o",
                "000002-unsafe-object-pointer.c",
                "000002-unsafe-object-pointer.o",
            }, state.removes, case.name)
            assert.is_true(service:close())
            assert.equal(1, state.cleaned)
        end

        local baseline_spawn_service, baseline_spawn_state =
            new_fake_service({ syntax_only = false }, function()
                return nil, "spawn failed"
            end)
        local baseline_spawn_module =
            assert(baseline_spawn_service:module_context())
        local result = baseline_spawn_module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", result.status)
        assert.same({
            "000001-baseline.c",
            "000001-baseline.o",
        }, baseline_spawn_state.removes)
        assert.same({}, baseline_spawn_state.files)
        assert.is_true(baseline_spawn_service:close())
    end)

    it("reports injected workspace and cleanup failures as infrastructure",
    function()
        local service = assert(cprobe.new_service({
            runner = function()
                error("runner must not be reached")
            end,
            temp_provider = function()
                return nil, "no private temporary directory"
            end,
        }))
        local module = assert(service:module_context())
        local result = module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", result.status)
        assert.equal("baseline", result.stage)
        assert.matches("no private temporary directory", result.diagnostic)
        assert.is_true(service:close())

        local cleanup_called = 0
        local write_failure_service = assert(cprobe.new_service({
            runner = function()
                error("runner must not be reached")
            end,
            temp_provider = function()
                return {
                    root = "/fake/write-error",
                    write = function()
                        error("disk vanished")
                    end,
                    remove = function() return true end,
                    cleanup = function()
                        cleanup_called = cleanup_called + 1
                        return nil, "cleanup also failed"
                    end,
                }
            end,
        }))
        local write_failure_module =
            assert(write_failure_service:module_context())
        local write_failure =
            write_failure_module:probe_unsafe_object_pointer(
                cpointer("source_s"), cpointer("target_s"))
        assert.equal("infrastructure_failure", write_failure.status)
        assert.matches("disk vanished", write_failure.diagnostic)
        local closed, close_error = write_failure_service:close()
        assert.is_nil(closed)
        assert.matches("cleanup also failed", close_error)
        assert.equal(1, cleanup_called)
        local closed_again, repeated_error = write_failure_service:close()
        assert.is_nil(closed_again)
        assert.equal(close_error, repeated_error)
        assert.equal(1, cleanup_called)
    end)

    it("keys every ordered toolchain, header-context, and type direction input",
    function()
        local function probe_key(options, context_options, source, target)
            local service = new_fake_service(options)
            local module = assert(service:module_context(context_options))
            local result = module:probe_unsafe_object_pointer(source, target)
            assert.equal("success", result.status)
            assert.is_true(service:close())
            return result.key
        end

        local source = cpointer("source_s")
        local target = cpointer("target_s")
        local base_options = {
            compiler_argv = { "wrapper", "cc" },
            language_mode = "c99",
            compile_flags = { "--target=one" },
            cppflags = { "-DFEATURE=1" },
            cflags = { "-Wall" },
            include_dirs = { "/sdk/one" },
            profile_identity = "profile-one",
        }
        local base_context = {
            cwd = "/project",
            source_dir = "module",
            includes = {
                {
                    include_kind = "angle",
                    include_name = "first.h",
                    original = "first.h",
                    resolved = "/sdk/one/first.h",
                },
                {
                    include_kind = "angle",
                    include_name = "second.h",
                    original = "second.h",
                    resolved = "/sdk/one/second.h",
                },
            },
        }
        local base = probe_key(base_options, base_context, source, target)
        assert.equal(base,
            probe_key(base_options, base_context, source, target))

        local changes = {
            {
                compiler_argv = { "cc", "wrapper" },
            },
            {
                language_mode = "gnu99",
            },
            {
                compile_flags = { "--target=two" },
            },
            {
                cppflags = { "-DFEATURE=2" },
            },
            {
                cflags = { "-Wextra" },
            },
            {
                include_dirs = { "/sdk/two" },
            },
            {
                profile_identity = "profile-two",
            },
        }
        for _, change in ipairs(changes) do
            local options = {}
            for key, value in pairs(base_options) do options[key] = value end
            for key, value in pairs(change) do options[key] = value end
            assert.not_equal(base,
                probe_key(options, base_context, source, target))
        end

        local reversed_headers = {
            cwd = base_context.cwd,
            source_dir = base_context.source_dir,
            includes = {
                base_context.includes[2],
                base_context.includes[1],
            },
        }
        assert.not_equal(base,
            probe_key(base_options, reversed_headers, source, target))
        assert.not_equal(base,
            probe_key(base_options, {
                cwd = "/project",
                source_dir = "other-module",
                includes = base_context.includes,
            }, source, target))
        assert.not_equal(base,
            probe_key(base_options, base_context, target, source))
    end)

    it("is quiet by default and emits complete structured verbose evidence",
    function()
        local quiet_service = new_fake_service({}, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "first compiler line\ncomplete second line\n",
            }
        end)
        local quiet_module = assert(quiet_service:module_context())
        quiet_module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.same({}, quiet_service.evidence)
        assert.is_true(quiet_service:close())

        local events = {}
        local service, state = new_fake_service({
            verbose = true,
            verbose_sink = function(event)
                events[#events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "first compiler line\ncomplete second line\n",
            }
        end)
        local module = assert(service:module_context())
        local result = module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))

        assert.equal("first compiler line", result.summary)
        assert.equal(
            "first compiler line\ncomplete second line\n",
            result.diagnostic)
        local saw_command
        local saw_source
        local saw_complete_diagnostic
        local saw_cache_hit
        for _, event in ipairs(events) do
            if event.kind == "command" and event.stage == "candidate" then
                saw_command = event
            elseif event.kind == "source" and event.stage == "candidate" then
                saw_source = event
            elseif event.kind == "result" and event.stage == "candidate"
            and event.diagnostic ==
                "first compiler line\ncomplete second line\n" then
                saw_complete_diagnostic = true
            elseif event.kind == "cache" and event.cache == "candidate"
            and event.hit then
                saw_cache_hit = true
            end
        end
        assert.is_table(saw_command)
        assert.matches("^env LANG=C LC_ALL=C ", saw_command.command)
        assert.same(state.calls[2].argv, saw_command.argv)
        assert.is_table(saw_source)
        assert.matches("extern struct source_s %*titan_probe_s_%x+;",
            saw_source.source)
        assert.is_true(saw_complete_diagnostic)
        assert.is_true(saw_cache_hit)
        assert.same(events, service.evidence)
        assert.is_true(service:close())
    end)

    it("uses probe-private identifiers through the real C compiler",
    function()
        local root = temporary_directory()
        local success_header = root .. "/success.h"
        local rejection_header = root .. "/rejection.h"
        write_file(success_header, [[
struct titan_probe_source_s { int value; };
struct titan_probe_target_s { int value; };
]])
        write_file(rejection_header, [[
struct titan_probe_source_s { int value; };
struct titan_probe_target_s { int value; };
#define titan_probe_source +
#define titan_probe +
]])

        local service = assert(cprobe.new_service({
            -- Resolve past a checkout/user ccache shim: this integration
            -- exercises cprobe itself and must not depend on ccache's chosen
            -- cache directory being writable inside a test sandbox.
            compiler_argv = lfs.attributes("/usr/bin/cc", "mode")
                and { "/usr/bin/cc" } or (os.getenv("CC") or "cc"),
            cflags = { "-Wall", "-Werror" },
        }))
        local source = cpointer("titan_probe_source_s")
        local target = cpointer("titan_probe_target_s")
        local success_module = assert(service:module_context({
            source_dir = root,
            includes = {
                {
                    original = "success.h",
                    resolved = success_header,
                    include_kind = "quote",
                    include_name = "success.h",
                },
            },
        }))
        local rejection_module = assert(service:module_context({
            source_dir = root,
            includes = {
                {
                    original = "rejection.h",
                    resolved = rejection_header,
                    include_kind = "quote",
                    include_name = "rejection.h",
                },
            },
        }))

        local success =
            success_module:probe_unsafe_object_pointer(source, target)
        local rejection =
            rejection_module:probe_unsafe_object_pointer(source, target)

        assert.equal("success", success.status, success.message)
        assert.equal("success", rejection.status, rejection.message)
        assert.is_true(service:close())
        assert.is_nil(lfs.attributes(success.source_path))
        assert.is_nil(lfs.attributes(rejection.source_path))

        os.remove(success_header)
        os.remove(rejection_header)
        assert(lfs.rmdir(root))
    end)
end)
