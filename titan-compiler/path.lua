-- Pure lexical native filesystem paths. This does not inspect files, resolve
-- symbolic links, or turn relative paths into absolute paths.
--
-- Adapted from Go's internal/filepathlite and path/filepath algorithms:
-- https://go.dev/src/internal/filepathlite/path.go
-- https://go.dev/src/internal/filepathlite/path_windows.go
-- https://go.dev/src/path/filepath/path_windows.go
-- Copyright 2010, 2024 The Go Authors. All rights reserved.
-- Go's BSD license is reproduced in LICENSES/go-LICENSE.
local windows = package.config:sub(1, 1) == "\\"
local path = { separator = windows and "\\" or "/" }

local function checked(value)
    assert(type(value) == "string", "path must be a string")
    return value
end

local function is_separator(character)
    return character == "/" or (windows and character == "\\")
end

local function prefix_fold(value, prefix)
    if #value < #prefix then return false end
    for index = 1, #prefix do
        local a, b = value:sub(index, index), prefix:sub(index, index)
        if is_separator(b) then
            if not is_separator(a) then return false end
        elseif a:upper() ~= b:upper() then
            return false
        end
    end
    return #value == #prefix or is_separator(value:sub(#prefix + 1, #prefix + 1))
end

local function unc_length(value, prefix_length)
    local separators = 0
    for index = prefix_length + 1, #value do
        if is_separator(value:sub(index, index)) then
            separators = separators + 1
            if separators == 2 then return index - 1 end
        end
    end
    return #value
end

local function valid_volume_length(value, length)
    local first = 1
    for index = 1, length + 1 do
        if index > length or is_separator(value:sub(index, index)) then
            if value:sub(first, index - 1) == ".." then return 0 end
            first = index + 1
        end
    end
    return length
end

local function volume_length(value)
    if not windows then return 0 end
    if #value >= 2 and value:sub(2, 2) == ":" then return 2 end
    if not is_separator(value:sub(1, 1)) then return 0 end
    if prefix_fold(value, "\\\\.") or prefix_fold(value, "\\\\?") or
       prefix_fold(value, "\\??") then
        if #value == 3 then return 3 end
        if prefix_fold(value:sub(5), "UNC") then
            return valid_volume_length(value, unc_length(value, 8))
        end
        for index = 5, #value do
            if is_separator(value:sub(index, index)) then
                return valid_volume_length(value, index - 1)
            end
        end
        return valid_volume_length(value, #value)
    end
    if #value >= 2 and is_separator(value:sub(2, 2)) then
        return valid_volume_length(value, unc_length(value, 2))
    end
    return 0
end

function path.to_slash(value)
    checked(value)
    if windows then return (value:gsub("\\", "/")) end
    return value
end

function path.from_slash(value)
    checked(value)
    if windows then return (value:gsub("/", "\\")) end
    return value
end

function path.volume(value)
    checked(value)
    return path.from_slash(value:sub(1, volume_length(value)))
end

function path.is_absolute(value)
    checked(value)
    if not windows then return value:sub(1, 1) == "/" end
    local length = volume_length(value)
    if length == 0 then return false end
    if is_separator(value:sub(1, 1)) and is_separator(value:sub(2, 2)) then
        return true
    end
    return is_separator(value:sub(length + 1, length + 1))
end

function path.normalize(value)
    checked(value)
    local length = volume_length(value)
    local volume, tail = value:sub(1, length), value:sub(length + 1)
    if tail == "" then
        if length > 1 and is_separator(value:sub(1, 1)) and
           is_separator(value:sub(2, 2)) then
            return path.from_slash(value)
        end
        return value .. "."
    end
    local rooted = is_separator(tail:sub(1, 1))
    local components, ends, first = {}, {}, 1
    local written = rooted and 1 or 0
    local rewritten = rooted and path.separator ~= tail:sub(1, 1)
    local function append_component(component)
        if written > (rooted and 1 or 0) then
            if path.separator ~= tail:sub(written + 1, written + 1) then rewritten = true end
            written = written + 1
        end
        if component ~= tail:sub(written + 1, written + #component) then rewritten = true end
        written = written + #component
        components[#components + 1] = component
        ends[#components] = written
    end
    for index = 1, #tail + 1 do
        if index > #tail or is_separator(tail:sub(index, index)) then
            local component = tail:sub(first, index - 1)
            if component == ".." then
                if #components > 0 and components[#components] ~= ".." then
                    ends[#components] = nil
                    components[#components] = nil
                    written = ends[#components] or (rooted and 1 or 0)
                elseif not rooted then
                    append_component(component)
                end
            elseif component ~= "" and component ~= "." then
                append_component(component)
            end
            first = index + 1
        end
    end
    local cleaned = (rooted and path.separator or "") ..
        table.concat(components, path.separator)
    if cleaned == "" then
        cleaned = "."
        if tail:sub(1, 1) ~= "." then rewritten = true end
    end
    -- Remember divergence even if a later '..' removes the changed component.
    -- Removing an untouched trailing suffix alone does not trigger these guards.
    -- Inspect only surviving output, unlike Go's out-of-width buffer scan.
    if windows and length == 0 and rewritten then
        local first_component = components[1] or ""
        if not rooted and first_component:find(":", 1, true) then
            cleaned = ".\\" .. cleaned
        elseif cleaned:sub(1, 3) == "\\??" then
            cleaned = "\\." .. cleaned
        end
    end
    return path.from_slash(volume .. cleaned)
end

function path.split(value)
    checked(value)
    local length, index = volume_length(value), #value
    while index > length and not is_separator(value:sub(index, index)) do
        index = index - 1
    end
    return value:sub(1, index), value:sub(index + 1)
end

function path.basename(value)
    checked(value)
    if value == "" then return "." end
    local index = #value
    while index > 0 and is_separator(value:sub(index, index)) do index = index - 1 end
    value = value:sub(1, index)
    value = value:sub(volume_length(value) + 1)
    index = #value
    while index > 0 and not is_separator(value:sub(index, index)) do index = index - 1 end
    local leaf = value:sub(index + 1)
    return leaf ~= "" and leaf or path.separator
end

function path.dirname(value)
    checked(value)
    local length, index = volume_length(value), #value
    while index > length and not is_separator(value:sub(index, index)) do
        index = index - 1
    end
    local directory = path.normalize(value:sub(length + 1, index))
    local volume = path.volume(value)
    if directory == "." and length > 2 then return volume end
    return volume .. directory
end

function path.extension(value)
    checked(value)
    for index = #value, 1, -1 do
        local character = value:sub(index, index)
        if is_separator(character) then break end
        if character == "." then return value:sub(index) end
    end
    return ""
end

function path.join(...)
    local elements = table.pack(...)
    local pieces, size, last = {}, 0, ""
    for index = 1, elements.n do
        local element = checked(elements[index])
        if not windows then
            if element ~= "" then
                if size > 0 then pieces[#pieces + 1] = "/"; size = size + 1 end
                pieces[#pieces + 1] = element
                size = size + #element
            end
        else
            if size > 0 then
                if is_separator(last) then
                    local first = 1
                    while is_separator(element:sub(first, first)) do first = first + 1 end
                    element = element:sub(first)
                    if size == 1 and element:sub(1, 2) == "??" and
                       (#element == 2 or is_separator(element:sub(3, 3))) then
                        pieces[#pieces + 1] = ".\\"
                        size = size + 2
                    end
                elseif last ~= ":" then
                    pieces[#pieces + 1] = "\\"
                    size, last = size + 1, "\\"
                end
            end
            if element ~= "" then
                pieces[#pieces + 1] = element
                size, last = size + #element, element:sub(-1)
            end
        end
    end
    if size == 0 then return "" end
    return path.normalize(table.concat(pieces))
end

return path
