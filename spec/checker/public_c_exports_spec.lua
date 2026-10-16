local h = require "spec.support.helpers"
local temporary = require "spec.support.temporary"
local types = require "titan-compiler.types"
local driver = require "titan-compiler.driver"
local layout = require "titan-compiler.nominallayout"

local function with_header(body)
    local path = temporary.name(".h")
    local other = temporary.name(".h")
    local contents = [[
        typedef struct public_native_point {
            int x;
            int samples[2 + 3];
            struct public_native_point *next;
        } public_native_point;
    ]]
    for _, filename in ipairs({path, other}) do
        local file = assert(io.open(filename, "w"))
        assert(file:write(contents))
        assert(file:close())
    end
    local results = table.pack(xpcall(function() return body(path, other) end,
        debug.traceback))
    os.remove(path)
    os.remove(other)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function imports(path)
    return "foreign import " .. string.format("%q", path) .. "\n"
end

describe("public named C declaration exports", function()
    it("checks compiled aggregate fields against the consumer's real header", function()
        with_header(function(header)
            local ok, err, imported = h.run_checker_modules({
                provider = imports(header) .. [[
                    record Box
                        point: foreign public_native_point
                    end
                ]],
                consumer = imports(header) .. [[
                    local provider = import "provider"
                    function read(box: provider.Box): integer
                        return box.point.x + box.point.samples[0]
                    end
                ]],
            }, "consumer")
            assert.truthy(ok, err)
            local exported = imported.provider.type.members.Box.type.fields[1].type
            assert.is_string(exported.origin)
            assert.is_nil(exported._c_origin_header)
            assert.equal("Type.CStruct", exported.target._tag)
            assert.is_true(types.equals(exported.target, exported.target.fields.next.type.pointee))
        end)
    end)

    it("rejects missing headers and same-spelled declarations from another header", function()
        with_header(function(header, other)
            for _, consumer_header in ipairs({"", imports(other)}) do
                local ok, err = h.run_checker_modules({
                    provider = imports(header) .. [[
                        record Box
                            point: foreign public_native_point
                        end
                    ]],
                    consumer = consumer_header .. [[local provider = import "provider"]],
                }, "consumer")
                assert.falsy(ok)
                assert.match("imported C declaration .- is not visible", err)
                assert.match("foreign import its declaring header", err)
            end
        end)
    end)

    it("retains explicit source-import C header inheritance", function()
        with_header(function(header)
            local ok, err = h.run_checker_modules({
                provider = imports(header) .. [[
                    record Box
                        point: foreign public_native_point
                    end
                ]],
                consumer = [[
                    local provider = import "provider.titan"
                    function read(box: provider.Box): integer return box.point.x end
                ]],
            }, "consumer")
            assert.truthy(ok, err)
        end)
    end)

    it("round-trips recursive named graphs and symbolic extents in native layouts", function()
        local aggregate = types.CStruct(nil, "node", nil, {}, true, false, "node.h")
        local alias = types.CTypedef("node_t", aggregate, {}, "node.h")
        local integer = types.CInteger("int", true, 3, 32)
        local count = types.CField(aggregate, "count", integer, nil, false)
        local samples = types.CField(aggregate, "samples", types.CArray(
            integer, {op="+", "2", "3"}, {}), nil, false)
        local next_node = types.CField(aggregate, "next", types.CPointer(alias, {}), nil, false)
        aggregate.fields = {count, samples, next_node, count=count, samples=samples, next=next_node}
        local mod = types.Module("sample", {}, {First=aggregate, Second=aggregate, Alias=alias})
        local decoded = assert(driver.decode_module_interface(types.serialize(mod), "sample"))
        assert.is_true(types.equals(decoded.type_members.First, aggregate))
        local owner = types.Record("sample.Box", {
            types.Field("sample.Box", "node", aggregate, 0, false),
        }, {}, {}, 1)
        local plan = assert(layout.record(owner))
        local restored = assert(layout.decode(assert(layout.encode("sample", {plan})), "sample"))
        assert.is_true(types.equals(aggregate, restored.records[owner.name].by_index[0].type))
    end)

    it("rejects conflicting typedef targets and malformed aggregate names", function()
        local first = types.CTypedef("native_word", types.CInteger("int", true, 3, 32), {}, "word.h")
        local other = types.CTypedef("native_word", types.CFloat("double"), {}, "word.h")
        local decoded, err = driver.decode_module_interface(types.serialize(
            types.Module("sample", {}, {First=first, Second=other})), "sample")
        assert.is_nil(decoded)
        assert.match("duplicate C declaration identity", err)
        for _, names in ipairs({
            {"invalid;tag", "ValidAlias"}, {"ValidTag", "invalid;alias"},
        }) do
            local aggregate = types.CStruct(nil, names[1], names[2], {}, true, false, "word.h")
            assert.is_false(types.is_exportable_c_type_graph(aggregate))
            local plan = assert(layout.record(types.Record("sample.Box", {
                types.Field("sample.Box", "item", aggregate, 0, false),
            }, {}, {}, 1)))
            assert.is_nil(layout.encode("sample", {plan}))
            decoded, err = driver.decode_module_interface(types.serialize(
                types.Module("sample", {}, {Native=aggregate})), "sample")
            assert.is_nil(decoded)
            assert.match("invalid declaration identity", err)
        end
    end)

    it("rejects forged array expressions and inconsistent duplicate C identities", function()
        assert.is_false(types.valid_c_extent("1]; int injected; int a[1"))
        assert.is_false(types.valid_c_extent({op="+", "1", "2", unknown="state"}))
        local left = types.CStruct(nil, "node", nil, {}, true, false, "node.h")
        local right = types.clone_graph(left)
        right.fields = {types.CField(right, "changed", types.CInteger("int", true, 3, 32), nil, false)}
        local value, err = driver.decode_module_interface(types.serialize(
            types.Module("sample", {}, {First=left, Second=right})), "sample")
        assert.is_nil(value)
        assert.match("duplicate C declaration identity", err)
    end)
end)
