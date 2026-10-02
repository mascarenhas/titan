local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"

local function remove_tree(path)
    local attributes = lfs.symlinkattributes(path)
    if not attributes then return end
    if attributes.mode ~= "directory" then
        os.remove(path)
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            remove_tree(path .. "/" .. entry)
        end
    end
    lfs.rmdir(path)
end

local function workspace()
    local path = assert(os.tmpname()) .. "-compiler-io"
    os.remove(path)
    assert(lfs.mkdir(path))
    return path
end

local function with_overrides(target, replacements, body)
    local originals = {}
    for name, replacement in pairs(replacements) do
        originals[name] = target[name]
        target[name] = replacement
    end
    local results = table.pack(pcall(body))
    for name, original in pairs(originals) do
        target[name] = original
    end
    assert.is_true(results[1], results[2])
    return table.unpack(results, 2, results.n)
end

describe("compiler I/O strategy", function()
    local root

    teardown(function()
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

        local original_rename = os.rename
        os.rename = function()
            return nil, "injected atomic rename failure"
        end
        local called, replaced, replace_err = pcall(
            strategy.write_file, strategy, source, "replacement")
        os.rename = original_rename
        assert.is_true(called, replaced)
        assert.is_nil(replaced)
        assert.matches("injected atomic rename failure", replace_err, 1, true)
        assert.equal(bytes, assert(strategy:read_file(source)))

        local metadata = assert(strategy:stat(source))
        assert.same({
            "device", "inode", "kind", "mode", "modified_nanoseconds",
            "modified_seconds", "size",
        }, (function()
            local keys = {}
            for key in pairs(metadata) do keys[#keys + 1] = key end
            table.sort(keys)
            return keys
        end)())
        assert.equal("file", metadata.kind)
        assert.equal(#bytes, metadata.size)
        assert.equal(0x8000, metadata.mode & 0xF000)
        assert.is_number(metadata.device)
        assert.is_number(metadata.inode)
        assert.is_number(metadata.modified_seconds)
        assert.is_number(metadata.modified_nanoseconds)
        assert.is_true(metadata.modified_nanoseconds >= 0)
        assert.is_true(metadata.modified_nanoseconds < 1000000000)

        local hard_link = directory .. "/source-hard-link.bin"
        assert(lfs.link(source, hard_link))
        local hard_link_metadata = assert(strategy:stat(hard_link))
        assert.equal(metadata.device, hard_link_metadata.device)
        assert.equal(metadata.inode, hard_link_metadata.inode)
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
        root = workspace()
        local strategy = compiler_io.new_sync()
        local target = root .. "/target"
        assert.is_true(strategy:write_file(target, "target bytes"))
        local link = root .. "/link"
        local linked = strategy:run({ "ln", "-s", target, link })
        assert.is_true(linked.ok, linked.diagnostic)

        assert.equal("file", assert(strategy:stat(link)).kind)
        assert.equal("symlink", assert(strategy:lstat(link)).kind)
        assert.equal(assert(strategy:realpath(target)),
            assert(strategy:realpath(link)))

        local actual = root .. "/actual"
        local nested = actual .. "/nested"
        assert.is_true(strategy:mkdir(actual))
        assert.is_true(strategy:mkdir(nested))
        local sibling = actual .. "/sibling"
        assert.is_true(strategy:write_file(sibling, "sibling bytes"))
        local directory_link = root .. "/directory-link"
        linked = strategy:run({ "ln", "-s", "actual/nested", directory_link })
        assert.is_true(linked.ok, linked.diagnostic)
        assert.equal(assert(strategy:realpath(sibling)),
            assert(strategy:realpath(directory_link .. "/../sibling")))

        local dangling = root .. "/dangling"
        linked = strategy:run({ "ln", "-s", root .. "/missing", dangling })
        assert.is_true(linked.ok, linked.diagnostic)
        local followed, followed_err = strategy:stat(dangling)
        assert.is_nil(followed)
        assert.is_nil(followed_err)
        assert.equal("symlink", assert(strategy:lstat(dangling)).kind)
        local canonical, canonical_err = strategy:realpath(dangling)
        assert.is_nil(canonical)
        assert.matches("does not exist", canonical_err, 1, true)
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
        assert.matches("2>&1$", success.command)

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
        assert.equal("exit", missing.why)
        assert.equal(127, missing.status)
        assert.is_false(missing.interrupted)

        local signalled = strategy:run({
            "sh", "-c", "kill -TERM $$",
        })
        assert.is_true(signalled.started)
        assert.is_false(signalled.ok)
        assert.equal("signal", signalled.why)
        assert.equal(15, signalled.status)
        assert.equal(15, signalled.signal)
        assert.equal(143, signalled.shell_status)
        assert.is_true(signalled.interrupted)

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
        assert.matches("cannot unlink directory", err, 1, true)

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

    it("normalizes uncommon metadata and realpath failures", function()
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
end)

-- These host tests exercise dispatch and result contracts. The Windows shell
-- representation itself is gated separately by the real native argv oracle.
describe("Windows synchronous compiler I/O", function()
    it("preserves opaque file IDs and distinguishes missing from query errors", function()
        local metadata = { kind = "file", mode = 0x8000, size = 4294967419,
            device = "win32-volume:fffffffffffffffe",
            inode = "win32-file:ffffffffffffffff0000000000000001",
            modified_seconds = 1790816523, modified_nanoseconds = 123456700 }
        local calls = {}
        with_overrides(platform, { windows = true, native = function(name, path, follow)
            calls[#calls + 1] = { name, path, follow }
            if path == "absent" then return nil, "not found", 2 end
            if path == "absent-parent/child" then return nil, "not found", 3 end
            if path == "denied" then return nil, "access denied", 5 end
            if path == "junction" then return nil, "untrusted mount point", 448 end
            if name == "_win_realpath" then return [[\\?\C:\owned\file]] end
            return metadata
        end }, function()
            local strategy = compiler_io.new_sync()
            assert.equal(metadata, strategy:stat("file"))
            assert.equal(metadata, strategy:lstat("file"))
            assert.same({ "_win_stat", "file", true }, calls[1])
            assert.same({ "_win_stat", "file", false }, calls[2])
            assert.equal([[\\?\C:\owned\file]], strategy:realpath("file"))
            for _, path in ipairs({ "absent", "absent-parent/child" }) do
                local attributes, err = strategy:stat(path)
                assert.is_nil(attributes); assert.is_nil(err)
            end
            local attributes, err = strategy:stat("denied")
            assert.is_nil(attributes); assert.equal("access denied", err)
            attributes, err = strategy:stat("junction")
            assert.is_nil(attributes); assert.equal("untrusted mount point", err)
        end)
    end)

    it("captures binary output and preserves native exit statuses", function()
        with_overrides(platform, { windows = true, native = function(name, path)
            assert.equal("_win_resolve_executable", name)
            if path == "missing-native-command.exe" then
                return nil, "executable not found", 2
            end
            return "C:/tools/" .. path
        end }, function()
            local status = 143
            with_overrides(io, { popen = function(command, mode)
                assert.equal("rb", mode)
                assert.matches('set "LANG=C"&&set "LC_ALL=C"&&', command, 1, true)
                return {
                    read = function() return "A\r\nB\0C\26D\255" end,
                    close = function() return nil, "exit", status end,
                }
            end }, function()
                local strategy = compiler_io.new_sync()
                local result = strategy:run({ "clang.exe", "-c", "file with spaces.c" })
                assert.is_true(result.started)
                assert.is_false(result.ok)
                assert.equal("exit", result.why)
                assert.equal(143, result.status)
                assert.is_false(result.interrupted)
                assert.is_nil(result.signal)
                assert.is_nil(result.shell_status)
                assert.equal("A\r\nB\0C\26D\255", result.output)

                for _, code in ipairs({ 1, 126, 127, 9009 }) do
                    status = code
                    result = strategy:run({ "clang.exe" })
                    assert.is_true(result.started)
                    assert.is_false(result.ok)
                    assert.equal(code, result.status)
                    assert.equal("exit", result.why)
                    assert.is_false(result.interrupted)
                end

                status = 9009
                result = strategy:run({ "missing-native-command.exe" })
                assert.is_false(result.started)
                assert.is_false(result.ok)
                assert.is_nil(result.status)
                assert.equal("executable not found", result.diagnostic)
            end)
        end)
    end)

    it("rejects unsafe command representations before opening a pipe", function()
        with_overrides(platform, { windows = true, native = function(name, path)
            assert.equal("_win_resolve_executable", name)
            if path == "missing-native-command.exe" then
                return nil, "executable not found", 2
            end
            return "C:/tools/" .. path
        end }, function()
            with_overrides(io, { popen = function()
                error("invalid command reached the shell")
            end }, function()
                local strategy = compiler_io.new_sync()
                for _, argv in ipairs({
                    { "clang.exe", "line\nbreak" },
                    { "clang.exe", "line\rbreak" },
                    { "clang.exe", "invalid\255UTF-8" },
                    { "wrapper.cmd", "argument" },
                    { "wrapper.BAT", "argument" },
                    { "wrapper.ps1", "argument" },
                    { "", "argument" },
                    { "clang.exe", string.rep("x", 8192) },
                }) do
                    local result = strategy:run(argv)
                    assert.is_false(result.started)
                    assert.is_false(result.ok)
                    assert.is_string(result.diagnostic)
                    assert.is_nil(result.command)
                end
            end)
        end)
    end)

    it("reserves beside the destination and preserves it on replacement failure", function()
        local root = workspace()
        local path = root .. "/existing.bin"
        local temporary = root .. "/reserved.tmp"
        local old = assert(io.open(path, "wb"))
        assert(old:write("old contents")); assert(old:close())
        local calls = {}
        local ok, failure = pcall(function()
            with_overrides(platform, {
                windows = true,
                native = function(name, first, second)
                    calls[#calls + 1] = { name, first, second }
                    if name == "_win_reserve_sibling" then
                        assert.equal(path, first)
                        local file = assert(io.open(temporary, "wb"))
                        assert(file:close())
                        return temporary
                    elseif name == "_win_replace" then
                        assert.equal(temporary, first)
                        assert.equal(path, second)
                        return nil, "replacement denied"
                    end
                    error("unexpected native operation " .. name)
                end,
            }, function()
                local strategy = compiler_io.new_sync()
                local written, err = strategy:write_file(path, "new contents")
                assert.is_nil(written)
                assert.equal("replacement denied", err)
                assert.equal("old contents", assert(strategy:read_file(path)))
                assert.is_nil(lfs.attributes(temporary))
                assert.equal(2, #calls)
            end)
        end)
        remove_tree(root)
        assert.is_true(ok, failure)
    end)
end)
