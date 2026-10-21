local core = require "titan-compiler.coder.core"
local _ENV = core

-- Closure transfer is a cold operation over an immutable module manifest. The
-- ordinary closure layout and all creation/call paths remain unchanged.
function coder._transfer_register_source(tlcontext, ftype, native, coercive,
                                        strict, captures, loc)
    tlcontext.transfer_entries = tlcontext.transfer_entries or {}
    tlcontext.transfer_by_native = tlcontext.transfer_by_native or {}
    if tlcontext.transfer_by_native[native] then return end
    local entry = {
        kind = "source", ftype = ftype, native = native,
        coercive = coercive, strict = strict, captures = captures or {},
        loc = loc, id = tlcontext.prefix .. "transfer_entry_"
            .. tostring(#tlcontext.transfer_entries),
    }
    tlcontext.transfer_by_native[native] = entry
    tlcontext.transfer_entries[#tlcontext.transfer_entries + 1] = entry
    function_type_tag(tlcontext, ftype)
    return entry
end

function coder._transfer_register_adapter(tlcontext, site)
    local entry = coder._transfer_register_source(tlcontext,
        site.adapter.target, site.native, "NULL", site.strict,
        {{ type = site.adapter.source, boxed = false }},
        site.adapter.location)
    if entry then
        entry.kind = "adapter"
        entry.adapter = site.adapter
    end
    return entry
end

local function project_value(ctx, cap, expression)
    local typ = cap.type
    local resolved = types.resolve_c_typedef(typ)
    if types.is_c_udata_pointer(typ) then
        return "(void)(" .. expression .. ");\n"
            .. "luaL_error(L, \"cannot transfer a captured Lua-managed C pointer\");"
    elseif resolved._tag == "Type.CInteger" or resolved._tag == "Type.CFloat"
       or resolved._tag == "Type.CPointer" then
        return coder._reflection_project_c(ctx, typ, expression)
    elseif typ._tag == "Type.Option" then
        local base = types.resolve_c_typedef(typ.base)
        if types.is_c_udata_pointer(typ.base) then
            return "if (" .. coder._option_present(typ, expression) .. ") {\n"
                .. "luaL_error(L, \"cannot transfer a captured Lua-managed C pointer\");"
                .. "\n} else { lua_pushnil(L); }"
        elseif base._tag == "Type.CInteger" or base._tag == "Type.CFloat"
           or base._tag == "Type.CPointer" then
            return "if (" .. coder._option_present(typ, expression) .. ") {\n"
                .. coder._reflection_project_c(ctx, typ.base,
                    coder._option_get(typ, nil, expression))
                .. "\n} else { lua_pushnil(L); }"
        end
    end
    if not cap.dynamic_plan or cap.dynamic_plan.tag == "none" then
        return "(void)(" .. expression .. ");\n"
            .. "luaL_error(L, \"closure capture has no transfer reconstruction conversion\");"
    end
    return "TValue _projected = {{0}, 0};\n"
        .. setboxed(ctx, typ, "&_projected", expression)
        .. "\nlua_pushtvalue(L, _projected);"
end

local function restore_value(ctx, cap, target)
    local typ = cap.type
    local resolved = types.resolve_c_typedef(typ)
    if types.is_c_udata_pointer(typ) then
        return "luaL_error(L, \"cannot transfer a captured Lua-managed C pointer\");"
    elseif resolved._tag == "Type.CInteger" or resolved._tag == "Type.CFloat"
       or resolved._tag == "Type.CPointer" then
        return coder._reflection_construct_c(ctx, typ, target, "&_value")
    elseif typ._tag == "Type.Option" then
        local base = types.resolve_c_typedef(typ.base)
        if types.is_c_udata_pointer(typ.base) then
            return "if (ttisnil(&_value)) { "
                .. coder._option_nil(typ, target) .. " } else {\n"
                .. "luaL_error(L, \"cannot transfer a captured Lua-managed C pointer\");\n}"
        elseif base._tag == "Type.CInteger" or base._tag == "Type.CFloat"
           or base._tag == "Type.CPointer" then
            local scalar = "_transferred_scalar"
            return "if (ttisnil(&_value)) { "
                .. coder._option_nil(typ, target) .. " } else {\n"
                .. cvardecl(ctx, typ.base, scalar) .. " = " .. initval(typ.base) .. ";\n"
                .. coder._reflection_construct_c(ctx, typ.base, scalar, "&_value")
                .. "\n" .. coder._option_wrap(typ, target, scalar) .. "\n}"
        end
    end
    if not cap.dynamic_plan or cap.dynamic_plan.tag == "none" then
        return "luaL_error(L, \"closure capture has no transfer reconstruction conversion\");"
    end
    return coder._dynamiccheckandget(ctx,
        maybe3.get_checked(cap.dynamic_plan, "closure capture reconstruction"),
        typ, target, "&_value", cap.loc,
        "closure capture reconstruction")
end

local function emit_source_entry(tlcontext, entry)
    local ctx = newcontext(tlcontext)
    local project, restore = {}, {}
    for ordinal, cap in ipairs(entry.captures) do
        local index = ordinal - 1
        local source = "&_fn->upvalue[" .. (4 + index) .. "]"
        local expression
        local prefix = ""
        if cap.boxed then
            prefix = "Udata *_box = uvalue(" .. source .. ");\n"
            expression = box_read(cap.type, "_box")
        else
            expression = getslot(cap.type, nil, source)
        end
        project[#project + 1] = "{\n"
            .. prefix .. project_value(ctx, cap, expression) .. "\n}"

        local convert = cvardecl(ctx, cap.type, "_converted")
            .. " = " .. initval(cap.type) .. ";\n"
            .. restore_value(ctx, cap, "_converted")
        local body
        if cap.boxed then
            body = "lua_pushnil(L);\n"
                .. newbox(ctx, cap.type, "_box", "s2v(L->top.p - 1)") .. "\n"
                .. convert .. "\n" .. box_write(cap.type, "_box", "_converted")
        else
            body = convert .. "\nTValue _slot = {{0}, 0};\n"
                .. setslot(cap.type, "&_slot", "_converted")
                .. "\nlua_pushtvalue(L, _slot);"
        end
        restore[#restore + 1] = "{\nTValue _value = lua_totvalue(L, _capture_base + "
            .. index .. ");\n(void)_value;\n" .. body .. "\n}"
    end
    local copy_captures = ""
    if #entry.captures > 0 then
        copy_captures = render([[
            for (unsigned _i = 0; _i < $COUNT; ++_i) {
                TValue _slot = lua_totvalue(L, _top + 1 + (int)_i);
                setobj2n(L, &_closure->upvalue[4 + _i], &_slot);
            }
        ]], { COUNT = #entry.captures })
    end
    return render([[
        static void ${ID}_project(lua_State *L, CClosure *_fn) {
            if (_fn->nupvalues != $NUP || _fn->f != $COERCIVE)
                luaL_error(L, "closure does not match its transfer entry");
            Udata *_mod = uvalue(&_fn->upvalue[0]);
            (void)_mod;
            $PROJECT
        }
        static void ${ID}_restore(lua_State *L, Udata *_mod, int _capture_base) {
            (void)_mod;
            _capture_base = lua_absindex(L, _capture_base);
            (void)_capture_base;
            int _top = lua_gettop(L);
            /* Convert and root every slot/fresh cell before creating the final
             * closure. Its initialization can then retain the white-object
             * invariant without construction barriers. */
            $CAPTURE
            CClosure *_closure = luaF_newCclosure(L, $NUP);
            _closure->f = $COERCIVE;
            setuvalue(L, &_closure->upvalue[0], _mod);
            setpvalue(&_closure->upvalue[1], (void *)$TAG);
            setpvalue(&_closure->upvalue[2], titan_cast_func(void *, $NATIVE));
            setpvalue(&_closure->upvalue[3], TITAN_BRAND);
            $COPYCAPTURES
            setfvalue(&_closure->upvalue[$STRICT_INDEX], $STRICT);
            setclCvalue(L, s2v(L->top.p), _closure); L->top.p++;
            lua_assert(iswhite(_closure));
            luaC_checkGC(L);
            lua_copy(L, -1, _top + 1);
            lua_settop(L, _top + 1);
        }
    ]], {
        ID = entry.id,
        PROJECT = table.concat(project, "\n"),
        CAPTURE = table.concat(restore, "\n"),
        NUP = #entry.captures + 5,
        COUNT = #entry.captures,
        COPYCAPTURES = copy_captures,
        STRICT_INDEX = #entry.captures + 4,
        COERCIVE = entry.coercive,
        NATIVE = entry.native,
        STRICT = entry.strict,
        TAG = function_type_tag(tlcontext, entry.ftype),
    })
end

local function emit_adapter_entry(tlcontext, entry)
    return render([[
        static void ${ID}_project(lua_State *L, CClosure *_fn) {
            if (_fn->nupvalues < 6)
                luaL_error(L, "invalid adjusted closure capture");
            lua_pushtvalue(L, _fn->upvalue[_fn->nupvalues - 2]);
        }
        static void ${ID}_restore(lua_State *L, Udata *_mod, int _capture_base) {
            _capture_base = lua_absindex(L, _capture_base);
            TValue _source_value = lua_totvalue(L, _capture_base);
            CClosure *_source = ttisCclosure(&_source_value)
                ? clCvalue(&_source_value) : NULL;
            if (_source == NULL || _source->nupvalues < 5
                || _source->nupvalues >= MAXUPVAL
                || !ttislightuserdata(&_source->upvalue[1])
                || pvalue(&_source->upvalue[1]) != $SOURCE_TAG
                || !ttislightuserdata(&_source->upvalue[3])
                || pvalue(&_source->upvalue[3]) != TITAN_BRAND)
                luaL_error(L, "invalid source closure for transferred adjustment");
            unsigned _count = _source->nupvalues;
            CClosure *_closure = luaF_newCclosure(L, _count + 1);
            _closure->f = _source->f;
            for (unsigned _i = 0; _i < _count - 1; ++_i)
                setobj2n(L, &_closure->upvalue[_i], &_source->upvalue[_i]);
            setuvalue(L, &_closure->upvalue[0], _mod);
            setpvalue(&_closure->upvalue[1], (void *)$TARGET_TAG);
            setpvalue(&_closure->upvalue[2], titan_cast_func(void *, $NATIVE));
            setclCvalue(L, &_closure->upvalue[_count - 1], _source);
            setfvalue(&_closure->upvalue[_count], $STRICT);
            lua_assert(iswhite(_closure));
            setclCvalue(L, s2v(L->top.p), _closure); L->top.p++;
            luaC_checkGC(L);
        }
    ]], {
        ID = entry.id,
        NATIVE = entry.native,
        STRICT = entry.strict,
        SOURCE_TAG = function_type_tag(tlcontext, entry.adapter.source),
        TARGET_TAG = function_type_tag(tlcontext, entry.adapter.target),
    })
end

function coder._transfer_emit_entry(tlcontext, code, entry)
    if entry.emitted then return end
    entry.emitted = true
    code[#code + 1] = entry.kind == "adapter"
        and emit_adapter_entry(tlcontext, entry)
        or emit_source_entry(tlcontext, entry)
end

function coder._transfer_emit_sources(tlcontext, code)
    for _, entry in ipairs(tlcontext.transfer_entries or {}) do
        coder._transfer_emit_entry(tlcontext, code, entry)
    end
end

function coder._transfer_emit_manifest(tlcontext, sigs, code)
    local entries = tlcontext.transfer_entries or {}
    local initializers = {}
    for _, entry in ipairs(entries) do
        assert(entry.emitted, "closure transfer entry was not emitted")
        initializers[#initializers + 1] = render([[
            { titan_cast_func(void *, $NATIVE), $STRICT,
              $COUNT, ${ID}_project, ${ID}_restore }
        ]], {
            NATIVE = entry.native,
            STRICT = entry.strict, COUNT = #entry.captures,
            ID = entry.id,
        })
    end
    local array = "NULL"
    if #initializers > 0 then
        array = tlcontext.prefix .. "transfer_entries"
        code[#code + 1] = "static const TitanTransferEntry " .. array
            .. "[] = {\n" .. table.concat(initializers, ",\n") .. "\n};"
    end
    -- Generated nominal codecs are reached through their metatable binding
    -- (TITAN_MT_CODEC); only the immutable entry array is emitted here.
    coder._codec_emit_table(tlcontext, code)
    tlcontext.transfer_manifest = tlcontext.prefix .. "transfer_manifest"
    code[#code + 1] = render([[
        static const TitanTransferModule $MANIFEST = {
            $NAME, $COUNT, $ENTRIES
        };
    ]], {
        MANIFEST = tlcontext.transfer_manifest,
        NAME = c_string_literal(tlcontext.module),
        COUNT = #entries, ENTRIES = array,
    })
end
