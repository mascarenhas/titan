local core = require "titan-compiler.coder.core"
local _ENV = core

-- Code generation consumes only the ordinary erased checker product. Detached
-- generic surface graphs live exclusively in private source metadata on the
-- module and its declarations; following the checked AST recursively is not
-- safe because declaration and type annotations contain cycles. Keep this walk
-- iterative, identity-aware, and bounded so the entry assertion itself cannot
-- overflow the Lua stack or chase an accidentally unbounded graph.
function coder._assert_erased_boundary(ast)
    local max_tables = 1000000

    local function nonempty(value)
        if value == nil or value == false then return false end
        return type(value) ~= "table" or next(value) ~= nil
    end

    local function generic_reason(value)
        local tag = rawget(value, "_tag")
        if tag == "Type.GenericScope"
            or tag == "Type.TypeParameter"
            or tag == "Type.Parameter"
            or tag == "Type.FunctionScheme"
            or tag == "Type.GenericAlias" then
            return "generic type form " .. tag
        elseif tag == "Type.Nominal" and nonempty(rawget(value, "args")) then
            return "generic type form " .. tag
        elseif (tag == "Type.Record" or tag == "Type.Union"
                or tag == "Type.Interface" or tag == "Type.Method"
                or tag == "Type.StaticMethod")
            and (nonempty(rawget(value, "scope"))
                or nonempty(rawget(value, "typeparams"))) then
            return "generic type form " .. tag
        elseif tag == "Type.Inference" or tag == "Type.InferenceCell"
            or tag == "Inference" or tag == "Inference.Cell" then
            return "generic inference form " .. tag
        elseif tag == "Ast.TypeParam" then
            return "generic AST form " .. tag
        elseif type(tag) == "string" and tag:sub(1, 4) == "Ast." then
            for _, field in ipairs({
                "typeparams", "typeargs", "_nominal_typeargs" }) do
                if nonempty(rawget(value, field)) then
                    return "generic AST field '" .. field .. "' on " .. tag
                end
            end
        elseif type(tag) == "string"
            and (tag:find("Inference", 1, true)
                or tag:find("TypeVariable", 1, true)) then
            return "generic inference form " .. tag
        end
        return nil
    end

    local function walk(root_value, label, skip_declared_type)
        local pending = {}
        local seen = {}
        local scheduled = 0

        local function enqueue(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            scheduled = scheduled + 1
            if scheduled > max_tables then
                error("coder erased-boundary " .. label
                    .. " exceeds its bounded graph budget", 3)
            end
            pending[#pending + 1] = value
        end

        enqueue(root_value)
        while #pending > 0 do
            local value = pending[#pending]
            pending[#pending] = nil
            local reason = generic_reason(value)
            if reason then
                error(reason .. " reached coder through " .. label, 3)
            end
            local tag = rawget(value, "_tag")
            for key, child in next, value do
                local semantic_type_binding = key == "_decl" and
                    (tag == "Ast.TypeName" or
                        tag == "Ast.TypeQualName" or
                        tag == "Ast.TypeParam")
                if not (skip_declared_type and
                        (key == "_declared_type" or
                            key == "_declared_registry" or
                            key == "_erased_registry" or
                            key == "_surface_typeparams" or
                            key == "_surface_typeargs" or
                            key == "_declared_method" or
                            key == "_resolved_typearg" or
                            key == "_surface_named_args" or
                            semantic_type_binding)) then
                    enqueue(key)
                    enqueue(child)
                end
            end
        end
    end

    walk(ast, "code-facing AST", true)
    walk(types.registry, "active type registry", false)
end

function coder.generate(modname, ast, static_deps, abi, emit_line_directives, options)
    -- Omission preserves the historical default. Reset this before any
    -- validation that may fail so a previous invocation's policy never leaks
    -- into the next generation.
    coder._emit_line_directives = emit_line_directives ~= false
    assert(type(abi) == "string" and abi ~= "",
        "coder.generate requires the compiled-module ABI")
    local staticmetadata = require "titan-compiler.staticmetadata"
    assert(staticmetadata.valid_module_name(modname),
        "coder.generate requires a valid logical module name")
    if ast._erased_registry then
        types.registry = ast._erased_registry
    end
    coder._assert_erased_boundary(ast)
    local tlcontext = {
        module = modname,
        prefix = mangle_qn(modname) .. "_",
        variables = {},
        metatables = {},
        owned_c_metatables = {},
        functions = {},
        modules = {},
        -- ABI-family-prefixed diagnostic spelling -> { id, key, registry_key }.
        -- The prefix distinguishes C-bearing from C-free callable shapes whose
        -- human-readable type strings happen to collide.
        functags = {},
        functag_list = {},            -- same entries, in allocation order (for emission)
        functag_count = 0,
        array_writer_list = {},       -- constructed Array element policies
        array_writer_count = 0,
        interface_pairs = {},         -- canonical concrete/interface key -> exact pair
        interface_pair_list = {},     -- pair entries in discovery order
        callable_adapters = {},       -- frozen plan object -> translation-unit site
        callable_adapter_list = {},   -- growing discovery-order site registry
        callable_adapter_count = 0,
        bound_luas = {},              -- mangled bound-Lua-trampoline name -> { module }
        bound_stricts = {},           -- mangled bound-strict-entry name -> { module }
        static_slots = {},            -- "fqtn.name" -> module upvalue slot of a static's closure
        nominal_namespace_slots = {}, -- nominal fqtn -> module uv slot of its static-namespace table
        lambdas = {},                 -- ExpFunction nodes pending file-scope emission
        lambda_count = 0,             -- counter for unique lambda native/Lua names
        names = {},                   -- { native C symbol, qualified Titan name } pairs for the trace name table
        source_foreign_headers = {},
        nominal_plans = {},
        nominal_plan_list = {},
        imported_nominal_layouts = options and options.nominal_layouts or {},
        upvalue = 0
    }

    local funcs = {}
    local initvars = {}
    local includes = {}
    local sigs = {}
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

    local source_identity = coder._source_module_identity_name(modname)
    table.insert(sigs, render([[
        TITAN_SOURCE_LOCAL const void *$IDENTITY(void) {
            static const char token = 0;
            return &token;
        }
    ]], { IDENTITY = source_identity }))

    for _, node in ipairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelImport" then
                import_module(loadmods, initmods, sigs, mprefixes,
                    static_deps[node.modname] ~= true, node)
                if node._foreign_header then
                    tlcontext.source_foreign_headers[#tlcontext.source_foreign_headers + 1] =
                        node._foreign_header
                end
            elseif tag == "Ast.TopLevelVar" then
                codevardec(initctx, initvars, switch_get, switch_set, gvar_map, node)
            elseif tag == "Ast.TopLevelRecord" then
                coder._nominal_plan(initctx, node._type)
                coderecorddec(initctx, code, initrecs, node)
            elseif tag == "Ast.TopLevelUnion" then
                for _, variant in ipairs(node._type.variants) do
                    coder._nominal_plan(initctx, node._type, variant)
                end
                coder._codeuniondec(initctx, code, initrecs, node)
            elseif tag == "Ast.TopLevelInterface" then
                coder._codeinterfacedec(
                    initctx, sigs, code, initrecs, node)
            end
        end
    end

    -- Create each nominal's static-namespace table (what `m.Rec`/`m.Union`
    -- returns) before statics run, then expose public nominals as read-only
    -- module members.
    for _, node in ipairs(ast) do
        if not node._ignore
            and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion") then
            local slot = tlcontext.nominal_namespace_slots[node._type.name]
            table.insert(funcs, render([[
                lua_newtable(L);
                {
                  // set nominal_metatable[TITAN_MT_STATICS] = <statics table>
                  TValue _vmeta;
                  TString *_name = luaS_new(L, $NAME);
                  lu_byte tag = luaH_getstr(_titan_metatables, _name, &_vmeta);
                  (void)tag;
                  Table *_meta = hvalue(&_vmeta);
                  lua_assert(!tagisempty(tag));
                  TValue _key;
                  setpvalue(&_key, TITAN_MT_STATICS);
                  luaH_set(L, _meta, &_key, s2v(L->top.p - 1));
                  invalidateTMcache(_meta);
                  luaC_barrierback(L, obj2gco(_meta), s2v(L->top.p - 1));
                }
                setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                lua_pop(L, 1);
            ]], {
                NAME = c_string_literal(node._type.name),
                SLOT = c_integer_literal(slot),
            }))
            if not node.islocal then
                register_readonly_member(node.name, slot)
            end
        end
    end

    for _, node in ipairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelForeignFunc" then
                node._foreign_inline = coder._foreign_function_is_inline(node)
                if not ast._foreign_header_output then
                    if node._foreign_inline then
                        table.insert(sigs,
                            coder._code_foreign_function(tlcontext, node, true))
                    else
                        table.insert(sigs, "TITAN_SOURCE_LOCAL "
                            .. coder._foreign_function_signature(node) .. ";")
                    end
                end
                if not node._foreign_inline then
                    table.insert(code,
                        coder._code_foreign_function(tlcontext, node, false))
                end
            elseif tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic" then
                codefuncdec(tlcontext, node)
                table.insert(sigs, node._sig)
                table.insert(code, node._body)
                if tag == "Ast.TopLevelFunc" and not node.islocal then
                    table.insert(code, node._luabody)
                    table.insert(code, node._strictbody)
                    if node._closure_upvalue then
                        -- Build the canonical closure once into its shadow slot;
                        -- `m.f` is served from that same slot via the module
                        -- metatable, so internal references and `m.f` denote one
                        -- identity. The closure carries its function-type tag
                        -- (upvalue[1]), native entry pointer (upvalue[2]),
                        -- fixed closure brand (upvalue[3]), and trailing strict
                        -- entry (upvalue[4]).
                        table.insert(funcs, render([[
                            titan_pushmodule(L, _mod);
                            lua_pushlightuserdata(L, (void*)$FUNCTAG);
                            lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                            lua_pushlightuserdata(L, TITAN_BRAND);
                            lua_pushcfunction(L, $STRICTNAME);
                            lua_pushcclosure(L, $LUANAME, 5);
                            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                            lua_pop(L, 1);
                        ]], {
                            LUANAME = func_luaname(
                                tlcontext.module, node.name, node.islocal),
                            SLOT = c_integer_literal(node._closure_upvalue),
                            FUNCTAG = function_type_tag(tlcontext, node._type),
                            NATIVE = func_name(
                                tlcontext.module, node.name, node.islocal),
                            STRICTNAME = coder._func_strictname(
                                tlcontext.module, node.name, node.islocal),
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
                    table.insert(code, node._strictbody)
                    table.insert(funcs, render([[
                        titan_pushmodule(L, _mod);
                        lua_pushlightuserdata(L, (void*)$FUNCTAG);
                        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                        lua_pushlightuserdata(L, TITAN_BRAND);
                        lua_pushcfunction(L, $STRICTNAME);
                        lua_pushcclosure(L, $LUANAME, 5);
                        setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                        luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                        lua_pop(L, 1);
                    ]], {
                        LUANAME = func_luaname(
                            tlcontext.module, node.name, node.islocal),
                        SLOT = c_integer_literal(node._closure_upvalue),
                        FUNCTAG = function_type_tag(tlcontext, node._type),
                        NATIVE = func_name(
                            tlcontext.module, node.name, node.islocal),
                        STRICTNAME = coder._func_strictname(
                            tlcontext.module, node.name, node.islocal),
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
                    table.insert(code, node._strictbody)
                    -- Build the static's canonical 5-upvalue closure once into
                    -- its shadow slot. Public statics are also installed into
                    -- the record's static-namespace table; local record functions remain
                    -- reachable to Titan code through direct/static-slot paths.
                    local closure_init
                    if node.islocal then
                        closure_init = [[
                            titan_pushmodule(L, _mod);
                            lua_pushlightuserdata(L, (void*)$FUNCTAG);
                            lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
                            lua_pushlightuserdata(L, TITAN_BRAND);
                            lua_pushcfunction(L, $STRICTNAME);
                            lua_pushcclosure(L, $LUANAME, 5);
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
                            lua_pushlightuserdata(L, TITAN_BRAND);
                            lua_pushcfunction(L, $STRICTNAME);
                            lua_pushcclosure(L, $LUANAME, 5);
                            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
                            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
                            lua_setfield(L, -2, $NAMESTR);
                            lua_pop(L, 1);
                        ]]
                    end
                    table.insert(funcs, render(closure_init, {
                        RECNSSLOT = c_integer_literal(
                            tlcontext.nominal_namespace_slots[node._type.fqtn]),
                        LUANAME = static_luaname(node._type),
                        NAMESTR = c_string_literal(node.name),
                        SLOT = c_integer_literal(node._closure_upvalue),
                        FUNCTAG = function_type_tag(tlcontext,
                            types.Function(node._type.params, node._type.rettypes, false,
                                node._type.varargtype,
                                node._type.flexrettype)),
                        NATIVE = static_name(node._type),
                        STRICTNAME = coder._static_strictname(node._type),
                    }))
                end
            elseif node._module_initializer or tag == "Ast.StatBlock" then
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
            table.insert(code, lnode._strictbody)
            i = i + 1
        end
    end

    -- Array constructors encountered while emitting functions/lambdas have
    -- now frozen the complete module-local writer inventory.
    local array_writer_inits = {}
    coder._emit_array_writers(
        tlcontext, sigs, code, array_writer_inits)

    -- Prepare the complete concrete/Interface pair inventory before sorting or
    -- emitting it. A field-snapshot conversion can itself construct a nested
    -- Interface or callable view, so this growing drain is the one fixpoint
    -- that discovers every wrapper/adaptor obligation deterministically.
    do
        local i = 1
        while i <= #tlcontext.interface_pair_list do
            coder._prepare_interface_pair_wrapper(
                tlcontext, tlcontext.interface_pair_list[i])
            i = i + 1
        end
    end

    -- Interface method payloads are process-static function-pointer arrays.
    -- Exact slots point at concrete methods; adjusted slots point at private
    -- relation-free adapters emitted from checker-frozen action graphs. They
    -- are filled only after imported native symbols have been recovered, on
    -- both module-initialization branches, and before user initializers can
    -- construct a wrapper. Field-only Interfaces need no zero-length C array;
    -- their wrapper payload is empty and their snapshots live in uservalues.
    local interface_pair_inits = {}
    local emitted_adapter_cap_assert = false
    table.sort(tlcontext.interface_pair_list, function(left, right)
        return util.bytewise_less(left.key, right.key)
    end)
    for _, pair in ipairs(tlcontext.interface_pair_list) do
        for index, mapping in ipairs(pair.methods) do
            if mapping.slot_kind == "adapter" then
                if not emitted_adapter_cap_assert then
                    table.insert(sigs, render([[
                        typedef char $NAME[
                            (TITAN_VARARG_MAX == 200) ? 1 : -1];
                    ]], {
                        NAME = tlcontext.prefix
                            .. "interface_adapter_vararg_cap_must_match",
                    }))
                    emitted_adapter_cap_assert = true
                end
                local adapter_sig, adapter_body =
                    coder._emit_interface_adapter(
                        tlcontext, pair, index, mapping)
                table.insert(sigs, adapter_sig)
                table.insert(code, adapter_body)
            end
        end
        if #pair.methods > 0 then
            table.insert(sigs, render([[
                static TitanInterfaceMethod $ID[$COUNT];
            ]], {
                ID = pair.id,
                COUNT = c_integer_literal(#pair.methods),
            }))
        end
        local wrapper_sig, wrapper_body =
            coder._emit_interface_pair_wrapper(pair)
        table.insert(sigs, wrapper_sig)
        table.insert(code, wrapper_body)
        for index, mapping in ipairs(pair.methods) do
            local entry = mapping.slot_kind == "adapter"
                and assert(pair.adapter_ids[index])
                or method_name(mapping.concrete)
            table.insert(interface_pair_inits, render([[
                $ID[$INDEX] = titan_cast_func(
                    TitanInterfaceMethod, $METHOD);
            ]], {
                ID = pair.id,
                INDEX = c_integer_literal(index - 1),
                METHOD = entry,
            }))
        end
        table.insert(interface_pair_inits, render([[
            {
                Table *_titan_interface_concrete_metatable =
                    hvalue(&_mod->uv[$CONCRETE_METATABLE].uv);
                Table *_titan_interface_target_metatable =
                    hvalue(&_mod->uv[$INTERFACE_METATABLE].uv);
                TValue _titan_interface_key;
                TValue _titan_interface_existing;
                sethvalue(L, &_titan_interface_key,
                    _titan_interface_target_metatable);
                lu_byte _titan_interface_existing_tag = luaH_get(
                    _titan_interface_concrete_metatable,
                    &_titan_interface_key,
                    &_titan_interface_existing);
                if (tagisempty(_titan_interface_existing_tag)) {
                    titan_ensure_stack(L, 3);
                    sethvalue(L, s2v(L->top.p),
                        _titan_interface_concrete_metatable);
                    L->top.p++;
                    sethvalue(L, s2v(L->top.p),
                        _titan_interface_target_metatable);
                    L->top.p++;
                    titan_pushmodule(L, _mod);
                    lua_pushcclosure(L, $WRAPPER, 1);
                    lua_rawset(L, -3);
                    lua_pop(L, 1);
                }
            }
        ]], {
            CONCRETE_METATABLE =
                c_integer_literal(pair.concrete_metatable_slot),
            INTERFACE_METATABLE =
                c_integer_literal(pair.interface_metatable_slot),
            WRAPPER = pair.wrapper_id,
        }))
    end

    -- Closure-adapter emission is deliberately a growing drain: nested
    -- callable component operations are discovered only while an enclosing
    -- adapter body is rendered. All declarations still land in $SIGS before
    -- every function body, and function tags/trace names are finalized only
    -- after this registry is complete.
    do
        local i = 1
        while i <= #tlcontext.callable_adapter_list do
            if not emitted_adapter_cap_assert then
                table.insert(sigs, render([[
                    typedef char $NAME[
                        (TITAN_VARARG_MAX == 200) ? 1 : -1];
                ]], {
                    NAME = tlcontext.prefix
                        .. "callable_adapter_vararg_cap_must_match",
                }))
                emitted_adapter_cap_assert = true
            end
            local site = tlcontext.callable_adapter_list[i]
            local adapter_sig, adapter_body =
                coder._emit_callable_adapter(tlcontext, site)
            table.insert(sigs, adapter_sig)
            table.insert(code, adapter_body)
            i = i + 1
        end
    end

    if #switch_get > 0 then
        table.insert(code, render([[
            static int $INDEXNAME(lua_State *L) {
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

            static int $NEWINDEXNAME(lua_State *L) {
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
            INDEXNAME = coder._module_metamethod_name(modname, "index"),
            NEWINDEXNAME = coder._module_metamethod_name(
                modname, "newindex"),
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
            lua_pushcclosure(L, $INDEXNAME, 2);
            lua_setfield(L, -3, "__index");
            /* Store __newindex in metatable */
            titan_pushmodule(L, _mod);
            lua_pushvalue(L, -2);
            lua_pushcclosure(L, $NEWINDEXNAME, 2);
            lua_setfield(L, -3, "__newindex");
            /* Set metatable on the module udata */
            titan_pushmodule(L, _mod);
            lua_pushvalue(L, -3);
            lua_setmetatable(L, -2);
            /* Pop module, varmap, and metatable */
            lua_pop(L, 3);
        ]], {
            INDEXNAME = coder._module_metamethod_name(modname, "index"),
            NEWINDEXNAME = coder._module_metamethod_name(modname, "newindex"),
            MODMETA = c_string_literal("Titan module " .. modname .. " metatable"),
            MODNAME = c_string_literal("Titan module " .. modname),
            GVARMAP = table.concat(gvar_map, "\n")
        })
    end

    local nslots = initctx.nslots

    -- A lambda or bound-method-ref initializer (codelambda/codemethodref) pays
    -- the fresh closure's GC debt after publishing its traced result. That check
    -- can re-enter code and relocate the Lua stack, so the initializer
    -- recomputes `_base` from a saved offset. Declare `_base_off` alongside
    -- `_base` when any such initializer is present. (Both lowerings reserve a
    -- gc temp, so nslots > 0 and `_base` is always declared.)
    local baseoff = initctx.uses_base_off
        and "\n            ptrdiff_t _base_off = savestack(L, _base);" or ""
    if nslots > 0 then
        table.insert(initvars, 1, render([[
            titan_ensure_stack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
                setnilvalue2s(_s);
            }$BASEOFF
        ]], {
            NSLOTS = c_integer_literal(nslots),
            BASEOFF = baseoff,
        }))
        table.insert(initvars, "L->top.p = _base;")
    end

    -- The generic-aware checker freezes a detached declared graph before it
    -- replaces every code-facing annotation and the active registry with their
    -- erased forms. Preserve ordinary callers which have no separate graph.
    local metadata_type = rawget(ast, "_declared_type")
    if metadata_type == nil then metadata_type = ast._type end
    local serialized_type = types.serialize(metadata_type)
    local own_layouts = {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelRecord" then
            own_layouts[node._type.name] = coder._nominal_plan(initctx, node._type)
        elseif not node._ignore and node._tag == "Ast.TopLevelUnion" then
            for _, variant in ipairs(node._type.variants) do
                own_layouts[node._type.name .. "." .. variant.name] =
                    coder._nominal_plan(initctx, node._type, variant)
            end
        end
    end
    local encoded_layouts = assert(require("titan-compiler.nominallayout")
        .encode(modname, own_layouts))
    local metadata, metadata_err =
        staticmetadata.render(modname, abi, serialized_type, encoded_layouts)
    assert(metadata, metadata_err)
    local initializer, initializer_err =
        staticmetadata.c_initializer(metadata)
    assert(initializer, initializer_err)
    table.insert(code, render(coder.modmetadata, {
        METADATANAME = tlcontext.prefix .. "titan_metadata",
        METADATA = initializer,
    }))

    table.insert(code, render(modtypes, {
        TYPESNAME = tlcontext.prefix .. "types",
        TYPES = c_string_literal(serialized_type),
    }))
    table.insert(code, render([[
        int $TYPESNAME(lua_State *L) {
            static const char layouts[] = $TYPES;
            lua_pushlstring(L, layouts, sizeof(layouts) - 1);
            return 1;
        }
    ]], {
        TYPESNAME = tlcontext.prefix .. "layouts",
        TYPES = c_string_literal(encoded_layouts),
    }))

    table.insert(code, render(modabi, {
        ABINAME = tlcontext.prefix .. "abi",
    }))

    init_data_from_other_modules(tlcontext, includes, loadmods, loadglobals,
        initrecs, mprefixes, static_deps)

    for _, entry in pairs(tlcontext.owned_c_metatables) do
        table.insert(initrecs, render([[
            luaL_getmetatable(L, $NAME);
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);
                lua_newtable(L);
                lua_pushinteger(L, TITAN_OWNED);
                lua_rawsetp(L, -2, TITAN_BRAND);
                lua_pushliteral(L, $DISPLAY);
                lua_setfield(L, -2, "__name");
                lua_pushliteral(L, $TAG);
                lua_rawsetp(L, -2, TITAN_MT_TYPE);
                lua_pushliteral(L, "__metatable");
                lua_pushliteral(L, $DISPLAY);
                lua_settable(L, -3);
                lua_pushvalue(L, -1);
                lua_setfield(L, LUA_REGISTRYINDEX, $NAME);
            } else {
                if (!lua_istable(L, -1)) {
                    luaL_error(L,
                        "invalid Titan owned C metatable registry entry");
                }
                int tag = lua_rawgetp(L, -1, TITAN_BRAND);
                if (tag != LUA_TNUMBER) {
                    luaL_error(L,
                        "invalid Titan owned C metatable registry entry");
                }
                if (ivalue(s2v(L->top.p - 1)) != TITAN_OWNED) {
                    luaL_error(L,
                        "invalid Titan owned C metatable registry entry");
                }
                lua_pop(L, 1);
            }
            setobj2t(L, &_mod->uv[$INDEX].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$INDEX].uv);
            lua_pop(L, 1);
        ]], {
            NAME = c_string_literal(entry.registry_key),
            DISPLAY = c_string_literal(entry.name),
            TAG = c_string_literal(entry.tag),
            INDEX = c_integer_literal(entry.slot),
        }))
    end

    -- Function-type tags: a per-library `static const void*` each, declared up
    -- front (in $SIGS, ahead of any function body that references it) and set up
    -- in _init by publish-or-recover through the Lua registry. C-free function
    -- types share registry keys across modules. Portable C-bearing graphs use
    -- their structural metadata identity; header-defined graphs remain scoped
    -- to the defining module because imported C type identity is module-local.
    local initfunctags = {}
    for _, entry in ipairs(tlcontext.functag_list) do
        table.insert(sigs, render([[
            static const char $TAGNAME[] = $TAG;
            static const char *$ID = $TAGNAME;
        ]], {
            TAGNAME = entry.id .. "_tag",
            TAG = c_string_literal(entry.tag),
            ID = entry.id,
        }))
        table.insert(initfunctags, render([[
            $ID = titan_publish_function_type_tag(L, $KEYSTR, $ID);
        ]], {
            KEYSTR = c_string_literal("Titan function type " .. entry.key .. " tag"),
            ID = entry.id,
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
                SYM = c_string_literal(
                    coder._linkage_symbol_name(pair[1])),
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

    assert(tlcontext.upvalue <= 0xFFFF,
        ("module '%s' requires %d module-state slots; Lua supports at most %d")
        :format(modname, tlcontext.upvalue, 0xFFFF))
    table.insert(code, render(init, {
        INITNAME = tlcontext.prefix .. 'init',
        LUAOPEN_NAME = 'luaopen_' .. mangle_qn(modname),
        PRELOADNAME = tlcontext.prefix .. 'register_preload',
        PRELOADMODNAME = c_string_literal(modname),
        INITMODULES = table.concat(initmods, "\n"),
        LOADMODULES1 = table.concat(loadmods, "\n"),
        LOADMODULES2 = #loadmods > 1 and table.concat(loadmods, "\n") or "",
        LOADGLOBALS = table.concat(loadglobals, "\n"),
        INITFUNCTAGS = table.concat(initfunctags, "\n"),
        INITPAIRS = table.concat(interface_pair_inits, "\n"),
        INITARRAYWRITERS = table.concat(array_writer_inits, "\n"),
        INITVARS = table.concat(initvars, "\n"),
        INITRECORDS = table.concat(initrecs, "\n"),
        FUNCS = table.concat(funcs, "\n"),
        INITNAMES = initnames,
        MODNAMESTR = c_string_literal("Titan module " .. modname),
        INITSOURCEIDENTITY = render([[
            setpvalue(&_mod->uv[$INDEX].uv, (void *)$IDENTITY());
        ]], {
            INDEX = c_integer_literal(tlcontext.source_identity_upvalue),
            IDENTITY = source_identity,
        }),
        INITARRAYMETA = render([[
            {
                Table *_array_metatable;
                Table *_const_array_metatable;
                titan_array_metatables(
                    L, &_array_metatable, &_const_array_metatable);
                sethvalue(L, &_mod->uv[$MUTABLE_INDEX].uv,
                    _array_metatable);
                luaC_barrierback(L, obj2gco(_mod),
                    &_mod->uv[$MUTABLE_INDEX].uv);
                sethvalue(L, &_mod->uv[$CONST_INDEX].uv,
                    _const_array_metatable);
                luaC_barrierback(L, obj2gco(_mod),
                    &_mod->uv[$CONST_INDEX].uv);
            }
        ]], {
            MUTABLE_INDEX = c_integer_literal(
                tlcontext.array_metatable_upvalue),
            CONST_INDEX = c_integer_literal(
                tlcontext.const_array_metatable_upvalue),
        }),
        CREATEMETA = create_meta,
        MODULEINIT = moduleinit,
        NUPVALS = tlcontext.upvalue
    }))

    table.insert(code, render(postamble, {
        LUAOPEN_NAME = 'luaopen_' .. mangle_qn(modname),
        INITNAME = tlcontext.prefix .. 'init',
    }))

    -- The runtime prefix comes first; this module's checked C environment
    -- precedes every generated Titan declaration header.
    local ffi_header = ast._ffi_header_output
        or (ast._ffi_header and ast._ffi_header.filename)
        or (modname:gsub("[.]", "/") .. ".ffi.h")
    local foreignimports = {
        "#include " .. c_string_literal(ffi_header),
    }
    if ast._foreign_header_output then
        foreignimports[#foreignimports + 1] =
            "#include " .. c_string_literal(ast._foreign_header_output)
    else
        for _, header in ipairs(tlcontext.source_foreign_headers) do
            foreignimports[#foreignimports + 1] =
                "#include " .. c_string_literal(header)
        end
    end

    local preamble_substs = {
        FIXEDPREFIX =
            require("titan-compiler.cpreamble").fixed_prefix,
        AFTERFOREIGNIMPORTS =
            require("titan-compiler.cpreamble").after_foreign_imports
            .. "\n" .. coder._native_option_declarations(),
        INCLUDES = table.concat(includes, "\n"),
        SIGS = coder._nominal_declarations(tlcontext) .. "\n"
            .. table.concat(sigs, "\n"),
    }
    local foreignimports_begin, foreignimports_end =
        preamble:find("$FOREIGNIMPORTS", 1, true)
    assert(foreignimports_begin)
    -- A valid C header name may contain `$identifier`. Splice these completed
    -- include lines between the rendered template halves so util.render never
    -- interprets header text as another template substitution.
    local preamble =
        render(preamble:sub(1, foreignimports_begin - 1), preamble_substs)
        .. table.concat(foreignimports, "\n")
        .. render(preamble:sub(foreignimports_end + 1), preamble_substs)

    -- Report the logical modules whose direct native entry points this
    -- generated object actually references. The standalone archive protocol
    -- gate uses this use-site set so an exported but unused nominal type does
    -- not force an unrelated carried object out of a selected archive.
    local direct_native_modules = {}
    local native_bindings = {}
    local function remember_binding(name)
        native_bindings[name] = static_deps[name] == true and "direct"
            or (mprefixes[name] and "handle" or "global")
    end
    for name in pairs(mprefixes) do remember_binding(name) end
    for _, func in pairs(tlcontext.functions) do
        remember_binding(func.module)
        if static_deps[func.module] == true then
            direct_native_modules[func.module] = true
        end
    end
    for _, info in pairs(tlcontext.bound_luas) do
        remember_binding(info.module)
        if static_deps[info.module] == true then
            direct_native_modules[info.module] = true
        end
    end
    for _, info in pairs(tlcontext.bound_stricts) do
        remember_binding(info.module)
        if static_deps[info.module] == true then
            direct_native_modules[info.module] = true
        end
    end

    local foreign_header = ast._foreign_header_contents
    if not ast._foreign_header_prepared then
        foreign_header = coder.generate_foreign_header(
            modname, ast, tlcontext)
    end
    local source = preamble .. "\n\n" .. table.concat(code, "\n\n")
    -- A `#line` directive applies its number to the immediately following
    -- physical source line. Template substitutions can contribute blank
    -- lines after a standalone directive; remove every such semantic line
    -- before the driver persists the translation unit so native frames retain
    -- the exact Titan location. Optional formatting preserves this spelling.
    local removed
    repeat
        source, removed = source:gsub(
            "([ \t]*#line[^\n]*\n)[ \t]*\n", "%1")
    until removed == 0
    return source, direct_native_modules, foreign_header, native_bindings, encoded_layouts
end

return core.coder
