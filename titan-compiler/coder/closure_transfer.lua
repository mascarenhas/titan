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
        project[#project + 1] = "case " .. index .. ": {\n"
            .. prefix .. project_value(ctx, cap, expression) .. "\nreturn; }"

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
        restore[#restore + 1] = "case " .. index .. ": {\n" .. body .. "\nreturn; }"
    end
    local init_captures, copy_captures = "", ""
    if #entry.captures > 0 then
        init_captures = render([[
            for (unsigned _i = 0; _i < $COUNT; ++_i)
                setnilvalue(&_closure->upvalue[4 + _i]);
        ]], { COUNT = #entry.captures })
        copy_captures = render([[
            for (unsigned _i = 0; _i < $COUNT; ++_i) {
                lua_rawgeti(L, _slots, (lua_Integer)_i + 1);
                setobj2n(L, &_closure->upvalue[4 + _i], s2v(L->top.p - 1));
                lua_pop(L, 1);
            }
        ]], { COUNT = #entry.captures })
    end
    return render([[
        static void ${ID}_project(lua_State *L, CClosure *_fn,
                                 unsigned _index) {
            Udata *_mod = uvalue(&_fn->upvalue[0]);
            (void)_mod;
            titan_ensure_stack(L, 2);
            switch (_index) {
                $PROJECT
                default: luaL_error(L, "invalid closure capture index");
            }
        }
        static void ${ID}_capture(lua_State *L, Udata *_mod,
                                 unsigned _index, int _value_index) {
            (void)_mod;
            TValue _value = lua_totvalue(L, _value_index);
            (void)_value;
            titan_ensure_stack(L, 2);
            switch (_index) {
                $CAPTURE
                default: luaL_error(L, "invalid closure capture index");
            }
        }
        static void ${ID}_restore(lua_State *L, Udata *_mod, int _slots) {
            _slots = lua_absindex(L, _slots);
            titan_ensure_stack(L, 2);
            CClosure *_closure = luaF_newCclosure(L, $NUP);
            _closure->f = $COERCIVE;
            setuvalue(L, &_closure->upvalue[0], _mod);
            setpvalue(&_closure->upvalue[1], (void *)$TAG);
            setpvalue(&_closure->upvalue[2], titan_cast_func(void *, $NATIVE));
            setpvalue(&_closure->upvalue[3], TITAN_BRAND);
            $INITCAPTURES
            setfvalue(&_closure->upvalue[$STRICT_INDEX], $STRICT);
            setclCvalue(L, s2v(L->top.p), _closure); L->top.p++;
            $COPYCAPTURES
            lua_assert(iswhite(_closure));
            luaC_checkGC(L);
        }
    ]], {
        ID = entry.id,
        PROJECT = table.concat(project, "\n"),
        CAPTURE = table.concat(restore, "\n"),
        NUP = #entry.captures + 5,
        COUNT = #entry.captures,
        INITCAPTURES = init_captures,
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
        static void ${ID}_project(lua_State *L, CClosure *_fn,
                                 unsigned _index) {
            if (_index != 0 || _fn->nupvalues < 6)
                luaL_error(L, "invalid adjusted closure capture");
            titan_ensure_stack(L, 1);
            lua_pushtvalue(L, _fn->upvalue[_fn->nupvalues - 2]);
        }
        static void ${ID}_capture(lua_State *L, Udata *_mod,
                                 unsigned _index, int _value_index) {
            (void)_mod;
            if (_index != 0)
                luaL_error(L, "invalid adjusted closure capture index");
            lua_pushvalue(L, _value_index);
        }
        static void ${ID}_restore(lua_State *L, Udata *_mod, int _slots) {
            _slots = lua_absindex(L, _slots);
            titan_ensure_stack(L, 2);
            lua_rawgeti(L, _slots, 1);
            TValue _source_value = lua_totvalue(L, -1);
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
            setclCvalue(L, s2v(L->top.p - 1), _closure);
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
        local boxed = {}
        for _, capture in ipairs(entry.captures) do
            boxed[#boxed + 1] = capture.boxed and "1" or "0"
        end
        local boxed_name = "NULL"
        if #boxed > 0 then
            boxed_name = entry.id .. "_boxed"
            code[#code + 1] = "static const unsigned char " .. boxed_name
                .. "[] = { " .. table.concat(boxed, ", ") .. " };"
        end
        initializers[#initializers + 1] = render([[
            { titan_cast_func(void *, $NATIVE), $COERCIVE, $STRICT,
              $COUNT, $BOXED, ${ID}_project, ${ID}_capture, ${ID}_restore, $KIND }
        ]], {
            NATIVE = entry.native, COERCIVE = entry.coercive,
            STRICT = entry.strict, COUNT = #entry.captures,
            BOXED = boxed_name, ID = entry.id,
            KIND = entry.kind == "adapter"
                and "TITAN_TRANSFER_ADAPTER" or "TITAN_TRANSFER_SOURCE",
        })
    end
    local array = "NULL"
    if #initializers > 0 then
        array = tlcontext.prefix .. "transfer_entries"
        code[#code + 1] = "static const TitanTransferEntry " .. array
            .. "[] = {\n" .. table.concat(initializers, ",\n") .. "\n};"
    end
    tlcontext.transfer_manifest = tlcontext.prefix .. "transfer_manifest"
    sigs[#sigs + 1] = "Udata *" .. tlcontext.prefix .. "init(lua_State *L);"
    code[#code + 1] = render([[
        static const TitanTransferModule $MANIFEST = {
            $NAME, $INIT, $SYMBOLS, $COUNT, $ENTRIES
        };
    ]], {
        MANIFEST = tlcontext.transfer_manifest,
        NAME = c_string_literal(tlcontext.module),
        INIT = tlcontext.prefix .. "init",
        SYMBOLS = tlcontext.prefix .. "native_symbol",
        COUNT = #entries, ENTRIES = array,
    })
end
