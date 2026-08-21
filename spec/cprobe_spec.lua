local cprobe = require "titan-compiler.cprobe"
local cpreamble = require "titan-compiler.cpreamble"
local csemantics = require "titan-compiler.csemantics"
local sha256 = require "titan-compiler.sha256"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
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

    it("transfers tmpname and mkdir cancellation ownership to the strategy",
    function()
        local reservation = assert(os.tmpname())
        local strategy = compiler_io.new_sync()
        local ordinary_unlink = strategy.unlink
        local ordinary_mkdir = strategy.mkdir
        local unlink_owned
        local mkdir_owned

        function strategy:tmpname()
            return reservation
        end
        function strategy:unlink(path, remove_if_cancelled)
            if path == reservation then unlink_owned = remove_if_cancelled end
            return ordinary_unlink(self, path, remove_if_cancelled)
        end
        function strategy:mkdir(path, remove_if_cancelled)
            if path == reservation then mkdir_owned = remove_if_cancelled end
            return ordinary_mkdir(self, path, remove_if_cancelled)
        end

        local service, err = cprobe.new_service({
            io = strategy,
            profile = target_profile(),
        })
        assert(service, err)
        local workspace, workspace_error = service:_ensure_workspace()
        assert(workspace, workspace_error)
        assert.equal(reservation, workspace.root)
        assert.is_true(unlink_owned)
        assert.is_true(mkdir_owned)
        assert.equal("directory", lfs.attributes(reservation, "mode"))
        assert.is_true(service:close())
        assert.is_nil(lfs.symlinkattributes(reservation))
    end)

    it("propagates cancellation while releasing a probe reservation",
    function()
        local reservation = assert(os.tmpname())
        local cancellation = { kind = "simulated cancellation" }
        local strategy = compiler_io.new_sync()
        local ordinary_unlink = strategy.unlink

        function strategy:tmpname()
            return reservation
        end
        function strategy:unlink(path, remove_if_cancelled)
            assert.equal(reservation, path)
            assert.is_true(remove_if_cancelled)
            assert.is_true(ordinary_unlink(self, path, remove_if_cancelled))
            error(cancellation)
        end

        local service, err = cprobe.new_service({
            io = strategy,
            profile = target_profile(),
        })
        assert(service, err)
        local completed, reason = pcall(service._ensure_workspace, service)
        assert.is_false(completed)
        assert.equal(cancellation, reason)
        assert.is_nil(lfs.symlinkattributes(reservation))
        assert.is_true(service:close())
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

    it("batches distinct declaration pairs and deduplicates cache keys",
    function()
        local service, state = new_fake_service()
        local module = assert(service:module_context({
            includes = { "declarations.h" },
        }))
        local int = target_profile().integers.int.type
        local first = {
            left_type = types.CTypedef("ffi_batch_left_one", int),
            right_type = types.CTypedef("ffi_batch_right_one", int),
        }
        local second = {
            left_type = types.CTypedef("ffi_batch_left_two", int),
            right_type = types.CTypedef("ffi_batch_right_two", int),
        }

        local results = module:validate_declaration_compatibilities({
            first, second, first,
        })
        assert.equal(3, #results)
        assert.equal("success", results[1].status)
        assert.equal("success", results[2].status)
        assert.equal("success", results[3].status)
        assert.is_false(results[1].cached)
        assert.is_false(results[2].cached)
        assert.is_true(results[3].cached)
        -- One baseline plus one candidate compilation proves that the checker
        -- does not turn a successful group back into per-pair subprocesses.
        assert.equal(2, #state.calls)

        local source = state.calls[2].metadata.source
        for index = 1, 3 do
            assert.equal(source, results[index].source)
        end
        assert.matches(
            "void titan_probe_db_%x+%(void%);\n"
                .. "void titan_probe_db_%x+%(void%)\n%{",
            source)
        local _, block_count = source:gsub("\n    %{\n", "")
        assert.equal(2, block_count)
        assert.matches(
            '# pragma GCC diagnostic ignored "%-Wnested%-externs"',
            source)
        local first_name = assert(source:match(
            "extern ffi_batch_left_one (titan_probe_d1_%x+);"))
        local second_name = assert(source:match(
            "extern ffi_batch_left_two (titan_probe_d2_%x+);"))
        assert.not_equal(first_name, second_name)
        assert.matches(
            "extern ffi_batch_right_one " .. first_name .. ";",
            source, 1, true)
        assert.matches(
            "extern ffi_batch_right_two " .. second_name .. ";",
            source, 1, true)
        assert.is_nil(source:match("titan_probe_d3_%x+"))

        local cached = module:validate_declaration_compatibilities({
            first, second,
        })
        assert.is_true(cached[1].cached)
        assert.is_true(cached[2].cached)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())
    end)

    it("reports plural declaration API boundary and baseline failures",
    function()
        local int = target_profile().integers.int.type
        local candidate = {
            left_type = types.CTypedef("ffi_plural_left", int),
            right_type = types.CTypedef("ffi_plural_right", int),
        }

        local service = new_fake_service()
        local module = assert(service:module_context({
            includes = { "declarations.h" },
        }))
        assert.has_error(function()
            module:validate_declaration_compatibilities(false)
        end, "C declaration compatibility candidates must be an array")

        local facade = assert(
            service:validate_declaration_compatibilities(
                module, { candidate }))
        assert.equal("success", facade[1].status)
        local wrong, wrong_error =
            service:validate_declaration_compatibilities({}, { candidate })
        assert.is_nil(wrong)
        assert.matches(
            "module context does not belong to this probe service",
            wrong_error, 1, true)
        assert.is_true(service:close())

        local closed =
            module:validate_declaration_compatibilities({ candidate })
        assert.equal("infrastructure_failure", closed[1].status)
        assert.equal("closed", closed[1].reason)
        assert.matches("probe service is closed",
            closed[1].message, 1, true)

        local message_service =
            new_fake_service({}, function()
                return nil, "injected compiler launch failure"
            end)
        local message_module = assert(message_service:module_context({
            includes = { "declarations.h" },
        }))
        local message_baseline =
            message_module:validate_declaration_compatibilities({ candidate })
        assert.equal(
            "infrastructure_failure", message_baseline[1].status)
        assert.matches(
            "C declaration compatibility",
            message_baseline[1].message, 1, true)
        assert.is_true(message_service:close())

        local baseline_service = new_fake_service()
        local baseline_module = assert(baseline_service:module_context({
            includes = { "declarations.h" },
        }))
        baseline_service._ensure_baseline = function()
            return {
                status = "infrastructure_failure",
                cached = false,
                diagnostic = "injected baseline failure",
                summary = "injected baseline failure",
            }
        end
        local baseline = baseline_module:validate_declaration_compatibilities({
            candidate,
            {
                left_type = types.CTypedef("ffi_plural_second_left", int),
                right_type = types.CTypedef("ffi_plural_second_right", int),
            },
        })
        assert.equal(2, #baseline)
        for index = 1, 2 do
            assert.equal("infrastructure_failure", baseline[index].status)
            assert.equal("baseline", baseline[index].stage)
            assert.matches(
                "foreign header baseline failed",
                baseline[index].message, 1, true)
        end
        assert.is_true(baseline_service:close())
    end)

    it("isolates batch tag scopes and preserves singleton C verdicts",
    function()
        local root = temporary_directory()
        local header = root .. "/batch-types.h"
        write_file(header, [[
typedef struct { int value; } ffi_batch_anon_left;
typedef struct { int value; } ffi_batch_anon_right;
]])

        local function new_real_service()
            return assert(cprobe.new_service({
                -- Bypass a user ccache shim: this test needs only the real
                -- compiler's declaration and tag-scope verdicts.
                compiler_argv = lfs.attributes("/usr/bin/cc", "mode")
                    and { "/usr/bin/cc" }
                    or { os.getenv("CC") or "cc" },
                cflags = {
                    "-Wall", "-Werror", "-Wnested-externs",
                    "-pedantic-errors",
                },
            }))
        end

        local function module_context(service)
            return assert(service:module_context({
                source_dir = root,
                includes = {
                    {
                        original = "batch-types.h",
                        resolved = header,
                        include_kind = "quote",
                        include_name = "batch-types.h",
                    },
                },
            }))
        end

        local int = target_profile().integers.int.type
        local function scoped_tag()
            return cstruct("ffi_batch_scope_tag")
        end
        local function scoped_function()
            return types.CFunction({
                types.CPointer(scoped_tag(), {}),
            }, int, false, "cdecl")
        end
        local function anonymous_typedef(name)
            return types.CTypedef(name,
                types.CStruct(nil, nil, nil, {}, true, false))
        end
        local candidates = {
            {
                left_type = scoped_tag(),
                right_type = scoped_tag(),
            },
            {
                left_type = scoped_function(),
                right_type = scoped_function(),
            },
            {
                left_type = types.CArray(int, nil),
                right_type = types.CArray(int, 4),
            },
            {
                left_type = anonymous_typedef("ffi_batch_anon_left"),
                right_type = anonymous_typedef("ffi_batch_anon_right"),
            },
        }

        local singleton_statuses = {}
        for index, candidate in ipairs(candidates) do
            local service = new_real_service()
            local result = module_context(service)
                :validate_declaration_compatibilities({ candidate })[1]
            singleton_statuses[index] = result.status
            assert.is_true(service:close())
        end
        assert.same({
            "success", "rejected", "success", "rejected",
        }, singleton_statuses)

        local service = new_real_service()
        local results = module_context(service)
            :validate_declaration_compatibilities(candidates)
        local batch_statuses = {}
        for index, result in ipairs(results) do
            batch_statuses[index] = result.status
        end
        assert.same(singleton_statuses, batch_statuses)
        assert.is_true(service:close())

        assert(os.remove(header))
        assert(lfs.rmdir(root))
    end)

    it("bisects rejected declaration batches to singleton verdicts", function()
        local service, state = new_fake_service({}, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            elseif metadata.source:find("ffi_batch_bad", 1, true) then
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic =
                        "probe.c:9: error: rejected declaration batch",
                }
            end
            return { started = true, ok = true, status = 0 }
        end)
        local module = assert(service:module_context({
            includes = { "declarations.h" },
        }))
        local int = target_profile().integers.int.type
        local function candidate(name)
            return {
                left_type = types.CTypedef(
                    "ffi_batch_" .. name, int),
                right_type = types.CTypedef(
                    "ffi_batch_" .. name .. "_equivalent", int),
            }
        end

        local candidates = {
            candidate("first"),
            candidate("second"),
            candidate("bad"),
            candidate("fourth"),
        }
        local results =
            module:validate_declaration_compatibilities(candidates)
        assert.same({ "success", "success", "rejected", "success" }, {
            results[1].status,
            results[2].status,
            results[3].status,
            results[4].status,
        })
        assert.matches("rejected declaration batch",
            results[3].message, 1, true)
        -- baseline; rejected 4-pair batch; accepted left half; rejected right
        -- half; then the rejected and accepted singleton leaves.
        assert.equal(6, #state.calls)

        local cached =
            module:validate_declaration_compatibilities(candidates)
        assert.equal(6, #state.calls)
        for index = 1, 4 do assert.is_true(cached[index].cached) end
        assert.equal("rejected", cached[3].status)
        assert.is_true(service:close())
    end)

    it("does not bisect or cache declaration-batch infrastructure failures",
    function()
        local service, state = new_fake_service({}, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return nil, "configured compiler could not be started"
        end)
        local module = assert(service:module_context({
            includes = { "declarations.h" },
        }))
        local int = target_profile().integers.int.type
        local candidates = {}
        for index = 1, 3 do
            candidates[index] = {
                left_type = types.CTypedef(
                    "ffi_batch_infra_left_" .. index, int),
                right_type = types.CTypedef(
                    "ffi_batch_infra_right_" .. index, int),
            }
        end

        local first =
            module:validate_declaration_compatibilities(candidates)
        assert.equal(2, #state.calls)
        for index = 1, 3 do
            assert.equal("infrastructure_failure", first[index].status)
            assert.is_nil(first[index].accepted)
            assert.is_false(first[index].cached)
            assert.equal(
                state.calls[2].metadata.source, first[index].source)
        end

        local retried =
            module:validate_declaration_compatibilities(candidates)
        assert.equal(3, #state.calls)
        for index = 1, 3 do
            assert.equal("infrastructure_failure", retried[index].status)
            assert.is_false(retried[index].cached)
        end
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
        assert.is_true(service:close())
        assert.same(events, service.evidence)
        assert.equal("cleanup", events[#events].kind)
        assert.is_true(events[#events].ok)
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

describe("persistent successful C probe markers", function()
    local function entries(path)
        local out = {}
        local iterator, state = lfs.dir(path)
        if not iterator then return out end
        for name in iterator, state do
            if name ~= "." and name ~= ".." then
                out[#out + 1] = name
            end
        end
        table.sort(out)
        return out
    end

    it("partitions contexts by restattable header and search identities",
    function()
        local service = new_fake_service()
        local function context(identity)
            return assert(service:module_context({ includes = {{
                original = "public.h",
                resolved = "/headers/public.h",
                include_kind = "quote",
                include_name = "public.h",
                c_header_dependencies = {{
                    kind = "file",
                    path = "/headers/public.h",
                    identity = identity,
                }},
                c_header_search_inputs = {{
                    kind = "search",
                    path = "/earlier/public.h",
                    identity = "c-header-search-v1:lstat=missing;stat=missing",
                }},
            }}}))
        end
        local first = context("first contents")
        local second = context("second contents")
        assert.not_equal(first.header_key, second.header_key)
        assert.same({
            { kind = "file", path = "/headers/public.h",
              identity = "first contents" },
            { kind = "search", path = "/earlier/public.h",
              identity =
                "c-header-search-v1:lstat=missing;stat=missing" },
        }, first.header_inputs)
        assert.is_true(service:close())
    end)

    it("bounds retained probe keys independently of header closure size",
    function()
        local function dependencies(count, changed_last)
            local result = {}
            for index = 1, count do
                result[index] = {
                    kind = "file",
                    path = ("/headers/dependency-%04d.h"):format(index),
                    identity = ("c-header-file-v1:sha256:%064d"):format(
                        changed_last and index == count and 1 or 0),
                }
            end
            return result
        end
        local function context(service, inputs)
            return assert(service:module_context({ includes = {{
                original = "public.h",
                resolved = "/headers/public.h",
                include_kind = "quote",
                include_name = "public.h",
                c_header_dependencies = inputs,
            }}}))
        end

        local service = new_fake_service()
        local small = context(service, dependencies(1))
        local large = context(service, dependencies(2000))
        local changed = context(service, dependencies(2000, true))

        assert.matches(
            "^titan%-cprobe%-header%-context%-v2:sha256:[0-9a-f]+$",
            large.header_key)
        assert.equal(#small.header_key, #large.header_key)
        assert.equal(#small.baseline_key, #large.baseline_key)
        assert.not_equal(large.header_key, changed.header_key)
        assert.not_equal(large.baseline_key, changed.baseline_key)

        local result = large:probe_unsafe_object_pointer(
            cpointer("large_header_source"),
            cpointer("large_header_target"))
        assert.equal("success", result.status, result.message)
        local changed_result = changed:probe_unsafe_object_pointer(
            cpointer("large_header_source"),
            cpointer("large_header_target"))
        assert.equal("success", changed_result.status,
            changed_result.message)
        assert.not_equal(result.key, changed_result.key)
        assert.equal(#result.key, #changed_result.key)
        assert.is_true(#result.key < 1024)
        assert.is_true(service:close())
    end)

    it("bounds retained keys independently of forced-header manifest size",
    function()
        local small = new_fake_service()
        local small_module = assert(small:module_context())
        local small_result = small_module:probe_unsafe_object_pointer(
            cpointer("forced_source"), cpointer("forced_target"))
        assert.equal("success", small_result.status, small_result.message)

        local previous_forced_header_inputs =
            cdriver.forced_header_inputs
        cdriver.forced_header_inputs = function()
            return {
                c_header_dependencies = {},
                c_header_search_inputs = {},
                manifest = string.rep("forced-header-input;", 20000),
            }
        end
        local created, large_or_error = pcall(new_fake_service)
        cdriver.forced_header_inputs = previous_forced_header_inputs
        assert.is_true(created, large_or_error)
        local large = large_or_error
        local large_module = assert(large:module_context())
        local large_result = large_module:probe_unsafe_object_pointer(
            cpointer("forced_source"), cpointer("forced_target"))
        assert.equal("success", large_result.status, large_result.message)

        assert.matches(
            "^titan%-cprobe%-forced%-header%-context%-v2:sha256:[0-9a-f]+$",
            large.forced_header_manifest)
        assert.equal(#small.forced_header_manifest,
            #large.forced_header_manifest)
        assert.equal(#small.toolchain_key, #large.toolchain_key)
        assert.equal(#small_module.header_key, #large_module.header_key)
        assert.equal(#small_module.baseline_key, #large_module.baseline_key)
        assert.equal(#small_result.key, #large_result.key)
        assert.not_equal(small.toolchain_key, large.toolchain_key)
        assert.not_equal(small_module.header_key, large_module.header_key)
        assert.not_equal(small_module.baseline_key, large_module.baseline_key)
        assert.not_equal(small_result.key, large_result.key)
        assert.is_true(#large_result.key < 1024)

        assert.is_true(small:close())
        assert.is_true(large:close())
    end)

    it("does not reuse persistent probes after header bytes change", function()
        local cache = temporary_directory()
        local function options(identity)
            return { includes = {{
                original = "public.h",
                resolved = "/headers/public.h",
                include_kind = "quote",
                include_name = "public.h",
                c_header_dependencies = {{
                    kind = "file",
                    path = "/headers/public.h",
                    identity = identity,
                }},
            }} }
        end
        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local first_result = assert(first:module_context(
            options("before"))):validate_baseline()
        assert.equal("success", first_result.status, first_result.message)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local changed, changed_state = new_fake_service({
            cache_directory = cache,
        })
        local changed_result = assert(changed:module_context(
            options("after"))):validate_baseline()
        assert.equal("success", changed_result.status, changed_result.message)
        assert.is_false(changed_result.persistent_cached == true)
        assert.equal(1, #changed_state.calls)
        assert.is_true(changed:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("does not reuse persistent probes after a forced header changes",
    function()
        local root = temporary_directory()
        local cache = root .. "/cache"
        assert(lfs.mkdir(cache))
        local forced = root .. "/forced.h"
        write_file(forced, "#define TITAN_FORCED_PROBE 1\n")
        local compiler = lfs.attributes("/usr/bin/cc", "mode")
            and { "/usr/bin/cc" } or { os.getenv("CC") or "cc" }
        local function service()
            return assert(cprobe.new_service({
                compiler_argv = compiler,
                cppflags = { "-include", forced },
                profile = target_profile(),
                cache_directory = cache,
            }))
        end

        local source = "int titan_forced_probe;\n"
        local first = service()
        local first_result = first:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_true(first_result.ok, first_result.diagnostic)
        assert.is_false(first_result.persistent_cached == true)
        assert.is_true(first:close())

        write_file(forced, "#error forced header changed\n")
        local changed = service()
        local changed_result = changed:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_false(changed_result.ok)
        assert.is_false(changed_result.persistent_cached == true)
        assert.matches("forced header changed", changed_result.diagnostic,
            1, true)
        assert.is_true(changed:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(os.remove(forced))
        assert(lfs.rmdir(cache))
        assert(lfs.rmdir(root))
    end)

    it("publishes forced C-flag header closure into module inputs", function()
        local root = temporary_directory()
        local forced = root .. "/forced.h"
        local nested = root .. "/nested.h"
        write_file(forced, '#include "nested.h"\n')
        write_file(nested, "#define TITAN_FORCED_CFLAG 1\n")
        local compiler = lfs.attributes("/usr/bin/cc", "mode")
            and { "/usr/bin/cc" } or { os.getenv("CC") or "cc" }
        local function service()
            return assert(cprobe.new_service({
                compiler_argv = compiler,
                cflags = { "-include", "forced.h" },
                include_dirs = { root },
                profile = target_profile(),
            }))
        end

        local first = service()
        local module = assert(first:module_context())
        assert.same({ forced, nested }, {
            first.forced_header_dependencies[1].path,
            first.forced_header_dependencies[2].path,
        })
        assert.same(first.forced_header_inputs, module.header_inputs)
        local cwd = assert(lfs.currentdir())
        assert.equal(cwd .. "/forced.h",
            first.forced_header_search_inputs[1].path)
        assert.equal(forced,
            first.forced_header_search_inputs[2].path)
        local first_toolchain_key = first.toolchain_key
        assert.is_true(first:close())

        local duplicated = assert(cprobe.new_service({
            compiler_argv = compiler,
            cflags = {
                "-include", "forced.h", "-include", "forced.h",
            },
            include_dirs = { root },
            profile = target_profile(),
        }))
        assert.not_equal(first_toolchain_key, duplicated.toolchain_key)
        assert.is_true(duplicated:close())

        write_file(nested, "#define TITAN_FORCED_CFLAG 2\n")
        local changed = service()
        assert.not_equal(first_toolchain_key, changed.toolchain_key)
        assert.is_true(changed:close())

        assert(os.remove(nested))
        assert(os.remove(forced))
        assert(lfs.rmdir(root))
    end)

    it("does not publish success when a forced header changes during a probe",
    function()
        local root = temporary_directory()
        local cache = root .. "/cache"
        assert(lfs.mkdir(cache))
        local forced = root .. "/forced.h"
        write_file(forced, "#define TITAN_FORCED_RACE 1\n")
        local state, runner, temp_provider = fake_environment(function()
            write_file(forced, "#define TITAN_FORCED_RACE 2\n")
            return { started = true, ok = true, status = 0, diagnostic = "" }
        end)
        local service = assert(cprobe.new_service({
            compiler_argv = { "/usr/bin/cc" },
            cppflags = { "-include", forced },
            profile = target_profile(),
            cache_directory = cache,
            runner = runner,
            temp_provider = temp_provider,
        }))
        local result = service:module_context():validate_baseline()
        assert.equal("infrastructure_failure", result.status)
        assert.matches("forced C header input changed", result.diagnostic,
            1, true)
        assert.equal(1, #state.calls)
        assert.same({}, entries(cache))
        assert.is_true(service:close())

        assert(os.remove(forced))
        assert(lfs.rmdir(cache))
        assert(lfs.rmdir(root))
    end)

    it("restats again after locating a persistent forced-header hit",
    function()
        local root = temporary_directory()
        local cache = root .. "/cache"
        assert(lfs.mkdir(cache))
        local forced = root .. "/forced.h"
        local source = "int titan_forced_lookup_race;\n"
        write_file(forced, "#define TITAN_FORCED_LOOKUP_RACE 1\n")
        local function options()
            return {
                compiler_argv = { "/usr/bin/cc" },
                cppflags = { "-include", forced },
                profile = target_profile(),
                cache_directory = cache,
            }
        end
        local first = assert(cprobe.new_service(options()))
        assert.is_true(first:_run_source(
            "candidate", source, "same-key").ok)
        assert.is_true(first:close())

        local second = assert(cprobe.new_service(options()))
        local ordinary_lookup = second._persistent_success
        second._persistent_success = function(self, probe_source, key)
            local hit, path, digest =
                ordinary_lookup(self, probe_source, key)
            write_file(forced,
                "#define TITAN_FORCED_LOOKUP_RACE 2\n")
            return hit, path, digest
        end
        local raced = second:_run_source(
            "candidate", source, "same-key")
        assert.is_false(raced.ok)
        assert.equal("header_inputs", raced.reason)
        assert.is_false(raced.persistent_cached == true)
        assert.is_true(second:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(os.remove(forced))
        assert(lfs.rmdir(cache))
        assert(lfs.rmdir(root))
    end)

    it("does not reuse an in-memory candidate after a forced header changes",
    function()
        local root = temporary_directory()
        local forced = root .. "/forced.h"
        write_file(forced, "#define TITAN_FORCED_MEMORY 1\n")
        local service, state = new_fake_service({
            compiler_argv = { "/usr/bin/cc" },
            cppflags = { "-include", forced },
            profile = target_profile(),
        })
        local module = assert(service:module_context())
        local first = module:probe_unsafe_object_pointer(
            cpointer("forced_source"), cpointer("forced_target"))
        assert.equal("success", first.status, first.message)
        assert.equal(2, #state.calls)

        write_file(forced, "#define TITAN_FORCED_MEMORY 2\n")
        local changed = module:probe_unsafe_object_pointer(
            cpointer("forced_source"), cpointer("forced_target"))
        assert.equal("infrastructure_failure", changed.status)
        assert.equal("header_inputs", changed.reason)
        assert.is_false(changed.cached == true)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())

        assert(os.remove(forced))
        assert(lfs.rmdir(root))
    end)

    it("rejects missing forced headers without a success marker", function()
        local root = temporary_directory()
        local cache = root .. "/cache"
        assert(lfs.mkdir(cache))
        local service, err = cprobe.new_service({
            compiler_argv = { "/usr/bin/cc" },
            compile_flags = { "-include", root .. "/missing.h" },
            profile = target_profile(),
            cache_directory = cache,
            runner = function()
                error("runner must not be reached")
            end,
        })
        assert.is_nil(service)
        assert.matches("missing or unreadable", err, 1, true)
        assert.same({}, entries(cache))

        assert(lfs.rmdir(cache))
        assert(lfs.rmdir(root))
    end)

    it("keeps source-foreign generated bytes in key identity but not restat inputs",
    function()
        local physical = assert(cprobe.normalize_include_descriptor({
            original = "/tmp/provider.check.h",
            resolved = "/tmp/provider.check.h",
            include_kind = "quote",
            include_name = "/tmp/provider.check.h",
            c_header_dependencies = {
                { kind = "file", path = "/tmp/provider.check.h",
                  identity = "generated bytes" },
                { kind = "file", path = "/headers/nested.h",
                  identity = "nested bytes" },
            },
            c_header_search_inputs = {
                { kind = "search", path = "/headers/earlier.h",
                  identity = "missing candidate" },
            },
        }, { source_dir = "/tmp" }))
        local alias = assert(cprobe.source_foreign_include_alias(
            physical, "provider.module", "/project/provider.titan.h"))
        local service = new_fake_service()
        local module = assert(service:module_context({ includes = { alias } }))
        assert.same({
            { kind = "file", path = "/headers/nested.h",
              identity = "nested bytes" },
            { kind = "search", path = "/headers/earlier.h",
              identity = "missing candidate" },
        }, module.header_inputs)
        assert.matches(
            "^titan%-cprobe%-header%-context%-v2:sha256:[0-9a-f]+$",
            module.header_key)
        assert.not_matches("generated bytes", module.header_key, 1, true)
        assert.is_true(service:close())
    end)

    it("rejects invalid persistent cache configuration", function()
        local rejected, err = cprobe.new_service({
            cache_directory = false,
        })
        assert.is_nil(rejected)
        assert.matches("cache_directory must be a pathname string",
            err, 1, true)

        local previous_currentdir = lfs.currentdir
        lfs.currentdir = function()
            return nil, "injected cwd failure"
        end
        local ok, relative, relative_err = pcall(cprobe.new_service, {
            cache_directory = "relative-cache",
        })
        lfs.currentdir = previous_currentdir
        assert.is_true(ok)
        assert.is_nil(relative)
        assert.matches("cannot determine cache cwd", relative_err, 1, true)

        rejected, err = cprobe.new_service({
            cache_directory = "/tmp/titan-cprobe-validation-only",
            cache_identity = {},
        })
        assert.is_nil(rejected)
        assert.matches("cache_identity must be a string", err, 1, true)
    end)

    it("fails open when marker close or rename fails", function()
        local cache = temporary_directory()
        local service = new_fake_service({ cache_directory = cache })
        local source = "int titan_marker_publication_failure;\n"
        local path = service:_persistent_success_location(source)

        local previous_open = io.open
        io.open = function(name, mode)
            if name:match("%.tmp$") then
                return {
                    write = function() return true end,
                    close = function() return nil end,
                }
            end
            return previous_open(name, mode)
        end
        local close_ok, close_result = pcall(
            service._publish_persistent_success,
            service, path)
        io.open = previous_open
        assert.is_true(close_ok)
        assert.is_nil(close_result)
        assert.same({}, entries(cache))

        local previous_rename = os.rename
        os.rename = function()
            return nil, "injected rename failure"
        end
        local rename_ok, rename_result = pcall(
            service._publish_persistent_success,
            service, path)
        assert.is_true(rename_ok)
        assert.is_nil(rename_result)
        assert.same({}, entries(cache))

        write_file(path, "")
        local race_ok, race_result = pcall(
            service._publish_persistent_success,
            service, path)
        os.rename = previous_rename
        assert.is_true(race_ok)
        assert.is_true(race_result)
        assert.same({ path:match("([^/]+)$") }, entries(cache))

        assert.is_true(service:close())
        assert(os.remove(path))
        assert(lfs.rmdir(cache))
    end)

    it("retains only the committed marker when publication is cancelled",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local ordinary_write = strategy.write_file
        local cancellation = { kind = "simulated cancellation" }
        local publication_path
        strategy.write_file = function(self, path, contents)
            local written, err = ordinary_write(self, path, contents)
            if written and path:match("%.success$") then
                publication_path = path
                error(cancellation)
            end
            return written, err
        end

        local source = "int titan_cancelled_marker_publication;\n"
        local first, first_state = new_fake_service({
            cache_directory = cache,
            io = strategy,
        })
        local completed, reason = pcall(
            first._run_source, first, "candidate", source, "same-key")
        assert.is_false(completed)
        assert.equal(cancellation, reason)
        assert.equal(1, #first_state.calls)

        local expected_path = first:_persistent_success_location(
            source, "same-key")
        assert.equal(expected_path, publication_path)
        assert.same({ expected_path:match("([^/]+)$") }, entries(cache))
        assert.is_true(first:close())

        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("a committed marker must not invoke the compiler")
        end)
        local hit = second:_run_source("candidate", source, "same-key")
        assert.is_true(hit.ok)
        assert.is_true(hit.persistent_cached)
        assert.equal(expected_path, hit.cache_path)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())

        assert(os.remove(expected_path))
        assert(lfs.rmdir(cache))
    end)

    it("keys empty success markers by probe text and semantic context",
    function()
        local cache = temporary_directory()
        local source = "int titan_persistent_success;\n"
        local legacy = cache .. "/" .. sha256.hex(source) .. ".success"
        write_file(legacy, "legacy source-only marker")
        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local run = first:_run_source("candidate", source, "first-key")
        assert.is_true(run.ok)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local names = entries(cache)
        assert.equal(2, #names)
        assert.is_true(entries(cache)[1] == legacy:match("([^/]+)$") or
            entries(cache)[2] == legacy:match("([^/]+)$"))
        local marker_name = run.cache_path:match("([^/]+)$")
        assert.not_equal(sha256.hex(source) .. ".success", marker_name)
        local marker = assert(io.open(cache .. "/" .. marker_name, "rb"))
        assert.equal("", assert(marker:read("a")))
        assert.is_true(marker:close())
        -- Presence is the complete contract; readers never decode payload.
        write_file(cache .. "/" .. marker_name, "ignored marker payload")

        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("a persistent success must not invoke the compiler")
        end)
        local hit = second:_run_source(
            "baseline", source, "first-key")
        assert.is_true(hit.ok)
        assert.is_true(hit.persistent_cached)
        assert.equal(0, #second_state.calls)
        assert.equal(0, second_state.created)
        assert.is_true(second:close())

        local changed, changed_state = new_fake_service({
            cache_directory = cache,
        })
        local changed_run = changed:_run_source(
            "baseline", source, "a-different-semantic-key")
        assert.is_true(changed_run.ok)
        assert.is_nil(changed_run.persistent_cached)
        assert.equal(1, #changed_state.calls)
        assert.not_equal(run.cache_path, changed_run.cache_path)
        assert.is_true(changed:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("never stores compiler rejection or infrastructure failure", function()
        local cache = temporary_directory()
        local outcomes = {
            { started = true, ok = false, status = 1,
                diagnostic = "rejected" },
            { started = false, ok = false, diagnostic = "not started" },
            { started = true, ok = false, interrupted = true,
                diagnostic = "interrupted" },
        }
        for index, outcome in ipairs(outcomes) do
            local service = new_fake_service({
                cache_directory = cache,
            }, function()
                return outcome
            end)
            local run = service:_run_source("candidate",
                "int titan_failure_" .. index .. ";\n", "failure-key")
            assert.is_false(run.ok)
            assert.is_true(service:close())
        end
        assert.same({}, entries(cache))
        assert(lfs.rmdir(cache))
    end)

    it("partitions exact source bytes and optional cache namespaces", function()
        local root = temporary_directory()
        local source = "int titan_namespace;\n"
        local first = new_fake_service({
            cache_directory = root,
            cache_identity = "first configuration",
        })
        assert.is_true(first:_run_source(
            "candidate", source, "namespace-key").ok)
        assert.is_true(first:close())

        local changed, changed_state = new_fake_service({
            cache_directory = root,
            cache_identity = "first configuration",
        })
        assert.is_true(changed:_run_source("candidate",
            source .. " ", "namespace-key").ok)
        assert.equal(1, #changed_state.calls)
        assert.is_true(changed:close())

        local other, other_state = new_fake_service({
            cache_directory = root,
            cache_identity = "second configuration",
        })
        assert.is_true(other:_run_source(
            "candidate", source, "namespace-key").ok)
        assert.equal(1, #other_state.calls)
        assert.is_true(other:close())

        for _, namespace in ipairs(entries(root)) do
            for _, name in ipairs(entries(root .. "/" .. namespace)) do
                assert(os.remove(root .. "/" .. namespace .. "/" .. name))
            end
            assert(lfs.rmdir(root .. "/" .. namespace))
        end
        assert(lfs.rmdir(root))
    end)

    it("fails open when its cache path cannot be created", function()
        local root = temporary_directory()
        local blocked = root .. "/blocked"
        write_file(blocked, "ordinary file")
        local service, state = new_fake_service({
            cache_directory = blocked .. "/cache",
        })
        local run = service:_run_source(
            "candidate", "int titan_fail_open;\n", "fail-open-key")
        assert.is_true(run.ok)
        assert.equal(1, #state.calls)
        assert.is_true(service:close())
        assert(os.remove(blocked))
        assert(lfs.rmdir(root))
    end)

    it("publishes only after successful per-probe cleanup", function()
        local cache = temporary_directory()
        local state, runner, provider = fake_environment()
        local ordinary_provider = provider
        provider = function()
            local workspace = ordinary_provider()
            workspace.remove = function()
                return nil, "injected cleanup failure"
            end
            return workspace
        end
        local service = assert(cprobe.new_service({
            cache_directory = cache,
            runner = runner,
            temp_provider = provider,
        }))
        local run = service:_run_source(
            "candidate", "int titan_cleanup_failure;\n", "cleanup-key")
        assert.is_false(run.ok)
        assert.is_true(run.cleanup_error)
        assert.same({}, entries(cache))
        -- The injected provider cannot close cleanly; the semantic assertion is
        -- that it still did not publish a success marker.
        service:close()
        assert(lfs.rmdir(cache))
    end)

    it("stabilizes randomized source-foreign headers before cache lookup",
    function()
        local cache = temporary_directory()
        local function alias_for(physical)
            local include = assert(cprobe.normalize_include_descriptor({
                include_kind = "quote",
                include_name = physical,
            }, { source_dir = "." }))
            return assert(cprobe.source_foreign_include_alias(
                include, "provider.module", "/project/provider.titan.h"))
        end

        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local first_module = assert(first:module_context({
            includes = { alias_for("/tmp/provider-check-one.h") },
        }))
        local first_source = cprobe.render_baseline_source(first_module)
        local first_header_key = first_module.header_key
        local first_baseline_key = first_module.baseline_key
        local first_result = first_module:validate_baseline()
        assert.equal("success", first_result.status, first_result.message)
        local first_pointer = first_module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.equal("success", first_pointer.status, first_pointer.message)
        assert.equal(1, first_state.created)
        assert.equal(2, #first_state.calls)
        local wrapper_name = next(first_module.probe_wrappers)
        assert.matches("^titan%-source%-foreign%-[0-9a-f]+%.h$",
            wrapper_name)
        assert.equal('#include "/tmp/provider-check-one.h"\n',
            first_module.probe_wrappers[wrapper_name])
        assert.is_true(first:close())
        assert.same({}, first_state.files)

        local second, second_state = new_fake_service({
            cache_directory = cache,
        })
        local second_module = assert(second:module_context({
            includes = { alias_for("/tmp/provider-check-two.h") },
        }))
        assert.equal(first_source,
            cprobe.render_baseline_source(second_module))
        assert.equal(first_header_key, second_module.header_key)
        assert.equal(first_baseline_key, second_module.baseline_key)
        local second_result = second_module:validate_baseline()
        assert.equal("success", second_result.status, second_result.message)
        assert.is_true(second_result.persistent_cached)
        local second_pointer = second_module:probe_unsafe_object_pointer(
            cpointer("source_s"), cpointer("target_s"))
        assert.equal("success", second_pointer.status, second_pointer.message)
        assert.is_true(second_pointer.persistent_cached)
        assert.equal(first_pointer.key, second_pointer.key)
        assert.equal(0, second_state.created)
        assert.equal(0, #second_state.calls)
        assert.same({}, second_state.writes)
        assert.is_true(second:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("rejects conflicting bindings for one stable probe-header wrapper",
    function()
        local physical = assert(cprobe.normalize_include_descriptor({
            include_kind = "quote",
            include_name = "/tmp/provider-check.h",
        }, { source_dir = "." }))
        local invalid, invalid_error = cprobe.source_foreign_include_alias(
            {}, "provider", "/project/provider.titan.h")
        assert.is_nil(invalid)
        assert.matches("requires a normalized include", invalid_error)
        local angle = assert(cprobe.normalize_include_descriptor({
            include_kind = "angle",
            include_name = "provider-check.h",
        }))
        invalid, invalid_error = cprobe.source_foreign_include_alias(
            angle, "provider", "/project/provider.titan.h")
        assert.is_nil(invalid)
        assert.matches("requires an absolute quoted physical include",
            invalid_error)
        invalid, invalid_error = cprobe.source_foreign_include_alias(
            physical, "", "/project/provider.titan.h")
        assert.is_nil(invalid)
        assert.matches("requires a module name", invalid_error)
        invalid, invalid_error = cprobe.source_foreign_include_alias(
            physical, "provider", "")
        assert.is_nil(invalid)
        assert.matches("requires an absolute public header path",
            invalid_error)

        local unsafe, unsafe_error = cprobe.normalize_include_descriptor({
            original = "provider",
            resolved = "/project/provider.titan.h",
            include_kind = "quote",
            include_name = "../outside.h",
            probe_wrapper = {
                name = "../outside.h",
                contents = '#include "/tmp/provider-check.h"\n',
            },
        })
        assert.is_nil(unsafe)
        assert.matches("invalid private probe%-header wrapper descriptor",
            unsafe_error)

        local service = new_fake_service()
        local function alias_for(physical)
            local include = assert(cprobe.normalize_include_descriptor({
                include_kind = "quote",
                include_name = physical,
            }, { source_dir = "." }))
            return assert(cprobe.source_foreign_include_alias(
                include, "provider", "/project/provider.titan.h"))
        end
        assert(service:module_context({
            includes = { alias_for("/tmp/provider-check-one.h") },
        }))
        local conflicting, err = service:module_context({
            includes = { alias_for("/tmp/provider-check-two.h") },
        })
        assert.is_nil(conflicting)
        assert.matches("conflicting private probe%-header wrapper", err)
        assert.is_true(service:close())
    end)

    it("treats probe-header wrapper creation failures as infrastructure",
    function()
        local cache = temporary_directory()
        local state, runner, ordinary_provider = fake_environment()
        local service = assert(cprobe.new_service({
            cache_directory = cache,
            runner = runner,
            temp_provider = function()
                local workspace = ordinary_provider()
                local ordinary_write = workspace.write
                function workspace:write(name, contents)
                    if name:match("^titan%-source%-foreign%-") then
                        return nil, "injected wrapper failure"
                    end
                    return ordinary_write(self, name, contents)
                end
                return workspace
            end,
        }))
        local physical = assert(cprobe.normalize_include_descriptor({
            include_kind = "quote",
            include_name = "/tmp/provider-check.h",
        }, { source_dir = "." }))
        local alias = assert(cprobe.source_foreign_include_alias(
            physical, "provider", "/project/provider.titan.h"))
        local module = assert(service:module_context({ includes = { alias } }))
        local result = module:validate_baseline()
        assert.equal("infrastructure_failure", result.status)
        assert.matches("private probe%-header wrapper", result.message)
        assert.equal(0, #state.calls)
        assert.same({}, entries(cache))
        assert.is_true(service:close())
        assert(lfs.rmdir(cache))
    end)

    it("preserves quoted-include origin through a private wrapper", function()
        local root = temporary_directory()
        local origin = root .. "/origin"
        assert(lfs.mkdir(origin))
        local nested = origin .. "/nested.h"
        local physical = origin .. "/provider-check.h"
        write_file(nested, "struct titan_wrapper_origin { int member; };\n")
        write_file(physical, '#include "nested.h"\n')
        local include = assert(cprobe.normalize_include_descriptor({
            include_kind = "quote",
            include_name = physical,
        }, { source_dir = root }))
        local alias = assert(cprobe.source_foreign_include_alias(
            include, "provider", root .. "/provider.titan.h"))
        local service = assert(cprobe.new_service({
            compiler_argv = lfs.attributes("/usr/bin/cc", "mode")
                and { "/usr/bin/cc" } or (os.getenv("CC") or "cc"),
            cflags = { "-Wall", "-Werror" },
        }))
        local module = assert(service:module_context({
            source_dir = root,
            includes = { alias },
        }))
        local result = module:validate_baseline()
        assert.equal("success", result.status, result.message)
        assert.is_true(service:close())
        assert(os.remove(physical))
        assert(os.remove(nested))
        assert(lfs.rmdir(origin))
        assert(lfs.rmdir(root))
    end)
end)
