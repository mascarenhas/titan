local core = require "titan-compiler.coder.core"
local _ENV = core

--
-- Functions for C literals
--

-- Preserve arbitrary Titan string bytes while keeping generated C source
-- textual and readable.
some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    -- Generated fragments pass through util.render recursively. Keep a
    -- literal dollar out of that template language even when user text is
    -- followed by an identifier, while preserving the exact byte in C.
    ["$"] = "\\044",
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

function c_string_literal(s)
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

function coder._foreign_include_line(include)
    return "#include " .. assert(include and include.rendered,
        "foreign include has no normalized spelling")
end

-- C declarations rendered while generating one module report the origin
-- headers of their named FFI components. coder.generate installs the collector;
-- direct unit helpers can still render declarations with no active collector.
function coder._record_c_type_use(typ)
    local collect = coder._ffi_include_collector
    if not collect then return end
    for _, include in ipairs(types.c_ffi_includes(typ)) do
        collect(include, false)
    end
end

function coder._render_c_type_name(typ)
    coder._record_c_type_use(typ)
    return cdeclarator.render_type_name(typ)
end

function coder._render_c_declaration(typ, name)
    coder._record_c_type_use(typ)
    return cdeclarator.render_declaration(typ, name)
end

function c_integer_literal(n)
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

function c_float_literal(n)
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
-- .c. Returned as its own line with a trailing newline so it never fuses
-- with adjacent code; clang-format normalizes directive indentation before the
-- driver invokes the C compiler. Nodes without a `loc` (synthesized AST) emit
-- nothing.
function emitline(node)
    if not coder._emit_line_directives then return "" end
    local loc = node and node.loc
    if not loc or not loc.line or not loc.filename then return "" end
    return "#line " .. tostring(loc.line) .. " "
        .. c_string_literal(loc.filename) .. "\n"
end

function getslot(typ --[[:table]], dst --[[:string?]], src --[[:string]])
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
        ct = coder._render_c_type_name(typ)
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        tmpl = "$DST (($CT)fltvalue($SRC))"
        ct = coder._render_c_type_name(typ)
    elseif types.is_c_udata_pointer(typ) then
        tmpl = "$DST (ttisnil($SRC) ? NULL : (($CT)uvalue($SRC)))"
        ct = coder._render_c_type_name(typ)
    elseif typ._tag == "Type.CPointer" or typ._tag == "Type.CArray" or
           (typ._tag == "Type.CTypedef"
            and (types.resolve_c_typedef(typ)._tag == "Type.CPointer"
                 or types.resolve_c_typedef(typ)._tag == "Type.CArray")) then
        tmpl = "$DST (($CT)pvalue($SRC))"
        ct = coder._render_c_type_name(
            cdeclarator.adjust_parameter_type(typ))
    elseif typ._tag == "Type.COwned" then
        tmpl = "$DST uvalue($SRC)"
    else error("invalid type " .. types.tostring(typ)) end
    return render(tmpl, { DST = dst, SRC = src, CT = ct })
end

function toboolean(typ --[[:table]], src --[[:string]])
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
function nextupvalue(tlcontext)
    local slot = tlcontext.upvalue
    tlcontext.upvalue = slot + 1
    return slot
end

function mangle_qn(qualname)
    return qualname:gsub("[%-.]", "_")
end

-- TITAN_ENTRY_TAG marks every generated Lua entry-wrapper C symbol with a name
-- Titan owns and no Lua/libc symbol shares. The unified backtrace merge
-- (titan-runtime/titan.c) keys on this substring to locate Titan native-stack
-- boundaries — each entry wrapper is where one Lua->Titan call splices a run of
-- native Titan frames into the CallInfo-driven Lua trace. The `#line` from
-- the function-definition `#line` still attributes these wrappers to the
-- .titan source.
TITAN_ENTRY_TAG = "titanentry"

function coder._source_private_prefix(owner, name)
    -- Keep the generated-header guard ASCII-only. Callable entries use the
    -- separated naming helpers below; private visibility never changes their
    -- spelling.
    return mangle_qn(owner) .. "_" .. name
end

function coder._source_module_identity_name(modname)
    return mangle_qn(modname) .. "_module_identity"
end

function coder._nominal_function_prefix(fqtn, name)
    local modname, owner = fqtn:match("^(.*)[.]([^.]+)$")
    assert(modname and owner,
        "nominal callable owner must be a module-qualified name")
    return coder._function_prefix(modname, owner)
        .. "_\\u2131_" .. name
end

function fname_prefix(typ)
    return coder._nominal_function_prefix(typ.fqtn, typ.name)
end

function static_name(typ)
    return fname_prefix(typ) .. "_titanstatic"
end

function static_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_luastatic"
end

function method_name(typ)
    return fname_prefix(typ) .. "_titanmethod"
end

function method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_luamethod"
end

-- Bound-method trampolines: the native one (`_boundmethod`) matches the
-- self-removed function ABI and delegates to the method's own native entry with
-- the captured `self`; the Lua one (`_boundlua`) is the closure's `lua_CFunction`
-- and inserts `self` before delegating to the method's Lua entry. Both are
-- exported so a bind site in another module (with only the `.so`) can reach them.
function bound_method_name(typ)
    return fname_prefix(typ) .. "_boundmethod"
end

function bound_method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_boundlua"
end

function coder._bound_method_strictname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_boundstrict"
end

-- Interface method artifacts live in the Interface owner's translation unit.
-- Direct Titan calls dispatch through the wrapper payload inline. The generic
-- Lua method entry remains file-local; only the three first-class bound-method
-- roles need stable exported C symbols.
function coder._interface_method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_interfacelua"
end

function coder._interface_bound_method_name(typ)
    return fname_prefix(typ) .. "_interface_boundmethod"
end

function coder._interface_bound_method_luaname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG
        .. "_interface_boundlua"
end

function coder._interface_bound_method_strictname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG
        .. "_interface_boundstrict"
end

function modprefix(modname)
    return mangle_qn(modname) .. "_"
end

function coder._function_prefix(modname, name)
    -- A C99 universal-character-name cannot occur in a Titan identifier, so
    -- this boundary cannot be confused with either the module or member text.
    return modprefix(modname) .. "\\u2133_" .. name
end

function coder._nominal_metamethod_name(fqtn, role)
    assert(role == "index" or role == "newindex",
        "unknown nominal metamethod role")
    return coder._nominal_function_prefix(fqtn, "meta_" .. role)
end

function coder._module_metamethod_name(modname, role)
    assert(role == "index" or role == "newindex",
        "unknown module metamethod role")
    return coder._function_prefix(modname, "meta_" .. role)
end

function coder._linkage_symbol_name(c_spelling)
    -- C source spells the separator as a UCN. Object files, DWARF, libbacktrace,
    -- and native symbol tools expose the corresponding UTF-8 linkage name.
    return (c_spelling
        :gsub("\\u2133", "\226\132\179")
        :gsub("\\u2131", "\226\132\177"))
end

function func_name(modname, name, _)
    return coder._function_prefix(modname, name) .. "_titan"
end

function coder._foreign_func_name(modname, name)
    return func_name(modname, name, false)
end

function coder._foreign_reference_name(reference)
    if reference.source then
        return coder._foreign_func_name(reference.module, reference.name)
    end
    return reference.name
end

function func_luaname(modname, name, _)
    return coder._function_prefix(modname, name)
        .. "_" .. TITAN_ENTRY_TAG .. "_lua"
end

function coder._func_strictname(modname, name, _)
    return coder._function_prefix(modname, name)
        .. "_" .. TITAN_ENTRY_TAG .. "_strict"
end

function coder._static_strictname(typ)
    return fname_prefix(typ) .. "_" .. TITAN_ENTRY_TAG .. "_strictstatic"
end

function module_initializer_name(tlcontext)
    return tlcontext.prefix .. TITAN_ENTRY_TAG .. "_module_initializer"
end

-- Return the externally visible C symbols this source module will define.
-- Library-mode preflight uses the coder's own naming helpers so collisions are
-- rejected before code generation instead of being discovered by the linker.
-- File-local Lua wrappers, lambdas, and module initializers deliberately do
-- not participate. Source-visible local native entries have hidden cross-object
-- linkage and do participate because they can still collide at final link.
function coder.external_symbols(modname, ast)
    local mangled = mangle_qn(modname)
    local symbols = {
        { symbol = mangled .. "_abi", owner = "module ABI entry" },
        { symbol = mangled .. "_types", owner = "module type entry" },
        { symbol = mangled .. "_init", owner = "module initializer entry" },
        { symbol = "luaopen_" .. mangled, owner = "module Lua entry" },
        { symbol = coder._source_module_identity_name(modname),
          owner = "source module identity entry" },
    }

    local function add(symbol, owner)
        symbols[#symbols + 1] = { symbol = symbol, owner = owner }
    end

    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelFunc" then
                add(func_name(modname, node.name, node.islocal),
                    "function '" .. modname .. "." .. node.name .. "'")
            elseif node._tag == "Ast.TopLevelForeignFunc" then
                add(coder._foreign_func_name(modname, node.name),
                    "foreign function '" .. modname .. "." .. node.name .. "'")
            elseif node._tag == "Ast.TopLevelStatic" then
                local owner = types.registry[node._type.fqtn]
                local owner_kind = owner and owner._tag == "Type.Union"
                    and "union" or "record"
                add(static_name(node._type),
                    owner_kind .. " function '" .. node._type.fqtn .. "." ..
                        node._type.name .. "'")
            elseif node._tag == "Ast.TopLevelMethod" then
                local owner = "method '" .. node._type.fqtn .. ":" ..
                    node._type.name .. "'"
                add(method_name(node._type), owner)
                add(bound_method_name(node._type), owner .. " bound entry")
                add(bound_method_luaname(node._type),
                    owner .. " bound Lua entry")
                add(coder._bound_method_strictname(node._type),
                    owner .. " bound strict entry")
            elseif node._tag == "Ast.TopLevelInterface" then
                for _, method in ipairs(node._type.methods) do
                    local owner = "interface method '" .. method.fqtn
                        .. ":" .. method.name .. "'"
                    add(coder._interface_bound_method_name(method),
                        owner .. " bound entry")
                    add(coder._interface_bound_method_luaname(method),
                        owner .. " bound Lua entry")
                    add(coder._interface_bound_method_strictname(method),
                        owner .. " bound strict entry")
                end
            end
        end
    end

    return symbols
end

-- Return the known public symbol families represented by a recovered module
-- interface. Static-provider preflight has no AST, but it can still reject the
-- same protocol/function/record-member collisions before invoking the linker.
function coder.interface_external_symbols(modname, modtype)
    local mangled = mangle_qn(modname)
    local symbols = {
        { symbol = mangled .. "_abi", owner = "module ABI entry" },
        { symbol = mangled .. "_types", owner = "module type entry" },
        { symbol = mangled .. "_init", owner = "module initializer entry" },
        { symbol = "luaopen_" .. mangled, owner = "module Lua entry" },
        { symbol = coder._source_module_identity_name(modname),
          owner = "source module identity entry" },
    }

    local function add(symbol, owner)
        symbols[#symbols + 1] = { symbol = symbol, owner = owner }
    end

    for _, member in ipairs(modtype.members or {}) do
        local typ = member.type
        if member._tag == "Type.ModuleMember" and typ then
            if typ._tag == "Type.Function" then
                add(func_name(modname, member.name),
                    "function '" .. modname .. "." .. member.name .. "'")
            elseif typ._tag == "Type.Record" or typ._tag == "Type.Union" then
                local owner_kind = typ._tag == "Type.Record"
                    and "record" or "union"
                for _, static in pairs(typ.functions or {}) do
                    if not static.islocal then
                        add(static_name(static),
                            owner_kind .. " function '" .. static.fqtn .. "." ..
                                static.name .. "'")
                    end
                end
                for _, method in pairs(typ.methods or {}) do
                    if not method.islocal then
                        local owner = "method '" .. method.fqtn .. ":" ..
                            method.name .. "'"
                        add(method_name(method), owner)
                        add(bound_method_name(method), owner .. " bound entry")
                        add(bound_method_luaname(method),
                            owner .. " bound Lua entry")
                        add(coder._bound_method_strictname(method),
                            owner .. " bound strict entry")
                    end
                end
            end
        end
    end
    -- Interfaces are type-only module members. They are published directly in
    -- Type.Module.type_members and deliberately never occupy a value-facing
    -- ModuleMember or module-userdata prefix slot.
    local interface_names = {}
    for name, typ in pairs(modtype.type_members or {}) do
        if typ._tag == "Type.Interface" then
            interface_names[#interface_names + 1] = name
        end
    end
    table.sort(interface_names, util.bytewise_less)
    for _, name in ipairs(interface_names) do
        local interface = modtype.type_members[name]
        for _, method in ipairs(interface.methods) do
            local owner = "interface method '" .. method.fqtn
                .. ":" .. method.name .. "'"
            add(coder._interface_bound_method_name(method),
                owner .. " bound entry")
            add(coder._interface_bound_method_luaname(method),
                owner .. " bound Lua entry")
            add(coder._interface_bound_method_strictname(method),
                owner .. " bound strict entry")
        end
    end
    return symbols
end

-- Record the mapping from a native function's mangled C symbol to its qualified
-- Titan source name, for the trace name table emitted in _init (deliverable 2).
-- The runtime (errorhandler) looks each native frame's DWARF symbol up here and
-- shows the qualified name instead of the mangled symbol. Forms:
--   top-level func  -> "<module>.<func>"
--   method          -> "<module>.<record>:<method>"
--   record function -> "<module>.<record>.<function>"
--   anonymous/lambda-> "anonymous function at <file>.titan:<linedefined>"
function register_trace_name(tlcontext, symbol, qualname)
    table.insert(tlcontext.names, { symbol, qualname })
end

-- The qualified Titan name of an anonymous function, formatted at codegen from
-- its DEFINITION location (the lambda's `loc`). The trace's leading
-- `<file>:<current-line>` already shows the execution point; this names it.
function anon_qualname(loc)
    if loc and loc.line and loc.filename then
        return "anonymous function at " .. loc.filename .. ":" .. tostring(loc.line)
    end
    return "anonymous function"
end

-- Get the module uservalue slot holding the canonical metatable for this
-- nominal type. Records, unions, and Interfaces share the Type.Nominal value
-- representation, but their registry keys are intentionally distinct; retain
-- the owner kind beside the slot so imported recovery uses the right key.
-- `ctx` may be a per-function context (has `.tlcontext`) or the top-level
-- tlcontext itself — genluaentry passes the latter into checkandget when
-- coercing a Lua-facing nominal parameter, and that may be the first use of the
-- type's metatable. Resolve the tlcontext either way (`ctx.metatables` is the
-- same shared table in both); allocating the slot here is safe because it
-- happens before init_data_from_other_modules emits the per-state recovery.
function type2metatable(ctx, typ --[[:table]])
    local tlcontext = ctx.tlcontext or ctx
    local entry = ctx.metatables[typ.fqtn]
    if not entry then
        local owner = assert(types.registry[typ.fqtn],
            "nominal type is missing from the registry: " .. typ.fqtn)
        assert(owner._tag == "Type.Record" or owner._tag == "Type.Union"
               or owner._tag == "Type.Interface",
            "invalid nominal owner " .. owner._tag)
        entry = {
            slot = nextupvalue(tlcontext),
            kind = owner._tag == "Type.Record" and "record"
                or owner._tag == "Type.Union" and "union"
                or "interface",
        }
        ctx.metatables[typ.fqtn] = entry
    end
    return entry.slot
end

-- Every module reserves consecutive private uservalue slots
-- for the canonical mutable and const Array proxy metatables. Importers
-- reconstruct only the public variable/function prefix and never need these
-- private slots. Array's native representation remains Table*: only boxed/
-- Lua-facing conversions and mutable-to-const casts consult the cached tags.
function array_metatable_kind(ctx, isconst)
    assert(type(isconst) == "boolean",
        "Array metatable lookup requires a const qualifier")
    local tlcontext = ctx.tlcontext or ctx
    local slot = isconst
        and tlcontext.const_array_metatable_upvalue
        or tlcontext.array_metatable_upvalue
    assert(slot, "Array metatable slot was not allocated")
    return render("hvalue(&_mod->uv[$INDEX].uv)", {
        INDEX = c_integer_literal(slot),
    })
end
coder.array_metatable_kind = array_metatable_kind

function array_metatable(ctx, typ)
    typ = assert(types.normalize(typ),
        "Array metatable lookup has an unnormalizable type")
    assert(typ._tag == "Type.Array"
           and type(typ.isconst) == "boolean",
        "Array metatable lookup requires a qualified Array type")
    return array_metatable_kind(ctx, typ.isconst)
end

-- Return the module-local Lua-writer entry for an Array element type,
-- allocating its private module slot on first construction.  Writer identity
-- is deliberately local to the emitting module: the closure is behavior
-- carried by the canonical proxy, never a runtime type tag.
function coder._array_writer(ctx, elem, plan)
    local tlcontext = ctx.tlcontext or ctx
    assert(elem and plan ~= nil,
        "Array construction is missing its checker writer annotation")
    assert(plan ~= false,
        "rejected Array writer plan reached code generation")
    coder._checked_dynamic_plan(plan, elem, "Array writer inventory")
    for _, entry in ipairs(tlcontext.array_writer_list) do
        if types.equals(entry.elem, elem) then
            assert(entry.plan.kind == plan.kind
                    and entry.plan.op == plan.op
                    and types.equals(entry.plan.target, plan.target),
                "equal constructed Array types disagree on writer plan")
            return entry
        end
    end
    local entry = {
        elem = elem,
        plan = plan,
        slot = nextupvalue(tlcontext),
        name = tlcontext.prefix .. "array_writer_"
            .. tostring(tlcontext.array_writer_count),
    }
    tlcontext.array_writer_count = tlcontext.array_writer_count + 1
    table.insert(tlcontext.array_writer_list, entry)
    return entry
end

function owned_c_metatable(ctx, typ)
    local tlcontext = ctx.tlcontext or ctx
    local key = types.tostring(typ)
    local entry = tlcontext.owned_c_metatables[key]
    if not entry then
        local display = "Titan owned C " .. key .. " metatable"
        entry = {
            slot = nextupvalue(tlcontext),
            name = display,
            registry_key = display,
            tag = types.serialize(typ),
        }
        tlcontext.owned_c_metatables[key] = entry
    end
    return entry.slot
end

-- Generated code reaches nominal/owned-C identities through module
-- uservalue slots. Functions and adapters receive their owning module as `_mod`.
function coder._nominal_metatable_expr(ctx, typ)
    return render("hvalue(&_mod->uv[$I].uv)", {
        I = c_integer_literal(type2metatable(ctx, typ)),
    })
end

function coder._owned_c_metatable_expr(ctx, typ)
    return render("hvalue(&_mod->uv[$I].uv)", {
        I = c_integer_literal(owned_c_metatable(ctx, typ)),
    })
end


function function_type_tag(tlcontext, ftype --[[:table]])
    local key = types.tostring(ftype)
    local entry = tlcontext.functags[key]
    if not entry then
        local n = tlcontext.functag_count
        tlcontext.functag_count = n + 1
        entry = {
            id = tlcontext.prefix .. "functag_" .. n,
            key = key,
            tag = types.serialize(ftype),
        }
        tlcontext.functags[key] = entry
        table.insert(tlcontext.functag_list, entry)
    end
    return entry.id
end

return core.coder
