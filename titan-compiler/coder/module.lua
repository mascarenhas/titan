local core = require "titan-compiler.coder.core"
local ffiheaders = require "titan-compiler.ffiheaders"
local _ENV = core

preamble = [[
$FIXEDPREFIX

$FOREIGNIMPORTS

$AFTERFOREIGNIMPORTS

$MODULEPRIVATE

/* Native exports must refer to this image's definitions even when another
 * physical provider of the same logical module is mapped in the process.
 * Darwin's ordinary two-level namespace already preserves that binding. */
#if defined(__ELF__)
#pragma GCC visibility push(protected)
#endif

$INCLUDES

$SIGS

]]

-- Opener names are not injective: `a.b-c` and `a.b_c` share luaopen_a_b_c.
-- A file load must therefore request the exact name before any
-- initialization. `require` passes the searcher's loader data as the second
-- argument: the Titan and Lua file searchers pass a path, while
-- `package.preload` passes ":preload:", which deliberately aliases this
-- opener under any name in the requesting state. Direct internal calls pass
-- no loader data at all.
postamble = [[
${DEFLINE}int $LUAOPEN_NAME(lua_State *L) {
    int _file_load = lua_type(L, 2) == LUA_TSTRING;
    if (_file_load) {
        size_t _data_len;
        const char *_data = lua_tolstring(L, 2, &_data_len);
        _file_load = _data_len != sizeof(":preload:") - 1 ||
            memcmp(_data, ":preload:", _data_len) != 0;
    }
    if (_file_load && lua_type(L, 1) == LUA_TSTRING) {
        size_t _requested_len;
        const char *_requested = lua_tolstring(L, 1, &_requested_len);
        if (_requested_len != sizeof($LOGICALNAME) - 1 ||
            memcmp(_requested, $LOGICALNAME, _requested_len) != 0)
            return luaL_error(L, "module name mismatch: requested '%s', "
                "provider defines '%s'", _requested, $LOGICALNAME);
    }
    titan_invalidate_backtrace_state(L);
    Udata *mod = $INITNAME(L);
    setuvalue(L, s2v(L->top.p), mod);
    L->top.p++;
    return 1;
}
]]

modabi = [[
${DEFLINE}int $ABINAME(lua_State* L) {
    lua_pushliteral(L, TITAN_ABI_VERSION);
    return 1;
}

/* Native bootstrap query: callable before a Lua state or module exists. */
${DEFLINE}const char *${ABINAME}_value(void) {
    return TITAN_ABI_VERSION;
}
]]

init = [[
int $LUAOPEN_NAME(lua_State *L);

TITAN_MODULE_PRIVATE void $PRELOADNAME(lua_State *L);

${DEFLINE}TITAN_MODULE_PRIVATE void $PRELOADNAME(lua_State *L) {
    titan_module_preload(L, $PRELOADMODNAME, sizeof($PRELOADMODNAME) - 1,
        $LUAOPEN_NAME, $NATIVERESOLVER);
}
${DEFLINE}Udata *$INITNAME(lua_State *L) {
    titan_ensure_stack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
    if(lua_isnil(L, -1)) {
        lua_pop(L, 1);
        Udata *_mod = luaS_newudata(L, sizeof($NATIVETYPE), $NUPVALS);
        $NATIVETYPE *_native = ($NATIVETYPE *)getudatamem(_mod);
        memset(_native, 0, sizeof(*_native));
        _native->provider.symbols = $NATIVERESOLVER;
        /* Root privately until every dependency check succeeds. A failed
         * require must not publish a partial module that bypasses the check
         * when Lua catches the error and retries. */
        titan_pushmodule(L, _mod);
        $INITRECOVERYSTRINGS
        Table *_titan_metatables = titan_ensure_metatables_table(L);
        (void)_titan_metatables; // in case this module does not publish any types
        $INITSOURCEIDENTITY
        $INITARRAYMETA
        $LOADMODULES1
        $INITMODULES
        $LOADGLOBALS
        lua_setfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
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
        /* The canonical module owns its native bindings as well as its
         * values. A second image must not reinterpret or overwrite them. */
        return _mod;
    }
}
]]

modtypes = [[
${DEFLINE}int $TYPESNAME(lua_State* L) {
    lua_pushliteral(L, $TYPES);
    return 1;
}
]]

coder.modmetadata = [[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#elif defined(__ELF__) || defined(_WIN32) || defined(__wasm__)
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
-- Implementation notes: doc/implementation/codegen-overview.md#static-vs-dynamic-dependency-wiring
function import_module(loadmods, initmods, sigs, mprefixes,
                       dynamic, node, tlcontext)
    local modname = node.modname
    local upvalue = node._upvalue
    local mprefix = mangle_qn(modname) .. "_"
    local public_layout = coder._public_prefix_layout(node._type)
    local source_check = ""
    local first_import = mprefixes[modname] == nil
    mprefixes[modname] = mprefix
    if not dynamic then
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
        -- Aliases keep separate module slots but share one canonical handle.
        if first_import then
            table.insert(loadmods,
                "TitanModuleProvider " .. mprefix .. "provider;")
        end
        local compatibility = coder._binary_check(tlcontext, modname,
            mprefix .. "provider", file)
        table.insert(initmods, render([[
            {
                /* An earlier import may initialize an embedded copy of this
                 * module. Elect/check each provider immediately before init. */
                $HANDLE = titan_module_provider(L, $MODULE, $FILE);
                titan_check_module_abi(L, $HANDLE, "$ABI", $FILE);
                $COMPATIBILITY
                Udata* (*$INIT)(lua_State *L) = titan_cast_func(Udata* (*)(lua_State*), titan_module_symbol(L, $HANDLE, "$INIT"));
                Udata *_m = $INIT(L);
                TitanModuleProvider _canonical =
                    titan_module_provider(L, $MODULE, NULL);
                if (_canonical.symbols != $HANDLE.symbols) {
                    $HANDLE = _canonical;
                    titan_check_module_abi(L, $HANDLE, "$ABI", $FILE);
                    $COMPATIBILITY
                }
                setuvalue(L, &_mod->uv[$INDEX].uv, _m);
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            }
        ]], {
            HANDLE = mprefix .. "provider",
            MODULE = c_string_literal(modname),
            FILE = c_string_literal(file),
            ABI = mprefix .. "abi",
            COMPATIBILITY = compatibility,
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

function init_data_from_other_modules(tlcontext, includes, binding_defs, loadmods,
                                      loadglobals, initmetas, mprefixes,
                                      static_deps)
    -- Imported addresses belong to this Lua state's importer userdata. The
    -- canonical owner may differ between states using the same consumer image.
    local function bind(module, name, declaration, pointer_type)
        if static_deps[module] == true then
            table.insert(includes, "extern " .. declaration .. ";")
            return
        end
        tlcontext.native_fields[name] = declaration .. ";"
        local prefix = mprefixes[module]
        table.insert(loadglobals, render([[
            $TARGET = titan_cast_func($TYPE,
                titan_module_symbol(L, $PROVIDER, $SYMBOL));
        ]], {
            TARGET = coder._module_native_ref(tlcontext, name),
            TYPE = pointer_type,
            PROVIDER = (prefix or mangle_qn(module) .. "_") .. "provider",
            SYMBOL = c_string_literal(coder._linkage_symbol_name(name)),
        }))
    end
    for _, key in ipairs(coder._sorted_keys(tlcontext.functions)) do
        local func = tlcontext.functions[key]
        local dynamic = static_deps[func.module] ~= true
        bind(func.module, func.mangled,
            function_sig(func.mangled, func.type, dynamic),
            function_sig("", func.type, true))
    end
    -- Raw C functions have no implicit state argument. Bind their imported
    -- addresses once per physical consumer image, using the same checked
    -- canonical providers as ordinary Titan imports. Publication is atomic:
    -- independent states may initialize shared code concurrently, but none
    -- may redirect an address already visible to a raw callback.
    for _, func in ipairs(coder._sorted_foreign_imports(tlcontext)) do
        local pointer = types.CPointer(func.type, {})
        local binding_decl = cdeclarator.render_declaration(pointer, func.binding)
        coder._record_private_symbol(tlcontext, func.binding,
            "foreign function binding '" .. func.module .. "." .. func.name .. "'")
        table.insert(includes, "extern TITAN_SOURCE_LOCAL "
            .. binding_decl .. ";")
        table.insert(binding_defs, "TITAN_SOURCE_LOCAL "
            .. binding_decl .. " = NULL;")
        local candidate
        if static_deps[func.module] == true then
            table.insert(includes, "extern "
                .. cdeclarator.render_declaration(func.type, func.mangled)
                .. ";")
            candidate = func.mangled
        else
            local provider = (mprefixes[func.module]
                or mangle_qn(func.module) .. "_") .. "provider"
            candidate = "titan_cast_func("
                .. cdeclarator.render_declaration(pointer, "")
                .. ", titan_module_symbol(L, " .. provider .. ", "
                .. c_string_literal(coder._linkage_symbol_name(func.mangled))
                .. "))"
        end
        table.insert(loadglobals, render([[
            {
                $CANDIDATE_DECL = $CANDIDATE;
                $EXPECTED_DECL = NULL;
                if (!__atomic_compare_exchange_n(&$BINDING, &_expected,
                        _candidate, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)
                    && _expected != _candidate) {
                    luaL_error(L, $ERROR);
                }
            }
        ]], {
            CANDIDATE_DECL = cdeclarator.render_declaration(pointer, "_candidate"),
            EXPECTED_DECL = cdeclarator.render_declaration(pointer, "_expected"),
            CANDIDATE = candidate,
            BINDING = func.binding,
            ERROR = c_string_literal("foreign function '" .. func.module
                .. "." .. func.name
                .. "' has a different native binding in this consumer image"),
        }))
    end
    for _, name in ipairs(coder._sorted_keys(tlcontext.bound_luas)) do
        local info = tlcontext.bound_luas[name]
        local declaration = static_deps[info.module] == true
            and ("int " .. name .. "(lua_State *L)")
            or ("int (*" .. name .. ")(lua_State *L)")
        bind(info.module, name, declaration, "int (*)(lua_State *L)")
    end
    for _, name in ipairs(coder._sorted_keys(tlcontext.bound_stricts)) do
        local info = tlcontext.bound_stricts[name]
        local declaration = static_deps[info.module] == true
            and ("int " .. name .. "(lua_State *L)")
            or ("int (*" .. name .. ")(lua_State *L)")
        bind(info.module, name, declaration, "int (*)(lua_State *L)")
    end

    for _, fqtn in ipairs(coder._sorted_keys(tlcontext.metatables)) do
        local entry = tlcontext.metatables[fqtn]
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

    for _, module in ipairs(coder._sorted_keys(tlcontext.modules)) do
        local upvalue = tlcontext.modules[module]
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

-- Implementation notes: doc/implementation/lua-interop-internals.md#records-from-lua
function coderecorddec(ctx, sigs, code, initrecs, node)
    local tlcontext = ctx.tlcontext or ctx
    local projector, constructor = coder._reflection_metadata(ctx, sigs, code, node)
    -- (the type tag is forward-declared up front in generate(), so that
    -- forward/mutually-recursive record field types resolve)
    local plan = coder._nominal_plan(ctx, node._type)
    local fieldmap = {}
    for _, field in ipairs(node._type.fields) do
        if not field.islocal then
            local accessor = coder._nominal_function_prefix(
                node._type.name, field.name) .. "_fieldaccessor"
            coder._record_private_symbol(tlcontext, accessor,
                "record field '" .. node._type.name .. "." .. field.name .. "' accessor")
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
            elseif field.dynamic_plan.tag == "none" then
                write = coder._dynamiccheckandget(ctx, nil, field.type,
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
                        ctx, maybe3.get_checked(field.dynamic_plan, "record field writer"), field.type, converted, "tv",
                        node.loc, "Lua record-field write"),
                    STORE = coder._nominal_store(ctx, plan, slot,
                        field.type, "_rec", converted),
                })
            end
            table.insert(sigs, render([[
                TITAN_MODULE_PRIVATE void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_rec, TValue *tv, int write);
            ]], { ACCESSOR = accessor }))
            table.insert(code, definitionline(node.loc) .. render([[
                TITAN_MODULE_PRIVATE void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_rec, TValue *tv, int write) {
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
    for _, name in ipairs(coder._sorted_keys(node._type.methods)) do
        local method = node._type.methods[name]
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
    local indexname = coder._nominal_metamethod_name(node._type.name, "index")
    local newindexname = coder._nominal_metamethod_name(node._type.name, "newindex")
    coder._record_private_symbol(tlcontext, indexname,
        "record '" .. node._type.name .. "' __index")
    coder._record_private_symbol(tlcontext, newindexname,
        "record '" .. node._type.name .. "' __newindex")
    table.insert(sigs, render([[
        TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L);
        TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L);
    ]], {
        INDEXNAME = indexname,
        NEWINDEXNAME = newindexname,
    }))
    table.insert(code, render([[
            ${DEFLINE}TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L) {
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
            ${DEFLINE}TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L) {
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
            DEFLINE = definitionline(node.loc),
            INDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "index"),
            NEWINDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "newindex"),
            CHECKANDGET = coder._dynamiccheckandget(
                ctx, assert(node._dynamic_receiver_plan,
                    "record receiver lacks its Lua boundary plan"),
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
        lua_pushboolean(L, $PUBLIC);
        lua_rawsetp(L, -2, TITAN_MT_PUBLIC);
        lua_pushlightuserdata(L, titan_cast_func(void *, $PROJECTOR));
        lua_rawsetp(L, -2, TITAN_MT_PROJECT);
        lua_pushlightuserdata(L, titan_cast_func(void *, $CONSTRUCTOR));
        lua_rawsetp(L, -2, TITAN_MT_CONSTRUCT);
        $CODEC
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
        TAG = c_string_literal(types.serialize_semantic(node._declared_type or node._type)),
        PUBLIC = node.islocal and "0" or "1",
        PROJECTOR = projector,
        CONSTRUCTOR = constructor,
        FIELDMAP = table.concat(fieldmap, "\n"),
        CODEC = coder._codec_binding(ctx, node),
    }))
end

-- Generate the Lua-facing metatable for a union. Variants, tags, and payloads
-- are opaque; only public methods participate in lookup, and all writes fail.
-- Implementation notes: doc/implementation/unions.md#functions-namespaces-and-lua-exposure
function coder._codeuniondec(ctx, sigs, code, initnominals, node)
    local tlcontext = ctx.tlcontext or ctx
    local projector, constructor = coder._reflection_metadata(ctx, sigs, code, node)
    local payload_reader = coder._nominal_function_prefix(
        node._type.name, "payload_reader")
    coder._record_private_symbol(tlcontext, payload_reader,
        "union '" .. node._type.name .. "' payload reader")
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
    table.insert(sigs, render([[
        TITAN_MODULE_PRIVATE void $READER(lua_State *L, Udata *_union, lua_Integer part,
                                          TValue *tv);
    ]], { READER = payload_reader }))
    table.insert(code, definitionline(node.loc) .. render([[
        TITAN_MODULE_PRIVATE void $READER(lua_State *L, Udata *_union, lua_Integer part,
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

    local indexname = coder._nominal_metamethod_name(node._type.name, "index")
    local newindexname = coder._nominal_metamethod_name(node._type.name, "newindex")
    coder._record_private_symbol(tlcontext, indexname,
        "union '" .. node._type.name .. "' __index")
    coder._record_private_symbol(tlcontext, newindexname,
        "union '" .. node._type.name .. "' __newindex")
    table.insert(sigs, render([[
        TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L);
        TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L);
    ]], {
        INDEXNAME = indexname,
        NEWINDEXNAME = newindexname,
    }))
    table.insert(code, render([[
        ${DEFLINE}TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L) {
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

        ${DEFLINE}TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L) {
            return luaL_error(L,
                "%s:%d:%d: cannot assign member '%s' in union '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }
    ]], {
        DEFLINE = definitionline(node.loc),
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        CHECKANDGET = coder._dynamiccheckandget(
            ctx, assert(node._dynamic_receiver_plan,
                "union receiver lacks its Lua boundary plan"),
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
            lua_pushboolean(L, $PUBLIC);
            lua_rawsetp(L, -2, TITAN_MT_PUBLIC);
            lua_pushlightuserdata(L, titan_cast_func(void *, $PROJECTOR));
            lua_rawsetp(L, -2, TITAN_MT_PROJECT);
            lua_pushlightuserdata(L, titan_cast_func(void *, $CONSTRUCTOR));
            lua_rawsetp(L, -2, TITAN_MT_CONSTRUCT);
            $CODEC
            titan_pushmodule(L, _mod);
            lua_rawsetp(L, -2, TITAN_MT_MOD);
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
        TAG = c_string_literal(types.serialize_semantic(node._declared_type or node._type)),
        PAYLOAD_READER = payload_reader,
        PUBLIC = node.islocal and "0" or "1",
        PROJECTOR = projector,
        CONSTRUCTOR = constructor,
        METHODMAP = table.concat(methodmap, "\n"),
        CODEC = coder._codec_binding(ctx, node),
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
    register_trace_entry(tlcontext, bound_luaname)
    local payload_name = "_titan_interface_payload"
    local rettype = method.rettypes[1]

    -- The ordinary method entry belongs to the Interface owner and therefore
    -- checks/coerces the public Interface signature with that owner's `_mod`.
    -- Its final call is parameterized to read uv[0]/uv[1] and invoke the copied
    -- payload slot directly with `_fn = NULL`.
    coder._record_private_symbol(tlcontext, luaname,
        "interface method '" .. interface.name .. ":" .. method.name .. "' Lua entry")
    table.insert(sigs, "TITAN_MODULE_PRIVATE int " .. luaname .. "(lua_State *L);")
    table.insert(code, genluaentry(
        tlcontext, interface.name .. ":" .. method.name, "",
        method, method_node.loc, luaname, {
            dynamic_plans = method_node._lua_dynamic_plans,
            dynamic_vararg_plan =
                method_node._lua_vararg_dynamic_plan,
            interface_method_index = index,
            native_carrier_entry = nativename,
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
        ${DEFLINE}$NATIVE_SIG {
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

        ${DEFLINE}int $BOUND_LUA(lua_State *L) {
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
        DEFLINE = definitionline(method_node.loc),
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
    coder._transfer_register_source(tlcontext, ftype,
        nativename, bound_luaname, strictname, {{
            type = types.Nominal(interface.name), boxed = false,
            dynamic_plan = method_node._lua_dynamic_plans[1],
            loc = method_node.loc,
        }}, method_node.loc)
end

-- Interface declarations are type-only, but their owner module publishes one
-- protected per-state metatable and all method/bound dispatch artifacts.
-- Implementation notes: doc/implementation/interfaces.md#metatable-identity-and-dynamic-boundaries
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

    local tlcontext = ctx.tlcontext or ctx
    local membermap = {}
    for _, field in ipairs(interface.fields) do
        local accessor = coder._nominal_function_prefix(
            interface.name, field.name) .. "_fieldaccessor"
        coder._record_private_symbol(tlcontext, accessor,
            "interface field '" .. interface.name .. "." .. field.name .. "' accessor")
        table.insert(membermap, render([[
            lua_pushliteral(L, $NAME);
            lua_pushlightuserdata(L, titan_cast_func(void *, $ACCESSOR));
            lua_rawset(L, -3);
        ]], {
            NAME = c_string_literal(field.name),
            ACCESSOR = accessor,
        }))
        table.insert(sigs, render([[
            TITAN_MODULE_PRIVATE void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_interface, TValue *tv, int write);
        ]], { ACCESSOR = accessor }))
        table.insert(code, definitionline(node.loc) .. render([[
            TITAN_MODULE_PRIVATE void $ACCESSOR(lua_State *L, Udata *_mod, Udata *_interface, TValue *tv, int write) {
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
    local indexname = coder._nominal_metamethod_name(interface.name, "index")
    local newindexname = coder._nominal_metamethod_name(interface.name, "newindex")
    coder._record_private_symbol(tlcontext, indexname,
        "interface '" .. interface.name .. "' __index")
    coder._record_private_symbol(tlcontext, newindexname,
        "interface '" .. interface.name .. "' __newindex")
    table.insert(sigs, render([[
        TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L);
        TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L);
    ]], {
        INDEXNAME = indexname,
        NEWINDEXNAME = newindexname,
    }))
    table.insert(code, render([[
        ${DEFLINE}TITAN_MODULE_PRIVATE int $INDEXNAME(lua_State *L) {
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

        ${DEFLINE}TITAN_MODULE_PRIVATE int $NEWINDEXNAME(lua_State *L) {
            return luaL_error(L,
                "%s:%d:%d: cannot assign member '%s' in interface '%s'",
                $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
        }
    ]], {
        DEFLINE = definitionline(node.loc),
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
        TAG = c_string_literal(types.serialize_semantic(node._declared_type or interface)),
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
-- Native bindings and canonical function tags live in the module's native
-- payload; they are private to the Lua state that owns this userdata.
-- Implementation notes: doc/implementation/codegen-overview.md#user-value-allocation
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

local function render_foreign_header(modname, ast, tlcontext, header_paths,
        policy)
    tlcontext = tlcontext or { module = modname }
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
    local source_paths = {}
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
                source_paths[node.modname] = header
            end
        end
    end

    local declarations = {}
    local inline_bodies = {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            local signature = coder._foreign_function_signature(node)
            declarations[#declarations + 1] =
                (node.islocal and "TITAN_SOURCE_LOCAL " or "extern ")
                .. signature .. ";"
            if node.islocal then
                declarations[#declarations + 1] = "static inline "
                    .. coder._foreign_function_signature(node,
                        coder._foreign_inline_name(modname, node.name)) .. ";"
                inline_bodies[#inline_bodies + 1] =
                    coder._code_foreign_inline(tlcontext, node)
            end
        end
    end

    -- A copied inline callback uses its declaring module's initialized slot,
    -- never an uninitialized translation-unit-local copy. These hidden names
    -- are source-private implementation details, absent from public metadata.
    for _, func in ipairs(coder._sorted_foreign_imports(tlcontext)) do
        declarations[#declarations + 1] = "extern TITAN_SOURCE_LOCAL "
            .. cdeclarator.render_declaration(
                types.CPointer(func.type, {}), func.binding) .. ";"
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
    -- live beside the canonical main source. The emission policy is part of
    -- the recipe: it decides the rendered bodies, and a change must invalidate
    -- an already prepared header through the certificate digests.
    local recipe = { prefix = prefix, body = body, source_headers = source_headers,
        policy = { line_directives = policy.line_directives, coverage = policy.coverage } }
    return ffiheaders.foreign_contents(recipe, ffi_header, function(name)
        return assert(source_paths[name])
    end), recipe
end

-- Canonical identity of one foreign-header recipe (rendered text, source-header
-- module list, emission policy); header paths are environment, not content.
function coder._foreign_header_digest(recipe)
    return ffiheaders.foreign_recipe_digest(recipe)
end

-- Headers are rendered before (and, for restored plans, independently of) C
-- generation, so the caller supplies the current line/coverage policy instead
-- of relying on flags a previous generation happened to leave behind.
function coder.generate_foreign_header(
        modname, ast, tlcontext, header_paths, policy)
    assert(type(policy) == "table"
        and type(policy.line_directives) == "boolean"
        and type(policy.coverage) == "boolean",
        "foreign-header generation requires an explicit emission policy")
    return coder._with_emission_policy(policy, render_foreign_header,
        modname, ast, tlcontext, header_paths, policy)
end

return core.coder
