local path = require "titan-compiler.path"
local selection = {}

selection.LABELS = { "windows", "darwin", "linux", "browser", "native" }
local labels = {}
for _, label in ipairs(selection.LABELS) do labels[label] = true end

function selection.classify(basename)
    local stem = basename:match("^(.*)%.titan$")
    if not stem then return nil end
    local base, label = stem:match("^(.+)%.([^.]+)$")
    if not label or not labels[label:lower()] then return basename end
    if label ~= label:lower() then
        return nil, nil, "mis-cased target label in source '" .. basename .. "'"
    end
    local previous_base, previous = base:match("^(.+)%.([^.]+)$")
    if previous_base and labels[previous:lower()] then
        return nil, nil, "stacked target labels in source '" .. basename .. "'"
    end
    return base .. ".titan", label
end

function selection.target_labels(target)
    if target == "linux" or target == "darwin" or target == "windows" then
        return { target, "native" }
    elseif target == "native" or target == "browser" then
        return { target }
    end
    error("invalid source selection target '" .. tostring(target) .. "'", 2)
end

function selection.applies(target, label)
    return label == target or (label == "native" and
        (target == "linux" or target == "darwin" or target == "windows"))
end

-- Source descriptors already carry this canonical path. Direct compiler and
-- checker APIs can also supply a physical source filename: normalize its leaf
-- with the same grammar, never stripping a label from a directory component.
function selection.output_stem(native_output, modname)
    native_output = native_output or modname:gsub("[.]", "/") .. ".titan"
    local basename = path.basename(native_output)
    local logical, _, err = selection.classify(basename)
    assert(not err, err)
    if logical then
        native_output = native_output:sub(1, #native_output - #basename) .. logical
    end
    return (native_output:gsub("[.]titan$", ""))
end

return selection
