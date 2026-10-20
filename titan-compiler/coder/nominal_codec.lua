local core = require "titan-compiler.coder.core"
local _ENV = core

-- Compiler-generated protobuf codecs for public records and unions.
--
-- Each eligible nominal gets one straight-line encoder and one canonical-wire
-- decoder over its own native storage plan. They replicate titan.protobuf's
-- reflective codec exactly on the inputs they accept and otherwise decline
-- with status 0 (see titan-runtime/transfer.h): no generated code raises a
-- codec error, runs a transfer hook or registered resource codec, loads a
-- module, or enters Lua. The declaring module publishes the entries in its
-- TitanTransferModule manifest and binds each canonical metatable to its entry
-- under TITAN_MT_CODEC during nominal registration.

local HOOKS = { "to_transfer_payload", "from_transfer_payload" }

-- protobuf.titan's field_number: wire numbering skips 19000..19999.
local function field_number(ordinal)
    if ordinal >= 19000 then return ordinal + 1000 end
    return ordinal
end

local function key_bits(number, wire)
    return string.format("%d", number * 8 + wire)
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
-- nominal whose complete field or variant list is public. Imported
-- interfaces expose only public members, so compare against the full count.
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

local eligible_owner

-- A field descriptor the generated code handles directly, or nil. Nested
-- nominals must themselves be statically eligible, so a root whose declared
-- graph reaches an endpoint, hook, private, or reflective-only nominal never
-- attempts the generated path. Runtime lookup remains authoritative.
local function field_kind(typ, active)
    typ = erased(typ)
    local tag = typ._tag
    if tag == "Type.Nil" or tag == "Type.Boolean" or tag == "Type.Integer"
        or tag == "Type.Float" or tag == "Type.String" then
        return { tag = tag }
    elseif tag == "Type.Nominal" then
        local owner = nominal_owner(typ)
        if owner and eligible_owner(owner, active) then
            return { tag = tag, owner = owner, type = types.Nominal(owner.name) }
        end
    elseif tag == "Type.Option" then
        local base = field_kind(typ.base, active)
        if base and base.tag ~= "Type.Nil" then
            return { tag = tag, base = base }
        end
    end
    return nil
end

local eligibility = setmetatable({}, { __mode = "k" })

-- Cycles assume eligibility while in progress; the runtime binding lookup
-- still declines a nested nominal that has no codec.
eligible_owner = function(owner, active)
    local known = eligibility[owner]
    if known ~= nil then return known end
    active = active or {}
    if active[owner] then return true end
    if not all_public(owner) or has_hooks(owner) then
        eligibility[owner] = false
        return false
    end
    active[owner] = true
    local ok = true
    local lists = owner._tag == "Type.Record" and { owner.fields } or {}
    if owner._tag == "Type.Union" then
        for _, variant in ipairs(owner.variants) do lists[#lists + 1] = variant.parts end
    end
    for _, list in ipairs(lists) do
        for _, field in ipairs(list) do
            if not field_kind(field.type, active) then ok = false break end
        end
        if not ok then break end
    end
    active[owner] = nil
    eligibility[owner] = ok
    return ok
end

local function uv_of(slot)
    return coder._nominal_uv(slot, "_rec")
end

local function encode_scalar(tag, key_number, expression)
    if tag == "Type.Integer" then
        return "if (!titan_protobuf_buf_write_varint(_buf, INT64_C(" .. key_bits(key_number, 0)
            .. ")) || !titan_protobuf_buf_write_varint(_buf, titan_codec_zigzag("
            .. expression .. "))) return 0;"
    elseif tag == "Type.Boolean" then
        return "if (!titan_protobuf_buf_write_varint(_buf, INT64_C(" .. key_bits(key_number, 0)
            .. ")) || !titan_protobuf_buf_write_varint(_buf, (" .. expression
            .. ") ? 1 : 0)) return 0;"
    elseif tag == "Type.Float" then
        return "if (!titan_protobuf_buf_write_double(_buf, INT64_C(" .. key_bits(key_number, 1)
            .. "), " .. expression .. ")) return 0;"
    end
    error("unexpected generated codec scalar " .. tag)
end

local function encode_reference(kind, key_number, source)
    if kind.tag == "Type.String" then
        return "titan_codec_write_string(_buf, INT64_C(" .. key_bits(key_number, 2)
            .. "), " .. source .. ")"
    end
    return "titan_codec_encode_nested(L, _resources, _buf, " .. source .. ", "
        .. c_string_literal(kind.owner.name) .. ", "
        .. (kind.owner._tag == "Type.Union" and "1" or "0")
        .. ", INT64_C(" .. key_bits(key_number, 2) .. "), &_self, _depth + 1)"
end

-- Encoder:field for one declared field or part.
local function encode_field(plan, field, kind, number)
    local slot = assert(plan.by_index[field.index], "generated codec slot")
    local tag = kind.tag
    if tag == "Type.Nil" then
        return "/* nil field " .. number .. " emits no wire field */"
    elseif tag == "Type.String" or tag == "Type.Nominal" then
        assert(slot.storage == "uv")
        return "if (!" .. encode_reference(kind, number, uv_of(slot)) .. ") return 0;"
    elseif tag == "Type.Option" then
        local base = kind.base
        if base.tag == "Type.String" or base.tag == "Type.Nominal" then
            assert(slot.storage == "uv")
            local source = uv_of(slot)
            return "if (!ttisnil(" .. source .. ") && !"
                .. encode_reference(base, number, source) .. ") return 0;"
        end
        assert(slot.storage == "payload" and slot.kind == "option")
        local member = coder._nominal_member(plan, slot, "_rec")
        return "if ((" .. member .. ").present) {\n"
            .. encode_scalar(base.tag, number, "(" .. member .. ").value") .. "\n}"
    end
    assert(slot.storage == "payload" and slot.kind == "scalar")
    return encode_scalar(tag, number, coder._nominal_member(plan, slot, "_rec"))
end

local function decode_scalar(tag, destination)
    if tag == "Type.Integer" then
        return "if (!titan_codec_read_varint(_data, _length, &_position, &_bits)) goto decline;\n"
            .. destination .. " = titan_codec_unzigzag(_bits);"
    elseif tag == "Type.Boolean" then
        return "if (!titan_codec_read_varint(_data, _length, &_position, &_bits) || _bits > 1) goto decline;\n"
            .. destination .. " = (int)_bits;"
    elseif tag == "Type.Float" then
        return "if (!titan_codec_take_fixed64(_data, _length, &_position, &_number)) goto decline;\n"
            .. destination .. " = _number;"
    end
    error("unexpected generated codec scalar " .. tag)
end

local function wire_of(tag)
    if tag == "Type.Integer" or tag == "Type.Boolean" then return 0 end
    if tag == "Type.Float" then return 1 end
    return 2
end

local function decode_reference(ctx, kind, destination)
    if kind.tag == "Type.String" then
        return "if (!titan_codec_take_slice(_data, _length, &_position, &_offset, &_count)) goto decline;\n"
            .. "setsvalue(L, " .. destination
            .. ", luaS_newlstr(L, (const char *)_data + _offset, _count));\n"
            .. "luaC_barrierback(L, obj2gco(_rec), " .. destination .. ");"
    end
    return "if (!titan_codec_take_slice(_data, _length, &_position, &_offset, &_count)) goto decline;\n"
        .. "if (!titan_codec_decode_nested(L, _resources, &_mod->uv["
        .. c_integer_literal(type2metatable(ctx, kind.type))
        .. "].uv, _data + _offset, _count, _depth + 1)) goto decline;\n"
        .. "setobj(L, " .. destination .. ", s2v(L->top.p - 1));\n"
        .. "luaC_barrierback(L, obj2gco(_rec), " .. destination .. ");\n"
        .. "L->top.p--;"
end

-- decode_field for one declared field on canonical wire: the next key is this
-- field's exact key or the field is absent here. Absent required fields,
-- unconsumed (unknown, duplicate, or reordered) fields, and every wire
-- anomaly decline into the reflective decoder.
local function decode_field(ctx, plan, field, kind, number)
    local slot = assert(plan.by_index[field.index], "generated codec slot")
    local tag = kind.tag
    if tag == "Type.Nil" then
        return "/* nil field " .. number .. " is absent on canonical wire */"
    end
    local required = tag ~= "Type.Option"
    local base = required and kind or kind.base
    local body
    if base.tag == "Type.String" or base.tag == "Type.Nominal" then
        assert(slot.storage == "uv")
        body = decode_reference(ctx, base, uv_of(slot))
    elseif required then
        assert(slot.storage == "payload" and slot.kind == "scalar")
        body = decode_scalar(base.tag, coder._nominal_member(plan, slot, "_rec"))
    else
        assert(slot.storage == "payload" and slot.kind == "option")
        local member = coder._nominal_member(plan, slot, "_rec")
        body = decode_scalar(base.tag, "(" .. member .. ").value")
            .. "\n(" .. member .. ").present = 1;"
    end
    return render([[
        _taken = titan_codec_take_key(_data, _length, &_position, UINT64_C($KEY));
        if (_taken < 0) goto decline;
        if (_taken) {
            $BODY
        }$MISSING
    ]], {
        KEY = key_bits(number, wire_of(base.tag)),
        BODY = body,
        MISSING = required and " else goto decline;" or "",
    })
end

local function encode_fields(plan, fields)
    local code = {}
    for ordinal, field in ipairs(fields) do
        code[#code + 1] = encode_field(plan, field,
            assert(field_kind(field.type)), field_number(ordinal))
    end
    return table.concat(code, "\n")
end

local function decode_fields(ctx, plan, fields)
    local code = {}
    for ordinal, field in ipairs(fields) do
        code[#code + 1] = decode_field(ctx, plan, field,
            assert(field_kind(field.type)), field_number(ordinal))
    end
    return table.concat(code, "\n")
end

local DECODE_LOCALS = [[
    size_t _position = 0;
    size_t _offset = 0;
    size_t _count = 0;
    uint64_t _bits = 0;
    double _number = 0;
    int _taken = 0;
    ptrdiff_t _saved;
    Udata *_rec;
    (void)_resources; (void)_offset; (void)_count;
    (void)_bits; (void)_number; (void)_taken;
]]

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

local function emit_record(ctx, owner, encode, decode)
    local plan = coder._nominal_plan(ctx, owner)
    return render([[
        static int $ENCODE(lua_State *L, const TValue *_resources,
            titan_protobuf_buffer *_buf, Udata *_rec, const TitanCodecPath *_path,
            int _depth) {
            TitanCodecPath _self;
            (void)L; (void)_resources;
            if (_depth >= TITAN_CODEC_DEPTH_LIMIT || titan_codec_on_path(_path, _rec))
                return 0;
            _self.object = _rec;
            _self.parent = _path;
            (void)_self;
            $ENCODE_FIELDS
            return 1;
        }
        static int $DECODE(lua_State *L, const TValue *_resources, Udata *_mod,
            const uint8_t *_data, size_t _length, int _depth) {
            $LOCALS
            if (_depth >= TITAN_CODEC_DEPTH_LIMIT)
                return 0;
            titan_ensure_stack(L, 2);
            _saved = savestack(L, L->top.p);
            $ALLOCATE
            $DECODE_FIELDS
            if (_position != _length) goto decline;
            return 1;
        decline:
            L->top.p = restorestack(L, _saved);
            return 0;
        }
    ]], {
        ENCODE = encode,
        DECODE = decode,
        LOCALS = DECODE_LOCALS,
        ALLOCATE = allocate(ctx, plan, owner),
        ENCODE_FIELDS = encode_fields(plan, owner.fields),
        DECODE_FIELDS = decode_fields(ctx, plan, owner.fields),
    })
end

local function emit_union(ctx, owner, encode, decode)
    local encode_cases, decode_cases = {}, {}
    for ordinal, variant in ipairs(owner.variants) do
        local plan = coder._nominal_plan(ctx, owner, variant)
        local number = field_number(ordinal)
        encode_cases[#encode_cases + 1] = render([[
            case $TAG: {
                int64_t _mark = titan_protobuf_buf_begin_nested(_buf, INT64_C($KEY));
                if (_mark < 0) return 0;
                $PARTS
                return titan_protobuf_buf_end_nested(_buf, _mark) > 0;
            }
        ]], {
            TAG = c_integer_literal(variant.index),
            KEY = key_bits(number, 2),
            PARTS = encode_fields(plan, variant.parts),
        })
        decode_cases[#decode_cases + 1] = render([[
            case UINT64_C($KEY): {
                $ALLOCATE
                $TAGFIELD = $TAG;
                $PARTS
                break;
            }
        ]], {
            KEY = key_bits(number, 2),
            ALLOCATE = allocate(ctx, plan, owner),
            TAGFIELD = coder._nominal_tag("_rec"),
            TAG = c_integer_literal(variant.index),
            PARTS = decode_fields(ctx, plan, variant.parts),
        })
    end
    return render([[
        static int $ENCODE(lua_State *L, const TValue *_resources,
            titan_protobuf_buffer *_buf, Udata *_rec, const TitanCodecPath *_path,
            int _depth) {
            TitanCodecPath _self;
            (void)L; (void)_resources;
            if (_depth >= TITAN_CODEC_DEPTH_LIMIT || titan_codec_on_path(_path, _rec))
                return 0;
            _self.object = _rec;
            _self.parent = _path;
            (void)_self;
            switch ($UNIONTAG) {
                $ENCODE_CASES
                default:
                    return 0;
            }
        }
        static int $DECODE(lua_State *L, const TValue *_resources, Udata *_mod,
            const uint8_t *_data, size_t _length, int _depth) {
            $LOCALS
            uint64_t _key = 0;
            if (_depth >= TITAN_CODEC_DEPTH_LIMIT)
                return 0;
            titan_ensure_stack(L, 2);
            /* Canonical oneof: exactly one recognized length-delimited variant. */
            if (!titan_codec_read_varint(_data, _length, &_position, &_key)
                || !titan_codec_take_slice(_data, _length, &_position, &_offset, &_count)
                || _position != _length)
                return 0;
            _data += _offset;
            _length = _count;
            _position = 0;
            _saved = savestack(L, L->top.p);
            switch (_key) {
                $DECODE_CASES
                default:
                    return 0;
            }
            if (_position != _length) goto decline;
            return 1;
        decline:
            L->top.p = restorestack(L, _saved);
            return 0;
        }
    ]], {
        ENCODE = encode,
        DECODE = decode,
        LOCALS = DECODE_LOCALS,
        UNIONTAG = coder._nominal_tag("_rec"),
        ENCODE_CASES = table.concat(encode_cases, "\n"),
        DECODE_CASES = table.concat(decode_cases, "\n"),
    })
end

-- Emit the codec pair for one source nominal declaration and register its
-- manifest entry. Returns nothing for ineligible nominals.
function coder._codec_emit(ctx, code, node)
    local owner = node._type
    if node.islocal or not eligible_owner(owner) then return end
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
    code[#code + 1] = emit(ctx, owner, entry.encode, entry.decode)
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
