-- Pure Windows pathname spelling. Never a physical-file identity oracle.
-- Ordinary paths use "/" here; extended paths keep literal "\" semantics.
local path = {}

local function invalid(message)
    return nil, message, "invalid_path"
end

local function native_required(message)
    return nil, message, "native_resolution_required"
end

local function checked(value)
    if type(value) ~= "string" or value == "" then
        return invalid("path must be a nonempty string")
    end
    if value:find("\0", 1, true) then return invalid("path contains a NUL byte") end
    return value
end

local function guid_component(value)
    if #value ~= 44 or not value:sub(1, 7):match("^[Vv][Oo][Ll][Uu][Mm][Ee]{$")
        or value:sub(-1) ~= "}" then return false end
    local guid = value:sub(8, -2)
    for i = 1, 36 do
        local c = guid:sub(i, i)
        if i == 9 or i == 14 or i == 19 or i == 24 then
            if c ~= "-" then return false end
        elseif not c:match("^[0-9a-fA-F]$") then
            return false
        end
    end
    return true
end

local function unc_components(body, separator)
    local server, share, tail
    if separator == "\\" then
        server, share, tail = body:match("^([^\\]+)\\([^\\]+)(.*)$")
    else
        server, share, tail = body:match("^([^/]+)/([^/]+)(.*)$")
    end
    if not server or server == "." or server == ".." or
       share == "." or share == ".." then
        return invalid("UNC path requires a server and a share")
    end
    if tail ~= "" then
        if tail:sub(1, 1) ~= separator then return invalid("invalid UNC root") end
        tail = tail:sub(2)
    end
    return server, share, tail
end

local function parse(value)
    local valid, message, reason = checked(value)
    if not valid then return nil, message, reason end
    if value:sub(1, 4) == "\\\\?\\" then
        if value:find("/", 1, true) then
            return invalid("extended Windows paths must use backslashes")
        end
        local body = value:sub(5)
        local root, tail = body:match("^([A-Za-z]:\\)(.*)$")
        if root then
            return { value = value, kind = "extended_drive",
                root = "\\\\?\\" .. root, tail = tail, extended = true, absolute = true }
        end
        if body:sub(1, 4):match("^[Uu][Nn][Cc]\\$") then
            local server, share, rest = unc_components(body:sub(5), "\\")
            if not server then return nil, share, rest end
            return { value = value, kind = "extended_unc",
                root = value:sub(1, 8) .. server .. "\\" .. share .. "\\",
                tail = rest, extended = true, absolute = true }
        end
        local volume, rest = body:match("^([^\\]+)\\(.*)$")
        if volume and guid_component(volume) then
            return { value = value, kind = "extended_volume",
                root = "\\\\?\\" .. volume .. "\\", tail = rest,
                extended = true, absolute = true }
        end
        return invalid("unsupported or incomplete extended filesystem root")
    end
    -- Never turn a slash-spelled namespace into a different, usable namespace.
    local ordinary = value:gsub("\\", "/")
    if ordinary:sub(1, 4) == "//?/" or ordinary:sub(1, 4) == "//./" then
        return invalid("unsupported device namespace or malformed extended prefix")
    end
    local drive, tail = ordinary:match("^([A-Za-z]:)(.*)$")
    if drive then
        if tail:sub(1, 1) == "/" then
            return { value = ordinary, kind = "drive_absolute",
                root = drive .. "/", tail = tail:sub(2), absolute = true }
        end
        return { value = ordinary, kind = "drive_relative",
            root = drive, tail = tail, absolute = false }
    end
    if ordinary:sub(1, 2) == "//" then
        local server, share, rest = unc_components(ordinary:sub(3), "/")
        if not server then return nil, share, rest end
        return { value = ordinary, kind = "unc_absolute",
            root = "//" .. server .. "/" .. share .. "/", tail = rest, absolute = true }
    end
    if ordinary:sub(1, 1) == "/" then
        return { value = ordinary, kind = "root_relative",
            root = "/", tail = ordinary:sub(2), absolute = false }
    end
    return { value = ordinary, kind = "relative", root = "", tail = ordinary,
        absolute = false }
end

function path.separators(value)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, message, reason end
    return parsed.value
end

function path.kind(value)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, message, reason end
    return parsed.kind
end

-- "absolute" here means fully qualified, not merely rooted on an ambient drive.
function path.is_absolute(value)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, message, reason end
    return parsed.absolute
end

-- Explicit spelling normalization, never called implicitly by absolute/join.
-- This must not replace filesystem resolution of authored link/.. observations.
function path.normalize(value, preserve_parent)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, message, reason end
    if parsed.extended then return parsed.value end
    local components = {}
    local bounded = parsed.absolute or parsed.kind == "root_relative"
    for component in parsed.tail:gmatch("[^/]+") do
        if component == ".." and not preserve_parent then
            if #components > 0 and components[#components] ~= ".." then
                components[#components] = nil
            elseif not bounded then
                components[#components + 1] = component
            end
        elseif component ~= "." then
            components[#components + 1] = component
        end
    end
    local result = parsed.root .. table.concat(components, "/")
    return result ~= "" and result or "."
end

-- Join explicitly inherits the base's namespace. Only the supplied relative
-- suffix's separators change for an extended base; the base and dot components
-- stay literal. An authored ordinary relative path against an extended cwd must
-- use absolute() and its native-resolution diagnostic instead.
function path.join(base, suffix)
    local root, root_error, root_reason = parse(base)
    if not root then return nil, root_error, root_reason end
    local child, child_error, child_reason = parse(suffix)
    if not child then return nil, child_error, child_reason end
    if child.kind ~= "relative" then
        return invalid("join suffix must be an ordinary relative path")
    end
    local separator = root.extended and "\\" or "/"
    local tail = root.extended and child.value:gsub("/", "\\") or child.value
    local prefix = root.value
    if prefix:sub(-1) ~= separator and
        not (root.kind == "drive_relative" and root.tail == "") then
        prefix = prefix .. separator
    end
    return prefix .. tail
end

function path.absolute(value, cwd)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, message, reason end
    if parsed.absolute then return parsed.value end
    if parsed.kind == "drive_relative" then
        return native_required("drive-relative path requires Windows per-drive current-directory resolution")
    end
    local current, cwd_error, cwd_reason = parse(cwd)
    if not current then return nil, cwd_error, cwd_reason end
    if not current.absolute then return invalid("cwd must be a fully qualified Windows path") end
    if current.extended then
        return native_required("ordinary relative path with extended cwd requires native resolution")
    end
    if parsed.kind == "root_relative" then
        return current.root .. parsed.tail
    end
    return path.join(current.value, parsed.value)
end

-- Peel one lexical component without collapsing "."/".." or crossing a root.
-- Roots return nil,nil. A relative leaf returns nil,leaf. A trailing separator
-- returns an empty leaf; callers can deliberately peel it without interpreting
-- it as a filename. Third/fourth returns carry validation error/reason.
function path.split(value)
    local parsed, message, reason = parse(value)
    if not parsed then return nil, nil, message, reason end
    if parsed.tail == "" or (not parsed.extended and parsed.tail:match("^/*$")) then
        return nil, nil
    end
    local parent, leaf
    if parsed.extended then
        parent, leaf = parsed.tail:match("^(.*)\\([^\\]*)$")
    else
        parent, leaf = parsed.tail:match("^(.*)/([^/]*)$")
    end
    if parent then return parsed.root .. parent, leaf end
    return parsed.root ~= "" and parsed.root or nil, parsed.tail
end

return path
