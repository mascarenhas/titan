local core = require "titan-compiler.coder.core"
local _ENV = core

function coder._module_native_ref(ctx, name)
    local top = ctx.tlcontext or ctx
    return "((" .. top.prefix .. "native_data *)getudatamem(_mod))->" .. name
end

function coder._external_reference(ctx, module, name)
    local top = ctx.tlcontext or ctx
    if module == top.module or top.static_deps[module] == true then
        return name
    end
    return coder._module_native_ref(top, name)
end

-- Slots are provider-owned data just like native callable symbols. The
-- importing module's own slot holding its dependency remains a constant.
function coder._binary_slot_name(module, kind, declaration)
    if kind == "static" then
        return coder._nominal_function_prefix(declaration.fqtn,
            declaration.name) .. "_closure_slot"
    end
    return coder._function_prefix(module, declaration.name)
        .. (kind == "variable" and "_variable_slot" or "_closure_slot")
end

function coder._imported_slot(ctx, module, kind, declaration)
    local index = kind == "variable" and declaration._upvalue
        or declaration._closure_upvalue
    if module == ctx.module or ctx.tlcontext.static_deps[module] == true then
        return c_integer_literal(assert(index, "direct imported slot is absent"))
    end
    local name = coder._binary_slot_name(module, kind, declaration)
    ctx.tlcontext.external_slots[name] = { module = module }
    return coder._module_native_ref(ctx, name)
end

function coder._binary_check(tlcontext, module, handle, file)
    local compatibility = require "titan-compiler.binarycompat"
    local modtype = assert(tlcontext.binary_modules[module],
        "missing checked compatibility module " .. module)
    local expected = compatibility.requirements(modtype,
        tlcontext.binary_registry, tlcontext.binary_usage[module] or {})
    local verifier = compatibility.verifier(expected, tlcontext.module, module)
    return render([[
        titan_check_module_compatibility(L, $HANDLE, $SYMBOL, $FILE,
            $VERIFIER, $LENGTH);
    ]], {
        HANDLE = handle,
        SYMBOL = c_string_literal(mangle_qn(module) .. "_compatibility"),
        FILE = c_string_literal(file),
        VERIFIER = c_string_literal(verifier),
        LENGTH = #verifier,
    })
end

function coder._binary_exports(tlcontext, ast, code)
    local compatibility = require "titan-compiler.binarycompat"
    local metadata = compatibility.encode(compatibility.module(
        ast._declared_type or ast._type, tlcontext.binary_registry))
    table.insert(code, render([[
        int $SYMBOL(lua_State *L) {
            static const char metadata[] = $METADATA;
            lua_pushlstring(L, metadata, sizeof(metadata) - 1);
            return 1;
        }
    ]], {
        SYMBOL = tlcontext.prefix .. "compatibility",
        METADATA = c_string_literal(metadata),
    }))
    for index, entry in ipairs(coder._public_prefix_layout(ast._type)) do
        table.insert(code, render("const unsigned int $NAME = $INDEX;", {
            NAME = coder._binary_slot_name(tlcontext.module,
                entry.kind, entry.value),
            INDEX = index - 1,
        }))
    end
end

function coder._binary_imports(tlcontext, includes, loadmods, loadglobals,
                               mprefixes)
    -- Explicit dependencies are verified before their initialization. An owner
    -- exposed only through an alias/signature is already loaded by those
    -- initializers; verify its own contract before using any global symbol.
    local modules = {}
    for module in pairs(tlcontext.binary_usage) do
        if module ~= tlcontext.module and not mprefixes[module]
            and tlcontext.static_deps[module] ~= true then
            modules[#modules + 1] = module
        end
    end
    table.sort(modules, util.bytewise_less)
    for _, module in ipairs(modules) do
        local file = module .. " (transitive dependency)"
        table.insert(loadglobals, render([[
            TitanModuleProvider $PROVIDER =
                titan_module_provider(L, $MODULE, NULL);
            titan_check_module_abi(L, $PROVIDER, $ABI, $FILE);
        ]], {
            PROVIDER = mangle_qn(module) .. "_provider",
            MODULE = c_string_literal(module),
            ABI = c_string_literal(mangle_qn(module) .. "_abi"),
            FILE = c_string_literal(file),
        }))
        table.insert(loadglobals,
            coder._binary_check(tlcontext, module,
                mangle_qn(module) .. "_provider", file))
    end
    local names = {}
    for name in pairs(tlcontext.external_slots) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)
    for _, name in ipairs(names) do
        local module = tlcontext.external_slots[name].module
        tlcontext.native_fields[name] = "unsigned int " .. name .. ";"
        local prefix = mprefixes[module]
        local provider = (prefix or mangle_qn(module) .. "_") .. "provider"
        table.insert(loadglobals, render(
            "$NAME = *(const unsigned int *)titan_module_symbol(L, $PROVIDER, $SYMBOL);", {
                NAME = coder._module_native_ref(tlcontext, name),
                PROVIDER = provider,
                SYMBOL = c_string_literal(coder._linkage_symbol_name(name)),
            }))
    end
end

-- Every initialization path publishes the same native export descriptor with
-- the canonical userdata, including executable/static and package.loadlib
-- entry paths which have no runtime-owned DSO handle.
function coder._binary_resolver(tlcontext, ast)
    local slots = {}
    for _, entry in ipairs(coder._public_prefix_layout(ast._type)) do
        slots[coder._binary_slot_name(tlcontext.module,
            entry.kind, entry.value)] = true
    end
    local symbols = coder.interface_external_symbols(tlcontext.module, ast._type)
    -- This source generation emits the optional native query. A recovered
    -- ABI-2 interface alone cannot promise that its provider has this export.
    symbols[#symbols + 1] = {
        symbol = mangle_qn(tlcontext.module) .. "_abi_value",
        owner = "module ABI value entry",
    }
    table.sort(symbols, function(a, b)
        return util.bytewise_less(a.symbol, b.symbol)
    end)
    local entries, seen = {}, {}
    for _, entry in ipairs(symbols) do
        local name = entry.symbol
        if not seen[name] then
            seen[name] = true
            entries[#entries + 1] = render([[
                if (strcmp(symbol, $SYMBOL) == 0) return $ADDRESS;
            ]], {
                SYMBOL = c_string_literal(coder._linkage_symbol_name(name)),
                ADDRESS = slots[name] and ("(void *)&" .. name)
                    or ("titan_cast_func(void *, " .. name .. ")"),
            })
        end
    end
    return render([[
        static void *$NAME(const char *symbol) {
            $ENTRIES
            return NULL;
        }
    ]], {
        NAME = tlcontext.prefix .. "native_symbol",
        ENTRIES = table.concat(entries, "\n"),
    })
end

function coder._binary_payload(tlcontext)
    local names, fields = {}, { "TitanModuleData provider;" }
    for name in pairs(tlcontext.native_fields) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)
    for _, name in ipairs(names) do
        fields[#fields + 1] = tlcontext.native_fields[name]
    end
    return render([[
        typedef struct {
            $FIELDS
        } $TYPE;
        static void *$RESOLVER(const char *symbol);
    ]], {
        FIELDS = table.concat(fields, "\n"),
        TYPE = tlcontext.prefix .. "native_data",
        RESOLVER = tlcontext.prefix .. "native_symbol",
    })
end
