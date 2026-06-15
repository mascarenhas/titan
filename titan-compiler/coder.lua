local types = require "titan-compiler.types"
local util  = require "titan-compiler.util"

local coder = {}

local codeexp, codestat, codeforeignexp

local render = util.render

--
-- Functions for C literals
--

-- Technically, we only need to escape the quote and backslash
-- But quoting some extra things helps readability...
local some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
}

local function c_string_literal(s)
    return '"' .. (s:gsub('.', some_c_escape_sequences)) .. '"'
end

local function c_integer_literal(n)
    return string.format("%i", n)
end

local function c_float_literal(n)
    return string.format("%f", n)
end


-- Is this expression a numeric literal?
-- If yes, return that number. If not, returns nil.
--
-- This limited form of constant-folding is enough to optimize things like for
-- loops, since most of the time the loop step is a numeric literal.
-- Note to self: A constant-folding optimization pass would obsolete this
local function node2literal(node)
    local tag = node._tag
    if tag == "Ast.ExpInteger" or tag == "Ast.ExpFloat" then
        return tonumber(node.value)
    elseif tag == "Ast.ExpUnop" and node.op == "-" then
        local lexp = node2literal(node.exp)
        return lexp and -lexp
    else
        return nil
    end
end

local function getslot(typ --[[:table]], dst --[[:string?]], src --[[:string]])
    dst = dst and dst .. " =" or ""
    local tmpl
    if typ._tag == "Type.Integer" then tmpl = "$DST ivalue($SRC)"
    elseif typ._tag == "Type.Float" then tmpl = "$DST fltvalue($SRC)"
    elseif typ._tag == "Type.Boolean" then tmpl = "$DST ttistrue($SRC)"
    elseif typ._tag == "Type.Nil" then tmpl = "$DST 0"
    elseif typ._tag == "Type.String" then tmpl = "$DST tsvalue($SRC)"
    elseif typ._tag == "Type.Array" then tmpl = "$DST hvalue($SRC)"
    elseif typ._tag == "Type.Map" then tmpl = "$DST hvalue($SRC)"
    elseif typ._tag == "Type.Value" then tmpl = "$DST *($SRC)"
    elseif typ._tag == "Type.Nominal" then tmpl = "$DST clCvalue($SRC)"
    elseif typ._tag == "Type.Option" then tmpl = "$DST *($SRC)"
    else error("invalid type " .. types.tostring(typ)) end
    return render(tmpl, { DST = dst, SRC = src })
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
    else error("invalid type " .. types.tostring(typ)) end
    return render(tmpl, { SRC = src })
end

-- Get the next local state slot for this module
local function nextupvalue(tlcontext)
    tlcontext.upvalue = tlcontext.upvalue + 1
    return tlcontext.upvalue
end

local function mangle_qn(qualname)
    return qualname:gsub("[%-.]", "_")
end

local function tagname(fqtn)
    return mangle_qn(fqtn) .. "_typetag"
end

local function fname_prefix(typ)
    return mangle_qn(typ.fqtn) .. "_" .. typ.name
end

local function static_name(typ)
    return fname_prefix(typ) .. "_titanstatic"
end

local function static_luaname(typ)
    return fname_prefix(typ) .. "_luastatic"
end

local function method_name(typ)
    return fname_prefix(typ) .. "_titanmethod"
end

local function method_luaname(typ)
    return fname_prefix(typ) .. "_luamethod"
end

local function modprefix(modname)
    return mangle_qn(modname) .. "_"
end

local function func_name(modname, name)
    return modprefix(modname) .. name .. "_titan"
end

local function func_luaname(modname, name)
    return modprefix(modname) .. name .. "_lua"
end

local function var_name(modname, name)
    return modprefix(modname) .. name .. "_titanvar"
end

-- get name of the variable holding the tag for this type
local function type2tagname(ctx, typ --[[:table]])
    local mod, name = typ.fqtn:match("^(.*)%.(%a+)$")
    local mangled = tagname(typ.fqtn)
    if mod == ctx.module then
        -- local tag
        return mangled
    else
        -- imported tag
        ctx.tags[typ.fqtn] = { module = mod, type = name, mangled = mangled }
        return mangled
    end
end

-- get name of the variable holding the metatable for this type
local function type2metatable(ctx, typ --[[:table]])
    if not ctx.metatables[typ.fqtn] then
        ctx.metatables[typ.fqtn] = nextupvalue(ctx.tlcontext)
    end
    return ctx.metatables[typ.fqtn]
end

local checkandset

local function codethrow(ctx, template, params)
    return render([[
        luaL_error(L, "$TEMPLATE", $PARAMS);
    ]], {
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
            THROWFLOAT = codethrow(ctx, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINTEGER = codethrow(ctx, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
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
            THROW = codethrow(ctx, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
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
              void *_tag = *((void**)(getudatamem(_ud)));
              if (TITAN_LIKELY($TAG == _tag)) {
                $VAR = clCvalue(&_ud->uv[0].uv);
              } else {
                lua_pushlightuserdata(L, _tag);
                if(lua_rawget(L, LUA_REGISTRYINDEX) == LUA_TNIL) {
                    setuvalue(L, s2v(L->top.p), _ud);
                    $THROWNIL
                } else {
                    $THROWUD
                }
              }
            } else {
              $THROWPRIM
            }
        ]], {
            TAG = type2tagname(ctx, typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            EXP = exp,
            VAR = cvar,
            NAME = types.tostring(typ),
            THROWNIL = codethrow(ctx, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "luaL_tolstring(L, -1, NULL)" }),
            THROWUD = codethrow(ctx, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "lua_tostring(L, -1)" }),
            THROWPRIM = codethrow(ctx, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "lua_typename(L, ttype($EXP))" })
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
        THROW = codethrow(ctx, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", "$TAG", "lua_typename(L, ttype($EXP))" })
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
            THROWFLOAT = codethrow(ctx, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINT = codethrow(ctx, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($SRC))" })
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
            THROW = codethrow(ctx, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($SRC))" })
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
              CClosure *_cl = NULL;
              $CHECKANDGET
              setclCvalue(L, $DST, _cl);
            }
        ]], {
            CHECKANDGET = checkandget(ctx, typ, "_cl", src, loc),
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
        THROW = codethrow(ctx, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", "$TAG", "lua_typename(L, ttype($SRC))" })
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
    elseif typ._tag == "Type.Value" then tmpl = "setobj2t(L, $DST, &$SRC);"
    elseif typ._tag == "Type.Nominal" then tmpl = "setclCvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Option" then tmpl = "setobj2t(L, $DST, &$SRC);"
    else
        error("invalid type " .. types.tostring(typ))
    end
    local code = render(tmpl, { DST = dst, SRC = src })
    return code
end

local function setwrapped(typ --[[:table]], dst --[[:string]], src --[[:string]])
    if typ._tag == "Type.Nominal" then
        return render([[
            setobj2t(L, $DST, &(($SRC)->upvalue[0]));
        ]], {
            DST = dst,
            SRC = src
        })
    elseif typ._tag == "Type.Option" and typ.base._tag == "Type.Nominal" then
        return render([[
            if(ttisnil(&$SRC)) {
                setnilvalue($DST);
            } else {
                setobj2t(L, $DST, &(clCvalue(&$SRC)->upvalue[0]));
            }
        ]], {
            DST = dst,
            SRC = src
        })
    else
        return setslot(typ, dst, src)
    end
end

local function copyslotwrapped(typ, dst, src)
    if typ._tag == "Type.Nominal" then
        return render([[
            setobj2t(L, $DST, &(clCvalue($SRC)->upvalue[0]));
        ]], {
            DST = dst,
            SRC = src
        })
    elseif typ._tag == "Type.Option" and typ.base._tag == "Type.Nominal" then
        return render([[
            if(ttisnil($SRC)) {
                setnilvalue($DST);
            } else {
                setobj2t(L, $DST, &(clCvalue($SRC)->upvalue[0]));
            }
        ]], {
            DST = dst,
            SRC = src
        })
    else
        return render([[
            setobj2t(L, $DST, $SRC);
        ]], {
            DST = dst,
            SRC = src
        })
    end
end

local function foreignctype(typ --[[:table]])
    if typ._tag == "Type.Pointer" then
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
    elseif typ._tag == "Type.Nominal" then return "CClosure*"
    elseif typ._tag == "Type.Pointer" then return foreignctype(typ)
    elseif typ._tag == "Type.Option" then return "TValue"
    -- A foreign typedef of a supported scalar (e.g. size_t -> integer) can
    -- leak in via inference; use the C type of its resolved underlying type.
    elseif typ._tag == "Type.Typedef" then return ctype(typ._type)
    else error("invalid type " .. types.tostring(typ))
    end
end

local function initval(typ --[[:table]])
    if typ._tag == "Type.Value" or typ._tag == "Type.Option" then return "{ {0}, 0 }"
    else return "0" end
end


local function function_sig(fname, ftype, is_pointer)
    local params = { "lua_State *L", "CClosure *_mod" }
    if ftype._tag == "Type.Method" then
        table.insert(params, "CClosure*")
    end
    for i, ptype in ipairs(ftype.params) do
        table.insert(params, ctype(ptype))
    end
    for i = 2, #ftype.rettypes do
        table.insert(params, ctype(ftype.rettypes[i]) .. "*")
    end
    local rettype = ftype.rettypes[1]
    local template = is_pointer
                     and "$RETTYPE (*$FNAME)($PARAMS)"
                     or  "$RETTYPE $FNAME($PARAMS)"
    return render(template, {
        RETTYPE = ctype(rettype),
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
        tags = tlcontext.tags,             -- set of external record types that we need tags of
        metatables = tlcontext.metatables, -- set of record metatables that we need
        functions = tlcontext.functions, -- set of external functions and methods that we call
        variables = tlcontext.variables, -- set of external variables that we use
        module = tlcontext.module, -- module name,
        modules = tlcontext.modules, -- set of record metatables that we need
        tlcontext = tlcontext -- toplevel context
    }
end

local function newslot(ctx --[[:table]], name --[[:string]])
    local sdepth = ctx.depth
    ctx.depth = ctx.depth + 1
    ctx.allocations = ctx.allocations + 1
    if ctx.depth > ctx.nslots then ctx.nslots = ctx.depth end
    return render([[
        TValue *$NAME = s2v(_base + $SDEPTH);
    ]], {
        NAME = name,
        SDEPTH = c_integer_literal(sdepth),
    })
end

local function newtmp(ctx --[[:table]], typ --[[:table]], isgc --[[:boolean]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    if isgc then
        local slotname = "_tmp_" .. tmp .. "_slot"
        return render([[
            $NEWSLOT
            $TYPE $TMPNAME = $INIT;
        ]], {
            TYPE = ctype(typ),
            NEWSLOT = newslot(ctx, slotname),
            TMPNAME = tmpname,
            INIT = initval(typ)
        }), tmpname, slotname
    else
        return render([[
            $TYPE $TMPNAME = $INIT;
        ]], {
            TYPE = ctype(typ),
            TMPNAME = tmpname,
            INIT = initval(typ)
        }), tmpname
    end
end

local function newforeigntmp(ctx --[[:table]], typ --[[:table]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local ftype
    if typ._tag == "Type.String" then
        ftype = "char*"
    elseif typ._tag == "Type.Pointer" then
        ftype = foreignctype(typ)
    else
        error("don't know how to convert foreign type "..types.tostring(typ))
    end
    return render([[
        $TYPE $TMPNAME;
    ]], {
        TYPE = ftype,
        TMPNAME = tmpname,
    }), tmpname
end

local function pushd(ctx)
    table.insert(ctx.dstack, ctx.depth)
end

local function popd(ctx)
    ctx.depth = table.remove(ctx.dstack)
end

-- All the code generation functions for STATEMENTS take
-- the function context and the AST node and return the
-- generated C code for the statement, as a string

local function codeblock(ctx, node)
    local stats = {}
    pushd(ctx)
    for _, stat in ipairs(node.stats) do
        table.insert(stats, codestat(ctx, stat))
    end
    popd(ctx)
    return " {\n " .. table.concat(stats, "\n ") .. "\n }"
end

local function codewhile(ctx, node)
    pushd(ctx)
    local nallocs = ctx.allocations
    local cstats, cexp = codeexp(ctx, node.condition, true)
    local cblk = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    popd(ctx)
    local tmpl
    if cstats == "" then
        tmpl = [[
            while($CEXP) {
                $CBLK
                $CHECKGC
            }
        ]]
    else
        tmpl = [[
            while(1) {
                $CSTATS
                if(!($CEXP)) {
                    break;
                }
                $CBLK
                $CHECKGC
            }
        ]]
    end
    return render(tmpl, {
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CBLK = cblk,
        CHECKGC = nallocs > 0 and "luaC_checkGC(L);" or ""
    })
end

local function coderepeat(ctx, node)
    pushd(ctx)
    local nallocs = ctx.allocations
    -- In Lua the `until` condition is in the scope of the body, so it may
    -- reference body-local variables. Code the body's statements INLINE (not
    -- wrapped in a nested C block) and then the condition, so both share one
    -- C scope and the body locals' C names are bound and still visible.
    local stats = {}
    for _, stat in ipairs(node.block.stats) do
        table.insert(stats, codestat(ctx, stat))
    end
    local cblk = table.concat(stats, "\n")
    local cstats, cexp = codeexp(ctx, node.condition, true)
    nallocs = ctx.allocations - nallocs
    popd(ctx)
    return render([[
        while(1) {
            $CBLK
            $CSTATS
            if($CEXP) {
                break;
            }
            $CHECKGC
        }
    ]], {
        CBLK = cblk,
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CHECKGC = nallocs > 0 and "luaC_checkGC(L);" or ""
    })
end

local function codeif(ctx, node, idx)
    idx = idx or 1
    local cstats, cexp, cthn, cels
    if idx == #node.thens then -- last condition
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        cels = node.elsestat and "else " .. codestat(ctx, node.elsestat):match("^[ \t]*(.*)") or ""
    else
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        cels = "else " .. codeif(ctx, node, idx + 1):match("^[ \t]*(.*)")
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
    node.decl._cvar = "_local_" .. node.decl.name
    local csstats, csexp = codeexp(ctx, node.start)
    local cfstats, cfexp = codeexp(ctx, node.finish)
    local cistats, ciexp = codeexp(ctx, node.inc)
    local nallocs = ctx.allocations
    local cblock = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    popd(ctx)
    -- Lua-faithful numeric for (see lvm.c forprep/forloop/floatforloop):
    -- a zero step raises a run-time error; the integer loop is driven by an
    -- unsigned iteration count so it cannot overflow past the integer limits
    -- into a non-terminating loop; and the visible control variable is a
    -- fresh copy each iteration (a separate internal index advances), so it
    -- is independent of the iteration and read-only.
    local cvtyp = node.decl._type._tag == "Type.Integer" and "lua_Integer" or "lua_Number"
    local subs = {
        CVAR = node.decl._cvar,
        -- declare the visible control variable only if the body uses it
        CVARDECL = node.decl._used
            and (cvtyp .. " " .. node.decl._cvar .. " = _foridx;") or "",
        CSSTATS = csstats, CSEXP = csexp,
        CFSTATS = cfstats, CFEXP = cfexp,
        CISTATS = cistats, CIEXP = ciexp,
        CBLOCK = cblock,
        CHECKGC = nallocs > 0 and "luaC_checkGC(L);" or "",
        FILE = c_string_literal(node.loc.filename),
        LINE = node.loc.line,
        COL = node.loc.col,
        STEP0 = codethrow(ctx, "%s:%d:%d: 'for' step is zero",
                          { "$FILE", "$LINE", "$COL" }),
    }
    if node.decl._type._tag == "Type.Integer" then
        return render([[
            {
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
            }
        ]], subs)
    else
        return render([[
            {
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
            }
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

local function codeassignment(ctx, var, cexp, etype)
    local vtag = var._tag
    if vtag == "Ast.VarName" or (vtag == "Ast.VarDot" and var._decl) then
        if vtag == "Ast.VarDot" and var._decl._tag == "Type.Field" then
            local lstats, lexp = codeexp(ctx, var.exp)
            local index = var._decl.index
            return render([[
                $STATS
                {
                    CClosure *_recobj = $RECORD;
                    TValue *_fieldslot = &(_recobj->upvalue[$INDEX]);
                    $SETSLOT
                    $BARRIER
                }
            ]], {
                STATS = lstats,
                RECORD = lexp,
                INDEX = index,
                SETSLOT = setslot(var._type, "_fieldslot", cexp),
                BARRIER = types.is_gc(var._type)
                          and "luaC_barrier(L, _recobj, _fieldslot);" or ""
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
                    CClosure *_imod = clCvalue(&_mod->upvalue[$MODINDEX]);
                    TValue *_varslot = &_imod->upvalue[$VARINDEX];
                    $SETSLOT;
                    $BARRIER
                }
            ]], {
                SETSLOT = setslot(var._type, "_varslot", cexp),
                BARRIER = types.is_gc(var._type)
                          and "luaC_barrier(L, _imod, _varslot);" or "",
                MODINDEX = c_integer_literal(var.exp.var._decl._upvalue),
                VARINDEX = c_integer_literal(var._decl._upvalue)
            })
        elseif var._decl._tag == "Ast.TopLevelVar" then
            local cset = setslot(var._type, var._decl._slot, cexp)
            if types.is_gc(var._type) then
                cset = cset .. "\nluaC_barrier(L, _mod, " .. var._decl._slot .. ");"
            end
            return cset
        elseif var._decl._used and cexp ~= var._decl._cvar then
            local cset = ""
            if types.is_gc(var._type) then
                cset = setslot(var._type, var._decl._slot, var._decl._cvar)
            end
            return render([[
                $CVAR = $CEXP;
                $CSET
            ]], {
                CVAR = var._decl._cvar,
                CEXP = cexp,
                CSET = cset,
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
        end
    else
        error("invalid tag for lvalue of assignment: " .. vtag)
    end
end

local function codesingleassignment(ctx, node)
    local var = node.vars[1]
    local exp = node.exps[1]
    local cstats, cexp = codeexp(ctx, exp, false, var._decl)
    return cstats .. "\n" .. codeassignment(ctx, var, cexp, exp._type)
end

local function codemultiassignment(ctx, node)
    local stats = {}
    local tmps = {}
    for i, exp in ipairs(node.exps) do
        local var = node.vars[i]
        local vtag = var and var._tag
        if var then
            local typ = exp._type
            local ctmp, tmpname = newtmp(ctx, typ)
            tmps[i] = tmpname
            local cstats, cexp = codeexp(ctx, exp)
            table.insert(stats, render([[
                $CTMP
                $CSTATS
                $TMPNAME = $CEXP;
            ]], {
                CTMP = ctmp,
                CSTATS = cstats,
                TMPNAME = tmpname,
                CEXP = cexp
            }))
        end
    end
    for i, var in ipairs(node.vars) do
        if tmps[i] then table.insert(stats, codeassignment(ctx, var, tmps[i], node.exps[i]._type)) end
    end
    return table.concat(stats, "\n")
end

local function makestring(ctx, cexp, target)
    local cstr = render("luaS_new(L, $VALUE)", {
        VALUE = cexp
    })
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

local function nativetoforeignexp(ctx, exp, cexp)
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

    error("don't know how to handle type "..types.tostring(exp._type))
end

local function foreigntonativeexp(ctx, exp, cexp, target)
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

local function codeforeigncall(ctx, node)
    -- TODO catch name conflicts among imports
    local cfuncname = node.exp.var.name
    local caexps = {}
    local castats = {}
    for _, arg in ipairs(node.args.args) do
        local cstat, cexp = codeforeignexp(ctx, arg)
        table.insert(castats, cstat)
        table.insert(caexps, cexp)
    end
    local cstats = table.concat(castats, "\n")
    local ccall = render("$NAME($CAEXPS)", {
        NAME = cfuncname,
        CAEXPS = table.concat(caexps, ", "),
    })
    return cstats, ccall
end

local function codeforeignvar(ctx, node)
    return "", node.name
end

local function codecall(ctx, node)
    local castats, caexps, tmpnames, retslots = {}, { "L" }, {}, {}
    local fname
    local fnode = node.exp.var
    local modarg = "_mod"
    if node.args._tag == "Ast.ArgsFunc" then
        if fnode._tag == "Ast.VarName" then
            fname = func_name(ctx.module, fnode.name)
        elseif fnode._tag == "Ast.VarDot" then
            if fnode.exp._type._tag == "Type.ForeignModule" then
                return codeforeigncall(ctx, node)
            elseif fnode._decl._tag == "Type.StaticMethod" then
                fname = static_name(fnode._decl)
                local mod, record = fnode._decl.fqtn:match("^(.*)%.(%a+)$")
                if mod ~= ctx.module then
                    assert(fnode.exp.var._tag == "Ast.VarDot")
                    ctx.functions[fnode._decl.fqtn .. "." .. fnode._decl.name] = {
                        module = mod,
                        record = record,
                        type = fnode._decl,
                        name = fnode._decl.name,
                        mangled = fname
                    }
                    modarg = render("clCvalue(&_mod->upvalue[$INDEX])", {
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
                modarg = render("clCvalue(&_mod->upvalue[$INDEX])", {
                    INDEX = c_integer_literal(fnode.exp.var._decl._upvalue)
                })
            end
        end
        table.insert(caexps, modarg)
    else
        assert(node.args._tag == "Ast.ArgsMethod")
        local mtype = node._method
        fname = method_name(mtype)
        local mod, record = mtype.fqtn:match("^(.*)%.(%a+)$")
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
            modarg = render("clCvalue(&_mod->upvalue[$INDEX])", {
                INDEX = c_integer_literal(ctx.modules[mod])
            })
        end
        local cstat, cexp = codeexp(ctx, node.exp)
        table.insert(castats, cstat)
        table.insert(caexps, modarg)
        table.insert(caexps, cexp)
    end
    for _, arg in ipairs(node.args.args) do
        local cstat, cexp = codeexp(ctx, arg)
        table.insert(castats, cstat)
        if arg._tag == "Ast.ExpCall" and arg._extras then
            -- A multi-return call expanded in this argument list: force it to
            -- run now (into a temp), filling its out-param temps, before the
            -- ExpExtra arguments that read those temps are evaluated -- C does
            -- not specify the evaluation order of a call's arguments.
            local ctmp, tmpname = newtmp(ctx, arg._type)
            table.insert(castats, render([[
                $CTMP
                $TMPNAME = $CEXP;
            ]], { CTMP = ctmp, TMPNAME = tmpname, CEXP = cexp }))
            cexp = tmpname
        end
        table.insert(caexps, cexp)
    end
    for i = 2, #node._types do
        node._extras = node._extras or {}
        local typ = node._types[i]
        local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
        node._extras[i] = tmpname
        tmpnames[i] = tmpname
        table.insert(castats, ctmp)
        table.insert(caexps, "&" .. tmpname)
        retslots[i] = tmpslot
    end
    local cstats = table.concat(castats, "\n")
    local ccall = render("$NAME($CAEXPS)", {
        NAME = fname,
        CAEXPS = table.concat(caexps, ", "),
    })
    if util.any(types.is_gc, node._types) then
        local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
        tmpnames[1] = tmpname
        retslots[1] = tmpslot
        local cslots = {}
        for i, typ in ipairs(node._types) do
            if types.is_gc(typ) then
                table.insert(cslots, setslot(typ, retslots[i], tmpnames[i]) .. ";")
            end
        end
        return render([[
            $CSTATS
            $CTMP
            $TMPNAME = $CCALL;
            $SLOTS
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            TMPNAME = tmpname,
            CCALL = ccall,
            SLOTS = table.concat(cslots, "\n"),
        }), tmpname
    else
        return cstats, ccall
    end
end

local function codereturn(ctx, node)
    local cs, cexp = codeexp(ctx, node.exps[1])
    local cstats = { cs }
    if #node.exps > 1 then
        -- The first return expression may itself be a bare multi-return
        -- call whose 2..n values are produced through out-param temps that
        -- the ExpExtra nodes below read back. Evaluate it into a temp NOW so
        -- the call actually executes (and fills those out-param temps)
        -- before we copy them into our own *_outparam_i. Otherwise the call
        -- would be deferred into the trailing 'return $CEXP' and the extra
        -- values would be read uninitialized.
        local ctmp, tmpname = newtmp(ctx, node.exps[1]._type)
        table.insert(cstats, render([[
            $CTMP
            $TMPNAME = $CEXP;
        ]], {
            CTMP = ctmp,
            TMPNAME = tmpname,
            CEXP = cexp,
        }))
        cexp = tmpname
    end
    for i = 2, #node.exps do
        local cs, ce = codeexp(ctx, node.exps[i])
        table.insert(cstats, cs)
        table.insert(cstats, "*_outparam_" .. i .. " = " .. ce .. ";")
    end
    -- Always reset the stack top to _base on return. Whether the function
    -- ends up reserving slots is not known when an early return is coded
    -- (a later statement can bump ctx.nslots), and the preamble always
    -- declares _base, so an unconditional reset keeps every return path
    -- consistent with the preamble (otherwise an early return could leave
    -- L->top.p one or more slots too high).
    return render([[
        $CSTATS
        L->top.p = _base;
        return $CEXP;
    ]], {
        CSTATS = table.concat(cstats, "\n"),
        CEXP = cexp,
    })
end

local function localname(ctx, name)
    local idx = ctx.names[name] or 1
    ctx.names[name] = idx + 1
    return name .. "_" .. tostring(idx)
end

function codestat(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatDecl" then
        local code = {}
        for i = 1, #node.decls do
            local exp = node.exps[i]
            local decl = node.decls[i]
            local cstats, cexp = codeexp(ctx, exp)
            if decl._used then
                local typ = decl._type
                decl._cvar = "_local_" .. localname(ctx, decl.name)
                local cdecl = ctype(typ) .. " " .. decl._cvar .. ";"
                local cslot = ""
                local cset = ""
                if types.is_gc(typ) then
                    decl._slot = "_localslot_" .. localname(ctx, decl.name)
                    cslot = newslot(ctx, decl._slot);
                    cset = render([[
                        /* update slot */
                        $SETSLOT
                    ]], {
                        SETSLOT = setslot(typ, decl._slot, decl._cvar),
                    })
                end
                table.insert(code, render([[
                    $CDECL
                    $CSLOT
                    $CSTATS
                    $CVAR = $CEXP;
                    $CSET
                ]], {
                    CDECL = cdecl,
                    CSLOT = cslot,
                    CSTATS = cstats,
                    CVAR = decl._cvar,
                    CEXP = cexp,
                    CSET = cset
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
    elseif tag == "Ast.StatAssign" then
        if #node.vars == 1 then
            return codesingleassignment(ctx, node)
        else
            return codemultiassignment(ctx, node)
        end
    elseif tag == "Ast.StatCall" then
        if node.callexp.exp.var._tag == "Ast.VarDot"
           and node.callexp.exp.var.exp._type._tag == "Type.ForeignModule" then
            local fstats, fexp = codeforeigncall(ctx, node.callexp)
            return fstats .. fexp .. ";"
        else
            local cstats, cexp = codecall(ctx, node.callexp)
            return cstats .. "\n    " .. cexp .. ";"
        end
    elseif tag == "Ast.StatReturn" then
        return codereturn(ctx, node)
    elseif tag == "Ast.StatBreak" then
        return "break;"
    else
        error("invalid node tag " .. tag)
    end
end

-- All the code generation functions for EXPRESSIONS return
-- preliminary C code necessary for computing the expression
-- as a string of C statements, plus the code for the expression
-- as a string with a C expression. For trivial expressions
-- the preliminary code is always the empty string

local function codevar(ctx, node)
    if node._tag == "Ast.VarDot" then
        if node._decl._tag == "Type.Field" then
            local cstats, cexp = codeexp(ctx, node.exp)
            return cstats,
                getslot(node._type, nil, render("&(($EXP)->upvalue[$INDEX])", {
                    EXP = cexp,
                    INDEX = node._decl.index
                }))
        else
            assert(node._decl._tag == "Type.ModuleVariable")
            ctx.variables[node.exp.var.name .. "." .. node.name] = {
                module = node.exp.var.name,
                name = node.name,
                slot = node._decl._slot
            }
            local slot = render("&(clCvalue(&_mod->upvalue[$MODINDEX])->upvalue[$VARINDEX])", {
                MODINDEX = c_integer_literal(node.exp.var._decl._upvalue),
                VARINDEX = c_integer_literal(node._decl._upvalue)
            })
            return "", getslot(node._type, nil, slot)
        end
    elseif node._decl._tag == "Ast.TopLevelVar" then
        return "", getslot(node._type, nil, node._decl._slot)
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
        return makestring(ctx, c_string_literal(node.value), target)
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
    local slots = {}
    for _, field in ipairs(node.fields) do
        local exp = field.exp
        local cstats, cexp = codeexp(ctx, exp)
        local ctmpe, tmpename, tmpeslot = newtmp(ctx, node._type.elem, true)

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
            SETSLOT = setwrapped(node._type.elem, tmpeslot, tmpename),
        })

        table.insert(slots, tmpeslot)
        table.insert(stats, code)
    end
    if #node.fields > 0 then
        table.insert(stats, render([[
            luaH_resizearray(L, $TMPNAME, $SIZE);
        ]], {
            TMPNAME = tmpname,
            SIZE = #node.fields
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
        if types.is_gc(node._type.elem) then
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
    cinit = render([[
        $CTMP
        $TMPNAME = luaF_newCclosure(L, $NFIELDS);
        memset($TMPNAME->upvalue, 0, sizeof(TValue) * $NFIELDS);
        setclCvalue(L, $TMPSLOT, $TMPNAME);
        {
            Udata* _ud = luaS_newudata(L, sizeof(void*), 1);
            *((void**)(getudatamem(_ud))) = (void*)$TAG;
            _ud->metatable = hvalue(&_mod->upvalue[$META]);
            setclCvalue(L, &_ud->uv[0].uv, $TMPNAME);
            setuvalue(L, &($TMPNAME->upvalue[0]), _ud);
            /* an emergency GC inside luaS_newudata can blacken the
               closure, so this store needs a forward barrier */
            luaC_barrier(L, $TMPNAME, &($TMPNAME->upvalue[0]));
        }
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        NFIELDS = #record.fields + 1,
        TAG = type2tagname(ctx, node._type),
        META = c_integer_literal(type2metatable(ctx, node._type))
    })
    table.insert(stats, cinit)
    local slots = {}
    for _, field in ipairs(node.fields) do
        local exp = field.exp
        local cstats, cexp = codeexp(ctx, exp)
        local ctmpe, tmpename, tmpeslot = newtmp(ctx, field._field.type, true)
        local code = render([[
            $CSTATS
            $CTMPE
            $TMPENAME = $CEXP;
            $SETSLOT;
            setobj2t(L, &($RECORD->upvalue[$INDEX]), $SLOT);
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
                luaC_barrier(L, $TMPNAME, $SLOT);
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
        if node.exp._type._tag == "Type.Array" then
            return estats, "luaH_getn(L, " .. ecode .. ")"
        else
            return estats, "tsslen(" .. ecode .. ")"
        end
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
local function generate_binop_shift(shift_pos, shift_neg, exp, ctx)
    local x_stats, x_var = codeexp(ctx, exp.lhs)
    local y_stats, y_var = codeexp(ctx, exp.rhs)
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${X_STATS}
        ${Y_STATS}
        ${R_DECL}
        if (TITAN_LIKELY(l_castS2U(${Y}) < TITAN_LUAINTEGER_NBITS)) {
            ${R} = intop(${SHIFT_POS}, ${X}, ${Y});
        } else {
            if (l_castS2U(-${Y}) < TITAN_LUAINTEGER_NBITS) {
                ${R} = intop(${SHIFT_NEG}, ${X}, -${Y});
            } else {
                ${R} = 0;
            }
        }
    ]], {
        SHIFT_POS = shift_pos,
        SHIFT_NEG = shift_neg,
        X = x_var,
        X_STATS = x_stats,
        Y = y_var,
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
    local m_stats, m_var = codeexp(ctx, exp.lhs)
    local n_stats, n_var = codeexp(ctx, exp.rhs)
    local qdecl, qname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${M_STATS}
        ${N_STATS}
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
        M_STATS = m_stats,
        N = n_var,
        N_STATS = n_stats,
        Q = qname,
        Q_DECL = qdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_DIV0 = codethrow(ctx, "error at line %d, divide by zero", { "$LINE" })
    })
    return cstats, qname
end

-- see luai_numidiv
local function generate_binop_idiv_flt(exp, ctx)
    local x_stats, x_var = codeexp(ctx, exp.lhs)
    local y_stats, y_var = codeexp(ctx, exp.rhs)
    local rdecl, rname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${X_STATS}
        ${Y_STATS}
        ${R_DECL}
        ${R_NAME} = floor(${X} / ${Y});
    ]], {
        X = x_var,
        X_STATS = x_stats,
        Y = y_var,
        Y_STATS = y_stats,
        R_DECL = rdecl,
        R_NAME = rname,
    })
    return cstats, rname
end

-- Lua/Titan guarantees that (m == n*(m//n) + (,%n))
-- See generate binop_intdiv and luaV_mod
local function generate_binop_mod_int(exp, ctx)
    local m_stats, m_var = codeexp(ctx, exp.lhs)
    local n_stats, n_var = codeexp(ctx, exp.rhs)
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${M_STATS}
        ${N_STATS}
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
        M_STATS = m_stats,
        N = n_var,
        N_STATS = n_stats,
        R = rname,
        R_DECL = rdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_MOD0 = codethrow(ctx, "error at line %d, % by zero", { "$LINE" })
    })
    return cstats, rname
end

-- Float modulo, faithful to Lua's luai_nummod (see lvm.c/llimits.h):
--   m = fmod(a, b); if ((m>0) ? b<0 : (m<0 && b!=0)) m += b;
-- This differs from C's fmod for operands of opposite sign, where Lua
-- (like floored division) returns a result with the sign of the divisor.
local function generate_binop_mod_flt(exp, ctx)
    local m_stats, m_var = codeexp(ctx, exp.lhs)
    local n_stats, n_var = codeexp(ctx, exp.rhs)
    local bdecl, bname = newtmp(ctx, types.Float())
    local rdecl, rname = newtmp(ctx, types.Float())
    local cstats = util.render([[
        ${M_STATS}
        ${N_STATS}
        ${B_DECL};
        ${R_DECL};
        ${B} = ${N};
        ${R} = fmod(${M}, ${B});
        if (((${R}) > 0) ? ((${B}) < 0) : (((${R}) < 0) && ((${B}) > 0))) {
            ${R} += ${B};
        }
    ]], {
        M = m_var,
        M_STATS = m_stats,
        N = n_var,
        N_STATS = n_stats,
        B = bname,
        B_DECL = bdecl,
        R = rname,
        R_DECL = rdecl,
    })
    return cstats, rname
end

local function codebinaryop(ctx, node, iscondition)
    local op = node.op
    if op == "~=" then op = "!=" end
    if op == "and" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = codeexp(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. rstats, "(" .. lcode .. " && " .. rcode .. ")"
        elseif types.is_truthy(node.lhs._type) then
            local rstats, rcode = codeexp(ctx, node.rhs)
            return rstats, rcode
        elseif types.is_falsy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        else
            local lstats, lcode = codeexp(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            -- Materialize the lhs into a temp of its own type so the
            -- truthiness test works for any lhs (boolean C value, a
            -- comparison rvalue, an option, a value) — never &<rawCode>.
            local lctmp, lcname = newtmp(ctx, node.lhs._type)
            local code = render([[
                $LSTATS
                $LCTMP
                $LCNAME = $LCODE;
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
                LCTMP = lctmp,
                LCNAME = lcname,
                COND = toboolean(node.lhs._type, lcname),
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
            })
            return code, tmpname
        end
    elseif op == "or" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = codeexp(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. rstats, "(" .. lcode .. " || " .. rcode .. ")"
        elseif types.is_truthy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        elseif types.is_falsy(node.lhs._type) then
            local rstats, rcode = codeexp(ctx, node.rhs)
            return rstats, rcode
        elseif node.lhs._type._tag == "Type.Option" then
            assert(types.equals(node.lhs._type.base, node.rhs._type))
            local lstats, lcode = codeexp(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            -- Materialize the option lhs into a TValue temp ONCE: the lhs may
            -- be a non-lvalue (e.g. a direct call returning t?), and it must
            -- be evaluated exactly once, not in both the test and the extract.
            local lctmp, lcname = newtmp(ctx, node.lhs._type)
            local code = render([[
                $LSTATS
                $LCTMP
                $LCNAME = $LCODE;
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
                LCTMP = lctmp,
                LCNAME = lcname,
                COND = toboolean(node.lhs._type, lcname),
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
                GETL = getslot(node._type, tmpname, "&" .. lcname),
            })
            return code, tmpname
        else
            assert(node._type._tag == "Type.Value")
            local lstats, lcode = codeexp(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
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
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        return lstats .. rstats, "pow(" .. lcode .. ", " .. rcode .. ")"
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
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        local cstats = lstats .. rstats
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
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        if op == "!=" then
            return lstats .. rstats, "!luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        else
            return lstats .. rstats, "luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        end
    else
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        return lstats .. rstats, "(" .. lcode .. op .. rcode .. ")"
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

-- Generate code for expression 'node'
-- 'iscondition' is 'true' if expression is used not for value but for
--    controlling conditinal execution
-- 'target' is not nil if expression is rvalue for a 'Ast.VarName' lvalue,
--    in this case it will be the '_decl' of the lvalue
function codeexp(ctx, node, iscondition, target)
    local tag = node._tag
    if tag == "Ast.VarDot" and node.exp._type._tag == "Type.ForeignModule" then
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
        return codeexp(ctx, node.var, iscondition)
    elseif tag == "Ast.ExpUnop" then
        return codeunaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpBinop" then
        return codebinaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._tag == "Ast.VarDot"
           and node.exp.var.exp._type._tag == "Type.ForeignModule" then
        local fstats, fexp = codeforeigncall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" then
        return codecall(ctx, node, target)
    elseif tag == "Ast.ExpExtra" then
        return "", node.exp._extras[node.index]
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
            THROW_WRONG_INT = codethrow(ctx, "type error at line %d, number '%f' has no integer representation", { "$LINE", "$TMPNAME1" })
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
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CTMP
            setnilvalue(&$TMPNAME);
        ]], {
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
            THROW_WRONG_CAST = codethrow(ctx, "%s:%d:%d: type error, expected %s but found nil", { "$FILE", "$LINE", "$COL", "$TYPENAME" })
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
        return codeexp(ctx, node.exp, iscondition, target)
    else
        error("invalid node tag " .. tag)
    end
end

function codeforeignexp(ctx, node)
    local tag = node._tag
    if tag == "Ast.ExpCall"
           and node.exp.var._tag == "Ast.VarDot"
           and node.exp.var.exp._type._tag == "Type.ForeignModule" then
        return codeforeigncall(ctx, node)
    elseif tag == "Ast.VarDot" and node.exp._type._tag == "Type.ForeignModule" then
        return codeforeignvar(ctx, node)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpCast" and node.target._tag == "Type.String" then
        local cstats, cexp = codeforeignexp(ctx, node.exp)
        return cstats, foreigncast(cexp, node._type)
    else
        local cstat, cexp = codeexp(ctx, node)
        local fstat, fexp = nativetoforeignexp(ctx, node, cexp)
        return cstat .. fstat, fexp
    end
end

-- Generate Lua entry point `lua_name` for a Titan
-- function or method with name `titan_name` and Titan
-- entry point `titan_entry`, type `typ`, and declared on location `loc`
local function genluaentry(tlcontext, titan_name, titan_entry, typ, loc, lua_name)
    -- generate Lua entry point
    local stats = {}
    local pnames = { "L", "_mod" }
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
    for i = 2, #typ.rettypes do
        local ptype = typ.rettypes[i]
        local pname = "_outparam_" .. i
        table.insert(pnames, "&" .. pname)
        table.insert(stats, ctype(ptype) .. " " .. pname .. " = " .. initval(ptype) .. ";")
    end
    local rettype = typ.rettypes[1]
    if #params > 0 then
        table.insert(stats, [[
            lua_pushvalue(L, 1); /* make space for error slot */
            lua_pushnil(L);
            lua_replace(L, 1); /* replace first stack element with nil, this is our error slot */
        ]])
    end
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
    table.insert(stats, render([[
        L->errfunc = __save_errfunc;
        return $NRET;
    ]], {
        NRET = #typ.rettypes
    }))
    return render([[
    static int $LUANAME(lua_State *L) {
        StkId func = L->ci->func.p;
        if((L->top.p - func - 1) != $EXPECTED) {
            luaL_error(L, "calling Titan function %s with %d arguments, but expected %d", $NAME, (int)(L->top.p - func - 1), $EXPECTED);
        }
        $ERRORSLOT
        ptrdiff_t __save_errfunc = L->errfunc;
        lua_pushcclosure(L, errorhandler, 0);
        L->errfunc = savestack(L, L->top.p - 1);
        CClosure *_mod = clCvalue(&clCvalue(s2v(func))->upvalue[0]);
        $BODY
    }]], {
        LUANAME = lua_name,
        EXPECTED = c_integer_literal(#params),
        ERRORSLOT = #params == 0 and "lua_pushnil(L);" or "",
        NAME = c_string_literal(titan_name),
        BODY = table.concat(stats, "\n"),
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
    elseif node._tag == "Ast.TopLevelStatic" then
        fname = static_name(node._type)
        luaname = static_luaname(node._type)
    else
        assert(node._tag == "Ast.TopLevelMethod")
        fname = method_name(node._type)
        luaname = method_luaname(node._type)
    end
    local cparams = { "lua_State *L", "CClosure *_mod" }
    if node._tag == "Ast.TopLevelMethod" then
        node._self._cvar = "__self__"
        if node._self._assigned then
            node._self._slot = "__selfslot__"
            table.insert(stats, newslot(ctx, node._self._slot))
        end
        table.insert(cparams, ctype(node._self._type) .. " " .. node._self._cvar)
    end
    for i, param in ipairs(node.params) do
        param._cvar = "_param_" .. param.name
        if types.is_gc(param._type) and param._assigned then
            param._slot = "_paramslot_" .. param.name
            table.insert(stats, newslot(ctx, param._slot))
        end
        table.insert(cparams, ctype(param._type) .. " " .. param._cvar)
    end
    for i = 2, #node._type.rettypes do
        local outtype = node._type.rettypes[i]
        table.insert(cparams, ctype(outtype) .. " *" .. "_outparam_" .. i)
    end
    local body = codestat(ctx, node.block)
    local nslots = ctx.nslots
    if nslots > 0 then
        table.insert(stats, 1, render([[
        luaC_checkGC(L);
        /* function preamble: reserve needed stack space */
        if (L->stack_last.p - L->top.p > $NSLOTS) {
            if (L->ci->top.p < L->top.p + $NSLOTS) L->ci->top.p = L->top.p + $NSLOTS;
        } else {
            lua_checkstack(L, $NSLOTS);
        }
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue(s2v(_s));
        }
        ]], {
            NSLOTS = c_integer_literal(nslots),
        }))
    else
        -- No reserved slots, but still anchor _base so every return path can
        -- reset L->top.p uniformly (the reset is then a no-op).
        table.insert(stats, 1, "        StkId _base = L->top.p;")
    end
    table.insert(stats, body)
    if rettype._tag == "Type.Nil" then
        table.insert(stats, [[
            L->top.p = _base;
            return 0;]])
    end
    node._body = render([[
    $ISLOCAL $RETTYPE $NAME($PARAMS) {
        $BODY
    }]], {
        ISLOCAL = node.islocal and "static" or "",
        RETTYPE = ctype(rettype),
        NAME = fname,
        PARAMS = table.concat(cparams, ", "),
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        $ISLOCAL $RETTYPE $NAME($PARAMS);
    ]], {
        ISLOCAL = node.islocal and "static" or "",
        RETTYPE = ctype(rettype),
        NAME = fname,
        PARAMS = table.concat(cparams, ", ")
    })
    node._luabody = genluaentry(tlcontext, node.name, fname, node._type, node.loc, luaname)
end

local function codevardec(ctx, initvars, switch_get, switch_set, gvar_map, node)
    local cstats, cexp = codeexp(ctx, node.value)
    node._slot = render("&_mod->upvalue[$INDEX]",
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
                  and "luaC_barrier(L, _mod, " .. node._slot .. ");" or ""
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
            COPYSLOT = copyslotwrapped(node._type, "s2v(L->top.p - 1)", node._slot)
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
                      and "luaC_barrier(L, _mod, " .. node._slot .. ");" or ""
        }))
    end
end

local preamble = [[
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "luaconf.h"
#include "lauxlib.h"
#include "lgc.h"
#include "ltable.h"
#include "ltm.h"
#include "lfunc.h"
#include "lstring.h"
#include "lvm.h"
#include "lobject.h"
#include "ldo.h"

#include "titan.h"

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
    CClosure *mod = $INITNAME(L);
    setobj2s(L, L->top.p, &mod->upvalue[0]);
    L->top.p++;
    return 1;
}
]]

local init = [[
static int _initialized = 0; /* tags and external functions are set up */

CClosure *$INITNAME(lua_State *L) {
    lua_checkstack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
    if(lua_isnil(L, -1)) {
        _initialized = 1;
        lua_pop(L, 1);
        CClosure *_mod = luaF_newCclosure(L, $NUPVALS);
        memset(_mod->upvalue, 0, sizeof(TValue) * $NUPVALS);
        for(int i = 0; i < $NUPVALS; i++) {
            setnilvalue(&_mod->upvalue[i]);
        }
        titan_pushmodule(L, _mod);
        lua_setfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
        $LOADMODULES1
        $INITMODULES
        $INITRECORDS
        $INITVARS
        lua_newtable(L);
        setobj2t(L, &_mod->upvalue[0], s2v(L->top.p - 1));
        luaC_barrier(L, _mod, &_mod->upvalue[0]);
        $FUNCS
        lua_pop(L, 1);
        $CREATEMETA
        $INITTAGS
        return _mod;
    } else {
        CClosure *_mod = clCvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        if(!_initialized) {
            _initialized = 1;
            /* set up tag cache and functions from shared libraries */
            $LOADMODULES2
            $INITTAGS
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
local function import_module(loadmods, initmods, sigs, mprefixes, dynamic, node)
    local modname = node.modname
    local upvalue = node._upvalue
    local mprefix = mangle_qn(modname) .. "_"
    mprefixes[modname] = mprefix
    if dynamic then
        local file = modname:gsub("[.]", "/") .. ".so"
        table.insert(loadmods, render([[
            void *$HANDLE = loadlib(L, "$FILE");
        ]], { HANDLE = mprefix .. "handle", FILE = file }))
        table.insert(initmods, render([[
            {
                CClosure* (*$INIT)(lua_State *L) = titan_cast_func(CClosure* (*)(lua_State*), loadsym(L, $HANDLE, "$INIT"));
                CClosure *_m = $INIT(L);
                setclCvalue(L, &_mod->upvalue[$INDEX], _m);
            }
        ]], { HANDLE = mprefix .. "handle", INIT = mprefix .. "init", INDEX = c_integer_literal(upvalue) }))
    else
        table.insert(sigs, render("extern CClosure *$INIT(lua_State *L);", {
            INIT = mprefix .. "init"
        }))
        table.insert(initmods, render([[
            {
                CClosure *_m = $INIT(L);
                setclCvalue(L, &_mod->upvalue[$INDEX], _m);
            }
        ]], { INIT = mprefix .. "init", INDEX = c_integer_literal(upvalue) }))
    end
    -- Set upvalue indexes for public members in the module's type
    -- if they are not set yet
    local memberslot = 1
    for _, member in ipairs(node._type.members) do
        if member._tag == "Type.ModuleVariable" then
            member._upvalue = memberslot
            memberslot = memberslot + 1
        end
    end
end

local function init_data_from_other_modules(tlcontext, includes, loadmods, initmetas, inittags, mprefixes, static_deps)
    -- When linking dynamically, we need to make 'static' variables and load the values
    -- from the other module's dynamic library
    -- When linking statically, we only need to make 'extern' forward declarations.

    for name, func in pairs(tlcontext.functions) do
        local is_dynamic = not static_deps[func.module]
        local storage_class = is_dynamic and "static" or "extern"
        local fname = func.mangled
        table.insert(includes, storage_class .. " " .. function_sig(fname, func.type, is_dynamic) .. ";")
        if is_dynamic then
            local mprefix = mprefixes[func.module]
            if not mprefix then
                mprefix = mangle_qn(func.module) .. "_"
                mprefixes[func.module] = mprefix
                local file = func.module:gsub("[.]", "/") .. ".so"
                table.insert(loadmods, render([[
                    void *$HANDLE = loadlib(L, "$FILE");
                ]], { HANDLE = mprefix .. "handle", FILE = file }))
            end
            table.insert(loadmods, render([[
                $NAME = titan_cast_func($TYPE, loadsym(L, $HANDLE, "$NAME"));
            ]], { NAME = fname, TYPE = function_sig("", func.type, true), HANDLE = mprefix .. "handle" }))
        end
    end

    for name, tag in pairs(tlcontext.tags) do
        table.insert(includes, "static const void *" .. tag.mangled .. ";")
        table.insert(inittags, render([[
            lua_getfield(L, LUA_REGISTRYINDEX, "Titan record $TYPE tag");
            $TAG = lua_topointer(L, -1);
            lua_pop(L, 1);
        ]], {
            TAG = tag.mangled,
            TYPE = name,
        }))
    end

    for fqtn, upvalue in pairs(tlcontext.metatables) do
        table.insert(initmetas, render([[
            luaL_getmetatable(L, "Titan record $TYPE metatable");
            setobj2t(L, &_mod->upvalue[$INDEX], s2v(L->top.p - 1));
            lua_pop(L, 1);
        ]], {
            INDEX = c_integer_literal(upvalue),
            TYPE = fqtn,
        }))
    end

    for module, upvalue in pairs(tlcontext.modules) do
        table.insert(initmetas, render([[
            lua_getfield(L, LUA_REGISTRYINDEX, "Titan module $MODULE");
            setobj2t(L, &_mod->upvalue[$INDEX], s2v(L->top.p - 1));
            lua_pop(L, 1);
        ]], {
            INDEX = c_integer_literal(upvalue),
            MODULE = module,
        }))
    end
end

local function coderecorddec(ctx, code, initrecs, inittags, node)
    -- (the type tag is forward-declared up front in generate(), so that
    -- forward/mutually-recursive record field types resolve)
    local fieldmap, getswitch, setswitch = {}, {}, {}
    for i, field in ipairs(node._type.fields) do
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
            SETWRAPPED = field.type._tag == "Type.Nominal" and
                "setobj2s(L, L->top.p - 1, &((clCvalue(_slot))->upvalue[0]));" or
                "setobj2s(L, L->top.p - 1, _slot);"
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
    for name, method in pairs(node._type.methods) do
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
    if #node._type.fields > 0 then
        table.insert(code, render([[
            static int __index_$RECNAME(lua_State *L) {
                TValue *_recslot = s2v(L->ci->func.p + 1);
                CClosure *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _fieldidxv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_fieldidxv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag))) {
                    const TValue *_fieldidx = &_fieldidxv;
                    if(ttisCclosure(_fieldidx)) {
                        setobj2s(L, L->top.p - 1, _fieldidx);
                    } else {
                        TValue *_slot = &_rec->upvalue[ivalue(_fieldidx)];
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
                CClosure *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _fieldidxv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_fieldidxv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag) && ttisinteger(&_fieldidxv))) {
                    TValue* _dst = &(_rec->upvalue[ivalue(&_fieldidxv)]);
                    TValue* _src = s2v(L->ci->func.p + 3);
                    switch(ivalue(&_fieldidxv)) {
                        $SETCASES
                    }
                    luaC_barrier(L, _rec, _dst);
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
        /* If we are here then this is the first time
           this module is initialized in the current Lua state,
           so there is no metatable or tag stored for this record */
        luaL_newmetatable(L, "Titan record $TYPE metatable");
        lua_pushliteral(L, "__metatable");
        lua_pushliteral(L, "Titan record $TYPE");
        lua_rawset(L, -3);
        lua_newtable(L);
        $FIELDMAP
        lua_pushliteral(L, "__index");
        lua_pushvalue(L, -2);
        lua_pushcclosure(L, __index_$RECNAME, 1);
        lua_rawset(L, -4);
        lua_pushliteral(L, "__newindex");
        lua_pushvalue(L, -2);
        lua_pushcclosure(L, __newindex_$RECNAME, 1);
        lua_rawset(L, -4);
        lua_pop(L, 2); /* pop fieldmap and metatable */
        $TAG = &$TAG;
        /* Index from tag to typename for error messages */
        lua_pushstring(L, "$TYPE");
        lua_rawsetp(L, LUA_REGISTRYINDEX, $TAG);
        /* Store tag in registry for other instances of this record in
           the current Lua state */
        lua_pushlightuserdata(L, &$TAG);
        lua_setfield(L, LUA_REGISTRYINDEX, "Titan record $TYPE tag");
    ]], {
        RECNAME = mangle_qn(node._type.name),
        TAG = tagname(node._type.name),
        TYPE = node._type.name,
        FIELDMAP = table.concat(fieldmap, "\n")
    }))
    table.insert(inittags, render([[
        lua_getfield(L, LUA_REGISTRYINDEX, "Titan record $TYPE tag");
        $TAG = lua_topointer(L, -1);
        lua_pop(L, 1);
    ]], {
        TAG = tagname(node._type.name),
        TYPE = node._type.name,
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
    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                node._upvalue = nextupvalue(tlcontext)
            end
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
end

function coder.generate(modname, ast, static_deps)
    local tlcontext = {
        module = modname,
        prefix = mangle_qn(modname) .. "_",
        variables = {},
        metatables = {},
        tags = {},
        functions = {},
        modules = {},
        upvalue = 0
    }

    local funcs = {}
    local initvars = {}
    local includes = {}
    local sigs = {}
    local foreignimports = {}
    local initmods = {}
    local loadmods = {}
    local inittags = {}
    local mprefixes = {}
    local initrecs = {}
    local code = {}
    local switch_get = {}
    local switch_set = {}
    local gvar_map = {}
    local create_meta = ""

    local initctx = newcontext(tlcontext)

    allocate_upvalues(tlcontext, ast)

    -- Forward-declare every record's type tag up front, before any record
    -- body is emitted, so a record field whose type is a record declared
    -- LATER (or mutually recursive) does not reference an as-yet-undeclared
    -- tag in the generated C.
    for _, node in pairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelRecord" then
            table.insert(code, "static const void *" .. tagname(node._type.name) .. ";")
        end
    end

    for _, node in pairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelImport" then
                import_module(loadmods, initmods, sigs, mprefixes, not static_deps[node.modname], node)
            elseif tag == "Ast.TopLevelForeignImport" then
                local include
                if node.headername:match("^/") then
                    include = [[#include "$HEADERNAME"]]
                else
                    include = [[#include <$HEADERNAME>]]
                end
                table.insert(foreignimports, render(include, {
                    HEADERNAME = node.headername
                }))
            elseif tag == "Ast.TopLevelVar" then
                codevardec(initctx, initvars, switch_get, switch_set, gvar_map, node)
            elseif tag == "Ast.TopLevelRecord" then
                coderecorddec(initctx, code, initrecs, inittags, node)
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
                    table.insert(funcs, render([[
                        titan_pushmodule(L, _mod);
                        lua_pushcclosure(L, $LUANAME, 1);
                        lua_setfield(L, -2, $NAMESTR);
                    ]], {
                        LUANAME = func_luaname(tlcontext.module, node.name),
                        NAMESTR = c_string_literal(node.name),
                    }))
                elseif tag == "Ast.TopLevelMethod" then
                    table.insert(code, node._luabody)
                elseif tag == "Ast.TopLevelStatic" then
                    table.insert(code, node._luabody)
                    table.insert(funcs, render([[
                        lua_getfield(L, -1, $RECNAME);
                        titan_pushmodule(L, _mod);
                        lua_pushcclosure(L, $LUANAME, 1);
                        lua_setfield(L, -2, $NAMESTR);
                        lua_pop(L, 1);
                    ]], {
                        RECNAME = c_string_literal(node.class),
                        LUANAME = static_luaname(node._type),
                        NAMESTR = c_string_literal(node.name),
                    }))
                end
            elseif tag == "Ast.TopLevelRecord" then
                table.insert(funcs, render([[
                    lua_newtable(L);
                    lua_setfield(L, -2, $NAMESTR);
                ]], {
                    NAMESTR = c_string_literal(node.name),
                }))
            else
                -- ignore other nodes in second pass
            end
        end
    end

    if #switch_get > 0 then
        table.insert(code, render([[
            static int __index(lua_State *L) {
                CClosure *_me = clCvalue(s2v(L->ci->func.p));
                CClosure *_mod = clCvalue(&_me->upvalue[0]);
                TValue _indexv;
                lu_byte _indextag = luaH_get(hvalue(&_me->upvalue[1]), s2v(L->ci->func.p + 2), &_indexv);
                if(TITAN_UNLIKELY(tagisempty(_indextag))) {
                    return luaL_error(L,
                        "global variable '%s' does not exist in Titan module '%s'",
                        lua_tostring(L, 2), $MODSTR);
                }
                switch(ivalue(&_indexv)) {
                    $SWITCH_GET
                }
                return 1;
            }

            static int __newindex(lua_State *L) {
                CClosure *_me = clCvalue(s2v(L->ci->func.p));
                CClosure *_mod = clCvalue(&_me->upvalue[0]);
                TValue *_value = s2v(L->ci->func.p + 3);
                TValue _indexv;
                lu_byte _indextag = luaH_get(hvalue(&_me->upvalue[1]), s2v(L->ci->func.p + 2), &_indexv);
                if(TITAN_UNLIKELY(tagisempty(_indextag))) {
                    return luaL_error(L,
                        "global variable '%s' does not exist in Titan module '%s'",
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
            /* Set metatable */
            setobj2s(L, L->top.p, &_mod->upvalue[0]);
            L->top.p++;
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

    if nslots > 0 then
        table.insert(initvars, 1, render([[
            lua_checkstack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
                setnilvalue(s2v(_s));
            }
        ]], {
            NSLOTS = c_integer_literal(nslots),
        }))
        table.insert(initvars, "L->top.p = _base;")
    end

    table.insert(code, render(modtypes, {
        TYPESNAME = tlcontext.prefix .. "types",
        TYPES = string.format("%q", types.serialize(ast._type))
    }))

    init_data_from_other_modules(tlcontext, includes, loadmods, initrecs, inittags, mprefixes, static_deps)

    table.insert(code, render(init, {
        INITNAME = tlcontext.prefix .. 'init',
        INITMODULES = table.concat(initmods, "\n"),
        LOADMODULES1 = table.concat(loadmods, "\n"),
        LOADMODULES2 = #loadmods > 1 and table.concat(loadmods, "\n") or "",
        INITTAGS = table.concat(inittags, "\n"),
        INITVARS = table.concat(initvars, "\n"),
        INITRECORDS = table.concat(initrecs, "\n"),
        FUNCS = table.concat(funcs, "\n"),
        MODNAMESTR = c_string_literal("Titan module "..modname),
        CREATEMETA = create_meta,
        NUPVALS = tlcontext.upvalue + 1
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
