local types = require "titan-compiler.types"
local util  = require "titan-compiler.util"

local coder = {}

-- Lua 5.5's CallInfo encodes finite result requests only through MAXRESULTS.
-- The checker rejects wider finite generic function-value calls; keep the same
-- value here as an internal assertion so hand-built or stale ASTs cannot emit
-- an invalid finite luaD_callnoyield request. Statically open generic calls use
-- LUA_MULTRET.
local LUA_VM_MAX_RESULTS = 250

local codeexp, codestat, codeforeignexp, codelambda, codelambdadec, codemethodref
local codedotsindex   -- forward: codecall (case-2 borrow) calls it; defined below

local render = util.render

--
-- Functions for C literals
--

-- Preserve arbitrary Titan string bytes while keeping generated C source
-- textual and readable.
local some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["?"] = "\\077",
    ["\0"] = "\\000",
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
}

local function c_string_literal(s)
    local out = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        local escaped = some_c_escape_sequences[c]
        if escaped then
            out[#out + 1] = escaped
        else
            local byte = string.byte(c)
            -- Keep generated C source textual and encoding-independent. Three
            -- octal digits cannot consume a following digit as part of the
            -- escape.
            if byte < 32 or byte == 127 or byte >= 128 then
                out[#out + 1] = string.format("\\%03o", byte)
            else
                out[#out + 1] = c
            end
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function c_integer_literal(n)
    -- The most negative lua_Integer cannot be written as the literal
    -- -9223372036854775808: C parses that as -(9223372036854775808), whose
    -- magnitude overflows a signed integer, so the compiler warns and gives
    -- it unsigned type. Emit the Lua header macro (itself -LUA_MAXINTEGER-1)
    -- instead. Every other value formats safely.
    if n == math.mininteger then
        return "LUA_MININTEGER"
    end
    return string.format("%i", n)
end

local function c_float_literal(n)
    if n ~= n then return "NAN" end            -- nan (unreachable from a literal, defensive)
    if n == math.huge then return "HUGE_VAL" end   -- +inf, e.g. the literal 1e400
    if n == -math.huge then return "(-HUGE_VAL)" end
    local s = string.format("%.17g", n)        -- round-trips every finite double
    -- %.17g prints an integral value as a bare integer token ("1", "0", "-2"),
    -- which is a C *integer* constant: spliced into a raw operator it would make
    -- e.g. `1.0 / 2.0` integer division (== 0) and `0.0 / 0.0` an integer divide
    -- by zero. Force a floating constant when the token has no '.' or exponent.
    if not s:find("[.eE]") then s = s .. ".0" end
    return s
end

-- Emit a standalone C `#line` directive pointing at `node`'s .titan source
-- location, so DWARF and libbacktrace symbolization attribute the *following*
-- generated C to the original .titan file and line rather than the generated
-- .c. Returned as its own line with a
-- trailing newline so it never fuses with adjacent code; the `#` may be
-- indented (reindent_c re-indents it) since leading whitespace before a
-- directive is legal C. Nodes without a `loc` (synthesized AST) emit nothing.
local function emitline(node)
    local loc = node and node.loc
    if not loc or not loc.line or not loc.filename then return "" end
    return "#line " .. tostring(loc.line) .. " "
        .. c_string_literal(loc.filename) .. "\n"
end

local foreignctype

local function getslot(typ --[[:table]], dst --[[:string?]], src --[[:string]])
    dst = dst and dst .. " =" or ""
    local tmpl
    local ct
    if typ._tag == "Type.Integer" then tmpl = "$DST ivalue($SRC)"
    elseif typ._tag == "Type.Float" then tmpl = "$DST fltvalue($SRC)"
    elseif typ._tag == "Type.Boolean" then tmpl = "$DST ttistrue($SRC)"
    elseif typ._tag == "Type.Nil" then tmpl = "$DST 0"
    elseif typ._tag == "Type.String" then tmpl = "$DST tsvalue($SRC)"
    elseif typ._tag == "Type.Array" then tmpl = "$DST hvalue($SRC)"
    elseif typ._tag == "Type.Map" then tmpl = "$DST hvalue($SRC)"
    elseif typ._tag == "Type.Value" then tmpl = "$DST *($SRC)"
    elseif types.is_c_tvalue(typ) then tmpl = "$DST *($SRC)"
    elseif typ._tag == "Type.Nominal" then tmpl = "$DST uvalue($SRC)"
    elseif typ._tag == "Type.Option" then tmpl = "$DST *($SRC)"
    elseif typ._tag == "Type.Function" then tmpl = "$DST *($SRC)"
    elseif typ._tag == "Type.CInteger" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CInteger") then
        tmpl = "$DST (($CT)ivalue($SRC))"
        ct = foreignctype(typ)
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        tmpl = "$DST (($CT)fltvalue($SRC))"
        ct = foreignctype(typ)
    elseif types.is_c_udata_pointer(typ) then
        tmpl = "$DST (ttisnil($SRC) ? NULL : (($CT)uvalue($SRC)))"
        ct = foreignctype(typ)
    elseif typ._tag == "Type.CPointer" or typ._tag == "Type.CArray" or
           (typ._tag == "Type.CTypedef"
            and (types.resolve_c_typedef(typ)._tag == "Type.CPointer"
                 or types.resolve_c_typedef(typ)._tag == "Type.CArray")) then
        tmpl = "$DST (($CT)pvalue($SRC))"
        ct = foreignctype(typ)
    elseif typ._tag == "Type.COwned" then
        tmpl = "$DST uvalue($SRC)"
    else error("invalid type " .. types.tostring(typ)) end
    return render(tmpl, { DST = dst, SRC = src, CT = ct })
end

local function toboolean(typ --[[:table]], src --[[:string]])
    local tmpl
    if types.is_truthy(typ) then return "1"
    elseif types.is_falsy(typ) then return "0"
    elseif typ._tag == "Type.Boolean" then return src
    elseif typ._tag == "Type.Value" then
        tmpl = "!l_isfalse(&$SRC)"
    elseif typ._tag == "Type.Option" and typ.base._tag == "Type.Boolean" then
        tmpl = "!l_isfalse(&$SRC)"
    elseif typ._tag == "Type.Option" and typ.base._tag ~= "Type.Boolean" then
        tmpl = "!ttisnil(&$SRC)"
    elseif typ._tag == "Type.Pointer" then
        -- a foreign C pointer is truthy iff it is non-NULL
        tmpl = "($SRC != NULL)"
    elseif types.resolve_c_typedef(typ)._tag == "Type.CPointer" then
        tmpl = "($SRC != NULL)"
    else error("invalid type " .. types.tostring(typ)) end
    return render(tmpl, { SRC = src })
end

-- Get the next module user-value slot. Slots are 0-based: the module state is a
-- Udata whose user values hold the module's globals/imports/metatables/etc.
-- directly, and the old uv[0] (reserved for the Lua-facing module table) is
-- gone, so hand out the current counter and post-increment. After all
-- allocations tlcontext.upvalue is exactly the number of slots (NUPVALS).
local function nextupvalue(tlcontext)
    local slot = tlcontext.upvalue
    tlcontext.upvalue = slot + 1
    return slot
end

local function mangle_qn(qualname)
    return qualname:gsub("[%-.]", "_")
end

-- TITAN_ENTRY_TAG marks every generated Lua entry-wrapper C symbol with a name
-- Titan owns and no Lua/libc symbol shares. The unified backtrace merge
-- (titan-runtime/titan.c) keys on this substring to locate Titan native-stack
-- boundaries — each entry wrapper is where one Lua->Titan call splices a run of
-- native Titan frames into the CallInfo-driven Lua trace. The `#line` from
-- the function-definition `#line` still attributes these wrappers to the
-- .titan source.
local TITAN_ENTRY_TAG = "titanentry"

local function fname_prefix(typ)
    return mangle_qn(typ.fqtn) .. "_" .. typ.name
end

local function static_name(typ)
    return fname_prefix(typ) .. "_titanstatic"
end

local function static_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_luastatic"
end

local function method_name(typ)
    return fname_prefix(typ) .. "_titanmethod"
end

local function method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_luamethod"
end

-- Bound-method trampolines: the native one (`_boundmethod`) matches the
-- self-removed function ABI and delegates to the method's own native entry with
-- the captured `self`; the Lua one (`_boundlua`) is the closure's `lua_CFunction`
-- and inserts `self` before delegating to the method's Lua entry. Both are
-- exported so a bind site in another module (with only the `.so`) can reach them.
local function bound_method_name(typ)
    return fname_prefix(typ) .. "_boundmethod"
end

local function bound_method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_boundlua"
end

local function modprefix(modname)
    return mangle_qn(modname) .. "_"
end

local function func_name(modname, name)
    return modprefix(modname) .. name .. "_titan"
end

local function func_luaname(modname, name)
    return modprefix(modname) .. name .. "_" .. TITAN_ENTRY_TAG .. "_lua"
end

local function module_initializer_name(tlcontext)
    return tlcontext.prefix .. TITAN_ENTRY_TAG .. "_module_initializer"
end

-- Record the mapping from a native function's mangled C symbol to its qualified
-- Titan source name, for the trace name table emitted in _init (deliverable 2).
-- The runtime (errorhandler) looks each native frame's DWARF symbol up here and
-- shows the qualified name instead of the mangled symbol. Forms:
--   top-level func  -> "<module>.<func>"
--   method          -> "<module>.<record>:<method>"
--   record function -> "<module>.<record>.<function>"
--   anonymous/lambda-> "anonymous function at <file>.titan:<linedefined>"
local function register_trace_name(tlcontext, symbol, qualname)
    table.insert(tlcontext.names, { symbol, qualname })
end

-- The qualified Titan name of an anonymous function, formatted at codegen from
-- its DEFINITION location (the lambda's `loc`). The trace's leading
-- `<file>:<current-line>` already shows the execution point; this names it.
local function anon_qualname(loc)
    if loc and loc.line and loc.filename then
        return "anonymous function at " .. loc.filename .. ":" .. tostring(loc.line)
    end
    return "anonymous function"
end

-- get name of the variable holding the metatable for this type.
-- `ctx` may be a per-function context (has `.tlcontext`) or the top-level
-- tlcontext itself — genluaentry passes the latter into checkandget when
-- coercing a Lua-facing record parameter, and that may be the first use of the
-- type's metatable. Resolve the tlcontext either way (`ctx.metatables` is the
-- same shared table in both); allocating the slot here is safe because it
-- happens before init_data_from_other_modules emits the per-state recovery.
local function type2metatable(ctx, typ --[[:table]])
    local tlcontext = ctx.tlcontext or ctx
    if not ctx.metatables[typ.fqtn] then
        ctx.metatables[typ.fqtn] = nextupvalue(tlcontext)
    end
    return ctx.metatables[typ.fqtn]
end

local function owned_c_metatable_key(typ)
    assert(typ._tag == "Type.COwned")
    return types.tostring(typ.pointee) .. (typ.count and "[]" or "")
end

local function owned_c_metatable(ctx, typ)
    local tlcontext = ctx.tlcontext or ctx
    local key = owned_c_metatable_key(typ)
    local entry = tlcontext.owned_c_metatables[key]
    if not entry then
        entry = {
            slot = nextupvalue(tlcontext),
            name = "Titan owned C " .. tlcontext.module .. " " .. key .. " metatable",
        }
        tlcontext.owned_c_metatables[key] = entry
    end
    return entry.slot
end

-- Get the C identifier of the `static const void *` holding the type tag for a
-- function type, allocating one (numbered per module) on first use. Tags are
-- keyed by the verbatim canonical type string and shared across all modules
-- through the Lua registry (publish-or-recover, emitted in _init), so two
-- modules that mention `(integer) -> integer` agree on the same tag pointer and
-- the fast path can recognise each other's function values.
local function function_type_tag(tlcontext, ftype --[[:table]])
    local key = types.tostring(ftype)
    local entry = tlcontext.functags[key]
    if not entry then
        local n = tlcontext.functag_count
        tlcontext.functag_count = n + 1
        entry = { id = tlcontext.prefix .. "functag_" .. n, key = key }
        tlcontext.functags[key] = entry
        table.insert(tlcontext.functag_list, entry)
    end
    return entry.id
end

local checkandset

-- `loc` is the .titan source location of the raise; it stamps a fully-resolved
-- `#line` directly above the luaL_error so the native frame that throws
-- symbolizes to the throw's exact .titan line instead of a
-- line drifted N rows into the surrounding expanded coercion C. The `#line`
-- uses resolved values (not $LINE/$FILE placeholders) so it is independent of
-- whatever render vars the caller's enclosing template happens to define. The
-- `$LINE`/`$FILE`/etc. placeholders left in $PARAMS are still filled by that
-- enclosing template (ignore_missing=true keeps them intact here).
local function codethrow(loc, template, params)
    local line = loc and emitline({ loc = loc }) or ""
    return render([[
        $LINEDIR
        luaL_error(L, "$TEMPLATE", $PARAMS);
    ]], {
        LINEDIR = line,
        TEMPLATE = template,
        PARAMS = table.concat(params, ',')
    }, true)
end

local function checkandget(ctx, typ --[[:table]], cvar --[[:string]], exp --[[:string]], loc --[[:table]])
    local tag
    if typ._tag == "Type.Integer" then
        return render([[
            if (TITAN_LIKELY(ttisinteger($EXP))) {
                $VAR = ivalue($EXP);
            } else if (ttisfloat($EXP)) {
                lua_Number _v = fltvalue($EXP);
                lua_Number _flt = l_floor(_v);
                if (TITAN_UNLIKELY(_v != _flt)) {
                    $THROWFLOAT
                } else if (TITAN_UNLIKELY(!lua_numbertointeger(_flt, &$VAR))) {
                    $THROWFLOAT
                }
            } else {
                $THROWINTEGER
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROWFLOAT = codethrow(loc, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINTEGER = codethrow(loc, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.Float" then
        return render([[
            if (TITAN_LIKELY(ttisfloat($EXP))) {
                $VAR = fltvalue($EXP);
            } else if (ttisinteger($EXP)) {
                $VAR = (lua_Number)ivalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.Boolean" then
        return render([[
            if (l_isfalse($EXP)) {
                $VAR = 0;
            } else {
                $VAR = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif types.is_c_tvalue(typ) then
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif typ._tag == "Type.CInteger" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CInteger") then
        return render([[
            if (TITAN_LIKELY(ttisinteger($EXP))) {
                $VAR = ($CT)ivalue($EXP);
            } else if (ttisfloat($EXP)) {
                lua_Number _v = fltvalue($EXP);
                lua_Number _flt = l_floor(_v);
                lua_Integer _i;
                if (TITAN_UNLIKELY(_v != _flt)) {
                    $THROWFLOAT
                } else if (TITAN_UNLIKELY(!lua_numbertointeger(_flt, &_i))) {
                    $THROWFLOAT
                } else {
                    $VAR = ($CT)_i;
                }
            } else {
                $THROWINTEGER
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = foreignctype(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROWFLOAT = codethrow(loc, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINTEGER = codethrow(loc, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        return render([[
            if (TITAN_LIKELY(ttisfloat($EXP))) {
                $VAR = ($CT)fltvalue($EXP);
            } else if (ttisinteger($EXP)) {
                $VAR = ($CT)ivalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = foreignctype(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif types.is_c_udata_pointer(typ) then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
                $VAR = ($CT)uvalue($EXP);
            } else if (ttisnil($EXP)) {
                $VAR = NULL;
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = foreignctype(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected C userdata pointer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.CPointer" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CPointer") then
        return render([[
            if (TITAN_LIKELY(ttislightuserdata($EXP))) {
                $VAR = ($CT)pvalue($EXP);
            } else if (ttisnil($EXP)) {
                $VAR = NULL;
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = foreignctype(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected C pointer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.COwned" then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP)
                    && uvalue($EXP)->metatable == hvalue(&_mod->uv[$META].uv))) {
                $VAR = uvalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            META = c_integer_literal(owned_c_metatable(ctx, typ)),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", {
                "$FILE", "$LINE", "$COL",
                c_string_literal(types.tostring(typ)),
                "lua_typename(L, ttype($EXP))"
            })
        })
    elseif typ._tag == "Type.Nil" then tag = "nil"
    elseif typ._tag == "Type.String" then tag = "string"
    elseif typ._tag == "Type.Array" then tag = "table"
    elseif typ._tag == "Type.Map" then tag = "table"
    elseif typ._tag == "Type.Value" then
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif typ._tag == "Type.Function" then
        -- No callability check at the boundary: a function-typed value is
        -- stored boxed exactly like `value`. If it turns out not to be
        -- callable, luaD_callnoyield raises cleanly when it is actually called.
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if(ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECKANDSET
            }
        ]], {
            VAR = cvar,
            EXP = exp,
            CHECKANDSET = checkandset(ctx, typ.base, "&" .. cvar, exp, loc)
        })
    elseif typ._tag == "Type.Nominal" then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
              Udata* _ud = uvalue($EXP);
              if (TITAN_LIKELY(_ud->metatable == $MT)) {
                $VAR = _ud;
              } else {
                lua_pushlightuserdata(L, (void*)_ud->metatable);
                if (lua_rawget(L, LUA_REGISTRYINDEX) == LUA_TNIL) {
                    lua_pop(L, 1);
                    setuvalue(L, s2v(L->top.p), _ud); L->top.p++;
                    $THROWNIL
                } else {
                    $THROWUD
                }
              }
            } else {
              $THROWPRIM
            }
        ]], {
            MT = render("hvalue(&_mod->uv[$I].uv)", { I = c_integer_literal(type2metatable(ctx, typ)) }),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            EXP = exp,
            VAR = cvar,
            NAME = types.tostring(typ),
            THROWNIL = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "luaL_tolstring(L, -1, NULL)" }),
            THROWUD = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "lua_tostring(L, -1)" }),
            THROWPRIM = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "lua_typename(L, ttype($EXP))" })
        })
    else
        error("invalid type " .. types.tostring(typ))
    end
    return render([[
        if (TITAN_LIKELY($PREDICATE($EXP))) {
            $GETSLOT;
        } else {
            $THROW
        }
    ]], {
        EXP = exp,
        TAG = c_string_literal(tag),
        PREDICATE = 'ttis'..tag,
        GETSLOT = getslot(typ, cvar, exp),
        FILE = c_string_literal(loc.filename),
        LINE = c_integer_literal(loc.line),
        COL = c_integer_literal(loc.col),
        THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", "$TAG", "lua_typename(L, ttype($EXP))" })
    })
end

function checkandset(ctx, typ --[[:table]], dst --[[:string]], src --[[:string]], loc --[[:table]])
    local tag
    if typ._tag == "Type.Integer" then
        -- Accept an integral float (and reject a non-integral or out-of-range
        -- one) exactly like checkandget, so an integer? slot/parameter is
        -- consistent with a plain integer at the Lua boundary.
        return render([[
            if (TITAN_LIKELY(ttisinteger($SRC))) {
                setobj2t(L, $DST, $SRC);
            } else if (ttisfloat($SRC)) {
                lua_Number _v = fltvalue($SRC);
                lua_Number _flt = l_floor(_v);
                lua_Integer _i;
                if (TITAN_UNLIKELY(_v != _flt)) {
                    $THROWFLOAT
                } else if (TITAN_UNLIKELY(!lua_numbertointeger(_flt, &_i))) {
                    $THROWFLOAT
                } else {
                    setivalue($DST, _i);
                }
            } else {
                $THROWINT
            }
        ]], {
            SRC = src,
            DST = dst,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROWFLOAT = codethrow(loc, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINT = codethrow(loc, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($SRC))" })
        })
    elseif typ._tag == "Type.Float" then
        return render([[
            if (TITAN_LIKELY(ttisfloat($SRC))) {
                setobj2t(L, $DST, $SRC);
            } else if (ttisinteger($SRC)) {
                setfltvalue($DST, ((lua_Number)ivalue($SRC)));
            } else {
                $THROW
                luaL_error(L, "%s:%d:%d: type error, expected float but found %s", $FILE, $LINE, $COL, lua_typename(L, ttype($SRC)));
            }
        ]], {
            SRC = src,
            DST = dst,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($SRC))" })
        })
    elseif typ._tag == "Type.Boolean" then tag = "boolean"
    elseif typ._tag == "Type.Nil" then tag = "nil"
    elseif typ._tag == "Type.String" then tag = "string"
    elseif typ._tag == "Type.Array" then tag = "table"
    elseif typ._tag == "Type.Map" then tag = "table"
    elseif typ._tag == "Type.Value" then
        return render([[
            setobj2t(L, $DST, $SRC);
        ]], {
            SRC = src,
            DST = dst,
        })
    elseif typ._tag == "Type.Function" then
        -- Like `value`: store boxed with no callability check (deferred to the
        -- call). Used when a function value crosses the boundary into a record
        -- field or map slot.
        return render([[
            setobj2t(L, $DST, $SRC);
        ]], {
            SRC = src,
            DST = dst,
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if(ttisnil($SRC)) {
                setnilvalue($DST);
            } else {
                $CHECKANDSET
            }
        ]], {
            SRC = src,
            DST = dst,
            CHECKANDSET = checkandset(ctx, typ.base, dst, src, loc)
        })
    elseif typ._tag == "Type.Nominal" then
        return render([[
            {
              Udata *_recval = NULL;
              $CHECKANDGET
              setuvalue(L, $DST, _recval);
            }
        ]], {
            CHECKANDGET = checkandget(ctx, typ, "_recval", src, loc),
            DST = dst
        })
    else
        error("invalid type " .. types.tostring(typ))
    end
    return render([[
        if (TITAN_LIKELY($PREDICATE($SRC))) {
            setobj2t(L, $DST, $SRC);
        } else {
            $THROW
        }
    ]], {
        TAG = c_string_literal(tag),
        PREDICATE = 'ttis'..tag,
        SRC = src,
        DST = dst,
        FILE = c_string_literal(loc.filename),
        LINE = c_integer_literal(loc.line),
        COL = c_integer_literal(loc.col),
        THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", "$TAG", "lua_typename(L, ttype($SRC))" })
    })
end

local function setslot(typ --[[:table]], dst --[[:string]], src --[[:string]])
    local tmpl
    if typ._tag == "Type.Integer" then tmpl = "setivalue($DST, $SRC);"
    elseif typ._tag == "Type.Float" then tmpl = "setfltvalue($DST, $SRC);"
    elseif typ._tag == "Type.Boolean" then tmpl = "titan_setbvalue($DST, $SRC);"
    elseif typ._tag == "Type.Nil" then tmpl = "setnilvalue($DST); ((void)$SRC);"
    elseif typ._tag == "Type.String" then tmpl = "setsvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Array" then tmpl = "sethvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Map" then tmpl = "sethvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Value" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif types.is_c_tvalue(typ) then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif typ._tag == "Type.Nominal" then tmpl = "setuvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Option" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif typ._tag == "Type.Function" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif typ._tag == "Type.CInteger" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CInteger") then
        tmpl = "setivalue($DST, ((lua_Integer)$SRC));"
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        tmpl = "setfltvalue($DST, ((lua_Number)$SRC));"
    elseif types.is_c_udata_pointer(typ) then
        tmpl = [[do {
            Udata *_titan_u = (Udata *)($SRC);
            if (_titan_u == NULL) setnilvalue($DST);
            else setuvalue(L, $DST, _titan_u);
        } while (0);]]
    elseif typ._tag == "Type.CPointer" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CPointer") then
        tmpl = "setpvalue($DST, ((void*)$SRC));"
    elseif typ._tag == "Type.CArray" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CArray") then
        tmpl = "setpvalue($DST, ((void*)$SRC));"
    elseif typ._tag == "Type.COwned" then
        tmpl = "setuvalue(L, $DST, $SRC);"
    else
        error("invalid type " .. types.tostring(typ))
    end
    local code = render(tmpl, { DST = dst, SRC = src })
    return code
end

local function setwrapped(typ --[[:table]], dst --[[:string]], src --[[:string]])
    if typ._tag == "Type.Nominal" then
        -- A record value IS the Udata; hand Lua the udata directly ($SRC is a
        -- Udata*).
        return render([[
            setuvalue(L, $DST, $SRC);
        ]], {
            DST = dst,
            SRC = src
        })
    elseif typ._tag == "Type.Option" and typ.base._tag == "Type.Nominal" then
        -- $SRC is a TValue already holding the udata value.
        return render([[
            do {
                TValue _titan_v = $SRC;
                if(ttisnil(&_titan_v)) {
                setnilvalue($DST);
                } else {
                    setobj2t(L, $DST, &_titan_v);
                }
            } while (0);
        ]], {
            DST = dst,
            SRC = src
        })
    else
        return setslot(typ, dst, src)
    end
end

-- A record value is now the Udata held directly in the slot, so for every type
-- (nominal, option-of-nominal, or otherwise) the slot already holds the final
-- TValue to copy out verbatim — no type dispatch needed (unlike setwrapped).
local function copyslotwrapped(dst, src)
    return render([[
        setobj2t(L, $DST, $SRC);
    ]], {
        DST = dst,
        SRC = src
    })
end

foreignctype = function(typ --[[:table]])
    if typ._tag == "Type.CTypedef" then
        return typ.name
    elseif typ._tag == "Type.COwned" then
        return "Udata*"
    elseif typ._tag == "Type.CVoid" then
        return "void"
    elseif typ._tag == "Type.CInteger" or typ._tag == "Type.CFloat" then
        return typ.spelling
    elseif typ._tag == "Type.CStruct" then
        return "struct " .. (typ.tagname or typ.cname)
    elseif typ._tag == "Type.CUnion" then
        return "union " .. (typ.tagname or typ.cname)
    elseif typ._tag == "Type.CArray" then
        return foreignctype(typ.elem) .. "*"
    elseif typ._tag == "Type.CPointer" then
        local pointee = types.resolve_c_typedef(typ.pointee)
        local quals = typ.quals and #typ.quals > 0
            and table.concat(typ.quals, " ") .. " " or ""
        if pointee._tag == "Type.CFunction" then
            local params = {}
            for _, param in ipairs(pointee.params) do
                table.insert(params, foreignctype(param))
            end
            if pointee.vararg then
                table.insert(params, "...")
            end
            if #params == 0 then
                table.insert(params, "void")
            end
            return render("$RET (*$QUALS)($PARAMS)", {
                RET = foreignctype(pointee.ret),
                QUALS = quals,
                PARAMS = table.concat(params, ", "),
            })
        end
        return quals .. foreignctype(typ.pointee) .. " *"
    elseif typ._tag == "Type.Pointer" then
        if typ.type._tag == "Type.Nil" then
            return "void*"
        end
        if typ.type._tag == "Type.Typedef" then
            return typ.type.name .. "*"
        end
        return foreignctype(typ.type) .. "*"
    elseif typ._tag == "Type.String" then
        return "char*"
    end
    error("FIXME unknown foreign c type: "..types.tostring(typ))
end

local function foreigncdecl(typ, name)
    if typ._tag == "Type.CPointer" then
        local pointee = types.resolve_c_typedef(typ.pointee)
        if pointee._tag == "Type.CFunction" then
            local params = {}
            for _, param in ipairs(pointee.params) do
                table.insert(params, foreignctype(param))
            end
            if pointee.vararg then
                table.insert(params, "...")
            end
            if #params == 0 then
                table.insert(params, "void")
            end
            local quals = typ.quals and #typ.quals > 0
                and " " .. table.concat(typ.quals, " ") .. " " or ""
            return render("$RET (*$QUALS$NAME)($PARAMS)", {
                RET = foreignctype(pointee.ret),
                QUALS = quals,
                NAME = name,
                PARAMS = table.concat(params, ", "),
            })
        end
    end
    return foreignctype(typ) .. " " .. name
end

local function foreigncast(exp, typ --[[:table]])
    return render([[(($CASTTYPE)($CEXP))]], {
        CASTTYPE = foreignctype(typ),
        CEXP = exp,
    })
end

local function ctype(typ --[[:table]])
    if typ._tag == "Type.Integer" then return "lua_Integer"
    elseif typ._tag == "Type.Float" then return "lua_Number"
    elseif typ._tag == "Type.Boolean" then return "int"
    elseif typ._tag == "Type.Nil" then return "int"
    elseif typ._tag == "Type.String" then return "TString*"
    elseif typ._tag == "Type.Array" then return "Table*"
    elseif typ._tag == "Type.Map" then return "Table*"
    elseif typ._tag == "Type.Value" then return "TValue"
    elseif typ._tag == "Type.Nominal" then return "Udata*"
    elseif typ._tag == "Type.Pointer" then return foreignctype(typ)
    elseif typ._tag == "Type.COwned" then return "Udata*"
    elseif types.is_c(typ) then return foreignctype(typ)
    elseif typ._tag == "Type.Option" then return "TValue"
    -- A first-class function value is boxed (it may be a Titan closure, a Lua
    -- closure, a C function, or a `__call` object), like `value`/`option`.
    elseif typ._tag == "Type.Function" then return "TValue"
    -- A foreign typedef of a supported scalar (e.g. size_t -> integer) can
    -- leak in via inference; use the C type of its resolved underlying type.
    elseif typ._tag == "Type.Typedef" then return ctype(typ._type)
    else error("invalid type " .. types.tostring(typ))
    end
end

local function initval(typ --[[:table]])
    if typ._tag == "Type.Value" or typ._tag == "Type.Option"
       or typ._tag == "Type.Function" or types.is_c_tvalue(typ) then
        return "{ {0}, 0 }"
    else return "0" end
end

-- Plain C declaration for Titan-visible locals/parameters. Setjmp-sensitive
-- values are protected by explicit spill/reload slots below, keeping the source
-- local/param C autos ordinary (and avoiding volatile in the function ABI).
local function cvardecl(ctx, typ, name)
    if types.is_c(typ) and typ._tag ~= "Type.CTypedef" then
        return foreigncdecl(typ, name)
    end
    return ctype(typ) .. " " .. name
end

-- A statement after which control never falls through (return/break/raise). The
-- checker does NOT type-check statements that follow such a terminator within a
-- block (they are dead code: their var uses get no `_decl`/`_type`), so the coder
-- MUST NOT attempt to generate them — doing so dereferences those nil
-- annotations. Stopping at the terminator also drops the unreachable C. (This
-- predates error handling: `raise`/`return` followed by any var-using statement
-- always produced unchecked nodes; it only became reachable now that `raise`
-- routinely precedes dead code in try bodies.)
local function is_terminator(node)
    local tag = node._tag
    return tag == "Ast.StatReturn" or tag == "Ast.StatBreak"
        or tag == "Ast.StatRaise"
end

-- The last statement that control can reach in a block's `stats` (the first
-- terminator, or the final statement if none terminates). Mirrors codestats'
-- dead-code stop, so it reflects exactly what the coder emitted.
local function last_reachable_stat(block)
    local last
    for _, s in ipairs(block.stats) do
        last = s
        if is_terminator(s) then break end
    end
    return last
end

local function set_add(set, decl)
    if decl then set[decl] = true end
end

local function set_union(dst, src)
    if not src then return dst end
    for k in pairs(src) do dst[k] = true end
    return dst
end

local function set_copy(src)
    return set_union({}, src)
end

-- C `setjmp` correctness (C11 §7.13.2.1): an automatic variable of a function
-- that calls `setjmp`, is changed between that `setjmp` and its matching
-- `longjmp`, and is read after the longjmp has an indeterminate value unless the
-- read is made from volatile-backed storage. We do not make every local/param
-- volatile. Instead this pass marks only Decl objects assigned in a protected
-- region whose post-longjmp path can read them. Codegen then keeps GC values in
-- their existing Lua-stack slots and uses tiny volatile C spill slots only for
-- non-GC scalars.
local collect_reads_exp, collect_reads_stat, collect_writes_stat

local function collect_reads_var(node, out)
    if not node then return out end
    local tag = node._tag
    if tag == "Ast.VarName" then
        set_add(out, node._decl)
    elseif tag == "Ast.VarDot" then
        collect_reads_exp(node.exp, out)
        if node._decl and node._decl._tag == "Ast.Decl" then
            set_add(out, node._decl)
        end
    elseif tag == "Ast.VarBracket" then
        collect_reads_exp(node.exp1, out)
        collect_reads_exp(node.exp2, out)
    end
    return out
end

local function collect_lvalue_reads(node, out)
    if not node then return out end
    local tag = node._tag
    if tag == "Ast.VarDot" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.VarBracket" then
        collect_reads_exp(node.exp1, out)
        collect_reads_exp(node.exp2, out)
    end
    return out
end

local function collect_lvalue_write(node, out)
    if node and node._decl and node._decl._tag == "Ast.Decl" then
        set_add(out, node._decl)
    end
    return out
end

local function collect_reads_block(node, out)
    out = out or {}
    if not node then return out end
    for _, stat in ipairs(node.stats) do
        collect_reads_stat(stat, out)
        if is_terminator(stat) then break end
    end
    return out
end

local function collect_writes_block(node, out)
    out = out or {}
    if not node then return out end
    for _, stat in ipairs(node.stats) do
        collect_writes_stat(stat, out)
        if is_terminator(stat) then break end
    end
    return out
end

collect_reads_exp = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.VarName" or tag == "Ast.VarDot"
            or tag == "Ast.VarBracket" then
        collect_reads_var(node, out)
    elseif tag == "Ast.ExpVar" then
        collect_reads_var(node.var, out)
    elseif tag == "Ast.ExpInitList" then
        for _, field in ipairs(node.fields) do
            collect_reads_exp(field.exp, out)
        end
    elseif tag == "Ast.ExpCall" then
        collect_reads_exp(node.exp, out)
        for _, arg in ipairs(node.args.args) do
            collect_reads_exp(arg, out)
        end
    elseif tag == "Ast.ExpUnop" or tag == "Ast.ExpCast"
            or tag == "Ast.ExpAdjust" or tag == "Ast.ExpDotsIndex" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpBinop" then
        collect_reads_exp(node.lhs, out)
        collect_reads_exp(node.rhs, out)
    elseif tag == "Ast.ExpConcat" then
        for _, exp in ipairs(node.exps) do
            collect_reads_exp(exp, out)
        end
    elseif tag == "Ast.ExpExtra" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpMethodRef" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpFunction" then
        -- Nested functions/lambdas have their own setjmp scopes and contexts.
    else
        -- literals, ExpDots, ExpDotsLen
    end
    return out
end

collect_reads_stat = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        collect_reads_block(node, out)
    elseif tag == "Ast.StatDecl" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatAssign" then
        for _, var in ipairs(node.vars) do collect_lvalue_reads(var, out) end
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatCall" then
        collect_reads_exp(node.callexp, out)
    elseif tag == "Ast.StatReturn" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatRaise" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.StatWhile" then
        collect_reads_exp(node.condition, out)
        collect_reads_block(node.block, out)
    elseif tag == "Ast.StatRepeat" then
        collect_reads_block(node.block, out)
        collect_reads_exp(node.condition, out)
    elseif tag == "Ast.StatFor" then
        collect_reads_exp(node.start, out)
        collect_reads_exp(node.finish, out)
        collect_reads_exp(node.inc, out)
        collect_reads_block(node.block, out)
    elseif tag == "Ast.StatForIn" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
        collect_reads_block(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            collect_reads_exp(t.condition, out)
            collect_reads_block(t.block, out)
        end
        collect_reads_block(node.elsestat, out)
    elseif tag == "Ast.StatTry" then
        collect_reads_block(node.block, out)
        collect_reads_block(node.catchblock, out)
        collect_reads_block(node.finallyblock, out)
    else
        -- StatBreak has no reads.
    end
    return out
end

collect_writes_stat = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        collect_writes_block(node, out)
    elseif tag == "Ast.StatDecl" then
        for _, decl in ipairs(node.decls) do set_add(out, decl) end
    elseif tag == "Ast.StatAssign" then
        for _, var in ipairs(node.vars) do collect_lvalue_write(var, out) end
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
            or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
        if tag == "Ast.StatForIn" then
            for _, decl in ipairs(node.decls) do set_add(out, decl) end
        end
        collect_writes_block(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do collect_writes_block(t.block, out) end
        collect_writes_block(node.elsestat, out)
    elseif tag == "Ast.StatTry" then
        collect_writes_block(node.block, out)
        collect_writes_block(node.catchblock, out)
        collect_writes_block(node.finallyblock, out)
    end
    return out
end

local function mark_spills(assigned, reads)
    for decl in pairs(assigned) do
        if reads[decl] then decl._needs_spill = true end
    end
end

local function analyze_try_spills_block(block, after_reads)
    if not block or not block.stats then return end
    local stats = {}
    for _, stat in ipairs(block.stats) do
        table.insert(stats, stat)
        if is_terminator(stat) then break end
    end
    local after = set_copy(after_reads or {})
    for i = #stats, 1, -1 do
        local stat = stats[i]
        local tag = stat._tag
        if tag == "Ast.StatBlock" then
            analyze_try_spills_block(stat, after)
        elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
                or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
            local loop_after = set_copy(after)
            collect_reads_stat(stat, loop_after)
            analyze_try_spills_block(stat.block, loop_after)
        elseif tag == "Ast.StatIf" then
            for _, t in ipairs(stat.thens) do
                analyze_try_spills_block(t.block, after)
            end
            analyze_try_spills_block(stat.elsestat, after)
        elseif tag == "Ast.StatTry" then
            local catch_reads = collect_reads_block(stat.catchblock)
            local finally_reads = collect_reads_block(stat.finallyblock)

            -- A body error reaches code after the try only if a catch can handle
            -- it. A finally-only body error re-raises after the finally, so only
            -- the finally can observe body-written values on that longjmp path.
            local body_boundary_reads = set_copy(catch_reads)
            set_union(body_boundary_reads, finally_reads)
            if stat.catchblock then set_union(body_boundary_reads, after) end
            mark_spills(collect_writes_block(stat.block), body_boundary_reads)

            -- The catch has a protected boundary only when a finally follows; if
            -- it raises, dispatch re-raises after the finally, so post-try code is
            -- not reached on that longjmp path.
            if stat.catchblock and stat.finallyblock then
                mark_spills(collect_writes_block(stat.catchblock), finally_reads)
            end

            local nested_body_after = set_copy(after)
            set_union(nested_body_after, catch_reads)
            set_union(nested_body_after, finally_reads)
            analyze_try_spills_block(stat.block, nested_body_after)

            local nested_catch_after = set_copy(after)
            set_union(nested_catch_after, finally_reads)
            analyze_try_spills_block(stat.catchblock, nested_catch_after)
            analyze_try_spills_block(stat.finallyblock, after)
        end

        local reads = collect_reads_stat(stat)
        if is_terminator(stat) then
            after = reads
        else
            set_union(reads, after)
            after = reads
        end
    end
end

local function analyze_try_spills(block)
    analyze_try_spills_block(block, {})
end

-- A non-void/non-nil function whose last reachable statement is something other
-- than a plain `StatReturn` (a `raise`, or a `StatTry`/`if` whose arms all
-- return) falls off the end of the generated C even though Titan control never
-- reaches there: the returns live inside an inner C scope or after a `lua_error`
-- (which Lua 5.5 declares returning `int`, NOT `l_noret`), so the C compiler
-- cannot prove no-fall-through and warns "control reaches end of non-void
-- function". The checker has already proven the function always-returns, so emit
-- an unreachable trailing `return` of the zero value to satisfy the C control-
-- flow check (dead code; never executed). A function whose last reachable
-- statement IS a `StatReturn` needs nothing (the C return is right there).
local function unreachable_return(rettype, block)
    if not rettype or rettype._tag == "Type.Nil" then return nil end
    local last = last_reachable_stat(block)
    if last and last._tag == "Ast.StatReturn" then return nil end
    -- A braced initializer (`{ {0}, 0 }` for TValue-boxed types) is illegal in a
    -- bare `return`, so zero a temp first and return it.
    return render([[
        /* unreachable: every path above already returned/raised; this satisfies
        ** the C control-flow check (Titan never falls through here) */
        {
            $TYPE _ur = $INIT;
            L->top.p = _base;
            return _ur;
        }]], { TYPE = ctype(rettype), INIT = initval(rettype) })
end

-- The `TitanVarg*` descriptor for a vararg of element type `elemtype`, keyed on
-- `ctype(elemtype)` so its element pointer has the exact C type (§2.F). Mirrors
-- titan.h's seven typedefs.
local varg_struct_by_ctype = {
    ["lua_Integer"] = "TitanVargInteger",
    ["lua_Number"]  = "TitanVargFloat",
    ["int"]         = "TitanVargBoolean",
    ["TString*"]    = "TitanVargString",
    ["Table*"]      = "TitanVargArrayOrMap",
    ["TValue"]      = "TitanVargValue",
    ["Udata*"]      = "TitanVargNominal",
}
local function varg_struct_name(elemtype --[[:table]])
    local ct = ctype(elemtype)
    local name = varg_struct_by_ctype[ct]
    if not name then
        error("no variadic struct for element ctype " .. ct
              .. " (type " .. types.tostring(elemtype) .. ")")
    end
    return name
end

-- The AST `node.params` keeps the trailing vararg marker Decl (`name == false`)
-- even after the checker lifts its element type onto the function type's
-- `varargtype` slot. The coder's param loops generate per-name C parameters, so
-- they must skip that marker (the vararg is emitted separately as the backing
-- struct + start). Returns the fixed-parameter Decls only.
local function fixed_params(params)
    local n = #params
    if n > 0 and params[n].name == false then
        local out = {}
        for i = 1, n - 1 do out[i] = params[i] end
        return out
    end
    return params
end


local function function_sig(fname, ftype, is_pointer)
    -- Every native entry takes the function's own closure (_fn) right after the
    -- module closure (_mod): NULL on the static path, the callee on a value call,
    -- the wrapper closure in the Lua entry. Closures read captured upvalues from
    -- it; top-level/static/method bodies ignore it. This uniform ABI lets the
    -- value-call fast path dispatch on the type tag alone.
    local params = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    if ftype._tag == "Type.Method" then
        table.insert(params, "Udata*")
    end
    for _, ptype in ipairs(ftype.params) do
        table.insert(params, ctype(ptype))
    end
    -- A variadic function takes its backing struct + start offset right after the
    -- declared params and before the out-params (§5.2). `varargtype` is the Titan
    -- vararg element type (false for non-variadic, and for C-FFI `vararg`).
    if ftype.varargtype then
        table.insert(params, varg_struct_name(ftype.varargtype) .. " *_varargs")
        table.insert(params, "int _start")
    end
    for i = 2, #ftype.rettypes do
        table.insert(params, ctype(ftype.rettypes[i]) .. "*")
    end
    -- A flexible result run is caller-owned typed storage. Keep this pair last
    -- so every fixed-only signature remains byte-for-byte unchanged.
    if ftype.flexrettype then
        table.insert(params,
            varg_struct_name(ftype.flexrettype) .. " *_flexout")
        table.insert(params, "int _flexwant")
    end
    local rettype = ftype.rettypes[1]
    local template = is_pointer
                     and "$RETTYPE (*$FNAME)($PARAMS)"
                     or  "$RETTYPE $FNAME($PARAMS)"
    return render(template, {
        -- a zero-return `() -> ()` function has a `void` native entry
        RETTYPE = rettype and ctype(rettype) or "void",
        FNAME = fname,
        PARAMS = table.concat(params, ", ")
    })
end

-- creates a new code generation context for a function
local function newcontext(tlcontext)
    return {
        tmp = 1,    -- next temporary index (for generating temporary names)
        nslots = 0, -- number of slots needed by function
        allocations = 0, -- number of allocations
        depth = 0,  -- current stack depth
        dstack = {}, -- stack of stack depths
        prefix = tlcontext.prefix, -- prefix for module member functions and variables
        names = {}, -- map of names to autoincrement suffixes for disambiguation,
        metatables = tlcontext.metatables, -- set of record metatables that we need
        functions = tlcontext.functions, -- set of external functions and methods that we call
        variables = tlcontext.variables, -- set of external variables that we use
        module = tlcontext.module, -- module name,
        modules = tlcontext.modules, -- set of record metatables that we need
        bound_luas = tlcontext.bound_luas, -- external bound-method Lua trampolines we bind
        tlcontext = tlcontext -- toplevel context
    }
end

-- Address a reserved Lua-stack slot by its stable stack offset. Lua's GC is
-- non-moving, so pointers to GC objects remain valid; only pointers into the
-- Lua stack must be recomputed after an operation that can reallocate it.
local function stackslotat(depth --[[:number]])
    return render("(restorestack(L, _base_off) + $DEPTH)", {
        DEPTH = c_integer_literal(depth),
    })
end

local function slotat(depth --[[:number]])
    return "s2v(" .. stackslotat(depth) .. ")"
end

local function reserveslot(ctx --[[:table]])
    local d = ctx.depth
    ctx.depth = ctx.depth + 1
    ctx.allocations = ctx.allocations + 1
    if ctx.depth > ctx.nslots then ctx.nslots = ctx.depth end
    ctx.uses_base_off = true
    return d
end

local function newslot(ctx --[[:table]])
    return slotat(reserveslot(ctx))
end

local function decl_needs_spill(decl)
    return decl and decl._needs_spill and decl._used and not decl._boxed
end

local function register_spill_decl(ctx, decl)
    if not decl_needs_spill(decl) then return end
    if ctx.spill_decl_seen and ctx.spill_decl_seen[decl] then return end
    ctx.spill_decl_seen = ctx.spill_decl_seen or {}
    ctx.spill_decl_seen[decl] = true
    ctx.active_spill_decls = ctx.active_spill_decls or {}
    table.insert(ctx.active_spill_decls, decl)
end

local function spill_cvar(decl)
    if not decl._spill_cvar then
        decl._spill_cvar = "_spill" .. decl._cvar
    end
    return decl._spill_cvar
end

local function spill_decl_init(ctx, decl)
    if not decl_needs_spill(decl) then return "" end
    register_spill_decl(ctx, decl)
    if types.is_gc(decl._type) then
        -- GC values already have a Lua-stack slot. That slot is the stable
        -- storage; no separate C spill is needed.
        return ""
    end
    return render([[
        volatile $CT $SPILL = $CVAR;
    ]], {
        CT = ctype(decl._type),
        SPILL = spill_cvar(decl),
        CVAR = decl._cvar,
    })
end

local function spill_decl_zero(ctx, decl)
    if not decl_needs_spill(decl) then return "" end
    register_spill_decl(ctx, decl)
    if types.is_gc(decl._type) then return "" end
    return render([[
        volatile $CT $SPILL = $INIT;
    ]], {
        CT = ctype(decl._type),
        SPILL = spill_cvar(decl),
        INIT = initval(decl._type),
    })
end

local function spill_update(decl)
    if not decl_needs_spill(decl) or types.is_gc(decl._type) then return "" end
    return render([[
        $SPILL = $CVAR;
    ]], {
        SPILL = spill_cvar(decl),
        CVAR = decl._cvar,
    })
end

local function spill_reload(ctx)
    local decls = ctx.active_spill_decls
    if not decls then return "" end
    local lines = {}
    for _, decl in ipairs(decls) do
        if decl_needs_spill(decl) then
            if types.is_gc(decl._type) then
                if decl._slot then
                    table.insert(lines,
                        getslot(decl._type, decl._cvar, decl._slot) .. ";")
                end
            elseif decl._spill_cvar then
                table.insert(lines, render("$CVAR = $SPILL;", {
                    CVAR = decl._cvar,
                    SPILL = decl._spill_cvar,
                }))
            end
        end
    end
    if #lines == 0 then return "" end
    return "/* reload setjmp-sensitive Titan locals/params */\n"
        .. table.concat(lines, "\n")
end

local function newtmp(ctx --[[:table]], typ --[[:table]], isgc --[[:boolean]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    if isgc then
        local slot = newslot(ctx)
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, typ, tmpname),
            INIT = initval(typ)
        }), tmpname, slot
    else
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, typ, tmpname),
            INIT = initval(typ)
        }), tmpname
    end
end

-- Evaluate already-generated expression code now, exactly once, and keep its
-- value stable across later expression setup. GC-able values are anchored in a
-- reserved stack slot so a subsequent collection cannot sweep them; the slot
-- itself is addressed by offset because a call may reallocate the Lua stack.
local function materialize_code(ctx, typ, stats, exp)
    local decl, name, slot = newtmp(ctx, typ, types.is_gc(typ))
    local anchor = slot and setslot(typ, slot, name) or ""
    return render([[
        $STATS
        $DECL
        $NAME = $EXP;
        $ANCHOR
    ]], {
        STATS = stats,
        DECL = decl,
        NAME = name,
        EXP = exp,
        ANCHOR = anchor,
    }), name
end

local function materialize(ctx, node)
    local stats, exp = codeexp(ctx, node)
    return materialize_code(ctx, node._type, stats, exp)
end

-- Generate call arguments in source order. A pure trailing suffix can remain as
-- direct C expressions: with no intervening statements, reordering those reads
-- is unobservable. Every argument at or before an effectful argument is frozen
-- at its source position, preventing later calls/checks from changing a
-- deferred local/global read. This preserves Titan's left-to-right semantics
-- without copying already-rooted pure GC arguments on every call.
local function expression_contains_call(node)
    local tag = node._tag
    if tag == "Ast.ExpCall" then
        return true
    elseif tag == "Ast.ExpCast" or tag == "Ast.ExpUnop"
           or tag == "Ast.ExpAdjust" then
        return expression_contains_call(node.exp)
    elseif tag == "Ast.ExpBinop" then
        return expression_contains_call(node.lhs)
            or expression_contains_call(node.rhs)
    end
    return false
end

local function ordered_call_args(ctx, args, n)
    local coded = {}
    for i = 1, n do
        local stats, exp = codeexp(ctx, args[i])
        coded[i] = {
            stats = stats,
            exp = exp,
            typ = args[i]._type,
            contains_call = expression_contains_call(args[i]),
        }
    end

    local freeze = {}
    local later_has_stats = false
    for i = n, 1, -1 do
        -- Foreign scalar calls can remain bare C expressions (no setup
        -- statements), so an AST call is effectful even when `stats` is empty.
        local has_stats = coded[i].stats ~= "" or coded[i].contains_call
        freeze[i] = has_stats or later_has_stats
        later_has_stats = later_has_stats or has_stats
    end

    local stats, exps = {}, {}
    for i = 1, n do
        local c = coded[i]
        if freeze[i] then
            local cstats, cexp =
                materialize_code(ctx, c.typ, c.stats, c.exp)
            stats[i], exps[i] = cstats, cexp
        else
            stats[i], exps[i] = c.stats, c.exp
        end
    end
    return stats, exps
end

-- A checked named call carries a dense formal-order argument list plus the
-- formal indexes of explicitly written expressions in lexical order. Freeze
-- each explicit expression immediately in that lexical order, then generate
-- the synthetic nil omissions. The returned expressions remain indexed by
-- formal position for the unchanged native ABI.
local function named_ordered_call_args(ctx, args, order)
    local stats = {}
    local exps = {}
    local seen = {}
    for _, index in ipairs(order) do
        assert(index >= 1 and index <= #args)
        assert(not seen[index], "duplicate formal index in named call order")
        assert(not args[index]._named_omitted)
        seen[index] = true
        local cstats, cexp = codeexp(ctx, args[index])
        local mstats, mexp = materialize_code(ctx, args[index]._type,
            cstats, cexp)
        table.insert(stats, mstats)
        exps[index] = mexp
    end
    for index, arg in ipairs(args) do
        if not seen[index] then
            assert(arg._named_omitted,
                "named call order omitted an explicit argument")
            local cstats, cexp = codeexp(ctx, arg)
            local mstats, mexp = materialize_code(ctx, arg._type,
                cstats, cexp)
            table.insert(stats, mstats)
            exps[index] = mexp
        end
    end
    return stats, exps
end

local function newforeigntmp(ctx --[[:table]], typ --[[:table]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local fdecl
    local finit = ""
    local rtyp = types.resolve_c_typedef(typ)
    if typ._tag == "Type.String" then
        fdecl = "char* " .. tmpname
        finit = " = NULL"
    elseif typ._tag == "Type.Pointer" or types.is_c(typ) then
        fdecl = types.is_c(typ) and foreigncdecl(typ, tmpname)
            or foreignctype(typ) .. " " .. tmpname
        if typ._tag == "Type.Pointer" or typ._tag == "Type.COwned"
           or rtyp._tag == "Type.CPointer" then
            finit = " = NULL"
        elseif rtyp._tag == "Type.CInteger" or rtyp._tag == "Type.CFloat" then
            finit = " = 0"
        elseif types.is_c_tvalue(typ) then
            finit = " = { {0}, 0 }"
        end
    else
        error("don't know how to convert foreign type "..types.tostring(typ))
    end
    return render([[
        $DECL$INIT;
    ]], {
        DECL = fdecl,
        INIT = finit,
    }), tmpname
end

-- A captured-and-mutated local/param is stored in a "box": a heap cell whose
-- single value holds the variable's value. The box pointer is the thing copied
-- into closures that capture the variable, so all sharers mutate one cell. The
-- box is a Lua *userdata* (`Udata*`), not a CClosure: a userdata's GC traversal
-- (`traverseudata`) calls `genlink`, so an overwriting write can use the BACK
-- barrier (`luaC_barrierback`) — which, unlike the forward barrier a CClosure
-- box would require, does not float fresh values written in a hot loop to the
-- old generation until the next major GC. A box never crosses a module boundary
-- (it backs a captured local inside one module's closures, and only that module
-- generates the code that touches it), so this representation is module-internal
-- and does not affect the cross-module ABI (no TITAN_VER bump).
--
-- Two representations, chosen by `is_rawbox` (= `not types.is_gc(typ)`):
--   (N) any non-gc type (integer/float/boolean/Nil/ordinary foreign
--       pointer/scalar typedef, plus an Option of a non-gc base whose TValue is
--       only ever nil-or-scalar): a 0-uservalue userdata (`Udata0`) with the
--       raw, non-collectable C value stored inline (`getudatamem`). No TValue
--       tagging and no barrier — ever.
--   (G) every gc type (TValue-stored: String/Array/Map/record/Function/Value,
--       COwned, C TValue, Lua-internal Udata*, and an Option of a gc base): a
--       1-uservalue userdata holding a TValue in `uv[0].uv`, written with the
--       BACK barrier.

-- A box uses the raw (N) representation iff its value can never hold a GC
-- pointer, i.e. `not types.is_gc(typ)`. `is_gc` is exactly the predicate that
-- governs every other barrier decision in the coder, so a non-gc type has no GC
-- reference and is safe to store raw and untraced in a Udata0. Because newbox /
-- box_read / box_write derive the storage type and size from ctype(typ) /
-- sizeof(ctype(typ)), any non-gc type works with no enumeration: integer, float,
-- boolean, Nil (a dummy int), an Option of a non-gc base (a TValue that is only
-- ever nil-or-scalar), ordinary foreign pointers, and scalar typedefs all route
-- here automatically. Everything that may hold a GC object uses (G).
local function is_rawbox(typ --[[:table]])
    return not types.is_gc(typ)
end

-- The C lvalue/rvalue for a box's stored value.
--   (G) -> "&BOX->uv[0].uv" (a TValue*, used with setslot/getslot)
--   (N) -> "*(CT *)getudatamem(BOX)" (the raw unboxed C value)
local function box_value_slot(boxvar)
    return "&" .. boxvar .. "->uv[0].uv"
end

-- Read a box's value as a C rvalue yielding the unboxed value.
local function box_read(typ --[[:table]], boxvar --[[:string]])
    if is_rawbox(typ) then
        return render("(*($CT *)getudatamem($BOX))",
            { CT = ctype(typ), BOX = boxvar })
    else
        return getslot(typ, nil, box_value_slot(boxvar))
    end
end

-- Write `cexp` into a box. (N) stores the raw scalar inline, no barrier.
-- (G) stores a TValue and, when the value may be collectable, runs the BACK
-- barrier (safe because the box is a genlink-managed userdata).
local function box_write(typ --[[:table]], boxvar --[[:string]], cexp --[[:string]])
    if is_rawbox(typ) then
        return render("*($CT *)getudatamem($BOX) = $CEXP;",
            { CT = ctype(typ), BOX = boxvar, CEXP = cexp })
    else
        local slot = box_value_slot(boxvar)
        local code = setslot(typ, slot, cexp)
        if types.is_gc(typ) then
            code = code .. render(
                "\nluaC_barrierback(L, obj2gco($BOX), $SLOT);",
                { BOX = boxvar, SLOT = slot })
        end
        return code
    end
end

-- `newbox` emits the box allocation: declares the `Udata*` C var, allocates the
-- cell inline (luaS_newudata expanded with the size check dropped — the size is
-- a tiny constant), and anchors the box in a fresh stack slot against the GC
-- BEFORE any later allocation. For (G) the value slot is nil'd before anchoring
-- so a GC triggered by a later alloc never traverses a garbage uv[0]. The caller
-- stores the initial value afterwards (via box_write).
--   typ:      the Titan type of the boxed variable (selects (G) vs (N))
--   boxvar:   name of the `Udata*` C variable to declare
--   slot: relocation-safe expression for the box's anchor slot
local function newbox(ctx, typ, boxvar, slot)
    if is_rawbox(typ) then
        return render([[
            Udata *$BOXVAR = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(0, sizeof($CT))));
            $BOXVAR->len = sizeof($CT); $BOXVAR->nuvalue = 0; $BOXVAR->metatable = NULL;
            setuvalue(L, $SLOT, $BOXVAR);
        ]], {
            BOXVAR = boxvar,
            SLOT = slot,
            CT = ctype(typ),
        })
    else
        return render([[
            Udata *$BOXVAR = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(1, 0)));
            $BOXVAR->len = 0; $BOXVAR->nuvalue = 1; $BOXVAR->metatable = NULL;
            setnilvalue(&$BOXVAR->uv[0].uv);
            setuvalue(L, $SLOT, $BOXVAR);
        ]], {
            BOXVAR = boxvar,
            SLOT = slot,
        })
    end
end

local function pushd(ctx)
    table.insert(ctx.dstack, ctx.depth)
end

local function popd(ctx)
    ctx.depth = table.remove(ctx.dstack)
end

local function push_spillscope(ctx)
    ctx.spill_scope_stack = ctx.spill_scope_stack or {}
    local n = ctx.active_spill_decls and #ctx.active_spill_decls or 0
    table.insert(ctx.spill_scope_stack, n)
end

local function pop_spillscope(ctx)
    local n = table.remove(ctx.spill_scope_stack)
    if not ctx.active_spill_decls then return end
    for i = #ctx.active_spill_decls, n + 1, -1 do
        local decl = ctx.active_spill_decls[i]
        ctx.active_spill_decls[i] = nil
        if ctx.spill_decl_seen then ctx.spill_decl_seen[decl] = nil end
    end
end

-- Does `node` (a statement, typically a StatBlock) lexically contain a `StatTry`,
-- WITHOUT descending into nested function bodies (ExpFunction has its own codegen
-- context, entry-wrapper boundary, and errorjmp save)? Used to (a) run the
-- per-function spill analysis and entry errorjmp-save setup, and (b) decide
-- whether a loop must save its errorjmp at entry so a `break` crossing a try
-- boundary can restore it.
local function stat_contains_try(node)
    if node == nil or node == false then return false end
    local tag = node._tag
    if tag == "Ast.StatTry" then
        return true
    elseif tag == "Ast.StatBlock" then
        for _, s in ipairs(node.stats) do
            if stat_contains_try(s) then return true end
        end
        return false
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatFor"
           or tag == "Ast.StatRepeat" or tag == "Ast.StatForIn" then
        if tag == "Ast.StatForIn" and node._has_close then
            return true
        end
        return stat_contains_try(node.block)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            if stat_contains_try(t.block) then return true end
        end
        return stat_contains_try(node.elsestat)
    else
        -- StatDecl/StatAssign/StatCall/StatReturn/StatBreak/StatRaise and any
        -- expression-bearing statement: no nested block that is not a function
        -- body of its own. ExpFunction bodies are intentionally NOT scanned.
        return false
    end
end

-- Emit the statements of a block's `stats` list, stopping after the first
-- terminator (the rest is unreachable, unchecked dead code).
local function codestats(ctx, stats_list)
    local out = {}
    for _, stat in ipairs(stats_list) do
        table.insert(out, codestat(ctx, stat))
        if is_terminator(stat) then break end
    end
    return out
end

-- All the code generation functions for STATEMENTS take
-- the function context and the AST node and return the
-- generated C code for the statement, as a string

local function codeblock(ctx, node)
    pushd(ctx)
    push_spillscope(ctx)
    local stats = codestats(ctx, node.stats)
    pop_spillscope(ctx)
    popd(ctx)
    return " {\n " .. table.concat(stats, "\n ") .. "\n }"
end

local function codetransparentblock(ctx, node)
    push_spillscope(ctx)
    local stats = codestats(ctx, node.stats)
    pop_spillscope(ctx)
    return table.concat(stats, "\n")
end

-- Open a loop frame (#3): if the loop body contains a try, allocate a save id so
-- a `break` crossing that try boundary can restore the loop-entry errorjmp/nC.
-- Returns the frame; the caller must `close_loop` after coding the body, then
-- splice `loop_save_lines(frame)` at loop entry.
local function open_loop(ctx, node)
    ctx.loop_after_id = (ctx.loop_after_id or 0) + 1
    local frame = { try_depth = ctx.try_depth or 0, after_id = ctx.loop_after_id }
    if stat_contains_try(node.block) then
        ctx.loop_save_id = (ctx.loop_save_id or 0) + 1
        frame.save_id = ctx.loop_save_id
    end
    ctx.loopstack = ctx.loopstack or {}
    table.insert(ctx.loopstack, frame)
    return frame
end

local function close_loop(ctx)
    table.remove(ctx.loopstack)
end

-- The loop-entry errorjmp/nC save lines, emitted ONLY if a `break` inside the
-- loop actually crossed a try boundary (frame.used, set in the StatBreak arm).
local function loop_save_lines(frame)
    if not (frame.save_id and frame.used) then return "" end
    return render([[
        lua_longjmp *_loop_errorjmp_$ID = L->errorJmp;
        l_uint32 _loop_nC_$ID = L->nCcalls;
    ]], { ID = c_integer_literal(frame.save_id) })
end

-- The label spliced immediately AFTER a loop so a PA_BREAK dispatch inside a
-- finally (which cannot use a bare C `break`) can `goto` past the loop. Emitted
-- only when such a break was actually generated (frame.uses_after_label).
local function after_loop_label(frame)
    if not frame.uses_after_label then return "" end
    return "\n_after_loop_" .. frame.after_id .. ": ;"
end

local function codewhile(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    local nallocs = ctx.allocations
    local cstats, cexp = codeexp(ctx, node.condition, true)
    local cblk = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    local tmpl
    if cstats == "" then
        tmpl = [[
            $LOOPSAVE
            while($CEXP) {
                $CBLK
                $CHECKGC
            }$AFTER
        ]]
    else
        tmpl = [[
            $LOOPSAVE
            while(1) {
                $CSTATS
                if(!($CEXP)) {
                    break;
                }
                $CBLK
                $CHECKGC
            }$AFTER
        ]]
    end
    return render(tmpl, {
        LOOPSAVE = loopsave,
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CBLK = cblk,
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        AFTER = after_loop_label(frame),
    })
end

local function coderepeat(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    local nallocs = ctx.allocations
    -- In Lua the `until` condition is in the scope of the body, so it may
    -- reference body-local variables. Code the body's statements INLINE (not
    -- wrapped in a nested C block) and then the condition, so both share one
    -- C scope and the body locals' C names are bound and still visible.
    local cblk = table.concat(codestats(ctx, node.block.stats), "\n")
    local cstats, cexp = codeexp(ctx, node.condition, true)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    return render([[
        $LOOPSAVE
        while(1) {
            $CBLK
            $CSTATS
            if($CEXP) {
                break;
            }
            $CHECKGC
        }$AFTER
    ]], {
        LOOPSAVE = loopsave,
        CBLK = cblk,
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        AFTER = after_loop_label(frame),
    })
end

local function codeif(ctx, node, idx)
    idx = idx or 1
    local cstats, cexp, cthn, cels
    if idx == #node.thens then -- last condition
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        -- Put the else body on its own line(s): a statement's code now begins
        -- with a `#line` directive, which must start
        -- a line — gluing it after `else ` on one line would put the `#` off
        -- column 1 and break compilation. `else\n<body>` is equally valid C.
        cels = node.elsestat and "else\n" .. codestat(ctx, node.elsestat) or ""
    else
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        cels = "else\n" .. codeif(ctx, node, idx + 1)
    end
    return render([[
        {
            $CSTATS
            if($CEXP) {
                $CTHN
            } $CELS
        }
    ]], {
        CSTATS = cstats,
        CEXP = toboolean(node.thens[idx].condition._type, cexp),
        CTHN = cthn,
        CELS = cels
    })
end

local function codefor(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    node.decl._cvar = "_local_" .. node.decl.name
    local csstats, csexp = codeexp(ctx, node.start)
    local cfstats, cfexp = codeexp(ctx, node.finish)
    local cistats, ciexp = codeexp(ctx, node.inc)
    local nallocs = ctx.allocations
    local cblock = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    -- Lua-faithful numeric for (see lvm.c forprep/forloop/floatforloop):
    -- a zero step raises a run-time error; the integer loop is driven by an
    -- unsigned iteration count so it cannot overflow past the integer limits
    -- into a non-terminating loop; and the visible control variable is a
    -- fresh copy each iteration (a separate internal index advances), so it
    -- is independent of the iteration and read-only.
    local subs = {
        LOOPSAVE = loopsave,
        CVAR = node.decl._cvar,
        -- declare the visible control variable only if the body uses it.
        CVARDECL = node.decl._used
            and (cvardecl(ctx, node.decl._type, node.decl._cvar) .. " = _foridx;") or "",
        CSSTATS = csstats, CSEXP = csexp,
        CFSTATS = cfstats, CFEXP = cfexp,
        CISTATS = cistats, CIEXP = ciexp,
        CBLOCK = cblock,
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        FILE = c_string_literal(node.loc.filename),
        LINE = node.loc.line,
        COL = node.loc.col,
        STEP0 = codethrow(node.loc, "%s:%d:%d: 'for' step is zero",
                          { "$FILE", "$LINE", "$COL" }),
        AFTER = after_loop_label(frame),
    }
    if node.decl._type._tag == "Type.Integer" then
        return render([[
            {
                $LOOPSAVE
                $CSSTATS
                lua_Integer _forstart = $CSEXP;
                $CFSTATS
                lua_Integer _forlimit = $CFEXP;
                $CISTATS
                lua_Integer _forstep = $CIEXP;
                if (_forstep == 0) {
                    $STEP0
                }
                if (_forstep > 0 ? (_forstart <= _forlimit) : (_forstart >= _forlimit)) {
                    lua_Unsigned _forcount = (_forstep > 0)
                        ? (l_castS2U(_forlimit) - l_castS2U(_forstart)) / l_castS2U(_forstep)
                        : (l_castS2U(_forstart) - l_castS2U(_forlimit)) / (l_castS2U(-(_forstep + 1)) + 1u);
                    lua_Integer _foridx = _forstart;
                    while (1) {
                        $CVARDECL
                        $CBLOCK
                        $CHECKGC
                        if (_forcount == 0) {
                            break;
                        }
                        _forcount--;
                        _foridx = l_castU2S(l_castS2U(_foridx) + l_castS2U(_forstep));
                    }
                }
            }$AFTER
        ]], subs)
    else
        return render([[
            {
                $LOOPSAVE
                $CSSTATS
                lua_Number _forstart = $CSEXP;
                $CFSTATS
                lua_Number _forlimit = $CFEXP;
                $CISTATS
                lua_Number _forstep = $CIEXP;
                if (_forstep == 0) {
                    $STEP0
                }
                if (_forstep > 0 ? (_forstart <= _forlimit) : (_forstart >= _forlimit)) {
                    lua_Number _foridx = _forstart;
                    while (1) {
                        $CVARDECL
                        $CBLOCK
                        $CHECKGC
                        _foridx += _forstep;
                        if (!(_forstep > 0 ? (_foridx <= _forlimit) : (_foridx >= _forlimit))) {
                            break;
                        }
                    }
                }
            }$AFTER
        ]], subs)
    end
end

-- Reads the entry for key $K (a boxed TValue*) of table $T into a local
-- TValue holder and points $SLOT at it. Lua 5.5's luaH_get* functions
-- copy the value out and return its tag (leaving the holder untouched
-- when the key is absent), so the holder is set to nil on a miss.
local function get_table_key(keytype, t, k, slot)
    local tgetkey
    if keytype._tag == "Type.String" then
        tgetkey = [[
            TValue ${SLOT}_v;
            lu_byte ${SLOT}_tag;
            if (ttypetag($K) == LUA_VSHRSTR) {
                ${SLOT}_tag = luaH_getshortstr($T, tsvalue($K), &${SLOT}_v);
            } else {
                ${SLOT}_tag = luaH_get($T, $K, &${SLOT}_v);
            }
            if (tagisempty(${SLOT}_tag)) {
                setnilvalue(&${SLOT}_v);
            }
            $SLOT = &${SLOT}_v;
        ]]
    elseif keytype._tag == "Type.Integer" then
        tgetkey = [[
            TValue ${SLOT}_v;
            lu_byte ${SLOT}_tag = luaH_getint($T, ivalue($K), &${SLOT}_v);
            if (tagisempty(${SLOT}_tag)) {
                setnilvalue(&${SLOT}_v);
            }
            $SLOT = &${SLOT}_v;
        ]]
    elseif keytype._tag == "Type.Float" then
        tgetkey = [[
            TValue ${SLOT}_v;
            lu_byte ${SLOT}_tag;
            {
                lua_Integer _ik;
                if (luaV_tointeger($K, &_ik, F2Ieq)) {
                    ${SLOT}_tag = luaH_getint($T, _ik, &${SLOT}_v);
                } else {
                    ${SLOT}_tag = luaH_get($T, $K, &${SLOT}_v);
                }
            }
            if (tagisempty(${SLOT}_tag)) {
                setnilvalue(&${SLOT}_v);
            }
            $SLOT = &${SLOT}_v;
        ]]
    else
        tgetkey = [[
            TValue ${SLOT}_v;
            lu_byte ${SLOT}_tag = luaH_get($T, $K, &${SLOT}_v);
            if (tagisempty(${SLOT}_tag)) {
                setnilvalue(&${SLOT}_v);
            }
            $SLOT = &${SLOT}_v;
        ]]
    end
    return render(tgetkey, {
        SLOT = slot,
        T = t,
        K = k,
    })
end

-- Stores the TValue $V into table $T at key $K (a boxed TValue*).
-- Lua 5.5 removed the "get a writable slot" API (luaH_newkey is gone);
-- raw stores go through luaH_set/luaH_setint, which take the value.
-- The GC barrier for the stored value is the caller's responsibility;
-- new keys are barriered internally by the insertion code.
local function set_table_entry(keytype, t, k, v)
    local tsetkey
    if keytype._tag == "Type.Integer" then
        tsetkey = [[
            luaH_setint(L, $T, ivalue($K), $V);
        ]]
    elseif keytype._tag == "Type.Float" then
        tsetkey = [[
            {
                lua_Integer _ik;
                if (luaV_tointeger($K, &_ik, F2Ieq)) {
                    luaH_setint(L, $T, _ik, $V);
                } else {
                    luaH_set(L, $T, $K, $V);
                }
            }
        ]]
    else
        tsetkey = [[
            luaH_set(L, $T, $K, $V);
            invalidateTMcache($T);
        ]]
    end
    return render(tsetkey, {
        T = t,
        K = k,
        V = v,
    })
end

local codecfield
local codecindex_parts

local function codeassignment(ctx, var, cexp, etype)
    local vtag = var._tag
    if vtag == "Ast.VarName" or (vtag == "Ast.VarDot" and var._decl) then
        if vtag == "Ast.VarDot" and var._decl._tag == "Type.Field" then
            local lstats, lexp = codeexp(ctx, var.exp)
            local index = var._decl.index
            return render([[
                $STATS
                {
                    Udata *_recobj = $RECORD;
                    TValue *_fieldslot = &(_recobj->uv[$INDEX].uv);
                    $SETSLOT
                    $BARRIER
                }
            ]], {
                STATS = lstats,
                RECORD = lexp,
                INDEX = index,
                SETSLOT = setslot(var._type, "_fieldslot", cexp),
                BARRIER = types.is_gc(var._type)
                          and "luaC_barrierback(L, obj2gco(_recobj), _fieldslot);" or ""
            })
        elseif vtag == "Ast.VarDot" and var._decl._tag == "Type.CField" then
            local lstats, lexp = codecfield(ctx, var)
            return render([[
                $STATS
                $FIELD = $CEXP;
            ]], {
                STATS = lstats,
                FIELD = lexp,
                CEXP = cexp,
            })
        elseif vtag == "Ast.VarDot" then -- module variable
            assert(var._decl._tag == "Type.ModuleVariable")
            ctx.variables[var.exp.var.name .. "." .. var.name] = {
                module = var.exp.var.name,
                name = var.name,
                slot = var._decl._slot
            }
            return render([[
                {
                    Udata *_imod = uvalue(&_mod->uv[$MODINDEX].uv);
                    TValue *_varslot = &_imod->uv[$VARINDEX].uv;
                    $SETSLOT;
                    $BARRIER
                }
            ]], {
                SETSLOT = setslot(var._type, "_varslot", cexp),
                BARRIER = types.is_gc(var._type)
                          and "luaC_barrierback(L, obj2gco(_imod), _varslot);" or "",
                MODINDEX = c_integer_literal(var.exp.var._decl._upvalue),
                VARINDEX = c_integer_literal(var._decl._upvalue)
            })
        elseif var._decl._tag == "Ast.TopLevelVar" then
            local cset = setslot(var._type, var._decl._slot, cexp)
            if types.is_gc(var._type) then
                cset = cset .. "\nluaC_barrierback(L, obj2gco(_mod), " .. var._decl._slot .. ");"
            end
            return cset
        elseif ctx.captures and ctx.captures[var._decl] then
            -- Inside a lambda body: write to a captured (boxed) variable through
            -- its box cell. By-value captures are immutable, so a write target is
            -- always boxed.
            local cap = ctx.captures[var._decl]
            return box_write(var._type, cap.boxvar, cexp)
        elseif var._decl._boxed then
            -- Captured-and-mutated local/param of the current function: write
            -- through its box cell.
            return box_write(var._type, var._decl._box, cexp)
        elseif var._decl._used and cexp ~= var._decl._cvar then
            local cset = ""
            if types.is_gc(var._type) then
                cset = setslot(var._type, var._decl._slot, var._decl._cvar)
            end
            return render([[
                $CVAR = $CEXP;
                $CSET
                $SPILL
            ]], {
                CVAR = var._decl._cvar,
                CEXP = cexp,
                CSET = cset,
                SPILL = spill_update(var._decl),
            })
        else
            return render([[
                ((void)$CEXP);
            ]], {
                CEXP = cexp,
            })
        end
    elseif vtag == "Ast.VarBracket" then
        local exp1type = var.exp1._type._tag
        if exp1type == "Type.Array" then
            local arr = var.exp1
            local idx = var.exp2
            local castats, caexp = codeexp(ctx, arr)
            local cistats, ciexp = codeexp(ctx, idx)
            return render([[
                {
                    $CASTATS
                    $CISTATS
                    Table *_t = $CAEXP;
                    lua_Integer _k = $CIEXP;
                    TValue _vv;
                    $SETVV
                    lua_Unsigned _actual_i = l_castS2U(_k) - 1u;
                    unsigned int _asize = _t->asize;
                    if (_actual_i < _asize) {
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                    } else if (_asize <= (UINT_MAX/2) && _actual_i < 2*(lua_Unsigned)_asize) {
                        luaH_resizearray(L, _t, cast_uint(2*(lua_Unsigned)_asize));
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                    } else {
                        luaH_setint(L, _t, _k, &_vv);
                    }
                    $BARRIER
                }
            ]], {
                CASTATS = castats,
                CISTATS = cistats,
                CAEXP = caexp,
                CIEXP = ciexp,
                SETVV = setwrapped(etype, "&_vv", cexp),
                BARRIER = types.is_gc(arr._type.elem)
                          and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            })
        elseif exp1type == "Type.Map" then
            local map = var.exp1
            local key = var.exp2
            local cmstats, cmexp = codeexp(ctx, map)
            local ckstats, ckexp = codeexp(ctx, key)
            local ctmpk, tmpkname, tmpkslot = newtmp(ctx, key._type, true)

            return render([[
                {
                    $CMSTATS
                    Table *_t = $CMEXP;
                    $CKSTATS
                    $CTMPK
                    $TMPKNAME = $CKEXP;
                    $SETSLOTK

                    TValue _vv;
                    $SETVV
                    $STORE
                    $BARRIER
                }
            ]], {
                CMSTATS = cmstats,
                CMEXP = cmexp,
                CKSTATS = ckstats,
                CTMPK = ctmpk,
                TMPKNAME = tmpkname,
                CKEXP = ckexp,
                SETSLOTK = setwrapped(key._type, tmpkslot, tmpkname),
                SETVV = setwrapped(etype, "&_vv", cexp),
                STORE = set_table_entry(key._type, "_t", tmpkslot, "&_vv"),
                BARRIER = types.is_gc(map._type.values)
                          and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            })
        elseif types.is_c(var.exp1._type) then
            local parts = codecindex_parts(ctx, var)
            return render([[
                {
                    $BSTATS
                    $ISTATS
                    $CIDX
                    $IDX = $IEXP;
                    $BOUNDS
                    $BASE[$IDX] = $CEXP;
                }
            ]], {
                BSTATS = parts.bstats,
                ISTATS = parts.istats,
                CIDX = parts.cidx,
                IDX = parts.idxname,
                IEXP = parts.iexp,
                BOUNDS = parts.bounds,
                BASE = parts.baseexp,
                CEXP = cexp,
            })
        end
    else
        error("invalid tag for lvalue of assignment: " .. vtag)
    end
end

-- Evaluate a checker-adjusted finite expression list once in lexical order.
-- Values delivered to fixed sink slots are materialized (and GC-rooted);
-- explicit surplus expressions are forced for effect and never acquire a fake
-- sink/output position. Returns the prelude plus fixed holder names/types.
function coder._codeadjustedfixed(ctx, node)
    local adjusted = node._result_adjustment
        or { exps = node.exps, fixed = node.exps, tail_scalars = {},
             discards = {}, open_source = false }
    assert(not adjusted.open_source and #adjusted.tail_scalars == 0)
    local fixed_index, discard_set = {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local stats, names, exptypes = {}, {}, {}
    for _, exp in ipairs(adjusted.exps) do
        local cstats, cexp = codeexp(ctx, exp)
        local i = fixed_index[exp]
        if i then
            local mstats, name
            if types.is_c(exp._type) and not types.is_gc(exp._type) then
                -- C structs/unions cannot be initialized from scalar zero;
                -- use the foreign declaration helper, which intentionally
                -- leaves aggregate temporaries uninitialized until assignment.
                local decl
                decl, name = newforeigntmp(ctx, exp._type)
                mstats = render([[
                    $CSTATS
                    $DECL
                    $NAME = $EXP;
                ]], {
                    CSTATS = cstats,
                    DECL = decl,
                    NAME = name,
                    EXP = cexp,
                })
            else
                mstats, name = materialize_code(ctx, exp._type,
                    cstats, cexp)
            end
            table.insert(stats, mstats)
            names[i], exptypes[i] = name, exp._type
        else
            assert(discard_set[exp] or exp._discard_results)
            table.insert(stats, cstats)
            table.insert(stats, "(void)(" .. cexp .. ");")
        end
    end
    return stats, names, exptypes
end

local function codesingleassignment(ctx, node)
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    table.insert(stats, codeassignment(ctx, node.vars[1],
        assert(tmps[1]), assert(exptypes[1])))
    return table.concat(stats, "\n")
end

local function codemultiassignment(ctx, node)
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    for i, var in ipairs(node.vars) do
        if tmps[i] then
            table.insert(stats,
                codeassignment(ctx, var, tmps[i], exptypes[i]))
        end
    end
    return table.concat(stats, "\n")
end

local function makestring(ctx, cexp, target, length)
    local cstr
    if length then
        cstr = render("luaS_newlstr(L, $VALUE, $LENGTH)", {
            VALUE = cexp,
            LENGTH = length,
        })
    else
        cstr = render("luaS_new(L, $VALUE)", {
            VALUE = cexp,
        })
    end
    if target then
        return "", cstr
    else
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
        return render([[
            $CTMP
            $TMPNAME = $CSTR;
            setsvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            CTMP = ctmp,
            TMPNAME = tmpname,
            CSTR = cstr,
            TMPSLOT = tmpslot,
        }), tmpname
    end
end

local function is_addressable_local(exp)
    if exp._tag ~= "Ast.ExpVar" or exp.var._tag ~= "Ast.VarName" then
        return false
    end
    local decl = exp.var._decl
    return decl and decl._tag == "Ast.Decl" and not decl._boxed
end

local function materialize_address_tmp(ctx, exp, cexp)
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local slot = types.is_gc(exp._type) and newslot(ctx) or nil
    return render([[
        $CDECL;
        $TMPNAME = $CEXP;
        $ANCHOR
    ]], {
        CDECL = cvardecl(ctx, exp._type, tmpname),
        TMPNAME = tmpname,
        CEXP = cexp,
        ANCHOR = slot and setslot(exp._type, slot, tmpname) or "",
    }), render("(&$TMPNAME)", { TMPNAME = tmpname })
end

local function mutable_out_anchor(ctx, exp, target)
    local source = exp
    if exp._tag == "Ast.ExpCast"
       and exp.exp
       and target
       and types.c_mutable_address_coerceable(exp.exp._type, target) then
        source = exp.exp
    end
    if not (target and types.c_mutable_address_coerceable(source._type, target))
       or not is_addressable_local(source)
       or not types.is_gc(source._type) then
        return nil
    end
    local decl = source.var._decl
    if not decl._slot then
        decl._slot = newslot(ctx)
    end
    return setslot(source._type, decl._slot, decl._cvar)
end

local function nativetoforeignexp(ctx, exp, cexp, target)
    local stype = types.resolve_c_typedef(exp._type)
    local ttype = target and types.resolve_c_typedef(target) or nil

    if target and types.c_mutable_address_coerceable(exp._type, target)
       and exp._tag == "Ast.ExpVar"
       and exp.var._tag == "Ast.VarName"
       and exp.var._decl
       and exp.var._decl._tag == "Ast.Decl"
       and not exp.var._decl._boxed then
        return "", render("(&($CEXP))", { CEXP = cexp })
    end

    if target and types.c_address_coerceable(exp._type, target)
       and is_addressable_local(exp) then
        return "", render("(&($CEXP))", { CEXP = cexp })
    elseif target and types.c_address_coerceable(exp._type, target) then
        return materialize_address_tmp(ctx, exp, cexp)
    end

    if target and types.is_c_tvalue(target) then
        if stype._tag == "Type.Value" or types.is_c_tvalue(exp._type) then
            return "", cexp
        end
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
        return render([[
            $CTMP
            $SETTMP
            $ANCHOR
        ]], {
            CTMP = ctmp,
            SETTMP = setwrapped(exp._type, "&" .. tmpname, cexp),
            ANCHOR = setslot(types.Value(), tmpslot, tmpname),
        }), tmpname
    end

    if stype._tag == "Type.Value"
       and (not ttype or ttype._tag == "Type.Value") then
        return "", cexp
    end

    if stype._tag == "Type.COwned"
       and (not ttype or ttype._tag == "Type.CPointer") then
        return "", render("getudatamem($EXP)", { EXP = cexp })
    end

    if types.is_c(exp._type) then
        return "", cexp
    end

    if exp._type._tag == "Type.Integer"
    or exp._type._tag == "Type.Float"
    or exp._type._tag == "Type.Boolean"
    or exp._type._tag == "Type.Pointer" then
        return "", cexp
    end

    if exp._type._tag == "Type.Nil" then
        return "", "NULL"
    end

    if exp._type._tag == "Type.String" then
        if target and not (ttype and ttype._tag == "Type.CPointer") then
            return "", cexp
        end
        local texp, tmp = newforeigntmp(ctx, exp._type)
        local cvtexp = render([[getstr($CEXP)]], { CEXP = cexp })
        return render([[
            $TEXP
            $TMP = $CVTEXP;
        ]], {
            TEXP = texp,
            TMP = tmp,
            CVTEXP = cvtexp,
        }), tmp
    end

    if exp._type._tag == "Type.Value" and target then
        local texp, tmp = newforeigntmp(ctx, target)
        return render([[
            $TEXP
            $CHECKANDGET
        ]], {
            TEXP = texp,
            CHECKANDGET = checkandget(ctx, target, tmp, "&" .. cexp, exp.loc),
        }), tmp
    end

    error("don't know how to handle type "..types.tostring(exp._type))
end

local function foreigntonativeexp(ctx, exp, cexp, target)
    local etype = types.resolve_c_typedef(exp._type)

    if etype._tag == "Type.Value" then
        return "", cexp
    elseif etype._tag == "Type.CInteger" then
        return "", "((lua_Integer)" .. cexp .. ")"
    elseif etype._tag == "Type.CFloat" then
        return "", "((lua_Number)" .. cexp .. ")"
    elseif etype._tag == "Type.CPointer" then
        return "", cexp
    elseif etype._tag == "Type.CArray" then
        return "", cexp
    elseif etype._tag == "Type.CStruct" or etype._tag == "Type.CUnion" then
        return "", cexp
    end

    if exp._type._tag == "Type.Integer"
    or exp._type._tag == "Type.Float"
    or exp._type._tag == "Type.Boolean"
    or exp._type._tag == "Type.Pointer" then
        return "", cexp
    end

    if exp._type._tag == "Type.Nil" then
        return "", "0"
    end

    if exp._type._tag == "Type.String" then
        -- A C function may return NULL (e.g. getenv of an unset variable); a
        -- Titan `string` has no nil representation, so raise a clean run-time
        -- error instead of letting luaS_new dereference NULL.
        local texp, tmp = newforeigntmp(ctx, exp._type)
        local guard = render([[
            $TEXP
            $TMP = $CEXP;
            if ($TMP == NULL) {
                luaL_error(L, "foreign function returned a NULL string");
            }
        ]], { TEXP = texp, TMP = tmp, CEXP = cexp })
        local mkstats, mkexp = makestring(ctx, tmp, target)
        return guard .. "\n" .. mkstats, mkexp
    end

    if exp._type._tag == "Type.Typedef" then
        return foreigntonativeexp(ctx, exp._type, cexp, target)
    end

    error("don't know how to handle type "..types.tostring(exp._type))
end

local function finish_foreign_call(ctx, ret, prestats, ccall, poststats)
    if #poststats == 0 then
        return prestats, ccall
    end

    local ret_res = types.resolve_c_typedef(ret)
    local post = table.concat(poststats, "\n")
    if ret_res._tag == "Type.CVoid" then
        return render([[
            $PRESTATS
            $CCALL;
            $POST
        ]], {
            PRESTATS = prestats,
            CCALL = ccall,
            POST = post,
        }), "((void)0)"
    end

    local fdecl, fname = newforeigntmp(ctx, ret)
    return render([[
        $PRESTATS
        $FDECL
        $FNAME = $CCALL;
        $POST
    ]], {
        PRESTATS = prestats,
        FDECL = fdecl,
        FNAME = fname,
        CCALL = ccall,
        POST = post,
    }), fname
end

local function codeforeigncall(ctx, node)
    local cfuncname = node.exp.var.name
    local ftype = node.exp._type
    local ret = ftype.ret or ftype.rettypes[1] or types.CVoid()
    local caexps = {}
    local castats = {}
    local poststats = {}
    if node._named_arg_order then
        assert(node._named_call_kind == "foreign")
        assert(not ftype.vararg)
        assert(#node.args.args == #ftype.params)
        local actuals = {}
        local seen = {}
        local postbyindex = {}
        local function freeze(index)
            assert(index >= 1 and index <= #ftype.params)
            assert(not seen[index], "duplicate formal index in named FFI call")
            seen[index] = true
            local arg = node.args.args[index]
            local target = ftype.params[index]
            local cstat, cexp = codeforeignexp(ctx, arg, target)
            local cdecl, cname = newforeigntmp(ctx, target)
            table.insert(castats, cstat)
            table.insert(castats, cdecl)
            table.insert(castats, cname .. " = " .. cexp .. ";")
            actuals[index] = cname
            postbyindex[index] = mutable_out_anchor(ctx, arg, target)
        end
        for _, index in ipairs(node._named_arg_order) do
            assert(not node.args.args[index]._named_omitted)
            freeze(index)
        end
        for index, arg in ipairs(node.args.args) do
            if not seen[index] then
                assert(arg._named_omitted,
                    "named FFI order omitted an explicit argument")
                freeze(index)
            end
        end
        for index = 1, #ftype.params do
            caexps[index] = assert(actuals[index])
            if postbyindex[index] then
                table.insert(poststats, postbyindex[index])
            end
        end
    else
        for i, arg in ipairs(node.args.args) do
            local cstat, cexp = codeforeignexp(ctx, arg, ftype.params[i])
            table.insert(castats, cstat)
            table.insert(caexps, cexp)
            local anchor = mutable_out_anchor(ctx, arg, ftype.params[i])
            if anchor then
                table.insert(poststats, anchor)
            end
        end
    end
    local cstats = table.concat(castats, "\n")
    local ccall = render("$NAME($CAEXPS)", {
        NAME = cfuncname,
        CAEXPS = table.concat(caexps, ", "),
    })
    return finish_foreign_call(ctx, ret, cstats, ccall, poststats)
end

local function codecfunctionptrcall(ctx, node)
    assert(not node._named_arg_order)
    local cfunc = node._c_pointer_call
    local fstats, fexp = codeexp(ctx, node.exp)
    local fdecl, fname = newforeigntmp(ctx, node.exp._type)
    local castats = {
        fstats,
        fdecl,
        render([[
            $FNAME = $FEXP;
            if (TITAN_UNLIKELY($FNAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot call a NULL C function pointer", $FILE, $LINE, $COL);
            }
        ]], {
            FNAME = fname,
            FEXP = fexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true),
    }
    local caexps = {}
    local poststats = {}
    for i, arg in ipairs(node.args.args) do
        local cstat, cexp = codeforeignexp(ctx, arg, cfunc.params[i])
        table.insert(castats, cstat)
        table.insert(caexps, cexp)
        local anchor = mutable_out_anchor(ctx, arg, cfunc.params[i])
        if anchor then
            table.insert(poststats, anchor)
        end
    end
    local cstats = table.concat(castats, "\n")
    local ccall = render("$FNAME($ARGS)", {
        FNAME = fname,
        ARGS = table.concat(caexps, ", "),
    })
    return finish_foreign_call(ctx, cfunc.ret, cstats, ccall, poststats)
end

local function codeforeignvar(_, node)
    return "", node.name
end

-- Is the callee of this ExpCall a statically-known function symbol (a top-level
-- function, a record function, an imported module function, or a foreign call)?
-- If so, codecall emits a direct native call. Otherwise the callee is a
-- first-class function *value* and codevaluecall handles it.
local function is_static_callee(node)
    if node.args._tag ~= "Ast.ArgsFunc" then return true end
    if node.exp._tag ~= "Ast.ExpVar" then return false end
    local var = node.exp.var
    if var._tag == "Ast.VarDot" and var.exp and var.exp._type
       and var.exp._type._tag == "Type.CModule" then
        return true   -- foreign call, handled by codeforeigncall
    end
    local decl = var._decl
    return decl ~= nil and (decl._tag == "Ast.TopLevelFunc"
        or decl._tag == "Type.ModuleMember"
        or decl._tag == "Type.StaticMethod")
end

local function optionize_type(t)
    if t._tag == "Type.Option" or t._tag == "Type.Value" then
        return t
    else
        return types.Option(t)
    end
end

local function nil_can_adjust_to(typ)
    return typ and (types.coerceable(types.Nil(), typ)
        or types.compatible(typ, types.Nil()))
end

-- Build and append the backing-struct argument (`_varargs` + `_start`) for a
-- native call to a variadic callee. Appends the two C expressions to `caexps`
-- and any setup statements to `castats`. `vargexps` holds the already-coerced
-- surplus static args (those beyond the callee's fixed params); `dots_tail` is
-- true when the call forwards the current function's own `...` (a trailing
-- `Ast.ExpDots` marker); `nstatic` is the static-prefix arg count.
-- Shared by codecall (static call site) and codevaluecall (first-class value
-- fast path) -- both build the struct identically (§5.7).
local function emit_vararg_struct(ctx, node, callee_ftype, vargexps,
                                  dots_tail, nstatic, caexps, castats)
    local callee_vararg = callee_ftype.varargtype
    if not dots_tail then
        -- Static arg list into a variadic callee. Keep the elements on the C
        -- stack and point an exact, named TitanVarg descriptor at them. This
        -- avoids both heap allocation and the old incompatible-struct cast.
        assert(#vargexps <= 200, "static variadic arg count exceeds TITAN_VARARG_MAX")
        local n = #vargexps
        local struct = varg_struct_name(callee_vararg)
        local elem_ct = ctype(callee_vararg)
        local suffix = tostring(ctx.tmp)
        ctx.tmp = ctx.tmp + 1
        local argsname = "_vargargs_" .. suffix
        local vname = "_varg_" .. suffix
        local arrlen = math.max(n, 1)
        local inits = n > 0 and ("{ " .. table.concat(vargexps, ", ") .. " }")
                              or "{ 0 }"
        table.insert(castats, render([[
            $ELEM_CT $ARGS[$ARRLEN] = $INITS;
            $STRUCT $VARG = { $N, $ARGS };
        ]], {
            STRUCT = struct,
            ELEM_CT = elem_ct,
            ARGS = argsname,
            ARRLEN = c_integer_literal(arrlen),
            N = c_integer_literal(n),
            VARG = vname,
            INITS = inits,
        }))
        table.insert(caexps, "&" .. vname)
        table.insert(caexps, "0")
    else
        -- FORWARDING the current `...` into a variadic callee. `vargexps` holds the
        -- over-supplied static args (those beyond the callee's fixed params), all
        -- already coerced to the callee element type by the checker.
        local va = assert(ctx.varargs, "forwarding '...' outside a variadic function")
        local eg = callee_vararg          -- callee element type
        local ef = va.elem                -- this function's `...` element type
        local same_ct = ctype(ef) == ctype(eg)
        local k = nstatic                 -- static-prefix arg count
        local m = #callee_ftype.params    -- callee fixed-param count
        local tail_start = va.start
        if node._open_args then
            -- The checker has already projected any borrowed fixed arguments
            -- into `args` and records the first still-open element explicitly.
            -- Advance the descriptor view past those projections instead of
            -- inferring borrowing again from the elaborated argument count.
            tail_start = render("($START + $DELTA)", {
                START = va.start,
                DELTA = c_integer_literal(node._open_args.start - 1),
            })
        elseif k < m then
            -- Borrow `...[1 .. (m-k)]` for the remaining fixed params before
            -- forwarding the rest as the variadic tail. This is needed even
            -- when the tail representation changes and we must fresh-copy it.
            local delta = m - k
            for j = 1, delta do
                -- Synthesize a `...[j]` read using the same lowering as a
                -- user-written `...[i]`, then use an ordinary cast node when the
                -- callee fixed parameter needs the borrowed element coerced.
                -- The checker proved that the present element can be coerced.
                local ptype = callee_ftype.params[k + j]
                local nilfill = nil_can_adjust_to(ptype)
                local btype = nilfill and optionize_type(ef) or ef
                local idxnode = {
                    _tag = "Ast.ExpDotsIndex",
                    loc = node.loc,
                    exp = { _tag = "Ast.ExpInteger", value = j, loc = node.loc,
                            _type = types.Integer() },
                    _type = btype,
                    _nilfill = nilfill,
                }
                local borrow = idxnode
                if not types.equals(btype, ptype) and
                   types.coerceable(btype, ptype) then
                    borrow = {
                        _tag = "Ast.ExpCast",
                        loc = node.loc,
                        exp = idxnode,
                        target = ptype,
                        _type = ptype,
                    }
                end
                local bstat, bexp = codeexp(ctx, borrow)
                table.insert(castats, bstat)
                table.insert(caexps, bexp)
            end
            tail_start = render("($START + $DELTA)",
                { START = va.start, DELTA = c_integer_literal(delta) })
        end
        -- The logical projection can lie past an empty/short physical backing
        -- run. Clamp the descriptor start once and use that same physical view
        -- in both pass-through and fresh-copy cases; otherwise `#...` in the
        -- callee can become negative and CASE 3 can index beyond `args[]`.
        tail_start = render([[
            (((int)$SRC->n_args < ($LOGICAL))
                ? (int)$SRC->n_args : ($LOGICAL))
        ]], { SRC = va.cname, LOGICAL = tail_start })
        if same_ct and k <= m then
            -- CASE 1 (pass-through): static prefix exactly fills the callee fixed
            -- params, or the missing fixed params were borrowed above, and the
            -- element representation matches; pass the current backing struct and
            -- adjusted start unchanged. No allocation, no copy.
            table.insert(caexps, render("($STRUCT *)$NAME",
                { STRUCT = varg_struct_name(eg), NAME = va.cname }))
            table.insert(caexps, tail_start)
        else
            -- CASE 3 (fresh copy): k > m (the static prefix grows the tail) OR the
            -- element representation differs (ctype(ef) != ctype(eg), each element
            -- converted). Build a fresh Udata0 backing struct of element type eg
            -- holding [ surplus static args (only when k > m), then each current
            -- `...` element converted to eg ], sized at RUNTIME, cap-checked
            -- against TITAN_VARARG_MAX, anchored per §2.D, and passed with
            -- _start = 0.
            -- The Udata0 holding the fresh struct is anchored on a RESERVED stack
            -- slot (newslot -> s2v(restorestack(...) + depth)), which persists
            -- for the whole function -- not a lexical C block. The struct-pointer C local is
            -- declared at statement scope (unique _varg_N name) so it stays visible
            -- at the call. Calls are materialized before any tail `L->top.p =
            -- _base` reset, keeping the anchor live across the call.
            -- The fresh Udata0 allocation can trigger a GC that shrinks/relocates
            -- the Lua stack (luaD_shrinkstack), dangling the raw `_base` pointer;
            -- and the forwarded call itself may grow the stack. Save `_base` as an
            -- offset (uses_base_off) and recompute it after the call so the tail
            -- `L->top.p = _base` reset is valid.
            ctx.uses_base_off = true
            local struct = varg_struct_name(eg)
            local elem_ct = ctype(eg)
            local nprefix = #vargexps      -- static-prefix elements (only k > m)
            local suffix = tostring(ctx.tmp)
            ctx.tmp = ctx.tmp + 1
            local udname = "_vargud_" .. suffix
            local slotdepth = reserveslot(ctx)
            local argsname = "_vargargs_" .. suffix
            local descname = "_vargdesc_" .. suffix
            local vname = "_varg_" .. suffix
            local cntname = "_vcount_" .. suffix
            local nname = "_nvarargs_" .. suffix
            local tailcount = "_vtail_" .. suffix
            -- Prefix-element stores (already coerced to eg by the checker). When eg
            -- is collectable, a fresh prefix value held only in a C temp would be
            -- swept by the Udata0 allocation below (which may GC). Anchor each gc
            -- prefix value on a reserved stack slot FIRST (the slot persists per
            -- §2.D), so it survives both the allocation and the call; then store the
            -- raw pointer into the (untraced) struct payload.
            local prefix_anchor = {}
            local prefix_inits = {}
            for j, cexp in ipairs(vargexps) do
                local pexp = cexp
                if types.is_gc(eg) then
                    local ctmp, tmpname, tmpslot = newtmp(ctx, eg, true)
                    table.insert(prefix_anchor, render([[
                        $CTMP
                        $TMPNAME = $CEXP;
                        $SETSLOT
                    ]], {
                        CTMP = ctmp,
                        TMPNAME = tmpname,
                        CEXP = cexp,
                        SETSLOT = setslot(eg, tmpslot, tmpname),
                    }))
                    pexp = tmpname
                end
                table.insert(prefix_inits, render([[
                    $VNAME->args[$IDX] = $PEXP;
                ]], { VNAME = vname, IDX = c_integer_literal(j - 1), PEXP = pexp }))
            end
            -- Per-element conversion of the incoming `...` into the callee element
            -- type. The checker has proven ef/eg compatible, so this is the
            -- standard coercion: identical ctype -> raw copy; integer->value (and
            -- other gradual `value` widenings) -> setwrapped into a TValue;
            -- value->integer (and similar narrowings) -> checkandget runtime check.
            local convbody
            if same_ct then
                convbody = render("$VNAME->args[$NPREFIX + _vj] = $SRC;", {
                    VNAME = vname,
                    NPREFIX = c_integer_literal(nprefix),
                    SRC = render("$SRC->args[$START + _vj]",
                        { SRC = va.cname, START = tail_start }),
                })
            else
                local src = render("$SRC->args[$START + _vj]",
                    { SRC = va.cname, START = tail_start })
                local dst = render("$VNAME->args[$NPREFIX + _vj]",
                    { VNAME = vname, NPREFIX = c_integer_literal(nprefix) })
                if eg._tag == "Type.Value" or eg._tag == "Type.Option"
                   or eg._tag == "Type.Function" then
                    -- widening into a tagged TValue (e.g. integer -> value).
                    convbody = setwrapped(ef, "&(" .. dst .. ")", src)
                else
                    -- narrowing out of a TValue (e.g. value -> integer): runtime
                    -- check via checkandget (ef is the boxed source element type).
                    convbody = checkandget(ctx, eg, dst, "&(" .. src .. ")", node.loc)
                end
            end
            table.insert(castats, render([[
                $PREFIX_ANCHOR
                ptrdiff_t $TAIL = (ptrdiff_t)$SRC->n_args - $START;
                if ($TAIL < 0) $TAIL = 0;
                ptrdiff_t $CNT = (ptrdiff_t)$NPREFIX + $TAIL;
                if (TITAN_UNLIKELY($CNT > TITAN_VARARG_MAX)) {
                    luaL_error(L, "%s:%d:%d: too many variadic arguments forwarded (%d, max %d)", $FILE, $LINE, $COL, (int)$CNT, (int)TITAN_VARARG_MAX);
                }
                lu_byte $NN = (lu_byte)$CNT;
                Udata *$UDNAME = gco2u(luaC_newobj(L, LUA_VUSERDATA,
                    sizeudata(0, (size_t)$NN * sizeof($ELEM_CT))));
                $UDNAME->len = (size_t)$NN * sizeof($ELEM_CT);
                $UDNAME->nuvalue = 0; $UDNAME->metatable = NULL;
                setuvalue(L, $SLOT, $UDNAME);
                $ELEM_CT *$ARGSNAME = ($ELEM_CT *)getudatamem($UDNAME);
                $STRUCT $DESCNAME = { $NN, $ARGSNAME };
                $STRUCT *$VNAME = &$DESCNAME;
                $PREFIX_INITS
                for (int _vj = 0; _vj < (int)$TAIL; _vj++) {
                    $CONVBODY
                }
            ]], {
                PREFIX_ANCHOR = table.concat(prefix_anchor, "\n"),
                CNT = cntname,
                TAIL = tailcount,
                NN = nname,
                NPREFIX = c_integer_literal(nprefix),
                SRC = va.cname,
                START = tail_start,
                FILE = c_string_literal(node.loc.filename),
                LINE = c_integer_literal(node.loc.line),
                COL = c_integer_literal(node.loc.col),
                UDNAME = udname,
                SLOT = slotat(slotdepth),
                STRUCT = struct,
                ELEM_CT = elem_ct,
                ARGSNAME = argsname,
                DESCNAME = descname,
                VNAME = vname,
                PREFIX_INITS = table.concat(prefix_inits, "\n"),
                CONVBODY = convbody,
            }))
            table.insert(caexps, vname)
            table.insert(caexps, "0")
        end
    end
end

-- Allocate the caller-owned typed backing for one flexible-result call.  A
-- finite consumer gets its exact right-sized buffer; an open consumer (or a
-- flexible return whose inherited budget is only known at run time) gets the
-- bounded 200-element backing.  Open GC-bearing runs also reserve a parallel,
-- traced Lua-stack range.  The native descriptor is never itself a root.
--
-- `_coder_open_want` is installed transiently by an open sink. It is either
-- `LUA_MULTRET` or a C expression for an inherited finite copy budget. Exact
-- native calls receive that budget directly. Generic calls in this statically
-- open mode always use LUA_MULTRET, recover the raw count from the Lua stack,
-- and copy at most this budget into the run.
function coder._flex_call_buffer(ctx, node, ftype, stats, callargs)
    if not ftype.flexrettype then return nil end
    local demand = node._coder_open_want or node._flex_result_demand or 0
    local isopen = node._coder_open_want ~= nil or demand == "open"
    if demand == "open" then demand = "LUA_MULTRET" end
    if type(demand) == "number" then
        assert(demand >= 0 and demand <= 200)
    else
        assert(type(demand) == "string")
    end
    local prefix = isopen and (node._finite_flex_prefix
        or (node._open_results and node._open_results.start - 1) or 0) or 0
    local call_demand = demand
    if isopen and prefix > 0 then
        if type(demand) == "number" then
            call_demand = math.min(200, prefix + demand)
        else
            call_demand = render([[
                (($WANT == LUA_MULTRET) ? LUA_MULTRET
                    : (($WANT >= $REMAINING) ? TITAN_VARARG_MAX
                        : ($WANT + $PREFIX)))
            ]], {
                WANT = demand,
                REMAINING = c_integer_literal(200 - prefix),
                PREFIX = c_integer_literal(prefix),
            })
        end
    end
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_flexargs_" .. suffix
    local descname = "_flexdesc_" .. suffix
    local cap = isopen and 200
        or (type(demand) == "number" and math.max(demand, 1) or 200)
    table.insert(stats, render([[
        $ELEM $ARGS[$CAP] = {0};
        $STRUCT $DESC = { 0, $ARGS };
    ]], {
        ELEM = ctype(ftype.flexrettype),
        ARGS = argsname,
        CAP = c_integer_literal(cap),
        STRUCT = varg_struct_name(ftype.flexrettype),
        DESC = descname,
    }))
    table.insert(callargs, "&" .. descname)
    table.insert(callargs, type(call_demand) == "number"
        and c_integer_literal(call_demand) or call_demand)
    local run = {
        elem = ftype.flexrettype,
        demand = demand,
        call_demand = call_demand,
        args = argsname,
        desc = descname,
        total_count = "(int)" .. descname .. ".n_args",
        count = prefix == 0 and ("(int)" .. descname .. ".n_args")
            or render("(((int)$DESC.n_args > $START) ? ((int)$DESC.n_args - $START) : 0)", {
                DESC = descname,
                START = c_integer_literal(prefix),
            }),
        start = c_integer_literal(prefix),
        prefix = prefix,
        capacity = cap,
        isopen = isopen,
        effectively_open = node._coder_open_effectively_open
            or (isopen and "1" or "0"),
        ownership = "caller",
    }
    if isopen and types.is_gc(run.elem) then
        run.root_depth = ctx.depth
        for _ = 1, cap do reserveslot(ctx) end
    end
    return run
end

-- Publish a caller-owned run into its parallel traced root range.  This handoff
-- performs no allocation: it is safe immediately after an exact native return
-- and after generic stack values have been converted into the typed backing.
function coder._anchor_result_run(run)
    if not run or not run.root_depth then return "" end
    return render([[
        for (int _rri = 0; _rri < $COUNT; _rri++) {
            $SETSLOT
        }
    ]], {
        COUNT = run.count,
        SETSLOT = setslot(run.elem,
            "s2v(" .. stackslotat(run.root_depth) .. " + _rri)",
            run.args .. "[" .. run.start .. " + _rri]"),
    })
end

-- Release the parallel roots after a sink has copied/stored the run.  Reserved
-- slots remain part of the function's fixed frame and may be reused by the
-- ordinary depth stack; clearing only the live prefix avoids retaining dead
-- collectable values across loops or later allocations.
function coder._cleanup_result_run(run)
    if not run or not run.root_depth then return "" end
    return render([[
        for (int _rri = 0; _rri < $COUNT; _rri++) {
            setnilvalue(s2v($ROOT + _rri));
        }
    ]], {
        COUNT = run.count,
        ROOT = stackslotat(run.root_depth),
    })
end

-- Read one typed run element and convert it through the ordinary Titan cast
-- lowering.  The source run remains rooted for the whole sink operation, so
-- the temporary need not acquire another slot merely to bridge this copy.
-- Returns setup statements plus the converted C expression.
function coder._convert_result_run_element(ctx, run, target, index, loc)
    local raw = run.args .. "[" .. run.start .. " + " .. index .. "]"
    if types.equals(run.elem, target) then return "", raw end
    local csrc, srcname = newtmp(ctx, run.elem)
    local synthvar = {
        _tag = "Ast.VarName",
        _type = run.elem,
        _decl = { _cvar = srcname },
    }
    local synthcast = {
        _tag = "Ast.ExpCast",
        loc = loc,
        exp = synthvar,
        target = target,
        _type = target,
    }
    local convstats, convexp = codeexp(ctx, synthcast)
    return render([[
        $CSRC
        $SRCNAME = $RAW;
        $CONVSTATS
    ]], {
        CSRC = csrc,
        SRCNAME = srcname,
        RAW = raw,
        CONVSTATS = convstats,
    }), convexp
end

-- Lower the sole open producer of an adjusted expression list. Input `...`
-- borrows its already-rooted descriptor view; a flexible call publishes a
-- caller-owned run through `_coder_result_run`.  `want` and
-- `effectively_open` let a flexible-return sink pass its inherited run-time
-- budget while arrays and variadic arguments use an unconditional open demand.
function coder._carries_open_source(exp, source)
    if exp == source then return true end
    return exp and exp._tag == "Ast.ExpCast"
        and coder._carries_open_source(exp.exp, source) or false
end

function coder._code_open_source(ctx, source, want, effectively_open, carrier)
    if source._tag == "Ast.ExpDots" then
        local va = assert(ctx.varargs, "open '...' outside a variadic function")
        local projection = source._open_dots and source._open_dots.start or 1
        local logical_start = projection == 1 and tostring(va.start)
            or render("($START + $DELTA)", {
                START = va.start,
                DELTA = c_integer_literal(projection - 1),
            })
        local start = render("(((int)$SRC->n_args < $LOGICAL) ? (int)$SRC->n_args : $LOGICAL)", {
            SRC = va.cname,
            LOGICAL = logical_start,
        })
        return "", "((void)0)", {
            elem = va.elem,
            args = va.cname .. "->args",
            start = start,
            count = render("((int)$SRC->n_args - $START)", {
                SRC = va.cname,
                START = start,
            }),
            capacity = 200,
            isopen = true,
            effectively_open = effectively_open or "1",
            ownership = "borrowed",
        }
    end
    assert(source._tag == "Ast.ExpCall")
    source._coder_open_want = want or "LUA_MULTRET"
    source._coder_open_effectively_open = effectively_open or "1"
    local stats, exp = codeexp(ctx, carrier or source)
    local run = assert(source._coder_result_run,
        "open call producer did not publish a result run")
    source._coder_open_want = nil
    source._coder_open_effectively_open = nil
    return stats, exp, run
end

-- Evaluate an adjusted open expression list exactly once in lexical order.
-- Its finite prefix and explicit scalar tail are materialized separately; the
-- sole trailing dynamic producer is returned as a shared result run.  A call
-- may simultaneously provide a fixed primary value and the dynamic run, so
-- open-source identity is orthogonal to fixed/tail membership.
function coder._codeadjustedopen(ctx, adjusted, want, effectively_open)
    local fixed_index, tail_index, discard_set = {}, {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for i, exp in ipairs(adjusted.tail_scalars) do tail_index[exp] = i end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local stats, fixednames, tailnames = {}, {}, {}
    local run
    for _, exp in ipairs(adjusted.exps) do
        local cs, ce
        if coder._carries_open_source(exp, adjusted.open_source) then
            cs, ce, run = coder._code_open_source(ctx,
                adjusted.open_source, want, effectively_open, exp)
        else
            cs, ce = codeexp(ctx, exp)
        end
        local fi, ti = fixed_index[exp], tail_index[exp]
        if fi or ti then
            local mstats, name = materialize_code(ctx, exp._type, cs, ce)
            table.insert(stats, mstats)
            if fi then fixednames[fi] = name else tailnames[ti] = name end
        else
            assert(coder._carries_open_source(exp, adjusted.open_source)
                or discard_set[exp] or exp._discard_results)
            table.insert(stats, cs)
            table.insert(stats, "(void)(" .. ce .. ");")
        end
    end
    assert(run, "adjusted open expression list produced no result run")
    return stats, fixednames, tailnames, run
end

-- Materialize an adjusted scalar-prefix + dynamic run as one input-variadic
-- descriptor.  Source roots (including the run's parallel root range) remain
-- live through the native call; the temporary descriptor backing is therefore
-- intentionally untraced and caller-scoped.
function coder._emit_open_vararg_struct(ctx, node, callee_ftype, tailnames,
                                        run, stats, callargs)
    local elem = assert(callee_ftype.varargtype)
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_open_vargs_" .. suffix
    local descname = "_open_vargdesc_" .. suffix
    local countname = "_open_vargcount_" .. suffix
    local prefixsets = {}
    for i, name in ipairs(tailnames) do
        table.insert(prefixsets, render("$ARGS[$INDEX] = $VALUE;", {
            ARGS = argsname,
            INDEX = c_integer_literal(i - 1),
            VALUE = name,
        }))
    end
    local convstats, convexp = coder._convert_result_run_element(
        ctx, run, elem, "_vai", node.loc)
    table.insert(stats, render([[
        int $COUNT = $NPREFIX + $RUNCOUNT;
        if (TITAN_UNLIKELY($COUNT > TITAN_VARARG_MAX)) {
            luaL_error(L,
                "%s:%d:%d: too many variadic arguments (%d, max %d)",
                $FILE, $LINE, $COL, $COUNT, (int)TITAN_VARARG_MAX);
        }
        $ELEM $ARGS[TITAN_VARARG_MAX] = {0};
        $PREFIXSETS
        for (int _vai = 0; _vai < $RUNCOUNT; _vai++) {
            $CONVSTATS
            $ARGS[$NPREFIX + _vai] = $VALUE;
        }
        $STRUCT $DESC = { (lu_byte)$COUNT, $ARGS };
    ]], {
        COUNT = countname,
        NPREFIX = c_integer_literal(#tailnames),
        RUNCOUNT = run.count,
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
        ELEM = ctype(elem),
        ARGS = argsname,
        PREFIXSETS = table.concat(prefixsets, "\n"),
        CONVSTATS = convstats,
        VALUE = convexp,
        STRUCT = varg_struct_name(elem),
        DESC = descname,
    }))
    table.insert(callargs, "&" .. descname)
    table.insert(callargs, "0")
    return {
        elem = elem,
        args = argsname,
        desc = descname,
        count = countname,
        start = "0",
        ownership = "caller",
    }
end

-- Generate a call through a first-class function *value* (a boxed TValue of
-- type Type.Function). The value may be a Titan closure, a Lua closure, a C
-- function, or a `__call` object, so the call goes through the Lua stack with
-- `luaD_callnoyield`, which raises cleanly if the value is not callable.
--
-- luaD_callnoyield can grow (and relocate) the Lua stack for the callee's
-- frame, which would dangle this native function's `_base`. We therefore use
-- savestack/restorestack offsets for everything that must survive the call and
-- recompute `_base` from `_base_off` afterwards (see codefuncdec).
local function codevaluecall(ctx, node)
    assert(not node._named_arg_order)
    ctx.uses_base_off = true
    -- `_callee_type` / `_types` describe the callable's native ABI.  The
    -- checker deliberately keeps those separate from the results visible to
    -- this particular consumer: a discarded call, for example, has
    -- `_type == Void` and no visible results while the native entry still
    -- returns its complete fixed prefix.  Keep both counts explicit here.
    local ftype = node._callee_type or node.exp._type
    local abi_nresults = #node._types
    local visible_types = node._visible_types or node._types
    local nresults = #visible_types
    if not node._open_results then
        assert(nresults <= LUA_VM_MAX_RESULTS,
            "checker admitted an oversized finite generic result request")
    end
    local stats = {}

    -- 1. evaluate the callee into an anchored TValue
    local fstat, fexp = codeexp(ctx, node.exp)
    local fdecl, fname, fslot = newtmp(ctx, ftype, true)
    table.insert(stats, fstat)
    table.insert(stats, fdecl)
    table.insert(stats, fname .. " = " .. fexp .. ";")
    table.insert(stats, setslot(ftype, fslot, fname))

    -- A variadic callee value: `ftype.varargtype` is set. The argument list holds
    -- the fixed-param args (1..nfixed) followed by any surplus static args (each
    -- destined for the backing struct), and a trailing `Ast.ExpDots` marker when
    -- the call forwards the current function's own `...` (§2.B). The marker never
    -- reaches codeexp. Dispatch is identical to a non-variadic value: the fast
    -- path (exact tag match) builds the struct and calls the native pointer with
    -- `_varargs` + `_start`; the generic path pushes every arg (expanding any
    -- forwarded `...` element-by-element) and lets the callee's genluaentry
    -- coerce + rebuild.
    local callee_vararg = ftype.varargtype
    local args = node.args.args
    local nargs = #args
    local dots_tail = nargs > 0 and args[nargs]._tag == "Ast.ExpDots"
    local nstatic = dots_tail and (nargs - 1) or nargs
    -- `_npassed_args` trims only fixed-arity surplus. Every explicit argument
    -- to an input-variadic callee belongs to its fixed prefix or variadic run.
    local npassed = callee_vararg and nstatic
        or (node._npassed_args or nstatic)
    assert(npassed <= nstatic)
    local nfixed = #ftype.params

    -- 2. evaluate arguments into anchored temps. Fixed-param args (1..nfixed) are
    --    boxed per the callee's declared parameter type; surplus static args are
    --    boxed per the vararg element type (they become backing-struct elements).
    local argnames, argtypes = {}, {}   -- fixed-param args (both paths)
    local vargexps = {}                 -- surplus static-arg C exprs (struct + push)
    local inputrun, inputtail
    if callee_vararg and node._arg_adjustment
       and node._arg_adjustment.open_source then
        local astats, fixednames, tailnames, run = coder._codeadjustedopen(
            ctx, node._arg_adjustment, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for i, atype in ipairs(ftype.params) do
            argnames[i] = assert(fixednames[i])
            argtypes[i] = atype
        end
        inputrun, inputtail = run, tailnames
    elseif not callee_vararg and node._arg_adjustment then
        local astats, anames = coder._codeadjustedfixed(ctx, {
            _result_adjustment = node._arg_adjustment,
            exps = args,
        })
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for i, atype in ipairs(ftype.params) do
            argnames[i] = assert(anames[i])
            argtypes[i] = atype
        end
    else
        for i = 1, nstatic do
            local arg = args[i]
            local astat, aexp = codeexp(ctx, arg)
            table.insert(stats, astat)
            if i <= npassed then
                local atype = (callee_vararg and i > nfixed) and callee_vararg
                              or ftype.params[i]
                local adecl, aname, aslot = newtmp(ctx, atype,
                    types.is_gc(atype))
                table.insert(stats, adecl)
                table.insert(stats, aname .. " = " .. aexp .. ";")
                if aslot then
                    table.insert(stats, setslot(atype, aslot, aname))
                end
                if callee_vararg and i > nfixed then
                    table.insert(vargexps, aname)
                else
                    argnames[i] = aname
                    argtypes[i] = atype
                end
            else
                -- Positional Titan surplus is effect-only.  Keep the lexical
                -- expression exactly once without adding it to the callable ABI.
                table.insert(stats, "(void)(" .. aexp .. ");")
            end
        end
    end

    -- 3. The fast native branch must satisfy the complete fixed ABI, while the
    -- generic VM branch produces only this consumer's visible projection. Keep
    -- those storage domains separate and converge into visible holders.
    local abinames = {}
    for i = 1, abi_nresults do
        local rtype = node._types[i]
        local rdecl, rname = newtmp(ctx, rtype)
        table.insert(stats, rdecl)
        abinames[i] = rname
    end
    local visnames, visslots = {}, {}
    for i, rtype in ipairs(visible_types) do
        local rdecl, rname = newtmp(ctx, rtype)
        table.insert(stats, rdecl)
        visnames[i] = rname
        if types.is_gc(rtype) then
            visslots[i] = slotat(reserveslot(ctx))
        end
    end

    -- Build the backing struct (`_varargs`, `_start`) when the callee is variadic.
    -- The two struct C exprs go into `vargca` (consumed by `fastargs`); the setup
    -- statements go into a FRESH local list `vargstats` -- NOT the shared `stats`
    -- prelude -- and are spliced into the FAST branch only (the `$VARGSTATS` slot,
    -- right before `$FASTCALL`). The struct is therefore built ONLY on the fast
    -- path (exact tag match): the generic `else` path neither allocates the struct
    -- nor narrows (its case-3 `checkandget` could raise spuriously on a gradual
    -- `value` mismatch, before the generic path -- which must dispatch to the real
    -- runtime function -- ever ran). The generic path re-pushes elements directly
    -- from `vargexps`/`ctx.varargs` and does not read the struct.
    --
    -- Because the build and the native call both live in the fast branch's
    -- `if`-true block, they materialize together before any caller resets
    -- L->top.p: collectable vararg elements anchored on source slots (and a
    -- case-3 fresh Udata0 on its reserved slot) stay live across `$FASTCALL`.
    -- The common `_base = restorestack(L, _base_off);` after the if/else runs on
    -- both paths (a case-3 allocation may have relocated the stack).
    local vargca = {}   -- the two struct C exprs (_varargs ptr, _start)
    local vargstats = {}   -- the struct-build setup statements (fast path only)
    if callee_vararg and not inputrun then
        emit_vararg_struct(ctx, node, ftype, vargexps, dots_tail, npassed,
                           vargca, vargstats)
    end

    -- 4a. fast path: the value is a Titan closure whose exact type tag matches
    --     the callee's static type -> unboxed direct native call
    ctx.valuecall_count = (ctx.valuecall_count or 0) + 1
    local fptype = "_vc_fp_t_" .. ctx.valuecall_count
    -- _fn on the fast path is the callee closure itself, so its native entry can
    -- reach any captured upvalues (slots 3+).
    local fastargs = { "L", "_vc_mod", "_vc_callee" }
    for _, aname in ipairs(argnames) do table.insert(fastargs, aname) end
    -- A variadic callee: `vargca` holds the trailing native args at the pinned ABI
    -- slot -- the backing-struct pointer + `_start`, preceded (in the start-adjust
    -- case) by the fixed params borrowed from this function's own `...`. They sit
    -- after the static fixed-param args and before the out-params (function_sig).
    local inputvarg
    if inputrun then
        inputvarg = coder._emit_open_vararg_struct(ctx, node, ftype,
            inputtail, inputrun, vargstats, fastargs)
    else
        for _, vexp in ipairs(vargca) do table.insert(fastargs, vexp) end
    end
    for i = 2, abi_nresults do
        table.insert(fastargs, "&" .. abinames[i])
    end
    local flexrun = coder._flex_call_buffer(ctx, node, ftype, stats, fastargs)
    local fastcall = "_vc_fp(" .. table.concat(fastargs, ", ") .. ");"
    if abi_nresults > 0 then
        fastcall = abinames[1] .. " = " .. fastcall
    end

    local fastprojections = {}
    local sources = node._result_sources or {}
    for i, name in ipairs(visnames) do
        local source = sources[i] or { kind = "fixed", index = i }
        if source.kind == "fixed" then
            table.insert(fastprojections,
                name .. " = " .. assert(abinames[source.index]) .. ";")
        else
            assert(source.kind == "flex" and flexrun)
            table.insert(fastprojections, render([[
                if ($DESC.n_args >= $INDEX) {
                    $SETPRESENT;
                } else {
                    setnilvalue(&$VISIBLE);
                }
            ]], {
                DESC = flexrun.desc,
                INDEX = c_integer_literal(source.index),
                SETPRESENT = setslot(flexrun.elem, "&" .. name,
                    flexrun.args .. "[" .. c_integer_literal(source.index - 1) .. "]"),
                VISIBLE = name,
            }))
        end
    end
    -- ABI holders are assigned only by the exact native branch. Mark even a
    -- consumer-hidden holder used in that branch so discarded fixed results do
    -- not trigger -Wunused-but-set-variable, without reading uninitialized
    -- storage after the generic branch.
    for _, name in ipairs(abinames) do
        table.insert(fastprojections, "(void)" .. name .. ";")
    end
    if flexrun and flexrun.isopen then
        table.insert(fastprojections, coder._anchor_result_run(flexrun))
        node._coder_result_run = flexrun
    end

    -- 4b. generic path: box function + args and call through the Lua stack. For a
    -- variadic callee, push every fixed and surplus static arg, then (when
    -- forwarding) each `...` element one by one; the callee's genluaentry reads
    -- `nfixed` fixed params and the rest as vararg, coercing each.
    local pushes = { "setobj2s(L, L->top.p, &" .. fname .. "); L->top.p++;" }
    local pushfixed = callee_vararg and nfixed or npassed
    for i = 1, pushfixed do
        if argnames[i] then
            table.insert(pushes,
                setslot(argtypes[i], "s2v(L->top.p)", argnames[i]) .. " L->top.p++;")
        end
    end
    local npush_dynamic = ""
    if inputrun then
        npush_dynamic = " + " .. c_integer_literal(#inputtail)
            .. " + " .. inputrun.count
        table.insert(pushes, render([[
            if (TITAN_UNLIKELY($NPREFIX + $COUNT > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "%s:%d:%d: too many variadic arguments (%d, max %d)",
                    $FILE, $LINE, $COL, $NPREFIX + $COUNT,
                    (int)TITAN_VARARG_MAX);
            }
        ]], {
            NPREFIX = c_integer_literal(#inputtail),
            COUNT = inputrun.count,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }))
        for _, name in ipairs(inputtail) do
            table.insert(pushes,
                setslot(callee_vararg, "s2v(L->top.p)", name)
                    .. " L->top.p++;")
        end
        local pushstats, pushexp
        if node._arg_adjustment.open_source._tag == "Ast.ExpDots" then
            -- Preserve the existing forwarding contract for an input `...`:
            -- the exact native branch converts it to the static descriptor,
            -- while the generic branch pushes the written representation and
            -- lets the runtime callee's Lua entry perform its own checks.  A
            -- value-typed run viewed through a compatible (...: integer)
            -- static type may dispatch to a runtime (...: value) closure;
            -- narrowing it here would raise before that dispatch can occur.
            pushstats = ""
            pushexp = inputrun.args .. "[" .. inputrun.start .. " + _vpj]"
        else
            -- A flexible-result producer is consumed by this call's static
            -- input sink, just like an explicit scalar argument.  Apply its
            -- element conversion on both branches; only borrowed input `...`
            -- has the established runtime-signature forwarding behavior above.
            pushstats, pushexp = coder._convert_result_run_element(
                ctx, inputrun, callee_vararg, "_vpj", node.loc)
        end
        table.insert(pushes, render([[
            for (int _vpj = 0; _vpj < $COUNT; _vpj++) {
                $PUSHSTATS
                $SETSLOT L->top.p++;
            }
        ]], {
            COUNT = inputrun.count,
            PUSHSTATS = pushstats,
            SETSLOT = setslot(
                node._arg_adjustment.open_source._tag == "Ast.ExpDots"
                    and inputrun.elem or callee_vararg,
                "s2v(L->top.p)", pushexp),
        }))
    else
        for _, vexp in ipairs(vargexps) do
            table.insert(pushes,
                setslot(callee_vararg, "s2v(L->top.p)", vexp) .. " L->top.p++;")
        end
    end
    if dots_tail and not inputvarg then
        -- forward the current `...`: push each element start-relative. The element
        -- C type matches the vararg struct exactly, so this is a wrapped store.
        local va = assert(ctx.varargs, "forwarding '...' in a value call outside a variadic function")
        local source_start = node._open_args and render("($START + $DELTA)", {
            START = va.start,
            DELTA = c_integer_literal(node._open_args.start - 1),
        }) or va.start
        source_start = render([[
            (((int)$SRC->n_args < ($LOGICAL))
                ? (int)$SRC->n_args : ($LOGICAL))
        ]], { SRC = va.cname, LOGICAL = source_start })
        npush_dynamic = render(" + ((int)$SRC->n_args - $START)",
            { SRC = va.cname, START = source_start })
        table.insert(pushes, render([[
            for (int _vpj = 0; _vpj < (int)$SRC->n_args - $START; _vpj++) {
                $SETSLOT L->top.p++;
            }
        ]], {
            SRC = va.cname,
            START = source_start,
            SETSLOT = setslot(va.elem, "s2v(L->top.p)",
                render("$SRC->args[$START + _vpj]",
                    { SRC = va.cname, START = source_start })),
        }))
    end
    local slowreads = {}
    for i = 1, nresults do
        table.insert(slowreads, checkandget(ctx, visible_types[i], visnames[i],
            "s2v(restorestack(L, _vc_func) + " .. (i-1) .. ")", node.loc))
    end
    local slowcall = render([[
        luaD_callnoyield(L, restorestack(L, _vc_func), $NRESULTS);
    ]], { NRESULTS = c_integer_literal(nresults) })
    local slowpre, slowopen = "", ""
    -- Reserve the generic branch's complete finite result area as well as the
    -- function and arguments. `luaD_callnoyield` is an internal primitive and
    -- therefore assumes its caller has satisfied the public API's
    -- `checkresults` capacity invariant; finite nil-padding may write every
    -- requested slot even when the callable returns nothing.
    local npushfixed = 1 + pushfixed
        + (inputrun and 0 or #vargexps) + nresults
    if flexrun and flexrun.isopen then
        -- A statically open generic producer always uses LUA_MULTRET. Its
        -- results remain rooted on the Lua stack while Titan measures the raw
        -- count, applies the static fixed/flexible shape, and copies only the
        -- enclosing sink's finite/open budget into typed backing.
        slowcall = [[
            luaD_callnoyield(L, restorestack(L, _vc_func), LUA_MULTRET);
            if (L->ci->top.p < L->top.p) L->ci->top.p = L->top.p;
            int _vc_raw = (int)(L->top.p - restorestack(L, _vc_func));
        ]]
        slowpre = render([[
            while (L->top.p < restorestack(L, _vc_func) + $NVISIBLE) {
                setnilvalue(s2v(L->top.p));
                L->top.p++;
            }
        ]], { NVISIBLE = c_integer_literal(nresults) })
        slowopen = render([[
            int _vc_flexraw = _vc_raw - $NFIXED;
            if (_vc_flexraw < 0) _vc_flexraw = 0;
            int _vc_want = $WANT;
            if (($EFFECTIVELY_OPEN) && TITAN_UNLIKELY(_vc_flexraw > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "%s:%d:%d: too many flexible return values (%d, max %d)",
                    $FILE, $LINE, $COL, _vc_flexraw, (int)TITAN_VARARG_MAX);
            }
            int _vc_keep = _vc_flexraw;
            if (_vc_want != LUA_MULTRET && _vc_keep > _vc_want)
                _vc_keep = _vc_want;
            if (_vc_keep > TITAN_VARARG_MAX) _vc_keep = TITAN_VARARG_MAX;
            $DESC.n_args = (lu_byte)_vc_keep;
            for (int _vri = 0; _vri < _vc_keep; _vri++) {
                $READONE
            }
            $ANCHORRUN
        ]], {
            NFIXED = c_integer_literal(abi_nresults),
            WANT = flexrun.call_demand,
            EFFECTIVELY_OPEN = flexrun.effectively_open,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            DESC = flexrun.desc,
            READONE = checkandget(ctx, flexrun.elem,
                flexrun.args .. "[_vri]",
                "s2v(restorestack(L, _vc_func) + "
                    .. c_integer_literal(abi_nresults) .. " + _vri)",
                node.loc),
            ANCHORRUN = coder._anchor_result_run(flexrun),
        })
    end

    -- Only consumer-visible holders are live after branch convergence. Hidden
    -- ABI temporaries die in the fast branch without crossing an allocation;
    -- anchoring them on the generic branch would read uninitialized storage.
    local anchors = {}
    for i, rtype in ipairs(visible_types) do
        if visslots[i] then
            table.insert(anchors,
                setslot(rtype, visslots[i], visnames[i]))
        end
    end
    table.insert(stats, render([[
        if (ttisCclosure(&$FNAME) && clCvalue(&$FNAME)->nupvalues >= 3
            && ttislightuserdata(&clCvalue(&$FNAME)->upvalue[1])
            && pvalue(&clCvalue(&$FNAME)->upvalue[1]) == $FUNCTAG) {
            /* fast path: exact function-type match, unboxed native call */
            CClosure *_vc_callee = clCvalue(&$FNAME);
            Udata *_vc_mod = uvalue(&_vc_callee->upvalue[0]);
            $FPTYPEDEF;
            $FPTYPE _vc_fp = titan_cast_func($FPTYPE,
                pvalue(&_vc_callee->upvalue[2]));
            $VARGSTATS
            $LINEDIR
            $FASTCALL
            $FASTPROJECTIONS
        } else {
            /* generic path: call any callable value through the Lua stack;
               luaD_callnoyield raises if it is not callable */
            lua_checkstack(L, $NPUSH);
            ptrdiff_t _vc_func = savestack(L, L->top.p);
            $PUSHES
            $LINEDIR
            $SLOWCALL
            $SLOWPRE
            $SLOWREADS
            $SLOWOPEN
            L->top.p = restorestack(L, _vc_func);
        }
        _base = restorestack(L, _base_off);
        $ANCHORS
        $INPUTCLEANUP
    ]], {
        FNAME = fname,
        FUNCTAG = function_type_tag(ctx.tlcontext, ftype),
        FPTYPEDEF = "typedef " .. function_sig(fptype, ftype, true),
        FPTYPE = fptype,
        VARGSTATS = table.concat(vargstats, "\n"),
        LINEDIR = emitline(node),
        FASTCALL = fastcall,
        FASTPROJECTIONS = table.concat(fastprojections, "\n"),
        NPUSH = c_integer_literal(npushfixed) .. npush_dynamic,
        PUSHES = table.concat(pushes, "\n"),
        SLOWCALL = slowcall,
        SLOWPRE = slowpre,
        SLOWREADS = table.concat(slowreads, "\n"),
        SLOWOPEN = slowopen,
        ANCHORS = table.concat(anchors, "\n"),
        INPUTCLEANUP = inputrun and coder._cleanup_result_run(inputrun) or "",
    }))

    -- 5. expose extra return values for ExpExtra readers
    if nresults >= 2 then
        node._extras = node._extras or {}
        for i = 2, nresults do
            node._extras[i] = visnames[i]
        end
    end

    local cstats = table.concat(stats, "\n")
    if nresults == 0 then
        return cstats, "((void)0)"
    else
        return cstats, visnames[1]
    end
end

local function codecall(ctx, node)
    if node._named_arg_order then
        assert(node._named_call_kind == "titan")
    end
    if not is_static_callee(node) then
        return codevaluecall(ctx, node)
    end
    local castats, caexps = {}, { "L" }
    local fname
    local fnode = node.exp.var
    local modarg = "_mod"
    if node.args._tag == "Ast.ArgsFunc" then
        if fnode._tag == "Ast.VarName" then
            fname = func_name(ctx.module, fnode.name)
        elseif fnode._tag == "Ast.VarDot" then
            if fnode.exp._type._tag == "Type.CModule" then
                return codeforeigncall(ctx, node)
            elseif fnode._decl._tag == "Type.StaticMethod" then
                fname = static_name(fnode._decl)
                local mod, record = fnode._decl.fqtn:match("^(.*)%.([^.]+)$")
                if mod ~= ctx.module then
                    assert(fnode.exp.var._tag == "Ast.VarDot")
                    ctx.functions[fnode._decl.fqtn .. "." .. fnode._decl.name] = {
                        module = mod,
                        record = record,
                        type = fnode._decl,
                        name = fnode._decl.name,
                        mangled = fname
                    }
                    modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                        INDEX = c_integer_literal(fnode.exp.var.exp.var._decl._upvalue) -- whew!
                    })
                end
            else
                assert(fnode._decl._tag == "Type.ModuleMember")
                fname = func_name(fnode._decl.modname, fnode.name)
                local mod = fnode._decl.modname
                if mod ~= ctx.module then
                    ctx.functions[mod .. "." .. fnode.name] = {
                        module = mod,
                        name = fnode.name,
                        type = fnode._type,
                        mangled = fname
                    }
                end
                modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                    INDEX = c_integer_literal(fnode.exp.var._decl._upvalue)
                })
            end
        end
        table.insert(caexps, modarg)
        table.insert(caexps, "NULL")  -- _fn: a static top-level call has no closure
    else
        assert(node.args._tag == "Ast.ArgsMethod")
        local mtype = node._method
        fname = method_name(mtype)
        local mod, record = mtype.fqtn:match("^(.*)%.([^.]+)$")
        if mod ~= ctx.module then
            ctx.functions[mtype.fqtn .. ":" .. mtype.name] = {
                module = mod,
                record = record,
                name = mtype.name,
                type = mtype,
                mangled = fname
            }
            if not ctx.modules[mod] then
                ctx.modules[mod] = nextupvalue(ctx.tlcontext)
            end
            modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                INDEX = c_integer_literal(ctx.modules[mod])
            })
        end
        local cstat, cexp = materialize(ctx, node.exp)
        table.insert(castats, cstat)
        table.insert(caexps, modarg)
        table.insert(caexps, "NULL")  -- _fn: a record method call has no closure
        table.insert(caexps, cexp)
    end
    -- The callee's static type, to detect a variadic callee and its fixed arity.
    -- ArgsMethod -> node._method; a static-method VarDot -> fnode._decl; otherwise
    -- the var's resolved Type.Function on fnode._type.
    local callee_ftype
    if node.args._tag == "Ast.ArgsMethod" then
        callee_ftype = node._method
    elseif fnode._tag == "Ast.VarDot"
           and fnode._decl and fnode._decl._tag == "Type.StaticMethod" then
        callee_ftype = fnode._decl
    else
        callee_ftype = fnode._type
    end
    local callee_vararg = callee_ftype and callee_ftype.varargtype
    if node._named_arg_order then
        assert(callee_ftype)
        assert(not callee_vararg and not callee_ftype.vararg)
    end
    -- Any native Titan call can reallocate the Lua stack (directly or while
    -- servicing a collection). Keep `_base` as an offset and materialize the
    -- call so `_base` can be restored before result anchoring or later slot use.
    ctx.uses_base_off = true
    local args = node.args.args
    local nargs = #args
    -- A trailing `Ast.ExpDots` marker means this call FORWARDS the current
    -- function's own `...` into the (variadic) callee (the checker kept it for a
    -- variadic callee; §5.7). The static-prefix args are args[1..nargs-1]; the
    -- marker itself never reaches codeexp.
    local dots_tail = nargs > 0 and args[nargs]._tag == "Ast.ExpDots"
    if node._named_arg_order then assert(not dots_tail) end
    local nstatic = dots_tail and (nargs - 1) or nargs
    -- `_npassed_args` trims only fixed-arity surplus. Every explicit argument
    -- to an input-variadic callee belongs to its fixed prefix or variadic run.
    local npassed = callee_vararg and nstatic
        or (node._npassed_args or nstatic)
    assert(npassed <= nstatic)
    local nfixed = callee_vararg and #callee_ftype.params or npassed
    local vargexps = {} -- surplus static args destined for the backing struct
    local inputrun
    if node._named_arg_order then
        assert(nstatic == #callee_ftype.params)
        local argstats, argexps = named_ordered_call_args(ctx, args,
            node._named_arg_order)
        for _, stat in ipairs(argstats) do
            table.insert(castats, stat)
        end
        for i = 1, nstatic do
            local argexp = assert(argexps[i])
            table.insert(caexps, argexp)
        end
    elseif callee_vararg and node._arg_adjustment
           and node._arg_adjustment.open_source then
        local astats, fixednames, tailnames, run = coder._codeadjustedopen(
            ctx, node._arg_adjustment, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(castats, stat) end
        for i = 1, #callee_ftype.params do
            local fixedname = assert(fixednames[i])
            table.insert(caexps, fixedname)
        end
        coder._emit_open_vararg_struct(ctx, node, callee_ftype,
            tailnames, run, castats, caexps)
        inputrun = run
    elseif not callee_vararg and node._arg_adjustment then
        -- The adjusted fixed inputs are not necessarily a prefix of the lexical
        -- expression list: a zero-result trailing producer can be retained for
        -- effect before a synthesized nil occupies the formal slot. Drive the
        -- ABI arguments from object-identity mapping, not `_npassed_args` alone.
        local astats, anames = coder._codeadjustedfixed(ctx, {
            _result_adjustment = node._arg_adjustment,
            exps = args,
        })
        for _, stat in ipairs(astats) do table.insert(castats, stat) end
        for i = 1, #callee_ftype.params do
            local aname = assert(anames[i])
            table.insert(caexps, aname)
        end
    else
        -- Only arguments that belong to the native input shape need stable C
        -- values.  A positional surplus is a lexical suffix; generate that
        -- suffix separately below so an effectful discarded call is never
        -- materialized with its consumer-facing `Void` type.
        local argstats, argexps = ordered_call_args(ctx, args, npassed)
        for i = 1, npassed do
            local cexp = argexps[i]
            table.insert(castats, argstats[i])
            if callee_vararg and i > nfixed then
                -- a surplus static arg -> a backing-struct element (already coerced
                -- to the element type by the checker)
                table.insert(vargexps, cexp)
            else
                table.insert(caexps, cexp)
            end
        end
        for i = npassed + 1, nstatic do
            -- Surplus positional Titan arguments remain in source order and
            -- are evaluated once, but are not part of the native ABI.
            local stat, exp = codeexp(ctx, args[i])
            table.insert(castats, stat)
            table.insert(castats, "(void)(" .. exp .. ");")
        end
    end
    -- Build + append the backing struct (`_varargs`, `_start`) for a variadic
    -- callee. The call is materialized below, so collectable source-slot anchors
    -- and any case-3 stack-anchored Udata0 remain live until the callee returns.
    if callee_vararg and not inputrun then
        emit_vararg_struct(ctx, node, callee_ftype, vargexps, dots_tail,
                           npassed, caexps, castats)
    end
    -- Keep the complete fixed ABI prefix in native temporaries even when this
    -- consumer hides some or all of it. Consumer-visible results get separate
    -- holders below; this is what lets a flex-only primary be an option TValue
    -- while the native entry itself still returns C void.
    local abinames = {}
    for i, typ in ipairs(node._types) do
        local decl, name = newtmp(ctx, typ)
        table.insert(castats, decl)
        abinames[i] = name
        if i >= 2 then table.insert(caexps, "&" .. name) end
    end
    local flexrun = coder._flex_call_buffer(ctx, node, callee_ftype,
        castats, caexps)

    local visible = node._visible_types or node._types
    local sources = node._result_sources or {}
    local visnames, visslots, projections = {}, {}, {}
    for i, typ in ipairs(visible) do
        local decl, name = newtmp(ctx, typ)
        table.insert(castats, decl)
        visnames[i] = name
        if types.is_gc(typ) then
            visslots[i] = slotat(reserveslot(ctx))
        end
        local source = sources[i] or { kind = "fixed", index = i }
        if source.kind == "fixed" then
            table.insert(projections,
                name .. " = " .. assert(abinames[source.index]) .. ";")
        else
            assert(source.kind == "flex" and flexrun)
            table.insert(projections, render([[
                if ($DESC.n_args >= $INDEX) {
                    $SETPRESENT;
                } else {
                    setnilvalue(&$VISIBLE);
                }
            ]], {
                DESC = flexrun.desc,
                INDEX = c_integer_literal(source.index),
                SETPRESENT = setslot(flexrun.elem, "&" .. name,
                    flexrun.args .. "[" .. c_integer_literal(source.index - 1) .. "]"),
                VISIBLE = name,
            }))
        end
    end

    local anchors = {}
    for i, typ in ipairs(visible) do
        if visslots[i] then
            table.insert(anchors,
                setslot(typ, visslots[i], visnames[i]) .. ";")
        end
    end
    node._extras = node._extras or {}
    for i = 2, #visnames do node._extras[i] = visnames[i] end

    local ccall = render("$NAME($CAEXPS)", {
        NAME = fname,
        CAEXPS = table.concat(caexps, ", "),
    })
    local callstat = #node._types > 0
        and (abinames[1] .. " = " .. ccall .. ";")
        or (ccall .. ";")
    table.insert(castats, emitline(node) .. callstat)
    -- The callee may relocate the Lua stack; restore `_base` before addressing
    -- any reserved result root, then publish only the visible projection.
    table.insert(castats, "_base = restorestack(L, _base_off);")
    if flexrun and flexrun.isopen then
        table.insert(castats, coder._anchor_result_run(flexrun))
        node._coder_result_run = flexrun
    end
    for _, stat in ipairs(projections) do table.insert(castats, stat) end
    for _, stat in ipairs(anchors) do table.insert(castats, stat) end
    if inputrun then
        table.insert(castats, coder._cleanup_result_run(inputrun))
    end
    for _, name in ipairs(abinames) do
        table.insert(castats, "(void)" .. name .. ";")
    end

    local cstats = table.concat(castats, "\n")
    if #visnames == 0 then
        return cstats, "((void)0)"
    end
    return cstats, visnames[1]
end

-- A `StatTry` body/catch is emitted as straight-line C inside an inline setjmp
-- boundary, so the `lua_longjmp _lj` is an automatic of an inner C scope. A
-- `return` that jumps out of the whole native function, or a `break` that jumps
-- out of an enclosing loop, must first restore `L->errorJmp` (and `nCcalls`) to
-- the values they held BEFORE the protected region was entered, or `L->errorJmp`
-- would dangle to an out-of-scope `_lj`. We snapshot those once at function entry
-- (`_entry_errorjmp`/`_entry_nC`) and at each loop entry whose body contains a
-- try (`_loop_errorjmp_N`/`_loop_nC_N`), then restore at the crossing transfer.
-- Only emitted when a try is actually in scope, to keep try-free code untouched.
local function restore_entry_errorjmp()
    return [[
        L->errorJmp = _entry_errorjmp;
        L->nCcalls = _entry_nC;]]
end

-- Pending-action discriminator values (B.3). A `StatTry` with a finally records,
-- on every exit of its protected region, a pending action; the finally runs
-- straight-line; then an if-chain dispatch (NEVER a C `switch`, which would
-- capture the PA_BREAK arm's `break`) performs it. PA_NONE falls through.
local PA_NONE   = "0"
local PA_RETURN = "1"
local PA_BREAK  = "2"
local PA_RAISE  = "3"

-- Compute the per-return saved-value storage for a try-with-finally (B.4 "GC
-- anchoring"). Fixed results use stack-anchored slots for GC types and
-- `volatile` C temps for non-GC scalars. A flexible result gets frame-owned
-- backing plus a volatile count; GC-bearing elements also get a parallel range
-- of traced Lua-stack slots. The descriptor itself is deliberately not used:
-- the pending frame owns its backing until dispatch copies it to the caller.
local function make_return_frame(ctx, id)
    local rettypes = ctx.rettypes or {}
    local saves = {}
    local decls = {}
    for i = 1, #rettypes do
        local typ = rettypes[i]
        local cvar = "_pa_ret_" .. id .. "_" .. i
        local isgc = types.is_gc(typ)
        local slot
        if isgc then
            -- GC saved return: anchor in a reserved stack slot so it survives the
            -- finally (which may allocate / run the GC). The C temp just caches a
            -- copy; the slot is the live root.
            slot = reserveslot(ctx)
            table.insert(decls, render("$VQ$CT $CVAR = $INIT;", {
                VQ = "", CT = ctype(typ), CVAR = cvar, INIT = initval(typ),
            }))
        else
            -- Non-GC saved return: a plain C temp. The whole native function is a
            -- setjmp scope, so mark it volatile (the value is set before the
            -- finally — which may longjmp out on a raise — and read in dispatch).
            table.insert(decls, render("volatile $CT $CVAR = $INIT;", {
                CT = ctype(typ), CVAR = cvar, INIT = initval(typ),
            }))
        end
        -- A try-with-finally that contains no `return` leaves these temps written
        -- nowhere (or, for GC types, written but only ever read via the slot), so
        -- silence -Wunused-variable / -Wunused-but-set unconditionally.
        table.insert(decls, "(void)" .. cvar .. ";")
        saves[i] = { typ = typ, cvar = cvar, slot = slot }
    end
    local flex = false
    if ctx.flexrettype then
        local args = "_pa_flexargs_" .. id
        local count = "_pa_flexcount_" .. id
        local root_depth
        if types.is_gc(ctx.flexrettype) then
            root_depth = ctx.depth
            for _ = 1, 200 do reserveslot(ctx) end
        end
        table.insert(decls, render([[
            $ELEM $ARGS[TITAN_VARARG_MAX] = {0};
            volatile int $COUNT = 0;
            (void)$ARGS;
            (void)$COUNT;
        ]], {
            ELEM = ctype(ctx.flexrettype),
            ARGS = args,
            COUNT = count,
        }))
        flex = {
            elem = ctx.flexrettype,
            args = args,
            count = count,
            root_depth = root_depth,
            start = "0",
            capacity = 200,
            ownership = "pending",
        }
    end
    return {
        id = id,
        fixed = saves,
        flex = flex,
    }, table.concat(decls, "\n")
end

function coder._saved_fixed_value(save)
    if save.slot then
        return getslot(save.typ, nil, slotat(save.slot))
    end
    return save.cvar
end

function coder._flex_root(flex, index)
    if not flex.root_depth then return "" end
    return setslot(flex.elem,
        "s2v(" .. stackslotat(flex.root_depth) .. " + " .. index .. ")",
        flex.args .. "[" .. index .. "]")
end

-- Clear the live root prefix from a previous, partially evaluated pending
-- return, then reset the count before a body/catch return starts evaluating.
-- A conversion can longjmp after publishing earlier elements, so the count is
-- volatile and is the authoritative prefix length on recovery.
function coder._reset_pending_flex(flex)
    if not flex then return "" end
    local clear = ""
    if flex.root_depth then
        clear = render([[
            for (int _pa_clear_i = 0; _pa_clear_i < $COUNT; _pa_clear_i++) {
                setnilvalue(s2v($ROOT + _pa_clear_i));
            }
        ]], {
            COUNT = flex.count,
            ROOT = stackslotat(flex.root_depth),
        })
    end
    return clear .. "\n" .. flex.count .. " = 0;"
end

-- Emit the real function epilogue for a return saved by a finally frame. Read
-- fixed roots and copy the complete flexible run before resetting `L->top`;
-- after that reset no allocation occurs before control reaches the caller.
local function dispatch_return_epilogue(ctx, frame)
    local from = frame.fixed
    local lines = {}
    -- restore the errorjmp chain to the function-entry values (this return is
    -- crossing the finally's torn-down boundary back to the caller)
    ctx.used_entry_restore = true
    table.insert(lines, restore_entry_errorjmp())
    -- Read each saved value into a fresh C temp BEFORE resetting the stack top:
    -- a GC saved return lives in a slot at `_base + d` (>= _base), so reading it
    -- after `L->top.p = _base` would touch a slot above top. No allocation runs
    -- here, so the temps hold valid (register-held) values across the reset.
    for i = 1, #from do
        table.insert(lines, render("$CT $NAME = $READ;", {
            CT = ctype(from[i].typ),
            NAME = "_pa_dret_" .. frame.id .. "_" .. i,
            READ = coder._saved_fixed_value(from[i]),
        }))
    end
    if frame.flex then
        table.insert(lines, render([[
            int _pa_dflex_count_$ID = (int)$COUNT;
            for (int _pa_dflex_i_$ID = 0;
                 _pa_dflex_i_$ID < _pa_dflex_count_$ID;
                 _pa_dflex_i_$ID++) {
                _flexout->args[_pa_dflex_i_$ID] = $ARGS[_pa_dflex_i_$ID];
            }
            _flexout->n_args = (lu_byte)_pa_dflex_count_$ID;
        ]], {
            ID = c_integer_literal(frame.id),
            COUNT = frame.flex.count,
            ARGS = frame.flex.args,
        }))
    end
    table.insert(lines, "L->top.p = _base;")
    for i = 2, #from do
        table.insert(lines, "*_outparam_" .. i .. " = _pa_dret_"
            .. frame.id .. "_" .. i .. ";")
    end
    if #from == 0 then
        table.insert(lines, "return;")
    else
        table.insert(lines, "return _pa_dret_" .. frame.id .. "_1;")
    end
    return table.concat(lines, "\n")
end

-- A `return`/`break` inside the body or catch of an enclosing try-with-finally
-- is NOT realized as the real control transfer: it sets that try's pending
-- action (+ saves the return values), then `goto`s the try's `_finally` label so
-- the finally still runs before the action is performed (B.3 rule d/h). The
-- innermost enclosing try-with-finally is `ctx.finally_stack[#ctx.finally_stack]`.
local function innermost_finally(ctx)
    local fs = ctx.finally_stack
    return fs and fs[#fs] or nil
end

local function push_boundary(ctx, tag)
    ctx.protected_boundary_stack = ctx.protected_boundary_stack or {}
    table.insert(ctx.protected_boundary_stack, tag)
end

local function pop_boundary(ctx)
    assert(ctx.protected_boundary_stack and #ctx.protected_boundary_stack > 0)
    table.remove(ctx.protected_boundary_stack)
end

-- A pending return/break that jumps to a finally label leaves the C scope of
-- every inline boundary opened between the target try and the current point.
-- Restore those `lua_longjmp` links before the `goto`; otherwise a raise from
-- the finally would longjmp to an out-of-scope `_lj_*` object. Stop at `floor`
-- so outer still-active boundaries remain installed and can catch/cascade a
-- raise from the finally (the plan's inside-out finally semantics).
local function restore_boundaries_to(ctx, floor)
    local bs = ctx.protected_boundary_stack or {}
    local lines = {}
    for i = #bs, floor + 1, -1 do
        table.insert(lines, render([[
            L->errorJmp = _lj_$T.previous;
            L->nCcalls = _oldnC_$T;
        ]], { T = bs[i] }))
    end
    return table.concat(lines, "\n")
end

function coder._adjusted_return(node)
    local adjusted = node._result_adjustment
    if not adjusted then
        -- Compatibility for hand-built ASTs: the checker normally publishes
        -- the richer adjustment record on every return.
        adjusted = { exps = node.exps, fixed = node.exps,
            tail_scalars = {}, discards = {}, open_source = false }
    end
    return adjusted
end

-- Peel only checker-synthesized sink coercions from a statically visible
-- flexible-tail expression. A user-written explicit cast is unmarked and is
-- therefore part of the carrier evaluation even when the caller discards that
-- tail position.
function coder._implicit_tail_carrier(exp)
    local carrier = exp
    while carrier._tag == "Ast.ExpCast" and carrier._implicit_coercion do
        carrier = carrier.exp
    end
    return carrier
end

-- Rebuild the peeled implicit-cast chain over an already materialized carrier.
-- This lets the carrier run exactly once in lexical order while the target
-- checks/conversions remain inside the caller's remaining-result guard.
function coder._retarget_implicit_tail(exp, carrier, replacement)
    if exp == carrier then return replacement end
    assert(exp._tag == "Ast.ExpCast" and exp._implicit_coercion)
    local copy = {}
    for key, value in pairs(exp) do copy[key] = value end
    copy.exp = coder._retarget_implicit_tail(exp.exp, carrier, replacement)
    return copy
end

-- Lower the checker's return adjustment into either the caller's real ABI
-- destination or a finally frame. Both destinations use this exact lexical
-- walk, so fixed projections, effect-only surplus expressions, explicit tail
-- scalars, open runs, conversions, truncation, and cleanup stay identical.
-- Returns the emitted statements and (for a direct return) its fixed holders.
function coder._lower_return_to_destination(ctx, node, destination)
    local adjusted = coder._adjusted_return(node)
    local fixed_index, tail_set, discard_set = {}, {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for _, exp in ipairs(adjusted.tail_scalars) do tail_set[exp] = true end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local cstats, fixednames = {}, {}
    local flex = destination.flex
    local openrun
    local tail_seen = 0
    if flex and destination.kind == "direct" then
        local suffix = tostring(ctx.tmp)
        ctx.tmp = ctx.tmp + 1
        flex.count = "_flexcount_" .. suffix
        table.insert(cstats, "int " .. flex.count .. " = 0;")
        table.insert(cstats, "_flexout->n_args = 0;")
    elseif flex then
        table.insert(cstats, coder._reset_pending_flex(flex))
    end

    local function append_flexible(setup, value)
        assert(flex)
        local root = coder._flex_root(flex, flex.count)
        return render([[
            if (_flexwant == LUA_MULTRET || $COUNT < _flexwant) {
                $SETUP
                if (TITAN_UNLIKELY($COUNT >= TITAN_VARARG_MAX)) {
                    luaL_error(L, "too many flexible return values (max %d)",
                        (int)TITAN_VARARG_MAX);
                }
                $ARGS[$COUNT] = $VALUE;
                $ROOT
                $COUNT++;
            }
        ]], {
            COUNT = flex.count,
            ARGS = flex.args,
            SETUP = setup,
            VALUE = value,
            ROOT = root,
        })
    end

    -- Walk the checker's lexical expression list exactly once. Sink values are
    -- materialized (and GC-rooted when necessary); explicit surplus expressions
    -- are still forced for effect but never mapped to a native out-parameter.
    for _, exp in ipairs(adjusted.exps) do
        local fi = fixed_index[exp]
        local istail = tail_set[exp]
        local carrier = istail and coder._implicit_tail_carrier(exp) or exp
        local cs, ce
        if coder._carries_open_source(exp, adjusted.open_source) then
            assert(flex)
            -- The open producer may also expose statically visible fixed
            -- results that the checker mapped into the flexible tail. Reserve
            -- their positions before asking the producer for its dynamic run;
            -- generic value calls perform element conversion while building
            -- that run, so over-requesting even one element can raise on a
            -- value that the inherited finite result budget would discard.
            local pending_tail = #adjusted.tail_scalars - tail_seen
            cs, ce, openrun = coder._code_open_source(ctx,
                adjusted.open_source, render([[
                ((_flexwant == LUA_MULTRET) ? LUA_MULTRET
                    : ((_flexwant > ($COUNT + $PENDING))
                        ? (_flexwant - $COUNT - $PENDING) : 0))
            ]], {
                COUNT = flex.count,
                PENDING = c_integer_literal(pending_tail),
            }), "(_flexwant == LUA_MULTRET)", carrier)
        else
            cs, ce = codeexp(ctx, carrier)
        end
        if fi then
            -- The checker deliberately stops annotating statements after an
            -- always-escaping construct. C emission still visits that dead
            -- syntax, so use the destination type when such an unreachable
            -- return expression has no `_type` annotation.
            local sinktype = exp._type
                or (destination.fixed and destination.fixed[fi].typ)
                or ctx.rettypes[fi]
            local mstats, name = materialize_code(ctx,
                assert(sinktype), cs, ce)
            table.insert(cstats, mstats)
            if destination.fixed then
                local save = assert(destination.fixed[fi])
                table.insert(cstats, save.cvar .. " = " .. name .. ";")
                if save.slot then
                    -- Publish the frame root immediately: a later return
                    -- expression may allocate or relocate the Lua stack.
                    table.insert(cstats,
                        setslot(save.typ, slotat(save.slot), save.cvar))
                end
            else
                fixednames[fi] = name
            end
        elseif istail then
            -- Evaluate and stabilize the written carrier regardless of demand;
            -- return expressions retain their ordinary effects/order. Only the
            -- checker-inserted conversion to the flexible element type belongs
            -- to the result sink and is suppressed when this position is beyond
            -- the inherited finite budget.
            local carrier_type = assert(carrier._type or exp._type)
            local carrier_stats, carrier_name = materialize_code(ctx,
                carrier_type, cs, ce)
            table.insert(cstats, carrier_stats)
            local conversion_stats, value = "", carrier_name
            if carrier ~= exp then
                local replacement = {
                    _tag = "Ast.VarName",
                    _type = carrier_type,
                    _decl = { _cvar = carrier_name },
                }
                local converted = coder._retarget_implicit_tail(exp,
                    carrier, replacement)
                conversion_stats, value = codeexp(ctx, converted)
            end
            table.insert(cstats,
                append_flexible(conversion_stats, value))
            tail_seen = tail_seen + 1
        else
            -- This includes declared explicit surplus. `codeexp` supplies any
            -- setup statements; `(void)` forces bare foreign/scalar calls too.
            assert(coder._carries_open_source(exp, adjusted.open_source)
                or discard_set[exp] or exp._discard_results)
            table.insert(cstats, cs)
            table.insert(cstats, "(void)(" .. ce .. ");")
        end
    end
    if openrun then
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, flex.elem, "_ori", node.loc)
        local root = coder._flex_root(flex, flex.count)
        table.insert(cstats, render([[
            for (int _ori = 0; _ori < $RUNCOUNT; _ori++) {
                if (_flexwant == LUA_MULTRET || $COUNT < _flexwant) {
                    if (TITAN_UNLIKELY($COUNT >= TITAN_VARARG_MAX)) {
                        luaL_error(L, "too many flexible return values (max %d)",
                            (int)TITAN_VARARG_MAX);
                    }
                    $CONVSTATS
                    $ARGS[$COUNT] = $VALUE;
                    $ROOT
                    $COUNT++;
                }
            }
            $CLEANUP
        ]], {
            RUNCOUNT = openrun.count,
            COUNT = flex.count,
            ARGS = flex.args,
            CONVSTATS = convstats,
            VALUE = convexp,
            ROOT = root,
            CLEANUP = coder._cleanup_result_run(openrun),
        }))
    end
    if flex and destination.kind == "direct" then
        table.insert(cstats,
            "_flexout->n_args = (lu_byte)" .. flex.count .. ";")
    end
    return cstats, fixednames
end

local function codereturn(ctx, node)
    -- Route through an enclosing finally: evaluate into the innermost frame,
    -- publish RETURN only after every conversion and root write succeeded, then
    -- tear down the crossed boundaries and enter the finally.
    local fin = innermost_finally(ctx)
    if fin then
        fin.label_used = true
        local cstats = coder._lower_return_to_destination(ctx, node, {
            kind = "pending",
            fixed = fin.fixed,
            flex = fin.flex,
        })
        table.insert(cstats, fin.pa_var .. " = " .. PA_RETURN .. ";")
        table.insert(cstats,
            restore_boundaries_to(ctx, fin.boundary_floor))
        table.insert(cstats, "goto " .. fin.label .. ";")
        return table.concat(cstats, "\n")
    end

    -- Clean-exit restore (#3): a `return` crossing one or more protected regions
    -- must put L->errorJmp/nCcalls back to their function-entry values before the
    -- epilogue, so the dangling inner `_lj` is never reachable.
    local crossing = ctx.try_depth and ctx.try_depth > 0
    if crossing then ctx.used_entry_restore = true end
    local restore = crossing and restore_entry_errorjmp() .. "\n" or ""
    local destination = {
        kind = "direct",
        flex = ctx.flexrettype and {
            elem = ctx.flexrettype,
            args = "_flexout->args",
            ownership = "direct",
        } or false,
    }
    local cstats, fixednames = coder._lower_return_to_destination(ctx, node,
        destination)

    -- Always reset the stack top to _base on return. Read/copy the fixed
    -- results only after every lexical expression has executed, but before the
    -- final native return; no allocation occurs during this handoff.
    for i = 2, #ctx.rettypes do
        table.insert(cstats,
            "*_outparam_" .. i .. " = " .. assert(fixednames[i]) .. ";")
    end
    table.insert(cstats, restore)
    table.insert(cstats, "L->top.p = _base;")
    if #ctx.rettypes == 0 then
        table.insert(cstats, "return;")
    else
        table.insert(cstats, "return " .. assert(fixednames[1]) .. ";")
    end
    return table.concat(cstats, "\n")
end

-- `raise <exp>`: evaluate the (already `value`-coerced) operand into an anchored
-- temp, push it onto the Lua stack as the error object, then `lua_error(L)`. The
-- entry wrapper ensured `errorhandler` is active on `L->errfunc`, so the longjmp
-- through `lua_error` runs that handler, which builds the unified Lua+Titan trace before
-- unwinding. The temp is a `value`-typed (GC) TValue, so `newtmp` anchors it in a
-- reserved stack slot; that anchor keeps it alive across the `lua_checkstack`
-- (which may run the GC and reallocate the stack) before we copy it to the new top.
-- An `emitline` stamps the throw to the raise's exact `.titan` line so the native
-- frame symbolizes there (mirrors `codethrow`).
local function coderaise(ctx, node)
    if not node.exp then
        -- Bare `raise` (re-raise) — legal only inside a catch (checker-enforced).
        -- Reinstall the catch's saved `traceback` into registry[TITAN_BACKTRACE_KEY]
        -- and SET the pin (TITAN_TRACE_PINNED), so errorhandler KEEPS the ORIGINAL
        -- trace rather than capturing a fresh one at this (shallower) re-raise
        -- site; then push the saved `error` value and lua_error(L). The enclosing
        -- catch's implicit locals are threaded through ctx (`ctx.catch_*_decl`).
        local errcvar = ctx.catch_error_decl._cvar      -- TValue (the error value)
        local tbcvar = ctx.catch_traceback_decl._cvar   -- TString* (the trace)
        return render([[
            lua_checkstack(L, 2);
            lua_pushliteral(L, TITAN_BACKTRACE_KEY);
            setsvalue2s(L, L->top.p, $TB);
            L->top.p++;
            lua_rawset(L, LUA_REGISTRYINDEX);
            lua_pushliteral(L, TITAN_TRACE_PINNED);
            lua_pushboolean(L, 1);
            lua_rawset(L, LUA_REGISTRYINDEX);
            setobj2s(L, L->top.p, &$ERR);
            L->top.p++;
            $LINEDIR
            lua_error(L);
        ]], {
            LINEDIR = emitline(node),
            TB = tbcvar,
            ERR = errcvar,
        })
    end
    local cstats, cexp = codeexp(ctx, node.exp)
    local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
    return render([[
        $CSTATS
        $CTMP
        $TMPNAME = $CEXP;
        $ANCHOR
        lua_checkstack(L, 1);
        setobj2t(L, s2v(L->top.p), &$TMPNAME);
        L->top.p++;
        $LINEDIR
        lua_error(L);
    ]], {
        CSTATS = cstats,
        CTMP = ctmp,
        TMPNAME = tmpname,
        CEXP = cexp,
        ANCHOR = setslot(types.Value(), tmpslot, tmpname),
        LINEDIR = emitline(node),
    })
end

-- Find the innermost enclosing finally frame that is in the SAME target loop as a
-- `break` issued at the current point (i.e. opened at or below the innermost
-- loop). A break inside a finally-protected region must run that finally before it
-- can reach the loop; if there is none in the loop, the break is realized directly
-- (restore loop errorjmp + goto past the loop). `ctx.loopstack`/`ctx.finally_stack`
-- reflect the lexical context of the call site.
local function enclosing_break_finally(ctx)
    local fs = ctx.finally_stack
    if not fs or #fs == 0 then return nil end
    local loop_len = ctx.loopstack and #ctx.loopstack or 0
    local fin = fs[#fs]
    -- The frame is between the break and the innermost loop iff it was opened while
    -- that loop (or a deeper one) was already on the stack.
    if fin.loopstack_len >= loop_len and loop_len > 0 then
        return fin
    end
    return nil
end

-- Realize a `break` at the current point: if an enclosing finally lies between the
-- break and its target loop, route through it (set pending BREAK, goto its
-- finally); otherwise restore the loop-entry errorjmp/nC (if a try boundary is
-- open) and `goto` the label past the enclosing loop (NOT a bare `break`, which a
-- dispatch if-chain could not safely sit inside). Used by both the StatBreak arm
-- and the PA_BREAK dispatch arm (which chains finallys inside-out).
local function realize_break(ctx)
    local fin = enclosing_break_finally(ctx)
    if fin then
        fin.label_used = true
        return render([[
            $PA = $PABREAK;
            $RESTORE
            goto $LABEL;
        ]], {
            PA = fin.pa_var,
            PABREAK = PA_BREAK,
            RESTORE = restore_boundaries_to(ctx, fin.boundary_floor),
            LABEL = fin.label,
        })
    end
    -- direct break: target the innermost loop frame, restoring its entry errorjmp
    -- if a try boundary is open between here and the loop entry.
    local frame = ctx.loopstack and ctx.loopstack[#ctx.loopstack]
    assert(frame, "internal error: break with no enclosing loop")
    frame.uses_after_label = true
    local restore = ""
    if frame.save_id and (ctx.try_depth or 0) > frame.try_depth then
        frame.used = true
        restore = render([[
            L->errorJmp = _loop_errorjmp_$ID;
            L->nCcalls = _loop_nC_$ID;
        ]], { ID = c_integer_literal(frame.save_id) })
    end
    return render([[
        $RESTORE
        goto $AFTER;
    ]], { RESTORE = restore, AFTER = "_after_loop_" .. frame.after_id })
end

-- The pending-action dispatch if-chain emitted after a finally (B.3 rule i). Never
-- a C `switch` (which would capture PA_BREAK's `break`). PA_RETURN/PA_BREAK chain
-- through any enclosing finally; PA_RAISE reinstalls the saved trace + pin and
-- re-raises; PA_NONE falls through.
local function dispatch_after_finally(ctx, pa_var, frame, d_pa_err, d_pa_tb)
    -- RETURN arm: chain to an outer finally if one encloses this try, else emit
    -- the real return epilogue with the saved values.
    local outer_fin = innermost_finally(ctx)
    local return_arm
    if outer_fin then
        outer_fin.label_used = true
        -- Copy this try's complete pending return into the outer frame. Inner
        -- roots stay live until every outer backing/root write and the final
        -- count publication are complete. Only then publish RETURN, restore all
        -- boundaries crossed by the goto, and enter the outer finally.
        local lines = {}
        for i = 1, #frame.fixed do
            local from = frame.fixed[i]
            local to = outer_fin.fixed[i]
            table.insert(lines,
                to.cvar .. " = " .. coder._saved_fixed_value(from) .. ";")
            if to.slot then
                table.insert(lines, setslot(to.typ, slotat(to.slot), to.cvar))
            end
        end
        if frame.flex then
            assert(outer_fin.flex)
            local copy_count = "_pa_copy_count_" .. frame.id
                .. "_" .. outer_fin.id
            local copy_index = "_pa_copy_i_" .. frame.id
                .. "_" .. outer_fin.id
            table.insert(lines, coder._reset_pending_flex(outer_fin.flex))
            table.insert(lines, "int " .. copy_count .. " = (int)"
                .. frame.flex.count .. ";")
            table.insert(lines, render([[
                for (int $INDEX = 0; $INDEX < $COPYCOUNT; $INDEX++) {
                    $TOARGS[$INDEX] = $FROMARGS[$INDEX];
                    $ROOT
                }
                $TOCOUNT = $COPYCOUNT;
            ]], {
                INDEX = copy_index,
                COPYCOUNT = copy_count,
                TOARGS = outer_fin.flex.args,
                FROMARGS = frame.flex.args,
                ROOT = coder._flex_root(outer_fin.flex, copy_index),
                TOCOUNT = outer_fin.flex.count,
            }))
        end
        table.insert(lines, outer_fin.pa_var .. " = " .. PA_RETURN .. ";")
        table.insert(lines,
            restore_boundaries_to(ctx, outer_fin.boundary_floor))
        table.insert(lines, "goto " .. outer_fin.label .. ";")
        return_arm = table.concat(lines, "\n")
    else
        return_arm = dispatch_return_epilogue(ctx, frame)
    end

    -- BREAK arm: chain through enclosing finallys or break past the loop. Only a
    -- try that is itself inside a loop can ever observe a pending BREAK (a break in
    -- the body/catch targets the innermost ENCLOSING loop; a break to a loop
    -- written inside the body is handled by that inner loop's own frame). With no
    -- enclosing loop, PA_BREAK is unreachable, so emit nothing.
    local break_arm = (ctx.loopstack and #ctx.loopstack > 0)
        and realize_break(ctx) or "/* unreachable: no enclosing loop */ ;"

    -- RAISE arm: reinstall the saved trace + pin (preserve original trace), push
    -- the saved error, lua_error.
    local raise_arm = render([[
        lua_checkstack(L, 2);
        lua_pushliteral(L, TITAN_BACKTRACE_KEY);
        setsvalue2s(L, L->top.p, tsvalue($PATB));
        L->top.p++;
        lua_rawset(L, LUA_REGISTRYINDEX);
        lua_pushliteral(L, TITAN_TRACE_PINNED);
        lua_pushboolean(L, 1);
        lua_rawset(L, LUA_REGISTRYINDEX);
        setobj2s(L, L->top.p, $PAERR);
        L->top.p++;
        lua_error(L);
    ]], {
        PATB = slotat(d_pa_tb),
        PAERR = slotat(d_pa_err),
    })

    return render([[
        if ($PA == $PARETURN) {
            $RETARM
        } else if ($PA == $PABREAK) {
            $BREAKARM
        } else if ($PA == $PARAISE) {
            $RAISEARM
        }
        /* PA_NONE: fall through past the try */
    ]], {
        PA = pa_var,
        PARETURN = PA_RETURN,
        PABREAK = PA_BREAK,
        PARAISE = PA_RAISE,
        RETARM = return_arm,
        BREAKARM = break_arm,
        RAISEARM = raise_arm,
    })
end

-- The "save" prologue of an inline setjmp boundary (rawrunprotected save), tagged
-- with `tag` so a try with two boundaries (body + catch) keeps distinct locals.
local function boundary_save(tag)
    return render([[
        /* inline protected boundary (rawrunprotected save) */
        l_uint32 _oldnC_$T = L->nCcalls;
        CallInfo *_oldci_$T = L->ci;
        lu_byte _oldah_$T = L->allowhook;
        ptrdiff_t _oldtop_$T = savestack(L, L->top.p);
        ptrdiff_t _olderrfunc_$T = L->errfunc;
        lua_longjmp _lj_$T;
        _lj_$T.status = LUA_OK;
        _lj_$T.previous = L->errorJmp;
        L->errorJmp = &_lj_$T;
        if (TITAN_SETJMP(_lj_$T.b) == 0) {
    ]], { T = tag })
end

-- The "tail" that closes a boundary's protected block and restores the
-- error-handler chain (rawrunprotected tail), opening the `if (status != OK)`
-- recovery arm and saving the caught error into slot `d_err` and its snapshotted
-- trace into slot `d_tb`. The caller supplies the recovery body and closes braces.
local function boundary_recover_open(ctx, tag, d_err, d_tb)
    return render([[
        }
        /* restore the error-handler chain (rawrunprotected tail) */
        L->errorJmp = _lj_$T.previous;
        L->nCcalls = _oldnC_$T;
        if (_lj_$T.status != LUA_OK) {
            /* raised; errorhandler already filled the trace slot. Mirror
            ** luaD_pcall's recovery: restore ci/allowhook, close any to-be-
            ** closed vars from called Lua, materialize the error object. */
            L->ci = _oldci_$T;
            L->allowhook = _oldah_$T;
            /* A longjmp can skip an inner Titan Lua-entry wrapper before that
            ** wrapper restores L->errfunc. Put the boundary-entry message
            ** handler back before closing Lua frames, so any __close error is
            ** handled by a valid Titan errorhandler instead of a stale stack
            ** slot from the skipped inner entry. */
            L->errfunc = _olderrfunc_$T;
            _lj_$T.status = luaD_closeprotected(L, _oldtop_$T, _lj_$T.status);
            luaD_seterrorobj(L, _lj_$T.status, restorestack(L, _oldtop_$T));
            if (TITAN_UNLIKELY(!lua_checkstack(L, 4)))
                luaD_throw(L, LUA_ERRMEM);
            /* a value-call or another stack-growing operation inside the protected
            ** region may have reallocated the stack; recompute _base before
            ** touching any reserved slot */
            _base = restorestack(L, _base_off);
            /* save the error object into its anchored slot, then drop it from the
            ** top; the registry snapshot/clear below pushes within the
            ** lua_checkstack(4) margin established above. */
            setobj2s(L, $ERRSTACK, s2v(L->top.p - 1));
            L->top.p = restorestack(L, _oldtop_$T);
            /* snapshot registry[TITAN_BACKTRACE_KEY] into the traceback slot */
            lua_pushliteral(L, TITAN_BACKTRACE_KEY);
            lua_rawget(L, LUA_REGISTRYINDEX);
            if (!ttisstring(s2v(L->top.p - 1))) {
                L->top.p--;
                lua_pushliteral(L, "");
            }
            setobj2s(L, $TBSTACK, s2v(L->top.p - 1));
            L->top.p--;
            /* clear slot + pin so a fresh error raised later is captured anew
            ** (a bare re-raise re-pins the saved trace) */
            lua_pushliteral(L, TITAN_BACKTRACE_KEY);
            lua_pushnil(L);
            lua_rawset(L, LUA_REGISTRYINDEX);
            lua_pushliteral(L, TITAN_TRACE_PINNED);
            lua_pushnil(L);
            lua_rawset(L, LUA_REGISTRYINDEX);
            /* re-establish the function's steady-state reserved top
            ** (`_base + nslots`) so any reserved slots used in the recovery sit
            ** below L->top.p and are GC-scanned. The literal nslots is patched in
            ** by codefuncdec/codelambdadec once the high-water mark is known. */
            L->top.p = _base + TITAN_RESERVED_NSLOTS;
            $SPILLRELOAD
    ]], {
        T = tag,
        ERRSTACK = stackslotat(d_err),
        TBSTACK = stackslotat(d_tb),
        SPILLRELOAD = spill_reload(ctx),
    })
end

-- `catch`/`finally` codegen.
--
-- A StatTry wraps its body in an inline setjmp boundary that replicates
-- luaD_rawrunprotected + luaD_pcall's error recovery, emitted as straight-line C
-- in the native function (no thunk, no capture conversion). The Lua entry wrapper
-- already ensured errorhandler is active on L->errfunc, and luaG_errormsg invokes
-- it regardless of which boundary is on L->errorJmp, so the unified trace is
-- already in registry[TITAN_BACKTRACE_KEY] by the time the longjmp lands here.
--
-- Per-try anchored slots (reserveslot -> depths within the function's _base..nslots
-- region) hold the caught error value and the snapshotted trace string; a write
-- into a stack slot needs no GC barrier (the stack is a root).
--
-- Boundary accounting (B.4): the BODY always gets a boundary. A CATCH gets its
-- OWN boundary only when a FINALLY follows (so a raise in the catch still runs the
-- finally); without a finally a catch error propagates to the outer boundary.
-- A FINALLY itself installs no boundary: it is straight-line,
-- and a raise/runtime error in it longjmps out, skipping the dispatch (override).
local function codetry(ctx, node)
    -- A function containing a try always needs `_base` recomputed from an offset
    -- after a caught longjmp (a value-call or GC inside the body may have
    -- relocated the stack), so force the base-offset preamble.
    ctx.uses_base_off = true
    ctx.try_id = (ctx.try_id or 0) + 1
    local id = ctx.try_id
    local has_finally = node.finallyblock and true or false
    local has_catch = node.catchblock and true or false

    -- Reserve the per-try anchored slots up front (depths persist across the body,
    -- catch, and finally). The recovery recomputes addresses inline from a freshly
    -- restored `_base`, so only the depth index is needed.
    local d_err = reserveslot(ctx)   -- the BODY-boundary caught error
    local d_tb = reserveslot(ctx)    -- ... and its snapshotted trace
    -- For a try-with-finally, the pending RAISE carries its own saved error +
    -- trace slots (set on a body raise with no catch, or on a catch raise), since
    -- the dispatch re-raises after the finally runs.
    local d_pa_err, d_pa_tb
    if has_finally then
        d_pa_err = reserveslot(ctx)
        d_pa_tb = reserveslot(ctx)
    end

    -- Per-try pending-action discriminator + saved-return storage (finally only).
    local pa_var = "_pa_" .. id
    local fin_label = "_finally_" .. id
    local ret_frame, ret_decls, fin_frame
    if has_finally then
        ret_frame, ret_decls = make_return_frame(ctx, id)
        -- Push the finally frame so body/catch `return`/`break` route here. Record
        -- the current loop nesting so a break can decide whether an OUTER finally
        -- in the same target loop must also run (chaining).
        ctx.finally_stack = ctx.finally_stack or {}
        ret_frame.pa_var = pa_var
        ret_frame.label = fin_label
        ret_frame.loopstack_len = ctx.loopstack and #ctx.loopstack or 0
        ret_frame.boundary_floor = ctx.protected_boundary_stack
            and #ctx.protected_boundary_stack or 0
        ret_frame.label_used = false -- set when return/break gotos it
        table.insert(ctx.finally_stack, ret_frame)
        fin_frame = ret_frame
    end

    -- The body and catch run as protected straight-line C. Within them, a
    -- `return`/`break` that escapes a NON-finally try must clean-exit-restore the
    -- errorjmp chain (#3); for a finally try, return/break route to the finally
    -- instead (codereturn / the StatBreak arm consult ctx.finally_stack first).
    ctx.try_depth = (ctx.try_depth or 0) + 1
    push_boundary(ctx, tostring(id))
    local cbody = node.block._defer_tail
        and codetransparentblock(ctx, node.block)
        or codestat(ctx, node.block)
    if ctx.entry_try == node then
        -- A function-scope catch is also the safety boundary for a trusted
        -- native entry (for example the coroutine and libuv dispatchers).
        -- Install its jump target before the entry GC step: an emergency-GC
        -- allocation failure must land in the Titan catch, never unwind across
        -- the native caller's stack. Callback domains reserve LUA_MINSTACK
        -- before entry, so the non-raising stack reservation preamble remains
        -- safe outside this boundary.
        cbody = [[
            luaC_checkGC(L);
            _base = restorestack(L, _base_off);
        ]] .. cbody
    end
    pop_boundary(ctx)
    ctx.try_depth = ctx.try_depth - 1

    -- Bind the catch's implicit locals to C autos populated in the recovery.
    local errcvar = "_catch_error_" .. id
    local tbcvar = "_catch_tb_" .. id
    local ccatch = ""
    if has_catch then
        local errdecl = node._error_decl
        local tbdecl = node._traceback_decl
        errdecl._cvar = errcvar
        tbdecl._cvar = tbcvar
        local saved_err, saved_tb = ctx.catch_error_decl, ctx.catch_traceback_decl
        ctx.catch_error_decl = errdecl
        ctx.catch_traceback_decl = tbdecl
        ctx.try_depth = ctx.try_depth + 1
        if has_finally then push_boundary(ctx, id .. "c") end
        ccatch = codestat(ctx, node.catchblock)
        if has_finally then pop_boundary(ctx) end
        ctx.try_depth = ctx.try_depth - 1
        ctx.catch_error_decl, ctx.catch_traceback_decl = saved_err, saved_tb
    end

    -- Pop the finally frame BEFORE coding the finally block: a `return`/`break`
    -- inside the finally must NOT loop back to this finally (it would be illegal —
    -- the checker bans escaping return/break in a finally — and a contained break
    -- targets a loop opened inside the finally, handled by the normal loop frame).
    if has_finally then
        table.remove(ctx.finally_stack)
    end
    local cfinally = has_finally and codestat(ctx, node.finallyblock) or ""

    if not has_finally then
        -- Body boundary; on error, materialize+bind catch locals
        -- and run the catch directly (no own boundary — its raise propagates out).
        return render([[
            {
                $SAVE
                    $CBODY
                $RECOVER
                    TValue $ERR = *$ERRSLOT;
                    TString *$TB = tsvalue($TBSLOT);
                    (void)$ERR;
                    (void)$TB;
                    $CCATCH
                }
            }
        ]], {
            SAVE = boundary_save(tostring(id)),
            CBODY = cbody,
            RECOVER = boundary_recover_open(ctx, tostring(id), d_err, d_tb),
            CCATCH = ccatch,
            ERR = errcvar,
            TB = tbcvar,
            ERRSLOT = slotat(d_err),
            TBSLOT = slotat(d_tb),
        })
    end

    -- ===== try WITH finally =====

    -- On a caught error with NO catch: stash error+trace into the PA_RAISE slots
    -- and set pending RAISE (reinstall the original trace when re-raising).
    local no_catch_raise = render([[
        setobj2t(L, $PAERR, $ERR);
        setsvalue(L, $PATB, tsvalue($TB));
        $PA = $PARAISE;
    ]], {
        PAERR = slotat(d_pa_err),
        PATB = slotat(d_pa_tb),
        ERR = slotat(d_err),
        TB = slotat(d_tb),
        PA = pa_var,
        PARAISE = PA_RAISE,
    })

    -- The catch body, run under ITS OWN boundary so a raise in it still runs the
    -- finally. The body boundary's recovery binds the catch locals, then opens a
    -- second boundary around the catch; on a catch error -> stash to PA_RAISE
    -- slots + pending RAISE; on catch normal completion the pending stays whatever
    -- the body set it to (NONE unless a return/break in the body routed here, but
    -- a body that raised reached here by error, so it is NONE -> finally swallows).
    local catch_under_boundary = ""
    if has_catch then
        catch_under_boundary = render([[
            TValue $ERR = *$ERRSLOT;
            TString *$TB = tsvalue($TBSLOT);
            (void)$ERR;
            (void)$TB;
            $CSAVE
                $CCATCH
            $CRECOVER
                $NOCATCHRAISE
            }
        ]], {
            ERR = errcvar,
            TB = tbcvar,
            ERRSLOT = slotat(d_err),
            TBSLOT = slotat(d_tb),
            CSAVE = boundary_save(id .. "c"),
            CCATCH = ccatch,
            CRECOVER = boundary_recover_open(ctx, id .. "c", d_err, d_tb),
            NOCATCHRAISE = no_catch_raise,
        })
    else
        -- finally-only: a body error becomes a pending RAISE re-propagated after
        -- the finally (rule c).
        catch_under_boundary = no_catch_raise
    end

    local dispatch = dispatch_after_finally(ctx, pa_var, ret_frame,
        d_pa_err, d_pa_tb)

    local tmpl
    if node._defer_tail then
        tmpl = [[
            int $PA = $PANONE;
            $RETDECLS
            $SAVE
                $CBODY
            $RECOVER
                $CATCHARM
            }
            $FINLABEL
            $CFINALLY
            /* dispatch the pending action (if-chain — never a C switch, which
            ** would capture the PA_BREAK arm's `break`) */
            $DISPATCH
        ]]
    else
        tmpl = [[
            {
                int $PA = $PANONE;
                $RETDECLS
                {
                    $SAVE
                        $CBODY
                    $RECOVER
                        $CATCHARM
                    }
                }
                $FINLABEL
                $CFINALLY
                /* dispatch the pending action (if-chain — never a C switch, which
                ** would capture the PA_BREAK arm's `break`) */
                $DISPATCH
            }
        ]]
    end

    return render(tmpl, {
        PA = pa_var,
        PANONE = PA_NONE,
        RETDECLS = ret_decls,
        SAVE = boundary_save(tostring(id)),
        CBODY = cbody,
        RECOVER = boundary_recover_open(ctx, tostring(id), d_err, d_tb),
        CATCHARM = catch_under_boundary,
        FINLABEL = fin_frame.label_used and (fin_label .. ": ;") or "",
        CFINALLY = cfinally,
        DISPATCH = dispatch,
    })
end

local function localname(ctx, name)
    local idx = ctx.names[name] or 1
    ctx.names[name] = idx + 1
    return name .. "_" .. tostring(idx)
end

local function forin_is_nil(typ, cexp)
    if typ._tag == "Type.Option" or typ._tag == "Type.Value" then
        return "ttisnil(&" .. cexp .. ")"
    elseif types.is_c_tvalue(typ) then
        return "ttisnil(&" .. cexp .. ")"
    elseif types.resolve_c_typedef(typ)._tag == "Type.CPointer" then
        return "(" .. cexp .. " == NULL)"
    elseif typ._tag == "Type.Nil" then
        return "1"
    else
        return "0"
    end
end

local function code_hidden_decl(ctx, decl, exp, prepared)
    local typ = decl._type
    local cstats, cexp
    if prepared then
        cstats, cexp = "", prepared
    else
        cstats, cexp = codeexp(ctx, exp)
    end
    decl._cvar = "_forin_" .. localname(ctx, decl.name)
    local cset = ""
    if types.is_gc(typ) then
        decl._slot = newslot(ctx)
        cset = setslot(typ, decl._slot, decl._cvar)
    end
    return render([[
        $CSTATS
        $CDECL
        $CVAR = $CEXP;
        (void)$CVAR;
        $CSET
    ]], {
        CSTATS = cstats,
        CDECL = cvardecl(ctx, typ, decl._cvar) .. " = " .. initval(typ) .. ";",
        CVAR = decl._cvar,
        CEXP = cexp,
        CSET = cset,
    })
end

local function code_hidden_result_decls(ctx, decls)
    local out = {}
    for _, decl in ipairs(decls) do
        local typ = decl._type
        decl._cvar = "_forin_" .. localname(ctx, decl.name)
        if types.is_gc(typ) then
            decl._slot = newslot(ctx)
        end
        table.insert(out, cvardecl(ctx, typ, decl._cvar)
            .. " = " .. initval(typ) .. ";")
    end
    return table.concat(out, "\n")
end

local function predeclare_defer_tail(ctx, block)
    local out = {}
    local function visit_block(b)
        for _, stat in ipairs(b.stats) do
            if stat._tag == "Ast.StatDecl" then
                for _, decl in ipairs(stat.decls) do
                    if decl._used and not (decl._captured and decl._assigned)
                       and not decl._defer_tail_predeclared then
                        decl._cvar = "_local_" .. localname(ctx, decl.name)
                        decl._defer_tail_predeclared = true
                        table.insert(out, cvardecl(ctx, decl._type, decl._cvar) .. ";")
                        local spill = spill_decl_zero(ctx, decl)
                        if spill ~= "" then
                            decl._defer_tail_spill_predeclared = true
                            table.insert(out, spill)
                        end
                    end
                end
            elseif stat._tag == "Ast.StatTry" and stat._defer_tail then
                visit_block(stat.block)
            end
        end
    end
    visit_block(block)
    return table.concat(out, "\n")
end

local function code_hidden_assign(decl, cexp)
    local cset = ""
    if types.is_gc(decl._type) then
        cset = setslot(decl._type, decl._slot, decl._cvar)
    end
    return render([[
        $CVAR = $CEXP;
        $CSET
    ]], {
        CVAR = decl._cvar,
        CEXP = cexp,
        CSET = cset,
    })
end

local function code_forin_call(ctx, call, result_decls)
    local cstats, cexp = codeexp(ctx, call)
    local out = { cstats }
    if result_decls[1] then
        table.insert(out, code_hidden_assign(result_decls[1], cexp))
    end
    for i = 2, #result_decls do
        table.insert(out, code_hidden_assign(result_decls[i], call._extras[i]))
    end
    return table.concat(out, "\n")
end

local function codeforinrun(ctx, node)
    local forin = node.forin
    local initcall = code_forin_call(ctx, forin._init_call, forin._result_decls)
    local visible = codestat(ctx, forin._visible_stat)
    local body = codestat(ctx, forin.block)
    local nextcall = code_forin_call(ctx, forin._next_call, forin._result_decls)
    local ctrl = forin._result_decls[1]
    return render([[
        $INITCALL
        while (1) {
            if ($ISNIL) {
                break;
            }
            $VISIBLE
            $BODY
            $NEXTCALL
            luaC_checkGC(L);
            _base = restorestack(L, _base_off);
        }
    ]], {
        INITCALL = initcall,
        ISNIL = forin_is_nil(ctrl._type, ctrl._cvar),
        VISIBLE = visible,
        BODY = body,
        NEXTCALL = nextcall,
    })
end

local function codeforin(ctx, node)
    pushd(ctx)
    ctx.uses_base_off = true
    local tuple, tuplevalues = coder._codeadjustedfixed(ctx, {
        _result_adjustment = node._tuple_adjustment,
        exps = node.exps,
    })
    for i, decl in ipairs(node._tuple_decls) do
        table.insert(tuple,
            code_hidden_decl(ctx, decl, node.exps[i], tuplevalues[i]))
    end
    table.insert(tuple, code_hidden_result_decls(ctx, node._result_decls))

    local frame = open_loop(ctx, node)
    local runnode = { _tag = "Ast.StatForInRun", loc = node.loc, forin = node }
    local loopcode
    if node._has_close then
        local closestat = {
            _tag = "Ast.StatCall",
            loc = node.loc,
            callexp = node._close_call,
            _forin_nil_guard = node._runtime_optional_close
                and node._tuple_decls[4] or false,
        }
        local trynode = {
            _tag = "Ast.StatTry",
            loc = node.loc,
            block = {
                _tag = "Ast.StatBlock",
                loc = node.loc,
                stats = { runnode },
            },
            catchblock = false,
            finallyblock = {
                _tag = "Ast.StatBlock",
                loc = node.loc,
                stats = { closestat },
            },
        }
        loopcode = codestat(ctx, trynode)
    else
        loopcode = codestat(ctx, runnode)
    end
    close_loop(ctx)
    popd(ctx)

    return render([[
        {
            $TUPLE
            $LOOPSAVE
            $LOOPCODE
        }$AFTER
    ]], {
        TUPLE = table.concat(tuple, "\n"),
        LOOPSAVE = loop_save_lines(frame),
        LOOPCODE = loopcode,
        AFTER = after_loop_label(frame),
    })
end

local function codestat_dispatch(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatDecl" then
        local code, initnames = coder._codeadjustedfixed(ctx, node)
        local fixed = node._result_adjustment
            and node._result_adjustment.fixed or node.exps
        for i = 1, #node.decls do
            local exp = fixed[i]
            local decl = node.decls[i]
            local cstats, cexp = "", assert(initnames[i])
            decl._boxed = decl._captured and decl._assigned
            if decl._boxed then
                -- Captured-and-mutated: storage is a heap box (Udata cell).
                -- Ordering avoids an unanchored-box window: (1) evaluate the init
                -- into a temp (it may allocate); (2) create+anchor the box with no
                -- allocation between alloc and anchor; (3) store the init into the
                -- box (with the back barrier if gc).
                local typ = decl._type
                local isgc = types.is_gc(typ)
                local n = localname(ctx, decl.name)
                -- A gc init value must be anchored in a stack slot before the box
                -- allocation (luaC_newobj can run the GC), so the still-white
                -- init is not swept while only held in a C local.
                local ctmp, tmpname, tmpslot = newtmp(ctx, typ, isgc)
                decl._box = "_box_" .. n
                local boxslot = newslot(ctx)
                local anchortmp = tmpslot
                    and setslot(typ, tmpslot, tmpname) or ""
                table.insert(code, render([[
                    $CSTATS
                    $CTMP
                    $TMPNAME = $CEXP;
                    $ANCHORTMP
                    $NEWBOX
                    $SETSLOT
                ]], {
                    CSTATS = cstats,
                    CTMP = ctmp,
                    TMPNAME = tmpname,
                    CEXP = cexp,
                    ANCHORTMP = anchortmp,
                    NEWBOX = newbox(ctx, typ, decl._box, boxslot),
                    SETSLOT = box_write(typ, decl._box, tmpname),
                }))
            elseif decl._used then
                local typ = decl._type
                if not decl._cvar then
                    decl._cvar = "_local_" .. localname(ctx, decl.name)
                end
                local cdecl = decl._defer_tail_predeclared
                    and "" or cvardecl(ctx, typ, decl._cvar) .. ";"
                local cslot = ""
                local cset = ""
                local cspilldecl = decl._defer_tail_spill_predeclared
                    and "" or spill_decl_zero(ctx, decl)
                local cspillset = spill_update(decl)
                if types.is_gc(typ) then
                    decl._slot = newslot(ctx)
                    cset = render([[
                        /* update slot */
                        $SETSLOT
                    ]], {
                        SETSLOT = setslot(typ, decl._slot, decl._cvar),
                    })
                end
                table.insert(code, render([[
                    $CDECL
                    $CSPILLDECL
                    $CSLOT
                    $CSTATS
                    $CVAR = $CEXP;
                    $CSET
                    $CSPILLSET
                ]], {
                    CDECL = cdecl,
                    CSPILLDECL = cspilldecl,
                    CSLOT = cslot,
                    CSTATS = cstats,
                    CVAR = decl._cvar,
                    CEXP = cexp,
                    CSET = cset,
                    CSPILLSET = cspillset,
                }))
            else
                table.insert(code, render([[
                    $CSTATS
                    ((void)$CEXP);
                ]], {
                    CSTATS = cstats,
                    CEXP = cexp
                }))
            end
        end
        return table.concat(code, "\n")
    elseif tag == "Ast.StatBlock" then
        return codeblock(ctx, node)
    elseif tag == "Ast.StatWhile" then
        return codewhile(ctx, node)
    elseif tag == "Ast.StatRepeat" then
        return coderepeat(ctx, node)
    elseif tag == "Ast.StatIf" then
        return codeif(ctx, node)
    elseif tag == "Ast.StatFor" then
        return codefor(ctx, node)
    elseif tag == "Ast.StatForIn" then
        return codeforin(ctx, node)
    elseif tag == "Ast.StatForInRun" then
        return codeforinrun(ctx, node)
    elseif tag == "Ast.StatAssign" then
        if #node.vars == 1 then
            return codesingleassignment(ctx, node)
        else
            return codemultiassignment(ctx, node)
        end
    elseif tag == "Ast.StatCall" then
        local callee = node.callexp.exp
        local callcode
        if node.callexp._c_pointer_call then
            local fstats, fexp = codecfunctionptrcall(ctx, node.callexp)
            callcode = fstats .. "\n    ((void)(" .. fexp .. "));"
        elseif callee.var and callee.var._tag == "Ast.VarDot"
           and callee.var.exp._type._tag == "Type.CModule" then
            local fstats, fexp = codeforeigncall(ctx, node.callexp)
            callcode = fstats .. "\n    ((void)(" .. fexp .. "));"
        else
            local cstats, cexp = codecall(ctx, node.callexp)
            callcode = cstats .. "\n    ((void)(" .. cexp .. "));"
        end
        if node._forin_nil_guard then
            local decl = node._forin_nil_guard
            assert(decl._type._tag == "Type.Function" and decl._cvar)
            return render([[
                if (!ttisnil(&$CLOSE)) {
                    $CALL
                }
            ]], {
                CLOSE = decl._cvar,
                CALL = callcode,
            })
        end
        return callcode
    elseif tag == "Ast.StatReturn" then
        return codereturn(ctx, node)
    elseif tag == "Ast.StatBreak" then
        -- A `break` inside the body/catch of an enclosing try-with-finally (in the
        -- same target loop) must run that finally first: set its pending BREAK and
        -- `goto` the finally (which then chains outward or breaks past the loop).
        if enclosing_break_finally(ctx) then
            return realize_break(ctx)
        end
        -- Clean-exit restore (#3): a `break` crossing one or more protected
        -- regions inside its target loop must restore L->errorJmp/nCcalls to the
        -- loop's entry values (saved when the loop body contains a try) before
        -- the C `break`, else L->errorJmp dangles to an out-of-scope `_lj`. The
        -- target loop is the innermost loop frame; a restore is needed only when
        -- a try boundary is open between this break and that loop entry.
        local frame = ctx.loopstack and ctx.loopstack[#ctx.loopstack]
        if frame and frame.save_id and (ctx.try_depth or 0) > frame.try_depth then
            frame.used = true   -- the loop must emit its entry errorjmp/nC save
            return render([[
                L->errorJmp = _loop_errorjmp_$ID;
                L->nCcalls = _loop_nC_$ID;
                break;]], { ID = c_integer_literal(frame.save_id) })
        end
        return "break;"
    elseif tag == "Ast.StatRaise" then
        return coderaise(ctx, node)
    elseif tag == "Ast.StatTry" then
        local predecls = node._defer_tail and predeclare_defer_tail(ctx, node.block) or ""
        local trycode = codetry(ctx, node)
        if predecls == "" then return trycode end
        return predecls .. "\n" .. trycode
    else
        error("invalid node tag " .. tag)
    end
end

-- Prepend a `#line` directive so each statement's generated C attributes back
-- to its .titan source line, then dispatch.
-- The directive is a standalone leading line; codestat_dispatch never splices
-- between multiply-referenced operand slots, so this cannot misattribute or
-- break an un-hoisted operand.
function codestat(ctx, node)
    return emitline(node) .. codestat_dispatch(ctx, node)
end

-- All the code generation functions for EXPRESSIONS return
-- preliminary C code necessary for computing the expression
-- as a string of C statements, plus the code for the expression
-- as a string with a C expression. For trivial expressions
-- the preliminary code is always the empty string

local function code_owned_payload(owner, pointee)
    return render("(($CT *)getudatamem($OWNER))", {
        CT = foreignctype(pointee),
        OWNER = owner,
    })
end

codecindex_parts = function(ctx, node)
    local basetype = types.resolve_c_typedef(node.exp1._type)
    local bstats, bexp = codeexp(ctx, node.exp1)
    local istats, iexp = codeexp(ctx, node.exp2)
    local cidx, idxname = newtmp(ctx, types.Integer())
    local baseexp, lenexp, bounds

    if basetype._tag == "Type.CPointer" then
        local cbase, basename = newtmp(ctx, node.exp1._type)
        bstats = render([[
            $BSTATS
            $CBASE
            $BASENAME = $BEXP;
            if (TITAN_UNLIKELY($BASENAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot index a NULL C pointer", $FILE, $LINE, $COL);
            }
        ]], {
            BSTATS = bstats,
            CBASE = cbase,
            BASENAME = basename,
            BEXP = bexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
        baseexp = basename
        bounds = ""
    elseif basetype._tag == "Type.CArray" then
        baseexp = bexp
        lenexp = c_integer_literal(basetype.len)
    elseif basetype._tag == "Type.COwned" then
        baseexp = code_owned_payload(bexp, basetype.pointee)
        lenexp = render("((lua_Integer)($OWNER->len / sizeof($CT)))", {
            OWNER = bexp,
            CT = foreignctype(basetype.pointee),
        })
    else
        error("invalid C index base " .. types.tostring(node.exp1._type))
    end

    if lenexp then
        bounds = render([[
            if (TITAN_UNLIKELY($IDX < 0 || $IDX >= $LEN)) {
                luaL_error(L, "%s:%d:%d: C index %I out of range [0, %d)", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
            }
        ]], {
            IDX = idxname,
            LEN = lenexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    end

    return {
        bstats = bstats,
        istats = istats,
        cidx = cidx,
        idxname = idxname,
        iexp = iexp,
        bounds = bounds,
        baseexp = baseexp,
    }
end

codecfield = function(ctx, node)
    local basetype = types.resolve_c_typedef(node.exp._type)
    local cstats, cexp = codeexp(ctx, node.exp)
    local field = node._decl
    if basetype._tag == "Type.CPointer" then
        local cbase, basename = newtmp(ctx, node.exp._type)
        return render([[
            $CSTATS
            $CBASE
            $BASENAME = $CEXP;
            if (TITAN_UNLIKELY($BASENAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot access field '%s' of a NULL C pointer", $FILE, $LINE, $COL, $FIELDSTR);
            }
        ]], {
            CSTATS = cstats,
            CBASE = cbase,
            BASENAME = basename,
            CEXP = cexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            FIELDSTR = c_string_literal(field.name),
        }, true), render("$BASE->$FIELD", {
            BASE = basename,
            FIELD = field.name,
        })
    elseif basetype._tag == "Type.COwned" then
        return cstats, render("$BASE->$FIELD", {
            BASE = code_owned_payload(cexp, basetype.pointee),
            FIELD = field.name,
        })
    else
        return cstats, render("$BASE.$FIELD", {
            BASE = cexp,
            FIELD = field.name,
        })
    end
end

local function codevar(ctx, node)
    if node._tag == "Ast.VarDot" then
        if node._decl._tag == "Type.Field" then
            local cstats, cexp = codeexp(ctx, node.exp)
            return cstats,
                getslot(node._type, nil, render("&(($EXP)->uv[$INDEX].uv)", {
                    EXP = cexp,
                    INDEX = node._decl.index
                }))
        elseif node._decl._tag == "Type.CField" then
            return codecfield(ctx, node)
        elseif node._decl._tag == "Type.CPseudoSize" then
            local op = node._decl.name == "sizeof" and "sizeof" or "_Alignof"
            return "", render("((lua_Integer)$OP($CT))", {
                OP = op,
                CT = ctype(node._decl.ctype),
            })
        elseif node._decl._tag == "Type.ModuleMember"
               and node._type._tag == "Type.Function" then
            -- Reference to an imported module's function as a first-class value:
            -- index the canonical closure out of that module's `_mod` directly
            -- (the closure slot is reconstructed in import_module), so the
            -- reference is O(1) and identity-preserving.
            return "", getslot(node._type, nil, render(
                "&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$FNINDEX].uv)", {
                MODINDEX = c_integer_literal(node.exp.var._decl._upvalue),
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and ctx.tlcontext.static_slots[node._decl.fqtn .. "." .. node._decl.name] then
            -- Reference to a record function (e.g. `Rec.new`) as a value: read its
            -- canonical closure from the shadow slot allocated for it.
            return "", getslot(node._type, nil, render("&_mod->uv[$SLOT].uv", {
                SLOT = c_integer_literal(
                    ctx.tlcontext.static_slots[node._decl.fqtn .. "." .. node._decl.name]),
            }))
        else
            assert(node._decl._tag == "Type.ModuleVariable")
            ctx.variables[node.exp.var.name .. "." .. node.name] = {
                module = node.exp.var.name,
                name = node.name,
                slot = node._decl._slot
            }
            local slot = render("&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$VARINDEX].uv)", {
                MODINDEX = c_integer_literal(node.exp.var._decl._upvalue),
                VARINDEX = c_integer_literal(node._decl._upvalue)
            })
            return "", getslot(node._type, nil, slot)
        end
    elseif node._decl._tag == "Ast.TopLevelVar" then
        return "", getslot(node._type, nil, node._decl._slot)
    elseif node._decl._tag == "Ast.TopLevelFunc" then
        -- Reference to a top-level function as a first-class value: read its
        -- canonical closure from the shadow upvalue slot, boxed as a TValue.
        return "", getslot(node._type, nil, render("&_mod->uv[$SLOT].uv", {
            SLOT = c_integer_literal(node._decl._closure_upvalue)
        }))
    elseif ctx.captures and ctx.captures[node._decl] then
        -- Inside a lambda body: the variable is captured from an enclosing
        -- function and lives in this closure's upvalues (read via _fn). A boxed
        -- capture is read through its box; a by-value capture directly.
        local cap = ctx.captures[node._decl]
        if cap.boxed then
            return "", box_read(node._type, cap.boxvar)
        else
            return "", getslot(node._type, nil,
                "&_fn->upvalue[" .. c_integer_literal(cap.index) .. "]")
        end
    elseif node._decl._boxed then
        -- Captured-and-mutated local/param of the current function: read through
        -- its box cell.
        return "", box_read(node._type, node._decl._box)
    else
        return "", node._decl._cvar
    end
end

local function codevalue(ctx, node, target)
    local tag = node._tag
    if tag == "Ast.ExpNil" then
        return "", "0"
    elseif tag == "Ast.ExpBool" then
        return "", node.value and "1" or "0"
    elseif tag == "Ast.ExpInteger" then
        return "", c_integer_literal(node.value)
    elseif tag == "Ast.ExpFloat" then
        return "", c_float_literal(node.value)
    elseif tag == "Ast.ExpString" then
        return makestring(ctx, c_string_literal(node.value), target,
            tostring(#node.value))
    else
        error("invalid tag for a literal value: " .. tag)
    end
end

local function codearray(ctx, node, target)
    local stats = {}
    local cinit, ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        -- always build the array anchored in a stack slot; a target slot
        -- such as a module-global upvalue is not scanned by minor
        -- collections, so the fresh table could be swept while a callee
        -- in the fill loop triggers the GC (caller stores + barriers
        -- after we return)
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end
    cinit = render([[
        $CTMP
        $TMPNAME = luaH_new(L);
        sethvalue(L, $TMPSLOT, $TMPNAME);
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
    })
    table.insert(stats, cinit)
    -- A trailing `...` field (key-less `Ast.ExpDots`, §4.7) makes this a
    -- runtime-sized build: the static prefix fields precede it, then the current
    -- frame's whole `...` tail (`args[_start .. n_args-1]`) is appended (§5.6).
    local elemtype = node._type.elem
    local nfields = #node.fields
    local dots_tail = nfields > 0
        and node.fields[nfields].exp._tag == "Ast.ExpDots"
    local nprefix = dots_tail and nfields - 1 or nfields
    local slots = {}
    local discarded = {}
    local openrun
    if node._array_adjustment then
        for _, exp in ipairs(node._array_adjustment.discards) do
            discarded[exp] = true
        end
    end
    if node._array_adjustment and node._array_adjustment.open_source then
        local astats, _, tailnames, run = coder._codeadjustedopen(ctx,
            node._array_adjustment, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for _, name in ipairs(tailnames) do
            local slot = slotat(reserveslot(ctx))
            table.insert(stats, setwrapped(elemtype, slot, name))
            table.insert(slots, slot)
        end
        openrun = run
    else
        for i = 1, nprefix do
            local exp = node.fields[i].exp
            local cstats, cexp = codeexp(ctx, exp)
            if discarded[exp] then
                table.insert(stats, cstats)
                table.insert(stats, "(void)(" .. cexp .. ");")
            else
                local ctmpe, tmpename, tmpeslot = newtmp(ctx, elemtype, true)
                local code = render([[
                    $CSTATS
                    $CTMPE
                    $TMPENAME = $CEXP;
                    $SETSLOT
                ]], {
                    CSTATS = cstats,
                    CTMPE = ctmpe,
                    TMPENAME = tmpename,
                    CEXP = cexp,
                    SETSLOT = setwrapped(elemtype, tmpeslot, tmpename),
                })

                table.insert(slots, tmpeslot)
                table.insert(stats, code)
            end
        end
    end
    local nstored = #slots
    if openrun then
        -- Runtime-sized array build. The vararg elements are already anchored
        -- upstream (§2.D) and the GC is non-moving, so reading `args[]` across the
        -- resize is safe -- no pre-copy needed; this is the case-3 forward copy
        -- (§5.7) plus the table back barrier on each store. The prefix temps are
        -- on reserved stack slots, so they too survive the resize-GC.
        -- Drive the backing-struct typedef and the `args[]` stride/read off the
        -- REAL vararg element type (`va.elem`) -- the struct the callee actually
        -- allocated. The array's declared element type (`elemtype`) may differ
        -- (the checker §4.7 lets a context override it, e.g. `{...integer}` in a
        -- `{float}` context); casting the buffer to the array-element struct would
        -- bit-reinterpret a 8-byte `lua_Integer` slot as a 8-byte `lua_Number` or
        -- read 16-byte `TValue`s out of the smaller buffer. Convert each element
        -- from `va.elem` to `elemtype` before storing (the checker has proven it
        -- coerceable; identical types convert to a verbatim copy).
        -- `luaH_resizearray` -> `luaM_reallocvector` can GC, which may shrink and
        -- relocate the Lua stack (`luaD_shrinkstack`), dangling the raw `_base`
        -- pointer. Save it as an offset and recompute it after the resize so
        -- the prefix-slot reads and `obj2arr` stores below use
        -- the live stack. The preamble declares `_base_off` when uses_base_off.
        ctx.uses_base_off = true
        -- A reusable TValue scratch to wrap each vararg element before `obj2arr`
        -- (which takes a `TValue *`); for value/option/function the converted
        -- element already IS a TValue and `setwrapped` copies it verbatim.
        local vslot = "_vaslot_" .. ctx.tmp
        ctx.tmp = ctx.tmp + 1
        local barrier = types.is_gc(elemtype) and render([[
            luaC_barrierback(L, obj2gco($TMPNAME), &$VSLOT);
        ]], { TMPNAME = tmpname, VSLOT = vslot }) or ""
        -- The per-element store. When the vararg element type matches the array
        -- element type, wrap the raw `args[]` read straight into the TValue slot.
        -- Otherwise materialize the read into a `va.elem` temp, convert it to the
        -- array element type via the ordinary cast codegen (a synthetic ExpCast,
        -- as in the option t1?->t2? path), and wrap the result.
        local rawread = openrun.args .. "[" .. openrun.start .. " + _vj]"
        local element_store
        if types.equals(openrun.elem, elemtype) then
            element_store = setwrapped(elemtype, "&" .. vslot, rawread)
        else
            local csrc, srcname = newtmp(ctx, openrun.elem)
            local synthvar = { _tag = "Ast.VarName", _type = openrun.elem,
                               _decl = { _cvar = srcname } }
            local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                                exp = synthvar, target = elemtype, _type = elemtype }
            local convstats, convexp = codeexp(ctx, synthcast)
            element_store = render([[
                $CSRC
                $SRCNAME = $RAWREAD;
                $CONVSTATS
                $SETWRAPPED
            ]], {
                CSRC = csrc,
                SRCNAME = srcname,
                RAWREAD = rawread,
                CONVSTATS = convstats,
                SETWRAPPED = setwrapped(elemtype, "&" .. vslot, convexp),
            })
        end
        table.insert(stats, render([[
            {
                int _vacount = $RUNCOUNT;
                luaH_resizearray(L, $TMPNAME, (unsigned int)($NPREFIX + _vacount));
                _base = restorestack(L, _base_off);
                $PREFIX_STORES
                /* zero-init: a boolean store sets only the tag (booleans carry
                ** no payload), but obj2arr copies value_ too — leaving it
                ** undefined would warn under -Wmaybe-uninitialized / break
                ** -Werror. */
                TValue $VSLOT = {0};
                for (int _vj = 0; _vj < _vacount; _vj++) {
                    $SETWRAPPED
                    obj2arr($TMPNAME, $NPREFIX + _vj, &$VSLOT);
                    $BARRIER
                }
                $CLEANUP
            }
        ]], {
            RUNCOUNT = openrun.count,
            TMPNAME = tmpname,
            NPREFIX = c_integer_literal(nstored),
            VSLOT = vslot,
            SETWRAPPED = element_store,
            BARRIER = barrier,
            CLEANUP = coder._cleanup_result_run(openrun),
            PREFIX_STORES = (function()
                local ps = {}
                for i = 1, nstored do
                    local slot = slots[i]
                    table.insert(ps, render([[
                        obj2arr($TMPNAME, $INDEX, $SLOT);
                    ]], { TMPNAME = tmpname, INDEX = c_integer_literal(i - 1), SLOT = slot }))
                    if types.is_gc(elemtype) then
                        table.insert(ps, render([[
                            luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
                        ]], { TMPNAME = tmpname, SLOT = slot }))
                    end
                end
                return table.concat(ps, "\n")
            end)(),
        }))
        return table.concat(stats, "\n"), tmpname
    end
    if nstored > 0 then
        table.insert(stats, render([[
            luaH_resizearray(L, $TMPNAME, $SIZE);
        ]], {
            TMPNAME = tmpname,
            SIZE = nstored
        }))

    end
    for i, slot in ipairs(slots) do
        table.insert(stats, render([[
            obj2arr($TMPNAME, $INDEX, $SLOT);
        ]], {
            TMPNAME = tmpname,
            INDEX = i-1,
            SLOT = slot
        }))
        if types.is_gc(elemtype) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
            ]], {
                TMPNAME = tmpname,
                SLOT = slot,
            }))
        end
    end
    return table.concat(stats, "\n"), tmpname
end

local function codemap(ctx, node, target)
    local stats = {}
    local cinit, ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        -- always build the map anchored in a stack slot (see codearray)
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end
    cinit = render([[
        $CTMP
        $TMPNAME = luaH_new(L);
        sethvalue(L, $TMPSLOT, $TMPNAME);
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
    })
    table.insert(stats, cinit)
    local slots = {}
    for _, field in ipairs(node.fields) do
        local kexp = field.name
        local ckstats, ckexp = codeexp(ctx, kexp)
        local ctmpk, tmpkname, tmpkslot = newtmp(ctx, node._type.keys, true)

        local vexp = field.exp
        local cvstats, cvexp = codeexp(ctx, vexp)
        local ctmpv, tmpvname, tmpvslot = newtmp(ctx, node._type.values, true)

        local code = render([[
            $CKSTATS
            $CTMPK
            $TMPKNAME = $CKEXP;
            $SETSLOTK

            $CVSTATS
            $CTMPV
            $TMPVNAME = $CVEXP;
            $SETSLOTV
        ]], {
            CKSTATS = ckstats,
            CTMPK = ctmpk,
            TMPKNAME = tmpkname,
            CKEXP = ckexp,
            SETSLOTK = setwrapped(node._type.keys, tmpkslot, tmpkname),

            CVSTATS = cvstats,
            CTMPV = ctmpv,
            TMPVNAME = tmpvname,
            CVEXP = cvexp,
            SETSLOTV = setwrapped(node._type.values, tmpvslot, tmpvname),
        })

        table.insert(slots, { k = tmpkslot, v = tmpvslot })
        table.insert(stats, code)
    end
    for _, slot in ipairs(slots) do
        table.insert(stats, render([[
            {
                $STORE
            }
        ]], {
            STORE = set_table_entry(node._type.keys, tmpname, slot.k, slot.v),
        }))
        if types.is_gc(node._type.values) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOTV);
            ]], {
                TMPNAME = tmpname,
                SLOTV = slot.v,
            }))
        end
    end
    return table.concat(stats, "\n"), tmpname
end

local function coderecord(ctx, node, target)
    local stats = {}
    local cinit, ctmp, tmpname, tmpslot
    local record = types.registry[node._type.fqtn]
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end
    -- The record value IS the Udata: one allocation, fields in user values
    -- uv[0..N-1] (0-based), type identity is the udata's metatable (no raw
    -- payload), metatable straight on the udata. luaS_newudata returns the
    -- object already nil-filled and white, and we anchor it via setuvalue
    -- immediately, so the half-built record is reachable before any field is
    -- evaluated; each gc field store uses the back barrier to keep it honest.
    cinit = render([[
        $CTMP
        $TMPNAME = luaS_newudata(L, 0, $NUSERVALUES);
        $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
        setuvalue(L, $TMPSLOT, $TMPNAME);
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        NUSERVALUES = record.nfields or #record.fields,
        META = c_integer_literal(type2metatable(ctx, node._type))
    })
    table.insert(stats, cinit)
    for _, field in ipairs(node.fields) do
        local exp = field.exp
        local cstats, cexp = codeexp(ctx, exp)
        local ctmpe, tmpename, tmpeslot = newtmp(ctx, field._field.type, true)
        local code = render([[
            $CSTATS
            $CTMPE
            $TMPENAME = $CEXP;
            $SETSLOT;
            setobj2t(L, &($RECORD->uv[$INDEX].uv), $SLOT);
        ]], {
            CSTATS = cstats,
            CTMPE = ctmpe,
            TMPENAME = tmpename,
            CEXP = cexp,
            SETSLOT = setslot(field._field.type, tmpeslot, tmpename),
            SLOT = tmpeslot,
            RECORD = tmpname,
            INDEX = field._field.index
        })
        table.insert(stats, code)
        if types.is_gc(field._field.type) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
            ]], {
                TMPNAME = tmpname,
                SLOT = tmpeslot,
            }))
        end
    end
    return table.concat(stats, "\n"), tmpname
end

local function codeunaryop(ctx, node, iscondition)
    local op = node.op
    if op == "not" then
        local estats, ecode = codeexp(ctx, node.exp, iscondition)
        return estats, "!(" .. ecode .. ")"
    elseif op == "#" then
        local estats, ecode = codeexp(ctx, node.exp)
        local etype = types.resolve_c_typedef(node.exp._type)
        if node.exp._type._tag == "Type.Array" then
            return estats, "luaH_getn(L, " .. ecode .. ")"
        elseif etype._tag == "Type.CArray" then
            return estats, c_integer_literal(etype.len)
        elseif etype._tag == "Type.COwned" and etype.count then
            return estats, render("((lua_Integer)($OWNER->len / sizeof($CT)))", {
                OWNER = ecode,
                CT = foreignctype(etype.pointee),
            })
        else
            return estats, "tsslen(" .. ecode .. ")"
        end
    elseif op == "-" and node.exp._type._tag == "Type.Integer" then
        -- Integer negation wraps two's-complement like Lua (intop(-,0,x));
        -- raw (-x) is signed-overflow UB for math.mininteger.
        local estats, ecode = codeexp(ctx, node.exp)
        return estats, "intop(-, 0, " .. ecode .. ")"
    else
        local estats, ecode = codeexp(ctx, node.exp)
        return estats, "(" .. op .. ecode .. ")"
    end
end

-- In Lua and Titan, the shift amount in a bitshift can be any integer, but in
-- C shift amount must be a positive number less than the width of the integer
-- type being shifted. This means that we need some if statements to implement
-- the Lua shift semantics in C.
--
-- Most of the time, the shift amount should be a constant, which will allow the
-- C compiler to eliminate all of these branches as dead code and generate code that is
-- just as good as a raw C bitshift without the extra Lua semantics.
--
-- For the dynamic case, we gain a bit of performance (~20%) compared to the
-- algorithm in luaV_shiftl by reordering the branches to put the common case
-- (shift amount is a small positive integer) under only one level of branching
-- and with a TITAN_LIKELY annotation.
local ordered_binary_operands

local function generate_binop_shift(shift_pos, shift_neg, exp, ctx)
    local x_stats, x_code = codeexp(ctx, exp.lhs)
    local y_stats, y_code = codeexp(ctx, exp.rhs)
    local xdecl, x_var = newtmp(ctx, types.Integer())
    local ydecl, y_var = newtmp(ctx, types.Integer())
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${X_STATS}
        ${X_DECL}
        ${X} = ${X_CODE};
        ${Y_STATS}
        ${Y_DECL}
        ${Y} = ${Y_CODE};
        ${R_DECL}
        if (TITAN_LIKELY(l_castS2U(${Y}) < TITAN_LUAINTEGER_NBITS)) {
            ${R} = intop(${SHIFT_POS}, ${X}, ${Y});
        } else {
            if (l_castS2U(intop(-, 0, ${Y})) < TITAN_LUAINTEGER_NBITS) {
                ${R} = intop(${SHIFT_NEG}, ${X}, intop(-, 0, ${Y}));
            } else {
                ${R} = 0;
            }
        }
    ]], {
        SHIFT_POS = shift_pos,
        SHIFT_NEG = shift_neg,
        X = x_var,
        X_DECL = xdecl,
        X_CODE = x_code,
        X_STATS = x_stats,
        Y = y_var,
        Y_DECL = ydecl,
        Y_CODE = y_code,
        Y_STATS = y_stats,
        R = rname,
        R_DECL = rdecl,
    })
    return cstats, rname
end

-- Lua/Titan integer division rounds to negative infinity instead of towards
-- zero. We inline luaV_div here to give the C compiler more optimization
-- opportunities (see that function for comments on how it works).
local function generate_binop_idiv_int(exp, ctx)
    local m_stats, m_code = codeexp(ctx, exp.lhs)
    local n_stats, n_code = codeexp(ctx, exp.rhs)
    local mdecl, m_var = newtmp(ctx, types.Integer())
    local ndecl, n_var = newtmp(ctx, types.Integer())
    local qdecl, qname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${M_STATS}
        ${M_DECL}
        ${M} = ${M_CODE};
        ${N_STATS}
        ${N_DECL}
        ${N} = ${N_CODE};
        ${Q_DECL}
        if (l_castS2U(${N}) + 1u <= 1u) {
            if (${N} == 0){
                $THROW_DIV0
            } else {
                ${Q} = intop(-, 0, ${M});
            }
        } else {
            ${Q} = ${M} / ${N};
            if ((${M} ^ ${N}) < 0 && ${M} % ${N} != 0) {
                ${Q} -= 1;
            }
        }
    ]], {
        M = m_var,
        M_DECL = mdecl,
        M_CODE = m_code,
        M_STATS = m_stats,
        N = n_var,
        N_DECL = ndecl,
        N_CODE = n_code,
        N_STATS = n_stats,
        Q = qname,
        Q_DECL = qdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_DIV0 = codethrow(exp.loc, "error at line %d, divide by zero", { "$LINE" })
    })
    return cstats, qname
end

-- see luai_numidiv
local function generate_binop_idiv_flt(exp, ctx)
    local stats, x_var, y_var = ordered_binary_operands(ctx, exp)
    local rdecl, rname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${STATS}
        ${R_DECL}
        ${R_NAME} = floor(${X} / ${Y});
    ]], {
        X = x_var,
        Y = y_var,
        STATS = stats,
        R_DECL = rdecl,
        R_NAME = rname,
    })
    return cstats, rname
end

-- Lua/Titan guarantees that (m == n*(m//n) + (,%n))
-- See generate binop_intdiv and luaV_mod
local function generate_binop_mod_int(exp, ctx)
    local m_stats, m_code = codeexp(ctx, exp.lhs)
    local n_stats, n_code = codeexp(ctx, exp.rhs)
    local mdecl, m_var = newtmp(ctx, types.Integer())
    local ndecl, n_var = newtmp(ctx, types.Integer())
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${M_STATS}
        ${M_DECL}
        ${M} = ${M_CODE};
        ${N_STATS}
        ${N_DECL}
        ${N} = ${N_CODE};
        ${R_DECL};
        if (l_castS2U(${N}) + 1u <= 1u) {
            if (${N} == 0){
                $THROW_MOD0
            } else {
                ${R} = 0;
            }
        } else {
            ${R} = ${M} % ${N};
            if (${R} != 0 && (${M} ^ ${N}) < 0) {
                ${R} += ${N};
            }
        }
    ]], {
        M = m_var,
        M_DECL = mdecl,
        M_CODE = m_code,
        M_STATS = m_stats,
        N = n_var,
        N_DECL = ndecl,
        N_CODE = n_code,
        N_STATS = n_stats,
        R = rname,
        R_DECL = rdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_MOD0 = codethrow(exp.loc, "error at line %d, %% by zero", { "$LINE" })
    })
    return cstats, rname
end

-- Float modulo, faithful to Lua's luai_nummod (see lvm.c/llimits.h):
--   m = fmod(a, b); if ((m>0) ? b<0 : (m<0 && b!=0)) m += b;
-- This differs from C's fmod for operands of opposite sign, where Lua
-- (like floored division) returns a result with the sign of the divisor.
local function generate_binop_mod_flt(exp, ctx)
    local stats, m_var, n_var = ordered_binary_operands(ctx, exp)
    local bdecl, bname = newtmp(ctx, types.Float())
    local rdecl, rname = newtmp(ctx, types.Float())
    local cstats = util.render([[
        ${STATS}
        ${B_DECL};
        ${R_DECL};
        ${B} = ${N};
        ${R} = fmod(${M}, ${B});
        if (((${R}) > 0) ? ((${B}) < 0) : (((${R}) < 0) && ((${B}) > 0))) {
            ${R} += ${B};
        }
    ]], {
        M = m_var,
        N = n_var,
        STATS = stats,
        B = bname,
        B_DECL = bdecl,
        R = rname,
        R_DECL = rdecl,
    })
    return cstats, rname
end

-- Preserve Titan/Lua's left-to-right operand evaluation. If preparing the RHS
-- emits statements, freeze the LHS first; otherwise those statements could
-- mutate state that a deferred LHS expression still reads.
ordered_binary_operands = function(ctx, node)
    local lstats, lcode = codeexp(ctx, node.lhs)
    local rstats, rcode = codeexp(ctx, node.rhs)
    if rstats == "" then
        return lstats, lcode, rcode
    end
    local ldecl, lname, lslot =
        newtmp(ctx, node.lhs._type, types.is_gc(node.lhs._type))
    local anchor = lslot and setslot(node.lhs._type, lslot, lname) or ""
    return render([[
        $LSTATS
        $LDECL
        $LNAME = $LCODE;
        $ANCHOR
        $RSTATS
    ]], {
        LSTATS = lstats,
        LDECL = ldecl,
        LNAME = lname,
        LCODE = lcode,
        ANCHOR = anchor,
        RSTATS = rstats,
    }), lname, rcode
end

local function codebinaryop(ctx, node, _)
    local op = node.op
    if op == "~=" then op = "!=" end
    if op == "and" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local rdecl, rname = newtmp(ctx, types.Boolean())
            return render([[
                $LSTATS
                $RDECL
                if (!$LCODE) {
                    $RNAME = 0;
                } else {
                    $RSTATS
                    $RNAME = $RCODE;
                }
            ]], {
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                RDECL = rdecl,
                RNAME = rname,
            }), rname
        elseif types.is_truthy(node.lhs._type) then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. "\n((void)" .. lcode .. ");\n" .. rstats, rcode
        elseif types.is_falsy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        else
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            local code = render([[
                $LSTATS
                $CTMP
                if(!($COND)) {
                    setnilvalue(&$TMPNAME);
                } else {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                COND = toboolean(node.lhs._type, lcode),
                LSTATS = lstats,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
            })
            return code, tmpname
        end
    elseif op == "or" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local rdecl, rname = newtmp(ctx, types.Boolean())
            return render([[
                $LSTATS
                $RDECL
                if ($LCODE) {
                    $RNAME = 1;
                } else {
                    $RSTATS
                    $RNAME = $RCODE;
                }
            ]], {
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                RDECL = rdecl,
                RNAME = rname,
            }), rname
        elseif types.is_truthy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        elseif types.is_falsy(node.lhs._type) then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. "\n((void)" .. lcode .. ");\n" .. rstats, rcode
        elseif node.lhs._type._tag == "Type.Option" then
            assert(types.equals(node.lhs._type.base, node.rhs._type))
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            local code = render([[
                $LSTATS
                $CTMP
                if(!($COND)) {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                } else {
                    $GETL;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                COND = toboolean(node.lhs._type, lcode),
                LSTATS = lstats,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
                GETL = getslot(node._type, tmpname, "&" .. lcode),
            })
            return code, tmpname
        else
            assert(node._type._tag == "Type.Value")
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
            local tmpset = setslot(types.Value(), tmpslot, tmpname)
            local code = render([[
                $LSTATS
                $CTMP
                $TMPNAME = $LCODE;
                if(l_isfalse(&$TMPNAME)) {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
            })
            return code, tmpname
        end
    elseif op == "^" then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        local bdecl, bname = newtmp(ctx, types.Float())
        local edecl, ename = newtmp(ctx, types.Float())
        local cstats = render([[
            $STATS
            $BDECL
            $EDECL
            $B = $LCODE;
            $E = $RCODE;
        ]], { STATS=stats, BDECL=bdecl, EDECL=edecl,
              B=bname, E=ename, LCODE=lcode, RCODE=rcode })
        -- luai_numpow: exponent 2 is a*a, not pow(a,2) (differs by 1 ULP).
        return cstats, "((" .. ename .. " == 2) ? (" .. bname .. " * " .. bname
                       .. ") : pow(" .. bname .. ", " .. ename .. "))"
    elseif op == "~" then
        -- Lua's binary '~' is bitwise exclusive-or; C's binary xor is '^'
        -- (Titan's '^' is exponentiation). Wrap like Lua's intop(^,...).
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "intop(^, " .. lcode .. ", " .. rcode .. ")"
    elseif op == "<<" then
        return generate_binop_shift("<<", ">>", node, ctx)
    elseif op == ">>" then
        return generate_binop_shift(">>", "<<", node, ctx)
    elseif op == "%" then
        local ltyp = node.lhs._type._tag
        local rtyp = node.rhs._type._tag
        if ltyp == "Type.Integer" and rtyp == "Type.Integer" then
            return generate_binop_mod_int(node, ctx)
        elseif ltyp == "Type.Float" and rtyp == "Type.Float" then
            return generate_binop_mod_flt(node, ctx)
        else
            error("impossible: " .. ltyp .. " " .. rtyp)
        end
    elseif op == "//" then
        local ltyp = node.lhs._type._tag
        local rtyp = node.rhs._type._tag
        if ltyp == "Type.Integer" and rtyp == "Type.Integer" then
            return generate_binop_idiv_int(node, ctx)
        elseif ltyp == "Type.Float" and rtyp == "Type.Float" then
            return generate_binop_idiv_flt(node, ctx)
        else
            error("impossible: " .. ltyp .. " " .. rtyp)
        end
    elseif node.lhs._type._tag == "Type.String"
           and node.rhs._type._tag == "Type.String"
           and (op == "==" or op == "!=" or op == "<"
                or op == "<=" or op == ">" or op == ">=") then
        -- String comparison must be by content, not by TString* pointer:
        -- equality via luaS_eqstr, ordering via the VM's lexicographic
        -- comparators (which call l_strcmp). Pointer comparison is wrong for
        -- long (non-interned) strings and never lexicographic.
        local cstats, lcode, rcode = ordered_binary_operands(ctx, node)
        if op == "==" then
            return cstats, "luaS_eqstr(" .. lcode .. ", " .. rcode .. ")"
        elseif op == "!=" then
            return cstats, "(!luaS_eqstr(" .. lcode .. ", " .. rcode .. "))"
        else
            local ltmp, ltn = newtmp(ctx, types.Value())
            local rtmp, rtn = newtmp(ctx, types.Value())
            cstats = cstats .. render([[
                $LTMP
                setsvalue(L, &$LTN, $LCODE);
                $RTMP
                setsvalue(L, &$RTN, $RCODE);
            ]], { LTMP = ltmp, LTN = ltn, RTMP = rtmp, RTN = rtn,
                  LCODE = lcode, RCODE = rcode })
            local cmp
            if op == "<" then
                cmp = "luaV_lessthan(L, &" .. ltn .. ", &" .. rtn .. ")"
            elseif op == "<=" then
                cmp = "luaV_lessequal(L, &" .. ltn .. ", &" .. rtn .. ")"
            elseif op == ">" then
                cmp = "luaV_lessthan(L, &" .. rtn .. ", &" .. ltn .. ")"
            else
                cmp = "luaV_lessequal(L, &" .. rtn .. ", &" .. ltn .. ")"
            end
            return cstats, cmp
        end
    elseif (op == "==" or op == "!=") and
            ctype(node.lhs._type) == "TValue" and
            ctype(node.rhs._type) == "TValue" then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        if op == "!=" then
            return stats, "!luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        else
            return stats, "luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        end
    elseif (op == "<" or op == "<=" or op == ">" or op == ">="
            or op == "==" or op == "!=")
           and ((node.lhs._type._tag == "Type.Integer" and node.rhs._type._tag == "Type.Float")
             or (node.lhs._type._tag == "Type.Float"   and node.rhs._type._tag == "Type.Integer")) then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        local ldecl, lname = newtmp(ctx, node.lhs._type)
        local rdecl, rname = newtmp(ctx, node.rhs._type)
        local cstats = render([[
            $STATS
            $LDECL
            $LNAME = $LCODE;
            $RDECL
            $RNAME = $RCODE;
        ]], { STATS=stats, LDECL=ldecl, LNAME=lname, LCODE=lcode,
              RDECL=rdecl, RNAME=rname, RCODE=rcode })
        local lint = node.lhs._type._tag == "Type.Integer"
        local cmp
        if op == "==" or op == "!=" then
            cmp = lint and ("titan_eq_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_eq_intfloat(" .. rname .. ", " .. lname .. ")")
            if op == "!=" then cmp = "(!" .. cmp .. ")" end
        elseif op == "<" then
            cmp = lint and ("titan_lt_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_lt_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == "<=" then
            cmp = lint and ("titan_le_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_le_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == ">" then           -- a > b  ==  b < a
            cmp = lint and ("titan_lt_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_lt_intfloat(" .. rname .. ", " .. lname .. ")")
        else                            -- ">=":  a >= b  ==  b <= a
            cmp = lint and ("titan_le_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_le_intfloat(" .. rname .. ", " .. lname .. ")")
        end
        return cstats, cmp
    elseif (op == "+" or op == "-" or op == "*")
           and node.lhs._type._tag == "Type.Integer"
           and node.rhs._type._tag == "Type.Integer" then
        -- Integer + - * wrap two's-complement like Lua (intop), instead of raw
        -- signed C arithmetic which is overflow UB under -O2 (no -fwrapv).
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "intop(" .. op .. ", " .. lcode .. ", " .. rcode .. ")"
    else
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "(" .. lcode .. op .. rcode .. ")"
    end
end

local function codeindexarray(ctx, node)
    local castats, caexp = codeexp(ctx, node.exp1)
    local cistats, ciexp = codeexp(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = checkandget(ctx, typ, tmpname, "_s", node.loc)
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
    end
    local cfinish
    if typ._tag == "Type.Option" then
        cfinish = render([[
          if(ttisnil(_s)) {
            setnilvalue(&$TMPNAME);
          } else {
            $CCHECK
            $CSET
          }
        ]], {
            TMPNAME = tmpname,
            CCHECK = ccheck,
            CSET = cset,
        })
    else
        cfinish = render([[
            $CCHECK
            $CSET
        ]], {
            CCHECK = ccheck,
            CSET = cset,
        })
    end
    local stats = render([[
        $CTMP
        {
            $CASTATS
            $CISTATS
            Table *_t = $CAEXP;
            lua_Integer _k = $CIEXP;

            TValue _av;
            lu_byte _atag;
            luaH_fastgeti(_t, _k, &_av, _atag);
            if (tagisempty(_atag)) {
                setnilvalue(&_av);
            }
            const TValue *_s = &_av;

            $CFINISH
    }]], {
        CTMP = ctmp,
        CASTATS = castats,
        CISTATS = cistats,
        CAEXP = caexp,
        CIEXP = ciexp,
        CFINISH = cfinish
    })
    return stats, tmpname
end

local function codeindexmap(ctx, node)
    local cmstats, cmexp = codeexp(ctx, node.exp1)
    local ckstats, ckexp = codeexp(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = checkandget(ctx, typ, tmpname, "_s", node.loc)
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
    end
    local cfinish
    if typ._tag == "Type.Option" then
        cfinish = render([[
          if(ttisnil(_s)) {
            setnilvalue(&$TMPNAME);
          } else {
            $CCHECK
            $CSET
          }
        ]], {
            TMPNAME = tmpname,
            CCHECK = ccheck,
            CSET = cset,
        })
    else
        cfinish = render([[
            $CCHECK
            $CSET
        ]], {
            CCHECK = ccheck,
            CSET = cset,
        })
    end
    local ktyp = node.exp2._type
    local ctmpk, tmpkname, tmpkslot = newtmp(ctx, ktyp, true)
    local stats = render([[
        $CTMP
        {
            $CMSTATS
            $CKSTATS
            Table *_t = $CMEXP;
            $CTMPK
            $TMPKNAME = $CKEXP;
            $SETSLOTK
            const TValue* _s;
            $CTABLEKEY
            $CFINISH
    }]], {
        CTMP = ctmp,
        CMSTATS = cmstats,
        CKSTATS = ckstats,
        CMEXP = cmexp,
        CTMPK = ctmpk,
        TMPKNAME = tmpkname,
        CKEXP = ckexp,
        SETSLOTK = setwrapped(ktyp, tmpkslot, tmpkname),
        CTABLEKEY = get_table_key(ktyp, "_t", tmpkslot, "_s"),
        CFINISH = cfinish
    })
    return stats, tmpname
end

local function codeindexc(ctx, node)
    local elem = node._type
    local parts = codecindex_parts(ctx, node)
    local ctmp, tmpname, tmpslot = newtmp(ctx, elem, types.is_gc(elem))
    local cset = types.is_gc(elem) and setslot(elem, tmpslot, tmpname) or ""

    return render([[
        $CTMP
        {
            $BSTATS
            $ISTATS
            $CIDX
            $IDX = $IEXP;
            $BOUNDS
            $TMPNAME = $BASE[$IDX];
            $CSET
        }
    ]], {
        CTMP = ctmp,
        BSTATS = parts.bstats,
        ISTATS = parts.istats,
        CIDX = parts.cidx,
        IDX = parts.idxname,
        IEXP = parts.iexp,
        BOUNDS = parts.bounds,
        TMPNAME = tmpname,
        BASE = parts.baseexp,
        CSET = cset,
    }), tmpname
end

local function codecpseudonew(ctx, node)
    assert(not node._named_arg_order)
    local decl = node.exp.var._decl
    local ctyp = decl.ctype
    local ret = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, ret, true)
    local countstats, countdecl, countassign, countname

    if decl.array then
        local arg = node.args.args[1]
        countstats, countname = codeexp(ctx, arg)
        countdecl = ""
        countassign = render([[
            $COUNTSTATS
            lua_Integer _count = $COUNTEXP;
            if (TITAN_UNLIKELY(_count < 0)) {
                luaL_error(L, "%s:%d:%d: C array allocation count cannot be negative", $FILE, $LINE, $COL);
            }
        ]], {
            COUNTSTATS = countstats,
            COUNTEXP = countname,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    else
        countdecl = "lua_Integer _count = 1;"
        countassign = ""
    end

    return render([[
        $CTMP
        {
            $COUNTDECL
            $COUNTASSIGN
            size_t _elem_size = sizeof($CT);
            if (TITAN_UNLIKELY((size_t)_count > ((size_t)-1) / _elem_size)) {
                luaL_error(L, "%s:%d:%d: C allocation size overflow", $FILE, $LINE, $COL);
            }
            size_t _nbytes = (size_t)_count * _elem_size;
            $TMPNAME = luaS_newudata(L, _nbytes, 0);
            $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
            setuvalue(L, $TMPSLOT, $TMPNAME);
            memset(getudatamem($TMPNAME), 0, _nbytes);
        }
    ]], {
        CTMP = ctmp,
        COUNTDECL = countdecl,
        COUNTASSIGN = countassign,
        CT = foreignctype(ctyp),
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        META = c_integer_literal(owned_c_metatable(ctx, ret)),
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
    }), tmpname
end

-- `...[i]` (Ast.ExpDotsIndex). The current frame's vararg view is
-- `args[_start .. n_args-1]`, 1-based for the user, so `...[i]` reads
-- `args[_start + i - 1]` after a `1 <= i <= n_args - _start` bounds check.
-- Two modes set by the checker:
--   _nilfill == false (user `...[i]`, non-optional adjust-up): out-of-range
--     RAISES a Titan runtime error; result is the unboxed element value, type t.
--   _nilfill == true (optional adjust-up): out-of-range yields nil; result is a
--     t? option TValue (mirrors the codeindexarray option branch).
function codedotsindex(ctx, node)
    local va = assert(ctx.varargs, "...[i] outside a variadic function")
    local elem = va.elem
    local cistats, ciexp = codeexp(ctx, node.exp)
    -- Materialize the index into a temp first: the bounds check and the element
    -- read both reference it, and the operand may have side effects.
    local cidx, idxname = newtmp(ctx, types.Integer())
    -- length expression: n_args - _start
    local lenexp = render("((lua_Integer)$NAME->n_args - $START)",
        { NAME = va.cname, START = va.start })
    local elemexp = render("$NAME->args[$START + $IDX - 1]",
        { NAME = va.cname, START = va.start, IDX = idxname })
    if not node._nilfill then
        -- non-optional: bounds check raises; result is the unboxed element.
        local ctmp, tmpname, tmpslot = newtmp(ctx, elem, types.is_gc(elem))
        local cset = types.is_gc(elem) and setslot(elem, tmpslot, tmpname) or ""
        local throw = render([[
            luaL_error(L, "%s:%d:%d: variadic index %I out of range [1, %d]", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
        ]], {
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            IDX = idxname,
            LEN = lenexp,
        }, true)
        return render([[
            $CTMP
            {
                $CISTATS
                $CIDX
                $IDX = $CIEXP;
                if (TITAN_UNLIKELY($IDX < 1 || $IDX > $LEN)) {
                    $THROW
                }
                $TMPNAME = $ELEMEXP;
                $CSET
            }
        ]], {
            CTMP = ctmp,
            CISTATS = cistats,
            CIDX = cidx,
            IDX = idxname,
            CIEXP = ciexp,
            LEN = lenexp,
            THROW = throw,
            TMPNAME = tmpname,
            ELEMEXP = elemexp,
            CSET = cset,
        }), tmpname
    else
        -- optional: out-of-range -> nil; in-range -> wrap the element into a t?
        -- TValue. node._type is the option type; elem is its base.
        local opttype = node._type
        local ctmp, tmpname = newtmp(ctx, opttype)
        return render([[
            $CTMP
            {
                $CISTATS
                $CIDX
                $IDX = $CIEXP;
                if ($IDX < 1 || $IDX > $LEN) {
                    setnilvalue(&$TMPNAME);
                } else {
                    $SETSLOT
                }
            }
        ]], {
            CTMP = ctmp,
            CISTATS = cistats,
            CIDX = cidx,
            IDX = idxname,
            CIEXP = ciexp,
            LEN = lenexp,
            TMPNAME = tmpname,
            SETSLOT = setslot(elem, "&" .. tmpname, elemexp),
        }), tmpname
    end
end

-- Generate code for expression 'node'
-- 'iscondition' is 'true' if expression is used not for value but for
--    controlling conditinal execution
-- 'target' is not nil if expression is rvalue for a 'Ast.VarName' lvalue,
--    in this case it will be the '_decl' of the lvalue
local function codeexp_dispatch(ctx, node, iscondition, target)
    local tag = node._tag
    if tag == "Ast.VarDot" and node.exp._type._tag == "Type.CModule" then
        local fstats, fexp = codeforeignvar(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.VarName" or (tag == "Ast.VarDot" and node._decl) then
        return codevar(ctx, node)
    elseif tag == "Ast.VarBracket" then
        if node.exp1._type._tag == "Type.Array" then
            return codeindexarray(ctx, node)
        elseif node.exp1._type._tag == "Type.Map" then
            return codeindexmap(ctx, node)
        elseif types.is_c(node.exp1._type) then
            return codeindexc(ctx, node)
        end
        error("impossible var bracket")
    elseif tag == "Ast.ExpNil" or
                tag == "Ast.ExpBool" or
                tag == "Ast.ExpInteger" or
                tag == "Ast.ExpFloat" or
                tag == "Ast.ExpString" then
        return codevalue(ctx, node, target)
    elseif tag == "Ast.ExpInitList" then
        if node._type._tag == "Type.Nominal" then
            return coderecord(ctx, node, target)
        elseif node._type._tag == "Type.Map" then
            return codemap(ctx, node, target)
        else
            return codearray(ctx, node, target)
        end
        error("impossible init list")
    elseif tag == "Ast.ExpVar" then
        if node._foreign_function_pointer then
            return "", foreigncast(node._foreign_function_pointer, node._type)
        end
        return codeexp(ctx, node.var, iscondition)
    elseif tag == "Ast.ExpUnop" then
        return codeunaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpBinop" then
        return codebinaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._decl
           and node.exp.var._decl._tag == "Type.CPseudoNew" then
        return codecpseudonew(ctx, node)
    elseif tag == "Ast.ExpCall" and node._c_pointer_call then
        local fstats, fexp = codecfunctionptrcall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._tag == "Ast.VarDot"
           and node.exp.var.exp._type._tag == "Type.CModule" then
        local fstats, fexp = codeforeigncall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" then
        return codecall(ctx, node, target)
    elseif tag == "Ast.ExpExtra" then
        return "", node.exp._extras[node.index]
    elseif tag == "Ast.ExpCast" and types.equals(node.exp._type, node._type) then
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast"
           and (node.exp._type._tag == "Type.Typedef"
                or node._type._tag == "Type.Typedef") then
        -- A scalar foreign typedef (e.g. size_t) IS its underlying scalar in C,
        -- so `<typedef> as T` (or a cast TO a typedef) behaves exactly like the
        -- cast of/to the underlying type. Resolve the typedef(s) and re-dispatch
        -- through the ordinary cast arms via a synthetic cast node, mirroring
        -- `ctype` (which recurses through `Type.Typedef._type`). We never mutate
        -- the shared AST/type tables in place; the synthetic node carries its own
        -- resolved types and reuses the original operand and location.
        local function resolve(t)
            -- Unwrap ALL typedef levels: typedefs can chain (e.g. macOS's
            -- `size_t` -> `__darwin_size_t` -> `unsigned long`, glibc's
            -- `clock_t` -> `__clock_t` -> long). A one-level unwrap leaves a
            -- Typedef on the synthesized cast, which re-enters this arm forever.
            while t and t._tag == "Type.Typedef" do t = t._type end
            return t
        end
        local stype = resolve(node.exp._type)
        local ttype = resolve(node._type)
        if types.equals(stype, ttype) then
            -- typedef-vs-underlying identity (e.g. size_t as integer): no-op
            return codeexp(ctx, node.exp, iscondition, target)
        end
        local synthexp
        if node.exp._type._tag == "Type.Typedef" then
            -- Re-tag the operand with its underlying type by wrapping it in a
            -- pass-through cast node so the existing arms see a native source.
            synthexp = { _tag = "Ast.ExpCast", loc = node.exp.loc,
                         exp = node.exp, target = stype, _type = stype,
                         _typedef_resolved = true }
        else
            synthexp = node.exp
        end
        local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                            exp = synthexp, target = ttype, _type = ttype }
        return codeexp(ctx, synthcast, iscondition, target)
    elseif tag == "Ast.ExpCast" and node._typedef_resolved then
        -- Pass-through wrapper produced above: the operand's static type is a
        -- typedef but its C representation already is the underlying scalar, so
        -- just emit the operand unchanged under its resolved type.
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast" and types.is_c(node._type) then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp = nativetoforeignexp(ctx, node.exp, cexp, node._type)
        if types.is_c_tvalue(node._type) then
            return cstats .. fstats, fexp
        end
        return cstats .. fstats, foreigncast(fexp, node._type)
    elseif tag == "Ast.ExpCast" and types.is_c(node.exp._type)
           and node._type._tag == "Type.Integer" then
        local cstats, cexp = codeexp(ctx, node.exp)
        return cstats, "((lua_Integer)" .. cexp .. ")"
    elseif tag == "Ast.ExpCast" and types.is_c(node.exp._type)
           and node._type._tag == "Type.Float" then
        local cstats, cexp = codeexp(ctx, node.exp)
        return cstats, "((lua_Number)" .. cexp .. ")"
    elseif tag == "Ast.ExpCast" and types.is_c(node.exp._type)
           and node._type._tag == "Type.Boolean" then
        local cstats, cexp = codeexp(ctx, node.exp)
        return cstats, toboolean(types.resolve_c_typedef(node.exp._type), cexp)
    elseif tag == "Ast.ExpCast" and types.is_c(node.exp._type)
           and node._type._tag == "Type.String" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local ctmp, tmpname = newforeigntmp(ctx, node.exp._type)
        local guard = render([[
            $CSTATS
            $CTMP
            $TMPNAME = $CEXP;
            if ($TMPNAME == NULL) {
                luaL_error(L, "foreign pointer cast to string was NULL");
            }
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            TMPNAME = tmpname,
            CEXP = cexp,
        })
        local mkstats, mkexp = makestring(ctx, tmpname, target)
        return guard .. "\n" .. mkstats, mkexp
    elseif tag == "Ast.ExpCast" and node.exp._tag == "Ast.ExpVar" and node.exp.var._tag == "Ast.VarBracket"
           and node.exp._type._tag ~= "Type.Option" then
        -- Fold casts of array/map indexing into the code for the operation
        local t = node.exp.var._type
        node.exp.var._type = node._type
        local cstats, cexp = codeexp(ctx, node.exp.var)
        node.exp.var._type = t
        return cstats, cexp
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Value" then
        -- cast from value to any type
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local ctmps, tmpnames = newtmp(ctx, node.exp._type)
        local ctmpt, tmpnamet = newtmp(ctx, node.target)
        local cget = checkandget(ctx, node._type, tmpnamet, "&" .. tmpnames, node.loc)
        return render([[
            $EXPSTATS
            $TMPSOURCE
            $SOURCE = $EXP;
            $TMPTARGET
            $CHECKANDGET
        ]], {
            EXPSTATS = cstats,
            TMPSOURCE = ctmps,
            SOURCE = tmpnames,
            TMPTARGET = ctmpt,
            EXP = cexp,
            CHECKANDGET = cget
        }), tmpnamet
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Value" then
        -- cast to value from any type
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local ctmp, tmpname = newtmp(ctx, node.target)
        return render([[
            $EXPSTATS
            $TMPTARGET
            $SETSLOT
        ]], {
            EXPSTATS = cstats,
            TMPTARGET = ctmp,
            SETSLOT = setwrapped(node.exp._type, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Integer" and node._type._tag == "Type.Float" then
        -- cast from integer to float
        local cstat, cexp = codeexp(ctx, node.exp)
        return cstat, "((lua_Number)" .. cexp .. ")"
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Boolean" then
        -- cast to boolean from any type (including options, via truthiness)
        local cstat, cexp = codeexp(ctx, node.exp, true)
        return cstat, toboolean(node.exp._type, cexp)
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Float" and node.target._tag == "Type.Integer" then
        -- cast from float to integer
        local cstat, cexp = codeexp(ctx, node.exp)
        local ctmp1, tmpname1 = newtmp(ctx, types.Float())
        local ctmp2, tmpname2 = newtmp(ctx, types.Float())
        local ctmp3, tmpname3 = newtmp(ctx, types.Integer())
        local cfloor = render([[
            $CSTAT
            $CTMP1
            $CTMP2
            $CTMP3
            $TMPNAME1 = $CEXP;
            $TMPNAME2 = l_floor($TMPNAME1);
            if ($TMPNAME1 != $TMPNAME2) {
                $THROW_WRONG_INT
            } else if (!lua_numbertointeger($TMPNAME2, &$TMPNAME3)) {
                $THROW_WRONG_INT
            }
        ]], {
            CSTAT = cstat,
            CEXP = cexp,
            CTMP1 = ctmp1,
            CTMP2 = ctmp2,
            CTMP3 = ctmp3,
            TMPNAME1 = tmpname1,
            TMPNAME2 = tmpname2,
            TMPNAME3 = tmpname3,
            LINE = c_integer_literal(node.loc.line),
            THROW_WRONG_INT = codethrow(node.loc, "type error at line %d, number '%f' has no integer representation", { "$LINE", "$TMPNAME1" })
        })
        return cfloor, tmpname3
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.String"
           and node.exp._type._tag ~= "Type.Option" then
        local cvt
        local cstats, cexp = codeexp(ctx, node.exp)
        if node.exp._type._tag == "Type.Integer" then
            cvt = render("_integer2str(L, $EXP)", { EXP = cexp })
        elseif node.exp._type._tag == "Type.Float" then
            cvt = render("_float2str(L, $EXP)", { EXP = cexp })
        else
            error("invalid node type for coercion to string: " .. types.tostring(node.exp._type))
        end
        if target then
            return cstats, cvt
        else
            local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
            local code = render([[
                $CSTATS
                $CTMP
                $TMPNAME = $CVT;
                setsvalue(L, $TMPSLOT, $TMPNAME);
            ]], {
                CSTATS = cstats,
                CTMP = ctmp,
                TMPNAME = tmpname,
                CVT = cvt,
                TMPSLOT = tmpslot,
            })
            return code, tmpname
        end
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option" and node.exp._type._tag == "Type.Nil" then
        -- Nil-producing expressions are not necessarily literals. Preserve an
        -- effectful call before materializing the option nil (argument/result
        -- adjustment commonly inserts this cast around such a producer).
        local cstats, cexp = codeexp(ctx, node.exp)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            (void)($CEXP);
            $CTMP
            setnilvalue(&$TMPNAME);
        ]], {
            CSTATS = cstats,
            CEXP = cexp,
            CTMP = ctmp,
            TMPNAME = tmpname
        }), tmpname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option"
           and node.exp._type._tag == "Type.Option" then
        -- t1? -> t2? (coerceable bases): propagate nil; for a present value,
        -- unwrap the base, convert it base-to-base, and re-wrap. The base
        -- conversion reuses the ordinary cast codegen via a synthetic cast of
        -- the extracted value (so e.g. float->integer keeps its range check).
        local sbase = node.exp._type.base
        local tbase = node._type.base
        local cstats, cexp = codeexp(ctx, node.exp)
        local csrc, srcname = newtmp(ctx, node.exp._type)
        local cbase, basename = newtmp(ctx, sbase)
        local cdst, dstname = newtmp(ctx, node._type)
        local synthvar = { _tag = "Ast.VarName", _type = sbase,
                           _decl = { _cvar = basename } }
        local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                            exp = synthvar, target = tbase, _type = tbase }
        local convstats, convexp = codeexp(ctx, synthcast)
        return render([[
            $CSTATS
            $CSRC
            $SRCNAME = $CEXP;
            $CDST
            if (TITAN_UNLIKELY(ttisnil(&$SRCNAME))) {
                setnilvalue(&$DSTNAME);
            } else {
                $CBASE
                $GETBASE;
                $CONVSTATS
                $SETDST
            }
        ]], {
            CSTATS = cstats,
            CSRC = csrc,
            SRCNAME = srcname,
            CEXP = cexp,
            CBASE = cbase,
            GETBASE = getslot(sbase, basename, "&" .. srcname),
            CONVSTATS = convstats,
            CDST = cdst,
            DSTNAME = dstname,
            SETDST = setslot(tbase, "&" .. dstname, convexp),
        }), dstname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option" then
        -- cast from t to t?
        assert(types.equals(node._type.base, node.exp._type))
        local cstats, cexp = codeexp(ctx, node.exp)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CTMP
            $SETSLOT
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            SETSLOT = setslot(node._type.base, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Option" then
        -- cast from t? to t
        assert(types.equals(node.exp._type.base, node._type))
        local cstats, cexp = codeexp(ctx, node.exp)
        -- Materialize the option value into a TValue temp first: the operand
        -- may be a non-lvalue (e.g. a direct call returning t?), so we cannot
        -- take its address directly.
        local csrc, srcname = newtmp(ctx, node.exp._type)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CSRC
            $SRCNAME = $CEXP;
            $CTMP
            if(TITAN_UNLIKELY(ttisnil(&$SRCNAME))) {
                $THROW_WRONG_CAST
            } else {
                $GETSLOT;
            }
        ]], {
            CSTATS = cstats,
            CSRC = csrc,
            SRCNAME = srcname,
            CEXP = cexp,
            CTMP = ctmp,
            FILE = c_string_literal(node.loc.filename),
            LINE = node.loc.line,
            COL = node.loc.col,
            TYPENAME = c_string_literal(types.tostring(node._type)),
            GETSLOT = getslot(node._type, tmpname, "&" .. srcname),
            THROW_WRONG_CAST = codethrow(node.loc, "%s:%d:%d: type error, expected %s but found nil", { "$FILE", "$LINE", "$COL", "$TYPENAME" })
        }), tmpname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Pointer" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp = nativetoforeignexp(ctx, node.exp, cexp)
        return cstats .. fstats, foreigncast(fexp, node._type)
    elseif tag == "Ast.ExpConcat" then
        local strs, copies = {}, {}
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
        for i, exp in ipairs(node.exps) do
            local cstat, cexp = codeexp(ctx, exp)
            local strvar = string.format('_str%d', i)
            local lenvar = string.format('_len%d', i)
            table.insert(strs, render([[
                $CSTAT
                TString *$STRVAR = $CEXP;
                size_t $LENVAR = tsslen($STRVAR);
                _len += $LENVAR;
            ]], {
                CSTAT = cstat,
                CEXP = cexp,
                STRVAR = strvar,
                LENVAR = lenvar,
            }))
            table.insert(copies, render([[
                memcpy(_buff + _tl, getstr($STRVAR), $LENVAR * sizeof(char));
                _tl += $LENVAR;
            ]], {
                STRVAR = strvar,
                LENVAR = lenvar,
            }))
        end
        local code = render([[
          $CTMP
          {
              size_t _len = 0;
              size_t _tl = 0;
              $STRS
              if(_len <= LUAI_MAXSHORTLEN) {
                  char _buff[LUAI_MAXSHORTLEN];
                  $COPIES
                  $TMPNAME = luaS_newlstr(L, _buff, _len);
              } else {
                  $TMPNAME = luaS_createlngstrobj(L, _len);
                  char *_buff = getstr($TMPNAME);
                  $COPIES
              }
          }
          setsvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            CTMP = ctmp,
            STRS = table.concat(strs, "\n"),
            COPIES = table.concat(copies, "\n"),
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
        })
        return code, tmpname
    elseif tag == "Ast.ExpAdjust" then
        if node._adjustvoid then
            -- `(f())` on a zero-return call: execute the void call for effect,
            -- then yield a single nil value (encoded as int 0, like Type.Nil)
            local cstats, cexp = codeexp(ctx, node.exp, iscondition)
            return cstats .. "\n    " .. cexp .. ";", "0"
        end
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpDotsLen" then
        -- `#...` -> logical length of the current frame's vararg view, which is
        -- the total backing count minus the start offset.
        local va = assert(ctx.varargs, "#... outside a variadic function")
        return "", render("((lua_Integer)$NAME->n_args - $START)",
            { NAME = va.cname, START = va.start })
    elseif tag == "Ast.ExpDotsIndex" then
        return codedotsindex(ctx, node)
    elseif tag == "Ast.ExpFunction" then
        return codelambda(ctx, node)
    elseif tag == "Ast.ExpMethodRef" then
        return codemethodref(ctx, node)
    else
        error("invalid node tag " .. tag)
    end
end

-- codeexp's `stats` half is frequently spliced *mid-line* into a larger
-- template (e.g. an expression-position slot), so a blanket `#line` prepend
-- here would land a `#` off column 1 and break compilation. Instead, error
-- attribution within an expression's expanded C is pinned where it matters —
-- directly above each luaL_error in codethrow — so we keep codeexp a plain
-- dispatch passthrough (the function-entry/statement/throw stamps cover the
-- rest).
function codeexp(ctx, node, iscondition, target)
    return codeexp_dispatch(ctx, node, iscondition, target)
end

function codeforeignexp(ctx, node, target)
    local tag = node._tag
    if tag == "Ast.ExpCall" and node._c_pointer_call then
        return codecfunctionptrcall(ctx, node)
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._tag == "Ast.VarDot"
           and node.exp.var.exp._type._tag == "Type.CModule" then
        return codeforeigncall(ctx, node)
    elseif tag == "Ast.VarDot" and node.exp._type._tag == "Type.CModule" then
        return codeforeignvar(ctx, node)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpCast" and node.target._tag == "Type.String" then
        local cstats, cexp = codeforeignexp(ctx, node.exp)
        return cstats, foreigncast(cexp, node._type)
    elseif tag == "Ast.ExpCast" and types.is_c(node._type) then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp = nativetoforeignexp(ctx, node.exp, cexp, node._type)
        if types.is_c_tvalue(node._type) then
            return cstats .. fstats, fexp
        end
        return cstats .. fstats, foreigncast(fexp, node._type)
    else
        local cstat, cexp = codeexp(ctx, node)
        local fstat, fexp = nativetoforeignexp(ctx, node, cexp, target)
        return cstat .. fstat, fexp
    end
end

-- Generate Lua entry point `lua_name` for a Titan
-- function or method with name `titan_name` and Titan
-- entry point `titan_entry`, type `typ`, and declared on location `loc`
local function genluaentry(tlcontext, titan_name, titan_entry, typ, loc, lua_name)
    -- generate Lua entry point
    local stats = {}
    local pnames = { "L", "_mod", "_fn" }
    local params
    if typ._tag == "Type.Function" or typ._tag == "Type.StaticMethod" then
        params = typ.params
    else
        assert(typ._tag == "Type.Method")
        params = { types.Nominal(typ.fqtn), table.unpack(typ.params) }
    end
    for i, param in ipairs(params) do
        local pname = "_param_" .. tostring(i)
        local slot = "s2v(func + " .. i .. ")"
        table.insert(pnames, pname)
        table.insert(stats, ctype(param) .. " " .. pname .. " = " .. initval(param) .. ";")
        table.insert(stats, checkandget(tlcontext, param, pname, slot, loc))
    end
    -- Variadic: build the backing struct from the surplus Lua-stack args. Pinned
    -- after the fixed params and before the out-params in the native call. The
    -- struct is a GC-anchored Udata0 (not a C-stack VLA): it must survive the
    -- error-handler frame and any GC the per-element coercion triggers. Surplus
    -- arg slots `func + nfixed + j` stay on the Lua stack below L->top.p for the
    -- whole native call, so they remain the anchors for any collectable element
    -- (§2.D); this struct's payload (getudatamem) is untraced.
    local varargtype = typ.varargtype
    if varargtype then
        local nfixed = #params
        local elem_ct = ctype(varargtype)
        local struct = varg_struct_name(varargtype)
        -- Allocate 0-uservalue Udata for the runtime-sized element storage,
        -- anchor it on the Lua stack so the GC keeps that storage alive across
        -- the native call, then make a small C-stack descriptor point at the
        -- payload. Each surplus arg is read through the same checkandget coercion
        -- the fixed params use, into `_varargs->args[j]`. `_start` is 0 (the
        -- generic entry always builds a fresh, fully-backed run). The entry guard
        -- below has already ensured the arg count is >= nfixed.
        local readone = checkandget(tlcontext, varargtype,
            "_varargs->args[_vj]", "s2v(_vfunc + " .. nfixed .. " + 1 + _vj)", loc)
        table.insert(stats, render([[
            ptrdiff_t _vcount = _nargs - $NFIXED;
            if (TITAN_UNLIKELY(_vcount > TITAN_VARARG_MAX)) {
                luaL_error(L, "too many variadic arguments to Titan function %s (%d, max %d)", $NAME, (int)_vcount, (int)TITAN_VARARG_MAX);
            }
            lu_byte _nvarargs = (lu_byte)_vcount;
            lua_checkstack(L, 1);
            Udata *_varargs_ud = gco2u(luaC_newobj(L, LUA_VUSERDATA,
                sizeudata(0, (size_t)_nvarargs * sizeof($ELEM_CT))));
            _varargs_ud->len = (size_t)_nvarargs * sizeof($ELEM_CT);
            _varargs_ud->nuvalue = 0; _varargs_ud->metatable = NULL;
            setuvalue(L, s2v(L->top.p), _varargs_ud);
            L->top.p++;
            /* recompute the arg base AFTER the lua_checkstack/push that may have
               relocated the Lua stack, so the surplus-arg slot reads are valid */
            StkId _vfunc = L->ci->func.p;
            $ELEM_CT *_varargs_args = ($ELEM_CT *)getudatamem(_varargs_ud);
            $STRUCT _varargs_desc = { _nvarargs, _varargs_args };
            $STRUCT *_varargs = &_varargs_desc;
            for (int _vj = 0; _vj < (int)_nvarargs; _vj++) {
                $READONE
            }
            int _start = 0;
        ]], {
            NFIXED = c_integer_literal(nfixed),
            NAME = c_string_literal(titan_name),
            STRUCT = struct,
            ELEM_CT = elem_ct,
            READONE = readone,
        }))
        table.insert(pnames, "_varargs")
        table.insert(pnames, "_start")
    end
    for i = 2, #typ.rettypes do
        local ptype = typ.rettypes[i]
        local pname = "_outparam_" .. i
        table.insert(pnames, "&" .. pname)
        table.insert(stats, ctype(ptype) .. " " .. pname .. " = " .. initval(ptype) .. ";")
    end
    local flexrettype = typ.flexrettype
    if flexrettype then
        table.insert(stats, render([[
            int _requested_results = get_nresults(L->ci->callstatus);
            int _flexwant = (_requested_results == LUA_MULTRET)
                ? LUA_MULTRET : _requested_results - $NFIXED;
            if (_flexwant != LUA_MULTRET && _flexwant < 0) _flexwant = 0;
            if (TITAN_UNLIKELY(_flexwant > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many flexible results requested from Titan function %s (%d, max %d)",
                    $NAME, _flexwant, (int)TITAN_VARARG_MAX);
            }
            int _flexcap = (_flexwant == LUA_MULTRET)
                ? TITAN_VARARG_MAX : _flexwant;
            $ELEM _flexargs[(_flexcap > 0) ? _flexcap : 1];
            $STRUCT _flexdesc = { 0, _flexargs };
        ]], {
            NFIXED = c_integer_literal(#typ.rettypes),
            NAME = c_string_literal(titan_name),
            ELEM = ctype(flexrettype),
            STRUCT = varg_struct_name(flexrettype),
        }))
        table.insert(pnames, "&_flexdesc")
        table.insert(pnames, "_flexwant")
    end
    local rettype = typ.rettypes[1]
    if #params > 0 then
        table.insert(stats, [[
            lua_pushvalue(L, 1); /* make space for error slot */
            lua_pushnil(L);
            lua_replace(L, 1); /* replace first stack element with nil, this is our error slot */
        ]])
    end
    if flexrettype then
        local call
        if rettype then
            call = render("$TYPE res = $NAME($PARAMS);", {
                TYPE = ctype(rettype),
                NAME = titan_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        else
            call = render("$NAME($PARAMS);", {
                NAME = titan_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        end
        local fixedsets = {}
        if rettype then
            table.insert(fixedsets,
                setwrapped(rettype, "s2v(_firstret)", "res") .. ";")
        end
        for i = 2, #typ.rettypes do
            table.insert(fixedsets, render([[
                $SETSLOT;
            ]], {
                SETSLOT = setwrapped(typ.rettypes[i],
                    "s2v(_firstret + " .. c_integer_literal(i - 1) .. ")",
                    "_outparam_" .. i),
            }))
        end
        table.insert(stats, render([[
            lua_checkstack(L, $NFIXED + _flexcap);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            for (int _ri = 0; _ri < $NFIXED + _flexcap; _ri++) {
                setnilvalue(s2v(L->top.p + _ri));
            }
            L->top.p += $NFIXED + _flexcap;
            $CALL
            /* The native callee may relocate the stack. Restore the reserved
               destination base before publishing fixed/flexible results. */
            StkId _firstret = restorestack(L, _firstret_off);
            $FIXEDSETS
            for (int _fri = 0; _fri < (int)_flexdesc.n_args; _fri++) {
                $SETFLEX;
            }
            L->top.p = _firstret + $NFIXED + (int)_flexdesc.n_args;
        ]], {
            NFIXED = c_integer_literal(#typ.rettypes),
            CALL = call,
            FIXEDSETS = table.concat(fixedsets, "\n"),
            SETFLEX = setwrapped(flexrettype,
                "s2v(_firstret + " .. c_integer_literal(#typ.rettypes)
                    .. " + _fri)", "_flexdesc.args[_fri]"),
        }))
    elseif #typ.rettypes == 0 then
        -- zero-return `() -> ()`: invoke the void native entry purely for
        -- effect and return no values across the Lua boundary
        table.insert(stats, render([[
            $NAME($PARAMS);
        ]], {
            NAME = titan_entry,
            PARAMS = table.concat(pnames, ", "),
        }))
    else
        table.insert(stats, render([[
            lua_checkstack(L, $NRET);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            L->top.p += $NRET;
            $TYPE res = $NAME($PARAMS);
            /* the native callee may have grown (and thus relocated) the Lua
               stack via lua_checkstack, so recompute the return slot pointer
               from the saved offset before writing through it */
            StkId _firstret = restorestack(L, _firstret_off);
            $SETSLOT;
            _firstret++;
        ]], {
            TYPE = ctype(rettype),
            NAME = titan_entry,
            PARAMS = table.concat(pnames, ", "),
            SETSLOT = setwrapped(rettype, "s2v(_firstret)", "res"),
            NRET = #typ.rettypes
        }))
        for i = 2, #typ.rettypes do
            table.insert(stats, render([[
                $SETSLOT;
                _firstret++;
            ]], {
                SETSLOT = setwrapped(typ.rettypes[i], "s2v(_firstret)", "_outparam_" .. i)
            }))
        end
    end
    table.insert(stats, render([[
        if (TITAN_UNLIKELY(__installed_errfunc)) {
            L->errfunc = __save_errfunc;
        }
        return $NRET;
    ]], {
        NRET = flexrettype
            and (c_integer_literal(#typ.rettypes)
                .. " + (int)_flexdesc.n_args")
            or c_integer_literal(#typ.rettypes)
    }))
    -- Missing Lua arguments are adjusted upward with nil before parameter
    -- coercion, matching Titan call-site adjustment. Input-variadic wrappers
    -- collect surplus arguments; fixed wrappers deliberately ignore them.
    local argcheck
    if varargtype then
        argcheck = render([[
        ptrdiff_t _nargs = L->top.p - func - 1;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            lua_checkstack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue(s2v(L->top.p));
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
            NAME = c_string_literal(titan_name),
        })
    else
        argcheck = render([[
        ptrdiff_t _nargs = L->top.p - func - 1;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            lua_checkstack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue(s2v(L->top.p));
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
        })
    end
    return render([[
    static int $LUANAME(lua_State *L) {
        StkId func = L->ci->func.p;
        $ARGCHECK
        $ERRORSLOT
        ptrdiff_t __save_errfunc = L->errfunc;
        int __installed_errfunc = 0;
        if (TITAN_UNLIKELY(!titan_errfunc_is_errorhandler(L))) {
            lua_pushcfunction(L, errorhandler);
            L->errfunc = savestack(L, L->top.p - 1);
            __installed_errfunc = 1;
        }
        CClosure *_fn = clCvalue(s2v(func));
        Udata *_mod = uvalue(&_fn->upvalue[0]);
        $ENTRYLINE$BODY
    }]], {
        LUANAME = lua_name,
        ARGCHECK = argcheck,
        ERRORSLOT = #params == 0 and "lua_pushnil(L);" or "",
        NAME = c_string_literal(titan_name),
        -- Stamp the Lua-entry wrapper to the function definition's .titan loc
        -- so its native frame, and any arg-coercion throw within it, symbolizes
        -- to the .titan source rather than drifting through the wrapper's
        -- generated C.
        ENTRYLINE = emitline({ loc = loc }),
        BODY = table.concat(stats, "\n"),
    })
end

-- A captured-and-mutated parameter is boxed: its incoming value is anchored in
-- its reserved slot for gc types, then copied into a fresh box cell so a nested
-- lambda capturing it shares the same mutable storage. Sets `param._box`.
local function codeboxparam(ctx, param)
    local typ = param._type
    param._box = "_box_" .. param.name
    local boxslot = newslot(ctx)
    return render([[
        $NEWBOX
        $SETSLOT
    ]], {
        NEWBOX = newbox(ctx, typ, param._box, boxslot),
        SETSLOT = box_write(typ, param._box, param._cvar),
    })
end

-- Titan calling convention:
--     first parameter is a lua_State*, other parameters
--     get the other arguments, with each being its actual
--     native type. Garbage-collectable arguments also need
--     to be pushed to the Lua stack by the *caller*. The
--     function returns its first return value directly.
--     Other return values go in out parameters, following
--     the in parameters. Gc-able return values *do not*
--     need to be pushed by the callee, as it is assumed
--     that the caller is going to push them if needed and
--     just returning from a function does not call GC
local function codefuncdec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local rettype = node._type.rettypes[1]
    local fname, luaname
    if node._tag == "Ast.TopLevelFunc" then
        fname = func_name(tlcontext.module, node.name)
        luaname = func_luaname(tlcontext.module, node.name)
        register_trace_name(tlcontext, fname,
            tlcontext.module .. "." .. node.name)
    elseif node._tag == "Ast.TopLevelStatic" then
        fname = static_name(node._type)
        luaname = static_luaname(node._type)
        -- fqtn is "<module>.<record>"; a static is "<module>.<record>.<static>".
        register_trace_name(tlcontext, fname,
            node._type.fqtn .. "." .. node._type.name)
    else
        assert(node._tag == "Ast.TopLevelMethod")
        fname = method_name(node._type)
        luaname = method_luaname(node._type)
        -- fqtn is "<module>.<record>"; a method is "<module>.<record>:<method>".
        register_trace_name(tlcontext, fname,
            node._type.fqtn .. ":" .. node._type.name)
    end
    -- Detect a `StatTry` in this function's body up front. Nested
    -- function/lambda bodies have their own contexts and are not scanned.
    ctx.has_try = stat_contains_try(node.block)
    ctx.entry_try = node.block._tag == "Ast.StatTry" and
        node.block.catchblock and node.block or nil
    if ctx.has_try then analyze_try_spills(node.block) end
    -- The declared return types, so a `return` routed through a finally
    -- (codetry/codereturn) can size + fill the per-try saved-return temps.
    ctx.rettypes = node._type.rettypes
    ctx.flexrettype = node._type.flexrettype or false
    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    if node._tag == "Ast.TopLevelMethod" then
        -- `self` is a real Decl that capture analysis can mark captured/assigned,
        -- so it is treated exactly like a parameter: anchored when a gc-typed and
        -- assigned self, and boxed when captured-and-mutated by a nested lambda.
        local self = node._self
        self._cvar = "__self__"
        self._boxed = self._captured and self._assigned
        if types.is_gc(self._type) and (self._assigned or self._needs_spill) then
            self._slot = newslot(ctx)
            -- anchor the incoming gc self before the box allocation (which can
            -- trigger GC), so a reassigned/captured self stays live
            table.insert(stats, setslot(self._type, self._slot, self._cvar))
        end
        if self._boxed then
            table.insert(stats, codeboxparam(ctx, self))
        end
        table.insert(stats, spill_decl_init(ctx, self))
        table.insert(cparams, cvardecl(ctx, self._type, self._cvar))
    end
    for _, param in ipairs(fixed_params(node.params)) do
        param._cvar = "_param_" .. param.name
        param._boxed = param._captured and param._assigned
        if types.is_gc(param._type) and (param._assigned or param._needs_spill) then
            param._slot = newslot(ctx)
            -- anchor the incoming gc param in its own slot before the box
            -- allocation (which can trigger GC) — see codeboxparam
            table.insert(stats, setslot(param._type, param._slot, param._cvar))
        end
        if param._boxed then
            table.insert(stats, codeboxparam(ctx, param))
        end
        table.insert(stats, spill_decl_init(ctx, param))
        table.insert(cparams, cvardecl(ctx, param._type, param._cvar))
    end
    -- Variadic: the backing struct + start offset, pinned after the declared
    -- params and before the out-params, and threaded into ctx for `...` lowering.
    local varargtype = node._type.varargtype
    if varargtype then
        table.insert(cparams, varg_struct_name(varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        ctx.varargs = { cname = "_varargs", start = "_start", elem = varargtype }
    end
    for i = 2, #node._type.rettypes do
        local outtype = node._type.rettypes[i]
        table.insert(cparams, ctype(outtype) .. " *" .. "_outparam_" .. i)
    end
    if node._type.flexrettype then
        table.insert(cparams,
            varg_struct_name(node._type.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
    end
    -- Attribute the first native frame to the function definition: a `#line`
    -- at function entry (after parameter setup, before the body) so a
    -- backtrace through the entry shows the .titan definition line, not the
    -- generated .c.
    local body = emitline(node) .. codestat(ctx, node.block)
    local nslots = ctx.nslots
    -- Patch the try-recovery's reserved-top restore (codetry emits the symbolic
    -- TITAN_RESERVED_NSLOTS so a catch's own slots are GC-scanned) now that the
    -- function-wide high-water mark is final.
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    -- A value-call (codevaluecall) can relocate the Lua stack, which would
    -- dangle `_base`; such a function saves `_base` as an offset so it can be
    -- recomputed after each value-call.
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    -- Clean-exit restore foundation (#3): snapshot the errorjmp chain at function
    -- entry so a `return` crossing a protected region can restore it before the
    -- epilogue (the inner `_lj` would otherwise be out of scope). Emitted only
    -- when a `return` actually crossed a try (codereturn set used_entry_restore),
    -- so a try with no escaping return adds no dead locals.
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
            .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        if (L->stack_last.p - L->top.p > $NSLOTS) {
            if (L->ci->top.p < L->top.p + $NSLOTS) L->ci->top.p = L->top.p + $NSLOTS;
        } else {
            if (TITAN_UNLIKELY(!lua_checkstack(L, $NSLOTS)))
                luaD_throw(L, LUA_ERRMEM);
        }
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue(s2v(_s));
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        -- No reserved slots, but still anchor _base so every return path can
        -- reset L->top.p uniformly (the reset is then a no-op).
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    table.insert(stats, body)
    -- A zero-return `() -> ()` function has no `rettypes[1]`: its native entry
    -- returns C `void`, so falling off the end emits a bare `return;`. A
    -- `nil`-returning function returns the int 0 (the native nil encoding).
    local crettype = rettype and ctype(rettype) or "void"
    local flexempty = node._type.flexrettype
        and "            _flexout->n_args = 0;\n" or ""
    if not rettype then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return;]])
    elseif rettype._tag == "Type.Nil" then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return 0;]])
    else
        local ur = unreachable_return(rettype, node.block)
        if ur then table.insert(stats, ur) end
    end
    node._body = render([[
    $ISLOCAL $RETTYPE $NAME($PARAMS) {
        $BODY
    }]], {
        ISLOCAL = node.islocal and "static" or "",
        RETTYPE = crettype,
        NAME = fname,
        PARAMS = table.concat(cparams, ", "),
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        $ISLOCAL $RETTYPE $NAME($PARAMS);
    ]], {
        ISLOCAL = node.islocal and "static" or "",
        RETTYPE = crettype,
        NAME = fname,
        PARAMS = table.concat(cparams, ", ")
    })
    node._luabody = genluaentry(tlcontext, node.name, fname, node._type, node.loc, luaname)
end

local function codeinitializerdec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local fname = module_initializer_name(tlcontext)
    ctx.has_try = stat_contains_try(node)
    ctx.entry_try = node._tag == "Ast.StatTry" and
        node.catchblock and node or nil
    if ctx.has_try then analyze_try_spills(node) end
    ctx.rettypes = {}

    local body = codestat(ctx, node)
    local nslots = ctx.nslots
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
            .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        if (L->stack_last.p - L->top.p > $NSLOTS) {
            if (L->ci->top.p < L->top.p + $NSLOTS) L->ci->top.p = L->top.p + $NSLOTS;
        } else {
            if (TITAN_UNLIKELY(!lua_checkstack(L, $NSLOTS)))
                luaD_throw(L, LUA_ERRMEM);
        }
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue(s2v(_s));
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    table.insert(stats, "        (void)_mod;")
    table.insert(stats, "        (void)_fn;")
    table.insert(stats, body)
    table.insert(stats, [[
            L->top.p = _base;
            return;]])
    node._body = render([[
    static void $NAME(lua_State *L, Udata *_mod, CClosure *_fn) {
        $BODY
    }]], {
        NAME = fname,
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        static void $NAME(lua_State *L, Udata *_mod, CClosure *_fn);
    ]], {
        NAME = fname,
    })
end

-- Emit the two bound-method trampolines for a TopLevelMethod, delegating to the
-- method's own native/Lua entries. They turn `obj:m` into a first-class function
-- value of the self-removed type `(params) -> rettypes`, with `self` captured in
-- the closure's `upvalue[3]`. Public methods export these trampolines so a bind
-- site in a module that only has this module's `.so` can still reach them; local
-- methods keep them file-local.
-- Produces node._boundsig / node._boundbody.
local function codemethodtrampoline(tlcontext, node)
    local mtype = node._type
    -- the self-removed function type whose ABI the native trampoline matches
    local ftype = types.Function(mtype.params, mtype.rettypes, false,
        mtype.varargtype, mtype.flexrettype)
    local nativename = bound_method_name(mtype)
    local luaname = bound_method_luaname(mtype)
    local mnative = method_name(mtype)
    local mlua = method_luaname(mtype)
    -- The bound trampoline forwards to the method; if its own native frame ever
    -- appears in a trace, name it after the method (<module>.<record>:<method>).
    register_trace_name(tlcontext, nativename,
        mtype.fqtn .. ":" .. mtype.name)
    local rettype = mtype.rettypes[1]
    local crettype = rettype and ctype(rettype) or "void"

    -- Named parameter list matching function_sig(ftype) so the trampoline body
    -- can forward each one. Names are local to the trampoline (`_bp_N` for params,
    -- `_outparam_N` for out-params), independent of the method's own _cvar names.
    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    local callargs = { "L", "_mod", "NULL",
        "uvalue(&_fn->upvalue[3])" }
    for i, ptype in ipairs(mtype.params) do
        local pname = "_bp_" .. i
        table.insert(cparams, ctype(ptype) .. " " .. pname)
        table.insert(callargs, pname)
    end
    -- A variadic method's bound trampoline forwards the backing struct + start
    -- offset verbatim, at the pinned position (after params, before out-params),
    -- so it matches function_sig(ftype) byte-for-byte.
    if mtype.varargtype then
        table.insert(cparams, varg_struct_name(mtype.varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        table.insert(callargs, "_varargs")
        table.insert(callargs, "_start")
    end
    for i = 2, #mtype.rettypes do
        local oname = "_outparam_" .. i
        table.insert(cparams, ctype(mtype.rettypes[i]) .. " *" .. oname)
        table.insert(callargs, oname)
    end
    if mtype.flexrettype then
        table.insert(cparams,
            varg_struct_name(mtype.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
        table.insert(callargs, "_flexout")
        table.insert(callargs, "_flexwant")
    end
    local call = render("$NAME($ARGS)", {
        NAME = mnative,
        ARGS = table.concat(callargs, ", "),
    })
    local bodycall
    if rettype then
        bodycall = "return " .. call .. ";"
    else
        bodycall = call .. ";\n        return;"
    end

    -- native trampoline signature == function_sig of the self-removed type, but
    -- with named parameters so the body can forward them.
    local storage = node.islocal and "static TITAN_UNUSED " or ""
    local nativesig = render("$STORAGE$RETTYPE $NAME($PARAMS)", {
        STORAGE = storage,
        RETTYPE = crettype,
        NAME = nativename,
        PARAMS = table.concat(cparams, ", "),
    })
    -- Public bound trampolines are exported (non-static): a bind site in a
    -- module that only has this module's `.so` reaches the native one for the
    -- fast path AND the Lua one (the closure's lua_CFunction) by dlsym.
    node._boundbody = render([[
    $SIG {
        $BODYCALL
    }
    $STORAGE int $LUANAME(lua_State *L) {
        /* insert the captured receiver (self) as the first stack argument, then
           delegate to the method's Lua entry (which reuses all the boundary
           checks/coercions). upvalue[3] holds the record udata directly (the
           record value IS the udata), which is exactly the Lua-facing value the
           method Lua entry expects. The bound closure's upvalue[0] is the
           method's module, so the method Lua entry recovers _mod correctly from
           it. */
        CClosure *_bound = clCvalue(s2v(L->ci->func.p));
        lua_checkstack(L, 1);
        setobj2s(L, L->top.p, &(_bound->upvalue[3]));
        L->top.p++;
        lua_insert(L, 1);
        return $MLUA(L);
    }]], {
        SIG = nativesig,
        STORAGE = storage,
        BODYCALL = bodycall,
        LUANAME = luaname,
        MLUA = mlua,
    })
    node._boundsig = render([[
        $STORAGE$SIG;
        $STORAGE int $LUANAME(lua_State *L);
    ]], {
        STORAGE = storage,
        SIG = function_sig(nativename, ftype, false),
        LUANAME = luaname,
    })
    -- Publish the bound function type's tag from the DEFINING module (every
    -- method, even one never bound here): a `.so`-only importer recovers the tag
    -- from the registry this module populates, so its bound value's fast path can
    -- recognise the trampoline. (publish-or-recover dedupes a double publish.)
    function_type_tag(tlcontext, ftype)
end

-- Names + registration for a lambda node, assigned on first sight at its use
-- site. Both the closure-creation (codelambda) and the body emission
-- (codelambdadec) read these; assigning here (lazily) keeps the native/Lua names
-- stable across the two.
local function lambda_register(tlcontext, node)
    if not node._lambda_native then
        local n = tlcontext.lambda_count
        tlcontext.lambda_count = n + 1
        node._lambda_native = tlcontext.prefix .. "lambda_" .. n
        node._lambda_lua = tlcontext.prefix .. "lambda_" .. n .. "_" .. TITAN_ENTRY_TAG .. "_lua"
        -- An anonymous function shows as "anonymous function at <file>:<defline>"
        -- (the lambda's DEFINITION loc), formatted into the name table here.
        register_trace_name(tlcontext, node._lambda_native, anon_qualname(node.loc))
        table.insert(tlcontext.lambdas, node)
    end
end

-- Read a captured variable in the CURRENT function, for pushing into a nested
-- lambda's closure. Returns (boxexpr, valuestats, valueexpr): for a boxed
-- capture, `boxexpr` is the C expression for the box `Udata*`; for a by-value
-- capture, `valueexpr` (with prelude `valuestats`) is the C value expression.
-- A capture that is itself captured by the current function (transitive) is
-- reached through the current `_fn`; otherwise it is a local/param of the current
-- function.
local function read_capture(ctx, decl)
    local cap = ctx.captures and ctx.captures[decl]
    if cap then
        -- transitive: the current function captured this decl too
        if cap.boxed then
            return cap.boxvar, nil, nil
        else
            return nil, "", getslot(decl._type, nil,
                "&_fn->upvalue[" .. c_integer_literal(cap.index) .. "]")
        end
    elseif decl._boxed then
        return decl._box, nil, nil
    else
        -- a by-value local/param of the current function
        return nil, "", decl._cvar
    end
end

-- Use-site code for an anonymous function: build a fresh CClosure with
-- upvalue[0]=_mod, [1]=type tag, [2]=native ptr, and [3+i]=captured variable i
-- (a box Udata* or a copied value), then return the closure value (anchored in
-- a gc temp). The capture pushes are transient raw stack pushes (guarded by
-- lua_checkstack, consumed by lua_pushcclosure), not nslots-accounted.
function codelambda(ctx, node)
    local tlcontext = ctx.tlcontext
    lambda_register(tlcontext, node)
    local ncap = #node._captures
    local stats = {}
    -- lua_checkstack can relocate the Lua stack; this function therefore needs
    -- _base recomputed from its saved offset afterwards (like a value call).
    ctx.uses_base_off = true
    table.insert(stats, render([[
        lua_checkstack(L, $NPUSH);
        titan_pushmodule(L, _mod);
        lua_pushlightuserdata(L, (void*)$FUNCTAG);
        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
    ]], {
        NPUSH = c_integer_literal(3 + ncap),
        FUNCTAG = function_type_tag(tlcontext, node._type),
        NATIVE = node._lambda_native,
    }))
    for _, decl in ipairs(node._captures) do
        local captype = decl._type
        local boxexpr, vstats, vexpr = read_capture(ctx, decl)
        if boxexpr then
            table.insert(stats, render([[
                setuvalue(L, s2v(L->top.p), $BOX); L->top.p++;
            ]], { BOX = boxexpr }))
        else
            table.insert(stats, render([[
                $VSTATS
                $SETSLOT L->top.p++;
            ]], {
                VSTATS = vstats,
                SETSLOT = setslot(captype, "s2v(L->top.p)", vexpr),
            }))
        end
    end
    -- lua_pushcclosure moves the pushed upvalues into the fresh (white) closure,
    -- so no barrier is needed at creation. The result closure is on top.
    local cdecl, tmpname, tmpslot = newtmp(ctx, node._type, true)
    table.insert(stats, render([[
        lua_pushcclosure(L, $LUANAME, $NUP);
        _base = restorestack(L, _base_off);
        $CDECL
        setobj2t(L, $TMPSLOT, s2v(L->top.p - 1));
        $GETSLOT;
        L->top.p--;
    ]], {
        LUANAME = node._lambda_lua,
        NUP = c_integer_literal(3 + ncap),
        CDECL = cdecl,
        TMPSLOT = tmpslot,
        GETSLOT = getslot(node._type, tmpname, "s2v(L->top.p - 1)"),
    }))
    return table.concat(stats, "\n"), tmpname
end

-- Use-site code for a bound method reference `obj:m`: evaluate the receiver once
-- into an anchored gc temp, then build a 4-upvalue CClosure exactly like a
-- 1-capture lambda whose capture is `self`:
--   upvalue[0] = the method's module closure
--   upvalue[1] = the self-removed function-type tag (light userdata)
--   upvalue[2] = the bound native trampoline pointer (light userdata)
--   upvalue[3] = self (the captured receiver)
-- The closure's lua_CFunction is the bound Lua trampoline. The result is an
-- ordinary Type.Function value, callable through both paths and Lua-crossable.
function codemethodref(ctx, node)
    local tlcontext = ctx.tlcontext
    local mtype = node._method
    local ftype = node._type      -- Type.Function (self removed)
    local nativename = bound_method_name(mtype)
    local luaname = bound_method_luaname(mtype)
    local mod, record = mtype.fqtn:match("^(.*)%.([^.]+)$")

    -- The bound closure's upvalue[0] must be the defining module's closure: `_mod`
    -- for a same-module method, or the imported module's closure recovered from
    -- our `_mod` upvalues exactly as method *calls* do. Cross-module also requires
    -- the trampoline symbol to be reachable (extern / dlsym), registered in
    -- ctx.functions keyed by its mangled name.
    local modexpr = "_mod"
    if mod ~= ctx.module then
        ctx.functions[mtype.fqtn .. ":bound:" .. mtype.name] = {
            module = mod,
            record = record,
            name = mtype.name,
            type = ftype,
            mangled = nativename,
        }
        -- the Lua trampoline (the closure's lua_CFunction) is not function_sig
        -- shaped, so it gets its own extern/dlsym registry entry
        ctx.bound_luas[luaname] = { module = mod }
        if not ctx.modules[mod] then
            ctx.modules[mod] = nextupvalue(ctx.tlcontext)
        end
        modexpr = render("uvalue(&_mod->uv[$INDEX].uv)", {
            INDEX = c_integer_literal(ctx.modules[mod]),
        })
    end

    ctx.uses_base_off = true
    local stats = {}

    -- 1. evaluate the receiver once into an anchored gc temp (self: Udata*)
    local rtype = node.exp._type
    local rstat, rexp = codeexp(ctx, node.exp)
    local rdecl, rname, rslot = newtmp(ctx, rtype, true)
    table.insert(stats, rstat)
    table.insert(stats, rdecl)
    table.insert(stats, rname .. " = " .. rexp .. ";")
    table.insert(stats, setslot(rtype, rslot, rname))

    -- 2. push the four upvalues and build the closure
    table.insert(stats, render([[
        lua_checkstack(L, 4);
        titan_pushmodule(L, $MODEXPR);
        lua_pushlightuserdata(L, (void*)$FUNCTAG);
        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
        $PUSHSELF L->top.p++;
    ]], {
        MODEXPR = modexpr,
        FUNCTAG = function_type_tag(tlcontext, ftype),
        NATIVE = nativename,
        PUSHSELF = setslot(rtype, "s2v(L->top.p)", rname),
    }))

    -- 3. consume the closure into an anchored gc temp
    local cdecl, tmpname, tmpslot = newtmp(ctx, ftype, true)
    table.insert(stats, render([[
        lua_pushcclosure(L, $LUANAME, 4);
        _base = restorestack(L, _base_off);
        $CDECL
        setobj2t(L, $TMPSLOT, s2v(L->top.p - 1));
        $GETSLOT;
        L->top.p--;
    ]], {
        LUANAME = luaname,
        CDECL = cdecl,
        TMPSLOT = tmpslot,
        GETSLOT = getslot(ftype, tmpname, "s2v(L->top.p - 1)"),
    }))
    return table.concat(stats, "\n"), tmpname
end

-- File-scope emission of a lambda: its native entry (signature via function_sig,
-- so the uniform (L,_mod,_fn,params...,outparams) ABI) and Lua entry. The body
-- reads captures from _fn->upvalue[3+i]; the ctx.captures map (decl -> {index,
-- boxed, boxvar}) is consulted by codevar/codeassignment before the local/box
-- logic. Produces node._sig / node._body / node._luabody.
function codelambdadec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local rettype = node._type.rettypes[1]
    local fname = node._lambda_native
    local luaname = node._lambda_lua
    -- A try inside this lambda's own body gets its own spill analysis and entry
    -- errorjmp-save (an enclosing function's try does not affect this context).
    ctx.has_try = stat_contains_try(node.block)
    ctx.entry_try = node.block._tag == "Ast.StatTry" and
        node.block.catchblock and node.block or nil
    if ctx.has_try then analyze_try_spills(node.block) end
    -- The lambda's own return types (sizes finally saved-return temps).
    ctx.rettypes = node._type.rettypes
    ctx.flexrettype = node._type.flexrettype or false

    -- Build the capture map and bind each boxed capture's box pointer once at
    -- body entry. By-value captures are read directly from _fn (immutable).
    ctx.captures = {}
    local capbinds = {}
    for i, decl in ipairs(node._captures) do
        local index = 3 + (i - 1)
        local boxed = decl._boxed and true or false
        local entry = { index = index, boxed = boxed }
        if boxed then
            entry.boxvar = "_box_cap_" .. i
            table.insert(capbinds, render([[
                Udata *$BOXVAR = uvalue(&_fn->upvalue[$INDEX]);
            ]], { BOXVAR = entry.boxvar, INDEX = c_integer_literal(index) }))
        end
        ctx.captures[decl] = entry
    end

    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    for _, param in ipairs(fixed_params(node.params)) do
        param._cvar = "_param_" .. param.name
        param._boxed = param._captured and param._assigned
        if types.is_gc(param._type) and (param._assigned or param._needs_spill) then
            param._slot = newslot(ctx)
            table.insert(stats, setslot(param._type, param._slot, param._cvar))
        end
        if param._boxed then
            table.insert(stats, codeboxparam(ctx, param))
        end
        table.insert(stats, spill_decl_init(ctx, param))
        table.insert(cparams, cvardecl(ctx, param._type, param._cvar))
    end
    -- A lambda's `ctx` is fresh (newcontext), so ctx.varargs starts nil; set it
    -- only for a variadic lambda. An inner lambda thus NEVER inherits an enclosing
    -- function's `...` (scope rule 4) — its own ctx governs `...` lowering.
    local varargtype = node._type.varargtype
    if varargtype then
        table.insert(cparams, varg_struct_name(varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        ctx.varargs = { cname = "_varargs", start = "_start", elem = varargtype }
    end
    for i = 2, #node._type.rettypes do
        local outtype = node._type.rettypes[i]
        table.insert(cparams, ctype(outtype) .. " *" .. "_outparam_" .. i)
    end
    if node._type.flexrettype then
        table.insert(cparams,
            varg_struct_name(node._type.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
    end

    local body = codestat(ctx, node.block)
    local nslots = ctx.nslots
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
            .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        if (L->stack_last.p - L->top.p > $NSLOTS) {
            if (L->ci->top.p < L->top.p + $NSLOTS) L->ci->top.p = L->top.p + $NSLOTS;
        } else {
            if (TITAN_UNLIKELY(!lua_checkstack(L, $NSLOTS)))
                luaD_throw(L, LUA_ERRMEM);
        }
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue(s2v(_s));
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    -- box-capture bindings come first, before any body code or preamble use
    for i = #capbinds, 1, -1 do
        table.insert(stats, 1, capbinds[i])
    end
    table.insert(stats, body)
    local crettype = rettype and ctype(rettype) or "void"
    local flexempty = node._type.flexrettype
        and "            _flexout->n_args = 0;\n" or ""
    if not rettype then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return;]])
    elseif rettype._tag == "Type.Nil" then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return 0;]])
    else
        local ur = unreachable_return(rettype, node.block)
        if ur then table.insert(stats, ur) end
    end
    node._body = render([[
    static $RETTYPE $NAME($PARAMS) {
        $BODY
    }]], {
        RETTYPE = crettype,
        NAME = fname,
        PARAMS = table.concat(cparams, ", "),
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        static $RETTYPE $NAME($PARAMS);
        static int $LUANAME(lua_State *L);
    ]], {
        RETTYPE = crettype,
        NAME = fname,
        PARAMS = table.concat(cparams, ", "),
        LUANAME = luaname,
    })
    node._luabody = genluaentry(tlcontext, "lambda", fname, node._type, node.loc, luaname)
end

local function codevardec(ctx, initvars, switch_get, switch_set, gvar_map, node)
    local cstats, cexp = codeexp(ctx, node.value)
    node._slot = render("&_mod->uv[$INDEX].uv",
        { INDEX = c_integer_literal(node._upvalue) })
    table.insert(initvars, render([[
        $CSTATS
        {
            $CTYPE _var = $CEXP;
            $SETSLOT
            $BARRIER
        }
    ]], {
        CSTATS = cstats,
        CEXP = cexp,
        CTYPE = ctype(node._type),
        SETSLOT = setslot(node._type, node._slot, "_var"),
        BARRIER = types.is_gc(node._type)
                  and "luaC_barrierback(L, obj2gco(_mod), " .. node._slot .. ");" or ""
    }))
    if not node.islocal then
        table.insert(gvar_map, render([[
            lua_pushinteger(L, $INDEX);
            lua_setfield(L, -2, $NAME);
        ]], {
            INDEX = c_integer_literal(node._upvalue),
            NAME = c_string_literal(node.decl.name),
        }))
        table.insert(switch_get, render([[
            case $I: {
                $COPYSLOT;
                break;
            }
        ]], {
            I = c_integer_literal(node._upvalue),
            COPYSLOT = copyslotwrapped("s2v(L->top.p - 1)", node._slot)
        }))
        table.insert(switch_set, render([[
            case $I: {
                $SETSLOT;
                $BARRIER
                break;
            }
        ]], {
            I = c_integer_literal(node._upvalue),
            SETSLOT = checkandset(ctx, node._type, node._slot, "_value", node.loc),
            BARRIER = types.is_gc(node._type)
                      and "luaC_barrierback(L, obj2gco(_mod), " .. node._slot .. ");" or ""
        }))
    end
end

local preamble = [[
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "luaconf.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lgc.h"
#include "ltable.h"
#include "ltm.h"
#include "lfunc.h"
#include "lstring.h"
#include "lvm.h"
#include "lobject.h"
#include "ldo.h"

#include "titan.h"

static inline int titan_errfunc_is_errorhandler(lua_State *L) {
    if (L->errfunc == 0) return 0;
    StkId errfunc = restorestack(L, L->errfunc);
    TValue *v = s2v(errfunc);
    return ttislcf(v) && fvalue(v) == errorhandler;
}

$FOREIGNIMPORTS

#ifdef __clang__
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wparentheses-equality"
#endif

$INCLUDES

$SIGS

]]

local postamble = [[
int $LUAOPEN_NAME(lua_State *L) {
    titan_invalidate_backtrace_state(L);
    Udata *mod = $INITNAME(L);
    setuvalue(L, s2v(L->top.p), mod);
    L->top.p++;
    return 1;
}
]]

local modabi = [[
int $ABINAME(lua_State* L) {
    lua_pushliteral(L, TITAN_VER);
    return 1;
}
]]

local init = [[
static int _initialized = 0; /* tags and external functions are set up */

Udata *$INITNAME(lua_State *L) {
    lua_checkstack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
    if(lua_isnil(L, -1)) {
        _initialized = 1;
        lua_pop(L, 1);
        Udata *_mod = luaS_newudata(L, 0, $NUPVALS);
        titan_pushmodule(L, _mod);
        lua_setfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
        $LOADMODULES1
        $INITMODULES
        $LOADGLOBALS
        $INITRECORDS
        $INITVARS
        $INITFUNCTAGS
        $FUNCS
        $INITNAMES
        $CREATEMETA
        $MODULEINIT
        return _mod;
    } else {
        Udata *_mod = uvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        if(!_initialized) {
            _initialized = 1;
            /* set up function-type tags and functions from shared libraries */
            $LOADMODULES2
            $LOADGLOBALS
            $INITFUNCTAGS
        }
        return _mod;
    }
}
]]

local modtypes = [[
int $TYPESNAME(lua_State* L) {
    lua_pushliteral(L, $TYPES);
    return 1;
}
]]

-- Generates the code for importing the module, and storing it
-- in the corresponding local state slot
local function import_module(loadmods, initmods, sigs, mprefixes,
                             dynamic, node)
    local modname = node.modname
    local upvalue = node._upvalue
    local mprefix = mangle_qn(modname) .. "_"
    mprefixes[modname] = mprefix
    if dynamic then
        local file = modname:gsub("[.]", "/") .. ".so"
        table.insert(loadmods, render([[
            void *$HANDLE = loadlib(L, "$FILE");
            titan_check_abi(L, $HANDLE, "$ABI", "$FILE");
        ]], {
            HANDLE = mprefix .. "handle",
            FILE = file,
            ABI = mprefix .. "abi",
        }))
        table.insert(initmods, render([[
            {
                Udata* (*$INIT)(lua_State *L) = titan_cast_func(Udata* (*)(lua_State*), loadsym(L, $HANDLE, "$INIT"));
                Udata *_m = $INIT(L);
                setuvalue(L, &_mod->uv[$INDEX].uv, _m);
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            }
        ]], { HANDLE = mprefix .. "handle", INIT = mprefix .. "init", INDEX = c_integer_literal(upvalue) }))
    else
        table.insert(sigs, render("extern Udata *$INIT(lua_State *L);", {
            INIT = mprefix .. "init"
        }))
        table.insert(initmods, render([[
            {
                Udata *_m = $INIT(L);
                setuvalue(L, &_mod->uv[$INDEX].uv, _m);
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            }
        ]], { INIT = mprefix .. "init", INDEX = c_integer_literal(upvalue) }))
    end
    -- Set upvalue indexes for public members in the module's type, mirroring
    -- allocate_upvalues in the imported module: exported variables (slots
    -- 0..V-1) first, then every exported function's canonical-closure slot
    -- (V..V+F-1). 0-based to match the imported module's 0-based nextupvalue.
    -- This lets us reference an imported function value by index instead of a
    -- table lookup.
    local memberslot = 0
    for _, member in ipairs(node._type.members) do
        if member._tag == "Type.ModuleVariable" then
            member._upvalue = memberslot
            memberslot = memberslot + 1
        end
    end
    for _, member in ipairs(node._type.members) do
        if member._tag == "Type.ModuleMember" and member.type._tag == "Type.Function" then
            member._closure_upvalue = memberslot
            memberslot = memberslot + 1
        end
    end
end

local function init_data_from_other_modules(tlcontext, includes, loadmods,
                                            loadglobals, initmetas, mprefixes,
                                            static_deps)
    -- When linking dynamically, we need to make 'static' variables and load the values
    -- from the other module's dynamic library
    -- When linking statically, we only need to make 'extern' forward declarations.

    for _, func in pairs(tlcontext.functions) do
        local is_dynamic = static_deps[func.module] ~= true
        local storage_class = is_dynamic and "static" or "extern"
        local fname = func.mangled
        table.insert(includes, storage_class .. " " .. function_sig(fname, func.type, is_dynamic) .. ";")
        if is_dynamic then
            local mprefix = mprefixes[func.module]
            if mprefix then
                table.insert(loadmods, render([[
                    $NAME = titan_cast_func($TYPE, loadsym(L, $HANDLE, "$NAME"));
                ]], { NAME = fname, TYPE = function_sig("", func.type, true), HANDLE = mprefix .. "handle" }))
            else
                -- The defining module is present only through another module's
                -- exported interface (for example, a re-exported record alias).
                -- Initialize the explicit imports first: their RTLD_GLOBAL loads
                -- publish this entry point, so this module need not dlopen the
                -- defining DSO itself.
                table.insert(loadglobals, render([[
                    $NAME = titan_cast_func($TYPE, loadglobalsym(L, "$NAME"));
                ]], { NAME = fname, TYPE = function_sig("", func.type, true) }))
            end
        end
    end

    -- Bound-method Lua trampolines we reference for cross-module `obj:m`: each is
    -- the closure's lua_CFunction. Statically-linked deps just need an `extern`
    -- prototype. Direct `.so` imports use the checked handle opened by the
    -- function loop above; transitive providers have no local handle and resolve
    -- the trampoline from the RTLD_GLOBAL namespace with the native entry point.
    for luaname, info in pairs(tlcontext.bound_luas) do
        local is_dynamic = static_deps[info.module] ~= true
        if is_dynamic then
            local mprefix = mprefixes[info.module]
            table.insert(includes,
                "static int (*" .. luaname .. ")(lua_State *L);")
            if mprefix then
                table.insert(loadmods, render([[
                    $NAME = titan_cast_func(int (*)(lua_State *L), loadsym(L, $HANDLE, "$NAME"));
                ]], { NAME = luaname, HANDLE = mprefix .. "handle" }))
            else
                table.insert(loadglobals, render([[
                    $NAME = titan_cast_func(int (*)(lua_State *L), loadglobalsym(L, "$NAME"));
                ]], { NAME = luaname }))
            end
        else
            table.insert(includes, "extern int " .. luaname .. "(lua_State *L);")
        end
    end

    for fqtn, upvalue in pairs(tlcontext.metatables) do
        table.insert(initmetas, render([[
            luaL_getmetatable(L, "Titan record $TYPE metatable");
            setobj2t(L, &_mod->uv[$INDEX].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            lua_pop(L, 1);
        ]], {
            INDEX = c_integer_literal(upvalue),
            TYPE = fqtn,
        }))
    end

    for module, upvalue in pairs(tlcontext.modules) do
        table.insert(initmetas, render([[
            lua_getfield(L, LUA_REGISTRYINDEX, "Titan module $MODULE");
            setobj2t(L, &_mod->uv[$INDEX].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            lua_pop(L, 1);
        ]], {
            INDEX = c_integer_literal(upvalue),
            MODULE = module,
        }))
    end
end

local function coderecorddec(ctx, code, initrecs, node)
    -- (the type tag is forward-declared up front in generate(), so that
    -- forward/mutually-recursive record field types resolve)
    local fieldmap, getswitch, setswitch = {}, {}, {}
    for _, field in ipairs(node._type.fields) do
        if not field.islocal then
            table.insert(fieldmap, render([[
                lua_pushliteral(L, $NAME);
                lua_pushinteger(L, $INDEX);
                lua_rawset(L, -3);
            ]], {
                NAME = c_string_literal(field.name),
                INDEX = c_integer_literal(field.index)
            }))
            table.insert(getswitch, render([[
                case $INDEX: {
                    $SETWRAPPED
                    break;
                }
            ]], {
                INDEX = c_integer_literal(field.index),
                -- The field value (for any type, including a nominal whose
                -- value is itself a udata) is held directly at _slot.
                SETWRAPPED = "setobj2s(L, L->top.p - 1, _slot);"
            }))
            table.insert(setswitch, render([[
                case $INDEX: {
                    $CHECKANDSET;
                    break;
                }
            ]], {
                INDEX = c_integer_literal(field.index),
                CHECKANDSET = checkandset(ctx, field.type, "_dst", "_src", node.loc)
            }))
        end
    end
    for name, method in pairs(node._type.methods) do
        if not method.islocal then
            table.insert(fieldmap, render([[
                lua_pushliteral(L, $NAME);
                /* Module is upvalue of Lua entry point of method */
                titan_pushmodule(L, _mod);
                lua_pushcclosure(L, $METHOD, 1);
                lua_rawset(L, -3);
            ]], {
                NAME = c_string_literal(name),
                METHOD = method_luaname(method)
            }))
        end
    end
    if #node._type.fields > 0 then
        table.insert(code, render([[
            static int __index_$RECNAME(lua_State *L) {
                TValue *_recslot = s2v(L->ci->func.p + 1);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_func->upvalue[1]);
                Udata *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _fieldidxv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_fieldidxv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag))) {
                    const TValue *_fieldidx = &_fieldidxv;
                    if(ttisCclosure(_fieldidx)) {
                        setobj2s(L, L->top.p - 1, _fieldidx);
                    } else {
                        TValue *_slot = &_rec->uv[ivalue(_fieldidx)].uv;
                        (void)_slot; /* records with only local fields have no cases */
                        switch(ivalue(_fieldidx)) {
                            $GETCASES
                        }
                    }
                    return 1;
                } else {
                    return luaL_error(L, "%s:%d:%d: field '%s' not found in record '%s'", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
                }
            }
            static int __newindex_$RECNAME(lua_State *L) {
                TValue *_recslot = s2v(L->ci->func.p + 1);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_func->upvalue[1]);
                Udata *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _fieldidxv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_fieldidxv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag) && ttisinteger(&_fieldidxv))) {
                    TValue* _dst = &(_rec->uv[ivalue(&_fieldidxv)].uv);
                    TValue* _src = s2v(L->ci->func.p + 3);
                    (void)_src; /* records with only local fields have no cases */
                    switch(ivalue(&_fieldidxv)) {
                        $SETCASES
                    }
                    luaC_barrierback(L, obj2gco(_rec), _dst);
                    return 0;
                } else {
                    return luaL_error(L, "%s:%d:%d: field '%s' not found in record '%s'", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
                }
            }
        ]], {
            RECNAME = mangle_qn(node._type.name),
            CHECKANDGET = checkandget(ctx, types.Nominal(node._type.name), "_rec", "_recslot", node.loc),
            FQTN = c_string_literal(node._type.name),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            GETCASES = table.concat(getswitch, "\n"),
            SETCASES = table.concat(setswitch, "\n")
        }))
    else
        table.insert(code, render([[
            static int __index_$RECNAME(lua_State *L) {
                return luaL_error(L, "%s:%d:%d: field %s not found in record %s", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
            }
            static int __newindex_$RECNAME(lua_State *L) {
                return luaL_error(L, "%s:%d:%d: field %s not found in record %s", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
            }
        ]], {
            RECNAME = mangle_qn(node._type.name),
            FQTN = c_string_literal(node._type.name),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }))
    end
    table.insert(initrecs, render([[
        {
        /* If we are here then this is the first time
           this module is initialized in the current Lua state,
           so there is no metatable stored for this record */
        luaL_newmetatable(L, "Titan record $TYPE metatable");
        const void *_mtp = lua_topointer(L, -1);
        lua_pushliteral(L, "__metatable");
        lua_pushliteral(L, "Titan record $TYPE");
        lua_rawset(L, -3);
        lua_newtable(L);
        $FIELDMAP
        lua_pushliteral(L, "__index");
        lua_pushvalue(L, -2);            /* fieldmap */
        titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
        lua_pushcclosure(L, __index_$RECNAME, 2);
        lua_rawset(L, -4);
        lua_pushliteral(L, "__newindex");
        lua_pushvalue(L, -2);            /* fieldmap */
        titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
        lua_pushcclosure(L, __newindex_$RECNAME, 2);
        lua_rawset(L, -4);
        lua_pop(L, 2); /* pop fieldmap and metatable */
        /* Index from metatable pointer to typename for error messages */
        lua_pushstring(L, "$TYPE");
        lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        RECNAME = mangle_qn(node._type.name),
        TYPE = node._type.name,
        FIELDMAP = table.concat(fieldmap, "\n")
    }))
end

-- Distribute local state slots for the variables and
-- imported modules of the current module,
-- starting with exported variables in the order they appear;
-- slots for record metatables are allocated in
-- "init_data_from_other_modules"
-- Tags can be stored in C variables, as their value
-- is the same across all instances of the module
local function allocate_upvalues(tlcontext, ast)
    -- Exported variables first (slots 1..V). Importers reconstruct these
    -- indices purely from the module interface, enumerating members in
    -- declaration order (see import_module), so the layout here must match.
    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                node._upvalue = nextupvalue(tlcontext)
            end
        end
    end
    -- Then a canonical-closure slot for *every* exported function (slots
    -- V+1..V+F), exported-always: an importer may take the value even when this
    -- module never references it, and indexing the closure (rather than a hash
    -- lookup) keeps the cross-module reference O(1) and fast-path eligible.
    for _, node in pairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelFunc" and not node.islocal then
            node._closure_upvalue = nextupvalue(tlcontext)
        end
    end
    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and node.islocal then
                node._upvalue = nextupvalue(tlcontext)
            elseif tag == "Ast.TopLevelImport" then
                node._upvalue = nextupvalue(tlcontext)
            end
        end
    end
    -- Referenced local functions (private, so only when used as a value) and
    -- every record function (e.g. `Rec.new`) each get a canonical-closure slot.
    for _, node in pairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelFunc" and node.islocal and node._valref then
                node._closure_upvalue = nextupvalue(tlcontext)
            elseif node._tag == "Ast.TopLevelStatic" then
                node._closure_upvalue = nextupvalue(tlcontext)
                tlcontext.static_slots[node._type.fqtn .. "." .. node._type.name] =
                    node._closure_upvalue
            elseif node._tag == "Ast.TopLevelRecord" then
                -- A per-record uv slot holding the record's static-namespace
                -- table (what `m.Rec` returns). Allocated in the late group so
                -- importer-visible slot math (vars 1..V, fn closures V+1..V+F)
                -- is unchanged.
                tlcontext.record_namespace_slots[node._type.name] =
                    nextupvalue(tlcontext)
            end
        end
    end
end

function coder.generate(modname, ast, static_deps)
    local tlcontext = {
        module = modname,
        prefix = mangle_qn(modname) .. "_",
        variables = {},
        metatables = {},
        owned_c_metatables = {},
        functions = {},
        modules = {},
        functags = {},       -- canonical function-type string -> { id, key }
        functag_list = {},   -- same entries, in allocation order (for emission)
        functag_count = 0,
        bound_luas = {},     -- mangled bound-Lua-trampoline name -> { module }
        static_slots = {},   -- "fqtn.name" -> module upvalue slot of a static's closure
        record_namespace_slots = {}, -- record fqtn -> module uv slot of its static-namespace table
        lambdas = {},        -- ExpFunction nodes pending file-scope emission
        lambda_count = 0,    -- counter for unique lambda native/Lua names
        names = {},          -- { native C symbol, qualified Titan name } pairs for the trace name table
        upvalue = 0
    }

    local funcs = {}
    local initvars = {}
    local includes = {}
    local sigs = {}
    local foreignimports = {}
    local initmods = {}
    local loadmods = {}
    local loadglobals = {}
    local mprefixes = {}
    local initrecs = {}
    local code = {}
    local switch_get = {}
    local switch_set = {}
    local gvar_map = {}
    local create_meta = ""
    local moduleinit = ""

    -- Register a read-only member (an exported function or a record namespace)
    -- in the unified member map served by the module metatable. The member's
    -- value lives directly in its uv slot; `__index` pushes it, `__newindex`
    -- rejects assignment.
    local function register_readonly_member(name, slot)
        table.insert(gvar_map, render([[
            lua_pushinteger(L, $SLOT);
            lua_setfield(L, -2, $NAME);
        ]], {
            SLOT = c_integer_literal(slot),
            NAME = c_string_literal(name),
        }))
        table.insert(switch_get, render([[
            case $SLOT: {
                setobj2s(L, L->top.p - 1, &_mod->uv[$SLOT].uv);
                break;
            }
        ]], {
            SLOT = c_integer_literal(slot),
        }))
        table.insert(switch_set, render([[
            case $SLOT: {
                return luaL_error(L, "cannot assign to '%s' in Titan module '%s'", lua_tostring(L, 2), $MODSTR);
            }
        ]], {
            SLOT = c_integer_literal(slot),
            MODSTR = c_string_literal(modname),
        }))
    end

    local initctx = newcontext(tlcontext)

    allocate_upvalues(tlcontext, ast)

    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelImport" then
                import_module(loadmods, initmods, sigs, mprefixes,
                    static_deps[node.modname] ~= true, node)
            elseif tag == "Ast.TopLevelForeignImport" then
                local include
                local include_name = node.headername
                if node._include then
                    include_name = node._include.include_name
                    if node._include.include_kind == "quote" then
                        include = [[#include "$HEADERNAME"]]
                    else
                        include = [[#include <$HEADERNAME>]]
                    end
                elseif node.headername:match("^/") then
                    include = [[#include "$HEADERNAME"]]
                else
                    include = [[#include <$HEADERNAME>]]
                end
                table.insert(foreignimports, render(include, {
                    HEADERNAME = include_name
                }))
            elseif tag == "Ast.TopLevelVar" then
                codevardec(initctx, initvars, switch_get, switch_set, gvar_map, node)
            elseif tag == "Ast.TopLevelRecord" then
                coderecorddec(initctx, code, initrecs, node)
            end
        end
    end

    -- Create each record's static-namespace table (what `m.Rec` returns) and
    -- store it into the record's uv slot, BEFORE statics run so a static can be
    -- installed into the namespace it belongs to. Register the namespace in the
    -- module member map under the record's short name.
    for _, node in pairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelRecord" then
            local slot = tlcontext.record_namespace_slots[node._type.name]
            table.insert(funcs, render([[
                lua_newtable(L);
                setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                lua_pop(L, 1);
            ]], {
                SLOT = c_integer_literal(slot),
            }))
            if not node.islocal then
                register_readonly_member(node.name, slot)
            end
        end
    end

    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic" then
                codefuncdec(tlcontext, node)
                table.insert(sigs, node._sig)
                table.insert(code, node._body)
                if tag == "Ast.TopLevelFunc" and not node.islocal then
                    table.insert(code, node._luabody)
                    if node._closure_upvalue then
                        -- Build the canonical closure once into its shadow slot;
                        -- `m.f` is served from that same slot via the module
                        -- metatable, so internal references and `m.f` denote one
                        -- identity. The closure carries its function-type tag
                        -- (upvalue[1]) and native entry pointer (upvalue[2]) for
                        -- the fast call path.
                        table.insert(funcs, render([[
                            titan_pushmodule(L, _mod);
                            lua_pushlightuserdata(L, (void*)$FUNCTAG);
                            lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                            lua_pushcclosure(L, $LUANAME, 3);
                            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                            lua_pop(L, 1);
                        ]], {
                            LUANAME = func_luaname(tlcontext.module, node.name),
                            SLOT = c_integer_literal(node._closure_upvalue),
                            FUNCTAG = function_type_tag(tlcontext, node._type),
                            NATIVE = func_name(tlcontext.module, node.name),
                        }))
                        register_readonly_member(node.name, node._closure_upvalue)
                    else
                        error("BUG: exported function '" .. node.name
                              .. "' has no canonical-closure slot")
                    end
                elseif tag == "Ast.TopLevelFunc" and node.islocal
                       and node._closure_upvalue then
                    -- A referenced `local` function has no module-table entry, so
                    -- emit its Lua entry and build its canonical closure straight
                    -- into the shadow slot.
                    table.insert(code, node._luabody)
                    table.insert(funcs, render([[
                        titan_pushmodule(L, _mod);
                        lua_pushlightuserdata(L, (void*)$FUNCTAG);
                        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                        lua_pushcclosure(L, $LUANAME, 3);
                        setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                        luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                        lua_pop(L, 1);
                    ]], {
                        LUANAME = func_luaname(tlcontext.module, node.name),
                        SLOT = c_integer_literal(node._closure_upvalue),
                        FUNCTAG = function_type_tag(tlcontext, node._type),
                        NATIVE = func_name(tlcontext.module, node.name),
                    }))
                elseif tag == "Ast.TopLevelMethod" then
                    table.insert(code, node._luabody)
                    -- Emit the bound-method trampolines for every method, so a
                    -- bind site `obj:m` (here or in a module that only has this
                    -- module's `.so`) turns the method into a function value.
                    codemethodtrampoline(tlcontext, node)
                    table.insert(sigs, node._boundsig)
                    table.insert(code, node._boundbody)
                elseif tag == "Ast.TopLevelStatic" then
                    table.insert(code, node._luabody)
                    -- Build the static's canonical 3-upvalue closure once into
                    -- its shadow slot. Public statics are also installed into
                    -- the record's static-namespace table; local record functions remain
                    -- reachable to Titan code through direct/static-slot paths.
                    local closure_init
                    if node.islocal then
                        closure_init = [[
                            titan_pushmodule(L, _mod);
                            lua_pushlightuserdata(L, (void*)$FUNCTAG);
                            lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                            lua_pushcclosure(L, $LUANAME, 3);
                            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                            lua_pop(L, 1);
                        ]]
                    else
                        closure_init = [[
                            setobj2s(L, L->top.p, &_mod->uv[$RECNSSLOT].uv);
                            L->top.p++;
                            titan_pushmodule(L, _mod);
                            lua_pushlightuserdata(L, (void*)$FUNCTAG);
                            lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                            lua_pushcclosure(L, $LUANAME, 3);
                            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                            lua_setfield(L, -2, $NAMESTR);
                            lua_pop(L, 1);
                        ]]
                    end
                    table.insert(funcs, render(closure_init, {
                        RECNSSLOT = c_integer_literal(
                            tlcontext.record_namespace_slots[node._type.fqtn]),
                        LUANAME = static_luaname(node._type),
                        NAMESTR = c_string_literal(node.name),
                        SLOT = c_integer_literal(node._closure_upvalue),
                        FUNCTAG = function_type_tag(tlcontext,
                            types.Function(node._type.params, node._type.rettypes, false,
                                node._type.varargtype,
                                node._type.flexrettype)),
                        NATIVE = static_name(node._type),
                    }))
                end
            elseif tag == "Ast.StatBlock" then
                codeinitializerdec(tlcontext, node)
                table.insert(sigs, node._sig)
                table.insert(code, node._body)
                moduleinit = render([[
                    $NAME(L, _mod, NULL);
                ]], {
                    NAME = module_initializer_name(tlcontext),
                })
            else
                -- ignore other nodes in second pass
            end
        end
    end

    -- Drain pending lambdas to file scope. A lambda nested inside another lambda
    -- is registered only while the outer one's body is emitted, so re-read the
    -- length each iteration rather than snapshotting. Forward declarations go in
    -- $SIGS (ahead of every body) so any emission order resolves.
    do
        local i = 1
        while i <= #tlcontext.lambdas do
            local lnode = tlcontext.lambdas[i]
            codelambdadec(tlcontext, lnode)
            table.insert(sigs, lnode._sig)
            table.insert(code, lnode._body)
            table.insert(code, lnode._luabody)
            i = i + 1
        end
    end

    if #switch_get > 0 then
        table.insert(code, render([[
            static int __index(lua_State *L) {
                CClosure *_me = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_me->upvalue[0]);
                TValue _indexv;
                lu_byte _indextag = luaH_get(hvalue(&_me->upvalue[1]), s2v(L->ci->func.p + 2), &_indexv);
                if(TITAN_UNLIKELY(tagisempty(_indextag))) {
                    return luaL_error(L,
                        "member '%s' does not exist in Titan module '%s'",
                        lua_tostring(L, 2), $MODSTR);
                }
                switch(ivalue(&_indexv)) {
                    $SWITCH_GET
                }
                return 1;
            }

            static int __newindex(lua_State *L) {
                CClosure *_me = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_me->upvalue[0]);
                TValue *_value = s2v(L->ci->func.p + 3);
                /* _mod/_value are used only by writable-variable cases; a module
                   with only read-only members (functions/records) leaves them
                   untouched, so discard explicitly to stay warning-clean. */
                (void)_mod; (void)_value;
                TValue _indexv;
                lu_byte _indextag = luaH_get(hvalue(&_me->upvalue[1]), s2v(L->ci->func.p + 2), &_indexv);
                if(TITAN_UNLIKELY(tagisempty(_indextag))) {
                    return luaL_error(L,
                        "member '%s' does not exist in Titan module '%s'",
                        lua_tostring(L, 2), $MODSTR);
                }
                switch(ivalue(&_indexv)) {
                    $SWITCH_SET
                }
                return 1;
            }
         ]], {
             MODSTR = c_string_literal(modname),
             SWITCH_GET = table.concat(switch_get, "\n"),
             SWITCH_SET = table.concat(switch_set, "\n"),
        }))

        create_meta = render([[
            luaL_newmetatable(L, $MODMETA); /* push metatable */
            /* protect it */
            lua_pushliteral(L, $MODNAME);
            lua_setfield(L, -2, "__metatable");
            /* Map from var names to slots */
            lua_newtable(L);
            $GVARMAP
            /* Store __index in metatable */
            titan_pushmodule(L, _mod);
            lua_pushvalue(L, -2);
            lua_pushcclosure(L, __index, 2);
            lua_setfield(L, -3, "__index");
            /* Store __newindex in metatable */
            titan_pushmodule(L, _mod);
            lua_pushvalue(L, -2);
            lua_pushcclosure(L, __newindex, 2);
            lua_setfield(L, -3, "__newindex");
            /* Set metatable on the module udata */
            titan_pushmodule(L, _mod);
            lua_pushvalue(L, -3);
            lua_setmetatable(L, -2);
            /* Pop module, varmap, and metatable */
            lua_pop(L, 3);
        ]], {
            MODMETA = c_string_literal("Titan module ".. modname .. " metatable"),
            MODNAME = c_string_literal("Titan module ".. modname),
            GVARMAP = table.concat(gvar_map, "\n")
        })
    end

    local nslots = initctx.nslots

    -- A lambda or bound-method-ref initializer (codelambda/codemethodref) can
    -- relocate the Lua stack via lua_checkstack, so it recomputes `_base` from a
    -- saved offset (`_base = restorestack(L, _base_off);`). Declare `_base_off`
    -- alongside `_base` in the init-var prologue when any such initializer is
    -- present. (Both codelambda and codemethodref reserve a gc temp, so
    -- nslots > 0 whenever uses_base_off is set, and `_base` is always declared.)
    local baseoff = initctx.uses_base_off
        and "\n            ptrdiff_t _base_off = savestack(L, _base);" or ""
    if nslots > 0 then
        table.insert(initvars, 1, render([[
            lua_checkstack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
                setnilvalue(s2v(_s));
            }$BASEOFF
        ]], {
            NSLOTS = c_integer_literal(nslots),
            BASEOFF = baseoff,
        }))
        table.insert(initvars, "L->top.p = _base;")
    end

    table.insert(code, render(modtypes, {
        TYPESNAME = tlcontext.prefix .. "types",
        TYPES = string.format("%q", types.serialize(ast._type)),
    }))

    table.insert(code, render(modabi, {
        ABINAME = tlcontext.prefix .. "abi",
    }))

    init_data_from_other_modules(tlcontext, includes, loadmods, loadglobals,
        initrecs, mprefixes, static_deps)

    for _, entry in pairs(tlcontext.owned_c_metatables) do
        table.insert(initrecs, render([[
            if (luaL_newmetatable(L, $NAME)) {
                lua_pushliteral(L, "__metatable");
                lua_pushliteral(L, $DISPLAY);
                lua_settable(L, -3);
            }
            setobj2t(L, &_mod->uv[$INDEX].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            lua_pop(L, 1);
        ]], {
            NAME = c_string_literal(entry.name),
            DISPLAY = c_string_literal(entry.name),
            INDEX = c_integer_literal(entry.slot),
        }))
    end

    -- Function-type tags: a per-library `static const void*` each, declared up
    -- front (in $SIGS, ahead of any function body that references it) and set up
    -- in _init by publish-or-recover through the Lua registry so unrelated
    -- modules that mention the same function type agree on one tag pointer.
    local initfunctags = {}
    for _, entry in ipairs(tlcontext.functag_list) do
        table.insert(sigs, "static const void *" .. entry.id .. ";")
        table.insert(initfunctags, render([[
            lua_getfield(L, LUA_REGISTRYINDEX, $KEYSTR);
            if(lua_isnil(L, -1)) {
                lua_pop(L, 1);
                $ID = &$ID;
                lua_pushlightuserdata(L, (void*)$ID);
                lua_setfield(L, LUA_REGISTRYINDEX, $KEYSTR);
            } else {
                $ID = lua_topointer(L, -1);
                lua_pop(L, 1);
            }
        ]], {
            ID = entry.id,
            KEYSTR = c_string_literal("Titan function type " .. entry.key .. " tag"),
        }))
    end

    -- Trace name table (deliverable 2): map each native C symbol this module
    -- generates -> its qualified Titan source name, into the shared registry
    -- sub-table registry[TITAN_NAMES_KEY] (lazily created — multiple modules
    -- contribute). errorhandler looks each native frame's symbol up here to show
    -- the qualified name instead of the mangled C symbol.
    local initnames = ""
    if #tlcontext.names > 0 then
        local setnames = {}
        for _, pair in ipairs(tlcontext.names) do
            table.insert(setnames, render([[
                lua_pushliteral(L, $QUAL);
                lua_setfield(L, -2, $SYM);
            ]], {
                SYM = c_string_literal(pair[1]),
                QUAL = c_string_literal(pair[2]),
            }))
        end
        initnames = render([[
            lua_getfield(L, LUA_REGISTRYINDEX, $NAMESKEY);
            if(lua_isnil(L, -1)) {
                lua_pop(L, 1);
                lua_newtable(L);
                lua_pushvalue(L, -1);
                lua_setfield(L, LUA_REGISTRYINDEX, $NAMESKEY);
            }
            $SETNAMES
            lua_pop(L, 1); /* pop the names table */
        ]], {
            NAMESKEY = "TITAN_NAMES_KEY",
            SETNAMES = table.concat(setnames, "\n"),
        })
    end

    table.insert(code, render(init, {
        INITNAME = tlcontext.prefix .. 'init',
        INITMODULES = table.concat(initmods, "\n"),
        LOADMODULES1 = table.concat(loadmods, "\n"),
        LOADMODULES2 = #loadmods > 1 and table.concat(loadmods, "\n") or "",
        LOADGLOBALS = table.concat(loadglobals, "\n"),
        INITFUNCTAGS = table.concat(initfunctags, "\n"),
        INITVARS = table.concat(initvars, "\n"),
        INITRECORDS = table.concat(initrecs, "\n"),
        FUNCS = table.concat(funcs, "\n"),
        INITNAMES = initnames,
        MODNAMESTR = c_string_literal("Titan module "..modname),
        CREATEMETA = create_meta,
        MODULEINIT = moduleinit,
        NUPVALS = tlcontext.upvalue
    }))

    table.insert(code, render(postamble, {
        LUAOPEN_NAME = 'luaopen_' .. mangle_qn(modname),
        INITNAME = tlcontext.prefix .. 'init',
    }))

    local preamble = render(preamble, {
        INCLUDES = table.concat(includes, "\n"),
        SIGS = table.concat(sigs, "\n"),
        FOREIGNIMPORTS = table.concat(foreignimports, "\n"),
    })

    return preamble .. "\n\n" .. table.concat(code, "\n\n")
end

return coder
