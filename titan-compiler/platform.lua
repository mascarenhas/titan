-- Host properties and the Windows serial command transport. This module does
-- no filesystem/process work on import; native support is acquired only when
-- a synchronous Windows filesystem operation actually needs it.
local platform = {
    windows = package.config:sub(1, 1) == "\\",
    path = require "titan-compiler.windows_path",
}

function platform.is_absolute(path)
    if platform.windows then return platform.path.is_absolute(path) end
    return path:sub(1, 1) == "/"
end

function platform.join(directory, name)
    if platform.windows then return platform.path.join(directory, name) end
    return directory:sub(-1) == "/" and directory .. name or directory .. "/" .. name
end

function platform.parent(path)
    if platform.windows then return platform.path.split(path) end
    return path:match("^(.*)/[^/]+$")
end

function platform.absolute(path, cwd, strategy)
    if not platform.windows then
        return platform.is_absolute(path) and path or platform.join(cwd, path)
    end
    local result, err, reason = platform.path.absolute(path, cwd)
    if result or reason ~= "native_resolution_required" then return result, err end
    -- Injected I/O cannot accidentally consult the host's per-drive cwd.
    -- This optional capability does not change the required API-1 surface.
    if strategy then
        if type(strategy.absolute) == "function" then return strategy:absolute(path) end
        return nil, err
    end
    return platform.native("_win_abspath", path)
end

local function checked_word(word, index)
    if type(word) ~= "string" then
        return nil, "command argument " .. index .. " must be a string"
    elseif word:find("\0", 1, true) then
        return nil, "command argument " .. index .. " contains a NUL byte"
    elseif word:find("[\r\n]") then
        return nil, "Windows command arguments cannot contain line breaks"
    elseif not utf8.len(word) then
        return nil, "Windows command arguments must be valid UTF-8"
    end
    return word
end

-- The native C startup parser, rather than cmd, consumes these quotes and
-- backslashes. cmd escaping below must preserve this entire representation.
local function crt_argument(word)
    local parts, slashes = { '"' }, 0
    for index = 1, #word do
        local character = word:sub(index, index)
        if character == "\\" then
            slashes = slashes + 1
        else
            parts[#parts + 1] = string.rep("\\",
                character == '"' and (slashes * 2 + 1) or slashes)
            parts[#parts + 1] = character
            slashes = 0
        end
    end
    parts[#parts + 1] = string.rep("\\", slashes * 2)
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local metacharacters = {}
for character in ('()[]%!^"`<>&|;, *?\t'):gmatch(".") do
    metacharacters[character] = true
end

local function cmd_argument(word)
    return (word:gsub(".", function(character)
        return metacharacters[character] and ("^" .. character) or character
    end))
end

-- This deliberately represents argv, not an arbitrary cmd script. CC and
-- flag strings still use the compiler's existing shell-word parser. Native
-- executable prefixes are supported; batch wrappers add another shell parse
-- and are rejected instead of reinterpreting generated arguments as code.
function platform.windows_command(argv, merge_stderr)
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "command must be a nonempty argument array"
    end
    local words = {}
    for index = 1, #argv do
        local word, err = checked_word(argv[index], index)
        if not word then return nil, err end
        if index == 1 then
            if word == "" then return nil, "command executable is empty" end
            local extension = word:lower():match("([.][^./\\]+)$")
            if extension == nil then
                -- Resolve an extensionless native tool as .exe instead of
                -- letting PATHEXT select a batch file and add another parse.
                word = word .. ".exe"
            elseif extension ~= ".exe" and extension ~= ".com" then
                return nil, "Windows compiler commands require a native " ..
                    "executable, not a batch wrapper"
            end
            local resolved, resolve_error =
                platform.native("_win_resolve_executable", word)
            if not resolved then return nil, resolve_error end
            word = resolved
            if word:sub(1, 4) == "\\\\?\\" then
                return nil, "Windows command transport requires an ordinary " ..
                    "fully qualified executable path; extended executable paths are unsupported"
            end
            -- cmd interprets slash in its executable position differently
            -- from the C compiler's ordinary path arguments.
            words[index] = cmd_argument(crt_argument(word:gsub("/", "\\")))
        else
            words[index] = cmd_argument(crt_argument(word))
        end
    end
    for key in pairs(argv) do
        if type(key) ~= "number" or key < 1 or key > #argv or key % 1 ~= 0 then
            return nil, "command must be a dense argument array"
        end
    end
    -- Beginning with a fixed builtin also avoids cmd /c's special treatment
    -- of a command line whose very first character is a quote.
    local command = 'set "LANG=C"&&set "LC_ALL=C"&&' .. table.concat(words, " ")
    if merge_stderr then command = command .. " 2>&1" end
    -- This conservative byte bound also bounds UTF-16 code units for UTF-8
    -- paths. Response-file support is separate from this initial transport.
    if #command > 8191 then
        return nil, "Windows command exceeds the 8191-byte transport limit"
    end
    return command
end

function platform.native(name, ...)
    local loaded, support = pcall(require, "titan")
    if not loaded then return nil, "cannot load Windows native support: " ..
        tostring(support) end
    if type(support) ~= "table" or type(support[name]) ~= "function" then
        return nil, "Windows native support does not provide " .. name
    end
    return support[name](...)
end

return platform
