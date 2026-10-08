-- Host properties, lexical paths, and Windows command rendering.
-- Importing this module performs no filesystem or process operations.
local platform = {
    windows = package.config:sub(1, 1) == "\\",
    path = require "titan-compiler.windows_path",
}

-- Windows' CRT getenv snapshot does not see updates made through libuv's
-- Win32 process environment. Keep native loading lazy so importing this
-- lexical platform module still performs no native operations.
function platform.getenv(name)
    if platform.windows then return (require("luv").os_getenv(name)) end
    return os.getenv(name)
end

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
    local result, err = platform.path.absolute(path, cwd)
    if result then return platform.path.normalize(result) end
    -- Injected I/O cannot accidentally consult the host's per-drive cwd.
    -- This optional capability does not change the required API-1 surface.
    if strategy then
        if type(strategy.absolute) == "function" then return strategy:absolute(path) end
        return nil, err
    end
    return nil, err
end

local function checked_word(word, index, shell)
    if type(word) ~= "string" then
        return nil, "command argument " .. index .. " must be a string"
    elseif word:find("\0", 1, true) then
        return nil, "command argument " .. index .. " contains a NUL byte"
    elseif shell and word:find("[\r\n]") then
        return nil, "Windows command arguments cannot contain line breaks"
    elseif shell and not utf8.len(word) then
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

-- CC and flag strings use the compiler's existing shell-word parser. Windows
-- resolves and executes the configured command; this layer only quotes argv.
function platform.windows_command(argv, merge_stderr)
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "command must be a nonempty argument array"
    end
    local words = {}
    for index = 1, #argv do
        local word, err = checked_word(argv[index], index, true)
        if not word then return nil, err end
        if index == 1 then
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
    return command
end

-- Display parsed native argv for verbose parallel compilation. The process
-- dependency receives the original argv and owns execution quoting.
function platform.windows_process_command(argv)
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "command must be a nonempty argument array"
    end
    local words, executable = {}
    for index = 1, #argv do
        local word, err = checked_word(argv[index], index)
        if not word then return nil, err end
        if index == 1 then
            executable = word
        end
        words[index] = crt_argument(word)
    end
    for key in pairs(argv) do
        if type(key) ~= "number" or key < 1 or key > #argv or key % 1 ~= 0 then
            return nil, "command must be a dense argument array"
        end
    end
    return table.concat(words, " "), executable
end

return platform
