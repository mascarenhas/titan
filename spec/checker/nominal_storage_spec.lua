local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local probe_session

local declarations = [[
    #include "titan/ffi.h"
    typedef struct ns_point { int x; int y; } ns_point;
    typedef const ns_point ns_const_point;
    typedef union ns_cell { int count; double number; } ns_cell;
    typedef int ns_row[3];
    typedef int ns_short_row[2];
    typedef int ns_symbolic_row[(1 + 2)];
    typedef const int ns_const_row[3];
    typedef int ns_incomplete_row[];
    typedef struct ns_incomplete ns_incomplete;
    typedef struct ns_packet { int count; char data[]; } ns_packet;
    typedef union ns_packet_union { ns_packet packet; int tag; } ns_packet_union;
    typedef struct ns_packet_outer { ns_packet_union storage; } ns_packet_outer;
    typedef struct ns_gc_value { TValue value; } ns_gc_value;
    typedef union ns_gc_union { Udata *object; int count; } ns_gc_union;
    typedef struct ns_gc_outer { ns_gc_union cells[2]; } ns_gc_outer;
    static ns_row ns_source_row;
    static ns_short_row ns_source_short_row;
]]

local function with_header(fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    assert(file:write(declarations))
    assert(file:close())
    local results = table.pack(pcall(fn, function(body)
        return h.run_checker(
            'foreign import "' .. header .. '"\n' .. body,
            probe_session)
    end))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function declaration(ast, name, tag)
    for _, node in ipairs(ast) do
        if node.name == name and (not tag or node._tag == tag) then
            return node
        end
    end
    error("missing declaration " .. name)
end

local function uncast(exp)
    while exp._tag == "Ast.ExpCast" do exp = exp.exp end
    return exp
end

describe("nominal native storage checking", function()
    setup(function()
        probe_session = h.new_checker_probe_session()
    end)

    teardown(function()
        h.close_checker_probe_session(probe_session)
        probe_session = nil
    end)

    it("normalizes written unsized nominal arrays and constructor parameters to borrowed pointers",
    function()
        local ok, err, ast = h.run_checker([[
            local record Buffer
                const length: integer
                local const data: foreign int[]
            end
            local union Buffers
                empty()
                present(data: foreign int[], size: integer)
            end
            local function use(b: Buffer, u: Buffers): integer
                b.data[0] = 7
                case u
                when empty() then return b.data[0]
                when present(data, size) then return data[0] + size
                end
            end
            local function create(): Buffer
                return Buffer.new(0, nil)
            end
        ]], probe_session)
        assert.truthy(ok, err)
        local buffer = declaration(ast, "Buffer")._type
        local data = buffer.fields[2]
        assert.equal("Type.CPointer", data.type._tag)
        assert.equal(1, data.index)
        assert.same(data.type, buffer.functions.new.params[2])
        local written = declaration(ast, "Buffer").fields[2]
        assert.equal("borrowed_array_view", written._nominal_storage.kind)
        local buffers = declaration(ast, "Buffers")._type
        local part = buffers.variants.present.parts[1]
        assert.equal("Type.CPointer", part.type._tag)
        assert.equal(1, part.index)
        assert.is_false(part.isconst)
        assert.same(part.type, buffers.functions.present.params[1])
        local case = declaration(ast, "use").block.stats[2]
        assert.equal("Type.CPointer", case.arms[2].bindings[1]._type._tag)
    end)

    it("admits fixed native members and checks borrowed projections independently of storage types",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local record Box
                    const point: foreign ns_point
                    cell: foreign ns_cell
                    row: foreign ns_row
                end
                local function create(): Box
                    local point = foreign ns_point.new()
                    local cell = foreign ns_cell.new()
                    return Box.new(point, cell, ffi.ns_source_row)
                end
                local function change(box: Box, replacement: foreign ns_cell)
                    local point = box.point
                    point.x = 11
                    local row = box.row
                    row[1] = 12
                    box.cell = replacement
                    box.row = ffi.ns_source_row
                    box.point.y = 13
                end
            ]])
            assert.truthy(ok, err)
            local box = declaration(ast, "Box")._type
            assert.equal("Type.CStruct", types.resolve_c_typedef(box.fields[1].type)._tag)
            assert.equal("Type.CUnion", types.resolve_c_typedef(box.fields[2].type)._tag)
            assert.equal("Type.CArray", types.resolve_c_typedef(box.fields[3].type)._tag)
            assert.is_false(types.has_tvalue_representation(box.fields[1].type))
            assert.is_false(types.has_tvalue_representation(box.fields[3].type))
            local stats = declaration(ast, "change").block.stats
            local projection = stats[1].exps[1].var
            assert.equal("Type.CPointer", projection._type._tag)
            assert.equal("fixed_aggregate", projection._nominal_storage.kind)
            assert.same(box.fields[1].type, projection._nominal_storage.storage_type)
            assert.same(projection._type, projection._nominal_projection_type)
            assert.is_false(types.c_pointer_has_qual(projection._type, "const"))
            assert.equal("Type.CPointer", stats[3].decls[1]._type._tag)
            assert.equal("Type.CUnion", types.resolve_c_typedef(stats[5].vars[1]._type)._tag)
            assert.equal("Type.CArray", types.resolve_c_typedef(stats[6].vars[1]._type)._tag)
        end)
    end)

    it("keeps declared C qualification on projected pointers",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local record Readonly
                    point: foreign ns_const_point
                    row: foreign ns_const_row
                end
                local function view(holder: Readonly)
                    local point = holder.point
                    local row = holder.row
                end
            ]])
            assert.truthy(ok, err)
            local stats = declaration(ast, "view").block.stats
            assert.is_true(types.c_pointer_has_qual(stats[1].decls[1]._type, "const"))
            assert.is_true(types.c_pointer_has_qual(stats[2].decls[1]._type, "const"))
            local accepted, failure = check([[
                local record Readonly
                    point: foreign ns_const_point
                end
                local function view(holder: Readonly): foreign *ns_point
                    return holder.point
                end
            ]])
            assert.is_false(accepted)
            assert.match("const", failure)
        end)
    end)

    it("projects union parts as mutable borrowed addresses without changing part ordinals or const flags",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local union Native
                    empty()
                    pair(number: integer, point: foreign ns_point, row: foreign ns_row)
                end
                local function alter(value: Native): integer
                    case value
                    when empty() then return 0
                    when pair { point = point, row = row } then
                        point.x = 5
                        row[0] = 6
                        return point.x + row[0]
                    end
                end
            ]])
            assert.truthy(ok, err)
            local variant = declaration(ast, "Native")._type.variants.pair
            assert.equal(2, variant.parts[2].index)
            assert.is_false(variant.parts[2].isconst)
            local arm = declaration(ast, "alter").block.stats[1].arms[2]
            for index, binding in ipairs(arm.bindings) do
                assert.equal("Type.CPointer", binding._type._tag)
                assert.equal("fixed_aggregate", binding._nominal_storage.kind)
                assert.equal(index + 1, binding._part_index)
                assert.is_false(types.c_pointer_has_qual(binding._type, "const"))
            end
        end)
    end)

    it("rejects const field replacement and unproven fixed-array extents",
    function()
        with_header(function(check)
            local cases = {
                { [[
                    local record Box const point: foreign ns_point end
                    local function change(box: Box, point: foreign ns_point)
                        box.point = point
                    end
                ]], "cannot assign to const field 'point'" },
                { [[
                    local record Box row: foreign ns_row end
                    local function create(): Box
                        return Box.new(ffi.ns_source_short_row)
                    end
                ]], "argument" },
                { [[
                    local record Box row: foreign ns_row end
                    local function create(pointer: foreign *int): Box
                        return Box.new(pointer)
                    end
                ]], "argument" },
            }
            for _, case in ipairs(cases) do
                local ok, err = check(case[1])
                assert.is_false(ok)
                assert.match(case[2], err, 1, true)
            end
        end)
    end)

    it("rejects incomplete, flexible, and recursively GC-bearing embedded storage",
    function()
        with_header(function(check)
            local cases = {
                { "ns_incomplete", "requires complete C struct" },
                { "ns_incomplete_row", "requires a complete C array" },
                { "ns_packet", "flexible array member" },
                { "ns_packet_union", "flexible array member" },
                { "ns_packet_outer", "flexible array member" },
                { "ns_gc_value", "GC-bearing FFI storage" },
                { "ns_gc_outer", "GC-bearing FFI storage" },
            }
            for _, case in ipairs(cases) do
                for _, body in ipairs({
                    "local record Bad field: foreign " .. case[1] .. " end",
                    "local union Bad part(foreign " .. case[1] .. ") end",
                }) do
                    local ok, err = check(body)
                    assert.is_false(ok)
                    assert.match(case[2], err, 1, true)
                end
            end
        end)
    end)

    it("retains TValue and Udata tracing exceptions and rejects general aggregate boxing",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local record Traced
                    value: foreign TValue
                    object: foreign *Udata
                end
                local function read(holder: Traced): foreign TValue
                    return holder.value
                end
            ]])
            assert.truthy(ok, err)
            local returned = declaration(ast, "read").block.stats[1].exps[1]
            assert.is_true(types.is_c_tvalue(returned._type))
            assert.equal("value", returned.var._nominal_storage.kind)
            local accepted, failure = check([[
                local function boxed(point: foreign ns_point): value
                    return point
                end
            ]])
            assert.is_false(accepted)
            assert.match("value", failure)
        end)
    end)

    it("preserves fixed projections alongside erased generic member storage",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local record Box<|T|>
                    value: T
                    local const point: foreign ns_point
                end
                local union Slot<|T|>
                    present(value: T, point: foreign ns_point)
                end
                local function read(box: Box<|integer|>): integer
                    local point = box.point
                    point.x = 4
                    return box.value + point.x
                end
                local function read_slot(slot: Slot<|integer|>): integer
                    case slot
                    when present(value, point) then
                        point.x = 9
                        return value
                    end
                end
            ]])
            assert.truthy(ok, err)
            local record = declaration(ast, "Box")._type
            assert.equal("Type.Value", record.fields[1].type._tag)
            local projected = declaration(ast, "read").block.stats[1].exps[1].var
            assert.equal("Type.CPointer", projected._type._tag)
            assert.equal("fixed_aggregate", projected._nominal_storage.kind)
            local bindings = declaration(ast, "read_slot").block.stats[1].arms[1].bindings
            assert.equal("Type.Value", bindings[1]._type._tag)
            assert.equal("value", bindings[1]._nominal_storage.kind)
            assert.equal("Type.CPointer", bindings[2]._type._tag)
            assert.equal("fixed_aggregate", bindings[2]._nominal_storage.kind)
        end)
    end)

    it("retains direct fresh array plans through positional adjustment and surplus effects",
    function()
        local ok, err, ast = h.run_checker([[
            local record NativeIntArray
                const length: integer
                local const array: foreign int[]
            end
            local function effect(): integer return 17 end
            local function create(count: integer): NativeIntArray
                return NativeIntArray.new(count,
                    foreign int.new_array(count), effect())
            end
        ]], probe_session)
        assert.truthy(ok, err)
        local call = uncast(declaration(ast, "create").block.stats[1].exps[1])
        local constructor = assert(call._nominal_constructor)
        assert.equal("record", constructor.kind)
        assert.same({ 0, 1 }, constructor.field_indices)
        local allocation = constructor.allocation_plans[2]
        assert.equal("nominal_tail", allocation.storage)
        assert.equal("Type.CPointer", allocation.result_type._tag)
        assert.equal(2, allocation.nominal_slot_index)
        local source = uncast(call._arg_adjustment.fixed[2])
        assert.same(source._c_allocation_plan, allocation)
        assert.same(source._arg_adjustment.fixed[1], allocation.count_expression)
        assert.equal(1, #call._arg_adjustment.discards)
        assert.equal(3, #call._arg_adjustment.exps)
    end)

    it("retains named and generic constructor plans in lexical argument order",
    function()
        local ok, err, ast = h.run_checker([[
            local record Mixed<|T|>
                value: T
                const first: foreign int[]
                const second: foreign long double[]
            end
            local function count(value: integer): integer return value end
            local function create(): Mixed<|integer|>
                return Mixed.new{
                    second = foreign long double.new_array(count(0)),
                    value = 21,
                    first = foreign int.new_array(count(4)),
                }
            end
        ]], probe_session)
        assert.truthy(ok, err)
        local call = uncast(declaration(ast, "create").block.stats[1].exps[1])
        assert.same({ 3, 1, 2 }, call._named_arg_order)
        local constructor = assert(call._nominal_constructor)
        assert.equal("Type.Value", constructor.slots[1].type._tag)
        assert.equal("Type.Value", constructor.owner.fields[1].type._tag)
        assert.is_nil(constructor.allocation_plans[1])
        for _, index in ipairs({ 2, 3 }) do
            local allocation = constructor.allocation_plans[index]
            assert.equal("nominal_tail", allocation.storage)
            assert.same(allocation, uncast(call.args.args[index])._c_allocation_plan)
            assert.equal("Ast.ExpCall", allocation.count_expression._tag)
        end
    end)

    it("plans fixed object and fixed-array initialization without an owned intermediate",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local record Fixed
                    point: foreign ns_point
                    first: foreign ns_row
                    second: foreign ns_row
                    symbolic: foreign ns_symbolic_row
                end
                local function create(): Fixed
                    return Fixed.new(foreign ns_point.new(),
                        foreign ns_row.new(), foreign int.new_array(3),
                        foreign int.new_array(3))
                end
            ]])
            assert.truthy(ok, err)
            local call = uncast(declaration(ast, "create").block.stats[1].exps[1])
            for index, allocation in ipairs(call._nominal_constructor.allocation_plans) do
                assert.equal("nominal_fixed", allocation.storage)
                assert.same(call._nominal_constructor.slots[index].type,
                    allocation.result_type)
                assert.is_false(types.has_tvalue_representation(allocation.result_type))
                assert.same(allocation, uncast(call._arg_adjustment.fixed[index])._c_allocation_plan)
            end
            assert.equal(4, #call._nominal_constructor.allocation_plans)
        end)
    end)

    it("plans array and FAM union tails without changing immutable part descriptors",
    function()
        with_header(function(check)
            local ok, err, ast = check([[
                local union Native
                    pair(array: foreign const *int, packet: foreign *ns_packet)
                end
                local function create(count: integer): Native
                    return Native.pair(foreign int.new_array(0),
                        foreign ns_packet.new(count))
                end
            ]])
            assert.truthy(ok, err)
            local call = uncast(declaration(ast, "create").block.stats[1].exps[1])
            local constructor = assert(call._nominal_constructor)
            assert.equal("union", constructor.kind)
            assert.equal("pair", constructor.variant.name)
            assert.same({ 1, 2 }, constructor.field_indices)
            assert.is_false(constructor.slots[1].isconst)
            local array, fam = constructor.allocation_plans[1], constructor.allocation_plans[2]
            assert.equal("nominal_tail", array.storage)
            assert.equal(0, array.array_count_literal)
            assert.is_true(types.c_pointer_has_qual(array.result_type, "const"))
            assert.equal("nominal_tail", fam.storage)
            assert.is_true(fam.fam)
            assert.equal("data", fam.fam_field.name)
        end)
    end)

    it("does not infer freshness through callable aliases, returned owners, or mutable fields",
    function()
        local ok, err, ast = h.run_checker([[
            local record Buffer const data: foreign int[] end
            local record Mutable data: foreign int[] end
            local function allocate(count: integer): owned int[]
                return foreign int.new_array(count)
            end
            local function create(count: integer)
                local constructor = Buffer.new
                local aliased = constructor(foreign int.new_array(count))
                local mutable = Mutable.new(foreign int.new_array(count))
                local indirect = Buffer.new(allocate(count))
                local owner: owned int[] = foreign int.new_array(count)
                local borrowed = Buffer.new(owner)
            end
        ]], probe_session)
        assert.truthy(ok, err)
        local stats = declaration(ast, "create").block.stats
        local aliased = uncast(stats[2].exps[1])
        assert.is_nil(aliased._nominal_constructor)
        assert.equal("owned", uncast(aliased._arg_adjustment.fixed[1])._c_allocation_plan.storage)
        for _, index in ipairs({ 3, 4, 6 }) do
            local call = uncast(stats[index].exps[1])
            assert.is_nil(next(call._nominal_constructor.allocation_plans))
        end
        local mutable = uncast(stats[3].exps[1])
        assert.equal("owned", uncast(mutable._arg_adjustment.fixed[1])._c_allocation_plan.storage)
    end)

    it("rejects unproven fixed allocation extents and GC-bearing fused tails",
    function()
        with_header(function(check)
            for _, count in ipairs({ "2", "0", "length" }) do
                local ok, err = check([[
                    local record Fixed row: foreign ns_row end
                    local function create(length: integer): Fixed
                        return Fixed.new(foreign int.new_array(]] .. count .. [[))
                    end
                ]])
                assert.is_false(ok)
                assert.match("fixed nominal C array", err, 1, true)
            end
            local ok, err = check([[
                local record Hidden const data: foreign ns_gc_value[] end
                local function create(length: integer): Hidden
                    return Hidden.new(foreign ns_gc_value.new_array(length))
                end
            ]])
            assert.is_false(ok)
            assert.match("fused nominal tail", err, 1, true)
            assert.match("GC-bearing FFI storage", err, 1, true)
        end)
    end)
end)
