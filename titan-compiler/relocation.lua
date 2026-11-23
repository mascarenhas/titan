-- Only compiler-owned filesystem roots are relocatable. Paths remain paths at
-- I/O boundaries; these labels are used solely in certified semantic identity.
local paths = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local root_fields = require("titan-compiler.declarationschemas").relocation
local util = require "titan-compiler.util"
local lpeg = require "lpeglabel"
local relocation = {}

local function normalized(path)
    return paths.to_slash(paths.normalize(path))
end

local function same(left, right)
    return left == right or platform.windows and left:lower() == right:lower()
end

local function suffix(path, root)
    if same(path, root) then return "" end
    if same(path:sub(1, #root + 1), root .. "/") then return path:sub(#root + 1) end
end

function relocation.valid_roots(roots)
    if roots == nil then return true end
    if type(roots) ~= "table" or getmetatable(roots) then return false end
    for name, root in pairs(roots) do
        if not root_fields[name] or type(root) ~= "string" or root == "" then return false end
    end
    return true
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
            -- Windows 8.3 spellings can also differ from the resolved path.
            -- Use long names for roots that need relocatable certificates.
            if real and same(normalized(real), normalized(absolute)) then
                result[name] = normalized(absolute)
            end
        end
    end
    return result
end

-- The longest root that contains `spelling`, among the `admitted` names when
-- given. Roots that alias one directory tie, and the bytewise-first name wins
-- whatever order `pairs` yields, so a certified label never depends on it.
local function containing_root(roots, spelling, admitted)
    local best, tail
    for name, root in pairs(roots) do
        local relative = suffix(spelling, root)
        if relative and (not admitted or admitted[name])
           and (not best or #root > #roots[best]
                or #root == #roots[best] and util.bytewise_less(name, best)) then
            best, tail = name, relative
        end
    end
    return best, tail
end

function relocation.path(context, path)
    if type(path) ~= "string" or not platform.is_absolute(path) then return path end
    local best, tail = containing_root(context.relocation_roots or {}, normalized(path))
    return best and ("<titan:" .. best .. ">" .. tail) or path
end

function relocation.rebind(context, path, previous)
    if type(path) ~= "string" or not platform.is_absolute(path) then return path end
    local best, tail = containing_root(
        previous or {}, normalized(path), context.relocation_roots or {})
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
            result[index] = rewritten or value
        end
    end
    return result
end

local P, R, S = lpeg.P, lpeg.R, lpeg.S
local newline = P("\r\n") + S("\r\n")
local backslash = P("\\") + P("??/")
local splice = backslash * newline
local horizontal = S(" \t\v\f")
local spacing = (horizontal + splice)^0
local gap = splice^0 * horizontal * spacing
local block_close = P("*") * splice^0 * P("/")
local block_open = P("/") * splice^0 * P("*")
local block = block_open * (P(1) - block_close)^0 * block_close
local line_comment = P("/") * splice^0 * P("/") * (splice + (P(1) - newline))^0
local directive_end = (spacing * block)^0 * spacing * line_comment^-1 * #(newline + -P(1))

local function quoted(quote)
    local escaped = splice + backslash * (P(1) - newline)
    return P(quote) * (escaped + (P(1) - newline - S(quote .. "\\")))^0 * P(quote)^-1
end

local raw_string = lpeg.Cmt((P("u8") + S("uUL"))^-1 * P('R"') *
    lpeg.C((P(1) - S(" ()\\\t\r\n\v\f"))^-16) * P("("),
    function(source, position, delimiter)
        local _, finish = source:find(")" .. delimiter .. '"', position, true)
        return finish and finish + 1 or #source + 1
    end)
local word = R("az", "AZ", "09", "\128\255") + S("_$")
local token = raw_string + quoted('"') + quoted("'") + block + line_comment +
    block_open * P(1)^0 + word * (word + splice)^0 + splice + (P(1) - newline)
local directive = lpeg.Cmt((spacing * block)^0 * spacing * P("#") * spacing *
    (P("include") * gap * #S('"<') * lpeg.Cc(true) +
     (P("line") * gap * R("09")^1 + P("define") * gap * P("TITAN_GENERATED_C_FILE"))
        * gap * #P('"') * lpeg.Cc(false)) * lpeg.Carg(1),
    function(_, position, include, visit)
        return visit(position, include) or position
    end)
-- Only try each directive at the beginning of a logical line. The token walk
-- consumes multiline comments, literals and phase-2 splices without exposing
-- directive-like text inside those constructs.
local directives = (directive * token^0 * newline^-1 + token^1 * newline^-1 + newline)^0

local function rewrite(context, contents, previous, includes_only)
    if not contents:find("#", 1, true) then return contents end
    local parts, copied = nil, 1
    lpeg.match(directives, contents, 1, function(opening, include)
        local path, after, first, finish
        if include then
            -- Header names are preprocessing tokens, not string literals.
            local delimiter = contents:sub(opening, opening) == '"' and '"' or ">"
            local end_at = contents:find("[" .. delimiter .. "\r\n]", opening + 1)
            if not end_at or contents:sub(end_at, end_at) ~= delimiter then return nil end
            first, finish, after = opening + 1, end_at, end_at + 1
            path = contents:sub(first, finish - 1)
        elseif not includes_only then
            path, after = util.decode_c_line_filename(contents, opening)
            if not path then return nil end
            first, finish = opening, after
        else
            return nil
        end
        if lpeg.match(directive_end, contents, after) then
            local mapped = previous and relocation.rebind(context, path, previous)
                or relocation.path(context, path)
            if mapped ~= path then
                parts = parts or {}
                parts[#parts + 1] = contents:sub(copied, first - 1)
                parts[#parts + 1] = include and mapped or util.c_line_filename(mapped)
                copied = finish
            end
        end
        return after
    end)
    if not parts then return contents end
    parts[#parts + 1] = contents:sub(copied)
    return table.concat(parts)
end

function relocation.includes(context, contents, previous)
    return rewrite(context, contents, previous, true)
end

function relocation.generated(context, contents, previous)
    return rewrite(context, contents, previous, false)
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
