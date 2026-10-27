local temporary = require "spec.support.temporary"
local cprobe = require "titan-compiler.cprobe"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local cpreamble = require "titan-compiler.cpreamble"
local csemantics = require "titan-compiler.csemantics"
local sha256 = require "titan-compiler.sha256"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local ffiheaders = require "titan-compiler.ffiheaders"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local path = require "titan-compiler.path"

-- Synthetic filesystem fixtures still need fully absolute native names. Keep
-- explicit POSIX rendering models under their own scoped platform semantics.
local function fixture_path(posix)
    if platform.windows then return path.to_slash(path.join("C:/", posix:sub(2))) end
    return posix
end

local function posix_model_it(name, body)
    it(name, function()
        local windows = platform.windows
        platform.windows = false
        local result = table.pack(pcall(body))
        platform.windows = windows
        assert.is_true(result[1], result[2])
        return table.unpack(result, 2, result.n)
    end)
end

describe("quoted C header names", function()
    it("preserves literal bytes and only normalizes Windows separators", function()
        local name = "folder 文 😀 $line\\literal/header.h"
        local expected = require("titan-compiler.platform").windows
            and name:gsub("\\", "/") or name
        assert.equal('"' .. expected .. '"', ffiheaders.quote_header(name))
    end)

    it("rejects bytes that cannot occur in a quoted header token", function()
        for _, byte in ipairs({ '"', "\r", "\n", "\0" }) do
            local rendered, err = ffiheaders.quote_header("before" .. byte .. "after.h")
            assert.is_nil(rendered)
            assert.match("quoted C header name", err, 1, true)
        end
    end)

    it("preserves extended Windows namespaces in quoted headers", function()
        for _, name in ipairs({
            [[\\?\C:\folder\header.h]],
            [[\\?\UNC\server\share\header.h]],
        }) do
            assert.equal('"' .. name .. '"', ffiheaders.quote_header(name))
        end
    end)
end)

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
            root = fixture_path("/fake/titan probe " .. state.created),
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
    local path = assert(temporary.name("-cprobe-spec"))
    assert(lfs.mkdir(path))
    return path
end

local function write_file(path, contents)
    local previous = lfs.attributes(path, "modification")
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
    if previous then assert(lfs.touch(path, previous + 1, previous + 1)) end
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

local function entries(path)
    local out = {}
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

local function remove_directory(directory)
    for _, name in ipairs(entries(directory)) do assert(os.remove(path.join(directory, name))) end
    assert(lfs.rmdir(directory))
end

local function with_default_workspace(body)
    local strategy = compiler_io.new_sync()
    local service = assert(cprobe.new_service({
        io = strategy,
        include_dirs = {},
        profile = target_profile(),
    }))
    local workspace = assert(service:_ensure_workspace())
    local completed, reason = pcall(body, service, strategy, workspace)
    if lfs.attributes(workspace.root, "mode") then
        remove_directory(workspace.root)
    end
    if not completed then error(reason, 0) end
end

describe("C probe service", function()
    it("owns a validated target profile independently of probe caching", function()
        local profile = target_profile()
        local service = new_fake_service({ profile = profile })

        assert.not_equal(profile, service.profile)
        assert.equal(profile.identity, service.profile_identity)
        assert.equal(profile.identity, service.profile.identity)
        profile.integers.int.type.bits = 7
        assert.equal(32, service.profile.integers.int.type.bits)
        assert.is_true(service:close())

        local rejected, err = cprobe.new_service({
            include_dirs = {},
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
        local reservation = assert(temporary.name())
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
            include_dirs = {},
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
        local reservation = assert(temporary.name())
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
            include_dirs = {},
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

    it("retries close after cancellation of completed directory removal",
    function()
        with_default_workspace(function(service, strategy, workspace)
            local cancellation = { kind = "cancelled completed rmdir" }
            local ordinary_rmdir = strategy.rmdir
            local removals = 0
            function strategy:rmdir(directory)
                assert.equal(workspace.root, directory)
                removals = removals + 1
                assert.is_true(ordinary_rmdir(self, directory))
                error(cancellation)
            end

            local completed, reason = pcall(service.close, service)
            assert.is_false(completed)
            assert.equal(cancellation, reason)
            assert.equal(workspace, service.workspace)
            assert.is_true(service.closed)
            assert.is_nil(service.close_error)
            assert.is_nil(lfs.attributes(workspace.root, "mode"))

            strategy.rmdir = ordinary_rmdir
            assert.is_true(service:close())
            assert.is_nil(service.workspace)
            assert.equal(1, removals)
            assert.is_true(service:close())
        end)
    end)

    it("accepts a workspace disappearing during listing without retrying rmdir",
    function()
        with_default_workspace(function(service, strategy, workspace)
            local ordinary_rmdir = strategy.rmdir
            function strategy:list(directory)
                assert.equal(workspace.root, directory)
                assert.is_true(ordinary_rmdir(self, directory))
                return nil, "directory disappeared during listing"
            end
            function strategy:rmdir()
                error("rmdir retried after listing confirmed absence")
            end

            assert.is_true(service:close())
            assert.is_nil(service.workspace)
            assert.is_nil(lfs.attributes(workspace.root, "mode"))
        end)
    end)

    it("accepts a workspace disappearing between listing and rmdir",
    function()
        with_default_workspace(function(service, strategy, workspace)
            local ordinary_list = strategy.list
            local ordinary_rmdir = strategy.rmdir
            local removals = 0
            function strategy:list(directory)
                local listed = assert(ordinary_list(self, directory))
                assert.is_true(ordinary_rmdir(self, directory))
                return listed
            end
            function strategy:rmdir(directory)
                removals = removals + 1
                return ordinary_rmdir(self, directory)
            end

            assert.is_true(service:close())
            assert.is_nil(service.workspace)
            assert.equal(1, removals)
            assert.is_nil(lfs.attributes(workspace.root, "mode"))
        end)
    end)

    for _, operation in ipairs({ "list", "rmdir" }) do
        for _, inspection in ipairs({ "existing", "ambiguous" }) do
            it("preserves " .. operation .. " failure with " .. inspection ..
            " workspace inspection", function()
                with_default_workspace(function(service, strategy, workspace)
                    local ordinary_lstat = strategy.lstat
                    if operation == "list" then
                        function strategy:list()
                            return nil, "injected list permission failure"
                        end
                    end
                    function strategy:rmdir()
                        return nil, "injected rmdir permission failure"
                    end
                    function strategy:lstat(directory)
                        assert.equal(workspace.root, directory)
                        if inspection == "ambiguous" then
                            return nil, "injected inspection permission failure"
                        end
                        return ordinary_lstat(self, directory)
                    end

                    local closed, close_error = service:close()
                    assert.is_nil(closed)
                    assert.matches("injected " .. operation ..
                        " permission failure", close_error, 1, true)
                    assert.equal("directory",
                        lfs.attributes(workspace.root, "mode"))
                end)
            end)
        end

        it("propagates cancellation confirming absence after " .. operation,
        function()
            with_default_workspace(function(service, strategy, workspace)
                local cancellation = { kind = "cancelled absence confirmation" }
                local ordinary_list = strategy.list
                local ordinary_rmdir = strategy.rmdir
                local ordinary_lstat = strategy.lstat
                function strategy:list(directory)
                    if operation == "list" then
                        assert.is_true(ordinary_rmdir(self, directory))
                        return nil, "directory disappeared during listing"
                    end
                    return ordinary_list(self, directory)
                end
                function strategy:rmdir(directory)
                    assert.is_true(ordinary_rmdir(self, directory))
                    return nil, "directory removal acknowledgement failed"
                end
                function strategy:lstat(directory)
                    assert.equal(workspace.root, directory)
                    error(cancellation)
                end

                local completed, reason = pcall(service.close, service)
                assert.is_false(completed)
                assert.equal(cancellation, reason)
                assert.equal(workspace, service.workspace)
                assert.is_nil(service.close_error)
                assert.is_nil(lfs.attributes(workspace.root, "mode"))

                strategy.lstat = ordinary_lstat
                strategy.list = ordinary_list
                strategy.rmdir = ordinary_rmdir
                assert.is_true(service:close())
                assert.is_nil(service.workspace)
            end)
        end)
    end

    it("preserves earlier unlink failures when the workspace later disappears",
    function()
        with_default_workspace(function(service, strategy, workspace)
            assert.is_true(workspace:write("stray.o", "probe output"))
            local ordinary_unlink = strategy.unlink
            local ordinary_rmdir = strategy.rmdir
            function strategy:unlink(filename)
                assert.equal(path.to_slash(path.join(workspace.root, "stray.o")),
                    path.to_slash(filename))
                return nil, "injected earlier unlink failure"
            end
            function strategy:rmdir(directory)
                assert.is_true(ordinary_unlink(self,
                    path.join(directory, "stray.o")))
                assert.is_true(ordinary_rmdir(self, directory))
                return nil, "directory removal acknowledgement failed"
            end

            local closed, close_error = service:close()
            assert.is_nil(closed)
            assert.matches("injected earlier unlink failure", close_error,
                1, true)
            assert.is_nil(service.workspace)
            assert.is_nil(lfs.attributes(workspace.root, "mode"))
        end)
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

        local missing, missing_error = cprobe.new_service()
        assert.is_nil(missing)
        assert.matches("include_dirs must be an explicit ordered array",
            missing_error, 1, true)
        local default_service = assert(cprobe.new_service({ include_dirs = {} }))
        local defaults =
            assert(default_service:cdriver_process_options())
        assert.same({}, defaults.compiler_include_dirs)
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

    posix_model_it("is lazy and builds exact header, declarator, and command inputs",
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
            "void titan_probe_b%(void%) {\n    %(void%)0;\n}",
            baseline_source)

        local candidate_source = state.calls[2].metadata.source
        local source_name = assert(candidate_source:match(
            "extern struct source_s %*(titan_probe_s);"))
        local target_name = assert(candidate_source:match(
            "struct target_s %*(titan_probe_t) ="))
        local function_name = assert(candidate_source:match(
            "void (titan_probe_f)%(void%);"))
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
            "extern unsigned char (titan_probe_l);"))
        local rhs = assert(accepted.source:match(
            "extern long long (titan_probe_r);"))
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
                .. "%(%(const int %*%)%(titan_probe_r%)%)",
            nil_probe.source)
        assert.equal(4, #state.calls)
        assert.is_true(service:close())
    end)

    it("keeps a cached baseline rejection distinct from candidate rejection",
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
            "could not be started",
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
            "extern const ffi_left_alias (titan_probe_d);"))
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
            "extern int (titan_probe_d)%[%("
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

    it(platform.windows and "retries a real native out-of-range compiler exit instead of caching it"
        or "retries a real shell-signalled compiler instead of caching it",
    function()
        local observed = {}
        local service, state = new_fake_service({},
            function()
                local result
                if platform.windows then
                    result = cdriver.capture_command({
                        path.join(driver.TITAN_ROOT, "bin", "lua.exe"),
                        "-e", "os.exit(9009)",
                    })
                    observed[#observed + 1] = result
                else
                    result = cdriver.capture_command({
                        "/bin/sh", "-c", "kill -TERM $$",
                    })
                end
                return result
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
        assert.equal("infrastructure_failure", second.status)
        if platform.windows then
            for _, result in ipairs(observed) do
                assert.is_true(result.started)
                assert.is_false(result.ok)
                assert.equal(9009, result.status)
                assert.equal("exit", result.why)
            end
            for _, result in ipairs({ first, second }) do
                assert.is_false(result.interrupted)
                assert.equal("malformed_runner_result", result.reason)
                assert.matches("invalid exit status", result.diagnostic, 1, true)
            end
        else
            assert.is_true(first.interrupted)
            assert.matches("interrupted", first.message)
            assert.is_true(second.interrupted)
        end
        assert.is_false(second.baseline_cached)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())
    end)

    it("uses portable private-object compilation by default", function()
        local root = temporary_directory()
        local fake_compiler = path.join(root, platform.windows and "fake-compiler.lua" or "fake-compiler.sh")
        local compiler
        if platform.windows then
            write_file(fake_compiler, [[
local seen_compile = false
for _, argument in ipairs(arg) do
    if argument == "-fsyntax-only" then os.exit(97) end
    if argument == "-c" then seen_compile = true end
end
os.exit(seen_compile and 0 or 98)
]])
            compiler = { path.join(driver.TITAN_ROOT, "bin", "lua.exe"), fake_compiler }
        else
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
            compiler = { "/bin/sh", fake_compiler }
        end

        local service = assert(cprobe.new_service({
            include_dirs = {},
            compiler_argv = compiler,
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
            include_dirs = {},
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
            include_dirs = {},
            runner = function()
                error("runner must not be reached")
            end,
            temp_provider = function()
                return {
                    root = fixture_path("/fake/write-error"),
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

        for _, invalid_root in ipairs({
            "relative/workspace", fixture_path("/bad") .. "\0root",
        }) do
            local invalid_service = assert(cprobe.new_service({
                include_dirs = {},
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
            if invalid_root:find("\0", 1, true) then
                assert.is_true(path.is_absolute(invalid_root))
                if platform.windows then
                    -- Native path validation rejects NUL before cprobe's
                    -- ordered absolute-root guard reaches its own NUL check.
                    local absolute, message, reason = platform.path.is_absolute(invalid_root)
                    assert.is_nil(absolute)
                    assert.matches("contains a NUL byte", message, 1, true)
                    assert.equal("invalid_path", reason)
                    assert.matches("must be absolute", invalid_error, 1, true)
                else
                    assert.matches("contains a NUL byte", invalid_error, 1, true)
                end
            else
                assert.matches("must be absolute", invalid_error, 1, true)
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
        release.tmpname = function() return fixture_path("/fake/reservation") end
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
        creation.tmpname = function() return fixture_path("/fake/reservation") end
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
        cleanup.tmpname = function() return fixture_path("/fake/workspace-one") end
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
        listing.tmpname = function() return fixture_path("/fake/workspace-two") end
        listing.unlink = function() return true end
        listing.mkdir = function() return true end
        local listing_workspace = assert(listing_service:_ensure_workspace())
        listing.list = function()
            return nil, "injected list failure"
        end
        function listing:lstat(directory)
            assert.equal(listing_workspace.root, directory)
            return { kind = "directory" }
        end
        listing.rmdir = function() return true end
        closed, close_error = listing_service:close()
        assert.is_nil(closed)
        assert.matches("injected list failure", close_error, 1, true)
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
        assert.matches("extern struct source_s %*titan_probe_s;",
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
            include_dirs = driver.foreign_include_dirs(),
            -- Resolve past a checkout/user ccache shim: this integration
            -- exercises cprobe itself and must not depend on ccache's chosen
            -- cache directory being writable inside a test sandbox.
            compiler_argv = platform.windows
                and assert(driver.toolchain_descriptor()).compiler_argv
                or (lfs.attributes("/usr/bin/cc", "mode")
                    and { "/usr/bin/cc" } or (os.getenv("CC") or "cc")),
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
            "candidate", source, "private-path")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(expected, first_run.diagnostic)
        assert.equal(1, #first_state.calls)

        local encoded = assert(compiler_io.new_sync():read_file(
            first_run.cache_path))
        assert.is_nil(encoded:find(fixture_path("/fake/titan probe"), 1, true))
        assert.is_true(first:close())

        local second, second_state = new_fake_service({
            cache_directory = cache,
        }, function()
            error("normalized persistent result must not invoke the compiler")
        end)
        local second_run = second:_run_source(
            "candidate", source, "private-path")
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
                local root = path.to_slash(path.dirname(metadata.source_path))
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
            "candidate", source, "bare-root")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(raw_diagnostics[1], first_run.diagnostic)
        assert.equal("unstable_diagnostic", publications[#publications])
        assert.is_nil(lfs.attributes(first_run.cache_path))
        local memory = first:_run_source(
            "candidate", source, "bare-root")
        assert.equal("service", memory.cache_tier)
        assert.equal(first_run.diagnostic, memory.diagnostic)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local fresh, fresh_state = create(8)
        local fresh_run = fresh:_run_source(
            "candidate", source, "bare-root")
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
            "candidate", source, "ambiguous")
        assert.equal("compiler_rejection", first_run.classification)
        assert.equal(raw_diagnostics[1], first_run.diagnostic)
        assert.matches("000009%-ambiguous[.]c", first_run.diagnostic)
        assert.matches("~backup", first_run.diagnostic, 1, true)
        assert.matches(" backup", first_run.diagnostic, 1, true)
        assert.matches("%)backup", first_run.diagnostic)
        local workspace_prefix = fixture_path("/fake/titan probe 1") .. "/"
        assert.matches("archive " .. workspace_prefix, first_run.diagnostic, 1, true)
        assert.matches("archive(" .. workspace_prefix, first_run.diagnostic, 1, true)
        assert.is_nil(lfs.attributes(first_run.cache_path))
        assert.equal("unstable_diagnostic", publications[#publications])
        local memory_run = first:_run_source(
            "candidate", source, "ambiguous")
        assert.equal(first_run.diagnostic, memory_run.diagnostic)
        assert.equal("service", memory_run.cache_tier)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local second, second_state = service(0)
        local second_run = second:_run_source(
            "candidate", source, "ambiguous")
        assert.equal(raw_diagnostics[2], second_run.diagnostic)
        assert.matches("000001%-ambiguous[.]c", second_run.diagnostic)
        assert.not_equal(first_run.diagnostic, second_run.diagnostic)
        assert.equal(1, #second_state.calls)
        assert.is_nil(lfs.attributes(second_run.cache_path))
        assert.is_true(second:close())
        assert.same({}, entries(cache))
        assert(lfs.rmdir(cache))
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
            "candidate", source, "oversized")
        assert.equal(diagnostic, first_run.diagnostic)
        assert.equal("too_large", publications[#publications])
        assert.is_nil(lfs.attributes(first_run.cache_path))
        local memory_run = first:_run_source(
            "candidate", source, "oversized")
        assert.equal(diagnostic, memory_run.diagnostic)
        assert.equal("service", memory_run.cache_tier)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())

        local fresh, fresh_state = create()
        local fresh_run = fresh:_run_source(
            "candidate", source, "oversized")
        assert.equal(diagnostic, fresh_run.diagnostic)
        assert.equal(1, #fresh_state.calls)
        assert.is_nil(lfs.attributes(fresh_run.cache_path))
        assert.is_true(fresh:close())
        assert.same({}, entries(cache))
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

    it("accepts a cache-directory creation race", function()
        local strategy = compiler_io.new_sync()
        local cache = fixture_path("/cache")
        local cache_root = path.to_slash(path.dirname(cache))
        local service = assert(cprobe.new_service({
            io = strategy,
            include_dirs = {},
            profile = target_profile(),
            cache_directory = cache,
        }))
        local cache_stats = 0
        strategy.stat = function(_, filename)
            if filename == cache_root then return { kind = "directory" } end
            assert.equal(cache, filename)
            cache_stats = cache_stats + 1
            if cache_stats == 1 then return nil, "not found" end
            return { kind = "directory" }
        end
        strategy.mkdir = function(_, filename)
            assert.equal(cache, filename)
            return nil, "already created concurrently"
        end
        strategy.write_file = function(_, filename, contents)
            assert.equal(path.normalize(cache), path.normalize(path.dirname(filename)))
            assert.matches("^[0-9a-f]+[.]result$", path.basename(filename))
            assert.equal("rejected", assert(cprobe_cache.decode(contents)).diagnostic)
            return true
        end

        local source = "int value;\n"
        local path, key = service:_cache_location(source)
        local _, publication = service:_publish_result(key, path, {
            classification = "compiler_rejection", status = 1,
            source = source, diagnostic = "rejected",
        })
        assert.equal("published", publication)
        assert.equal(2, cache_stats)
        assert.is_true(service:close())
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
            include_dirs = {},
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

    local function with_checking_header_directories(body, nested)
        local strategy = compiler_io.new_sync()
        local owner = { io = strategy }
        assert(ffiheaders.filename(owner,
            nested and "nested/probe.ffi.h" or "probe.ffi.h"))
        local directories = { table.unpack(owner.source_ffi_header_directories) }
        local completed, reason = pcall(body, owner, strategy, directories)
        for index = #directories, 1, -1 do
            if lfs.attributes(directories[index], "mode") then
                remove_directory(directories[index])
            end
        end
        if not completed then error(reason, 0) end
    end

    it("closes checking-header directories disappearing after initial inspection",
    function()
        with_checking_header_directories(function(owner, strategy, directories)
            local root = directories[1]
            local ordinary_lstat = strategy.lstat
            local ordinary_rmdir = strategy.rmdir
            function strategy:lstat(directory)
                local attributes, err = ordinary_lstat(self, directory)
                if attributes then
                    assert.equal(root, directory)
                    assert.is_true(ordinary_rmdir(self, directory))
                end
                return attributes, err
            end

            assert.is_true(ffiheaders.close(owner))
            assert.is_nil(owner.source_ffi_header_directories)
            assert.is_nil(owner.source_ffi_header_bundle)
            assert.is_nil(lfs.attributes(root, "mode"))
        end)
    end)

    it("closes checking-header directories after rmdir commits but reports ENOENT",
    function()
        with_checking_header_directories(function(owner, strategy, directories)
            local root = directories[1]
            local ordinary_rmdir = strategy.rmdir
            function strategy:rmdir(directory)
                assert.equal(root, directory)
                assert.is_true(ordinary_rmdir(self, directory))
                return nil, "fs.rmdir: ENOENT: no such file or directory"
            end

            assert.is_true(ffiheaders.close(owner))
            assert.is_nil(owner.source_ffi_header_directories)
            assert.is_nil(owner.source_ffi_header_bundle)
            assert.is_nil(lfs.attributes(root, "mode"))
        end)
    end)

    for _, inspection in ipairs({ "existing", "ambiguous" }) do
        it("retains checking-header ownership after rmdir fails with " ..
        inspection .. " inspection", function()
            with_checking_header_directories(function(owner, strategy, directories)
                local root = directories[1]
                local ordinary_lstat = strategy.lstat
                local ordinary_rmdir = strategy.rmdir
                local initial = true
                function strategy:lstat(directory)
                    assert.equal(root, directory)
                    if not initial and inspection == "ambiguous" then
                        return nil, "injected checking-header inspection failure"
                    end
                    initial = false
                    return ordinary_lstat(self, directory)
                end
                function strategy:rmdir(directory)
                    assert.equal(root, directory)
                    return nil, "fs.rmdir: EACCES: permission denied"
                end

                local closed, close_error = ffiheaders.close(owner)
                assert.is_nil(closed)
                assert.equal("fs.rmdir: EACCES: permission denied", close_error)
                assert.same(directories, owner.source_ffi_header_directories)
                assert.equal(root, owner.source_ffi_header_bundle)
                assert.equal("directory", lfs.attributes(root, "mode"))

                strategy.lstat = ordinary_lstat
                strategy.rmdir = ordinary_rmdir
                assert.is_true(ffiheaders.close(owner))
                assert.is_nil(owner.source_ffi_header_directories)
                assert.is_nil(owner.source_ffi_header_bundle)
            end)
        end)
    end

    it("retains original checking-header directories when absence confirmation cancels",
    function()
        with_checking_header_directories(function(owner, strategy, directories)
            local root, child = directories[1], directories[2]
            local owned_directories = owner.source_ffi_header_directories
            local cancellation = { kind = "cancelled checking-header confirmation" }
            local ordinary_lstat = strategy.lstat
            local ordinary_rmdir = strategy.rmdir
            function strategy:lstat(directory)
                local attributes, err = ordinary_lstat(self, directory)
                if directory == child and not attributes then error(cancellation) end
                return attributes, err
            end
            function strategy:rmdir(directory)
                assert.equal(child, directory)
                assert.is_true(ordinary_rmdir(self, directory))
                return nil, "directory removal acknowledgement failed"
            end

            local completed, reason = pcall(ffiheaders.close, owner)
            assert.is_false(completed)
            assert.equal(cancellation, reason)
            assert.equal(owned_directories, owner.source_ffi_header_directories)
            assert.same(directories, owner.source_ffi_header_directories)
            assert.equal(root, owner.source_ffi_header_bundle)
            assert.is_nil(lfs.attributes(child, "mode"))
            assert.equal("directory", lfs.attributes(root, "mode"))

            strategy.lstat = ordinary_lstat
            strategy.rmdir = ordinary_rmdir
            assert.is_true(ffiheaders.close(owner))
            assert.is_nil(owner.source_ffi_header_directories)
            assert.is_nil(owner.source_ffi_header_bundle)
            assert.is_nil(lfs.attributes(root, "mode"))
        end, true)
    end)

    it("normalizes generated dependency diagnostics without retaining private paths",
    function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local owner = { io = strategy }
        local dependency = assert(ffiheaders.prepare(owner, "lib.dep", {},
            fixture_path("/project/lib/dep.titan")))
        local header = assert(ffiheaders.prepare(owner, "app.consumer", {
            { _tag = "Ast.TopLevelImport", _source_import = true,
                _ffi_header_descriptor = dependency },
        }, fixture_path("/project/app/consumer.titan")))
        assert.is_true(ffiheaders.close(owner))
        local include = assert(cprobe.normalize_include_descriptor({
            include_kind = "quote", include_name = header.logical_name,
            resolved = header.identity, generated_header = header,
        }))
        local private_root, calls = nil, 0
        local service
        service = assert(cprobe.new_service({
            include_dirs = {},
            io = strategy, cache_directory = cache,
            runner = function(_, metadata)
                calls = calls + 1
                local staged = assert(service.generated_workspaces[header.digest]).header
                private_root = staged.bundle_root
                local consumer_path = staged.filename
                local dependency_path = staged.dependencies[1].filename
                assert.equal(header.contents, assert(strategy:read_file(consumer_path)))
                assert.equal(dependency.contents, assert(strategy:read_file(dependency_path)))
                return { started = true, ok = false, status = 1,
                    diagnostic = "In file included from " .. consumer_path .. ":2,\n"
                        .. dependency_path .. ":5: error: generated declaration rejected" }
            end,
        }))
        local context = assert(service:module_context({ includes = { include } }))
        local result = context:validate_baseline()
        assert.equal("rejected", result.status)
        assert.equal(1, calls)
        local expected = "In file included from " .. header.identity .. ":2,\n"
            .. dependency.identity .. ":5: error: generated declaration rejected"
        assert.equal(expected, result.diagnostic)
        assert.is_nil(assert(strategy:read_file(result.cache_path)):find(private_root, 1, true))
        assert.is_true(service:close())
        assert.is_nil(lfs.attributes(private_root))

        local restored = assert(cprobe.new_service({
            include_dirs = {},
            cache_directory = cache,
            runner = function() error("persistent generated result must not compile") end,
        }))
        local replay = assert(restored:module_context({ includes = { include } })):validate_baseline()
        assert.is_true(replay.persistent_cached)
        assert.equal(expected, replay.diagnostic)
        assert.is_nil(restored.generated_workspaces)
        assert.is_true(restored:close())
        assert(os.remove(result.cache_path))
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

    it("classifies runners strictly and emits nonoverlapping lifecycle traces",
    function()
        local untraced = new_fake_service()
        local untraced_run = untraced:_run_source(
            "candidate", "int titan_untraced_execution;\n", "untraced")
        assert.equal(sha256.hex(untraced_run.source), untraced_run.execution_digest)
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
        assert.equal("", terminal_events[1].key)
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
        assert.equal("", terminal_events[2].key)
        assert.equal("", terminal_events[3].key)

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

end)

describe("source-only probe cache", function()
    it("keys exact raw bytes and preserves successful diagnostics across toolchains", function()
        local cache = temporary_directory()
        local source = '#include <sdk.h>\nint titan_cached_source;\n'
        local diagnostic = "accepted with warning\nsecond line\0tail"
        local first, first_state = new_fake_service({ cache_directory = cache }, function()
            return { started = true, ok = true, status = 0, diagnostic = diagnostic }
        end)
        local run = first:_run_source("candidate", source)
        assert.equal(cache .. "/" .. sha256.hex(source) .. ".result", run.cache_path)
        assert.equal(1, #first_state.calls)
        assert.same({ outcome = "success", exit_status = 0, diagnostic = diagnostic },
            assert(cprobe_cache.decode(assert(compiler_io.new_sync():read_file(run.cache_path)))))
        assert.is_true(first:close())

        local second, state = new_fake_service({
            cache_directory = cache,
            compiler_argv = { "/nonexistent/other-compiler" },
            compile_flags = { "--target=changed" },
            cppflags = { "-DCHANGED=1" },
            cflags = { "-include", "/nonexistent/forced.h", "-Werror" },
            language_mode = "c11", syntax_only = true,
            include_dirs = { "/different-sdk" },
        })
        local hit = second:_run_source("candidate", source)
        assert.is_true(hit.persistent_cached)
        assert.equal(diagnostic, hit.diagnostic)
        assert.equal(0, #state.calls)
        local changed = second:_run_source("candidate", source .. "\n")
        assert.is_false(changed.cached == true)
        assert.equal(1, #state.calls)
        assert.not_equal(run.cache_path, changed.cache_path)
        assert.is_true(second:close())
        remove_directory(cache)
    end)

    it("does not hide header metadata or module ownership in generated source", function()
        local strategy = compiler_io.new_sync()
        local analysis = cdriver.new_process_analysis()
        local first, first_state = new_fake_service({ io = strategy, process_analysis = analysis })
        local first_module = assert(first:module_context({
            module = "first", source_dir = fixture_path("/first-project"),
            includes = { { include_kind = "angle", include_name = "api.h",
                resolved = "/first-sdk/api.h", c_header_dependencies = {
                    { kind = "file", path = "/first-sdk/api.h", identity = "old" },
                }, c_header_search_inputs = {} } },
        }))
        local source, target = cpointer("source"), cpointer("target")
        local accepted = first_module:probe_unsafe_object_pointer(source, target)
        assert.equal(sha256.hex(accepted.source), accepted.key)
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())

        local second, second_state = new_fake_service({ io = strategy,
            process_analysis = analysis, compiler_argv = { "other-cc" },
            cflags = { "-DCHANGED" }, include_dirs = { "/second-sdk" } })
        local second_module = assert(second:module_context({
            module = "second", source_dir = fixture_path("/second-project"),
            includes = { { include_kind = "angle", include_name = "api.h",
                resolved = "/second-sdk/api.h", c_header_dependencies = {
                    { kind = "file", path = "/second-sdk/api.h", identity = "new" },
                }, c_header_search_inputs = {} } },
        }))
        local reused = second_module:probe_unsafe_object_pointer(source, target)
        assert.equal(accepted.source, reused.source)
        assert.equal(accepted.key, reused.key)
        assert.equal("analysis", reused.cache_tier)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())
    end)

    it("refreshes parsed headers without changing source-only probe outcomes", function()
        local root = temporary_directory()
        local cache, header = root .. "/cache", root .. "/observed.h"
        assert(lfs.mkdir(cache))
        write_file(header, "typedef int observed_type;\n")
        local strategy = compiler_io.new_sync()
        local function service()
            return new_fake_service({
                io = strategy, profile = target_profile(),
                compiler_argv = platform.windows and assert(driver.toolchain_descriptor()).compiler_argv
                    or { "/usr/bin/cc" },
                cache_directory = cache,
            }, function(_, _, metadata)
                local rejected = metadata.source:find("struct rejected_target", 1, true) ~= nil
                return { started = true, ok = not rejected, status = rejected and 1 or 0,
                    diagnostic = rejected and "retained source rejection" or "" }
            end)
        end
        local function parse_and_probe(current)
            local parsed, err, include = cdriver.process_file(header,
                assert(current:cdriver_process_options()))
            assert.is_table(parsed, err)
            assert.is_nil(err)
            assert.is_table(include)
            local module = assert(current:module_context({ includes = { include } }))
            local accepted = module:probe_unsafe_object_pointer(
                cpointer("source"), cpointer("accepted_target"))
            local rejected = module:probe_unsafe_object_pointer(
                cpointer("source"), cpointer("rejected_target"))
            assert.equal("success", accepted.status, accepted.message)
            assert.equal("rejected", rejected.status, rejected.message)
            return parsed, include, accepted, rejected
        end

        local first, first_state = service()
        local first_types, first_include, accepted, rejected = parse_and_probe(first)
        assert.same({ "int" }, first_types.observed_type.def)
        assert.equal(3, #first_state.calls)
        local original_input = first_include.c_header_dependencies[1]
        assert.equal(header, original_input.path)
        assert.is_table(original_input.observation)
        assert.equal("ns", original_input.observation.precision)
        assert.is_true(first:close())

        write_file(header, "typedef long observed_type;\n")
        local second, second_state = service()
        local changed_types, changed_include, cached_accept, cached_reject = parse_and_probe(second)
        assert.same({ "long" }, changed_types.observed_type.def)
        local changed_input = changed_include.c_header_dependencies[1]
        assert.not_equal(original_input.identity, changed_input.identity)
        assert.is_table(changed_input.observation)
        assert.equal("ns", changed_input.observation.precision)
        assert.is_false(cdriver.same_header_observation(
            original_input.observation, changed_input.observation))
        for _, pair in ipairs({ { accepted, cached_accept }, { rejected, cached_reject } }) do
            assert.equal(pair[1].source, pair[2].source)
            assert.equal(pair[1].key, pair[2].key)
            assert.is_true(pair[2].persistent_cached)
        end
        assert.equal("retained source rejection", cached_reject.diagnostic)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())

        local before = cdriver.process_cache_stats(strategy)
        local third, third_state = service()
        local warm_types = parse_and_probe(third)
        assert.same({ "long" }, warm_types.observed_type.def)
        local after = cdriver.process_cache_stats(strategy)
        assert.equal(before.file_reads, after.file_reads)
        assert.equal(before.file_hashes, after.file_hashes)
        assert.equal(0, #third_state.calls)
        assert.is_true(third:close())
        cdriver.clear_process_cache(strategy)
        remove_directory(cache)
        assert(os.remove(header))
        assert(lfs.rmdir(root))
    end)

    it("reuses rejection until the programmer removes its record", function()
        local cache = temporary_directory()
        local source = "int titan_stale_rejection;\n"
        local first = new_fake_service({ cache_directory = cache }, function()
            return { started = true, ok = false, status = 2, diagnostic = "old rejection" }
        end)
        local rejected = first:_run_source("candidate", source)
        assert.is_true(first:close())
        local second, second_state = new_fake_service({ cache_directory = cache })
        local hit = second:_run_source("candidate", source)
        assert.equal("compiler_rejection", hit.classification)
        assert.equal(2, hit.status)
        assert.equal("old rejection", hit.diagnostic)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())
        assert(os.remove(rejected.cache_path))
        local refreshed, refreshed_state = new_fake_service({ cache_directory = cache })
        assert.equal("success", refreshed:_run_source("candidate", source).classification)
        assert.equal(1, #refreshed_state.calls)
        assert.is_true(refreshed:close())
        remove_directory(cache)
    end)

    it("persists baseline rejection without inferring a candidate verdict", function()
        local cache = temporary_directory()
        local first, first_state = new_fake_service({ cache_directory = cache }, function()
            return { started = true, ok = false, status = 1, diagnostic = "broken header" }
        end)
        local module = assert(first:module_context({ includes = { "broken.h" } }))
        assert.equal("rejected", module:validate_baseline().status)
        assert.equal(1, #first_state.calls)
        assert.is_true(first:close())
        local second, second_state = new_fake_service({ cache_directory = cache })
        local second_module = assert(second:module_context({ includes = { "broken.h" } }))
        assert.equal("rejected", second_module:validate_baseline().status)
        local result = second_module:probe_unsafe_object_pointer(cpointer("s"), cpointer("t"))
        assert.equal("infrastructure_failure", result.status)
        assert.equal("baseline", result.stage)
        assert.equal(0, #second_state.calls)
        assert.equal(1, #entries(cache))
        assert.is_true(second:close())
        remove_directory(cache)
    end)

    it("compiles declaration leaves in order and reuses every outcome independently", function()
        local cache = temporary_directory()
        local first, state = new_fake_service({ cache_directory = cache }, function(_, _, metadata)
            local rejected = metadata.source:find("struct bad", 1, true) ~= nil
            return { started = true, ok = not rejected, status = rejected and 1 or 0,
                diagnostic = rejected and "one bad pair" or "accepted leaf warning" }
        end)
        local module = assert(first:module_context())
        local pair_a = { left_type = cpointer("a"), right_type = cpointer("b") }
        local pair_bad = { left_type = cpointer("a"), right_type = cpointer("bad") }
        local pair_c = { left_type = cpointer("c"), right_type = cpointer("d") }
        local results = module:validate_declaration_compatibilities({ pair_a, pair_bad, pair_c, pair_a })
        assert.same({ "success", "rejected", "success", "success" },
            { results[1].status, results[2].status, results[3].status, results[4].status })
        assert.equal("one bad pair", results[2].diagnostic)
        assert.equal("accepted leaf warning", results[1].diagnostic)
        assert.is_true(results[4].cached)
        assert.equal(4, #state.calls)
        for index = 1, 3 do
            assert.equal(results[index].source, state.calls[index + 1].metadata.source)
            assert.equal(sha256.hex(results[index].source), results[index].key)
            local _, declarations = results[index].source:gsub("extern struct ", "")
            assert.equal(2, declarations)
        end
        assert.is_true(first:close())
        local second, second_state = new_fake_service({ cache_directory = cache })
        local second_module = assert(second:module_context())
        local reordered = second_module:validate_declaration_compatibilities({ pair_c, pair_bad, pair_a })
        assert.same({ "success", "rejected", "success" },
            { reordered[1].status, reordered[2].status, reordered[3].status })
        assert.equal("one bad pair", reordered[2].diagnostic)
        assert.equal("accepted leaf warning", reordered[3].diagnostic)
        assert.equal(0, #second_state.calls)
        assert.equal(4, #entries(cache))
        assert.is_true(second:close())
        remove_directory(cache)
    end)

    it("treats invalid and oversized records as misses and repairs them", function()
        local cache = temporary_directory()
        local source = "int titan_corrupt_record;\n"
        local path = cache .. "/" .. sha256.hex(source) .. ".result"
        for _, bytes in ipairs({ "", "titan-cprobe-2\n0\n0\n", "titan-cprobe-1\n1\n9\nshort",
            string.rep("x", cprobe_cache.MAX_RECORD_BYTES + 1) }) do
            write_file(path, bytes)
            local service, state = new_fake_service({ cache_directory = cache })
            assert.equal("success", service:_run_source("candidate", source).classification)
            assert.equal(1, #state.calls)
            local encoded = assert(compiler_io.new_sync():read_file(path))
            assert.equal("success", assert(cprobe_cache.decode(encoded)).outcome)
            assert.is_true(service:close())
        end
        remove_directory(cache)
    end)

    it("keeps service hits free of disk I/O", function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local service, state = new_fake_service({ io = strategy, cache_directory = cache })
        local source = "int titan_memory_hit;\n"
        assert.is_true(service:_run_source("candidate", source).ok)
        strategy.stat = function() error("memory hit reached stat") end
        strategy.read_file = function() error("memory hit reached read") end
        strategy.write_file = function() error("memory hit reached write") end
        assert.equal("service", service:_run_source("candidate", source).cache_tier)
        assert.equal(1, #state.calls)
        assert.is_true(service:close())
        remove_directory(cache)
    end)

    it("retains the first completed source result while requests interleave", function()
        local analysis = cdriver.new_process_analysis()
        local strategy = compiler_io.new_sync()
        local executions = {}
        local first = new_fake_service({ io = strategy, process_analysis = analysis,
            execution_trace = function(event) executions[#executions + 1] = event end,
        }, function()
            coroutine.yield("running")
            return { started = true, ok = false, status = 1, diagnostic = "later result" }
        end)
        local second = new_fake_service({ io = strategy, process_analysis = analysis })
        local source = "int titan_interleaved_source;\n"
        local worker = coroutine.create(function() return first:_run_source("candidate", source) end)
        local started, marker = coroutine.resume(worker)
        assert.is_true(started)
        assert.equal("running", marker)
        assert.equal("success", second:_run_source("candidate", source).classification)
        local resumed, result = coroutine.resume(worker)
        assert.is_true(resumed, result)
        assert.equal("success", result.classification)
        assert.equal("analysis", result.cache_tier)
        assert.equal(1, #executions)
        assert.equal("compiler_rejection", executions[1].outcome)
        assert.is_true(first:close())
        assert.is_true(second:close())
    end)
end)

describe("probe cache I/O failures", function()
    it("bounds a record that grows between stat and read", function()
        local cache = temporary_directory()
        local strategy = compiler_io.new_sync()
        local source = "int titan_record_growth;\n"
        local path = cache .. "/" .. sha256.hex(source) .. ".result"
        local real_stat = strategy.stat
        strategy.stat = function(self, requested)
            if requested == path then return { kind = "file", size = 1 } end
            return real_stat(self, requested)
        end
        strategy.read_file = function(_, requested, limit)
            assert.equal(path, requested)
            assert.equal(cprobe_cache.MAX_RECORD_BYTES, limit)
            -- Even a strategy which ignores its requested read bound cannot
            -- make the decoder retain or trust an oversized record.
            return string.rep("x", limit + 1)
        end
        local written
        strategy.write_file = function(_, requested, contents)
            assert.equal(path, requested)
            written = assert(cprobe_cache.decode(contents))
            return true
        end
        local service, state = new_fake_service({ io = strategy, cache_directory = cache })
        assert.equal("success", service:_run_source("candidate", source).classification)
        assert.equal(1, #state.calls)
        assert.equal("success", written.outcome)
        assert.is_true(service:close())
        remove_directory(cache)
    end)

    it("returns and remembers the compiler result when publication fails", function()
        for _, status in ipairs({ 0, 1 }) do
            local cache = temporary_directory()
            local strategy = compiler_io.new_sync()
            strategy.write_file = function() return nil, "injected rename failure" end
            local service, state = new_fake_service({ io = strategy, cache_directory = cache }, function()
                return { started = true, ok = status == 0, status = status, diagnostic = "exact result" }
            end)
            local source = "int titan_write_failure;\n"
            local first = service:_run_source("candidate", source)
            local second = service:_run_source("candidate", source)
            assert.equal(status == 0 and "success" or "compiler_rejection", first.classification)
            assert.equal(first.classification, second.classification)
            assert.equal("exact result", first.diagnostic)
            assert.equal("service", second.cache_tier)
            assert.equal(1, #state.calls)
            assert.same({}, entries(cache))
            assert.is_true(service:close())
            remove_directory(cache)
        end
    end)
end)

describe("singleton declaration compilation", function()
    it("accepts an enum and its compatible integer carrier under Werror", function()
        local root = temporary_directory()
        local header = root .. "/enum-carrier.h"
        write_file(header, [[
enum titan_cache_enum {
    TITAN_CACHE_NEGATIVE = -1,
    TITAN_CACHE_POSITIVE = 1
};
]])
        local service = assert(cprobe.new_service({
            include_dirs = driver.foreign_include_dirs(),
            compiler_argv = platform.windows
                and assert(driver.toolchain_descriptor()).compiler_argv
                or (lfs.attributes("/usr/bin/cc", "mode")
                    and { "/usr/bin/cc" } or (os.getenv("CC") or "cc")),
            cflags = { "-Wall", "-Wextra", "-Werror" },
        }))
        local module = assert(service:module_context({ includes = {
            { include_kind = "quote", include_name = header },
        } }))
        local enum_type = types.CInteger("enum titan_cache_enum", true, 3, 32)
        local int_type = types.CInteger("int", true, 3, 32)
        local compatible = module:validate_declaration_compatibility(
            types.CFunction({}, enum_type, false, "cdecl"),
            types.CFunction({}, int_type, false, "cdecl"))
        assert.equal("success", compatible.status, compatible.message)
        local incompatible = module:validate_declaration_compatibility(
            enum_type, types.CFloat("double"))
        assert.equal("rejected", incompatible.status)
        assert.is_true(service:close())
        remove_directory(root)
    end)
end)

describe("whole-question enum carrier selection", function()
    local all_ids = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
    local int_enum = types.CInteger("enum probe_enum", true, 3, 32)

    -- A minimal ELF fixture for the service's object-read lifecycle. Exhaustive
    -- object-format and hostile table coverage belongs to staticmetadata_spec.
    local function object_bytes(payload)
        local names = "\0.shstrtab\0.titan.cprobe\0"
        local names_offset, payload_offset = 64, 64 + #names
        local section_offset = payload_offset + #payload
        local function section(name, kind, offset, size)
            return string.pack("<I4I4I8I8I8I8I4I4I8I8",
                name, kind, 0, 0, offset, size, 0, 0, 1, 0)
        end
        return "\127ELF\2\1\1" .. string.rep("\0", 9) ..
            string.pack("<I2I2I4I8I8I8I4I2I2I2I2I2I2",
                1, 62, 1, 0, 0, section_offset, 0, 64, 0, 0, 64, 3, 1) ..
            names .. payload .. string.rep("\0", 64) ..
            section(1, 3, names_offset, #names) ..
            section(11, 1, payload_offset, #payload)
    end
    local function payload(count, id)
        return "TITENUM\0\1\12" .. string.char(count, id)
    end
    local function fake_selection_service(options, response)
        options = options or {}
        local strategy = options.io or compiler_io.new_sync()
        options.io = strategy
        local state
        local original_stat, original_read = strategy.stat, strategy.read_file
        function strategy:stat(filename)
            local name = path.basename(filename)
            if name:match("[.]o$") and state and state.files[name] then
                return { kind = "file", size = #state.files[name] }
            end
            return original_stat(self, filename)
        end
        function strategy:read_file(filename, limit)
            local name = path.basename(filename)
            if name:match("[.]o$") and state and state.files[name] then return state.files[name] end
            return original_read(self, filename, limit)
        end
        local service
        service, state = new_fake_service(options, function(index, argv, metadata, files)
            if metadata.stage == "candidate" then
                local bytes = response
                if type(response) == "function" then
                    bytes = response(index, argv, metadata, files)
                end
                if bytes then
                    files.files[path.basename(assert(metadata.object_path))] = bytes
                end
            end
            return { started = true, ok = true, status = 0, diagnostic = "" }
        end)
        return service, state
    end
    local function context(service)
        return assert(service:module_context({}))
    end

    it("reads the exact enum payload with Clang address sanitizer enabled", function()
        local strategy = compiler_io.new_sync()
        if not strategy:run({ "clang", "--version" }).ok then
            pending("Clang is required for the sanitized enum object probe")
            return
        end
        local root = temporary_directory()
        local header = root .. "/enum-carrier.h"
        write_file(header, "enum probe_enum { NEGATIVE = -1, POSITIVE = 1 };\n")
        local service = assert(cprobe.new_service({
            io = strategy, compiler_argv = { "clang" },
            include_dirs = driver.foreign_include_dirs(),
            cflags = { "-fsanitize=address,undefined", "-fno-lto",
                "-Wall", "-Wextra", "-Werror" },
        }))
        local ok, failure = xpcall(function()
            local module = assert(service:module_context({ includes = {
                { include_kind = "quote", include_name = header },
            } }))
            local result = module:select_enum_carrier(int_enum, all_ids)
            assert.equal("success", result.status, result.message)
            assert.same({ kind = "enum_carrier", match_count = 1,
                carrier_id = 6 }, result.selection)
        end, debug.traceback)
        assert.is_true(service:close())
        remove_directory(root)
        assert.is_true(ok, failure)
    end)

    it("compiles one selection candidate, forces object output, and copies cache answers", function()
        local service, state = fake_selection_service({ syntax_only = true },
            object_bytes(payload(1, 6)))
        local module = context(service)
        local first = module:select_enum_carrier(int_enum, { 2, 4, 6 })
        assert.equal("success", first.status, first.message)
        assert.same({ kind = "enum_carrier", match_count = 1, carrier_id = 6 }, first.selection)
        assert.equal(2, #state.calls) -- one shared baseline and one whole query
        assert.is_nil(state.calls[1].metadata.object_path)
        assert.is_string(state.calls[2].metadata.object_path)
        assert.is_truthy(table.concat(state.calls[2].argv, " "):find(" -c ", 1, true))
        assert.is_falsy(table.concat(state.calls[2].argv, " "):find("-fsyntax-only", 1, true))
        assert.equal(sha256.hex(first.source), first.key)
        first.selection.carrier_id = 2
        local again = module:select_enum_carrier(int_enum, { 2, 4, 6 })
        assert.equal("service", again.cache_tier)
        assert.equal(6, again.selection.carrier_id)
        assert.equal(2, #state.calls)
        assert.same({}, state.files)
        assert.is_true(service:close())
    end)

    it("preserves deterministic absent and multiple carrier answers", function()
        for _, answer in ipairs({ { 0, 0 }, { 2, 13 } }) do
            local service, state = fake_selection_service(nil,
                object_bytes(payload(answer[1], answer[2])))
            local module = context(service)
            local first = module:select_enum_carrier(int_enum, { 6, 7 })
            assert.equal("success", first.status, first.message)
            assert.equal(answer[1], first.selection.match_count)
            assert.equal(answer[2], first.selection.carrier_id)
            assert.equal("service", module:select_enum_carrier(int_enum, { 6, 7 }).cache_tier)
            assert.equal(2, #state.calls)
            assert.is_true(service:close())
        end
    end)

    it("accepts a COFF enum result through the same object and cache lifecycle", function()
        -- Long COFF section names live in the symbol string table. Parser
        -- bounds and hostile table variants are owned by staticmetadata_spec.
        local result = payload(1, 6)
        local name = ".titan.cprobe\0"
        local bytes = string.pack("<I2I2I4I4I4I2I2", 0x8664, 1, 0,
            60 + #result, 0, 0, 0) ..
            "/4\0\0\0\0\0\0" .. string.pack("<I4I4I4I4I4I4I2I2I4",
                0, 0, #result, 60, 0, 0, 0, 0, 0x40100040) ..
            result .. string.pack("<I4", #name + 4) .. name
        local service, state = fake_selection_service(nil, bytes)
        local module = context(service)
        local selected = module:select_enum_carrier(int_enum, { 2, 4, 6 })
        assert.equal("success", selected.status, selected.message)
        assert.equal(6, selected.selection.carrier_id)
        assert.equal("service", module:select_enum_carrier(int_enum, { 2, 4, 6 }).cache_tier)
        assert.equal(2, #state.calls)
        assert.same({}, state.files)
        assert.is_true(service:close())
    end)

    it("retries missing, malformed and ineligible object payloads after cleanup", function()
        for _, bytes in ipairs({ false, "not an object", object_bytes("wrong"),
            object_bytes(payload(1, 12)), object_bytes(payload(1, 7)),
            object_bytes(payload(2, 9)), object_bytes(payload(0, 6)) }) do
            local service, state = fake_selection_service(nil, bytes)
            local module = context(service)
            for _ = 1, 2 do
                local result = module:select_enum_carrier(int_enum, { 2, 4, 6 })
                assert.equal("infrastructure_failure", result.status)
                assert.equal("result_extraction", result.reason)
                assert.is_nil(result.selection)
                assert.same({}, state.files)
            end
            assert.equal(3, #state.calls) -- baseline is still safely reusable
            assert.is_true(service:close())
        end
    end)

    it("keeps complete question bytes as the only identity across cache tiers", function()
        local cache = temporary_directory()
        local analysis, strategy = cdriver.new_process_analysis(), compiler_io.new_sync()
        local first, first_state = fake_selection_service({ io = strategy,
            process_analysis = analysis, cache_directory = cache }, object_bytes(payload(1, 6)))
        local result = context(first):select_enum_carrier(int_enum, all_ids)
        assert.equal("success", result.status, result.message)
        assert.equal(2, #first_state.calls)
        assert.is_true(first:close())
        local second, second_state = fake_selection_service({ io = strategy,
            process_analysis = analysis, compiler_argv = { "other-compiler" },
            cflags = { "-DOTHER_TARGET" } }, false)
        local reused = context(second):select_enum_carrier(int_enum, all_ids)
        assert.equal("analysis", reused.cache_tier)
        assert.same(result.selection, reused.selection)
        assert.equal(0, #second_state.calls)
        assert.is_true(second:close())
        local third, third_state = fake_selection_service({ cache_directory = cache },
            object_bytes(payload(1, 6)))
        local module = context(third)
        local persisted = module:select_enum_carrier(int_enum, all_ids)
        assert.equal("persistent", persisted.cache_tier)
        assert.same(result.selection, persisted.selection)
        assert.equal(0, #third_state.calls)
        local changed = module:select_enum_carrier(int_enum, { 6, 7 })
        assert.not_equal(result.source, changed.source)
        assert.not_equal(result.key, changed.key)
        assert.equal(1, #third_state.calls) -- persistent baseline
        assert.is_true(third:close())
        remove_directory(cache)
    end)

    it("treats untyped or ineligible cache answers as misses", function()
        local cache = temporary_directory()
        local first = fake_selection_service({ cache_directory = cache },
            object_bytes(payload(1, 6)))
        local result = context(first):select_enum_carrier(int_enum, { 6 })
        assert.equal("success", result.status, result.message)
        assert.is_true(first:close())
        for _, selection in ipairs({ false,
            { kind = "enum_carrier", match_count = 1, carrier_id = 7 } }) do
            write_file(result.cache_path, assert(cprobe_cache.encode({ outcome = "success",
                exit_status = 0, diagnostic = "", selection = selection or nil })))
            local service, state = fake_selection_service({ cache_directory = cache },
                object_bytes(payload(1, 6)))
            local refreshed = context(service):select_enum_carrier(int_enum, { 6 })
            assert.equal("success", refreshed.status, refreshed.message)
            assert.equal(6, refreshed.selection.carrier_id)
            assert.equal(1, #state.calls)
            assert.is_true(service:close())
        end
        remove_directory(cache)
    end)

    it("keeps the first completed typed answer when query executions interleave", function()
        local analysis, strategy = cdriver.new_process_analysis(), compiler_io.new_sync()
        local first = fake_selection_service({ io = strategy, process_analysis = analysis },
            function()
                coroutine.yield("query running")
                return object_bytes(payload(1, 6))
            end)
        local second = fake_selection_service({ io = strategy, process_analysis = analysis },
            object_bytes(payload(1, 7)))
        local first_module, second_module = context(first), context(second)
        local worker = coroutine.create(function()
            return first_module:select_enum_carrier(int_enum, { 6, 7 })
        end)
        local started, marker = coroutine.resume(worker)
        assert.is_true(started)
        assert.equal("query running", marker)
        local completed = second_module:select_enum_carrier(int_enum, { 6, 7 })
        assert.equal("success", completed.status, completed.message)
        assert.equal(7, completed.selection.carrier_id)
        local resumed, reused = coroutine.resume(worker)
        assert.is_true(resumed, reused)
        assert.equal("analysis", reused.cache_tier)
        assert.equal(7, reused.selection.carrier_id)
        assert.is_true(first:close())
        assert.is_true(second:close())
    end)

    it("rejects malformed eligibility questions before launching a compiler", function()
        for _, ids in ipairs({ { 6, 6 }, { 0 }, { 12 }, { 1.5 }, { [2] = 6 } }) do
            local service, state = fake_selection_service(nil, false)
            assert.equal("infrastructure_failure", context(service):select_enum_carrier(int_enum, ids).status)
            assert.equal(0, #state.calls)
            assert.is_true(service:close())
        end
    end)

    it("does not publish selections after object I/O or cleanup failures", function()
        for _, failure in ipairs({ "stat", "read", "oversized", "cleanup" }) do
            local cache = temporary_directory()
            local service, state = fake_selection_service({ cache_directory = cache },
                object_bytes(payload(1, 6)))
            local module = context(service)
            assert.equal("success", module:validate_baseline().status)
            local original_stat = service.io.stat
            local original_read = service.io.read_file
            local original_remove = service.workspace.remove
            if failure == "stat" or failure == "oversized" then
                function service.io:stat(path)
                    if path:match("%.o$") then
                        if failure == "stat" then return nil, "injected object stat failure" end
                        return { kind = "file", size = 16 * 1024 * 1024 + 1 }
                    end
                    return original_stat(self, path)
                end
            elseif failure == "read" then
                function service.io:read_file(path, limit)
                    if path:match("%.o$") then
                        assert.equal(16 * 1024 * 1024, limit)
                        return nil, "injected object read failure"
                    end
                    return original_read(self, path, limit)
                end
            else
                function service.workspace:remove(name)
                    local ok, err = original_remove(self, name)
                    if name:match("%.o$") then return nil, "injected object cleanup failure" end
                    return ok, err
                end
            end
            local failed = module:select_enum_carrier(int_enum, all_ids)
            assert.equal("infrastructure_failure", failed.status)
            assert.is_nil(failed.selection)
            assert.equal(1, #entries(cache)) -- only the header baseline
            service.io.stat, service.io.read_file = original_stat, original_read
            service.workspace.remove = original_remove
            local retried = module:select_enum_carrier(int_enum, all_ids)
            assert.equal("success", retried.status, retried.message)
            assert.equal(6, retried.selection.carrier_id)
            assert.equal(3, #state.calls)
            assert.same({}, state.files)
            assert.is_true(service:close())
            remove_directory(cache)
        end
    end)

    it("caches compiler rejection but retries interrupted or unavailable compilers", function()
        for _, raw in ipairs({
            { started = true, ok = false, status = 1, diagnostic = "invalid declaration" },
            { started = true, ok = false, interrupted = true, diagnostic = "interrupted" },
            { started = false, ok = false, status = 127, diagnostic = "missing compiler" },
        }) do
            local service, state = fake_selection_service(nil, false)
            local module = context(service)
            assert.equal("success", module:validate_baseline().status)
            local original = service.runner
            service.runner = function(argv, metadata)
                original(argv, metadata)
                return raw
            end
            local first = module:select_enum_carrier(int_enum, all_ids)
            local second = module:select_enum_carrier(int_enum, all_ids)
            assert.is_nil(first.selection)
            if raw.status == 1 then
                assert.equal("rejected", first.status)
                assert.equal("service", second.cache_tier)
                assert.equal(2, #state.calls)
            else
                assert.equal("infrastructure_failure", first.status)
                assert.equal("infrastructure_failure", second.status)
                assert.equal(3, #state.calls)
            end
            assert.same({}, state.files)
            assert.is_true(service:close())
        end
    end)

    it("represents an empty eligible list as a deterministic absent carrier", function()
        local service, state = fake_selection_service(nil, object_bytes(payload(0, 0)))
        local selected = context(service):select_enum_carrier(int_enum, {})
        assert.equal("success", selected.status, selected.message)
        assert.equal(0, selected.selection.match_count)
        assert.equal(2, #state.calls)
        assert.is_true(service:close())
    end)

    it("selects real GCC and Clang carriers without linking or target execution", function()
        local root = temporary_directory()
        local header = root .. "/enum-query.h"
        write_file(header, [[
enum probe_enum { PROBE_NEGATIVE = -1, PROBE_POSITIVE = 1 };
typedef enum probe_enum probe_alias;
typedef const enum probe_enum qualified_probe_alias;
enum probe_short { PROBE_SMALL = 1 };
enum probe_wide { PROBE_WIDE = 18446744073709551615ULL };
]])
        local compilers = { os.getenv("CC") or "cc" }
        for _, path in ipairs({ "/usr/bin/clang", "/home/linuxbrew/.linuxbrew/bin/clang" }) do
            if lfs.attributes(path, "mode") == "file" then
                compilers[#compilers + 1] = path
                break
            end
        end
        for _, compiler in ipairs(compilers) do
            for _, short_enums in ipairs({ false, true }) do
                local executions = {}
                local flags = { "-Wall", "-Wextra", "-Werror" }
                if short_enums then flags[#flags + 1] = "-fshort-enums" end
                local service = assert(cprobe.new_service({ compiler_argv = compiler,
                    include_dirs = driver.foreign_include_dirs(),
                    cflags = flags, syntax_only = true,
                    execution_trace = function(event) executions[#executions + 1] = event end }))
                local module = assert(service:module_context({ includes = {
                    { include_kind = "quote", include_name = header } } }))
                local selected_id = short_enums and 2 or 6
                for _, spelling in ipairs({ "enum probe_enum", "probe_alias", "__typeof__((PROBE_NEGATIVE))" }) do
                    local typ = spelling == "probe_alias"
                        and types.CTypedef(spelling, int_enum)
                        or types.CInteger(spelling, true, 3, 32)
                    local selected = module:select_enum_carrier(typ, all_ids)
                    assert.equal("success", selected.status, selected.message)
                    assert.equal(1, selected.selection.match_count)
                    assert.equal(spelling:find("__typeof__", 1, true) and 6 or selected_id,
                        selected.selection.carrier_id)
                end
                local qualified_type =
                    types.CInteger("qualified_probe_alias", true, 3, 32)
                local qualified = module:select_enum_carrier(qualified_type, all_ids)
                assert.equal("success", qualified.status, qualified.message)
                -- GCC versions differ on qualified enums; preserve the answer
                -- from the previous declaration-pair probe on the same host.
                local oracle_service = assert(cprobe.new_service({
                    include_dirs = driver.foreign_include_dirs(),
                    compiler_argv = compiler, cflags = flags, syntax_only = true }))
                local oracle_module = assert(oracle_service:module_context({ includes = {
                    { include_kind = "quote", include_name = header } } }))
                local carrier_type = types.CInteger(
                    short_enums and "signed char" or "int", true,
                    short_enums and 1 or 3, short_enums and 8 or 32)
                local oracle = oracle_module:validate_declaration_compatibility(
                    qualified_type, carrier_type)
                assert.is_true(oracle_service:close())
                assert.is_true(oracle.status == "success" or oracle.status == "rejected",
                    oracle.message)
                local accepted = oracle.status == "success"
                assert.equal(accepted and 1 or 0, qualified.selection.match_count)
                assert.equal(accepted and selected_id or 0, qualified.selection.carrier_id)
                local absent = module:select_enum_carrier(int_enum, { 7 })
                assert.equal("success", absent.status, absent.message)
                assert.equal(0, absent.selection.match_count)
                local wide = types.CInteger("enum probe_wide", false, 4, 64)
                local full = module:select_enum_carrier(wide, all_ids)
                assert.equal("success", full.status, full.message)
                assert.equal(1, full.selection.match_count)
                assert.is_true(full.selection.carrier_id == 9 or
                    full.selection.carrier_id == 11)
                local bounded = module:select_enum_carrier(wide,
                    { 1, 2, 3, 4, 5, 6, 7, 8, 10 })
                assert.equal("success", bounded.status, bounded.message)
                assert.equal(0, bounded.selection.match_count)
                assert.equal(8, #executions) -- baseline + seven complete questions
                for _, event in ipairs(executions) do
                    assert.equal("single", event.batch_kind)
                    assert.equal("success", event.outcome)
                end
                assert.is_true(service:close())
            end
        end
        remove_directory(root)
    end)
end)

describe("speculative acceptance batches", function()
    -- A strategy whose `run` and optional `run_batch` decide each probe from
    -- its fake-workspace source, so batching is observable without processes.
    local function batching_service(decide, options)
        local base = compiler_io.new_sync()
        local log = { runs = {}, batches = {} }
        local state, _, temp_provider = fake_environment()
        local function verdict(argv)
            local source
            for index, argument in ipairs(argv) do
                if argument == "-c" then source = argv[index + 1] end
            end
            local name = source and source:match("([^/\\]+)$")
            return decide(name and state.files[name] or "", argv)
        end
        local strategy = setmetatable({}, { __index = base })
        function strategy:run(argv)
            log.runs[#log.runs + 1] = argv
            return verdict(argv)
        end
        function strategy:run_batch(commands, batch_options)
            log.batches[#log.batches + 1] = {
                count = #commands, jobs = batch_options.jobs,
                files = (function()
                    local names = {}
                    for name in pairs(state.files) do names[#names + 1] = name end
                    return #names
                end)(),
            }
            local results = {}
            for index, argv in ipairs(commands) do results[index] = verdict(argv) end
            return results, log.cancel
        end
        options = options or {}
        options.io = strategy
        options.temp_provider = options.temp_provider or temp_provider
        options.include_dirs = options.include_dirs or {}
        if options.jobs == nil then options.jobs = 4 end
        local service = assert(cprobe.new_service(options))
        return service, log, state
    end

    local function accept()
        return { started = true, ok = true, status = 0, diagnostic = "" }
    end

    local function by_marker(source)
        if source:find("rejected_s", 1, true) then
            return { started = true, ok = false, status = 1,
                diagnostic = "probe.c:9: error: rejected by test compiler" }
        elseif source:find("missing_s", 1, true) then
            return { started = false, ok = false, status = 127,
                diagnostic = "test compiler is unavailable" }
        end
        return accept()
    end

    local function deferring_context(service, answers)
        local batch = service:new_probe_batch(answers)
        batch.deferring = answers == nil
        return assert(service:module_context({ batch = batch })), batch
    end

    it("batches only services whose strategy runner can batch", function()
        local service = batching_service(accept)
        assert.is_true(service:batching())
        assert.is_true(service:close())
        service = batching_service(accept, { jobs = 1 })
        assert.is_false(service:batching())
        assert.is_true(service:close())
        local unbatched = assert(cprobe.new_service({
            include_dirs = {}, jobs = 4,
            io = setmetatable({ run_batch = false }, { __index = compiler_io.new_sync() }),
        }))
        assert.is_false(unbatched:batching())
        assert.is_true(unbatched:close())
        local custom = new_fake_service({ jobs = 4 })
        assert.is_false(custom:batching())
        assert.is_true(custom:close())
        -- The stock native batch stands in only for the stock runner: an
        -- overridden `run`, on the instance or behind its metatable, keeps
        -- synchronous runner calls unless `run_batch` is overridden too.
        local function overriding_run(_, argv) return { started = false, ok = false, argv = argv } end
        local instance = compiler_io.new_sync()
        instance.run = overriding_run
        local delegated_base = compiler_io.new_sync()
        delegated_base.run = overriding_run
        local owned_batch = setmetatable({
            run_batch = function() return {} end,
        }, { __index = delegated_base })
        local output_root_wrapper = setmetatable({
            tmpname = function() return nil, "unused" end,
        }, { __index = compiler_io.new_sync() })
        for _, case in ipairs({
            { instance, false },
            { setmetatable({}, { __index = delegated_base }), false },
            { owned_batch, true },
            { output_root_wrapper, true },
        }) do
            local candidate = assert(cprobe.new_service({
                include_dirs = {}, jobs = 4, io = case[1],
            }))
            assert.equal(case[2], candidate:batching())
            assert.is_true(candidate:close())
        end
        local invalid, err = cprobe.new_service({ include_dirs = {}, jobs = 0 })
        assert.is_nil(invalid)
        assert.equal("jobs must be a positive integer", err)
        local owner = batching_service(accept)
        local other = batching_service(accept)
        local rejected
        rejected, err = other:module_context({ batch = owner:new_probe_batch() })
        assert.is_nil(rejected)
        assert.matches("batch must belong to this probe service", err, 1, true)
        assert.is_true(owner:close())
        assert.is_true(other:close())
    end)

    it("defers eligible misses with their final keys and publishes the verdicts",
    function()
        local service, log, state = batching_service(accept)
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        local first_target = cpointer("first_s")
        local second_target = cpointer("second_s")

        local first = module:probe_unsafe_object_pointer(source, first_target)
        local duplicate = module:probe_unsafe_object_pointer(source, first_target)
        local second = module:probe_unsafe_object_pointer(source, second_target)
        local rendered = cprobe.render_unsafe_object_pointer_source(
            module, source, first_target)
        assert.equal("success", first.status)
        assert.is_true(first.accepted)
        assert.equal(sha256.hex(rendered), first.key)
        assert.equal(first.key, duplicate.key)
        assert.equal("success", second.status)
        assert.not_equal(first.key, second.key)
        -- Only the context baseline compiled synchronously; nothing is staged.
        assert.equal(1, #log.runs)
        assert.same({}, log.batches)
        assert.same({}, state.files)

        assert.is_true(batch:flush())
        assert.same({ { count = 2, jobs = 4, files = 2 } }, log.batches)
        assert.same({}, state.files)
        local cached = module:probe_unsafe_object_pointer(source, first_target)
        assert.is_true(cached.cached)
        assert.equal("service", cached.cache_tier)
        assert.equal(first.key, cached.key)
        assert.is_true(batch:flush())
        assert.equal(1, #log.batches)
        assert.is_true(service:close())
    end)

    it("keeps hits, baseline failures, enum-range and undeclared extents synchronous",
    function()
        local service, log = batching_service(accept)
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        local target = cpointer("target_s")
        batch.deferring = false
        local direct = module:probe_unsafe_object_pointer(source, target)
        assert.is_false(direct.cached)
        assert.equal(2, #log.runs)
        batch.deferring = true
        local hit = module:probe_unsafe_object_pointer(source, target)
        assert.is_true(hit.cached)
        local pair = { left_type = cpointer("left_s"), right_type = cpointer("left_s") }
        local synchronous = module:validate_declaration_compatibilities({ pair })[1]
        assert.equal("success", synchronous.status)
        assert.equal(3, #log.runs)
        local other = { left_type = cpointer("right_s"), right_type = cpointer("right_s") }
        local deferred = module:validate_declaration_compatibilities(
            { other }, { deferrable = true })[1]
        assert.equal("success", deferred.status)
        assert.equal(3, #log.runs)
        assert.equal(1, #batch.pending)
        assert.is_true(batch:flush())
        assert.is_true(service:close())

        local failing, failing_log = batching_service(function(contents)
            if contents:find("titan_probe_b", 1, true) then
                return { started = true, ok = false, status = 1,
                    diagnostic = "probe.c:1: error: broken header" }
            end
            return accept()
        end)
        local failing_module, failing_batch = deferring_context(failing)
        local failed = failing_module:probe_unsafe_object_pointer(source, target)
        assert.equal("infrastructure_failure", failed.status)
        assert.matches("foreign header baseline failed", failed.message, 1, true)
        assert.same({}, failing_batch.pending)
        assert.equal(1, #failing_log.runs)
        assert.is_true(failing:close())
    end)

    it("publishes only real verdicts and answers a recheck from completed runs",
    function()
        local service, log = batching_service(by_marker)
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        local accepted = module:probe_unsafe_object_pointer(source, cpointer("accepted_s"))
        local rejected = module:probe_unsafe_object_pointer(source, cpointer("rejected_s"))
        local missing = module:probe_unsafe_object_pointer(source, cpointer("missing_s"))
        for _, result in ipairs({ accepted, rejected, missing }) do
            assert.equal("success", result.status)
        end
        assert.is_false(batch:flush())
        assert.equal("success", service.result_cache[accepted.key].outcome)
        assert.equal("compiler_rejection", service.result_cache[rejected.key].outcome)
        assert.is_nil(service.result_cache[missing.key])
        assert.is_nil(batch.outcomes[accepted.key])
        assert.is_nil(batch.outcomes[rejected.key])
        assert.equal(1, #batch.outcomes[missing.key])
        local runs = #log.runs

        local recheck = deferring_context(service, batch.outcomes)
        local again_rejected = recheck:probe_unsafe_object_pointer(source, cpointer("rejected_s"))
        local again_missing = recheck:probe_unsafe_object_pointer(source, cpointer("missing_s"))
        assert.equal("rejected", again_rejected.status)
        assert.matches("rejected by test compiler", again_rejected.message, 1, true)
        assert.equal("infrastructure_failure", again_missing.status)
        assert.matches("could not be started", again_missing.message, 1, true)
        -- Completed verdicts and the recorded failure compiled nothing again.
        assert.equal(runs, #log.runs)
        -- The recorded failure answered one request. A further use the
        -- batch deduplicated retries synchronously, as the synchronous
        -- path's second use would.
        local repeated_missing = recheck:probe_unsafe_object_pointer(source, cpointer("missing_s"))
        assert.equal(again_missing.message, repeated_missing.message)
        assert.equal(runs + 1, #log.runs)
        assert.equal(1, #log.batches)
        assert.is_true(service:close())
    end)

    it("replays a recorded failure once, before a verdict published later",
    function()
        local failed_once = {}
        local service, log = batching_service(function(source)
            if source:find("flaky_s", 1, true) and not failed_once[source] then
                failed_once[source] = true
                return { started = false, ok = false, status = 127,
                    diagnostic = "transient test compiler failure" }
            end
            return by_marker(source)
        end)
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        local flaky = cpointer("flaky_s")
        -- A synchronous (top-level) use fails; a later deferred use of the
        -- same source succeeds at the flush and is published.
        batch.deferring = false
        local first = module:probe_unsafe_object_pointer(source, flaky)
        assert.equal("infrastructure_failure", first.status)
        batch.deferring = true
        local second = module:probe_unsafe_object_pointer(source, flaky)
        module:probe_unsafe_object_pointer(source, cpointer("rejected_s"))
        assert.is_false(batch:flush())
        assert.equal("success", service.result_cache[second.key].outcome)
        local runs = #log.runs

        local recheck = deferring_context(service, batch.outcomes)
        local again_first = recheck:probe_unsafe_object_pointer(source, flaky)
        local again_second = recheck:probe_unsafe_object_pointer(source, flaky)
        assert.equal("infrastructure_failure", again_first.status)
        assert.matches("transient test compiler failure", again_first.message, 1, true)
        assert.equal("success", again_second.status)
        assert.is_true(again_second.cached)
        assert.equal("rejected", recheck:probe_unsafe_object_pointer(
            source, cpointer("rejected_s")).status)
        assert.equal(runs, #log.runs)
        assert.is_true(service:close())
    end)

    it("owns nested baseline failures separately from ordered direct validations",
    function()
        for _, failures in ipairs({ 1, 5 }) do
            local baseline_calls, candidate_calls = 0, {}
            local service, log = batching_service(function(source)
                if source:find("titan_probe_b", 1, true) then
                    baseline_calls = baseline_calls + 1
                    if baseline_calls <= failures then
                        return { started = false, ok = false, status = 127,
                            diagnostic = "transient baseline " .. baseline_calls }
                    end
                    return accept()
                end
                candidate_calls[source] = (candidate_calls[source] or 0) + 1
                return by_marker(source)
            end)
            local module, batch = deferring_context(service)
            local source, target = cpointer("source_s"), cpointer("target_s")
            local function candidate(context)
                return context:probe_unsafe_object_pointer(source, target)
            end
            local function direct(context) return context:validate_baseline() end
            -- One nested failure, or three direct failures interleaved with
            -- two nested failures, all followed by same-source recovery.
            local actions = failures == 1 and { candidate, candidate } or
                { direct, candidate, direct, candidate, direct, candidate }
            local original = {}
            for index, action in ipairs(actions) do original[index] = action(module) end
            local recovered = original[#original]
            assert.equal("success", recovered.status)
            assert.equal(failures + 1, baseline_calls)
            module:probe_unsafe_object_pointer(source, cpointer("rejected_s"))
            assert.is_false(batch:flush())
            assert.equal("success", service.result_cache[recovered.key].outcome)
            local runs = #log.runs
            -- A completed candidate must still hit before its baseline. Force
            -- a real miss only when a later distinct candidate needs the gate.
            service.result_cache[module.baseline_key] = nil
            local recheck = deferring_context(service, batch.outcomes)
            for index, action in ipairs(actions) do
                local replayed, first = action(recheck), original[index]
                assert.equal(first.status, replayed.status)
                assert.equal(first.key, replayed.key)
                assert.equal(first.message, replayed.message)
                assert.equal(first.diagnostic, replayed.diagnostic)
                assert.equal(first.stage, replayed.stage)
            end
            assert.equal("rejected", recheck:probe_unsafe_object_pointer(
                source, cpointer("rejected_s")).status)
            assert.equal(runs, #log.runs)
            assert.equal(failures + 1, baseline_calls)
            -- No nested failure can remain in direct-baseline history and
            -- shift onto this uncached distinct-key request.
            local distinct = recheck:probe_unsafe_object_pointer(
                source, cpointer("distinct_s"))
            assert.equal("success", distinct.status)
            assert.is_false(distinct.cached)
            assert.equal(failures + 2, baseline_calls)
            assert.equal(runs + 2, #log.runs)
            for _, calls in pairs(candidate_calls) do assert.equal(1, calls) end
            assert.equal(3, (function()
                local total = 0
                for _ in pairs(candidate_calls) do total = total + 1 end
                return total
            end)())
            assert.equal(1, #log.batches)
            assert.is_true(service:close())
        end
    end)

    it("finishes malformed batch containers and rethrows a raised batch",
    function()
        for _, container in ipairs({ "absent", false, "text", 7, {} }) do
            local service, _, state = batching_service(accept)
            service.io.run_batch = function()
                if container == "absent" then return nil end
                return container
            end
            local module, batch = deferring_context(service)
            local source = cpointer("source_s")
            local first = module:probe_unsafe_object_pointer(source, cpointer("first_s"))
            local second = module:probe_unsafe_object_pointer(source, cpointer("second_s"))
            assert.is_false(batch:flush())
            assert.same({}, state.files)
            for _, result in ipairs({ first, second }) do
                assert.is_nil(service.result_cache[result.key])
                assert.equal("infrastructure_failure",
                    batch.outcomes[result.key][1].classification)
            end
            assert.is_true(service:close())
        end

        local cancellation = setmetatable({}, {
            __tostring = function() return "injected batch cancellation" end,
        })
        local service, _, state = batching_service(accept)
        service.io.run_batch = function() error(cancellation) end
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        local first = module:probe_unsafe_object_pointer(source, cpointer("first_s"))
        local second = module:probe_unsafe_object_pointer(source, cpointer("second_s"))
        local called, raised = pcall(batch.flush, batch)
        assert.is_false(called)
        assert.equal(cancellation, raised)
        -- Every prepared probe source was removed before the error unwound.
        assert.same({}, state.files)
        assert.is_nil(service.result_cache[first.key])
        assert.is_nil(service.result_cache[second.key])
        assert.is_true(service:close())
    end)

    it("finishes every prepared probe when finishing or publication raises",
    function()
        local jobs = require "titan-compiler.jobs"
        local cancellation = setmetatable({}, {
            __tostring = function() return "injected strategy cancellation" end,
        })
        -- A strategy-owned workspace (its methods are called directly, so a
        -- cancellation unwinds) whose first removal after `armed` raises.
        local function raising_removal()
            local state, _, base_provider = fake_environment()
            local control = { armed = false, raised = 0 }
            local function provider(...)
                local workspace = base_provider(...)
                workspace._compiler_io_strategy_owned = true
                local remove = workspace.remove
                function workspace:remove(name)
                    if control.armed and control.raised == 0 then
                        control.raised = 1
                        error(cancellation)
                    end
                    return remove(self, name)
                end
                return workspace
            end
            return state, control, provider
        end
        local function deferred_pair(service)
            local module, batch = deferring_context(service)
            local source = cpointer("source_s")
            local first = module:probe_unsafe_object_pointer(source, cpointer("first_s"))
            local second = module:probe_unsafe_object_pointer(source, cpointer("second_s"))
            return batch, first, second
        end

        -- Cancellation in the first result's artifact removal.
        local state, control, provider = raising_removal()
        local service = batching_service(accept, { temp_provider = provider })
        local batch, first, second = deferred_pair(service)
        control.armed = true
        local called, raised = pcall(batch.flush, batch)
        assert.is_false(called)
        assert.equal(cancellation, raised)
        assert.equal(1, control.raised)
        -- Both prepared probes were finished before the error unwound.
        assert.same({}, state.files)
        assert.is_nil(service.result_cache[first.key])
        assert.is_nil(service.result_cache[second.key])
        assert.is_true(service:close())

        -- Cancellation while publishing the first verdict to the disk tier.
        local directory = temporary_directory()
        local ok, err = pcall(function()
            local published, _, publish_state = batching_service(accept, {
                cache_directory = directory,
            })
            local publish_batch = deferred_pair(published)
            published.io.write_file = function() error(cancellation) end
            local publish_called, publish_raised = pcall(publish_batch.flush, publish_batch)
            assert.is_false(publish_called)
            assert.equal(cancellation, publish_raised)
            assert.same({}, publish_state.files)
            assert.is_true(published:close())
        end)
        remove_directory(directory)
        assert(ok, err)

        -- A caught signal returned with the results survives the raise and
        -- is delivered once, by the owner's close, after the signalled
        -- fixture's cleanup.
        local signal_state, signal_control, signal_provider = raising_removal()
        local delivered = {}
        local previous = jobs.propagate
        jobs.propagate = function(signal)
            if signal then
                delivered[#delivered + 1] = {
                    signal = signal, files = next(signal_state.files),
                    cleaned = signal_state.cleaned,
                }
            end
        end
        ok, err = pcall(function()
            local signalled, log = batching_service(accept, { temp_provider = signal_provider })
            local signal_batch = deferred_pair(signalled)
            log.cancel = 15
            signal_control.armed = true
            local signal_called, signal_raised = pcall(signal_batch.flush, signal_batch)
            assert.is_false(signal_called)
            assert.equal(cancellation, signal_raised)
            assert.equal(15, signalled.cancelled_signal)
            assert.same({}, delivered)
            assert.same({}, signal_state.files)
            assert.equal(0, signal_state.cleaned)
            assert.is_true(signalled:close())
            assert.same({ { signal = 15, cleaned = 1 } }, delivered)
        end)
        jobs.propagate = previous
        assert(ok, err)

        -- An indexed result container that raises answers no command.
        local proxied, _, proxy_state = batching_service(accept)
        proxied.io.run_batch = function()
            return setmetatable({}, { __index = function() error("proxy failure") end })
        end
        local proxy_batch, proxy_first = deferred_pair(proxied)
        assert.is_false(proxy_batch:flush())
        assert.same({}, proxy_state.files)
        local outcome = proxy_batch.outcomes[proxy_first.key][1]
        assert.equal("infrastructure_failure", outcome.classification)
        assert.matches("proxy failure", outcome.diagnostic, 1, true)
        assert.is_true(proxied:close())
    end)

    it("reports preparation failures and delivers a caught signal after close",
    function()
        local jobs = require "titan-compiler.jobs"
        local writes = 0
        local state, _, base_provider = fake_environment()
        local function provider(...)
            local workspace = base_provider(...)
            local write = workspace.write
            function workspace:write(name, contents)
                if name:match("unsafe%-object%-pointer%.c$") then
                    writes = writes + 1
                    if writes == 1 then return nil, "injected write failure" end
                end
                return write(self, name, contents)
            end
            return workspace
        end
        local service, log = batching_service(accept, { temp_provider = provider })
        local module, batch = deferring_context(service)
        local source = cpointer("source_s")
        module:probe_unsafe_object_pointer(source, cpointer("first_s"))
        module:probe_unsafe_object_pointer(source, cpointer("second_s"))
        local delivered = {}
        local previous = jobs.propagate
        log.cancel = 2
        jobs.propagate = function(signal)
            if signal then
                delivered[#delivered + 1] = {
                    signal = signal, files = next(state.files), cleaned = state.cleaned,
                }
            end
        end
        local ok, err = pcall(function()
            local called, raised = pcall(batch.flush, batch)
            assert.is_false(called)
            assert.equal("C probe batch interrupted by signal 2", raised)
            assert.equal(1, log.batches[1].count)
            -- Checking unwinds to the service's owner; nothing is delivered
            -- until it closes the service.
            assert.same({}, delivered)
            assert.equal(2, service.cancelled_signal)
            assert.same({}, state.files)
            local outcome = assert(next(batch.outcomes) and batch.outcomes[next(batch.outcomes)])
            assert.equal("workspace", outcome[1].reason)
            assert.is_true(service:close())
            assert.same({ { signal = 2, cleaned = 1 } }, delivered)
            assert.is_true(service:close())
            assert.equal(1, #delivered)
        end)
        jobs.propagate = previous
        assert(ok, err)
    end)
end)
