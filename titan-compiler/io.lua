local lfs = require "lfs"
local platform = require "titan-compiler.platform"

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

local function lfs_attributes(path, follow)
    local fn = follow and lfs.attributes or lfs.symlinkattributes
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
        device = attributes.dev,
        inode = attributes.ino,
        modified_seconds = modified_seconds,
        modified_nanoseconds = modified_nanoseconds,
    }
end

function Sync:cwd()
    local called, directory, err = pcall(lfs.currentdir)
    if not called then return nil, tostring(directory) end
    if not directory then return nil, operation_error("cwd", err) end
    return directory
end

-- Optional Windows spelling resolution, deliberately owned by this process's
-- synchronous backend rather than imposed on an injected filesystem strategy.
function Sync:absolute(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if platform.windows then return platform.native("_win_abspath", path) end
    local cwd, err = self:cwd()
    if not cwd then return nil, err end
    return platform.absolute(path, cwd)
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
    if platform.windows then return platform.native("_win_realpath", path) end

    local attributes, attribute_err = lfs_attributes(path, true)
    if not attributes then
        return nil, attribute_err or ("path does not exist: " .. path)
    end
    local cwd, cwd_err = self:cwd()
    if not cwd then return nil, cwd_err end
    return resolve_existing_path(path, cwd)
end

function Sync:stat(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if platform.windows then
        local result, err, code = platform.native("_win_stat", path, true)
        if not result and (code == 2 or code == 3) then return nil, nil end
        return result, err
    end
    local attributes, err = lfs_attributes(path, true)
    if not attributes then return nil, err end
    return normalized_stat(attributes)
end

function Sync:lstat(path)
    local valid, path_err = checked_path(path)
    if not valid then return nil, path_err end
    if platform.windows then
        local result, err, code = platform.native("_win_stat", path, false)
        if not result and (code == 2 or code == 3) then return nil, nil end
        return result, err
    end
    local attributes, err = lfs_attributes(path, false)
    if not attributes then return nil, err end
    return normalized_stat(attributes)
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
    -- move that identity beside the destination. Writing and closing the
    -- sibling before rename means readers observe either the previous complete
    -- file or the replacement complete file, never a truncated intermediate.
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
    if platform.windows then
        return platform.native("_win_replace", from, to)
    end
    return call_mutation("rename", lua_os.rename, from, to)
end

function Sync:tmpname()
    if platform.windows then return platform.native("_win_tmpname") end
    local called, path, err = pcall(lua_os.tmpname)
    if not called then return nil, tostring(path) end
    if not path then return nil, operation_error("tmpname", err) end
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
    return platform.native("_win_reserve_sibling", path, directory)
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

    local command
    if platform.windows then
        local command_err
        command, command_err = platform.windows_command(normalized,
            options.stderr_to_stdout ~= false)
        if not command then
            return { started = false, ok = false, diagnostic = command_err }
        end
    else
        command = "env LANG=C LC_ALL=C " .. shell_command(normalized)
        if options.stderr_to_stdout ~= false then
            command = command .. " 2>&1"
        end
    end

    local opened, pipe, popen_err = pcall(lua_io.popen, command,
        platform.windows and "rb" or "r")
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

    -- Windows exit statuses are native values, not POSIX wait-status words.
    -- In particular, an ordinary exit 143 is not evidence of SIGTERM there.
    local shell_status = not platform.windows and not succeeded and why == "exit" and
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
    -- Windows tools were resolved before execution. Every native exit value
    -- remains a process result; cmd's missing-tool status is not distinctive.
    local missing = not platform.windows and not succeeded and why == "exit" and
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
