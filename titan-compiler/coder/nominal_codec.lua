local core = require "titan-compiler.coder.core"
local _ENV = core

-- Compiler-generated protobuf codecs for public records and unions.
--
-- Each eligible nominal gets one encoder and one decoder specialized to its
-- native storage plan (titan-runtime/transfer.h). They are titan.protobuf's
-- reflective codec for that nominal: identical wire, identical error strings
-- raised at identical points, and no decline. Scalars, strings, and nested
-- records/unions are handled natively; a nested nominal re-enters its own
-- generated codec when it has one. Every other field, and every merged or
-- otherwise unusual wire form, is handed to the reflective field codec through
-- titan.protobuf's fixed handoff entry with the shared root state. The
-- declaring module emits the entries in one static array beside its transfer
-- manifest, whose layout is unchanged, and binds each canonical metatable
-- under TITAN_MT_CODEC.

local HOOKS = { "to_transfer_payload", "from_transfer_payload" }

-- protobuf.titan's field_number: wire numbering skips 19000..19999.
local function field_number(ordinal)
    if ordinal >= 19000 then return ordinal + 1000 end
    return ordinal
end

local function key_bits(number, wire)
    return string.format("INT64_C(%d)", number * 8 + wire)
end

local function erased(typ)
    if types.contains_generic(typ) then return types.erase(typ) end
    return typ
end

local function nominal_owner(typ)
    local owner = types.registry[typ.fqtn]
    if owner and (owner._tag == "Type.Record" or owner._tag == "Type.Union") then
        return owner
    end
    return nil
end

local function has_hooks(owner)
    for _, name in ipairs(HOOKS) do
        if (owner.methods and owner.methods[name])
            or (owner.functions and owner.functions[name]) then
            return true
        end
    end
    return false
end

-- The reflective require_record/require_union visibility rule: a public
-- nominal whose complete field or variant list is public.
local function all_public(owner)
    if owner.islocal then return false end
    if owner._tag == "Type.Record" then
        for _, field in ipairs(owner.fields) do
            if field.islocal then return false end
        end
        return (owner.nfields or #owner.fields) == #owner.fields
    end
    for _, variant in ipairs(owner.variants) do
        if variant.islocal then return false end
    end
    return (owner.nvariants or #owner.variants) == #owner.variants
end

-- Field types the reflective codec can encode at all. A nominal with any
-- other field (callables, Maps, Interfaces, `value`, owned or union C types)
-- stays entirely reflective: no generated code for a field that always raises.
local function encodable(typ)
    typ = erased(typ)
    local tag = typ._tag
    if tag == "Type.Option" then return encodable(typ.base) end
    if tag == "Type.Nil" or tag == "Type.Boolean" or tag == "Type.Integer"
        or tag == "Type.Float" or tag == "Type.String" or tag == "Type.Array" then
        return true
    end
    if tag == "Type.Nominal" then return nominal_owner(typ) ~= nil end
    if types.is_direct_c(typ) then
        local resolved = types.resolve_c_typedef(typ)._tag
        return resolved == "Type.CInteger" or resolved == "Type.CFloat"
            or resolved == "Type.CPointer" or resolved == "Type.CStruct"
            or resolved == "Type.CArray"
    end
    return false
end

-- The natively encoded kind of a field, or nil for a reflective handoff.
local function native_kind(typ)
    typ = erased(typ)
    local tag = typ._tag
    if tag == "Type.Nil" or tag == "Type.Boolean" or tag == "Type.Integer"
        or tag == "Type.Float" or tag == "Type.String" then
        return { tag = tag }
    elseif tag == "Type.Nominal" then
        local owner = nominal_owner(typ)
        if owner then
            return { tag = tag, owner = owner, type = types.Nominal(owner.name) }
        end
    elseif tag == "Type.Option" then
        local base = native_kind(typ.base)
        if base and base.tag ~= "Type.Nil" then
            return { tag = tag, base = base }
        end
    end
    return nil
end

-- A generated decoder keeps one 32-byte directory entry per declared field
-- (a union: per variant plus every variant's parts) on the C stack, at up to
-- 128 nesting levels. Wider nominals stay reflective, whose per-level C stack
-- use does not grow with field count, so deep wide graphs raise the nesting
-- error instead of exhausting the C stack.
local DIRECTORY_LIMIT = 64

local function eligible(node)
    local owner = node._type
    if node.islocal or not all_public(owner) or has_hooks(owner) then
        return false
    end
    local lists = owner._tag == "Type.Record" and { owner.fields } or {}
    local entries = owner._tag == "Type.Record" and #owner.fields or 0
    if owner._tag == "Type.Union" then
        entries = #owner.variants
        for _, variant in ipairs(owner.variants) do
            lists[#lists + 1] = variant.parts
            entries = entries + #variant.parts
        end
    end
    if entries > DIRECTORY_LIMIT then return false end
    for _, list in ipairs(lists) do
        for _, field in ipairs(list) do
            if not encodable(field.type) then return false end
        end
    end
    return true
end

local function uv_of(slot)
    return coder._nominal_uv(slot, "_rec")
end

-- The reflective descriptor coordinates of one field: its declaring nominal,
-- 1-based variant ordinal (0 for a record), and 1-based field ordinal.
local function coordinates(env, ordinal)
    return {
        OWNER = c_string_literal(env.owner.name),
        VARIANT = c_integer_literal(env.variant),
        INDEX = c_integer_literal(ordinal),
    }
end

local function nominal_args(kind)
    return c_string_literal(kind.owner.name) .. ", "
        .. (kind.owner._tag == "Type.Union" and "1" or "0")
end

local function encode_scalar(tag, number, expression)
    if tag == "Type.Integer" then
        return "titan_codec_put_varint(L, _st->buf, " .. key_bits(number, 0)
            .. ", titan_codec_zigzag(" .. expression .. "));"
    elseif tag == "Type.Boolean" then
        return "titan_codec_put_varint(L, _st->buf, " .. key_bits(number, 0)
            .. ", (" .. expression .. ") ? 1 : 0);"
    elseif tag == "Type.Float" then
        return "titan_codec_put_double(L, _st->buf, " .. key_bits(number, 1)
            .. ", " .. expression .. ");"
    end
    error("unexpected generated codec scalar " .. tag)
end

local function encode_reference(kind, number, source, env, ordinal)
    if kind.tag == "Type.String" then
        return "titan_codec_put_string(L, _st->buf, " .. key_bits(number, 2)
            .. ", " .. source .. ");"
    end
    local where = coordinates(env, ordinal)
    return "titan_codec_put_nominal(L, _st, " .. source .. ", " .. nominal_args(kind)
        .. ", " .. number .. ", &_self, _depth + 1, " .. where.OWNER .. ", "
        .. where.VARIANT .. ", " .. where.INDEX .. ");"
end

-- Encoder:field for one declared field or part at depth `_depth + 1`. The
-- enclosing frame has already checked that depth.
local function encode_field(ctx, plan, env, field, ordinal)
    local slot = assert(plan.by_index[field.index], "generated codec slot")
    local number = field_number(ordinal)
    local kind = native_kind(field.type)
    if not kind then
        local where = coordinates(env, ordinal)
        return render([[
            {
                titan_ensure_stack(L, 2);
                $PROJECT
                titan_codec_encode_handoff(L, _st, TITAN_CODEC_ENCODE_FIELD,
                    $OWNER, $VARIANT, $INDEX, $NUMBER, &_self, _depth + 1,
                    s2v(L->top.p - 1));
                L->top.p--;
            }
        ]], {
            PROJECT = coder._reflection_projection(ctx, plan, field, "_rec"),
            OWNER = where.OWNER, VARIANT = where.VARIANT, INDEX = where.INDEX,
            NUMBER = c_integer_literal(number),
        })
    end
    local tag = kind.tag
    if tag == "Type.Nil" then
        return "/* nil field " .. number .. " emits no wire field */"
    elseif tag == "Type.String" or tag == "Type.Nominal" then
        assert(slot.storage == "uv")
        return encode_reference(kind, number, uv_of(slot), env, ordinal)
    elseif tag == "Type.Option" then
        local base = kind.base
        if base.tag == "Type.String" or base.tag == "Type.Nominal" then
            assert(slot.storage == "uv")
            local source = uv_of(slot)
            return "if (!ttisnil(" .. source .. ")) {\n"
                .. encode_reference(base, number, source, env, ordinal) .. "\n}"
        end
        assert(slot.storage == "payload" and slot.kind == "option")
        local member = coder._nominal_member(plan, slot, "_rec")
        return "if ((" .. member .. ").present) {\n"
            .. encode_scalar(base.tag, number, "(" .. member .. ").value") .. "\n}"
    end
    assert(slot.storage == "payload" and slot.kind == "scalar")
    return encode_scalar(tag, number, coder._nominal_member(plan, slot, "_rec"))
end

local function decode_scalar(tag, field, data, destination)
    if tag == "Type.Integer" then
        return destination .. " = titan_codec_get_integer(L, " .. field .. ");"
    elseif tag == "Type.Boolean" then
        return destination .. " = titan_codec_get_boolean(L, " .. field .. ");"
    elseif tag == "Type.Float" then
        return destination .. " = titan_codec_get_float(L, " .. field .. ", " .. data .. ");"
    end
    error("unexpected generated codec scalar " .. tag)
end

local function store_top(destination)
    return "setobj(L, " .. destination .. ", s2v(L->top.p - 1));\n"
        .. "luaC_barrierback(L, obj2gco(_rec), " .. destination .. ");\n"
        .. "L->top.p--;"
end

local function decode_reference(ctx, kind, field, number, env, ordinal, destination)
    if kind.tag == "Type.String" then
        return "{ TString *_text = titan_codec_get_string(L, " .. field .. ", "
            .. env.data .. ");\n"
            .. "setsvalue(L, " .. destination .. ", _text);\n"
            .. "luaC_barrierback(L, obj2gco(_rec), " .. destination .. "); }"
    end
    local where = coordinates(env, ordinal)
    return "titan_codec_get_nominal(L, _st, &_mod->uv["
        .. c_integer_literal(type2metatable(ctx, kind.type)) .. "].uv, "
        .. nominal_args(kind) .. ", " .. field .. ", " .. number .. ", "
        .. env.data .. ", " .. env.length .. ", _depth + 1, " .. where.OWNER .. ", "
        .. where.VARIANT .. ", " .. where.INDEX .. ", _scratch);\n" .. store_top(destination)
end

-- Whether decoding a field can call titan_codec_decode_field, which reuses
-- the frame's one-field Message slot (`_scratch`).
local function decodes_reflectively(kind)
    if not kind then return true end
    local base = kind.tag == "Type.Option" and kind.base or kind
    return kind.tag == "Type.Nil" or base.tag == "Type.Nominal"
end

-- decode_field for one declared field or part at depth `_depth + 1`, from
-- the latest occurrence in the parsed directory. A field without a native
-- kind, and a present nil-typed field (whose nested slice the reflective
-- decoder validates), use the reflective field decoder: on the field's single
-- occurrence, or on the whole message when the field repeats. An absent
-- optional field is nil without a handoff, as decode_field returns nil before
-- touching it. A reflective result stays on the stack (`_scratch` + k) until
-- store_results, because the reflective constructor converts fields only
-- after decode_record has decoded every one of them.
local function decode_field(ctx, plan, env, field, ordinal)
    local slot = assert(plan.by_index[field.index], "generated codec slot")
    local number = field_number(ordinal)
    local entry = "&" .. env.fields .. "[" .. (ordinal - 1) .. "]"
    local kind = native_kind(field.type)
    local where = coordinates(env, ordinal)
    local handoff = render([[
        titan_codec_decode_field(L, _st, $OWNER, $VARIANT, $INDEX, $NUMBER,
            $ENTRY, $DATA, $LENGTH, _depth + 1, _scratch);
    ]], {
        OWNER = where.OWNER, VARIANT = where.VARIANT, INDEX = where.INDEX,
        NUMBER = c_integer_literal(number), ENTRY = entry, DATA = env.data,
        LENGTH = env.length,
    })
    if not kind then
        if erased(field.type)._tag == "Type.Option" then
            return "if ((" .. entry .. ")->count == 0) {\n"
                .. "setnilvalue(s2v(L->top.p));\nL->top.p++;\n} else {\n"
                .. handoff .. "\n}"
        end
        return handoff
    end
    local tag = kind.tag
    if tag == "Type.Nil" then
        return "if ((" .. entry .. ")->count != 0) {\n" .. handoff .. "\nL->top.p--;\n}"
    end
    local required = tag ~= "Type.Option"
    local base = required and kind or kind.base
    local body
    if base.tag == "Type.String" or base.tag == "Type.Nominal" then
        assert(slot.storage == "uv")
        body = decode_reference(ctx, base, entry, number, env, ordinal, uv_of(slot))
    elseif required then
        assert(slot.storage == "payload" and slot.kind == "scalar")
        body = decode_scalar(base.tag, entry, env.data,
            coder._nominal_member(plan, slot, "_rec"))
    else
        assert(slot.storage == "payload" and slot.kind == "option")
        local member = coder._nominal_member(plan, slot, "_rec")
        body = decode_scalar(base.tag, entry, env.data, "(" .. member .. ").value")
            .. "\n(" .. member .. ").present = 1;"
    end
    if required then
        return "titan_codec_need(L, " .. entry .. ", " .. number .. ");\n" .. body
    end
    return "if ((" .. entry .. ")->count != 0) {\n" .. body .. "\n}"
end

local function encode_fields(ctx, plan, env, fields)
    local code = {}
    if #fields > 0 then code[1] = "titan_codec_depth(L, _depth + 1);" end
    for ordinal, field in ipairs(fields) do
        code[#code + 1] = encode_field(ctx, plan, env, field, ordinal)
    end
    return table.concat(code, "\n")
end

-- The reflective constructor's storage steps, rooted before any field.
local function allocate(ctx, plan, owner)
    return render([[
        _rec = luaS_newudata(L, $SIZE, $NUV);
        setuvalue(L, s2v(L->top.p), _rec);
        L->top.p++;
        _rec->metatable = hvalue(&_mod->uv[$META].uv);
        memset(getudatamem(_rec), 0, $SIZE);
    ]], {
        SIZE = coder._nominal_size(plan),
        NUV = c_integer_literal(plan.nuv),
        META = c_integer_literal(type2metatable(ctx, types.Nominal(owner.name))),
    })
end

-- A decoding frame's Lua stack plan: its record, then (when a field can
-- decode reflectively) the one-field Message slot `_scratch` followed by one
-- result per field without a native kind, plus one transient slot.
local function decode_plan(fields)
    local scratch, results = false, 0
    for _, field in ipairs(fields) do
        local kind = native_kind(field.type)
        if decodes_reflectively(kind) then scratch = true end
        if not kind then results = results + 1 end
    end
    return scratch, results
end

local function decode_fields(ctx, plan, env, node, fields)
    local scratch, results = decode_plan(fields)
    local code = { "titan_codec_reserve(L, " .. (2 + (scratch and 1 or 0) + results) .. ");" }
    code[#code + 1] = allocate(ctx, plan, env.owner)
    if env.variant > 0 then code[#code + 1] = env.tag end
    if scratch then
        code[#code + 1] = "_scratch = savestack(L, L->top.p);\n"
            .. "setnilvalue(s2v(L->top.p));\nL->top.p++;"
    end
    if #fields > 0 then code[#code + 1] = "titan_codec_depth(L, _depth + 1);" end
    local reflective = {}
    for ordinal, field in ipairs(fields) do
        code[#code + 1] = decode_field(ctx, plan, env, field, ordinal)
        if not native_kind(field.type) then reflective[#reflective + 1] = field end
    end
    -- store_results: construction conversions in field order, after decoding.
    for k, field in ipairs(reflective) do
        code[#code + 1] = "{ TValue _source = *s2v(restorestack(L, _scratch) + "
            .. k .. ");\n"
            .. coder._reflection_store(ctx, node.loc, plan, field, "_rec", "&_source")
            .. "\n}"
    end
    if scratch then code[#code + 1] = "L->top.p = restorestack(L, _scratch);" end
    return table.concat(code, "\n")
end

-- Whether encoding the fields can run Titan code (a handoff, a resource
-- codec, or a nested frame that hands off): such a frame roots its record on
-- the Lua stack, since a hook may drop the last reference to it.
local function encodes_reflectively(fields)
    for _, field in ipairs(fields) do
        local kind = native_kind(field.type)
        if not kind then return true end
        local base = kind.tag == "Type.Option" and kind.base or kind
        if base.tag == "Type.Nominal" then return true end
    end
    return false
end

local ROOT_RECORD = "titan_codec_reserve(L, 1);\n"
    .. "setuvalue(L, s2v(L->top.p), _rec);\nL->top.p++;"

local function emit_record(ctx, node, encode, decode)
    local owner = node._type
    local plan = coder._nominal_plan(ctx, owner)
    local env = {
        owner = owner, variant = 0, fields = "_fields",
        data = "_data", length = "_length",
    }
    local rooted = encodes_reflectively(owner.fields)
    return render([[
        static void $ENCODE(lua_State *L, TitanCodecState *_st, Udata *_rec,
            const TitanCodecPath *_path, int _depth) {
            TitanCodecPath _self;
            titan_codec_depth(L, _depth);
            titan_codec_enter(L, _st, _path, _rec);
            _self.object = obj2gco(_rec);
            _self.parent = _path;
            (void)_self;
            $ROOT
            $ENCODE_FIELDS
            $UNROOT
        }
        static void $DECODE(lua_State *L, TitanCodecState *_st, Udata *_mod,
            const uint8_t *_data, size_t _length, int _depth) {
            TitanCodecField _fields[$CAPACITY];
            Udata *_rec;
            ptrdiff_t _scratch = -1;
            (void)_scratch;
            titan_codec_parse(L, _data, _length, _fields, $COUNT);
            titan_codec_depth(L, _depth);
            $DECODE_FIELDS
        }
    ]], {
        ENCODE = encode,
        DECODE = decode,
        CAPACITY = c_integer_literal(math.max(#owner.fields, 1)),
        COUNT = c_integer_literal(#owner.fields),
        ROOT = rooted and ROOT_RECORD or "",
        UNROOT = rooted and "L->top.p--;" or "",
        ENCODE_FIELDS = encode_fields(ctx, plan, env, owner.fields),
        DECODE_FIELDS = decode_fields(ctx, plan, env, node, owner.fields),
    })
end

local function emit_union(ctx, node, encode, decode)
    local owner = node._type
    local encode_cases, decode_cases = {}, {}
    for ordinal, variant in ipairs(owner.variants) do
        local plan = coder._nominal_plan(ctx, owner, variant)
        local env = {
            owner = owner, variant = ordinal, fields = "_parts",
            data = "_part_data", length = "_part_length",
            tag = coder._nominal_tag("_rec") .. " = "
                .. c_integer_literal(variant.index) .. ";",
        }
        local rooted = encodes_reflectively(variant.parts)
        encode_cases[#encode_cases + 1] = render([[
            case $TAG: {
                int64_t _mark;
                $ROOT
                _mark = titan_codec_begin(L, _st, $KEY);
                $PARTS
                titan_codec_end(L, _st, _mark);
                $UNROOT
                return;
            }
        ]], {
            TAG = c_integer_literal(variant.index),
            KEY = key_bits(field_number(ordinal), 2),
            ROOT = rooted and ROOT_RECORD or "",
            UNROOT = rooted and "L->top.p--;" or "",
            PARTS = encode_fields(ctx, plan, env, variant.parts),
        })
        decode_cases[#decode_cases + 1] = render([[
            case $ORDINAL: {
                const uint8_t *_part_data = _data + _variants[$SLOT].offset;
                size_t _part_length = _variants[$SLOT].length;
                TitanCodecField _parts[$CAPACITY];
                ptrdiff_t _scratch = -1;
                (void)_scratch;
                titan_codec_parse(L, _part_data, _part_length, _parts, $COUNT);
                $PARTS
                return;
            }
        ]], {
            ORDINAL = c_integer_literal(ordinal),
            SLOT = c_integer_literal(ordinal - 1),
            CAPACITY = c_integer_literal(math.max(#variant.parts, 1)),
            COUNT = c_integer_literal(#variant.parts),
            PARTS = decode_fields(ctx, plan, env, node, variant.parts),
        })
    end
    return render([[
        static void $ENCODE(lua_State *L, TitanCodecState *_st, Udata *_rec,
            const TitanCodecPath *_path, int _depth) {
            TitanCodecPath _self;
            titan_codec_depth(L, _depth);
            titan_codec_enter(L, _st, _path, _rec);
            _self.object = obj2gco(_rec);
            _self.parent = _path;
            (void)_self;
            switch ($UNIONTAG) {
                $ENCODE_CASES
                default:
                    titan_codec_raise(L, "protobuf: private union variant");
                    return;
            }
        }
        static void $DECODE(lua_State *L, TitanCodecState *_st, Udata *_mod,
            const uint8_t *_data, size_t _length, int _depth) {
            TitanCodecField _variants[$CAPACITY];
            Udata *_rec;
            uint32_t _selected;
            titan_codec_parse(L, _data, _length, _variants, $COUNT);
            _selected = titan_codec_single(_variants, $COUNT);
            if (_selected == 0) {
                /* Zero, repeated, replaced, or non-message variants. */
                titan_codec_reserve(L, 1);
                titan_codec_decode_handoff(L, _st, TITAN_CODEC_DECODE_NOMINAL,
                    $NAME, 0, 0, 0, _data, _length, _depth);
                return;
            }
            titan_codec_depth(L, _depth);
            switch (_selected) {
                $DECODE_CASES
                default:
                    titan_codec_raise(L, "protobuf: union has no recognized variant");
                    return;
            }
        }
    ]], {
        ENCODE = encode,
        DECODE = decode,
        UNIONTAG = coder._nominal_tag("_rec"),
        CAPACITY = c_integer_literal(math.max(#owner.variants, 1)),
        COUNT = c_integer_literal(#owner.variants),
        NAME = c_string_literal(owner.name),
        ENCODE_CASES = table.concat(encode_cases, "\n"),
        DECODE_CASES = table.concat(decode_cases, "\n"),
    })
end

-- Emit the codec pair for one source nominal declaration and register its
-- manifest entry. Ineligible nominals stay entirely reflective.
function coder._codec_emit(ctx, code, node)
    if not eligible(node) then return end
    local owner = node._type
    local tlcontext = ctx.tlcontext or ctx
    tlcontext.transfer_codecs = tlcontext.transfer_codecs or {}
    tlcontext.transfer_codec_index = tlcontext.transfer_codec_index or {}
    local entry = {
        name = owner.name,
        is_union = owner._tag == "Type.Union",
        encode = coder._nominal_function_prefix(owner.name, "codec_encode"),
        decode = coder._nominal_function_prefix(owner.name, "codec_decode"),
        index = #tlcontext.transfer_codecs,
    }
    tlcontext.transfer_codecs[#tlcontext.transfer_codecs + 1] = entry
    tlcontext.transfer_codec_index[owner.name] = entry
    local emit = entry.is_union and emit_union or emit_record
    code[#code + 1] = emit(ctx, node, entry.encode, entry.decode)
end

-- Metatable registration lines binding a nominal to its manifest entry.
function coder._codec_binding(ctx, node)
    local tlcontext = ctx.tlcontext or ctx
    local entry = tlcontext.transfer_codec_index
        and tlcontext.transfer_codec_index[node._type.name]
    if not entry then return "" end
    return render([[
        lua_pushconstlightuserdata(L, &${PREFIX}transfer_codecs[$INDEX]);
        lua_rawsetp(L, -2, TITAN_MT_CODEC);
    ]], {
        PREFIX = tlcontext.prefix,
        INDEX = c_integer_literal(entry.index),
    })
end

-- The immutable manifest array; NULL with no generated codecs.
function coder._codec_emit_table(tlcontext, code)
    local entries = tlcontext.transfer_codecs or {}
    if #entries == 0 then return "NULL", 0 end
    local initializers = {}
    for _, entry in ipairs(entries) do
        initializers[#initializers + 1] = render([[
            { $NAME, $UNION, $ENCODE, $DECODE }
        ]], {
            NAME = c_string_literal(entry.name),
            UNION = entry.is_union and "1" or "0",
            ENCODE = entry.encode,
            DECODE = entry.decode,
        })
    end
    local array = tlcontext.prefix .. "transfer_codecs"
    code[#code + 1] = "static const TitanTransferCodec " .. array
        .. "[] = {\n" .. table.concat(initializers, ",\n") .. "\n};"
    return array, #entries
end
