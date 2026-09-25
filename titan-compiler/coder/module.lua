local core = require "titan-compiler.coder.core"
local _ENV = core

preamble = [[
$FIXEDPREFIX

$FOREIGNIMPORTS

$AFTERFOREIGNIMPORTS

$INCLUDES

$SIGS

]]

postamble = [[
int $LUAOPEN_NAME(lua_State *L) {
    titan_invalidate_backtrace_state(L);
    Udata *mod = $INITNAME(L);
    setuvalue(L, s2v(L->top.p), mod);
    L->top.p++;
    return 1;
}
]]

modabi = [[
int $ABINAME(lua_State* L) {
    lua_pushliteral(L, TITAN_ABI_VERSION);
    return 1;
}
]]

init = [[
int $LUAOPEN_NAME(lua_State *L);

static void $PRELOADNAME(lua_State *L) {
    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L, $LUAOPEN_NAME);
    lua_setfield(L, -2, $PRELOADMODNAME);
    lua_pop(L, 1);
}

static int _initialized = 0; /* tags and external functions are set up */

Udata *$INITNAME(lua_State *L) {
    titan_ensure_stack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);
        Udata *_mod = luaS_newudata(L, 0, $NUPVALS);
        /* Root privately until every dependency check succeeds. A failed
         * require must not publish a partial module that bypasses the check
         * when Lua catches the error and retries. */
        titan_pushmodule(L, _mod);
        Table *_titan_metatables = titan_ensure_metatables_table(L);
        (void)_titan_metatables; // in case this module does not publish any types
        $INITSOURCEIDENTITY
        $INITARRAYMETA
        $LOADMODULES1
        $INITMODULES
        $LOADGLOBALS
        lua_setfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
        _initialized = 1;
        $INITRECORDS
        $INITFUNCTAGS
        $INITPAIRS
        $INITARRAYWRITERS
        $FUNCS
        $INITNAMES
        $INITVARS
        $CREATEMETA
        $MODULEINIT
        $PRELOADNAME(L);
        return _mod;
    } else {
        Udata *_mod = uvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        if(!_initialized) {
            /* set up function-type tags and functions from shared libraries */
            $LOADMODULES2
            $LOADGLOBALS
            _initialized = 1;
            $INITFUNCTAGS
            $INITPAIRS
            $INITNAMES
            $PRELOADNAME(L);
        }
        return _mod;
    }
}
]]

modtypes = [[
int $TYPESNAME(lua_State* L) {
    lua_pushliteral(L, $TYPES);
    return 1;
}
]]

coder.modmetadata = [[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#elif defined(__ELF__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#else
#error unsupported object format for Titan archive metadata
#endif

#if defined(__clang__)
#define TITAN_META_NO_ADDRESS_SANITIZE \
    __attribute__((no_sanitize("address")))
#else
#define TITAN_META_NO_ADDRESS_SANITIZE
#endif

TITAN_META_SECTION TITAN_META_NO_ADDRESS_SANITIZE
static const unsigned char $METADATANAME[] = $METADATA;
]]

-- Enumerate the ABI-visible prefix of a module userdata. Producers and
-- importers must use this exact order: public variables, public top-level
-- function closures, then public nominal static closures by module-member and
-- bytewise static-name order.
function coder._public_prefix_layout(modtype)
    return types.public_module_prefix_layout(modtype)
end

-- Deterministic compiler-private slots available only on a trusted direct
-- source edge. They follow the public prefix, both unconditional Array-
-- metatable slots, and the source-provider identity; they never participate
-- in serialized metadata or Lua member maps.
function coder._source_prefix_layout(modtype)
    return types.source_module_prefix_layout(modtype)
end

-- Generates the code for importing the module, and storing it
-- in the corresponding local state slot
function import_module(loadmods, initmods, sigs, mprefixes,
                       dynamic, node, tlcontext)
    local modname = node.modname
    local upvalue = node._upvalue
    local mprefix = mangle_qn(modname) .. "_"
    local public_layout = coder._public_prefix_layout(node._type)
    local source_check = ""
    mprefixes[modname] = mprefix
    if node._source_import then
        assert(not dynamic,
            "trusted source import cannot use dynamic initialization")
        local identity = coder._source_module_identity_name(modname)
        local identity_index = #public_layout + 2
        table.insert(sigs, render([[
            TITAN_SOURCE_LOCAL const void *$IDENTITY(void);
        ]], { IDENTITY = identity }))
        source_check = render([[
            if(_m->nuvalue <= $IDENTITY_INDEX
               || !ttislightuserdata(&_m->uv[$IDENTITY_INDEX].uv)
               || pvalue(&_m->uv[$IDENTITY_INDEX].uv) != $IDENTITY()) {
                luaL_error(L, "source import '$MODULE' found canonical "
                    "module state from a different physical provider");
            }
        ]], {
            IDENTITY = identity,
            IDENTITY_INDEX = c_integer_literal(identity_index),
            MODULE = modname,
        })
    end
    if dynamic then
        -- The checker may have rehydrated this logical module from an ancestor
        -- container. Its transient file field records that physical provider;
        -- logical symbol names remain derived from modname below.
        local file = node._type.file
        tlcontext.binary_modules[modname] = tlcontext.binary_modules[modname]
            or rawget(node, "_declared_type") or node._type
        table.insert(loadmods, render([[
            void *$HANDLE = loadlib(L, $FILE);
            titan_check_abi(L, $HANDLE, "$ABI", $FILE);
            $COMPATIBILITY
        ]], {
            HANDLE = mprefix .. "handle",
            FILE = c_string_literal(file),
            ABI = mprefix .. "abi",
            COMPATIBILITY = coder._binary_check(tlcontext, modname,
                mprefix .. "handle", file),
        }))
        table.insert(initmods, render([[
            {
                Udata* (*$INIT)(lua_State *L) = titan_cast_func(Udata* (*)(lua_State*), loadsym(L, $HANDLE, "$INIT"));
                Udata *_m = $INIT(L);
                setuvalue(L, &_mod->uv[$INDEX].uv, _m);
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            }
        ]], {
            HANDLE = mprefix .. "handle",
            INIT = mprefix .. "init",
            INDEX = c_integer_literal(upvalue),
        }))
    else
        table.insert(sigs, render("extern Udata *$INIT(lua_State *L);", {
            INIT = mprefix .. "init"
        }))
        table.insert(initmods, render([[
            {
                Udata *_m = $INIT(L);
                $SOURCE_CHECK
                setuvalue(L, &_mod->uv[$INDEX].uv, _m);
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            }
        ]], {
            INIT = mprefix .. "init",
            INDEX = c_integer_literal(upvalue),
            SOURCE_CHECK = source_check,
        }))
    end
    -- Reconstruct the complete ABI-visible prefix, including nominal statics.
    for slot, entry in ipairs(public_layout) do
        local index = slot - 1
        if entry.kind == "variable" then
            entry.value._upvalue = index
        else
            entry.value._closure_upvalue = index
        end
    end
    if node._source_import then
        for slot, entry in ipairs(coder._source_prefix_layout(node._type)) do
            -- Public slots occupy 0..N-1, mutable/const Array metatables occupy
            -- N/N+1, and the source-provider identity occupies N+2.
            local index = #public_layout + 2 + slot
            if entry.kind == "variable" then
                entry.value._upvalue = index
            else
                entry.value._closure_upvalue = index
            end
        end
    end
end

function init_data_from_other_modules(tlcontext, includes, loadmods,
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

    -- A cross-module bind site also installs the defining provider's strict
    -- stack entry as the bound closure's final LCF upvalue.
    for strictname, info in pairs(tlcontext.bound_stricts) do
        local is_dynamic = static_deps[info.module] ~= true
        if is_dynamic then
            local mprefix = mprefixes[info.module]
            table.insert(includes,
                "static int (*" .. strictname .. ")(lua_State *L);")
            if mprefix then
                table.insert(loadmods, render([[
                    $NAME = titan_cast_func(int (*)(lua_State *L), loadsym(L, $HANDLE, "$NAME"));
                ]], { NAME = strictname, HANDLE = mprefix .. "handle" }))
            else
                table.insert(loadglobals, render([[
                    $NAME = titan_cast_func(int (*)(lua_State *L), loadglobalsym(L, "$NAME"));
                ]], { NAME = strictname }))
            end
        else
            table.insert(includes,
                "extern int " .. strictname .. "(lua_State *L);")
        end
    end

    for fqtn, entry in pairs(tlcontext.metatables) do
        table.insert(initmetas, render([[
            luaL_getmetatable(L, "Titan $KIND $TYPE metatable");
            setobj2t(L, &_mod->uv[$INDEX].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            lua_pop(L, 1);
        ]], {
            INDEX = c_integer_literal(entry.slot),
            KIND = entry.kind,
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

function coderecorddec(ctx, code, initrecs, node)
    -- (the type tag is forward-declared up front in generate(), so that
    -- forward/mutually-recursive record field types resolve)
    local plan = coder._nominal_plan(ctx, node._type)
    local fieldmap = {}
    for _, field in ipairs(node._type.fields) do
        if not field.islocal then
            local accessor = coder._nominal_function_prefix(
                node._type.name, field.name) .. "_fieldaccessor"
            table.insert(fieldmap, render([[
                lua_pushliteral(L, $NAME);
                lua_pushlightuserdata(L, titan_cast_func(void *, $ACCESSOR));
                lua_rawset(L, -3);
            ]], {
                NAME = c_string_literal(field.name),
                ACCESSOR = accessor,
            }))
            local slot = assert(plan.by_index[field.index])
            local write
            if field.isconst then
                write = render([[
                    luaL_error(L,
                        "%s:%d:%d: cannot assign const field '%s' in record '%s'",
                        $FILE, $LINE, $COL, $FIELD, $FQTN);
                ]], {
                    FILE = c_string_literal(node.loc.filename),
                    LINE = c_integer_literal(node.loc.line),
                    COL = c_integer_literal(node.loc.col),
                    FIELD = c_string_literal(field.name),
                    FQTN = c_string_literal(node._type.name),
                })
            elseif field.dynamic_plan == false then
                write = coder._dynamiccheckandget(ctx, false, field.type,
                    "_unavailable", "tv", node.loc, "Lua record-field write")
            else
                local converted = "_converted"
                write = render([[
                    $DECL = $INIT;
                    $CHECK
                    $STORE
                ]], {
                    DECL = cvardecl(ctx, field.type, converted),
                    INIT = initval(field.type),
                    CHECK = coder._dynamiccheckandget(
                        ctx, field.dynamic_plan, field.type, converted, "tv",
                        node.loc, "Lua record-field write"),
                    STORE = coder._nominal_store(ctx, plan, slot,
                        field.type, "_rec", converted),
                })
            end
            table.insert(code, render([[
                static void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_rec, TValue *tv, int write) {
                    (void)_mod; /* scalar fields need no cached identities */
                    if (write) {
                        $WRITE
                    } else {
                        $SETWRAPPED
                    }
                }
            ]], {
                ACCESSOR = accessor,
                WRITE = write,
                SETWRAPPED = coder._nominal_box(ctx, plan, slot,
                    field.type, "_rec", "tv"),
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
    table.insert(code, render([[
            static int $INDEXNAME(lua_State *L) {
                TValue *_recslot = s2v(L->ci->func.p + 1);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_func->upvalue[1]);
                Udata *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _memberv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_memberv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag))) {
                    if(ttisCclosure(&_memberv)) {
                        setobj2s(L, L->top.p - 1, &_memberv);
                    } else if (ttislightuserdata(&_memberv)
                               && pvalue(&_memberv) != NULL) {
                        void (*_accessor)(lua_State *, Udata *, Udata *, TValue *, int) =
                            titan_cast_func(
                                void (*)(lua_State *, Udata *, Udata *, TValue *, int),
                                pvalue(&_memberv));
                        _accessor(L, _mod, _rec, s2v(L->top.p - 1), 0);
                    } else {
                        return luaL_error(L,
                            "malformed internal member map for record '%s'", $FQTN);
                    }
                    return 1;
                } else {
                    return luaL_error(L, "%s:%d:%d: field '%s' not found in record '%s'", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
                }
            }
            static int $NEWINDEXNAME(lua_State *L) {
                TValue *_recslot = s2v(L->ci->func.p + 1);
                CClosure *_func = clCvalue(s2v(L->ci->func.p));
                Udata *_mod = uvalue(&_func->upvalue[1]);
                Udata *_rec = NULL;
                $CHECKANDGET;
                TValue *_fieldslot = s2v(L->ci->func.p + 2);
                Table *_fieldmap = hvalue(&(_func->upvalue[0]));
                TValue _memberv;
                lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_memberv);
                if(TITAN_LIKELY(!tagisempty(_fieldtag)
                               && ttislightuserdata(&_memberv)
                               && pvalue(&_memberv) != NULL)) {
                    void (*_accessor)(lua_State *, Udata *, Udata *, TValue *, int) =
                        titan_cast_func(
                            void (*)(lua_State *, Udata *, Udata *, TValue *, int),
                            pvalue(&_memberv));
                    _accessor(L, _mod, _rec, s2v(L->ci->func.p + 3), 1);
                    return 0;
                } else {
                    return luaL_error(L, "%s:%d:%d: field '%s' not found in record '%s'", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
                }
            }
        ]], {
            INDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "index"),
            NEWINDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "newindex"),
            CHECKANDGET = coder._dynamiccheckandget(
                ctx, node._dynamic_receiver_plan,
                types.Nominal(node._type.name), "_rec", "_recslot",
                node.loc, "Lua record receiver"),
            FQTN = c_string_literal(node._type.name),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }))
    table.insert(initrecs, render([[
      {
        /* If we are here then this is the first time
           this module is initialized in the current Lua state,
           so there is no metatable stored for this record */
        luaL_newmetatable(L, "Titan record $TYPE metatable");
        const void *_mtp = lua_topointer(L, -1);
        lua_pushinteger(L, TITAN_RECORD);
        lua_rawsetp(L, -2, TITAN_BRAND);
        lua_pushliteral(L, "__metatable");
        lua_pushliteral(L, "Titan record $TYPE");
        lua_rawset(L, -3);
        lua_pushliteral(L, $TAG);
        lua_rawsetp(L, -2, TITAN_MT_TYPE);
        titan_pushmodule(L, _mod);
        lua_rawsetp(L, -2, TITAN_MT_MOD);
        lua_newtable(L);
        $FIELDMAP
        lua_pushvalue(L, -1); /* fieldmap */
        lua_rawsetp(L, -3, TITAN_MT_MEMBERMAP);  /* metatable.[TITAN_MT_MEMBERMAP] = membermap */
        lua_pushliteral(L, "__index");
        lua_pushvalue(L, -2);            /* membermap */
        titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
        lua_pushcclosure(L, $INDEXNAME, 2);
        lua_rawset(L, -4);
        lua_pushliteral(L, "__newindex");
        lua_pushvalue(L, -2);            /* membermap */
        titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
        lua_pushcclosure(L, $NEWINDEXNAME, 2);
        lua_rawset(L, -4);
        // Set _titan_metatables[type] = metatable
        TString *_type = luaS_new(L, "$TYPE");
        int _hres = luaH_psetstr(_titan_metatables, _type, s2v(L->top.p-2));
        if (_hres == HOK) {
          luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
        } else {
          setsvalue2s(L, L->top.p - 1, _type);
          luaH_finishset(L, _titan_metatables, s2v(L->top.p - 1), s2v(L->top.p - 2), _hres);
          luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
        }
        lua_pop(L, 2); /* pop fieldmap/type and metatable */
        /* Index from metatable pointer to typename for error messages */
        lua_pushliteral(L, "$TYPE");
        lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
      }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        TYPE = node._type.name,
        TAG = c_string_literal(types.serialize(node._declared_type or node._type)),
        FIELDMAP = table.concat(fieldmap, "\n")
    }))
end

-- Generate the Lua-facing metatable for a union. Variants, tags, and payloads
-- are opaque; only public methods participate in lookup, and all writes fail.
function coder._codeuniondec(ctx, code, initnominals, node)
    local payload_reader = coder._nominal_function_prefix(
        node._type.name, "payload_reader")
    local payload_cases = {}
    for _, variant in ipairs(node._type.variants) do
        local plan = coder._nominal_plan(ctx, node._type, variant)
        local part_cases = {}
        for _, part in ipairs(variant.parts) do
            part_cases[#part_cases + 1] = render([[
                case $INDEX: {
                    $PAYLOAD
                    return;
                }
            ]], {
                INDEX = c_integer_literal(part.index),
                PAYLOAD = coder._nominal_box(ctx, plan,
                    assert(plan.by_index[part.index]), part.type, "_union", "tv"),
            })
        end
        table.insert(payload_cases, render([[
            case $INDEX: {
                switch (part) {
                    case 0: setivalue(tv, $INDEX); return;
                    case -1: setivalue(tv, $ARITY); return;
                    $PART_CASES
                    default:
                        setnilvalue(tv);
                        return;
                }
                return;
            }
        ]], {
            INDEX = c_integer_literal(variant.index),
            ARITY = #variant.parts,
            PART_CASES = table.concat(part_cases, "\n"),
        }))
    end
    table.insert(code, render([[
        static void $READER(lua_State *L, Udata *_union, lua_Integer part,
                            TValue *tv) {
            switch ($TAG) {
                $CASES
                default:
                    luaL_error(L, "malformed internal tag for union '%s'", $FQTN);
                    return;
            }
        }
    ]], {
        READER = payload_reader,
        TAG = coder._nominal_tag("_union"),
        CASES = table.concat(payload_cases, "\n"),
        FQTN = c_string_literal(node._type.name),
    }))
    local methodmap = {}
    local methodnames = {}
    for name, method in pairs(node._type.methods or {}) do
        if not method.islocal then
            methodnames[#methodnames + 1] = name
        end
    end
    table.sort(methodnames, util.bytewise_less)
    for _, name in ipairs(methodnames) do
        local method = node._type.methods[name]
        methodmap[#methodmap + 1] = render([[
            lua_pushliteral(L, $NAME);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $METHOD, 1);
            lua_rawset(L, -3);
        ]], {
            NAME = c_string_literal(name),
            METHOD = method_luaname(method),
        })
    end

    table.insert(code, render([[
        static int $INDEXNAME(lua_State *L) {
            TValue *_unionslot = s2v(L->ci->func.p + 1);
            CClosure *_func = clCvalue(s2v(L->ci->func.p));
            Udata *_mod = uvalue(&_func->upvalue[1]);
            Udata *_union = NULL;
            $CHECKANDGET;
            (void)_union;
            TValue *_memberslot = s2v(L->ci->func.p + 2);
            Table *_membermap = hvalue(&_func->upvalue[0]);
            TValue _memberv;
            lu_byte _membertag =
                luaH_get(_membermap, _memberslot, &_memberv);
            if (TITAN_LIKELY(!tagisempty(_membertag)
                             && ttisCclosure(&_memberv))) {
                setobj2s(L, L->top.p - 1, &_memberv);
                return 1;
            }
            return luaL_error(L,
                "%s:%d:%d: member '%s' not found in union '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }

        static int $NEWINDEXNAME(lua_State *L) {
            return luaL_error(L,
                "%s:%d:%d: cannot assign member '%s' in union '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        CHECKANDGET = coder._dynamiccheckandget(
            ctx, node._dynamic_receiver_plan,
            types.Nominal(node._type.name),
            "_union", "_unionslot", node.loc, "Lua union receiver"),
        FQTN = c_string_literal(node._type.name),
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
    }))

    table.insert(initnominals, render([[
        {
            luaL_newmetatable(L, "Titan union $TYPE metatable");
            const void *_mtp = lua_topointer(L, -1);
            lua_pushinteger(L, TITAN_UNION);
            lua_rawsetp(L, -2, TITAN_BRAND);
            lua_pushliteral(L, "__metatable");
            lua_pushliteral(L, "Titan union $TYPE");
            lua_rawset(L, -3);
            lua_pushliteral(L, $TAG);
            lua_rawsetp(L, -2, TITAN_MT_TYPE);
            lua_pushlightuserdata(L, titan_cast_func(void *, $PAYLOAD_READER));
            lua_rawsetp(L, -2, TITAN_MT_PAYLOAD);
            lua_newtable(L);
            $METHODMAP
            lua_pushvalue(L, -1); /* methodmap */
            lua_rawsetp(L, -3, TITAN_MT_MEMBERMAP);  /* metatable[TITAN_MT_MEMBERMAP] = methodmap */
            lua_pushliteral(L, "__index");
            lua_pushvalue(L, -2);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $INDEXNAME, 2);
            lua_rawset(L, -4);
            lua_pushliteral(L, "__newindex");
            lua_pushcfunction(L, $NEWINDEXNAME);
            lua_rawset(L, -4);
            // Set _titan_metatables[type] = metatable
            TString *_type = luaS_new(L, "$TYPE");
            int _hres = luaH_psetstr(_titan_metatables, _type, s2v(L->top.p-2));
            if (_hres == HOK) {
              luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
            } else {
              setsvalue2s(L, L->top.p-1, _type);
              luaH_finishset(L, _titan_metatables, s2v(L->top.p - 1), s2v(L->top.p - 2), _hres);
              luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
            }
            lua_pop(L, 2);
            lua_pushliteral(L, "$TYPE");
            lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        TYPE = node._type.name,
        TAG = c_string_literal(types.serialize(node._declared_type or node._type)),
        PAYLOAD_READER = payload_reader,
        METHODMAP = table.concat(methodmap, "\n"),
    }))
end

function coder._code_interface_method_artifacts(
    tlcontext, sigs, code, interface, method_node, index)
    local method = assert(method_node._type)
    assert(method._tag == "Type.Method"
        and interface.methods[index + 1] == method,
        "Interface method AST/descriptor order mismatch")
    local ftype = types.method_function_type(method)
    local luaname = coder._interface_method_luaname(method)
    local nativename = coder._interface_bound_method_name(method)
    local bound_luaname = coder._interface_bound_method_luaname(method)
    local strictname = coder._interface_bound_method_strictname(method)
    local payload_name = "_titan_interface_payload"
    local rettype = method.rettypes[1]

    -- The ordinary method entry belongs to the Interface owner and therefore
    -- checks/coerces the public Interface signature with that owner's `_mod`.
    -- Its final call is parameterized to read uv[0]/uv[1] and invoke the copied
    -- payload slot directly with `_fn = NULL`.
    table.insert(sigs, "static int " .. luaname .. "(lua_State *L);")
    table.insert(code, genluaentry(
        tlcontext, interface.name .. ":" .. method.name, "",
        method, method_node.loc, luaname, {
            dynamic_plans = method_node._lua_dynamic_plans,
            dynamic_vararg_plan =
                method_node._lua_vararg_dynamic_plan,
            interface_method_index = index,
        }))

    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    local callargs = {
        "L",
        "_titan_interface_concrete_module",
        "NULL",
        "_titan_interface_concrete_self",
    }
    for i, ptype in ipairs(method.params) do
        local pname = "_bp_" .. tostring(i)
        table.insert(cparams, cvardecl(tlcontext, ptype, pname))
        table.insert(callargs, pname)
    end
    if method.varargtype then
        table.insert(cparams,
            varg_struct_name(method.varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        table.insert(callargs, "_varargs")
        table.insert(callargs, "_start")
    end
    for i = 2, #method.rettypes do
        local oname = "_outparam_" .. tostring(i)
        table.insert(cparams,
            cpointerdecl(method.rettypes[i], oname))
        table.insert(callargs, oname)
    end
    if method.flexrettype then
        table.insert(cparams,
            varg_struct_name(method.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
        table.insert(callargs, "_flexout")
        table.insert(callargs, "_flexwant")
    end

    local payload_call = render("$PAYLOAD($ARGS)", {
        PAYLOAD = payload_name,
        ARGS = table.concat(callargs, ", "),
    })
    local native_call = rettype
        and ("return " .. payload_call .. ";")
        or (payload_call .. ";\n        return;")
    local nativesig = cfunctiondecl(
        rettype, nativename, table.concat(cparams, ", "), false)

    register_trace_name(tlcontext, nativename,
        interface.name .. ":" .. method.name)
    register_trace_name(tlcontext, strictname,
        interface.name .. ":" .. method.name)

    local strictbody = genluaentry(
        tlcontext, interface.name .. ":" .. method.name,
        nativename, ftype, method_node.loc, strictname, {
            strict = true,
            strict_name = strictname,
            lua_entry = bound_luaname,
            storage = "",
            strict_plans = method_node._bound_strict_guard_plans,
            strict_vararg_plan =
                method_node._bound_strict_vararg_guard_plan,
        })

    table.insert(sigs, render([[
        $NATIVE_SIG;
        int $LUA_NAME(lua_State *L);
        int $STRICT_NAME(lua_State *L);
    ]], {
        NATIVE_SIG = function_sig(nativename, ftype, false),
        LUA_NAME = bound_luaname,
        STRICT_NAME = strictname,
    }))
    table.insert(code, render([[
        $NATIVE_SIG {
            (void)_mod; /* Interface owner; payload receives concrete owner. */
            if (TITAN_UNLIKELY(_fn == NULL || _fn->nupvalues < 6)) {
                luaL_error(L, "invalid bound Interface method closure");
            }
            Udata *_titan_interface_wrapper =
                uvalue(&_fn->upvalue[4]);
            if (TITAN_UNLIKELY(
                    _titan_interface_wrapper->len
                        % sizeof(TitanInterfaceMethod) != 0
                    || _titan_interface_wrapper->len
                        / sizeof(TitanInterfaceMethod) != $METHOD_COUNT)) {
                luaL_error(L, "malformed internal Interface wrapper for %s",
                    $IFACE);
            }
            TitanInterfaceMethod _titan_interface_stored =
                ((TitanInterfaceMethod *)getudatamem(
                    _titan_interface_wrapper))[$INDEX];
            if (TITAN_UNLIKELY(_titan_interface_stored == NULL)) {
                luaL_error(L, "uninitialized internal Interface method %s:%s",
                    $IFACE, $METHOD);
            }
            $PAYLOAD_DECL = titan_cast_func(
                $PAYLOAD_TYPE, _titan_interface_stored);
            Udata *_titan_interface_concrete_module =
                uvalue(&_titan_interface_wrapper->uv[0].uv);
            Udata *_titan_interface_concrete_self =
                uvalue(&_titan_interface_wrapper->uv[1].uv);
            $NATIVE_CALL
        }

        int $BOUND_LUA(lua_State *L) {
            CClosure *_bound = clCvalue(s2v(L->ci->func.p));
            if (TITAN_UNLIKELY(_bound->nupvalues < 6)) {
                return luaL_error(L,
                    "invalid bound Interface method closure");
            }
            titan_ensure_stack(L, 1);
            setobj2s(L, L->top.p, &_bound->upvalue[4]);
            L->top.p++;
            lua_insert(L, 1);
            return $INTERFACE_LUA(L);
        }

        $STRICT_BODY
    ]], {
        NATIVE_SIG = nativesig,
        METHOD_COUNT = c_integer_literal(#interface.methods),
        IFACE = c_string_literal(interface.name),
        METHOD = c_string_literal(method.name),
        INDEX = c_integer_literal(index),
        PAYLOAD_DECL = function_sig(payload_name, method, true),
        PAYLOAD_TYPE = function_sig("", method, true),
        NATIVE_CALL = native_call,
        BOUND_LUA = bound_luaname,
        INTERFACE_LUA = luaname,
        STRICT_BODY = strictbody,
    }))

    function_type_tag(tlcontext, ftype)
end

-- Interface declarations are type-only, but their owner module publishes one
-- protected per-state metatable and all method/bound dispatch artifacts.
function coder._codeinterfacedec(ctx, sigs, code, initnominals, node)
    local interface = assert(node._type)
    assert(interface._tag == "Type.Interface"
        and types.validate_interface_descriptor(interface),
        "malformed Interface declaration reached code generation")
    assert(#node.fields == #interface.fields)
    assert(#node.methods == #interface.methods)

    -- Allocate the owner's cached metatable slot even when no value of this
    -- Interface is constructed in the declaring module. Importing consumers
    -- recover the same registry metatable through type2metatable.
    type2metatable(ctx, types.Nominal(interface.name))

    local membermap = {}
    for _, field in ipairs(interface.fields) do
        local accessor = coder._nominal_function_prefix(
            interface.name, field.name) .. "_fieldaccessor"
        table.insert(membermap, render([[
            lua_pushliteral(L, $NAME);
            lua_pushlightuserdata(L, titan_cast_func(void *, $ACCESSOR));
            lua_rawset(L, -3);
        ]], {
            NAME = c_string_literal(field.name),
            ACCESSOR = accessor,
        }))
        table.insert(code, render([[
            static void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_interface, TValue *tv, int write) {
                (void)_mod;
                if (write) {
                    luaL_error(L,
                        "%s:%d:%d: cannot assign member '%s' in interface '%s'",
                        $FILE, $LINE, $COL, $FIELD, $FQTN);
                } else {
                    TValue *_slot = &_interface->uv[$UVINDEX].uv;
                    $SETWRAPPED
                }
            }
        ]], {
            ACCESSOR = accessor,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            FIELD = c_string_literal(field.name),
            FQTN = c_string_literal(interface.name),
            UVINDEX = c_integer_literal(2 + field.index),
            SETWRAPPED = copyboxed(ctx, field.type, "tv", "_slot"),
        }))
    end
    for index, method_node in ipairs(node.methods) do
        local method = interface.methods[index]
        coder._code_interface_method_artifacts(
            ctx.tlcontext, sigs, code, interface, method_node, index - 1)
        table.insert(membermap, render([[
            lua_pushliteral(L, $NAME);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $METHOD, 1);
            lua_rawset(L, -3);
        ]], {
            NAME = c_string_literal(method.name),
            METHOD = coder._interface_method_luaname(method),
        }))
    end

    local receiver_plan = assert(node._dynamic_receiver_plan,
        "Interface receiver lacks its Lua boundary plan")
    table.insert(code, render([[
        static int $INDEXNAME(lua_State *L) {
            TValue *_interfaceslot = s2v(L->ci->func.p + 1);
            CClosure *_func = clCvalue(s2v(L->ci->func.p));
            Udata *_mod = uvalue(&_func->upvalue[1]);
            Udata *_interface = NULL;
            $CHECK_RECEIVER
            (void)_interface;
            TValue *_memberslot = s2v(L->ci->func.p + 2);
            Table *_membermap = hvalue(&_func->upvalue[0]);
            TValue _memberv;
            lu_byte _membertag =
                luaH_get(_membermap, _memberslot, &_memberv);
            if (TITAN_LIKELY(!tagisempty(_membertag))) {
                if (ttisCclosure(&_memberv)) {
                    setobj2s(L, L->top.p - 1, &_memberv);
                } else if (ttislightuserdata(&_memberv)
                           && pvalue(&_memberv) != NULL) {
                    void (*_accessor)(lua_State *, Udata *, Udata *, TValue *, int) =
                        titan_cast_func(
                            void (*)(lua_State *, Udata *, Udata *, TValue *, int),
                            pvalue(&_memberv));
                    _accessor(L, _mod, _interface, s2v(L->top.p - 1), 0);
                } else {
                    return luaL_error(L,
                        "malformed internal member map for interface '%s'",
                        $FQTN);
                }
                return 1;
            }
            return luaL_error(L,
                "%s:%d:%d: member '%s' not found in interface '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }

        static int $NEWINDEXNAME(lua_State *L) {
            return luaL_error(L,
                "%s:%d:%d: cannot assign member '%s' in interface '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            interface.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            interface.name, "newindex"),
        CHECK_RECEIVER = coder._dynamiccheckandget(
            ctx, receiver_plan, types.Nominal(interface.name),
            "_interface", "_interfaceslot", node.loc,
            "Lua Interface receiver"),
        FQTN = c_string_literal(interface.name),
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
    }))

    table.insert(initnominals, render([[
        {
            luaL_newmetatable(L, "Titan interface $TYPE metatable");
            const void *_mtp = lua_topointer(L, -1);
            lua_pushinteger(L, TITAN_INTERFACE);
            lua_rawsetp(L, -2, TITAN_BRAND);
            lua_pushliteral(L, "__metatable");
            lua_pushliteral(L, "Titan interface $TYPE");
            lua_rawset(L, -3);
            lua_pushliteral(L, $TAG);
            lua_rawsetp(L, -2, TITAN_MT_TYPE);
            titan_pushmodule(L, _mod);
            lua_rawsetp(L, -2, TITAN_MT_MOD);
            lua_newtable(L);
            $MEMBERMAP
            lua_pushvalue(L, -1); /* membermap */
            lua_rawsetp(L, -3, TITAN_MT_MEMBERMAP);  /* metatable[TITAN_MT_MEMBERMAP] = membermap */
            lua_pushliteral(L, "__index");
            lua_pushvalue(L, -2);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $INDEXNAME, 2);
            lua_rawset(L, -4);
            lua_pushliteral(L, "__newindex");
            lua_pushcfunction(L, $NEWINDEXNAME);
            lua_rawset(L, -4);
            // Set _titan_metatables[type] = metatable
            TString *_type = luaS_new(L, "$TYPE");
            int _hres = luaH_psetstr(_titan_metatables, _type, s2v(L->top.p-2));
            if (_hres == HOK) {
              luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
            } else {
              setsvalue2s(L, L->top.p-1, _type);
              luaH_finishset(L, _titan_metatables, s2v(L->top.p - 1), s2v(L->top.p - 2), _hres);
              luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
            }
            // Pop membermap/type and metatable
            lua_pop(L, 2);
            lua_pushliteral(L, "$TYPE");
            lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        TYPE = interface.name,
        TAG = c_string_literal(types.serialize(node._declared_type or interface)),
        INDEXNAME = coder._nominal_metamethod_name(
            interface.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            interface.name, "newindex"),
        MEMBERMAP = table.concat(membermap, "\n"),
    }))
end

-- Distribute local state slots for the variables and
-- imported modules of the current module,
-- starting with exported variables in the order they appear;
-- slots for record metatables are allocated in
-- "init_data_from_other_modules"
-- Tags can be stored in C variables, as their value
-- is the same across all instances of the module
function allocate_upvalues(tlcontext, ast)
    -- Allocate the public ABI prefix from the serialized module interface, then
    -- stamp the corresponding source declarations. Importers walk the same
    -- helper, so these indices are reconstructible without loading a namespace
    -- table.
    local public_slots = {}
    for _, entry in ipairs(coder._public_prefix_layout(ast._type)) do
        local slot = nextupvalue(tlcontext)
        public_slots[entry.key] = slot
        if entry.kind == "variable" then
            entry.value._upvalue = slot
        else
            entry.value._closure_upvalue = slot
        end
    end
    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelVar" and not node.islocal then
                node._upvalue = assert(
                    public_slots["variable:" .. node.decl.name])
            elseif node._tag == "Ast.TopLevelFunc" and not node.islocal then
                node._closure_upvalue = assert(
                    public_slots["function:" .. node.name])
            elseif node._tag == "Ast.TopLevelStatic" and not node.islocal then
                node._closure_upvalue = public_slots[
                "static:" .. node._type.fqtn .. "." .. node._type.name]
            end
        end
    end

    -- Every module has the mutable and const Array-metatable caches
    -- immediately after the public prefix. Their consecutive order is the
    -- private-state contract reconstructed by source importers.
    tlcontext.array_metatable_upvalue = nextupvalue(tlcontext)
    tlcontext.const_array_metatable_upvalue = nextupvalue(tlcontext)

    -- A direct source importer must consume the exact co-generated producer,
    -- not a same-name module state left in the registry by another provider.
    -- The immutable provider token in this fixed compiler-private slot lets an
    -- importer prove that ownership before it reads any source-only slot.
    tlcontext.source_identity_upvalue = nextupvalue(tlcontext)

    -- A trusted source importer additionally reconstructs this deterministic
    -- compiler-private region. It includes mutable module variables and every
    -- first-class local callable, but is deliberately absent from metadata and
    -- Lua member maps.
    local source_slots = {}
    for _, entry in ipairs(coder._source_prefix_layout(ast._type)) do
        local slot = nextupvalue(tlcontext)
        source_slots[entry.key] = slot
        if entry.kind == "variable" then
            entry.value._upvalue = slot
        else
            entry.value._closure_upvalue = slot
        end
    end
    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelVar" and node.islocal then
                node._upvalue = assert(
                    source_slots["variable:" .. node.decl.name])
            elseif node._tag == "Ast.TopLevelFunc" and node.islocal then
                node._closure_upvalue = assert(
                    source_slots["function:" .. node.name])
            elseif node._tag == "Ast.TopLevelStatic" and node.islocal then
                node._closure_upvalue = assert(source_slots[
                "static:" .. node._type.fqtn .. "." .. node._type.name])
            end
        end
    end

    -- The remaining slots are private implementation state whose order no
    -- importer reconstructs.
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelImport" then
            node._upvalue = nextupvalue(tlcontext)
        end
    end
    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelStatic" then
                assert(node._closure_upvalue,
                    "static lacks public or source-private closure slot")
                tlcontext.static_slots[
                node._type.fqtn .. "." .. node._type.name] =
                    node._closure_upvalue
            elseif node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion" then
                tlcontext.nominal_namespace_slots[node._type.name] =
                    nextupvalue(tlcontext)
            end
        end
    end
end

function coder.generate_ffi_header(modname, ast, source_header)
    return require("titan-compiler.ffiheaders").render(modname, ast, source_header)
end

function coder.generate_foreign_header(modname, ast, tlcontext, header_paths)
    local has_foreign = false
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            has_foreign = true
            break
        end
    end
    if not has_foreign then
        return nil
    end

    local guard = "TITAN_GENERATED_FOREIGN_"
        .. coder._source_private_prefix(modname, "header"):upper() .. "_H"
    header_paths = header_paths or {}
    local ffi_header = header_paths.ffi_header or ast._ffi_header_output
        or (ast._ffi_header and ast._ffi_header.filename)
        or (modname:gsub("[.]", "/") .. ".ffi.h")
    local includes = { "#include " .. c_string_literal(ffi_header) }
    local source_headers = {}
    local seen = { [ffi_header] = true }
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelImport"
            and node._source_import and node._foreign_header then
            local header = header_paths.source_header
                and header_paths.source_header(node) or node._foreign_header
            if not seen[header] then
                seen[header] = true
                source_headers[#source_headers + 1] = node.modname
                includes[#includes + 1] = "#include " .. c_string_literal(header)
            end
        end
    end

    local declarations = {}
    local inline_bodies = {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            local inline = node._foreign_inline
            if inline == nil then
                inline = coder._foreign_function_is_inline(node)
                node._foreign_inline = inline
            end
            local signature = coder._foreign_function_signature(node)
            if inline then
                declarations[#declarations + 1] =
                    "static inline " .. signature .. ";"
                inline_bodies[#inline_bodies + 1] =
                    coder._code_foreign_function(tlcontext, node, true)
            else
                declarations[#declarations + 1] =
                    "TITAN_SOURCE_LOCAL " .. signature .. ";"
            end
        end
    end

    local prefix = table.concat({
        "/* Generated by Titan: source foreign function interface. */",
        "#ifndef " .. guard,
        "#define " .. guard,
        "",
    }, "\n")
    local body = table.concat({
        "",
        "#ifndef TITAN_SOURCE_LOCAL",
        "#if defined(__GNUC__) || defined(__clang__)",
        "#define TITAN_SOURCE_LOCAL __attribute__((visibility(\"hidden\")))",
        "#else",
        "#define TITAN_SOURCE_LOCAL",
        "#endif",
        "#endif",
        "",
        table.concat(declarations, "\n\n"),
        "",
        table.concat(inline_bodies, "\n\n"),
        "",
        "#endif /* " .. guard .. " */",
        "",
    }, "\n")
    -- Persist the bodies independently from compiler-owned include paths.
    -- Checking uses logical module paths, while native folder-module headers
    -- live beside the canonical main source.
    return prefix .. "\n" .. table.concat(includes, "\n") .. "\n" .. body,
        { prefix = prefix, body = body, source_headers = source_headers }
end

return core.coder
