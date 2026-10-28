local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"

local compiler_io = {}

local lua_io = io
local lua_os = os

local REQUIRED_METHODS = {
    "cwd",
    "realpath",
    "stat",
    "lstat",
    "readable",
    "read_file",
    "write_file",
    "list",
    "mkdir",
    "unlink",
    "rmdir",
    "rename",
    "tmpname",
    "run",
    "yield",
}

local Sync = {}
Sync.__index = Sync

local function checked_path(path)
    if type(path) ~= "string" then
        return nil, "path must be a string"
    elseif path:find("\0", 1, true) then
        return nil, "path contains a NUL byte"
    end
    return path
end

local function operation_error(operation, err)
    if err == nil or err == "" then
        return operation .. " failed"
    end
    return tostring(err)
end

local function missing_errno(code)
    -- LuaFileSystem reports the platform errno as its third failure result.
    -- Titan's supported POSIX targets use 2 for ENOENT. Keep ENOTDIR and
    -- permission failures observable rather than collapsing every failed
    -- lookup into an absent path.
    return code == 2
end

local function windows_link_attributes(path)
    -- The table form tries to resolve directory targets and can throw in LFS.
    -- Scalar queries also preserve metadata for dangling links.
    -- Ordinary stat supplies reliable errno for failed lookups.
    local mode = lfs.symlinkattributes(path, "mode")
    if mode ~= "link" then return lfs.attributes(path) end
    return {
        mode = mode,
        permissions = lfs.symlinkattributes(path, "permissions"),
        size = lfs.symlinkattributes(path, "size"),
        modification = lfs.symlinkattributes(path, "modification"),
    }
end

local function lfs_attributes(path, follow)
    local fn = follow and lfs.attributes or
        (platform.windows and windows_link_attributes or lfs.symlinkattributes)
    local called, attributes, err, code = pcall(fn, path)
    if not called then return nil, tostring(attributes) end
    if attributes then return attributes end
    if missing_errno(code) then return nil, nil end
    return nil, operation_error(follow and "stat" or "lstat", err)
end

local FILE_TYPE_BITS = {
    file = 0x8000,
    directory = 0x4000,
    link = 0xA000,
    socket = 0xC000,
    ["named pipe"] = 0x1000,
    ["char device"] = 0x2000,
    ["block device"] = 0x6000,
}

local KIND = {
    file = "file",
    directory = "directory",
    link = "symlink",
}

local function permission_bits(permissions)
    if type(permissions) ~= "string" then return 0 end

    local bits = 0
    local ordinary = {
        { 1, "r", 0x100 }, { 2, "w", 0x080 },
        { 4, "r", 0x020 }, { 5, "w", 0x010 },
        { 7, "r", 0x004 }, { 8, "w", 0x002 },
    }
    for _, entry in ipairs(ordinary) do
        if permissions:sub(entry[1], entry[1]) == entry[2] then
            bits = bits | entry[3]
        end
    end

    local owner_execute = permissions:sub(3, 3)
    if owner_execute == "x" or owner_execute == "s" then
        bits = bits | 0x040
    end
    if owner_execute == "s" or owner_execute == "S" then
        bits = bits | 0x800
    end

    local group_execute = permissions:sub(6, 6)
    if group_execute == "x" or group_execute == "s" then
        bits = bits | 0x008
    end
    if group_execute == "s" or group_execute == "S" then
        bits = bits | 0x400
    end

    local other_execute = permissions:sub(9, 9)
    if other_execute == "x" or other_execute == "t" then
        bits = bits | 0x001
    end
    if other_execute == "t" or other_execute == "T" then
        bits = bits | 0x200
    end
    return bits
end

local function normalized_stat(attributes)
    local modified = attributes.modification or 0
    local modified_seconds = math.floor(modified)
    local modified_nanoseconds = math.floor(
        (modified - modified_seconds) * 1000000000 + 0.5)
    if modified_nanoseconds >= 1000000000 then
        modified_seconds = modified_seconds + 1
        modified_nanoseconds = 0
    end

    return {
        size = attributes.size or 0,
        kind = KIND[attributes.mode] or "other",
        mode = (FILE_TYPE_BITS[attributes.mode] or 0) |
            permission_bits(attributes.permissions),
        -- These are opaque physical-file identity components. Consumers
        -- compare the pair only for equality; they must not interpret their
        -- numeric values.
        -- LuaFileSystem's Windows inode has no physical-file meaning.
        device = not platform.windows and attributes.dev or nil,
        inode = not platform.windows and attributes.ino or nil,
        modified_seconds = modified_seconds,
        modified_nanoseconds = modified_nanoseconds,
        -- LFS exposes floating seconds, not a declared native nanosecond clock.
        time_precision = "coarse",
        precision = "coarse",
    }
end

local tried_native_support = false

local function stat_attributes(path, follow)
    local support = package.loaded.titan
    if not support and not tried_native_support then
        tried_native_support = true
        local loaded, value = pcall(require, "titan")
        if loaded then support = value end
    end
    local precise = type(support) == "table" and support._stat_precise
    if type(precise) == "function" then
        local attributes, err, code = precise(path, follow)
        if not attributes then
            if missing_errno(code) then return nil, nil end
            return nil, operation_error(follow and "stat" or "lstat", err)
        end
        -- The native call owns this fresh result. Preserve its exact integer
        -- timestamps and opaque file IDs for certificate observations, while
        -- supplying the existing resolver/header fields from those same bytes.
        attributes.kind = attributes.kind == "link" and "symlink" or attributes.kind
        attributes.device, attributes.inode = attributes.dev, attributes.ino
        attributes.modified_seconds = attributes.mtime_ns // 1000000000
        attributes.modified_nanoseconds = attributes.mtime_ns % 1000000000
        attributes.changed_seconds = attributes.ctime_ns // 1000000000
        attributes.changed_nanoseconds = attributes.ctime_ns % 1000000000
        attributes.precision, attributes.time_precision = "ns", "ns"
        return attributes
    end
    local attributes, err = lfs_attributes(path, follow)
    if not attributes then return nil, err end
    return normalized_stat(attributes)
end

function Sync:cwd()
    local called, directory, err = pcall(lfs.currentdir)
    if not called then return nil, tostring(directory) end
    if not directory then return nil, operation_error("cwd", err) end
    return directory
end

function Sync:absolute(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    local cwd, err = self:cwd()
    if not cwd then return nil, err end
    local absolute, absolute_error = platform.absolute(path, cwd)
    if not absolute then return nil, absolute_error end
    return platform.windows and paths.normalize(absolute) or absolute
end

local function absolute_path(path, cwd)
    if path:sub(1, 1) == "/" then return path end
    if cwd == "/" then return "/" .. path end
    return cwd .. "/" .. path
end

local function path_parent(path)
    local parent, leaf = path:match("^(.*)/([^/]*)$")
    if not parent then return nil end
    if parent == "" then parent = "/" end
    return parent, leaf
end

-- Resolve an existing path without invoking a utility subprocess. LuaFileSystem
-- can expose a link target and can canonicalize an existing directory through
-- currentdir(), so peel non-directory leaves until one physical directory can
-- be entered, then append those leaves again. This is synchronous and contains
-- no callback/yield point; restoring the process-global cwd is therefore one
-- indivisible operation for ordinary titanc and its compiler tests.
local function resolve_existing_path(path, original_cwd)
    local candidate = absolute_path(path, original_cwd)
    local unresolved = {}
    local seen = {}
    local link_hops = 0

    while candidate and candidate ~= "" do
        if seen[candidate] then
            return nil, "too many levels of symbolic links while resolving '" ..
                path .. "'"
        end
        seen[candidate] = true

        local called, link, link_err = pcall(lfs.symlinkattributes, candidate)
        if not called then return nil, tostring(link) end
        if link and link.mode == "link" and link.target then
            link_hops = link_hops + 1
            if link_hops > 40 then
                return nil, "too many levels of symbolic links while resolving '" ..
                    path .. "'"
            end
            if link.target:sub(1, 1) == "/" then
                candidate = link.target
            else
                local parent = path_parent(candidate)
                if not parent then
                    return nil, "cannot resolve symbolic link '" .. path .. "'"
                end
                candidate = parent .. "/" .. link.target
            end
        else
            local changed, change_err = lfs.chdir(candidate)
            if changed then
                local resolved, current_err = lfs.currentdir()
                local restored, restore_err = lfs.chdir(original_cwd)
                if not restored then
                    return nil, operation_error("restore cwd", restore_err)
                elseif not resolved then
                    return nil, operation_error("realpath", current_err)
                end
                for _, component in ipairs(unresolved) do
                    resolved = (resolved == "/" and "/" or
                        resolved .. "/") .. component
                end
                return resolved
            end

            local parent, leaf = path_parent(candidate)
            if not parent or leaf == "" then
                return nil, operation_error("realpath", link_err or change_err)
            end
            table.insert(unresolved, 1, leaf)
            candidate = parent
        end
    end
    return nil, "cannot resolve path '" .. path .. "'"
end

function Sync:realpath(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end

    local attributes, attribute_err = lfs_attributes(path, true)
    if not attributes then
        return nil, attribute_err or ("path does not exist: " .. path)
    end
    -- Windows uses lexical paths; LuaFileSystem supplies the existence check.
    if platform.windows then return self:absolute(path) end
    local cwd, cwd_err = self:cwd()
    if not cwd then return nil, cwd_err end
    return resolve_existing_path(path, cwd)
end

function Sync:stat(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    return stat_attributes(path, true)
end

function Sync:lstat(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    return stat_attributes(path, false)
end

local function open_file(path, mode)
    local called, file, err = pcall(lua_io.open, path, mode)
    if not called then return nil, tostring(file) end
    if not file then return nil, operation_error("open", err) end
    return file
end

function Sync:readable(path)
    local valid = checked_path(path)
    if not valid then return false end
    local file = open_file(path, "rb")
    if not file then return false end
    pcall(file.close, file)
    return true
end

-- Optional strategy capability: effective POSIX X_OK, not file readability.
-- Tool selection must fail closed when a strategy cannot supply this query.
function Sync:executable(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    local support = require "titan"
    if type(support) ~= "table" or type(support._executable_access) ~= "function" then
        return nil, "installed Titan native support lacks _executable_access; reinstall Titan"
    end
    return support._executable_access(path)
end

-- Optional strategy capability: match libuv's Windows CWD search policy.
function Sync:executable_search_cwd()
    local support = require "titan"
    if type(support) ~= "table" or
       type(support._executable_search_cwd) ~= "function" then
        return nil, "installed Titan native support lacks _executable_search_cwd; reinstall Titan"
    end
    return support._executable_search_cwd()
end

function Sync:read_file(path, max_bytes)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if max_bytes ~= nil and
       (type(max_bytes) ~= "number" or max_bytes < 0 or
        max_bytes % 1 ~= 0 or max_bytes >= math.maxinteger) then
        return nil, "read limit must be a nonnegative integer"
    end
    local file, open_err = open_file(path, "rb")
    if not file then return nil, open_err end

    -- Read one byte beyond the caller's bound so it can distinguish a file at
    -- the limit from a file which grew after stat, without ever materializing
    -- an unbounded replacement.
    local amount = max_bytes ~= nil and max_bytes + 1 or "a"
    local read_ok, contents, read_err = pcall(file.read, file, amount)
    local close_ok, closed, close_err = pcall(file.close, file)
    if not read_ok then return nil, tostring(contents) end
    if contents == nil and read_err == nil and max_bytes ~= nil then
        contents = ""
    end
    if not contents then return nil, operation_error("read", read_err) end
    if not close_ok then return nil, tostring(closed) end
    if not closed then return nil, operation_error("close", close_err) end
    return contents
end

-- Optional strategy capability: feed a file's bytes, in order, into the
-- incremental digest `stream` without materializing the whole file, and
-- return the total byte count. A native stream absorbs the open file through
-- one fixed buffer; any other stream receives chunks of at most
-- ABSORB_CHUNK_BYTES through `stream:update(bytes)`. Strategies without this
-- capability are read whole. A stream error propagates unchanged once the
-- file is closed.
local ABSORB_CHUNK_BYTES = 1024 * 1024

function Sync:absorb_file(path, stream)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    -- Resolve the stream's methods before a handle exists, so a raising
    -- lookup cannot strand an open file.
    local absorb = stream.absorb
    local update = absorb == nil and stream.update or nil
    local file, open_err = open_file(path, "rb")
    if not file then return nil, open_err end
    local function rethrow(err)
        pcall(file.close, file)
        error(err, 0)
    end
    local total, failure = 0, nil
    if absorb ~= nil then
        local absorbed, count, absorb_err = pcall(absorb, stream, file)
        if not absorbed then rethrow(count) end
        if count == nil then failure = operation_error("read", absorb_err) end
        total = count
    else
        while true do
            local read_ok, chunk, read_err = pcall(file.read, file, ABSORB_CHUNK_BYTES)
            if not read_ok then
                failure = tostring(chunk)
                break
            elseif chunk == nil then
                if read_err ~= nil then failure = operation_error("read", read_err) end
                break
            end
            total = total + #chunk
            local updated, update_err = pcall(update, stream, chunk)
            if not updated then rethrow(update_err) end
        end
    end
    local close_ok, closed, close_err = pcall(file.close, file)
    if failure then return nil, failure end
    if not close_ok then return nil, tostring(closed) end
    if not closed then return nil, operation_error("close", close_err) end
    return total
end

local function write_file_direct(path, contents)
    local file, open_err = open_file(path, "wb")
    if not file then return nil, open_err end

    local write_ok, written, write_err = pcall(file.write, file, contents)
    local close_ok, closed, close_err = pcall(file.close, file)
    if not write_ok then return nil, tostring(written) end
    if not written then return nil, operation_error("write", write_err) end
    if not close_ok then return nil, tostring(closed) end
    if not closed then return nil, operation_error("close", close_err) end
    return true
end

function Sync:write_file(path, contents)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if type(contents) ~= "string" then
        return nil, "file contents must be a string"
    end

    -- Reserve a process-unique basename through Lua's tmpname contract, then
    -- move that identity beside the destination. Write and close the sibling
    -- before publishing its complete contents.
    local temporary
    if platform.windows then
        local reserve_err
        temporary, reserve_err = self:reserve_sibling(path)
        if not temporary then return nil, reserve_err end
    else
        local reservation, reservation_err = self:tmpname()
        if not reservation then return nil, reservation_err end
        local removed, remove_err = self:unlink(reservation)
        if not removed then return nil, remove_err end
        local unique = reservation:match("([^/]+)$") or reservation
        temporary = path .. "." .. unique .. ".tmp"
    end

    local written, write_err = write_file_direct(temporary, contents)
    if not written then
        self:unlink(temporary)
        return nil, write_err
    end
    local renamed, rename_err = self:rename(temporary, path)
    if not renamed then
        self:unlink(temporary)
        return nil, rename_err
    end
    return true
end

function Sync:list(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    local opened, iterator, state = pcall(lfs.dir, path)
    if not opened then return nil, tostring(iterator) end
    if not iterator then return nil, operation_error("list", state) end

    local collected, entries = pcall(function()
        local result = {}
        for entry in iterator, state do
            if entry ~= "." and entry ~= ".." then
                result[#result + 1] = entry
            end
        end
        return result
    end)
    if not collected then return nil, tostring(entries) end
    return entries
end

local function call_mutation(operation, fn, ...)
    local called, result, err = pcall(fn, ...)
    if not called then return nil, tostring(result) end
    if not result then return nil, operation_error(operation, err) end
    return true
end

function Sync:mkdir(path, _remove_if_cancelled)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    return call_mutation("mkdir", lfs.mkdir, path)
end

function Sync:unlink(path, _remove_if_cancelled)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    local attributes = lfs_attributes(path, false)
    if attributes and attributes.mode == "directory" then
        return nil, "cannot unlink directory '" .. path .. "'"
    end
    return call_mutation("unlink", lua_os.remove, path)
end

function Sync:rmdir(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    return call_mutation("rmdir", lfs.rmdir, path)
end

function Sync:rename(from, to)
    local valid_from, from_err = checked_path(from)
    if not valid_from then return nil, from_err end
    local valid_to, to_err = checked_path(to)
    if not valid_to then return nil, to_err end
    if platform.windows and lfs.symlinkattributes(to, "mode") then
        -- Windows' ordinary rename does not replace an existing destination.
        local removed, remove_err = call_mutation("unlink", lua_os.remove, to)
        if not removed then return nil, remove_err end
    end
    return call_mutation("rename", lua_os.rename, from, to)
end

function Sync:tmpname()
    local called, path, err = pcall(lua_os.tmpname)
    if not called then return nil, tostring(path) end
    if not path then return nil, operation_error("tmpname", err) end
    if platform.windows then
        -- Windows tmpnam chooses a name without creating it. Keep that name in
        -- the user's temporary directory and reserve the caller-owned file.
        local directory = platform.getenv("TEMP") or platform.getenv("TMP")
        if directory then path = paths.join(directory, paths.basename(path)) end
        local file, open_err = open_file(path, "wb")
        if not file then return nil, open_err end
        local closed, close_err = file:close()
        if not closed then return nil, close_err end
    end
    return path
end

-- Optional synchronous capability; injected strategies retain their existing
-- required surface and keep ownership of their own temporary-file operations.
function Sync:reserve_sibling(path, directory)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if not platform.windows then
        return nil, "direct sibling reservation is a Windows capability"
    end
    local temporary, temporary_err = self:tmpname()
    if not temporary then return nil, temporary_err end
    local removed, remove_err = self:unlink(temporary)
    if not removed then return nil, remove_err end
    local sibling = paths.join(paths.dirname(path), paths.basename(temporary))
    if directory then
        local made, make_err = lfs.mkdir(sibling)
        return made and sibling or nil, make_err
    end
    local file, open_err = open_file(sibling, "wb")
    if not file then return nil, open_err end
    local closed, close_err = file:close()
    return closed and sibling or nil, close_err
end

local function normalize_argv(value)
    if type(value) ~= "table" then
        return nil, "command must be an argument array"
    end
    local argv = {}
    for i = 1, #value do
        local argument = value[i]
        if type(argument) ~= "string" then
            return nil, "command argument " .. i .. " must be a string"
        elseif argument:find("\0", 1, true) then
            return nil, "command argument " .. i .. " contains a NUL byte"
        end
        argv[i] = argument
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value or
           key % 1 ~= 0 then
            return nil, "command must be a dense argument array"
        end
    end
    return argv
end

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function shell_command(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = shell_quote(argument)
    end
    return table.concat(quoted, " ")
end

-- The normalized result of one completed captured POSIX shell command.
-- Status 129..192 is the shell's report of a signal-terminated child, and
-- 126/127 mean the command could not be executed.
local function shell_result(command, output, succeeded, why, status)
    local shell_status = not succeeded and why == "exit" and
        type(status) == "number" and status >= 129 and status <= 192 and
        status or nil
    local signal = not succeeded and (
        why == "signal" and status or
        shell_status and (shell_status - 128)
    ) or nil
    local interrupted = signal ~= nil
    if interrupted then
        why = "signal"
        status = signal
    end
    local missing = not succeeded and why == "exit" and
        (status == 126 or status == 127)

    return {
        started = not missing,
        ok = succeeded == true,
        status = succeeded and 0 or status,
        shell_status = shell_status,
        signal = signal,
        why = why,
        interrupted = interrupted,
        command = command,
        diagnostic = output,
        output = output,
    }
end

local function captured_command(argv)
    return "env LANG=C LC_ALL=C " .. shell_command(argv)
end

-- Preserve the normalized result contract historically supplied by
-- c-parser.cpp.capture_command. The default implementation uses one POSIX
-- shell only as the io.popen transport; argv remains parsed and losslessly
-- quoted, and both locale variables are fixed for deterministic diagnostics.
function Sync:run(argv, options)
    options = options or {}
    if type(options) ~= "table" then
        return {
            started = false,
            ok = false,
            diagnostic = "command options must be a table",
        }
    end

    local normalized, normalize_err = normalize_argv(argv)
    if not normalized then
        return {
            started = false,
            ok = false,
            diagnostic = normalize_err,
        }
    elseif #normalized == 0 then
        return {
            started = false,
            ok = false,
            diagnostic = "command is empty",
        }
    end

    if platform.windows then
        local called, result = pcall(function()
            return require("titan-compiler.process").capture(normalized, options)
        end)
        if called then
            result.command = platform.windows_process_command(normalized)
            return result
        end
        return { started = false, ok = false,
            diagnostic = "could not start captured command: " .. tostring(result) }
    end
    local command = captured_command(normalized)
    if options.stderr_to_stdout ~= false then command = command .. " 2>&1" end
    if self._process_inherit then
        -- Keep the ordinary shell/locale/redirection semantics, but make the
        -- coordinator's output leases explicit across exec and descendants.
        local captured, result = pcall(function()
            return require("titan-compiler.process").capture(
                { "/bin/sh", "-c", command }, {
                    inherit = self._process_inherit,
                    inherit_environment = true,
                    stderr_to_stdout = false,
                })
        end)
        if not captured then
            return { started = false, ok = false, command = command,
                diagnostic = "could not start captured command: " .. tostring(result) }
        end
        if result.started and result.why then
            return shell_result(command, result.output or "",
                result.ok, result.why, result.status)
        end
        result.command = command
        return result
    end

    local opened, pipe, popen_err = pcall(lua_io.popen, command,
        "r")
    if not opened or not pipe then
        return {
            started = false,
            ok = false,
            command = command,
            diagnostic = "could not start captured command: " ..
                tostring(opened and popen_err or pipe),
        }
    end

    local read_ok, output = pcall(pipe.read, pipe, "*a")
    if not read_ok then
        pcall(pipe.close, pipe)
        return {
            -- io.popen returned a live pipe, so a child transport existed
            -- even though output capture failed. Keep that launch fact for
            -- telemetry; without a completed status this remains strictly
            -- nonsemantic infrastructure evidence.
            started = true,
            ok = false,
            command = command,
            diagnostic = "could not capture command output: " ..
                tostring(output),
        }
    end

    local close_ok, succeeded, why, status = pcall(pipe.close, pipe)
    if not close_ok then
        return {
            -- As above, failure to wait does not undo the successful popen.
            started = true,
            ok = false,
            command = command,
            diagnostic = output .. "\nfailed waiting for command: " ..
                tostring(succeeded),
        }
    end

    return shell_result(command, output, succeeded, why, status)
end

local function batch_failure_result(command, diagnostic)
    return { started = false, ok = false, command = command,
        diagnostic = "could not start captured command: " .. diagnostic }
end

-- A failed ledger, completion channel or log removal leaves no result of the
-- batch usable as semantic evidence, as for generated-C batches. A launched
-- child keeps its launch fact and output but loses its completed status: this
-- is `run`'s shape for a started child without a usable exit.
local function transport_failed_result(result, command, failure)
    local output = result.output or result.diagnostic
    return {
        started = result.started == true, ok = false, command = command,
        diagnostic = "the native C probe batch failed: " .. failure ..
            ((output and output ~= "") and ("\n" .. output) or ""),
    }
end

-- Optional batching capability; it is not a required strategy method, and a
-- caller without it runs each command through `run`. Runs independent argv
-- arrays concurrently, each capturing combined standard output and error with
-- the same command text and result shape as `run(argv)`. One
-- `jobs.open_slots(options.jobs, { guard = true })` ledger bounds the batch:
-- the implicit process slot, exact parent-jobserver tokens, the local cap,
-- the unusable-server fallback, and reaping before a slot is released.
-- Returns the results in input order and the INT/TERM/HUP signal that
-- cancelled the batch, if any. On every exit, returned or raised, each
-- launched child has been reaped before its slot was released, the ledger
-- has returned its tokens and restored the signal actions, and the
-- completion channel and every log are removed. An error raised by the
-- strategy's own `run`, `tmpname` or `read_file` (a cancellation) stops
-- further launches and is rethrown unchanged after that teardown. A ledger,
-- completion-channel or log-removal failure, including one reported only
-- while tearing down, fails every command of the batch with that text even
-- when every child already launched; a launched child keeps `started`.
-- Implementation notes: doc/implementation/c-ffi-expressions.md#speculative-batched-acceptance-probes
function Sync:run_batch(commands, options)
    local jobs = require "titan-compiler.jobs"
    local cap = type(options) == "table" and options.jobs or nil
    if math.type(cap) ~= "integer" or cap < 1 then
        error("run_batch requires a positive integer jobs bound", 2)
    end
    local results, launchable = {}, {}
    for index, argv in ipairs(commands) do
        local normalized, normalize_err = normalize_argv(argv)
        if not normalized then
            results[index] = { started = false, ok = false, diagnostic = normalize_err }
        elseif #normalized == 0 then
            results[index] = { started = false, ok = false, diagnostic = "command is empty" }
        else
            launchable[#launchable + 1] = {
                index = index, argv = normalized,
                command = platform.windows
                    and platform.windows_process_command(normalized)
                    or captured_command(normalized),
            }
        end
    end
    if #launchable == 0 then return results end
    local slots, slots_err = jobs.open_slots(cap, { guard = true })
    if not slots then
        for _, item in ipairs(launchable) do
            results[item.index] = batch_failure_result(item.command, tostring(slots_err))
        end
        return results
    end
    local failure, raised, cancelled, channel
    local function batch_failure(message)
        failure = failure and (failure .. "; " .. message) or message
    end
    local function remove_log(log)
        local removed, remove_err = jobs.protected_remove(log)
        if not removed then
            batch_failure("failed to remove a C probe log: " .. tostring(remove_err))
        end
    end
    local launched, next_position = {}, #launchable + 1
    if slots.limit == 1 or #launchable == 1 then
        -- One granted slot (explicit `make -j1`, an unusable parent server,
        -- or a single command): run in order under the guard, without a
        -- channel.
        for _, item in ipairs(launchable) do
            local signal = slots:cancelled()
            if signal then
                results[item.index] = batch_failure_result(item.command,
                    "the batch was interrupted by signal " .. tostring(signal))
            else
                local called, result = pcall(self.run, self, item.argv)
                if not called then
                    raised = { error = result }
                    break
                end
                results[item.index] = result
            end
        end
    else
        local opened, opened_channel, channel_err = pcall(jobs.open_channel,
            function() return self:tmpname() end)
        if not opened then
            raised = { error = opened_channel }
        elseif not opened_channel then
            batch_failure(tostring(channel_err))
            next_position = 1
        else
            channel = opened_channel
            local drive_failure
            next_position, drive_failure, cancelled, raised = jobs.drive(
                slots, channel, #launchable, function(position)
                    local item = launchable[position]
                    local log, log_err = self:tmpname()
                    if not log then return nil, log_err end
                    local called, process, launch_err = pcall(jobs.launch,
                        channel, item.argv, item.command, log, log, position, nil,
                        not platform.windows and self._process_inherit and {
                            inherit = self._process_inherit,
                        } or nil)
                    if not called or not process then
                        remove_log(log)
                        if not called then error(process, 0) end
                        return nil, launch_err
                    end
                    process.log = log
                    launched[position] = process
                    return process
                end, function(position, launch_err)
                    local item = launchable[position]
                    results[item.index] = batch_failure_result(item.command,
                        tostring(launch_err))
                end, "C probe compiler")
            if drive_failure then batch_failure(drive_failure) end
        end
    end

    -- Teardown on every path. Closing the ledger returns every borrowed byte
    -- and restores the signal actions; every child was reaped first.
    local slots_ok, slots_close_err = slots:close()
    if not slots_ok then batch_failure(tostring(slots_close_err)) end
    cancelled = cancelled or slots:cancelled()
    if channel then
        local channel_ok, channel_close_err = jobs.close_channel(channel)
        if not channel_ok then batch_failure(channel_close_err) end
    end
    local outputs = {}
    for position = 1, #launchable do
        local process = launched[position]
        if process then
            local called, output, read_err = pcall(self.read_file, self, process.log)
            if not called then
                raised = raised or { error = output }
                output, read_err = nil, nil
            end
            outputs[position] = { output = output, read_err = read_err }
            remove_log(process.log)
        end
    end
    if raised then error(raised.error, 0) end

    for position = next_position, #launchable do
        local item = launchable[position]
        results[item.index] = batch_failure_result(item.command, cancelled and
            "the batch was interrupted by signal " .. tostring(cancelled) or
            tostring(failure))
    end
    for position = 1, #launchable do
        local process = launched[position]
        if process then
            local item = launchable[position]
            local output, read_err = outputs[position].output, outputs[position].read_err
            local result
            if not output or #process.finish_errors ~= 0 then
                result = { started = true, ok = false, command = item.command,
                    diagnostic = (output or "") .. "\ncould not capture command output: " ..
                        tostring(read_err or table.concat(process.finish_errors, "; ")) }
            elseif platform.windows then
                local signal = process.term == "signal" and process.code or nil
                result = { started = true, ok = process.ok == true,
                    status = process.code, why = process.term, signal = signal,
                    interrupted = signal ~= nil, command = item.command,
                    diagnostic = output, output = output }
            else
                result = shell_result(item.command, output,
                    process.ok, process.term, process.code)
            end
            results[item.index] = result
        end
    end
    if failure then
        -- Unlaunched commands above already carry the failure text.
        for position = 1, next_position - 1 do
            local item = launchable[position]
            results[item.index] = transport_failed_result(
                results[item.index], item.command, failure)
        end
    end
    return results, cancelled
end

function Sync:yield(_module_name)
    -- Ordinary titanc and the compiler's Lua tests execute synchronously.
end

function compiler_io.validate(candidate, level)
    level = level or 2
    local candidate_type = type(candidate)
    if candidate_type ~= "table" and candidate_type ~= "userdata" then
        error("compiler I/O strategy must be a table or userdata", level)
    end

    for _, name in ipairs(REQUIRED_METHODS) do
        local readable, method = pcall(function()
            return candidate[name]
        end)
        if not readable then
            error("cannot read compiler I/O strategy method '" .. name ..
                "': " .. tostring(method), level)
        elseif type(method) ~= "function" then
            error("compiler I/O strategy method '" .. name ..
                "' must be callable", level)
        end
    end
    return candidate
end

function compiler_io.new_sync()
    return setmetatable({}, Sync)
end

return compiler_io
