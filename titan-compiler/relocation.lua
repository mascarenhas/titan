-- Only compiler-owned filesystem roots are relocatable. Paths remain paths at
-- I/O boundaries; these labels are used solely in certified semantic identity.
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local relocation = {}

local function normalized(path)
    path = paths.to_slash(paths.normalize(path))
    return platform.windows and path:lower() or path
end

local function suffix(path, root)
    if path == root then return "" end
    if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 1) end
end

function relocation.roots(strategy, selected)
    local result, cwd = {}, assert(strategy:cwd())
    for name, path in pairs(selected) do
        if type(path) == "string" and path ~= "" then
            local absolute = assert(platform.absolute(path, cwd))
            local real = strategy:realpath(absolute)
            if not real then
                local parent, leaves = absolute, {}
                while not real do
                    local next_parent = paths.dirname(parent)
                    if next_parent == parent then break end
                    table.insert(leaves, 1, paths.basename(parent))
                    parent = next_parent
                    real = strategy:realpath(parent)
                end
                if real then
                    for _, leaf in ipairs(leaves) do real = paths.join(real, leaf) end
                end
            end
            -- A symlinked root is an external physical binding, not permission
            -- to retarget an SDK/output tree while keeping its cache identity.
            if real and normalized(real) == normalized(absolute) then
                result[name] = normalized(absolute)
            end
        end
    end
    return result
end

function relocation.path(context, path)
    if type(path) ~= "string" or not platform.is_absolute(path) then return path end
    local spelling, best, tail = normalized(path)
    for name, root in pairs(context.relocation_roots or {}) do
        local relative = suffix(spelling, root)
        if relative and (not best or #root > #context.relocation_roots[best]) then
            best, tail = name, relative
        end
    end
    return best and ("<titan:" .. best .. ">" .. tail) or path
end

function relocation.rebind(context, path, previous)
    if type(path) ~= "string" or not platform.is_absolute(path) then return path end
    local spelling, best, tail = normalized(path)
    for name, root in pairs(previous or {}) do
        local relative = suffix(spelling, root)
        if relative and context.relocation_roots and context.relocation_roots[name]
            and (not best or #root > #previous[best]) then
            best, tail = name, relative
        end
    end
    return best and (context.relocation_roots[best] .. tail) or path
end

function relocation.resolve(context, path)
    local name, tail = path:match("^<titan:([%w_]+)>(.*)$")
    local root = name and (context.relocation_roots or {})[name]
    return root and (root .. tail) or path
end

function relocation.changed(context, previous)
    for name, root in pairs(previous or {}) do
        if (context.relocation_roots or {})[name] ~= root then return true end
    end
    for name, root in pairs(context.relocation_roots or {}) do
        if (previous or {})[name] ~= root then return true end
    end
    return false
end

-- Parse path operands, not arbitrary flag text. In particular -D strings,
-- -f*-prefix-map values, rpaths and unknown/opaque options keep their bytes.
local PATH_OPTIONS = { ["-I"] = true, ["-isystem"] = true, ["-iquote"] = true,
    ["-idirafter"] = true, ["-include"] = true, ["-imacros"] = true,
    ["-isysroot"] = true, ["--sysroot"] = true, ["-L"] = true, ["-B"] = true }
local JOINED_OPTIONS = { "--sysroot=", "-isystem", "-iquote", "-idirafter",
    "-include", "-imacros", "-isysroot", "-I", "-L", "-B" }

function relocation.argv(context, argv)
    local result, operand = {}, false
    for index, value in ipairs(argv or {}) do
        if operand then
            result[index], operand = relocation.path(context, value), false
        elseif PATH_OPTIONS[value] then
            result[index], operand = value, true
        else
            local rewritten
            for _, option in ipairs(JOINED_OPTIONS) do
                if #value > #option and value:sub(1, #option) == option then
                    rewritten = option .. relocation.path(context, value:sub(#option + 1))
                    break
                end
            end
            -- A standalone absolute argv element names a compiler/input file;
            -- flags with embedded values are never treated as such an element.
            result[index] = rewritten or relocation.path(context, value)
        end
    end
    return result
end

-- Only the header-name token is rewritten. Never rewrite C literals, macro
-- definitions, #line locations or the preprocessor's expanded semantic bytes.
function relocation.includes(context, contents, previous)
    return (contents:gsub('(#[ \t]*include[ \t]+")([^"\r\n]+)(")',
        function(before, path, after)
            return before .. (previous and relocation.rebind(context, path, previous)
                or relocation.path(context, path)) .. after
        end))
end

function relocation.generated(context, contents, previous)
    contents = relocation.includes(context, contents, previous)
    local function mapped(path)
        return previous and relocation.rebind(context, path, previous)
            or relocation.path(context, path)
    end
    contents = contents:gsub('(#[ \t]*define[ \t]+TITAN_GENERATED_C_FILE[ \t]+")([^"\r\n]+)(")',
        function(before, path, after) return before .. mapped(path) .. after end)
    return (contents:gsub('(#[ \t]*line[ \t]+%d+[ \t]+")([^"\r\n]+)(")',
        function(before, path, after) return before .. mapped(path) .. after end))
end

function relocation.files(context, files)
    local result = {}
    for index, input in ipairs(files or {}) do
        local copy = {}
        for key, value in pairs(input) do copy[key] = value end
        copy.path = relocation.path(context, input.path)
        if input.realpath then copy.realpath = relocation.path(context, input.realpath) end
        result[index] = copy
    end
    return result
end

function relocation.browser(context, data)
    data.identity = nil
    for key, path in pairs(data.paths) do data.paths[key] = relocation.path(context, path) end
    for index, path in ipairs(data.include_dirs) do
        data.include_dirs[index] = relocation.path(context, path)
    end
    data.compile_flags = relocation.argv(context, data.compile_flags)
    data.lua.path = relocation.path(context, data.lua.path)
    data.probe_cache_directory = relocation.path(context, data.probe_cache_directory)
    return data
end

return relocation
