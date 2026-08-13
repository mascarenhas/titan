local types = require "titan-compiler.types"
local util  = require "titan-compiler.util"
local cdeclarator = require "titan-compiler.cdeclarator"

local coder = {
    _csemantics = require "titan-compiler.csemantics",
    -- Generation-local policy stored on the module table because coder.lua is
    -- already at Lua's top-level local-variable limit. coder.generate resets
    -- it on every invocation before emitline can be reached.
    _emit_line_directives = true,
}

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
-- .c. Returned as its own line with a trailing newline so it never fuses
-- with adjacent code; clang-format normalizes directive indentation before the
-- driver invokes the C compiler. Nodes without a `loc` (synthesized AST) emit
-- nothing.
local function emitline(node)
    if not coder._emit_line_directives then return "" end
    local loc = node and node.loc
    if not loc or not loc.line or not loc.filename then return "" end
    return "#line " .. tostring(loc.line) .. " "
        .. c_string_literal(loc.filename) .. "\n"
end

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

local function fname_prefix(typ)
    return coder._nominal_function_prefix(typ.fqtn, typ.name)
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

local function modprefix(modname)
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

local function func_name(modname, name, _)
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

local function func_luaname(modname, name, _)
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

local function module_initializer_name(tlcontext)
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
local function type2metatable(ctx, typ --[[:table]])
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

-- Every ABI-0.17-or-newer module reserves one private uservalue slot for the canonical
-- per-state Array proxy metatable.  Importers reconstruct only the public
-- variable/function prefix and never need this private slot.  Array's native
-- representation remains Table*: only boxed/Lua-facing conversions consult
-- this cached pointer.
function array_metatable(ctx)
    if ctx.interface_adapter_array_metatable then
        return ctx.interface_adapter_array_metatable
    end
    local tlcontext = ctx.tlcontext or ctx
    assert(tlcontext.array_metatable_upvalue,
        "Array metatable slot was not allocated")
    return render("hvalue(&_mod->uv[$INDEX].uv)", {
        INDEX = c_integer_literal(tlcontext.array_metatable_upvalue),
    })
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

local function owned_c_metatable_key(typ)
    assert(typ._tag == "Type.COwned")
    local scope = types.c_ffi_scope_key(typ)
    return (scope and scope .. "\0" or "") .. types.tostring(typ)
end

local function owned_c_metatable(ctx, typ)
    local tlcontext = ctx.tlcontext or ctx
    local key = owned_c_metatable_key(typ)
    local entry = tlcontext.owned_c_metatables[key]
    if not entry then
        local scope = types.c_ffi_scope_key(typ) or tlcontext.module
        entry = {
            slot = nextupvalue(tlcontext),
            name = "Titan owned C " .. scope .. " "
                .. types.tostring(typ) .. " metatable",
        }
        tlcontext.owned_c_metatables[key] = entry
    end
    return entry.slot
end

-- Most generated code reaches nominal/owned-C identities through module
-- uservalue slots. A private Interface adapter may be emitted in a third
-- bridge module while its `_mod` operand is deliberately the concrete
-- owner's module. Such an adapter resolves the identities it needs from the
-- per-state registry on entry and supplies stack-neutral local expressions
-- through these two override maps.
function coder._nominal_metatable_expr(ctx, typ)
    local overrides = ctx.interface_adapter_nominal_metatables
    if overrides and overrides[typ.fqtn] then
        return overrides[typ.fqtn]
    end
    return render("hvalue(&_mod->uv[$I].uv)", {
        I = c_integer_literal(type2metatable(ctx, typ)),
    })
end

function coder._owned_c_metatable_expr(ctx, typ)
    local key = owned_c_metatable_key(typ)
    local overrides = ctx.interface_adapter_owned_c_metatables
    if overrides and overrides[key] then
        return overrides[key]
    end
    return render("hvalue(&_mod->uv[$I].uv)", {
        I = c_integer_literal(owned_c_metatable(ctx, typ)),
    })
end

-- Get the C identifier of the `static const void *` holding the type tag for a
-- function type, allocating one (numbered per module) on first use. Tags are
-- keyed by the canonical type string and shared across all modules through the
-- Lua registry (publish-or-recover, emitted in _init). C-bearing function types
-- additionally include their defining Titan module in the registry key because
-- imported C typedef identity is module-local; C-free types retain the shared
-- key so `(integer) -> integer` values keep their cross-module exact fast path.
function coder._function_type_tag_cache_key(ftype, fallback_scope)
    local key = types.tostring(ftype)
    local c_bearing = types.first_c_ffi_type(ftype) ~= nil
    if not c_bearing then return "Titan\0" .. key end
    local scope = types.c_ffi_scope_key(ftype) or fallback_scope or ""
    return "C\0" .. scope .. "\0" .. key
end

local function function_type_tag(tlcontext, ftype --[[:table]])
    local key = types.tostring(ftype)
    local c_bearing = types.first_c_ffi_type(ftype) ~= nil
    -- The display spelling is not a structural identity: a C typedef named
    -- `integer`, for example, deliberately renders like Titan `integer`.
    -- Keep the two runtime ABI families in distinct local-cache buckets so a
    -- C-bearing callable can never reuse the native tag of a C-free callable
    -- merely because their diagnostics have the same text.
    local ffi_scope = types.c_ffi_scope_key(ftype)
    local cache_key = coder._function_type_tag_cache_key(
        ftype, tlcontext.module)
    local entry = tlcontext.functags[cache_key]
    if not entry then
        local n = tlcontext.functag_count
        tlcontext.functag_count = n + 1
        local registry_key = key
        if c_bearing then
            registry_key = (ffi_scope or tlcontext.module) .. " " .. key
        end
        entry = {
            id = tlcontext.prefix .. "functag_" .. n,
            key = key,
            registry_key = registry_key,
        }
        tlcontext.functags[cache_key] = entry
        table.insert(tlcontext.functag_list, entry)
    end
    return entry.id
end

-- `checkandget`/`checkandset` lower the deliberately coercive dynamic
-- boundary shared by written `value as/is T` and genuine Lua entry points.
-- Strict Titan observations (implicit gradual projections, typed Array/Map
-- reads, and branded non-exact Titan calls) use the separate helpers declared
-- here and defined once the native C type helpers are available.
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
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, false)
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, false)
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
            CT = coder._render_c_type_name(typ),
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
            CT = coder._render_c_type_name(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected C pointer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.COwned" then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP)
                    && uvalue($EXP)->metatable == $META)) {
                $VAR = uvalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            META = coder._owned_c_metatable_expr(ctx, typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", {
                "$FILE", "$LINE", "$COL",
                c_string_literal(types.tostring(typ)),
                "lua_typename(L, ttype($EXP))"
            })
        })
    elseif typ._tag == "Type.Array" then
        -- Lua/value boundaries carry the canonical Array proxy, while the
        -- exact/native representation remains its backing Table*.  Use the
        -- module's cached metatable pointer; never query the registry here.
        return render([[
            {
                Table *_titan_array = titan_array_try_backing($EXP, $META);
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    $VAR = _titan_array;
                } else {
                    $THROW
                }
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx),
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Nil" then tag = "nil"
    elseif typ._tag == "Type.String" then tag = "string"
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
            MT = coder._nominal_metatable_expr(ctx, typ),
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
    return coder._dynamiccheckandset_from_get(ctx, typ, dst, src, loc)
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
        return coder._code_checked_numeric_setslot(typ, dst, src)
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        return coder._code_checked_numeric_setslot(typ, dst, src)
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

coder._dynamic_op_for_tag = {
    ["Type.Integer"] = "integer",
    ["Type.Float"] = "float",
    ["Type.Boolean"] = "truthiness",
    ["Type.Nil"] = "nil",
    ["Type.String"] = "string",
    ["Type.Value"] = "value",
    ["Type.Array"] = "array",
    ["Type.Map"] = "map",
    ["Type.Function"] = "callable",
    ["Type.Nominal"] = "nominal",
    ["Type.Record"] = "nominal",
    ["Type.Union"] = "nominal",
    ["Type.Interface"] = "nominal",
    ["Type.Option"] = "option",
    ["Type.CInteger"] = "c_integer",
    ["Type.CFloat"] = "c_float",
    ["Type.COwned"] = "c_owned",
}

-- Validate the checker-owned dynamic decision before emitting any operation.
-- `false` is an explicit unavailable policy at the annotated root (currently
-- raw C pointers and compounds that contain one); nil means a checker
-- annotation was lost. A nonfalse Option plan is inductive and therefore must
-- contain one complete, nonfalse child plan.
function coder._checked_dynamic_plan_impl(plan, typ, use, seen, root)
    assert(plan ~= nil,
        (use or "dynamic boundary") .. " is missing its checker plan")
    if plan == false then
        assert(root,
            (use or "dynamic boundary")
                .. " contains an unavailable recursive plan")
        return false
    end
    assert(plan.kind == "dynamic_coercion",
        (use or "dynamic boundary") .. " has unknown plan kind "
            .. tostring(plan.kind))

    local target = assert(types.normalize(typ),
        (use or "dynamic boundary") .. " has an unnormalizable target")
    assert(plan.target and types.equals(plan.target, target),
        (use or "dynamic boundary") .. " plan target does not match "
            .. types.tostring(typ))

    seen = seen or {}
    local prior = seen[plan]
    if prior then
        assert(types.equals(prior.target, target),
            (use or "dynamic boundary")
                .. " reuses one recursive plan for different targets")
        assert(not prior.active,
            (use or "dynamic boundary")
                .. " contains a recursive dynamic-plan cycle")
        return plan
    end
    seen[plan] = { target = target, active = true }

    local expected = types.is_c_tvalue(target)
        and "c_tvalue" or coder._dynamic_op_for_tag[target._tag]
    assert(expected,
        (use or "dynamic boundary") .. " has unsupported target "
            .. types.tostring(target))
    assert(plan.op == expected,
        (use or "dynamic boundary") .. " has unknown/mismatched operation "
            .. tostring(plan.op))
    if plan.op == "option" then
        coder._checked_dynamic_plan_impl(
            plan.inner, target.base,
            (use or "dynamic boundary") .. " Option present value",
            seen, false)
    end
    seen[plan].active = false
    return plan
end

function coder._checked_dynamic_plan(plan, typ, use)
    return coder._checked_dynamic_plan_impl(plan, typ, use, {}, true)
end

-- Store a native/internal Titan value in a Lua-visible TValue domain.  Arrays
-- are the exceptional representation: internal storage is the backing Table,
-- while Lua/value/raw-Map storage is the canonical proxy Udata.  Keep this
-- helper semantically typed (rather than dispatching on ctype): Array and Map
-- both use Table*, and Option(Array), value, and Function all use TValue.
function setboxed(ctx, typ --[[:table]], dst --[[:string]], src --[[:string]])
    if typ._tag == "Type.Array" then
        return render([[
            {
                Udata *_titan_proxy =
                    titan_array_require_proxy(L, $SRC, $META);
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
            META = array_metatable(ctx),
        })
    elseif typ._tag == "Type.Option"
           and typ.base._tag == "Type.Array" then
        return render([[
            do {
                TValue _titan_v = $SRC;
                if (ttisnil(&_titan_v)) {
                    setnilvalue($DST);
                } else {
                    Udata *_titan_proxy = titan_array_require_proxy(
                        L, hvalue(&_titan_v), $META);
                    setuvalue(L, $DST, _titan_proxy);
                }
            } while (0);
        ]], {
            DST = dst,
            SRC = src,
            META = array_metatable(ctx),
        })
    elseif typ._tag == "Type.Nominal" then
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

-- Publish a compiler-internal TValue slot through a Lua accessor.  This is
-- type-aware for Array and Option(Array); every other internal slot already
-- has its Lua-visible representation.
function copyboxed(ctx, typ, dst, src)
    if typ._tag == "Type.Array" then
        return render([[
            {
                Udata *_titan_proxy = titan_array_require_proxy(
                    L, hvalue($SRC), $META);
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
            META = array_metatable(ctx),
        })
    elseif typ._tag == "Type.Option"
           and typ.base._tag == "Type.Array" then
        return render([[
            if (ttisnil($SRC)) {
                setnilvalue($DST);
            } else {
                Udata *_titan_proxy = titan_array_require_proxy(
                    L, hvalue($SRC), $META);
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
            META = array_metatable(ctx),
        })
    end
    return render([[
        setobj2t(L, $DST, $SRC);
    ]], {
        DST = dst,
        SRC = src,
    })
end

-- Array/Map element slots can legitimately come from two storage domains:
-- Titan writes nested Arrays as raw backing Tables, while Lua writes canonical
-- proxies through __newindex and raw-visible Maps always store proxies.  These
-- converters accept exactly those sanctioned forms and normalize the result to
-- Titan's internal representation.  `value` is the dual case: a raw backing
-- encountered in an internal slot is boxed, while an ordinary Map Table passes
-- through unchanged.
function checkandgetmixed(ctx, typ, cvar, exp, loc)
    if typ._tag == "Type.Array" then
        return render([[
            {
                Table *_titan_array = NULL;
                if (ttistable($EXP)) {
                    Table *_titan_candidate = hvalue($EXP);
                    if (titan_array_try_proxy(_titan_candidate, $META) != NULL)
                        _titan_array = _titan_candidate;
                } else {
                    _titan_array = titan_array_try_backing($EXP, $META);
                }
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    $VAR = _titan_array;
                } else {
                    $THROW
                }
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx),
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Value" then
        return render([[
            if (ttistable($EXP)) {
                Udata *_titan_proxy =
                    titan_array_try_proxy(hvalue($EXP), $META);
                if (_titan_proxy != NULL) {
                    setuvalue(L, &$VAR, _titan_proxy);
                } else {
                    setobj2t(L, &$VAR, $EXP);
                }
            } else {
                setobj2t(L, &$VAR, $EXP);
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx),
            VAR = cvar,
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECK
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CHECK = checkandsetmixed(ctx, typ.base, "&" .. cvar, exp, loc),
        })
    end
    return checkandget(ctx, typ, cvar, exp, loc)
end

checkandsetmixed = function(ctx, typ, dst, src, loc)
    if typ._tag == "Type.Array" then
        return render([[
            {
                Table *_titan_array = NULL;
                if (ttistable($SRC)) {
                    Table *_titan_candidate = hvalue($SRC);
                    if (titan_array_try_proxy(_titan_candidate, $META) != NULL)
                        _titan_array = _titan_candidate;
                } else {
                    _titan_array = titan_array_try_backing($SRC, $META);
                }
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    sethvalue(L, $DST, _titan_array);
                } else {
                    $THROW
                }
            }
        ]], {
            SRC = src,
            DST = dst,
            META = array_metatable(ctx),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($SRC))" }),
        })
    elseif typ._tag == "Type.Value" then
        return render([[
            if (ttistable($SRC)) {
                Udata *_titan_proxy =
                    titan_array_try_proxy(hvalue($SRC), $META);
                if (_titan_proxy != NULL) {
                    setuvalue(L, $DST, _titan_proxy);
                } else {
                    setobj2t(L, $DST, $SRC);
                }
            } else {
                setobj2t(L, $DST, $SRC);
            }
        ]], {
            SRC = src,
            DST = dst,
            META = array_metatable(ctx),
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($SRC)) {
                setnilvalue($DST);
            } else {
                $CHECK
            }
        ]], {
            SRC = src,
            DST = dst,
            CHECK = checkandsetmixed(ctx, typ.base, dst, src, loc),
        })
    end
    return checkandset(ctx, typ, dst, src, loc)
end

local function foreigncast(exp, typ --[[:table]])
    return render([[(($CASTTYPE)($CEXP))]], {
        CASTTYPE = coder._render_c_type_name(typ),
        CEXP = exp,
    })
end

function coder._raw_ctype(typ --[[:table]])
    if typ._tag == "Type.Integer" then return "lua_Integer"
    elseif typ._tag == "Type.Float" then return "lua_Number"
    elseif typ._tag == "Type.Boolean" then return "int"
    elseif typ._tag == "Type.Nil" then return "int"
    elseif typ._tag == "Type.String" then return "TString*"
    elseif typ._tag == "Type.Array" then return "Table*"
    elseif typ._tag == "Type.Map" then return "Table*"
    elseif typ._tag == "Type.Value" then return "TValue"
    elseif typ._tag == "Type.Nominal" then return "Udata*"
    elseif typ._tag == "Type.Pointer" then
        return cdeclarator.render_type_name(typ)
    elseif typ._tag == "Type.COwned" then
        return cdeclarator.render_type_name(typ)
    elseif types.is_direct_c(typ) then
        return cdeclarator.render_type_name(
            cdeclarator.adjust_parameter_type(typ))
    elseif typ._tag == "Type.Option" then return "TValue"
    -- A first-class function value is boxed (it may be a Titan closure, a Lua
    -- closure, a C function, or a `__call` object), like `value`/`option`.
    elseif typ._tag == "Type.Function" then return "TValue"
    -- A foreign typedef of a supported scalar (e.g. size_t -> integer) can
    -- leak in via inference; use the C type of its resolved underlying type.
    elseif typ._tag == "Type.Typedef" then return coder._raw_ctype(typ._type)
    else error("invalid type " .. types.tostring(typ))
    end
end

local function ctype(typ --[[:table]])
    coder._record_c_type_use(typ)
    return coder._raw_ctype(typ)
end

local function initval(typ --[[:table]])
    if typ._tag == "Type.Value" or typ._tag == "Type.Option"
       or typ._tag == "Type.Function" or types.is_c_tvalue(typ) then
        return "{ {0}, 0 }"
    end
    local resolved = types.resolve_c_typedef(typ)
    if resolved._tag == "Type.CStruct" or resolved._tag == "Type.CUnion" then
        return "{0}"
    end
    return "0"
end

-- Plain C declaration for Titan-visible locals/parameters. Setjmp-sensitive
-- values are protected by explicit spill/reload slots below, keeping the source
-- local/param C autos ordinary (and avoiding volatile in the function ABI).
local function cvardecl(ctx, typ, name)
    if types.is_direct_c(typ) or typ._tag == "Type.Pointer" then
        return coder._render_c_declaration(typ, name)
    end
    return ctype(typ) .. " " .. name
end

local function fresh_lowering_name(ctx, prefix)
    local index = ctx.tmp or 1
    ctx.tmp = index + 1
    return prefix .. tostring(index)
end

-- Some boxed-store paths predate checker-owned boundary plans, but C
-- scalar/pointer values still need a native temporary because their boxed and
-- native representations differ.  This helper only performs that mechanical
-- representation step; its caller remains responsible for authorization.
function coder._dynamiccheckandset_from_get(ctx, typ, dst, src, loc)
    local name = fresh_lowering_name(ctx, "_titan_checked_c_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = checkandget(ctx, typ, name, src, loc),
        STORE = setslot(typ, dst, name),
    })
end

-- Lower the checker-owned DynamicCoercionPlan to a native/internal result.
-- The per-type emitter below is deliberately not an authorization oracle: the
-- plan operation is validated first, Option recursion consumes `inner`, and a
-- checked unavailable marker emits a well-behaved boundary error.
function coder._dynamiccheckandget(ctx, plan, typ, cvar, exp, loc, use)
    plan = coder._checked_dynamic_plan(plan, typ, use)
    if plan == false then
        return render([[
            (void)($EXP);
            $THROW
        ]], {
            EXP = exp,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            TYPE = c_string_literal(types.tostring(typ)),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, dynamic coercion to %s is unavailable",
                { "$FILE", "$LINE", "$COL", "$TYPE" }),
        })
    elseif plan.op == "option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $PRESENT
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            PRESENT = coder._dynamiccheckandset(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "dynamic boundary") .. " Option present value"),
        })
    end
    return checkandget(ctx, typ, cvar, exp, loc)
end

-- Derive the boxed-store form from the exact same native-result plan.  This is
-- the single path used by Lua formals, module/record writes, Array writers,
-- and any other genuine Lua sink, preventing representation-specific drift.
function coder._dynamiccheckandset(ctx, plan, typ, dst, src, loc, use)
    local name = fresh_lowering_name(ctx, "_titan_dynamic_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._dynamiccheckandget(
            ctx, plan, typ, name, src, loc, use),
        STORE = setslot(typ, dst, name),
    })
end

function coder._planned_value_projection_get(ctx, node, cvar, source)
    local adjustment = node._adjustment
    if adjustment
       and adjustment.kind == "gradual_view"
       and adjustment.op == "project" then
        return coder._strictcheckandget(
            ctx, adjustment.guard, node._type, cvar, source, node.loc,
            "implicit value projection")
    elseif adjustment
           and adjustment.kind == "direct_coercion"
           and adjustment.coercion
           and adjustment.coercion.op == "value_to_c_value" then
        -- A named Option force/map may carry the strict Value-to-C leaf as an
        -- inner coercion because the outer Option operation is itself direct.
        -- It retains gradual-observation semantics: exact C scalar/owned
        -- categories only, never the broader written/Lua conversion.
        return coder._strictcheckandget(
            ctx, adjustment.coercion.guard, node._type, cvar, source,
            node.loc, "Option-composed value projection")
    end

    local cast = assert(node._written_cast,
        "value projection is missing its checker written-cast plan")
    if cast.op == "dynamic" then
        return coder._dynamiccheckandget(
            ctx, assert(cast.dynamic,
                "dynamic written cast lacks its embedded plan"),
            node._type, cvar, source, node.loc, "written value as")
    elseif cast.op == "explicit"
           and cast.conversion
           and cast.conversion.op == "unsafe_dynamic_c_pointer" then
        local target = types.normalize(node._type)
        assert(target and target._tag == "Type.CPointer",
            "unsafe dynamic pointer exception has a non-pointer target")
        -- This is the sole intentional use of the old lightuserdata
        -- category conversion without a DynamicCoercionPlan.  Its authority
        -- is the checker-owned written-cast conversion above.
        return checkandget(ctx, node._type, cvar, source, node.loc)
    end
    error("unknown value projection plan operation " .. tostring(cast.op))
end

coder._gradual_op_for_tag = {
    ["Type.Integer"] = "integer",
    ["Type.Float"] = "float",
    ["Type.Boolean"] = "boolean",
    ["Type.Nil"] = "nil",
    ["Type.String"] = "string",
    ["Type.Value"] = "value",
    ["Type.Array"] = "array",
    ["Type.Map"] = "map",
    ["Type.Function"] = "callable",
    ["Type.Nominal"] = "nominal",
    ["Type.Record"] = "nominal",
    ["Type.Union"] = "nominal",
    ["Type.Interface"] = "nominal",
    ["Type.Option"] = "option",
    ["Type.CInteger"] = "c_integer",
    ["Type.CFloat"] = "c_float",
    ["Type.COwned"] = "c_owned",
}

local function checked_gradual_guard(plan, typ, use, seen, root)
    use = use or "strict gradual observation"
    assert(plan ~= nil, use .. " is missing its checker guard plan")
    if plan == false then
        assert(root, use .. " contains an unavailable recursive guard")
        return false
    end
    assert(plan.kind == "gradual_guard",
        use .. " has unknown guard plan kind " .. tostring(plan.kind))

    local target = assert(types.normalize(typ),
        use .. " has an unnormalizable target")
    assert(plan.target and types.equals(plan.target, target),
        use .. " guard target does not match " .. types.tostring(typ))

    seen = seen or {}
    if seen[plan] then
        assert(types.equals(seen[plan], target),
            use .. " reuses one recursive guard for different targets")
        return plan
    end
    seen[plan] = target

    local expected = types.is_c_tvalue(target)
        and "c_tvalue" or coder._gradual_op_for_tag[target._tag]
    assert(expected,
        use .. " has unsupported guard target " .. types.tostring(target))
    assert(plan.op == expected,
        use .. " has unknown/mismatched guard operation "
            .. tostring(plan.op))
    if expected == "array" then
        checked_gradual_guard(
            plan.element, target.elem, use .. " Array element", seen, false)
    elseif expected == "map" then
        checked_gradual_guard(
            plan.key, target.keys, use .. " Map key", seen, false)
        checked_gradual_guard(
            plan.value, target.values, use .. " Map value", seen, false)
    elseif expected == "option" then
        checked_gradual_guard(
            plan.inner, target.base, use .. " Option present value",
            seen, false)
    end
    return plan
end

function coder._checked_gradual_guard(plan, typ, use)
    return checked_gradual_guard(plan, typ, use, {}, true)
end

function coder._checked_plan_pair(plan, source_type, target_type, use)
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")
    local planned_source = plan.source and types.normalize(plan.source)
    local planned_target = plan.target and types.normalize(plan.target)
    assert(planned_source and planned_target
           and types.equals(planned_source, source)
           and types.equals(planned_target, target),
        use .. " plan does not match its operand types")
    return source, target
end

function coder._checked_identity_plan(plan, source_type, target_type, use)
    assert(plan ~= nil, use .. " lacks its checker plan")
    assert(plan ~= false, use .. " reached code generation after rejection")
    assert(plan.kind == "identity",
        use .. " has unknown plan kind " .. tostring(plan.kind))
    local source, target =
        coder._checked_plan_pair(plan, source_type, target_type, use)
    assert(types.equals(source, target),
        use .. " identity plan changes its operand type")
    return plan
end

function coder._is_c_pointer_plan_type(typ)
    return typ and typ._tag == "Type.CPointer"
end

function coder._is_boxable_c_value_plan_type(typ)
    if not typ then return false end
    return typ._tag == "Type.CInteger"
        or typ._tag == "Type.CFloat"
        or typ._tag == "Type.COwned"
        or types.is_c_tvalue(typ)
        or (typ._tag == "Type.CPointer"
            and types.c_pointer_category(typ) ~= "function")
end

function coder._checked_coercion_plan_impl(
        coercion, source_type, target_type, use, seen)
    use = use or "direct coercion"
    assert(coercion ~= nil, use .. " lacks its checker plan")
    assert(coercion ~= false,
        use .. " reached code generation after rejection")
    if coercion.kind == "identity" then
        return coder._checked_identity_plan(
            coercion, source_type, target_type, use)
    end
    assert(coercion.kind == "coercion",
        use .. " has unknown plan kind " .. tostring(coercion.kind))

    local source, target =
        coder._checked_plan_pair(coercion, source_type, target_type, use)
    seen = seen or {}
    local prior = seen[coercion]
    if prior then
        assert(types.equals(prior.source, source)
               and types.equals(prior.target, target),
            use .. " reuses one recursive plan for different operand types")
        assert(not prior.active,
            use .. " contains a recursive coercion cycle")
        return coercion
    end
    seen[coercion] = {
        source = source,
        target = target,
        active = true,
    }

    local op = coercion.op
    local numeric_key = source._tag .. ":" .. target._tag
    local expected_numeric = coder._numeric_coercion_ops
        and coder._numeric_coercion_ops[numeric_key]
    if expected_numeric and op == expected_numeric then
        coder._checked_numeric_coercion(
            coercion, source, target, use)
    elseif op == "c_enum_integer" then
        assert(types.is_c_enum_integer_conversion(source, target),
            use .. " has a mismatched C enum/integer operation")
    elseif op == "c_automatic_to_owned" then
        local resolved_source = types.resolve_c_typedef(source)
        assert(target._tag == "Type.COwned" and not target.count
               and (resolved_source._tag == "Type.CStruct"
                    or resolved_source._tag == "Type.CUnion")
               and types.equals(source,
                   types.resolve_c_typedef(target.pointee)),
            use .. " has a mismatched automatic-C-object ownership operation")
    elseif op == "c_automatic_array_to_owned" then
        assert(target._tag == "Type.COwned" and target.count
               and source._tag == "Type.CArray"
               and type(source.len) == "number"
               and types.equals(source.elem, target.pointee),
            use .. " has a mismatched automatic-C-array ownership operation")
    elseif op == "c_owner_truthiness" then
        assert(source._tag == "Type.COwned"
               and target._tag == "Type.Boolean",
            use .. " has a mismatched C-owner truthiness operation")
    elseif op == "c_pointer_truthiness" then
        assert(coder._is_c_pointer_plan_type(source)
               and target._tag == "Type.Boolean",
            use .. " has a mismatched C-pointer truthiness operation")
    elseif op == "nil_to_c_pointer" then
        assert(source._tag == "Type.Nil"
               and coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched nil-to-C-pointer operation")
    elseif op == "c_address" then
        assert(types.c_address_coerceable(source, target),
            use .. " has a mismatched const C-address operation")
    elseif op == "mutable_c_address" then
        assert(types.c_mutable_address_coerceable(source, target),
            use .. " has a mismatched mutable C-address operation")
    elseif op == "c_pointer" then
        assert(types.is_c_pointer_coercion(source, target),
            use .. " has a mismatched C-pointer operation")
    elseif op == "c_object_to_void_pointer" then
        assert(types.is_c_object_to_void_pointer_conversion(
                source, target),
            use .. " has a mismatched C object-to-void-pointer operation")
    elseif op == "c_void_to_object_pointer" then
        assert(types.is_c_void_to_object_pointer_coercion(
                source, target),
            use .. " has a mismatched C void-to-object-pointer operation")
    elseif op == "string_to_c_pointer" then
        assert(types.is_string_to_c_pointer_coercion(source, target),
            use .. " has a mismatched string-to-C-pointer operation")
    elseif op == "c_value_to_value" then
        assert(coder._is_boxable_c_value_plan_type(source)
               and target._tag == "Type.Value",
            use .. " has a mismatched C-value boxing operation")
    elseif op == "value_to_c_value" then
        assert(source._tag == "Type.Value"
               and coder._is_boxable_c_value_plan_type(target)
               and not coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched value-to-C operation")
        coder._checked_gradual_guard(
            coercion.guard, target, use .. " strict C-value guard")
    elseif op == "c_value_to_c_tvalue" then
        assert(coder._is_boxable_c_value_plan_type(source)
               and types.is_c_tvalue(target),
            use .. " has a mismatched C-TValue boxing operation")
    elseif op == "to_c_tvalue" then
        assert(not types.is_direct_c(source)
               and types.is_c_tvalue(target),
            use .. " has a mismatched whole-slot C-TValue operation")
    elseif op == "truthiness" then
        assert(target._tag == "Type.Boolean"
               and source._tag ~= "Type.Boolean"
               and source._tag ~= "Type.Value"
               and not types.is_direct_c(source),
            use .. " has a mismatched truthiness operation")
    elseif op == "option_nil" then
        assert(source._tag == "Type.Nil"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-nil operation")
        assert(coercion.inner == nil,
            use .. " Option-nil operation has an unexpected inner plan")
    elseif op == "option_map" then
        assert(source._tag == "Type.Option"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-map operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source.base, target.base,
            use .. " Option map", seen)
    elseif op == "option_wrap" then
        assert(source._tag ~= "Type.Nil"
               and source._tag ~= "Type.Option"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-wrap operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source, target.base,
            use .. " Option wrap", seen)
    elseif op == "option_force" then
        assert(source._tag == "Type.Option"
               and target._tag ~= "Type.Option",
            use .. " has a mismatched Option-force operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source.base, target,
            use .. " Option force", seen)
    elseif op == "legacy_pointer" then
        assert(target._tag == "Type.Pointer"
               and (source._tag == "Type.Pointer"
                    or source._tag == "Type.String"
                    or source._tag == "Type.Nil"),
            use .. " has a mismatched legacy-pointer operation")
    elseif op == "interface_wrapper" then
        assert(source._tag == "Type.Nominal"
               and target._tag == "Type.Nominal"
               and type(coercion.methods) == "table",
            use .. " has a mismatched Interface-wrapper operation")
        -- The scalar operation is representation-changing and must be paired
        -- with the richer cast-site `_interface_conversion` annotation. This
        -- validator only proves that the ordinary coercion tree retained the
        -- expected endpoint/op; expression lowering validates and consumes the
        -- canonical descriptors, ordered mappings, and exactness marker.
    else
        error(use .. " has unknown/mismatched operation " .. tostring(op))
    end

    seen[coercion].active = false
    return coercion
end

function coder._checked_coercion_plan(
        coercion, source_type, target_type, use)
    return coder._checked_coercion_plan_impl(
        coercion, source_type, target_type, use, {})
end

function coder._checked_callable_plan_impl(
        callable, source_type, target_type, use, seen)
    use = use or "callable adjustment"
    assert(callable ~= nil, use .. " lacks its checker plan")
    assert(callable ~= false,
        use .. " reached code generation after rejection")
    assert(callable.kind == "callable",
        use .. " has unknown plan kind " .. tostring(callable.kind))
    local source, target =
        coder._checked_plan_pair(callable, source_type, target_type, use)
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function",
        use .. " has non-callable operand types")
    assert(source.vararg == false and target.vararg == false,
        use .. " has a non-false reserved Function slot")
    assert(callable.exact == types.equals(source, target),
        use .. " has a mismatched exact-callable marker")
    assert(type(callable.arguments) == "table"
           and type(callable.results) == "table",
        use .. " lacks its action lists")

    seen = seen or {}
    local prior = seen[callable]
    if prior then
        assert(types.equals(prior.source, source)
               and types.equals(prior.target, target),
            use .. " reuses one recursive plan for different callable types")
        assert(not prior.active,
            use .. " contains a recursive callable-plan cycle")
        return callable
    end
    seen[callable] = {
        source = source,
        target = target,
        active = true,
    }

    local argument_index = 0
    local function argument(kind, label)
        argument_index = argument_index + 1
        local action = callable.arguments[argument_index]
        assert(action,
            use .. " is missing " .. label)
        assert(action.kind == kind,
            use .. " has " .. tostring(action.kind)
                .. " where " .. kind .. " was required")
        return action
    end
    local function component(action, from, to, label)
        assert(action.adjustment
               and action.adjustment.kind ~= "direct_coercion",
            use .. " " .. label
                .. " contains an ordinary component coercion")
        coder._checked_adjustment_plan_impl(
            action.adjustment, from, to,
            use .. " " .. label, seen)
    end

    local function accepts_missing_nil(typ)
        typ = types.normalize(typ)
        local tag = typ and typ._tag
        return tag == "Type.Nil" or tag == "Type.Value"
            or tag == "Type.Option" or tag == "Type.Pointer"
            or tag == "Type.CPointer"
    end

    local shared_arguments = math.min(#source.params, #target.params)
    for index = 1, shared_arguments do
        local action = argument("argument", "shared argument action")
        assert(action.expected_index == index
               and action.actual_index == index,
            use .. " has mismatched shared argument indexes")
        component(action, target.params[index], source.params[index],
            "argument " .. index)
    end
    for index = #target.params + 1, #source.params do
        assert(accepts_missing_nil(source.params[index]),
            use .. " nil-fills a non-nullable actual argument")
        if target.varargtype then
            local action = argument(
                "tail_or_nil_to_argument", "tail-to-argument action")
            assert(action.actual_index == index
                   and action.expected_tail_offset
                       == index - #target.params,
                use .. " has mismatched tail-to-argument indexes")
            component(action, target.varargtype, source.params[index],
                "tail-to-argument " .. index)
        else
            local action = argument("nil_fill", "nil-fill action")
            assert(action.actual_index == index,
                use .. " has a mismatched nil-fill index")
            assert(action.adjustment == nil,
                use .. " nil-fill action has an unexpected adjustment")
        end
    end
    for index = #source.params + 1, #target.params do
        if source.varargtype then
            local action = argument(
                "argument_to_tail", "argument-to-tail action")
            assert(action.expected_index == index,
                use .. " has a mismatched argument-to-tail index")
            component(action, target.params[index], source.varargtype,
                "argument-to-tail " .. index)
        else
            local action = argument(
                "ignore_argument", "ignored-argument action")
            assert(action.expected_index == index,
                use .. " has a mismatched ignored-argument index")
            assert(action.adjustment == nil,
                use .. " ignored-argument action has an unexpected adjustment")
        end
    end
    if source.varargtype and target.varargtype then
        local action = argument("tail_to_tail", "tail-to-tail action")
        assert(action.expected_tail_consumed
                   == math.max(0, #source.params - #target.params),
            use .. " has a mismatched tail-to-tail offset")
        component(action, target.varargtype, source.varargtype,
            "input tail")
    elseif source.varargtype then
        local action = argument("empty_tail", "empty-tail action")
        assert(action.adjustment == nil,
            use .. " empty-tail action has an unexpected adjustment")
    elseif target.varargtype then
        local action = argument("ignore_tail", "ignored-tail action")
        assert(action.expected_tail_consumed
                   == math.max(0, #source.params - #target.params),
            use .. " has a mismatched ignored-tail offset")
        assert(action.adjustment == nil,
            use .. " ignored-tail action has an unexpected adjustment")
    end
    assert(argument_index == #callable.arguments,
        use .. " has unexpected extra argument actions")

    local result_index = 0
    local function result(kind, label)
        result_index = result_index + 1
        local action = callable.results[result_index]
        assert(action,
            use .. " is missing " .. label)
        assert(action.kind == kind,
            use .. " has " .. tostring(action.kind)
                .. " where " .. kind .. " was required")
        return action
    end

    for index, expected in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            local action = result("result", "fixed-result action")
            assert(action.actual_index == index
                   and action.expected_index == index,
                use .. " has mismatched fixed-result indexes")
            component(action, actual, expected, "result " .. index)
        elseif source.flexrettype then
            if expected._tag == "Type.Option" then
                local action = result(
                    "flex_to_optional_result",
                    "flexible-to-optional result action")
                assert(action.expected_index == index
                       and action.actual_flex_offset
                           == index - #source.rettypes,
                    use .. " has mismatched flexible-result indexes")
                assert(action.wrap_present == nil
                       or action.wrap_present == true,
                    use .. " has invalid optional-result wrap metadata")
                local adjusted_target =
                    action.wrap_present and expected.base or expected
                component(action, source.flexrettype, adjusted_target,
                    "flexible result " .. index)
            else
                local action = result(
                    "flex_to_result", "flexible-result action")
                assert(action.expected_index == index
                       and action.actual_flex_offset
                           == index - #source.rettypes,
                    use .. " has mismatched flexible-result indexes")
                assert(action.wrap_present == nil,
                    use .. " non-optional flexible result has wrap metadata")
                component(action, source.flexrettype, expected,
                    "flexible result " .. index)
            end
        else
            local action = result(
                "nil_fill_result", "missing-result nil-fill action")
            assert(accepts_missing_nil(expected)
                   and action.expected_index == index
                   and action.expected_type
                   and types.equals(action.expected_type, expected)
                   and action.adjustment == nil,
                use .. " has a malformed missing-result nil-fill action")
        end
    end
    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            local action = result(
                "result_to_flex", "result-to-flex action")
            assert(action.actual_index == index
                   and action.expected_flex_offset
                       == index - #target.rettypes,
                use .. " has mismatched result-to-flex indexes")
            component(action, source.rettypes[index], target.flexrettype,
                "result-to-flex " .. index)
        else
            local action = result("hide_result", "hidden-result action")
            assert(action.actual_index == index,
                use .. " has a mismatched hidden-result index")
            assert(action.adjustment == nil,
                use .. " hidden-result action has an unexpected adjustment")
        end
    end
    if source.flexrettype and target.flexrettype then
        local action = result("flex_to_flex", "flex-to-flex action")
        assert(action.actual_flex_consumed
                   == math.max(0, #target.rettypes - #source.rettypes),
            use .. " has a mismatched flex-to-flex offset")
        component(action, source.flexrettype, target.flexrettype,
            "flexible result tail")
    elseif source.flexrettype then
        local action = result("hide_flex", "hidden-flex action")
        assert(action.actual_flex_consumed
                   == math.max(0, #target.rettypes - #source.rettypes),
            use .. " has a mismatched hidden-flex offset")
        assert(action.adjustment == nil,
            use .. " hidden-flex action has an unexpected adjustment")
    elseif target.flexrettype then
        local action = result("end_flex", "end-flex action")
        assert(action.adjustment == nil,
            use .. " end-flex action has an unexpected adjustment")
    end
    assert(result_index == #callable.results,
        use .. " has unexpected extra result actions")

    seen[callable].active = false
    return callable
end

function coder._checked_adjustment_plan_impl(
        adjustment, source_type, target_type, use, seen)
    use = use or "assignment adjustment"
    assert(adjustment ~= nil, use .. " lacks its checker plan")
    assert(adjustment ~= false,
        use .. " reached code generation after rejection")
    local kind = adjustment.kind
    if kind == "identity" then
        return coder._checked_identity_plan(
            adjustment, source_type, target_type, use)
    end

    local source, target =
        coder._checked_plan_pair(adjustment, source_type, target_type, use)
    if kind == "direct_coercion" then
        coder._checked_coercion_plan_impl(
            adjustment.coercion, source, target,
            use .. " direct coercion", {})
    elseif kind == "gradual_view" then
        local op = adjustment.op
        if op == "inject" then
            assert(target._tag == "Type.Value"
                   and source._tag ~= "Type.Value",
                use .. " has a mismatched gradual injection")
            assert(adjustment.guard == nil,
                use .. " gradual injection has an unexpected guard")
        elseif op == "project" then
            assert(source._tag == "Type.Value"
                   and target._tag ~= "Type.Value",
                use .. " has a mismatched gradual projection")
            coder._checked_gradual_guard(
                adjustment.guard, target, use .. " projection guard")
        elseif op == "structural" then
            assert(source._tag == target._tag
                   and (source._tag == "Type.Array"
                        or source._tag == "Type.Map"
                        or source._tag == "Type.Option"),
                use .. " has a mismatched structural gradual view")
            coder._checked_gradual_guard(
                adjustment.guard, target, use .. " structural guard")
        else
            error(use .. " has unknown gradual-view operation "
                .. tostring(op))
        end
    elseif kind == "callable" then
        coder._checked_callable_plan_impl(
            adjustment, source, target, use, seen or {})
    else
        error(use .. " has unknown plan kind " .. tostring(kind))
    end
    return adjustment
end

function coder._checked_adjustment_plan(
        adjustment, source_type, target_type, use)
    return coder._checked_adjustment_plan_impl(
        adjustment, source_type, target_type, use, {})
end

function coder._checked_callable_plan(
        callable, source_type, target_type, use)
    return coder._checked_callable_plan_impl(
        callable, source_type, target_type, use, {})
end

coder._explicit_conversion_ops = {
    pointer_to_string = true,
    gc_identity_to_void_pointer = true,
    legacy_pointer_to_c_void = true,
    c_function_pointer_to_void = true,
    c_void_to_function_pointer = true,
    counted_owner_to_string = true,
    c_numeric = true,
    c_object_to_void_pointer = true,
    c_void_to_object_pointer = true,
    unsafe_dynamic_c_pointer = true,
}

function coder._checked_explicit_conversion_plan(
        conversion, source_type, target_type, use)
    use = use or "written explicit conversion"
    assert(conversion ~= nil, use .. " lacks its checker plan")
    assert(conversion ~= false,
        use .. " reached code generation after rejection")
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")

    if conversion.kind == "unsafe_object_pointer"
       or conversion.kind == "address_then_unsafe_object_pointer" then
        local planned_source = conversion.source
            and types.normalize(conversion.source)
        local planned_target = conversion.target
            and types.normalize(conversion.target)
        local expected_source
        local source_is_addressable_object = source._tag == "Type.CStruct"
            or source._tag == "Type.CUnion"
        if conversion.kind == "unsafe_object_pointer" then
            if coder._is_c_pointer_plan_type(source) then
                expected_source = source
            elseif source._tag == "Type.CArray" then
                expected_source = types.normalize(
                    types.c_local_address_pointer(source_type))
            end
        else
            expected_source = types.normalize(
                types.c_local_address_pointer(source_type))
        end
        local candidate = planned_source and planned_target
            and types.c_unsafe_object_pointer_candidate(
                planned_source, planned_target)
        assert(coder._is_c_pointer_plan_type(planned_source)
               and coder._is_c_pointer_plan_type(expected_source)
               and coder._is_c_pointer_plan_type(planned_target)
               and coder._is_c_pointer_plan_type(target)
               and candidate
               and types.equals(planned_source, expected_source)
               and types.equals(planned_target, target)
               and type(conversion.probe_key) == "string"
               and conversion.probe_key ~= "",
            use .. " has a mismatched checked C-pointer operation")
        if conversion.kind == "unsafe_object_pointer" then
            assert(coder._is_c_pointer_plan_type(source)
                   or source._tag == "Type.CArray",
                use .. " has an invalid checked C-pointer source")
        else
            assert(source_is_addressable_object,
                use .. " has an invalid checked C-address source")
        end
        return conversion
    end

    assert(conversion.kind == "explicit_conversion",
        use .. " has unknown plan kind " .. tostring(conversion.kind))
    coder._checked_plan_pair(conversion, source, target, use)
    assert(coder._explicit_conversion_ops[conversion.op],
        use .. " has unknown operation " .. tostring(conversion.op))

    local op = conversion.op
    if op == "c_numeric" then
        coder._checked_explicit_numeric_conversion(
            conversion, source, target, use)
    elseif op == "pointer_to_string" then
        assert(types.is_pointer_to_string_cast(source, target),
            use .. " has a mismatched pointer-to-string operation")
    elseif op == "counted_owner_to_string" then
        assert(types.is_counted_c_character_owner(source)
               and target._tag == "Type.String",
            use .. " has a mismatched counted-owner-to-string operation")
    elseif op == "unsafe_dynamic_c_pointer" then
        assert(source._tag == "Type.Value"
               and coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched unsafe dynamic-pointer operation")
    elseif op == "gc_identity_to_void_pointer" then
        assert(types.is_gc_identity_void_pointer_cast(source, target),
            use .. " has a mismatched GC-identity pointer operation")
    elseif op == "legacy_pointer_to_c_void" then
        assert(types.is_legacy_pointer_to_c_void_cast(source, target),
            use .. " has a mismatched legacy-to-C-pointer operation")
    elseif op == "c_function_pointer_to_void" then
        assert(types.is_c_function_pointer_void_cast(source, target),
            use .. " has a mismatched C-function-to-void-pointer operation")
    elseif op == "c_void_to_function_pointer" then
        assert(types.is_c_void_function_pointer_cast(source, target),
            use .. " has a mismatched C-void-to-function-pointer operation")
    elseif op == "c_object_to_void_pointer" then
        assert(types.is_c_object_to_void_pointer_conversion(
                source, target),
            use .. " has a mismatched written object-to-void-pointer operation")
    elseif op == "c_void_to_object_pointer" then
        assert(types.is_written_c_void_to_object_pointer_cast(
                source, target),
            use .. " has a mismatched written void-to-object-pointer operation")
    end
    return conversion
end

function coder._checked_written_cast_plan(
        cast, source_type, target_type, use)
    use = use or "written cast"
    assert(cast ~= nil, use .. " lacks its checker plan")
    assert(cast ~= false, use .. " reached code generation after rejection")
    assert(cast.kind == "written_cast",
        use .. " has unknown plan kind " .. tostring(cast.kind))
    local source, target =
        coder._checked_plan_pair(cast, source_type, target_type, use)

    if cast.op == "identity" then
        assert(types.equals(source, target),
            use .. " identity operation changes its operand type")
    elseif cast.op == "dynamic" then
        assert(source._tag == "Type.Value",
            use .. " dynamic operation has a non-value source")
        coder._checked_dynamic_plan(
            cast.dynamic, target, use .. " dynamic conversion")
    elseif cast.op == "coercion" then
        coder._checked_coercion_plan(
            cast.coercion, source, target, use .. " direct coercion")
    elseif cast.op == "explicit" then
        coder._checked_explicit_conversion_plan(
            cast.conversion, source, target, use .. " explicit conversion")
    elseif cast.op == "callable" then
        coder._checked_callable_plan(
            cast.callable, source, target, use .. " callable adjustment")
    elseif cast.op == "gradual" then
        coder._checked_adjustment_plan(
            cast.view, source, target, use .. " gradual view")
        assert(cast.guard == cast.view.guard,
            use .. " gradual guard differs from its view plan")
    elseif cast.op == "interface_downcast" then
        local source_base = source._tag == "Type.Option"
            and source.base or source
        local source_owner = source_base._tag == "Type.Nominal"
            and types.registry[source_base.fqtn] or nil
        local target_owner = target._tag == "Type.Nominal"
            and types.registry[target.fqtn] or nil
        assert(source_owner
               and source_owner._tag == "Type.Interface"
               and target_owner
               and (target_owner._tag == "Type.Record"
                    or target_owner._tag == "Type.Union"),
            use .. " has a mismatched Interface downcast")
    else
        error(use .. " has unknown operation " .. tostring(cast.op))
    end
    return cast
end

function coder._checked_comparison_plan(plan, left, right, use)
    use = use or "equality comparison"
    assert(plan ~= nil, use .. " is missing its checker comparison plan")
    assert(plan ~= false, use .. " reached code generation after rejection")
    assert(plan.kind == "comparison",
        use .. " has unknown comparison plan kind " .. tostring(plan.kind))
    left, right = types.normalize(left), types.normalize(right)
    assert(left and right and plan.left and plan.right
           and types.equals(plan.left, left)
           and types.equals(plan.right, right),
        use .. " comparison plan does not match its operand types")
    local op = plan.op
    assert(op == "identity" or op == "consistent"
           or op == "numeric" or op == "option",
        use .. " has unknown comparison operation " .. tostring(op))
    if op == "identity" then
        assert(types.equals(left, right),
            use .. " identity comparison has unequal operands")
    elseif op == "numeric" then
        assert((left._tag == "Type.Integer"
                and right._tag == "Type.Float")
               or (left._tag == "Type.Float"
                   and right._tag == "Type.Integer"),
            use .. " numeric comparison has nonnumeric operand tags")
    elseif op == "consistent" then
        local left_value = left._tag == "Type.Value"
        local right_value = right._tag == "Type.Value"
        if left_value ~= right_value then
            local adjustment
            local unexpected
            if left_value then
                adjustment = plan.right_adjustment
                unexpected = plan.left_adjustment
            else
                adjustment = plan.left_adjustment
                unexpected = plan.right_adjustment
            end
            assert(unexpected == nil,
                use .. " has an adjustment on the value operand")
            coder._checked_adjustment_plan_impl(
                adjustment,
                left_value and right or left,
                left_value and left or right,
                use .. " value injection", {})
        else
            assert(not left_value,
                use .. " consistent comparison duplicates identity")
            assert(plan.left_adjustment == nil
                   and plan.right_adjustment == nil,
                use .. " has an unexpected consistency adjustment")
            assert(left._tag == right._tag
                   and (left._tag == "Type.Array"
                        or left._tag == "Type.Map"
                        or left._tag == "Type.Option"
                        or left._tag == "Type.Function"),
                use .. " has no structural consistency evidence")
        end
    elseif op == "option" then
        assert(left._tag == "Type.Option"
               and right._tag == "Type.Option",
            use .. " Option comparison has non-Option operands")
        coder._checked_comparison_plan(
            plan.inner, left.base, right.base, use .. " Option payload")
    end
    return plan
end

-- Read a boxed slot for a Titan observation through a gradual view.  Unlike
-- `checkandget`, this is a tag guard, not a dynamic conversion: Titan integer,
-- float, and boolean representations must already be exact.  The remaining
-- categories already use exact outer-kind/metatable checks in `checkandget`;
-- Option recurses here so its present arm cannot accidentally regain the
-- coercive numeric/truthiness policy.
function coder._strictcheckandget(ctx, plan, typ, cvar, exp, loc, use)
    plan = coder._checked_gradual_guard(plan, typ, use)
    if plan == false then
        return render([[
            (void)($EXP);
            $THROW
        ]], {
            EXP = exp,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            TYPE = c_string_literal(types.tostring(typ)),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, strict observation of %s is unavailable",
                { "$FILE", "$LINE", "$COL", "$TYPE" }),
        })
    end
    local resolved = typ._tag == "Type.CTypedef"
        and types.resolve_c_typedef(typ) or typ
    if typ._tag == "Type.Integer" then
        return render([[
            if (TITAN_LIKELY(ttisinteger($EXP))) {
                $VAR = ivalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected integer tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Float" then
        return render([[
            if (TITAN_LIKELY(ttisfloat($EXP))) {
                $VAR = fltvalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected float tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Boolean" then
        return render([[
            if (TITAN_LIKELY(ttisboolean($EXP))) {
                $VAR = !l_isfalse($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected boolean tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif resolved._tag == "Type.CInteger" then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, true)
    elseif resolved._tag == "Type.CFloat" then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, true)
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECK
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CHECK = coder._strictcheckandsetmixed(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "strict gradual observation")
                    .. " Option present value"),
        })
    end
    return checkandget(ctx, typ, cvar, exp, loc)
end

-- Box the result of the same strict observation.  Keeping this mechanically
-- derived from `strictcheckandget` prevents the old function-argument versus
-- field-write split from reappearing for strict paths.
function coder._strictcheckandset(ctx, plan, typ, dst, src, loc, use)
    local name = fresh_lowering_name(ctx, "_titan_strict_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._strictcheckandget(
            ctx, plan, typ, name, src, loc, use),
        STORE = setslot(typ, dst, name),
    })
end

-- Array/Map slots may contain a nested Array either as its internal backing or
-- as the canonical Lua proxy.  Normalize only those two sanctioned shapes;
-- all leaf observations still use the strict tag policy above.
function coder._strictcheckandgetmixed(
        ctx, plan, typ, cvar, exp, loc, use)
    plan = coder._checked_gradual_guard(plan, typ, use)
    if plan == false then
        return coder._strictcheckandget(
            ctx, plan, typ, cvar, exp, loc, use)
    end
    if typ._tag == "Type.Array" then
        return render([[
            {
                Table *_titan_array = NULL;
                if (ttistable($EXP)) {
                    Table *_titan_candidate = hvalue($EXP);
                    if (titan_array_try_proxy(_titan_candidate, $META) != NULL)
                        _titan_array = _titan_candidate;
                } else {
                    _titan_array = titan_array_try_backing($EXP, $META);
                }
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    $VAR = _titan_array;
                } else {
                    $THROW
                }
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx),
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Value" then
        return render([[
            if (ttistable($EXP)) {
                Udata *_titan_proxy =
                    titan_array_try_proxy(hvalue($EXP), $META);
                if (_titan_proxy != NULL) {
                    setuvalue(L, &$VAR, _titan_proxy);
                } else {
                    setobj2t(L, &$VAR, $EXP);
                }
            } else {
                setobj2t(L, &$VAR, $EXP);
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx),
            VAR = cvar,
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECK
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CHECK = coder._strictcheckandsetmixed(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "strict gradual observation")
                    .. " Option present value"),
        })
    end
    return coder._strictcheckandget(
        ctx, plan, typ, cvar, exp, loc, use)
end

function coder._strictcheckandsetmixed(
        ctx, plan, typ, dst, src, loc, use)
    local name = fresh_lowering_name(ctx, "_titan_strict_mixed_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._strictcheckandgetmixed(
            ctx, plan, typ, name, src, loc, use),
        STORE = setslot(typ, dst, name),
    })
end

-- Emit the generated dynamic-boundary writer and initialize its module-local
-- cached CClosure for each Array element type constructed by this module.
-- These closures are carried by proxies; they are never published as tags.
function coder._emit_array_writers(tlcontext, sigs, code, initfuncs)
    for _, entry in ipairs(tlcontext.array_writer_list) do
        local loc = {
            filename = "<Lua write to "
                .. types.tostring(types.Array(entry.elem)) .. ">",
            line = 1,
            col = 1,
        }
        table.insert(sigs, render([[
            static int $NAME(lua_State *L);
        ]], {
            NAME = entry.name,
        }))
        table.insert(code, render([[
            static int $NAME(lua_State *L) {
                StkId func = L->ci->func.p;
                if (TITAN_UNLIKELY(L->top.p - func - 1 < 1)) {
                    return luaL_error(L,
                        "missing value for Titan Array writer");
                }
                CClosure *_fn = clCvalue(s2v(func));
                Udata *_mod = uvalue(&_fn->upvalue[0]);
                (void)_mod; /* conversion policies without nominal/C caches */
                titan_ensure_stack(L, 1);
                func = L->ci->func.p;
                TValue *_src = s2v(func + 1);
                $CONVERT
                L->top.p++;
                return 1;
            }
        ]], {
            NAME = entry.name,
            CONVERT = coder._dynamiccheckandset(
                tlcontext, entry.plan, entry.elem,
                "s2v(L->top.p)", "_src", loc, "Array writer"),
        }))
        table.insert(initfuncs, render([[
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $NAME, 1);
            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
            lua_pop(L, 1);
        ]], {
            NAME = entry.name,
            SLOT = c_integer_literal(entry.slot),
        }))
    end
end

local function cpointerdecl(typ, name)
    if types.is_direct_c(typ) or typ._tag == "Type.Pointer" then
        return coder._render_c_declaration(
            types.CPointer(typ, {}), name)
    end
    return ctype(typ) .. " *" .. name
end

local function cpointertype(typ)
    if types.is_direct_c(typ) or typ._tag == "Type.Pointer" then
        return coder._render_c_type_name(types.CPointer(typ, {}))
    end
    return ctype(typ) .. "*"
end

local function cfunctiondecl(rettype, name, params, is_pointer)
    local declarator = is_pointer and "(*" .. name .. ")" or name
    declarator = declarator .. "(" .. params .. ")"
    if rettype
       and (types.is_direct_c(rettype)
            or rettype._tag == "Type.Pointer") then
        return coder._render_c_declaration(rettype, declarator)
    end
    return (rettype and ctype(rettype) or "void") .. " " .. declarator
end

-- A statement after which control never falls through (return/break/raise or a
-- checker-proven infinite loop). The
-- checker does NOT type-check statements that follow such a terminator within a
-- block (they are dead code: their var uses get no `_decl`/`_type`), so the coder
-- MUST NOT attempt to generate them — doing so dereferences those nil
-- annotations. Stopping at the terminator also drops the unreachable C. (This
-- predates error handling: `raise`/`return` followed by any var-using statement
-- always produced unchecked nodes; it only became reachable now that `raise`
-- routinely precedes dead code in try bodies.)
local function is_terminator(node)
    return node._tag == "Ast.StatBreak" or node._always_returns == true
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
-- their existing Lua-stack slots and uses volatile scalar or byte-
-- representation spill storage for non-GC values.
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

-- Follow a C aggregate subobject lvalue back to its automatic root. Pointer
-- dereferences deliberately stop the walk: a raw pointer may alias any object,
-- so only direct by-value aggregate storage has a checker-visible root whose
-- complete representation we can commit.
function coder._lvalue_root_decl(node)
    if not node then return nil end
    if node._tag == "Ast.ExpVar" then
        return coder._lvalue_root_decl(node.var)
    elseif node._tag == "Ast.VarName" then
        local decl = node._decl
        if decl and decl._tag == "Ast.Decl" then return decl end
    elseif node._tag == "Ast.VarDot" then
        if node._decl and node._decl._tag == "Type.CField"
           and node.exp and node.exp._type
           and types.is_c_aggregate(node.exp._type) then
            return coder._lvalue_root_decl(node.exp)
        end
    elseif node._tag == "Ast.VarBracket" then
        if node.exp1 and node.exp1._type
           and types.is_c_aggregate(node.exp1._type) then
            return coder._lvalue_root_decl(node.exp1)
        end
    end
    return nil
end

local function collect_lvalue_write(node, out)
    set_add(out, coder._lvalue_root_decl(node))
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
    elseif tag == "Ast.ExpUnionInit" then
        collect_reads_exp(node.value, out)
    elseif tag == "Ast.ExpUnop" or tag == "Ast.ExpCast"
            or tag == "Ast.ExpIs"
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

function coder._collect_writes_exp(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.VarDot" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.VarBracket" then
        coder._collect_writes_exp(node.exp1, out)
        coder._collect_writes_exp(node.exp2, out)
    elseif tag == "Ast.ExpVar" then
        coder._collect_writes_exp(node.var, out)
    elseif tag == "Ast.ExpInitList" then
        for _, field in ipairs(node.fields) do
            coder._collect_writes_exp(field.exp, out)
        end
    elseif tag == "Ast.ExpCall" then
        for _, decl in ipairs(node._c_mutated_decls or {}) do
            set_add(out, decl)
        end
        coder._collect_writes_exp(node.exp, out)
        for _, arg in ipairs(node.args.args) do
            coder._collect_writes_exp(arg, out)
        end
    elseif tag == "Ast.ExpUnionInit" then
        coder._collect_writes_exp(node.value, out)
    elseif tag == "Ast.ExpUnop" or tag == "Ast.ExpCast"
            or tag == "Ast.ExpIs"
            or tag == "Ast.ExpAdjust" or tag == "Ast.ExpDotsIndex"
            or tag == "Ast.ExpExtra" or tag == "Ast.ExpMethodRef" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.ExpBinop" then
        coder._collect_writes_exp(node.lhs, out)
        coder._collect_writes_exp(node.rhs, out)
    elseif tag == "Ast.ExpConcat" then
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.ExpFunction" then
        -- Nested functions/lambdas have their own setjmp scopes and contexts.
    else
        -- names and literals do not write.
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
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatRepeat" then
        collect_reads_stat(node.block, out)
        collect_reads_exp(node.condition, out)
    elseif tag == "Ast.StatFor" then
        collect_reads_exp(node.start, out)
        collect_reads_exp(node.finish, out)
        collect_reads_exp(node.inc, out)
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatForIn" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            collect_reads_exp(t.condition, out)
            collect_reads_stat(t.block, out)
        end
        collect_reads_stat(node.elsestat, out)
    elseif tag == "Ast.StatCase" then
        collect_reads_exp(node.exp, out)
        for _, arm in ipairs(node.arms) do
            collect_reads_stat(arm.block, out)
        end
        collect_reads_stat(node.elseblock, out)
    elseif tag == "Ast.StatTry" then
        collect_reads_stat(node.block, out)
        collect_reads_stat(node.catchblock, out)
        collect_reads_stat(node.finallyblock, out)
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
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatAssign" then
        for _, var in ipairs(node.vars) do
            collect_lvalue_write(var, out)
            coder._collect_writes_exp(var, out)
        end
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatCall" then
        coder._collect_writes_exp(node.callexp, out)
    elseif tag == "Ast.StatReturn" then
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatRaise" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
            or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
        if tag == "Ast.StatWhile" or tag == "Ast.StatRepeat" then
            coder._collect_writes_exp(node.condition, out)
        elseif tag == "Ast.StatFor" then
            coder._collect_writes_exp(node.start, out)
            coder._collect_writes_exp(node.finish, out)
            coder._collect_writes_exp(node.inc, out)
        else
            for _, exp in ipairs(node.exps) do
                coder._collect_writes_exp(exp, out)
            end
        end
        if tag == "Ast.StatForIn" then
            for _, decl in ipairs(node.decls) do set_add(out, decl) end
        end
        collect_writes_stat(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            coder._collect_writes_exp(t.condition, out)
            collect_writes_stat(t.block, out)
        end
        collect_writes_stat(node.elsestat, out)
    elseif tag == "Ast.StatCase" then
        coder._collect_writes_exp(node.exp, out)
        for _, arm in ipairs(node.arms) do
            set_add(out, arm.binding)
            collect_writes_stat(arm.block, out)
        end
        collect_writes_stat(node.elseblock, out)
    elseif tag == "Ast.StatTry" then
        collect_writes_stat(node.block, out)
        collect_writes_stat(node.catchblock, out)
        collect_writes_stat(node.finallyblock, out)
    end
    return out
end

local function mark_spills(assigned, reads)
    for decl in pairs(assigned) do
        if reads[decl] then decl._needs_spill = true end
    end
end

local analyze_try_spills_block

function coder._analyze_try_spills_stat(stat, after)
    if not stat or stat == false then return end
    local tag = stat._tag
    if tag == "Ast.StatBlock" then
        analyze_try_spills_block(stat, after)
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
            or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
        local loop_after = set_copy(after)
        collect_reads_stat(stat, loop_after)
        coder._analyze_try_spills_stat(stat.block, loop_after)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(stat.thens) do
            coder._analyze_try_spills_stat(t.block, after)
        end
        coder._analyze_try_spills_stat(stat.elsestat, after)
    elseif tag == "Ast.StatCase" then
        for _, arm in ipairs(stat.arms) do
            coder._analyze_try_spills_stat(arm.block, after)
        end
        coder._analyze_try_spills_stat(stat.elseblock, after)
    elseif tag == "Ast.StatTry" then
        local catch_reads = collect_reads_stat(stat.catchblock)
        local finally_reads = collect_reads_stat(stat.finallyblock)

        -- A body error reaches code after the try only if a catch can handle
        -- it. A finally-only body error re-raises after the finally, so only
        -- the finally can observe body-written values on that longjmp path.
        local body_boundary_reads = set_copy(catch_reads)
        set_union(body_boundary_reads, finally_reads)
        if stat.catchblock then set_union(body_boundary_reads, after) end
        mark_spills(collect_writes_stat(stat.block), body_boundary_reads)

        -- The catch has a protected boundary only when a finally follows; if
        -- it raises, dispatch re-raises after the finally, so post-try code is
        -- not reached on that longjmp path.
        if stat.catchblock and stat.finallyblock then
            mark_spills(collect_writes_stat(stat.catchblock), finally_reads)
        end

        local nested_body_after = set_copy(after)
        set_union(nested_body_after, catch_reads)
        set_union(nested_body_after, finally_reads)
        coder._analyze_try_spills_stat(stat.block, nested_body_after)

        local nested_catch_after = set_copy(after)
        set_union(nested_catch_after, finally_reads)
        coder._analyze_try_spills_stat(stat.catchblock, nested_catch_after)
        coder._analyze_try_spills_stat(stat.finallyblock, after)
    end
end

analyze_try_spills_block = function(block, after_reads)
    if not block or not block.stats then
        coder._analyze_try_spills_stat(block, after_reads or {})
        return
    end
    local stats = {}
    for _, stat in ipairs(block.stats) do
        table.insert(stats, stat)
        if is_terminator(stat) then break end
    end
    local after = set_copy(after_reads or {})
    for i = #stats, 1, -1 do
        local stat = stats[i]
        coder._analyze_try_spills_stat(stat, after)

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
-- than a plain `StatReturn` (a `raise`, a proven infinite loop, or a
-- `StatTry`/`if` whose arms do not fall through) falls off the end of the
-- generated C even though Titan control never reaches there: the returns live
-- inside an inner C scope or after a `lua_error` (which Lua 5.5 declares
-- returning `int`, NOT `l_noret`), so the C compiler cannot always prove
-- no-fall-through and warns "control reaches end of non-void function". The
-- checker has already proven the function non-fallthrough, so emit an
-- unreachable trailing `return` of the zero value to satisfy the C control-flow
-- check (dead code; never executed). A function whose last reachable statement
-- IS a `StatReturn` needs nothing (the C return is right there).
local function unreachable_return(rettype, block)
    if not rettype or rettype._tag == "Type.Nil" then return nil end
    local last = last_reachable_stat(block)
    if last and last._tag == "Ast.StatReturn" then return nil end
    -- A braced initializer (`{ {0}, 0 }` for TValue-boxed types) is illegal in a
    -- bare `return`, so zero a temp first and return it.
    return render([[
        /* unreachable: no Titan path above falls through; this satisfies the C
         * control-flow check */
        {
            $DECL = $INIT;
            L->top.p = _base;
            return _ur;
        }]], {
            DECL = cvardecl(nil, rettype, "_ur"),
            INIT = initval(rettype),
        })
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
    -- An owned C value is represented by its owning full Udata, just like a
    -- Titan nominal value. Select this semantically: C declarator rendering
    -- spells the owner as `Udata *`, while the ordinary nominal ctype is
    -- `Udata*`, and ABI selection must not depend on whitespace.
    local resolved = types.resolve_c_typedef(elemtype)
    if resolved and resolved._tag == "Type.COwned" then
        return "TitanVargNominal"
    end
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
        table.insert(params, cpointertype(ftype.rettypes[i]))
    end
    -- A flexible result run is caller-owned typed storage. Keep this pair last
    -- so every fixed-only signature remains byte-for-byte unchanged.
    if ftype.flexrettype then
        table.insert(params,
            varg_struct_name(ftype.flexrettype) .. " *_flexout")
        table.insert(params, "int _flexwant")
    end
    local rettype = ftype.rettypes[1]
    -- A zero-return `() -> ()` function has a `void` native entry. Rendering
    -- the return type around the complete function declarator also handles a
    -- C function-pointer return without losing precedence.
    return cfunctiondecl(
        rettype, fname, table.concat(params, ", "), is_pointer)
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
        bound_stricts = tlcontext.bound_stricts,
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

function coder._aggregate_spill_copy(decl, to_spill)
    local spill = spill_cvar(decl)
    local cvar = assert(decl._cvar)
    local address = decl._c_backing_storage
        and decl._c_backing_storage.address or ("&(" .. cvar .. ")")
    local bytes = decl._c_backing_storage
        and decl._c_backing_storage.bytes or ("sizeof(" .. cvar .. ")")
    if to_spill then
        return render([[
            {
                for (size_t _spill_i = 0;
                     _spill_i < $BYTES; _spill_i++) {
                    $SPILL[_spill_i] =
                        ((const unsigned char *)$ADDRESS)[_spill_i];
                }
            }
        ]], {
            SPILL = spill,
            ADDRESS = address,
            BYTES = bytes,
        })
    end
    return render([[
        {
            for (size_t _spill_i = 0;
                 _spill_i < $BYTES; _spill_i++) {
                ((unsigned char *)$ADDRESS)[_spill_i] =
                    $SPILL[_spill_i];
            }
        }
    ]], {
        SPILL = spill,
        ADDRESS = address,
        BYTES = bytes,
    })
end

local function spill_decl_init(ctx, decl)
    if not decl_needs_spill(decl) then return "" end
    register_spill_decl(ctx, decl)
    if types.is_gc(decl._type) then
        -- GC values already have a Lua-stack slot. That slot is the stable
        -- storage; no separate C spill is needed.
        return ""
    end
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        local bytes = decl._c_backing_storage
            and decl._c_backing_storage.bytes
            or ("sizeof(" .. decl._cvar .. ")")
        return render([[
            unsigned char volatile $SPILL[$BYTES];
            $COPY
        ]], {
            SPILL = spill_cvar(decl),
            BYTES = bytes,
            COPY = coder._aggregate_spill_copy(decl, true),
        })
    end
    return render([[
        $CT volatile $SPILL = $CVAR;
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
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        local bytes = decl._c_backing_storage
            and decl._c_backing_storage.bytes
            or ("sizeof(" .. decl._cvar .. ")")
        return render([[
            unsigned char volatile $SPILL[$BYTES] = {0};
        ]], {
            SPILL = spill_cvar(decl),
            BYTES = bytes,
        })
    end
    return render([[
        $CT volatile $SPILL = $INIT;
    ]], {
        CT = ctype(decl._type),
        SPILL = spill_cvar(decl),
        INIT = initval(decl._type),
    })
end

local function spill_update(decl)
    if not decl_needs_spill(decl) or types.is_gc(decl._type) then return "" end
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        return coder._aggregate_spill_copy(decl, true)
    end
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
                if types.is_c_aggregate(decl._type)
                   or decl._c_backing_storage then
                    table.insert(lines,
                        coder._aggregate_spill_copy(decl, false))
                else
                    table.insert(lines, render("$CVAR = $SPILL;", {
                        CVAR = decl._cvar,
                        SPILL = decl._spill_cvar,
                    }))
                end
            end
        end
    end
    if #lines == 0 then return "" end
    return "/* reload setjmp-sensitive Titan locals/params */\n"
        .. table.concat(lines, "\n")
end

local function newtmp(ctx --[[:table]], typ --[[:table]], isgc --[[:boolean]],
                      initializer --[[:string?]])
    -- Module-level Lua entry wrappers share the translation-unit context but
    -- may be emitted before any native body has needed a temporary. Treat that
    -- as the first allocation just like `fresh_lowering_name`; GC-bearing
    -- temporaries still require an ordinary function context with stack slots.
    local tmp = ctx.tmp or 1
    ctx.tmp = tmp + 1
    local tmpname = "_tmp_" .. tmp
    -- A temporary freezes an expression value, so a C array/function uses its
    -- adjusted pointer representation. Direct array declarators are reserved
    -- for actual object storage (locals/fields), never assignment-based temps.
    local tmptype = (types.is_direct_c(typ) and
        cdeclarator.adjust_parameter_type(typ)) or typ
    if isgc then
        local slot = newslot(ctx)
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, tmptype, tmpname),
            INIT = initializer or initval(typ)
        }), tmpname, slot
    else
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, tmptype, tmpname),
            INIT = initializer or initval(typ)
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

-- Freeze an already generated value in a C temporary for lexical evaluation
-- order without publishing a tracing root. Native calls transport arguments in
-- C formals, not Lua-stack slots. The expression's ordinary allocation/result
-- publication and traced program homes retain ownership; any fresh allocation
-- performed while evaluating it establishes its own root immediately.
function coder._freeze_code(ctx, typ, stats, exp)
    local decl, name = newtmp(ctx, typ, false)
    return render([[
        $STATS
        $DECL
        $NAME = $EXP;
    ]], {
        STATS = stats,
        DECL = decl,
        NAME = name,
        EXP = exp,
    }), name
end

function coder._freeze(ctx, node)
    local stats, exp = codeexp(ctx, node)
    return coder._freeze_code(ctx, node._type, stats, exp)
end

function coder._nominal_owner_module_expr(ctx, fqtn)
    assert(type(fqtn) == "string",
        "nominal owner descriptor has no qualified name")
    local module = assert(fqtn:match("^(.*)%.[^.]+$"),
        "nominal owner is not module-qualified: " .. fqtn)
    if module == ctx.module then return "_mod" end
    if not ctx.modules[module] then
        ctx.modules[module] = nextupvalue(ctx.tlcontext)
    end
    return render("uvalue(&_mod->uv[$INDEX].uv)", {
        INDEX = c_integer_literal(ctx.modules[module]),
    })
end

function coder._interface_owner_module_expr(ctx, owner)
    assert(owner and type(owner.name) == "string",
        "Interface concrete/owner descriptor has no qualified name")
    return coder._nominal_owner_module_expr(ctx, owner.name)
end

function coder._interface_closed_record(value, allowed, use)
    assert(type(value) == "table", use .. " is not a table")
    for key in pairs(value) do
        assert(allowed[key] == true,
            use .. " has unknown field " .. tostring(key))
    end
end

function coder._interface_dense_list(value, use)
    assert(type(value) == "table", use .. " is not a list")
    local count = #value
    for key in pairs(value) do
        assert(type(key) == "number"
               and key >= 1 and key <= count
               and key == math.floor(key),
            use .. " is not a closed dense list")
    end
    return count
end

function coder._interface_frozen_value_equal(actual, expected)
    if type(actual) ~= type(expected) then return false end
    if type(expected) ~= "table" then return actual == expected end
    if expected._tag and expected._tag:match("^Type%.") then
        return actual._tag ~= nil and types.equals(actual, expected)
    end
    for key, value in pairs(expected) do
        if not coder._interface_frozen_value_equal(actual[key], value) then
            return false
        end
    end
    for key in pairs(actual) do
        if expected[key] == nil then return false end
    end
    return true
end

function coder._interface_adapter_is_gc(typ)
    if typ == false or typ == nil then return false end
    local normalized = types.normalize(typ)
    return normalized ~= nil and types.is_gc(normalized) or false
end

function coder._interface_injection_may_relocate(typ)
    typ = types.normalize(typ)
    if not typ then return false end
    if typ._tag == "Type.Array" then return true end
    if typ._tag == "Type.Option" then
        return coder._interface_injection_may_relocate(typ.base)
    end
    return false
end

function coder._validate_interface_frozen_guard(
        guard, target, use, seen)
    target = assert(types.normalize(target),
        use .. " has an unnormalizable target")
    coder._interface_closed_record(guard, {
        kind = true, op = true, target = true,
        element = true, key = true, value = true,
        inner = true, name = true,
    }, use)
    assert(guard.kind == "gradual_guard"
           and guard.target
           and types.equals(guard.target, target),
        use .. " has a mismatched target")

    seen = seen or {}
    assert(not seen[guard], use .. " contains a recursive guard cycle")
    seen[guard] = true
    local tag = target._tag
    if tag == "Type.Array" then
        assert(guard.op == "array"
               and guard.element
               and guard.key == nil and guard.value == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed Array guard")
        coder._validate_interface_frozen_guard(
            guard.element, target.elem, use .. " Array element", seen)
    elseif tag == "Type.Map" then
        assert(guard.op == "map"
               and guard.key and guard.value
               and guard.element == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed Map guard")
        coder._validate_interface_frozen_guard(
            guard.key, target.keys, use .. " Map key", seen)
        coder._validate_interface_frozen_guard(
            guard.value, target.values, use .. " Map value", seen)
    elseif tag == "Type.Option" then
        assert(guard.op == "option"
               and guard.inner
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.name == nil,
            use .. " has a malformed Option guard")
        coder._validate_interface_frozen_guard(
            guard.inner, target.base, use .. " Option value", seen)
    elseif tag == "Type.Nominal"
           or tag == "Type.Record"
           or tag == "Type.Union" then
        local name = target.fqtn or target.name
        assert(guard.op == "nominal" and guard.name == name
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.inner == nil,
            use .. " has a malformed nominal guard")
    else
        local expected = types.is_c_tvalue(target)
            and "c_tvalue" or coder._gradual_op_for_tag[tag]
        assert(expected and guard.op == expected
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed leaf guard")
    end
    seen[guard] = nil
end

function coder._validate_interface_adapter_operation(
        operation, declared_source, declared_target, use, seen)
    coder._interface_closed_record(operation, {
        kind = true, mode = true,
        source = true, target = true,
        declared_source = true, declared_target = true,
        timing = true, may_raise = true, may_relocate = true,
        guard = true, callable = true, adapter = true,
    }, use)
    local source = assert(types.normalize(declared_source),
        use .. " has an unnormalizable declared source")
    local target = assert(types.normalize(declared_target),
        use .. " has an unnormalizable declared target")
    assert(operation.source and operation.target
           and operation.declared_source
           and operation.declared_target
           and types.equals(operation.source, source)
           and types.equals(operation.target, target)
           and types.equals(
               types.normalize(operation.declared_source), source)
           and types.equals(
               types.normalize(operation.declared_target), target),
        use .. " changes its frozen endpoints")

    if operation.kind == "identity" then
        assert(types.equals(source, target)
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == false
               and operation.may_relocate == false
               and operation.guard == nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed identity operation")
    elseif operation.kind == "gradual_inject" then
        local relocates =
            coder._interface_injection_may_relocate(source)
        assert(target._tag == "Type.Value"
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == relocates
               and operation.may_relocate == relocates
               and operation.guard == nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed gradual injection")
    elseif operation.kind == "gradual_guard" then
        local delayed = operation.mode == "structural"
            and target._tag ~= "Type.Option"
        assert((operation.mode == "project"
                or operation.mode == "structural")
               and operation.timing == (delayed
                    and "delayed_observation" or "immediate")
               and operation.may_raise == not delayed
               and operation.may_relocate == not delayed
               and operation.guard ~= nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed gradual guard")
        coder._validate_interface_frozen_guard(
            operation.guard, target, use .. " guard", {})
        -- Keep the central strict helper's closed low-level representation
        -- check as a second assertion, without asking any type relation.
        coder._checked_gradual_guard(
            operation.guard, target, use .. " guard")
    elseif operation.kind == "callable_view" then
        assert(source._tag == "Type.Function"
               and target._tag == "Type.Function"
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == true
               and operation.may_relocate == false
               and operation.guard == nil
               and operation.adapter ~= nil
               and operation.callable == operation.adapter.callable,
            use .. " has a malformed callable view")
        coder._validate_callable_adapter_plan(
            operation.adapter, source, target,
            use .. " callable view", seen)
    else
        error(use .. " has unknown operation "
            .. tostring(operation.kind))
    end
    return operation
end

function coder._validate_interface_adapter_action(
        action, expected, operation_source, operation_target, use, seen)
    assert(type(action) == "table", use .. " is not a table")
    local allowed = {}
    for key in pairs(expected) do allowed[key] = true end
    local has_operation = operation_source ~= nil
    if has_operation then allowed.operation = true end
    coder._interface_closed_record(action, allowed, use)
    if has_operation then
        assert(action.operation ~= nil,
            use .. " lacks its frozen component operation")
        coder._validate_interface_adapter_operation(
            action.operation, operation_source, operation_target,
            use .. " operation", seen)
        expected.rebase_after = action.operation.may_relocate
    end
    for key, value in pairs(expected) do
        assert(coder._interface_frozen_value_equal(action[key], value),
            use .. " has a mismatched " .. tostring(key))
    end
    if has_operation then
        assert(action.rebase_after
               == action.operation.may_relocate,
            use .. " has a mismatched rebase marker")
    else
        assert(action.operation == nil
               and action.rebase_after == false,
            use .. " has an unexpected component operation")
    end
end

function coder._interface_expected_action(
        kind, order, phase, source_type, target_type, extra)
    local expected = {
        kind = kind,
        order = order,
        id = phase .. ":" .. tostring(order),
        phase = phase,
        source_type = source_type,
        target_type = target_type,
        source_gc =
            coder._interface_adapter_is_gc(source_type),
        destination_gc =
            coder._interface_adapter_is_gc(target_type),
        rebase_after = false,
    }
    for key, value in pairs(extra or {}) do expected[key] = value end
    return expected
end

function coder._validate_interface_callable_actions(
        callable, source, target, use, seen)
    coder._interface_closed_record(callable, {
        kind = true, source = true, target = true,
        exact = true, arguments = true, results = true,
    }, use)
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function"
           and callable.kind == "interface_callable_actions"
           and callable.source and callable.target
           and types.equals(callable.source, source)
           and types.equals(callable.target, target)
           and callable.exact == types.equals(source, target),
        use .. " has mismatched callable signatures")
    coder._interface_dense_list(
        callable.arguments, use .. " arguments")
    coder._interface_dense_list(
        callable.results, use .. " results")

    seen = seen or {}
    assert(not seen[callable],
        use .. " contains a recursive callable cycle")
    seen[callable] = true

    local ai = 0
    local function argument(kind, source_type, target_type, extra,
            operation_source, operation_target)
        ai = ai + 1
        local expected = coder._interface_expected_action(
            kind, ai, "argument", source_type, target_type, extra)
        coder._validate_interface_adapter_action(
            callable.arguments[ai], expected,
            operation_source, operation_target,
            use .. " argument " .. tostring(ai), seen)
    end

    local shared = math.min(#source.params, #target.params)
    for index = 1, shared do
        argument("argument",
            target.params[index], source.params[index], {
                expected_index = index,
                actual_index = index,
                source_kind = "interface_fixed",
                destination_kind = "concrete_fixed",
            }, target.params[index], source.params[index])
    end
    for index = #target.params + 1, #source.params do
        if target.varargtype then
            argument("tail_or_nil_to_argument",
                target.varargtype, source.params[index], {
                    actual_index = index,
                    expected_tail_offset =
                        index - #target.params,
                    source_kind = "interface_tail",
                    source_open = true,
                    destination_kind = "concrete_fixed",
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                    present_arm = "operation",
                }, target.varargtype, source.params[index])
        else
            argument("nil_fill",
                types.Nil(), source.params[index], {
                    actual_index = index,
                    source_kind = "constant_nil",
                    destination_kind = "concrete_fixed",
                    admissible = true,
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                })
        end
    end
    for index = #source.params + 1, #target.params do
        if source.varargtype then
            argument("argument_to_tail",
                target.params[index], source.varargtype, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "concrete_tail",
                    destination_open = true,
                }, target.params[index], source.varargtype)
        else
            argument("ignore_argument",
                target.params[index], false, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "discard",
                    destination_gc = false,
                    effect = "evaluate_and_discard",
                })
        end
    end
    if source.varargtype and target.varargtype then
        argument("tail_to_tail",
            target.varargtype, source.varargtype, {
                expected_tail_consumed =
                    math.max(0, #source.params - #target.params),
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "concrete_tail",
                destination_open = true,
            }, target.varargtype, source.varargtype)
    elseif source.varargtype then
        argument("empty_tail", false, source.varargtype, {
            source_kind = "empty",
            destination_kind = "concrete_tail",
            source_gc = false,
            destination_open = true,
            count = 0,
        })
    elseif target.varargtype then
        argument("ignore_tail", target.varargtype, false, {
            expected_tail_consumed =
                math.max(0, #source.params - #target.params),
            source_kind = "interface_tail",
            source_open = true,
            destination_kind = "discard",
            destination_gc = false,
            effect = "evaluate_run_and_discard",
        })
    end
    assert(ai == #callable.arguments,
        use .. " has extra argument actions")

    local ri = 0
    local function result(kind, source_type, target_type, extra,
            operation_source, operation_target)
        ri = ri + 1
        local expected = coder._interface_expected_action(
            kind, ri, "result", source_type, target_type, extra)
        coder._validate_interface_adapter_action(
            callable.results[ri], expected,
            operation_source, operation_target,
            use .. " result " .. tostring(ri), seen)
    end

    for index, expected_type in ipairs(target.rettypes) do
        local actual_type = source.rettypes[index]
        if actual_type then
            result("result", actual_type, expected_type, {
                actual_index = index,
                expected_index = index,
                source_kind = "concrete_fixed",
                destination_kind = "interface_fixed",
            }, actual_type, expected_type)
        elseif source.flexrettype then
            local optional = expected_type._tag == "Type.Option"
            local wraps =
                callable.results[ri + 1].wrap_present == true
            local operation_target =
                wraps and expected_type.base or expected_type
            result(optional and "flex_to_optional_result"
                    or "flex_to_result",
                source.flexrettype, expected_type, {
                    expected_index = index,
                    actual_flex_offset =
                        index - #source.rettypes,
                    source_kind = "concrete_flex",
                    source_open = true,
                    destination_kind = "interface_fixed",
                    operation_target_type = operation_target,
                    missing_arm = {
                        kind = optional and "nil_fill"
                            or "raise_missing_result",
                        target_type = expected_type,
                    },
                    present_arm = {
                        kind = "operation",
                        wrap_present = wraps,
                        target_type = operation_target,
                    },
                    wrap_present = wraps,
                }, source.flexrettype, operation_target)
            assert(optional
                   or callable.results[ri].wrap_present == false,
                use .. " has Option wrapping on a non-Option result")
        else
            result("nil_fill_result", types.Nil(), expected_type, {
                expected_index = index,
                expected_type = expected_type,
                source_kind = "constant_nil",
                destination_kind = "interface_fixed",
                admissible = true,
                effect = "synthesize_nil",
                missing_arm = {
                    kind = "nil_fill",
                    admissible = true,
                    target_type = expected_type,
                },
            })
        end
    end
    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            result("result_to_flex",
                source.rettypes[index], target.flexrettype, {
                    actual_index = index,
                    expected_flex_offset =
                        index - #target.rettypes,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_flex",
                    destination_open = true,
                }, source.rettypes[index], target.flexrettype)
        else
            result("hide_result", source.rettypes[index], false, {
                actual_index = index,
                source_kind = "concrete_fixed",
                destination_kind = "discard",
                destination_gc = false,
                effect = "discard",
            })
        end
    end
    if source.flexrettype and target.flexrettype then
        result("flex_to_flex",
            source.flexrettype, target.flexrettype, {
                actual_flex_consumed =
                    math.max(0,
                        #target.rettypes - #source.rettypes),
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "interface_flex",
                destination_open = true,
            }, source.flexrettype, target.flexrettype)
    elseif source.flexrettype then
        result("hide_flex", source.flexrettype, false, {
            actual_flex_consumed =
                math.max(0,
                    #target.rettypes - #source.rettypes),
            source_kind = "concrete_flex",
            source_open = true,
            destination_kind = "discard",
            destination_gc = false,
            effect = "discard_run",
        })
    elseif target.flexrettype then
        result("end_flex", false, target.flexrettype, {
            source_kind = "empty",
            destination_kind = "interface_flex",
            source_gc = false,
            destination_open = true,
            count = 0,
        })
    end
    assert(ri == #callable.results,
        use .. " has extra result actions")
    seen[callable] = nil
end

function coder._validate_callable_strict_slot(
        slot, typ, index, use)
    coder._interface_closed_record(slot, {
        index = true, type = true, guard = true,
    }, use)
    local normalized = assert(types.normalize(typ),
        use .. " has an unnormalizable boundary type")
    assert(slot.index == index
           and slot.type
           and types.equals(slot.type, normalized)
           and slot.guard ~= nil,
        use .. " has a mismatched boundary slot")
    if slot.guard ~= false then
        coder._validate_interface_frozen_guard(
            slot.guard, normalized, use .. " guard", {})
        coder._checked_gradual_guard(
            slot.guard, normalized, use .. " guard")
    end
end

function coder._validate_callable_strict_relay(relay, target, use)
    coder._interface_closed_record(relay, {
        kind = true, parameters = true, vararg = true,
        results = true, flexible_result = true,
    }, use)
    assert(relay.kind == "callable_strict_relay",
        use .. " has an unknown relay kind")
    assert(coder._interface_dense_list(
        relay.parameters, use .. " parameters") == #target.params,
        use .. " has a mismatched parameter count")
    for index, typ in ipairs(target.params) do
        coder._validate_callable_strict_slot(
            relay.parameters[index], typ, index,
            use .. " parameter " .. tostring(index))
    end
    if target.varargtype then
        assert(type(relay.vararg) == "table",
            use .. " lacks its variadic boundary")
        coder._validate_callable_strict_slot(
            relay.vararg, target.varargtype, "vararg",
            use .. " variadic boundary")
    else
        assert(relay.vararg == false,
            use .. " has an unexpected variadic boundary")
    end
    assert(coder._interface_dense_list(
        relay.results, use .. " results") == #target.rettypes,
        use .. " has a mismatched result count")
    for index, typ in ipairs(target.rettypes) do
        coder._validate_callable_strict_slot(
            relay.results[index], typ, index,
            use .. " result " .. tostring(index))
    end
    if target.flexrettype then
        assert(type(relay.flexible_result) == "table",
            use .. " lacks its flexible-result boundary")
        coder._validate_callable_strict_slot(
            relay.flexible_result, target.flexrettype,
            "flexible_result", use .. " flexible-result boundary")
    else
        assert(relay.flexible_result == false,
            use .. " has an unexpected flexible-result boundary")
    end
end

function coder._validate_callable_adapter_demand(
        demand, source, target, use)
    coder._interface_closed_record(demand, {
        kind = true, abi_cap = true,
        source_has_flex = true, target_has_flex = true,
        fixed_source_flex_consumed = true,
        fixed_source_surplus = true,
        remaining_source_capacity = true,
        within_abi_cap = true, mode = true,
        target_demand_parameter = true,
        unlimited_demand = true,
    }, use)
    local consumed = math.max(
        0, #target.rettypes - #source.rettypes)
    local surplus = math.max(
        0, #source.rettypes - #target.rettypes)
    local source_has_flex = source.flexrettype ~= nil
        and source.flexrettype ~= false
    local target_has_flex = target.flexrettype ~= nil
        and target.flexrettype ~= false
    local expected = {
        kind = "callable_flexible_result_demand",
        abi_cap = 200,
        source_has_flex = source_has_flex,
        target_has_flex = target_has_flex,
        fixed_source_flex_consumed = consumed,
        fixed_source_surplus = surplus,
        remaining_source_capacity = 200 - consumed,
        within_abi_cap = consumed <= 200,
        mode = not source_has_flex and "none"
            or (target_has_flex and "forward_target_demand"
                or "fixed_prefix"),
        target_demand_parameter = target_has_flex
            and "_flexwant" or false,
        unlimited_demand = target_has_flex
            and "LUA_MULTRET" or false,
    }
    assert(coder._interface_frozen_value_equal(demand, expected),
        use .. " is not canonical")
end

function coder._callable_action_rebase_reason(action)
    assert(action.operation
            and action.operation.timing == "immediate"
            and action.operation.may_relocate == true
            and action.operation.kind ~= "callable_view",
        "callable adapter has a rebase for a non-relocating action")
    return "immediate_gradual_guard"
end

function coder._validate_callable_adapter_rebases(adapter, use)
    coder._interface_dense_list(
        adapter.rebase_points, use .. " rebase points")
    local expected = {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    expected[#expected + 1] = {
        kind = "after_native_call",
        backend = "immediate_source_closure",
        reason = "source_call_may_relocate_stack",
    }
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    for index, point in ipairs(adapter.rebase_points) do
        local wanted = expected[index]
        assert(wanted, use .. " has an extra rebase point")
        local allowed
        if point.kind == "after_action" then
            allowed = { kind = true, action = true, reason = true }
        elseif point.kind == "after_native_call" then
            allowed = { kind = true, backend = true, reason = true }
        else
            allowed = { kind = true, reason = true }
        end
        coder._interface_closed_record(
            point, allowed,
            use .. " rebase point " .. tostring(index))
        assert(coder._interface_frozen_value_equal(point, wanted),
            use .. " has a mismatched rebase point " .. tostring(index))
    end
    assert(#adapter.rebase_points == #expected,
        use .. " is missing a rebase point")
end

function coder._validate_callable_adapter_plan(
        adapter, source_type, target_type, use, seen)
    use = use or "callable adapter"
    coder._interface_closed_record(adapter, {
        kind = true, source = true, target = true, exact = true,
        location = true, trace_name = true,
        callable = true, arguments = true, results = true,
        dense = true, strict_relay = true, rooting = true,
        rebase_points = true, flexible_result_demand = true,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }, use)
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function"
           and adapter.kind == "callable_adapter_plan"
           and adapter.source and adapter.target
           and types.equals(adapter.source, source)
           and types.equals(adapter.target, target)
           and adapter.exact == types.equals(source, target)
           and adapter.arguments == adapter.callable.arguments
           and adapter.results == adapter.callable.results
           and adapter.relation_free == true
           and adapter.no_nested_interface_conversions == true
           and adapter.uses_base_off == true,
        use .. " has mismatched identity/signatures")

    seen = seen or {}
    assert(not seen[adapter],
        use .. " contains a recursive adapter cycle")
    seen[adapter] = true

    coder._interface_closed_record(adapter.location, {
        filename = true, line = true, col = true,
    }, use .. " location")
    local loc = adapter.location
    assert(type(loc.filename) == "string"
           and type(loc.line) == "number" and loc.line >= 1
           and loc.line == math.floor(loc.line)
           and type(loc.col) == "number" and loc.col >= 1
           and loc.col == math.floor(loc.col),
        use .. " lacks a real source location")
    local expected_trace = string.format(
        "[callable adapter %s -> %s at %s:%d:%d]",
        types.tostring(source), types.tostring(target),
        loc.filename, loc.line, loc.col)
    assert(adapter.trace_name == expected_trace,
        use .. " has a mismatched trace name")

    coder._validate_interface_callable_actions(
        adapter.callable, source, target,
        use .. " callable actions", seen)
    coder._interface_closed_record(adapter.dense, {
        argument_count = true, result_count = true,
    }, use .. " dense inventory")
    assert(adapter.dense.argument_count == #adapter.arguments
           and adapter.dense.result_count == #adapter.results,
        use .. " has a mismatched dense inventory")
    coder._validate_callable_strict_relay(
        adapter.strict_relay, target, use .. " strict relay")
    coder._validate_callable_adapter_rooting(adapter, use)
    coder._validate_callable_adapter_rebases(adapter, use)
    coder._validate_callable_adapter_demand(
        adapter.flexible_result_demand, source, target,
        use .. " flexible-result demand")

    seen[adapter] = nil
    return adapter
end

function coder._adapter_operation_allocates(action)
    return action.operation ~= nil
        and action.operation.kind == "callable_view"
end

function coder._adapter_has_open_source(actions)
    for _, action in ipairs(actions) do
        if action.operation and action.source_open then return true end
    end
    return false
end

function coder._adapter_has_open_allocating_destination(actions)
    for _, action in ipairs(actions) do
        if coder._adapter_operation_allocates(action)
           and action.destination_open then
            return true
        end
    end
    return false
end

function coder._adapter_actions_allocate(adapter)
    for _, actions in ipairs({ adapter.arguments, adapter.results }) do
        for _, action in ipairs(actions) do
            if coder._adapter_operation_allocates(action) then return true end
        end
    end
    return false
end

function coder._validate_interface_adapter_fixed_roots(
        roots, actions, policy, use, retain_until)
    coder._interface_dense_list(roots, use)
    local expected = {}
    for _, action in ipairs(actions) do
        local include
        local typ
        if policy == "none" then
            include = false
        elseif policy == "allocation_destination" then
            include = coder._adapter_operation_allocates(action)
                and action.destination_gc
                and not action.destination_open
            typ = action.target_type
        elseif policy == "result_source" then
            include = action.operation ~= nil
                and action.source_gc
                and not action.source_open
            typ = action.source_type
        else
            error(use .. " has unknown fixed-root policy " .. tostring(policy))
        end
        if include then
            expected[#expected + 1] = {
                action = action.id,
                type = typ,
                storage = "lua_stack_slot",
                retain_until = retain_until,
            }
        end
    end
    assert(coder._interface_frozen_value_equal(roots, expected),
        use .. " does not match its action inventory")
end

function coder._validate_interface_adapter_range(
        range, id, phase, side, element_type, lifetime, traced, use)
    local present = element_type ~= nil
        and element_type ~= false
    local gc_bearing = present
        and coder._interface_adapter_is_gc(element_type) or false
    traced = gc_bearing and traced == true
    local expected = {
        kind = "open_root_range",
        id = id,
        phase = phase,
        side = side,
        present = present,
        element_type = element_type or false,
        gc_bearing = gc_bearing,
        traced = traced,
        storage = traced and "parallel_lua_stack_range" or false,
        dynamic_start = present and "run_start" or false,
        dynamic_count = present and "run_count" or false,
        retain_until = lifetime,
        raw_storage_is_root = false,
    }
    coder._interface_closed_record(range, {
        kind = true, id = true, phase = true, side = true,
        present = true, element_type = true,
        gc_bearing = true, traced = true, storage = true,
        dynamic_start = true, dynamic_count = true,
        retain_until = true, raw_storage_is_root = true,
    }, use)
    assert(coder._interface_frozen_value_equal(range, expected),
        use .. " is not canonical")
end

function coder._validate_adapter_rooting(
        adapter, source, target, lifetimes, construction, use)
    local rooting = adapter.rooting
    local allowed = {
        raw_descriptors_are_roots = true,
        raw_buffers_are_roots = true,
        fixed = true, ranges = true,
    }
    if construction then allowed.construction = true end
    coder._interface_closed_record(rooting, allowed, use .. " rooting")
    assert(rooting.raw_descriptors_are_roots == false
           and rooting.raw_buffers_are_roots == false,
        use .. " treats raw adapter storage as a root")

    if construction then
        coder._interface_closed_record(rooting.construction, {
            result = true,
        }, use .. " construction roots")
        local expected = {
            type = target,
            gc_bearing = true,
            traced = true,
            storage = "conditional_lua_stack_slot",
            condition = "eligible_exact_titan_clone",
            retain_until = lifetimes.result_destination,
        }
        coder._interface_closed_record(rooting.construction.result, {
            type = true, gc_bearing = true, traced = true,
            storage = true, condition = true, retain_until = true,
        }, use .. " construction result root")
        assert(coder._interface_frozen_value_equal(
                rooting.construction.result, expected),
            use .. " has a mismatched construction result root")
    end

    coder._interface_closed_record(rooting.fixed, {
        argument_source = true,
        argument_destination = true,
        result_source = true,
        result_destination = true,
    }, use .. " fixed roots")
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.argument_source, adapter.arguments,
        "none", use .. " argument source roots",
        lifetimes.argument_source)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.argument_destination, adapter.arguments,
        "allocation_destination", use .. " argument destination roots",
        lifetimes.argument_destination)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.result_source, adapter.results,
        "result_source", use .. " result source roots",
        lifetimes.result_source)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.result_destination, adapter.results,
        "allocation_destination", use .. " result destination roots",
        lifetimes.result_destination)

    coder._interface_closed_record(rooting.ranges, {
        argument_source = true,
        argument_destination = true,
        result_source = true,
        result_destination = true,
    }, use .. " root ranges")
    coder._validate_interface_adapter_range(
        rooting.ranges.argument_source,
        "argument_source", "argument", "source",
        target.varargtype, lifetimes.argument_source,
        false, use .. " argument source range")
    coder._validate_interface_adapter_range(
        rooting.ranges.argument_destination,
        "argument_destination", "argument", "destination",
        source.varargtype, lifetimes.argument_destination,
        coder._adapter_has_open_allocating_destination(adapter.arguments),
        use .. " argument destination range")
    coder._validate_interface_adapter_range(
        rooting.ranges.result_source,
        "result_source", "result", "source",
        source.flexrettype, lifetimes.result_source,
        coder._adapter_has_open_source(adapter.results),
        use .. " result source range")
    coder._validate_interface_adapter_range(
        rooting.ranges.result_destination,
        "result_destination", "result", "destination",
        target.flexrettype, lifetimes.result_destination,
        coder._adapter_has_open_allocating_destination(adapter.results),
        use .. " result destination range")
end

function coder._validate_callable_adapter_rooting(adapter, use)
    coder._validate_adapter_rooting(
        adapter, adapter.source, adapter.target, {
            argument_source = "all_arguments_converted",
            argument_destination = "source_native_call_returns",
            result_source = "all_results_converted",
            result_destination = "target_caller_handoff",
        }, true, use)
end

function coder._validate_interface_adapter_rooting(adapter, use)
    coder._validate_adapter_rooting(
        adapter, adapter.concrete_signature, adapter.interface_signature, {
            argument_source = "all_arguments_converted",
            argument_destination = "concrete_call_returns",
            result_source = "all_results_converted",
            result_destination = "interface_caller_handoff",
        }, false, use)
end
function coder._validate_interface_adapter_rebases(adapter, use)
    coder._interface_dense_list(
        adapter.rebase_points, use .. " rebase points")
    local expected = {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    expected[#expected + 1] = {
        kind = "after_native_call",
        method = adapter.concrete_method,
        reason = "concrete_call_may_relocate_stack",
    }
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    for index, point in ipairs(adapter.rebase_points) do
        local wanted = expected[index]
        assert(wanted, use .. " has an extra rebase point")
        coder._interface_closed_record(point,
            point.kind == "after_action"
                and { kind = true, action = true, reason = true }
                or { kind = true, method = true, reason = true },
            use .. " rebase point " .. tostring(index))
        assert(coder._interface_frozen_value_equal(point, wanted),
            use .. " has a mismatched rebase point "
                .. tostring(index))
    end
    assert(#adapter.rebase_points == #expected,
        use .. " is missing a rebase point")
end

function coder._validate_interface_adapter(
        adapter, concrete, interface, mapping, use)
    coder._interface_closed_record(adapter, {
        kind = true, slot = true, slot_kind = true,
        name = true, symbol_key = true, trace_name = true,
        concrete_owner = true, concrete_owner_module = true,
        concrete_method = true, concrete_signature = true,
        interface = true, interface_method = true,
        native_signature = true, interface_signature = true,
        hidden_operands = true,
        arguments = true, results = true, callable = true,
        callable_adapter = true, relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true, rooting = true,
        rebase_points = true,
    }, use)
    local owner_module = assert(
        concrete.name:match("^(.*)%.[^.]+$"),
        use .. " concrete owner is not module-qualified")
    assert(adapter.kind == "interface_method_adapter"
           and adapter.slot == mapping.index
           and adapter.slot_kind == "adapter"
           and adapter.name == mapping.name
           and adapter.symbol_key == string.format(
               "%s->%s#%d:%s", concrete.name, interface.name,
               mapping.index, mapping.name)
           and adapter.trace_name == string.format(
               "%s:%s [adapter for %s:%s]",
               interface.name, mapping.name,
               concrete.name, mapping.name)
           and adapter.concrete_owner == concrete
           and adapter.concrete_owner_module == owner_module
           and adapter.concrete_method == mapping.concrete
           and adapter.concrete_signature == mapping.source
           and adapter.interface == interface
           and adapter.interface_method == mapping.required
           and adapter.native_signature == mapping.required
           and adapter.interface_signature == mapping.target
           and adapter.arguments == adapter.callable.arguments
           and adapter.results == adapter.callable.results
           and adapter.callable_adapter
           and adapter.callable == adapter.callable_adapter.callable
           and adapter.callable_adapter
                == mapping.adjustment._callable_adapter
           and adapter.relation_free == true
           and adapter.no_nested_interface_conversions == true
           and adapter.uses_base_off == true,
        use .. " has mismatched adapter identity/signatures")

    coder._interface_closed_record(adapter.hidden_operands, {
        concrete_owner_module = true,
        closure = true, self = true,
    }, use .. " hidden operands")
    local module_operand =
        adapter.hidden_operands.concrete_owner_module
    coder._interface_closed_record(module_operand, {
        parameter = true, provenance = true,
        owner = true, module = true,
        forwards_unchanged = true,
        emitter_module_is_forbidden = true,
    }, use .. " concrete module operand")
    assert(module_operand.parameter == "_mod"
           and module_operand.provenance
               == "interface_wrapper_uservalue_0"
           and module_operand.owner == concrete
           and module_operand.module == owner_module
           and module_operand.forwards_unchanged == true
           and module_operand.emitter_module_is_forbidden == true,
        use .. " changes concrete-owner module provenance")
    local closure_operand = adapter.hidden_operands.closure
    coder._interface_closed_record(closure_operand, {
        parameter = true, adapter_value = true,
        concrete_call_value = true,
    }, use .. " closure operand")
    assert(closure_operand.parameter == "_fn"
           and closure_operand.adapter_value == "NULL"
           and closure_operand.concrete_call_value == "NULL",
        use .. " does not freeze NULL payload closures")
    local self_operand = adapter.hidden_operands.self
    coder._interface_closed_record(self_operand, {
        provenance = true, type = true,
        forwards_unchanged = true,
    }, use .. " self operand")
    assert(self_operand.provenance
               == "interface_wrapper_uservalue_1"
           and self_operand.type
           and types.equals(
               self_operand.type, types.Nominal(concrete.name))
           and self_operand.forwards_unchanged == true,
        use .. " changes concrete self provenance")

    coder._validate_callable_adapter_plan(
        adapter.callable_adapter, mapping.source, mapping.target,
        use .. " shared callable adapter", {})
    coder._validate_interface_callable_actions(
        adapter.callable, mapping.source, mapping.target,
        use .. " callable", {})
    coder._validate_interface_adapter_rooting(adapter, use)
    coder._validate_interface_adapter_rebases(adapter, use)
    return adapter
end

function coder._interface_adapter_signature(name, method, is_pointer)
    assert(method._tag == "Type.Method")
    local params = {
        "lua_State *L",
        "Udata *_mod",
        "CClosure *_fn",
        "Udata *_self",
    }
    for index, typ in ipairs(method.params) do
        params[#params + 1] =
            cvardecl(nil, typ, "_ia_param_" .. tostring(index))
    end
    if method.varargtype then
        params[#params + 1] =
            varg_struct_name(method.varargtype) .. " *_varargs"
        params[#params + 1] = "int _start"
    end
    for index = 2, #method.rettypes do
        params[#params + 1] = cpointertype(method.rettypes[index])
            .. " _ia_out_" .. tostring(index)
    end
    if method.flexrettype then
        params[#params + 1] =
            varg_struct_name(method.flexrettype) .. " *_flexout"
        params[#params + 1] = "int _flexwant"
    end
    return cfunctiondecl(
        method.rettypes[1], name,
        table.concat(params, ", "), is_pointer)
end

function coder._callable_adapter_signature(name, typ, is_pointer)
    assert(typ._tag == "Type.Function")
    local params = {
        "lua_State *L",
        "Udata *_mod",
        "CClosure *_fn",
    }
    for index, param in ipairs(typ.params) do
        params[#params + 1] =
            cvardecl(nil, param, "_ia_param_" .. tostring(index))
    end
    if typ.varargtype then
        params[#params + 1] =
            varg_struct_name(typ.varargtype) .. " *_varargs"
        params[#params + 1] = "int _start"
    end
    for index = 2, #typ.rettypes do
        params[#params + 1] = cpointertype(typ.rettypes[index])
            .. " _ia_out_" .. tostring(index)
    end
    if typ.flexrettype then
        params[#params + 1] =
            varg_struct_name(typ.flexrettype) .. " *_flexout"
        params[#params + 1] = "int _flexwant"
    end
    return cfunctiondecl(
        typ.rettypes[1], name,
        table.concat(params, ", "), is_pointer)
end

function coder._adapter_source_signature(adapter)
    if adapter.kind == "callable_adapter_plan" then
        return adapter.source
    end
    assert(adapter.kind == "interface_method_adapter")
    return adapter.concrete_signature
end

function coder._adapter_target_signature(adapter)
    if adapter.kind == "callable_adapter_plan" then
        return adapter.target
    end
    assert(adapter.kind == "interface_method_adapter")
    return adapter.interface_signature
end

function coder._adapter_error_kind(adapter)
    return adapter.kind == "callable_adapter_plan"
        and "callable adapter" or "Interface adapter"
end

function coder._interface_adapter_collect_identity(
        inventory, typ)
    typ = types.normalize(typ)
    if not typ then return end
    if typ._tag == "Type.Array" then
        inventory.array = true
    elseif typ._tag == "Type.Option" then
        coder._interface_adapter_collect_identity(
            inventory, typ.base)
    elseif typ._tag == "Type.Nominal" then
        inventory.nominals[typ.fqtn] = typ
    elseif typ._tag == "Type.Record"
           or typ._tag == "Type.Union" then
        inventory.nominals[typ.name] =
            types.Nominal(typ.name)
    elseif typ._tag == "Type.COwned" then
        inventory.owned_c[owned_c_metatable_key(typ)] = typ
    end
end

function coder._interface_adapter_identity_inventory(adapter)
    local inventory = {
        array = false,
        nominals = {},
        owned_c = {},
    }
    local function operation(op)
        if op.kind == "gradual_inject" then
            if coder._interface_injection_may_relocate(op.source) then
                coder._interface_adapter_collect_identity(
                    inventory, op.source)
            end
        elseif op.kind == "gradual_guard"
               and op.timing == "immediate" then
            coder._interface_adapter_collect_identity(
                inventory, op.target)
        end
    end
    for _, action in ipairs(adapter.arguments) do
        if action.operation then operation(action.operation) end
    end
    for _, action in ipairs(adapter.results) do
        if action.operation then operation(action.operation) end
    end
    return inventory
end

function coder._interface_adapter_identity_prelude(
        ctx, adapter)
    local inventory =
        coder._interface_adapter_identity_inventory(adapter)
    local code = {}
    -- A registry lookup needs one API result slot. First creation of the
    -- shared Array metatable needs three: the table, its retained callback
    -- upvalue, and the closure being installed by luaL_setfuncs.
    local scratch_slots = inventory.array and 3 or 0
    ctx.interface_adapter_nominal_metatables = {}
    ctx.interface_adapter_owned_c_metatables = {}
    if inventory.array then
        ctx.interface_adapter_array_metatable =
            "_ia_array_metatable"
        code[#code + 1] =
            "Table *_ia_array_metatable = titan_array_metatable(L);"
    end

    local nominal_names = {}
    for name in pairs(inventory.nominals) do
        nominal_names[#nominal_names + 1] = name
    end
    table.sort(nominal_names, util.bytewise_less)
    for _, name in ipairs(nominal_names) do
        scratch_slots = math.max(scratch_slots, 1)
        local owner = assert(types.registry[name],
            "Interface adapter nominal is absent from registry: " .. name)
        assert(owner._tag == "Type.Record"
               or owner._tag == "Type.Union"
               or owner._tag == "Type.Interface",
            "Interface adapter nominal has invalid owner "
                .. tostring(owner._tag))
        local kind = owner._tag == "Type.Record" and "record"
            or owner._tag == "Type.Union" and "union"
            or "interface"
        local cvar = "_ia_nominal_metatable_"
            .. coder._interface_symbol_fragment(name)
        ctx.interface_adapter_nominal_metatables[name] = cvar
        code[#code + 1] = render([[
            luaL_getmetatable(
                L, "Titan $KIND $TYPE metatable");
            if (TITAN_UNLIKELY(!ttistable(s2v(L->top.p - 1)))) {
                luaL_error(L,
                    "missing per-state metatable for Interface adapter type %s",
                    $DISPLAY);
            }
            Table *$CVAR = hvalue(s2v(L->top.p - 1));
            lua_pop(L, 1);
        ]], {
            KIND = kind,
            TYPE = name,
            DISPLAY = c_string_literal(name),
            CVAR = cvar,
        })
    end

    local owned_names = {}
    for name in pairs(inventory.owned_c) do
        owned_names[#owned_names + 1] = name
    end
    table.sort(owned_names, util.bytewise_less)
    for _, name in ipairs(owned_names) do
        scratch_slots = math.max(scratch_slots, 1)
        local typ = inventory.owned_c[name]
        -- COwned identities are private to the translation unit performing
        -- the conversion, not to the record whose method is being called.
        -- Inventory the emitter-owned metatable so module initialization
        -- creates it, then resolve that exact registry identity without ever
        -- indexing the inbound concrete-owner `_mod`.
        owned_c_metatable(ctx, typ)
        local cvar = "_ia_owned_c_metatable_"
            .. coder._interface_symbol_fragment(name)
        ctx.interface_adapter_owned_c_metatables[name] = cvar
        code[#code + 1] = render([[
            luaL_getmetatable(
                L, "Titan owned C $MODULE $TYPE metatable");
            if (TITAN_UNLIKELY(!ttistable(s2v(L->top.p - 1)))) {
                luaL_error(L,
                    "missing per-state owned-C metatable in Interface adapter");
            }
            Table *$CVAR = hvalue(s2v(L->top.p - 1));
            lua_pop(L, 1);
        ]], {
            MODULE = ctx.tlcontext.module,
            TYPE = types.tostring(typ),
            CVAR = cvar,
        })
    end
    return table.concat(code, "\n"), scratch_slots
end

function coder._interface_adapter_allocate_roots(ctx, adapter)
    -- Keep this in lockstep with titan-runtime/titan.h's TITAN_VARARG_MAX.
    -- Existing callable lowering uses the same 200-element ABI bound. The
    -- emitted adapter checks every dynamic count before indexing either its C
    -- buffer or the parallel traced range.
    local open_cap = 200
    local roots = {
        argument_source = {},
        argument_destination = {},
        result_source = {},
        result_destination = {},
        ranges = {},
    }
    local frame_base = ctx.depth
    local frame_end = frame_base
    for _, phase in ipairs({ "argument", "result" }) do
        -- Fresh argument-destination allocation roots die when the concrete
        -- call returns. Native result roots are born only after that return, so
        -- both phases safely reuse one physical frame region while retaining
        -- distinct frozen logical inventories.
        ctx.depth = frame_base
        local names = {
            phase .. "_source",
            phase .. "_destination",
        }
        for _, name in ipairs(names) do
            local list = adapter.rooting.fixed[name]
            for _, root in ipairs(list) do
                roots[name][root.action] = reserveslot(ctx)
            end
        end
        for _, name in ipairs(names) do
            local range = adapter.rooting.ranges[name]
            if range.traced then
                roots.ranges[name] = ctx.depth
                for _ = 1, open_cap do reserveslot(ctx) end
            end
        end
        if ctx.depth > frame_end then frame_end = ctx.depth end
    end
    ctx.depth = frame_end
    return roots
end

function coder._interface_adapter_anchor(
        typ, depth, value)
    if depth == nil then return "" end
    return setslot(typ, slotat(depth), value)
end

function coder._interface_adapter_anchor_range(
        typ, depth, count, value)
    if depth == nil then return "" end
    return render([[
        for (int _ia_root_i = 0;
             _ia_root_i < $COUNT; _ia_root_i++) {
            $STORE
        }
    ]], {
        COUNT = count,
        STORE = setslot(typ,
            "s2v(" .. stackslotat(depth) .. " + _ia_root_i)",
            value),
    })
end

function coder._interface_adapter_nil_fill(typ, destination)
    typ = types.normalize(typ)
    assert(typ, "Interface adapter nil-fill target is unnormalizable")
    if typ._tag == "Type.Value"
       or typ._tag == "Type.Option"
       or types.is_c_tvalue(typ) then
        return "setnilvalue(&" .. destination .. ");"
    elseif typ._tag == "Type.Nil" then
        return destination .. " = 0;"
    elseif typ._tag == "Type.Pointer"
           or typ._tag == "Type.CPointer" then
        return destination .. " = NULL;"
    end
    error("Interface adapter cannot nil-fill "
        .. types.tostring(typ))
end

function coder._emit_interface_adapter_operation(
        ctx, operation, source, destination, loc, use, result_root)
    local code
    if operation.kind == "identity"
       or (operation.kind == "gradual_guard"
           and operation.timing == "delayed_observation") then
        code = destination .. " = " .. source .. ";"
    elseif operation.kind == "callable_view" then
        local wrapper_stats, wrapper_value =
            coder._emit_callable_adapter_value(
                ctx, operation.adapter, source, loc, use,
                assert(result_root,
                    use .. " lacks its allocating-operation root"))
        code = wrapper_stats .. "\n"
            .. destination .. " = " .. wrapper_value .. ";"
    elseif operation.kind == "gradual_inject" then
        code = setboxed(
            ctx, operation.source, "&" .. destination, source)
    elseif operation.kind == "gradual_guard" then
        code = coder._strictcheckandget(
            ctx, operation.guard, operation.target,
            destination, "&" .. source, loc, use)
    else
        error(use .. " has unsupported operation "
            .. tostring(operation.kind))
    end
    if operation.may_relocate then
        code = code
            .. "\n_base = restorestack(L, _base_off);"
    end
    return code
end

function coder._emit_interface_adapter_argument_sources(
        ctx, adapter, roots, loc)
    local code = {}
    local interface = coder._adapter_target_signature(adapter)
    if interface.varargtype then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(
                    _varargs == NULL
                    || _start < 0
                    || _start > (int)_varargs->n_args
                    || (int)_varargs->n_args > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "malformed Interface adapter variadic input for %s",
                    $TRACE);
            }
            int _ia_interface_tail_count =
                (int)_varargs->n_args - _start;
            (void)_ia_interface_tail_count;
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    -- Native fixed arguments and open runs remain C inputs, not tracing-stack
    -- values. The canonical inventory therefore emits no source anchors.
    for _, action in ipairs(adapter.arguments) do
        local depth = roots.argument_source[action.id]
        if depth ~= nil then
            local index = action.expected_index
            assert(index and action.source_kind == "interface_fixed",
                "fixed Interface argument root has no fixed source")
            code[#code + 1] =
                coder._interface_adapter_anchor(
                    action.source_type, depth,
                    "_ia_param_" .. tostring(index))
        end
    end
    if roots.ranges.argument_source ~= nil then
        code[#code + 1] =
            coder._interface_adapter_anchor_range(
                interface.varargtype,
                roots.ranges.argument_source,
                "_ia_interface_tail_count",
                "_varargs->args[_start + _ia_root_i]")
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local code = {}
    local concrete = coder._adapter_source_signature(adapter)
    if concrete.varargtype then
        code[#code + 1] = render([[
            $ELEM _ia_concrete_vargs[TITAN_VARARG_MAX] = {0};
            int _ia_concrete_vcount = 0;
        ]], {
            ELEM = ctype(concrete.varargtype),
        })
    end
    for index, typ in ipairs(concrete.params) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ, "_ia_concrete_arg_" .. tostring(index)),
            INIT = initval(typ),
        })
    end

    local function root_fixed(action)
        local depth = roots.argument_destination[action.id]
        return depth ~= nil and slotat(depth) or nil
    end
    local function root_tail()
        local depth = roots.ranges.argument_destination
        return depth ~= nil and ("s2v(" .. stackslotat(depth)
            .. " + _ia_concrete_vcount)") or nil
    end
    local function append_guard()
        return render([[
            if (TITAN_UNLIKELY(
                    _ia_concrete_vcount >= TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many variadic arguments in Interface adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    for _, action in ipairs(adapter.arguments) do
        local use = adapter.trace_name
            .. " " .. action.id
        if action.kind == "argument" then
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_param_" .. tostring(action.expected_index),
                    "_ia_concrete_arg_" .. tostring(action.actual_index),
                    loc, use, root_fixed(action))
        elseif action.kind == "tail_or_nil_to_argument" then
            code[#code + 1] = render([[
                if (_ia_interface_tail_count >= $OFFSET) {
                    $PRESENT
                } else {
                    $MISSING
                }
            ]], {
                OFFSET =
                    c_integer_literal(action.expected_tail_offset),
                PRESENT = coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_varargs->args[_start + "
                        .. c_integer_literal(
                            action.expected_tail_offset - 1)
                        .. "]",
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index),
                    loc, use, root_fixed(action)),
                MISSING = coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index)),
            })
        elseif action.kind == "nil_fill" then
            code[#code + 1] =
                coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index))
        elseif action.kind == "argument_to_tail" then
            code[#code + 1] = append_guard()
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_param_" .. tostring(action.expected_index),
                    "_ia_concrete_vargs[_ia_concrete_vcount]",
                    loc, use, root_tail())
            code[#code + 1] = "_ia_concrete_vcount++;"
        elseif action.kind == "tail_to_tail" then
            code[#code + 1] = render([[
                for (int _ia_tail_i = $CONSUMED;
                     _ia_tail_i < _ia_interface_tail_count;
                     _ia_tail_i++) {
                    $GUARD
                    $CONVERT
                    _ia_concrete_vcount++;
                }
            ]], {
                CONSUMED = c_integer_literal(
                    action.expected_tail_consumed),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_varargs->args[_start + _ia_tail_i]",
                        "_ia_concrete_vargs[_ia_concrete_vcount]",
                        loc, use, root_tail()),
            })
        elseif action.kind == "empty_tail"
               or action.kind == "ignore_argument"
               or action.kind == "ignore_tail" then
            -- Parameters have already been evaluated by the caller. Ignored
            -- native C values/runs require neither conversion nor a stack copy.
        else
            error(use .. " has unsupported argument action "
                .. tostring(action.kind))
        end
    end
    if concrete.varargtype then
        code[#code + 1] = render([[
            $STRUCT _ia_concrete_vdesc = {
                (lu_byte)_ia_concrete_vcount,
                _ia_concrete_vargs
            };
        ]], {
            STRUCT = varg_struct_name(concrete.varargtype),
        })
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local code = {}
    local concrete = coder._adapter_source_signature(adapter)
    local interface = coder._adapter_target_signature(adapter)
    for index, typ in ipairs(concrete.rettypes) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ,
                "_ia_concrete_result_" .. tostring(index)),
            INIT = initval(typ),
        })
    end
    if concrete.flexrettype then
        local demand = adapter.kind == "callable_adapter_plan"
            and adapter.flexible_result_demand
            or adapter.callable_adapter.flexible_result_demand
        local consumed = demand.fixed_source_flex_consumed
        local fixed_surplus = demand.fixed_source_surplus
        assert(demand.within_abi_cap
               and demand.abi_cap == 200,
            coder._adapter_error_kind(adapter)
                .. " fixed flex demand exceeds ABI cap")
        code[#code + 1] = render([[
            $ELEM _ia_concrete_fargs[TITAN_VARARG_MAX] = {0};
            $STRUCT _ia_concrete_fdesc = {
                0, _ia_concrete_fargs
            };
            int _ia_concrete_fwant = $DEMAND;
        ]], {
            ELEM = ctype(concrete.flexrettype),
            STRUCT = varg_struct_name(concrete.flexrettype),
            DEMAND = interface.flexrettype and render([[
                (_flexwant == LUA_MULTRET)
                    ? LUA_MULTRET
                    : ((_flexwant <= $SURPLUS)
                        ? $PREFIX
                        : (((_flexwant - $SURPLUS) >= $REMAINING)
                            ? TITAN_VARARG_MAX
                            : _flexwant - $SURPLUS + $PREFIX))
            ]], {
                REMAINING = c_integer_literal(
                    demand.remaining_source_capacity),
                PREFIX = c_integer_literal(consumed),
                SURPLUS = c_integer_literal(fixed_surplus),
            }) or c_integer_literal(consumed),
        })
    end

    local args
    local invocation_name
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(_fn == NULL
                    || _fn->nupvalues < 6
                    || !ttisCclosure(
                        &_fn->upvalue[_fn->nupvalues - 2]))) {
                luaL_error(L, "invalid callable adapter wrapper for %s", $TRACE);
            }
            CClosure *_ia_source = clCvalue(
                &_fn->upvalue[_fn->nupvalues - 2]);
            if (TITAN_UNLIKELY(_ia_source->nupvalues < 5
                    || !ttisfulluserdata(&_ia_source->upvalue[0])
                    || !ttislightuserdata(&_ia_source->upvalue[1])
                    || !ttislightuserdata(&_ia_source->upvalue[2])
                    || pvalue(&_ia_source->upvalue[1]) != $SOURCE_TAG)) {
                luaL_error(L, "invalid callable adapter source for %s", $TRACE);
            }
            Udata *_ia_source_mod = uvalue(&_ia_source->upvalue[0]);
            typedef $SOURCE_FP_DECL;
            $SOURCE_FP_TYPE _ia_source_fp = titan_cast_func(
                $SOURCE_FP_TYPE, pvalue(&_ia_source->upvalue[2]));
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
            SOURCE_TAG = function_type_tag(ctx.tlcontext, concrete),
            SOURCE_FP_DECL = function_sig(
                "_ia_source_fp_type", concrete, true),
            SOURCE_FP_TYPE = "_ia_source_fp_type",
        })
        args = { "L", "_ia_source_mod", "_ia_source" }
        invocation_name = "_ia_source_fp"
    else
        args = { "L", "_mod", "NULL", "_self" }
        invocation_name = method_name(adapter.concrete_method)
    end
    for index = 1, #concrete.params do
        args[#args + 1] =
            "_ia_concrete_arg_" .. tostring(index)
    end
    if concrete.varargtype then
        args[#args + 1] = "&_ia_concrete_vdesc"
        args[#args + 1] = "0"
    end
    for index = 2, #concrete.rettypes do
        args[#args + 1] =
            "&_ia_concrete_result_" .. tostring(index)
    end
    if concrete.flexrettype then
        args[#args + 1] = "&_ia_concrete_fdesc"
        args[#args + 1] = "_ia_concrete_fwant"
    end
    local invocation = invocation_name
        .. "(" .. table.concat(args, ", ") .. ")"
    if #concrete.rettypes > 0 then
        invocation = "_ia_concrete_result_1 = "
            .. invocation .. ";"
    else
        invocation = invocation .. ";"
    end
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = emitline({ loc = adapter.location })
    end
    code[#code + 1] = invocation
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = emitline({ loc = adapter.location })
    end
    code[#code + 1] =
        "_base = restorestack(L, _base_off);"
    for index = 1, #concrete.rettypes do
        code[#code + 1] =
            "(void)_ia_concrete_result_" .. tostring(index) .. ";"
    end

    if concrete.flexrettype then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(
                    (int)_ia_concrete_fdesc.n_args
                        > TITAN_VARARG_MAX
                    || (_ia_concrete_fwant != LUA_MULTRET
                        && (int)_ia_concrete_fdesc.n_args
                            > _ia_concrete_fwant))) {
                luaL_error(L,
                    "malformed flexible result run in adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    for _, action in ipairs(adapter.results) do
        local depth = roots.result_source[action.id]
        if depth ~= nil then
            assert(action.source_kind == "concrete_fixed"
                   and action.actual_index,
                "fixed Interface result root has no fixed source")
            code[#code + 1] =
                coder._interface_adapter_anchor(
                    action.source_type, depth,
                    "_ia_concrete_result_"
                        .. tostring(action.actual_index))
        end
    end
    if roots.ranges.result_source ~= nil then
        code[#code + 1] =
            coder._interface_adapter_anchor_range(
                concrete.flexrettype,
                roots.ranges.result_source,
                "(int)_ia_concrete_fdesc.n_args",
                "_ia_concrete_fargs[_ia_root_i]")
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local code = {}
    local interface = coder._adapter_target_signature(adapter)
    for index, typ in ipairs(interface.rettypes) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ,
                "_ia_interface_result_" .. tostring(index)),
            INIT = initval(typ),
        })
    end
    if interface.flexrettype then
        code[#code + 1] = [[
            int _ia_interface_fcount = 0;
            _flexout->n_args = 0;
        ]]
    end

    local function root_fixed(action)
        local depth = roots.result_destination[action.id]
        return depth ~= nil and slotat(depth) or nil
    end
    local function root_flex()
        local depth = roots.ranges.result_destination
        return depth ~= nil and ("s2v(" .. stackslotat(depth)
            .. " + _ia_interface_fcount)") or nil
    end
    local function append_guard()
        return render([[
            if (TITAN_UNLIKELY(
                    _ia_interface_fcount >= TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many flexible results in Interface adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local function wants_more()
        return "(_flexwant == LUA_MULTRET"
            .. " || _ia_interface_fcount < _flexwant)"
    end

    for _, action in ipairs(adapter.results) do
        local use = adapter.trace_name
            .. " " .. action.id
        if action.kind == "result" then
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_concrete_result_"
                        .. tostring(action.actual_index),
                    "_ia_interface_result_"
                        .. tostring(action.expected_index),
                    loc, use, root_fixed(action))
        elseif action.kind == "nil_fill_result" then
            code[#code + 1] =
                coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_interface_result_"
                        .. tostring(action.expected_index))
        elseif action.kind == "flex_to_optional_result"
               or action.kind == "flex_to_result" then
            local present
            if action.wrap_present then
                local base_name = "_ia_present_"
                    .. tostring(action.order)
                present = render([[
                    $DECL = $INIT;
                    $CONVERT
                    $WRAP
                ]], {
                    DECL = cvardecl(
                        ctx, action.operation_target_type, base_name),
                    INIT = initval(action.operation_target_type),
                    CONVERT =
                        coder._emit_interface_adapter_operation(
                            ctx, action.operation,
                            "_ia_concrete_fargs["
                                .. c_integer_literal(
                                    action.actual_flex_offset - 1)
                                .. "]",
                            base_name, loc, use, root_fixed(action)),
                    WRAP = setslot(
                        action.operation_target_type,
                        "&_ia_interface_result_"
                            .. tostring(action.expected_index),
                        base_name),
                })
            else
                present =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_fargs["
                            .. c_integer_literal(
                                action.actual_flex_offset - 1)
                            .. "]",
                        "_ia_interface_result_"
                            .. tostring(action.expected_index),
                        loc, use, root_fixed(action))
            end
            local missing
            if action.missing_arm.kind == "nil_fill" then
                missing = coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_interface_result_"
                        .. tostring(action.expected_index))
            else
                missing = render([[
                    luaL_error(L,
                        "adapter %s expected result %d",
                        $TRACE, $INDEX);
                ]], {
                    TRACE = c_string_literal(adapter.trace_name),
                    INDEX = c_integer_literal(action.expected_index),
                })
            end
            code[#code + 1] = render([[
                if ((int)_ia_concrete_fdesc.n_args >= $OFFSET) {
                    $PRESENT
                } else {
                    $MISSING
                }
            ]], {
                OFFSET =
                    c_integer_literal(action.actual_flex_offset),
                PRESENT = present,
                MISSING = missing,
            })
        elseif action.kind == "result_to_flex" then
            code[#code + 1] = render([[
                if ($WANTS) {
                    $GUARD
                    $CONVERT
                    _ia_interface_fcount++;
                }
            ]], {
                WANTS = wants_more(),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_result_"
                            .. tostring(action.actual_index),
                        "_flexout->args[_ia_interface_fcount]",
                        loc, use, root_flex()),
            })
        elseif action.kind == "flex_to_flex" then
            code[#code + 1] = render([[
                for (int _ia_flex_i = $CONSUMED;
                     _ia_flex_i < (int)_ia_concrete_fdesc.n_args
                        && $WANTS;
                     _ia_flex_i++) {
                    $GUARD
                    $CONVERT
                    _ia_interface_fcount++;
                }
            ]], {
                CONSUMED = c_integer_literal(
                    action.actual_flex_consumed),
                WANTS = wants_more(),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_fargs[_ia_flex_i]",
                        "_flexout->args[_ia_interface_fcount]",
                        loc, use, root_flex()),
            })
        elseif action.kind == "hide_result"
               or action.kind == "hide_flex"
               or action.kind == "end_flex" then
            -- Concrete results were evaluated by the call, but these actions
            -- do not make them live at the target boundary. They publish no
            -- source or destination root and perform no later allocating work.
        else
            error(use .. " has unsupported result action "
                .. tostring(action.kind))
        end
    end
    if interface.flexrettype then
        code[#code + 1] =
            "_flexout->n_args = (lu_byte)_ia_interface_fcount;"
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter(
        tlcontext, pair, index, mapping)
    local adapter = assert(mapping.interface_adapter)
    local name = assert(pair.adapter_ids[index])
    local ctx = newcontext(tlcontext)
    local roots =
        coder._interface_adapter_allocate_roots(ctx, adapter)
    local identities, identity_scratch =
        coder._interface_adapter_identity_prelude(ctx, adapter)
    local loc = {
        -- Native traceback filtering recognizes generated Titan frames by a
        -- `.titan` line-table source. The separately registered symbol name is
        -- the stable logical adapter trace shown to the user.
        filename = adapter.trace_name .. ".titan",
        line = 1,
        col = 1,
    }
    local argument_sources =
        coder._emit_interface_adapter_argument_sources(
            ctx, adapter, roots, loc)
    local flex_validation = ""
    if coder._adapter_target_signature(adapter).flexrettype then
        flex_validation = render([[
            if (TITAN_UNLIKELY(
                    _flexout == NULL
                    || (_flexwant != LUA_MULTRET
                        && (_flexwant < 0
                            || _flexwant > TITAN_VARARG_MAX)))) {
                luaL_error(L,
                    "malformed Interface adapter flexible-result demand for %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local arguments = coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local call = coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local results = coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local interface = coder._adapter_target_signature(adapter)
    local handoff = {}
    for index = 2, #interface.rettypes do
        handoff[#handoff + 1] = render([[
            *_ia_out_$INDEX = _ia_interface_result_$INDEX;
        ]], {
            INDEX = c_integer_literal(index),
        })
    end
    local finish
    if #interface.rettypes == 0 then
        finish = "L->top.p = _base;\nreturn;"
    else
        finish = [[
            L->top.p = _base;
            return _ia_interface_result_1;
        ]]
    end
    register_trace_name(tlcontext, name, adapter.trace_name)
    local signature =
        coder._interface_adapter_signature(
            name, adapter.native_signature, false)
    local root_preamble
    if ctx.nslots > 0 then
        root_preamble = render([[
            /*
             * Rooted scratch occupies NSLOTS entries. Identity setup later
             * uses transient API slots, so reserve them without adding them
             * to the GC-visible rooted range.
            */
            titan_ensure_stack(L, $NRESERVE);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for (StkId _ia_slot = L->top.p - 1;
                 _base <= _ia_slot; _ia_slot--) {
                setnilvalue2s(_ia_slot);
            }
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NSLOTS = c_integer_literal(ctx.nslots),
            NRESERVE =
                c_integer_literal(ctx.nslots + identity_scratch),
        })
    elseif identity_scratch > 0 then
        root_preamble = render([[
            /* Reserve transient Interface identity-setup results. */
            titan_ensure_stack(L, $NRESERVE);
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NRESERVE = c_integer_literal(identity_scratch),
        })
    else
        root_preamble = [[
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]]
    end
    local body = render([[
        static TITAN_NOINLINE $SIGNATURE {
            (void)_fn;
            $GC_POLL
            $ROOT_PREAMBLE
            $ARGUMENT_SOURCES
            $FLEX_VALIDATION
            $IDENTITIES
            $ARGUMENTS
            $CALL
            $RESULTS
            $HANDOFF
            $FINISH
        }
    ]], {
        SIGNATURE = signature,
        GC_POLL = coder._adapter_actions_allocate(adapter)
            and "luaC_checkGC(L);" or "",
        ROOT_PREAMBLE = root_preamble,
        ARGUMENT_SOURCES = argument_sources,
        FLEX_VALIDATION = flex_validation,
        IDENTITIES = identities,
        ARGUMENTS = arguments,
        CALL = call,
        RESULTS = results,
        HANDOFF = table.concat(handoff, "\n"),
        FINISH = finish,
    })
    return "static TITAN_NOINLINE "
        .. coder._interface_adapter_signature(
            name, adapter.native_signature, false)
        .. ";", body
end

-- Encode a source identity injectively into a portable C identifier fragment.
-- Pair/adapter identities must not depend on AST discovery order, and the
-- ordinary source-name mangler is intentionally not injective (`.` and `-`
-- both become `_`). Two hex digits per source byte keep this private symbol
-- namespace deterministic without relying on a collision-prone hash.
function coder._interface_symbol_fragment(name)
    assert(type(name) == "string" and name ~= "",
        "Interface symbol identity is not a nonempty string")
    local bytes = {}
    for i = 1, #name do
        bytes[i] = string.format("%02x", name:byte(i))
    end
    return table.concat(bytes)
end

-- Validate and inventory one concrete/Interface pair. Exact slots point
-- directly at the concrete method; adjusted slots carry one checker-frozen
-- adapter plan and receive a deterministic private adapter symbol.
function coder._interface_pair(ctx, conversion)
    local use = "concrete-to-Interface conversion"
    assert(conversion and conversion.kind == "interface_conversion",
        use .. " lacks its checker annotation")
    local concrete = assert(conversion.concrete,
        use .. " lacks its concrete descriptor")
    local interface = assert(conversion.interface,
        use .. " lacks its Interface descriptor")
    assert(concrete._tag == "Type.Record" or concrete._tag == "Type.Union",
        use .. " has a non-concrete owner")
    assert(interface._tag == "Type.Interface"
           and types.validate_interface_descriptor(interface),
        use .. " has an invalid Interface descriptor")
    assert(conversion.concrete_type
           and conversion.concrete_type._tag == "Type.Nominal"
           and conversion.concrete_type.fqtn == concrete.name,
        use .. " has a mismatched concrete value type")
    assert(conversion.interface_type
           and conversion.interface_type._tag == "Type.Nominal"
           and conversion.interface_type.fqtn == interface.name,
        use .. " has a mismatched Interface value type")
    assert(type(conversion.methods) == "table"
           and #conversion.methods == #interface.methods,
        use .. " has a noncanonical ordered method mapping")
    local tlcontext = ctx.tlcontext
    local key = concrete.name .. "\0" .. interface.name
    local prior = tlcontext.interface_pairs[key]
    local entry = prior
    if not entry then
        local pair_fragment =
            coder._interface_symbol_fragment(concrete.name)
            .. "_to_"
            .. coder._interface_symbol_fragment(interface.name)
        entry = {
            key = key,
            id = tlcontext.prefix .. "interface_pair_" .. pair_fragment,
            concrete = concrete,
            interface = interface,
            methods = conversion.methods,
            adapter_ids = {},
        }
        tlcontext.interface_pairs[key] = entry
        table.insert(tlcontext.interface_pair_list, entry)
    else
        assert(entry.concrete == concrete
               and entry.interface == interface
               and #entry.methods == #conversion.methods,
            use .. " disagrees with an existing pair obligation")
    end

    local all_exact = true
    for index, mapping in ipairs(conversion.methods) do
        local required = interface.methods[index]
        assert(mapping.index == index - 1
               and mapping.name == required.name
               and mapping.required == required
               and mapping.concrete
               and mapping.concrete._tag == "Type.Method"
               and mapping.concrete.fqtn == concrete.name,
            use .. " has a malformed mapping at slot "
                .. tostring(index - 1))
        assert(mapping.source
               and mapping.source._tag == "Type.Function"
               and mapping.target
               and mapping.target._tag == "Type.Function"
               and types.equals(
                   mapping.source,
                   types.method_function_type(mapping.concrete))
               and types.equals(
                   mapping.target,
                   types.method_function_type(required)),
            use .. " has mismatched projected signatures at slot "
                .. tostring(index - 1))
        assert(mapping.exact == types.equals(
                mapping.source, mapping.target),
            use .. " has an inconsistent exactness marker")
        all_exact = all_exact and mapping.exact
        if mapping.exact then
            assert(mapping.slot_kind == "exact"
                   and mapping.interface_adapter == nil,
                use .. " has a malformed exact mapping")
        else
            assert(mapping.slot_kind == "adapter"
                   and mapping.interface_adapter,
                use .. " has an adjusted mapping without a frozen adapter")
            entry.adapter_ids[index] =
                entry.id .. "_adapter_" .. tostring(index - 1)
            coder._validate_interface_adapter(
                mapping.interface_adapter,
                concrete, interface, mapping,
                use .. " slot " .. tostring(index - 1))
        end
        if prior then
            local old = prior.methods[index]
            assert(old.concrete == mapping.concrete
                   and old.required == mapping.required
                   and old.exact == mapping.exact,
                use .. " disagrees with an existing mapping at slot "
                    .. tostring(index - 1))
        end

        local method = mapping.concrete
        local module, record =
            assert(method.fqtn:match("^(.*)%.([^.]+)$"))
        if module ~= ctx.module then
            local symbol = method_name(method)
            ctx.functions[method.fqtn .. ":interface:"
                .. interface.name .. ":" .. method.name] = {
                module = module,
                record = record,
                name = method.name,
                type = method,
                mangled = symbol,
            }
        end
    end
    assert(conversion.exact == all_exact,
        use .. " has a mismatched pair exactness marker")
    return entry
end

-- Build the exact two-uservalue wrapper from an already authorized scalar
-- conversion. Freeze the concrete source once in C for lexical stability; its
-- ordinary traced home (or immediate allocation/result root) remains live while
-- the fresh wrapper allocation establishes its own root.
function coder._code_interface_wrapper(
        ctx, conversion, source_stats, source_exp, result_root)
    local pair = coder._interface_pair(ctx, conversion)
    local frozen_stats, concrete_value = coder._freeze_code(
        ctx, conversion.concrete_type, source_stats, source_exp)
    local wrapper_decl, wrapper, wrapper_slot
    if result_root then
        assert(type(result_root) == "string",
            "Interface allocation root is not a C expression")
        wrapper_decl, wrapper =
            newtmp(ctx, conversion.interface_type, false)
        wrapper_slot = result_root
    else
        wrapper_decl, wrapper, wrapper_slot =
            newtmp(ctx, conversion.interface_type, true)
    end
    local metatable_slot =
        type2metatable(ctx, conversion.interface_type)
    local concrete_module =
        coder._interface_owner_module_expr(ctx, conversion.concrete)

    -- luaS_newudata may relocate the Lua stack. The fresh destination root is
    -- addressed by saved offset, so force the ordinary `_base_off` preamble and
    -- rebase immediately after allocation before publishing it.
    ctx.uses_base_off = true
    return render([[
        $SOURCE_STATS
        $WRAPPER_DECL
        {
            Udata *_titan_interface_concrete_module = $CONCRETE_MODULE;
            Table *_titan_interface_metatable =
                hvalue(&_mod->uv[$METATABLE_SLOT].uv);
            $WRAPPER = luaS_newudata(
                L, sizeof($VTABLE), 2);
            _base = restorestack(L, _base_off);
            setuvalue(L, $WRAPPER_SLOT, $WRAPPER);
            $WRAPPER->metatable = _titan_interface_metatable;
            setuvalue(L, &$WRAPPER->uv[0].uv,
                _titan_interface_concrete_module);
            luaC_barrierback(L, obj2gco($WRAPPER),
                &$WRAPPER->uv[0].uv);
            setuvalue(L, &$WRAPPER->uv[1].uv, $CONCRETE_VALUE);
            luaC_barrierback(L, obj2gco($WRAPPER),
                &$WRAPPER->uv[1].uv);
            memcpy(getudatamem($WRAPPER), $VTABLE, sizeof($VTABLE));
        }
    ]], {
        SOURCE_STATS = frozen_stats,
        WRAPPER_DECL = wrapper_decl,
        WRAPPER = wrapper,
        WRAPPER_SLOT = wrapper_slot,
        CONCRETE_MODULE = concrete_module,
        CONCRETE_VALUE = concrete_value,
        METATABLE_SLOT = c_integer_literal(metatable_slot),
        VTABLE = pair.id,
    }), wrapper
end

function coder._code_interface_conversion(ctx, node)
    local conversion = assert(node._interface_conversion,
        "Interface cast is missing its checker conversion")
    local result_root = node._allocation_result_root
    assert(result_root == nil or type(result_root) == "string",
        "Interface conversion allocation root is not a C expression")
    assert(conversion.source and conversion.target
           and types.equals(conversion.source, node.exp._type)
           and types.equals(conversion.target, node._type),
        "Interface conversion does not match its cast node")

    if conversion.option == "interface_wrapper" then
        assert(not conversion.source_optional
               and not conversion.target_optional,
            "scalar Interface wrapper has optional endpoints")
        local source_stats, source_exp = codeexp(ctx, node.exp)
        return coder._code_interface_wrapper(
            ctx, conversion, source_stats, source_exp, result_root)
    end

    assert(conversion.option == "option_map"
           or conversion.option == "option_wrap"
           or conversion.option == "option_force",
        "unknown Interface Option operation "
            .. tostring(conversion.option))

    if conversion.option == "option_wrap" then
        assert(not conversion.source_optional
               and conversion.target_optional,
            "Interface Option-wrap has mismatched endpoints")
        local source_stats, source_exp = codeexp(ctx, node.exp)
        local wrapper_stats, wrapper =
            coder._code_interface_wrapper(
                ctx, conversion, source_stats, source_exp, result_root)
        local result_decl, result = newtmp(ctx, node._type)
        return render([[
            $WRAPPER_STATS
            $RESULT_DECL
            setuvalue(L, &$RESULT, $WRAPPER);
        ]], {
            WRAPPER_STATS = wrapper_stats,
            RESULT_DECL = result_decl,
            RESULT = result,
            WRAPPER = wrapper,
        }), result
    end

    local source_stats, source =
        coder._freeze(ctx, node.exp)
    local concrete_decl, concrete =
        newtmp(ctx, conversion.concrete_type)
    local wrapper_stats, wrapper =
        coder._code_interface_wrapper(
            ctx, conversion, "", concrete, result_root)
    local result_decl, result = newtmp(ctx, node._type)
    local nil_arm
    local present_store
    if conversion.option == "option_map" then
        assert(conversion.source_optional
               and conversion.target_optional
               and conversion.nil_propagates,
            "Interface Option-map has mismatched endpoints")
        nil_arm = "setnilvalue(&" .. result .. ");"
        present_store = "setuvalue(L, &" .. result .. ", "
            .. wrapper .. ");"
    else
        assert(conversion.option == "option_force"
               and conversion.source_optional
               and not conversion.target_optional
               and conversion.forces_source,
            "Interface Option-force has mismatched endpoints")
        nil_arm = codethrow(node.loc,
            "%s:%d:%d: type error, expected %s but found nil", {
                c_string_literal(node.loc.filename),
                c_integer_literal(node.loc.line),
                c_integer_literal(node.loc.col),
                c_string_literal(
                    types.tostring(conversion.interface_type)),
            })
        present_store = result .. " = " .. wrapper .. ";"
    end
    return render([[
        $SOURCE_STATS
        $RESULT_DECL
        if (TITAN_UNLIKELY(ttisnil(&$SOURCE))) {
            $NIL_ARM
        } else {
            $CONCRETE_DECL
            $GET_CONCRETE;
            $WRAPPER_STATS
            $PRESENT_STORE
        }
    ]], {
        SOURCE_STATS = source_stats,
        SOURCE = source,
        RESULT_DECL = result_decl,
        RESULT = result,
        NIL_ARM = nil_arm,
        CONCRETE_DECL = concrete_decl,
        GET_CONCRETE = getslot(
            conversion.concrete_type, concrete, "&" .. source),
        WRAPPER_STATS = wrapper_stats,
        PRESENT_STORE = present_store,
    }), result
end

function coder._code_interface_downcast(ctx, node, predicate_only)
    local downcast = assert(node._interface_downcast,
        "Interface downcast lacks its checker annotation")
    assert(downcast.kind == "interface_downcast"
           and downcast.interface
           and downcast.interface._tag == "Type.Interface"
           and downcast.concrete
           and (downcast.concrete._tag == "Type.Record"
                or downcast.concrete._tag == "Type.Union"),
        "malformed Interface downcast annotation")
    local target = node.target or node._type
    assert(target._tag == "Type.Nominal"
           and target.fqtn == downcast.concrete.name,
        "Interface downcast target is not its concrete nominal")

    local source_stats, source = materialize(ctx, node.exp)
    local wrapper_decl, wrapper =
        newtmp(ctx, types.Nominal(downcast.interface.name))
    local concrete_decl, concrete =
        newtmp(ctx, target)
    local result_decl, result = newtmp(
        ctx, predicate_only and types.Boolean() or target)
    local metatable_slot = type2metatable(ctx, target)
    local unwrap
    if downcast.source_optional then
        unwrap = render([[
            if (!ttisnil(&$SOURCE)) {
                $GET_WRAPPER;
            }
        ]], {
            SOURCE = source,
            GET_WRAPPER = getslot(
                types.Nominal(downcast.interface.name),
                wrapper, "&" .. source),
        })
    else
        unwrap = wrapper .. " = " .. source .. ";"
    end

    local failure
    local success
    if predicate_only then
        failure = result .. " = 0;"
        success = result .. " = 1;"
    else
        failure = codethrow(node.loc,
            "%s:%d:%d: type error, Interface value does not wrap %s", {
                c_string_literal(node.loc.filename),
                c_integer_literal(node.loc.line),
                c_integer_literal(node.loc.col),
                c_string_literal(types.tostring(target)),
            })
        success = result .. " = " .. concrete .. ";"
    end
    return render([[
        $SOURCE_STATS
        $WRAPPER_DECL
        $CONCRETE_DECL
        $RESULT_DECL
        $UNWRAP
        if ($WRAPPER != NULL) {
            $CONCRETE = uvalue(&$WRAPPER->uv[1].uv);
        }
        if (TITAN_LIKELY($CONCRETE != NULL
                && $CONCRETE->metatable ==
                    hvalue(&_mod->uv[$METATABLE_SLOT].uv))) {
            $SUCCESS
        } else {
            $FAILURE
        }
    ]], {
        SOURCE_STATS = source_stats,
        WRAPPER_DECL = wrapper_decl,
        WRAPPER = wrapper,
        CONCRETE_DECL = concrete_decl,
        CONCRETE = concrete,
        RESULT_DECL = result_decl,
        RESULT = result,
        UNWRAP = unwrap,
        METATABLE_SLOT = c_integer_literal(metatable_slot),
        SUCCESS = success,
        FAILURE = failure,
    }), result
end

function coder._resolve_cast_type(typ)
    -- `Type.Typedef` is the legacy scalar typedef representation retained by
    -- a few compiler paths; current C imports use `Type.CTypedef`.
    while typ and typ._tag == "Type.Typedef" do typ = typ._type end
    return types.resolve_c_typedef(typ)
end

function coder._is_numeric_type(typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    return tag == "Type.Integer" or tag == "Type.Float"
        or tag == "Type.CInteger" or tag == "Type.CFloat"
end

function coder._is_c_numeric_type(typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    return tag == "Type.CInteger" or tag == "Type.CFloat"
end

function coder._numeric_carriers(source_type, target_type)
    local source = coder._resolve_cast_type(source_type)
    local target = coder._resolve_cast_type(target_type)
    local anchor
    if source and (source._tag == "Type.CInteger"
                   or source._tag == "Type.CFloat") then
        anchor = source
    elseif target and (target._tag == "Type.CInteger"
                       or target._tag == "Type.CFloat") then
        anchor = target
    end
    assert(anchor and anchor._c_numeric_carriers,
        "C numeric lowering lacks authoritative target-profile metadata")
    return anchor._c_numeric_carriers
end

function coder._numeric_trait(source_type, target_type, typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    local carriers = coder._numeric_carriers(source_type, target_type)
    if tag == "Type.Integer" then
        return carriers.lua_integer
    elseif tag == "Type.Float" then
        return carriers.lua_number
    elseif tag == "Type.CInteger" or tag == "Type.CFloat" then
        assert(resolved._c_numeric,
            "direct C numeric type lacks target-profile traits")
        assert(resolved._c_numeric_carriers
               and resolved._c_numeric_carriers.identity == carriers.identity,
            "C numeric conversion combines different target profiles")
        return resolved._c_numeric
    end
    error("non-numeric type in numeric lowering: " .. types.tostring(typ))
end

function coder._numeric_c_name(typ, trait)
    coder._record_c_type_use(typ)
    local resolved = coder._resolve_cast_type(typ)
    if resolved._tag == "Type.Integer" then return "lua_Integer" end
    if resolved._tag == "Type.Float" then return "lua_Number" end
    return trait.spelling
end

function coder._integer_maximum_expression(trait)
    local ct = trait.spelling
    if not trait.signed then
        if trait.precision == 1 then
            return render("(($CT)1)", { CT = ct })
        end
        return render("((($CT)~($CT)0))", { CT = ct })
    end
    assert(trait.unsigned and trait.precision,
        "signed C integer trait lacks its unsigned partner/precision")
    return render([[
        (($CT)((((($UCT)1) << $PRECISION) - (($UCT)1))))
    ]], {
        CT = ct,
        UCT = trait.unsigned,
        PRECISION = c_integer_literal(trait.precision),
    })
end

function coder._integer_minimum_expression(trait)
    if not trait.signed then
        return render("(($CT)0)", { CT = trait.spelling })
    end
    return render("(($CT)(-($MAXIMUM) - 1))", {
        CT = trait.spelling,
        MAXIMUM = coder._integer_maximum_expression(trait),
    })
end

function coder._integer_range_predicate(
        source_type, target_type, source, source_trait, target_trait)
    local contains, err =
        coder._csemantics.integer_range_contains(
            target_trait, source_trait)
    assert(contains ~= nil, err)
    if contains then return "1" end

    local checks = {}
    local source_ct = coder._numeric_c_name(source_type, source_trait)
    if source_trait.signed and not target_trait.signed then
        checks[#checks + 1] = render("(($SOURCE) >= 0)", {
            SOURCE = source,
        })
    elseif source_trait.signed and target_trait.signed
           and target_trait.precision < source_trait.precision then
        checks[#checks + 1] = render(
            "(($SOURCE) >= (($SOURCE_CT)($MINIMUM)))", {
                SOURCE = source,
                SOURCE_CT = source_ct,
                MINIMUM = coder._integer_minimum_expression(target_trait),
            })
    end

    local needs_maximum
    if source_trait.signed == target_trait.signed then
        needs_maximum =
            target_trait.precision < source_trait.precision
    else
        needs_maximum =
            target_trait.precision < source_trait.precision
    end
    if needs_maximum then
        checks[#checks + 1] = render(
            "(($SOURCE) <= (($SOURCE_CT)($MAXIMUM)))", {
                SOURCE = source,
                SOURCE_CT = source_ct,
                MAXIMUM = coder._integer_maximum_expression(target_trait),
            })
    end
    assert(#checks > 0,
        "non-containing integer ranges produced no runtime checks")
    return "(" .. table.concat(checks, " && ") .. ")"
end

function coder._float_integer_capacity(trait)
    assert(trait and trait.kind == "float"
           and trait.maximum_exponent and trait.radix,
        "integer-to-floating lowering lacks target radix/exponent metadata")
    local radix = trait.radix
    local radix_binary_exponent = 0
    while radix >= 2 do
        radix = math.floor(radix / 2)
        radix_binary_exponent = radix_binary_exponent + 1
    end
    assert(radix_binary_exponent > 0)
    -- C's maximum finite value is at least radix^(maximum_exponent - 1).
    -- This lower bound is deliberately conservative for non-binary targets.
    return radix_binary_exponent * (trait.maximum_exponent - 1)
end

-- Generate the non-raising acceptance half of one native numeric conversion.
-- The source expression must already be stable. The returned setup statements
-- run before the predicate; callers cast/store only after it succeeds.
function coder._code_native_numeric_predicate(
        ctx, source_type, target_type, source, mode)
    assert(coder._is_numeric_type(source_type)
           and coder._is_numeric_type(target_type),
        "numeric predicate received a non-numeric type")
    local source_res = coder._resolve_cast_type(source_type)
    local target_res = coder._resolve_cast_type(target_type)
    local source_trait =
        coder._numeric_trait(source_type, target_type, source_type)
    local target_trait =
        coder._numeric_trait(source_type, target_type, target_type)

    if source_trait.kind == "integer"
       and target_trait.kind == "integer" then
        if mode == "c_operator"
           or (mode == "explicit_c"
               and source_res._tag == "Type.CInteger"
               and target_res._tag == "Type.CInteger") then
            return "", "1"
        end
        return "", coder._integer_range_predicate(
            source_type, target_type, source, source_trait, target_trait)
    elseif source_trait.kind == "float"
           and target_trait.kind == "float" then
        if target_trait.rank >= source_trait.rank then
            return "", "1"
        end
        assert(target_trait.maximum_macro,
            "narrow C floating target lacks its <float.h> maximum")
        return "", render([[
            (isfinite((long double)($SOURCE))
                && fabsl((long double)($SOURCE))
                    <= (long double)($MAXIMUM))
        ]], {
            SOURCE = source,
            MAXIMUM = target_trait.maximum_macro,
        })
    elseif source_trait.kind == "integer"
           and target_trait.kind == "float" then
        if source_trait.precision <=
           coder._float_integer_capacity(target_trait) then
            return "", "1"
        end
        local long_double = coder._numeric_carriers(
            source_type, target_type).long_double
        assert(source_trait.precision <=
               coder._float_integer_capacity(long_double),
            "integer source is wider than the target profile's long double")
        assert(target_trait.maximum_macro,
            "C floating target lacks its <float.h> maximum")
        return "", render([[
            (fabsl((long double)($SOURCE))
                <= (long double)($MAXIMUM))
        ]], {
            SOURCE = source,
            MAXIMUM = target_trait.maximum_macro,
        })
    elseif source_trait.kind == "float"
           and target_trait.kind == "integer" then
        assert(ctx, "float-to-integer acceptance needs a lowering context")
        local truncated =
            fresh_lowering_name(ctx, "_titan_numeric_truncated_")
        local magnitude = render(
            "ldexpl(1.0L, $PRECISION)", {
                PRECISION = c_integer_literal(target_trait.precision),
            })
        local lower = target_trait.signed
            and "(-(" .. magnitude .. "))" or "0.0L"
        return render([[
            long double $TRUNCATED =
                truncl((long double)($SOURCE));
        ]], {
            TRUNCATED = truncated,
            SOURCE = source,
        }), render([[
            (isfinite((long double)($SOURCE))
                && $TRUNCATED >= $LOWER
                && $TRUNCATED < $UPPER)
        ]], {
            SOURCE = source,
            TRUNCATED = truncated,
            LOWER = lower,
            UPPER = magnitude,
        })
    end
    error("unknown numeric conversion category")
end

coder._numeric_coercion_ops = {
    ["Type.Integer:Type.Float"] = "integer_to_float",
    ["Type.Float:Type.Integer"] = "float_to_integer",
    ["Type.CInteger:Type.Integer"] = "c_integer_to_integer",
    ["Type.Integer:Type.CInteger"] = "integer_to_c_integer",
    ["Type.CFloat:Type.Float"] = "c_float_to_float",
    ["Type.Float:Type.CFloat"] = "float_to_c_float",
    ["Type.Integer:Type.CFloat"] = "integer_to_c_float",
}

-- Central authority check for scalar coercion lowering. Tag-driven dispatch is
-- not permission: every automatic/written coercion must carry the exact
-- checker-owned source/target/op decision.
function coder._checked_numeric_coercion(plan, source_type, target_type, use)
    assert(plan, (use or "numeric coercion") .. " lacks its checker plan")
    assert(plan.kind == "coercion",
        (use or "numeric coercion") .. " has unknown plan kind "
            .. tostring(plan.kind))
    local source = assert(types.normalize(source_type))
    local target = assert(types.normalize(target_type))
    assert(plan.source and plan.target
           and types.equals(plan.source, source)
           and types.equals(plan.target, target),
        (use or "numeric coercion")
            .. " plan does not match its operand types")
    local key = source._tag .. ":" .. target._tag
    local expected = coder._numeric_coercion_ops[key]
    assert(expected and plan.op == expected,
        (use or "numeric coercion")
            .. " has unknown/mismatched operation " .. tostring(plan.op))
    return plan
end

function coder._checked_explicit_numeric_conversion(
        conversion, source_type, target_type, use)
    assert(conversion,
        (use or "explicit C numeric conversion") .. " lacks its checker plan")
    assert(conversion.kind == "explicit_conversion"
           and conversion.op == "c_numeric",
        (use or "explicit C numeric conversion")
            .. " has unknown plan operation " .. tostring(conversion.op))
    local source = assert(types.normalize(source_type))
    local target = assert(types.normalize(target_type))
    assert(conversion.source and conversion.target
           and types.equals(conversion.source, source)
           and types.equals(conversion.target, target)
           and coder._is_c_numeric_type(source)
           and coder._is_c_numeric_type(target),
        (use or "explicit C numeric conversion")
            .. " plan does not match its operand types")
    return conversion
end

function coder._numeric_range_throw(loc, source_type, target_type)
    return codethrow(loc,
        "%s:%d:%d: type error, numeric value is outside the range of %s",
        {
            c_string_literal(loc.filename),
            c_integer_literal(loc.line),
            c_integer_literal(loc.col),
            c_string_literal(types.tostring(target_type)),
        })
end

-- Checked native-to-native scalar conversion. Integer-to-integer explicit C
-- casts retain C semantics; every other potentially unsafe crossing validates
-- representability before the cast and before any destination mutation.
function coder._code_checked_numeric_cast(
        ctx, source_type, target_type, source, loc, mode)
    -- A function may return a const-qualified C typedef. Capture it in its
    -- declaration so universal foreign-call materialization does not require
    -- a later assignment to a read-only temporary.
    local csource, source_name = newtmp(ctx, source_type, false, source)
    local ctarget, target_name = newtmp(ctx, target_type)
    local predicate_stats, predicate =
        coder._code_native_numeric_predicate(
            ctx, source_type, target_type, source_name, mode)
    local target_trait =
        coder._numeric_trait(source_type, target_type, target_type)
    return render([[
        $CSOURCE
        $PREDICATE_STATS
        if (TITAN_UNLIKELY(!($PREDICATE))) {
            $THROW
        }
        $CTARGET
        $TARGET_NAME = (($TARGET_CT)$SOURCE_NAME);
    ]], {
        CSOURCE = csource,
        SOURCE_NAME = source_name,
        PREDICATE_STATS = predicate_stats,
        PREDICATE = predicate,
        THROW = coder._numeric_range_throw(
            loc, source_type, target_type),
        CTARGET = ctarget,
        TARGET_NAME = target_name,
        TARGET_CT = coder._numeric_c_name(target_type, target_trait),
    }), target_name
end

function coder._code_boxed_numeric_predicate(
        ctx, target, source, strict)
    local resolved = coder._resolve_cast_type(target)
    local result_decl, result = newtmp(ctx, types.Boolean())
    local lines = { result_decl, result .. " = 0;" }

    local function branch(tag_predicate, source_type, get_value, prefix)
        local source_decl, source_name = newtmp(ctx, source_type)
        local predicate_stats, predicate =
            coder._code_native_numeric_predicate(
                ctx, source_type, target, source_name, "boundary")
        lines[#lines + 1] = render([[
            $PREFIX ($TAG_PREDICATE) {
                $SOURCE_DECL
                $SOURCE_NAME = $GET_VALUE;
                $PREDICATE_STATS
                $RESULT = $PREDICATE;
            }
        ]], {
            PREFIX = prefix,
            TAG_PREDICATE = tag_predicate,
            SOURCE_DECL = source_decl,
            SOURCE_NAME = source_name,
            GET_VALUE = get_value,
            PREDICATE_STATS = predicate_stats,
            RESULT = result,
            PREDICATE = predicate,
        })
    end

    if resolved._tag == "Type.CInteger" then
        branch("ttisinteger(" .. source .. ")", types.Integer(),
            "ivalue(" .. source .. ")", "if")
        if not strict then
            local value_decl, value = newtmp(ctx, types.Float())
            local integer_decl, integer = newtmp(ctx, types.Integer())
            local predicate_stats, predicate =
                coder._code_native_numeric_predicate(
                    ctx, types.Integer(), target, integer, "boundary")
            lines[#lines + 1] = render([[
                else if (ttisfloat($SOURCE)) {
                    $VALUE_DECL
                    $INTEGER_DECL
                    $VALUE = fltvalue($SOURCE);
                    if (isfinite($VALUE)
                        && truncl((long double)$VALUE)
                            == (long double)$VALUE
                        && lua_numbertointeger($VALUE, &$INTEGER)) {
                        $PREDICATE_STATS
                        $RESULT = $PREDICATE;
                    }
                }
            ]], {
                SOURCE = source,
                VALUE_DECL = value_decl,
                INTEGER_DECL = integer_decl,
                VALUE = value,
                INTEGER = integer,
                PREDICATE_STATS = predicate_stats,
                RESULT = result,
                PREDICATE = predicate,
            })
        end
    else
        branch("ttisfloat(" .. source .. ")", types.Float(),
            "fltvalue(" .. source .. ")", "if")
        if not strict then
            branch("ttisinteger(" .. source .. ")", types.Integer(),
                "ivalue(" .. source .. ")", "else if")
        end
    end
    return table.concat(lines, "\n"), result
end

function coder._code_checked_boxed_numeric(
        ctx, target, cvar, source, loc, strict)
    local predicate_stats, predicate =
        coder._code_boxed_numeric_predicate(
            ctx, target, source, strict)
    local resolved = coder._resolve_cast_type(target)
    local tag_name = resolved._tag == "Type.CInteger"
        and "C-integer" or "C-float"
    return render([[
        $PREDICATE_STATS
        if (TITAN_UNLIKELY(!($PREDICATE))) {
            $THROW
        }
        if (ttisinteger($SOURCE)) {
            $CVAR = (($CT)ivalue($SOURCE));
        } else {
            $CVAR = (($CT)fltvalue($SOURCE));
        }
    ]], {
        PREDICATE_STATS = predicate_stats,
        PREDICATE = predicate,
        SOURCE = source,
        CVAR = cvar,
        CT = coder._render_c_type_name(target),
        THROW = codethrow(loc,
            "%s:%d:%d: type error, expected representable %s but found %s",
            {
                c_string_literal(loc.filename),
                c_integer_literal(loc.line),
                c_integer_literal(loc.col),
                c_string_literal(tag_name),
                "lua_typename(L, ttype(" .. source .. "))",
            }),
    })
end

function coder._code_checked_numeric_setslot(typ, dst, src)
    local resolved = coder._resolve_cast_type(typ)
    local target = resolved._tag == "Type.CInteger"
        and types.Integer() or types.Float()
    local predicate_stats, predicate =
        coder._code_native_numeric_predicate(
            nil, typ, target, "_titan_numeric_box_source", "carrier")
    assert(predicate_stats == "",
        "C scalar carrier boxing unexpectedly needs predicate setup")
    local store = resolved._tag == "Type.CInteger"
        and "setivalue($DST, ((lua_Integer)_titan_numeric_box_source));"
        or "setfltvalue($DST, ((lua_Number)_titan_numeric_box_source));"
    return render([[
        do {
            $DECL = $SRC;
            if (TITAN_UNLIKELY(!($PREDICATE))) {
                luaL_error(L,
                    "type error, C scalar is outside its Titan carrier range");
            }
            $STORE
        } while (0);
    ]], {
        DECL = coder._render_c_declaration(
            typ, "_titan_numeric_box_source"),
        SRC = src,
        PREDICATE = predicate,
        STORE = render(store, { DST = dst }),
    })
end

-- Predicate twin of checkandget's value->integer/C-integer conversion.
function coder._code_boxed_is_integer(ctx, source)
    local cresult, result = newtmp(ctx, types.Boolean())
    local cvalue, value = newtmp(ctx, types.Float())
    local cfloor, floor = newtmp(ctx, types.Float())
    local cinteger, integer = newtmp(ctx, types.Integer())
    return render([[
        $CRESULT
        $CVALUE
        $CFLOOR
        $CINTEGER
        $RESULT = 0;
        if (ttisinteger($SOURCE)) {
            $RESULT = 1;
        } else if (ttisfloat($SOURCE)) {
            $VALUE = fltvalue($SOURCE);
            $FLOOR = l_floor($VALUE);
            $RESULT = ($VALUE == $FLOOR
                && lua_numbertointeger($FLOOR, &$INTEGER));
        }
    ]], {
        CRESULT = cresult,
        RESULT = result,
        CVALUE = cvalue,
        VALUE = value,
        CFLOOR = cfloor,
        FLOOR = floor,
        CINTEGER = cinteger,
        INTEGER = integer,
        SOURCE = source,
    }), result
end

-- Return setup statements and a C boolean expression for the non-raising form
-- of one checker-owned DynamicCoercionPlan.  This is the predicate twin of
-- `dynamiccheckandget`: in particular Option recurses through the embedded
-- plan, so a present `boolean?` uses truthiness just like `boolean`.
function coder._code_dynamic_predicate(ctx, plan, target, source)
    plan = coder._checked_dynamic_plan(plan, target, "written value is")
    if plan == false then return "", "0" end
    local resolved = coder._resolve_cast_type(target)
    local op = plan.op

    if op == "integer" then
        return coder._code_boxed_is_integer(ctx, source)
    elseif op == "c_integer" or op == "c_float" then
        return coder._code_boxed_numeric_predicate(
            ctx, target, source, false)
    elseif op == "float" then
        return "", render("(ttisfloat($SOURCE) || ttisinteger($SOURCE))", {
            SOURCE = source,
        })
    elseif op == "truthiness" or op == "value"
           or op == "callable" or op == "c_tvalue" then
        return "", "1"
    elseif op == "c_owned" then
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable ==
                    hvalue(&_mod->uv[$META].uv))
        ]], {
            SOURCE = source,
            META = c_integer_literal(owned_c_metatable(ctx, resolved)),
        })
    elseif op == "array" then
        return "", render([[
            ((ttistable($SOURCE)
                && titan_array_try_proxy(hvalue($SOURCE), $META) != NULL)
             || titan_array_try_backing($SOURCE, $META) != NULL)
        ]], {
            SOURCE = source,
            META = array_metatable(ctx),
        })
    elseif op == "nil" then
        return "", render("ttisnil($SOURCE)", { SOURCE = source })
    elseif op == "string" then
        return "", render("ttisstring($SOURCE)", { SOURCE = source })
    elseif op == "map" then
        return "", render("ttistable($SOURCE)", { SOURCE = source })
    elseif op == "nominal" then
        assert(resolved._tag == "Type.Nominal",
            "current nominal dynamic lowering requires a nominal value type")
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable == $META)
        ]], {
            SOURCE = source,
            META = render("hvalue(&_mod->uv[$INDEX].uv)", {
                INDEX = c_integer_literal(type2metatable(ctx, resolved)),
            }),
        })
    elseif op == "option" then
        local basestats, baseexp =
            coder._code_dynamic_predicate(
                ctx, plan.inner, resolved.base, source)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CRESULT
            if (ttisnil($SOURCE)) {
                $RESULT = 1;
            } else {
                $BASESTATS
                $RESULT = $BASEEXP;
            }
        ]], {
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
            BASESTATS = basestats,
            BASEEXP = baseexp,
        }), result
    end

    error("unknown dynamic predicate operation " .. tostring(op))
end

-- Non-raising twin of `_strictcheckandget` for a checker-owned GuardPlan.
-- Written tests between gradual Option views need to inspect the immediate
-- present payload without accidentally applying the broader Lua conversion
-- policy. Arrays, Maps, and callables retain deferred component checks; their
-- outer representation test is all that this predicate observes.
function coder._code_strict_predicate(ctx, plan, target, source)
    plan = coder._checked_gradual_guard(
        plan, target, "written gradual type test")
    if plan == false then return "", "0" end

    local resolved = coder._resolve_cast_type(target)
    local op = plan.op
    if op == "integer" then
        return "", render("ttisinteger($SOURCE)", { SOURCE = source })
    elseif op == "c_integer" or op == "c_float" then
        return coder._code_boxed_numeric_predicate(
            ctx, target, source, true)
    elseif op == "float" then
        return "", render("ttisfloat($SOURCE)", { SOURCE = source })
    elseif op == "boolean" then
        return "", render("ttisboolean($SOURCE)", { SOURCE = source })
    elseif op == "nil" then
        return "", render("ttisnil($SOURCE)", { SOURCE = source })
    elseif op == "string" then
        return "", render("ttisstring($SOURCE)", { SOURCE = source })
    elseif op == "value" or op == "callable"
           or op == "c_tvalue" then
        return "", "1"
    elseif op == "array" then
        return "", render([[
            ((ttistable($SOURCE)
                && titan_array_try_proxy(hvalue($SOURCE), $META) != NULL)
             || titan_array_try_backing($SOURCE, $META) != NULL)
        ]], {
            SOURCE = source,
            META = array_metatable(ctx),
        })
    elseif op == "map" then
        return "", render("ttistable($SOURCE)", { SOURCE = source })
    elseif op == "nominal" then
        assert(resolved._tag == "Type.Nominal",
            "strict nominal predicate requires a nominal value type")
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable == $META)
        ]], {
            SOURCE = source,
            META = render("hvalue(&_mod->uv[$INDEX].uv)", {
                INDEX = c_integer_literal(type2metatable(ctx, resolved)),
            }),
        })
    elseif op == "c_owned" then
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable ==
                    hvalue(&_mod->uv[$META].uv))
        ]], {
            SOURCE = source,
            META = c_integer_literal(owned_c_metatable(ctx, resolved)),
        })
    elseif op == "option" then
        local innerstats, innerexp = coder._code_strict_predicate(
            ctx, plan.inner, resolved.base, source)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CRESULT
            if (ttisnil($SOURCE)) {
                $RESULT = 1;
            } else {
                $INNERSTATS
                $RESULT = $INNEREXP;
            }
        ]], {
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
            INNERSTATS = innerstats,
            INNEREXP = innerexp,
        }), result
    end

    error("unknown strict predicate operation " .. tostring(op))
end

-- Non-raising twin of a checker-owned direct CoercionPlan. Most direct
-- coercions are total; the numeric narrowing and recursive Option operations
-- below are the cases whose corresponding `as` can reject the already
-- evaluated operand. The recursive helper consumes the exact stored inner
-- plan rather than asking the relation again.
function coder._code_coercion_predicate(
        ctx, coercion, source_type, target_type, source)
    coercion = coder._checked_coercion_plan(
        coercion, source_type, target_type,
        "written coercion type test")
    if coercion.kind == "identity" then return "", "1" end

    local op = coercion.op
    if coder._numeric_coercion_ops[
            assert(types.normalize(source_type))._tag .. ":"
            .. assert(types.normalize(target_type))._tag] then
        coder._checked_numeric_coercion(
            coercion, source_type, target_type,
            "written numeric coercion type test")
    end
    if op == "c_enum_integer" then
        assert(types.is_c_enum_integer_conversion(source_type, target_type),
            "C enum/integer predicate has mismatched types")
        return render("(void)($SOURCE);", { SOURCE = source }), "1"
    elseif op == "float_to_integer" then
        local cvalue, value = newtmp(ctx, types.Float())
        local cfloor, floor = newtmp(ctx, types.Float())
        local cinteger, integer = newtmp(ctx, types.Integer())
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CVALUE
            $CFLOOR
            $CINTEGER
            $CRESULT
            $VALUE = $SOURCE;
            $FLOOR = l_floor($VALUE);
            $RESULT = ($VALUE == $FLOOR
                && lua_numbertointeger($FLOOR, &$INTEGER));
        ]], {
            CVALUE = cvalue,
            VALUE = value,
            CFLOOR = cfloor,
            FLOOR = floor,
            CINTEGER = cinteger,
            INTEGER = integer,
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
        }), result
    elseif op == "integer_to_float" then
        return render("(void)($SOURCE);", { SOURCE = source }), "1"
    elseif op == "c_integer_to_integer"
           or op == "integer_to_c_integer"
           or op == "c_float_to_float"
           or op == "float_to_c_float"
           or op == "integer_to_c_float" then
        return coder._code_native_numeric_predicate(
            ctx, source_type, target_type, source, "boundary")
    elseif op == "value_to_c_value" then
        assert(source_type._tag == "Type.Value",
            "value-to-C predicate has a non-value source")
        return coder._code_strict_predicate(
            ctx, assert(coercion.guard,
                "value-to-C predicate lacks its strict guard"),
            target_type, "&" .. source)
    elseif op == "option_nil" then
        return "", "1"
    elseif op == "option_wrap" then
        return coder._code_coercion_predicate(
            ctx, coercion.inner, source_type, target_type.base, source)
    elseif op == "option_force" or op == "option_map" then
        local source_base = source_type.base
        local inner_target = op == "option_map"
            and target_type.base or target_type
        local cbase, basename =
            newtmp(ctx, source_base, types.is_gc(source_base))
        local innerstats, innerexp = coder._code_coercion_predicate(
            ctx, coercion.inner, source_base, inner_target, basename)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CBASE
            $CRESULT
            if (ttisnil(&$SOURCE)) {
                $RESULT = $NILRESULT;
            } else {
            $GETBASE;
                $INNERSTATS
                $RESULT = $INNEREXP;
            }
        ]], {
            CBASE = cbase,
            CRESULT = cresult,
            SOURCE = source,
            RESULT = result,
            NILRESULT = op == "option_map" and "1" or "0",
            GETBASE = getslot(source_base, basename, "&" .. source),
            INNERSTATS = innerstats,
            INNEREXP = innerexp,
        }), result
    end

    -- Truthiness, widening, boxing, admitted pointer conversions, and whole
    -- C-TValue copies cannot reject an already evaluated value. Checked C
    -- scalar representability operations are handled here by their dedicated
    -- branches once classified with the same CoercionPlan.
    return render("(void)($SOURCE);", { SOURCE = source }), "1"
end

function coder._codeis(ctx, node)
    if node._interface_downcast then
        return coder._code_interface_downcast(ctx, node, true)
    elseif node._interface_test then
        local test = node._interface_test
        local conversion = assert(test.conversion)
        assert(test.kind == "interface_implementation_test"
               and test.allocation_free == true
               and conversion.kind == "interface_conversion"
               and not conversion.source_optional
               and not conversion.target_optional,
            "malformed allocation-free Interface implementation test")
        local concrete = assert(conversion.concrete)
        local interface = assert(conversion.interface)
        assert((concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
               and interface._tag == "Type.Interface"
               and types.validate_interface_descriptor(interface)
               and #conversion.methods == #interface.methods,
            "malformed allocation-free Interface implementation mapping")
        local all_exact = true
        for index, mapping in ipairs(conversion.methods) do
            local required = interface.methods[index]
            assert(mapping.index == index - 1
                   and mapping.required == required
                   and mapping.name == required.name
                   and mapping.concrete
                   and mapping.concrete._tag == "Type.Method"
                   and mapping.concrete.fqtn == concrete.name
                   and mapping.source
                   and mapping.target
                   and types.equals(
                       mapping.source,
                       types.method_function_type(mapping.concrete))
                   and types.equals(
                       mapping.target,
                       types.method_function_type(required))
                   and mapping.exact == types.equals(
                       mapping.source, mapping.target),
                "malformed allocation-free Interface mapping at slot "
                    .. tostring(index - 1))
            all_exact = all_exact and mapping.exact
            if mapping.exact then
                assert(mapping.slot_kind == "exact"
                       and mapping.interface_adapter == nil,
                    "malformed exact Interface implementation mapping")
            else
                assert(mapping.slot_kind == "adapter"
                       and mapping.interface_adapter,
                    "adjusted Interface implementation test lacks its plan")
                coder._validate_interface_adapter(
                    mapping.interface_adapter,
                    concrete, interface, mapping,
                    "allocation-free Interface test slot "
                        .. tostring(index - 1))
            end
        end
        assert(conversion.exact == all_exact,
            "allocation-free Interface test has wrong exactness")
        local stats, source = materialize(ctx, node.exp)
        return stats .. "\n(void)(" .. source .. ");", "1"
    end

    -- Freeze the operand before inspecting it. This both enforces exactly-once
    -- evaluation and roots GC values while metatable/Array checks run.
    local original_source_type = node.exp._type
    coder._checked_written_cast_plan(
        node._written_cast, original_source_type, node.target,
        "written type test")
    local source_type = coder._resolve_cast_type(node.exp._type)
    local target_type = coder._resolve_cast_type(node.target)
    local stats, source
    if source_type._tag == "Type.CStruct"
       or source_type._tag == "Type.CUnion" then
        -- Generic temporaries use scalar initialization, which is not valid
        -- for a by-value C aggregate. Preserve the ordinary assignment-based
        -- aggregate materialization used by other expression consumers.
        stats, source = coder._materialize_c_aggregate(ctx, node.exp)
    else
        stats, source = materialize(ctx, node.exp)
    end
    local predicate_stats, predicate

    if source_type._tag == "Type.Value" then
        local cast = assert(node._written_cast,
            "value type test is missing its checker written-cast plan")
        if cast.op == "identity" then
            predicate_stats = render("(void)($SOURCE);", { SOURCE = source })
            predicate = "1"
        elseif cast.op == "dynamic" then
            predicate_stats, predicate =
                coder._code_dynamic_predicate(
                    ctx, assert(cast.dynamic,
                        "dynamic written cast lacks its embedded plan"),
                    node.target, "&" .. source)
        elseif cast.op == "explicit"
               and cast.conversion
               and cast.conversion.op == "unsafe_dynamic_c_pointer" then
            predicate_stats = ""
            local category = types.is_c_udata_pointer(node.target)
                and "ttisfulluserdata" or "ttislightuserdata"
            predicate = render(
                "($CATEGORY($SOURCE) || ttisnil($SOURCE))", {
                    CATEGORY = category,
                    SOURCE = "&" .. source,
                })
        else
            error("unknown value type-test plan operation "
                .. tostring(cast.op))
        end
    elseif node._written_cast
           and node._written_cast.op == "coercion" then
        predicate_stats, predicate = coder._code_coercion_predicate(
            ctx, assert(node._written_cast.coercion),
            original_source_type, node.target, source)
    elseif node._written_cast
           and node._written_cast.op == "explicit"
           and node._written_cast.conversion
           and node._written_cast.conversion.op == "c_numeric" then
        coder._checked_explicit_numeric_conversion(
            node._written_cast.conversion,
            original_source_type, node.target,
            "written C numeric type test")
        predicate_stats, predicate =
            coder._code_native_numeric_predicate(
                ctx, original_source_type, node.target,
                source, "explicit_c")
    elseif node._written_cast
           and node._written_cast.op == "gradual"
           and source_type._tag == "Type.Option"
           and target_type._tag == "Type.Option" then
        -- Option has no separate component-bearing backing. A written gradual
        -- test therefore observes its present payload now, with strict
        -- consistency guards rather than Lua-boundary coercions. Structural
        -- Array/Map/callable tests remain total at this outer view edge.
        predicate_stats, predicate = coder._code_strict_predicate(
            ctx, node._written_cast.guard, node.target, "&" .. source)
    elseif original_source_type._tag == "Type.Option"
           and types.equals(original_source_type.base, node.target) then
        predicate = render("!ttisnil(&$SOURCE)", { SOURCE = source })
        predicate_stats = ""
    elseif node._written_cast
           and node._written_cast.op == "explicit"
           and node._written_cast.conversion
           and node._written_cast.conversion.op ==
               "gc_identity_to_void_pointer"
           and source_type._tag == "Type.Function" then
        -- Function values deliberately defer callability checks until call
        -- time, so their boxed TValue is not necessarily collectable.  The
        -- explicit void-pointer cast can expose an identity only when there is
        -- an underlying GC object.
        predicate = render("iscollectable(&$SOURCE)", { SOURCE = source })
        predicate_stats = ""
    elseif (source_type._tag == "Type.CPointer"
            or source_type._tag == "Type.Pointer")
           and target_type._tag == "Type.String" then
        predicate = render("($SOURCE != NULL)", { SOURCE = source })
        predicate_stats = ""
    else
        -- Identity, boxing, truthiness, numeric widening, C numeric/pointer
        -- conversions, and every other admitted explicit cast are total.
        predicate_stats = render("(void)($SOURCE);", { SOURCE = source })
        predicate = "1"
    end

    return stats .. "\n" .. predicate_stats, predicate
end

-- Generate native call arguments in source order. A pure trailing suffix may
-- remain as direct C expressions: with no intervening statements, reordering
-- those reads is unobservable. Every argument at or before effectful setup is
-- frozen in a C temporary at its source position. Native arguments never gain
-- tracing-only Lua-stack copies; this helper preserves evaluation order only.
local function expression_contains_call(node)
    local tag = node._tag
    if tag == "Ast.ExpCall" then
        return true
    elseif tag == "Ast.ExpCast" or tag == "Ast.ExpIs"
           or tag == "Ast.ExpUnop"
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
        -- Calls are effectful even when their generated setup is empty.
        local has_stats = coded[i].stats ~= "" or coded[i].contains_call
        freeze[i] = has_stats or later_has_stats
        later_has_stats = later_has_stats or has_stats
    end

    local stats, exps = {}, {}
    for i = 1, n do
        local c = coded[i]
        if freeze[i] then
            local cstats, cexp =
                coder._freeze_code(ctx, c.typ, c.stats, c.exp)
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
        local mstats, mexp = coder._freeze_code(ctx, args[index]._type,
            cstats, cexp)
        table.insert(stats, mstats)
        exps[index] = mexp
    end
    for index, arg in ipairs(args) do
        if not seen[index] then
            assert(arg._named_omitted,
                "named call order omitted an explicit argument")
            local cstats, cexp = codeexp(ctx, arg)
            local mstats, mexp = coder._freeze_code(ctx, arg._type,
                cstats, cexp)
            table.insert(stats, mstats)
            exps[index] = mexp
        end
    end
    return stats, exps
end

local function newforeigntmp(ctx --[[:table]], typ --[[:table]],
                             initializer --[[:string?]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local fdecl
    local finit = ""
    local rtyp = types.resolve_c_typedef(typ)
    if typ._tag == "Type.String" then
        fdecl = "char* " .. tmpname
        finit = " = NULL"
    elseif typ._tag == "Type.Pointer" or types.is_direct_c(typ) then
        fdecl = coder._render_c_declaration(typ, tmpname)
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
    if initializer then
        finit = " = " .. initializer
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
    elseif tag == "Ast.StatCase" then
        for _, arm in ipairs(node.arms) do
            if stat_contains_try(arm.block) then return true end
        end
        return stat_contains_try(node.elseblock)
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
                        _foridx = luai_numadd(L, _foridx, _forstep);
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

local function code_owned_payload(owner, pointee)
    return render("(($CT)getudatamem($OWNER))", {
        CT = coder._render_c_type_name(types.CPointer(pointee, {})),
        OWNER = owner,
    })
end

function coder._prepared_c_null_check(var, base)
    local message
    local args
    if var._tag == "Ast.VarDot" then
        message = "%s:%d:%d: cannot access field '%s' of a NULL C pointer"
        args = {
            c_string_literal(var.loc.filename),
            c_integer_literal(var.loc.line),
            c_integer_literal(var.loc.col),
            c_string_literal(var.name),
        }
    else
        message = "%s:%d:%d: cannot index a NULL C pointer"
        args = {
            c_string_literal(var.loc.filename),
            c_integer_literal(var.loc.line),
            c_integer_literal(var.loc.col),
        }
    end
    return render([[
        if (TITAN_UNLIKELY($BASE == NULL)) {
            $THROW
        }
    ]], {
        BASE = base,
        THROW = codethrow(var.loc, message, args),
    })
end

function coder._prepared_c_bounds_check(var, index, length)
    return render([[
        if (TITAN_UNLIKELY($INDEX < 0 || $INDEX >= $LENGTH)) {
            luaL_error(L,
                "%s:%d:%d: C index %I out of range [0, %d)",
                $FILE, $LINE, $COL, (l_uacInt)$INDEX, (int)$LENGTH);
        }
    ]], {
        INDEX = index,
        LENGTH = length,
        FILE = c_string_literal(var.loc.filename),
        LINE = c_integer_literal(var.loc.line),
        COL = c_integer_literal(var.loc.col),
    }, true)
end

function coder._materialize_c_aggregate(ctx, exp)
    local stats, value = codeexp(ctx, exp)
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local name = "_tmp_" .. tmp
    return render([[
        $STATS
        $DECLARATION;
        $NAME = $VALUE;
    ]], {
        STATS = stats,
        DECLARATION = coder._render_c_declaration(exp._type, name),
        NAME = name,
        VALUE = value,
    }), name
end

-- Prepare an addressable C subobject without copying it. The top-level target
-- defers its own NULL/range validation until the store; any field/index step
-- needed to obtain that target's base is an ordinary LHS read, so its checks
-- execute during preparation. COwned roots remain in scanned slots across the
-- RHS. Aggregate and array subobjects retain a stable access path assembled
-- only from already-frozen roots and indices. This is equivalent to retaining
-- their address but does not require naming an anonymous C struct/union (or an
-- array whose element is one), which C99 cannot express in a declarator.
function coder._is_nested_c_storage(exp)
    if exp._tag ~= "Ast.ExpVar" then return false end
    local var = exp.var
    if var._tag == "Ast.VarDot" then
        return var._decl and var._decl._tag == "Type.CField"
            and types.is_direct_c(var.exp._type)
    elseif var._tag == "Ast.VarBracket" then
        return types.is_direct_c(var.exp1._type)
    end
    return false
end

function coder._prepare_c_loaded_value(ctx, exp)
    if coder._is_nested_c_storage(exp) then
        -- This path reads a pointer value needed as the final target's base.
        -- A by-value aggregate may therefore be copied to a temporary long
        -- enough to read that pointer; unlike a final aggregate mutation, no
        -- persistent address for the by-value object itself is required.
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, true)
        return materialize_code(ctx, exp._type, stats, storage)
    end
    return materialize(ctx, exp)
end

function coder._prepare_c_base(ctx, exp, allow_temporary)
    local basetype = types.resolve_c_typedef(exp._type)
    if exp._c_fam_access then
        local access = exp._c_fam_access
        if access.kind == "owned" then
            local owner_node = assert(exp.var).exp
            local stats, owner = materialize(ctx, owner_node)
            local owner_type = types.resolve_c_typedef(owner_node._type)
            local payload = coder._render_c_declaration(
                owner_type.pointee, "")
            return stats, {
                type = basetype,
                base = "((" .. payload .. " *)getudatamem("
                    .. owner .. "))->" .. access.field.name,
                length = "ivalue(&" .. owner .. "->uv[0].uv)",
                indirect = false,
            }
        end
        local stats, storage = coder._prepare_c_storage(
            ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            length = c_integer_literal(access.count),
            indirect = false,
        }
    end
    if basetype._tag == "Type.CPointer" then
        local stats, pointer = coder._prepare_c_loaded_value(ctx, exp)
        return stats, {
            type = basetype,
            base = pointer,
            indirect = true,
        }
    elseif basetype._tag == "Type.COwned" then
        local stats, owner = materialize(ctx, exp)
        local length = basetype.count and render(
            "((lua_Integer)($OWNER->len / sizeof($TYPE)))", {
                OWNER = owner,
                TYPE = coder._render_c_declaration(
                    basetype.pointee, ""),
            }) or nil
        return stats, {
            type = basetype,
            base = code_owned_payload(owner, basetype.pointee),
            length = length,
            indirect = true,
        }
    elseif basetype._tag == "Type.CArray" then
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            length = c_integer_literal(basetype.len),
            indirect = false,
        }
    elseif basetype._tag == "Type.CStruct"
           or basetype._tag == "Type.CUnion" then
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            indirect = false,
        }
    end
    error("invalid prepared C base " .. types.tostring(exp._type))
end

function coder._prepared_c_field(base, name)
    if base.indirect then
        return render("($BASE)->$FIELD", {
            BASE = base.base,
            FIELD = name,
        })
    end
    return render("($BASE).$FIELD", {
        BASE = base.base,
        FIELD = name,
    })
end

function coder._prepare_c_storage(ctx, exp, allow_temporary)
    if exp._tag ~= "Ast.ExpVar" then
        local basetype = types.resolve_c_typedef(exp._type)
        if allow_temporary
           and (basetype._tag == "Type.CStruct"
                or basetype._tag == "Type.CUnion") then
            return coder._materialize_c_aggregate(ctx, exp)
        end
        error("C assignment receiver has no persistent storage")
    end
    local var = exp.var
    if var._tag == "Ast.VarDot"
       and var._decl
       and var._decl._tag == "Type.CField"
       and types.is_direct_c(var.exp._type) then
        local stats, base =
            coder._prepare_c_base(ctx, var.exp, allow_temporary)
        local check = base.type._tag == "Type.CPointer"
            and coder._prepared_c_null_check(var, base.base) or ""
        return render([[
            $STATS
            $CHECK
        ]], {
            STATS = stats,
            CHECK = check,
        }), coder._prepared_c_field(base, var.name)
    elseif var._tag == "Ast.VarBracket"
           and types.is_direct_c(var.exp1._type) then
        local stats, base =
            coder._prepare_c_base(ctx, var.exp1, allow_temporary)
        local indexstats, index = materialize(ctx, var.exp2)
        local checks = {}
        if base.type._tag == "Type.CPointer" then
            table.insert(checks,
                coder._prepared_c_null_check(var, base.base))
        elseif base.length then
            table.insert(checks,
                coder._prepared_c_bounds_check(
                    var, index, base.length))
        end
        return render([[
            $STATS
            $INDEXSTATS
            $CHECKS
        ]], {
            STATS = stats,
            INDEXSTATS = indexstats,
            CHECKS = table.concat(checks, "\n"),
        }), render("$BASE[$INDEX]", {
            BASE = base.base,
            INDEX = index,
        })
    end
    return codeexp(ctx, exp)
end

local function codeassignment(ctx, var, cexp, etype, lvalue)
    local vtag = var._tag
    if vtag == "Ast.VarName" or (vtag == "Ast.VarDot" and var._decl) then
        if vtag == "Ast.VarDot" and var._decl._tag == "Type.Field" then
            local lstats, lexp
            if lvalue then
                lstats, lexp = "", assert(lvalue.record)
            else
                lstats, lexp = codeexp(ctx, var.exp)
            end
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
            local spill = spill_update(coder._lvalue_root_decl(var))
            if lvalue and lvalue.cfield_base then
                local base = {
                    type = assert(lvalue.cfield_type),
                    base = lvalue.cfield_base,
                    indirect = lvalue.cfield_indirect,
                }
                local check = base.type._tag == "Type.CPointer"
                    and coder._prepared_c_null_check(
                        var, base.base) or ""
                local field =
                    coder._prepared_c_field(base, var._decl.name)
                return render([[
                    $CHECK
                    $FIELD = $CEXP;
                    $SPILL
                ]], {
                    CHECK = check,
                    FIELD = field,
                    CEXP = cexp,
                    SPILL = spill,
                })
            end
            local lstats, lexp
            if lvalue then
                lstats, lexp = "", assert(lvalue.cfield)
            else
                lstats, lexp = codecfield(ctx, var)
            end
            return render([[
                $STATS
                $FIELD = $CEXP;
                $SPILL
            ]], {
                STATS = lstats,
                FIELD = lexp,
                CEXP = cexp,
                SPILL = spill,
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
            local castats, caexp, cistats, ciexp
            if lvalue then
                castats, caexp = "", assert(lvalue.array)
                cistats, ciexp = "", assert(lvalue.index)
            else
                castats, caexp = codeexp(ctx, arr)
                cistats, ciexp = codeexp(ctx, idx)
            end
            -- A resize can collect and relocate the Lua stack. Root both the
            -- backing and RHS only on that slow path, save `_base` by offset,
            -- then reload both values after the helper restores lenhint.
            ctx.uses_base_off = true
            local arrroot = slotat(reserveslot(ctx))
            local valroot = slotat(reserveslot(ctx))
            local barrier = types.is_gc(arr._type.elem)
                and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            return render([[
                {
                    $CASTATS
                    $CISTATS
                    Table *_t = $CAEXP;
                    lua_Integer _k = $CIEXP;
                    TValue _vv = {0};
                    $SETVV
                    if (TITAN_UNLIKELY(_k < 1)) {
                        $BADINDEX
                    }
                    lua_Unsigned _actual_i = l_castS2U(_k) - 1u;
                    unsigned _asize = _t->asize;
                    if (_actual_i < _asize) {
                        unsigned _length = cast_uint(titan_array_length(_t));
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                        $BARRIER
                        if (ttisnil(&_vv)) {
                            if (l_castS2U(_k) == _length) {
                                while (_length > 0 &&
                                       tagisempty(*getArrTag(_t, _length - 1u)))
                                    _length--;
                                titan_array_set_length(_t, _length);
                            }
                        } else if (l_castS2U(_k) > _length) {
                            titan_array_set_length(_t, l_castS2U(_k));
                        }
                    } else if (!ttisnil(&_vv)) {
                        sethvalue(L, $ARRROOT, _t);
                        setobj2t(L, $VALROOT, &_vv);
                        unsigned _newasize =
                            titan_array_growth(L, l_castS2U(_k));
                        titan_array_resize(L, _t, _newasize);
                        _base = restorestack(L, _base_off);
                        _t = hvalue($ARRROOT);
                        setobj(L, &_vv, $VALROOT);
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                        $BARRIER
                        titan_array_set_length(_t, l_castS2U(_k));
                    }
                }
            ]], {
                CASTATS = castats,
                CISTATS = cistats,
                CAEXP = caexp,
                CIEXP = ciexp,
                SETVV = setslot(etype, "&_vv", cexp),
                ARRROOT = arrroot,
                VALROOT = valroot,
                BARRIER = barrier,
                BADINDEX = codethrow(var.loc,
                    "%s:%d:%d: array index must be positive",
                    { c_string_literal(var.loc.filename),
                      c_integer_literal(var.loc.line),
                      c_integer_literal(var.loc.col) }),
            })
        elseif exp1type == "Type.Map" then
            local map = var.exp1
            local key = var.exp2
            local cmstats, cmexp, keyprep, tmpkslot
            if lvalue then
                cmstats, cmexp = "", assert(lvalue.map)
                keyprep, tmpkslot = "", assert(lvalue.keyslot)
            else
                cmstats, cmexp = codeexp(ctx, map)
                local ckstats, ckexp = codeexp(ctx, key)
                local ctmpk, tmpkname
                ctmpk, tmpkname, tmpkslot =
                    newtmp(ctx, key._type, true)
                keyprep = render([[
                    $CKSTATS
                    $CTMPK
                    $TMPKNAME = $CKEXP;
                    $SETSLOTK
                ]], {
                    CKSTATS = ckstats,
                    CTMPK = ctmpk,
                    TMPKNAME = tmpkname,
                    CKEXP = ckexp,
                    SETSLOTK =
                        setboxed(ctx, key._type, tmpkslot, tmpkname),
                })
            end

            return render([[
                {
                    $CMSTATS
                    Table *_t = $CMEXP;
                    $KEYPREP

                    TValue _vv;
                    $SETVV
                    $STORE
                    $BARRIER
                }
            ]], {
                CMSTATS = cmstats,
                CMEXP = cmexp,
                KEYPREP = keyprep,
                SETVV = setboxed(ctx, etype, "&_vv", cexp),
                STORE = set_table_entry(key._type, "_t", tmpkslot, "&_vv"),
                BARRIER = types.is_gc(map._type.values)
                          and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            })
        elseif types.is_direct_c(var.exp1._type) then
            local spill = spill_update(coder._lvalue_root_decl(var))
            local parts, indexprep
            if lvalue then
                local basetype = assert(lvalue.cbase_type)
                local baseexp = assert(lvalue.cbase)
                local checks = {}
                if basetype._tag == "Type.CPointer" then
                    table.insert(checks,
                        coder._prepared_c_null_check(var, baseexp))
                else
                    table.insert(checks, coder._prepared_c_bounds_check(
                        var, assert(lvalue.cindex),
                        assert(lvalue.clength)))
                end
                parts = {
                    bstats = "",
                    idxname = assert(lvalue.cindex),
                    baseexp = baseexp,
                }
                indexprep = table.concat(checks, "\n")
            else
                parts = codecindex_parts(ctx, var)
                indexprep = render([[
                    $ISTATS
                    $CIDX
                    $IDX = $IEXP;
                    $BOUNDS
                ]], {
                    ISTATS = parts.istats,
                    CIDX = parts.cidx,
                    IDX = parts.idxname,
                    IEXP = parts.iexp,
                    BOUNDS = parts.bounds,
                })
            end
            return render([[
                {
                    $BSTATS
                    $INDEXPREP
                    $BASE[$IDX] = $CEXP;
                    $SPILL
                }
            ]], {
                BSTATS = parts.bstats,
                INDEXPREP = indexprep,
                IDX = parts.idxname,
                BASE = parts.baseexp,
                CEXP = cexp,
                SPILL = spill,
            })
        end
    else
        error("invalid tag for lvalue of assignment: " .. vtag)
    end
end

-- Lua evaluates an indexed assignment's container and key before its RHS.
-- Materialize the Array lvalue explicitly so the backing stays in a scanned
-- root while the index and RHS run, then let codeassignment perform only the
-- mutation.  (The backing is non-moving, but it may otherwise be reachable
-- solely through a transient C local returned by a call.)
function coder._materialize_array_lvalue(ctx, var)
    local castats, caexp = codeexp(ctx, var.exp1)
    local cta, taname, taslot = newtmp(ctx, var.exp1._type, true)
    local cistats, ciexp = codeexp(ctx, var.exp2)
    local cti, tiname = newtmp(ctx, var.exp2._type)
    return render([[
        $CASTATS
        $CTA
        $TANAME = $CAEXP;
        $ANCHOR
        $CISTATS
        $CTI
        $TINAME = $CIEXP;
    ]], {
        CASTATS = castats,
        CTA = cta,
        TANAME = taname,
        CAEXP = caexp,
        ANCHOR = setslot(var.exp1._type, taslot, taname),
        CISTATS = cistats,
        CTI = cti,
        TINAME = tiname,
        CIEXP = ciexp,
    }), {
        array = taname,
        index = tiname,
    }
end

-- Every assignment freezes its effectful target operands before evaluating
-- the RHS. Multiple assignment applies the same preparation in lexical LHS
-- order across target kinds, so an Array target cannot leapfrog a preceding
-- record, Map, or C target. The returned descriptor retains GC owners/keys in
-- scanned slots; codeassignment performs only final-target validation and
-- mutation.
function coder._materialize_assignment_lvalue(ctx, var)
    if var._tag == "Ast.VarDot" and var._decl then
        if var._decl._tag == "Type.Field" then
            local stats, name = materialize(ctx, var.exp)
            return stats, { record = name }
        elseif var._decl._tag == "Type.CField" then
            local stats, base = coder._prepare_c_base(ctx, var.exp)
            return stats, {
                cfield_base = base.base,
                cfield_type = base.type,
                cfield_indirect = base.indirect,
            }
        end
        return "", nil
    elseif var._tag ~= "Ast.VarBracket" then
        return "", nil
    end

    local basetype = var.exp1._type
    if basetype._tag == "Type.Array" then
        return coder._materialize_array_lvalue(ctx, var)
    elseif basetype._tag == "Type.Map" then
        local mapstats, mapexp = codeexp(ctx, var.exp1)
        local mapdecl, mapname, mapslot =
            newtmp(ctx, basetype, true)
        local keystats, keyexp = codeexp(ctx, var.exp2)
        local keydecl, keyname, keyslot =
            newtmp(ctx, var.exp2._type, true)
        return render([[
            $MAPSTATS
            $MAPDECL
            $MAPNAME = $MAPEXP;
            $ANCHORMAP
            $KEYSTATS
            $KEYDECL
            $KEYNAME = $KEYEXP;
            $ANCHORKEY
        ]], {
            MAPSTATS = mapstats,
            MAPDECL = mapdecl,
            MAPNAME = mapname,
            MAPEXP = mapexp,
            ANCHORMAP = setslot(basetype, mapslot, mapname),
            KEYSTATS = keystats,
            KEYDECL = keydecl,
            KEYNAME = keyname,
            KEYEXP = keyexp,
            ANCHORKEY =
                setboxed(ctx, var.exp2._type, keyslot, keyname),
        }), {
            map = mapname,
            keyslot = keyslot,
        }
    elseif types.is_direct_c(basetype) then
        local basestats, base =
            coder._prepare_c_base(ctx, var.exp1)
        local indexstats, indexname = materialize(ctx, var.exp2)
        return basestats .. "\n" .. indexstats, {
            cbase = base.base,
            cbase_type = base.type,
            cindex = indexname,
            clength = base.length,
        }
    end
    error("invalid bracket lvalue type " .. types.tostring(basetype))
end

-- Evaluate a checker-adjusted finite expression list once in lexical order.
-- Values delivered to fixed sink slots use the supplied stabilizer; ordinary
-- sinks default to traced materialization, while native-call sites supply
-- `coder._freeze_code` so arguments remain C-only. Explicit surplus expressions are
-- forced for effect and never acquire a fake sink/output position.
function coder._codeadjustedfixed(ctx, node, stabilize)
    stabilize = stabilize or materialize_code
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
            if types.is_direct_c(exp._type)
               and not types.is_gc(exp._type) then
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
                mstats, name = stabilize(ctx, exp._type,
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
    local var = node.vars[1]
    local lvalue_stats, lvalue =
        coder._materialize_assignment_lvalue(ctx, var)
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    table.insert(stats, 1, lvalue_stats)
    table.insert(stats, codeassignment(ctx, var,
        assert(tmps[1]), assert(exptypes[1]), lvalue))
    return table.concat(stats, "\n")
end

local function codemultiassignment(ctx, node)
    local lvalue_stats = {}
    local lvalues = {}
    for i, var in ipairs(node.vars) do
        local stats, lvalue =
            coder._materialize_assignment_lvalue(ctx, var)
        if stats ~= "" then
            table.insert(lvalue_stats, stats)
        end
        lvalues[i] = lvalue
    end
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    table.insert(stats, 1, table.concat(lvalue_stats, "\n"))
    for i, var in ipairs(node.vars) do
        if tmps[i] then
            table.insert(stats,
                codeassignment(ctx, var, tmps[i], exptypes[i],
                    lvalues[i]))
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
    local direct_address_source = false
    local mutable_authority = false
    while source._tag == "Ast.ExpCast" and source.exp do
        local operand = source.exp
        local conversion = source._c_conversion
        if conversion and conversion.kind ==
           "address_then_unsafe_object_pointer" then
            direct_address_source = operand
            mutable_authority = true
        elseif is_addressable_local(operand)
           and source._adjustment
           and source._adjustment.kind == "direct_coercion"
           and source._adjustment.coercion
           and source._adjustment.coercion.op == "mutable_c_address" then
            -- Preserve the local root across an exact-address inner cast and
            -- an unrelated-pointer outer cast.
            direct_address_source = operand
            mutable_authority = true
        elseif is_addressable_local(operand)
           and source._written_cast then
            local written = coder._checked_written_cast_plan(
                source._written_cast, operand._type, source._type,
                "mutable C out-argument cast")
            local coercion = written.op == "coercion"
                and written.coercion or nil
            if coercion and coercion.op == "mutable_c_address" then
                direct_address_source = operand
                mutable_authority = true
            end
        end
        source = operand
    end

    source = direct_address_source or exp
    if not mutable_authority
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

local function nativetoforeignexp(ctx, exp, cexp, target, projection)
    local stype = coder._resolve_cast_type(exp._type)
    local ttype = target and coder._resolve_cast_type(target) or nil
    local coercion
    local conversion
    local has_projection_authority = false
    if projection and target then
        if projection._adjustment then
            coder._checked_adjustment_plan(
                projection._adjustment, exp._type, target,
                "native-to-foreign adjustment")
            has_projection_authority = true
            if projection._adjustment.kind == "direct_coercion" then
                coercion = projection._adjustment.coercion
            end
        elseif projection._written_cast then
            coder._checked_written_cast_plan(
                projection._written_cast, exp._type, target,
                "written native-to-foreign cast")
            has_projection_authority = true
            if projection._written_cast.op == "coercion" then
                coercion = projection._written_cast.coercion
            elseif projection._written_cast.op == "explicit" then
                conversion = projection._written_cast.conversion
            end
        elseif projection._c_conversion then
            conversion = coder._checked_explicit_conversion_plan(
                projection._c_conversion, exp._type, target,
                "checked native-to-foreign C conversion")
            has_projection_authority = true
        end
    end
    local operation = coercion and coercion.op
        or conversion and (conversion.op or conversion.kind)

    if operation == "c_enum_integer" then
        coder._checked_coercion_plan(
            coercion, exp._type, target,
            "native-to-C enum/integer coercion")
        return "", foreigncast(cexp, target)
    end

    if projection and target
       and coder._is_numeric_type(exp._type)
       and coder._is_numeric_type(target)
       and not types.equals(stype, ttype) then
        local mode = "boundary"
        if coercion then
            coder._checked_numeric_coercion(
                coercion,
                exp._type, target, "native-to-C numeric coercion")
        elseif conversion then
            coder._checked_explicit_numeric_conversion(
                conversion,
                exp._type, target, "written C numeric conversion")
            mode = "explicit_c"
        else
            error("native-to-C numeric conversion lacks checker authority")
        end
        return coder._code_checked_numeric_cast(
            ctx, exp._type, target, cexp, projection.loc, mode)
    end

    if operation == "mutable_c_address" then
        assert(is_addressable_local(exp),
            "mutable C-address plan has a non-addressable source")
        return "", render("(&($CEXP))", { CEXP = cexp })
    end

    if operation == "c_address" then
        if is_addressable_local(exp) then
            return "", render("(&($CEXP))", { CEXP = cexp })
        end
        return materialize_address_tmp(ctx, exp, cexp)
    end

    if operation == "c_automatic_to_owned"
       or operation == "c_automatic_array_to_owned" then
        local source_stats = ""
        local source_address
        local bytes
        local count = false
        local fam_plan
        if is_addressable_local(exp) then
            local allocation_plan = exp.var._decl._c_allocation_plan
            if allocation_plan
               and allocation_plan.storage == "automatic_fam" then
                fam_plan = allocation_plan
                local storage = assert(exp.var._decl._c_fam_storage)
                source_address = storage.address
                bytes = storage.bytes
                count = fam_plan.fam_count_literal
            end
        end
        if not source_address then
            if stype._tag == "Type.CArray" then
                source_address = cexp
                bytes = "sizeof(" .. cexp .. ")"
                count = stype.len
            else
                local source_decl, source_name =
                    newforeigntmp(ctx, exp._type, cexp)
                source_stats = source_decl
                source_address = "&" .. source_name
                bytes = "sizeof(" .. source_name .. ")"
            end
        end
        local owner_decl, owner, owner_slot = newtmp(ctx, target, true)
        local metadata = ""
        local nuvalues = 0
        if fam_plan then
            nuvalues = 1
            metadata = "setivalue(&" .. owner
                .. "->uv[0].uv, " .. c_integer_literal(count) .. ");"
        end
        return render([[
            $SOURCESTATS
            $OWNERDECL
            $OWNER = luaS_newudata(L, $BYTES, $NUVALUES);
            $OWNER->metatable = hvalue(&_mod->uv[$META].uv);
            $METADATA
            setuvalue(L, $OWNERSLOT, $OWNER);
            memcpy(getudatamem($OWNER), $SOURCE, $BYTES);
        ]], {
            SOURCESTATS = source_stats,
            OWNERDECL = owner_decl,
            OWNER = owner,
            BYTES = bytes,
            NUVALUES = c_integer_literal(nuvalues),
            META = c_integer_literal(owned_c_metatable(ctx, target)),
            METADATA = metadata,
            OWNERSLOT = owner_slot,
            SOURCE = source_address,
        }), owner
    end

    if operation == "c_function_pointer_to_void"
       or operation == "c_void_to_function_pointer" then
        return "", render("titan_cast_func($TARGET, $SOURCE)", {
            TARGET = coder._render_c_type_name(target),
            SOURCE = cexp,
        })
    end

    if operation == "gc_identity_to_void_pointer" then
        -- Freeze and anchor the native representation before any later call
        -- argument can collect it. Array/Map/record expressions already
        -- evaluate to their Table*/Udata* identity.
        local rootstats, source =
            materialize_code(ctx, exp._type, "", cexp)
        if stype._tag ~= "Type.Function" then
            return rootstats, source
        end

        -- Function values are boxed and may be immediate because callability
        -- is deliberately checked only when they are called.
        local cpointer, pointer = newtmp(ctx, target)
        return render([[
            $ROOTSTATS
            $CPOINTER
            if (TITAN_UNLIKELY(!iscollectable(&$SOURCE))) {
                $THROW
            }
            $POINTER = $CAST;
        ]], {
            ROOTSTATS = rootstats,
            CPOINTER = cpointer,
            SOURCE = source,
            POINTER = pointer,
            CAST = foreigncast(
                render("gcvalue(&$SOURCE)", { SOURCE = source }),
                target),
            FILE = c_string_literal(exp.loc.filename),
            LINE = c_integer_literal(exp.loc.line),
            COL = c_integer_literal(exp.loc.col),
            THROW = codethrow(
                exp.loc,
                "%s:%d:%d: type error, function value has no GC identity",
                { "$FILE", "$LINE", "$COL" }),
        }), pointer
    end

    if target and not types.equals(stype, ttype)
       and not has_projection_authority then
        error("native-to-foreign conversion lacks checker authority: "
            .. types.tostring(exp._type) .. " -> "
            .. types.tostring(target))
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
            SETTMP = setboxed(ctx, exp._type, "&" .. tmpname, cexp),
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

    if types.is_direct_c(exp._type) then
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
        assert(projection and projection._tag == "Ast.ExpCast",
            "boxed value to foreign target lacks its checker cast node")
        local texp, tmp = newforeigntmp(ctx, target)
        return render([[
            $TEXP
            $CHECKANDGET
        ]], {
            TEXP = texp,
            CHECKANDGET = coder._planned_value_projection_get(
                ctx, projection, tmp, "&" .. cexp),
        }), tmp
    end

    error("don't know how to handle type "..types.tostring(exp._type))
end

local function foreigntonativeexp(ctx, exp, cexp, target)
    local etype = types.resolve_c_typedef(exp._type)

    if etype._tag == "Type.Value" then
        return "", cexp
    elseif etype._tag == "Type.CInteger" then
        -- Keep the declaration's exact C carrier. A later explicit/implicit
        -- crossing to Titan integer, or boxing into a TValue slot, performs the
        -- checked range conversion. Prematurely narrowing here would lose the
        -- very value that the boundary must validate.
        return "", cexp
    elseif etype._tag == "Type.CFloat" then
        return "", cexp
    elseif etype._tag == "Type.CPointer" then
        return "", cexp
    elseif etype._tag == "Type.CFunction" then
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
    -- Foreign code can re-enter Lua or otherwise grow and relocate its stack.
    -- Materialize the result before recovering `_base`, then perform any
    -- post-call slot work only through the recovered pointer.
    ctx.uses_base_off = true
    local ret_res = types.resolve_c_typedef(ret)
    local post = table.concat(poststats, "\n")
    if ret_res._tag == "Type.CVoid" then
        return render([[
            $PRESTATS
            $CCALL;
            _base = restorestack(L, _base_off);
            $POST
        ]], {
            PRESTATS = prestats,
            CCALL = ccall,
            POST = post,
        }), "((void)0)"
    end

    local fdecl, fname = newforeigntmp(ctx, ret, ccall)
    return render([[
        $PRESTATS
        $FDECL
        _base = restorestack(L, _base_off);
        $POST
    ]], {
        PRESTATS = prestats,
        FDECL = fdecl,
        POST = post,
    }), fname
end

function coder._append_c_mutation_spills(node, poststats)
    for _, decl in ipairs(node._c_mutated_decls or {}) do
        local update = spill_update(decl)
        if update ~= "" then table.insert(poststats, update) end
    end
end

local function codeforeigncall(ctx, node)
    local cfuncname = coder._foreign_reference_name(
        assert(node._direct_foreign_reference,
            "direct foreign call lacks its checker reference"))
    local ftype = node.exp._type
    assert(ftype._tag == "Type.CFunction",
        "direct foreign call lost its C function declaration")
    local ret = ftype.ret
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
    -- A direct mutable-address argument may have changed the complete local
    -- object representation. Commit only after the C call returns normally;
    -- a C-side nonlocal exit must retain the last pre-call spill.
    coder._append_c_mutation_spills(node, poststats)
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
    coder._append_c_mutation_spills(node, poststats)
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
    if node._direct_foreign_reference then
        return true   -- foreign call, handled by codeforeigncall
    end
    local decl = var._decl
    return decl ~= nil and (decl._tag == "Ast.TopLevelFunc"
        or decl._tag == "Type.ModuleMember"
        or decl._tag == "Type.StaticMethod")
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
        -- C representation alone is not enough: Array and Map share Table*,
        -- while Option(Array), Option(Map), value, and Function share TValue.
        -- Only an equal semantic element type is representation-equivalent
        -- across this exact descriptor edge.
        local same_representation = types.equals(ef, eg)
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
            error("checker failed to materialize fixed arguments borrowed from '...'")
        end
        -- The logical projection can lie past an empty/short physical backing
        -- run. Clamp the descriptor start once and use that same physical view
        -- in both pass-through and fresh-copy cases; otherwise `#...` in the
        -- callee can become negative and CASE 3 can index beyond `args[]`.
        tail_start = render([[
            (((int)$SRC->n_args < ($LOGICAL))
                ? (int)$SRC->n_args : ($LOGICAL))
        ]], { SRC = va.cname, LOGICAL = tail_start })
        if same_representation and k <= m then
            -- CASE 1 (pass-through): static prefix exactly fills the callee fixed
            -- params, or the missing fixed params were borrowed above, and the
            -- element representation matches; pass the current backing struct and
            -- adjusted start unchanged. No allocation, no copy.
            table.insert(caexps, render("($STRUCT *)$NAME",
                { STRUCT = varg_struct_name(eg), NAME = va.cname }))
            table.insert(caexps, tail_start)
        else
            -- CASE 3 (fresh copy): k > m (the static prefix grows the tail) OR the
            -- element type differs and each element requires conversion (including
            -- same-C-representation callable views). Build a fresh Udata0 backing
            -- struct of element type eg
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
            -- Static-prefix expressions are stable C values whose fresh
            -- allocations/call results already own their ordinary roots. The raw
            -- TitanVargX payload borrows them and is never itself a root.
            local prefix_inits = {}
            for j, cexp in ipairs(vargexps) do
                table.insert(prefix_inits, render([[
                    $VNAME->args[$IDX] = $PEXP;
                ]], {
                    VNAME = vname,
                    IDX = c_integer_literal(j - 1),
                    PEXP = cexp,
                }))
            end
            -- Per-element conversion of the incoming `...` into the callee element
            -- type. The checker has proven ef/eg compatible, so this is the
            -- standard coercion: identical ctype -> raw copy; integer->value (and
            -- other gradual `value` widenings) -> setwrapped into a TValue;
            -- value->integer (and similar narrowings) -> checkandget runtime check.
            -- An allocating conversion receives a distinct destination slot for
            -- each element and publishes it only in the branch that actually
            -- creates the fresh object; an identity fallback remains C-only.
            local convbody
            if same_representation then
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
                local adjustment = assert(node._open_args
                        and node._open_args.adjustment,
                    "open variadic forwarding lacks checker adjustment")
                local result_root
                if coder._adjustment_allocates_gc(adjustment) then
                    local root_depth = ctx.depth
                    for _ = 1, 200 do reserveslot(ctx) end
                    result_root = "s2v(" .. stackslotat(root_depth)
                        .. " + " .. c_integer_literal(nprefix) .. " + _vj)"
                end
                local convstats, convexp =
                    coder._code_adjustment_value(
                        ctx, adjustment, ef, eg, src, node.loc,
                        node._open_args.callable_adapter, result_root)
                convbody = render([[
                    $CONVSTATS
                    $DST = $CONVEXP;
                ]], {
                    CONVSTATS = convstats,
                    DST = dst,
                    CONVEXP = convexp,
                })
            end
            table.insert(castats, render([[
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
            setnilvalue2s($ROOT + _rri);
        }
    ]], {
        COUNT = run.count,
        ROOT = stackslotat(run.root_depth),
    })
end

function coder._callable_adapter_site(tlcontext, adapter)
    coder._validate_callable_adapter_plan(
        adapter, adapter.source, adapter.target,
        "callable adapter registration", {})
    assert(not adapter.exact,
        "exact callable adjustment reached wrapper registration")
    local prior = tlcontext.callable_adapters[adapter]
    if prior then return prior end
    local index = tlcontext.callable_adapter_count
    tlcontext.callable_adapter_count = index + 1
    local stem = tlcontext.prefix
        .. "callable_adapter_" .. tostring(index)
    local site = {
        adapter = adapter,
        index = index,
        native = stem,
        strict = stem .. "_" .. TITAN_ENTRY_TAG .. "_strict",
    }
    tlcontext.callable_adapters[adapter] = site
    tlcontext.callable_adapter_list[#tlcontext.callable_adapter_list + 1] = site
    function_type_tag(tlcontext, adapter.source)
    function_type_tag(tlcontext, adapter.target)
    register_trace_name(tlcontext, site.native, adapter.trace_name)
    register_trace_name(tlcontext, site.strict, adapter.trace_name)
    return site
end

-- Construct the target callable view over one already available, already
-- rooted source value. Eligible exact-Titan sources get a fresh closure whose
-- upvalues are initialized directly while it is white, then published into one
-- traced result slot. Fallback values retain their original identity and need
-- no duplicate root.
function coder._emit_callable_adapter_value(
        ctx, adapter, raw, loc, use, result_root)
    use = use or "callable adapter construction"
    adapter = coder._validate_callable_adapter_plan(
        adapter, adapter.source, adapter.target, use, {})
    assert(not adapter.exact,
        use .. " unexpectedly constructs an exact callable view")
    local site = coder._callable_adapter_site(ctx.tlcontext, adapter)
    local source_decl, source_name = newtmp(ctx, adapter.source)
    local result_decl, result_name = newtmp(ctx, adapter.target)
    result_root = result_root or slotat(reserveslot(ctx))
    local location = adapter.location
    if loc then
        assert(type(loc) == "table" and loc.filename,
            use .. " lacks its owning source location")
    end
    local code = render([[
        $SOURCE_DECL
        $SOURCE_NAME = $RAW;
        $RESULT_DECL
        $RESULT_NAME = $SOURCE_NAME;
        {
            CClosure *_ca_source = ttisCclosure(&$SOURCE_NAME)
                ? clCvalue(&$SOURCE_NAME) : NULL;
            if (_ca_source != NULL
                    && _ca_source->nupvalues >= 5
                    && _ca_source->nupvalues < MAXUPVAL
                    && ttislightuserdata(&_ca_source->upvalue[1])
                    && pvalue(&_ca_source->upvalue[1]) == $SOURCE_TAG
                    && ttislightuserdata(&_ca_source->upvalue[3])
                    && pvalue(&_ca_source->upvalue[3])
                        == TITAN_FUNCTION_CLOSURE_BRAND) {
                int _ca_nup = (int)_ca_source->nupvalues;
                $LINE
                CClosure *_ca_wrapper =
                    luaF_newCclosure(L, _ca_nup + 1);
                _ca_wrapper->f = _ca_source->f;
                for (int _ca_i = 0; _ca_i < _ca_nup - 1; _ca_i++) {
                    if (_ca_i == 1) {
                        setpvalue(&_ca_wrapper->upvalue[_ca_i],
                            (void *)$TARGET_TAG);
                    } else if (_ca_i == 2) {
                        setpvalue(&_ca_wrapper->upvalue[_ca_i],
                            titan_cast_func(void *, $TARGET_ADAPTER));
                    } else {
                        setobj2n(L, &_ca_wrapper->upvalue[_ca_i],
                            &_ca_source->upvalue[_ca_i]);
                    }
                }
                setclCvalue(L,
                    &_ca_wrapper->upvalue[_ca_nup - 1], _ca_source);
                setfvalue(&_ca_wrapper->upvalue[_ca_nup], $TARGET_STRICT);
                lua_assert(iswhite(_ca_wrapper));
                setclCvalue(L, $RESULT_ROOT, _ca_wrapper);
                setclCvalue(L, &$RESULT_NAME, _ca_wrapper);
            }
        }
    ]], {
        SOURCE_DECL = source_decl,
        SOURCE_NAME = source_name,
        RAW = raw,
        RESULT_DECL = result_decl,
        RESULT_NAME = result_name,
        SOURCE_TAG = function_type_tag(
            ctx.tlcontext, adapter.source),
        TARGET_TAG = function_type_tag(
            ctx.tlcontext, adapter.target),
        TARGET_ADAPTER = site.native,
        TARGET_STRICT = site.strict,
        LINE = emitline({ loc = location }),
        RESULT_ROOT = result_root,
    })
    return code, result_name
end

-- Report whether a checker-frozen adjustment constructs a fresh GC object.
-- This is an ownership property only; it never rediscovers whether the edge is
-- semantically permitted.
function coder._adjustment_allocates_gc(adjustment)
    if adjustment.kind == "callable" then
        return adjustment.exact == false
    end
    if adjustment.interface_conversion then return true end
    local coercion = adjustment.coercion
    local function coercion_allocates(plan)
        if not plan or plan == false or plan.kind == "identity" then
            return false
        end
        if plan.op == "interface_wrapper" then return true end
        if plan.op == "option_map"
           or plan.op == "option_wrap"
           or plan.op == "option_force" then
            return coercion_allocates(plan.inner)
        end
        return false
    end
    return coercion_allocates(coercion)
end

-- Lower one checker-produced assignment adjustment over an already available
-- C expression. Identity, structural gradual views, and callable adjustments
-- preserve representation. Every representation-changing edge is reified as
-- an annotated cast carrying the exact checker plan; code generation never
-- reruns a type relation to rediscover permission.
function coder._code_adjustment_value(
        ctx, adjustment, source_type, target, raw, loc, adapter_alias,
        result_root)
    adjustment = coder._checked_adjustment_plan(
        adjustment, source_type, target, "value adjustment")
    if adjustment.kind == "identity" then
        assert(adapter_alias == nil or adapter_alias == false,
            "identity adjustment has an unexpected callable adapter")
        return "", raw
    elseif adjustment.kind == "callable" then
        if adjustment.exact then
            assert(adapter_alias == nil or adapter_alias == false,
                "exact callable adjustment has an unexpected adapter")
            return "", raw
        end
        local adapter = assert(adjustment._callable_adapter,
            "callable adjustment lacks its frozen adapter")
        assert(adapter_alias == nil or adapter_alias == adapter,
            "callable adjustment alias differs from its raw frozen adapter")
        coder._validate_callable_adapter_plan(
            adapter, source_type, target, "value callable adjustment", {})
        return coder._emit_callable_adapter_value(
            ctx, adapter, raw, loc, "value callable adjustment",
            result_root)
    end
    if adjustment.kind == "gradual_view"
       and adjustment.op == "structural" then
        -- Arrays, Maps, and callables retain a durable view whose component
        -- observations are guarded later. An Option has no separate mutable
        -- backing: its present payload is the immediate component observation.
        -- Guard it while the checker-owned view plan is still attached so a
        -- later identity option_force/option_map cannot forget the actual base
        -- type stored in this TValue.
        local asource = assert(adjustment.source)
        local atarget = assert(adjustment.target)
        if asource._tag ~= "Type.Option"
           or atarget._tag ~= "Type.Option" then
            return "", raw
        end
        assert(adjustment.guard
               and adjustment.guard.op == "option",
            "structural Option view lacks its strict guard plan")
        -- The successful guard neither allocates nor changes ownership. Keep
        -- both sides in C temporaries; the enclosing sink publishes any actual
        -- local/result/allocation home it requires.
        local csrc, srcname = newtmp(ctx, source_type, false)
        local cdst, dstname = newtmp(ctx, target, false)
        return render([[
            $CSRC
            $SRCNAME = $RAW;
            $CDST
            $CHECK
        ]], {
            CSRC = csrc,
            SRCNAME = srcname,
            RAW = raw,
            CDST = cdst,
            CHECK = coder._strictcheckandget(
                ctx, adjustment.guard, target, dstname, "&" .. srcname,
                loc, "structural Option view"),
        }), dstname
    end
    assert(adjustment.kind == "direct_coercion"
            or (adjustment.kind == "gradual_view"
                and (adjustment.op == "inject"
                     or adjustment.op == "project")),
        "unknown checker adjustment kind " .. tostring(adjustment.kind))

    local csrc, srcname = newtmp(ctx, source_type)
    local synthvar = {
        _tag = "Ast.VarName",
        _type = source_type,
        _decl = { _cvar = srcname },
    }
    local synthcast = {
        _tag = "Ast.ExpCast",
        loc = loc,
        exp = synthvar,
        target = target,
        _type = target,
        _implicit_coercion = true,
        _adjustment = adjustment,
        _interface_conversion = adjustment.interface_conversion,
        _allocation_result_root = result_root,
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

-- Read one typed run element and consume the open sink's stored adjustment.
-- The source run remains rooted for the whole sink operation, so the temporary
-- need not acquire another slot merely to bridge this copy.
function coder._convert_result_run_element(
        ctx, run, target, index, loc, result_root)
    local raw = run.args .. "[" .. run.start .. " + " .. index .. "]"
    coder._checked_adjustment_plan(
        run.adjustment, run.elem, target, "open result adjustment")
    if types.equals(run.elem, target) then
        assert(run.adjustment.kind == "identity",
            "equal open result elements lack an identity checker adjustment: "
                .. types.tostring(run.elem) .. " -> "
                .. types.tostring(target) .. " used "
                .. tostring(run.adjustment.kind))
        return "", raw
    end
    return coder._code_adjustment_value(
        ctx, run.adjustment, run.elem, target, raw, loc,
        run.callable_adapter, result_root)
end

-- Lower the sole open producer of an adjusted expression list. Input `...`
-- borrows its descriptor elements' existing traced provenance; a flexible call publishes a
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
function coder._codeadjustedopen(
        ctx, adjusted, want, effectively_open, stabilize)
    stabilize = stabilize or materialize_code
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
            local mstats, name = stabilize(
                ctx, exp._type, cs, ce)
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
    run.adjustment = assert(adjusted.open_adjustment,
        "open expression list lacks checker adjustment")
    run.callable_adapter = adjusted.open_callable_adapter or false
    if run.adjustment.kind == "callable" then
        assert(run.callable_adapter == run.adjustment._callable_adapter,
            "open callable adapter alias differs from its raw plan")
    else
        assert(run.callable_adapter == false,
            "non-callable open adjustment has a callable adapter alias")
    end
    return stats, fixednames, tailnames, run
end

-- Materialize an adjusted scalar-prefix + dynamic run as one input-variadic
-- descriptor. Native inputs remain C values; each open conversion that actually
-- allocates a fresh callable/Interface wrapper establishes that allocation's
-- immediate element-specific traced root. A conditional identity fallback does
-- not publish the source there. The descriptor backing is an untraced caller C
-- array.
function coder._emit_open_vararg_struct(ctx, node, callee_ftype, tailnames,
                                        run, stats, callargs)
    local elem = assert(callee_ftype.varargtype)
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_open_vargs_" .. suffix
    local descname = "_open_vargdesc_" .. suffix
    local countname = "_open_vargcount_" .. suffix
    local root_depth
    if coder._adjustment_allocates_gc(run.adjustment) then
        root_depth = ctx.depth
        for _ = 1, 200 do reserveslot(ctx) end
    end
    local runindex = c_integer_literal(#tailnames) .. " + _vai"
    local result_root = root_depth and ("s2v("
        .. stackslotat(root_depth) .. " + " .. runindex .. ")") or nil
    local convstats, convexp = coder._convert_result_run_element(
        ctx, run, elem, "_vai", node.loc, result_root)
    local prefixsets = {}
    for i, name in ipairs(tailnames) do
        local index = c_integer_literal(i - 1)
        table.insert(prefixsets, render([[
            $ARGS[$INDEX] = $VALUE;
        ]], {
            ARGS = argsname,
            INDEX = index,
            VALUE = name,
        }))
    end
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
-- function, or a `__call` object. An exact Titan tag takes the direct native
-- path; generic Titan and Lua-callable cases go through the Lua stack with
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

    -- 1. evaluate the callee once into a C temporary. The exact Titan branch
    -- receives it through the native convention; only the slow branches later
    -- publish it on the Lua stack as an actual Lua-convention argument.
    local fstat, fexp = codeexp(ctx, node.exp)
    local fdecl, fname = newtmp(ctx, ftype, false)
    table.insert(stats, fstat)
    table.insert(stats, fdecl)
    table.insert(stats, fname .. " = " .. fexp .. ";")

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

    -- 2. evaluate arguments into C temporaries. Fixed-param args (1..nfixed)
    --    use the callee's declared parameter type; surplus static args use the
    --    vararg element type and become native backing-struct elements. Slow
    --    branches later box these same values into their Lua argument slots.
    local argnames, argtypes = {}, {}   -- fixed-param args (both paths)
    local vargexps = {}                 -- surplus static-arg C exprs (struct + push)
    local inputrun, inputtail
    if callee_vararg and node._arg_adjustment
       and node._arg_adjustment.open_source then
        local astats, fixednames, tailnames, run = coder._codeadjustedopen(
            ctx, node._arg_adjustment, "LUA_MULTRET", "1", coder._freeze_code)
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
        }, coder._freeze_code)
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
                local adecl, aname = newtmp(ctx, atype, false)
                table.insert(stats, adecl)
                table.insert(stats, aname .. " = " .. aexp .. ";")
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
    -- Because the build and native call both live in the fast branch, a case-3
    -- fresh Udata0 is allocated and rooted only on that branch. The descriptor's
    -- native elements remain C arguments and receive no tracing-only copies.
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
    -- reach any captured upvalues (slots 4+).
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
    local argpushes = {}
    local pushfixed = callee_vararg and nfixed or npassed
    for i = 1, pushfixed do
        if argnames[i] then
            table.insert(argpushes,
                setboxed(ctx, argtypes[i], "s2v(L->top.p)", argnames[i])
                    .. " L->top.p++;")
        end
    end
    local npush_dynamic = ""
    if inputrun then
        npush_dynamic = " + " .. c_integer_literal(#inputtail)
            .. " + " .. inputrun.count
        table.insert(argpushes, render([[
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
            table.insert(argpushes,
                setboxed(ctx, callee_vararg, "s2v(L->top.p)", name)
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
        table.insert(argpushes, render([[
            for (int _vpj = 0; _vpj < $COUNT; _vpj++) {
                $PUSHSTATS
                $SETSLOT L->top.p++;
            }
        ]], {
            COUNT = inputrun.count,
            PUSHSTATS = pushstats,
            SETSLOT = setboxed(ctx,
                node._arg_adjustment.open_source._tag == "Ast.ExpDots"
                    and inputrun.elem or callee_vararg,
                "s2v(L->top.p)", pushexp),
        }))
    else
        for _, vexp in ipairs(vargexps) do
            table.insert(argpushes,
                setboxed(ctx, callee_vararg, "s2v(L->top.p)", vexp)
                    .. " L->top.p++;")
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
        table.insert(argpushes, render([[
            for (int _vpj = 0; _vpj < (int)$SRC->n_args - $START; _vpj++) {
                $SETSLOT L->top.p++;
            }
        ]], {
            SRC = va.cname,
            START = source_start,
            SETSLOT = setboxed(ctx, va.elem, "s2v(L->top.p)",
                render("$SRC->args[$START + _vpj]",
                    { SRC = va.cname, START = source_start })),
        }))
    end
    local lua_pushes = {
        "setobj2s(L, L->top.p, &" .. fname .. "); L->top.p++;",
    }
    local strict_pushes = {
        [[
        setobj2s(L, L->top.p,
            &_vc_callee->upvalue[_vc_callee->nupvalues - 1]);
        L->top.p++;]],
        "setobj2s(L, L->top.p, &" .. fname .. "); L->top.p++;",
    }
    for _, push in ipairs(argpushes) do
        table.insert(lua_pushes, push)
        table.insert(strict_pushes, push)
    end

    local function make_slowreads(strict)
        local reads = {}
        for i = 1, nresults do
            local source =
                "s2v(restorestack(L, _vc_func) + " .. (i - 1) .. ")"
            if strict then
                local plans = assert(node._strict_result_guard_plans,
                    "generic call lacks checker strict result guards")
                assert(plans[i] ~= nil,
                    "generic call result lacks its checker strict guard")
                table.insert(reads, coder._strictcheckandget(
                    ctx, plans[i], visible_types[i], visnames[i], source,
                    node.loc, "branded Titan callable result"))
            else
                local plans = assert(node._lua_result_dynamic_plans,
                    "generic call lacks checker dynamic result plans")
                assert(plans[i] ~= nil,
                    "generic call result lacks its checker dynamic plan")
                table.insert(reads, coder._dynamiccheckandget(
                    ctx, plans[i], visible_types[i], visnames[i], source,
                    node.loc, "non-Titan Lua callable result"))
            end
        end
        return table.concat(reads, "\n")
    end
    local lua_slowreads = make_slowreads(false)
    local strict_slowreads = make_slowreads(true)
    local slowcall = render([[
        luaD_callnoyield(L, restorestack(L, _vc_func), $NRESULTS);
    ]], { NRESULTS = c_integer_literal(nresults) })
    local slowpre, lua_slowopen, strict_slowopen = "", "", ""
    -- Reserve the generic branch's complete finite result area as well as the
    -- function and arguments. `luaD_callnoyield` is an internal primitive and
    -- therefore assumes its caller has satisfied the public API's
    -- `checkresults` capacity invariant; finite nil-padding may write every
    -- requested slot even when the callable returns nothing.
    local npushfixed = 2 + pushfixed
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
                setnilvalue2s(L->top.p);
                L->top.p++;
            }
        ]], { NVISIBLE = c_integer_literal(nresults) })
        local function make_slowopen(strict)
            local readone
            local source = "s2v(restorestack(L, _vc_func) + "
                .. c_integer_literal(abi_nresults) .. " + _vri)"
            if strict then
                assert(node._strict_open_result_guard_plan ~= nil,
                    "open generic call result lacks its checker strict guard")
                readone = coder._strictcheckandget(
                    ctx, node._strict_open_result_guard_plan,
                    flexrun.elem, flexrun.args .. "[_vri]",
                    source, node.loc,
                    "branded Titan callable flexible result")
            else
                assert(node._lua_open_result_dynamic_plan ~= nil,
                    "open generic call result lacks its checker dynamic plan")
                readone = coder._dynamiccheckandget(
                    ctx, node._lua_open_result_dynamic_plan, flexrun.elem,
                    flexrun.args .. "[_vri]", source, node.loc,
                    "non-Titan Lua callable flexible result")
            end
            return render([[
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
            READONE = readone,
            ANCHORRUN = coder._anchor_result_run(flexrun),
        })
        end
        lua_slowopen = make_slowopen(false)
        strict_slowopen = make_slowopen(true)
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
        {
        CClosure *_vc_callee =
            ttisCclosure(&$FNAME) ? clCvalue(&$FNAME) : NULL;
        if (TITAN_LIKELY(_vc_callee != NULL
                && _vc_callee->nupvalues >= 5
                && pvalueraw(valraw(&_vc_callee->upvalue[1]))
                    == $FUNCTAG)) {
            /* fast path: exact function-type match, unboxed native call */
            Udata *_vc_mod = uvalue(&_vc_callee->upvalue[0]);
            $FPTYPEDEF;
            $FPTYPE _vc_fp = titan_cast_func($FPTYPE,
                pvalue(&_vc_callee->upvalue[2]));
            $VARGSTATS
            $LINEDIR
            $FASTCALL
            $FASTPROJECTIONS
        } else {
            int _vc_is_titan =
                _vc_callee != NULL
                && _vc_callee->nupvalues >= 5
                && pvalueraw(valraw(&_vc_callee->upvalue[3]))
                    == TITAN_FUNCTION_CLOSURE_BRAND;
            if (_vc_is_titan) {
                /* Branded non-exact Titan closure: call its trailing strict
                   entry. The original closure is the hidden first VM argument
                   so the strict entry retains the owning module and captures. */
                titan_ensure_stack(L, $NPUSH);
                ptrdiff_t _vc_func = savestack(L, L->top.p);
                $STRICTPUSHES
                $LINEDIR
                $SLOWCALL
                $SLOWPRE
                $STRICTSLOWREADS
                $STRICTSLOWOPEN
                L->top.p = restorestack(L, _vc_func);
            } else {
                /* Genuine Lua/dynamic callable: dispatch through Lua with the
                   same already checker-adjusted arguments; only results
                   crossing back into typed Titan slots use the dynamic
                   boundary plan. */
                titan_ensure_stack(L, $NPUSH);
                ptrdiff_t _vc_func = savestack(L, L->top.p);
                $LUAPUSHES
                $LINEDIR
                $SLOWCALL
                $SLOWPRE
                $LUASLOWREADS
                $LUASLOWOPEN
                L->top.p = restorestack(L, _vc_func);
            }
        }
        _base = restorestack(L, _base_off);
        $ANCHORS
        $INPUTCLEANUP
        }
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
        STRICTPUSHES = table.concat(strict_pushes, "\n"),
        LUAPUSHES = table.concat(lua_pushes, "\n"),
        SLOWCALL = slowcall,
        SLOWPRE = slowpre,
        STRICTSLOWREADS = strict_slowreads,
        STRICTSLOWOPEN = strict_slowopen,
        LUASLOWREADS = lua_slowreads,
        LUASLOWOPEN = lua_slowopen,
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
            fname = func_name(ctx.module, fnode.name, fnode._decl.islocal)
        elseif fnode._tag == "Ast.VarDot" then
            if fnode.exp._type._tag == "Type.CModule" then
                return codeforeigncall(ctx, node)
            elseif fnode._decl._tag == "Type.StaticMethod" then
                fname = static_name(fnode._decl)
                local mod, record = fnode._decl.fqtn:match("^(.*)%.([^.]+)$")
                if mod ~= ctx.module then
                    ctx.functions[fnode._decl.fqtn .. "." .. fnode._decl.name] = {
                        module = mod,
                        record = record,
                        type = fnode._decl,
                        name = fnode._decl.name,
                        mangled = fname
                    }
                    if fnode._alias_namespace then
                        modarg = coder._nominal_owner_module_expr(
                            ctx, fnode._decl.fqtn)
                    else
                        assert(fnode.exp.var._tag == "Ast.VarDot")
                        modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                            INDEX = c_integer_literal(
                                fnode.exp.var.exp.var._decl._upvalue) -- whew!
                        })
                    end
                end
            else
                assert(fnode._decl._tag == "Type.ModuleMember")
                fname = func_name(
                    fnode._decl.modname, fnode.name, fnode._decl.islocal)
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
        if node._interface then
            local interface = node._interface
            local mtype = assert(node._interface_method)
            local index = assert(node._interface_method_index)
            local indexed = interface.methods[index + 1]
            assert(interface._tag == "Type.Interface"
                   and index >= 0
                   and indexed
                   and indexed.name == mtype.name
                   and types.equals(
                       types.method_function_type(indexed),
                       types.method_function_type(mtype)),
                "Interface call has a noncanonical method slot")
            local cstat, wrapper = coder._freeze(ctx, node.exp)
            local fptr = fresh_lowering_name(
                ctx, "_titan_interface_call_")
            table.insert(castats, cstat)
            table.insert(castats, render([[
                if (TITAN_UNLIKELY(
                        $WRAPPER->len % sizeof(TitanInterfaceMethod) != 0
                        || $WRAPPER->len / sizeof(TitanInterfaceMethod)
                            != $METHOD_COUNT)) {
                    luaL_error(L,
                        "malformed internal Interface wrapper for %s",
                        $IFACE);
                }
                TitanInterfaceMethod $STORED =
                    ((TitanInterfaceMethod *)getudatamem(
                        $WRAPPER))[$INDEX];
                if (TITAN_UNLIKELY(
                        $STORED == NULL)) {
                    luaL_error(L,
                        "uninitialized internal Interface method %s:%s",
                        $IFACE, $METHOD);
                }
                $FPTR_DECL = titan_cast_func(
                    $FPTR_TYPE,
                    $STORED);
            ]], {
                WRAPPER = wrapper,
                METHOD_COUNT = c_integer_literal(#interface.methods),
                IFACE = c_string_literal(interface.name),
                METHOD = c_string_literal(mtype.name),
                INDEX = c_integer_literal(index),
                STORED = fptr .. "_stored",
                FPTR_DECL = function_sig(fptr, mtype, true),
                FPTR_TYPE = function_sig("", mtype, true),
            }))
            fname = fptr
            table.insert(caexps,
                "uvalue(&" .. wrapper .. "->uv[0].uv)")
            table.insert(caexps, "NULL")
            table.insert(caexps,
                "uvalue(&" .. wrapper .. "->uv[1].uv)")
        else
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
            local cstat, cexp = coder._freeze(ctx, node.exp)
            table.insert(castats, cstat)
            table.insert(caexps, modarg)
            table.insert(caexps, "NULL")
            table.insert(caexps, cexp)
        end
    end
    -- The callee's static type, to detect a variadic callee and its fixed arity.
    -- ArgsMethod -> node._method; a static-method VarDot -> fnode._decl; otherwise
    -- the var's resolved Type.Function on fnode._type.
    local callee_ftype
    if node.args._tag == "Ast.ArgsMethod" then
        callee_ftype = node._interface_method or node._method
    elseif fnode._tag == "Ast.VarDot"
           and fnode._decl and fnode._decl._tag == "Type.StaticMethod" then
        callee_ftype = fnode._decl
    else
        callee_ftype = fnode._type
    end
    if callee_ftype and callee_ftype._tag == "Type.Function" then
        assert(callee_ftype.vararg == false,
            "Type.Function reserved vararg field must be false")
    end
    local callee_vararg = callee_ftype and callee_ftype.varargtype
    if node._named_arg_order then
        assert(callee_ftype)
        assert(not callee_vararg)
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
            ctx, node._arg_adjustment, "LUA_MULTRET", "1", coder._freeze_code)
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
        }, coder._freeze_code)
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
    -- callee. Its C payload borrows the already evaluated native values; only a
    -- case-3 backing allocation acquires a new traced root.
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
            table.insert(decls, render("$CT volatile $CVAR = $INIT;", {
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
            int volatile $COUNT = 0;
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
                setnilvalue2s($ROOT + _pa_clear_i);
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
        local name = "_pa_dret_" .. frame.id .. "_" .. i
        table.insert(lines, render("$DECL = $READ;", {
            DECL = cvardecl(ctx, from[i].typ, name),
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
        openrun.adjustment = assert(adjusted.open_adjustment,
            "open return expression lacks its checker adjustment")
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
            titan_ensure_stack(L, 2);
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
        titan_ensure_stack(L, 1);
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
        titan_ensure_stack(L, 2);
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
             * luaD_pcall's recovery: restore ci/allowhook, close any to-be-
             * closed vars from called Lua, materialize the error object. */
            L->ci = _oldci_$T;
            L->allowhook = _oldah_$T;
            /* A longjmp can skip an inner Titan Lua-entry wrapper before that
             * wrapper restores L->errfunc. Put the boundary-entry message
             * handler back before closing Lua frames, so any __close error is
             * handled by a valid Titan errorhandler instead of a stale stack
             * slot from the skipped inner entry. */
            L->errfunc = _olderrfunc_$T;
            _lj_$T.status = luaD_closeprotected(L, _oldtop_$T, _lj_$T.status);
            luaD_seterrorobj(L, _lj_$T.status, restorestack(L, _oldtop_$T));
            if (TITAN_UNLIKELY(!lua_checkstack(L, 4)))
                luaD_throw(L, LUA_ERRMEM);
            /* a value-call or another stack-growing operation inside the protected
             * region may have reallocated the stack; recompute _base before
             * touching any reserved slot */
            _base = restorestack(L, _base_off);
            /* save the error object into its anchored slot, then drop it from the
             * top; the registry snapshot/clear below pushes within the
             * lua_checkstack(4) margin established above. */
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
             * (a bare re-raise re-pins the saved trace) */
            lua_pushliteral(L, TITAN_BACKTRACE_KEY);
            lua_pushnil(L);
            lua_rawset(L, LUA_REGISTRYINDEX);
            lua_pushliteral(L, TITAN_TRACE_PINNED);
            lua_pushnil(L);
            lua_rawset(L, LUA_REGISTRYINDEX);
            /* re-establish the function's steady-state reserved top
             * (`_base + nslots`) so any reserved slots used in the recovery sit
             * below L->top.p and are GC-scanned. The literal nslots is patched in
             * by codefuncdec/codelambdadec once the high-water mark is known. */
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
             * would capture the PA_BREAK arm's `break`) */
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
                 * would capture the PA_BREAK arm's `break`) */
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
                        decl._defer_tail_predeclared = true
                        local plan = decl._c_allocation_plan
                        if plan and plan.storage:match("^automatic") then
                            local declaration =
                                coder._codeautomaticallocationdecl(ctx, decl)
                            if declaration ~= "" then
                                table.insert(out, declaration)
                            end
                            decl._c_allocation_predeclared = true
                            decl._defer_tail_spill_predeclared = true
                        else
                            decl._cvar = "_local_" .. localname(ctx, decl.name)
                            if decl._c_zero_init then
                                table.insert(out,
                                    cvardecl(ctx, decl._type, decl._cvar)
                                    .. " = {0};")
                                decl._c_zero_predeclared = true
                            else
                                table.insert(out,
                                    cvardecl(ctx, decl._type, decl._cvar) .. ";")
                            end
                            local spill = decl._c_zero_init
                                and spill_decl_init(ctx, decl)
                                or spill_decl_zero(ctx, decl)
                            if spill ~= "" then
                                decl._defer_tail_spill_predeclared = true
                                table.insert(out, spill)
                            end
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

function coder._codeautomaticallocationdecl(ctx, decl)
    local plan = assert(decl._c_allocation_plan)
    decl._boxed = false
    if decl._c_allocation_predeclared or not decl._used then return "" end
    local logical = localname(ctx, decl.name)
    local storage = plan.storage
    if storage == "automatic_object" or storage == "automatic_array" then
        decl._cvar = decl._cvar or ("_local_" .. logical)
        return render([[
            $CDECL = {0};
            $CSPILLDECL
        ]], {
            CDECL = cvardecl(ctx, decl._type, decl._cvar),
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    elseif storage == "automatic_array_borrow" then
        local count = assert(plan.array_count_literal)
        local backing = "_foreign_backing_" .. logical
        decl._cvar = decl._cvar or ("_local_" .. logical)
        local array_type = types.CArray(plan.payload_type, count)
        decl._c_backing_storage = {
            address = backing,
            bytes = "sizeof(" .. backing .. ")",
        }
        decl._spill_cvar = "_spill_foreign_backing_" .. logical
        return render([[
            $BACKING = {0};
            $POINTER;
            $POINTER = $BACKING_NAME;
            $CSPILLDECL
        ]], {
            BACKING = coder._render_c_declaration(array_type, backing),
            BACKING_NAME = backing,
            POINTER = coder._render_c_declaration(decl._type, decl._cvar),
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    elseif storage == "automatic_fam" then
        local field = assert(plan.fam_field)
        local array = types.resolve_c_typedef(field.type)
        assert(array._tag == "Type.CArray")
        local count = assert(plan.fam_count_literal)
        local union_name = "_foreign_fam_backing_" .. logical
        local pointer = "_foreign_fam_pointer_" .. logical
        local ctype_name = coder._render_c_declaration(plan.payload_type, "")
        local elem_name = coder._render_c_declaration(array.elem, "")
        local extent = render([[
            ((sizeof($CT) > (offsetof($CT, $FIELD) +
                ((size_t)$COUNT * sizeof($ELEM))))
                ? sizeof($CT)
                : (offsetof($CT, $FIELD) +
                    ((size_t)$COUNT * sizeof($ELEM))))
        ]], {
            CT = ctype_name,
            FIELD = field.name,
            COUNT = c_integer_literal(count),
            ELEM = elem_name,
        })
        decl._cvar = "(*" .. pointer .. ")"
        decl._c_fam_storage = {
            address = union_name .. ".bytes",
            bytes = "sizeof(" .. union_name .. ".bytes)",
        }
        decl._c_backing_storage = decl._c_fam_storage
        decl._spill_cvar = "_spill_foreign_fam_" .. logical
        return render([[
            union {
                $CT _align;
                unsigned char bytes[$EXTENT];
            } $UNION = {0};
            $CT *$POINTER = ($CT *)$UNION.bytes;
            $CSPILLDECL
        ]], {
            CT = ctype_name,
            EXTENT = extent,
            UNION = union_name,
            POINTER = pointer,
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    end
    error("unsupported automatic C allocation storage " .. tostring(storage))
end

-- Initialize one ordinary local declaration from an already materialized
-- native value. Case payload binders use this same path as source StatDecls so
-- capture boxes, GC roots, and setjmp spills remain one implementation.
function coder._codeinitializeddecl(ctx, decl, cstats, cexp)
    decl._boxed = decl._captured and decl._assigned
    if decl._boxed then
        -- Captured-and-mutated: storage is a heap box (Udata cell). Ordering
        -- avoids an unanchored-box window: freeze+anchor the value, allocate
        -- and anchor the box, then write it with the ordinary barrier.
        local typ = decl._type
        local isgc = types.is_gc(typ)
        local n = localname(ctx, decl.name)
        local ctmp, tmpname, tmpslot = newtmp(ctx, typ, isgc)
        decl._box = "_box_" .. n
        local boxslot = newslot(ctx)
        local anchortmp = tmpslot
            and setslot(typ, tmpslot, tmpname) or ""
        return render([[
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
        })
    elseif decl._used then
        local typ = decl._type
        if not decl._cvar then
            decl._cvar = "_local_" .. localname(ctx, decl.name)
        end
        local cdecl = decl._defer_tail_predeclared
            and "" or cvardecl(ctx, typ, decl._cvar) .. ";"
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
        return render([[
            $CDECL
            $CSPILLDECL
            $CSTATS
            $CVAR = $CEXP;
            $CSET
            $CSPILLSET
        ]], {
            CDECL = cdecl,
            CSPILLDECL = cspilldecl,
            CSTATS = cstats,
            CVAR = decl._cvar,
            CEXP = cexp,
            CSET = cset,
            CSPILLSET = cspillset,
        })
    end
    return render([[
        $CSTATS
        ((void)$CEXP);
    ]], {
        CSTATS = cstats,
        CEXP = cexp,
    })
end

-- Emit a tag-only switch whose arms live outside the switch. This preserves
-- Titan's enclosing-loop `break` semantics while allowing each arm to be an
-- ordinary full block (including catch/finally and lowered defers).
function coder._codecase(ctx, node)
    ctx.case_id = (ctx.case_id or 0) + 1
    local id = ctx.case_id
    local prefix = "_case_" .. id
    local endlabel = prefix .. "_end"
    local elselabel = prefix .. "_else"
    local scrutinee_stats, scrutinee =
        materialize(ctx, node.exp)
    local dispatch, bodies = {}, {}

    for i, arm in ipairs(node.arms) do
        local label = prefix .. "_arm_" .. (i - 1)
        table.insert(dispatch, render("case $TAG: goto $LABEL;", {
            TAG = c_integer_literal(arm._variant_index),
            LABEL = label,
        }))

        pushd(ctx)
        push_spillscope(ctx)
        local binding = ""
        if arm.binding then
            local payload = assert(arm._variant.payload)
            assert(payload ~= false,
                "empty union variant unexpectedly has a payload binder")
            binding = coder._codeinitializeddecl(ctx, arm.binding, "",
                getslot(payload, nil,
                    "&" .. scrutinee .. "->uv[1].uv"))
        end
        local block = codestat(ctx, arm.block)
        pop_spillscope(ctx)
        popd(ctx)

        table.insert(bodies, render([[
            $LABEL: {
                $BINDING
                $BLOCK
                goto $END;
            }
        ]], {
            LABEL = label,
            BINDING = binding,
            BLOCK = block,
            END = endlabel,
        }))
    end

    local elsebody = ""
    pushd(ctx)
    push_spillscope(ctx)
    if node.elseblock then
        elsebody = codestat(ctx, node.elseblock)
    end
    pop_spillscope(ctx)
    popd(ctx)
    table.insert(bodies, render([[
        $LABEL: {
            $BLOCK
            goto $END;
        }
    ]], {
        LABEL = elselabel,
        BLOCK = elsebody,
        END = endlabel,
    }))

    return render([[
        {
            $SCRUTINEE_STATS
            lua_Integer $TAGNAME = ivalue(&$SCRUTINEE->uv[0].uv);
            switch ($TAGNAME) {
                $DISPATCH
                default: goto $ELSE;
            }
            $BODIES
            $END: ;
        }
    ]], {
        SCRUTINEE_STATS = scrutinee_stats,
        TAGNAME = prefix .. "_tag",
        SCRUTINEE = scrutinee,
        DISPATCH = table.concat(dispatch, "\n"),
        ELSE = elselabel,
        BODIES = table.concat(bodies, "\n"),
        END = endlabel,
    })
end

local function codestat_dispatch(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatDecl" then
        if node._c_zero_init then
            local decl = assert(node.decls[1])
            assert(#node.decls == 1 and #node.exps == 0
                and decl._c_zero_init)
            -- Automatic C aggregates are direct C objects, never adjusted
            -- expression results or closure boxes. An unused object has no
            -- observable initialization, so it may follow the ordinary unused
            -- local elision rule.
            decl._boxed = false
            if not decl._used then return "" end
            if not decl._cvar then
                decl._cvar = "_local_" .. localname(ctx, decl.name)
            end
            if decl._c_zero_predeclared then
                return ""
            end
            return render([[
                $CDECL = {0};
                $CSPILLDECL
            ]], {
                CDECL = cvardecl(ctx, decl._type, decl._cvar),
                CSPILLDECL = spill_decl_init(ctx, decl),
            })
        end

        local has_automatic_allocation = false
        for _, decl in ipairs(node.decls) do
            if decl._c_allocation_plan
               and decl._c_allocation_plan.storage:match("^automatic") then
                has_automatic_allocation = true
                break
            end
        end
        if has_automatic_allocation then
            local code = {}
            local adjusted = assert(node._result_adjustment)
            for i, decl in ipairs(node.decls) do
                local plan = decl._c_allocation_plan
                if plan and plan.storage:match("^automatic") then
                    table.insert(code,
                        coder._codeautomaticallocationdecl(ctx, decl))
                else
                    local exp = assert(adjusted.fixed[i])
                    local cstats, cexp = codeexp(ctx, exp)
                    table.insert(code, coder._codeinitializeddecl(
                        ctx, decl, cstats, cexp))
                end
            end
            return table.concat(code, "\n")
        end

        local code, initnames = coder._codeadjustedfixed(ctx, node)
        for i = 1, #node.decls do
            local decl = node.decls[i]
            table.insert(code, coder._codeinitializeddecl(
                ctx, decl, "", assert(initnames[i])))
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
    elseif tag == "Ast.StatCase" then
        return coder._codecase(ctx, node)
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

codecindex_parts = function(ctx, node)
    if node._c_fam_access then
        local access = node._c_fam_access
        local istats, iexp = codeexp(ctx, node.exp2)
        local cidx, idxname = newtmp(ctx, types.Integer())
        local bstats, baseexp, lenexp
        if access.kind == "owned" then
            local owner_node = assert(node.exp1.var).exp
            local owner_stats, owner_exp = codeexp(ctx, owner_node)
            local owner_decl, owner_name = newtmp(ctx, owner_node._type)
            local owner_type = types.resolve_c_typedef(owner_node._type)
            local payload = coder._render_c_declaration(
                owner_type.pointee, "")
            bstats = render([[
                $STATS
                $DECL
                $OWNER = $EXP;
            ]], {
                STATS = owner_stats,
                DECL = owner_decl,
                OWNER = owner_name,
                EXP = owner_exp,
            })
            baseexp = "((" .. payload .. " *)getudatamem("
                .. owner_name .. "))->" .. access.field.name
            lenexp = "ivalue(&" .. owner_name .. "->uv[0].uv)"
        else
            bstats, baseexp = codeexp(ctx, node.exp1)
            lenexp = c_integer_literal(access.count)
        end
        local bounds = render([[
            if (TITAN_UNLIKELY($IDX < 0 || $IDX >= $LEN)) {
                luaL_error(L, "%s:%d:%d: C flexible-array index %I out of range [0, %d)", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
            }
        ]], {
            IDX = idxname,
            LEN = lenexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
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
            CT = coder._render_c_declaration(basetype.pointee, ""),
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
            local expression = render("$OP($CT)", {
                OP = op,
                CT = ctype(node._decl.ctype),
            })
            assert(node._decl.result_source,
                "C size pseudo-member lacks its checker-owned size_t type")
            return coder._code_checked_numeric_cast(
                ctx, node._decl.result_source, node._type,
                expression, node.loc, "boundary")
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
            -- Same-module nominal static: read its canonical closure directly.
            return "", getslot(node._type, nil, render("&_mod->uv[$SLOT].uv", {
                SLOT = c_integer_literal(
                    ctx.tlcontext.static_slots[node._decl.fqtn .. "." .. node._decl.name]),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and node._alias_namespace then
            -- A type alias preserves the nominal owner's static namespace; it
            -- does not manufacture a closure slot in the facade. Recover the
            -- initialized owner module from Titan's registry and index its
            -- ordinary ABI-visible static prefix.
            assert(node._decl._closure_upvalue ~= nil,
                "aliased public static lacks an owner prefix slot")
            local owner = coder._nominal_owner_module_expr(
                ctx, node._decl.fqtn)
            return "", getslot(node._type, nil, render(
                "&(($OWNER)->uv[$FNINDEX].uv)", {
                OWNER = owner,
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and node._import_decl then
            -- Imported nominal static: both modules reconstruct the ABI-visible
            -- canonical-closure prefix, so no namespace-table lookup or fresh
            -- closure is needed.
            return "", getslot(node._type, nil, render(
                "&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$FNINDEX].uv)", {
                MODINDEX = c_integer_literal(node._import_decl._upvalue),
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
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

-- Materialize the position stream shared by dense Array and positional
-- integer-Map constructors.  Values are evaluated and converted once in source
-- order before either representation is allocated.  Fixed positions are held
-- in scanned slots; a sole open producer remains as a typed result-run view
-- whose elements the representation-specific fill loop converts in order.
function coder._materialize_positional_inputs(ctx, node, elemtype)
    local stats, slots, discarded = {}, {}, {}
    local openrun
    local adjustment = assert(
        node._positional_adjustment or node._array_adjustment,
        "positional constructor lacks checker adjustment")
    for _, exp in ipairs(adjustment.discards) do
        discarded[exp] = true
    end

    local nfields = #node.fields
    local dots_tail = nfields > 0
        and node.fields[nfields].exp._tag == "Ast.ExpDots"
    local nprefix = dots_tail and nfields - 1 or nfields
    if adjustment.open_source then
        local astats, _, tailnames, run = coder._codeadjustedopen(
            ctx, adjustment, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for _, name in ipairs(tailnames) do
            local slot = slotat(reserveslot(ctx))
            table.insert(stats, setslot(elemtype, slot, name))
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
                local ctmpe, tmpename, tmpeslot =
                    newtmp(ctx, elemtype, true)
                table.insert(stats, render([[
                    $CSTATS
                    $CTMPE
                    $TMPENAME = $CEXP;
                    $SETSLOT
                ]], {
                    CSTATS = cstats,
                    CTMPE = ctmpe,
                    TMPENAME = tmpename,
                    CEXP = cexp,
                    SETSLOT = setslot(elemtype, tmpeslot, tmpename),
                }))
                table.insert(slots, tmpeslot)
            end
        end
    end
    return stats, slots, openrun
end

local function codearray(ctx, node, target)
    -- Always build the Array in a scanned stack slot. A target such as a
    -- module-global upvalue is not necessarily remembered until the caller's
    -- post-expression barrier, while constructor/open-run work can allocate.
    -- The caller copies this rooted result into its final owner afterward.
    local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    local inputstats, slots, openrun =
        coder._materialize_positional_inputs(ctx, node, node._type.elem)
    local stats = {}
    -- Keep the C temporary in the constructor's outer scope. Runtime-sized
    -- constructors perform allocation and filling in an inner block, but the
    -- expression result is consumed after that block.
    table.insert(stats, ctmp)
    for _, stat in ipairs(inputstats) do table.insert(stats, stat) end
    ctx.uses_base_off = true
    local elemtype = node._type.elem
    local writer_elem = assert(node._array_element_type,
        "Array construction lacks its normalized checker element type")
    assert(types.equals(writer_elem, types.normalize(elemtype)),
        "Array construction writer element disagrees with final Array type")
    local writer = coder._array_writer(
        ctx, writer_elem, node._array_writer_plan)
    local function initarray(capacity)
        return render([[
            $TMPNAME = titan_array_new(
                L, $META, $CAPACITY, &_mod->uv[$WRITER].uv);
            _base = restorestack(L, _base_off);
            sethvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
            META = array_metatable(ctx),
            CAPACITY = capacity,
            WRITER = c_integer_literal(writer.slot),
        })
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
        -- The per-element store consumes the checker's open adjustment. Equal
        -- types copy directly; every other accepted edge is lowered by the
        -- plan-aware conversion helper.
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, elemtype, "_vj", node.loc)
        local element_store = render([[
            $CONVSTATS
            $SETWRAPPED
        ]], {
            CONVSTATS = convstats,
            SETWRAPPED = setslot(elemtype, "&" .. vslot, convexp),
        })
        table.insert(stats, render([[
            {
                int _vacount = $RUNCOUNT;
                $INITARRAY
                $PREFIX_STORES
                /* zero-init: a boolean store sets only the tag (booleans carry
                 * no payload), but obj2arr copies value_ too — leaving it
                 * undefined would warn under -Wmaybe-uninitialized / break
                 * -Werror. */
                TValue $VSLOT = {0};
                for (int _vj = 0; _vj < _vacount; _vj++) {
                    $SETWRAPPED
                    obj2arr($TMPNAME, $NPREFIX + _vj, &$VSLOT);
                    $BARRIER
                }
                unsigned _array_length =
                    cast_uint($NPREFIX + _vacount);
                while (_array_length > 0 &&
                       tagisempty(*getArrTag($TMPNAME,
                                            _array_length - 1u)))
                    _array_length--;
                titan_array_set_length($TMPNAME, _array_length);
                $CLEANUP
            }
        ]], {
            RUNCOUNT = openrun.count,
            TMPNAME = tmpname,
            NPREFIX = c_integer_literal(nstored),
            INITARRAY = initarray(render([[
                ((lua_Unsigned)$NPREFIX + (lua_Unsigned)_vacount)
            ]], {
                NPREFIX = c_integer_literal(nstored),
            })),
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
    table.insert(stats, initarray(c_integer_literal(nstored)))
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
    table.insert(stats, render([[
        {
            unsigned _array_length = $SIZE;
            while (_array_length > 0 &&
                   tagisempty(*getArrTag($TMPNAME, _array_length - 1u)))
                _array_length--;
            titan_array_set_length($TMPNAME, _array_length);
        }
    ]], {
        SIZE = c_integer_literal(nstored),
        TMPNAME = tmpname,
    }))
    return table.concat(stats, "\n"), tmpname
end

function coder._codepositionalmap(ctx, node, target)
    local valuetype = node._type.values
    local inputstats, slots, openrun =
        coder._materialize_positional_inputs(ctx, node, valuetype)
    local ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end

    local stats = { ctmp }
    for _, stat in ipairs(inputstats) do table.insert(stats, stat) end
    ctx.uses_base_off = true

    local function initmap(count)
        return render([[
            if (TITAN_UNLIKELY((lua_Unsigned)($COUNT) >
                               (lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY)) {
                luaL_error(L, "positional map is too large");
            }
            $TMPNAME = luaH_new(L);
            _base = restorestack(L, _base_off);
            sethvalue(L, $TMPSLOT, $TMPNAME);
            luaH_resizearray(L, $TMPNAME, cast_uint($COUNT));
            _base = restorestack(L, _base_off);
        ]], {
            COUNT = count,
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
        })
    end

    local function fixedstores()
        local stores = {}
        for i, slot in ipairs(slots) do
            table.insert(stores, render([[
                {
                    TValue _map_value = {0};
                    $BOX
                    obj2arr($TMPNAME, $INDEX, &_map_value);
                    $BARRIER
                }
            ]], {
                BOX = setboxed(ctx, valuetype, "&_map_value",
                    getslot(valuetype, nil, slot)),
                TMPNAME = tmpname,
                INDEX = c_integer_literal(i - 1),
                BARRIER = types.is_gc(valuetype)
                    and render([[
                        luaC_barrierback(L, obj2gco($TMPNAME),
                                         &_map_value);
                    ]], { TMPNAME = tmpname })
                    or "",
            }))
        end
        return table.concat(stores, "\n")
    end

    if openrun then
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, valuetype, "_mi", node.loc)
        table.insert(stats, render([[
            {
                int _map_open_count = $RUNCOUNT;
                lua_Unsigned _map_count =
                    (lua_Unsigned)$NPREFIX +
                    (lua_Unsigned)_map_open_count;
                $INITMAP
                $FIXEDSTORES
                TValue _map_value = {0};
                for (int _mi = 0; _mi < _map_open_count; _mi++) {
                    $CONVSTATS
                    $BOX
                    obj2arr($TMPNAME, $NPREFIX + _mi, &_map_value);
                    $BARRIER
                }
                $CLEANUP
            }
        ]], {
            RUNCOUNT = openrun.count,
            NPREFIX = c_integer_literal(#slots),
            INITMAP = initmap("_map_count"),
            FIXEDSTORES = fixedstores(),
            CONVSTATS = convstats,
            BOX = setboxed(ctx, valuetype, "&_map_value", convexp),
            TMPNAME = tmpname,
            BARRIER = types.is_gc(valuetype)
                and render([[
                    luaC_barrierback(L, obj2gco($TMPNAME), &_map_value);
                ]], { TMPNAME = tmpname })
                or "",
            CLEANUP = coder._cleanup_result_run(openrun),
        }))
    else
        table.insert(stats, initmap(c_integer_literal(#slots)))
        table.insert(stats, fixedstores())
    end
    return table.concat(stats, "\n"), tmpname
end

local function codemap(ctx, node, target)
    if node._positional_adjustment then
        return coder._codepositionalmap(ctx, node, target)
    end
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
            SETSLOTK = setboxed(ctx, node._type.keys, tmpkslot, tmpkname),

            CVSTATS = cvstats,
            CTMPV = ctmpv,
            TMPVNAME = tmpvname,
            CVEXP = cvexp,
            SETSLOTV = setboxed(ctx, node._type.values, tmpvslot, tmpvname),
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

-- Lower the internal expression synthesized for one union-variant
-- constructor. The union userdata is rooted immediately; its absolute tag and
-- opaque payload then use ordinary internal TValue slots.
function coder._codeunioninit(ctx, node, target)
    local union = assert(node._union)
    local variant = assert(node._variant)
    assert(union._tag == "Type.Union" and variant._tag == "Type.Variant")
    assert(node._type._tag == "Type.Nominal"
        and node._type.fqtn == union.name)

    local ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end

    local stats = {
        render([[
            $CTMP
            $TMPNAME = luaS_newudata(L, 0, $NUSERVALUES);
            $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
            setuvalue(L, $TMPSLOT, $TMPNAME);
            setivalue(&$TMPNAME->uv[0].uv, $TAG);
        ]], {
            CTMP = ctmp,
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
            NUSERVALUES = variant.payload == false and "1" or "2",
            META = c_integer_literal(type2metatable(ctx, node._type)),
            TAG = c_integer_literal(variant.index),
        }),
    }

    if variant.payload ~= false then
        assert(node.value and node.value ~= false,
            "payload variant initializer has no value")
        local cstats, cexp = codeexp(ctx, node.value)
        local payloadslot = "&" .. tmpname .. "->uv[1].uv"
        table.insert(stats, render([[
            $CSTATS
            $SETSLOT
            $BARRIER
        ]], {
            CSTATS = cstats,
            SETSLOT = setslot(variant.payload, payloadslot, cexp),
            BARRIER = types.is_gc(variant.payload)
                and render("luaC_barrierback(L, obj2gco($UNION), $SLOT);", {
                    UNION = tmpname,
                    SLOT = payloadslot,
                }) or "",
        }))
    else
        assert(node.value == false or node.value == nil,
            "empty variant initializer unexpectedly has a value")
    end

    return table.concat(stats, "\n"), tmpname
end

function coder._freeze_c_operator_operand(ctx, exp, target)
    local cstats, cexp
    if exp._type._tag == "Type.Nil" then
        -- A nil-producing call can keep its effect in the expression half
        -- rather than in `stats`; the generic native-to-foreign bridge quite
        -- correctly replaces the value with NULL, but would then discard that
        -- expression.  Evaluate it explicitly before materializing the
        -- target-typed null constant.
        cstats, cexp = codeexp(ctx, exp)
        cstats = cstats .. "\n(void)(" .. cexp .. ");"
        cexp = "0"
    else
        -- The checker-owned C-operator trait, not an assignment relation on
        -- the operand AST, selects `target`. First recover the operand's raw
        -- C representation without asking the generic native-to-foreign
        -- bridge to authorize that distinct target; the checked numeric path
        -- below and the final explicit C cast then consume the trait.
        cstats, cexp = codeforeignexp(ctx, exp)
    end
    if coder._is_numeric_type(exp._type)
       and coder._is_numeric_type(target)
       and not types.equals(
            coder._resolve_cast_type(exp._type),
            coder._resolve_cast_type(target)) then
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, exp._type, target, cexp, exp.loc, "c_operator")
        cstats = cstats .. nstats
        cexp = nexp
    end
    local cdecl, cname = newforeigntmp(ctx, target)
    return render([[
        $CSTATS
        $CDECL
        $CNAME = $CAST;
    ]], {
        CSTATS = cstats,
        CDECL = cdecl,
        CNAME = cname,
        CAST = foreigncast(cexp, target),
    }), cname
end

function coder._code_c_unary_operator(ctx, node)
    local trait = assert(node._c_operator)
    local stats, operand = coder._freeze_c_operator_operand(
        ctx, node.exp, trait.lhs_target)
    return stats, "(" .. trait.cop .. operand .. ")"
end

function coder._code_c_binary_operator(ctx, node)
    local trait = assert(node._c_operator)
    -- Always freeze both sides.  Besides preserving Titan's left-to-right
    -- evaluation rule for two raw C calls, this makes array decay happen into
    -- the selected pointer temporary rather than ever attempting an array
    -- temporary assignment.
    local lstats, lhs = coder._freeze_c_operator_operand(
        ctx, node.lhs, trait.lhs_target)
    local rstats, rhs = coder._freeze_c_operator_operand(
        ctx, node.rhs, trait.rhs_target)
    local expression =
        "(" .. lhs .. " " .. trait.cop .. " " .. rhs .. ")"
    local ltarget = types.resolve_c_typedef(trait.lhs_target)
    local rtarget = types.resolve_c_typedef(trait.rhs_target)
    if node._type._tag == "Type.Integer"
       and ltarget and rtarget
       and ltarget._tag == "Type.CPointer"
       and rtarget._tag == "Type.CPointer"
       and trait.cop == "-" then
        assert(trait.result_source,
            "C pointer subtraction lacks its checker-owned ptrdiff_t type")
        local cstats, cexp = coder._code_checked_numeric_cast(
            ctx, trait.result_source, node._type,
            expression, node.loc, "boundary")
        return lstats .. "\n" .. rstats .. "\n" .. cstats, cexp
    end
    return lstats .. "\n" .. rstats, expression
end

local function codeunaryop(ctx, node, iscondition)
    if node._c_operator then
        return coder._code_c_unary_operator(ctx, node)
    end
    local op = node.op
    if op == "not" then
        local estats, ecode = codeexp(ctx, node.exp, iscondition)
        return estats, "!(" .. ecode .. ")"
    elseif op == "#" then
        local estats, ecode = codeexp(ctx, node.exp)
        local etype = types.resolve_c_typedef(node.exp._type)
        if node._c_fam_access then
            local access = node._c_fam_access
            if access.kind == "automatic" then
                return estats, c_integer_literal(access.count)
            end
            local owner_node = assert(node.exp.var).exp
            local owner_stats, owner_exp = codeexp(ctx, owner_node)
            local owner_decl, owner_name = newtmp(ctx, owner_node._type)
            return render([[
                $STATS
                $DECL
                $OWNER = $EXP;
            ]], {
                STATS = owner_stats,
                DECL = owner_decl,
                OWNER = owner_name,
                EXP = owner_exp,
            }), "ivalue(&" .. owner_name .. "->uv[0].uv)"
        elseif node.exp._type._tag == "Type.Array" then
            return estats, "((lua_Integer)titan_array_length(" .. ecode .. "))"
        elseif node.exp._type._tag == "Type.Map" then
            assert(types.equals(node.exp._type.keys, types.Integer()))
            return estats, "l_castU2S(luaH_getn(L, " .. ecode .. "))"
        elseif etype._tag == "Type.CArray" then
            return estats, c_integer_literal(etype.len)
        elseif etype._tag == "Type.COwned" and etype.count then
            return estats, render("((lua_Integer)($OWNER->len / sizeof($CT)))", {
                OWNER = ecode,
                CT = coder._render_c_declaration(etype.pointee, ""),
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
    if node._c_operator then
        return coder._code_c_binary_operator(ctx, node)
    end
    local op = node.op
    if op == "~=" then op = "!=" end
    local comparison
    if op == "==" or op == "!=" then
        local plan = node._comparison
        local function original_operand_type(exp, adjustment, side)
            if not adjustment then return exp._type end
            assert(exp._tag == "Ast.ExpCast"
                   and exp._adjustment == adjustment,
                "equality " .. side
                    .. " operand lost its ComparisonPlan adjustment")
            assert(exp.exp
                   and types.equals(
                       types.normalize(exp.exp._type),
                       types.normalize(adjustment.source)),
                "equality " .. side
                    .. " operand has the wrong original type")
            assert(types.equals(exp._type, adjustment.target),
                "equality " .. side
                    .. " operand has the wrong adjusted type")
            return adjustment.source
        end
        comparison = coder._checked_comparison_plan(
            plan,
            original_operand_type(
                node.lhs, plan and plan.left_adjustment, "left"),
            original_operand_type(
                node.rhs, plan and plan.right_adjustment, "right"),
            "equality comparison")
    end
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
            coder._raw_ctype(node.lhs._type) == "TValue" and
            coder._raw_ctype(node.rhs._type) == "TValue" then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        if op == "!=" then
            return stats, "!luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        else
            return stats, "luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        end
    elseif (op == "<" or op == "<=" or op == ">" or op == ">="
            or ((op == "==" or op == "!=")
                and comparison.op == "numeric"))
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
    local castats, caexp = materialize(ctx, node.exp1)
    local cistats, ciexp = materialize(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = coder._strictcheckandgetmixed(
        ctx, node._read_guard, typ, tmpname, "_s", node.loc,
        "typed Array read")
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
    end
    local stats = render([[
        $CTMP
        {
            $CASTATS
            $CISTATS
            Table *_t = $CAEXP;
            lua_Integer _k = $CIEXP;

            TValue _av = {0};
            if (_k < 1) {
                setnilvalue(&_av);
            } else {
                lua_Unsigned _actual_i = l_castS2U(_k) - 1u;
                if (_actual_i < _t->asize) {
                    arr2obj(_t, cast_uint(_actual_i), &_av);
                    if (tagisempty(ttypetag(&_av)))
                        setnilvalue(&_av);
                } else {
                    setnilvalue(&_av);
                }
            }
            const TValue *_s = &_av;

            $CCHECK
            $CSET
    }]], {
        CTMP = ctmp,
        CASTATS = castats,
        CISTATS = cistats,
        CAEXP = caexp,
        CIEXP = ciexp,
        CCHECK = ccheck,
        CSET = cset,
    })
    return stats, tmpname
end

local function codeindexmap(ctx, node)
    local cmstats, cmexp = materialize(ctx, node.exp1)
    local ckstats, ckexp = codeexp(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = coder._strictcheckandgetmixed(
        ctx, node._read_guard, typ, tmpname, "_s", node.loc,
        "typed Map read")
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
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
            $CCHECK
            $CSET
    }]], {
        CTMP = ctmp,
        CMSTATS = cmstats,
        CKSTATS = ckstats,
        CMEXP = cmexp,
        CTMPK = ctmpk,
        TMPKNAME = tmpkname,
        CKEXP = ckexp,
        SETSLOTK = setboxed(ctx, ktyp, tmpkslot, tmpkname),
        CTABLEKEY = get_table_key(ktyp, "_t", tmpkslot, "_s"),
        CCHECK = ccheck,
        CSET = cset,
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
    local plan = node._c_allocation_plan or {
        storage = "owned",
        payload_type = decl.ctype,
        array = decl.array == true,
        fam = decl.fam == true,
    }
    assert(not plan.storage:match("^automatic"),
        "automatic C allocation reached expression lowering")
    local ctyp = plan.payload_type
    local owner_type = types.COwned(ctyp, plan.array)
    local ctmp, tmpname, tmpslot = newtmp(ctx, owner_type, true)
    local countstats, countdecl, countassign

    if plan.array or plan.fam then
        local arg = node.args.args[1]
        local countname
        countstats, countname = codeexp(ctx, arg)
        countdecl = ""
        countassign = render([[
            $COUNTSTATS
            lua_Integer _count = $COUNTEXP;
            if (TITAN_UNLIKELY(_count < 0)) {
                luaL_error(L, "%s:%d:%d: C allocation count cannot be negative", $FILE, $LINE, $COL);
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

    local sizecode
    local nuvalues = 0
    local metadata = ""
    if plan.fam then
        local field = assert(plan.fam_field,
            "FAM allocation lacks its field descriptor")
        local resolved_field = types.resolve_c_typedef(field.type)
        assert(resolved_field._tag == "Type.CArray")
        nuvalues = 1
        sizecode = render([[
            size_t _prefix = offsetof($CT, $FIELD);
            size_t _elem_size = sizeof($ELEM);
            if (TITAN_UNLIKELY((size_t)_count > (((size_t)-1) - _prefix) / _elem_size)) {
                luaL_error(L, "%s:%d:%d: C flexible-array allocation size overflow", $FILE, $LINE, $COL);
            }
            size_t _nbytes = _prefix + (size_t)_count * _elem_size;
            if (_nbytes < sizeof($CT)) _nbytes = sizeof($CT);
        ]], {
            CT = coder._render_c_declaration(ctyp, ""),
            FIELD = field.name,
            ELEM = coder._render_c_declaration(resolved_field.elem, ""),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
        metadata = "setivalue(&" .. tmpname
            .. "->uv[0].uv, _count);"
    else
        sizecode = render([[
            size_t _elem_size = sizeof($CT);
            if (TITAN_UNLIKELY((size_t)_count > ((size_t)-1) / _elem_size)) {
                luaL_error(L, "%s:%d:%d: C allocation size overflow", $FILE, $LINE, $COL);
            }
            size_t _nbytes = (size_t)_count * _elem_size;
        ]], {
            CT = coder._render_c_declaration(ctyp, ""),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    end

    local stats = render([[
        $CTMP
        {
            $COUNTDECL
            $COUNTASSIGN
            $SIZECODE
            $TMPNAME = luaS_newudata(L, _nbytes, $NUVALUES);
            $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
            $METADATA
            setuvalue(L, $TMPSLOT, $TMPNAME);
            memset(getudatamem($TMPNAME), 0, _nbytes);
        }
    ]], {
        CTMP = ctmp,
        COUNTDECL = countdecl,
        COUNTASSIGN = countassign,
        SIZECODE = sizecode,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        NUVALUES = c_integer_literal(nuvalues),
        METADATA = metadata,
        META = c_integer_literal(owned_c_metatable(ctx, owner_type)),
    })
    if plan.storage == "owned_borrow" then
        return stats, render("(($CT *)getudatamem($OWNER))", {
            CT = coder._render_c_declaration(ctyp, ""),
            OWNER = tmpname,
        })
    end
    return stats, tmpname
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

function coder._cast_coercion(node)
    local plan = node._adjustment or node._written_cast
    local coercion = plan and plan.coercion
    if not coercion then return nil end
    return coder._checked_coercion_plan(
        coercion, node.exp._type, node._type, "expression coercion")
end

function coder._inner_assignment(source, target, inner)
    assert(inner, "Option conversion lacks its inner checker plan")
    inner = coder._checked_coercion_plan(
        inner, source, target, "Option inner conversion")
    source = assert(types.normalize(source),
        "Option inner conversion has an unnormalizable source")
    target = assert(types.normalize(target),
        "Option inner conversion has an unnormalizable target")
    if inner.kind == "identity" then return inner end
    return {
        kind = "direct_coercion",
        source = source,
        target = target,
        coercion = inner,
    }
end

-- Generate code for expression 'node'
-- 'iscondition' is 'true' if expression is used not for value but for
--    controlling conditinal execution
-- 'target' is not nil if expression is rvalue for a 'Ast.VarName' lvalue,
--    in this case it will be the '_decl' of the lvalue
local function codeexp_dispatch(ctx, node, iscondition, target)
    local tag = node._tag
    if tag == "Ast.ExpCast" and not node._typedef_resolved then
        if node._adjustment then
            coder._checked_adjustment_plan(
                node._adjustment, node.exp._type, node._type,
                "expression adjustment")
        end
        if node._written_cast then
            coder._checked_written_cast_plan(
                node._written_cast, node.exp._type, node._type,
                "written expression cast")
        end
        if node._c_conversion then
            coder._checked_explicit_conversion_plan(
                node._c_conversion, node.exp._type, node._type,
                "checked expression C conversion")
        end
    end
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
        elseif types.is_direct_c(node.exp1._type) then
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
    elseif tag == "Ast.ExpUnionInit" then
        return coder._codeunioninit(ctx, node, target)
    elseif tag == "Ast.ExpVar" then
        if node._foreign_function_reference then
            return "", foreigncast(
                coder._foreign_reference_name(node._foreign_function_reference),
                node._type)
        end
        return codeexp(ctx, node.var, iscondition)
    elseif tag == "Ast.ExpUnop" then
        return codeunaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpBinop" then
        return codebinaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._decl
           and node.exp.var._decl._tag == "Checker.CPseudoNew" then
        return codecpseudonew(ctx, node)
    elseif tag == "Ast.ExpCall" and node._c_pointer_call then
        local fstats, fexp = codecfunctionptrcall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" and node._direct_foreign_reference then
        local fstats, fexp = codeforeigncall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" then
        return codecall(ctx, node, target)
    elseif tag == "Ast.ExpExtra" then
        return "", node.exp._extras[node.index]
    elseif tag == "Ast.ExpIs" then
        return coder._codeis(ctx, node)
    elseif tag == "Ast.ExpCast" and node._interface_conversion then
        return coder._code_interface_conversion(ctx, node)
    elseif tag == "Ast.ExpCast" and node._interface_downcast then
        return coder._code_interface_downcast(ctx, node, false)
    elseif tag == "Ast.ExpCast" and types.equals(node.exp._type, node._type) then
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast"
           and ((node._adjustment
                    and node._adjustment.kind == "callable")
                or (node._written_cast
                    and (node._written_cast.op == "gradual"
                        or node._written_cast.op == "callable"))) then
        -- A finite callable edge is an allocating target view; a written
        -- structural gradual cast remains the existing representation view.
        -- Both consume only the checker-owned plan attached to this cast.
        local adjustment
        if node._adjustment then
            adjustment = node._adjustment
        else
            local cast = node._written_cast
            adjustment = cast.op == "gradual"
                and assert(cast.view,
                    "written gradual cast lacks its checker view plan")
                or assert(cast.callable,
                    "written callable cast lacks its checker adjustment")
        end
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local astats, aexp = coder._code_adjustment_value(
            ctx, adjustment, node.exp._type, node._type, cexp, node.loc,
            node._callable_adapter)
        return cstats .. astats, aexp
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
        for _, key in ipairs({
            "_implicit_coercion",
            "_adjustment",
            "_written_cast",
            "_c_conversion",
            "_operator_conversion",
        }) do
            synthcast[key] = node[key]
        end
        return codeexp(ctx, synthcast, iscondition, target)
    elseif tag == "Ast.ExpCast" and node._typedef_resolved then
        -- Pass-through wrapper produced above: the operand's static type is a
        -- typedef but its C representation already is the underlying scalar, so
        -- just emit the operand unchanged under its resolved type.
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast"
           and node._c_conversion
           and node._c_conversion.kind ==
               "address_then_unsafe_object_pointer" then
        coder._checked_explicit_conversion_plan(
            node._c_conversion, node.exp._type, node._type,
            "native address-then-pointer conversion")
        assert(is_addressable_local(node.exp),
            "native address-then-pointer conversion has a "
            .. "non-addressable source")
        local cstats, cexp = codeexp(ctx, node.exp)
        local address = render("(&($CEXP))", { CEXP = cexp })
        return cstats, foreigncast(address, node._type)
    elseif tag == "Ast.ExpCast"
           and types.is_direct_c(node._type)
           and (node.exp._type._tag ~= "Type.Option"
                or (types.is_c_tvalue(node._type)
                    and coder._cast_coercion(node)
                    and coder._cast_coercion(node).op == "to_c_tvalue")) then
        if node.exp._type._tag == "Type.Option" then
            assert(coder._cast_coercion(node).op == "to_c_tvalue",
                "Option-to-C-TValue cast lacks its whole-slot checker plan")
        end
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp =
            nativetoforeignexp(ctx, node.exp, cexp, node._type, node)
        if types.is_c_tvalue(node._type) then
            return cstats .. fstats, fexp
        end
        return cstats .. fstats, foreigncast(fexp, node._type)
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Integer" then
        local cstats, cexp = codeexp(ctx, node.exp)
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "C-to-Titan integer coercion")
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, node.exp._type, node._type, cexp, node.loc, "boundary")
        return cstats .. nstats, nexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Float" then
        local cstats, cexp = codeexp(ctx, node.exp)
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "C-to-Titan float coercion")
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, node.exp._type, node._type, cexp, node.loc, "boundary")
        return cstats .. nstats, nexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Boolean" then
        local cstats, cexp = codeexp(ctx, node.exp)
        return cstats, toboolean(types.resolve_c_typedef(node.exp._type), cexp)
    elseif tag == "Ast.ExpCast"
           and types.is_counted_c_character_owner(node.exp._type)
           and node._type._tag == "Type.String" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local ownerstats, owner =
            materialize_code(ctx, node.exp._type, cstats, cexp)
        local mkstats, mkexp = makestring(
            ctx,
            render("((const char *)getudatamem($OWNER))", {
                OWNER = owner,
            }),
            target,
            render("$OWNER->len", { OWNER = owner }))
        return ownerstats .. "\n" .. mkstats, mkexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
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
    elseif tag == "Ast.ExpCast"
           and node.exp._tag == "Ast.ExpVar"
           and node.exp.var._tag == "Ast.VarBracket"
           and node.exp._type._tag ~= "Type.Option"
           and node.exp._type._tag ~= "Type.Value" then
        -- Fold casts of array/map indexing into the code for the operation
        local t = node.exp.var._type
        node.exp.var._type = node._type
        local cstats, cexp = codeexp(ctx, node.exp.var)
        node.exp.var._type = t
        return cstats, cexp
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Value" then
        -- An implicit projection is a strict gradual observation; a written
        -- `value as T` consumes the broader Lua-boundary conversion plan.
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local ctmps, tmpnames = newtmp(ctx, node.exp._type)
        local ctmpt, tmpnamet = newtmp(ctx, node.target)
        local cget = coder._planned_value_projection_get(
            ctx, node, tmpnamet, "&" .. tmpnames)
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
            SETSLOT = setboxed(ctx, node.exp._type, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Integer" and node._type._tag == "Type.Float" then
        -- cast from integer to float
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "integer-to-float coercion")
        local cstat, cexp = codeexp(ctx, node.exp)
        return cstat, "((lua_Number)" .. cexp .. ")"
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Boolean" then
        -- cast to boolean from any type (including options, via truthiness)
        local cstat, cexp = codeexp(ctx, node.exp, true)
        return cstat, toboolean(node.exp._type, cexp)
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Float" and node.target._tag == "Type.Integer" then
        -- cast from float to integer
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "float-to-integer coercion")
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
            local conversion = assert(node._operator_conversion,
                "integer-to-string cast lacks its checker operator plan")
            assert(conversion.kind == "operator_conversion"
                    and conversion.op == "number_to_string",
                "integer-to-string cast has the wrong checker operator plan")
            cvt = render("_integer2str(L, $EXP)", { EXP = cexp })
        elseif node.exp._type._tag == "Type.Float" then
            local conversion = assert(node._operator_conversion,
                "float-to-string cast lacks its checker operator plan")
            assert(conversion.kind == "operator_conversion"
                    and conversion.op == "number_to_string",
                "float-to-string cast has the wrong checker operator plan")
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
        local outer_coercion = coder._cast_coercion(node)
        assert(outer_coercion and outer_coercion.op == "option_map",
            "Option-to-Option cast lacks its checker coercion plan")
        local inner = assert(outer_coercion.inner,
            "Option map lacks its inner adjustment")
        local inner_adjustment =
            coder._inner_assignment(sbase, tbase, inner)
        local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                            exp = synthvar, target = tbase, _type = tbase,
                            _implicit_coercion = true,
                            _adjustment = inner_adjustment }
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
        -- Cast from S to T?. The checker records one outer option_wrap plan;
        -- lower its inner S-to-T operation here without reclassifying it.
        local coercion = coder._cast_coercion(node)
        assert(coercion and coercion.op == "option_wrap",
            "Option injection has the wrong checker adjustment")
        local tbase = node._type.base
        local inner = assert(coercion.inner,
            "Option injection lacks its inner checker plan")
        local inner_adjustment =
            coder._inner_assignment(node.exp._type, tbase, inner)
        local converted = node.exp
        if inner.kind ~= "identity" then
            converted = {
                _tag = "Ast.ExpCast",
                loc = node.loc,
                exp = node.exp,
                target = tbase,
                _type = tbase,
                _implicit_coercion = true,
                _adjustment = inner_adjustment,
            }
        else
            assert(types.equals(node.exp._type, tbase),
                "identity Option injection changes its base type")
        end
        local cstats, cexp = codeexp(ctx, converted)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CTMP
            $SETSLOT
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            SETSLOT = setslot(tbase, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Option" then
        -- Cast from S? to T. Preserve nil failure, then lower the checker
        -- plan's inner S-to-T operation without reclassifying it.
        local coercion = coder._cast_coercion(node)
        assert(coercion and coercion.op == "option_force",
            "Option projection has the wrong checker adjustment")
        local sbase = node.exp._type.base
        local inner = assert(coercion.inner,
            "Option projection lacks its inner checker plan")
        local inner_adjustment =
            coder._inner_assignment(sbase, node._type, inner)
        local cstats, cexp = codeexp(ctx, node.exp)
        -- Materialize the option value into a TValue temp first: the operand
        -- may be a non-lvalue (e.g. a direct call returning t?), so we cannot
        -- take its address directly.
        local csrc, srcname = newtmp(ctx, node.exp._type)
        local cbase, basename = newtmp(ctx, sbase)
        local synthvar = {
            _tag = "Ast.VarName",
            _type = sbase,
            _decl = { _cvar = basename },
        }
        local converted = synthvar
        if inner.kind ~= "identity" then
            converted = {
                _tag = "Ast.ExpCast",
                loc = node.loc,
                exp = synthvar,
                target = node._type,
                _type = node._type,
                _implicit_coercion = true,
                _adjustment = inner_adjustment,
            }
        else
            assert(types.equals(sbase, node._type),
                "identity Option projection changes its base type")
        end
        local convstats, convexp = codeexp(ctx, converted)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CSRC
            $SRCNAME = $CEXP;
            $CTMP
            if(TITAN_UNLIKELY(ttisnil(&$SRCNAME))) {
                $THROW_WRONG_CAST
            } else {
                $CBASE
                $GETBASE;
                $CONVSTATS
                $TMPNAME = $CONVEXP;
            }
        ]], {
            CSTATS = cstats,
            CSRC = csrc,
            SRCNAME = srcname,
            CEXP = cexp,
            CBASE = cbase,
            GETBASE = getslot(sbase, basename, "&" .. srcname),
            CONVSTATS = convstats,
            CONVEXP = convexp,
            CTMP = ctmp,
            TMPNAME = tmpname,
            FILE = c_string_literal(node.loc.filename),
            LINE = node.loc.line,
            COL = node.loc.col,
            TYPENAME = c_string_literal(types.tostring(node._type)),
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
                if (TITAN_UNLIKELY($LENVAR >=
                        MAX_SIZE - sizeof(TString) - _len)) {
                    luaL_error(L, "string length overflow");
                }
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
    local stats, value =
        codeexp_dispatch(ctx, node, iscondition, target)
    local adjustment = node._assignment_adjustment
    if not adjustment then
        return stats, value
    end
    local adjusted_stats, adjusted_value =
        coder._code_adjustment_value(
            ctx, adjustment, node._type,
            adjustment.target or node._type, value, node.loc)
    return stats .. adjusted_stats, adjusted_value
end

function codeforeignexp(ctx, node, target)
    local tag = node._tag
    if tag == "Ast.ExpCall" and node._c_pointer_call then
        return codecfunctionptrcall(ctx, node)
    elseif tag == "Ast.ExpCall" and node._direct_foreign_reference then
        return codeforeigncall(ctx, node)
    elseif tag == "Ast.VarDot" and node.exp._type._tag == "Type.CModule" then
        return codeforeignvar(ctx, node)
    elseif tag == "Ast.ExpVar"
           and not node._foreign_function_reference
           and node.var
           and node.var._tag == "Ast.VarDot"
           and node.var.exp
           and node.var.exp._type
           and node.var.exp._type._tag == "Type.CModule" then
        -- `codeexp` normally converts a foreign scalar/module member into its
        -- Titan representation at this wrapper.  C operators and C call
        -- operands need the declaration's raw C expression so promotions
        -- happen from its actual type (not a premature lua_Integer/
        -- lua_Number cast).
        return codeforeignvar(ctx, node.var)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpCast" and node.target._tag == "Type.String" then
        local cstats, cexp = codeforeignexp(ctx, node.exp)
        return cstats, foreigncast(cexp, node._type)
    elseif tag == "Ast.ExpCast"
           and node._c_conversion
           and node._c_conversion.kind ==
               "address_then_unsafe_object_pointer" then
        coder._checked_explicit_conversion_plan(
            node._c_conversion, node.exp._type, node._type,
            "foreign address-then-pointer conversion")
        assert(is_addressable_local(node.exp),
            "foreign address-then-pointer conversion has a "
            .. "non-addressable source")
        local cstats, cexp = codeexp(ctx, node.exp)
        local address = render("(&($CEXP))", { CEXP = cexp })
        return cstats, foreigncast(address, node._type)
    elseif tag == "Ast.ExpCast"
           and types.is_direct_c(node._type)
           and node.exp._type._tag ~= "Type.Option" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp =
            nativetoforeignexp(ctx, node.exp, cexp, node._type, node)
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

-- Generate one Lua-stack entry for a Titan function. The ordinary entry is the
-- canonical closure's CClosure.f and applies genuine-Lua dynamic coercions.
-- The strict entry is stored as the closure's final LCF upvalue; it receives
-- the original closure as one hidden first argument and applies gradual tag
-- guards before calling the same native entry.
local function genluaentry(tlcontext, titan_name, titan_entry, typ, loc,
                           lua_name, options)
    options = options or {}
    local strict = options.strict == true
    local hidden = strict and 1 or 0
    local dynamic_plans = options.dynamic_plans
    local strict_plans = options.strict_plans
    local interface_method_index = options.interface_method_index
    if interface_method_index ~= nil then
        assert(not strict and typ._tag == "Type.Method"
               and interface_method_index >= 0,
            "invalid Interface Lua-entry dispatch configuration")
    end
    if not strict then
        assert(type(dynamic_plans) == "table",
            "genuine Lua function entry lacks checker parameter plans")
    else
        assert(type(strict_plans) == "table",
            "strict Titan function entry lacks checker guard plans")
    end
    local function readfixed(param, cvar, slot, index)
        if strict then
            assert(strict_plans[index] ~= nil,
                "strict Titan function parameter lacks its checker guard")
            return coder._strictcheckandget(
                tlcontext, strict_plans[index], param, cvar, slot, loc,
                "strict Titan function parameter")
        end
        assert(dynamic_plans[index] ~= nil,
            "genuine Lua function parameter lacks its checker plan")
        return coder._dynamiccheckandget(
            tlcontext, dynamic_plans[index], param, cvar, slot, loc,
            "genuine Lua function parameter")
    end
    local storage = options.storage or "static"
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
        local slot = "s2v(func + " .. (i + hidden) .. ")"
        table.insert(pnames, pname)
        table.insert(stats, cvardecl(tlcontext, param, pname)
            .. " = " .. initval(param) .. ";")
        table.insert(stats, readfixed(param, pname, slot, i))
    end
    local call_entry = titan_entry
    if interface_method_index ~= nil then
        local interface = assert(types.registry[typ.fqtn],
            "Interface method owner is absent from the type registry")
        local registered_method =
            interface.methods[interface_method_index + 1]
        assert(interface._tag == "Type.Interface"
               and registered_method
               and registered_method.name == typ.name
               and types.equals(
                   types.method_function_type(registered_method),
                   types.method_function_type(typ)),
            "Interface Lua-entry method index is not canonical")
        local payload_name =
            "_titan_interface_method_" .. tostring(interface_method_index)
        table.insert(stats, render([[
            if (TITAN_UNLIKELY(
                    _param_1->len % sizeof(TitanInterfaceMethod) != 0
                    || _param_1->len / sizeof(TitanInterfaceMethod)
                        != $METHOD_COUNT)) {
                return luaL_error(L,
                    "malformed internal Interface wrapper for %s", $IFACE);
            }
            TitanInterfaceMethod _titan_interface_stored =
                ((TitanInterfaceMethod *)getudatamem(_param_1))[$INDEX];
            if (TITAN_UNLIKELY(_titan_interface_stored == NULL)) {
                return luaL_error(L,
                    "uninitialized internal Interface method %s:%s",
                    $IFACE, $METHOD);
            }
            $METHOD_DECL = titan_cast_func(
                $METHOD_TYPE, _titan_interface_stored);
            Udata *_titan_interface_concrete_module =
                uvalue(&_param_1->uv[0].uv);
            Udata *_titan_interface_concrete_self =
                uvalue(&_param_1->uv[1].uv);
        ]], {
            METHOD_COUNT = c_integer_literal(#interface.methods),
            IFACE = c_string_literal(interface.name),
            METHOD = c_string_literal(typ.name),
            INDEX = c_integer_literal(interface_method_index),
            METHOD_DECL = function_sig(payload_name, typ, true),
            METHOD_TYPE = function_sig("", typ, true),
        }))
        pnames = {
            "L",
            "_titan_interface_concrete_module",
            "NULL",
            "_titan_interface_concrete_self",
        }
        for i = 2, #params do
            table.insert(pnames, "_param_" .. tostring(i))
        end
        call_entry = payload_name
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
        local readone
        if strict then
            assert(options.strict_vararg_plan ~= nil,
                "strict Titan variadic parameter lacks its checker guard")
            readone = coder._strictcheckandget(
                tlcontext, options.strict_vararg_plan, varargtype,
                "_varargs->args[_vj]",
                "s2v(_vfunc + " .. (nfixed + hidden) .. " + 1 + _vj)",
                loc, "strict Titan variadic parameter")
        else
            assert(options.dynamic_vararg_plan ~= nil,
                "genuine Lua variadic parameter lacks its checker plan")
            readone = coder._dynamiccheckandget(
                tlcontext, options.dynamic_vararg_plan, varargtype,
                "_varargs->args[_vj]",
                "s2v(_vfunc + " .. (nfixed + hidden) .. " + 1 + _vj)",
                loc, "genuine Lua variadic parameter")
        end
        table.insert(stats, render([[
            ptrdiff_t _vcount = _nargs - $NFIXED;
            if (TITAN_UNLIKELY(_vcount > TITAN_VARARG_MAX)) {
                luaL_error(L, "too many variadic arguments to Titan function %s (%d, max %d)", $NAME, (int)_vcount, (int)TITAN_VARARG_MAX);
            }
            lu_byte _nvarargs = (lu_byte)_vcount;
            titan_ensure_stack(L, 1);
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
        table.insert(stats, cvardecl(tlcontext, ptype, pname)
            .. " = " .. initval(ptype) .. ";")
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
    if strict or #params > 0 then
        table.insert(stats, [[
            lua_pushvalue(L, 1); /* make space for error slot */
            lua_pushnil(L);
            lua_replace(L, 1); /* replace first stack element with nil, this is our error slot */
        ]])
    end
    if flexrettype then
        local call
        if rettype then
            call = render("$DECL = $NAME($PARAMS);", {
                DECL = cvardecl(tlcontext, rettype, "res"),
                NAME = call_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        else
            call = render("$NAME($PARAMS);", {
                NAME = call_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        end
        local fixedsets = {}
        if rettype then
            table.insert(fixedsets,
                setboxed(tlcontext, rettype, "s2v(_firstret)", "res") .. ";")
        end
        for i = 2, #typ.rettypes do
            table.insert(fixedsets, render([[
                $SETSLOT;
            ]], {
                SETSLOT = setboxed(tlcontext, typ.rettypes[i],
                    "s2v(_firstret + " .. c_integer_literal(i - 1) .. ")",
                    "_outparam_" .. i),
            }))
        end
        table.insert(stats, render([[
            titan_ensure_stack(L, $NFIXED + _flexcap);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            for (int _ri = 0; _ri < $NFIXED + _flexcap; _ri++) {
                setnilvalue2s(L->top.p + _ri);
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
            SETFLEX = setboxed(tlcontext, flexrettype,
                "s2v(_firstret + " .. c_integer_literal(#typ.rettypes)
                    .. " + _fri)", "_flexdesc.args[_fri]"),
        }))
    elseif #typ.rettypes == 0 then
        -- zero-return `() -> ()`: invoke the void native entry purely for
        -- effect and return no values across the Lua boundary
        table.insert(stats, render([[
            $NAME($PARAMS);
        ]], {
            NAME = call_entry,
            PARAMS = table.concat(pnames, ", "),
        }))
    else
        table.insert(stats, render([[
            titan_ensure_stack(L, $NRET);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            L->top.p += $NRET;
            $DECL = $NAME($PARAMS);
            /* the native callee may have grown (and thus relocated) the Lua
               stack via lua_checkstack, so recompute the return slot pointer
               from the saved offset before writing through it */
            StkId _firstret = restorestack(L, _firstret_off);
            $SETSLOT;
            _firstret++;
        ]], {
            DECL = cvardecl(tlcontext, rettype, "res"),
            NAME = call_entry,
            PARAMS = table.concat(pnames, ", "),
            SETSLOT = setboxed(tlcontext, rettype, "s2v(_firstret)", "res"),
            NRET = #typ.rettypes
        }))
        for i = 2, #typ.rettypes do
            table.insert(stats, render([[
                $SETSLOT;
                _firstret++;
            ]], {
                SETSLOT = setboxed(tlcontext, typ.rettypes[i],
                    "s2v(_firstret)", "_outparam_" .. i)
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
        ptrdiff_t _nargs = L->top.p - func - 1 - $HIDDEN;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            titan_ensure_stack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue2s(L->top.p);
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
            HIDDEN = c_integer_literal(hidden),
            NAME = c_string_literal(titan_name),
        })
    else
        argcheck = render([[
        ptrdiff_t _nargs = L->top.p - func - 1 - $HIDDEN;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            titan_ensure_stack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue2s(L->top.p);
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
            HIDDEN = c_integer_literal(hidden),
        })
    end
    local carrier
    if strict then
        assert(options.strict_name)
        if options.callable_adapter then
            local adapter = options.callable_adapter
            assert(adapter.target == typ
                   or types.equals(adapter.target, typ),
                "callable strict relay has a mismatched target")
            carrier = render([[
            ptrdiff_t _strict_raw_nargs = L->top.p - func - 1;
            if (TITAN_UNLIKELY(_strict_raw_nargs < 1
                    || !ttisCclosure(s2v(func + 1)))) {
                return luaL_error(L,
                    "invalid callable strict-relay carrier");
            }
            CClosure *_fn = clCvalue(s2v(func + 1));
            if (TITAN_UNLIKELY(_fn->nupvalues < 6
                    || !ttisfulluserdata(&_fn->upvalue[0])
                    || !ttislightuserdata(&_fn->upvalue[1])
                    || !ttislightuserdata(&_fn->upvalue[2])
                    || !ttislightuserdata(&_fn->upvalue[3])
                    || !ttisCclosure(
                        &_fn->upvalue[_fn->nupvalues - 2])
                    || !ttislcf(&_fn->upvalue[
                        _fn->nupvalues - 1])
                    || pvalue(&_fn->upvalue[1]) != $FUNCTAG
                    || pvalue(&_fn->upvalue[2])
                        != titan_cast_func(void *, $ADAPTER)
                    || pvalue(&_fn->upvalue[3])
                        != TITAN_FUNCTION_CLOSURE_BRAND
                    || fvalue(&_fn->upvalue[_fn->nupvalues - 1])
                        != $STRICTENTRY)) {
                return luaL_error(L,
                    "invalid callable strict-relay wrapper");
            }
            ]], {
                STRICTENTRY = options.strict_name,
                ADAPTER = titan_entry,
                FUNCTAG = function_type_tag(tlcontext, typ),
            })
        else
            assert(options.lua_entry)
            carrier = render([[
            ptrdiff_t _strict_raw_nargs = L->top.p - func - 1;
            if (TITAN_UNLIKELY(_strict_raw_nargs < 1
                    || !ttisCclosure(s2v(func + 1)))) {
                return luaL_error(L, "invalid Titan strict-call carrier");
            }
            CClosure *_fn = clCvalue(s2v(func + 1));
            if (TITAN_UNLIKELY(_fn->nupvalues < 5
                    || _fn->f != $LUAENTRY
                    || !ttisfulluserdata(&_fn->upvalue[0])
                    || !ttislightuserdata(&_fn->upvalue[1])
                    || !ttislightuserdata(&_fn->upvalue[2])
                    || !ttislcf(&_fn->upvalue[_fn->nupvalues - 1])
                    || fvalue(&_fn->upvalue[_fn->nupvalues - 1])
                        != $STRICTENTRY)) {
                return luaL_error(L, "invalid Titan strict-call closure");
            }
            if (TITAN_UNLIKELY(
                    pvalue(&_fn->upvalue[1]) != $FUNCTAG)) {
                return luaL_error(L, "mistagged Titan strict-call closure");
            }
            ]], {
                LUAENTRY = options.lua_entry,
                STRICTENTRY = options.strict_name,
                FUNCTAG = function_type_tag(tlcontext, typ),
            })
        end
    else
        carrier = [[
        CClosure *_fn = clCvalue(s2v(func));
        ]]
    end
    local module_setup
    if strict and options.callable_adapter then
        -- The wrapper deliberately retains the immediate source closure's
        -- module in upvalue 0. Its consumer-local strict relay, however, must
        -- interpret target nominal/Array/owned-C identities through the
        -- consumer module that froze and emitted this adapter. Recover that
        -- already initialized module through its ordinary idempotent init
        -- entry, then refresh `func` because the registry lookup may relocate
        -- the Lua stack.
        module_setup = render([[
            Udata *_mod = $INIT(L);
            func = L->ci->func.p;
        ]], {
            INIT = tlcontext.prefix .. "init",
        })
    else
        module_setup = "Udata *_mod = uvalue(&_fn->upvalue[0]);"
    end
    return render([[
    $STORAGE int $LUANAME(lua_State *L) {
        StkId func = L->ci->func.p;
        $CARRIER
        $ARGCHECK
        $ERRORSLOT
        ptrdiff_t __save_errfunc = L->errfunc;
        int __installed_errfunc = 0;
        if (TITAN_UNLIKELY(!titan_errfunc_is_errorhandler(L))) {
            lua_pushcfunction(L, errorhandler);
            L->errfunc = savestack(L, L->top.p - 1);
            __installed_errfunc = 1;
        }
        $MODULE_SETUP
        $ENTRYLINE$BODY
    }]], {
        LUANAME = lua_name,
        STORAGE = storage,
        CARRIER = carrier,
        ARGCHECK = argcheck,
        ERRORSLOT = (not strict and #params == 0)
            and "lua_pushnil(L);" or "",
        MODULE_SETUP = module_setup,
        NAME = c_string_literal(titan_name),
        -- Stamp the Lua-entry wrapper to the function definition's .titan loc
        -- so its native frame, and any arg-coercion throw within it, symbolizes
        -- to the .titan source rather than drifting through the wrapper's
        -- generated C.
        ENTRYLINE = emitline({ loc = loc }),
        BODY = table.concat(stats, "\n"),
    })
end

function coder._emit_callable_adapter(tlcontext, site)
    local adapter = coder._validate_callable_adapter_plan(
        site.adapter, site.adapter.source, site.adapter.target,
        "callable adapter emission", {})
    local ctx = newcontext(tlcontext)
    local roots = coder._interface_adapter_allocate_roots(ctx, adapter)
    local identities, identity_scratch =
        coder._interface_adapter_identity_prelude(ctx, adapter)
    local loc = adapter.location
    local argument_sources =
        coder._emit_interface_adapter_argument_sources(
            ctx, adapter, roots, loc)
    local flex_validation = ""
    if adapter.target.flexrettype then
        flex_validation = render([[
            if (TITAN_UNLIKELY(
                    _flexout == NULL
                    || (_flexwant != LUA_MULTRET
                        && (_flexwant < 0
                            || _flexwant > TITAN_VARARG_MAX)))) {
                luaL_error(L,
                    "malformed callable adapter flexible-result demand for %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local arguments = coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local call = coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local results = coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local handoff = {}
    for index = 2, #adapter.target.rettypes do
        handoff[#handoff + 1] = render([[
            *_ia_out_$INDEX = _ia_interface_result_$INDEX;
        ]], {
            INDEX = c_integer_literal(index),
        })
    end
    local finish
    if #adapter.target.rettypes == 0 then
        finish = "L->top.p = _base;\nreturn;"
    else
        finish = [[
            L->top.p = _base;
            return _ia_interface_result_1;
        ]]
    end
    local root_preamble
    if ctx.nslots > 0 then
        root_preamble = render([[
            titan_ensure_stack(L, $NRESERVE);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for (StkId _ia_slot = L->top.p - 1;
                 _base <= _ia_slot; _ia_slot--) {
                setnilvalue2s(_ia_slot);
            }
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NSLOTS = c_integer_literal(ctx.nslots),
            NRESERVE = c_integer_literal(
                ctx.nslots + identity_scratch),
        })
    elseif identity_scratch > 0 then
        root_preamble = render([[
            titan_ensure_stack(L, $NRESERVE);
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NRESERVE = c_integer_literal(identity_scratch),
        })
    else
        root_preamble = [[
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]]
    end
    local native_signature = coder._callable_adapter_signature(
        site.native, adapter.target, false)
    local native_body = render([[
        static TITAN_NOINLINE $SIGNATURE {
            (void)_mod;
            $LINE$GC_POLL
            $ROOT_PREAMBLE
            $ARGUMENT_SOURCES
            $FLEX_VALIDATION
            $IDENTITIES
            $ARGUMENTS
            $CALL
            $RESULTS
            $HANDOFF
            $FINISH
        }
    ]], {
        SIGNATURE = native_signature,
        LINE = emitline({ loc = loc }),
        GC_POLL = coder._adapter_actions_allocate(adapter)
            and "luaC_checkGC(L);" or "",
        ROOT_PREAMBLE = root_preamble,
        ARGUMENT_SOURCES = argument_sources,
        FLEX_VALIDATION = flex_validation,
        IDENTITIES = identities,
        ARGUMENTS = arguments,
        CALL = call,
        RESULTS = results,
        HANDOFF = table.concat(handoff, "\n"),
        FINISH = finish,
    })

    local strict_plans = {}
    for index, slot in ipairs(adapter.strict_relay.parameters) do
        strict_plans[index] = slot.guard
    end
    local strict_body = genluaentry(
        tlcontext, adapter.trace_name, site.native,
        adapter.target, loc, site.strict, {
            strict = true,
            strict_name = site.strict,
            callable_adapter = adapter,
            strict_plans = strict_plans,
            strict_vararg_plan = adapter.strict_relay.vararg
                and adapter.strict_relay.vararg.guard or nil,
        })
    local declarations = table.concat({
        -- The consumer-local strict relay recovers this module's per-state
        -- identity slots instead of mistaking the captured source module for
        -- its target context. Adapter declarations precede the generated init
        -- definition, so provide the ordinary external prototype here.
        "Udata *" .. tlcontext.prefix .. "init(lua_State *L);",
        "static TITAN_NOINLINE "
            .. coder._callable_adapter_signature(
                site.native, adapter.target, false) .. ";",
        "static int " .. site.strict .. "(lua_State *L);",
    }, "\n")
    return declarations, native_body .. "\n" .. strict_body
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

function coder._foreign_function_is_inline(node)
    local block = node.block
    if not block or block._tag ~= "Ast.StatBlock" then return false end
    local stats = block.stats
    local first = 1
    while stats[first] and stats[first]._tag == "Ast.StatDecl" do
        first = first + 1
    end
    local function return_block(candidate)
        return candidate and candidate._tag == "Ast.StatBlock"
            and #candidate.stats == 1
            and candidate.stats[1]._tag == "Ast.StatReturn"
    end
    if first == #stats and stats[first]._tag == "Ast.StatReturn" then
        return true
    end
    local conditional = stats[first]
    if not conditional or conditional._tag ~= "Ast.StatIf"
       or #conditional.thens ~= 1
       or not return_block(conditional.thens[1].block) then
        return false
    end
    if first == #stats and return_block(conditional.elsestat) then
        return true
    end
    return first + 1 == #stats and not conditional.elsestat
        and stats[first + 1]._tag == "Ast.StatReturn"
end

function coder._new_foreign_context(tlcontext)
    return {
        tlcontext = tlcontext,
        temporary = 0,
        local_count = 0,
    }
end

function coder._foreign_temp(ctx, typ, prefix)
    ctx.temporary = ctx.temporary + 1
    local name = "_foreign_" .. (prefix or "tmp") .. "_"
        .. tostring(ctx.temporary)
    return coder._render_c_declaration(typ, name) .. ";", name
end

function coder._foreign_freeze(ctx, node, target, prefix)
    local stats, exp = coder._foreign_raw_exp(ctx, node)
    local typ = target or node._type
    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == "Type.CArray" then
        typ = cdeclarator.adjust_parameter_type(typ)
    end
    local decl, name = coder._foreign_temp(ctx, typ, prefix)
    local value = target and foreigncast(exp, target) or exp
    return table.concat({ stats, decl, name .. " = " .. value .. ";" }, "\n"), name
end

function coder._foreign_source_member_reference(var)
    local decl = var and var._decl
    if not decl then return nil end
    if decl._tag == "Ast.TopLevelForeignFunc" then
        return { source = true, module = decl._foreign_module, name = decl.name }
    elseif decl._tag == "Type.ModuleMember" and decl._foreign_source then
        return { source = true, module = decl.modname, name = decl.name }
    end
end

function coder._foreign_raw_var(ctx, node)
    if node._tag == "Ast.VarName" then
        if node._decl and node._decl._foreign_cname then
            return "", node._decl._foreign_cname
        end
        local reference = coder._foreign_source_member_reference(node)
        if reference then
            return "", coder._foreign_reference_name(reference)
        end
        error("foreign variable lacks a C name: " .. tostring(node.name))
    elseif node._tag == "Ast.VarDot" then
        local base_type = types.resolve_c_typedef(node.exp._type)
        if node.exp._type._tag == "Type.CModule" then
            return "", node.name
        end
        local reference = coder._foreign_source_member_reference(node)
        if reference then
            return "", coder._foreign_reference_name(reference)
        end
        if node._decl and node._decl._tag == "Type.CPseudoSize" then
            local op = node._decl.name == "sizeof" and "sizeof" or "_Alignof"
            return "", op .. "(" .. coder._render_c_declaration(
                node._decl.ctype, "") .. ")"
        end
        assert(node._decl and node._decl._tag == "Type.CField",
            "foreign member is not a C field")
        local stats, base = coder._foreign_raw_exp(ctx, node.exp)
        if base_type._tag == "Type.CPointer" then
            return stats, "(" .. base .. ")->" .. node._decl.name
        end
        return stats, "(" .. base .. ")." .. node._decl.name
    elseif node._tag == "Ast.VarBracket" then
        local bstats, base = coder._foreign_raw_exp(ctx, node.exp1)
        local istats, index = coder._foreign_raw_exp(ctx, node.exp2)
        return bstats .. "\n" .. istats,
            "(" .. base .. ")[" .. index .. "]"
    end
    error("unsupported foreign variable " .. tostring(node._tag))
end

function coder._foreign_raw_call(ctx, node)
    local signature
    local callee_stats = ""
    local callee
    if node._direct_foreign_reference then
        signature = node.exp._type
        callee = coder._foreign_reference_name(node._direct_foreign_reference)
    elseif node._c_pointer_call then
        signature = node._c_pointer_call
        callee_stats, callee = coder._foreign_freeze(
            ctx, node.exp, nil, "callee")
    else
        error("foreign function body reached a non-C call")
    end
    local stats = { callee_stats }
    local args = {}
    if node._named_arg_order then
        local frozen = {}
        for _, index in ipairs(node._named_arg_order) do
            local arg = node.args.args[index]
            local astats, value = coder._foreign_freeze(
                ctx, arg, signature.params[index], "arg")
            stats[#stats + 1] = astats
            frozen[index] = value
        end
        for index, arg in ipairs(node.args.args) do
            if not frozen[index] then
                local astats, value = coder._foreign_freeze(
                    ctx, arg, signature.params[index], "arg")
                stats[#stats + 1] = astats
                frozen[index] = value
            end
        end
        for index = 1, #signature.params do
            args[index] = assert(frozen[index],
                "named foreign argument was not frozen")
        end
    else
        for index, arg in ipairs(node.args.args) do
            local target = signature.params[index]
            local astats, value = coder._foreign_freeze(
                ctx, arg, target, "arg")
            stats[#stats + 1] = astats
            args[#args + 1] = value
        end
    end
    local call = callee .. "(" .. table.concat(args, ", ") .. ")"
    local ret = types.resolve_c_typedef(signature.ret)
    if ret._tag == "Type.CVoid" then
        stats[#stats + 1] = call .. ";"
        return table.concat(stats, "\n"), "((void)0)"
    end
    local decl, result = coder._foreign_temp(ctx, signature.ret, "result")
    stats[#stats + 1] = decl
    stats[#stats + 1] = result .. " = " .. call .. ";"
    return table.concat(stats, "\n"), result
end

function coder._foreign_raw_exp(ctx, node)
    local tag = node._tag
    if tag == "Ast.ExpNil" then
        return "", "NULL"
    elseif tag == "Ast.ExpBool" then
        return "", node.value and "1" or "0"
    elseif tag == "Ast.ExpInteger" then
        return "", c_integer_literal(node.value)
    elseif tag == "Ast.ExpFloat" then
        return "", c_float_literal(node.value)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpVar" then
        if node._foreign_function_reference then
            return "", coder._foreign_reference_name(
                node._foreign_function_reference)
        end
        return coder._foreign_raw_var(ctx, node.var)
    elseif tag == "Ast.VarName" or tag == "Ast.VarDot"
           or tag == "Ast.VarBracket" then
        return coder._foreign_raw_var(ctx, node)
    elseif tag == "Ast.ExpCall" then
        return coder._foreign_raw_call(ctx, node)
    elseif tag == "Ast.ExpCast" then
        local stats, exp = coder._foreign_raw_exp(ctx, node.exp)
        local operation
        if node._adjustment
           and node._adjustment.kind == "direct_coercion" then
            operation = node._adjustment.coercion.op
        elseif node._written_cast then
            if node._written_cast.op == "coercion" then
                operation = node._written_cast.coercion.op
            elseif node._written_cast.op == "explicit" then
                operation = node._written_cast.conversion.op
                    or node._written_cast.conversion.kind
            end
        elseif node._c_conversion then
            operation = node._c_conversion.op or node._c_conversion.kind
        end
        if operation == "c_address" or operation == "mutable_c_address" then
            return stats, "(&(" .. exp .. "))"
        elseif operation == "c_function_pointer_to_void"
               or operation == "c_void_to_function_pointer" then
            return stats, render("titan_cast_func($TARGET, $SOURCE)", {
                TARGET = coder._render_c_type_name(node._type),
                SOURCE = exp,
            })
        end
        return stats, foreigncast(exp, node._type)
    elseif tag == "Ast.ExpAdjust" then
        return coder._foreign_raw_exp(ctx, node.exp)
    elseif tag == "Ast.ExpUnop" then
        local stats, exp = coder._foreign_freeze(
            ctx, node.exp,
            node._c_operator and node._c_operator.lhs_target or nil,
            "operand")
        local op = node._c_operator and node._c_operator.cop or node.op
        if op == "not" then op = "!" end
        return stats, "(" .. op .. "(" .. exp .. "))"
    elseif tag == "Ast.ExpBinop" then
        local trait = node._c_operator
        local lstats, lhs = coder._foreign_freeze(
            ctx, node.lhs, trait and trait.lhs_target or nil, "lhs")
        local rstats, rhs = coder._foreign_freeze(
            ctx, node.rhs, trait and trait.rhs_target or nil, "rhs")
        local op = trait and trait.cop or node.op
        if op == "~=" then op = "!="
        elseif op == "~" then op = "^"
        elseif op == "and" then op = "&&"
        elseif op == "or" then op = "||" end
        return lstats .. "\n" .. rstats,
            "((" .. lhs .. ") " .. op .. " (" .. rhs .. "))"
    end
    error("unsupported expression in foreign function: " .. tostring(tag))
end

function coder._foreign_raw_lvalue(ctx, node)
    if node._tag == "Ast.VarBracket" then
        local bstats, base = coder._foreign_freeze(
            ctx, node.exp1, nil, "lvalue_base")
        local istats, index = coder._foreign_freeze(
            ctx, node.exp2, nil, "lvalue_index")
        return bstats .. "\n" .. istats,
            "(" .. base .. ")[" .. index .. "]"
    elseif node._tag == "Ast.VarDot"
           and node._decl and node._decl._tag == "Type.CField" then
        local base_type = types.resolve_c_typedef(node.exp._type)
        if base_type._tag == "Type.CPointer" then
            local stats, base = coder._foreign_freeze(
                ctx, node.exp, nil, "lvalue_base")
            return stats, "(" .. base .. ")->" .. node._decl.name
        end
        local base_node = node.exp._tag == "Ast.ExpVar"
            and node.exp.var or node.exp
        if base_node._tag == "Ast.VarName"
           or base_node._tag == "Ast.VarDot"
           or base_node._tag == "Ast.VarBracket" then
            local stats, base = coder._foreign_raw_lvalue(ctx, base_node)
            return stats, "(" .. base .. ")." .. node._decl.name
        end
    end
    return coder._foreign_raw_var(ctx, node)
end

function coder._foreign_raw_block(ctx, block, braces)
    local stats = {}
    for _, stat in ipairs(block.stats) do
        stats[#stats + 1] = coder._foreign_raw_stat(ctx, stat)
        if stat._always_returns then break end
    end
    local body = table.concat(stats, "\n")
    if braces == false then return body end
    return "{\n" .. body .. "\n}"
end

function coder._foreign_raw_stat(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        return coder._foreign_raw_block(ctx, node)
    elseif tag == "Ast.StatDecl" then
        local out, values = {}, {}
        for _, decl in ipairs(node.decls) do
            ctx.local_count = ctx.local_count + 1
            decl._foreign_cname = "_foreign_local_" .. decl.name .. "_"
                .. tostring(ctx.local_count)
            out[#out + 1] = coder._render_c_declaration(
                decl._type, decl._foreign_cname) .. ";"
        end
        for index, exp in ipairs(node.exps) do
            local decl = assert(node.decls[index],
                "foreign local initializer has no declaration")
            local stats, value = coder._foreign_freeze(
                ctx, exp, decl._type, "declaration")
            out[#out + 1] = stats
            values[index] = value
        end
        for index, decl in ipairs(node.decls) do
            out[#out + 1] = decl._foreign_cname .. " = "
                .. assert(values[index],
                    "foreign local declaration has no initializer") .. ";"
        end
        return table.concat(out, "\n")
    elseif tag == "Ast.StatAssign" then
        local out, targets, values = {}, {}, {}
        for _, var in ipairs(node.vars) do
            local stats, target = coder._foreign_raw_lvalue(ctx, var)
            out[#out + 1] = stats
            targets[#targets + 1] = target
        end
        for index, exp in ipairs(node.exps) do
            local target_type = node.vars[index] and node.vars[index]._type
            local stats, value = coder._foreign_freeze(
                ctx, exp, target_type, "assignment")
            out[#out + 1] = stats
            values[index] = value
        end
        for index, target in ipairs(targets) do
            out[#out + 1] = target .. " = " .. values[index] .. ";"
        end
        return table.concat(out, "\n")
    elseif tag == "Ast.StatCall" then
        local stats = coder._foreign_raw_exp(ctx, node.callexp)
        return stats
    elseif tag == "Ast.StatReturn" then
        if #node.exps == 0 then return "return;" end
        local stats, value = coder._foreign_raw_exp(ctx, node.exps[1])
        return stats .. "\nreturn " .. value .. ";"
    elseif tag == "Ast.StatBreak" then
        return "break;"
    elseif tag == "Ast.StatIf" then
        local chunks = {}
        for index, arm in ipairs(node.thens) do
            local stats, condition = coder._foreign_raw_exp(ctx, arm.condition)
            chunks[#chunks + 1] = (index == 1 and "" or "else ")
                .. "{\n" .. stats .. "\nif (" .. condition .. ") "
                .. coder._foreign_raw_block(ctx, arm.block)
                .. "\nelse "
        end
        local tail = node.elsestat
            and coder._foreign_raw_block(ctx, node.elsestat)
            or "{}"
        return table.concat(chunks) .. tail
            .. string.rep("\n}", #node.thens)
    elseif tag == "Ast.StatWhile" then
        local stats, condition = coder._foreign_raw_exp(ctx, node.condition)
        return "while (1) {\n" .. stats .. "\nif (!(" .. condition
            .. ")) break;\n" .. coder._foreign_raw_block(ctx, node.block, false)
            .. "\n}"
    elseif tag == "Ast.StatRepeat" then
        local stats, condition = coder._foreign_raw_exp(ctx, node.condition)
        return "do {\n" .. coder._foreign_raw_block(ctx, node.block, false)
            .. "\n" .. stats .. "\nif (" .. condition .. ") break;\n} while (1);"
    elseif tag == "Ast.StatFor" then
        local start_stats, start = coder._foreign_freeze(
            ctx, node.start, node.decl._type, "for_start")
        local finish_stats, finish = coder._foreign_freeze(
            ctx, node.finish, node.decl._type, "for_finish")
        local step_stats, step = coder._foreign_freeze(
            ctx, node.inc, node.decl._type, "for_step")
        ctx.local_count = ctx.local_count + 1
        node.decl._foreign_cname = "_foreign_for_" .. node.decl.name .. "_"
            .. tostring(ctx.local_count)
        local control = node.decl._foreign_cname
        return table.concat({
            "{", start_stats, finish_stats, step_stats,
            coder._render_c_declaration(node.decl._type, control) .. ";",
            "for (" .. control .. " = " .. start .. "; (" .. step
                .. " >= 0 ? " .. control .. " <= " .. finish .. " : "
                .. control .. " >= " .. finish .. "); " .. control
                .. " += " .. step .. ") "
                .. coder._foreign_raw_block(ctx, node.block),
            "}",
        }, "\n")
    end
    error("unsupported statement in foreign function: " .. tostring(tag))
end

function coder._foreign_function_signature(node)
    local params = {}
    local fixed_index = 1
    for _, param in ipairs(node.params) do
        if param.name ~= false then
            param._foreign_cname = "_param_" .. param.name
            local typ = cdeclarator.adjust_parameter_type(
                node._type.params[fixed_index])
            params[#params + 1] = coder._render_c_declaration(
                typ, param._foreign_cname)
            fixed_index = fixed_index + 1
        end
    end
    local ret = types.resolve_c_typedef(node._type.ret)
    local rettype = ret._tag == "Type.CVoid" and nil or node._type.ret
    return cfunctiondecl(rettype,
        coder._foreign_func_name(node._foreign_module, node.name),
        #params == 0 and "void" or table.concat(params, ", "), false)
end

function coder._code_foreign_function(tlcontext, node, inline)
    local ctx = coder._new_foreign_context(tlcontext)
    local signature = coder._foreign_function_signature(node)
    local body = coder._foreign_raw_block(ctx, node.block, false)
    local storage = inline and "static inline" or "TITAN_SOURCE_LOCAL"
    return storage .. " " .. signature .. " {\n" .. body .. "\n}"
end

-- Titan calling convention:
--     first parameter is a lua_State*; remaining inputs use their actual native
--     C types. The caller never publishes tracing-only Lua-stack copies of those
--     arguments. A callee creates a separate local home only when mutation or
--     setjmp spilling requires one. The function returns its first result
--     directly and writes later results through out parameters. A native caller
--     roots each GC-bearing result immediately after return, before later work
--     can collect it; returning itself cannot run the collector.
local function codefuncdec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local rettype = node._type.rettypes[1]
    local has_function_value = node._tag ~= "Ast.TopLevelFunc"
        or not node.islocal
        or node._closure_upvalue
    local fname, luaname, strictname, tracename
    if node._tag == "Ast.TopLevelFunc" then
        fname = func_name(tlcontext.module, node.name, node.islocal)
        luaname = func_luaname(tlcontext.module, node.name, node.islocal)
        strictname = coder._func_strictname(
            tlcontext.module, node.name, node.islocal)
        tracename = tlcontext.module .. "." .. node.name
        register_trace_name(tlcontext, fname, tracename)
        if has_function_value then
            register_trace_name(tlcontext, strictname, tracename)
        end
    elseif node._tag == "Ast.TopLevelStatic" then
        fname = static_name(node._type)
        luaname = static_luaname(node._type)
        strictname = coder._static_strictname(node._type)
        -- fqtn is "<module>.<record>"; a static is "<module>.<record>.<static>".
        tracename = node._type.fqtn .. "." .. node._type.name
        register_trace_name(tlcontext, fname, tracename)
        register_trace_name(tlcontext, strictname, tracename)
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
        table.insert(cparams,
            cpointerdecl(outtype, "_outparam_" .. i))
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
    -- Calls and allocation/GC helpers can relocate the Lua stack and dangle
    -- `_base`. Any lowering with such a rebase point sets `uses_base_off`, so
    -- the function saves `_base` as an offset for recovery afterward.
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
            setnilvalue2s(_s);
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
    local nativesig = cfunctiondecl(
        rettype, fname, table.concat(cparams, ", "), false)
    node._body = render([[
    $ISLOCAL $SIGNATURE {
        $BODY
    }]], {
        ISLOCAL = node.islocal and "TITAN_SOURCE_LOCAL" or "",
        SIGNATURE = nativesig,
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        $ISLOCAL $SIGNATURE;
    ]], {
        ISLOCAL = node.islocal and "TITAN_SOURCE_LOCAL" or "",
        SIGNATURE = nativesig,
    })
    node._luabody = genluaentry(
        tlcontext, node.name, fname, node._type, node.loc, luaname, {
            dynamic_plans = node._lua_dynamic_plans,
            dynamic_vararg_plan = node._lua_vararg_dynamic_plan,
        })
    if strictname and has_function_value then
        node._strictbody = genluaentry(
            tlcontext, node.name, fname, node._type, node.loc, strictname, {
                strict = true,
                strict_name = strictname,
                lua_entry = luaname,
                strict_plans = node._strict_guard_plans,
                strict_vararg_plan = node._strict_vararg_guard_plan,
            })
        node._sig = node._sig .. "\n    static int " .. strictname
            .. "(lua_State *L);"
    end
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
            setnilvalue2s(_s);
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
-- the closure's `upvalue[4]`. Public methods export these trampolines so a bind
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
    local strictname = coder._bound_method_strictname(mtype)
    local mnative = method_name(mtype)
    local mlua = method_luaname(mtype)
    -- The bound trampoline forwards to the method; if its own native frame ever
    -- appears in a trace, name it after the method (<module>.<record>:<method>).
    register_trace_name(tlcontext, nativename,
        mtype.fqtn .. ":" .. mtype.name)
    register_trace_name(tlcontext, strictname,
        mtype.fqtn .. ":" .. mtype.name)
    local rettype = mtype.rettypes[1]

    -- Named parameter list matching function_sig(ftype) so the trampoline body
    -- can forward each one. Names are local to the trampoline (`_bp_N` for params,
    -- `_outparam_N` for out-params), independent of the method's own _cvar names.
    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    local callargs = { "L", "_mod", "NULL",
        "uvalue(&_fn->upvalue[4])" }
    for i, ptype in ipairs(mtype.params) do
        local pname = "_bp_" .. i
        table.insert(cparams, cvardecl(tlcontext, ptype, pname))
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
        table.insert(cparams,
            cpointerdecl(mtype.rettypes[i], oname))
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
    local storage = node.islocal and "TITAN_SOURCE_LOCAL " or ""
    local strictbody = genluaentry(
        tlcontext, mtype.name, nativename, ftype, node.loc,
        strictname, {
            strict = true,
            strict_name = strictname,
            lua_entry = luaname,
            storage = node.islocal and "TITAN_SOURCE_LOCAL" or "",
            strict_plans = node._bound_strict_guard_plans,
            strict_vararg_plan = node._bound_strict_vararg_guard_plan,
        })
    local nativesig = storage .. cfunctiondecl(
        rettype, nativename, table.concat(cparams, ", "), false)
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
           checks/coercions). upvalue[4] holds the record udata directly (the
           record value IS the udata), which is exactly the Lua-facing value the
           method Lua entry expects. The bound closure's upvalue[0] is the
           method's module, so the method Lua entry recovers _mod correctly from
           it. */
        CClosure *_bound = clCvalue(s2v(L->ci->func.p));
        titan_ensure_stack(L, 1);
        setobj2s(L, L->top.p, &(_bound->upvalue[4]));
        L->top.p++;
        lua_insert(L, 1);
        return $MLUA(L);
    }
    $STRICTBODY]], {
        SIG = nativesig,
        STORAGE = storage,
        BODYCALL = bodycall,
        LUANAME = luaname,
        MLUA = mlua,
        STRICTBODY = strictbody,
    })
    node._boundsig = render([[
        $STORAGE$SIG;
        $STORAGE int $LUANAME(lua_State *L);
        $STORAGE int $STRICTNAME(lua_State *L);
    ]], {
        STORAGE = storage,
        SIG = function_sig(nativename, ftype, false),
        LUANAME = luaname,
        STRICTNAME = strictname,
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
        node._lambda_strict =
            tlcontext.prefix .. "lambda_" .. n .. "_" ..
                TITAN_ENTRY_TAG .. "_strict"
        -- An anonymous function shows as "anonymous function at <file>:<defline>"
        -- (the lambda's DEFINITION loc), formatted into the name table here.
        register_trace_name(tlcontext, node._lambda_native, anon_qualname(node.loc))
        register_trace_name(tlcontext, node._lambda_strict,
            anon_qualname(node.loc))
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
-- upvalue[0]=_mod, [1]=type tag, [2]=native ptr, [3]=closure brand,
-- [4+i]=captured variable i, and the strict LCF in the final upvalue, then
-- return the closure value
-- (anchored in a gc temp). The capture pushes are transient raw stack pushes
-- (guarded by lua_checkstack, consumed by lua_pushcclosure), not
-- nslots-accounted.
function codelambda(ctx, node)
    local tlcontext = ctx.tlcontext
    lambda_register(tlcontext, node)
    local ncap = #node._captures
    local stats = {}
    -- lua_checkstack can relocate the Lua stack; this function therefore needs
    -- _base recomputed from its saved offset afterwards (like a value call).
    ctx.uses_base_off = true
    table.insert(stats, render([[
        titan_ensure_stack(L, $NPUSH);
        titan_pushmodule(L, _mod);
        lua_pushlightuserdata(L, (void*)$FUNCTAG);
        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
        lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
    ]], {
        NPUSH = c_integer_literal(5 + ncap),
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
    table.insert(stats, render([[
        lua_pushcfunction(L, $STRICTNAME);
    ]], {
        STRICTNAME = node._lambda_strict,
    }))
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
        NUP = c_integer_literal(5 + ncap),
        CDECL = cdecl,
        TMPSLOT = tmpslot,
        GETSLOT = getslot(node._type, tmpname, "s2v(L->top.p - 1)"),
    }))
    return table.concat(stats, "\n"), tmpname
end

-- Use-site code for a bound method reference `obj:m`: evaluate the receiver once
-- into a C temp, then build a 6-upvalue CClosure exactly like a
-- 1-capture lambda whose capture is `self`:
--   upvalue[0] = the method's module closure
--   upvalue[1] = the self-removed function-type tag (light userdata)
--   upvalue[2] = the bound native trampoline pointer (light userdata)
--   upvalue[3] = the Titan function-closure brand (light userdata)
--   upvalue[4] = self (the captured receiver)
--   upvalue[5] = the bound strict entry (light C function)
-- The closure's lua_CFunction is the bound Lua trampoline. The result is an
-- ordinary Type.Function value, callable through both paths and Lua-crossable.
function codemethodref(ctx, node)
    local tlcontext = ctx.tlcontext
    local is_interface = node._interface_bound == true
    local mtype = is_interface
        and assert(node._interface_method) or node._method
    local ftype = node._type      -- Type.Function (self removed)
    local nativename = is_interface
        and coder._interface_bound_method_name(mtype)
        or bound_method_name(mtype)
    local luaname = is_interface
        and coder._interface_bound_method_luaname(mtype)
        or bound_method_luaname(mtype)
    local strictname = is_interface
        and coder._interface_bound_method_strictname(mtype)
        or coder._bound_method_strictname(mtype)
    local mod, record = mtype.fqtn:match("^(.*)%.([^.]+)$")

    -- The bound closure's upvalue[0] must be the defining module's closure: `_mod`
    -- for a same-module method, or the imported module's closure recovered from
    -- our `_mod` upvalues exactly as method *calls* do. Cross-module also requires
    -- the trampoline symbol to be reachable (extern / dlsym), registered in
    -- ctx.functions keyed by its mangled name.
    local modexpr = "_mod"
    if mod ~= ctx.module then
        ctx.functions[mtype.fqtn .. (is_interface
                and ":interface-bound:" or ":bound:") .. mtype.name] = {
            module = mod,
            record = record,
            name = mtype.name,
            type = ftype,
            mangled = nativename,
        }
        -- the Lua trampoline (the closure's lua_CFunction) is not function_sig
        -- shaped, so it gets its own extern/dlsym registry entry
        ctx.bound_luas[luaname] = { module = mod }
        ctx.bound_stricts[strictname] = { module = mod }
        if not ctx.modules[mod] then
            ctx.modules[mod] = nextupvalue(ctx.tlcontext)
        end
        modexpr = render("uvalue(&_mod->uv[$INDEX].uv)", {
            INDEX = c_integer_literal(ctx.modules[mod]),
        })
    end

    ctx.uses_base_off = true
    local stats = {}

    -- 1. evaluate the receiver once into a C temp (self: Udata*). Its eventual
    -- stack push below is real closure-upvalue transport, not a tracing copy.
    local rtype = node.exp._type
    local rstat, rexp = codeexp(ctx, node.exp)
    local rdecl, rname = newtmp(ctx, rtype, false)
    table.insert(stats, rstat)
    table.insert(stats, rdecl)
    table.insert(stats, rname .. " = " .. rexp .. ";")

    -- 2. push the six upvalues and build the closure
    table.insert(stats, render([[
        titan_ensure_stack(L, 6);
        titan_pushmodule(L, $MODEXPR);
        lua_pushlightuserdata(L, (void*)$FUNCTAG);
        lua_pushlightuserdata(L, titan_cast_func(void*, $NATIVE));
        lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
        $PUSHSELF L->top.p++;
        lua_pushcfunction(L, $STRICTNAME);
    ]], {
        MODEXPR = modexpr,
        FUNCTAG = function_type_tag(tlcontext, ftype),
        NATIVE = nativename,
        PUSHSELF = setslot(rtype, "s2v(L->top.p)", rname),
        STRICTNAME = strictname,
    }))

    -- 3. consume the freshly allocated closure and publish its initial root
    local cdecl, tmpname, tmpslot = newtmp(ctx, ftype, true)
    table.insert(stats, render([[
        lua_pushcclosure(L, $LUANAME, 6);
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
-- reads captures from _fn->upvalue[4+i]; the ctx.captures map (decl -> {index,
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
        local index = 4 + (i - 1)
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
        table.insert(cparams,
            cpointerdecl(outtype, "_outparam_" .. i))
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
            setnilvalue2s(_s);
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
    local nativesig = cfunctiondecl(
        rettype, fname, table.concat(cparams, ", "), false)
    node._body = render([[
    static $SIGNATURE {
        $BODY
    }]], {
        SIGNATURE = nativesig,
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        static $SIGNATURE;
        static int $LUANAME(lua_State *L);
        static int $STRICTNAME(lua_State *L);
    ]], {
        SIGNATURE = nativesig,
        LUANAME = luaname,
        STRICTNAME = node._lambda_strict,
    })
    node._luabody = genluaentry(
        tlcontext, "lambda", fname, node._type, node.loc, luaname, {
            dynamic_plans = node._lua_dynamic_plans,
            dynamic_vararg_plan = node._lua_vararg_dynamic_plan,
        })
    node._strictbody = genluaentry(
        tlcontext, "lambda", fname, node._type, node.loc,
        node._lambda_strict, {
            strict = true,
            strict_name = node._lambda_strict,
            lua_entry = luaname,
            strict_plans = node._strict_guard_plans,
            strict_vararg_plan = node._strict_vararg_guard_plan,
        })
end

local function codevardec(ctx, initvars, switch_get, switch_set, gvar_map, node)
    local cstats, cexp = codeexp(ctx, node.value)
    node._slot = render("&_mod->uv[$INDEX].uv",
        { INDEX = c_integer_literal(node._upvalue) })
    table.insert(initvars, render([[
        $CSTATS
        {
            $CDECL = $CEXP;
            $SETSLOT
            $BARRIER
        }
    ]], {
        CSTATS = cstats,
        CEXP = cexp,
        CDECL = cvardecl(ctx, node._type, "_var"),
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
            COPYSLOT = copyboxed(ctx, node._type,
                "s2v(L->top.p - 1)", node._slot)
        }))
        table.insert(switch_set, render([[
            case $I: {
                $SETSLOT;
                $BARRIER
                break;
            }
        ]], {
            I = c_integer_literal(node._upvalue),
            SETSLOT = coder._dynamiccheckandset(
                ctx, node._lua_write_dynamic_plan, node._type,
                node._slot, "_value", node.loc, "Lua module-variable write"),
            BARRIER = types.is_gc(node._type)
                      and "luaC_barrierback(L, obj2gco(_mod), " .. node._slot .. ");" or ""
        }))
    end
end

local preamble = [[
$FIXEDPREFIX

$FOREIGNIMPORTS

$AFTERFOREIGNIMPORTS

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
    titan_ensure_stack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
    if(lua_isnil(L, -1)) {
        _initialized = 1;
        lua_pop(L, 1);
        Udata *_mod = luaS_newudata(L, 0, $NUPVALS);
        titan_pushmodule(L, _mod);
        lua_setfield(L, LUA_REGISTRYINDEX, $MODNAMESTR);
        $INITSOURCEIDENTITY
        $INITARRAYMETA
        $LOADMODULES1
        $INITMODULES
        $LOADGLOBALS
        $INITRECORDS
        $INITFUNCTAGS
        $INITPAIRS
        $INITARRAYWRITERS
        $FUNCS
        $INITNAMES
        $INITVARS
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
            $INITPAIRS
            $INITNAMES
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
-- source edge. They follow the public prefix and unconditional Array-metatable
-- slot, and never participate in serialized metadata or Lua member maps.
function coder._source_prefix_layout(modtype)
    return types.source_module_prefix_layout(modtype)
end

-- Generates the code for importing the module, and storing it
-- in the corresponding local state slot
local function import_module(loadmods, initmods, sigs, mprefixes,
                             dynamic, node)
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
        local identity_index = #public_layout + 1
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
        table.insert(loadmods, render([[
            void *$HANDLE = loadlib(L, $FILE);
            titan_check_abi(L, $HANDLE, "$ABI", $FILE);
        ]], {
            HANDLE = mprefix .. "handle",
            FILE = c_string_literal(file),
            ABI = mprefix .. "abi",
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
            -- Public slots occupy 0..N-1, the Array metatable occupies N,
            -- and the source-provider identity occupies N+1.
            local index = #public_layout + 1 + slot
            if entry.kind == "variable" then
                entry.value._upvalue = index
            else
                entry.value._closure_upvalue = index
            end
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
                SETWRAPPED = copyboxed(ctx, field.type,
                    "s2v(L->top.p - 1)", "_slot"),
            }))
            table.insert(setswitch, render([[
                case $INDEX: {
                    $CHECKANDSET;
                    break;
                }
            ]], {
                INDEX = c_integer_literal(field.index),
                CHECKANDSET = coder._dynamiccheckandset(
                    ctx, field.dynamic_plan, field.type, "_dst", "_src",
                    node.loc, "Lua record-field write")
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
            static int $INDEXNAME(lua_State *L) {
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
            static int $NEWINDEXNAME(lua_State *L) {
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
            GETCASES = table.concat(getswitch, "\n"),
            SETCASES = table.concat(setswitch, "\n")
        }))
    else
        table.insert(code, render([[
            static int $INDEXNAME(lua_State *L) {
                return luaL_error(L, "%s:%d:%d: field %s not found in record %s", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
            }
            static int $NEWINDEXNAME(lua_State *L) {
                return luaL_error(L, "%s:%d:%d: field %s not found in record %s", $FILE, $LINE, $COL, lua_tostring(L, 2), $FQTN);
            }
        ]], {
            INDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "index"),
            NEWINDEXNAME = coder._nominal_metamethod_name(
                node._type.name, "newindex"),
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
        lua_pushcclosure(L, $INDEXNAME, 2);
        lua_rawset(L, -4);
        lua_pushliteral(L, "__newindex");
        lua_pushvalue(L, -2);            /* fieldmap */
        titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
        lua_pushcclosure(L, $NEWINDEXNAME, 2);
        lua_rawset(L, -4);
        lua_pop(L, 2); /* pop fieldmap and metatable */
        /* Index from metatable pointer to typename for error messages */
        lua_pushstring(L, "$TYPE");
        lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        TYPE = node._type.name,
        FIELDMAP = table.concat(fieldmap, "\n")
    }))
end

-- Generate the Lua-facing metatable for a union. Variants, tags, and payloads
-- are opaque; only public methods participate in lookup, and all writes fail.
function coder._codeuniondec(ctx, code, initnominals, node)
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
            lua_pushliteral(L, "__metatable");
            lua_pushliteral(L, "Titan union $TYPE");
            lua_rawset(L, -3);
            lua_newtable(L);
            $METHODMAP
            lua_pushliteral(L, "__index");
            lua_pushvalue(L, -2);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $INDEXNAME, 2);
            lua_rawset(L, -4);
            lua_pushliteral(L, "__newindex");
            lua_pushcfunction(L, $NEWINDEXNAME);
            lua_rawset(L, -4);
            lua_pop(L, 2);
            lua_pushstring(L, "$TYPE");
            lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        INDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            node._type.name, "newindex"),
        TYPE = node._type.name,
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
    assert(#node.methods == #interface.methods)

    -- Allocate the owner's cached metatable slot even when no value of this
    -- Interface is constructed in the declaring module. Importing consumers
    -- recover the same registry metatable through type2metatable.
    type2metatable(ctx, types.Nominal(interface.name))

    local methodmap = {}
    for index, method_node in ipairs(node.methods) do
        local method = interface.methods[index]
        coder._code_interface_method_artifacts(
            ctx.tlcontext, sigs, code, interface, method_node, index - 1)
        table.insert(methodmap, render([[
            lua_pushliteral(L, $NAME);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $METHOD, 1);
            lua_rawset(L, -3);
        ]], {
            NAME = c_string_literal(method.name),
            METHOD = coder._interface_method_luaname(method),
        }))
    end

    local receiver_plan =
        assert(node.methods[1]._lua_dynamic_plans[1],
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
            if (TITAN_LIKELY(!tagisempty(_membertag)
                             && ttisCclosure(&_memberv))) {
                setobj2s(L, L->top.p - 1, &_memberv);
                return 1;
            }
            return luaL_error(L,
                "%s:%d:%d: method '%s' not found in interface '%s'",
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
            lua_pushliteral(L, "__metatable");
            lua_pushliteral(L, "Titan interface $TYPE");
            lua_rawset(L, -3);
            lua_newtable(L);
            $METHODMAP
            lua_pushliteral(L, "__index");
            lua_pushvalue(L, -2);
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $INDEXNAME, 2);
            lua_rawset(L, -4);
            lua_pushliteral(L, "__newindex");
            lua_pushcfunction(L, $NEWINDEXNAME);
            lua_rawset(L, -4);
            lua_pop(L, 2);
            lua_pushstring(L, "$TYPE");
            lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
        }
    ]], {
        TYPE = interface.name,
        INDEXNAME = coder._nominal_metamethod_name(
            interface.name, "index"),
        NEWINDEXNAME = coder._nominal_metamethod_name(
            interface.name, "newindex"),
        METHODMAP = table.concat(methodmap, "\n"),
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

    -- Every module has exactly one Array-metatable cache immediately after the
    -- public prefix. This position remains unchanged and reconstructible by
    -- every binary importer.
    tlcontext.array_metatable_upvalue = nextupvalue(tlcontext)

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

function coder.generate_foreign_header(modname, ast, tlcontext)
    local has_foreign = false
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            has_foreign = true
            break
        end
    end
    if not has_foreign then
        ast._foreign_header_include_keys = nil
        return nil
    end

    local guard = "TITAN_GENERATED_FOREIGN_"
        .. coder._source_private_prefix(modname, "header"):upper() .. "_H"
    local direct, supplemental, source_headers = {}, {}, {}
    local seen = {}
    local covered_include_keys = {}
    local function add_include(list, include)
        local line = coder._foreign_include_line(include)
        if include.rendered then
            covered_include_keys[include.rendered] = true
        end
        if not seen[line] then
            seen[line] = true
            list[#list + 1] = line
        end
    end
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignImport" then
            add_include(direct, assert(node._include))
        elseif not node._ignore and node._tag == "Ast.TopLevelImport"
               and node._source_import and node._foreign_header then
            local line = "#include " .. c_string_literal(node._foreign_header)
            if not seen[line] then
                seen[line] = true
                source_headers[#source_headers + 1] = line
            end
        end
    end

    local origins = {}
    local visited = {}
    local function collect_type(typ)
        if type(typ) ~= "table" or not typ._tag
           or not typ._tag:match("^Type%.") then return end
        for _, include in ipairs(types.c_ffi_includes(typ)) do
            if include and include.rendered then
                origins[include.rendered] = include
            end
        end
    end
    local function visit(value)
        if type(value) ~= "table" or visited[value] then return end
        visited[value] = true
        collect_type(value._type)
        if value._decl then
            collect_type(value._decl.type)
            collect_type(value._decl.ctype)
        end
        for key, child in pairs(value) do
            if type(key) ~= "string" or key:sub(1, 1) ~= "_" then
                if type(child) == "table" then
                    if child._tag then
                        visit(child)
                    else
                        for _, item in ipairs(child) do visit(item) end
                    end
                end
            end
        end
    end
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignFunc" then
            visit(node)
        end
    end
    local origin_keys = {}
    for key in pairs(origins) do origin_keys[#origin_keys + 1] = key end
    table.sort(origin_keys, util.bytewise_less)
    for _, key in ipairs(origin_keys) do
        add_include(supplemental, origins[key])
    end

    local includes = {}
    for _, list in ipairs({ direct, supplemental, source_headers }) do
        for _, line in ipairs(list) do includes[#includes + 1] = line end
    end
    ast._foreign_header_include_keys = covered_include_keys

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

    return table.concat({
        "/* Generated by Titan: source foreign function interface. */",
        "#ifndef " .. guard,
        "#define " .. guard,
        "",
        table.concat(includes, "\n"),
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
end

-- Code generation consumes only the ordinary erased checker product. Detached
-- generic surface graphs live exclusively in `_declared_type` metadata on the
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
            for key, child in next, value do
                if not (skip_declared_type and
                        (key == "_declared_type" or
                         key == "_erased_registry")) then
                    enqueue(key)
                    enqueue(child)
                end
            end
        end
    end

    walk(ast, "code-facing AST", true)
    walk(types.registry, "active type registry", false)
end

function coder.generate(modname, ast, static_deps, abi, emit_line_directives)
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
        functag_list = {},   -- same entries, in allocation order (for emission)
        functag_count = 0,
        array_writer_list = {}, -- constructed Array element policies
        array_writer_count = 0,
        interface_pairs = {}, -- canonical concrete/interface key -> exact pair
        interface_pair_list = {}, -- pair entries in discovery order
        callable_adapters = {}, -- frozen plan object -> translation-unit site
        callable_adapter_list = {}, -- growing discovery-order site registry
        callable_adapter_count = 0,
        bound_luas = {},     -- mangled bound-Lua-trampoline name -> { module }
        bound_stricts = {},  -- mangled bound-strict-entry name -> { module }
        static_slots = {},   -- "fqtn.name" -> module upvalue slot of a static's closure
        nominal_namespace_slots = {}, -- nominal fqtn -> module uv slot of its static-namespace table
        lambdas = {},        -- ExpFunction nodes pending file-scope emission
        lambda_count = 0,    -- counter for unique lambda native/Lua names
        names = {},          -- { native C symbol, qualified Titan name } pairs for the trace name table
        source_foreign_headers = {},
        upvalue = 0
    }

    local funcs = {}
    local initvars = {}
    local includes = {}
    local sigs = {}
    local direct_foreign_includes = {}
    local direct_foreign_include_keys = {}
    local supplemental_foreign_includes = {}
    local function add_foreign_include(include, direct)
        local key = assert(include.rendered,
            "foreign include has no normalized spelling")
        if direct then
            if direct_foreign_include_keys[key] then return end
            direct_foreign_include_keys[key] = true
            direct_foreign_includes[#direct_foreign_includes + 1] = include
        elseif not supplemental_foreign_includes[key] then
            supplemental_foreign_includes[key] = include
        end
    end
    coder._ffi_include_collector = add_foreign_include
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
            elseif tag == "Ast.TopLevelForeignImport" then
                add_foreign_include(assert(node._include), true)
            elseif tag == "Ast.TopLevelVar" then
                codevardec(initctx, initvars, switch_get, switch_set, gvar_map, node)
            elseif tag == "Ast.TopLevelRecord" then
                coderecorddec(initctx, code, initrecs, node)
            elseif tag == "Ast.TopLevelUnion" then
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
                            lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
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
                        lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
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
                            lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
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
                            lua_pushlightuserdata(L, TITAN_FUNCTION_CLOSURE_BRAND);
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

    -- Interface pair payloads are process-static function-pointer arrays.
    -- Exact slots point at concrete methods; adjusted slots point at private
    -- relation-free adapters emitted from checker-frozen action graphs. They
    -- are filled only after imported native symbols have been recovered, on
    -- both module-initialization branches, and before user initializers can
    -- construct a wrapper. The wrapper copies the complete array by sizeof.
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
        table.insert(sigs, render([[
            static TitanInterfaceMethod $ID[$COUNT];
        ]], {
            ID = pair.id,
            COUNT = c_integer_literal(#pair.methods),
        }))
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
    local metadata, metadata_err =
        staticmetadata.render(modname, abi, serialized_type)
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
                lua_pushliteral(L, $DISPLAY);
                lua_setfield(L, -2, "__name");
                lua_pushliteral(L, "__metatable");
                lua_pushliteral(L, $DISPLAY);
                lua_settable(L, -3);
                lua_pushvalue(L, -1);
                lua_setfield(L, LUA_REGISTRYINDEX, $NAME);
            } else if (!lua_istable(L, -1)) {
                luaL_error(L,
                    "invalid Titan owned C metatable registry entry");
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
    -- in _init by publish-or-recover through the Lua registry. C-free function
    -- types share registry keys across modules; C-bearing types are scoped to
    -- the defining module because imported C type identity is module-local.
    local initfunctags = {}
    for _, entry in ipairs(tlcontext.functag_list) do
        table.insert(sigs, "static const void *" .. entry.id .. ";")
        table.insert(initfunctags, render([[
            $ID = titan_publish_function_type_tag(
                L, $KEYSTR, (const void *)&$ID);
        ]], {
            ID = entry.id,
            KEYSTR = c_string_literal(
                "Titan function type " .. entry.registry_key .. " tag"),
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
        MODNAMESTR = c_string_literal("Titan module "..modname),
        INITSOURCEIDENTITY = render([[
            setpvalue(&_mod->uv[$INDEX].uv, (void *)$IDENTITY());
        ]], {
            INDEX = c_integer_literal(tlcontext.source_identity_upvalue),
            IDENTITY = source_identity,
        }),
        INITARRAYMETA = render([[
            {
                Table *_array_metatable = titan_array_metatable(L);
                sethvalue(L, &_mod->uv[$INDEX].uv, _array_metatable);
                luaC_barrierback(L, obj2gco(_mod),
                    &_mod->uv[$INDEX].uv);
            }
        ]], {
            INDEX = c_integer_literal(tlcontext.array_metatable_upvalue),
        }),
        CREATEMETA = create_meta,
        MODULEINIT = moduleinit,
        NUPVALS = tlcontext.upvalue
    }))

    table.insert(code, render(postamble, {
        LUAOPEN_NAME = 'luaopen_' .. mangle_qn(modname),
        INITNAME = tlcontext.prefix .. 'init',
    }))

    local foreignimports = {}
    if ast._foreign_header_output then
        -- The generated companion reproduces the checked direct-FFI block and
        -- every source-foreign dependency before its declarations. Including
        -- only that companion here avoids requiring user C headers to be
        -- self-idempotent merely because this module has foreign functions.
        foreignimports[#foreignimports + 1] =
            "#include " .. c_string_literal(ast._foreign_header_output)
    else
        for _, include in ipairs(direct_foreign_includes) do
            foreignimports[#foreignimports + 1] =
                coder._foreign_include_line(include)
        end
        for _, header in ipairs(tlcontext.source_foreign_headers) do
            foreignimports[#foreignimports + 1] =
                "#include " .. c_string_literal(header)
        end
    end
    local supplemental_keys = {}
    for key in pairs(supplemental_foreign_includes) do
        if not direct_foreign_include_keys[key]
           and not (ast._foreign_header_output
               and ast._foreign_header_include_keys
               and ast._foreign_header_include_keys[key]) then
            supplemental_keys[#supplemental_keys + 1] = key
        end
    end
    table.sort(supplemental_keys, util.bytewise_less)
    for _, key in ipairs(supplemental_keys) do
        foreignimports[#foreignimports + 1] = coder._foreign_include_line(
            supplemental_foreign_includes[key])
    end

    local preamble_substs = {
        FIXEDPREFIX =
            require("titan-compiler.cpreamble").fixed_prefix,
        AFTERFOREIGNIMPORTS =
            require("titan-compiler.cpreamble").after_foreign_imports,
        INCLUDES = table.concat(includes, "\n"),
        SIGS = table.concat(sigs, "\n"),
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
    for _, func in pairs(tlcontext.functions) do
        if static_deps[func.module] == true then
            direct_native_modules[func.module] = true
        end
    end
    for _, info in pairs(tlcontext.bound_luas) do
        if static_deps[info.module] == true then
            direct_native_modules[info.module] = true
        end
    end
    for _, info in pairs(tlcontext.bound_stricts) do
        if static_deps[info.module] == true then
            direct_native_modules[info.module] = true
        end
    end

    local foreign_header = coder.generate_foreign_header(
        modname, ast, tlcontext)
    coder._ffi_include_collector = nil
    local source = preamble .. "\n\n" .. table.concat(code, "\n\n")
    -- A `#line` directive applies its number to the immediately following
    -- physical source line. Template substitutions can contribute blank
    -- lines after a standalone directive; remove every such semantic line
    -- before clang-format so native frames retain the exact Titan location. The
    -- formatter preserves this spelling, so one pass remains a fixed point.
    local removed
    repeat
        source, removed = source:gsub(
            "([ \t]*#line[^\n]*\n)[ \t]*\n", "%1")
    until removed == 0
    return source, direct_native_modules, foreign_header
end

return coder
