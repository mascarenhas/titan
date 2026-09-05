local cprobe = require "titan-compiler.cprobe"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local cpreamble = require "titan-compiler.cpreamble"
local csemantics = require "titan-compiler.csemantics"
local sha256 = require "titan-compiler.sha256"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"

local function keyed_fields(fields)
    local flattened = { "titan-cprobe-key-v1" }
    for _, field in ipairs(fields) do
        flattened[#flattened + 1] = field[1]
        flattened[#flattened + 1] = field[2] or ""
    end
    local encoded = {}
    for index, value in ipairs(flattened) do
        value = tostring(value)
        encoded[index] = #value .. ":" .. value
    end
    return table.concat(encoded)
end

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
    -- Synthetic probes use only the native inputs declared by each test,
    -- independently of the active SDK configured by a Busted helper.
    if options.include_dirs == nil then options.include_dirs = {} end
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

    it("rejects malformed header manifests and I/O strategies", function()
        local valid_input = {
            kind = "file",
            path = "/headers/api.h",
            identity = "identity",
        }
        local sparse = { valid_input }
        sparse.extra = valid_input
        local cases = {
            {
                value = false,
                expected = "C header dependencies must be an ordered array",
            },
            {
                value = { false },
                expected = "C header dependencies entry 1 must be a table",
            },
            {
                value = {{
                    kind = "search",
                    path = "/headers/api.h",
                    identity = "identity",
                }},
                expected = "C header dependencies entry 1 must have kind 'file'",
            },
            {
                value = {{
                    kind = "file",
                    path = "",
                    identity = "identity",
                }},
                expected = "must have a nonempty NUL-free path",
            },
            {
                value = {{
                    kind = "file",
                    path = "/headers/api.h",
                    identity = "",
                }},
                expected = "must have a nonempty identity",
            },
            {
                value = {{
                    kind = "file",
                    path = "/headers/api.h",
                    identity = "identity",
                    restat = "yes",
                }},
                expected = "restat flag must be boolean",
            },
            {
                value = sparse,
                expected = "must be a dense ordered array",
            },
        }
        for _, case in ipairs(cases) do
            local normalized, err = cprobe.normalize_include_descriptor({
                include_kind = "quote",
                include_name = "api.h",
                c_header_dependencies = case.value,
            }, {
                cwd = "/project",
                source_dir = "/project",
            })
            assert.is_nil(normalized)
            assert.matches(case.expected, err, 1, true)
        end

        local collected, conflict = cprobe.collect_header_inputs({}, {
            {
                kind = "file",
                path = "/headers/api.h",
                identity = "first",
            },
            {
                kind = "file",
                path = "/headers/api.h",
                identity = "second",
            },
        })
        assert.is_nil(collected)
        assert.matches("conflicting C header input identity", conflict,
            1, true)

        local service, strategy_error = cprobe.new_service({ io = {} })
        assert.is_nil(service)
        assert.matches("invalid compiler I/O strategy", strategy_error,
            1, true)
    end)

    it("requires complete include identity for reusable probe contexts",
    function()
        local cache = temporary_directory()
        local service = new_fake_service({
            process_analysis = cdriver.new_process_analysis(),
            cache_directory = cache,
        })
        for _, include in ipairs({
            "api.h",
            {
                include_kind = "angle",
                include_name = "api.h",
                c_header_dependencies = {},
            },
        }) do
            local context, err = service:module_context({
                includes = { include },
            })
            assert.is_nil(context)
            assert.matches("requires explicit c_header_dependencies and " ..
                "c_header_search_inputs", err, 1, true)
        end
        local complete, err = service:module_context({ includes = {{
            include_kind = "angle",
            include_name = "api.h",
            c_header_dependencies = {},
            c_header_search_inputs = {},
        }} })
        assert(complete, err)
        assert.is_true(service:close())
        assert(lfs.rmdir(cache))
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
        local analysis = cdriver.new_process_analysis()
        local function trace() end
        local service = new_fake_service({
            compiler_argv = { "wrapper", "configured cc" },
            compile_flags = { "--target=fake" },
            cppflags = { "-DCPP=1" },
            language_mode = "c11",
            cflags = { "-Wall" },
            include_dirs = { "/sdk/first", "/sdk/second" },
            profile = profile,
            process_analysis = analysis,
            process_trace = trace,
        })

        local options = assert(service:cdriver_process_options())
        assert.equal(analysis, options.process_analysis)
        assert.equal(trace, options.process_trace)
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
        local default_service = assert(cprobe.new_service())
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

    it("keeps baseline infrastructure failure distinct and retryable",
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
        assert.is_false(second.baseline_cached == true)
        assert.not_equal(first.key, second.key)
        assert.equal(2, #state.calls)
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
        assert.is_false(rejection_cached.cached == true)
        assert.equal(2, #rejection_state.calls)
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

        for _, invalid_root in ipairs({ "relative/workspace", "/bad\0root" }) do
            local invalid_service = assert(cprobe.new_service({
                runner = function()
                    error("runner must not be reached")
                end,
                temp_provider = function()
                    return {
                        root = invalid_root,
                        write = function() return true end,
                        remove = function() return true end,
                        cleanup = function() return true end,
                    }
                end,
            }))
            local invalid_workspace, invalid_error =
                invalid_service:_ensure_workspace()
            assert.is_nil(invalid_workspace)
            if invalid_root:sub(1, 1) ~= "/" then
                assert.matches("must be absolute", invalid_error, 1, true)
            else
                assert.matches("contains a NUL byte", invalid_error, 1, true)
            end
            assert.is_true(invalid_service:close())
        end
        local closed_again, repeated_error = write_failure_service:close()
        assert.is_nil(closed_again)
        assert.equal(close_error, repeated_error)
        assert.equal(1, cleanup_called)
    end)

    it("normalizes default strategy workspace failures and cleanup",
    function()
        local function service_with(strategy)
            return assert(cprobe.new_service({
                io = strategy,
                include_dirs = {},
                profile = target_profile(),
            }))
        end

        local reservation = compiler_io.new_sync()
        local reservation_service = service_with(reservation)
        reservation.tmpname = function()
            return nil, "injected reservation failure"
        end
        local workspace, workspace_error =
            reservation_service:_ensure_workspace()
        assert.is_nil(workspace)
        assert.matches("could not reserve private probe directory",
            workspace_error, 1, true)
        assert.matches("injected reservation failure", workspace_error,
            1, true)
        assert.is_true(reservation_service:close())

        local release = compiler_io.new_sync()
        local release_service = service_with(release)
        release.tmpname = function() return "/fake/reservation" end
        release.unlink = function()
            return nil, "injected release failure"
        end
        workspace, workspace_error = release_service:_ensure_workspace()
        assert.is_nil(workspace)
        assert.matches("could not release probe directory reservation",
            workspace_error, 1, true)
        assert.matches("injected release failure", workspace_error,
            1, true)
        assert.is_true(release_service:close())

        local creation = compiler_io.new_sync()
        local creation_service = service_with(creation)
        creation.tmpname = function() return "/fake/reservation" end
        creation.unlink = function() return true end
        creation.mkdir = function()
            return nil, "injected creation failure"
        end
        workspace, workspace_error = creation_service:_ensure_workspace()
        assert.is_nil(workspace)
        assert.matches("could not create private probe directory",
            workspace_error, 1, true)
        assert.matches("injected creation failure", workspace_error,
            1, true)
        assert.is_true(creation_service:close())

        local cleanup = compiler_io.new_sync()
        local cleanup_service = service_with(cleanup)
        cleanup.tmpname = function() return "/fake/workspace-one" end
        cleanup.unlink = function() return true end
        cleanup.mkdir = function() return true end
        assert(cleanup_service:_ensure_workspace())
        cleanup.list = function() return { "stray.o" } end
        cleanup.unlink = function()
            return nil, "injected unlink failure"
        end
        cleanup.rmdir = function() return true end
        local closed, close_error = cleanup_service:close()
        assert.is_nil(closed)
        assert.matches("stray.o: injected unlink failure", close_error,
            1, true)

        local listing = compiler_io.new_sync()
        local listing_service = service_with(listing)
        listing.tmpname = function() return "/fake/workspace-two" end
        listing.unlink = function() return true end
        listing.mkdir = function() return true end
        assert(listing_service:_ensure_workspace())
        listing.list = function()
            return nil, "injected list failure"
        end
        listing.rmdir = function() return true end
        closed, close_error = listing_service:close()
        assert.is_nil(closed)
        assert.matches("injected list failure", close_error, 1, true)
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

describe("persistent semantic C probe results", function()
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

    it("traces one persistent miss and the matching later hit", function()
        local cache = temporary_directory()
        local source = "int titan_traced_persistent_success;\n"
        local first_events = {}
        local first, first_state = new_fake_service({
            cache_directory = cache,
            persistent_cache_trace = function(stage, hit, key, path)
                first_events[#first_events + 1] = {
                    stage = stage,
                    hit = hit,
                    key = key,
                    path = path,
                }
            end,
        })
        local first_run = first:_run_source(
            "baseline", source, "same-semantic-key")
        assert.is_true(first_run.ok)
        assert.equal(1, #first_state.calls)
        assert.same({}, first.evidence)
        assert.equal(1, #first_events)
        assert.same({
            stage = "baseline",
            hit = false,
            key = first_run.cache_path:match("([^/.]+)[.]success$"),
            path = first_run.cache_path,
        }, first_events[1])
        assert.equal(0, assert(lfs.attributes(first_run.cache_path)).size)
        assert.is_true(first:close())

        local second_events = {}
        local second, second_state = new_fake_service({
            cache_directory = cache,
            persistent_cache_trace = function(stage, hit, key, path)
                second_events[#second_events + 1] = {
                    stage = stage,
                    hit = hit,
                    key = key,
                    path = path,
                }
            end,
        }, function()
            error("a traced persistent hit must not invoke the compiler")
        end)
        local second_run = second:_run_source(
            "baseline", source, "same-semantic-key")
        assert.is_true(second_run.ok)
        assert.is_true(second_run.persistent_cached)
        assert.equal(0, #second_state.calls)
        assert.same({}, second.evidence)
        assert.same({ {
            stage = "baseline",
            hit = true,
            key = first_events[1].key,
            path = first_events[1].path,
        } }, second_events)
        assert.is_true(second:close())

        assert(os.remove(first_run.cache_path))
        assert(lfs.rmdir(cache))
    end)

    it("serves a service-memory hit without hashing or persistent I/O",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local service, state = new_fake_service({
            io = strategy,
            cache_directory = cache,
        })
        local source = "int titan_service_memory_hit;\n"
        local first = service:_run_source(
            "candidate", source, "service-memory-key")
        assert.is_true(first.ok)
        assert.equal(1, #state.calls)

        local original_sha = sha256.hex
        local originals = {
            stat = strategy.stat,
            read_file = strategy.read_file,
            write_file = strategy.write_file,
            run = strategy.run,
        }
        local function unexpected(operation)
            return function()
                error("service-memory hit unexpectedly called " .. operation)
            end
        end
        sha256.hex = unexpected("SHA-256")
        strategy.stat = unexpected("stat")
        strategy.read_file = unexpected("read_file")
        strategy.write_file = unexpected("write_file")
        strategy.run = unexpected("run")

        local completed, repeated = pcall(
            service._run_source, service,
            "candidate", source, "service-memory-key")
        sha256.hex = original_sha
        for name, implementation in pairs(originals) do
            strategy[name] = implementation
        end

        assert.is_true(completed, repeated)
        assert.is_true(repeated.ok)
        assert.equal("service", repeated.cache_tier)
        assert.equal(1, #state.calls)
        assert.is_true(service:close())
        assert(os.remove(first.cache_path))
        assert(lfs.rmdir(cache))
    end)

    it("serves pointer and operator service hits before full source rendering",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local profile = target_profile()
        local service, state = new_fake_service({
            io = strategy,
            profile = profile,
            cache_directory = cache,
        })
        local module = assert(service:module_context())
        local pointer_source = cpointer("hot_service_source")
        local pointer_target = cpointer("hot_service_target")
        local trait = assert(csemantics.decide_binary_operator(
            profile, "+", profile.integers.int.type, types.Integer()))
        local first_pointer = module:probe_unsafe_object_pointer(
            pointer_source, pointer_target)
        local first_operator = module:probe_operator(trait)
        assert.equal("success", first_pointer.status, first_pointer.message)
        assert.equal("success", first_operator.status, first_operator.message)
        assert.equal(3, #state.calls)

        local original_preamble = module.header_preamble
        local original_sha = sha256.hex
        local originals = {
            stat = strategy.stat,
            read_file = strategy.read_file,
            write_file = strategy.write_file,
            run = strategy.run,
        }
        local function unexpected(operation)
            return function()
                error("semantic memory hit unexpectedly called " .. operation)
            end
        end
        -- The normalized metadata and raw semantic key do not need the full
        -- preamble. If either hit renders a translation unit, table.concat
        -- rejects this sentinel before the assertion below can succeed.
        module.header_preamble = {}
        sha256.hex = unexpected("SHA-256")
        strategy.stat = unexpected("stat")
        strategy.read_file = unexpected("read_file")
        strategy.write_file = unexpected("write_file")
        strategy.run = unexpected("run")

        local completed, repeated_pointer, repeated_operator = pcall(function()
            return module:probe_unsafe_object_pointer(
                    pointer_source, pointer_target),
                module:probe_operator(trait)
        end)
        module.header_preamble = original_preamble
        sha256.hex = original_sha
        for name, implementation in pairs(originals) do
            strategy[name] = implementation
        end

        assert.is_true(completed, repeated_pointer)
        assert.equal("success", repeated_pointer.status)
        assert.equal("service", repeated_pointer.cache_tier)
        assert.equal(first_pointer.source, repeated_pointer.source)
        assert.equal("success", repeated_operator.status)
        assert.equal("service", repeated_operator.cache_tier)
        assert.equal(first_operator.source, repeated_operator.source)
        assert.equal(3, #state.calls)
        assert.is_true(service:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("serves pointer and operator analysis hits before full source rendering",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local analysis = cdriver.new_process_analysis()
        local profile = target_profile()
        local pointer_source = cpointer("hot_analysis_source")
        local pointer_target = cpointer("hot_analysis_target")
        local trait = assert(csemantics.decide_binary_operator(
            profile, "+", profile.integers.int.type, types.Integer()))
        local publisher, publisher_state = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            profile = profile,
            cache_directory = cache,
        })
        local publisher_module = assert(publisher:module_context())
        local first_pointer = publisher_module:probe_unsafe_object_pointer(
            pointer_source, pointer_target)
        local first_operator = publisher_module:probe_operator(trait)
        assert.equal("success", first_pointer.status, first_pointer.message)
        assert.equal("success", first_operator.status, first_operator.message)
        assert.equal(3, #publisher_state.calls)
        assert.is_true(publisher:close())

        local consumer, consumer_state = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            profile = profile,
            cache_directory = cache,
        }, function()
            error("analysis hits must not invoke the compiler")
        end)
        local consumer_module = assert(consumer:module_context())
        local original_preamble = consumer_module.header_preamble
        local original_sha = sha256.hex
        local originals = {
            stat = strategy.stat,
            read_file = strategy.read_file,
            write_file = strategy.write_file,
            run = strategy.run,
        }
        local function unexpected(operation)
            return function()
                error("analysis memory hit unexpectedly called " .. operation)
            end
        end
        consumer_module.header_preamble = {}
        sha256.hex = unexpected("SHA-256")
        strategy.stat = unexpected("stat")
        strategy.read_file = unexpected("read_file")
        strategy.write_file = unexpected("write_file")
        strategy.run = unexpected("run")

        local completed, repeated_pointer, repeated_operator = pcall(function()
            return consumer_module:probe_unsafe_object_pointer(
                    pointer_source, pointer_target),
                consumer_module:probe_operator(trait)
        end)
        consumer_module.header_preamble = original_preamble
        sha256.hex = original_sha
        for name, implementation in pairs(originals) do
            strategy[name] = implementation
        end

        assert.is_true(completed, repeated_pointer)
        assert.equal("success", repeated_pointer.status)
        assert.equal("analysis", repeated_pointer.cache_tier)
        assert.equal(first_pointer.source, repeated_pointer.source)
        assert.equal("success", repeated_operator.status)
        assert.equal("analysis", repeated_operator.cache_tier)
        assert.equal(first_operator.source, repeated_operator.source)
        assert.equal(0, #consumer_state.calls)
        assert.is_true(consumer:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("normalizes private paths before returning and persisting diagnostics",
    function()
        local cache = temporary_directory()
        local expected = table.concat({
            "<titan-cprobe-source>: In function ‘probe’:",
            "<titan-cprobe-source>: At top level:",
            "<titan-cprobe-source>:7: error: rejected",
            "In file included from <titan-cprobe-source>:9,",
            "                 from <titan-cprobe-object>:11:",
            "<titan-cprobe-object>",
            "after\0tail",
        }, "\n")
        local first, first_state = new_fake_service({
            cache_directory = cache,
        }, function(_, _, metadata)
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = table.concat({
                    metadata.source_path .. ": In function ‘probe’:",
                    metadata.source_path .. ": At top level:",
                    metadata.source_path .. ":7: error: rejected",
                    "In file included from " .. metadata.source_path ..
                        ":9,",
                    "                 from " .. metadata.object_path ..
                        ":11:",
                    metadata.object_path,
                    "after\0tail",
                }, "\n"),
            }
        end)
        local source = "int titan_private_diagnostic_path;\n"
        local first_run = first:_run_source(
            "candidate", source, "private-diagnostic-key", "private-path")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(expected, first_run.diagnostic)
        assert.equal(1, #first_state.calls)

        local encoded = assert(compiler_io.new_sync():read_file(
            first_run.cache_path))
        assert.is_nil(encoded:find("/fake/titan probe", 1, true))
        assert.is_true(first:close())

        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("normalized persistent result must not invoke the compiler")
        end)
        local second_run = second:_run_source(
            "candidate", source, "private-diagnostic-key", "private-path")
        assert.is_true(second_run.persistent_cached)
        assert.equal(expected, second_run.diagnostic)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())

        assert(os.remove(first_run.cache_path))
        assert(lfs.rmdir(cache))
    end)

    it("keeps a bare private workspace root in service memory only",
    function()
        local cache = temporary_directory()
        local publications = {}
        local raw_diagnostics = {}
        local function create(sequence)
            local service, state = new_fake_service({
                cache_directory = cache,
                semantic_trace = function(event)
                    publications[#publications + 1] = event.publication
                end,
            }, function(_, _, metadata)
                local root = assert(
                    metadata.source_path:match("^(.*)/[^/]+$"))
                local diagnostic = "unstructured workspace " .. root ..
                    " invocation " .. sequence
                raw_diagnostics[#raw_diagnostics + 1] = diagnostic
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = diagnostic,
                }
            end)
            service.sequence = sequence
            return service, state
        end

        local source = "int titan_bare_workspace_diagnostic;\n"
        local first, first_state = create(4)
        local first_run = first:_run_source(
            "candidate", source, "bare-workspace-key", "bare-root")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(raw_diagnostics[1], first_run.diagnostic)
        assert.equal("unstable_diagnostic", publications[#publications])
        assert.is_nil(lfs.attributes(first_run.cache_path))
        local memory = first:_run_source(
            "candidate", source, "bare-workspace-key", "bare-root")
        assert.equal("service", memory.cache_tier)
        assert.equal(first_run.diagnostic, memory.diagnostic)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local fresh, fresh_state = create(8)
        local fresh_run = fresh:_run_source(
            "candidate", source, "bare-workspace-key", "bare-root")
        assert.equal("compiler_rejection", fresh_run.classification)
        assert.not_equal(first_run.diagnostic, fresh_run.diagnostic)
        assert.equal(1, #fresh_state.calls)
        assert.is_nil(lfs.attributes(fresh_run.cache_path))
        assert.is_true(fresh:close())
        assert.same({}, entries(cache))
        assert(lfs.rmdir(cache))
    end)

    it("keeps ambiguous private path diagnostics only in memory", function()
        local cache = temporary_directory()
        local publications = {}
        local raw_diagnostics = {}
        local function service(sequence)
            local created, state = new_fake_service({
                cache_directory = cache,
                semantic_trace = function(event)
                    publications[#publications + 1] = event.publication
                end,
            }, function(_, _, metadata)
                local diagnostic = table.concat({
                    metadata.source_path .. "~backup",
                    metadata.source_path .. " backup",
                    metadata.source_path .. ")backup",
                    metadata.source_path .. ": arbitrary context:",
                    "archive " .. metadata.source_path .. ":17: error",
                    "archive(" .. metadata.source_path .. ":19: error",
                }, "\n")
                raw_diagnostics[#raw_diagnostics + 1] = diagnostic
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = diagnostic,
                }
            end)
            created.sequence = sequence
            return created, state
        end

        local source = "int titan_ambiguous_private_diagnostic;\n"
        local first, first_state = service(8)
        local first_run = first:_run_source(
            "candidate", source, "ambiguous-private-key", "ambiguous")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(raw_diagnostics[1], first_run.diagnostic)
        assert.matches("000009%-ambiguous[.]c", first_run.diagnostic)
        assert.matches("~backup", first_run.diagnostic, 1, true)
        assert.matches(" backup", first_run.diagnostic, 1, true)
        assert.matches("%)backup", first_run.diagnostic)
        assert.matches("archive /fake/titan probe %d+/",
            first_run.diagnostic)
        assert.matches("archive%(/fake/titan probe %d+/",
            first_run.diagnostic)
        assert.is_nil(lfs.attributes(first_run.cache_path))
        assert.equal("unstable_diagnostic", publications[#publications])
        local memory_run = first:_run_source(
            "candidate", source, "ambiguous-private-key", "ambiguous")
        assert.equal(first_run.diagnostic, memory_run.diagnostic)
        assert.equal("service", memory_run.cache_tier)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local second, second_state = service(0)
        local second_run = second:_run_source(
            "candidate", source, "ambiguous-private-key", "ambiguous")
        assert.equal(raw_diagnostics[2], second_run.diagnostic)
        assert.matches("000001%-ambiguous[.]c", second_run.diagnostic)
        assert.not_equal(first_run.diagnostic, second_run.diagnostic)
        assert.equal(1, #second_state.calls)
        assert.is_nil(lfs.attributes(second_run.cache_path))
        assert.is_true(second:close())
        assert.same({}, entries(cache))
        assert(lfs.rmdir(cache))
    end)

    it("normalizes private aliases once and rejects overlapping spans",
    function()
        local function module_context(service, specifications)
            local includes = {}
            for index, specification in ipairs(specifications) do
                local normalized = assert(cprobe.normalize_include_descriptor({
                    original = specification.physical,
                    resolved = specification.physical,
                    include_kind = "quote",
                    include_name = specification.physical,
                    c_header_dependencies = { {
                        kind = "file",
                        path = specification.physical,
                        identity = "diagnostic-fixture:" ..
                            specification.physical,
                    } },
                    c_header_search_inputs = {},
                }, { source_dir = "/tmp" }))
                includes[index] = assert(cprobe.source_foreign_include_alias(
                    normalized, "diagnostic_alias_" .. index,
                    specification.public))
            end
            return assert(service:module_context({
                module = "diagnostic_alias_consumer",
                source_dir = "/tmp",
                includes = includes,
            }))
        end

        local function remove_cache(cache)
            for _, name in ipairs(entries(cache)) do
                assert(os.remove(cache .. "/" .. name))
            end
            assert(lfs.rmdir(cache))
        end

        local function assert_persistent_alias_case(
                name, specifications, diagnostic, expected)
            local cache = temporary_directory()
            local first, first_state = new_fake_service({
                cache_directory = cache,
            }, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = diagnostic,
                }
            end)
            local source = cpointer(name .. "_source")
            local target = cpointer(name .. "_target")
            local first_result = module_context(first, specifications):
                probe_unsafe_object_pointer(source, target)
            assert.equal("rejected", first_result.status)
            assert.equal(expected, first_result.diagnostic)
            assert.equal(2, #first_state.calls)
            assert.is_true(first:close())

            local repeated, repeated_state = new_fake_service({
                cache_directory = cache,
            }, function()
                error("stable normalized alias must reuse its result")
            end)
            local repeated_result = module_context(repeated, specifications):
                probe_unsafe_object_pointer(source, target)
            assert.equal("rejected", repeated_result.status)
            assert.equal(expected, repeated_result.diagnostic)
            assert.is_true(repeated_result.persistent_cached)
            assert.equal(0, #repeated_state.calls)
            assert.is_true(repeated:close())
            remove_cache(cache)
        end

        -- The first public spelling is the second alias's physical spelling.
        -- One-pass normalization must not cascade into the second public path.
        assert_persistent_alias_case("cascade", {
            {
                physical = "/tmp/cascade-first.h",
                public = "/tmp/cascade-second.h",
            },
            {
                physical = "/tmp/cascade-second.h",
                public = "/project/cascade-final.h",
            },
        }, "/tmp/cascade-first.h:7: error: cascade",
           "/tmp/cascade-second.h:7: error: cascade")

        -- A stable public path may legitimately retain the private basename.
        assert_persistent_alias_case("shared_name", { {
            physical = "/tmp/shared-name.h",
            public = "/project/shared-name.h",
        } }, "/tmp/shared-name.h:8: error: shared",
             "/project/shared-name.h:8: error: shared")

        local cache = temporary_directory()
        local publications = {}
        local overlap_diagnostic = "/tmp/overlap.h:2:7: error: overlap"
        local overlap_specifications = {
            {
                physical = "/tmp/overlap.h",
                public = "/project/short.h",
            },
            {
                physical = "/tmp/overlap.h:2",
                public = "/project/long.h",
            },
        }
        local function overlap_service()
            return new_fake_service({
                cache_directory = cache,
                semantic_trace = function(event)
                    publications[#publications + 1] = event.publication
                end,
            }, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = overlap_diagnostic,
                }
            end)
        end
        local source = cpointer("overlap_source")
        local target = cpointer("overlap_target")
        local first, first_state = overlap_service()
        local first_result = module_context(first, overlap_specifications):
            probe_unsafe_object_pointer(source, target)
        assert.equal("rejected", first_result.status)
        assert.equal(overlap_diagnostic, first_result.diagnostic)
        assert.is_false(first_result.persistent_cached)
        assert.equal("unstable_diagnostic", publications[#publications])
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())

        local repeated, repeated_state = overlap_service()
        local repeated_result = module_context(
            repeated, overlap_specifications):
            probe_unsafe_object_pointer(source, target)
        assert.equal("rejected", repeated_result.status)
        assert.equal(overlap_diagnostic, repeated_result.diagnostic)
        -- The baseline is persistent, but the ambiguous candidate reruns.
        assert.equal(1, #repeated_state.calls)
        assert.is_true(repeated:close())
        remove_cache(cache)

        cache = temporary_directory()
        publications = {}
        local conflict_diagnostic =
            "/tmp/conflicted.h:5: error: conflicting aliases"
        local conflict_specifications = {
            {
                physical = "/tmp/conflicted.h",
                public = "/project/conflicted-first.h",
            },
            {
                physical = "/tmp/conflicted.h",
                public = "/project/conflicted-second.h",
            },
        }
        local function conflict_service()
            return new_fake_service({
                cache_directory = cache,
                semantic_trace = function(event)
                    publications[#publications + 1] = event.publication
                end,
            }, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = conflict_diagnostic,
                }
            end)
        end
        source = cpointer("conflict_source")
        target = cpointer("conflict_target")
        first, first_state = conflict_service()
        first_result = module_context(first, conflict_specifications):
            probe_unsafe_object_pointer(source, target)
        assert.equal(conflict_diagnostic, first_result.diagnostic)
        assert.equal("unstable_diagnostic", publications[#publications])
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())

        repeated, repeated_state = conflict_service()
        repeated_result = module_context(repeated, conflict_specifications):
            probe_unsafe_object_pointer(source, target)
        assert.equal(conflict_diagnostic, repeated_result.diagnostic)
        assert.equal(1, #repeated_state.calls)
        assert.is_true(repeated:close())
        remove_cache(cache)
    end)

    it("keeps oversized diagnostics in memory without writing a record",
    function()
        local cache = temporary_directory()
        local diagnostic = string.rep("oversized diagnostic bytes\n", 42000)
        assert.is_true(#diagnostic > 1024 * 1024)
        local publications = {}
        local function create()
            return new_fake_service({
                cache_directory = cache,
                semantic_trace = function(event)
                    publications[#publications + 1] = event.publication
                end,
            }, function()
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = diagnostic,
                }
            end)
        end

        local source = "int titan_oversized_diagnostic;\n"
        local first, first_state = create()
        local first_run = first:_run_source(
            "candidate", source, "oversized-diagnostic-key", "oversized")
        assert.equal(diagnostic, first_run.diagnostic)
        assert.equal("too_large", publications[#publications])
        assert.is_nil(lfs.attributes(first_run.cache_path))
        local memory_run = first:_run_source(
            "candidate", source, "oversized-diagnostic-key", "oversized")
        assert.equal(diagnostic, memory_run.diagnostic)
        assert.equal("service", memory_run.cache_tier)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local fresh, fresh_state = create()
        local fresh_run = fresh:_run_source(
            "candidate", source, "oversized-diagnostic-key", "oversized")
        assert.equal(diagnostic, fresh_run.diagnostic)
        assert.equal(1, #fresh_state.calls)
        assert.is_nil(lfs.attributes(fresh_run.cache_path))
        assert.is_true(fresh:close())
        assert.same({}, entries(cache))
        assert(lfs.rmdir(cache))
    end)

    it("distinguishes persistent stat failures from ordinary misses", function()
        local strategy = compiler_io.new_sync()
        local events = {}
        local service = new_fake_service({
            io = strategy,
            cache_directory = "/cache",
            persistent_cache_trace = function(stage, hit, key, path)
                events[#events + 1] = {
                    stage = stage, hit = hit, key = key, path = path,
                }
            end,
        })
        strategy.stat = function(_, path)
            assert.matches("^/cache/[0-9a-f]+[.]", path)
            assert.is_true(path:match("[.]success$") ~= nil or
                path:match("[.]negative$") ~= nil)
            return nil, "injected persistent stat failure"
        end
        strategy.read_file = function()
            error("a failed stat must not read the persistent record")
        end

        local cached, path, digest, lookup = service:_read_persistent_result(
            "candidate", "raw_source", "int stat_failure;\n", "key")
        assert.is_nil(cached)
        assert.equal("io_error", lookup)
        assert.equal("/cache/" .. digest .. ".success", path)
        assert.same({ {
            stage = "candidate",
            hit = false,
            key = digest,
            path = path,
        } }, events)
        assert.is_true(service:close())
    end)

    it("never falls through a success stat error to a negative sibling",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local source = "int titan_positive_authority_stat_error;\n"
        local key = "positive-authority-stat-error"
        local seed = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = cache,
        }))
        local publication, _, negative_path =
            seed:_publish_semantic_result(
                "result", "raw_source", source, key, {
                    outcome = "compiler_rejection",
                    exit_status = 1,
                    diagnostic = "stale negative sibling",
                })
        assert.equal("published", publication)
        assert.matches("[.]negative$", negative_path)
        assert.is_true(seed:close())

        local lookup = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = cache,
        }))
        local success_path = negative_path:gsub(
            "[.]negative$", ".success")
        local ordinary_stat = strategy.stat
        local ordinary_read_file = strategy.read_file
        strategy.stat = function(self, path)
            if path == success_path then
                return nil, "injected positive-marker stat failure"
            elseif path == negative_path then
                error("a positive-marker stat error must stop lookup")
            end
            return ordinary_stat(self, path)
        end
        strategy.read_file = function(_, path)
            error("stat failure unexpectedly read " .. tostring(path))
        end

        local semantic, path, _, state = lookup:_read_persistent_result(
            "candidate", "raw_source", source, key)
        strategy.stat = ordinary_stat
        strategy.read_file = ordinary_read_file
        assert.is_nil(semantic)
        assert.equal(success_path, path)
        assert.equal("io_error", state)
        assert.is_true(lookup:close())

        assert(os.remove(negative_path))
        assert(lfs.rmdir(cache))
    end)

    it("never falls through a non-file success slot to a negative sibling",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local source = "int titan_corrupt_positive_slot;\n"
        local key = "corrupt-positive-slot"
        local seed = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = cache,
        }))
        local publication, _, negative_path =
            seed:_publish_semantic_result(
                "result", "raw_source", source, key, {
                    outcome = "compiler_rejection",
                    exit_status = 1,
                    diagnostic = "stale negative sibling",
                })
        assert.equal("published", publication)
        assert.matches("[.]negative$", negative_path)
        assert.is_true(seed:close())

        local lookup = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = cache,
        }))
        local success_path = negative_path:gsub(
            "[.]negative$", ".success")
        local ordinary_stat = strategy.stat
        local ordinary_read_file = strategy.read_file
        strategy.stat = function(self, path)
            if path == success_path then
                return { kind = "directory", size = 0 }
            elseif path == negative_path then
                error("a non-file positive slot must stop sibling lookup")
            end
            return ordinary_stat(self, path)
        end
        strategy.read_file = function(_, path)
            error("non-file positive slot unexpectedly read " .. tostring(path))
        end

        local semantic, path, _, state = lookup:_read_persistent_result(
            "candidate", "raw_source", source, key)
        strategy.stat = ordinary_stat
        strategy.read_file = ordinary_read_file
        assert.is_nil(semantic)
        assert.equal(success_path, path)
        assert.equal("invalid", state)
        assert.is_true(lookup:close())

        assert(os.remove(negative_path))
        assert(lfs.rmdir(cache))
    end)

    it("isolates persistent cache trace sink failures", function()
        local cache = temporary_directory()
        local source = "int titan_failing_cache_trace_sink;\n"
        local first = new_fake_service({
            cache_directory = cache,
            persistent_cache_trace = function()
                error("injected cache trace failure")
            end,
        })
        local first_run = first:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_true(first_run.ok)
        assert.is_true(first:close())

        local second, second_state = new_fake_service({
            cache_directory = cache,
            persistent_cache_trace = function()
                error("injected cache trace failure")
            end,
        }, function()
            error("a persistent hit must not invoke the compiler")
        end)
        local second_run = second:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_true(second_run.ok)
        assert.is_true(second_run.persistent_cached)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())

        assert(os.remove(first_run.cache_path))
        assert(lfs.rmdir(cache))
    end)

    it("builds one semantic location across lookup and publication", function()
        local cache = temporary_directory()
        local service = new_fake_service({ cache_directory = cache })
        local original_location = service._persistent_success_location
        local location_calls = 0
        service._persistent_success_location = function(self, ...)
            location_calls = location_calls + 1
            return original_location(self, ...)
        end

        local run = service:_run_source(
            "candidate", "int titan_single_location;\n", "same-key")
        assert.is_true(run.ok, run.diagnostic)
        assert.equal(1, location_calls)
        assert.is_true(service:close())
        assert(os.remove(run.cache_path))
        assert(lfs.rmdir(cache))
    end)

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

    it("bounds retained probe keys for a covered header sample", function()
        local function dependencies(count, changed_last)
            local result = {}
            for index = 1, count do
                result[index] = {
                    kind = "file",
                    path = ("/headers/dependency-%04d.h"):format(index),
                    identity = ("c-header-file-v1:sha256:%064d"):format(
                        changed_last and index == count and 1 or 0),
                    restat = false,
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
        local large_dependencies = dependencies(24)
        local large = context(service, large_dependencies)
        local changed = context(service, dependencies(24, true))
        local unbounded = {}
        for _, input in ipairs(large_dependencies) do
            unbounded[#unbounded + 1] = input.path
            unbounded[#unbounded + 1] = input.identity
        end

        assert.is_true(#table.concat(unbounded) > 1024)
        assert.equal(#small.header_key, #large.header_key)
        assert.equal(#small.baseline_key, #large.baseline_key)
        assert.not_equal(large.header_key, changed.header_key)
        assert.not_equal(large.baseline_key, changed.baseline_key)

        local result = large:probe_unsafe_object_pointer(
            cpointer("covered_header_source"),
            cpointer("covered_header_target"))
        local changed_result = changed:probe_unsafe_object_pointer(
            cpointer("covered_header_source"),
            cpointer("covered_header_target"))
        assert.equal("success", result.status, result.message)
        assert.equal("success", changed_result.status,
            changed_result.message)
        assert.not_equal(result.key, changed_result.key)
        assert.equal(#result.key, #changed_result.key)
        assert.is_true(#result.key < 1024)
        assert.is_true(service:close())
    end)

    it("bounds retained probe keys independently of header closure size #stress",
    function()
        local function dependencies(count, changed_last)
            local result = {}
            for index = 1, count do
                result[index] = {
                    kind = "file",
                    path = ("/headers/dependency-%04d.h"):format(index),
                    identity = ("c-header-file-v1:sha256:%064d"):format(
                        changed_last and index == count and 1 or 0),
                    restat = false,
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
                    restat = false,
                }},
                c_header_search_inputs = {},
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
            local options = {
                compiler_argv = compiler,
                cppflags = { "-include", forced },
                profile = target_profile(),
                cache_directory = cache,
            }
            return assert(cprobe.new_service(options))
        end

        local source = "int titan_forced_probe;\n"
        local first = service()
        local first_result = first:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_true(first_result.ok, first_result.diagnostic)
        assert.is_false(first_result.persistent_cached == true)
        assert.is_true(first:close())

        write_file(forced, "#define TITAN_FORCED_PROBE 2\n")
        local changed = service()
        local changed_result = changed:_run_source(
            "candidate", source, "same-semantic-key")
        assert.is_true(changed_result.ok, changed_result.diagnostic)
        assert.is_false(changed_result.persistent_cached == true)
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


    it("validates each non-analysis service and context snapshot once",
    function()
        local root = temporary_directory()
        local forced = root .. "/forced.h"
        local ordinary = root .. "/ordinary.h"
        write_file(forced, "#define TITAN_FORCED_SNAPSHOT 1\n")
        write_file(ordinary, "#define TITAN_ORDINARY_SNAPSHOT 1\n")
        local strategy = compiler_io.new_sync()
        local ordinary_identity = assert(cdriver.header_input_identity(
            "file", ordinary, strategy))
        local service, state = new_fake_service({
            io = strategy,
            compiler_argv = { "/usr/bin/cc" },
            cppflags = { "-include", forced },
            include_dirs = {},
            profile = target_profile(),
        })

        local original_identity = cdriver.header_input_identity
        local counts = {}
        cdriver.header_input_identity = function(kind, path, io_strategy)
            local input = kind .. "\0" .. path
            counts[input] = (counts[input] or 0) + 1
            return original_identity(kind, path, io_strategy)
        end
        local completed, failure = xpcall(function()
            local module = assert(service:module_context({ includes = {{
                original = "ordinary.h",
                resolved = ordinary,
                include_kind = "quote",
                include_name = "ordinary.h",
                c_header_dependencies = {{
                    kind = "file",
                    path = ordinary,
                    identity = ordinary_identity,
                }},
                c_header_search_inputs = {},
            }} }))
            assert.equal("success", module:validate_baseline().status)
            assert.equal("success", module:probe_unsafe_object_pointer(
                cpointer("snapshot_source_one"),
                cpointer("snapshot_target_one")).status)
            assert.equal("success", module:probe_unsafe_object_pointer(
                cpointer("snapshot_source_two"),
                cpointer("snapshot_target_two")).status)
            assert.equal(1, counts["search\0" .. forced])
            assert.equal(1, counts["file\0" .. forced])
            assert.equal(1, counts["file\0" .. ordinary])
            assert.equal(3, #state.calls)

            local repeated_context = assert(service:module_context({
                includes = {{
                    original = "ordinary.h",
                    resolved = ordinary,
                    include_kind = "quote",
                    include_name = "ordinary.h",
                    c_header_dependencies = {{
                        kind = "file",
                        path = ordinary,
                        identity = ordinary_identity,
                    }},
                    c_header_search_inputs = {},
                }},
            }))
            assert.equal("success",
                repeated_context:validate_baseline().status)
            assert.equal("success",
                repeated_context:probe_unsafe_object_pointer(
                    cpointer("snapshot_source_three"),
                    cpointer("snapshot_target_three")).status)
            assert.equal(1, counts["search\0" .. forced])
            assert.equal(1, counts["file\0" .. forced])
            assert.equal(1, counts["file\0" .. ordinary])
            assert.equal(4, #state.calls)
        end, debug.traceback)
        cdriver.header_input_identity = original_identity

        assert.is_true(service:close())
        assert(os.remove(ordinary))
        assert(os.remove(forced))
        assert(lfs.rmdir(root))
        assert.truthy(completed, failure)
    end)

    it("performs no probe-local restats inside a process analysis", function()
        local root = temporary_directory()
        local header = root .. "/analysis.h"
        write_file(header, "#define TITAN_ANALYSIS_SNAPSHOT 1\n")
        local strategy = compiler_io.new_sync()
        local identity = assert(cdriver.header_input_identity(
            "file", header, strategy))
        local service, state = new_fake_service({
            io = strategy,
            process_analysis = cdriver.new_process_analysis(),
        })

        local original_identity = cdriver.header_input_identity
        local identity_calls = 0
        cdriver.header_input_identity = function(...)
            identity_calls = identity_calls + 1
            return original_identity(...)
        end
        local completed, failure = xpcall(function()
            local module = assert(service:module_context({ includes = {{
                original = "analysis.h",
                resolved = header,
                include_kind = "quote",
                include_name = "analysis.h",
                c_header_dependencies = {{
                    kind = "file", path = header, identity = identity,
                }},
                c_header_search_inputs = {},
            }} }))
            assert.equal("success", module:validate_baseline().status)
            assert.equal("success", module:probe_unsafe_object_pointer(
                cpointer("analysis_source"),
                cpointer("analysis_target")).status)
            assert.equal(0, identity_calls)
            assert.equal(2, #state.calls)
        end, debug.traceback)
        cdriver.header_input_identity = original_identity

        assert.is_true(service:close())
        assert(os.remove(header))
        assert(lfs.rmdir(root))
        assert.truthy(completed, failure)
    end)

    it("treats header validation as an approximate invocation snapshot",
    function()
        local root = temporary_directory()
        local cache = root .. "/cache"
        assert(lfs.mkdir(cache))
        local forced = root .. "/forced.h"
        write_file(forced, "#define TITAN_FORCED_SNAPSHOT 1\n")
        local state, runner, temp_provider = fake_environment(function()
            write_file(forced, "#define TITAN_FORCED_SNAPSHOT 2\n")
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
        local module = assert(service:module_context())
        local result = module:validate_baseline()
        assert.equal("success", result.status, result.message)
        assert.equal(1, #state.calls)
        local cache_path = assert(service:_persistent_success_location(
            result.source, result.key))
        assert.equal("file", lfs.attributes(cache_path, "mode"))
        assert.equal(0, assert(lfs.attributes(cache_path)).size)
        local repeated = module:validate_baseline()
        assert.equal("success", repeated.status)
        assert.is_true(repeated.cached)
        assert.equal(1, #state.calls)
        assert.is_true(service:close())

        -- This cache is deliberately an invocation snapshot. The later
        -- generated-C compilation/publication boundary remains final authority.
        assert(os.remove(cache_path))
        assert(os.remove(forced))
        assert(lfs.rmdir(cache))
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

    it("strips only complete generated-file stat identity suffixes", function()
        local digest = string.rep("b", 64)
        local prefix = "c-header-file-v1:sha256:" .. digest
        local function remapped_identity(identity)
            local path = "/tmp/provider.check.h"
            local descriptor = assert(cprobe.normalize_include_descriptor({
                resolved = path,
                include_kind = "quote",
                include_name = path,
                c_header_dependencies = {{
                    kind = "file",
                    path = path,
                    identity = identity,
                }},
            }, { source_dir = "/tmp" }))
            local alias = assert(cprobe.source_foreign_include_alias(
                descriptor, "provider.module", "/project/provider.titan.h"))
            return alias.c_header_dependencies[1].identity
        end

        assert.equal(prefix,
            remapped_identity(prefix .. ";stat=file:33188:1:2"))
        assert.equal(prefix,
            remapped_identity(prefix .. ";stat=file:33188:-1:-2"))
        for _, malformed in ipairs({
            prefix .. ";stat=",
            prefix .. ";stat=file:33188:1",
            prefix .. ";stat=file:33188:1:2;semantic=A",
            prefix .. ";stat=other:33188:1:2",
            prefix .. ";stat=file:not-a-mode:1:2",
            prefix .. ";stat=file:33188:-:-2",
        }) do
            assert.equal(malformed, remapped_identity(malformed))
        end
    end)

    it("rejects invalid persistent cache configuration", function()
        local rejected, err = cprobe.new_service({
            persistent_cache_trace = false,
        })
        assert.is_nil(rejected)
        assert.matches("persistent_cache_trace must be a function",
            err, 1, true)

        rejected, err = cprobe.new_service({ semantic_trace = false })
        assert.is_nil(rejected)
        assert.matches("semantic_trace must be a function", err, 1, true)
        rejected, err = cprobe.new_service({ execution_trace = false })
        assert.is_nil(rejected)
        assert.matches("execution_trace must be a function", err, 1, true)
        rejected, err = cprobe.new_service({
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

    it("fails open when result close or rename fails", function()
        local cache = temporary_directory()
        local service = new_fake_service({ cache_directory = cache })
        local source = "int titan_result_publication_failure;\n"
        local semantic = {
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }

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
        local close_ok, close_result = pcall(function()
            return service:_publish_semantic_result(
                "result", "raw_source", source, "close-key", semantic)
        end)
        io.open = previous_open
        assert.is_true(close_ok)
        assert.equal("failed", close_result)
        assert.same({}, entries(cache))

        local previous_rename = os.rename
        os.rename = function()
            return nil, "injected rename failure"
        end
        local rename_ok, rename_result = pcall(function()
            return service:_publish_semantic_result(
                "result", "raw_source", source, "rename-key", semantic)
        end)
        assert.is_true(rename_ok)
        assert.equal("failed", rename_result)
        assert.same({}, entries(cache))
        os.rename = previous_rename

        assert.is_true(service:close())
        assert(lfs.rmdir(cache))
    end)

    it("keeps the first completed result across analysis publications",
    function()
        local analysis = cdriver.new_process_analysis()
        local first = new_fake_service({ process_analysis = analysis })
        local second = new_fake_service({ process_analysis = analysis })
        local third = new_fake_service({ process_analysis = analysis })
        local source = "int titan_analysis_publication_race;\n"
        local key = "shared-publication-key"
        local success = {
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }
        local rejection = {
            outcome = "compiler_rejection",
            exit_status = 1,
            diagnostic = "conflicting rejection",
        }

        assert.equal("disabled", first:_publish_semantic_result(
            "result", "raw_source", source, key, success))
        assert.equal("conflict", second:_publish_semantic_result(
            "result", "raw_source", source, key, rejection))

        local observed, tier = third:_lookup_semantic_result(
            "result", "candidate", "raw_source", source, key)
        assert.same(success, observed)
        assert.equal("analysis", tier)
        assert.equal("disabled", third:_publish_semantic_result(
            "result", "raw_source", source, key, success))

        assert.is_true(first:close())
        assert.is_true(second:close())
        assert.is_true(third:close())
    end)

    it("derives distinct trace keys for untraced analysis hits", function()
        local analysis = cdriver.new_process_analysis()
        local profile = target_profile()
        local publisher, publisher_state = new_fake_service({
            process_analysis = analysis,
            profile = profile,
        })
        local publisher_module = assert(publisher:module_context())
        local source = cpointer("analysis_trace_source")
        local target = cpointer("analysis_trace_target")
        local trait = assert(csemantics.decide_binary_operator(
            profile, "+", profile.integers.int.type, types.Integer()))

        local baseline = publisher_module:validate_baseline()
        local pointer = publisher_module:probe_unsafe_object_pointer(
            source, target)
        local operator = publisher_module:probe_operator(trait)
        assert.equal("success", baseline.status)
        assert.equal("success", pointer.status)
        assert.equal("success", operator.status)
        assert.equal(3, #publisher_state.calls)
        assert.is_nil(
            publisher.analysis_baseline_cache[baseline.key].key_digest)
        assert.is_nil(
            publisher.analysis_result_cache[pointer.key].key_digest)
        assert.is_nil(
            publisher.analysis_result_cache[operator.key].key_digest)

        local events = {}
        local consumer, consumer_state = new_fake_service({
            process_analysis = analysis,
            profile = profile,
            semantic_trace = function(event)
                events[#events + 1] = event
            end,
        }, function()
            error("analysis hits must not invoke the compiler")
        end)
        local consumer_module = assert(consumer:module_context())
        assert.equal("success", consumer_module:validate_baseline().status)
        assert.equal("success", consumer_module:probe_unsafe_object_pointer(
            source, target).status)
        assert.equal("success", consumer_module:probe_operator(trait).status)

        assert.equal(0, #consumer_state.calls)
        assert.equal(3, #events)
        local keys = {}
        for _, event in ipairs(events) do
            assert.matches("^[0-9a-f]+$", event.key)
            assert.equal(64, #event.key)
            assert.is_nil(keys[event.key])
            keys[event.key] = event.probe_kind
            assert.equal("analysis", event.cache_tier)
        end
        assert.equal("header_baseline",
            keys[consumer.semantic_trace_keys[baseline.key]])
        assert.equal("unsafe_object_pointer",
            keys[consumer.semantic_trace_keys[pointer.key]])
        assert.equal("c_operator",
            keys[consumer.semantic_trace_keys[operator.key]])
        assert.is_true(publisher:close())
        assert.is_true(consumer:close())
    end)

    it("returns the first winner to an interleaved semantic caller", function()
        local analysis = cdriver.new_process_analysis()
        local first_semantic_events = {}
        local first_execution_events = {}
        local first, first_state = new_fake_service({
            process_analysis = analysis,
            semantic_trace = function(event)
                first_semantic_events[#first_semantic_events + 1] = event
            end,
            execution_trace = function(event)
                first_execution_events[#first_execution_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            coroutine.yield("first semantic compiler")
            return { started = true, ok = true, status = 0 }
        end)
        local second, second_state = new_fake_service({
            process_analysis = analysis,
        }, function(_, _, metadata)
            assert.equal("candidate", metadata.stage)
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "first completed semantic rejection",
            }
        end)
        local first_module = assert(first:module_context())
        local second_module = assert(second:module_context())
        assert.equal("success", first_module:validate_baseline().status)

        local source = cpointer("publication_race_source")
        local target = cpointer("publication_race_target")
        local losing_result
        local task = coroutine.create(function()
            losing_result = first_module:probe_unsafe_object_pointer(
                source, target)
        end)
        local resumed, checkpoint = coroutine.resume(task)
        assert.is_true(resumed)
        assert.equal("first semantic compiler", checkpoint)

        local winner = second_module:probe_unsafe_object_pointer(
            source, target)
        assert.equal("rejected", winner.status)
        assert.equal("first completed semantic rejection", winner.diagnostic)
        local completed, completion_error = coroutine.resume(task)
        assert.is_true(completed, completion_error)
        assert.equal("dead", coroutine.status(task))

        -- The resumed physical compiler succeeded, but the earlier semantic
        -- rejection is authoritative inside this process analysis.
        assert.equal("rejected", losing_result.status)
        assert.is_false(losing_result.accepted)
        assert.is_true(losing_result.cached)
        assert.equal("analysis", losing_result.cache_tier)
        assert.equal("first completed semantic rejection",
            losing_result.diagnostic)
        assert.equal(2, #first_state.calls)
        assert.equal(1, #second_state.calls)
        assert.equal(2, #first_execution_events)
        assert.equal("success", first_execution_events[2].outcome)
        assert.equal("conflict", first_execution_events[2].publication)
        assert.is_true(first_execution_events[2].started)
        local semantic = first_semantic_events[#first_semantic_events]
        assert.equal("compiler_rejection", semantic.outcome)
        assert.equal("analysis", semantic.cache_tier)
        assert.equal("conflict", semantic.publication)

        local repeated = first_module:probe_unsafe_object_pointer(
            source, target)
        assert.equal("rejected", repeated.status)
        assert.is_true(repeated.cached)
        assert.equal("analysis", repeated.cache_tier)
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())
        assert.is_true(second:close())
    end)

    it("observes an in-analysis publication made during a persistent miss",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local analysis = cdriver.new_process_analysis()
        local source = "int titan_lookup_miss_publication_race;\n"
        local key = "lookup-miss-publication-race-key"
        local success = {
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }
        local lookup = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            cache_directory = cache,
        })
        local publisher = new_fake_service({
            io = strategy,
            process_analysis = analysis,
        })
        local path = assert(lookup:_persistent_success_location(source, key))
        local ordinary_stat = strategy.stat
        local yielded = false
        strategy.stat = function(self, candidate)
            if candidate == path and not yielded then
                yielded = true
                coroutine.yield("persistent miss stat")
                return nil, nil
            end
            return ordinary_stat(self, candidate)
        end

        local observed
        local tier
        local lookup_task = coroutine.create(function()
            observed, tier = lookup:_lookup_semantic_result(
                "result", "candidate", "raw_source", source, key)
        end)
        local resumed, checkpoint = coroutine.resume(lookup_task)
        assert.is_true(resumed)
        assert.equal("persistent miss stat", checkpoint)
        assert.equal("disabled", publisher:_publish_semantic_result(
            "result", "raw_source", source, key, success))
        local completed, completion_error = coroutine.resume(lookup_task)
        strategy.stat = ordinary_stat
        assert.is_true(completed, completion_error)
        assert.same(success, observed)
        assert.equal("analysis", tier)

        assert.is_true(lookup:close())
        assert.is_true(publisher:close())
        assert(lfs.rmdir(cache))
    end)

    it("lets an equal publisher commit while the first write is suspended",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local analysis = cdriver.new_process_analysis()
        local source = "int titan_equal_publication_race;\n"
        local key = "equal-publication-race-key"
        local success = {
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }
        local first = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            cache_directory = cache,
        })
        local second = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            cache_directory = cache,
        })
        local path = assert(first:_persistent_success_location(source, key))
        local ordinary_write_file = strategy.write_file
        local writes = 0
        strategy.write_file = function(self, candidate, contents)
            assert.equal(path, candidate)
            writes = writes + 1
            if writes == 1 then
                coroutine.yield("first persistent write")
                return nil, "injected first-writer failure"
            end
            return ordinary_write_file(self, candidate, contents)
        end

        local first_publication
        local first_task = coroutine.create(function()
            first_publication = first:_publish_semantic_result(
                "result", "raw_source", source, key, success)
        end)
        local resumed, checkpoint = coroutine.resume(first_task)
        assert.is_true(resumed)
        assert.equal("first persistent write", checkpoint)
        assert.equal("published", second:_publish_semantic_result(
            "result", "raw_source", source, key, success))
        local completed, completion_error = coroutine.resume(first_task)
        strategy.write_file = ordinary_write_file
        assert.is_true(completed, completion_error)
        assert.equal("existing", first_publication)
        assert.equal(2, writes)

        local fresh = new_fake_service({
            io = strategy,
            process_analysis = cdriver.new_process_analysis(),
            cache_directory = cache,
        })
        local observed, tier = fresh:_lookup_semantic_result(
            "result", "candidate", "raw_source", source, key)
        assert.same(success, observed)
        assert.equal("persistent", tier)

        assert.is_true(first:close())
        assert.is_true(second:close())
        assert.is_true(fresh:close())
        assert(os.remove(path))
        assert(lfs.rmdir(cache))
    end)

    it("accepts a cache-directory creation race", function()
        local strategy = compiler_io.new_sync()
        local service = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = "/cache",
        }))
        local cache_stats = 0
        strategy.stat = function(_, path)
            if path == "/" then return { kind = "directory" } end
            assert.equal("/cache", path)
            cache_stats = cache_stats + 1
            if cache_stats == 1 then return nil, "not found" end
            return { kind = "directory" }
        end
        strategy.mkdir = function(_, path)
            assert.equal("/cache", path)
            return nil, "already created concurrently"
        end
        strategy.write_file = function(_, path, contents)
            assert.matches("^/cache/[0-9a-f]+[.]negative$", path)
            assert.is_true(#contents > 32)
            return true
        end

        local publication = service:_publish_semantic_result(
            "result", "raw_source", "int value;\n", "key", {
                outcome = "compiler_rejection",
                exit_status = 1,
                diagnostic = "rejected",
            })
        assert.equal("published", publication)
        assert.equal(2, cache_stats)
        assert.is_true(service:close())
    end)

    it("retains only the committed negative when publication is cancelled",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local ordinary_write = strategy.write_file
        local cancellation = { kind = "simulated cancellation" }
        local publication_path
        strategy.write_file = function(self, path, contents)
            local written, err = ordinary_write(self, path, contents)
            if written and path:match("%.negative$") then
                publication_path = path
                error(cancellation)
            end
            return written, err
        end

        local source = "int titan_cancelled_result_publication;\n"
        local first, first_state = new_fake_service({
            cache_directory = cache,
            io = strategy,
        }, function()
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "cancelled publication rejection",
            }
        end)
        local completed, reason = pcall(
            first._run_source, first, "candidate", source, "same-key")
        assert.is_false(completed)
        assert.equal(cancellation, reason)
        assert.equal(1, #first_state.calls)

        local success_path = first:_persistent_success_location(
            source, "same-key")
        local expected_path = success_path:gsub("[.]success$", ".negative")
        assert.equal(expected_path, publication_path)
        assert.same({ expected_path:match("([^/]+)$") }, entries(cache))
        assert.is_true(first:close())

        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("a committed result must not invoke the compiler")
        end)
        local hit = second:_run_source("candidate", source, "same-key")
        assert.is_false(hit.ok)
        assert.equal("compiler_rejection", hit.classification)
        assert.is_true(hit.persistent_cached)
        assert.equal(expected_path, hit.cache_path)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())

        assert(os.remove(expected_path))
        assert(lfs.rmdir(cache))
    end)

    it("bounds the bytes read after a persistent-record stat race", function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local service = assert(cprobe.new_service({
            io = strategy,
            cache_directory = cache,
        }))
        local source = "int titan_oversized_result;\n"
        local success_path = assert(service:_persistent_success_location(
            source, "oversized-key"))
        local path = success_path:gsub("[.]success$", ".negative")
        write_file(path, string.rep("x", 1024 * 1024 + 1024))
        local ordinary_stat = strategy.stat
        local ordinary_read_file = strategy.read_file
        strategy.stat = function(_, candidate)
            if candidate == path then
                return { kind = "file", size = 1 }
            end
            return ordinary_stat(strategy, candidate)
        end
        strategy.read_file = function(_, candidate, max_bytes)
            local contents, err = ordinary_read_file(
                strategy, candidate, max_bytes)
            if candidate == path then
                assert.equal(1024 * 1024 + 256, max_bytes)
                assert.equal(max_bytes + 1, #contents)
            end
            return contents, err
        end

        local result, _, _, lookup = service:_read_persistent_result(
            "candidate", "raw_source", source, "oversized-key")
        strategy.stat = ordinary_stat
        strategy.read_file = ordinary_read_file
        assert.is_nil(result)
        assert.equal("invalid", lookup)
        assert.is_true(service:close())
        assert(os.remove(path))
        assert(lfs.rmdir(cache))
    end)

    it("keeps an in-analysis publication made during a persistent read",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local source = "int titan_lookup_publication_race;\n"
        local key = "lookup-publication-race-key"
        local rejection = {
            outcome = "compiler_rejection",
            exit_status = 1,
            diagnostic = "stale persistent rejection",
        }
        local success = {
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }
        local seed = new_fake_service({
            io = strategy,
            cache_directory = cache,
        })
        local publication, _, path = seed:_publish_semantic_result(
            "result", "raw_source", source, key, rejection)
        assert.equal("published", publication)
        assert.is_true(seed:close())

        local analysis = cdriver.new_process_analysis()
        local lookup = new_fake_service({
            io = strategy,
            process_analysis = analysis,
            cache_directory = cache,
        })
        local publisher = new_fake_service({
            io = strategy,
            process_analysis = analysis,
        })
        local ordinary_read_file = strategy.read_file
        local yielded = false
        strategy.read_file = function(self, candidate, max_bytes)
            local contents, err = ordinary_read_file(
                self, candidate, max_bytes)
            if candidate == path and not yielded then
                yielded = true
                coroutine.yield("persistent record read")
            end
            return contents, err
        end

        local observed
        local tier
        local lookup_task = coroutine.create(function()
            observed, tier = lookup:_lookup_semantic_result(
                "result", "candidate", "raw_source", source, key)
        end)
        local resumed, checkpoint = coroutine.resume(lookup_task)
        assert.is_true(resumed)
        assert.equal("persistent record read", checkpoint)
        assert.equal("disabled", publisher:_publish_semantic_result(
            "result", "raw_source", source, key, success))
        assert.is_true(coroutine.resume(lookup_task))
        strategy.read_file = ordinary_read_file
        assert.equal("dead", coroutine.status(lookup_task))
        assert.same(success, observed)
        assert.equal("analysis", tier)

        local third = new_fake_service({
            io = strategy,
            process_analysis = analysis,
        })
        local third_result, third_tier = third:_lookup_semantic_result(
            "result", "candidate", "raw_source", source, key)
        assert.same(success, third_result)
        assert.equal("analysis", third_tier)

        assert.is_true(lookup:close())
        assert.is_true(publisher:close())
        assert.is_true(third:close())
        assert(os.remove(path))
        assert(lfs.rmdir(cache))
    end)

    it("never promotes a valid cached baseline rejection to success", function()
        local cache = temporary_directory()
        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local first_result = assert(first:module_context()):validate_baseline()
        assert.equal("success", first_result.status)
        assert.equal(1, #first_state.calls)
        local success_path, digest = first:_persistent_success_location(
            first_result.source, first_result.key)
        assert(os.remove(success_path))
        local path = success_path:gsub("[.]success$", ".negative")
        local forged = assert(cprobe_cache.encode({
            key_digest = digest,
            outcome = "compiler_rejection",
            exit_status = 1,
            diagnostic = "forged baseline rejection",
        }))
        write_file(path, forged)
        assert.is_true(first:close())

        local retried, retried_state = new_fake_service({
            cache_directory = cache,
        })
        local retried_result =
            assert(retried:module_context()):validate_baseline()
        assert.equal("success", retried_result.status)
        assert.is_false(retried_result.cached)
        assert.equal(1, #retried_state.calls)
        assert.is_true(retried:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("preserves the exact v3 digest for success and negative files",
    function()
        local cache = temporary_directory()
        local function options()
            return {
                compiler_argv = { "cc" },
                compile_flags = {},
                language_mode = "c99",
                language_flag = false,
                cppflags = {},
                cflags = {},
                include_dirs = {},
                profile_identity = "",
                cache_directory = cache,
            }
        end

        local first, first_state = new_fake_service(options())
        local module = assert(first:module_context({
            cwd = "/project",
            source_dir = "/project",
        }))
        local source = cprobe.render_baseline_source(module)
        local key = module.baseline_key
        local success_path, digest = first:_persistent_success_location(
            source, key)
        assert.equal(
            "9dd4b19f0ac7bafbaace8b4e7f95dd4dce5bfdbb7cab552e57ff800fde8c44de",
            digest)
        assert.equal(cache .. "/" .. digest .. ".success", success_path)

        local success = first:_run_source("baseline", source, key)
        assert.is_true(success.ok)
        assert.equal(success_path, success.cache_path)
        assert.equal(0, assert(lfs.attributes(success_path)).size)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())
        assert(os.remove(success_path))

        local rejecting, rejecting_state = new_fake_service(
            options(), function()
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = "golden rejection",
                }
            end)
        local rejection = rejecting:_run_source("baseline", source, key)
        assert.is_false(rejection.ok)
        assert.equal("compiler_rejection", rejection.classification)
        local negative_path = cache .. "/" .. digest .. ".negative"
        assert.equal(negative_path, rejection.cache_path)
        assert.is_true(assert(lfs.attributes(negative_path)).size > 32)
        assert.equal(1, #rejecting_state.calls)
        assert.is_true(rejecting:close())

        local repeated, repeated_state = new_fake_service(
            options(), function()
                error("the golden negative must not invoke the compiler")
            end)
        local hit = repeated:_run_source("baseline", source, key)
        assert.is_false(hit.ok)
        assert.equal("compiler_rejection", hit.classification)
        assert.is_true(hit.persistent_cached)
        assert.equal(negative_path, hit.cache_path)
        assert.equal(0, #repeated_state.calls)
        assert.is_true(repeated:close())

        assert(os.remove(negative_path))
        assert(lfs.rmdir(cache))
    end)

    it("stores compiler rejection but never infrastructure failure", function()
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
        local cached_files = entries(cache)
        assert.equal(1, #cached_files)
        assert.matches("[.]negative$", cached_files[1])

        local repeated, repeated_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("a deterministic rejection must not invoke the compiler")
        end)
        local hit = repeated:_run_source(
            "candidate", "int titan_failure_1;\n", "failure-key")
        assert.is_false(hit.ok)
        assert.equal("compiler_rejection", hit.classification)
        assert.is_true(hit.persistent_cached)
        assert.equal(0, #repeated_state.calls)
        assert.is_true(repeated:close())
        assert(os.remove(cache .. "/" .. cached_files[1]))
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
        local execution_events = {}
        local service = assert(cprobe.new_service({
            cache_directory = cache,
            runner = runner,
            temp_provider = provider,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }))
        local run = service:_run_source(
            "candidate", "int titan_cleanup_failure;\n", "cleanup-key")
        assert.is_false(run.ok)
        assert.is_true(run.started)
        assert.is_true(run.cleanup_error)
        assert.equal("infrastructure_failure", run.classification)
        assert.equal(1, #execution_events)
        assert.is_true(execution_events[1].started)
        assert.equal("infrastructure_failure", execution_events[1].outcome)
        assert.same({}, entries(cache))
        -- The injected provider cannot close cleanly; the semantic assertion is
        -- that it still did not publish a semantic result.
        service:close()
        assert(lfs.rmdir(cache))
    end)

    it("stabilizes randomized source-foreign headers before cache lookup",
    function()
        local cache = temporary_directory()
        local generated_digest = string.rep("a", 64)
        local function alias_for(physical, stat_identity)
            local include = assert(cprobe.normalize_include_descriptor({
                include_kind = "quote",
                include_name = physical,
                c_header_dependencies = {{
                    kind = "file",
                    path = physical,
                    identity = "c-header-file-v1:sha256:" ..
                        generated_digest .. ";stat=" .. stat_identity,
                }},
            }, { source_dir = "." }))
            return assert(cprobe.source_foreign_include_alias(
                include, "provider.module", "/project/provider.titan.h"))
        end

        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local first_module = assert(first:module_context({
            includes = {
                alias_for("/tmp/provider-check-one.h", "file:33188:1:2"),
            },
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
            includes = {
                alias_for("/tmp/provider-check-two.h", "file:33188:3:4"),
            },
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

    it("keeps successful diagnostics in service memory only",
    function()
        local cache = temporary_directory()
        local public = "/project/provider.titan.h"
        local nested_public = "/project/nested.titan.h"
        local digest = string.rep("b", 64)
        local function alias_for(physical, nested_physical)
            local include = assert(cprobe.normalize_include_descriptor({
                include_kind = "quote",
                include_name = physical,
                c_header_dependencies = {{
                    kind = "file",
                    path = physical,
                    identity = "c-header-file-v1:sha256:" .. digest ..
                        ";stat=file:33188:1:2",
                }},
            }, { source_dir = "." }))
            return assert(cprobe.source_foreign_include_alias(
                include, "provider.module", public, {{
                    physical_path = nested_physical,
                    public_path = nested_public,
                }}))
        end

        local function warning_runner(physical, nested)
            return function(_, _, metadata, state)
                local wrapper_name
                for name in pairs(state.files) do
                    if name:match("^titan%-source%-foreign%-.*[.]h$") then
                        wrapper_name = name
                    end
                end
                assert.is_string(wrapper_name)
                local root = assert(
                    metadata.source_path:match("^(.*)/[^/]+$"))
                return {
                    started = true,
                    ok = true,
                    status = 0,
                    diagnostic = table.concat({
                        "In file included from " .. root .. "/" ..
                            wrapper_name .. ":1:",
                        physical .. ":2: warning: generated",
                        nested .. ":3: warning: nested",
                        metadata.source_path .. ":4: note: probe",
                    }, "\n"),
                }
            end
        end

        local first_physical = "/tmp/provider-check-one.h"
        local first_nested = "/tmp/nested-check-one.h"
        local first, first_state = new_fake_service({
            cache_directory = cache,
        }, warning_runner(first_physical, first_nested))
        local first_module = assert(first:module_context({
            includes = { alias_for(first_physical, first_nested) },
        }))
        local first_result = first_module:validate_baseline()
        assert.equal("success", first_result.status)
        assert.matches(public, first_result.diagnostic, 1, true)
        assert.matches(nested_public, first_result.diagnostic, 1, true)
        assert.matches("<titan-cprobe-source>:4", first_result.diagnostic,
            1, true)
        assert.is_nil(first_result.diagnostic:find(
            "/fake/titan probe", 1, true))
        assert.is_nil(first_result.diagnostic:find(first_physical, 1, true))
        assert.is_nil(first_result.diagnostic:find(first_nested, 1, true))
        assert.equal(1, #first_state.calls)
        local memory_result = first_module:validate_baseline()
        assert.is_true(memory_result.cached)
        assert.equal("service", memory_result.cache_tier)
        assert.equal(first_result.diagnostic, memory_result.diagnostic)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())
        assert.same({}, entries(cache))

        local second_physical = "/tmp/provider-check-two.h"
        local second_nested = "/tmp/nested-check-two.h"
        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, warning_runner(second_physical, second_nested))
        local second_module = assert(second:module_context({
            includes = { alias_for(second_physical, second_nested) },
        }))
        local second_result = second_module:validate_baseline()
        assert.is_false(second_result.persistent_cached == true)
        assert.equal(first_result.diagnostic, second_result.diagnostic)
        assert.equal(1, #second_state.calls)
        assert.is_true(second:close())
        assert.same({}, entries(cache))
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

    it("reuses deterministic pointer rejections across an analysis and process",
    function()
        local cache = temporary_directory()
        local analysis = cdriver.new_process_analysis()
        local diagnostic = "probe.c:11: error: incompatible pointer types\0tail"
        local function rejecting_service(extra)
            extra = extra or {}
            extra.cache_directory = cache
            return new_fake_service(extra, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return {
                    started = true,
                    ok = false,
                    status = 1,
                    diagnostic = diagnostic,
                }
            end)
        end
        local source = cpointer("negative_source")
        local target = cpointer("negative_target")

        local first, first_state = rejecting_service({
            process_analysis = analysis,
        })
        local first_result = assert(first:module_context()):
            probe_unsafe_object_pointer(source, target)
        assert.equal("rejected", first_result.status)
        assert.equal(diagnostic, first_result.diagnostic)
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())

        local same_analysis, analysis_state = rejecting_service({
            process_analysis = analysis,
        })
        local analysis_result = assert(same_analysis:module_context()):
            probe_unsafe_object_pointer(source, target)
        assert.equal("rejected", analysis_result.status)
        assert.equal("analysis", analysis_result.cache_tier)
        assert.equal(diagnostic, analysis_result.diagnostic)
        assert.equal(0, #analysis_state.calls)
        assert.is_true(same_analysis:close())

        local other_process, process_state = rejecting_service({
            process_analysis = cdriver.new_process_analysis(),
        })
        local process_result = assert(other_process:module_context()):
            probe_unsafe_object_pointer(source, target)
        assert.equal("rejected", process_result.status)
        assert.equal("persistent", process_result.cache_tier)
        assert.is_true(process_result.persistent_cached)
        assert.equal(diagnostic, process_result.diagnostic)
        assert.equal(0, #process_state.calls)
        assert.is_true(other_process:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("persists exact rejected declaration batches and their refinements",
    function()
        local cache = temporary_directory()
        local first, first_state = new_fake_service({
            cache_directory = cache,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" or
               not metadata.source:find("rejected_bad", 1, true) then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "declaration candidate rejected",
            }
        end)
        local accepted_first = {
            left_type = cpointer("accepted_first_left"),
            right_type = cpointer("accepted_first_right"),
        }
        local accepted_second = {
            left_type = cpointer("accepted_second_left"),
            right_type = cpointer("accepted_second_right"),
        }
        local rejected = {
            left_type = cpointer("rejected_bad_left"),
            right_type = cpointer("rejected_bad_right"),
        }
        local accepted_fourth = {
            left_type = cpointer("accepted_fourth_left"),
            right_type = cpointer("accepted_fourth_right"),
        }
        local candidates = {
            accepted_first,
            accepted_second,
            rejected,
            accepted_fourth,
        }
        local first_results = assert(first:module_context()):
            validate_declaration_compatibilities(candidates)
        assert.equal("success", first_results[1].status)
        assert.equal("success", first_results[2].status)
        assert.equal("rejected", first_results[3].status)
        assert.equal("success", first_results[4].status)
        -- Baseline; rejected four-pair batch; accepted left half; rejected
        -- right half; then its rejected and accepted singleton leaves.
        assert.equal(6, #first_state.calls)

        -- Every compiler result in that bisection tree has its own exact
        -- historical source/key evidence on disk. The rejected aggregate,
        -- rejected sub-batch, and rejected singleton use negative records;
        -- the accepted sub-batch and singleton retain empty success markers.
        for index = 2, 6 do
            local metadata = first_state.calls[index].metadata
            local success_path = assert(first:_persistent_success_location(
                metadata.source, metadata.key))
            local expected_path = metadata.source:find(
                "rejected_bad", 1, true) and success_path:gsub(
                    "[.]success$", ".negative") or success_path
            assert.equal("file", lfs.attributes(expected_path, "mode"))
        end
        assert.equal(6, #entries(cache))
        assert.is_true(first:close())

        local identical, identical_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("the identical rejected batch tree must be fully cached")
        end)
        local identical_results = assert(identical:module_context()):
            validate_declaration_compatibilities(candidates)
        assert.same({ "success", "success", "rejected", "success" }, {
            identical_results[1].status,
            identical_results[2].status,
            identical_results[3].status,
            identical_results[4].status,
        })
        for index = 1, 4 do
            assert.is_true(identical_results[index].persistent_cached)
        end
        assert.equal(0, #identical_state.calls)
        assert.is_true(identical:close())

        local repeated, repeated_state = new_fake_service({
            cache_directory = cache,
        }, function(_, _, metadata)
            assert.equal("candidate", metadata.stage)
            assert.matches("rejected_bad_left", metadata.source, 1, true)
            assert.matches("accepted_first_left", metadata.source, 1, true)
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "regrouped batch rejected",
            }
        end)
        local repeated_results = assert(repeated:module_context()):
            validate_declaration_compatibilities({
                rejected,
                accepted_fourth,
                accepted_first,
                accepted_second,
            })
        assert.equal("rejected", repeated_results[1].status)
        assert.equal("success", repeated_results[2].status)
        assert.equal("success", repeated_results[3].status)
        assert.equal("success", repeated_results[4].status)
        for index = 1, 4 do
            assert.equal("persistent", repeated_results[index].cache_tier)
        end
        -- The reordered aggregate has a distinct historical batch key and
        -- must run once. Its exact rejected/accepted half batches and the
        -- rejected half's singleton children then reuse the first tree.
        assert.equal(1, #repeated_state.calls)
        local regrouped = repeated_state.calls[1].metadata
        local regrouped_success_path =
            assert(repeated:_persistent_success_location(
                regrouped.source, regrouped.key))
        local regrouped_negative_path = regrouped_success_path:gsub(
            "[.]success$", ".negative")
        assert.equal("file",
            lfs.attributes(regrouped_negative_path, "mode"))
        assert.is_true(repeated:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("never persists declaration-batch infrastructure failures", function()
        local cache = temporary_directory()
        local candidates = {
            {
                left_type = cpointer("infrastructure_first_left"),
                right_type = cpointer("infrastructure_first_right"),
            },
            {
                left_type = cpointer("infrastructure_second_left"),
                right_type = cpointer("infrastructure_second_right"),
            },
        }
        local function service_with_failure()
            return new_fake_service({
                cache_directory = cache,
            }, function(_, _, metadata)
                if metadata.stage == "baseline" then
                    return { started = true, ok = true, status = 0 }
                end
                return nil, "configured compiler could not be started"
            end)
        end

        local first, first_state = service_with_failure()
        local first_results = assert(first:module_context()):
            validate_declaration_compatibilities(candidates)
        for index = 1, 2 do
            assert.equal("infrastructure_failure",
                first_results[index].status)
        end
        assert.equal(2, #first_state.calls)
        -- Only the successful baseline is durable.
        assert.equal(1, #entries(cache))
        assert.is_true(first:close())

        local repeated, repeated_state = service_with_failure()
        local repeated_results = assert(repeated:module_context()):
            validate_declaration_compatibilities(candidates)
        for index = 1, 2 do
            assert.equal("infrastructure_failure",
                repeated_results[index].status)
        end
        -- The baseline hits, but the failed aggregate must be launched again.
        assert.equal(1, #repeated_state.calls)
        assert.equal(1, #entries(cache))
        assert.is_true(repeated:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("uses historical batch sources and keys for durable declarations",
    function()
        local cache = temporary_directory()
        local candidate = {
            left_type = cpointer("durable_singleton_left"),
            right_type = cpointer("durable_singleton_right"),
        }
        local first, first_state = new_fake_service({
            cache_directory = cache,
        })
        local module = assert(first:module_context())
        local result = module:validate_declaration_compatibilities({
            candidate,
        })[1]
        assert.equal("success", result.status)
        assert.equal(2, #first_state.calls)

        local expected_source = table.concat({
            module.header_preamble,
            "",
            "#if defined(__clang__)",
            "# pragma clang diagnostic push",
            '# pragma clang diagnostic ignored "-Wunused-variable"',
            "#elif defined(__GNUC__)",
            "# pragma GCC diagnostic push",
            '# pragma GCC diagnostic ignored "-Wunused-variable"',
            "# if __GNUC__ >= 13",
            '#  pragma GCC diagnostic ignored "-Wenum-int-mismatch"',
            "# endif",
            "#endif",
            "extern " .. result.left_declaration .. ";",
            "extern " .. result.right_declaration .. ";",
            "#if defined(__clang__)",
            "# pragma clang diagnostic pop",
            "#elif defined(__GNUC__)",
            "# pragma GCC diagnostic pop",
            "#endif",
            "",
        }, "\n")
        assert.equal(expected_source, result.source)

        local singleton_batch_key = keyed_fields({
            { "toolchain", first.toolchain_key },
            { "headers", module.header_key },
            { "probe_kind", "declaration_compatibility_batch" },
            { "candidate_1", result.key },
        })
        local singleton_path, singleton_digest =
            first:_persistent_success_location(
                expected_source, singleton_batch_key)
        assert.equal(cache .. "/" .. singleton_digest .. ".success",
            singleton_path)
        assert.equal("file", lfs.attributes(singleton_path, "mode"))
        assert.equal(0, assert(lfs.attributes(singleton_path)).size)
        local leaf_path = first:_persistent_success_location(
            expected_source, result.key)
        assert.not_equal(singleton_path, leaf_path)
        assert.is_nil(lfs.attributes(leaf_path))
        assert.is_true(first:close())

        local singleton_hit, singleton_hit_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("the exact singleton batch marker must be reused")
        end)
        local singleton_result = assert(singleton_hit:module_context()):
            validate_declaration_compatibilities({ candidate })[1]
        assert.equal("success", singleton_result.status)
        assert.is_true(singleton_result.persistent_cached)
        assert.equal(0, #singleton_hit_state.calls)
        assert.is_true(singleton_hit:close())

        local candidates = {
            {
                left_type = cpointer("durable_batch_left_one"),
                right_type = cpointer("durable_batch_right_one"),
            },
            {
                left_type = cpointer("durable_batch_left_two"),
                right_type = cpointer("durable_batch_right_two"),
            },
        }
        local batch, batch_state = new_fake_service({
            cache_directory = cache,
        })
        local batch_module = assert(batch:module_context())
        local batch_results =
            batch_module:validate_declaration_compatibilities(candidates)
        assert.equal(1, #batch_state.calls)
        local batch_key = keyed_fields({
            { "toolchain", batch.toolchain_key },
            { "headers", batch_module.header_key },
            { "probe_kind", "declaration_compatibility_batch" },
            { "candidate_1", batch_results[1].key },
            { "candidate_2", batch_results[2].key },
        })
        local batch_path = batch:_persistent_success_location(
            batch_results[1].source, batch_key)
        assert.equal("file", lfs.attributes(batch_path, "mode"))
        assert.equal(0, assert(lfs.attributes(batch_path)).size)
        assert.is_true(batch:close())

        local batch_hit, batch_hit_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("the exact historical batch marker must be reused")
        end)
        local repeated = assert(batch_hit:module_context()):
            validate_declaration_compatibilities(candidates)
        for index = 1, 2 do
            assert.equal("success", repeated[index].status)
            assert.is_true(repeated[index].persistent_cached)
        end
        assert.equal(0, #batch_hit_state.calls)
        assert.is_true(batch_hit:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("refines successful declaration batch warnings into exact leaves",
    function()
        local cache = temporary_directory()
        local function warning_runner(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            local has_first = metadata.source:find(
                "warning_first", 1, true) ~= nil
            local has_second = metadata.source:find(
                "warning_second", 1, true) ~= nil
            local diagnostic = has_first and has_second and
                "probe.c:1: warning: batch diagnostic" or
                has_first and "probe.c:2: warning: first leaf" or
                "probe.c:3: warning: second leaf"
            return {
                started = true,
                ok = true,
                status = 0,
                diagnostic = diagnostic,
            }
        end
        local first, first_state = new_fake_service({
            cache_directory = cache,
        }, warning_runner)
        local candidates = {
            {
                left_type = cpointer("warning_first_left"),
                right_type = cpointer("warning_first_right"),
            },
            {
                left_type = cpointer("warning_second_left"),
                right_type = cpointer("warning_second_right"),
            },
        }
        local first_results = assert(first:module_context()):
            validate_declaration_compatibilities(candidates)
        assert.equal("success", first_results[1].status)
        assert.equal("success", first_results[2].status)
        assert.equal("probe.c:2: warning: first leaf",
            first_results[1].diagnostic)
        assert.equal("probe.c:3: warning: second leaf",
            first_results[2].diagnostic)
        -- Baseline, successful warning batch, then two singleton refinements.
        assert.equal(4, #first_state.calls)
        assert.is_true(first:close())

        local repeated, repeated_state = new_fake_service({
            cache_directory = cache,
        }, warning_runner)
        local repeated_results = assert(repeated:module_context()):
            validate_declaration_compatibilities(candidates)
        assert.equal("probe.c:2: warning: first leaf",
            repeated_results[1].diagnostic)
        assert.equal("probe.c:3: warning: second leaf",
            repeated_results[2].diagnostic)
        for index = 1, 2 do
            assert.equal("success", repeated_results[index].status)
            assert.equal("compiler", repeated_results[index].cache_tier)
            assert.is_false(
                repeated_results[index].persistent_cached == true)
        end
        -- The empty baseline marker is reused, while the warning-bearing
        -- batch and two exact singleton diagnostics remain memory-only.
        assert.equal(3, #repeated_state.calls)
        assert.is_true(repeated:close())

        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("keeps a post-spawn missing baseline status retryable", function()
        local cache = temporary_directory()
        local execution_events = {}
        local service, state = new_fake_service({
            cache_directory = cache,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function()
            return {
                started = true,
                ok = false,
                diagnostic = "capture failed after baseline spawn",
            }
        end)
        local module = assert(service:module_context())

        for _ = 1, 2 do
            local result = module:validate_baseline()
            assert.equal("infrastructure_failure", result.status)
            assert.is_nil(result.accepted)
            assert.equal("malformed_runner_result", result.reason)
        end
        assert.equal(2, #state.calls)
        assert.equal(2, #execution_events)
        for _, event in ipairs(execution_events) do
            assert.equal("header_baseline", event.probe_kind)
            assert.equal("infrastructure_failure", event.outcome)
            assert.is_true(event.started)
            assert.equal("not_applicable", event.publication)
        end
        assert.same({}, entries(cache))
        assert.is_true(service:close())
        assert(lfs.rmdir(cache))
    end)

    it("keeps a post-spawn invalid pointer status out of semantic caches",
    function()
        local cache = temporary_directory()
        local execution_events = {}
        local service, state = new_fake_service({
            cache_directory = cache,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = "missing wait status",
                diagnostic = "capture failed after pointer spawn",
            }
        end)
        local module = assert(service:module_context())
        for _ = 1, 2 do
            local result = module:probe_unsafe_object_pointer(
                cpointer("post_spawn_pointer_source"),
                cpointer("post_spawn_pointer_target"))
            assert.equal("infrastructure_failure", result.status)
            assert.is_nil(result.accepted)
            assert.equal("malformed_runner_result", result.reason)
        end
        assert.equal(3, #state.calls)
        assert.equal(3, #execution_events)
        for index = 2, 3 do
            local event = execution_events[index]
            assert.equal("unsafe_object_pointer", event.probe_kind)
            assert.equal("infrastructure_failure", event.outcome)
            assert.is_true(event.started)
            assert.equal("not_applicable", event.publication)
        end
        assert.equal(1, #entries(cache))
        assert.is_true(service:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("keeps a post-spawn missing operator status retryable", function()
        local cache = temporary_directory()
        local execution_events = {}
        local profile = target_profile()
        local trait = assert(csemantics.decide_binary_operator(
            profile, "+", profile.integers.int.type, types.Integer()))
        local service, state = new_fake_service({
            cache_directory = cache,
            profile = profile,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                diagnostic = "capture failed after operator spawn",
            }
        end)
        local module = assert(service:module_context())
        for _ = 1, 2 do
            local result = module:probe_operator(trait)
            assert.equal("infrastructure_failure", result.status)
            assert.is_nil(result.accepted)
            assert.equal("malformed_runner_result", result.reason)
        end
        assert.equal(3, #state.calls)
        assert.equal(3, #execution_events)
        for index = 2, 3 do
            local event = execution_events[index]
            assert.equal("c_operator", event.probe_kind)
            assert.equal("infrastructure_failure", event.outcome)
            assert.is_true(event.started)
            assert.equal("not_applicable", event.publication)
        end
        assert.equal(1, #entries(cache))
        assert.is_true(service:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("keeps a post-spawn missing declaration status retryable", function()
        local cache = temporary_directory()
        local execution_events = {}
        local profile = target_profile()
        local service, state = new_fake_service({
            cache_directory = cache,
            profile = profile,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                diagnostic = "capture failed after declaration spawn",
            }
        end)
        local int = profile.integers.int.type
        local candidate = {
            left_type = types.CTypedef("post_spawn_left", int),
            right_type = types.CTypedef("post_spawn_right", int),
        }
        local module = assert(service:module_context())
        for _ = 1, 2 do
            local result = module:validate_declaration_compatibility(
                candidate.left_type, candidate.right_type)
            assert.equal("infrastructure_failure", result.status)
            assert.is_nil(result.accepted)
            assert.equal("malformed_runner_result", result.reason)
        end
        assert.equal(3, #state.calls)
        assert.equal(3, #execution_events)
        for index = 2, 3 do
            local event = execution_events[index]
            assert.equal("declaration_compatibility", event.probe_kind)
            assert.equal("infrastructure_failure", event.outcome)
            assert.is_true(event.started)
            assert.equal("not_applicable", event.publication)
        end
        assert.equal(1, #entries(cache))
        assert.is_true(service:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("traces distinct no-cache semantics and declaration leaves",
    function()
        local events = {}
        local service, state = new_fake_service({
            semantic_trace = function(event)
                events[#events + 1] = event
            end,
        })
        local module = assert(service:module_context())
        local first_source = cpointer("no_cache_trace_source_one")
        local first_target = cpointer("no_cache_trace_target_one")
        assert.equal("success", module:probe_unsafe_object_pointer(
            first_source, first_target).status)
        assert.equal("success", module:probe_unsafe_object_pointer(
            first_source, first_target).status)
        assert.equal("success", module:probe_unsafe_object_pointer(
            cpointer("no_cache_trace_source_two"),
            cpointer("no_cache_trace_target_two")).status)

        local pointer_events = {}
        for _, event in ipairs(events) do
            if event.probe_kind == "unsafe_object_pointer" then
                pointer_events[#pointer_events + 1] = event
            end
        end
        assert.equal(3, #pointer_events)
        assert.matches("^[0-9a-f]+$", pointer_events[1].key)
        assert.equal(64, #pointer_events[1].key)
        assert.equal(pointer_events[1].key, pointer_events[2].key)
        assert.not_equal(pointer_events[1].key, pointer_events[3].key)
        assert.is_false(pointer_events[1].repeated)
        assert.is_true(pointer_events[2].repeated)
        assert.is_false(pointer_events[3].repeated)

        local declaration_start = #events
        local declarations = module:validate_declaration_compatibilities({
            {
                left_type = cpointer("no_cache_leaf_left_one"),
                right_type = cpointer("no_cache_leaf_right_one"),
            },
            {
                left_type = cpointer("no_cache_leaf_left_two"),
                right_type = cpointer("no_cache_leaf_right_two"),
            },
        })
        assert.equal("success", declarations[1].status)
        assert.equal("success", declarations[2].status)
        local declaration_events = {}
        for index = declaration_start + 1, #events do
            local event = events[index]
            if event.probe_kind == "declaration_compatibility" then
                declaration_events[#declaration_events + 1] = event
            end
        end
        assert.equal(2, #declaration_events)
        assert.matches("^[0-9a-f]+$", declaration_events[1].key)
        assert.matches("^[0-9a-f]+$", declaration_events[2].key)
        assert.equal(64, #declaration_events[1].key)
        assert.equal(64, #declaration_events[2].key)
        assert.not_equal(declaration_events[1].key,
            declaration_events[2].key)
        assert.is_false(declaration_events[1].repeated)
        assert.is_false(declaration_events[2].repeated)
        assert.equal(4, #state.calls)
        assert.is_true(service:close())
    end)

    it("classifies runners strictly and emits nonoverlapping lifecycle traces",
    function()
        local untraced = new_fake_service()
        local untraced_run = untraced:_run_source(
            "candidate", "int titan_untraced_execution;\n", "untraced")
        assert.is_nil(untraced_run.execution_digest)
        assert.is_true(untraced:close())

        local semantic_events = {}
        local execution_events = {}
        local service, state = new_fake_service({
            semantic_trace = function(event)
                semantic_events[#semantic_events + 1] = event
            end,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return {
                    started = true, ok = true, status = 0, wall_ms = 2.25,
                }
            end
            return {
                started = true, ok = false, status = 1,
                wall_ms = 7.5, diagnostic = "expected rejection",
            }
        end)
        local module = assert(service:module_context({
            includes = { "trace-first.h", "trace-second.h" },
        }))
        local source = cpointer("traced_source")
        local target = cpointer("traced_target")
        assert.equal("rejected",
            module:probe_unsafe_object_pointer(source, target).status)
        assert.equal("rejected",
            module:probe_unsafe_object_pointer(source, target).status)
        assert.equal(2, #state.calls)
        assert.equal(2, #execution_events)
        assert.equal(2.25, execution_events[1].wall_ms)
        assert.equal(7.5, execution_events[2].wall_ms)
        assert.equal("success", execution_events[1].outcome)
        assert.equal("compiler_rejection", execution_events[2].outcome)
        assert.is_true(execution_events[1].started)
        assert.is_true(execution_events[2].started)
        assert.equal("<trace-first.h>, <trace-second.h>",
            execution_events[1].header_label)
        assert.equal(execution_events[1].header_label,
            execution_events[2].header_label)
        assert.equal(3, #semantic_events)
        assert.equal("header_baseline", semantic_events[1].probe_kind)
        assert.equal("compiler", semantic_events[2].cache_tier)
        assert.equal("compiler_rejection", semantic_events[2].outcome)
        assert.equal("service", semantic_events[3].cache_tier)
        assert.is_true(semantic_events[3].repeated)
        for _, event in ipairs(semantic_events) do
            assert.equal("<trace-first.h>, <trace-second.h>",
                event.header_label)
        end
        assert.is_true(service:close())

        local infrastructure_events = {}
        local infrastructure, infrastructure_state = new_fake_service({
            execution_trace = function(event)
                infrastructure_events[#infrastructure_events + 1] = event
            end,
        }, function(call)
            if call == 1 then
                return {
                    started = true,
                    ok = false,
                    diagnostic = "capture failed after spawn",
                }
            end
            return nil, "injected pre-spawn failure"
        end)
        local post_spawn = infrastructure:_run_source(
            "candidate", "int post_spawn_failure;\n", "post-spawn")
        assert.equal("infrastructure_failure", post_spawn.classification)
        assert.is_true(post_spawn.started)
        assert.equal("malformed_runner_result", post_spawn.reason)
        assert.is_nil(post_spawn.cache_path)
        local pre_spawn = infrastructure:_run_source(
            "candidate", "int pre_spawn_failure;\n", "pre-spawn")
        assert.equal("infrastructure_failure", pre_spawn.classification)
        assert.is_false(pre_spawn.started)
        assert.equal("spawn", pre_spawn.reason)
        assert.equal(2, #infrastructure_state.calls)
        assert.equal(2, #infrastructure_events)
        assert.is_true(infrastructure_events[1].started)
        assert.is_false(infrastructure_events[2].started)
        assert.equal("", infrastructure_events[1].header_label)
        assert.equal("", infrastructure_events[2].header_label)
        assert.is_true(infrastructure:close())

        local malformed = {
            { started = true, ok = true, status = 1 },
            { started = true, ok = false },
            { started = false, ok = true, status = 0 },
            { started = true, ok = false, status = 126 },
            { started = true, ok = false, status = 127 },
            { started = true, ok = true, status = 0, wall_ms = -1 },
            { started = true, ok = true, status = 0,
              wall_ms = 0 / 0 },
            { started = true, spawned = false, ok = true, status = 0 },
            { started = true, ok = true, success = false, status = 0 },
            { started = true, ok = true, status = 0, code = 1 },
            { started = true, ok = false, status = 1, why = "signal",
              signal = 9 },
        }
        for index, runner_result in ipairs(malformed) do
            local candidate = new_fake_service({}, function()
                return runner_result
            end)
            local run = candidate:_run_source(
                "candidate", "int malformed_" .. index .. ";\n", "key")
            assert.equal("infrastructure_failure", run.classification)
            assert.is_true(candidate:close())
        end

        local long_headers = {}
        for index = 1, 8 do
            long_headers[index] = string.rep("long-header-", 20) ..
                tostring(index) .. ".h"
        end
        local bounded_events = {}
        local bounded = new_fake_service({
            semantic_trace = function(event)
                bounded_events[#bounded_events + 1] = event
            end,
        })
        local bounded_module = assert(bounded:module_context({
            includes = long_headers,
        }))
        assert.equal("infrastructure_failure",
            bounded_module:probe_operator({}).status)
        assert.equal(1, #bounded_events)
        assert.is_true(#bounded_events[1].header_label <= 192)
        assert.matches("long%-header%-", bounded_events[1].header_label)
        assert.matches("%+5 more", bounded_events[1].header_label)
        assert.is_true(bounded:close())

        local hostile_results = {
            setmetatable({}, {
                __index = function()
                    error("injected runner result access failure")
                end,
            }),
            {
                started = true,
                ok = false,
                status = 1,
                diagnostic = setmetatable({}, {
                    __tostring = function()
                        error("injected runner diagnostic tostring failure")
                    end,
                }),
            },
        }
        for index, runner_result in ipairs(hostile_results) do
            local candidate = new_fake_service({}, function()
                return runner_result
            end)
            local run = candidate:_run_source(
                "candidate", "int hostile_" .. index .. ";\n", "key")
            assert.equal("infrastructure_failure", run.classification)
            assert.equal("malformed_runner_result", run.reason)
            assert.matches("result normalization raised an error",
                run.diagnostic, 1, true)
            assert.is_true(candidate:close())
        end

        local unprintable_error = setmetatable({}, {
            __tostring = function()
                error("injected runner error tostring failure")
            end,
        })
        local raising = new_fake_service({}, function()
            error(unprintable_error)
        end)
        local raised = raising:_run_source(
            "candidate", "int hostile_error;\n", "key")
        assert.equal("infrastructure_failure", raised.classification)
        assert.matches("unprintable command runner error",
            raised.diagnostic, 1, true)
        assert.is_true(raising:close())

        local terminal_events = {}
        local early, early_state = new_fake_service({
            semantic_trace = function(event)
                terminal_events[#terminal_events + 1] = event
            end,
        })
        local early_module = assert(early:module_context())
        assert.equal("infrastructure_failure",
            early_module:probe_operator({}).status)
        assert.equal(0, #early_state.calls)
        assert.equal(1, #terminal_events)
        assert.equal("c_operator", terminal_events[1].probe_kind)
        assert.equal("infrastructure_failure", terminal_events[1].outcome)
        assert.matches("^[0-9a-f]+$", terminal_events[1].key)
        assert.is_true(early:close())
        assert.equal("infrastructure_failure",
            early_module:probe_unsafe_object_pointer(nil, nil).status)
        assert.equal(2, #terminal_events)
        assert.equal("unsafe_object_pointer",
            terminal_events[2].probe_kind)
        assert.equal("infrastructure_failure", terminal_events[2].outcome)
        assert.is_false(terminal_events[2].repeated)
        assert.equal("infrastructure_failure",
            early_module:probe_unsafe_object_pointer(nil, nil).status)
        assert.equal(3, #terminal_events)
        assert.equal("unsafe_object_pointer",
            terminal_events[3].probe_kind)
        assert.equal("infrastructure_failure", terminal_events[3].outcome)
        assert.is_false(terminal_events[3].repeated)
        assert.not_equal(terminal_events[2].key, terminal_events[3].key)

        local isolated = new_fake_service({
            semantic_trace = function() error("semantic trace failed") end,
            execution_trace = function() error("execution trace failed") end,
        })
        assert.equal("success", assert(isolated:module_context()):
            validate_baseline().status)
        assert.is_true(isolated:close())
    end)

    it("keeps telemetry on its module while probe Tasks interleave",
    function()
        local cache = temporary_directory()
        local persistent_events = {}
        local semantic_events = {}
        local execution_events = {}
        local service, state = new_fake_service({
            cache_directory = cache,
            persistent_cache_trace = function(
                    stage, hit, key, path, module_name)
                persistent_events[#persistent_events + 1] = {
                    stage = stage,
                    hit = hit,
                    key = key,
                    path = path,
                    module = module_name,
                }
            end,
            semantic_trace = function(event)
                semantic_events[#semantic_events + 1] = event
            end,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function(call, _, metadata)
            if call == 1 then coroutine.yield("module-a-compiler") end
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "expected rejection",
            }
        end)
        local module_a = assert(service:module_context({ module = "module.a" }))
        local module_b = assert(service:module_context({ module = "module.b" }))

        local task_a = coroutine.create(function()
            return module_a:probe_unsafe_object_pointer(
                cpointer("interleaved_a_source"),
                cpointer("interleaved_a_target"))
        end)
        local resumed, marker = coroutine.resume(task_a)
        assert.is_true(resumed)
        assert.equal("module-a-compiler", marker)

        local result_b = module_b:probe_unsafe_object_pointer(
            cpointer("interleaved_b_source"),
            cpointer("interleaved_b_target"))
        assert.equal("rejected", result_b.status)

        local result_a
        resumed, result_a = coroutine.resume(task_a)
        assert.is_true(resumed)
        assert.equal("rejected", result_a.status)
        assert.equal("dead", coroutine.status(task_a))
        assert.is_true(#state.calls >= 3)

        local seen = { ["module.a"] = false, ["module.b"] = false }
        for _, events in ipairs({
            persistent_events, semantic_events, execution_events,
        }) do
            assert.is_true(#events > 0)
            for _, event in ipairs(events) do
                assert.is_not_nil(seen[event.module])
                seen[event.module] = true
            end
        end
        assert.is_true(seen["module.a"])
        assert.is_true(seen["module.b"])
        assert.is_true(service:close())
        for _, name in ipairs(entries(cache)) do
            assert(os.remove(cache .. "/" .. name))
        end
        assert(lfs.rmdir(cache))
    end)

    it("keeps retryable failures out of semantic cache trace tiers", function()
        local declaration_events = {}
        local declaration_service, declaration_state = new_fake_service({
            semantic_trace = function(event)
                declaration_events[#declaration_events + 1] = event
            end,
        }, function(_, _, metadata)
            if metadata.stage == "baseline" then
                return { started = true, ok = true, status = 0 }
            end
            return nil, "injected declaration infrastructure failure"
        end)
        local int = target_profile().integers.int.type
        local duplicate = {
            left_type = types.CTypedef("trace_duplicate_left", int),
            right_type = types.CTypedef("trace_duplicate_right", int),
        }
        local duplicate_results = assert(declaration_service:module_context()):
            validate_declaration_compatibilities({ duplicate, duplicate })
        assert.equal(2, #declaration_state.calls)
        assert.equal("infrastructure_failure", duplicate_results[1].status)
        assert.equal("infrastructure_failure", duplicate_results[2].status)
        assert.is_false(duplicate_results[1].cached)
        assert.is_false(duplicate_results[2].cached)
        assert.equal(3, #declaration_events)
        assert.equal("compiler", declaration_events[2].cache_tier)
        assert.equal("compiler", declaration_events[3].cache_tier)
        assert.is_true(declaration_events[3].repeated)
        assert.is_true(declaration_service:close())

        local semantic_events = {}
        local execution_events = {}
        local baseline_service = new_fake_service({
            semantic_trace = function(event)
                semantic_events[#semantic_events + 1] = event
            end,
            execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        }, function()
            return {
                started = true,
                ok = false,
                status = 1,
                diagnostic = "injected rejected baseline",
            }
        end)
        local failed = assert(baseline_service:module_context()):
            probe_unsafe_object_pointer(
                cpointer("baseline_trace_source"),
                cpointer("baseline_trace_target"))
        assert.equal("infrastructure_failure", failed.status)
        assert.equal(1, #execution_events)
        assert.equal("compiler_rejection", execution_events[1].outcome)
        assert.equal(2, #semantic_events)
        assert.equal("header_baseline", semantic_events[1].probe_kind)
        assert.equal("infrastructure_failure", semantic_events[1].outcome)
        assert.equal("unsafe_object_pointer", semantic_events[2].probe_kind)
        assert.equal("infrastructure_failure", semantic_events[2].outcome)
        assert.is_true(baseline_service:close())
    end)
end)
