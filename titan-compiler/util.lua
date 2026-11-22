local lpeg = require "lpeglabel"

local util = {}

-- Renders a Lua literal: the sequence part in order, then the remaining
-- entries in bytewise order of their text. Serialized types and function-type
-- tags contain it, so the text must not follow `pairs` order.
function util.tostring(v)
    if type(v) ~= "table" then
        return string.format("%q", v)
    end

    local parts = {}
    local seen = {}

    for i, item in ipairs(v) do
        seen[i] = true
        parts[#parts + 1] = util.tostring(item)
    end

    local keyed = {}
    for k, item in pairs(v) do
        if not seen[k] then
            keyed[#keyed + 1] = string.format("[%s] = %s", util.tostring(k), util.tostring(item))
        end
    end
    table.sort(keyed, util.bytewise_less)
    table.move(keyed, 1, #keyed, #parts + 1, parts)

    return "{" .. table.concat(parts, ", ") .. "}"
end

function util.get_file_contents(filename, mode)
    local f, err = io.open(filename, mode or "r")
    if not f then
        return false, err
    end
    local s = f:read("a")
    f:close()
    if not s then
        return false, "unable to open file " .. filename
    else
        return s
    end
end

function util.set_file_contents(filename, contents, mode)
    local f, err = io.open(filename, mode or "w")
    if not f then
        return false, err
    end
    f:write(contents)
    f:close()
    return true
end

-- Generated directives must apply to the next statement, not template padding.
-- Skip C literals and comments so directive-like text remains byte-identical.
local generated_line_cleanup
do
    local P, S = lpeg.P, lpeg.S
    local newline = P("\r")^-1 * P("\n")
    local horizontal = S(" \t")
    local escaped = P("\\") * (P("\r\n") + P(1))
    local function quoted(quote)
        return P(quote) * (escaped + (P(1) - S(quote .. "\r\n")))^0 * P(quote)
    end
    local comment = P("/*") * (P(1) - P("*/"))^0 * P("*/")
        + P("//") * (escaped + (P(1) - S("\r\n")))^0
    local directive = lpeg.B("\n") * horizontal^0 * P("#line") * horizontal^1
        * (P(1) - S("\r\n"))^0 * newline
        * ((horizontal^0 * newline)^1 / "")
    generated_line_cleanup = lpeg.Cs(
        (quoted('"') + quoted("'") + comment + directive + P(1))^0)
end

function util.normalize_line_directives(source)
    if not source:find("#line", 1, true) then return source end
    return lpeg.match(generated_line_cleanup, "\n" .. source):sub(2)
end

-- Spell `filename` as the string literal of a C `#line` directive (or of
-- TITAN_GENERATED_C_FILE, which is only ever expanded in one). That literal
-- is unevaluated: Clang 23 rejects numeric (octal/hex) escapes there, so
-- bytes without a simple escape stay raw. `\?` keeps `--std=c99` trigraphs
-- from forming, and the UCN keeps a literal dollar out of util.render's
-- recursive template language.
-- Implementation notes: doc/implementation/codegen-overview.md#mixed-source-line-attribution
local LINE_FILENAME_ESCAPES = {
    ["\\"] = "\\\\", ['"'] = '\\"', ["?"] = "\\?", ["$"] = "\\u0024",
    ["\a"] = "\\a", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
    ["\r"] = "\\r", ["\t"] = "\\t", ["\v"] = "\\v",
}

function util.c_line_filename(filename)
    assert(not filename:find("\0", 1, true),
        "C line-control filename contains a NUL byte")
    return '"' .. filename:gsub('[\\"?$\a\b\f\n\r\t\v]', LINE_FILENAME_ESCAPES) .. '"'
end

-- Barebones string-based template function for generating C/Lua code. Replaces
-- $VAR and ${VAR} placeholders in the `code` template by the corresponding
-- strings in the `substs` table.
-- Implementation notes: doc/implementation/codegen-overview.md#no-c-ast-templates-utilrender-and-clang-format
function util.render(code, substs, ignore_missing)
    return (string.gsub(code, "%$({?)([A-Za-z_][A-Za-z_0-9]*)(}?)", function(a, k, b)
        if a == "{" and b == "" then
            error("unmatched ${ in template")
        end
        local v = substs[k]
        if not v then
            if ignore_missing then return nil end
            error("Internal compiler error: missing template variable " .. k .. "\n" .. code)
        end
        if a == "" and b == "}" then
            v = v .. b
        end
        return util.render(v, substs, ignore_missing)
    end))
end

function util.c_float_literal(n)
    if n ~= n then return "NAN" end
    if n == math.huge then return "HUGE_VAL" end
    if n == -math.huge then return "(-HUGE_VAL)" end
    local s = string.format("%.17g", n) -- round-trips every finite double
    -- Integral values still need floating syntax in raw C operators.
    if not s:find("[.eE]") then s = s .. ".0" end
    return s
end

-- Implementation notes: doc/implementation/ast-typedecl.md#_tag-dispatch-and-utilmake_visitor
function util.make_visitor(functions)
    return function(node, ...)
        assert(type(node) == "table")
        assert(node._tag)
        local f = assert(functions[node._tag])
        return f(node, ...)
    end
end

function util.to_set(array)
    local set = {}
    for _, v in ipairs(array) do
        set[v] = true
    end
    return set
end

function util.split_string(str, delim)
    local result = {}
    local n = 1
    local last_pos = 1
    local delim_len = #delim
    while true do
        local pos = string.find(str, delim, last_pos, true)
        if not pos then break end
        result[n] = string.sub(str, last_pos, pos - 1)
        n = n + 1
        last_pos = pos + delim_len
    end
    result[n] = string.sub(str, last_pos)
    return result
end

-- Compare strings by their raw numeric byte sequence. Lua's ordinary string
-- ordering delegates to the active locale, which is unsuitable for source and
-- interface order that must be reproducible across hosts.
function util.bytewise_less(a, b)
    local limit = math.min(#a, #b)
    for index = 1, limit do
        local abyte = string.byte(a, index)
        local bbyte = string.byte(b, index)
        if abyte ~= bbyte then return abyte < bbyte end
    end
    return #a < #b
end

--
-- Functional
--

function util.curry(f, a)
    return function(...)
        return f(a, ...)
    end
end

function util.any(f, l)
    for _, elem in ipairs(l) do
        if f(elem) then
            return true
        end
    end
    return false
end

return util
