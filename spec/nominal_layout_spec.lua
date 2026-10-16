local types = require "titan-compiler.types"
local layout = require "titan-compiler.nominallayout"
local graphcodec = require "titan-compiler.graphcodec"

local function field(name, typ, index, private, isconst, owner)
    local result = types.Field(owner or "sample.Record", name, typ, index, isconst == true)
    result.islocal = private == true
    return result
end

local function record(fields, name)
    return types.Record(name or "sample.Record", fields, {}, {}, #fields)
end

local function cint()
    return types.CInteger("int", true, 3, 32)
end

local function cstruct(name, fields, fam)
    return types.CStruct(nil, name, nil, fields or {}, true, fam == true)
end

local function rejected(fn, fragment)
    local value, err = fn()
    assert.is_nil(value)
    assert.is_string(err)
    assert.truthy(err:find(fragment, 1, true), err)
end

describe("nominal physical layouts", function()
    it("compacts public and private GC slots without changing logical ordinals", function()
        local owner = record({
            field("hidden_number", types.Integer(), 0, true),
            field("title", types.String(), 1),
            field("hidden_child", types.Value(), 2, true),
            field("ready", types.Boolean(), 3),
            field("count", cint(), 4),
        })
        local before = types.serialize(owner)
        local plan = assert(layout.record(owner))
        assert.equal(2, plan.nuv)
        assert.equal(1, plan.npublicuv)
        assert.same({3, 4, 0}, {plan.members[1].index,
            plan.members[2].index, plan.members[3].index})
        assert.equal(0, plan.by_name.title.uv_index)
        assert.equal(1, plan.by_name.hidden_child.uv_index)
        assert.equal("_public.f3", plan.by_index[3].path)
        assert.equal("f0", plan.by_index[0].path)
        assert.is_true(plan.complete)
        assert.is_true(plan.has_private)
        assert.equal(before, types.serialize(owner))
        assert.is_nil(owner.fields[1].uv_index)
    end)

    it("represents all-raw, all-GC, and empty records without fake GC slots", function()
        local raw = assert(layout.record(record({
            field("i", types.Integer(), 0), field("b", types.Boolean(), 1),
            field("f", types.Float(), 2), field("nil_slot", types.Nil(), 3),
        })))
        assert.equal(0, raw.nuv)
        assert.equal(4, #raw.public_members)
        local gc = assert(layout.record(record({
            field("s", types.String(), 0),
            field("a", types.Array(types.Integer(), {tag="no"}), 1),
            field("f", types.Function({}, {}, false, nil, nil), 2),
        })))
        assert.equal(3, gc.nuv)
        assert.equal(0, #gc.members)
        local empty = assert(layout.record(record({})))
        assert.equal(0, empty.nuv)
        assert.equal(0, #empty.members)
    end)

    it("classifies the erased generic carrier rather than a concrete application", function()
        local scope = types.GenericScope("sample", "sample.Record", nil,
            "owner", "record")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local plan = assert(layout.record(record({field("item", parameter, 0)})))
        assert.equal("uv", plan.slots[1].storage)
        assert.equal("Type.Value", plan.slots[1].type._tag)
        assert.equal("Type.Parameter", parameter._tag)
    end)

    it("keeps TValue, Udata pointers, owned values, and optional GC bases traced", function()
        local tvalue = cstruct("TValue")
        local udata = types.CPointer(cstruct("Udata"), {})
        for _, typ in ipairs({tvalue, udata, types.CTypedef("SavedValue", tvalue),
            types.COwned(cint(), false), types.Option(types.String()),
            types.Option(tvalue), types.Option(udata), types.Nominal("sample.Other")}) do
            assert.equal("uv", assert(layout.classify(typ)).storage)
        end
        assert.equal("payload", assert(layout.classify(
            types.CPointer(cstruct("TValue"), {}))).storage)
    end)

    it("retains native unsigned and extended floating types in optional payloads", function()
        local wide = types.CInteger("unsigned long long", false, 5, 64)
        for _, base in ipairs({wide, types.CFloat("long double"), types.Integer(),
            types.Boolean(), types.CPointer(cint(), {})}) do
            local result = assert(layout.classify(types.Option(base)))
            assert.equal("payload", result.storage)
            assert.equal("option", result.kind)
            assert.equal(base, result.base.type)
            assert.equal(base, result.type.base)
        end
    end)

    it("classifies fixed aggregates and typedef arrays while preserving their C declarations", function()
        local point = cstruct("point", {
            types.CField(nil, "x", cint(), nil, false),
            types.CField(nil, "y", cint(), nil, false),
        })
        local alias = types.CTypedef("int_four", types.CArray(cint(), 4))
        assert.equal("aggregate", assert(layout.classify(point)).kind)
        local array = assert(layout.classify(alias))
        assert.equal("array", array.kind)
        assert.equal(alias, array.type)
        local union = types.CUnion(nil, "choice", nil, {
            types.CField(nil, "point", point, nil, false),
            types.CField(nil, "bytes", alias, nil, false),
        }, true)
        assert.equal("aggregate", assert(layout.classify(union)).kind)
    end)

    it("normalizes uncounted array views without discarding C pointee constness", function()
        local view = types.CTypedef("const_view", types.CArray(cint(), nil, {"const"}))
        local result = assert(layout.classify(view))
        assert.equal("scalar", result.kind)
        assert.equal("Type.CPointer", result.type._tag)
        assert.same({"const"}, result.type.quals)
        assert.equal("Type.CArray", view.target._tag)
    end)

    it("rejects incomplete, FAM, and recursively GC-bearing by-value objects", function()
        local incomplete = types.CStruct(nil, "opaque", nil, {}, false, false)
        rejected(function() return layout.classify(incomplete) end, "incomplete")
        assert.equal("scalar", assert(layout.classify(types.CPointer(incomplete, {}))).kind)
        local fam = cstruct("packet", {
            types.CField(nil, "data", types.CArray(cint(), nil), nil, true),
        }, true)
        local nested = types.CUnion(nil, "nested", nil, {
            types.CField(nil, "packet", fam, nil, false),
        }, true)
        rejected(function() return layout.classify(nested) end, "FAM")
        local bearing = cstruct("bearing", {
            types.CField(nil, "values", types.CArray(cstruct("TValue"), 4), nil, false),
        })
        rejected(function() return layout.classify(bearing) end, "GC-bearing")
        rejected(function() return layout.classify(types.CArray(cint(), 0)) end, "extent")
    end)

    it("keeps an empty zero tag and sparse public union tags with one-based parts", function()
        local fqtn = "sample.Message"
        local empty = types.Variant(fqtn, "empty", {}, 0)
        local hidden = types.Variant(fqtn, "hidden", {
            field("private_value", cint(), 1, false, false, fqtn),
        }, 1)
        hidden.islocal = true
        local message = types.Variant(fqtn, "message", {
            field("count", types.Integer(), 1, false, false, fqtn),
            field("text", types.String(), 2, false, false, fqtn),
            field("enabled", types.Option(types.Boolean()), 3, false, false, fqtn),
        }, 2)
        local owner = types.Union(fqtn, {empty, hidden, message}, {}, {}, 3)
        local pempty = assert(layout.variant(owner, empty))
        local phidden = assert(layout.variant(owner, hidden))
        local pmessage = assert(layout.variant(owner, message))
        assert.equal(0, pempty.tag)
        assert.equal(0, pempty.nuv)
        assert.equal(0, pempty.arity)
        assert.equal("header", pmessage.header_member)
        assert.equal("tag", pmessage.tag_member)
        assert.equal(0, pmessage.by_index[2].uv_index)
        assert.equal("p1", pmessage.by_index[1].path)
        assert.is_false(pmessage.by_index[1].isconst)
        assert.is_nil(layout.public(phidden))
        local decoded = assert(layout.decode(assert(layout.encode("sample",
            {pempty, phidden, pmessage})), "sample"))
        assert.equal(0, decoded.variants[fqtn][0].arity)
        assert.is_nil(decoded.variants[fqtn][1])
        assert.equal(3, decoded.variants[fqtn][2].arity)
    end)

    it("publishes only the public prefix and UV map of a record with private C members", function()
        local hidden = cstruct("secret_native_type", {
            types.CField(nil, "native", cint(), nil, false),
        })
        local plan = assert(layout.record(record({
            field("secret_field", hidden, 0, true),
            field("public_count", cint(), 1),
            field("private_root", types.Value(), 2, true),
            field("public_text", types.String(), 3),
        })))
        local bytes = assert(layout.encode("sample", {[plan.name] = plan}))
        assert.is_nil(bytes:find("secret_native_type", 1, true))
        assert.is_nil(bytes:find("secret_field", 1, true))
        assert.is_nil(bytes:find("private_root", 1, true))
        local public = assert(layout.decode(bytes, "sample")).records[plan.name]
        assert.is_false(public.complete)
        assert.is_true(public.has_private)
        assert.equal(4, public.nfields)
        assert.equal(1, public.nuv)
        assert.is_nil(public.by_index[0])
        assert.is_nil(public.by_index[2])
        assert.equal("_public.f1", public.by_index[1].path)
        assert.equal("Type.CInteger", public.by_index[1].type._tag)
        assert.equal(0, public.by_index[3].uv_index)
        assert.is_nil(public.by_index[3].type)
    end)

    it("round-trips portable native declarations and complete constructor layouts", function()
        local callback = types.CPointer(types.CFunction({cint()},
            types.CVoid(), false, nil), {})
        local plan = assert(layout.record(record({
            field("pointer", types.CPointer(cint(), {"const"}), 0),
            field("callback", callback, 1),
            field("wide", types.Option(types.CInteger("unsigned long long", false, 5, 64)), 2),
            field("precise", types.Option(types.CFloat("long double")), 3),
        })))
        local public = assert(layout.decode(assert(layout.encode("sample", {plan})))).records[plan.name]
        assert.is_true(public.complete)
        assert.equal(0, public.nuv)
        for index, slot in ipairs(plan.slots) do
            assert.is_true(types.equals(slot.type, public.slots[index].type))
        end
        assert.equal("long double", public.by_index[3].base.type.spelling)
    end)

    it("omits source-local nominal owners and rejects public nonportable C layouts", function()
        local owner = record({field("pointer", types.CPointer(cstruct("private"), {}), 0)})
        local plan = assert(layout.record(owner))
        rejected(function() return layout.encode("sample", {plan}) end, "portable")
        owner.islocal = true
        plan = assert(layout.record(owner))
        local decoded = assert(layout.decode(assert(layout.encode("sample", {plan}))))
        assert.same({}, decoded.layouts)
    end)

    it("distinguishes generated names with underscores, dots, and dashes", function()
        local names = {"a.b_c", "a_b.c", "a-b.C", "a_b.C", "a._2eb"}
        local seen = {}
        for _, fqtn in ipairs(names) do
            local cname = assert(layout.record(record({}, fqtn))).cname
            assert.is_nil(seen[cname])
            assert.truthy(cname:match("^[A-Za-z_][A-Za-z0-9_]*$"))
            seen[cname] = true
        end
    end)

    it("encodes maps deterministically and rejects duplicate owners", function()
        local a = assert(layout.record(record({}, "sample.A")))
        local b = assert(layout.record(record({}, "sample.B")))
        assert.equal(assert(layout.encode("sample", {a, b})),
            assert(layout.encode("sample", {z = b, a = a})))
        rejected(function() return layout.encode("sample", {a, a}) end, "duplicate")
    end)

    it("rejects malformed closed metadata instead of fabricating layout facts", function()
        local plan = assert(layout.record(record({
            field("text", types.String(), 0), field("count", cint(), 1),
        })))
        local encoded = assert(layout.encode("sample", {plan}))
        local function changed(mutate, fragment)
            local wire = assert(graphcodec.decode(encoded))
            mutate(wire)
            rejected(function()
                return layout.decode(assert(graphcodec.encode(wire)), "sample")
            end, fragment)
        end
        changed(function(w) w.extra = true end, "index")
        changed(function(w) w[2] = 99 end, "incompatible")
        changed(function(w) w[4][1][6][1][5] = 1 end, "dense")
        changed(function(w) w[4][1][6][2][5] = "f999" end, "member name")
        changed(function(w) w[4][1][6][2][6] = {"Type.CStruct"} end, "aggregate declaration")
        changed(function(w) w[4][1][6][2][6][5] = 0 end, "exportable")
        changed(function(w) w[4][1][6][2][1] = 0 end, "ordered")
        changed(function(w) w[4][1][6][2] = nil end, "missing slots")
        changed(function(w) w[4][1][2] = "foreign.Record" end, "another module")
        rejected(function() return layout.decode(encoded, "other") end, "module name")
        rejected(function() return layout.decode(encoded:sub(1, -2)) end, "checksum")
    end)
end)
