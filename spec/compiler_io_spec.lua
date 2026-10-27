local temporary = require "spec.support.temporary"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local lfs = require "lfs"
local filesystem = require "spec.support.filesystem"

local function remove_tree(path)
    local strategy = compiler_io.new_sync()
    local attributes, err = strategy:lstat(path)
    assert.is_nil(err, err)
    if not attributes then return end
    if attributes.kind ~= "directory" then
        local followed = attributes.kind == "symlink" and strategy:stat(path)
        if platform.windows and followed and followed.kind == "directory" then
            assert(strategy:rmdir(path))
        else
            assert(strategy:unlink(path))
        end
        return
    end
    -- Remove links while their targets still exist, so directory links retain
    -- the Windows rmdir classification throughout fixture cleanup.
    local ordinary = {}
    for _, entry in ipairs(assert(strategy:list(path))) do
        local child = path .. "/" .. entry
        if assert(strategy:lstat(child)).kind == "symlink" then
            remove_tree(child)
        else
            ordinary[#ordinary + 1] = child
        end
    end
    for _, child in ipairs(ordinary) do remove_tree(child) end
    assert(strategy:rmdir(path))
end

local function workspace()
    local path = assert(temporary.name("-compiler-io"))
    assert(lfs.mkdir(path))
    return path
end

local function with_overrides(target, replacements, body)
    local originals = {}
    for name, replacement in pairs(replacements) do
        originals[#originals + 1] = { name, target[name] }
        target[name] = replacement
    end
    local results = table.pack(pcall(body))
    for _, original in ipairs(originals) do
        target[original[1]] = original[2]
    end
    assert.is_true(results[1], results[2])
    return table.unpack(results, 2, results.n)
end

local function with_native_stat(native, body)
    local support = require "titan"
    return with_overrides(support, { _stat_precise = native }, body)
end

local function coarse_stat_it(name, body)
    it(name, function() return with_native_stat(false, body) end)
end

local function posix_model_it(name, body)
    it(name, function()
        return with_native_stat(false, function()
            return with_overrides(platform, { windows = false }, body)
        end)
    end)
end

describe("compiler I/O strategy", function()
    local root

    after_each(function()
        if root then remove_tree(root); root = nil end
    end)

    it("constructs and strictly validates the synchronous surface", function()
        local strategy = compiler_io.new_sync()
        assert.equal(strategy, compiler_io.validate(strategy))
        for _, name in ipairs({
            "cwd", "realpath", "stat", "lstat", "readable", "read_file",
            "write_file", "list", "mkdir", "unlink", "rmdir", "rename",
            "tmpname", "run", "yield",
        }) do
            assert.is_function(strategy[name], name)
        end

        assert.has_error(function()
            compiler_io.validate(nil)
        end, "compiler I/O strategy must be a table or userdata")
        assert.has_error(function()
            compiler_io.validate({})
        end, "compiler I/O strategy method 'cwd' must be callable")

        local broken = compiler_io.new_sync()
        broken.read_file = false
        assert.has_error(function()
            compiler_io.validate(broken)
        end, "compiler I/O strategy method 'read_file' must be callable")
    end)

    it("keeps execution eligibility an optional strategy capability", function()
        local strategy = compiler_io.new_sync()
        strategy.executable = false
        assert.equal(strategy, compiler_io.validate(strategy))
    end)

    it("delegates effective execution eligibility without opening the file", function()
        local support, strategy = require "titan", compiler_io.new_sync()
        local checked, result, diagnostic = {}, true, nil
        with_overrides(support, { _executable_access = function(path)
            checked[#checked + 1] = path
            return result, diagnostic
        end }, function()
            with_overrides(io, { open = function()
                error("execution eligibility must not open or read a file")
            end }, function()
                assert.is_true(strategy:executable("/route/link/../tool"))
                result = false
                assert.is_false(strategy:executable("/route/link/../tool"))
                result, diagnostic = nil, "native eligibility query failed"
                local allowed, err = strategy:executable("/route/link/../tool")
                assert.is_nil(allowed)
                assert.equal(diagnostic, err)
                assert.same({ "/route/link/../tool", "/route/link/../tool",
                    "/route/link/../tool" }, checked)
            end)
        end)
    end)

    it("fails closed when native execution eligibility is unavailable", function()
        with_overrides(require "titan", { _executable_access = false }, function()
            local allowed, err = compiler_io.new_sync():executable("tool")
            assert.is_nil(allowed)
            assert.matches("native support lacks _executable_access", err, 1, true)
        end)
    end)

    it("validates execution query paths before calling native support", function()
        with_overrides(require "titan", { _executable_access = function()
            error("malformed paths must not reach native support")
        end }, function()
            local strategy = compiler_io.new_sync()
            local allowed, err = strategy:executable(false)
            assert.is_nil(allowed)
            assert.equal("path must be a string", err)
            allowed, err = strategy:executable("bad\0path")
            assert.is_nil(allowed)
            assert.equal("path contains a NUL byte", err)
        end)
    end)

    it("propagates native execution query cancellation unchanged", function()
        local cancelled = {}
        with_overrides(require "titan", { _executable_access = function()
            error(cancelled, 0)
        end }, function()
            local strategy = compiler_io.new_sync()
            local ok, err = pcall(strategy.executable, strategy, "tool")
            assert.is_false(ok)
            assert.equal(cancelled, err)
        end)
    end)

    it("keeps executable CWD search an optional strategy capability", function()
        local strategy = compiler_io.new_sync()
        strategy.executable_search_cwd = false
        assert.equal(strategy, compiler_io.validate(strategy))
    end)

    it("delegates executable CWD search without environment or file fallbacks", function()
        local support, strategy = require "titan", compiler_io.new_sync()
        local result, diagnostic, checked = true, nil, 0
        local function forbidden()
            error("CWD search policy must come only from native support")
        end
        with_overrides(support, { _executable_search_cwd = function(...)
            assert.equal(0, select("#", ...))
            checked = checked + 1
            return result, diagnostic
        end }, function()
            with_overrides(io, { open = forbidden }, function()
                with_overrides(os, { getenv = forbidden }, function()
                    with_overrides(platform, { getenv = forbidden }, function()
                        assert.is_true(strategy:executable_search_cwd())
                        result = false
                        assert.is_false(strategy:executable_search_cwd())
                        result, diagnostic = nil, "native CWD query unavailable"
                        local allowed, err = strategy:executable_search_cwd()
                        assert.is_nil(allowed)
                        assert.equal(diagnostic, err)
                        local cancelled = {}
                        diagnostic = cancelled
                        allowed, err = strategy:executable_search_cwd()
                        assert.is_nil(allowed)
                        assert.equal(cancelled, err)
                        assert.equal(4, checked)
                    end)
                end)
            end)
        end)
    end)

    it("reports unavailable native executable CWD policy without guessing", function()
        local strategy = compiler_io.new_sync()
        local function forbidden()
            error("unavailable CWD policy must not consult the host environment")
        end
        with_overrides(require "titan", { _executable_search_cwd = false }, function()
            with_overrides(platform, { getenv = forbidden }, function()
                with_overrides(os, { getenv = forbidden }, function()
                    local allowed, err = strategy:executable_search_cwd()
                    assert.is_nil(allowed)
                    assert.matches("native support lacks _executable_search_cwd", err, 1, true)
                end)
            end)
        end)
    end)

    it("propagates native executable CWD query cancellation unchanged", function()
        local cancelled = {}
        with_overrides(require "titan", { _executable_search_cwd = function()
            error(cancelled, 0)
        end }, function()
            local strategy = compiler_io.new_sync()
            local ok, err = pcall(strategy.executable_search_cwd, strategy)
            assert.is_false(ok)
            assert.equal(cancelled, err)
        end)
    end)

    it("keeps the synchronous yield checkpoint a no-op", function()
        local strategy = compiler_io.new_sync()
        local co = coroutine.create(function()
            strategy:yield()
            return "completed"
        end)
        local resumed, result = coroutine.resume(co)
        assert.is_true(resumed)
        assert.equal("completed", result)
        assert.equal("dead", coroutine.status(co))
    end)

    coarse_stat_it("declares floating timestamp observations coarse at whole and fractional seconds", function()
        local strategy = compiler_io.new_sync()
        for _, stamp in ipairs({ 100, 100.125 }) do
            with_overrides(lfs, {
                attributes = function()
                    return { mode = "file", size = 4, modification = stamp, dev = 1, ino = 2 }
                end,
            }, function()
                local stat = assert(strategy:stat("fixture.h"))
                assert.equal("coarse", stat.time_precision)
                assert.equal("coarse", stat.precision)
                assert.equal(100, stat.modified_seconds)
                assert.equal(stamp == 100 and 0 or 125000000, stat.modified_nanoseconds)
            end)
        end
    end)

    it("normalizes exact native timestamps and opaque identities for stat and lstat", function()
        local calls = {}
        local path = "SDK 日本/linked/../header.h"
        local function native(filename, follow)
            calls[#calls + 1] = { filename, follow }
            return { kind = follow and "file" or "link",
                dev = "18446744073709551615", ino = "0123456789abcdef0123456789abcdef",
                size = 19, mode = follow and 0x81A4 or 0xA1FF,
                mtime_ns = 1790816523123456789, ctime_ns = 1790816523987654321 }
        end
        with_native_stat(native, function()
            with_overrides(lfs, {
                attributes = function() error("native stat must not query LFS") end,
                symlinkattributes = function() error("native lstat must not query LFS") end,
            }, function()
                local strategy = compiler_io.new_sync()
                for _, follow in ipairs({ true, false }) do
                    local stat = assert(follow and strategy:stat(path) or strategy:lstat(path))
                    assert.same({
                        kind = follow and "file" or "symlink",
                        dev = "18446744073709551615", ino = "0123456789abcdef0123456789abcdef",
                        device = "18446744073709551615", inode = "0123456789abcdef0123456789abcdef",
                        size = 19, mode = follow and 0x81A4 or 0xA1FF,
                        precision = "ns", time_precision = "ns",
                        mtime_ns = 1790816523123456789, ctime_ns = 1790816523987654321,
                        modified_seconds = 1790816523, modified_nanoseconds = 123456789,
                        changed_seconds = 1790816523, changed_nanoseconds = 987654321,
                    }, stat)
                end
                assert.same({ { path, true }, { path, false } }, calls)
            end)
        end)
    end)

    it("preserves exact-second and pre-epoch native timestamps", function()
        for _, stamp in ipairs({ 0, -1, -1000000001 }) do
            with_native_stat(function()
                return { kind = "file", dev = "1", ino = "2", size = 0, mode = 0x81A4,
                    mtime_ns = stamp, ctime_ns = stamp }
            end, function()
                local stat = assert(compiler_io.new_sync():stat("fixture.h"))
                assert.equal("ns", stat.precision)
                assert.equal(stamp, stat.mtime_ns)
                assert.equal(stamp, stat.ctime_ns)
                assert.equal(stamp // 1000000000, stat.modified_seconds)
                assert.equal(stamp % 1000000000, stat.modified_nanoseconds)
                assert.equal(stat.modified_seconds, stat.changed_seconds)
                assert.equal(stat.modified_nanoseconds, stat.changed_nanoseconds)
            end)
        end
    end)

    it("distinguishes native missing paths and errors without querying coarse metadata", function()
        local calls = 0
        with_native_stat(function(path)
            calls = calls + 1
            if path == "missing" then return nil, "ENOENT: No such file or directory", 2 end
            if path == "blocked/child" then return nil, "ENOTDIR: Not a directory", 20 end
            return nil, "EACCES: Permission denied", 13
        end, function()
            with_overrides(lfs, {
                attributes = function() error("native error must not query LFS") end,
                symlinkattributes = function() error("native error must not query LFS") end,
            }, function()
                local strategy = compiler_io.new_sync()
                for _, method in ipairs({ "stat", "lstat" }) do
                    local missing, err = strategy[method](strategy, "missing")
                    assert.is_nil(missing)
                    assert.is_nil(err)
                    missing, err = strategy[method](strategy, "blocked/child")
                    assert.is_nil(missing)
                    assert.equal("ENOTDIR: Not a directory", err)
                    missing, err = strategy[method](strategy, "denied")
                    assert.is_nil(missing)
                    assert.equal("EACCES: Permission denied", err)
                end
                assert.equal(6, calls)
                assert.is_nil(strategy:stat(false))
                assert.is_nil(strategy:lstat("bad\0path"))
                assert.equal(6, calls)
            end)
        end)
    end)

    it("observes native precise support added after a coarse lookup", function()
        with_native_stat(false, function()
            local strategy = compiler_io.new_sync()
            with_overrides(lfs, {
                attributes = function()
                    return { mode = "file", size = 0, modification = 100 }
                end,
            }, function()
                assert.equal("coarse", assert(strategy:stat("fixture.h")).precision)
                require("titan")._stat_precise = function()
                    return { kind = "file", dev = "1", ino = "2", size = 0, mode = 0x81A4,
                        mtime_ns = 100000000000, ctime_ns = 100000000001 }
                end
                assert.equal("ns", assert(strategy:stat("fixture.h")).precision)
            end)
        end)
    end)

    it("propagates native precise-stat cancellation unchanged", function()
        local cancelled = {}
        with_native_stat(function() error(cancelled, 0) end, function()
            local ok, err = pcall(compiler_io.new_sync().stat, compiler_io.new_sync(), "fixture.h")
            assert.is_false(ok)
            assert.equal(cancelled, err)
        end)
    end)

    it("preserves binary files and normalizes filesystem operations", function()
        root = workspace()
        local strategy = compiler_io.new_sync()
        local cwd = assert(strategy:cwd())
        assert.equal(assert(lfs.currentdir()), cwd)

        local directory = root .. "/nested"
        assert.is_true(strategy:mkdir(directory))
        local source = directory .. "/source.bin"
        local bytes = "prefix\0middle\255suffix"
        assert.is_true(strategy:write_file(source, bytes))
        assert.is_true(strategy:readable(source))
        assert.equal(bytes, assert(strategy:read_file(source)))
        assert.equal(bytes, assert(strategy:read_file(source, #bytes)))
        assert.equal(bytes:sub(1, 6),
            assert(strategy:read_file(source, 5)))
        local invalid_read, invalid_read_error =
            strategy:read_file(source, -1)
        assert.is_nil(invalid_read)
        assert.matches("nonnegative integer", invalid_read_error, 1, true)
        local empty = directory .. "/empty.bin"
        assert.is_true(strategy:write_file(empty, ""))
        assert.equal("", assert(strategy:read_file(empty, 0)))
        assert.is_true(strategy:unlink(empty))

        local function reject_rename()
            return nil, "injected rename failure"
        end
        local function check_replacement()
            local replaced, replace_err = strategy:write_file(source, "replacement")
            assert.is_nil(replaced)
            assert.matches("injected rename failure", replace_err, 1, true)
        end
        with_overrides(os, { rename = reject_rename }, check_replacement)
        if platform.windows then
            assert.is_false(strategy:readable(source))
            assert.is_true(strategy:write_file(source, bytes))
        else
            assert.equal(bytes, assert(strategy:read_file(source)))
        end

        local metadata = assert(strategy:stat(source))
        local expected_keys = {
            "kind", "mode", "modified_nanoseconds", "modified_seconds",
            "precision", "size", "time_precision",
        }
        local precise = metadata.precision == "ns"
        if precise then
            for _, key in ipairs({
                "changed_seconds", "changed_nanoseconds", "ctime_ns", "mtime_ns", "dev", "ino",
            }) do expected_keys[#expected_keys + 1] = key end
        end
        if precise or not platform.windows then
            expected_keys[#expected_keys + 1] = "device"
            expected_keys[#expected_keys + 1] = "inode"
        end
        table.sort(expected_keys)
        assert.same(expected_keys, (function()
            local keys = {}
            for key in pairs(metadata) do keys[#keys + 1] = key end
            table.sort(keys)
            return keys
        end)())
        assert.equal("file", metadata.kind)
        assert.equal(#bytes, metadata.size)
        assert.equal(0x8000, metadata.mode & 0xF000)
        if precise then
            assert.is_string(metadata.device)
            assert.is_string(metadata.inode)
            assert.equal(metadata.dev, metadata.device)
            assert.equal(metadata.ino, metadata.inode)
            assert.equal("integer", math.type(metadata.mtime_ns))
            assert.equal("integer", math.type(metadata.ctime_ns))
        elseif platform.windows then
            assert.is_nil(metadata.device)
            assert.is_nil(metadata.inode)
        else
            assert.is_number(metadata.device)
            assert.is_number(metadata.inode)
        end
        assert.is_number(metadata.modified_seconds)
        assert.is_number(metadata.modified_nanoseconds)
        assert.equal(precise and "ns" or "coarse", metadata.time_precision)
        assert.is_true(metadata.modified_nanoseconds >= 0)
        assert.is_true(metadata.modified_nanoseconds < 1000000000)

        local hard_link = directory .. "/source-hard-link.bin"
        assert(lfs.link(source, hard_link))
        local hard_link_metadata = assert(strategy:stat(hard_link))
        assert.equal(bytes, assert(strategy:read_file(hard_link)))
        assert.equal(metadata.size, hard_link_metadata.size)
        if precise or not platform.windows then
            assert.equal(metadata.device, hard_link_metadata.device)
            assert.equal(metadata.inode, hard_link_metadata.inode)
        end
        assert.is_true(strategy:unlink(hard_link))

        local entries = assert(strategy:list(directory))
        table.sort(entries)
        assert.same({ "source.bin" }, entries)

        local renamed = directory .. "/renamed.bin"
        assert.is_true(strategy:rename(source, renamed))
        assert.is_false(strategy:readable(source))
        assert.equal(bytes, assert(strategy:read_file(renamed)))
        assert.is_true(strategy:unlink(renamed))
        assert.is_true(strategy:rmdir(directory))

        local absent, absent_err = strategy:stat(source)
        assert.is_nil(absent)
        assert.is_nil(absent_err)
        absent, absent_err = strategy:lstat(source)
        assert.is_nil(absent)
        assert.is_nil(absent_err)

        local temporary = assert(strategy:tmpname())
        local temporary_metadata = assert(strategy:stat(temporary))
        assert.equal("file", temporary_metadata.kind)
        assert.is_true(strategy:unlink(temporary))
    end)

    it("distinguishes symlinks, dangling targets, and canonical paths", function()
        local available, message = filesystem.symlink_capability()
        if not available then pending(message); return end
        root = workspace()
        local strategy = compiler_io.new_sync()
        local target = root .. "/target"
        assert.is_true(strategy:write_file(target, "target bytes"))
        local link = root .. "/link"
        assert(lfs.link(target, link, true))

        assert.equal("file", assert(strategy:stat(link)).kind)
        assert.equal("symlink", assert(strategy:lstat(link)).kind)
        if platform.windows then
            assert.equal(assert(strategy:absolute(target)),
                assert(strategy:realpath(target)))
            assert.equal(assert(strategy:absolute(link)),
                assert(strategy:realpath(link)))
            assert.not_equal(assert(strategy:realpath(target)),
                assert(strategy:realpath(link)))
        else
            assert.equal(assert(strategy:realpath(target)),
                assert(strategy:realpath(link)))
        end

        local actual = root .. "/actual"
        local nested = actual .. "/nested"
        assert.is_true(strategy:mkdir(actual))
        assert.is_true(strategy:mkdir(nested))
        local sibling = actual .. "/sibling"
        assert.is_true(strategy:write_file(sibling, "sibling bytes"))
        local directory_link = root .. "/directory-link"
        assert(lfs.link(nested, directory_link, true))
        if platform.windows then
            assert.equal(assert(strategy:absolute(directory_link)),
                assert(strategy:realpath(directory_link)))
            assert.not_equal(assert(strategy:realpath(nested)),
                assert(strategy:realpath(directory_link)))
            -- Win32 resolves dot-dot before traversing the directory link.
            sibling = root .. "/sibling"
            assert.is_true(strategy:write_file(sibling, "lexical sibling bytes"))
        else
            assert.equal(assert(strategy:realpath(nested)),
                assert(strategy:realpath(directory_link)))
        end
        assert.equal(assert(strategy:realpath(sibling)),
            assert(strategy:realpath(directory_link .. "/../sibling")))

        local dangling = root .. "/dangling"
        assert(lfs.link(root .. "/missing", dangling, true))
        local followed, followed_err = strategy:stat(dangling)
        assert.is_nil(followed)
        assert.is_nil(followed_err)
        assert.equal("symlink", assert(strategy:lstat(dangling)).kind)
        local canonical, canonical_err = strategy:realpath(dangling)
        assert.is_nil(canonical)
        if platform.windows then
            assert.is_string(canonical_err)
            assert.is_true(#canonical_err > 0)
        else
            assert.matches("does not exist", canonical_err, 1, true)
        end
    end)

    posix_model_it("keeps captured shell semantics while inheriting coordinator leases", function()
        local process = require "titan-compiler.process"
        local argv = { "tool with spaces", "quoted'argument", "line\nbreak" }
        for _, settings in ipairs({ {}, { stderr_to_stdout = false } }) do
            for _, case in ipairs({
                { ok = true, why = "exit", status = 0 },
                { ok = false, why = "exit", status = 3 },
                { ok = false, why = "exit", status = 126 },
                { ok = false, why = "exit", status = 127 },
                { ok = false, why = "exit", status = 143 },
                { ok = false, why = "signal", status = 15 },
            }) do
                local strategy, popen_calls = compiler_io.new_sync(), 0
                local leases, output = { 17, 41 }, "captured\0bytes"
                with_overrides(io, { popen = function(_, mode)
                    popen_calls = popen_calls + 1
                    assert.equal("r", mode)
                    return {
                        read = function() return output end,
                        close = function() return case.ok, case.why, case.status end,
                    }
                end }, function()
                    local baseline = strategy:run(argv, settings)
                    strategy._process_inherit = leases
                    with_overrides(process, { capture = function(actual, options)
                        assert.same({ "/bin/sh", "-c", baseline.command }, actual)
                        assert.equal(leases, options.inherit)
                        assert.is_true(options.inherit_environment)
                        assert.is_false(options.stderr_to_stdout)
                        return { started = true, ok = case.ok, why = case.why,
                            status = case.status, output = output }
                    end }, function()
                        assert.same(baseline, strategy:run(argv, settings))
                    end)
                    assert.equal(1, popen_calls)
                    strategy._process_inherit = nil
                    assert.same(baseline, strategy:run(argv, settings))
                    assert.equal(2, popen_calls)
                end)
            end
        end
    end)

    posix_model_it("does not escape inherited leases after a capture infrastructure failure", function()
        local process = require "titan-compiler.process"
        local strategy = compiler_io.new_sync()
        strategy._process_inherit = { 17 }
        with_overrides(io, { popen = function()
            error("an inherited command must not fall back to popen")
        end }, function()
            with_overrides(process, { capture = function() error("capture launch denied") end },
            function()
                local result = strategy:run({ "tool" })
                assert.is_false(result.started)
                assert.is_false(result.ok)
                assert.matches("capture launch denied", result.diagnostic, 1, true)
                assert.is_nil(result.status)
            end)
            local expected = { started = true, ok = false, output = "partial",
                diagnostic = "could not capture command output: interrupted read" }
            with_overrides(process, { capture = function() return expected end }, function()
                local result = strategy:run({ "tool" })
                assert.equal(expected, result)
                assert.is_string(result.command)
                assert.is_nil(result.status)
                assert.matches("interrupted read", result.diagnostic, 1, true)
            end)
        end)
    end)

    it("captures argv with deterministic locale and normalized status", function()
        root = workspace()
        local strategy = compiler_io.new_sync()
        local success = strategy:run({
            "sh", "-c",
            [[printf '%s|%s|' "$LANG" "$LC_ALL"; ]] ..
                [[printf 'A\000B'; printf '|diagnostic' >&2]],
        })
        assert.is_true(success.started)
        assert.is_true(success.ok)
        assert.equal(0, success.status)
        assert.equal("exit", success.why)
        assert.is_false(success.interrupted)
        assert.equal("C|C|A\0B|diagnostic", success.output)
        assert.equal(success.output, success.diagnostic)
        if platform.windows then
            assert.is_nil(success.command:find("2>&1", 1, true))
        else
            assert.matches("2>&1$", success.command)
        end

        local separate = strategy:run({ "sh", "-c", "printf stdout" }, {
            stderr_to_stdout = false,
        })
        assert.is_true(separate.ok, separate.diagnostic)
        assert.equal("stdout", separate.output)
        assert.is_nil(separate.command:find("2>&1", 1, true))

        local rejected = strategy:run({
            "sh", "-c", "printf rejected; exit 7",
        })
        assert.is_true(rejected.started)
        assert.is_false(rejected.ok)
        assert.equal("exit", rejected.why)
        assert.equal(7, rejected.status)
        assert.is_false(rejected.interrupted)
        assert.equal("rejected", rejected.output)

        local missing = strategy:run({
            root .. "/missing-command",
        })
        assert.is_false(missing.started)
        assert.is_false(missing.ok)
        if platform.windows then
            assert.is_nil(missing.why)
            assert.is_nil(missing.status)
            assert.is_nil(missing.interrupted)
            assert.is_string(missing.diagnostic)
        else
            assert.equal("exit", missing.why)
            assert.equal(127, missing.status)
            assert.is_false(missing.interrupted)
        end

        local signalled = strategy:run(platform.windows and {
            os.getenv("PREFIX") and
                platform.join(os.getenv("PREFIX"), "bin/lua.exe") or "lua.exe",
            "-E", "-e", "os.exit(143)",
        } or { "sh", "-c", "kill -TERM $$" })
        assert.is_true(signalled.started)
        assert.is_false(signalled.ok)
        if platform.windows then
            assert.equal("exit", signalled.why)
            assert.equal(143, signalled.status)
            assert.is_nil(signalled.signal)
            assert.is_nil(signalled.shell_status)
            assert.is_false(signalled.interrupted)
        else
            assert.equal("signal", signalled.why)
            assert.equal(15, signalled.status)
            assert.equal(15, signalled.signal)
            assert.equal(143, signalled.shell_status)
            assert.is_true(signalled.interrupted)
        end

        local invalid = strategy:run({ [1] = "sh", extra = "argument" })
        assert.is_false(invalid.started)
        assert.is_false(invalid.ok)
        assert.matches("dense argument array", invalid.diagnostic, 1, true)
    end)

    it("rejects malformed paths, writes, commands, and strategy methods",
    function()
        root = workspace()
        local strategy = compiler_io.new_sync()

        local value, err = strategy:stat(false)
        assert.is_nil(value)
        assert.equal("path must be a string", err)
        value, err = strategy:lstat("bad\0path")
        assert.is_nil(value)
        assert.equal("path contains a NUL byte", err)
        value, err = strategy:write_file(root .. "/bad", {})
        assert.is_nil(value)
        assert.equal("file contents must be a string", err)

        local directory = root .. "/directory"
        assert.is_true(strategy:mkdir(directory))
        value, err = strategy:unlink(directory)
        assert.is_nil(value)
        assert.is_string(err)
        assert.is_true(#err > 0)
        assert.equal("directory", assert(strategy:stat(directory)).kind)
        if not platform.windows then
            assert.matches("cannot unlink directory", err, 1, true)
        end

        local cases = {
            {
                argv = false,
                diagnostic = "command must be an argument array",
            },
            {
                argv = { "sh", false },
                diagnostic = "command argument 2 must be a string",
            },
            {
                argv = { "sh", "bad\0argument" },
                diagnostic = "command argument 2 contains a NUL byte",
            },
            {
                argv = {},
                diagnostic = "command is empty",
            },
            {
                argv = { "sh" },
                options = "invalid options",
                diagnostic = "command options must be a table",
            },
        }
        for _, case in ipairs(cases) do
            local result = strategy:run(case.argv, case.options)
            assert.is_false(result.started)
            assert.is_false(result.ok)
            assert.equal(case.diagnostic, result.diagnostic)
        end

        local unreadable = setmetatable({}, {
            __index = function(_, name)
                error("injected denial for " .. tostring(name))
            end,
        })
        local readable, validation_error = pcall(
            compiler_io.validate, unreadable)
        assert.is_false(readable)
        assert.matches("cannot read compiler I/O strategy method 'cwd'",
            validation_error, 1, true)
        assert.matches("injected denial for cwd", validation_error, 1, true)
    end)

    posix_model_it("normalizes uncommon metadata and realpath failures", function()
        local strategy = compiler_io.new_sync()
        with_overrides(lfs, {
            attributes = function()
                return {
                    mode = "file",
                    permissions = "rwsr-Sr-T",
                    modification = 1.9999999996,
                    size = 0,
                    dev = 7,
                    ino = 11,
                }
            end,
        }, function()
            local metadata = assert(strategy:stat("virtual"))
            assert.equal(0x8E00, metadata.mode & 0xFE00)
            assert.equal(2, metadata.modified_seconds)
            assert.equal(0, metadata.modified_nanoseconds)
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = function() return { mode = "file" } end,
            currentdir = (function()
                local calls = 0
                return function()
                    calls = calls + 1
                    return calls == 1 and "/" or "/virtual"
                end
            end)(),
            chdir = function() return true end,
        }, function()
            assert.equal("/virtual", assert(strategy:realpath("virtual")))
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = function()
                return { mode = "link", target = "loop" }
            end,
            currentdir = function() return "/base" end,
        }, function()
            local resolved, err = strategy:realpath("loop")
            assert.is_nil(resolved)
            assert.matches("too many levels of symbolic links", err, 1, true)
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = (function()
                local hop = 0
                return function()
                    hop = hop + 1
                    return { mode = "link", target = "/hop" .. hop }
                end
            end)(),
            currentdir = function() return "/base" end,
        }, function()
            local resolved, err = strategy:realpath("many-links")
            assert.is_nil(resolved)
            assert.matches("too many levels of symbolic links", err, 1, true)
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = function() return { mode = "file" } end,
            currentdir = (function()
                local calls = 0
                return function()
                    calls = calls + 1
                    return calls == 1 and "/base" or "/resolved"
                end
            end)(),
            chdir = (function()
                local calls = 0
                return function()
                    calls = calls + 1
                    if calls == 1 then return true end
                    return nil, "injected restore failure"
                end
            end)(),
        }, function()
            local resolved, err = strategy:realpath("entry")
            assert.is_nil(resolved)
            assert.equal("injected restore failure", err)
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = function() return { mode = "file" } end,
            currentdir = (function()
                local calls = 0
                return function()
                    calls = calls + 1
                    if calls == 1 then return "/base" end
                    return nil, "injected resolve failure"
                end
            end)(),
            chdir = function() return true end,
        }, function()
            local resolved, err = strategy:realpath("entry")
            assert.is_nil(resolved)
            assert.equal("injected resolve failure", err)
        end)

        with_overrides(lfs, {
            attributes = function() return { mode = "file" } end,
            symlinkattributes = function()
                return nil, "injected lookup failure"
            end,
            currentdir = function() return "/base" end,
            chdir = function() return nil, "injected chdir failure" end,
        }, function()
            local resolved, err = strategy:realpath("missing")
            assert.is_nil(resolved)
            assert.equal("injected lookup failure", err)
        end)
    end)

    it("normalizes command transport failures", function()
        for _, windows in ipairs({ false }) do
            with_overrides(platform, { windows = windows }, function()
                local strategy = compiler_io.new_sync()

                with_overrides(io, {
                    popen = function() return nil, "injected spawn failure" end,
                }, function()
                    local result = strategy:run({ "tool" })
                    assert.is_false(result.started)
                    assert.is_false(result.ok)
                    assert.matches("injected spawn failure", result.diagnostic,
                        1, true)
                end)

                local read_close_calls = 0
                with_overrides(io, {
                    popen = function()
                        return {
                            read = function() error("injected read failure") end,
                            close = function()
                                read_close_calls = read_close_calls + 1
                                return true
                            end,
                        }
                    end,
                }, function()
                    local result = strategy:run({ "tool" })
                    assert.is_true(result.started)
                    assert.is_false(result.ok)
                    assert.matches("injected read failure", result.diagnostic,
                        1, true)
                end)
                assert.equal(1, read_close_calls)

                with_overrides(io, {
                    popen = function()
                        return {
                            read = function() return "partial output" end,
                            close = function() error("injected wait failure") end,
                        }
                    end,
                }, function()
                    local result = strategy:run({ "tool" })
                    assert.is_true(result.started)
                    assert.is_false(result.ok)
                    assert.matches("partial output", result.diagnostic, 1, true)
                    assert.matches("injected wait failure", result.diagnostic,
                        1, true)
                end)
            end)
        end
    end)
end)

-- These host tests exercise dispatch and result contracts. The Windows shell
-- representation itself is gated separately by the real native argv oracle.
describe("Windows synchronous compiler I/O", function()
    it("renders configured worker argv without resolving or changing the executable", function()
        local command, executable = platform.windows_process_command({
            "clang", "", "two words", 'quote"inside', [[C:\trailing\]],
            "%PATH% !PATH! &|<>()^", "日本語 😀",
        })
        assert.equal("clang", executable)
        assert.equal([["clang" "" "two words" "quote\"inside" "C:\trailing\\" "%PATH% !PATH! &|<>()^" "日本語 😀"]], command)
        local argument = string.rep("x", 9000)
        assert.equal('"clang.exe" "' .. argument .. '"',
            platform.windows_process_command({ "clang.exe", argument }))
        for _, executable_name in ipairs({ "missing.exe", "clang.bat", "clang.cmd" }) do
            assert.equal(executable_name,
                select(2, platform.windows_process_command({ executable_name })))
        end
    end)

    it("rejects malformed argument arrays before process creation", function()
        for _, case in ipairs({
            { false, "nonempty argument array" },
            { {}, "nonempty argument array" },
            { { "clang.exe", false }, "must be a string" },
            { { "clang.exe", "bad\0argument" }, "NUL byte" },
            { { "clang.exe", extra = "value" }, "dense argument array" },
        }) do
            local command, err = platform.windows_process_command(case[1])
            assert.is_nil(command)
            assert.matches(case[2], err, 1, true)
        end
    end)

    coarse_stat_it("uses LuaFileSystem metadata and lexical existing paths on Windows", function()
        local attributes = { mode = "file", permissions = "rw-rw-rw-",
            size = 4294967419, dev = 7, ino = 0, modification = 1790816523 }
        local metadata = { kind = "file", mode = 0x81B6, size = 4294967419,
            modified_seconds = 1790816523, modified_nanoseconds = 0,
            time_precision = "coarse", precision = "coarse" }
        local calls = {}
        local function query(name, path)
            calls[#calls + 1] = { name, path }
            if path == "symlink" and name == "lstat" then
                return { mode = "link", permissions = "---------", size = 0,
                    modification = attributes.modification }
            end
            if path == "absent" then return nil, "not found", 2 end
            if path == "absent-parent/child" then return nil, "not found", 2 end
            if path == "denied" then return nil, "access denied", 13 end
            return attributes
        end
        with_overrides(platform, { windows = true }, function()
            with_overrides(lfs, {
                attributes = function(path) return query("stat", path) end,
                symlinkattributes = function(path, field)
                    assert.is_string(field)
                    if path == "absent" then return nil, "No error", 0 end
                    if path == "denied" then return nil, "stale errno", 2 end
                    local attributes, err, code = query("lstat", path)
                    return attributes and attributes[field], err, code
                end,
                currentdir = function() return "C:/work" end,
            }, function()
                local strategy = compiler_io.new_sync()
                assert.same(metadata, strategy:stat("file"))
                assert.same(metadata, strategy:lstat("file"))
                assert.same({ "stat", "file" }, calls[1])
                assert.same({ "lstat", "file" }, calls[2])
                assert.equal("symlink", assert(strategy:lstat("symlink")).kind)
                assert.equal(paths.normalize("C:/owned/file"),
                    strategy:realpath([[C:\owned\child\..\file]]))
                for _, path in ipairs({ "absent", "absent-parent/child" }) do
                    local absent, err = strategy:stat(path)
                    assert.is_nil(absent); assert.is_nil(err)
                    absent, err = strategy:lstat(path)
                    assert.is_nil(absent); assert.is_nil(err)
                    local canonical, canonical_err = strategy:realpath(path)
                    assert.is_nil(canonical)
                    assert.matches("does not exist", canonical_err, 1, true)
                end
                local absent, err = strategy:stat("denied")
                assert.is_nil(absent); assert.equal("access denied", err)
                absent, err = strategy:lstat("denied")
                assert.is_nil(absent); assert.equal("access denied", err)
            end)
        end)
    end)

    it("passes Windows argv and options directly to the process dependency", function()
        local process = require "titan-compiler.process"
        local argv = { "clang", "file with spaces.c", 'quote"inside',
            "%PATH% !PATH!", "line\nbreak", string.rep("x", 9000) }
        local options = { stderr_to_stdout = false }
        local expected = { started = true, ok = false, status = 256,
            why = "exit", interrupted = false, output = "A\r\nB\0C\26D\255" }
        with_overrides(platform, { windows = true }, function()
            with_overrides(process, { capture = function(actual, settings)
                assert.same(argv, actual)
                assert.equal(options, settings)
                return expected
            end }, function()
                assert.equal(expected, compiler_io.new_sync():run(argv, options))
            end)
        end)
    end)

    it("reserves beside the destination and cleans up a failed replacement", function()
        local root = workspace()
        local path = root .. "/existing.bin"
        local temporary_directory = root .. "/temporary"
        assert(lfs.mkdir(temporary_directory))
        local temporary_path = temporary_directory .. "/reserved.tmp"
        local sibling = paths.join(root, "reserved.tmp")
        local old = assert(io.open(path, "wb"))
        assert(old:write("old contents")); assert(old:close())
        local calls = {}
        local ok, failure = pcall(function()
            with_overrides(platform, { windows = true }, function()
                local strategy = compiler_io.new_sync()
                strategy.tmpname = function()
                    local file = assert(io.open(temporary_path, "wb"))
                    assert(file:close())
                    return temporary_path
                end
                with_overrides(os, { rename = function(from, to)
                    calls[#calls + 1] = { from, to }
                    assert.equal(sibling, from)
                    assert.equal(path, to)
                    return nil, "replacement denied"
                end }, function()
                    local written, err = strategy:write_file(path, "new contents")
                    assert.is_nil(written)
                    assert.equal("replacement denied", err)
                    assert.is_nil(lfs.attributes(path))
                    assert.is_nil(lfs.attributes(temporary_path))
                    assert.is_nil(lfs.attributes(sibling))
                    assert.same({ { sibling, path } }, calls)
                end)
            end)
        end)
        remove_tree(root)
        assert.is_true(ok, failure)
    end)
end)

-- The stock optional batch capability over the shared native scheduler.
describe("synchronous compiler I/O batches", function()
    local jobs = require "titan-compiler.jobs"
    local cdriver = require "c-parser.cdriver"
    local root

    after_each(function()
        if root then remove_tree(root); root = nil end
    end)

    -- The fixtures model a titanc run without a parent Make, whatever Make
    -- runs this spec, unless a test supplies its own MAKEFLAGS.
    local function under_make(makeflags, body)
        local getenv = platform.getenv
        return with_overrides(platform, {
            getenv = function(name)
                if name == "MAKEFLAGS" then return makeflags end
                return getenv(name)
            end,
        }, body)
    end

    local function script(text) return { "sh", "-c", text } end

    -- No ledger is left behind: a fresh signal guard can be installed.
    local function assert_guard_restored()
        if platform.windows then return end
        local guard = assert(require("titan")._signal_guard())
        assert.is_nil(guard:restore())
    end

    it("returns run's result for each command in input order", function()
        under_make(nil, function()
            local strategy = compiler_io.new_sync()
            local commands = {
                script("printf a; printf b >&2; printf c; exit 3"),
                script("printf accepted"),
                script("printf rejected >&2; exit 1"),
            }
            local results, cancelled = strategy:run_batch(commands, { jobs = 2 })
            assert.is_nil(cancelled)
            assert.equal(#commands, #results)
            for index, argv in ipairs(commands) do
                local expected = strategy:run(argv)
                for _, field in ipairs({
                    "started", "ok", "status", "why", "interrupted", "output",
                    "diagnostic",
                }) do
                    assert.same(expected[field], results[index][field],
                        index .. ": " .. field)
                end
            end
            -- Standard output and error share one log, in write order.
            assert.equal("abc", results[1].output)
            assert.equal(3, results[1].status)
            assert_guard_restored()
        end)
    end)

    it("answers invalid and empty argv without opening a ledger", function()
        local opened = 0
        with_overrides(jobs, {
            open_slots = function()
                opened = opened + 1
                error("no ledger is needed")
            end,
        }, function()
            local results = compiler_io.new_sync():run_batch({
                {}, "tool", { [1] = "sh", extra = "argument" },
            }, { jobs = 4 })
            assert.same({ started = false, ok = false,
                diagnostic = "command is empty" }, results[1])
            assert.is_false(results[2].started)
            assert.matches("argument array", results[2].diagnostic, 1, true)
            assert.is_false(results[3].started)
            assert.matches("dense argument array", results[3].diagnostic, 1, true)
        end)
        assert.equal(0, opened)
        assert.error_matches(function()
            compiler_io.new_sync():run_batch({ script("true") }, { jobs = 0 })
        end, "positive integer jobs bound", 1, true)
    end)

    it("runs a single command or a single granted slot in order through run",
    function()
        -- Windows batches apply only the local cap, so a serial parent Make
        -- does not reduce them to one slot there; the two commands then take
        -- the native batch.
        for _, case in ipairs({
            { makeflags = nil, jobs = 1, count = 2, serial = true },
            { makeflags = "-j1", jobs = 4, count = 2, serial = not platform.windows },
            { makeflags = nil, jobs = 4, count = 1, serial = true },
        }) do
            under_make(case.makeflags, function()
                local strategy = compiler_io.new_sync()
                local ran = {}
                function strategy:run(argv, options)
                    ran[#ran + 1] = argv[3]
                    return compiler_io.new_sync():run(argv, options)
                end
                local commands = {}
                for index = 1, case.count do
                    commands[index] = script("printf " .. index)
                end
                local results = strategy:run_batch(commands, { jobs = case.jobs })
                assert.equal(case.serial and case.count or 0, #ran)
                for index = 1, case.count do
                    if case.serial then assert.equal("printf " .. index, ran[index]) end
                    assert.is_true(results[index].ok)
                    assert.equal(tostring(index), results[index].output)
                end
                assert_guard_restored()
            end)
        end
    end)

    posix_model_it("forwards coordinator leases to every parallel captured child", function()
        root = workspace()
        local strategy, leases = compiler_io.new_sync(), { 17, 41 }
        strategy._process_inherit = leases
        local channel, launches, logs = {}, {}, 0
        function strategy:tmpname()
            logs = logs + 1
            local filename = root .. "/capture-" .. logs
            local file = assert(io.open(filename, "wb"))
            assert(file:close())
            return filename
        end
        local results = with_overrides(jobs, {
            open_slots = function()
                return { limit = 2, close = function() return true end,
                    cancelled = function() return nil end }
            end,
            open_channel = function() return channel end,
            close_channel = function(actual)
                assert.equal(channel, actual)
                return true
            end,
            launch = function(actual, argv, _, stdout, stderr, index, before_start, options)
                assert.equal(channel, actual)
                assert.equal(stdout, stderr)
                assert.is_nil(before_start)
                assert.equal(leases, options.inherit)
                launches[index] = argv
                local file = assert(io.open(stdout, "wb"))
                assert(file:write("child " .. index))
                assert(file:close())
                return { ok = true, term = "exit", code = 0, finish_errors = {} }
            end,
            drive = function(_, actual, count, launch)
                assert.equal(channel, actual)
                for index = 1, count do assert(launch(index)) end
                return count + 1
            end,
        }, function()
            return strategy:run_batch({ { "first-tool" }, { "second-tool" } }, { jobs = 2 })
        end)
        assert.same({ { "first-tool" }, { "second-tool" } }, launches)
        for index = 1, 2 do
            assert.is_true(results[index].ok, results[index].diagnostic)
            assert.equal("child " .. index, results[index].output)
            assert.is_nil(lfs.attributes(root .. "/capture-" .. index))
        end
    end)

    it("keeps no launched result usable after a transport or cleanup failure",
    function()
        local function faulted(fault, count)
            local overrides = {}
            local original_open = jobs.open_slots
            if fault == "release" or fault == "close" then
                overrides.open_slots = function(...)
                    local slots, err = original_open(...)
                    if not slots then return nil, err end
                    local method = slots[fault]
                    slots[fault] = function(self)
                        method(self)
                        return nil, "injected " .. fault .. " failure"
                    end
                    return slots
                end
            elseif fault == "channel" then
                local close_channel = jobs.close_channel
                overrides.close_channel = function(channel)
                    close_channel(channel)
                    return nil, "injected channel failure"
                end
            else
                local protected_remove = jobs.protected_remove
                overrides.protected_remove = function(path)
                    local removed, err = protected_remove(path)
                    if not removed then return removed, err end
                    return nil, "injected log failure"
                end
            end
            local commands = {}
            for index = 1, count do commands[index] = script("printf child" .. index) end
            local results = under_make(nil, function()
                return with_overrides(jobs, overrides, function()
                    return compiler_io.new_sync():run_batch(commands, { jobs = 2 })
                end)
            end)
            for index = 1, count do
                local result = results[index]
                -- The child launched and its output stays visible, but no
                -- completed status survives as semantic evidence.
                assert.is_true(result.started, fault)
                assert.is_false(result.ok, fault)
                assert.is_nil(result.status, fault)
                assert.matches("the native C probe batch failed: ",
                    result.diagnostic, 1, true)
                assert.matches("injected " .. fault .. " failure",
                    result.diagnostic, 1, true)
                assert.matches("child" .. index, result.diagnostic, 1, true)
            end
            assert_guard_restored()
        end
        for _, fault in ipairs({ "release", "close", "channel", "log" }) do
            faulted(fault, 2)
        end
        -- The one-command branch runs through `run` without a channel.
        faulted("close", 1)
    end)

    describe("cancellation", function()
        if platform.windows then
            it("is exercised with the POSIX completion channel", function()
                pending("Windows batches have no channel reservation or signal guard")
            end)
            return
        end

        local cancellation = setmetatable({}, {
            __tostring = function() return "injected strategy cancellation" end,
        })
        local holder

        after_each(function()
            if holder then holder:close(); holder = nil end
        end)

        local function quote(text) return assert(cdriver.shell_quote(text)) end

        -- A parent GNU Make FIFO jobserver holding `bytes`.
        local function pool(bytes)
            root = workspace()
            local fifo = root .. "/pool"
            assert(os.execute("mkfifo -m 600 " .. quote(fifo)))
            holder = assert(io.open(fifo, "r+"))
            assert(holder:setvbuf("no"))
            assert(holder:write(bytes))
            return fifo
        end

        local function available(fifo)
            local client = assert(require("titan")._jobserver_open("fifo", fifo))
            local count = 0
            while assert(client:acquire() ~= nil) and client:held() > count do
                count = count + 1
            end
            assert(client:close())
            return count
        end

        -- Runs `commands` at a local cap of four under a three-byte parent
        -- pool, recording the ledger, each reap and slot release, and every
        -- path the strategy reserved.
        local function cancelled_batch(strategy, commands)
            local fifo = pool("abc")
            local events, reserved, ledger = {}, {}, nil
            local tmpname = strategy.tmpname
            strategy.tmpname = function(self)
                local path, err = tmpname(self)
                reserved[#reserved + 1] = path
                return path, err
            end
            local open_slots, reap = jobs.open_slots, jobs.reap
            local called, raised = under_make("-j4 --jobserver-auth=fifo:" .. fifo,
                function()
                    return with_overrides(jobs, {
                        open_slots = function(...)
                            local slots, err = open_slots(...)
                            ledger = slots
                            if slots then
                                local release = slots.release
                                slots.release = function(self)
                                    events[#events + 1] = "release"
                                    return release(self)
                                end
                            end
                            return slots, err
                        end,
                        reap = function(process)
                            events[#events + 1] = "reap"
                            return reap(process)
                        end,
                    }, function()
                        return pcall(strategy.run_batch, strategy, commands, { jobs = 4 })
                    end)
                end)
            assert.is_false(called)
            assert.equal(cancellation, raised)
            -- The ledger returned every token and restored the signal actions.
            assert.is_nil(ledger.client)
            assert.is_nil(ledger.guard)
            assert_guard_restored()
            assert.equal(3, available(fifo))
            -- The completion FIFO and every log are gone.
            for _, path in ipairs(reserved) do
                assert.is_nil(lfs.attributes(path), path)
            end
            return events, reserved
        end

        it("rethrows a raised channel reservation before any launch", function()
            local strategy = compiler_io.new_sync()
            local reservations = 0
            local tmpname = strategy.tmpname
            strategy.tmpname = function(self)
                reservations = reservations + 1
                if reservations == 1 then error(cancellation) end
                return tmpname(self)
            end
            local events = cancelled_batch(strategy,
                { script("printf one"), script("printf two") })
            assert.same({}, events)
        end)

        it("reaps an earlier live child before it rethrows a raised log reservation",
        function()
            local strategy = compiler_io.new_sync()
            local reservations = 0
            local tmpname = strategy.tmpname
            strategy.tmpname = function(self)
                reservations = reservations + 1
                if reservations == 3 then error(cancellation) end
                return tmpname(self)
            end
            local events, reserved = cancelled_batch(strategy, {
                script("sleep 0.3; printf one"), script("printf two"),
                script("printf three"),
            })
            -- The second command's slot (a borrowed token) is released at
            -- once; the first child is reaped before its implicit slot is.
            assert.same({ "release", "reap", "release" }, events)
            -- The completion FIFO and the first child's log.
            assert.equal(2, #reserved)
        end)

        it("rethrows a raised one-command run after closing the ledger", function()
            local strategy = compiler_io.new_sync()
            function strategy:run() error(cancellation) end
            local events, reserved = cancelled_batch(strategy, { script("printf one") })
            assert.same({}, events)
            assert.same({}, reserved)
        end)

        it("removes every log before it rethrows a raised log read", function()
            local strategy = compiler_io.new_sync()
            local reads = 0
            local read_file = strategy.read_file
            strategy.read_file = function(self, ...)
                reads = reads + 1
                if reads == 1 then error(cancellation) end
                return read_file(self, ...)
            end
            local events, reserved = cancelled_batch(strategy,
                { script("printf one"), script("printf two") })
            assert.same({ "reap", "release", "reap", "release" }, events)
            assert.equal(3, #reserved)
            assert.equal(2, reads)
        end)
    end)
end)
