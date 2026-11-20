local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local objectmetadata = require "titan-compiler.objectmetadata"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"
-- Artifact snapshots hash every object and both ~11 MB static executables
-- before and after each titanc run; use the installed native SHA-256 (the
-- same digest as titan-compiler.sha256) instead of hashing them in Lua.
local sha256_binary = require("titan")._sha256_binary
local temporary = require "spec.support.temporary"

local REPOSITORY = assert(lfs.currentdir())
if platform.windows then REPOSITORY = assert(platform.path.normalize(REPOSITORY)) end
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local prefix = assert(require("spec.support.installed_prefix").active(),
    "compiler build scenario specs require an installed SDK")
local LUA = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")

local function normalize_slashes(path)
    return (path:gsub("\\", "/"))
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function mkdir(path)
    path = normalize_slashes(path)
    if exists(path) then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then mkdir(parent) end
    assert(lfs.mkdir(path))
end

local function write(path, contents)
    path = normalize_slashes(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir(parent) end
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function remove(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function executable_path(path)
    path = normalize_slashes(path)
    if platform.windows and not path:lower():match("%.exe$") then
        return path .. ".exe"
    end
    return path
end

local function shell_command(argv)
    local quoted = {}
    for index, value in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(value))
    end
    return table.concat(quoted, " ")
end

local function run_command(argv, cwd, env)
    argv = { table.unpack(argv) }
    if platform.windows then
        local ok_call, result = pcall(function()
            return compiler_io.new_sync():run(argv, { cwd = cwd, env = env })
        end)
        assert(ok_call, result)
        local output = result.output or result.diagnostic or ""
        output = output:gsub("\r\n", "\n")
        return result.started and result.ok, output, result.why, result.status
    end
    if env then
        local keys = {}
        for key in pairs(env) do keys[#keys + 1] = key end
        table.sort(keys)
        local prefixed = { "env" }
        for _, key in ipairs(keys) do
            prefixed[#prefixed + 1] = key .. "=" .. tostring(env[key])
        end
        for _, arg in ipairs(argv) do
            prefixed[#prefixed + 1] = arg
        end
        argv = prefixed
    end
    local previous_cwd
    if cwd then
        previous_cwd = assert(lfs.currentdir())
        assert(lfs.chdir(cwd))
    end
    local ok_call, result = pcall(function()
        return compiler_io.new_sync():run(argv)
    end)
    if previous_cwd then
        assert(lfs.chdir(previous_cwd))
    end
    assert(ok_call, result)
    local output = result.output or result.diagnostic or ""
    return result.started and result.ok, output, result.why, result.status
end

local function parse_verbose_output(output)
    local parsed = {
        raw = output,
        object_hits = {},
        object_misses = {},
        link_hits = {},
        link_misses = {},
        native_hits = {},
        native_misses = {},
        module_compiles = {},
        synthetic_compiles = {},
        c_source_compiles = {},
        preprocess_commands = {},
        link_commands = {},
        other_native_commands = {},
    }
    for line in (output .. "\n"):gmatch("(.-)\n") do
        local hit_mod, hit_path = line:match("^Titan object hit ([^:]+): (.+)$")
        local miss_mod, miss_detail = line:match("^Titan object miss ([^:]+): (.+)$")
        local link_hit = line:match("^Titan link hit (.+)$")
        local link_miss_target, link_miss_reason = line:match("^Titan link miss (%a:[^:]+): (.+)$")
        if not link_miss_target then
            link_miss_target, link_miss_reason = line:match("^Titan link miss ([^:]+): (.+)$")
        end
        local native_hit = line:match("^Titan native hit (.+)$")
        local native_miss = line:match("^Titan native miss (.+)$")
        if hit_mod then
            parsed.object_hits[hit_mod] = normalize_slashes(hit_path)
        elseif miss_mod then
            parsed.object_misses[miss_mod] = miss_detail
        elseif link_hit then
            parsed.link_hits[normalize_slashes(link_hit)] = true
        elseif link_miss_target then
            parsed.link_misses[normalize_slashes(link_miss_target)] = link_miss_reason
        elseif native_hit then
            parsed.native_hits[normalize_slashes(native_hit)] = true
        elseif native_miss then
            parsed.native_misses[normalize_slashes(native_miss)] = true
        elseif line ~= ""
            and not line:match("^Titan ")
            and not line:match("^titanc:")
            and not line:match("^%[cprobe%]") then
            local normalized = normalize_slashes(line):gsub('%^"', '"')
            local has_e_flag = normalized:find(" -E ", 1, true) ~= nil
                or normalized:find("'-E'", 1, true) ~= nil
                or normalized:find('"-E"', 1, true) ~= nil
            local is_preprocess = normalized:find("-print-prog-name", 1, true) ~= nil
                or normalized:find("-print-file-name", 1, true) ~= nil
                or normalized:find("-###", 1, true) ~= nil
                or (has_e_flag and (
                    normalized:find("-dD", 1, true) ~= nil
                    or normalized:find("-MD", 1, true) ~= nil
                    or normalized:find(" -x ", 1, true) ~= nil
                    or normalized:find("'-x'", 1, true) ~= nil
                    or normalized:find('"-x"', 1, true) ~= nil
                ))
            local is_compile = not is_preprocess and (
                normalized:find(" -c ", 1, true) ~= nil
                or normalized:find("'-c'", 1, true) ~= nil
                or normalized:find('"-c"', 1, true) ~= nil
            )
            local is_temporary_probe = normalized:find("/.titan-temporary", 1, true) ~= nil
                or normalized:find("static_executable", 1, true) ~= nil
            if is_preprocess then
                parsed.preprocess_commands[#parsed.preprocess_commands + 1] = normalized
            elseif is_compile then
                if is_temporary_probe then
                    parsed.other_native_commands[#parsed.other_native_commands + 1] = normalized
                elseif normalized:find("/.titan-links/", 1, true)
                    or normalized:find("__entrypoint.c", 1, true)
                    or normalized:find("__test_entrypoint.c", 1, true)
                    or normalized:find("__test_runner", 1, true) then
                    parsed.synthetic_compiles[#parsed.synthetic_compiles + 1] = normalized
                elseif normalized:find("/.native/", 1, true) then
                    parsed.c_source_compiles[#parsed.c_source_compiles + 1] = normalized
                else
                    parsed.module_compiles[#parsed.module_compiles + 1] = normalized
                end
            elseif normalized:find("dsymutil", 1, true)
                or normalized:find(" -FO ", 1, true)
                or normalized:find("'-FO'", 1, true)
                or normalized:find('"-FO"', 1, true)
                or normalized:find('"@', 1, true) then
                parsed.other_native_commands[#parsed.other_native_commands + 1] = normalized
            elseif normalized:find(" -o ", 1, true)
                or normalized:find("'-o'", 1, true)
                or normalized:find('"-o"', 1, true) then
                if is_temporary_probe then
                    parsed.other_native_commands[#parsed.other_native_commands + 1] = normalized
                else
                    parsed.link_commands[#parsed.link_commands + 1] = normalized
                end
            end
        end
    end
    return parsed
end

local function collect_artifacts(build_dir, executables, sentinel_time)
    local snapshot = {}
    local function record_file(key, full_path, stamp)
        if not exists(full_path) then return end
        if stamp and sentinel_time then
            assert(lfs.touch(full_path, sentinel_time, sentinel_time))
        end
        local bytes = read(full_path)
        local attr = assert(lfs.attributes(full_path))
        snapshot[key] = {
            path = normalize_slashes(full_path),
            digest = sha256_binary(bytes),
            size = #bytes,
            mtime = attr.modification,
            ino = attr.ino,
        }
    end
    local function visit(directory, relative_prefix)
        if not exists(directory) then return end
        for entry in lfs.dir(directory) do
            if entry ~= "." and entry ~= ".."
                and entry ~= ".titan-links"
                and entry ~= ".titan"
                and not entry:match("^%.titan%-stage") then
                local full = directory .. "/" .. entry
                local rel = relative_prefix ~= "" and (relative_prefix .. "/" .. entry) or entry
                local mode = lfs.symlinkattributes(full, "mode")
                if mode == "directory" then
                    visit(full, rel)
                elseif mode == "file" and (
                    entry:match("%.o$")
                    or entry:match("%.c$")
                    or entry:match("%.ffi%.h$")
                    or entry:match("%.titan%.h$")
                    or entry:match("%.priv%.h$")
                    or entry:match("%.parts$")
                ) then
                    record_file(rel, full, entry:match("%.o$") ~= nil)
                end
            end
        end
    end
    visit(build_dir, "")
    for label, exe_path in pairs(executables or {}) do
        record_file(label, exe_path, true)
    end
    return snapshot
end

local function diff_artifacts(before, after)
    local rewritten = {}
    for key, current in pairs(after) do
        local previous = before[key]
        if not previous
            or current.mtime ~= previous.mtime
            or current.digest ~= previous.digest
            or (previous.ino and current.ino and current.ino ~= previous.ino) then
            rewritten[key] = true
        else
            rewritten[key] = false
        end
    end
    return rewritten
end

local function detail_header_source(value)
    return string.format("#define INCREMENTAL_HEADER_VALUE %d\n", value)
end

local function value_header_source()
    return [[
#ifndef INCREMENTAL_VALUE_H
#define INCREMENTAL_VALUE_H
#include "detail.h"
#ifndef INCREMENTAL_BIAS
#define INCREMENTAL_BIAS 0
#endif
#ifndef INCREMENTAL_EXTRA_BIAS
#define INCREMENTAL_EXTRA_BIAS 0
#endif
static inline int incremental_header_value(void) {
  return INCREMENTAL_HEADER_VALUE + INCREMENTAL_BIAS + INCREMENTAL_EXTRA_BIAS;
}
static inline int incremental_checksum_ok(void) {
  const unsigned char data[3] = { 0x61, 0x62, 0x63 };
  unsigned int acc = 2166136261u;
  for (int i = 0; i < 3; ++i) {
    acc ^= data[i];
    acc *= 16777619u;
  }
  return acc == 0x1a47e90bu ? 1 : 0;
}
#endif
]]
end

local function leaf_module_source(adjustment, extra_declaration)
    return string.format([[
foreign import "value.h"
foreign function native_value(): int return ffi.incremental_header_value() end
foreign function native_checksum_ok(): int return ffi.incremental_checksum_ok() end
local function hidden(): integer return %d end
function value(): integer
    if (native_checksum_ok() as integer) == 0 then raise "native checksum verification failed" end
    return (native_value() as integer) + hidden() - 1
end
%s]], adjustment, extra_declaration or "")
end

local function app_module_source(dependency, expression)
    expression = expression or "extra()"
    return string.format([[
local leaf = import "fixture.%s"
local strings = import "string"
local test = import "test"
-- This literal must never enter the build import graph.
local example = 'local bogus = import "missing.fixture"'
function answer(): integer return leaf.value() + %s end
function testing(): boolean return test.testing() end
]], dependency, expression)
end

local function app_tests_source(case_name, extra_cases)
    return string.format([[
local test = import "test"
local app = import "fixture.app"
local leaf = import "fixture.leaf.titan"
function %s(context: test.Context)
    test.assert(test.testing() and app.testing() and app.answer() > 0 and (leaf.native_value() as integer) > 0)
end
%s]], case_name, extra_cases or "")
end

local function other_tests_source()
    return [[
local test = import "test"
local unrelated = import "fixture.unrelated"
function test_unrelated(context: test.Context)
    test.assert(unrelated.value() == 0)
end
]]
end

local function server_tests_root_source()
    return [[
local first = import "fixture.app_test"
local second = import "fixture.other_test"
]]
end

local function server_main_source()
    return [[
local app = import "fixture.app"
local unrelated = import "fixture.unrelated"
function main(args: {string}): integer
    if app.testing() then raise "test runner active during ordinary application execution" end
    return app.answer() + unrelated.value()
end
]]
end

describe("compiler-owned incremental build scenarios (CLI)", function()
    local workspace, source_dir, build_dir, app_exe, test_exe, sentinel_clock

    local function next_sentinel_time()
        sentinel_clock = sentinel_clock - 2
        return sentinel_clock
    end

    local function put_source(relative, contents)
        local path = source_dir .. "/" .. relative
        write(path, contents)
        return path
    end

    local function populate_baseline_tree()
        put_source("fixture/detail.h", detail_header_source(3))
        put_source("fixture/value.h", value_header_source())
        put_source("fixture/leaf.titan", leaf_module_source(1))
        put_source("fixture/app/app.titan", app_module_source("leaf"))
        put_source("fixture/app/extra.titan",
            'local function extra(): integer return #strings.upper("ok") end\n')
        put_source("fixture/unrelated.titan", "function value(): integer return 0 end\n")
        put_source("fixture/app_test.titan", app_tests_source("test_initial"))
        put_source("fixture/other_test.titan", other_tests_source())
        put_source("server/tests.titan", server_tests_root_source())
        put_source("titan_language_server.titan", server_main_source())
    end

    local function compiler_argv(options)
        options = options or {}
        local env = options.env or {}
        local frontend = options.frontend or (REPOSITORY .. "/titanc")
        local env_table = {
            TITAN_RUNTIME_PREBUILT = "1",
            CCACHE_DISABLE = "1",
            TITAN_PROBE_CACHE_DISABLE = "1",
            TITAN_ROOT = env.TITAN_ROOT or prefix,
            TITAN_BUILD_PROFILE = env.TITAN_BUILD_PROFILE or "validation",
            TITAN_EXTRA_CPPFLAGS = env.TITAN_EXTRA_CPPFLAGS or "",
            TITAN_EXTRA_CFLAGS = env.TITAN_EXTRA_CFLAGS or "-O0 -fno-lto",
            TITAN_EXTRA_LDFLAGS = env.TITAN_EXTRA_LDFLAGS or "-fno-lto",
        }
        if env.PATH then env_table.PATH = env.PATH end
        if env.CC then env_table.CC = env.CC end
        if env.TITAN_C_PARTS then env_table.TITAN_C_PARTS = env.TITAN_C_PARTS end
        local argv = {
            LUA,
            "-E",
            "-e",
            string.format(
                "package.path = %q .. package.path; package.cpath = %q .. package.cpath",
                REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
                REPOSITORY .. "/titan-runtime/bootstrap/?" .. SHARED_SUFFIX .. ";"),
            frontend,
        }
        if options.init_code and options.init_code ~= "" then
            table.insert(argv, 5, options.init_code)
            table.insert(argv, 5, "-e")
        end
        for _, arg in ipairs(options.args or {}) do
            argv[#argv + 1] = arg
        end
        return argv, env_table
    end

    local function invoke_titanc(options)
        local sentinel = next_sentinel_time()
        local tracked_exes = options.executables or {
            ["server-executable"] = app_exe,
            ["test-executable"] = test_exe,
        }
        local before = collect_artifacts(build_dir, tracked_exes, sentinel)
        local argv, env_table = compiler_argv(options)
        local ok, output, why, status = run_command(argv, options.cwd, env_table)
        local after = collect_artifacts(build_dir, tracked_exes, nil)
        local step = parse_verbose_output(output)
        step.ok = ok
        step.why = why
        step.status = status
        step.before = before
        step.after = after
        step.rewritten = diff_artifacts(before, after)
        return step
    end

    local function build_target(kind, options)
        options = options or {}
        local tree_arg = options.tree or source_dir
        local output_arg = options.output or build_dir
        local exe_arg = options.exe or (kind == "test" and test_exe or app_exe)
        local args = { "--incremental", "-v", "--tree", tree_arg, "--output", output_arg }
        if not platform.windows and options.static ~= false then
            args[#args + 1] = "--static"
        end
        if kind == "test" then
            args[#args + 1] = "--test"
        end
        if exe_arg ~= false then
            args[#args + 1] = "--exe"
            args[#args + 1] = exe_arg
        end
        for _, root in ipairs(options.roots or (kind == "test" and { "server.tests" } or { "titan_language_server" })) do
            args[#args + 1] = root
        end
        for _, extra in ipairs(options.extra_args or {}) do
            args[#args + 1] = extra
        end
        local step = invoke_titanc({
            args = args,
            env = options.env,
            cwd = options.cwd,
            frontend = options.frontend,
            executables = options.executables,
        })
        if options.expect_failure then
            assert.is_false(step.ok, step.raw)
        else
            assert.is_true(step.ok, step.raw)
        end
        return step
    end

    local function assert_module_rebuilt(step, modname, object_rel, expected_miss_pattern)
        assert.is_nil(step.object_hits[modname],
            "expected module " .. modname .. " to miss, but it hit:\n" .. step.raw)
        local reason = step.object_misses[modname]
        assert.is_string(reason,
            "missing 'Titan object miss " .. modname .. "' line in:\n" .. step.raw)
        if expected_miss_pattern then
            assert.matches(expected_miss_pattern, reason, 1, true)
        end
        assert.is_true(step.rewritten[object_rel] == true,
            "expected object " .. object_rel .. " to be rewritten on disk:\n" .. step.raw)
        local stem_c = object_rel:gsub("%.o$", ".c"):lower()
        local compiled_c = false
        for _, cmd in ipairs(step.module_compiles) do
            if cmd:lower():find(stem_c, 1, true) then
                compiled_c = true
                break
            end
        end
        assert.is_true(compiled_c,
            "expected native -c command for " .. stem_c .. " in:\n" .. step.raw)
    end

    local function assert_module_reused(step, modname, object_rel)
        assert.is_nil(step.object_misses[modname],
            "expected module " .. modname .. " to hit, but it missed (" ..
            tostring(step.object_misses[modname]) .. "):\n" .. step.raw)
        assert.is_string(step.object_hits[modname],
            "missing 'Titan object hit " .. modname .. "' line in:\n" .. step.raw)
        assert.is_false(step.rewritten[object_rel] == true,
            "expected object " .. object_rel .. " not to be rewritten on disk:\n" .. step.raw)
        local stem_c = object_rel:gsub("%.o$", ".c"):lower()
        for _, cmd in ipairs(step.module_compiles) do
            assert.is_nil(cmd:lower():find(stem_c, 1, true),
                "unexpected native -c command for reused module " .. modname .. ": " .. cmd)
        end
    end

    local function target_matches(targets, exe_full_path)
        exe_full_path = normalize_slashes(exe_full_path)
        if targets[exe_full_path] ~= nil then return targets[exe_full_path] end
        local base = exe_full_path:match("[^/]+$")
        for target, value in pairs(targets) do
            local norm = normalize_slashes(executable_path(target))
            if norm == exe_full_path
                or exe_full_path:sub(-(#norm + 1)) == "/" .. norm
                or (base and (norm == base or norm:sub(-(#base + 1)) == "/" .. base)) then
                return value
            end
        end
        return nil
    end

    local function assert_link_skipped(step, exe_label, exe_full_path)
        exe_full_path = normalize_slashes(exe_full_path)
        assert.is_true(target_matches(step.link_hits, exe_full_path) == true,
            "expected 'Titan link hit " .. exe_full_path .. "' in:\n" .. step.raw)
        assert.is_nil(target_matches(step.link_misses, exe_full_path),
            "unexpected link miss for " .. exe_full_path .. ":\n" .. step.raw)
        assert.equal(0, #step.module_compiles,
            "expected zero module compilations on link hit:\n" .. step.raw)
        assert.equal(0, #step.synthetic_compiles,
            "expected zero synthetic runner/entrypoint compilations on link hit:\n" .. step.raw)
        assert.equal(0, #step.c_source_compiles,
            "expected zero C-source compilations on link hit:\n" .. step.raw)
        assert.equal(0, #step.link_commands,
            "expected zero link commands on link hit:\n" .. step.raw)
        assert.is_false(step.rewritten[exe_label] == true,
            "expected executable " .. exe_label .. " not to be rewritten on link hit")
    end

    local function assert_link_performed(step, exe_label, exe_full_path)
        exe_full_path = normalize_slashes(exe_full_path)
        assert.is_nil(target_matches(step.link_hits, exe_full_path),
            "unexpected 'Titan link hit' when link should run:\n" .. step.raw)
        assert.is_true(#step.link_commands >= 1,
            "expected at least one native link command in:\n" .. step.raw)
        assert.is_true(step.rewritten[exe_label] == true,
            "expected executable " .. exe_label .. " to be written on disk")
    end

    local function run_executable(exe_full_path, extra_args, env_overrides)
        env_overrides = env_overrides or {}
        local standard_titan_path = (platform.windows and (build_dir .. "/lib/titan/0.6;") or "")
            .. prefix .. "/lib/titan/0.6;;"
        local titan_path_0_6 = env_overrides.TITAN_PATH_0_6 or standard_titan_path
        local env_table = {
            TITAN_PATH_0_6 = titan_path_0_6,
            PATH = prefix .. "/bin" .. (platform.windows and ";" or ":") .. (os.getenv("PATH") or ""),
        }
        for key, value in pairs(env_overrides) do
            if key ~= "TITAN_PATH_0_6" then
                env_table[key] = value
            end
        end
        local argv = { exe_full_path }
        for _, arg in ipairs(extra_args or {}) do
            argv[#argv + 1] = arg
        end
        return run_command(argv, nil, env_table)
    end

    local function verify_runtime(expected_app_code, expected_test_names, env_overrides)
        local ok, app_output, why, code = run_executable(app_exe, {}, env_overrides)
        assert.equal("exit", why, app_output)
        assert.equal(expected_app_code, code, app_output)
        assert.equal(expected_app_code == 0, ok, app_output)

        local test_ok, test_output, test_why, test_code =
            run_executable(test_exe, { "--verbose" }, env_overrides)
        assert.equal("exit", test_why, test_output)
        assert.equal(0, test_code, test_output)
        assert.is_true(test_ok, test_output)
        local count_noun = #expected_test_names == 1 and "test." or "tests."
        assert.matches(string.format("[  PASSED  ] %d %s", #expected_test_names, count_noun),
            test_output, 1, true)
        for _, name in ipairs(expected_test_names) do
            assert.matches("[ RUN      ] " .. name, test_output, 1, true)
        end
        return test_output
    end

    before_each(function()
        workspace = temporary.name()
        assert(os.remove(workspace))
        if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
        workspace = normalize_slashes(workspace)
        mkdir(workspace)
        source_dir = workspace .. "/source"
        build_dir = workspace .. "/build"
        app_exe = executable_path(workspace .. "/deliverables/bin/titan-language-server")
        test_exe = executable_path(build_dir .. "/tests/server/tests")
        sentinel_clock = os.time() - 120
    end)

    after_each(function()
        remove(workspace)
    end)

    local function isolated_sdk()
        local uv = require "luv"
        local sdk = workspace .. "/isolated SDK"
        local release_dir = "lib/titan/" .. driver.TITAN_LIBRARY_VERSION
        local function copy(relative)
            local source, target = prefix .. "/" .. relative, sdk .. "/" .. relative
            if lfs.attributes(source, "mode") == "directory" then
                mkdir(target)
                for name in lfs.dir(source) do
                    if name ~= "." and name ~= ".." then copy(relative .. "/" .. name) end
                end
            else
                mkdir(assert(target:match("^(.*)/[^/]+$")))
                assert(uv.fs_copyfile(source, target))
            end
        end
        copy("include")
        copy("src/lua-5.5.1")
        copy("etc/titan/build-profile")
        copy("lib/libbacktrace.a")
        copy(platform.windows and "lib/liblua55.a" or "lib/liblua.a")
        copy(release_dir .. "/libtitan.a")
        copy(release_dir .. "/titan" .. SHARED_SUFFIX)
        local tool_path
        if platform.windows then
            -- Fresh image validation uses the selected SDK's lua.exe. Keep
            -- its DLLs beside it and on PATH for the generated launchers too.
            for _, name in ipairs({ "lua.exe", "lua55.dll", "libuv-1.dll",
                    "libllhttp-9.4.dll", "libsqlite3-0.dll", "libssl-3-x64.dll",
                    "libcrypto-3-x64.dll" }) do
                copy("bin/" .. name)
            end
            tool_path = sdk .. "/bin;" .. (os.getenv("PATH") or "")
        else
            copy(release_dir .. "/titan.a")
        end
        return sdk, sdk .. "/" .. release_dir, tool_path
    end

    it("uses installed source modules without treating the SDK as an output or test-discovery root", function()
        local uv = require "luv"
        local sdk, lib, tool_path = isolated_sdk()
        local module = lib .. "/fruit/pick/pick.titan"
        write(module, "function answer(): integer return add(40) end\n")
        write(lib .. "/fruit/pick/internal.titan",
            "local function add(n: integer): integer return n + 2 end\n")
        write(lib .. "/sdk_test.titan", "this must not be discovered\n")
        write(lib .. "/sdk_entry.titan",
            "function main(args: {string}): integer return 0 end\n")
        put_source("consumer.titan", [[
local pick = import "fruit.pick"
function main(args: {string}): integer return pick.answer() - 42 end
]])
        put_source("private_consumer.titan", [[
local pick = import "fruit.pick.titan"
function main(args: {string}): integer return pick.add(40) - 42 end
]])
        put_source("plain.titan", "function answer(): integer return 42 end\n")
        put_source("fixture_test.titan", [[
local test = import "test"
local pick = import "fruit.pick"
function test_installed(context: test.Context)
    test.assert(pick.answer() == 42)
end
]])
        put_source("uses_sdk.titan", [[
local pick = import "fruit.pick"
function answer(): integer return pick.answer() end
]])
        put_source("through_sdk.titan", [[
local wrapper = import "uses_sdk"
function answer(): integer return wrapper.answer() end
]])
        put_source("private_library.titan", [[
local pick = import "fruit.pick.titan"
function answer(): integer return pick.add(40) end
]])
        put_source("ordinary_library.titan", [[
local pick = import "fruit.pick"
function answer(): integer return pick.add(40) end
]])
        local collector = require("spec.support.luacov_children").new(
            REPOSITORY, REPOSITORY, workspace .. "/child-coverage")
        local init_code = collector:init_code()
        local function compile(cwd, ...)
            local args = { "-v", ... }
            if args[2] ~= "--print-ast" then table.insert(args, 2, "--incremental") end
            local argv, env = compiler_argv({
                args = args,
                env = { TITAN_ROOT = sdk, PATH = tool_path }, init_code = init_code,
            })
            return run_command(argv, cwd, env)
        end
        local function run_program(output, name)
            local executable = platform.windows and
                assert(driver.windows_program_paths(name, nil, nil, output)).executable or
                output .. "/" .. name
            return run_executable(executable, nil, {
                TITAN_PATH_0_6 = lib .. ";;", PATH = tool_path,
            })
        end
        local ok, output = compile(source_dir, "consumer")
        assert.is_false(ok, output)
        assert.matches("installed source module 'fruit.pick' requires --output DIR", output, 1, true)
        ok, output = compile(source_dir, "-c", "plain")
        assert.is_true(ok, output)
        assert.is_true(exists(source_dir .. "/plain.o"))
        assert.is_false(exists(lib .. "/.titan-build.lock"))
        ok, output = compile(workspace, "--tree", source_dir, "--test",
            "--test-dir", lib, "-o", build_dir)
        assert.is_false(ok, output)
        assert.matches("is outside every --tree source root", output, 1, true)
        -- Reject every positional mode before generating the requested root,
        -- even when the first root needs it as an import, or discovery adds
        -- authored tests. An SDK source with main is not an --exe target.
        local root_error = "is installed in the SDK; titanc builds only authored roots"
        for index, invocation in ipairs({
            { "fruit.pick" },
            { "-c", "fruit.pick" },
            { "--test", "fruit.pick" },
            { "--test", "--test-dir", source_dir, "--tree", source_dir, "fruit.pick" },
            { "--exe", workspace .. "/not-authored", "sdk_entry" },
            { "consumer", "fruit.pick" },
        }) do
            local rejected = workspace .. "/rejected-" .. index
            ok, output = compile(source_dir, "-o", rejected, table.unpack(invocation))
            assert.is_false(ok, output)
            assert.matches(root_error, output, 1, true)
            assert.matches("pass --tree to a checkout of it", output, 1, true)
            assert.is_false(exists(rejected .. "/fruit"))
            assert.is_false(exists(rejected .. "/consumer.o"))
            assert.is_false(exists(rejected .. "/sdk_entry.o"))
        end
        ok, output = compile(source_dir, "--print-ast", "-o", build_dir, "fruit.pick")
        assert.is_false(ok, output)
        assert.matches(root_error, output, 1, true)
        local library = build_dir .. "/library"
        ok, output = compile(source_dir, "--print-ast", "-o", library, "uses_sdk")
        assert.is_true(ok, output)
        assert.is_false(exists(library .. "/fruit/pick/pick.o"))
        local rejected = build_dir .. "/private-library"
        ok, output = compile(source_dir, "-o", rejected, "private_library")
        assert.is_false(ok, output)
        assert.matches("fruit.pick.titan", output, 1, true)
        assert.matches("import \"fruit.pick\"", output, 1, true)
        assert.is_false(exists(rejected .. "/private_library.o"))
        ok, output = compile(source_dir, "-o", build_dir .. "/ordinary-library", "ordinary_library")
        assert.is_false(ok, output)
        assert.matches("fruit.pick", output, 1, true)
        assert.matches("add", output, 1, true)

        write(module, "function answer(): integer return false end\n")
        ok, output = compile(source_dir, "-o", library, "through_sdk")
        assert.is_false(ok, output)
        assert.matches("pick.titan", output, 1, true)
        assert.matches("integer", output, 1, true)
        write(module, "function answer(): integer return add(40) end\n")
        ok, output = compile(source_dir, "-o", library, "through_sdk")
        assert.is_true(ok, output)
        assert.is_true(exists(library .. "/through_sdk" .. SHARED_SUFFIX))
        assert.is_false(exists(library .. "/fruit/pick/pick.o"))
        if not platform.windows then assert.is_true(exists(library .. "/through_sdk.a")) end
        if not platform.windows then
            -- This SDK has no bin/lua, and the invoking Lua has options before
            -- the script name. Fresh validation must use that interpreter.
            local provider = build_dir .. "/provider"
            assert.is_false(exists(sdk .. "/bin/lua"))
            ok, output = compile(source_dir, "-o", provider, "plain")
            assert.is_true(ok, output)
            assert.is_true(exists(provider .. "/plain.so"))
            assert.is_true(exists(provider .. "/plain.a"))
        end

        ok, output = compile(source_dir, "-o", build_dir, "consumer")
        assert.is_true(ok, output)
        assert.is_true(exists(build_dir .. "/fruit/pick/pick.o"))
        local ran, result = run_program(build_dir, "consumer")
        assert.is_true(ran, result)
        ok, output = compile(workspace, "--tree", source_dir, "-o", build_dir, "consumer")
        assert.is_true(ok, output)
        assert.matches("Titan object hit fruit.pick", output, 1, true)
        local installed_object = read(build_dir .. "/fruit/pick/pick.o")
        ok, output = compile(source_dir, "-c", "-o", build_dir, "fruit.pick")
        assert.is_false(ok, output)
        assert.matches(root_error, output, 1, true)
        assert.equal(installed_object, read(build_dir .. "/fruit/pick/pick.o"))
        ok, output = compile(source_dir, "-j", "2", "-o", build_dir, "private_consumer")
        assert.is_true(ok, output)
        ran, result = run_program(build_dir, "private_consumer")
        assert.is_true(ran, result)
        ok, output = compile(workspace, "--tree", source_dir, "--test",
            "--test-dir", source_dir, "-o", build_dir .. "/sdk-test")
        assert.is_true(ok, output)
        ran, result = run_program(build_dir .. "/sdk-test", "fixture_test")
        assert.is_true(ran, result)
        assert.matches("[  PASSED  ] 1 test.", result, 1, true)
        ok, output = compile(workspace, "--tree", source_dir, "consumer")
        assert.is_false(ok, output)
        assert.matches("installed source module 'fruit.pick' requires --output DIR", output, 1, true)
        write(module, "function answer(): integer return add(41) end\n")
        ok, output = compile(workspace, "--tree", source_dir, "-o", build_dir, "consumer")
        assert.is_true(ok, output)
        assert.matches("Titan object miss fruit.pick", output, 1, true)
        local _, _, reason, status = run_program(build_dir, "consumer")
        assert.equal("exit", reason)
        assert.equal(1, status)

        local second = workspace .. "/second"
        write(second .. "/fruit/pick.titan", "function answer(): integer return 42 end\n")
        ok, output = compile(workspace, "--tree", second, "-c", "-o", build_dir .. "/authored", "fruit.pick")
        assert.is_true(ok, output)
        assert.is_true(exists(build_dir .. "/authored/fruit/pick.o"))
        local authored = build_dir .. "/authored-library"
        ok, output = compile(workspace, "--tree", source_dir .. ";" .. second,
            "-o", authored, "through_sdk")
        assert.is_true(ok, output)
        assert.is_true(exists(authored .. "/through_sdk" .. SHARED_SUFFIX))
        local provider = build_dir .. "/dependency-provider"
        ok, output = compile(workspace, "--tree", second, "-o", provider, "fruit.pick")
        assert.is_true(ok, output)
        assert(uv.fs_copyfile(provider .. "/fruit/pick" .. SHARED_SUFFIX,
            lib .. "/fruit/pick" .. SHARED_SUFFIX))
        local binary = build_dir .. "/compiled-library"
        ok, output = compile(workspace, "--tree", source_dir, "-o", binary, "through_sdk")
        assert.is_true(ok, output)
        assert.is_true(exists(binary .. "/through_sdk" .. SHARED_SUFFIX))
        assert.is_false(exists(binary .. "/fruit"))
        ok, output = compile(workspace, "--tree", source_dir .. ";" .. second,
            "--test", "--test-dir", source_dir, "-o", build_dir .. "/test")
        assert.is_true(ok, output)
        ran, result = run_program(build_dir .. "/test", "fixture_test")
        assert.is_true(ran, result)
        assert.matches("[  PASSED  ] 1 test.", result, 1, true)
        assert.is_false(exists(lib .. "/fruit/pick/pick.o"))
        assert.is_false(exists(lib .. "/fruit/pick/pick.c"))
        assert.is_false(exists(lib .. "/.titan-build.lock"))
        collector:collect()
    end)

    it("uses compiled nominal owners exposed by an installed source without linking them into a library", function()
        local uv = require "luv"
        local sdk, lib, tool_path = isolated_sdk()
        put_source("owner/model.h", "typedef struct cell { int unused; } cell;\n")
        put_source("owner/model.titan", [[
foreign import "model.h"

record Cell
  serial: integer
  local data: foreign cell
end

function Cell.new(serial: integer): Cell
  local data = foreign cell.new()
  return { serial = serial, data = data }
end
]])
        write(lib .. "/units.h", "typedef struct quantity { int unused; } quantity;\n")
        write(lib .. "/units.titan", [[
foreign import "units.h"

record Quantity
  count: integer
  local data: foreign quantity
end

function Quantity.new(count: integer): Quantity
  local data = foreign quantity.new()
  return { count = count, data = data }
end
]])
        write(lib .. "/instruments/meter.titan", [[
local strings = import "string"
local model = import "model"
local units = import "units"

type Quantity = units.Quantity

function measure(): Quantity
  return units.Quantity(7)
end

function cell(): model.Cell
  return model.Cell(42)
end

function writer(): strings.StringWriter
  return strings.writer()
end
]])
        put_source("library/via.titan", [[
local meter = import "instruments.meter"

type Quantity = meter.Quantity

function measure(): Quantity
  return meter.measure()
end

function text(): string
  local writer = meter.writer()
  writer:write("shared")
  return writer:drain() .. ":" .. meter.cell().serial
end
]])
        put_source("app/nominal.titan", [[
local via = import "via"

function main(args: {string}): integer
  if via.text() ~= "shared:42" or via.measure().count ~= 7 then return 1 end
  return 0
end
]])
        put_source("app/model_only.titan", [[
local model = import "model"

function main(args: {string}): integer
  return model.Cell(42).serial - 42
end
]])
        put_source("wrapper/wrap.titan", [[
local via = import "via"

function count(): integer
  return via.measure().count
end
]])
        put_source("app/wrapped.titan", [[
local wrap = import "wrap"

function main(args: {string}): integer
  return wrap.count() - 7
end
]])
        local collector = require("spec.support.luacov_children").new(
            REPOSITORY, REPOSITORY, workspace .. "/child-coverage")
        local function built(tree, output, ...)
            local argv, env = compiler_argv({
                args = { "--tree", source_dir .. "/" .. tree, "-o", output,
                    "--incremental", "-v", "-j", "2", ... },
                env = { TITAN_ROOT = sdk, PATH = tool_path },
                init_code = collector:init_code(),
            })
            local ok, log = run_command(argv, workspace, env)
            assert.is_true(ok, log)
            return parse_verbose_output(log)
        end
        local function run(name, output)
            local program = platform.windows and
                assert(driver.windows_program_paths(name, nil, nil, output)).executable or
                output .. "/" .. name
            local providers = platform.windows and
                output .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION .. ";" .. lib or lib
            local ok, result = run_command({ program }, workspace, {
                TITAN_ROOT = sdk, TITAN_PATH_0_6 = providers, PATH = tool_path,
            })
            assert.is_true(ok, result)
        end
        local function launcher_source(output, name)
            local links = output .. "/.titan-links"
            for entry in lfs.dir(links) do
                local filename = links .. "/" .. entry .. "/synthetic/" .. name .. "__entrypoint.c"
                if exists(filename) then return read(filename) end
            end
            error("missing generated launcher for " .. name)
        end
        local function install(output, filename)
            assert(uv.fs_copyfile(output .. "/" .. filename, lib .. "/" .. filename))
        end
        local function publish(output)
            local step = built("library", output, "via")
            assert.matches("Finished in [^\n]+: 1 compiled, linked via", step.raw)
            assert.equal(1, #step.module_compiles, step.raw)
            assert.is_false(exists(output .. "/instruments/meter.o"))
            assert.is_false(exists(output .. "/units.o"))
            local object = output .. "/via.o"
            local record = assert(objectmetadata.read(read(object), object))
            for _, owner in ipairs({ "titan.string", "model", "units" }) do
                assert.equal("global", record.object_metadata.bindings[owner])
                assert.is_nil(record.object_metadata.providers[owner])
            end
            step = built("library", output, "via")
            assert.matches("Finished in [^\n]+: 1 up to date, via", step.raw)
            assert.same({}, step.module_compiles)
            assert.truthy(step.object_hits.via, step.raw)
            assert.truthy(next(step.link_hits), step.raw)
            install(output, "via" .. SHARED_SUFFIX)
            if not platform.windows then
                local archive = output .. "/via.a"
                local parsed = assert(staticmetadata.scan_archive(archive))
                assert.same({ "via" }, parsed.key_order)
                assert.same({ "instruments.meter" }, parsed.entries.via.source_requirements)
                install(output, "via.a")
            end
        end

        local owner = build_dir .. "/owner"
        built("owner", owner, "model")
        install(owner, "model" .. SHARED_SUFFIX)
        if not platform.windows then install(owner, "model.a") end
        local control = build_dir .. "/no-source-requirements"
        built("app", control, "model_only")
        assert.not_matches("titan_linked_entries", launcher_source(control, "model_only"), 1, true)
        run("model_only", control)
        publish(build_dir .. "/library")

        -- Exercise the saved compiler API with the same published via, first
        -- against source and then against two physically distinct binaries.
        local replacement, bundle = build_dir .. "/replacement", build_dir .. "/bundle"
        put_source("replacement/instruments/meter.titan", read(lib .. "/instruments/meter.titan"))
        put_source("replacement/units.titan", read(lib .. "/units.titan"))
        put_source("replacement/units.h", read(lib .. "/units.h"))
        put_source("replacement/instruments/marker.titan", "const marker = true\n")
        built("replacement", replacement, "instruments.meter")
        built("replacement", bundle, "instruments.meter", "instruments.marker")
        local separate_owner, separate_meter = build_dir .. "/separate-owner", build_dir .. "/separate-meter"
        put_source("separate-meter/instruments/meter.titan", read(lib .. "/instruments/meter.titan"))
        built("replacement", separate_owner, "units")
        install(separate_owner, "units" .. SHARED_SUFFIX)
        if not platform.windows then install(separate_owner, "units.a") end
        built("separate-meter", separate_meter, "instruments.meter")
        assert(os.remove(lib .. "/units" .. SHARED_SUFFIX))
        if not platform.windows then assert(os.remove(lib .. "/units.a")) end
        local client = put_source("semantic/consumer.titan", [[
local via = import "via"
function inspect(): integer
  return via.measure().count
end
]])
        local api_fixture = workspace .. "/semantic.lua"
        write(api_fixture, [=[
local checker = require "titan-compiler.checker"
local completion = require "titan-compiler.completion"
local driver = require "titan-compiler.driver"
local paths = require "titan-compiler.path"
local types = require "titan-compiler.types"
local source_root, installed, client, expected_provider, expected_owner, owner_artifact = ...
local meter_name = "instruments.meter"
local meter_file = installed .. "/instruments/meter.titan"
local owner_file = installed .. "/units.titan"
driver.TITAN_SOURCE_PATH, driver.TITAN_BIN_PATH = source_root, installed

local function read(filename)
    local file <close> = assert(io.open(filename, "rb"))
    return assert(file:read("a"))
end
local function write(filename, bytes)
    local file <close> = assert(io.open(filename, "wb"))
    assert(file:write(bytes))
end
local function start(analysis, options, context_options)
    driver.imported, types.registry = {}, {}
    context_options = context_options or {}
    context_options.analysis_only = analysis
    context_options.transient_caches = true
    local context = driver.new_resolver_context(context_options)
    assert(context.installed_source_root == nil and context.output_root == nil)
    options = options or {}
    options.context = context
    return driver.defaultloader({}, options), context
end
local function clean(name, loader)
    local modtype, errors = checker.checkimport(name, loader)
    assert(modtype, errors)
    assert(#errors == 0, table.concat(errors, "\n"))
    return modtype
end
local function finalize(context)
    local result, errors = driver.finalize_resolver_context(context)
    assert(result, errors and table.concat(errors, "\n"))
end
local function verify_owner()
    local provider, meter, units = driver.imported.via, driver.imported[meter_name], driver.imported.units
    assert(provider.kind == "dynamic" and provider.source_requirements[1] == meter_name
        and #provider.source_requirements == 1)
    assert(meter.ast and meter.deps.units and paths.to_slash(meter.filename) == meter_file)
    assert(units.ast and paths.to_slash(units.source_files[1]) == owner_file)
    assert(paths.to_slash(units.ast[2].loc.filename) == owner_file)
    local quantity = assert(types.registry["units.Quantity"])
    assert(quantity.fields[1].name == "count" and quantity.fields[1].type._tag == "Type.Integer")
end

local loader, context = start(false, nil, { source_first = expected_provider ~= nil })
clean("via", loader)
verify_owner()
finalize(context)
assert(driver.close_loader(loader))

loader, context = start(true, nil, { source_first = expected_provider ~= nil })
local consumer = clean("consumer", loader)
assert(consumer.members.inspect.type.rettypes[1]._tag == "Type.Integer")
verify_owner()
assert(driver.imported.consumer.ast._analysis_only)
assert(driver.imported.via.deps[meter_name] and not driver.imported.via.deps.units)
finalize(context)
for _, provenance in pairs(context.contextual_resolutions) do
    assert(provenance.owner ~= "units")
end
local binaries = driver.completion_binary_catalog(context)
local saved_sources = {}
for _, name in ipairs({ meter_name, "units" }) do
    local payload = assert(driver.encode_project_entry(driver.imported[name]))
    saved_sources[name] = assert(driver.decode_project_entry(payload))
end
assert(driver.close_loader(loader))

local function assert_closed_completion(binaries, saved_sources)
    local text = read(client)
    local start_of_field = assert(text:find("count", 1, true))
    local prepared = assert(completion.prepare(client, text, start_of_field + 1))
    local io_strategy = require("titan-compiler.io").new_sync()
    local read_file = io_strategy.read_file
    function io_strategy:read_file(filename, ...)
        assert(not filename:match("%.titan$"), "completion read " .. filename)
        return read_file(self, filename, ...)
    end
    local native = require "titan"
    local loadlib = native._loadlib
    native._loadlib = function() error("completion inspected a DSO") end
    local loader = start(true, {
        cached_binary_interfaces = binaries, cached_source_entries = saved_sources,
        source_roots = { consumer = true },
        source_overrides = { consumer = { kind = "generated", main = client, files = { client },
            contents = { [client] = prepared.text } } },
    }, { completion_closed_world = true, completion = prepared.request, io = io_strategy })
    assert(loader("consumer"))
    local candidates = assert(driver.imported.consumer.completion).candidates
    local found
    for _, candidate in ipairs(candidates) do
        if candidate.name == "count" then found = candidate end
        assert(candidate.name ~= "data")
    end
    assert(found and found.detail == "integer")
    assert(driver.close_loader(loader))
    native._loadlib = loadlib
end
assert_closed_completion(binaries, saved_sources)

local meter = read(meter_file)
local function reselect(name, source_required)
    local probe = driver.new_resolver_context({ analysis_only = true })
    local resolved = driver.resolve_external_modules({ [name] = source_required }, {}, probe)[name]
    assert(driver.close_resolver_context(probe))
    return resolved
end
local function reject(detail)
    local attempt = start(true)
    assert(attempt("via"))
    assert(driver.imported[meter_name] == nil)
    for _ = 1, 2 do
        local modtype, err = checker.checkimport("via", attempt)
        assert(not modtype and err:find("module 'via' requires module '" .. meter_name .. "'", 1, true), err)
        assert(err:find(detail, 1, true), err)
    end
    assert(driver.close_loader(attempt))
end
assert(paths.to_slash(reselect("units", false).main_file) == owner_file)
assert(paths.to_slash(reselect(meter_name, true).main_file) == meter_file)

for _, order in ipairs({ { "units", "via" }, { "via", "units" } }) do
    loader, context = start(true)
    for _, name in ipairs(order) do clean(name, loader) end
    verify_owner()
    finalize(context)
    assert(driver.close_loader(loader))
end
loader = start(true, { source_roots = { units = true } })
local ok, missing = loader("units")
assert(not ok and missing == "source module 'units' not found", missing)
assert(driver.close_loader(loader))
assert(os.remove(meter_file))
assert(reselect(meter_name, true).kind == "error")
if expected_provider then
    local units = read(owner_file)
    assert(os.remove(owner_file))
    if expected_owner then
        write(expected_owner, read(owner_artifact))
        local prefer_static = expected_owner:sub(-2) == ".a"
        local kind = prefer_static and "static" or "dynamic"
        loader, context = start(true, { cached_source_entries = saved_sources }, { prefer_static = prefer_static })
        clean("consumer", loader)
        assert(driver.imported.via.kind == kind)
        assert(driver.imported.units == nil)
        finalize(context)
        assert(driver.imported.units == nil)
        for _, provider in ipairs(context.selected_static_providers) do
            assert(paths.to_slash(provider.archive) ~= expected_owner)
        end
        local observation
        for _, row in pairs(context.contextual_resolutions) do
            if row.owner == "units" and row.exposer == "via" then observation = row end
        end
        assert(observation and observation.ordinary_lookup and observation.kind == kind)
        assert(paths.to_slash(observation.provider_file) == expected_owner)
        binaries = driver.completion_binary_catalog(context)
        local captured = assert(binaries.units, "saved catalog omitted the contextual-only owner")
        assert(captured.kind == kind and paths.to_slash(captured.filename) == expected_owner)
        assert(driver.close_loader(loader))
        assert_closed_completion(binaries, {})
        write(meter_file, meter)
        write(owner_file, units)
        return
    end
    local elected = reselect(meter_name, false)
    assert(elected.kind == "dynamic" and paths.to_slash(elected.provider_file) == expected_provider)
    for _, analysis in ipairs({ false, true }) do
        loader, context = start(analysis, { cached_source_entries = saved_sources })
        clean("consumer", loader)
        local chosen = driver.imported[meter_name]
        assert(chosen.kind == "dynamic" and paths.to_slash(chosen.filename) == expected_provider)
        assert(driver.imported.via.deps[meter_name] and not driver.imported.via.deps.units)
        assert(driver.imported.units == nil)
        assert(types.registry["units.Quantity"].fields[1].name == "count")
        finalize(context)
        local carried
        for _, row in pairs(context.contextual_resolutions) do
            if row.owner == "units" and row.exposer == meter_name then carried = row end
        end
        assert(carried and not carried.ordinary_lookup and
            paths.to_slash(carried.provider_file) == expected_provider)
        binaries = driver.completion_binary_catalog(context)
        assert(driver.close_loader(loader))
        if analysis then assert_closed_completion(binaries, {}) end
    end
    write(meter_file, meter)
    write(owner_file, units)
    return
end
assert(reselect(meter_name, false).kind == "missing")
reject("not found")
write(meter_file, "record\n")
reject("meter.titan:")
write(meter_file, "const broken: integer = {}\n")
reject("meter.titan:")
write(meter_file, 'local via = import "via"\n')
reject("circular reference")
write(meter_file, meter)

assert(require("lfs").mkdir(source_root .. "/instruments"))
local override = source_root .. "/instruments/meter.titan"
write(override, meter .. "\nconst authored = true\n")
assert(paths.to_slash(reselect(meter_name, true).main_file) == override)
loader, context = start(true, { cached_source_entries = saved_sources })
clean("consumer", loader)
assert(paths.to_slash(driver.imported[meter_name].filename) == override)
assert(driver.imported[meter_name].type.members.authored and driver.imported[meter_name].ast)
finalize(context)
assert(driver.close_loader(loader))
assert(os.remove(override))

loader, context = start(true, { cached_source_entries = saved_sources })
clean("consumer", loader)
assert(paths.to_slash(driver.imported.units.filename) == owner_file)
assert(not driver.imported.units.ast and driver.imported.units._analysis_manifest)
finalize(context)
assert(driver.close_loader(loader))
]=])
        local semantic_inputs = collect_artifacts(lib)
        local function run_semantics(provider, nominal_owner, owner_artifact)
            local argv, env = compiler_argv({
                frontend = api_fixture,
                args = { source_dir .. "/semantic", lib, client, provider, nominal_owner, owner_artifact },
                env = { TITAN_ROOT = sdk, PATH = tool_path },
                init_code = collector:init_code(),
            })
            local ok, diagnostics = run_command(argv, workspace, env)
            assert.is_true(ok, diagnostics)
        end
        run_semantics()
        for _, selection in ipairs({
            { replacement, "instruments/meter" }, { bundle, "instruments" },
        }) do
            local file = selection[2] .. SHARED_SUFFIX
            install(selection[1], file)
            run_semantics(lib .. "/" .. file)
            assert(os.remove(lib .. "/" .. file))
        end
        local function separate_semantics(suffix)
            local owner_file = "units" .. suffix
            local provider_file = "instruments/meter" .. suffix
            install(separate_meter, provider_file)
            run_semantics(lib .. "/" .. provider_file, lib .. "/" .. owner_file, separate_owner .. "/" .. owner_file)
            assert(os.remove(lib .. "/" .. owner_file))
            assert(os.remove(lib .. "/" .. provider_file))
        end
        separate_semantics(SHARED_SUFFIX)
        if not platform.windows then separate_semantics(".a") end
        assert.same(semantic_inputs, collect_artifacts(lib))
        assert.same({}, collect_artifacts(source_dir .. "/semantic"))
        assert.is_false(exists(lib .. "/.titan-build.lock"))

        local wrapper = build_dir .. "/wrapper"
        local objects = built("wrapper", wrapper, "-c", "wrap")
        assert.equal(1, #objects.module_compiles, objects.raw)
        assert.is_false(exists(wrapper .. "/wrap" .. SHARED_SUFFIX))
        assert.is_false(exists(wrapper .. "/wrap.a"))
        for _, dependency in ipairs({ "instruments/meter", "units" }) do
            assert.is_false(exists(wrapper .. "/" .. dependency .. ".o"))
        end
        local object = wrapper .. "/wrap.o"
        local metadata = assert(objectmetadata.read(read(object), object)).object_metadata
        assert.same({ "instruments.meter" }, metadata.source_requirements)
        assert.equal("global", metadata.bindings.units)
        assert.is_nil(metadata.bindings["instruments.meter"])

        local wrapped_library = built("wrapper", wrapper, "wrap")
        assert.truthy(wrapped_library.object_hits.wrap, wrapped_library.raw)
        assert.same({}, wrapped_library.module_compiles)
        wrapped_library = built("wrapper", wrapper, "wrap")
        assert.truthy(wrapped_library.object_hits.wrap, wrapped_library.raw)
        assert.truthy(next(wrapped_library.link_hits), wrapped_library.raw)
        assert.same({}, wrapped_library.module_compiles)
        local image = wrapper .. "/wrap" .. SHARED_SUFFIX
        local inspected, exports = run_command(platform.windows and
            { "llvm-readobj", "--coff-exports", image } or { "nm", "-g", image }, workspace)
        assert.is_true(inspected, exports)
        assert.matches("wrap_init", exports, 1, true)
        for _, dependency in ipairs({ "instruments_meter", "units", "via" }) do
            assert.not_matches(dependency .. "_init", exports, 1, true)
        end
        install(wrapper, "wrap" .. SHARED_SUFFIX)
        if not platform.windows then
            local archive = assert(staticmetadata.scan_archive(wrapper .. "/wrap.a"))
            assert.same({ "wrap" }, archive.key_order)
            assert.same({ "instruments.meter" }, archive.entries.wrap.source_requirements)
            install(wrapper, "wrap.a")
        end
        local wrapped = build_dir .. "/wrapped"
        built("app", wrapped, "wrapped")
        run("wrapped", wrapped)
        local dynamic = build_dir .. "/dynamic"
        local cold = built("app", dynamic, "nominal")
        assert.truthy(cold.object_misses.units, cold.raw)
        local launcher = launcher_source(dynamic, "nominal")
        for _, name in ipairs({ "instruments.meter", "nominal", "units" }) do
            local _, count = launcher:gsub('{ "' .. name .. '",', "")
            assert.equal(1, count, name .. " must have exactly one catalog entry")
        end
        assert.not_matches('{ "model",', launcher, 1, true)
        if platform.windows then
            local image = assert(driver.windows_program_paths("nominal", nil, nil, dynamic)).provider
            local ok, exports = run_command({ "llvm-readobj", "--coff-exports", image }, workspace)
            assert.is_true(ok, exports)
            assert.matches("Name: units_abi_value", exports, 1, true)
            assert.matches("Name: units_compatibility", exports, 1, true)
            assert.matches("Name: units_init", exports, 1, true)
        end
        run("nominal", dynamic)
        local warm = built("app", dynamic, "nominal")
        assert.truthy(warm.object_hits.units, warm.raw)
        assert.truthy(warm.object_hits["instruments.meter"], warm.raw)
        assert.truthy(next(warm.link_hits), warm.raw)
        assert.same({}, warm.module_compiles)
        if not platform.windows then
            -- An archive chosen only while checking meter is not an owned
            -- archive dependency of via either.
            assert(os.remove(lib .. "/titan.so"))
            assert(os.remove(lib .. "/model.so"))
            publish(build_dir .. "/archive-only-library")
            assert(os.remove(lib .. "/via.so"))
            local static = build_dir .. "/static"
            built("app", static, "--static", "nominal")
            run("nominal", static)
        end
        collector:collect()
    end)

    it("publishes two libraries that share one application-owned installed source", function()
        local uv = require "luv"
        local sdk, lib, tool_path = isolated_sdk()
        local rocks = sdk .. "/lib/luarocks/rocks-5.5/"
        local installer = assert(loadfile("scripts/titan_install.lua"))()
        local titan_rock = rocks .. "titan/" .. driver.TITAN_LIBRARY_VERSION .. ".0-1"
        write(titan_rock .. "/installer/location.lua", string.format(
            "return { tree = %q, lua_dir = %q, luarocks = %q }\n", sdk, sdk, "unused"))
        local function stage(rock)
            local private = rocks .. rock .. "/1.0-1"
            mkdir(private .. "/dist/modules")
            write(private .. "/rock_manifest", "rock_manifest = {}\n")
            return private, private .. "/dist/modules/"
        end
        local private, modules = stage("titan-shared-sources")
        write(modules .. "shared/seed.titan", [[
local initializations = 0

function start(): integer
  initializations = initializations + 1
  return 40
end

function started(): integer
  return initializations
end
]])
        write(modules .. "shared/counter.h", "typedef struct counter_private { int unused; } counter_private;\n")
        write(modules .. "shared/counter.titan", [[
local seed = import "shared.seed"
foreign import "counter.h"

record Ticket
  serial: integer
  local storage: foreign counter_private
end

function Ticket.new(serial: integer): Ticket
  local storage = foreign counter_private.new()
  return { serial = serial, storage = storage }
end

function Ticket:code(): integer
  return self.serial + 100
end

serial = 0

function next(): Ticket
  serial = serial + 1
  return Ticket(serial)
end

function started(): integer
  return seed.started()
end

foreign function initial_serial(): int
  return 40
end

do
  serial = seed.start()
end
]])
        write(modules .. "shared/startup.titan", "const ready = true\n")
        write(modules .. "shared/unused.titan", "const never = true\n")
        assert(installer.publish_module(titan_rock, private))

        put_source("left/left/live.titan", [[
local helper = import "left.helper.titan"

type Ticket = helper.Ticket

function next(): Ticket
  return helper.next()
end
]])
        put_source("left/left/helper.titan", [[
local counter = import "shared.counter"
local startup = import "shared.startup"

type Ticket = counter.Ticket

local function next(): Ticket
  return counter.next()
end
]])
        put_source("left/left/dormant.titan", [[
local unused = import "shared.unused"
const never = unused.never
]])
        put_source("right/right.titan", [[
local counter = import "shared.counter"

function check(serial: integer, started: integer): boolean
  return counter.serial == serial and counter.started() == started and
    counter.initial_serial() == 40
end
]])
        put_source("facade/facade.titan", [[
local left = import "left.live"
local right = import "right"

function check(first: integer): boolean
  local ticket = left.next()
  return ticket.serial == first and ticket:code() == first + 100 and
    right.check(first, 1) and left.next().serial == first + 1 and right.check(first + 1, 1)
end
]])
        put_source("app/demo.titan", [[
local left = import "left.live"
local right = import "right"

function main(args: {string}): integer
  local first = left.next()
  if first.serial ~= 41 or first:code() ~= 141 then return 1 end
  if left.Ticket(first.serial):code() ~= 141 then return 2 end
  if not right.check(first.serial, 1) then return 3 end
  if left.next().serial ~= first.serial + 1 then return 4 end
  if not right.check(first.serial + 1, 1) then return 5 end
  return 0
end
]])
        put_source("app/through_facade.titan", [[
local facade = import "facade"

function main(args: {string}): integer
  local first = 41
  if args[1] then first = 42 end
  if args[1] == "own" then first = 43 end
  if args[1] == "bundle" then first = 44 end
  if not facade.check(first) then return 1 end
  return 0
end
]])
        put_source("app/shared_test.titan", [[
local test = import "test"
local facade = import "facade"

function test_shared_counter(context: test.Context)
  test.assert(facade.check(41))
end
]])

        local collector = require("spec.support.luacov_children").new(
            REPOSITORY, REPOSITORY, workspace .. "/child-coverage")
        local init_code = collector:init_code()
        local function compile(tree, output, ...)
            local args = { "--tree", source_dir .. "/" .. tree, "-o", output, "-v", "-j", "2", ... }
            if select(1, ...) ~= "--print-ast" then table.insert(args, 1, "--incremental") end
            local argv, env = compiler_argv({
                args = args,
                env = { TITAN_ROOT = sdk, PATH = tool_path }, init_code = init_code,
            })
            env.TITAN_PATH_0_6 = lib
            return run_command(argv, workspace, env)
        end
        local function built(...)
            local ok, output = compile(...)
            assert.is_true(ok, output)
            return parse_verbose_output(output)
        end
        local function compile_count(step, name)
            local count = 0
            for _, command in ipairs(step.module_compiles) do
                if command:find("/shared/" .. name .. ".c", 1, true) then
                    count = count + 1
                end
            end
            return count
        end
        local function symbols(image, exports)
            local argv
            if platform.windows then
                argv = { "llvm-readobj", "--coff-exports", image }
            elseif exports then
                argv = { "nm", "-g", image }
            else
                argv = { "nm", image }
            end
            local ok, output = run_command(argv, workspace)
            assert.is_true(ok, output)
            return output
        end
        local requirements = {
            ["left.dormant"] = { "shared.unused" },
            ["left.helper"] = { "shared.counter", "shared.startup" },
            ["left.live"] = { "shared.counter", "shared.startup" },
            right = { "shared.counter" },
            facade = { "shared.counter", "shared.startup" },
        }
        local function publish(rock, expected, ...)
            local output = build_dir .. "/" .. rock
            local step = built(rock, output, ...)
            assert.is_false(exists(output .. "/shared"), step.raw)
            local installed, dist = stage("titan-" .. rock)
            local image = symbols(output .. "/" .. rock .. SHARED_SUFFIX, true)
            local members = {}
            local pattern = platform.windows and "Name: ([%w_]+)_abi\n"
                or " [Tt] _?([%w_]+)_abi\n"
            for member in image:gmatch(pattern) do members[member] = true end
            local expected_exports = {}
            for _, member in ipairs(expected) do
                expected_exports[driver.mangle_module_name(member)] = true
            end
            assert.same(expected_exports, members)
            assert(uv.fs_copyfile(output .. "/" .. rock .. SHARED_SUFFIX, dist .. rock .. SHARED_SUFFIX))
            if not platform.windows then
                local archive = assert(staticmetadata.scan_archive(output .. "/" .. rock .. ".a"))
                assert.same(expected, archive.key_order)
                for _, name in ipairs(expected) do
                    assert.same(requirements[name], archive.entries[name].source_requirements)
                end
                assert(uv.fs_copyfile(output .. "/" .. rock .. ".a", dist .. rock .. ".a"))
            end
            assert(installer.publish_module(titan_rock, installed))
            return step
        end

        local left_out = build_dir .. "/left"
        built("left", left_out, "-c", "left.live", "left.dormant")
        assert.is_false(exists(left_out .. "/shared/counter.o"))
        publish("left", { "left.dormant", "left.helper", "left.live" }, "left.live", "left.dormant")
        publish("right", { "right" }, "right")
        assert(os.remove(lib .. "/shared/unused.titan"))
        publish("facade", { "facade" }, "facade")

        local function program_path(output, name)
            return platform.windows and
                assert(driver.windows_program_paths(name, nil, nil, output)).executable or
                output .. "/" .. name
        end
        local function run_program(output, name, ...)
            local executable = program_path(output, name)
            local search = platform.windows and
                output .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION .. ";" .. lib or lib
            return run_command({ executable, ... }, workspace, {
                TITAN_ROOT = sdk, TITAN_PATH_0_6 = search, PATH = tool_path,
            })
        end
        local function run(output, name, ...)
            local ok, result = run_program(output, name, ...)
            assert.is_true(ok, result)
            return result
        end
        local function assert_compiled_once(output, name, step)
            for _, dependency in ipairs({ "counter", "seed", "startup" }) do
                assert.equal(1, compile_count(step, dependency), step.raw)
                assert.is_true(exists(output .. "/shared/" .. dependency .. ".o"))
            end
            assert.is_false(exists(output .. "/shared/unused.o"))
            local image = platform.windows and
                assert(driver.windows_program_paths(name, nil, nil, output)).provider or
                program_path(output, name)
            local exports = symbols(image, false)
            local _, count = exports:gsub("shared_counter_init\n", "")
            assert.equal(1, count, exports)
        end

        local dynamic = build_dir .. "/dynamic"
        local step = built("app", dynamic, "demo")
        assert_compiled_once(dynamic, "demo", step)
        run(dynamic, "demo")
        built("app", build_dir .. "/print-app", "--print-ast", "demo")
        local through = build_dir .. "/through"
        step = built("app", through, "-c", "through_facade")
        for _, dependency in ipairs({ "counter", "seed", "startup" }) do
            assert.equal(1, compile_count(step, dependency), step.raw)
        end
        step = built("app", through, "through_facade")
        assert.same({}, step.module_compiles)
        run(through, "through_facade")
        step = built("app", through, "through_facade")
        assert.truthy(next(step.link_hits), step.raw)

        local tests = build_dir .. "/test-distribution"
        built("app", tests, "--test", "shared_test")
        assert.matches("[  PASSED  ] 1 test.", run(tests, "shared_test"), 1, true)
        local static = build_dir .. "/static"
        if not platform.windows then
            step = built("app", static, "--static", "through_facade")
            assert_compiled_once(static, "through_facade", step)

            put_source("other/other/live.titan", [[
local counter = import "shared.counter"
function next(): integer return counter.serial end
]])
            put_source("other/other/dormant.titan", "const unused = true\n")
            put_source("other/shared/counter.titan", "const serial = 0\n")
            local competing = build_dir .. "/competing"
            built("other", competing, "other.live", "other.dormant")
            assert(uv.fs_copyfile(competing .. "/other.a", lib .. "/other.a"))
            put_source("competing-app/shared/counter.titan", "const serial = 0\n")
            put_source("competing-app/competing.titan", [[
local other = import "other.live"
local own = import "shared.counter.titan"
local facade = import "facade"

function main(args: {string}): integer
  if not facade.check(other.next() + own.serial) then return 1 end
  return 0
end
]])
            local ok, diagnostic = compile("competing-app", build_dir .. "/conflict", "--static", "competing")
            assert.is_false(ok, diagnostic)
            assert.matches("shared.counter", diagnostic, 1, true)
            assert.matches("other.a", diagnostic, 1, true)
        end

        write(lib .. "/shared/seed.titan", (read(lib .. "/shared/seed.titan"):gsub("return 40", "return 41")))
        step = publish("facade", { "facade" }, "facade")
        assert.truthy(step.object_hits.facade, step.raw)
        assert.truthy(next(step.link_hits), step.raw)
        step = built("app", through, "through_facade")
        assert.equal(1, compile_count(step, "seed"), step.raw)
        assert.truthy(next(step.link_misses), step.raw)
        run(through, "through_facade", "changed")
        local original = read(lib .. "/shared/counter.titan")
        write(lib .. "/shared/counter.titan",
            (original:gsub("function next%(%)", "function next(delta: integer)")))
        local function rejects_incompatible(output, static)
            if static then built("app", output, "--static", "through_facade")
            else built("app", output, "through_facade") end
            local ok, diagnostic = run_program(output, "through_facade")
            assert.is_false(ok, diagnostic)
            assert.matches("binary compatibility mismatch", diagnostic, 1, true)
            assert.matches("shared.counter", diagnostic, 1, true)
        end
        rejects_incompatible(build_dir .. "/incompatible-dynamic")
        if not platform.windows then
            rejects_incompatible(build_dir .. "/incompatible-static", true)
        end
        write(lib .. "/shared/counter.titan", "const extra = 0\n" .. original)
        built("app", through, "through_facade")
        run(through, "through_facade", "changed")

        local helper = source_dir .. "/left/left/helper.titan"
        write(helper, (read(helper):gsub('local startup = import "shared.startup"\n', "")))
        write(lib .. "/shared/unused.titan", "const never = true\n")
        requirements["left.helper"], requirements["left.live"] = { "shared.counter" }, { "shared.counter" }
        publish("left", { "left.dormant", "left.helper", "left.live" }, "left.live", "left.dormant")
        requirements.facade = { "shared.counter" }
        step = publish("facade", { "facade" }, "facade")
        assert.matches("source-requirements", step.object_misses.facade, 1, true)
        local facade = build_dir .. "/facade/facade.o"
        assert.same(requirements.facade, assert(objectmetadata.read(read(facade), facade))
            .object_metadata.source_requirements)
        assert(os.remove(lib .. "/shared/startup.titan"))
        built("app", through, "through_facade")
        run(through, "through_facade", "changed")

        write(lib .. "/shared/counter.titan", original:gsub(
            'local seed = import "shared.seed"\n', '%0local facade = import "facade"\n'))
        local cyclic, cycle = compile("app", through, "through_facade")
        assert.is_false(cyclic, cycle)
        assert.matches("cyclic source requirement: shared.counter -> facade -> shared.counter",
            cycle, 1, true)
        write(lib .. "/shared/counter.titan", original)
        run(through, "through_facade", "changed")
        assert(os.remove(lib .. "/shared/counter.titan"))
        local ok, diagnostic = compile("app", through, "through_facade")
        assert.is_false(ok, diagnostic)
        assert.matches("shared.counter", diagnostic, 1, true)
        assert.matches("facade", diagnostic, 1, true)
        run(through, "through_facade", "changed")

        local replacement = build_dir .. "/replacement"
        local seed_output = build_dir .. "/replacement-seed"
        put_source("replacement-seed/shared/seed.titan", read(lib .. "/shared/seed.titan"))
        built("replacement-seed", seed_output, "shared.seed")
        local function copy_provider(output, stem, suffix)
            assert(uv.fs_copyfile(output .. "/" .. stem .. suffix, lib .. "/" .. stem .. suffix))
        end
        copy_provider(seed_output, "shared/seed", SHARED_SUFFIX)
        if not platform.windows then copy_provider(seed_output, "shared/seed", ".a") end
        local function replacement_source(extra)
            return (original:gsub("serial = seed.start%(%)", "serial = seed.start() + " .. extra))
        end
        put_source("replacement/shared/counter.h", read(lib .. "/shared/counter.h"))
        put_source("replacement/shared/counter.titan", replacement_source(1))
        built("replacement", replacement, "shared.counter")
        copy_provider(replacement, "shared/counter", SHARED_SUFFIX)
        run(dynamic, "demo") -- the old app still provides A even when a binary exists
        run(through, "through_facade", "changed")

        local elected = build_dir .. "/elected"
        -- No build-time traversal of the replacement DSO's private dependency.
        local seed_image = "/shared/seed" .. SHARED_SUFFIX
        assert(os.remove(lib .. seed_image))
        assert(os.remove(lib .. "/shared/seed.titan"))
        step = built("app", elected, "through_facade")
        assert.equal(0, compile_count(step, "counter"), step.raw)
        assert.is_false(exists(elected .. "/shared/counter.o"))
        copy_provider(seed_output, "shared/seed", SHARED_SUFFIX)
        run(elected, "through_facade", "own")
        local bare = workspace .. "/bare-requirement.lua"
        write(bare, [[
require "titan"
if ... == "initialized" then
    require "shared.counter"
    assert(require("left.live").next().serial == 43)
else
    local ok, err = pcall(require, "left.live")
    assert(not ok and err:find("Titan module 'shared.counter' is not supplied by the application", 1, true), err)
end
]])
        for _, mode in ipairs({ "uninitialized", "initialized" }) do
            local argv, env = compiler_argv({
                frontend = bare, args = { mode }, env = { TITAN_ROOT = sdk, PATH = tool_path },
            })
            env.TITAN_PATH_0_6 = lib
            local ran, output = run_command(argv, workspace, env)
            assert.is_true(ran, output)
        end
        step = built("app", elected, "through_facade")
        assert.truthy(next(step.link_hits), step.raw)
        run(elected, "through_facade", "own")
        built("app", build_dir .. "/print-binary", "--print-ast", "demo")

        if not platform.windows then
            local strict = build_dir .. "/strict-replacement"
            ok, diagnostic = compile("app", strict, "--static", "through_facade")
            assert.is_false(ok, diagnostic)
            assert.matches("shared.counter", diagnostic, 1, true)
            assert.matches("shared providers are not used", diagnostic, 1, true)
            copy_provider(replacement, "shared/counter", ".a")
            built("app", strict, "--static", "through_facade")
            assert.is_false(exists(strict .. "/shared/counter.o"))
            run(strict, "through_facade", "own")
            assert(os.remove(lib .. "/shared/counter.a"))
        end

        local facade_source = source_dir .. "/facade/facade.titan"
        write(facade_source, 'local counter = import "shared.counter"\n' ..
            read(facade_source):gsub("right.check%(first, 1%)", "counter.serial == first and right.check(first, 1)"))
        publish("facade", { "facade" }, "facade")
        put_source("app/replacement_test.titan", [[
local test = import "test"
local facade = import "facade"

function test_compiled_counter(context: test.Context)
  test.assert(facade.check(43))
end
]])
        local compiled_tests = build_dir .. "/test-compiled"
        built("app", compiled_tests, "--test", "replacement_test")
        assert.matches("[  PASSED  ] 1 test.", run(compiled_tests, "replacement_test"), 1, true)
        write(lib .. "/shared/counter.titan", replacement_source(0))
        built("app", build_dir .. "/prefer-source", "--source-first", "through_facade")
        run(build_dir .. "/prefer-source", "through_facade", "changed")
        assert(os.remove(lib .. "/shared/counter.titan"))

        -- Keep B fixed across the two compiled selections. A's logical name
        -- does not change, but the same output must publish a different row.
        built("app", elected, "through_facade")
        assert(os.remove(lib .. "/shared/counter" .. SHARED_SUFFIX))
        local bundle = build_dir .. "/replacement-bundle"
        put_source("replacement/shared/counter.titan", replacement_source(2))
        put_source("replacement/shared/companion.titan", "const marker = true\n")
        built("replacement", bundle, "shared.counter", "shared.companion")
        copy_provider(bundle, "shared", SHARED_SUFFIX)
        if not platform.windows then copy_provider(bundle, "shared", ".a") end
        assert.is_false(exists(lib .. "/shared/counter" .. SHARED_SUFFIX))
        step = built("app", elected, "through_facade")
        assert.truthy(next(step.link_misses), step.raw)
        assert.equal(0, compile_count(step, "counter"), step.raw)
        run(elected, "through_facade", "bundle")
        step = built("app", elected, "through_facade")
        assert.truthy(next(step.link_hits), step.raw)
        if not platform.windows then
            local strict = build_dir .. "/strict-bundle"
            built("app", strict, "--static", "through_facade")
            run(strict, "through_facade", "bundle")
            assert(os.remove(lib .. "/shared.a"))
        end
        assert(os.remove(lib .. "/shared" .. SHARED_SUFFIX))

        local claimed = lib .. "/shared/counter" .. SHARED_SUFFIX
        write(claimed, "invalid native image\n")
        ok, diagnostic = compile("app", elected, "through_facade")
        assert.is_false(ok, diagnostic)
        assert.matches("shared/counter" .. SHARED_SUFFIX, diagnostic:gsub("\\", "/"), 1, true)
        assert(os.remove(claimed))
        put_source("replacement/shared/counter.titan",
            (replacement_source(1):gsub("function next%(%)", "function next(delta: integer)")))
        built("replacement", replacement, "shared.counter")
        copy_provider(replacement, "shared/counter", SHARED_SUFFIX)
        rejects_incompatible(build_dir .. "/incompatible-replacement")

        if not platform.windows then
            local deployment = workspace .. "/deployment"
            mkdir(deployment)
            local function deployed(executable)
                local program = deployment .. "/check"
                assert(os.rename(executable, program))
                local ran, output = run_command({ "env", "-i", "PATH=/usr/bin:/bin",
                    "TITANC=" .. deployment .. "/no-compiler", "TITAN_ROOT=" .. deployment,
                    "TITAN_PATH_0_6=" .. deployment, program }, deployment)
                assert.is_true(ran, output)
                assert(os.remove(program))
            end
            deployed(program_path(static, "through_facade"))
            for _, name in ipairs({ "left", "right" }) do
                assert(uv.fs_copyfile(lib .. "/" .. name .. ".so", deployment .. "/" .. name .. ".so"))
            end
            deployed(program_path(dynamic, "demo"))
        end
        assert.is_false(exists(lib .. "/shared/counter.o"))
        assert.is_false(exists(lib .. "/shared/seed.c"))
        assert.is_false(exists(lib .. "/.titan-build.lock"))
        collector:collect()
    end)

    it("builds and incrementally updates application and test executables across closure, header, flag, profile, link, discovery, and recovery scenarios", function()
        populate_baseline_tree()
        local test_names = {
            "fixture.app_test.test_initial",
            "fixture.other_test.test_unrelated",
        }

        -- Install one stable CC wrapper for the entire progression so failed-link
        -- injection later does not alter toolchain identity mid-scenario.
        local fail_link_marker = workspace .. "/fail-next-server-link"
        local real_cc = assert(cdriver.split_shell_words(driver.CC))
        local wrapper_cc_command
        if platform.windows then
            local cc_wrapper = workspace .. "/cc-wrapper.lua"
            local quoted_cc = {}
            for index, word in ipairs(real_cc) do
                quoted_cc[index] = string.format("%q", word)
            end
            write(cc_wrapper, string.format([=[
package.path = %q .. package.path
package.cpath = %q .. package.cpath
local command = { %s }
local is_compile_or_preprocess = false
local output_path
for index, value in ipairs(arg) do
    if value == "-c" or value == "-E" or value == "-###"
        or value:find("^-print-", 1)
        or value:find("--version", 1, true) then
        is_compile_or_preprocess = true
    end
    if arg[index - 1] == "-o" then
        output_path = value
    else
        local rsp_pos = value:find(".link.rsp", 1, true)
        if value:sub(1, 1) == "@" and rsp_pos then
            output_path = value:sub(2, rsp_pos - 1)
        end
    end
    command[#command + 1] = value
end
local marker = %q
local marker_file = io.open(marker, "rb")
if marker_file then
    marker_file:close()
    local normalized_out = output_path and output_path:gsub("\\", "/"):lower() or ""
    local suffix = "/titan-language-server.exe"
    if not is_compile_or_preprocess
        and normalized_out:sub(-#suffix) == suffix then
        os.remove(marker)
        local out = io.open(output_path, "wb")
        if out then out:write(""); out:close() end
        io.stderr:write("injected linker failure after creating empty output\n")
        io.stderr:flush()
        os.exit(91)
    end
end
local ok, _, code = require("titan-compiler.process").run(command)
os.exit(ok and 0 or code or 1)
]=], REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
                REPOSITORY .. "/titan-runtime/bootstrap/?" .. SHARED_SUFFIX .. ";",
                table.concat(quoted_cc, ", "), fail_link_marker))
            wrapper_cc_command = shell_command({ LUA, cc_wrapper })
        else
            local cc_wrapper = workspace .. "/cc-wrapper.sh"
            write(cc_wrapper, table.concat({
                "#!/bin/sh",
                "if [ -f " .. assert(cdriver.shell_quote(fail_link_marker)) .. " ]; then",
                "    is_comp=no",
                "    out=",
                "    prev=",
                "    for a do",
                "        case \"$a\" in",
                "            -c|-E|-###|-print-*|*--version*) is_comp=yes ;;",
                "        esac",
                "        if [ \"$prev\" = -o ]; then out=$a; fi",
                "        prev=$a",
                "    done",
                "    case \"$out\" in",
                "        */titan-language-server|titan-language-server)",
                "            if [ \"$is_comp\" = no ]; then",
                "                rm -f " .. assert(cdriver.shell_quote(fail_link_marker)),
                "                : > \"$out\"",
                "                printf 'injected linker failure after creating empty output\\n' >&2",
                "                exit 91",
                "            fi",
                "            ;;",
                "    esac",
                "fi",
                "exec " .. shell_command(real_cc) .. " \"$@\"",
                "",
            }, "\n"))
            assert.is_true((run_command({ "chmod", "u+x", cc_wrapper })))
            wrapper_cc_command = shell_command({ cc_wrapper })
        end
        local function build_scenario(kind, opts)
            opts = opts or {}
            local env = { CC = wrapper_cc_command }
            for k, v in pairs(opts.env or {}) do env[k] = v end
            local merged = {}
            for k, v in pairs(opts) do merged[k] = v end
            merged.env = env
            return build_target(kind, merged)
        end

        -- Reject invalid --exe combinations before mutating outputs.
        local compile_only_exe = invoke_titanc({
            args = { "-c", "--tree", source_dir, "--output", build_dir,
                "--exe", app_exe, "titan_language_server" },
        })
        assert.is_false(compile_only_exe.ok)
        assert.matches("--exe", compile_only_exe.raw, 1, true)

        local library_only_exe = invoke_titanc({
            args = { "--tree", source_dir, "--output", workspace .. "/rejected-library-build",
                "--exe", app_exe, "fixture.unrelated" },
        })
        assert.is_false(library_only_exe.ok)
        assert.matches("--exe", library_only_exe.raw, 1, true)

        -- Initial application build: compiles closure and links into external --exe path.
        local initial_app = build_scenario("app")
        assert_module_rebuilt(initial_app, "fixture.leaf", "fixture/leaf.o", "no-object")
        assert_module_rebuilt(initial_app, "fixture.app", "fixture/app/app.o", "no-object")
        assert_module_rebuilt(initial_app, "fixture.unrelated", "fixture/unrelated.o", "no-object")
        assert_module_rebuilt(initial_app, "titan_language_server", "titan_language_server.o", "no-object")
        assert_link_performed(initial_app, "server-executable", app_exe)
        assert.is_true(exists(app_exe))
        assert.is_false(exists(build_dir .. "/titan_language_server"))

        -- Initial test build sharing the same output directory: reuses production objects
        -- (fixture.leaf, fixture.app, fixture.unrelated) and compiles only test modules.
        local initial_tests = build_scenario("test")
        assert_module_reused(initial_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(initial_tests, "fixture.app", "fixture/app/app.o")
        assert_module_reused(initial_tests, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_rebuilt(initial_tests, "fixture.app_test", "fixture/app_test.o", "no-object")
        assert_module_rebuilt(initial_tests, "fixture.other_test", "fixture/other_test.o", "no-object")
        assert_module_rebuilt(initial_tests, "server.tests", "server/tests.o", "no-object")
        assert_link_performed(initial_tests, "test-executable", test_exe)
        assert.is_nil(initial_tests.raw:find("__test_support", 1, true), initial_tests.raw)
        for key in pairs(initial_tests.after) do
            assert.is_nil(key:find("__test_support", 1, true), key)
        end

        verify_runtime(5, test_names)

        -- Hostile runtime environment variables must not hijack standalone execution.
        local hostile_env = {
            TITAN_PATH = workspace .. "/unrelated-fallback-sdk",
            TITAN_ROOT = workspace .. "/unrelated-compiler-sdk",
            LUA_PATH_5_5 = workspace .. "/unrelated-lua/?.lua",
            LUA_CPATH_5_5 = workspace .. "/unrelated-c/?" .. SHARED_SUFFIX,
        }
        if not platform.windows then
            hostile_env.TITAN_PATH_0_6 = workspace .. "/unrelated-versioned-sdk"
        else
            hostile_env.TITAN_PATH_0_6 = build_dir .. "/lib/titan/0.6;"
                .. prefix .. "/lib/titan/0.6;"
                .. workspace .. "/unrelated-versioned-sdk;;"
        end
        verify_runtime(5, test_names, hostile_env)

        -- Warm no-op builds skip module compilation, runner/entrypoint generation, and linking.
        local noop_app = build_scenario("app")
        for _, item in ipairs({
            { "fixture.leaf", "fixture/leaf.o" },
            { "fixture.app", "fixture/app/app.o" },
            { "fixture.unrelated", "fixture/unrelated.o" },
            { "titan_language_server", "titan_language_server.o" },
        }) do
            assert_module_reused(noop_app, item[1], item[2])
        end
        assert_link_skipped(noop_app, "server-executable", app_exe)

        local noop_tests = build_scenario("test")
        for _, item in ipairs({
            { "fixture.leaf", "fixture/leaf.o" },
            { "fixture.app", "fixture/app/app.o" },
            { "fixture.unrelated", "fixture/unrelated.o" },
            { "fixture.app_test", "fixture/app_test.o" },
            { "fixture.other_test", "fixture/other_test.o" },
            { "server.tests", "server/tests.o" },
        }) do
            assert_module_reused(noop_tests, item[1], item[2])
        end
        assert_link_skipped(noop_tests, "test-executable", test_exe)

        -- Relative --output and --exe paths canonicalize to the same certificates.
        local rel_app = build_scenario("app", {
            cwd = workspace,
            output = "build",
            exe = "deliverables/bin/titan-language-server",
        })
        assert_link_skipped(rel_app, "server-executable", app_exe)

        local rel_tests = build_scenario("test", {
            cwd = workspace,
            output = "build",
            exe = "build/tests/server/tests",
        })
        assert_link_skipped(rel_tests, "test-executable", test_exe)

        -- A malformed test or unimported source outside the application closure is ignored.
        put_source("fixture/never_imported.titan", "function broken_unimported(\n")
        put_source("fixture/app_test.titan", "function unfinished(\n")
        local app_ignores_broken_test = build_scenario("app")
        assert_link_skipped(app_ignores_broken_test, "server-executable", app_exe)

        local broken_test_build = build_scenario("test", { expect_failure = true })
        assert.equal(0, #broken_test_build.link_commands)

        put_source("fixture/app_test.titan", app_tests_source("test_initial"))
        local restored_tests = build_scenario("test")
        assert_link_skipped(restored_tests, "test-executable", test_exe)
        verify_runtime(5, test_names)

        -- Tightened body-edit oracle: a leaf implementation-only edit recompiles
        -- fixture/leaf.o only and must NOT rewrite consumer fixture/app/app.o.
        put_source("fixture/leaf.titan", leaf_module_source(2))
        local leaf_body_app = build_scenario("app")
        assert_module_rebuilt(leaf_body_app, "fixture.leaf", "fixture/leaf.o", "source-content")
        assert_module_reused(leaf_body_app, "fixture.app", "fixture/app/app.o")
        assert_module_reused(leaf_body_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(leaf_body_app, "titan_language_server", "titan_language_server.o")
        assert.equal(1, #leaf_body_app.module_compiles, leaf_body_app.raw)
        assert_link_performed(leaf_body_app, "server-executable", app_exe)

        local leaf_body_tests = build_scenario("test")
        assert_module_reused(leaf_body_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(leaf_body_tests, "fixture.app", "fixture/app/app.o")
        assert_module_reused(leaf_body_tests, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(leaf_body_tests, "fixture.app_test", "fixture/app_test.o")
        assert_module_reused(leaf_body_tests, "fixture.other_test", "fixture/other_test.o")
        assert_module_reused(leaf_body_tests, "server.tests", "server/tests.o")
        assert.equal(0, #leaf_body_tests.module_compiles, leaf_body_tests.raw)
        assert_link_performed(leaf_body_tests, "test-executable", test_exe)
        verify_runtime(6, test_names)

        -- Contrast with a public-interface change on fixture.leaf: direct importers
        -- (fixture.app, fixture.app_test) recompile, while transitive consumer
        -- titan_language_server (whose direct import fixture.app kept its public
        -- interface) and fixture.unrelated are still reused.
        put_source("fixture/leaf.titan",
            leaf_module_source(2, "function exported_bonus(): integer return 10 end\n"))
        local leaf_api_app = build_scenario("app")
        assert_module_rebuilt(leaf_api_app, "fixture.leaf", "fixture/leaf.o", "source-content")
        assert_module_rebuilt(leaf_api_app, "fixture.app", "fixture/app/app.o", "import-interface")
        assert_module_reused(leaf_api_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(leaf_api_app, "titan_language_server", "titan_language_server.o")
        assert_link_performed(leaf_api_app, "server-executable", app_exe)

        local leaf_api_tests = build_scenario("test")
        assert_module_reused(leaf_api_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(leaf_api_tests, "fixture.app", "fixture/app/app.o")
        assert_module_rebuilt(leaf_api_tests, "fixture.app_test", "fixture/app_test.o", "import-interface")
        assert_module_reused(leaf_api_tests, "fixture.other_test", "fixture/other_test.o")
        assert_module_reused(leaf_api_tests, "server.tests", "server/tests.o")
        verify_runtime(6, test_names)

        -- Changed import and source closure only.
        put_source("fixture/alternate.titan", "function value(): integer return 12 end\n")
        put_source("fixture/app/app.titan", app_module_source("alternate"))
        local import_change_app = build_scenario("app")
        assert_module_rebuilt(import_change_app, "fixture.alternate", "fixture/alternate.o", "no-object")
        assert_module_rebuilt(import_change_app, "fixture.app", "fixture/app/app.o", "source-content")
        assert_module_reused(import_change_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(import_change_app, "titan_language_server", "titan_language_server.o")
        assert_link_performed(import_change_app, "server-executable", app_exe)

        local import_change_tests = build_scenario("test")
        assert_module_reused(import_change_tests, "fixture.alternate", "fixture/alternate.o")
        assert_module_reused(import_change_tests, "fixture.app", "fixture/app/app.o")
        assert_module_reused(import_change_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(import_change_tests, "fixture.app_test", "fixture/app_test.o")
        assert_module_reused(import_change_tests, "fixture.other_test", "fixture/other_test.o")
        assert_module_reused(import_change_tests, "server.tests", "server/tests.o")
        verify_runtime(14, test_names)

        -- Folder-module contributor removal and module removal from the closure.
        put_source("fixture/app/app.titan", app_module_source("leaf", '#strings.upper("ok")'))
        assert(os.remove(source_dir .. "/fixture/app/extra.titan"))
        assert(os.remove(source_dir .. "/fixture/alternate.titan"))
        local folder_member_removed = build_scenario("app")
        assert_module_rebuilt(folder_member_removed, "fixture.app", "fixture/app/app.o", "source-set")
        assert_module_reused(folder_member_removed, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(folder_member_removed, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(folder_member_removed, "titan_language_server", "titan_language_server.o")
        build_scenario("test")
        verify_runtime(6, test_names)

        -- Adding and then removing a contributor without modifying app.titan itself
        -- must also miss via source-set membership certification.
        put_source("fixture/app/side_member.titan",
            "local function side_constant(): integer return 0 end\n")
        local contributor_added = build_scenario("app")
        assert_module_rebuilt(contributor_added, "fixture.app", "fixture/app/app.o", "source-set")
        assert(os.remove(source_dir .. "/fixture/app/side_member.titan"))
        local contributor_removed_only = build_scenario("app")
        assert_module_rebuilt(contributor_removed_only, "fixture.app", "fixture/app/app.o", "source-set")

        -- Folder-to-flat module layout transition.
        put_source("fixture/app.titan", app_module_source("leaf", '#strings.upper("ok")'))
        remove(source_dir .. "/fixture/app")
        local flat_transition_app = build_scenario("app")
        assert_module_rebuilt(flat_transition_app, "fixture.app", "fixture/app.o", "no-object")
        assert_module_reused(flat_transition_app, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(flat_transition_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(flat_transition_app, "titan_language_server", "titan_language_server.o")
        assert.is_true(exists(build_dir .. "/fixture/app.o"))
        build_scenario("test")
        verify_runtime(6, test_names)

        -- Transitive C header change (detail.h included by value.h) with preserved mtime:
        -- recompiles fixture.leaf (and explicit .titan importer fixture.app_test),
        -- but NOT ordinary public importer fixture.app or fixture.unrelated!
        local detail_path = source_dir .. "/fixture/detail.h"
        local old_detail_mtime = assert(lfs.attributes(detail_path, "modification"))
        put_source("fixture/detail.h", detail_header_source(8))
        assert(lfs.touch(detail_path, old_detail_mtime, old_detail_mtime))

        local header_app = build_scenario("app")
        assert_module_rebuilt(header_app, "fixture.leaf", "fixture/leaf.o", "c-input")
        assert_module_reused(header_app, "fixture.app", "fixture/app.o")
        assert_module_reused(header_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(header_app, "titan_language_server", "titan_language_server.o")
        assert.equal(1, #header_app.module_compiles, header_app.raw)
        assert_link_performed(header_app, "server-executable", app_exe)

        local header_tests = build_scenario("test")
        assert_module_reused(header_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(header_tests, "fixture.app", "fixture/app.o")
        assert_module_reused(header_tests, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_rebuilt(header_tests, "fixture.app_test", "fixture/app_test.o", "c-input")
        assert_module_reused(header_tests, "fixture.other_test", "fixture/other_test.o")
        assert_module_reused(header_tests, "server.tests", "server/tests.o")
        verify_runtime(11, test_names)

        -- CLI compile define (-D) and include (-I) / --cflag changes.
        local extra_inc = workspace .. "/extra-include"
        mkdir(extra_inc)
        local define_args = { "-DINCREMENTAL_BIAS=4" }
        local define_app = build_scenario("app", { extra_args = define_args })
        assert_module_rebuilt(define_app, "fixture.leaf", "fixture/leaf.o", "configuration options")
        assert_module_rebuilt(define_app, "fixture.unrelated", "fixture/unrelated.o", "configuration options")
        build_scenario("test", { extra_args = define_args })
        verify_runtime(15, test_names)

        local define_noop = build_scenario("app", { extra_args = define_args })
        assert_link_skipped(define_noop, "server-executable", app_exe)

        local cflag_args = { "-DINCREMENTAL_BIAS=4", "-I" .. extra_inc, "--cflag=-DINCREMENTAL_EXTRA_BIAS=2" }
        local cflag_app = build_scenario("app", { extra_args = cflag_args })
        assert_module_rebuilt(cflag_app, "fixture.leaf", "fixture/leaf.o", "configuration options")
        assert_module_rebuilt(cflag_app, "fixture.unrelated", "fixture/unrelated.o", "configuration options")
        build_scenario("test", { extra_args = cflag_args })
        verify_runtime(17, test_names)
        assert_link_skipped(build_scenario("app", { extra_args = cflag_args }), "server-executable", app_exe)

        -- Restore -DINCREMENTAL_BIAS=4 only.
        build_scenario("app", { extra_args = define_args })
        build_scenario("test", { extra_args = define_args })
        verify_runtime(15, test_names)
        assert_link_skipped(build_scenario("app", { extra_args = define_args }), "server-executable", app_exe)

        -- Build profile change (validation -> production -> validation).
        local prod_env = { TITAN_BUILD_PROFILE = "production" }
        local prod_app = build_scenario("app", { extra_args = define_args, env = prod_env })
        assert_module_rebuilt(prod_app, "fixture.leaf", "fixture/leaf.o", "configuration")
        assert_module_rebuilt(prod_app, "fixture.unrelated", "fixture/unrelated.o", "configuration")
        build_scenario("test", { extra_args = define_args, env = prod_env })
        verify_runtime(15, test_names)
        assert_link_skipped(build_scenario("app", { extra_args = define_args, env = prod_env }),
            "server-executable", app_exe)

        local restored_val_app = build_scenario("app", { extra_args = define_args })
        assert_module_rebuilt(restored_val_app, "fixture.unrelated", "fixture/unrelated.o", "configuration")
        build_scenario("test", { extra_args = define_args })
        verify_runtime(15, test_names)
        assert_link_skipped(build_scenario("app", { extra_args = define_args }), "server-executable", app_exe)

        -- Pure link-only changes (-L, -l, --ldflag, -X) relink without recompiling any module object.
        local lib_dir = workspace .. "/native-lib-search"
        mkdir(lib_dir)
        local payload_c = workspace .. "/extra_payload.c"
        local payload_o = workspace .. "/extra_payload.o"
        write(payload_c, "int scenario_extra_payload(void) { return 1; }\n")
        local cc_argv = assert(cdriver.split_shell_words(driver.CC))
        for _, flag in ipairs({ "-c", payload_c, "-o", payload_o }) do
            cc_argv[#cc_argv + 1] = flag
        end
        assert.is_true((run_command(cc_argv)))

        local link_only_args = {
            "-DINCREMENTAL_BIAS=4",
            "-X", payload_o,
            "-L", lib_dir,
            "-l", "m",
            "--ldflag=-L" .. lib_dir,
        }
        local link_only_app = build_scenario("app", { extra_args = link_only_args })
        assert_module_reused(link_only_app, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(link_only_app, "fixture.app", "fixture/app.o")
        assert_module_reused(link_only_app, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(link_only_app, "titan_language_server", "titan_language_server.o")
        assert.equal(0, #link_only_app.module_compiles, link_only_app.raw)
        assert_link_performed(link_only_app, "server-executable", app_exe)

        local link_only_noop = build_scenario("app", { extra_args = link_only_args })
        assert_link_skipped(link_only_noop, "server-executable", app_exe)

        -- Changing -X payload bytes with preserved mtime relinks without recompiling module objects.
        local old_payload_mtime = assert(lfs.attributes(payload_o, "modification"))
        write(payload_c, "int scenario_extra_payload(void) { return 2; }\n")
        assert.is_true((run_command(cc_argv)))
        assert(lfs.touch(payload_o, old_payload_mtime, old_payload_mtime))

        local payload_relink = build_scenario("app", { extra_args = link_only_args })
        assert_module_reused(payload_relink, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(payload_relink, "fixture.app", "fixture/app.o")
        assert_module_reused(payload_relink, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(payload_relink, "titan_language_server", "titan_language_server.o")
        assert.equal(0, #payload_relink.module_compiles, payload_relink.raw)
        assert_link_performed(payload_relink, "server-executable", app_exe)

        -- App-owned --c-source native helper compiles once, preprocesses on warm hit,
        -- and recompiles only the native node when edited.
        local c_helper = workspace .. "/app_helper.c"
        write(c_helper, "int scenario_c_helper(void) { return 7; }\n")
        local c_source_args = { "-DINCREMENTAL_BIAS=4", "--c-source", c_helper }
        local c_source_initial = build_scenario("app", { extra_args = c_source_args })
        assert.equal(0, #c_source_initial.module_compiles, c_source_initial.raw)
        assert.is_true(target_matches(c_source_initial.native_misses, c_helper) == true,
            "expected 'Titan native miss " .. c_helper .. "' in:\n" .. c_source_initial.raw)
        assert.is_nil(target_matches(c_source_initial.native_hits, c_helper), c_source_initial.raw)
        assert_link_performed(c_source_initial, "server-executable", app_exe)

        local c_source_noop = build_scenario("app", { extra_args = c_source_args })
        assert.is_true(target_matches(c_source_noop.native_hits, c_helper) == true,
            "expected 'Titan native hit " .. c_helper .. "' in:\n" .. c_source_noop.raw)
        assert.is_nil(target_matches(c_source_noop.native_misses, c_helper), c_source_noop.raw)
        assert_link_skipped(c_source_noop, "server-executable", app_exe)

        write(c_helper, "int scenario_c_helper(void) { return 9; }\n")
        local c_source_changed = build_scenario("app", { extra_args = c_source_args })
        assert.equal(0, #c_source_changed.module_compiles, c_source_changed.raw)
        assert.is_true(target_matches(c_source_changed.native_misses, c_helper) == true,
            "expected 'Titan native miss " .. c_helper .. "' in:\n" .. c_source_changed.raw)
        assert.is_nil(target_matches(c_source_changed.native_hits, c_helper), c_source_changed.raw)
        assert_link_performed(c_source_changed, "server-executable", app_exe)

        -- Compiler frontend content change invalidates all module objects (configuration compiler).
        local custom_frontend = workspace .. "/custom-titanc"
        write(custom_frontend, read(REPOSITORY .. "/titanc"))
        local frontend_first = build_scenario("app", {
            frontend = custom_frontend,
            extra_args = c_source_args,
        })
        assert_link_skipped(frontend_first, "server-executable", app_exe)

        write(custom_frontend, read(custom_frontend) .. "\n-- changed compiler frontend input\n")
        local frontend_changed = build_scenario("app", {
            frontend = custom_frontend,
            extra_args = c_source_args,
        })
        assert_module_rebuilt(frontend_changed, "fixture.leaf", "fixture/leaf.o", "configuration compiler")
        assert_module_rebuilt(frontend_changed, "fixture.unrelated", "fixture/unrelated.o", "configuration compiler")

        -- Restore the normal frontend with define_args before test-discovery and link-recovery checks.
        build_scenario("app", { extra_args = define_args })
        build_scenario("test", { extra_args = define_args })

        -- Test discovery change (rename + add test) affects only the test image;
        -- the application build is a complete no-op.
        put_source("fixture/app_test.titan", app_tests_source("test_renamed", [[
function test_added(context: test.Context)
    test.assert(test.testing())
end
]]))
        local app_after_test_edit = build_scenario("app", { extra_args = define_args })
        assert_link_skipped(app_after_test_edit, "server-executable", app_exe)

        local updated_tests = build_scenario("test", { extra_args = define_args })
        assert_module_rebuilt(updated_tests, "fixture.app_test", "fixture/app_test.o", "source-content")
        assert_module_reused(updated_tests, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(updated_tests, "fixture.app", "fixture/app.o")
        assert_module_reused(updated_tests, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(updated_tests, "fixture.other_test", "fixture/other_test.o")
        assert_module_rebuilt(updated_tests, "server.tests", "server/tests.o", "import-interface")
        assert_link_performed(updated_tests, "test-executable", test_exe)

        local updated_names = {
            "fixture.app_test.test_renamed",
            "fixture.app_test.test_added",
            "fixture.other_test.test_unrelated",
        }
        local test_execution = verify_runtime(15, updated_names)
        assert.is_nil(test_execution:find("fixture.app_test.test_initial", 1, true),
            "removed test remained in the runner")

        -- Missing generated .titan.h and .ffi.h headers are restored on an object hit.
        assert(os.remove(build_dir .. "/fixture/leaf.titan.h"))
        assert(os.remove(build_dir .. "/fixture/leaf.ffi.h"))
        local restored_headers = build_scenario("test", { extra_args = define_args })
        assert_module_reused(restored_headers, "fixture.leaf", "fixture/leaf.o")
        assert.is_true(exists(build_dir .. "/fixture/leaf.titan.h"))
        assert.is_true(exists(build_dir .. "/fixture/leaf.ffi.h"))
        assert_link_skipped(restored_headers, "test-executable", test_exe)

        -- Failed-link retry: a failed linker run compiles no modules, leaves no valid executable,
        -- and the subsequent retry relinks once from the reusable module objects.
        assert(os.remove(app_exe))
        write(fail_link_marker, "fail one final link\n")
        local failed_link = build_scenario("app", {
            extra_args = define_args,
            expect_failure = true,
        })
        assert.equal(0, #failed_link.module_compiles, failed_link.raw)
        assert.matches("injected linker failure", failed_link.raw, 1, true)
        assert.is_false(exists(app_exe))

        local retried_link = build_scenario("app", { extra_args = define_args })
        assert_module_reused(retried_link, "fixture.leaf", "fixture/leaf.o")
        assert_module_reused(retried_link, "fixture.app", "fixture/app.o")
        assert_module_reused(retried_link, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(retried_link, "titan_language_server", "titan_language_server.o")
        assert.equal(0, #retried_link.module_compiles, retried_link.raw)
        assert_link_performed(retried_link, "server-executable", app_exe)
        verify_runtime(15, updated_names)

        -- Empty/interrupted executable output recovery.
        write(app_exe, "")
        local recovered_empty_exe = build_scenario("app", { extra_args = define_args })
        assert.equal(0, #recovered_empty_exe.module_compiles, recovered_empty_exe.raw)
        assert_link_performed(recovered_empty_exe, "server-executable", app_exe)
        assert.is_true((lfs.attributes(app_exe, "size") or 0) > 0)
        verify_runtime(15, updated_names)
        assert_link_skipped(build_scenario("app", { extra_args = define_args }),
            "server-executable", app_exe)

        -- Interrupted module output recovery: primary object removed or truncated.
        assert(os.remove(build_dir .. "/fixture/leaf.o"))
        local recovered_missing_primary = build_scenario("app", { extra_args = define_args })
        assert_module_rebuilt(recovered_missing_primary, "fixture.leaf", "fixture/leaf.o", "no-object")
        assert_module_reused(recovered_missing_primary, "fixture.app", "fixture/app.o")
        assert_module_reused(recovered_missing_primary, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(recovered_missing_primary, "titan_language_server", "titan_language_server.o")
        verify_runtime(15, updated_names)

        write(build_dir .. "/fixture/leaf.o", "truncated partial object")
        local recovered_truncated_primary = build_scenario("app", { extra_args = define_args })
        assert_module_rebuilt(recovered_truncated_primary, "fixture.leaf", "fixture/leaf.o", "record-unreadable")
        assert_module_reused(recovered_truncated_primary, "fixture.app", "fixture/app.o")
        assert_module_reused(recovered_truncated_primary, "fixture.unrelated", "fixture/unrelated.o")
        assert_module_reused(recovered_truncated_primary, "titan_language_server", "titan_language_server.o")
        verify_runtime(15, updated_names)
    end)

    it("validates split C parts against the primary object record across part loss, truncation, policy shrink, source shrink, and module removal", function()
        local functions = {}
        local literal = string.rep("x", 32768)
        for index = 0, 63 do
            functions[#functions + 1] = string.format(
                'function item_%d(): string return "%s" end', index, literal)
        end
        functions[#functions + 1] = "function value(): integer return #item_0() end\n"
        put_source("fixture/split.titan", table.concat(functions, "\n"))
        put_source("titan_language_server.titan", [[
local split = import "fixture.split"
function main(args: {string}): integer
    return split.value() // 32768
end
]])
        local stem = build_dir .. "/fixture/split"
        local split_env = { TITAN_C_PARTS = "3" }

        local function read_split_parts_count()
            local record = assert(objectmetadata.read(read(stem .. ".o"), stem .. ".o"))
            return #assert(record.object_metadata.parts)
        end

        -- Initial 3-part build: primary record carries parts; no .parts companion file exists.
        local initial_split = build_target("app", { env = split_env })
        assert_module_rebuilt(initial_split, "fixture.split", "fixture/split.o", "no-object")
        assert.is_true(read_split_parts_count() >= 2, "expected large module to split into multiple parts")
        assert.is_true(exists(stem .. ".part1.o"))
        assert.is_true(exists(stem .. ".part1.c"))
        assert.is_true(exists(stem .. ".priv.h"))
        assert.is_false(exists(stem .. ".parts"))

        local ok, out, why, code = run_executable(app_exe)
        assert.equal("exit", why, out)
        assert.equal(1, code, out)
        assert.is_false(ok)

        assert_link_skipped(build_target("app", { env = split_env }), "server-executable", app_exe)
        -- misses against the primary record's parts list and rebuilds fixture.split.
        for _, suffix in ipairs({ ".part1.c", ".part1.o", ".priv.h" }) do
            assert(os.remove(stem .. suffix))
            local repaired = build_target("app", { env = split_env })
            assert_module_rebuilt(repaired, "fixture.split", "fixture/split.o", "parts")
            assert_module_reused(repaired, "titan_language_server", "titan_language_server.o")
            assert.is_true(exists(stem .. suffix), "missing split artifact not restored: " .. suffix)
            local run_ok, run_out, run_why, run_code = run_executable(app_exe)
            assert.equal("exit", run_why, run_out)
            assert.equal(1, run_code, run_out)
            assert.is_false(run_ok)
        end

        write(stem .. ".part1.o", "truncated sidecar part")
        local repaired_truncated = build_target("app", { env = split_env })
        assert_module_rebuilt(repaired_truncated, "fixture.split", "fixture/split.o", "parts")
        assert_module_reused(repaired_truncated, "titan_language_server", "titan_language_server.o")
        assert.is_true(exists(stem .. ".part1.o"))

        -- Policy shrink (TITAN_C_PARTS=1) retires .part1.o/.part1.c/.priv.h and records 1 part.
        local single_env = { TITAN_C_PARTS = "1" }
        local policy_single = build_target("app", { env = single_env })
        assert_module_rebuilt(policy_single, "fixture.split", "fixture/split.o", "codegen-options c_parts")
        assert.equal(1, read_split_parts_count())
        assert.is_false(exists(stem .. ".part1.o"))
        assert.is_false(exists(stem .. ".part1.c"))
        assert.is_false(exists(stem .. ".priv.h"))
        assert.is_false(exists(stem .. ".parts"))
        assert_link_skipped(build_target("app", { env = single_env }), "server-executable", app_exe)

        -- Restoring TITAN_C_PARTS=3 splits the module again.
        local policy_restored = build_target("app", { env = split_env })
        assert_module_rebuilt(policy_restored, "fixture.split", "fixture/split.o", "codegen-options c_parts")
        assert.is_true(read_split_parts_count() >= 2)
        assert.is_true(exists(stem .. ".part1.o"))
        assert.is_true(exists(stem .. ".priv.h"))

        -- Source shrink under TITAN_C_PARTS=3 transitions from multi-part to 1 part and cleans old parts.
        put_source("fixture/split.titan", "function value(): integer return 32768 end\n")
        local source_shrunk = build_target("app", { env = split_env })
        assert_module_rebuilt(source_shrunk, "fixture.split", "fixture/split.o", "source-content")
        assert.equal(1, read_split_parts_count())
        for _, suffix in ipairs({ ".part1.c", ".part1.o", ".priv.h", ".parts" }) do
            assert.is_false(exists(stem .. suffix), "stale split file remained: " .. suffix)
        end
        assert_link_skipped(build_target("app", { env = split_env }), "server-executable", app_exe)

        -- Removing fixture.split from the import closure and source tree succeeds cleanly.
        put_source("titan_language_server.titan",
            "function main(args: {string}): integer return 1 end\n")
        assert(os.remove(source_dir .. "/fixture/split.titan"))
        local removed_split = build_target("app", { env = split_env })
        assert_module_rebuilt(removed_split, "titan_language_server", "titan_language_server.o", "source-content")
        local final_ok, final_out, final_why, final_code = run_executable(app_exe)
        assert.equal("exit", final_why, final_out)
        assert.equal(1, final_code, final_out)
        assert.is_false(final_ok)
    end)

    it("coordinates concurrent application and test titanc invocations sharing one output tree", function()
        populate_baseline_tree()
        local test_names = {
            "fixture.app_test.test_initial",
            "fixture.other_test.test_unrelated",
        }
        local uv = require("titan-compiler.process").library()

        local function spawn_titanc(kind)
            local args = {
                "--incremental", "-v",
                "--tree", source_dir,
                "--output", build_dir,
            }
            if not platform.windows then
                args[#args + 1] = "--static"
            end
            if kind == "test" then
                args[#args + 1] = "--test"
                args[#args + 1] = "--exe"
                args[#args + 1] = test_exe
                args[#args + 1] = "server.tests"
            else
                args[#args + 1] = "--exe"
                args[#args + 1] = app_exe
                args[#args + 1] = "titan_language_server"
            end
            local env_map = uv.os_environ()
            env_map.TITAN_RUNTIME_PREBUILT = "1"
            env_map.CCACHE_DISABLE = "1"
            env_map.TITAN_PROBE_CACHE_DISABLE = "1"
            env_map.TITAN_ROOT = prefix
            env_map.TITAN_BUILD_PROFILE = "validation"
            env_map.TITAN_EXTRA_CPPFLAGS = ""
            env_map.TITAN_EXTRA_CFLAGS = "-O0 -fno-lto"
            env_map.TITAN_EXTRA_LDFLAGS = "-fno-lto"
            local env_list = {}
            for key, value in pairs(env_map) do
                env_list[#env_list + 1] = key .. "=" .. value
            end
            local spawn_args = {
                "-E", "-e",
                string.format(
                    "package.path = %q .. package.path; package.cpath = %q .. package.cpath",
                    REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
                    REPOSITORY .. "/titan-runtime/bootstrap/?" .. SHARED_SUFFIX .. ";"),
                REPOSITORY .. "/titanc",
                table.unpack(args),
            }
            local stdout = uv.new_pipe(false)
            local stderr = uv.new_pipe(false)
            local chunks = {}
            local child = { kind = kind, exited = false }
            local function close_handle(handle)
                if handle and not handle:is_closing() then handle:close() end
            end
            child.handle = assert(uv.spawn(LUA, {
                args = spawn_args,
                cwd = REPOSITORY,
                env = env_list,
                stdio = { nil, stdout, stderr },
            }, function(code, signal)
                child.code = code
                child.signal = signal
                child.exited = true
                close_handle(child.handle)
            end))
            local function read_pipe(pipe)
                pipe:read_start(function(err, data)
                    assert.is_nil(err)
                    if data then
                        chunks[#chunks + 1] = data
                    else
                        close_handle(pipe)
                    end
                end)
            end
            read_pipe(stdout)
            read_pipe(stderr)
            child.output = function()
                local text = table.concat(chunks)
                if platform.windows then text = text:gsub("\r\n", "\n") end
                return text
            end
            return child
        end

        local app_child = spawn_titanc("app")
        local test_child = spawn_titanc("test")
        local deadline = uv.new_timer()
        local timed_out = false
        -- Earlier synchronous builds can leave the shared libuv loop clock
        -- stale. Start the full deadline from the current time.
        uv.update_time()
        deadline:start(120000, 0, function()
            timed_out = true
            for _, child in ipairs({ app_child, test_child }) do
                if not child.exited then child.handle:kill("sigkill") end
            end
        end)
        deadline:unref()
        uv.run()
        if not deadline:is_closing() then deadline:close() end
        uv.run("nowait")

        local app_out = app_child.output()
        local test_out = test_child.output()
        assert.is_false(timed_out, "concurrent titanc invocations timed out:\n" .. app_out .. "\n" .. test_out)
        assert.equal(0, app_child.code, app_out)
        assert.equal(0, test_child.code, test_out)
        assert.equal("file", lfs.symlinkattributes(build_dir .. "/.titan-build.lock", "mode"))

        -- Because output-tree locking serializes certification through publication,
        -- the winner compiles shared production modules once and the waiter reuses them.
        local app_parsed = parse_verbose_output(app_out)
        local test_parsed = parse_verbose_output(test_out)
        for _, shared_mod in ipairs({ "fixture.leaf", "fixture.app", "fixture.unrelated" }) do
            local hits = (app_parsed.object_hits[shared_mod] and 1 or 0)
                + (test_parsed.object_hits[shared_mod] and 1 or 0)
            local misses = (app_parsed.object_misses[shared_mod] and 1 or 0)
                + (test_parsed.object_misses[shared_mod] and 1 or 0)
            assert.equal(1, misses,
                "expected shared module " .. shared_mod .. " to miss once across concurrent builds:\n"
                .. app_out .. "\n---\n" .. test_out)
            assert.equal(1, hits,
                "expected shared module " .. shared_mod .. " to hit once across concurrent builds:\n"
                .. app_out .. "\n---\n" .. test_out)
        end

        verify_runtime(5, test_names)
        assert_link_skipped(build_target("app"), "server-executable", app_exe)
        assert_link_skipped(build_target("test"), "test-executable", test_exe)
    end)
end)
